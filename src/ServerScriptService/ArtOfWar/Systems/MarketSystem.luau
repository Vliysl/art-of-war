local MarketSystem = {}

local ctx
local markets = {}

local CATEGORY_DEMAND = {
	staple = 1.25,
	fuel = 1.1,
	construction = 0.95,
	textile = 1.0,
	metal = 1.0,
	chemical = 0.9,
	military = 0.85,
	manufactured = 1.1,
	luxury = 0.55,
}

local PRICE_STEP = 0.3
local PRICE_CHANGE_EPSILON = 0.01

local function seedMarkets()
	table.clear(markets)
	local bundle = ctx.Bundle
	if not bundle or not bundle.tradeGoods then return end
	for goodId, def in bundle.tradeGoods do
		if def.unlockedByDefault ~= false then
			local m = {
				goodId = goodId,
				category = def.category,
				basePrice = def.basePrice,
				price = def.basePrice,
				supply = 0,
				demand = 0,
				lastChange = 0,
				researchGate = def.researchGate,
			}
			markets[goodId] = m
			ctx.WorldState.setMarket(goodId, m)
		end
	end
end

local function unlockGood(goodId)
	if markets[goodId] then return false end
	local bundle = ctx.Bundle
	local def = bundle and bundle.tradeGoods and bundle.tradeGoods[goodId]
	if not def then return false end
	local m = {
		goodId = goodId,
		category = def.category,
		basePrice = def.basePrice,
		price = def.basePrice,
		supply = 0,
		demand = 0,
		lastChange = 0,
		researchGate = def.researchGate,
	}
	markets[goodId] = m
	ctx.WorldState.setMarket(goodId, m)
	return true
end

-- perf: supply is an O(5713-province) scan, but it only changes when a province's owner / dev /
-- infra / goods change. Gate the scan on a dirty flag (set by the relevant events) with a slow
-- full-recompute fallback; prices still rebalance every tick off the cached supply/demand.
local supplyDirty = true
local lastSupplyRecomputeAt = -math.huge
local SUPPLY_FULL_INTERVAL = 30

local function recompute()
	local now = ctx.TickScheduler.getSimTime()
	if not supplyDirty and (now - lastSupplyRecomputeAt) < SUPPLY_FULL_INTERVAL then
		return
	end
	supplyDirty = false
	lastSupplyRecomputeAt = now
	for _, m in markets do
		m.supply = 0
		m.demand = 0
	end
	for _, prov in ctx.WorldState.allProvinces() do
		if prov.ownerTag and prov.ownerTag ~= "NONE" then
			local goods = prov.goods
			local devBoost = (prov.devTier or 0) * 0.25
			local infraBoost = (prov.infraTier or 0) * 0.1
			local supplyBoost = 1 + devBoost + infraBoost
			if goods and next(goods) ~= nil then
				for goodId, baseAmount in goods do
					local m = markets[goodId]
					if m and baseAmount and baseAmount > 0 then
						m.supply += supplyBoost * baseAmount
					end
				end
			elseif prov.tradeGood then
				local m = markets[prov.tradeGood]
				if m then m.supply += supplyBoost end
			end
		end
	end
	local owningCountries = 0
	for tag in ctx.WorldState.allCountries() do
		local ownedIds = ctx.ProvinceRegistry and ctx.ProvinceRegistry.byOwner(tag) or {}
		if #ownedIds > 0 then owningCountries += 1 end
	end
	if owningCountries == 0 then owningCountries = 1 end
	for _, m in markets do
		local scale = CATEGORY_DEMAND[m.category] or 1
		m.demand = owningCountries * scale
	end
end

local function rebalance()
	local wc = ctx.WorldConstants
	for goodId, m in markets do
		local supply = math.max(m.supply, 0.01)
		local ratio = m.demand / supply
		local clamped = math.clamp(ratio, wc.PriceBandLow, wc.PriceBandHigh)
		local target = m.basePrice * clamped
		local nextPrice = m.price + (target - m.price) * PRICE_STEP
		local delta = nextPrice - m.price
		m.price = nextPrice
		if math.abs(delta) > m.basePrice * PRICE_CHANGE_EPSILON then
			m.lastChange = delta
			ctx.WorldState.setMarket(goodId, m)
			ctx.EventBus.publish(ctx.Channels.MarketPriceChanged, {
				goodId = goodId,
				price = nextPrice,
				supply = m.supply,
				demand = m.demand,
				delta = delta,
			})
		end
	end
end

local function tickMarket()
	recompute()
	rebalance()
end

function MarketSystem.register(context)
	ctx = context
	ctx.MarketSystem = {
		get = function(id) return markets[id] end,
		all = function() return markets end,
		priceOf = function(id)
			local m = markets[id]
			return m and m.price or nil
		end,
		unlockGood = unlockGood,
	}
	local function markSupplyDirty() supplyDirty = true end
	ctx.EventBus.subscribe(ctx.Channels.ProvinceOwnershipChanged, markSupplyDirty)
	ctx.EventBus.subscribe(ctx.Channels.ProvinceDevelopmentChanged, markSupplyDirty)
	ctx.EventBus.subscribe(ctx.Channels.BuildingCompleted, markSupplyDirty)
	ctx.EventBus.subscribe(ctx.Channels.ProvinceOccupied, markSupplyDirty)

	ctx.TickScheduler.register({
		id = "MarketSystem",
		priority = 25,
		updateIntervalSeconds = ctx.WorldConstants.SecondsPerEconomyUpdate,
		update = tickMarket,
		start = seedMarkets,
	})
end

return MarketSystem
