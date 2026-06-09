local MovementSystem = {}

local ctx

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
	if distance == math.huge or distance <= 0 then return false, "bad_distance" end

	local speed = effectiveSpeed(army)
	if speed <= 0 then return false, "no_speed" end
	local duration = distance / speed

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

	-- If adjacent, just begin a single move (lets CombatSystem.onArmyArrival handle attack on arrival).
	if ctx.AdjacencyGraph.areNeighbors(army.provinceId, finalProvinceId) then
		clearPath(army)
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

	-- If the next step is the final destination and hostile, dispatch through attackProvince.
	if nextStep == finalId then
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

local function tickMovements()
	local now = ctx.TickScheduler.getSimTime()
	for armyId, army in ctx.WorldState.allArmies() do
		if army.movement and not army.battleId then
			if now >= army.movement.completesAt then
				finishMove(army)
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

	-- Self-register MoveArmyPath remote (idempotent — skip if already exists)
	local rs = game:GetService("ReplicatedStorage")
	local aow = rs:FindFirstChild("ArtOfWar")
	local remotes = aow and aow:FindFirstChild("Remotes")
	if remotes and not remotes:FindFirstChild("MoveArmyPath") then
		if context.InputValidator and context.InputValidator.register then
			context.InputValidator.register("MoveArmyPath", {
				schema = {
					{ name = "armyId", type = "string" },
					{ name = "targetProvinceId", type = "integer" },
				},
				rate = { count = 12, window = 10 },
			})
		end
		local r = Instance.new("RemoteEvent")
		r.Name = "MoveArmyPath"
		r.Parent = remotes
		r.OnServerEvent:Connect(function(player, armyId, targetProvinceId)
			if context.InputValidator and context.InputValidator.accept
				and not context.InputValidator.accept(player, "MoveArmyPath", armyId, targetProvinceId) then return end
			if not context.PlayerAuthority or not context.PlayerAuthority.tagFor then return end
			local tag = context.PlayerAuthority.tagFor(player)
			if not tag then return end
			local army = context.WorldState.getArmy(armyId)
			if not army or army.ownerTag ~= tag then return end
			beginMovePath(armyId, targetProvinceId)
		end)
	end
end

return MovementSystem
