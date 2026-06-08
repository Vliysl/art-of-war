local CombatSystem = {}

local ctx

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
	for _, b in ctx.WorldState.allBattles() do
		if b.provinceId == provinceId then return b end
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
	if not adjacency.areNeighbors(army.provinceId, targetProvinceId) then
		return false, "not_adjacent"
	end
	-- Dispatch movement
	local ok, reason = ctx.MovementSystem.beginMove(armyId, targetProvinceId)
	if not ok then return false, reason end
	return true
end

local function onArmyArrival(armyId, provinceId)
	local army = ctx.WorldState.getArmy(armyId)
	if not army then return end
	local province = ctx.WorldState.getProvince(provinceId)
	local controllerTag = province and province.controllerTag

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

end

function CombatSystem.register(context)
	ctx = context
	local api = {
		attackProvince = attackProvince,
		onArmyArrival = onArmyArrival,
		getBattleAt = getBattleAt,
	}
	context.CombatSystem = api
	for k, v in pairs(api) do CombatSystem[k] = v end

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
