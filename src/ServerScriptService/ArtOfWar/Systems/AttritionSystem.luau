-- AttritionSystem (Phase 5): monthly land attrition (spec B.10 / 6.9).
-- Crowding: stacked army strength over a province's supply limit bleeds the stack.
-- Terrain/frost: harsh climate bleeds armies in UNSUPPLIED (enemy/neutral) territory;
--   armies in friendly (controller == owner) provinces suffer ONLY crowding.
-- Naval formations and armies in active battle are exempt (combat/naval own those).
-- Wasteland (prov.isWasteland) and winter (prov.winter) are HOOKS (no data yet -> 0).
-- Applies via ArmySystem.applyCasualties (fraction of regiment count), month-gated.
local AttritionSystem = {}

local ctx

local function terrainOf(prov)
	local b = ctx.Bundle
	return (b and b.terrains and prov and b.terrains[prov.terrain]) or nil
end

local lastAttritionMonth = nil

local function runAttrition(months)
	months = months or 1
	local C = ctx.WorldConstants
	local AS = ctx.ArmySystem
	if not AS or not AS.compositionStrength or not AS.applyCasualties then return end

	-- Group ground armies (not in battle) by province; sum strength for crowding.
	local byProv = {}
	for _, army in ctx.WorldState.allArmies() do
		if army.domain ~= "naval" and not army.battleId and army.provinceId then
			local g = byProv[army.provinceId]
			if not g then g = { armies = {}, strength = 0 }; byProv[army.provinceId] = g end
			table.insert(g.armies, army)
			g.strength += AS.compositionStrength(army.composition)
		end
	end

	local base = C.ProvinceSupplyLimitBase or 5000
	local perDev = C.ProvinceSupplyLimitPerDev or 500
	local crowdRate = C.AttritionCrowdingRate or 0.05
	local terrScale = C.AttritionTerrainScale or 0.02
	local terrFree = C.AttritionTerrainFreeSupply or 8
	local frostRate = C.AttritionFrostRate or 0.03
	local cap = (C.AttritionMaxPerMonth or 0.10) * months

	for pid, g in pairs(byProv) do
		local prov = ctx.WorldState.getProvince(pid)
		if prov then
			local devTier = prov.devTier or 1
			local supply = base + devTier * perDev
			local crowd = 0
			if g.strength > supply and supply > 0 then
				crowd = ((g.strength - supply) / supply) * crowdRate
			end
			local terr = terrainOf(prov)
			local tsupply = terr and terr.supplyLimit
			local terrainAttr = 0
			if tsupply and tsupply > 0 then
				terrainAttr = terrScale * math.max(0, terrFree - tsupply) / terrFree
			end
			if prov.isWasteland then terrainAttr += terrScale end  -- hook (no data)
			local frost = prov.winter and frostRate or 0           -- hook (no season system)
			for _, army in ipairs(g.armies) do
				local friendly = (prov.controllerTag == army.ownerTag)
				local rate = crowd
				if not friendly then rate += terrainAttr + frost end
				rate = rate * months
				if rate > cap then rate = cap end
				if rate > 0 then
					AS.applyCasualties(army.id, rate)
				end
			end
		end
	end
end

local function attritionTick(sysCtx)
	local gd = (sysCtx and sysCtx.gameDate) or (ctx.TickScheduler.getGameDate and ctx.TickScheduler.getGameDate())
	if not gd then return end
	local mi = gd.year * 12 + (gd.month - 1)
	if lastAttritionMonth == nil then
		lastAttritionMonth = mi
		return
	end
	if mi ~= lastAttritionMonth then
		local months = mi - lastAttritionMonth
		lastAttritionMonth = mi
		runAttrition(months)
	end
end

function AttritionSystem.register(context)
	ctx = context
	local api = { runAttrition = runAttrition }
	context.AttritionSystem = api
	for k, v in pairs(api) do AttritionSystem[k] = v end

	context.TickScheduler.register({
		id = "AttritionSystem",
		priority = 39,
		updateIntervalSeconds = context.WorldConstants.AttritionTickInterval
			or context.WorldConstants.ManpowerRegenTickInterval or 6,
		update = attritionTick,
	})
end

return AttritionSystem
