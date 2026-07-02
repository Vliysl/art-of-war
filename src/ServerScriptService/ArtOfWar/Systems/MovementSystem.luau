local MovementSystem = {}

local SeaNodes = require(game:GetService("ReplicatedStorage"):WaitForChild("ArtOfWar"):WaitForChild("Shared"):WaitForChild("SeaNodes"))

local ctx

-- All units take one in-game week (7 ticks) per land step. Sea transport (C9) prices the
-- step by domain: open water sails fast, and the land<->sea transition is deliberately the
-- slow, vulnerable leg -- that step cost IS the whole embark/disembark mechanic (no states).
local MOVE_TICKS = 7
local function moveTicksFor(army, toProvinceId)
	local C = ctx.WorldConstants
	if C.EnableSeaTransport and toProvinceId ~= nil then
		local fromSea = SeaNodes.isSea(army.provinceId)
		local toSea = SeaNodes.isSea(toProvinceId)
		if fromSea and toSea then
			return C.SeaMoveTicksPerStep or 4
		elseif fromSea ~= toSea then
			return C.EmbarkMoveTicks or 10
		end
	end
	return MOVE_TICKS
end

local function combatCap()
	return ctx.WorldConstants.MultiplierCapCombatStat or 2
end

local function doctrineMod(country, domain)
	if not country or not country.doctrine then return 0 end
	local bundle = ctx.Bundle
	local doctrine = bundle and bundle.doctrines and bundle.doctrines[country.doctrine]
	if not doctrine or not doctrine.modifiers then return 0 end
	return doctrine.modifiers[domain] or 0
end

local function effectiveSpeed(army)
	local base = ctx.ArmySystem.compositionSpeed(army.composition) * (ctx.WorldConstants.ArmyMovementSpeed or 80)
	local country = ctx.WorldState.getCountry(army.ownerTag)
	local doctrineSpeed = doctrineMod(country, "army_movement_speed")
	local leaderSpeed = country and ctx.ModifierStack and ctx.ModifierStack.resolveAdditive(army.ownerTag, "army_movement_speed") or 0
	local mult = math.clamp(1 + doctrineSpeed + leaderSpeed, 1 / combatCap(), combatCap())
	return base * mult
end

local function clearPath(army)
	if not army then return end
	army.movementPath = nil
end

local function cancelMovement(armyId, reason)
	local army = ctx.WorldState.getArmy(armyId)
	if not army or not army.movement then return false end
	local from = army.movement.fromProvinceId
	army.movement = nil
	clearPath(army)
	ctx.WorldState.setArmy(armyId, army)
	if ctx.ArmySystem and ctx.ArmySystem.setState then
		ctx.ArmySystem.setState(armyId, "idle")
	end
	ctx.EventBus.publish(ctx.Channels.ArmyMoveCancelled, {
		armyId = armyId, tag = army.ownerTag, reason = reason or "cancelled", provinceId = from,
	})
	return true
end

local function beginMove(armyId, toProvinceId, options)
	local army = ctx.WorldState.getArmy(armyId)
	if not army then return false, "unknown_army" end
	if army.battleId then return false, "in_battle" end
	if army.provinceId == toProvinceId then return false, "same_province" end

	local adjacency = ctx.AdjacencyGraph
	if not adjacency.isRegistered(army.provinceId) or not adjacency.isRegistered(toProvinceId) then
		return false, "province_unregistered"
	end
	local bypassAdjacency = options and options.bypassAdjacency
	if not bypassAdjacency and not adjacency.areNeighbors(army.provinceId, toProvinceId) then
		return false, "not_adjacent"
	end

	-- War gate: cannot move into hostile owned territory without a declared war.
	-- Backstops every entry path (legacy MoveArmy, beginMovePath adjacent shortcut, continuePath).
	-- attackProvince re-checks this above us; the redundancy is intentional.
	local destProv = ctx.WorldState.getProvince(toProvinceId)
	local destController = destProv and destProv.controllerTag
	if destController and destController ~= "" and destController ~= "NONE" and destController ~= army.ownerTag then
		if ctx.DiplomacySystem and ctx.DiplomacySystem.areAtWar then
			if not ctx.DiplomacySystem.areAtWar(army.ownerTag, destController) then
				return false, "not_at_war"
			end
		end
	end

	local distance = adjacency.distance(army.provinceId, toProvinceId)
	if distance == math.huge then return false, "bad_distance" end

	-- Fixed cadence: one province step = 7 ticks (one week), independent of stud
	-- distance; sea/embark steps price differently (see moveTicksFor). The client draws
	-- a filling arrow over this window. (effectiveSpeed is retained/exported for future
	-- per-unit speeds.)
	local duration = moveTicksFor(army, toProvinceId) * (ctx.WorldConstants.SecondsPerSimTick or 1.5)

	local now = ctx.TickScheduler.getSimTime()
	army.movement = {
		fromProvinceId = army.provinceId,
		toProvinceId = toProvinceId,
		startedAt = now,
		completesAt = now + duration,
		pathDistance = distance,
	}
	army.originProvinceId = army.provinceId
	ctx.WorldState.setArmy(armyId, army)
	if ctx.ArmySystem and ctx.ArmySystem.setEntrenchment then
		ctx.ArmySystem.setEntrenchment(armyId, 0)
	end
	if ctx.ArmySystem and ctx.ArmySystem.setState then
		ctx.ArmySystem.setState(armyId, "moving")
	end
	ctx.EventBus.publish(ctx.Channels.ArmyMoveStarted, {
		armyId = armyId, tag = army.ownerTag,
		fromProvinceId = army.movement.fromProvinceId,
		toProvinceId = toProvinceId,
		duration = duration,
	})
	return true
end

-- A province is passable for path-search if:
--  * it's owned by the player (controllerTag == player tag)
--  * OR the player is at war with the controller
--  * OR the province is unowned (NONE)
-- Future: military-access treaties extend this allowlist.
local function provinceTraversable(provinceId, ownerTag)
	-- Open water is unowned and always traversable when sea transport is on (C9); a sea
	-- node has no province record, so it must short-circuit before the lookup below.
	if SeaNodes.isSea(provinceId) then
		return ctx.WorldConstants.EnableSeaTransport == true
	end
	local p = ctx.WorldState.getProvince(provinceId)
	if not p then return false end
	local controller = p.controllerTag
	if controller == ownerTag then return true end
	if not controller or controller == "NONE" or controller == "" then return true end
	-- enemy controller: check war
	if ctx.DiplomacySystem and ctx.DiplomacySystem.areAtWar then
		if ctx.DiplomacySystem.areAtWar(ownerTag, controller) then return true end
	end
	return false
end

-- High-level: queue a move that may cross multiple tiles.
-- If target is not adjacent, computes a path and stores remaining steps on army.movementPath.
local function beginMovePath(armyId, finalProvinceId)
	local army = ctx.WorldState.getArmy(armyId)
	if not army then return false, "unknown_army" end
	if army.battleId then return false, "in_battle" end
	if army.provinceId == finalProvinceId then return false, "same_province" end
	if not ctx.AdjacencyGraph.isRegistered(army.provinceId) or not ctx.AdjacencyGraph.isRegistered(finalProvinceId) then
		return false, "province_unregistered"
	end

	-- If adjacent, just begin a single move (lets CombatSystem.onArmyArrival handle attack on
	-- arrival). Under adjacent engagement, a DEFENDED hostile/unowned neighbor is instead
	-- dispatched through attackProvince -> engageFromAdjacent: the battle starts immediately
	-- and the army never leaves its tile. This is the PRIMARY player attack path (MoveArmyPath)
	-- and also covers AutoCapture/AISystem, which enter through here.
	if ctx.AdjacencyGraph.areNeighbors(army.provinceId, finalProvinceId) then
		clearPath(army)
		if ctx.WorldConstants.EnableAdjacentEngagement and ctx.CombatSystem and ctx.CombatSystem.isDefendedAgainst then
			local destProv = ctx.WorldState.getProvince(finalProvinceId)
			local wouldAttack = not destProv or destProv.controllerTag ~= army.ownerTag
			if wouldAttack and ctx.CombatSystem.isDefendedAgainst(army.ownerTag, finalProvinceId) then
				return ctx.CombatSystem.attackProvince(armyId, finalProvinceId)
			end
		end
		return beginMove(armyId, finalProvinceId)
	end

	-- Compute path through traversable tiles. The FINAL tile is allowed even if hostile (so we can land on it).
	local ownerTag = army.ownerTag
	local function passable(provId)
		if provId == finalProvinceId then return true end  -- always allow stepping onto destination
		return provinceTraversable(provId, ownerTag)
	end
	local path = ctx.AdjacencyGraph.findPath(army.provinceId, finalProvinceId, passable)
	if not path or #path < 2 then
		return false, "no_path"
	end
	-- path[1] is current province; path[2..N] are the steps to take.
	-- Begin the first step; store the rest as movementPath.
	local firstStep = path[2]
	local rest = {}
	for i = 3, #path do table.insert(rest, path[i]) end

	-- For the first step, if it's the final destination AND hostile, dispatch through CombatSystem
	-- so the diplomacy gate runs. Otherwise just beginMove.
	if firstStep == finalProvinceId then
		local destProv = ctx.WorldState.getProvince(firstStep)
		if destProv and destProv.controllerTag and destProv.controllerTag ~= ownerTag and destProv.controllerTag ~= "NONE" and destProv.controllerTag ~= "" then
			if ctx.CombatSystem and ctx.CombatSystem.attackProvince then
				clearPath(army)
				return ctx.CombatSystem.attackProvince(armyId, firstStep)
			end
		end
	end

	local ok, reason = beginMove(armyId, firstStep)
	if not ok then return false, reason end

	-- Now refresh the army record after beginMove may have set fields, then attach the remaining path.
	army = ctx.WorldState.getArmy(armyId)
	if army then
		army.movementPath = { steps = rest, finalProvinceId = finalProvinceId }
		ctx.WorldState.setArmy(armyId, army)
	end
	return true
end

-- Read-only preview: the EXACT route an army owned by `ownerTag` would take from `fromProvinceId`
-- to `toProvinceId` right now -- same AdjacencyGraph + traversability gate that beginMovePath uses,
-- so the client preview is guaranteed identical to the actual move. Returns
--   { ok = bool, blocked = bool, hostile = bool, nodes = { provinceId... } }
-- where nodes includes the start province. blocked => no friendly path (client draws a stub).
local function computePreviewPath(fromProvinceId, toProvinceId, ownerTag)
	fromProvinceId = tonumber(fromProvinceId)
	toProvinceId = tonumber(toProvinceId)
	if not fromProvinceId or not toProvinceId then return { ok = false } end
	if fromProvinceId == toProvinceId then return { ok = true, nodes = {} } end

	local destProv = ctx.WorldState.getProvince(toProvinceId)
	local hostile = destProv ~= nil and destProv.controllerTag ~= nil
		and destProv.controllerTag ~= ownerTag and destProv.controllerTag ~= "NONE"
		and destProv.controllerTag ~= ""

	if not ctx.AdjacencyGraph.isRegistered(fromProvinceId) or not ctx.AdjacencyGraph.isRegistered(toProvinceId) then
		return { ok = true, blocked = true, hostile = hostile, nodes = { fromProvinceId, toProvinceId } }
	end
	-- Mirror beginMovePath: the final tile is always steppable (so you can land on a hostile target).
	local function passable(provId)
		if provId == toProvinceId then return true end
		return provinceTraversable(provId, ownerTag)
	end
	local path = ctx.AdjacencyGraph.findPath(fromProvinceId, toProvinceId, passable)
	if not path or #path < 2 then
		return { ok = true, blocked = true, hostile = hostile, nodes = { fromProvinceId, toProvinceId } }
	end
	return { ok = true, blocked = false, hostile = hostile, nodes = path }
end

local function continuePath(army)
	local mp = army.movementPath
	if not mp then return end
	local steps = mp.steps
	local finalId = mp.finalProvinceId
	if not steps or #steps == 0 then
		army.movementPath = nil
		ctx.WorldState.setArmy(army.id, army)
		return
	end
	local nextStep = table.remove(steps, 1)
	if #steps == 0 then
		army.movementPath = nil
	else
		army.movementPath = { steps = steps, finalProvinceId = finalId }
	end
	ctx.WorldState.setArmy(army.id, army)

	-- Adjacent engagement: ANY defended hostile/unowned next step engages from the current
	-- tile, not just the final one (the legacy rule let armies walk INTO defended tiles
	-- mid-path). nextStep was already popped, so on success the remaining steps are exactly
	-- the post-victory continuation (resumed by endBattle's winner pass).
	if ctx.WorldConstants.EnableAdjacentEngagement and ctx.CombatSystem
		and ctx.CombatSystem.attackProvince and ctx.CombatSystem.isDefendedAgainst then
		local destProv = ctx.WorldState.getProvince(nextStep)
		local wouldAttack = not destProv or destProv.controllerTag ~= army.ownerTag
		if wouldAttack and ctx.CombatSystem.isDefendedAgainst(army.ownerTag, nextStep) then
			local attacked = ctx.CombatSystem.attackProvince(army.id, nextStep)
			if not attacked then
				army.movementPath = nil
				ctx.WorldState.setArmy(army.id, army)
			end
			return
		end
	elseif nextStep == finalId then
		-- Legacy rule: only a hostile FINAL step routes through attackProvince.
		local destProv = ctx.WorldState.getProvince(nextStep)
		local hostile = destProv and destProv.controllerTag
			and destProv.controllerTag ~= army.ownerTag
			and destProv.controllerTag ~= "NONE" and destProv.controllerTag ~= ""
		if hostile and ctx.CombatSystem and ctx.CombatSystem.attackProvince then
			local attacked = ctx.CombatSystem.attackProvince(army.id, nextStep)
			if not attacked then
				army.movementPath = nil
				ctx.WorldState.setArmy(army.id, army)
			end
			return
		end
	end
	local ok = beginMove(army.id, nextStep)
	if not ok then
		army.movementPath = nil
		ctx.WorldState.setArmy(army.id, army)
		beginMovePath(army.id, finalId)
	end
end

local function finishMove(army)
	local targetId = army.movement and army.movement.toProvinceId

	-- Arrival gate (EnableAdjacentEngagement): a defender appeared on the target while we
	-- marched. The army's provinceId never changed mid-move, so stop HERE and engage from
	-- adjacency instead of walking onto a defended tile. Friendly-controlled targets always
	-- complete the walk (that is how defenders reinforce their own contested tile).
	-- Invariant: no attacker ever stands on a defended tile.
	if targetId and ctx.WorldConstants.EnableAdjacentEngagement
		and ctx.CombatSystem and ctx.CombatSystem.isDefendedAgainst and ctx.CombatSystem.engageFromAdjacent then
		local destProv = ctx.WorldState.getProvince(targetId)
		local wouldAttack = not destProv or destProv.controllerTag ~= army.ownerTag
		if wouldAttack and ctx.CombatSystem.isDefendedAgainst(army.ownerTag, targetId) then
			-- Clear movement manually (NOT cancelMovement -- that would drop movementPath,
			-- which is the post-victory continuation).
			army.movement = nil
			ctx.WorldState.setArmy(army.id, army)
			ctx.EventBus.publish(ctx.Channels.ArmyMoveCancelled, {
				armyId = army.id, tag = army.ownerTag, reason = "engaged", provinceId = army.provinceId,
			})
			local ok = ctx.CombatSystem.engageFromAdjacent(army.id, targetId)
			if not ok then
				local refreshed = ctx.WorldState.getArmy(army.id)
				if refreshed then
					refreshed.movementPath = nil
					ctx.WorldState.setArmy(army.id, refreshed)
				end
				if ctx.ArmySystem and ctx.ArmySystem.setState then
					ctx.ArmySystem.setState(army.id, "idle")
				end
			end
			return
		end
	end

	army.movement = nil
	ctx.WorldState.setArmy(army.id, army)
	if targetId then
		ctx.ArmySystem.relocateArmy(army.id, targetId)
	end
	if ctx.ArmySystem and ctx.ArmySystem.setState then
		ctx.ArmySystem.setState(army.id, "idle")
	end
	ctx.EventBus.publish(ctx.Channels.ArmyMoveCompleted, {
		armyId = army.id, tag = army.ownerTag, provinceId = targetId,
	})
	-- Continue path if any (and not in battle / not retreating)
	local refreshed = ctx.WorldState.getArmy(army.id)
	if refreshed and refreshed.movementPath and not refreshed.battleId and not refreshed.retreating then
		continuePath(refreshed)
	end
end

-- Flag-OFF insurance (C9): with EnableSeaTransport off the sea edges vanish from the graph,
-- so any army still standing on a sea node could never move again. One-time sweep relocates
-- each to a shore province of its tile (own-controlled preferred) via the baked shore data.
local strandSweepDone = false
local function sweepStrandedSeaArmies()
	if ctx.WorldConstants.EnableSeaTransport then
		strandSweepDone = false
		return
	end
	if strandSweepDone then return end
	strandSweepDone = true
	for _, army in ctx.WorldState.allArmies() do
		if SeaNodes.isSea(army.provinceId) then
			local shore = SeaNodes.shoreOf(army.provinceId)
			local target = nil
			for _, pid in ipairs(shore) do
				local p = ctx.WorldState.getProvince(pid)
				if p and p.controllerTag == army.ownerTag then
					target = pid
					break
				end
			end
			target = target or shore[1]
			if target then
				cancelMovement(army.id, "sea_transport_disabled")
				ctx.ArmySystem.relocateArmy(army.id, target)
			else
				warn(string.format("[MovementSystem] army %s stranded at sea node %s with no baked shore -- leaving in place",
					tostring(army.id), tostring(army.provinceId)))
			end
		end
	end
end

local function tickMovements()
	sweepStrandedSeaArmies()
	local now = ctx.TickScheduler.getSimTime()
	-- perf: iterate only armies known to have a pending .movement (ArmySystem.movingArmies index)
	-- instead of scanning every army. The index may over-include, so the per-army conditions below
	-- are unchanged and re-applied verbatim -- behavior is identical, the loop is just narrower.
	if ctx.WorldConstants.UseArmyMembershipIndex and ctx.ArmySystem and ctx.ArmySystem.movingArmies then
		for _, army in ctx.ArmySystem.movingArmies() do
			if army.movement and not army.battleId then
				if now >= army.movement.completesAt then
					finishMove(army)
				end
			end
		end
	else
		for _, army in ctx.WorldState.allArmies() do
			if army.movement and not army.battleId then
				if now >= army.movement.completesAt then
					finishMove(army)
				end
			end
		end
	end
end

local function handleOwnershipLoss(tag)
	for _, army in ctx.ArmySystem.armiesOfOwner(tag) do
		if army.movement then cancelMovement(army.id, "owner_lost_province") end
	end
end

function MovementSystem.register(context)
	ctx = context
	local api = {
		beginMove = beginMove,
		beginMovePath = beginMovePath,
		cancelMovement = cancelMovement,
		effectiveSpeed = effectiveSpeed,
		continuePath = continuePath,
		computePreviewPath = computePreviewPath,
	}
	context.MovementSystem = api
	for k, v in pairs(api) do MovementSystem[k] = v end

	context.TickScheduler.register({
		id = "MovementSystem",
		priority = 34,
		updateIntervalSeconds = context.WorldConstants.MovementTickInterval or 1.5,
		update = tickMovements,
	})

	context.EventBus.subscribe(context.Channels.ArmyMoveCompleted, function(payload)
		if not payload or not payload.armyId or not payload.provinceId then return end
		if context.CombatSystem and context.CombatSystem.onArmyArrival then
			context.CombatSystem.onArmyArrival(payload.armyId, payload.provinceId)
		end
	end)

	context.EventBus.subscribe(context.Channels.ProvinceOwnershipChanged, function(payload)
		if payload and payload.oldOwner then
			handleOwnershipLoss(payload.oldOwner)
		end
	end)
end

return MovementSystem
