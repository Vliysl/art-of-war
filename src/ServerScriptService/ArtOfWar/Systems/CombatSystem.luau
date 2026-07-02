local CombatSystem = {}

local ctx

-- perf: provinceId -> battleId index so getBattleAt is O(1) instead of an
-- O(battles) linear scan on every army arrival. Maintained from the canonical
-- battle lifecycle channels (BattleStarted/BattleResolved published by
-- BattleManager.startBattle/endBattle -- the ONLY battle create/end sites; a
-- battle's provinceId is immutable, so joinBattle/tickBattle updates never move
-- it). The index stores ids and getBattleAt resolves the live record, so a
-- missing/stale entry degrades to nil exactly like the old scan.
local battleIdByProvince = {}

local function tickBattles()
	if not ctx.BattleManager then return end
	-- Snapshot ids to avoid mutation-during-iteration
	local ids = {}
	for id in ctx.WorldState.allBattles() do
		table.insert(ids, id)
	end
	for _, id in ids do
		local record = ctx.WorldState.getBattle(id)
		if record then ctx.BattleManager.tickBattle(record) end
	end
end

local function getBattleAt(provinceId)
	-- perf: O(1) index lookup (see battleIdByProvince). Resolve to the live record
	-- and self-heal a stale entry so behaviour matches the old full scan exactly.
	local id = battleIdByProvince[provinceId]
	if id then
		local b = ctx.WorldState.getBattle(id)
		if b and b.provinceId == provinceId then return b end
		battleIdByProvince[provinceId] = nil
	end
	return nil
end

local function isUnowned(tag)
	return tag == nil or tag == "" or tag == "NONE"
end

local function attackProvince(armyId, targetProvinceId)
	local army = ctx.WorldState.getArmy(armyId)
	if not army then return false, "unknown_army" end
	if army.battleId then return false, "in_battle" end
	local target = ctx.WorldState.getProvince(targetProvinceId)
	if not target then return false, "unknown_target" end
	-- Diplomacy gate: attacker must be at war with the controller (unless unowned)
	local defenderTag = target.controllerTag
	if not isUnowned(defenderTag) and defenderTag ~= army.ownerTag then
		local dipl = ctx.DiplomacySystem
		if dipl and dipl.areAtWar then
			if not dipl.areAtWar(army.ownerTag, defenderTag) then
				return false, "not_at_war"
			end
		end
		-- If DiplomacySystem missing, fall through (graceful degrade with warning)
	end
	-- Adjacency
	local adjacency = ctx.AdjacencyGraph
	if not adjacency or not adjacency.areNeighbors then return false, "no_adjacency" end
	if not adjacency.areNeighbors(army.provinceId, targetProvinceId) then
		return false, "not_adjacent"
	end
	-- Dispatch movement
	if not ctx.MovementSystem or not ctx.MovementSystem.beginMove then return false, "no_movement" end
	local ok, reason = ctx.MovementSystem.beginMove(armyId, targetProvinceId)
	if not ok then return false, reason end
	return true
end

-- Instant capture (EnableInstantCapture): an army standing on an undefended hostile-or-unowned
-- tile flips control immediately at a small casualty + organization cost (forts no longer slow
-- the flip -- they bleed harder instead). "Undefended" = no battle here and no army the captor
-- is at war with; neutral third-party stacks never hold a tile. Publishes the same
-- ProvinceOccupied payload SiegeSystem uses so war-score / capital / stamper / client react
-- unchanged.
local function captureIfUndefended(armyId, provinceId)
	local C = ctx.WorldConstants
	if not C.EnableInstantCapture then return false end
	local army = ctx.WorldState.getArmy(armyId)
	if not army or army.battleId then return false end
	local prov = ctx.WorldState.getProvince(provinceId)
	if not prov then return false end
	local controller = prov.controllerTag
	if controller == army.ownerTag then return false end
	local dipl = ctx.DiplomacySystem
	if not isUnowned(controller) then
		if not (dipl and dipl.areAtWar and dipl.areAtWar(army.ownerTag, controller)) then
			return false
		end
	end
	if getBattleAt(provinceId) then return false end
	if dipl and dipl.areAtWar then
		for _, other in ctx.ArmySystem.armiesInProvince(provinceId) do
			if other.ownerTag ~= army.ownerTag and dipl.areAtWar(army.ownerTag, other.ownerTag) then
				return false
			end
		end
	end

	local oldController = prov.controllerTag
	prov.controllerTag = army.ownerTag
	prov.occupation = nil
	ctx.WorldState.setProvince(provinceId, prov)

	local fortTier = prov.effectiveFortTier or prov.fortTier or 0
	local casualtyFrac = (C.InstantCaptureCasualtyFrac or 0.02)
		+ fortTier * (C.InstantCaptureCasualtyPerFortTier or 0.01)
	if casualtyFrac > 0 then
		ctx.ArmySystem.applyCasualties(armyId, casualtyFrac)
	end
	local orgLoss = C.InstantCaptureOrgLoss or 1.0
	if orgLoss > 0 and ctx.ArmySystem.adjustOrganization then
		ctx.ArmySystem.adjustOrganization(armyId, -orgLoss)
	end

	ctx.EventBus.publish(ctx.Channels.ProvinceOccupied, {
		provinceId = provinceId,
		newController = army.ownerTag,
		oldController = oldController,
		ownerTag = prov.ownerTag,
	})
	return true
end

local function onArmyArrival(armyId, provinceId)
	local army = ctx.WorldState.getArmy(armyId)
	if not army then return end
	local province = ctx.WorldState.getProvince(provinceId)
	local controllerTag = province and province.controllerTag
	if not ctx.BattleManager or not ctx.ArmySystem then return end

	-- Existing battle at province?
	local existing = getBattleAt(provinceId)
	if existing then
		-- Decide role from controller
		local role = "attacker"
		if controllerTag == army.ownerTag then
			role = "defender"
		else
			-- If controller is hostile to arriving, they're attacker
			role = "attacker"
		end
		ctx.BattleManager.joinBattle(existing.id, armyId, role)
		return
	end

	-- No battle: check for enemy in province
	local enemy = ctx.ArmySystem.findEnemyArmyAt(army.ownerTag, provinceId)
	if enemy then
		-- Build defender side from province controller's armies
		local defenders = {}
		for _, other in ctx.ArmySystem.armiesInProvince(provinceId) do
			if other.ownerTag == controllerTag and other.id ~= armyId then
				table.insert(defenders, other.id)
			end
		end
		if #defenders == 0 then
			-- Fallback: just the enemy we found
			defenders = { enemy.id }
		end
		local origins = { [armyId] = army.originProvinceId or army.provinceId }
		local warId = nil
		if ctx.DiplomacySystem and ctx.DiplomacySystem.findActiveWar and not isUnowned(controllerTag) then
			local war = ctx.DiplomacySystem.findActiveWar(army.ownerTag, controllerTag)
			if war then warId = war.id end
		end
		ctx.BattleManager.startBattle(provinceId, { armyId }, defenders, origins, warId)
		return
	end

	captureIfUndefended(armyId, provinceId)
end

function CombatSystem.register(context)
	ctx = context
	local api = {
		attackProvince = attackProvince,
		onArmyArrival = onArmyArrival,
		getBattleAt = getBattleAt,
		captureIfUndefended = captureIfUndefended,
	}
	context.CombatSystem = api
	for k, v in pairs(api) do CombatSystem[k] = v end

	-- perf: maintain the provinceId->battleId index from the canonical battle
	-- lifecycle channels. These fire AFTER WorldState.setBattle (EventBus drains
	-- synchronously), so the index is consistent with the store by the time any
	-- getBattleAt caller (onArmyArrival) runs. BattleStarted/BattleResolved are
	-- the only battle create/end sites; provinceId never changes thereafter.
	context.EventBus.subscribe(context.Channels.BattleStarted, function(payload)
		if payload and payload.provinceId and payload.battleId then
			battleIdByProvince[payload.provinceId] = payload.battleId
		end
	end)
	context.EventBus.subscribe(context.Channels.BattleResolved, function(payload)
		if payload and payload.provinceId then
			-- Only clear if this resolved battle is the one we have indexed, so a
			-- later same-province battle (already reindexed by BattleStarted) is kept.
			if not payload.battleId or battleIdByProvince[payload.provinceId] == payload.battleId then
				battleIdByProvince[payload.provinceId] = nil
			end
		end
	end)

	context.TickScheduler.register({
		id = "CombatSystem",
		priority = 36,
		updateIntervalSeconds = context.WorldConstants.CombatTickInterval or 3,
		update = function()
			tickBattles()
		end,
	})
end

return CombatSystem
