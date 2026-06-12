--!strict
-- ManufactorySystem: each constructed manufactory building consumes input
-- goods from the country stockpile and produces output goods, scaled by
-- daily cycles and infraTier. Operates per-day on Channels.DateAdvanced.
-- If any required input is depleted, throughput is scaled to whatever is
-- available (partial-yield cycle).

local ManufactorySystem = {}

local ctx
local cachedCountryProduction = {}    -- [tag] = { [goodId] = amount }
local cachedCountryConsumption = {}

local function manufactoryBuildingsFor(province)
	-- Iterate constructed buildings; return the manufactory ids in sequence.
	if not province or not province.buildings then return nil end
	local out = {}
	local bundle = ctx.Bundle
	for _, bid in province.buildings do
		local def = bundle.buildingTypes and bundle.buildingTypes[bid]
		if def and def.manufactoryId then
			table.insert(out, def.manufactoryId)
		end
	end
	return out
end

local function throughputScale(infraTier, minInfra)
	local wc = ctx.WorldConstants
	local base = wc.ManufactoryDailyCycles or 0.1
	local per = wc.ManufactoryInfraScalePerTier or 0.05
	local diff = math.max(0, (infraTier or 0) - (minInfra or 0))
	return base * (1 + per * diff)
end

local function recomputeFor(tag)
	local country = ctx.WorldState.getCountry(tag)
	if not country then
		cachedCountryProduction[tag] = {}
		cachedCountryConsumption[tag] = {}
		return {}, {}
	end

	local bundle = ctx.Bundle
	local mfgs = bundle.manufactories or {}
	local provinceIds = (ctx.ProvinceRegistry and ctx.ProvinceRegistry.byOwner(tag)) or {}
	local production, consumption = {}, {}

	for _, pid in provinceIds do
		local province = ctx.WorldState.getProvince(pid)
		if province and province.controllerTag == tag then
			local mfgIds = manufactoryBuildingsFor(province)
			if mfgIds then
				for _, mid in mfgIds do
					local mdef = mfgs[mid]
					if mdef then
						local cycles = throughputScale(province.infraTier or 0, mdef.minInfraTier or 0)
						-- Inputs are per-cycle; multiplied by daily cycles for per-day demand.
						for goodId, amount in (mdef.inputs or {}) do
							consumption[goodId] = (consumption[goodId] or 0) + (amount * cycles)
						end
						local outAmt = (mdef.outputAmount or 0) * cycles
						if mdef.output and outAmt > 0 then
							production[mdef.output] = (production[mdef.output] or 0) + outAmt
						end
					end
				end
			end
		end
	end

	cachedCountryProduction[tag] = production
	cachedCountryConsumption[tag] = consumption
	return production, consumption
end

local function applyDays(daysAdvanced)
	if not daysAdvanced or daysAdvanced <= 0 then return end
	-- S3: only relevant (claimed / at-war) countries are simulated.
	local relevant = ctx.PlayerAuthority and ctx.PlayerAuthority.relevantSet and ctx.PlayerAuthority.relevantSet() or nil
	for tag in ctx.WorldState.allCountries() do
		if relevant and not relevant[tag] then continue end
		-- S1: use cached per-cycle production/consumption (recomputed lazily on province/
		-- building mutation) instead of re-scanning every country's provinces every tick.
		if cachedCountryProduction[tag] == nil then recomputeFor(tag) end
		local production = cachedCountryProduction[tag] or {}
		local consumption = cachedCountryConsumption[tag] or {}
		local country = ctx.WorldState.getCountry(tag)
		if not country then continue end
		-- S1 guard: no manufactories -> no stockpile changes, no write/replication.
		if next(production) == nil and next(consumption) == nil then continue end
		country.stockpiles = country.stockpiles or {}
		country.dailyConsumption = country.dailyConsumption or {}

		-- Determine how much we can actually run based on input availability.
		-- ratio in [0,1]; if ANY input is undersupplied, throttle uniformly.
		local ratio = 1
		for goodId, dailyAmount in consumption do
			if dailyAmount > 0 then
				local available = country.stockpiles[goodId] or 0
				local needed = dailyAmount * daysAdvanced
				if needed > 0 then
					ratio = math.min(ratio, available / needed)
				end
			end
		end
		ratio = math.clamp(ratio, 0, 1)

		-- Apply consumption (clamped) and production (scaled by ratio)
		local appliedConsumption = {}
		for goodId, dailyAmount in consumption do
			local consumed = dailyAmount * daysAdvanced * ratio
			country.stockpiles[goodId] = math.max(0, (country.stockpiles[goodId] or 0) - consumed)
			appliedConsumption[goodId] = dailyAmount * ratio
		end

		local appliedProduction = {}
		for goodId, dailyAmount in production do
			local produced = dailyAmount * daysAdvanced * ratio
			country.stockpiles[goodId] = (country.stockpiles[goodId] or 0) + produced
			appliedProduction[goodId] = dailyAmount * ratio
		end

		-- Merge into country.dailyProduction (province output already lives there;
		-- manufactory adds to the same map so the UI sees totals).
		country.dailyProduction = country.dailyProduction or {}
		for goodId, amount in appliedProduction do
			country.dailyProduction[goodId] = (country.dailyProduction[goodId] or 0) + amount
		end
		country.dailyConsumption = appliedConsumption

		ctx.WorldState.setCountry(tag, country)

		if next(appliedProduction) ~= nil then
			ctx.EventBus.publish(ctx.Channels.ManufactoryProduced, {
				tag = tag,
				produced = appliedProduction,
				consumed = appliedConsumption,
				ratio = ratio,
			})
		end
	end
end

local function dailyProductionOf(tag)
	if cachedCountryProduction[tag] == nil then recomputeFor(tag) end
	return cachedCountryProduction[tag] or {}
end

local function dailyConsumptionOf(tag)
	if cachedCountryConsumption[tag] == nil then recomputeFor(tag) end
	return cachedCountryConsumption[tag] or {}
end

local function onProvinceMutated()
	table.clear(cachedCountryProduction)
	table.clear(cachedCountryConsumption)
end

ManufactorySystem.applyDays = function(...) return applyDays(...) end
ManufactorySystem.dailyProductionOf = function(...) return dailyProductionOf(...) end
ManufactorySystem.dailyConsumptionOf = function(...) return dailyConsumptionOf(...) end
ManufactorySystem.recomputeFor = function(...) return recomputeFor(...) end

function ManufactorySystem.register(context)
	ctx = context
	context.ManufactorySystem = {
		applyDays = applyDays,
		dailyProductionOf = dailyProductionOf,
		dailyConsumptionOf = dailyConsumptionOf,
		recomputeFor = recomputeFor,
	}
	context.EventBus.subscribe(context.Channels.BuildingCompleted, onProvinceMutated)
	context.EventBus.subscribe(context.Channels.ProvinceOwnershipChanged, onProvinceMutated)

	-- Run AFTER EconomySystem so its province output lands first; then we layer on top.
	context.TickScheduler.register({
		id = "ManufactorySystem",
		priority = 29,
		updateIntervalSeconds = (context.WorldConstants.SecondsPerEconomyUpdate or 3),
		update = function() end,
	})
end

return ManufactorySystem
