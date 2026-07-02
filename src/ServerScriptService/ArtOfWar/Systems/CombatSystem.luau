local CombatSystem = {}

local SeaNodes = require(game:GetService("ReplicatedStorage"):WaitForChild("ArtOfWar"):WaitForChild("Shared"):WaitForChild("SeaNodes"))

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

-- First army at the province the given owner is AT WAR with, or nil. This -- not bare
-- foreign ownership -- is what "defended" means everywhere in the adjacent-engagement
-- machinery: neutral third-party stacks never hold a tile, never get drafted, and never
-- block movement.
local function hostileArmyAt(ownerTag, provinceId)
	local dipl = ctx.DiplomacySystem
	if not (dipl and dipl.areAtWar) then return nil end
	for _, other in ctx.ArmySystem.armiesInProvince(provinceId) do
		if other.ownerTag ~= ownerTag and dipl.areAtWar(ownerTag, other.ownerTag) then
			return other
		end
	end
	return nil
end

local function isDefendedAgainst(ownerTag, provinceId)
	if getBattleAt(provinceId) then return true end
	return hostileArmyAt(ownerTag, provinceId) ~= nil
end

-- Defender draft for a NEW battle at a tile: the controller's armies AND every at-war
-- third party standing there (unioned -- a fallback-only draft left undrafted at-war
-- stragglers co-located with the winners after the battle).
local function buildDefendersAt(provinceId, attackerTag)
	local province = ctx.WorldState.getProvince(provinceId)
	local controllerTag = province and province.controllerTag
	local dipl = ctx.DiplomacySystem
	local defenders = {}
	for _, other in ctx.ArmySystem.armiesInProvince(provinceId) do
		if other.ownerTag ~= attackerTag then
			local isController = not isUnowned(controllerTag) and other.ownerTag == controllerTag
			local atWar = dipl and dipl.areAtWar and dipl.areAtWar(attackerTag, other.ownerTag)
			if isController or atWar then
				table.insert(defenders, other.id)
			end
		end
	end
	return defenders
end

-- HOI4-style engagement (EnableAdjacentEngagement): the attacker fights the battle at the
-- TARGET tile while physically remaining on its own tile; it marches in only on victory
-- (BattleManager winner processing). Single engagement entry point for every attack path.
local function engageFromAdjacent(armyId, targetProvinceId)
	local army = ctx.WorldState.getArmy(armyId)
	if not army then return false, "unknown_army" end
	if army.battleId then return false, "in_battle" end
	-- Sea nodes have no province record but ARE legal engagement targets (interception at
	-- sea); without this the unknown_target guard would make sea battles unreachable.
	local target = ctx.WorldState.getProvince(targetProvinceId)
	if not target and not SeaNodes.isSea(targetProvinceId) then return false, "unknown_target" end
	local defenderTag = target and target.controllerTag
	if not isUnowned(defenderTag) and defenderTag ~= army.ownerTag then
		local dipl = ctx.DiplomacySystem
		if dipl and dipl.areAtWar and not dipl.areAtWar(army.ownerTag, defenderTag) then
			return false, "not_at_war"
		end
	end
	local adjacency = ctx.AdjacencyGraph
	if not adjacency or not adjacency.areNeighbors then return false, "no_adjacency" end
	if not adjacency.areNeighbors(army.provinceId, targetProvinceId) then
		return false, "not_adjacent"
	end
	-- Domain rule (C9): sea<->sea battles and sea->land naval invasions are legal; a LAND
	-- army can never engage a sea node from the shore (build a transport route instead).
	if SeaNodes.isSea(targetProvinceId) and not SeaNodes.isSea(army.provinceId) then
		return false, "cannot_engage_sea_from_land"
	end

	-- Ongoing battle at the target: join it from here as a flanking origin. reinforce()
	-- already resolves the side (incl. third-party co-belligerents) and records the origin.
	local existing = getBattleAt(targetProvinceId)
	if existing then
		if army.movement and ctx.MovementSystem and ctx.MovementSystem.cancelMovement then
			ctx.MovementSystem.cancelMovement(armyId, "engaged")
		end
		return ctx.BattleManager.reinforce(armyId, targetProvinceId)
	end

	local defenders = buildDefendersAt(targetProvinceId, army.ownerTag)
	if #defenders == 0 then return false, "no_defenders" end

	-- Home defense preempts offense: a draftee currently attacking ELSEWHERE (its battleId
	-- points at another tile -- it fights from its own tile now) abandons that offensive
	-- before defending home. Its old battle ends "attackers_withdrew" if it was the last
	-- attacker (no war-score: BattleResolved carries a nil loser).
	local drafted = {}
	for _, defenderId in ipairs(defenders) do
		local d = ctx.WorldState.getArmy(defenderId)
		if d then
			if d.battleId and ctx.BattleManager.withdrawFromBattle then
				ctx.BattleManager.withdrawFromBattle(defenderId, "attackers_withdrew")
				d = ctx.WorldState.getArmy(defenderId)
			end
			if d and not d.battleId then
				table.insert(drafted, defenderId)
			end
		end
	end
	if #drafted == 0 then return false, "no_defenders" end

	if army.movement and ctx.MovementSystem and ctx.MovementSystem.cancelMovement then
		ctx.MovementSystem.cancelMovement(armyId, "engaged")
		army = ctx.WorldState.getArmy(armyId)
		if not army then return false, "unknown_army" end
	end
	army.originProvinceId = army.provinceId
	ctx.WorldState.setArmy(armyId, army)

	local warId = nil
	if ctx.DiplomacySystem and ctx.DiplomacySystem.findActiveWar and not isUnowned(defenderTag) then
		local war = ctx.DiplomacySystem.findActiveWar(army.ownerTag, defenderTag)
		if war then warId = war.id end
	end
	ctx.BattleManager.startBattle(targetProvinceId, { armyId }, drafted, { [armyId] = army.provinceId }, warId)
	return true
end

local function attackProvince(armyId, targetProvinceId)
	local army = ctx.WorldState.getArmy(armyId)
	if not army then return false, "unknown_army" end
	if army.battleId then return false, "in_battle" end
	local target = ctx.WorldState.getProvince(targetProvinceId)
	if not target and not SeaNodes.isSea(targetProvinceId) then return false, "unknown_target" end
	-- Diplomacy gate: attacker must be at war with the controller (unless unowned;
	-- sea nodes have no controller -- hostility is settled per army by the defender draft)
	local defenderTag = target and target.controllerTag
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
	-- Engage from our own tile (flag ON); an undefended target falls through to the
	-- legacy march (walk-in -> instant capture on arrival).
	if ctx.WorldConstants.EnableAdjacentEngagement then
		local ok, reason = engageFromAdjacent(armyId, targetProvinceId)
		if ok then return true end
		if reason ~= "no_defenders" then return false, reason end
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
		-- Side by OWNERSHIP first: join whichever side already fields our countrymen.
		-- Deciding purely from controllerTag mis-sided a winner marching onto a tile it
		-- just captured while a follow-up battle raged there (controller == us would have
		-- drafted us as a DEFENDER against our own side).
		local role = nil
		local function sideHas(ids)
			for _, id in ipairs(ids or {}) do
				local m = ctx.WorldState.getArmy(id)
				if m and m.ownerTag == army.ownerTag then return true end
			end
			return false
		end
		if sideHas(existing.defenderArmyIds) then
			role = "defender"
		elseif sideHas(existing.attackerArmyIds) then
			role = "attacker"
		else
			role = (controllerTag == army.ownerTag) and "defender" or "attacker"
		end
		ctx.BattleManager.joinBattle(existing.id, armyId, role)
		return
	end

	-- No battle: check for enemy in province. Under adjacent engagement "enemy" is strictly
	-- an AT-WAR army -- neutral co-location (a third party's transport on the same sea node,
	-- a neutral stack crossing an unowned tile) must not start a battle.
	local enemy
	if ctx.WorldConstants.EnableAdjacentEngagement then
		enemy = hostileArmyAt(army.ownerTag, provinceId)
	else
		enemy = ctx.ArmySystem.findEnemyArmyAt(army.ownerTag, provinceId)
	end
	if enemy then
		-- Under adjacent engagement the finishMove gate keeps attackers off defended tiles,
		-- so a walk-on battle start should be unreachable; log if it ever fires (co-located
		-- armies whose owners declared war mid-tick is the only known path).
		if ctx.WorldConstants.EnableAdjacentEngagement then
			warn(string.format("[CombatSystem] walk-on battle fallback at province %s (army %s)",
				tostring(provinceId), tostring(armyId)))
		end
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
		engageFromAdjacent = engageFromAdjacent,
		isDefendedAgainst = isDefendedAgainst,
		hostileArmyAt = hostileArmyAt,
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
