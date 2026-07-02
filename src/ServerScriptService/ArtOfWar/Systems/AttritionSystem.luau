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

-- Encirclement: a land army is in a pocket when NO adjacent land province is controlled by it
-- or an ally (supply line severed) AND at least one adjacent land province is held by an enemy
-- it is at war with (a real front, not a peaceful island). Sea nodes (negative ids) are ignored:
-- they neither supply nor besiege.
local function isEncircled(army)
	local pid = army.provinceId
	if pid == nil or (type(pid) == "number" and pid < 0) then return false end
	local adj = ctx.AdjacencyGraph
	if not (adj and adj.getNeighbors) then return false end
	local owner = army.ownerTag
	local dipl = ctx.DiplomacySystem
	local hasEnemy = false
	for _, n in ipairs(adj.getNeighbors(pid)) do
		if type(n) == "number" and n >= 0 then
			local np = ctx.WorldState.getProvince(n)
			if np then
				local c = np.controllerTag
				if c == owner then
					return false
				end
				if c and c ~= "" and c ~= "NONE" then
					if dipl and dipl.areAllied and dipl.areAllied(owner, c) then
						return false
					end
					if dipl and dipl.areAtWar and dipl.areAtWar(owner, c) then
						hasEnemy = true
					end
				end
			end
		end
	end
	return hasEnemy
end

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
	local encircleAttr = C.EncirclementAttritionPerMonth or 0
	local encircleOrg = C.EncirclementOrgLossPerMonth or 0
	local encircleOn = encircleAttr > 0 or encircleOrg > 0

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
				-- Encirclement penalty sits ON TOP of the normal cap (a pocket bleeds worse than
				-- any single terrain) and additionally drains organization, which has no passive regen.
				if encircleOn and isEncircled(army) then
					if encircleAttr > 0 then
						rate += encircleAttr * months
					end
					if encircleOrg > 0 and AS.adjustOrganization then
						AS.adjustOrganization(army.id, -encircleOrg * months)
					end
				end
				if rate > 0 then
					AS.applyCasualties(army.id, rate)
				end
			end
		end
	end
end

-- Per-tick (not month-gated): stamp a replicated supply status on each ground army
-- for the UI to show ("adequate" | "crowded" | "starving"). Read-only annotation —
-- the actual casualty application stays monthly in runAttrition. Only writes when the
-- status changes, to avoid replication churn.
local function computeSupplyStatus()
	local C = ctx.WorldConstants
	local AS = ctx.ArmySystem
	if not AS or not AS.compositionStrength then return end

	local byProv = {}
	for _, army in ctx.WorldState.allArmies() do
		-- Match runAttrition's exemptions: naval formations and armies in active
		-- battle are not subject to supply, so they get no status stamp either.
		if army.domain ~= "naval" and not army.battleId and army.provinceId then
			local g = byProv[army.provinceId]
			if not g then g = { armies = {}, strength = 0 }; byProv[army.provinceId] = g end
			table.insert(g.armies, army)
			g.strength += AS.compositionStrength(army.composition)
		end
	end

	local base = C.ProvinceSupplyLimitBase or 5000
	local perDev = C.ProvinceSupplyLimitPerDev or 500
	local terrFree = C.AttritionTerrainFreeSupply or 8

	for pid, g in pairs(byProv) do
		local prov = ctx.WorldState.getProvince(pid)
		if prov then
			local supply = base + (prov.devTier or 1) * perDev
			local overCrowded = supply > 0 and g.strength > supply
			local terr = terrainOf(prov)
			local tsupply = terr and terr.supplyLimit
			local harsh = (tsupply and tsupply > 0 and (terrFree - tsupply) > 0) or prov.isWasteland or prov.winter or false
			for _, army in ipairs(g.armies) do
				local friendly = (prov.controllerTag == army.ownerTag)
				local status = "adequate"
				if not friendly and harsh then
					status = "starving"
				elseif overCrowded then
					status = "crowded"
				end
				if army.supplyStatus ~= status then
					army.supplyStatus = status
					ctx.WorldState.setArmy(army.id, army)
				end
			end
		end
	end
end

local function attritionTick(sysCtx)
	computeSupplyStatus()
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
