--!strict
-- ManufactorySystem: each constructed manufactory building consumes input
-- goods from the country stockpile and produces output goods, scaled by
-- daily cycles and infraTier. Operates per-day on Channels.DateAdvanced.
-- If any required input is depleted, throughput is scaled to whatever is
-- available (partial-yield cycle).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DistrictTypes =
	require(ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Data"):WaitForChild("DistrictTypes"))

local ManufactorySystem = {}

local ctx
local cachedCountryProduction = {} -- [tag] = { [goodId] = amount }
local cachedCountryConsumption = {}
local sortedByFamily = nil -- { Industrial = {sorted recipe entries}, Manufacturing = {...} }

-- Build the per-family recipe ranking once (highest output value first). Under the district economy an
-- Industrial/Manufacturing district auto-picks the best recipe of its family that the province's infra can
-- host; input scarcity is handled by the per-cycle ratio throttle in applyDays.
local function ensureSorted()
	if sortedByFamily then
		return
	end
	sortedByFamily = { Industrial = {}, Manufacturing = {} }
	local mfgs = (ctx.Bundle and ctx.Bundle.manufactories) or {}
	local goods = (ctx.Bundle and ctx.Bundle.tradeGoods) or {}
	for _, mdef in mfgs do
		if mdef.unlockedByDefault ~= false and mdef.output then
			local fam = DistrictTypes.manufactoryFamilyFor(mdef.output)
			local price = (goods[mdef.output] and goods[mdef.output].basePrice) or 0
			local list = sortedByFamily[fam]
			if list then
				table.insert(
					list,
					{ mdef = mdef, value = (mdef.outputAmount or 0) * price, minInfra = mdef.minInfraTier or 0 }
				)
			end
		end
	end
	for _, list in sortedByFamily do
		table.sort(list, function(a, b)
			return a.value > b.value
		end)
	end
end

local function pickBestRecipe(family, infraTier)
	ensureSorted()
	local list = sortedByFamily[family]
	if not list then
		return nil
	end
	for _, entry in list do
		if entry.minInfra <= (infraTier or 0) then
			return entry.mdef
		end
	end
	return nil
end

-- District-driven manufactories: one auto-picked recipe per Industrial/Manufacturing district, throughput
-- scaled by the district LEVEL. Returns a list of { mdef, cycles }.
local function districtManufactoriesFor(province)
	local out = {}
	if not province.districts then
		return out
	end
	local baseCycles = (ctx.WorldConstants and ctx.WorldConstants.ManufactoryDailyCycles) or 0.1
	for _, d in pairs(province.districts) do
		if type(d) == "table" and DistrictTypes.isManufactory(d.type) then
			local def = DistrictTypes.types[d.type]
			local recipe = pickBestRecipe(def and def.family, province.infraTier or 0)
			if recipe then
				table.insert(out, { mdef = recipe, cycles = baseCycles * math.max(1, d.level or 1) })
			end
		end
	end
	return out
end

local function manufactoryBuildingsFor(province)
	-- Iterate constructed buildings; return the manufactory ids in sequence.
	if not province or not province.buildings then
		return nil
	end
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

	-- GateExtractionOnDistricts: manufactories run off Industrial/Manufacturing DISTRICTS (auto-picked
	-- recipe, throughput = district level). Otherwise the legacy path reads province.buildings manufactory_*.
	local gate = ctx.WorldConstants and ctx.WorldConstants.GateExtractionOnDistricts
	for _, pid in provinceIds do
		local province = ctx.WorldState.getProvince(pid)
		if province and province.controllerTag == tag then
			local runs
			if gate then
				runs = districtManufactoriesFor(province)
			else
				runs = {}
				local mfgIds = manufactoryBuildingsFor(province)
				if mfgIds then
					for _, mid in mfgIds do
						local mdef = mfgs[mid]
						if mdef then
							table.insert(runs, {
								mdef = mdef,
								cycles = throughputScale(province.infraTier or 0, mdef.minInfraTier or 0),
							})
						end
					end
				end
			end
			for _, run in runs do
				local mdef, cycles = run.mdef, run.cycles
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

	cachedCountryProduction[tag] = production
	cachedCountryConsumption[tag] = consumption
	return production, consumption
end

local function applyDays(daysAdvanced)
	if not daysAdvanced or daysAdvanced <= 0 then
		return
	end
	-- S3: only relevant (claimed / at-war) countries are simulated.
	local relevant = ctx.PlayerAuthority and ctx.PlayerAuthority.relevantSet and ctx.PlayerAuthority.relevantSet()
		or nil
	for tag in ctx.WorldState.allCountries() do
		if relevant and not relevant[tag] then
			continue
		end
		-- S1: use cached per-cycle production/consumption (recomputed lazily on province/
		-- building mutation) instead of re-scanning every country's provinces every tick.
		if cachedCountryProduction[tag] == nil then
			recomputeFor(tag)
		end
		local production = cachedCountryProduction[tag] or {}
		local consumption = cachedCountryConsumption[tag] or {}
		local country = ctx.WorldState.getCountry(tag)
		if not country then
			continue
		end
		-- S1 guard: no manufactories -> no stockpile changes, no write/replication.
		if next(production) == nil and next(consumption) == nil then
			continue
		end
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
	if cachedCountryProduction[tag] == nil then
		recomputeFor(tag)
	end
	return cachedCountryProduction[tag] or {}
end

local function dailyConsumptionOf(tag)
	if cachedCountryConsumption[tag] == nil then
		recomputeFor(tag)
	end
	return cachedCountryConsumption[tag] or {}
end

local function onProvinceMutated()
	table.clear(cachedCountryProduction)
	table.clear(cachedCountryConsumption)
end

ManufactorySystem.applyDays = function(...)
	return applyDays(...)
end
ManufactorySystem.dailyProductionOf = function(...)
	return dailyProductionOf(...)
end
ManufactorySystem.dailyConsumptionOf = function(...)
	return dailyConsumptionOf(...)
end
ManufactorySystem.recomputeFor = function(...)
	return recomputeFor(...)
end

function ManufactorySystem.register(context)
	ctx = context
	context.ManufactorySystem = {
		applyDays = applyDays,
		dailyProductionOf = dailyProductionOf,
		dailyConsumptionOf = dailyConsumptionOf,
		recomputeFor = recomputeFor,
	}
	context.EventBus.subscribe(context.Channels.BuildingCompleted, onProvinceMutated)
	context.EventBus.subscribe(context.Channels.ProvinceDistrictChanged, onProvinceMutated)
	context.EventBus.subscribe(context.Channels.DistrictUpgraded, onProvinceMutated)
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
