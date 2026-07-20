local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NavalSystem = {}

local ctx
local shipTypes = require(ReplicatedStorage.ArtOfWar.Data.ShipTypes)

local nextFleetId = 1
local nextOrderId = 1
local fleetsByTag = {}
local buildQueueByProvince = {}
local moveOrders = {}
local battles = {}

local function generateFleetId()
	local id = "FLEET_" .. nextFleetId
	nextFleetId += 1
	return id
end

local function generateOrderId()
	local id = "ORDER_" .. nextOrderId
	nextOrderId += 1
	return id
end

local function shipSpec(typeId)
	return shipTypes[typeId]
end

local function hasShipyard(province)
	if not province then return false end
	if province.hasShipyard == true then return true end
	return false
end

local function provinceBelongsTo(province, tag)
	return province and province.ownerTag == tag
end

local function fleetHullPool(fleet)
	local total = 0
	for _, ship in ipairs(fleet.ships or {}) do
		local spec = shipSpec(ship.typeId)
		if spec then
			total += spec.hullStrength * (ship.hullFraction or 1)
		end
	end
	return total
end

-- === Phase 3 naval unification: fleet <-> CombatEngine bridge =========================
-- Fleet organization pool (parallels the land army org pool). base = MIN ship organization
-- present (weakest-link, mirroring ArmySystem.compositionOrganization). A fleet is ONE
-- CombatEngine formation, so it carries a single org/morale pool that depletes in battle and
-- regenerates while docked.
local function fleetBaseOrg(fleet)
	local minOrg
	for _, ship in ipairs(fleet.ships or {}) do
		local spec = shipSpec(ship.typeId)
		if spec then
			local o = spec.organization or 8
			if not minOrg or o < minOrg then minOrg = o end
		end
	end
	return minOrg or 8
end

local function refreshFleetOrg(fleet)
	local base = fleetBaseOrg(fleet)
	fleet.baseOrganization = base
	if (fleet.organization or -1) < 0 or fleet.organization > base then
		fleet.organization = base
	end
end

-- Per-fleet naval technology multiplier (ship attack/defense), gated by EnableTechTree. Deterministic and
-- clamped to its branch cap in ResearchSystem.factor; authored low ("nerfed RON"). Naval combat applied NO
-- country multiplier before this (fleetSide set none), so this is the first technology -> naval wire.
local function techShipFactor(ownerTag, stat)
	if not (ctx.WorldConstants and ctx.WorldConstants.EnableTechTree) then
		return 1
	end
	local rs = ctx.ResearchSystem
	if rs and rs.factor and ownerTag then
		return rs.factor(ownerTag, "ship_" .. stat)
	end
	return 1
end

-- Group a fleet's ships by typeId into CombatEngine unit records. count = sum of hullFraction
-- so that (count * typeStrength) == that type's live hull pool -> sideStrength == fleetHullPool.
local function shipsToUnits(fleet)
	local atkF = techShipFactor(fleet.ownerTag, "attack")
	local defF = techShipFactor(fleet.ownerTag, "defense")
	local byType, order = {}, {}
	for _, ship in ipairs(fleet.ships or {}) do
		local spec = shipSpec(ship.typeId)
		if spec then
			local g = byType[ship.typeId]
			if not g then
				g = {
					typeId = ship.typeId,
					count = 0,
					attack = (spec.attack or (spec.gunpower or 0) / 10) * atkF,
					defense = (spec.defense or (spec.hullStrength or 0) / 20) * defF,
					combatWidth = spec.combatWidth or 3,
					discipline = spec.discipline or 1,
					role = spec.combatRole,
					tags = spec.tags,
					typeStrength = spec.typeStrength or spec.hullStrength or 1,
				}
				byType[ship.typeId] = g
				table.insert(order, g)
			end
			g.count += (ship.hullFraction or 1)
		end
	end
	return order
end

-- Build a CombatEngine side (one formation per fleet) from a fleet record.
local function fleetSide(fleet)
	local base = fleetBaseOrg(fleet)
	return {
		formations = {
			{
				id = fleet.id,
				morale = fleet.morale or ctx.WorldConstants.NavalMoraleMax,
				moraleMax = ctx.WorldConstants.NavalMoraleMax,
				organization = fleet.organization or base,
				baseOrganization = base,
				moraleResist = 0, -- naval admiral hook (generals phase)
				units = shipsToUnits(fleet),
			},
		},
	}
end

-- Apply an engine casualty RATIO to a fleet's hulls (multiplicative: each ship loses that
-- fraction of its remaining hull), dropping ships whose hull depletes.
local function applyShipCasualties(fleet, ratio)
	if not ratio or ratio <= 0 then return end
	local i = 1
	while i <= #fleet.ships do
		local ship = fleet.ships[i]
		ship.hullFraction = math.max(0, (ship.hullFraction or 1) * (1 - ratio))
		if ship.hullFraction <= 0.01 then
			table.remove(fleet.ships, i)
		else
			i += 1
		end
	end
end
-- =====================================================================================

local function registerFleetForTag(tag, fleetId)
	fleetsByTag[tag] = fleetsByTag[tag] or {}
	fleetsByTag[tag][fleetId] = true
end

local function unregisterFleet(tag, fleetId)
	local bucket = fleetsByTag[tag]
	if not bucket then return end
	bucket[fleetId] = nil
end

local function saveFleet(fleet)
	ctx.WorldState.setFleet(fleet.id, fleet)
end

local function removeFleet(fleetId)
	local fleet = ctx.WorldState.getFleet(fleetId)
	if not fleet then return end
	unregisterFleet(fleet.ownerTag, fleetId)
	ctx.WorldState.setFleet(fleetId, nil)
	ctx.EventBus.publish(ctx.Channels.FleetDisbanded, { fleetId = fleetId, ownerTag = fleet.ownerTag })
end

local function createFleet(ownerTag, provinceId, initialShip)
	local id = generateFleetId()
	local fleet = {
		id = id,
		ownerTag = ownerTag,
		provinceId = provinceId,
		ships = initialShip and { initialShip } or {},
		morale = ctx.WorldConstants.NavalMoraleMax,
		organization = 0,
		baseOrganization = 0,
		status = "docked",
		createdAt = ctx.TickScheduler.getSimTime(),
	}
	refreshFleetOrg(fleet)
	registerFleetForTag(ownerTag, id)
	saveFleet(fleet)
	ctx.EventBus.publish(ctx.Channels.FleetCreated, { fleetId = id, ownerTag = ownerTag, provinceId = provinceId })
	return fleet
end

local function addShipToFleet(fleet, typeId)
	local spec = shipSpec(typeId)
	if not spec then return false end
	table.insert(fleet.ships, {
		typeId = typeId,
		hullFraction = 1,
		commissionedAt = ctx.TickScheduler.getSimTime(),
	})
	refreshFleetOrg(fleet)
	saveFleet(fleet)
	return true
end

local function findDockedFleet(tag, provinceId)
	local bucket = fleetsByTag[tag]
	if not bucket then return nil end
	for fleetId in pairs(bucket) do
		local fleet = ctx.WorldState.getFleet(fleetId)
		if fleet and fleet.provinceId == provinceId and fleet.status == "docked" then
			return fleet
		end
	end
	return nil
end

function NavalSystem.queueRecruit(ownerTag, provinceId, typeId, count)
	count = math.clamp(tonumber(count) or 1, 1, ctx.WorldConstants.FleetRecruitMaxPerCall)
	local province = ctx.WorldState.getProvince(provinceId)
	if not province then return false, "unknown province" end
	if not provinceBelongsTo(province, ownerTag) then return false, "not your province" end
	if not hasShipyard(province) then return false, "no shipyard here" end
	if not province.coastal then return false, "shipyard requires coastal province" end
	local spec = shipSpec(typeId)
	if not spec then return false, "unknown ship type" end
	if (province.infraTier or 0) < spec.infraRequirement then return false, "infra too low" end

	local country = ctx.WorldState.getCountry(ownerTag)
	if not country then return false, "unknown country" end
	local costGold = spec.hullCost * count
	local costSailors = spec.sailorCost * count
	if (country.treasury or 0) < costGold then return false, "not enough treasury" end
	if (country.manpower or 0) < costSailors then return false, "not enough manpower" end
	country.treasury = country.treasury - costGold
	country.manpower = country.manpower - costSailors
	ctx.WorldState.setCountry(ownerTag, country)

	buildQueueByProvince[provinceId] = buildQueueByProvince[provinceId] or {}
	for _ = 1, count do
		table.insert(buildQueueByProvince[provinceId], {
			id = generateOrderId(),
			ownerTag = ownerTag,
			typeId = typeId,
			startedAt = ctx.TickScheduler.getSimTime(),
			buildSeconds = spec.buildDays * (ctx.WorldConstants.SecondsPerSimTick / ctx.WorldConstants.DaysPerEarlyTick),
		})
	end
	ctx.EventBus.publish(ctx.Channels.ShipRecruitQueued, {
		ownerTag = ownerTag, provinceId = provinceId, typeId = typeId, count = count,
	})
	return true
end

function NavalSystem.moveFleet(ownerTag, fleetId, destProvinceId)
	local fleet = ctx.WorldState.getFleet(fleetId)
	if not fleet then return false, "unknown fleet" end
	if fleet.ownerTag ~= ownerTag then return false, "not your fleet" end
	if fleet.battleId or fleet.status == "battle" then return false, "in_battle" end
	local dest = ctx.WorldState.getProvince(destProvinceId)
	if not dest then return false, "unknown destination" end

	local sea = ctx.SeaAdjacencyGraph
	if sea and sea.canReach then
		if not sea.canReach(fleet.provinceId, destProvinceId) then
			return false, "destination is not reachable by sea"
		end
	elseif not dest.coastal then
		return false, "destination is not coastal"
	end

	local travel = (sea and sea.travelTime and sea.travelTime(fleet.provinceId, destProvinceId)) or 30

	moveOrders[fleetId] = {
		id = generateOrderId(),
		ownerTag = ownerTag,
		fleetId = fleetId,
		from = fleet.provinceId,
		to = destProvinceId,
		progress = 0,
		totalSeconds = travel,
		startedAt = ctx.TickScheduler.getSimTime(),
	}
	fleet.status = "moving"
	fleet.destination = destProvinceId
	saveFleet(fleet)
	ctx.EventBus.publish(ctx.Channels.FleetMoveStarted, {
		fleetId = fleetId, ownerTag = ownerTag, from = fleet.provinceId, to = destProvinceId,
		travelSeconds = travel,
	})
	return true
end

function NavalSystem.attackFleet(ownerTag, fleetId, targetFleetId)
	local attacker = ctx.WorldState.getFleet(fleetId)
	local defender = ctx.WorldState.getFleet(targetFleetId)
	if not attacker or not defender then return false, "missing fleet" end
	if attacker.ownerTag ~= ownerTag then return false, "not your fleet" end
	if defender.ownerTag == ownerTag then return false, "cannot attack own fleet" end
	if attacker.provinceId ~= defender.provinceId then return false, "fleets not co-located" end
	local dipl = ctx.DiplomacySystem
	if dipl and dipl.areAtWar and not dipl.areAtWar(attacker.ownerTag, defender.ownerTag) then
		return false, "not_at_war"
	end

	local battleId = generateOrderId()
	battles[battleId] = {
		id = battleId,
		attacker = fleetId,
		defender = targetFleetId,
		startedAt = ctx.TickScheduler.getSimTime(),
		attackerStartHull = math.max(1, fleetHullPool(attacker)),
		defenderStartHull = math.max(1, fleetHullPool(defender)),
		provinceId = attacker.provinceId,
	}
	attacker.status = "battle"
	defender.status = "battle"
	attacker.battleId = battleId
	defender.battleId = battleId
	saveFleet(attacker)
	saveFleet(defender)
	ctx.EventBus.publish(ctx.Channels.NavalBattleStarted, {
		battleId = battleId, attacker = fleetId, defender = targetFleetId, provinceId = attacker.provinceId,
	})
	return true
end

function NavalSystem.disbandFleet(ownerTag, fleetId)
	local fleet = ctx.WorldState.getFleet(fleetId)
	if not fleet then return false, "unknown fleet" end
	if fleet.ownerTag ~= ownerTag then return false, "not your fleet" end
	if fleet.status == "battle" then return false, "cannot disband while in battle" end
	local country = ctx.WorldState.getCountry(ownerTag)
	if country then
		local refundGold = 0
		local refundManpower = 0
		for _, ship in ipairs(fleet.ships or {}) do
			local spec = shipSpec(ship.typeId)
			if spec then
				refundGold += spec.hullCost * 0.4 * (ship.hullFraction or 1)
				refundManpower += spec.sailorCost * 0.5 * (ship.hullFraction or 1)
			end
		end
		country.treasury = (country.treasury or 0) + math.floor(refundGold)
		country.manpower = (country.manpower or 0) + math.floor(refundManpower)
		ctx.WorldState.setCountry(ownerTag, country)
	end
	removeFleet(fleetId)
	return true
end

-- Force-disband every fleet a tag owns (country deletion / annexation sweep). Unlike
-- disbandFleet this skips refunds (the country record is going away) and ignores battle
-- status -- tickBattles self-heals when a battle's fleet record vanishes (missing fleet
-- -> the naval battle is pruned on its next tick).
local function disbandAllFor(ownerTag)
	local bucket = fleetsByTag[ownerTag]
	if not bucket then return 0 end
	local ids = {}
	for fleetId in pairs(bucket) do
		ids[#ids + 1] = fleetId
	end
	local removed = 0
	for _, fleetId in ipairs(ids) do
		if ctx.WorldState.getFleet(fleetId) then
			removeFleet(fleetId)
			removed += 1
		end
	end
	return removed
end

local function tickBuildQueues(dt)
	for provinceId, queue in pairs(buildQueueByProvince) do
		local i = 1
		while i <= #queue do
			local order = queue[i]
			local elapsed = ctx.TickScheduler.getSimTime() - order.startedAt
			if elapsed >= order.buildSeconds then
				local fleet = findDockedFleet(order.ownerTag, provinceId)
				if not fleet then
					fleet = createFleet(order.ownerTag, provinceId, {
						typeId = order.typeId, hullFraction = 1, commissionedAt = ctx.TickScheduler.getSimTime(),
					})
				else
					addShipToFleet(fleet, order.typeId)
				end
				ctx.EventBus.publish(ctx.Channels.ShipRecruited, {
					ownerTag = order.ownerTag, provinceId = provinceId, typeId = order.typeId, fleetId = fleet.id,
				})
				table.remove(queue, i)
			else
				i += 1
			end
		end
		if #queue == 0 then
			buildQueueByProvince[provinceId] = nil
		end
	end
end

local function tickMovement(dt)
	for fleetId, order in pairs(moveOrders) do
		local fleet = ctx.WorldState.getFleet(fleetId)
		if not fleet then
			moveOrders[fleetId] = nil
		else
			order.progress += dt
			if order.progress >= order.totalSeconds then
				fleet.provinceId = order.to
				fleet.status = "docked"
				fleet.destination = nil
				saveFleet(fleet)
				moveOrders[fleetId] = nil
				ctx.EventBus.publish(ctx.Channels.FleetMoveCompleted, {
					fleetId = fleetId, ownerTag = fleet.ownerTag, provinceId = order.to,
				})
			else
				ctx.EventBus.publish(ctx.Channels.FleetMoveProgressed, {
					fleetId = fleetId, progress = order.progress / order.totalSeconds,
				})
			end
		end
	end
end

-- Naval combat now resolves through the shared deterministic CombatEngine (role-matched,
-- discipline, morale/org rout) - the same model as land. Each fleet is one engine formation;
-- ships are grouped into units, casualties come back as a per-fleet ratio applied to hulls.
local function tickBattles(dt)
	local C = ctx.WorldConstants
	for battleId, battle in pairs(battles) do
		local attacker = ctx.WorldState.getFleet(battle.attacker)
		local defender = ctx.WorldState.getFleet(battle.defender)
		if not attacker or not defender then
			battles[battleId] = nil
		else
			local attackerAlive = #(attacker.ships or {}) > 0
			local defenderAlive = #(defender.ships or {}) > 0
			if not attackerAlive and not defenderAlive then
				attacker.status = "destroyed"
				defender.status = "destroyed"
				attacker.battleId = nil
				defender.battleId = nil
				removeFleet(attacker.id)
				removeFleet(defender.id)
				ctx.EventBus.publish(ctx.Channels.NavalBattleResolved, {
					battleId = battleId, winner = "mutual",
					attackerId = attacker.id, defenderId = defender.id, attackerTag = attacker.ownerTag, defenderTag = defender.ownerTag,
					provinceId = battle.provinceId, reason = "mutual_annihilation",
				})
				battles[battleId] = nil
			else
				local result = ctx.CombatEngine.resolveRound({
					constants = C,
					roleSet = "naval",
					width = C.NavalCombatWidth,
					scale = C.NavalDamageScale,
					regimentStrength = 1, -- ships carry an explicit typeStrength
					attacker = fleetSide(attacker),
					defender = fleetSide(defender),
				})

				applyShipCasualties(attacker, result.attacker.casualtyRatio)
				applyShipCasualties(defender, result.defender.casualtyRatio)

				local mMin, mMax = C.NavalMoraleMin, C.NavalMoraleMax
				attacker.morale = math.clamp((attacker.morale or mMax) + result.attacker.moraleDelta, mMin, mMax)
				defender.morale = math.clamp((defender.morale or mMax) + result.defender.moraleDelta, mMin, mMax)

				local aBase = fleetBaseOrg(attacker)
				local dBase = fleetBaseOrg(defender)
				attacker.organization = math.clamp((attacker.organization or aBase) + result.attacker.orgDelta, 0, aBase)
				defender.organization = math.clamp((defender.organization or dBase) + result.defender.orgDelta, 0, dBase)

				saveFleet(attacker)
				saveFleet(defender)

				attackerAlive = #(attacker.ships or {}) > 0
				defenderAlive = #(defender.ships or {}) > 0

				local resolved = result.outcome
				if not attackerAlive and not defenderAlive then
					resolved = "mutual"
				elseif not attackerAlive then
					resolved = "defender"
				elseif not defenderAlive then
					resolved = "attacker"
				end

				if resolved then
					attacker.status = attackerAlive and "docked" or "destroyed"
					defender.status = defenderAlive and "docked" or "destroyed"
					attacker.battleId = nil
					defender.battleId = nil
					attacker.destination = nil
					defender.destination = nil
					saveFleet(attacker)
					saveFleet(defender)
					if not attackerAlive then removeFleet(attacker.id) end
					if not defenderAlive then removeFleet(defender.id) end
					ctx.EventBus.publish(ctx.Channels.NavalBattleResolved, {
						battleId = battleId, winner = resolved,
						attackerId = attacker.id, defenderId = defender.id, attackerTag = attacker.ownerTag, defenderTag = defender.ownerTag,
						provinceId = battle.provinceId, reason = result.reason,
					})
					battles[battleId] = nil
				end
			end
		end
	end
end

local function tickMoraleRegen(dt)
	local C = ctx.WorldConstants
	local moraleRegen = C.NavalMoraleRegenPerTick
	local orgRegen = C.NavalOrgRegenPerTick or 0.5
	for _, bucket in pairs(fleetsByTag) do
		for fleetId in pairs(bucket) do
			local fleet = ctx.WorldState.getFleet(fleetId)
			if fleet and fleet.status == "docked" then
				local changed = false
				local maxMorale = C.NavalMoraleMax
				if (fleet.morale or maxMorale) < maxMorale then
					fleet.morale = math.min(maxMorale, (fleet.morale or maxMorale) + moraleRegen)
					changed = true
				end
				local base = fleetBaseOrg(fleet)
				if (fleet.organization or base) < base then
					fleet.organization = math.min(base, (fleet.organization or base) + orgRegen)
					changed = true
				end
				if changed then saveFleet(fleet) end
			end
		end
	end
end

local function queueLengthAt(_, provinceId)
	local queue = buildQueueByProvince[provinceId]
	if not queue then return 0 end
	return #queue
end

local function missionDef(missionId)
	local bundle = ctx.Bundle
	if not bundle or not bundle.navalMissions then return nil end
	return bundle.navalMissions.get and bundle.navalMissions.get(missionId) or bundle.navalMissions.types and bundle.navalMissions.types[missionId] or nil
end

local function assignMission(fleetId, missionType, targetProvinceId, opts)
	local fleet = ctx.WorldState.getFleet(fleetId)
	if not fleet then return false, "no_fleet" end
	if fleet.battleId then return false, "in_battle" end
	local def = missionDef(missionType)
	if not def then return false, "unknown_mission" end
	if def.requiresAdjacentTarget and targetProvinceId then
		local seaAdj = ctx.SeaAdjacencyGraph
		if seaAdj and seaAdj.areNeighbors and not seaAdj.areNeighbors(fleet.provinceId, targetProvinceId) then
			return false, "target_not_adjacent"
		end
	end
	fleet.mission = {
		type = missionType,
		targetProvinceId = targetProvinceId,
		targetFleetId = opts and opts.targetFleetId or nil,
		pairedFleetId = opts and opts.pairedFleetId or nil,
		startedAt = ctx.TickScheduler.getSimTime(),
		ticksElapsed = 0,
		treasuryGained = 0,
	}
	saveFleet(fleet)
	ctx.EventBus.publish(ctx.Channels.FleetMissionAssigned, {
		fleetId = fleetId,
		ownerTag = fleet.ownerTag,
		missionType = missionType,
		targetProvinceId = targetProvinceId,
	})
	return true
end

local function clearMission(fleetId, reason)
	local fleet = ctx.WorldState.getFleet(fleetId)
	if not fleet or not fleet.mission then return false end
	local prev = fleet.mission
	fleet.mission = nil
	saveFleet(fleet)
	ctx.EventBus.publish(ctx.Channels.FleetMissionCleared, {
		fleetId = fleetId,
		ownerTag = fleet.ownerTag,
		missionType = prev.type,
		reason = reason or "manual",
	})
	return true
end

local function applyTreasuryDelta(tag, delta)
	if not tag or delta == 0 then return end
	local country = ctx.WorldState.getCountry(tag)
	if not country then return end
	country.treasury = (country.treasury or 0) + delta
	ctx.WorldState.setCountry(tag, country)
end

local function targetProvinceController(provinceId)
	if not provinceId then return nil end
	local p = ctx.WorldState.getProvince(provinceId)
	return p and (p.controllerTag or p.ownerTag) or nil
end

local function tickMissions(dt)
	for _, bucket in pairs(fleetsByTag) do
		for fleetId in pairs(bucket) do
			local fleet = ctx.WorldState.getFleet(fleetId)
			if fleet and fleet.mission and not fleet.battleId then
				local def = missionDef(fleet.mission.type)
				if def then
					fleet.mission.ticksElapsed = (fleet.mission.ticksElapsed or 0) + 1
					if def.moraleDrainPerTick and def.moraleDrainPerTick > 0 then
						local maxMorale = ctx.WorldConstants.NavalMoraleMax or 100
						fleet.morale = math.max(0, (fleet.morale or maxMorale) - def.moraleDrainPerTick)
					end
					if def.treasuryEffectPerTick and def.treasuryEffectPerTick ~= 0 then
						local targetTag = targetProvinceController(fleet.mission.targetProvinceId)
						local dipl = ctx.DiplomacySystem
						local hostile = targetTag ~= nil and targetTag ~= fleet.ownerTag and (not dipl or not dipl.areAtWar or dipl.areAtWar(fleet.ownerTag, targetTag))
						if hostile then
							local effect = def.treasuryEffectPerTick
							if effect < 0 then
								-- Floor the victim at zero: N stacked raiders share the finite treasury
								-- instead of driving it arbitrarily negative, and the owner only ever
								-- gains what was actually taken.
								local targetCountry = ctx.WorldState.getCountry(targetTag)
								local available = targetCountry and math.max(0, targetCountry.treasury or 0) or 0
								effect = -math.min(available, -effect)
							end
							if effect ~= 0 then
								applyTreasuryDelta(targetTag, effect)
								if def.treasuryEffectGoesToMission then
									local gain = -effect
									fleet.mission.treasuryGained = (fleet.mission.treasuryGained or 0) + gain
									applyTreasuryDelta(fleet.ownerTag, gain)
								end
							end
						end
					end
					saveFleet(fleet)
				end
			end
		end
	end
end

function NavalSystem.register(context)
	ctx = context

	context.TickScheduler.register({
		id = "NavalBuild",
		priority = 70,
		updateIntervalSeconds = context.WorldConstants.NavalBuildTickInterval,
		update = function(sysCtx) tickBuildQueues(sysCtx.deltaSeconds) end,
	})
	context.TickScheduler.register({
		id = "NavalMovement",
		priority = 72,
		updateIntervalSeconds = context.WorldConstants.NavalMovementTickInterval,
		update = function(sysCtx) tickMovement(sysCtx.deltaSeconds) end,
	})
	context.TickScheduler.register({
		id = "NavalCombat",
		priority = 74,
		updateIntervalSeconds = context.WorldConstants.NavalCombatTickInterval,
		update = function(sysCtx)
			tickBattles(sysCtx.deltaSeconds)
			tickMoraleRegen(sysCtx.deltaSeconds)
		end,
	})
	context.TickScheduler.register({
		id = "NavalMissions",
		priority = 75,
		updateIntervalSeconds = context.WorldConstants.NavalMissionTickInterval or context.WorldConstants.NavalCombatTickInterval or 6,
		update = function(sysCtx) tickMissions(sysCtx.deltaSeconds) end,
	})

	context.NavalSystem = {
		queueRecruit = NavalSystem.queueRecruit,
		moveFleet    = NavalSystem.moveFleet,
		attackFleet  = NavalSystem.attackFleet,
		disbandFleet = NavalSystem.disbandFleet,
		disbandAllFor = disbandAllFor,
		assignMission = assignMission,
		clearMission = clearMission,
		queueLengthAt = queueLengthAt,
		fleetsForTag = function(tag)
			local out = {}
			local bucket = fleetsByTag[tag]
			if not bucket then return out end
			for fleetId in pairs(bucket) do
				local fleet = ctx.WorldState.getFleet(fleetId)
				if fleet then table.insert(out, fleet) end
			end
			return out
		end,
	}
end

return NavalSystem