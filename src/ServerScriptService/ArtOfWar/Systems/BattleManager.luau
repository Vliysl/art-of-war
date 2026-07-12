 local BattleManager = {}

local ctx
local nextBattleSeq = 0
-- perf: server-only per-battle round log (see tickBattle). Never replicated; cleared in endBattle.
local battleLogs = {}

local CombatPhases = require(game:GetService("ServerScriptService").ArtOfWar.ServerData.CombatPhases)

-- ===== Helpers (stable) =====================================================

local function unitsNavalLike(armyIds)
	for _, armyId in armyIds do
		local army = ctx.WorldState.getArmy(armyId)
		if army and army.domain == "naval" then return true end
	end
	return false
end

local function officerModifierFor(army, field)
	if not army or not army.officer or not army.officer.traits then return 0 end
	local mod = ctx.Bundle and ctx.Bundle.officerTraits or nil
	if not mod or not mod.modifierSum then return 0 end
	return mod.modifierSum(army.officer.traits, field) or 0
end

-- Combat depth C: the group general's contribution, folded ON TOP of the army's own officer as a
-- separate clamped factor so N grouped armies never compound the general's effect. LeaderTraits use
-- army_attack / army_defense / army_morale fields. Gated + returns the neutral value when off.
local function commanderTraitSum(general, field)
	if not general or not general.traits then return 0 end
	local defs = ctx.Bundle and ctx.Bundle.leaderTraits or nil
	if not defs then return 0 end
	local total = 0
	for _, id in ipairs(general.traits) do
		local t = defs[id]
		if t and t.modifiers and t.modifiers[field] then total += t.modifiers[field] end
	end
	return total
end

local function commanderCombatMultiplier(army, sideRole)
	if not ctx.WorldConstants.EnableGenerals or not ctx.GeneralSystem then return 1 end
	local general = ctx.GeneralSystem.getCommanderFor(army)
	if not general then return 1 end
	local field = (sideRole == "attack") and "army_attack" or "army_defense"
	local cap = ctx.WorldConstants.GeneralCombatBonusCap or 1.30
	-- Floor at 1: a general is pure upside -- a defensive general's negative attack trait never
	-- makes a member army WORSE than ungrouped (it just doesn't help attack). Ceiling caps runaway.
	local traitMult = math.clamp(1 + commanderTraitSum(general, field), 1, cap)
	local skillBonus = (math.clamp(general.skill or 2, 0, 5) - 2) * 0.1
	return traitMult * (1 + skillBonus)
end

local function commanderMoraleResist(army)
	if not ctx.WorldConstants.EnableGenerals or not ctx.GeneralSystem then return 0 end
	local general = ctx.GeneralSystem.getCommanderFor(army)
	if not general then return 0 end
	local cap = ctx.WorldConstants.GeneralMoraleResistCap or 0.25
	return math.clamp(commanderTraitSum(general, "army_morale"), 0, cap)
end

-- Doctrine-as-tactic classification (in-system; promote to data later)
local OFFENSIVE_DOCTRINES = {
	heavy_cavalry = true,
	dispersed_infantry_formation = true,
	concentrated_artillery = true,
	light_cavalry = true,
	dispersed_artillery = true,
}
local DEFENSIVE_DOCTRINES = {
	line_infantry_formation = true,
	asymmetrical_infantry_formation = true,
	professional_army = true,
}

local function generateBattleId(provinceId)
	nextBattleSeq += 1
	return string.format("battle_%s_%d", tostring(provinceId), nextBattleSeq)
end

local function combatCap()
	return ctx.WorldConstants.MultiplierCapCombatStat or 2
end

local function unitOf(unitTypeId)
	local b = ctx.Bundle
	return b and b.unitTypes and b.unitTypes[unitTypeId] or nil
end

local function terrainOf(provinceId)
	local prov = ctx.WorldState.getProvince(provinceId)
	if not prov then return nil end
	local b = ctx.Bundle
	return b and b.terrains and b.terrains[prov.terrain] or nil
end

local function trainingMultiplier(country)
	if not country then return 1 end
	local step = ctx.WorldConstants.TrainingTierStep or 1.1
	local maxTier = ctx.WorldConstants.ArmyTrainingTierMax or 5
	local tier = math.clamp(country.armyTrainingTier or 0, 0, maxTier)
	return step ^ tier
end

local function hasTerrainSpecialization(country, terrain)
	if not country or not country.terrainSpecializations or not terrain then return false end
	for _, spec in country.terrainSpecializations do
		if spec == terrain.id then return true end
	end
	return false
end

local function tacticBonusForCountry(country, kind)
	if not country or not country.doctrines then return 0 end
	for _, doctrineId in country.doctrines do
		if kind == "offensive" and OFFENSIVE_DOCTRINES[doctrineId] then
			return ctx.WorldConstants.CombatTacticOffensiveBonus or 0.05
		end
		if kind == "defensive" and DEFENSIVE_DOCTRINES[doctrineId] then
			return ctx.WorldConstants.CombatTacticDefensiveBonus or 0.05
		end
	end
	return 0
end

-- ===== Single stat multiplier (replaces statMult/statMultAtk/statMultDef) ====
-- Folds the static/external multipliers the CombatEngine does NOT compute itself.
-- EXCLUDES terrain atk/def, per-unit morale, discipline, organization and fort
-- (the engine applies those). sideRole = "attack" | "defense".
local function statMultiplier(army, terrain, sideRole)
	local country = ctx.WorldState.getCountry(army.ownerTag)
	local cap = combatCap()
	local domain = (sideRole == "attack") and "army_attack" or "army_defense"
	local additive = 0
	if ctx.ModifierStack and ctx.ModifierStack.resolveAdditive then
		additive = ctx.ModifierStack.resolveAdditive(army.ownerTag, domain) or 0
	end
	local mod = math.clamp(1 + additive, 1 / cap, cap)
	local training = trainingMultiplier(country)
	local spec = (terrain and hasTerrainSpecialization(country, terrain))
		and (ctx.WorldConstants.TerrainSpecializationFlat or 1.2)
		or 1
	local skillField = (sideRole == "attack") and "skillAttack" or "skillDefense"
	local skill = (army.officer and army.officer[skillField]) or 2
	local skillBonus = (math.clamp(skill, 0, 5) - 2) * 0.1   -- spec G.1.6: +/-0.1 per skill point vs default 2
	local officer = (1 + officerModifierFor(army, (sideRole == "attack") and "attack" or "defense")) * (1 + skillBonus)
	local commander = commanderCombatMultiplier(army, sideRole)
	local tactic, entrench = 1, 1
	if sideRole == "attack" then
		tactic = 1 + tacticBonusForCountry(country, "offensive")
	else
		tactic = 1 + tacticBonusForCountry(country, "defensive")
		entrench = 1 + (army.entrenchment or 0) * (ctx.WorldConstants.CombatEntrenchmentDefensePerLevel or 0.02)
	end
	return mod * training * spec * officer * commander * tactic * entrench
end

local function effectiveWidthFor(record)
	local terrain = terrainOf(record.provinceId)
	local base = (terrain and terrain.combatWidth) or (ctx.WorldConstants.CombatTerrainDefaultWidth or 60)
	base = math.max(ctx.WorldConstants.CombatTerrainMinWidth or 30, base)
	-- Count distinct living attacker origins
	local origins = {}
	for _, armyId in record.attackerArmyIds do
		local army = ctx.WorldState.getArmy(armyId)
		if army and not army.retreating and ctx.ArmySystem.compositionStrength(army.composition) > 0 then
			local origin = record.attackerOriginByArmyId and record.attackerOriginByArmyId[armyId]
			if origin then
				origins[origin] = true
			end
		end
	end
	local distinct = 0
	for _ in pairs(origins) do distinct += 1 end
	local extra = math.max(0, distinct - 1)
	extra = math.min(extra, ctx.WorldConstants.CombatFlankingMaxExtraOrigins or 3)
	return base + extra * (ctx.WorldConstants.CombatFlankingWidthPerExtraProvince or 30)
end

local function totalSideStrength(armyIds)
	local total = 0
	for _, armyId in armyIds do
		local army = ctx.WorldState.getArmy(armyId)
		if army then
			total += ctx.ArmySystem.compositionStrength(army.composition)
		end
	end
	return total
end

local function totalSideOrg(armyIds)
	local total = 0
	for _, armyId in armyIds do
		local army = ctx.WorldState.getArmy(armyId)
		if army then total += (army.organization or 0) end
	end
	return total
end

local function fortTierFor(provinceId)
	local prov = ctx.WorldState.getProvince(provinceId)
	if not prov then return 0 end
	return prov.effectiveFortTier or prov.fortTier or 0
end

local function findBattleAtProvince(provinceId)
	for _, b in ctx.WorldState.allBattles() do
		if b.provinceId == provinceId then return b end
	end
	return nil
end

-- Battle at the candidate, or an army the retreater is at war with standing on it. Neutral
-- third-party stacks never block anything.
local function hostileOrBattleAt(owner, candidateId)
	if findBattleAtProvince(candidateId) then return true end
	local dipl = ctx.DiplomacySystem
	if dipl and dipl.areAtWar then
		for _, other in ctx.ArmySystem.armiesInProvince(candidateId) do
			if other.ownerTag ~= owner and dipl.areAtWar(owner, other.ownerTag) then
				return true
			end
		end
	end
	return false
end

-- A retreat destination must be a LAND province (sea is never an escape route from a LAND
-- battle -- owner decision), controlled by the retreater or an ally, with no active battle
-- and no at-war army. A loser standing ON a sea node additionally accepts adjacent open
-- water (allowSea): empty sea nodes qualify; surrounded on all sides means lost at sea.
local function retreatCandidateOk(owner, candidateId, allowSea)
	if type(candidateId) == "number" and candidateId < 0 then
		return allowSea == true and not hostileOrBattleAt(owner, candidateId)
	end
	local province = ctx.WorldState.getProvince(candidateId)
	if not province then return false end
	local controller = province.controllerTag
	local controlledOrAllied = controller == owner
	if not controlledOrAllied and controller and controller ~= "" and controller ~= "NONE" then
		local dipl = ctx.DiplomacySystem
		controlledOrAllied = (dipl and dipl.areAllied and dipl.areAllied(owner, controller)) or false
	end
	if not controlledOrAllied then return false end
	return not hostileOrBattleAt(owner, candidateId)
end

local function chooseRetreatProvince(army)
	local adjacency = ctx.AdjacencyGraph
	local owner = army.ownerTag
	local origin = army.originProvinceId
	if not ctx.WorldConstants.EnableStrictRetreat then
		-- Legacy: origin if still ours, else first adjacent controlled tile. Allows
		-- non-adjacent origin teleports and retreats into contested/enemy-held tiles.
		if origin and origin ~= army.provinceId then
			local p = ctx.WorldState.getProvince(origin)
			if p and p.controllerTag == owner then
				return origin
			end
		end
		for _, candidateId in adjacency.getNeighbors(army.provinceId) do
			local province = ctx.WorldState.getProvince(candidateId)
			if province and province.controllerTag == owner then
				return candidateId
			end
		end
		return nil
	end
	local atSea = type(army.provinceId) == "number" and army.provinceId < 0
	if origin and origin ~= army.provinceId
		and adjacency.areNeighbors and adjacency.areNeighbors(army.provinceId, origin)
		and retreatCandidateOk(owner, origin, atSea) then
		return origin
	end
	for _, candidateId in adjacency.getNeighbors(army.provinceId) do
		if candidateId ~= origin and retreatCandidateOk(owner, candidateId, atSea) then
			return candidateId
		end
	end
	return nil
end

-- ===== Battle lifecycle =====================================================

local function endBattle(record, winnerSide, reason)
	-- Reentrancy guard: side processing below publishes events (ArmyDisbanded scrub,
	-- ProvinceOccupied -> forced peace -> endActiveBattlesBetween, ...) that the EventBus
	-- drains SYNCHRONOUSLY and that can route back here for this same record. Mark it and
	-- remove it from WorldState FIRST so any re-entrant path finds nothing to end --
	-- otherwise winners get processed twice and BattleResolved double-awards war-score.
	if record.ending then return end
	record.ending = true
	ctx.WorldState.setBattle(record.id, nil)
	battleLogs[record.id] = nil

	local battleId = record.id
	local provinceId = record.provinceId
	local attackerTag = nil
	local defenderTag = nil
	if record.attackerArmyIds[1] then
		local a = ctx.WorldState.getArmy(record.attackerArmyIds[1])
		if a then attackerTag = a.ownerTag end
	end
	if record.defenderArmyIds[1] then
		local d = ctx.WorldState.getArmy(record.defenderArmyIds[1])
		if d then defenderTag = d.ownerTag end
	end

	local winnerTag = nil
	local loserTag = nil
	if winnerSide == "attacker" then
		winnerTag = attackerTag
		loserTag = defenderTag
	elseif winnerSide == "defender" then
		winnerTag = defenderTag
		loserTag = attackerTag
	end

	local function setBattleMoraleMod(armyId, pct)
		local army = ctx.WorldState.getArmy(armyId)
		if not army then return end
		local months = ctx.WorldConstants.BattleMoraleModifierMonths or 6
		local expireMonthIndex = nil
		local getDate = ctx.TickScheduler and ctx.TickScheduler.getGameDate
		if getDate then
			local gd = getDate()
			if gd then expireMonthIndex = gd.year * 12 + (gd.month - 1) + months end
		end
		army.battleMoraleMod = { pct = pct, expireMonthIndex = expireMonthIndex }
		ctx.WorldState.setArmy(armyId, army)
	end

	local function processLosers(armyIds, isAttackerSide)
		for _, armyId in armyIds do
			local army = ctx.WorldState.getArmy(armyId)
			if army then
				army.battleId = nil
				ctx.WorldState.setArmy(armyId, army)
				local moraleHit = (ctx.WorldConstants.ArmyMoraleBattleLoss or 6) * 2
				ctx.ArmySystem.adjustMorale(armyId, -moraleHit)
				if ctx.ArmySystem.compositionStrength(army.composition) <= 0 then
					ctx.ArmySystem.destroyArmy(armyId, "annihilated")
				else
					-- Adjacent engagement: a beaten ATTACKER standing on its own (or an ally's)
					-- tile simply stands down there -- a failed attack is not a rout. It keeps
					-- the morale/org penalties; its queued path is dead. Cooldown stamped so
					-- AutoCapture doesn't grind the same attack every tick.
					local staysHome = false
					if isAttackerSide and ctx.WorldConstants.EnableAdjacentEngagement then
						local here = ctx.WorldState.getProvince(army.provinceId)
						local controller = here and here.controllerTag
						staysHome = controller == army.ownerTag
						if not staysHome and controller and controller ~= "" and controller ~= "NONE" then
							local dipl = ctx.DiplomacySystem
							staysHome = (dipl and dipl.areAllied and dipl.areAllied(army.ownerTag, controller)) or false
						end
					end
					if staysHome then
						army.movementPath = nil
						army.lastFailedAttackAt = ctx.TickScheduler.getSimTime()
						ctx.WorldState.setArmy(armyId, army)
						ctx.ArmySystem.setState(armyId, "idle")
						continue
					end
					local retreatTo = chooseRetreatProvince(army)
					if retreatTo then
						army.retreating = true
						ctx.ArmySystem.setState(armyId, "retreating")
						ctx.WorldState.setArmy(armyId, army)
						ctx.ArmySystem.relocateArmy(armyId, retreatTo)
						local refreshed = ctx.WorldState.getArmy(armyId)
						if refreshed then
							refreshed.retreating = nil
							refreshed.organization = math.max(refreshed.organization or 0, 1.0)
							refreshed.morale = math.floor((refreshed.morale or 0) * 0.5)
							ctx.WorldState.setArmy(armyId, refreshed)
							ctx.ArmySystem.setState(armyId, "idle")
						end
					else
						local atSea = type(army.provinceId) == "number" and army.provinceId < 0
						ctx.ArmySystem.destroyArmy(armyId, atSea and "lost_at_sea" or "annihilated")
					end
				end
			end
		end
	end

	local function processWinners(armyIds, isAttacker)
		for _, armyId in armyIds do
			local army = ctx.WorldState.getArmy(armyId)
			if army then
				army.battleId = nil
				if isAttacker then
					army.originProvinceId = nil
				end
				ctx.WorldState.setArmy(armyId, army)
				ctx.ArmySystem.setState(armyId, "idle")
				if isAttacker then
					ctx.ArmySystem.relocateArmy(armyId, provinceId)
					-- relocateArmy publishes no arrival event (and no-ops when the winner already
					-- stands on the tile). Route through onArmyArrival explicitly: it instant-
					-- captures the won tile, and if an at-war straggler somehow still stands there
					-- it starts the follow-up battle instead of leaving hostile armies co-located.
					-- Safe re-entrancy-wise: this record was removed before side processing.
					if ctx.CombatSystem and ctx.CombatSystem.onArmyArrival then
						ctx.CombatSystem.onArmyArrival(armyId, provinceId)
					end
					-- Adjacent engagement: a queued multi-tile order paused for this battle;
					-- resume it through the just-won tile.
					if ctx.WorldConstants.EnableAdjacentEngagement
						and ctx.MovementSystem and ctx.MovementSystem.continuePath then
						local refreshed = ctx.WorldState.getArmy(armyId)
						if refreshed and refreshed.movementPath
							and not refreshed.battleId and not refreshed.retreating then
							ctx.MovementSystem.continuePath(refreshed)
						end
					end
				end
			end
		end
	end

	if winnerSide == "attacker" then
		processLosers(record.defenderArmyIds, false)
		processWinners(record.attackerArmyIds, true)
	elseif winnerSide == "defender" then
		processLosers(record.attackerArmyIds, true)
		processWinners(record.defenderArmyIds, false)
	else
		processWinners(record.attackerArmyIds, false)
		processWinners(record.defenderArmyIds, false)
	end

	-- Post-battle morale modifiers (spec G.1.7): victor +bonus / loser -penalty for N months.
	local victorBonus = ctx.WorldConstants.BattleVictorMoraleBonus or 0.10
	local loserPenalty = ctx.WorldConstants.BattleLoserMoralePenalty or 0.20
	if winnerSide == "attacker" then
		for _, id in ipairs(record.attackerArmyIds) do setBattleMoraleMod(id, victorBonus) end
		for _, id in ipairs(record.defenderArmyIds) do setBattleMoraleMod(id, -loserPenalty) end
	elseif winnerSide == "defender" then
		for _, id in ipairs(record.defenderArmyIds) do setBattleMoraleMod(id, victorBonus) end
		for _, id in ipairs(record.attackerArmyIds) do setBattleMoraleMod(id, -loserPenalty) end
	end

	for _, armyId in ipairs(record.attackerArmyIds or {}) do
		local a = ctx.WorldState.getArmy(armyId)
		if a and a.casualtyDebt then a.casualtyDebt = nil; ctx.WorldState.setArmy(armyId, a) end
	end
	for _, armyId in ipairs(record.defenderArmyIds or {}) do
		local a = ctx.WorldState.getArmy(armyId)
		if a and a.casualtyDebt then a.casualtyDebt = nil; ctx.WorldState.setArmy(armyId, a) end
	end

	ctx.EventBus.publish(ctx.Channels.BattleResolved, {
		battleId = battleId,
		provinceId = provinceId,
		warId = record.warId,
		winnerTag = winnerTag,
		loserTag = loserTag,
		attackerArmyIds = record.attackerArmyIds,
		defenderArmyIds = record.defenderArmyIds,
		reason = reason,
	})
end

local function startBattle(provinceId, attackerArmyIds, defenderArmyIds, attackerOriginByArmyId, warId)
	local id = generateBattleId(provinceId)
	local now = ctx.TickScheduler.getSimTime()

	local naval = unitsNavalLike(attackerArmyIds) or unitsNavalLike(defenderArmyIds)
	local cycleId = naval and "naval" or "ground"

	local record = {
		id = id,
		provinceId = provinceId,
		attackerArmyIds = table.clone(attackerArmyIds),
		defenderArmyIds = table.clone(defenderArmyIds),
		attackerOriginByArmyId = attackerOriginByArmyId and table.clone(attackerOriginByArmyId) or {},
		startedAt = now,
		lastTickAt = now,
		warId = warId,
		width = 0,
		round = 0,
		attackerStrengthStart = totalSideStrength(attackerArmyIds),
		defenderStrengthStart = totalSideStrength(defenderArmyIds),
		attackerOrgStart = totalSideOrg(attackerArmyIds),
		defenderOrgStart = totalSideOrg(defenderArmyIds),
		phaseCycle = cycleId,
		phaseIndex = 1,
		phaseElapsed = 0,
	}

	for _, armyId in attackerArmyIds do
		local army = ctx.WorldState.getArmy(armyId)
		if army then
			army.battleId = id
			ctx.WorldState.setArmy(armyId, army)
			ctx.ArmySystem.setEntrenchment(armyId, 0)
			ctx.ArmySystem.setState(armyId, "attacking")
		end
	end
	for _, armyId in defenderArmyIds do
		local army = ctx.WorldState.getArmy(armyId)
		if army then
			army.battleId = id
			ctx.WorldState.setArmy(armyId, army)
			ctx.ArmySystem.setState(armyId, "defending")
		end
	end

	ctx.WorldState.setBattle(id, record)
	local attackerArmy = attackerArmyIds[1] and ctx.WorldState.getArmy(attackerArmyIds[1])
	local defenderArmy = defenderArmyIds[1] and ctx.WorldState.getArmy(defenderArmyIds[1])
	ctx.EventBus.publish(ctx.Channels.BattleStarted, {
		battleId = id,
		provinceId = provinceId,
		warId = warId,
		attackerTag = attackerArmy and attackerArmy.ownerTag,
		defenderTag = defenderArmy and defenderArmy.ownerTag,
		attackerArmyIds = record.attackerArmyIds,
		defenderArmyIds = record.defenderArmyIds,
	})
	return record
end

local function joinBattle(battleId, armyId, role)
	local record = ctx.WorldState.getBattle(battleId)
	if not record then return false, "no_battle" end
	local army = ctx.WorldState.getArmy(armyId)
	if not army then return false, "no_army" end
	local listToCheck = role == "attacker" and record.attackerArmyIds or record.defenderArmyIds
	for _, id in listToCheck do
		if id == armyId then return true, "already_in" end
	end
	if role == "attacker" then
		table.insert(record.attackerArmyIds, armyId)
		record.attackerOriginByArmyId[armyId] = army.originProvinceId or army.provinceId
		record.attackerStrengthStart += ctx.ArmySystem.compositionStrength(army.composition)
		record.attackerOrgStart += (army.organization or 0)
		army.battleId = battleId
		ctx.WorldState.setArmy(armyId, army)
		ctx.ArmySystem.setEntrenchment(armyId, 0)
		ctx.ArmySystem.setState(armyId, "attacking")
	else
		table.insert(record.defenderArmyIds, armyId)
		record.defenderStrengthStart += ctx.ArmySystem.compositionStrength(army.composition)
		record.defenderOrgStart += (army.organization or 0)
		army.battleId = battleId
		ctx.WorldState.setArmy(armyId, army)
		ctx.ArmySystem.setState(armyId, "defending")
	end
	ctx.WorldState.setBattle(battleId, record)
	ctx.EventBus.publish(ctx.Channels.BattleArmyJoined, {
		battleId = battleId,
		armyId = armyId,
		role = role,
		tag = army.ownerTag,
	})
	return true
end

-- ===== Round resolution (drives CombatEngine) ===============================

-- Build an engine side input from live armies. atkMult/defMult fold the static
-- multipliers; the engine applies terrain/morale/discipline/org/fort itself.
-- record/sideRole (optional, C9): an army standing on a sea node is a TRANSPORT and fights
-- badly (both mults scaled); in a LAND battle an attacker whose feet are still in the water
-- is a naval invasion and attacks weakened instead.
local function buildSideInput(armyIds, terrain, record, sideRole)
	local formations = {}
	local orgMax = ctx.WorldConstants.ArmyOrganizationMax or 10
	local moraleMax = ctx.WorldConstants.ArmyMoraleMax or 100
	for _, armyId in armyIds do
		local army = ctx.WorldState.getArmy(armyId)
		if army and not army.retreating then
			local units = {}
			for typeId, count in pairs(army.composition or {}) do
				if count and count > 0 then
					local u = unitOf(typeId)
					if u then
						table.insert(units, {
							typeId = typeId,
							count = count,
							attack = u.attack or 0,
							defense = u.defense or 0,
							combatWidth = u.combatWidth or 2,
							discipline = u.discipline,
							tags = u.tags,
							terrainMods = u.terrainMods,
							typeStrength = u.typeStrength,
						})
					end
				end
			end
			if #units > 0 then
				local atkMult = statMultiplier(army, terrain, "attack")
				local defMult = statMultiplier(army, terrain, "defense")
				if ctx.WorldConstants.EnableSeaTransport
					and type(army.provinceId) == "number" and army.provinceId < 0 then
					local battleAtSea = record == nil
						or (type(record.provinceId) == "number" and record.provinceId < 0)
					if battleAtSea or sideRole ~= "attacker" then
						local p = ctx.WorldConstants.SeaTransportCombatPenalty or 0.35
						atkMult *= p
						defMult *= p
					else
						atkMult *= (ctx.WorldConstants.SeaInvasionAttackPenalty or 0.5)
					end
				end
				table.insert(formations, {
					id = armyId,
					morale = army.morale or moraleMax,
					moraleMax = ctx.ArmySystem.effectiveMoraleMax(army),
					organization = army.organization or (army.baseOrganization or orgMax),
					baseOrganization = army.baseOrganization or orgMax,
					atkMult = atkMult,
					defMult = defMult,
					moraleResist = officerModifierFor(army, "morale") + officerModifierFor(army, "discipline")
						+ commanderMoraleResist(army),
					units = units,
				})
			end
		end
	end
	return { formations = formations }
end

local function awardSideXp(armyIds, damageDealt)
	local officerMod = ctx.Bundle and ctx.Bundle.officerTraits or nil
	if not officerMod or not officerMod.levelFor then return end
	local casualtyXp = math.floor(((damageDealt or 0) * 0.02) + 0.5)
	for _, armyId in ipairs(armyIds or {}) do
		local army = ctx.WorldState.getArmy(armyId)
		if army and type(army.officer) == "table" then
			local off = army.officer
			local prevLevel = off.level or 0
			off.experience = (off.experience or 0) + 1 + casualtyXp
			local newLevel = officerMod.levelFor(off.experience)
			if newLevel > prevLevel then
				off.level = newLevel
				local sk = math.clamp(2 + newLevel, 0, 5)
				off.skillAttack, off.skillDefense, off.skillManeuver = sk, sk, sk
				local newTrait
				if officerMod.pickEligibleTrait then
					local seed = (ctx.WorldConstants.OfficerRngSeed or 13337) + (off.experience or 0)
					newTrait = officerMod.pickEligibleTrait(off, army.domain or "ground", Random.new(seed))
					if newTrait then
						off.traits = off.traits or {}
						table.insert(off.traits, newTrait)
					end
				end
				if ctx.Channels and ctx.Channels.ArmyOfficerLeveled then
					ctx.EventBus.publish(ctx.Channels.ArmyOfficerLeveled, {
						armyId = armyId,
						tag = army.ownerTag,
						level = newLevel,
						newTraitId = newTrait,
						officerName = off.name,
					})
				end
			end
			ctx.WorldState.setArmy(armyId, army)
		end
	end
end

local function applySideDeltas(armyIds, sideResult, entrenchResetPct)
	for _, armyId in ipairs(armyIds or {}) do
		local ratio = sideResult.casualtiesByFormation[armyId] or 0
		if ratio and ratio > 0 then
			ctx.ArmySystem.applyCasualties(armyId, ratio)
			if ratio > entrenchResetPct then
				ctx.ArmySystem.setEntrenchment(armyId, 0)
			end
		end
		if sideResult.orgDelta and sideResult.orgDelta ~= 0 then
			ctx.ArmySystem.adjustOrganization(armyId, sideResult.orgDelta)
		end
		if sideResult.moraleDelta and sideResult.moraleDelta ~= 0 then
			ctx.ArmySystem.adjustMorale(armyId, sideResult.moraleDelta)
		end
	end
end

local function tickBattle(record)
	local terrain = terrainOf(record.provinceId)
	local width = effectiveWidthFor(record)
	record.width = width
	if not record.phaseCycle then
		record.phaseCycle = unitsNavalLike(record.attackerArmyIds) and "naval" or "ground"
		record.phaseIndex = 1
	end

	local phaseSpec = CombatPhases.getPhase(record.phaseCycle, record.phaseIndex or 1)

	local attackerSide = buildSideInput(record.attackerArmyIds, terrain, record, "attacker")
	local defenderSide = buildSideInput(record.defenderArmyIds, terrain, record, "defender")

	local result = ctx.CombatEngine.resolveRound({
		constants = ctx.WorldConstants,
		terrain = terrain,
		fortTier = fortTierFor(record.provinceId),
		roleSet = record.phaseCycle or "ground",
		phaseSpec = phaseSpec,
		width = width,
		regimentStrength = ctx.WorldConstants.ArmyRegimentStrength or 1000,
		attacker = attackerSide,
		defender = defenderSide,
	})

	local entrenchResetPct = ctx.WorldConstants.CombatEntrenchmentResetStrengthLossPct or 0.10
	applySideDeltas(record.attackerArmyIds, result.attacker, entrenchResetPct)
	applySideDeltas(record.defenderArmyIds, result.defender, entrenchResetPct)

	-- Officer XP: damage dealt by a side == damage taken by the other side.
	awardSideXp(record.attackerArmyIds, result.defender.damageTaken)
	awardSideXp(record.defenderArmyIds, result.attacker.damageTaken)

	-- Combat depth C: group generals also earn XP from their armies' battles, awarded ONCE per
	-- commander per round (a group's armies share one general -> don't multiply by member count).
	if ctx.WorldConstants.EnableGenerals and ctx.GeneralSystem and ctx.GeneralSystem.awardGeneralXp then
		local function awardCommanderSide(armyIds, damageDealt)
			local xp = 1 + math.floor((damageDealt or 0) * 0.02 + 0.5)
			local seen = {}
			for _, armyId in ipairs(armyIds) do
				local army = ctx.WorldState.getArmy(armyId)
				local gid = army and army.groupId
				local grp = gid and ctx.WorldState.getArmyGroup(gid)
				local cid = grp and grp.commanderId
				if cid and not seen[cid] then
					seen[cid] = true
					ctx.GeneralSystem.awardGeneralXp(army, xp)
				end
			end
		end
		awardCommanderSide(record.attackerArmyIds, result.defender.damageTaken)
		awardCommanderSide(record.defenderArmyIds, result.attacker.damageTaken)
	end

	record.round = (record.round or 0) + 1
	record.lastDamageRoll = { attacker = result.attacker.damageTaken, defender = result.defender.damageTaken }

	-- Battle "tide" in -1..1 (attacker advantage), replicated for the combat bubble.
	-- Blends remaining strength and organization fractions vs. start; org weighted
	-- higher because org collapse, not raw losses, decides a battle. Read-only —
	-- never feeds back into resolution.
	do
		local atkStr = totalSideStrength(record.attackerArmyIds)
		local defStr = totalSideStrength(record.defenderArmyIds)
		local atkOrg = totalSideOrg(record.attackerArmyIds)
		local defOrg = totalSideOrg(record.defenderArmyIds)
		local function frac(cur, start) return (start and start > 0) and (cur / start) or 0 end
		local atkScore = 0.4 * frac(atkStr, record.attackerStrengthStart) + 0.6 * frac(atkOrg, record.attackerOrgStart)
		local defScore = 0.4 * frac(defStr, record.defenderStrengthStart) + 0.6 * frac(defOrg, record.defenderOrgStart)
		record.tide = math.clamp(atkScore - defScore, -1, 1)
	end

	local activeSpec = phaseSpec or CombatPhases.getPhase(record.phaseCycle, record.phaseIndex or 1)
	local phaseDuration = math.max(1, (activeSpec and activeSpec.duration) or 1)
	record.phaseElapsed = (record.phaseElapsed or 0) + 1
	if record.phaseElapsed >= phaseDuration then
		-- Advance the phase. phaseCycle/phaseIndex ride the replicated battle record, so the client
		-- combat bubble reads them from there. The old BattlePhaseChanged -> BattlePhaseChannel broadcast
		-- (a dead client channel with ZERO subscribers) was removed: at war scale it fired FireAllClients
		-- per phase flip per battle every combat tick for data nothing consumed.
		record.phaseIndex = CombatPhases.next(record.phaseCycle, record.phaseIndex or 1)
		record.phaseElapsed = 0
	end

	-- perf: the round log is server-only debug data. Keeping it on the replicated record meant the
	-- whole ~60-entry array re-broadcast to every client on every 3s combat tick per battle. Store
	-- it in a module-level sidecar instead so the battle record stays small (the client UI reads
	-- tide/round/width, never the log). record.log stays nil on the wire.
	local logs = battleLogs[record.id]
	if not logs then logs = {}; battleLogs[record.id] = logs end
	table.insert(logs, {
		round = record.round,
		simTime = ctx.TickScheduler.getSimTime(),
		atkCasualtyRatio = result.attacker.casualtyRatio,
		defCasualtyRatio = result.defender.casualtyRatio,
		reason = result.reason,
	})
	while #logs > 60 do table.remove(logs, 1) end

	if result.outcome == "attacker" then
		endBattle(record, "attacker", result.reason)
		return
	elseif result.outcome == "defender" then
		endBattle(record, "defender", result.reason)
		return
	end

	record.lastTickAt = ctx.TickScheduler.getSimTime()
	ctx.WorldState.setBattle(record.id, record)
end

-- A bordering, idle friendly army joins an ongoing battle in an adjacent province
-- as a flanking reinforcement: it stays in its own province (origin recorded for the
-- combat-width bonus) rather than relocating. Requires true bordering adjacency and
-- that the army belongs to a belligerent on one side. Returns true on success.
local function reinforce(armyId, targetProvinceId)
	local army = ctx.WorldState.getArmy(armyId)
	if not army then return false, "no_army" end
	if army.battleId then return false, "in_battle" end
	if army.movement then return false, "in_motion" end

	local battle = findBattleAtProvince(targetProvinceId)
	if not battle then return false, "no_battle" end

	-- Reinforcement is strictly from a BORDERING province (flanking). An army already
	-- in the battle province isn't reinforcing -- and allowing it would record the
	-- battle province as a distinct attacker origin and wrongly inflate combat width.
	if army.provinceId == targetProvinceId then return false, "already_in_province" end
	local adj = ctx.AdjacencyGraph
	if not (adj and adj.areNeighbors and adj.areNeighbors(army.provinceId, targetProvinceId)) then
		return false, "not_adjacent"
	end

	local function ownerOf(ids)
		local first = ids and ids[1]
		local a = first and ctx.WorldState.getArmy(first)
		return a and a.ownerTag or nil
	end
	local attackerTag = ownerOf(battle.attackerArmyIds)
	local defenderTag = ownerOf(battle.defenderArmyIds)
	local me = army.ownerTag
	local role
	if me == attackerTag then
		role = "attacker"
	elseif me == defenderTag then
		role = "defender"
	else
		-- No alliance system yet: a third party may only join the side fighting an
		-- enemy it is itself at war with.
		local atWar = ctx.DiplomacySystem and ctx.DiplomacySystem.areAtWar
		if atWar and defenderTag and atWar(me, defenderTag) then
			role = "attacker"
		elseif atWar and attackerTag and atWar(me, attackerTag) then
			role = "defender"
		else
			return false, "not_belligerent"
		end
	end

	army.originProvinceId = army.provinceId
	ctx.WorldState.setArmy(armyId, army)
	return joinBattle(battle.id, armyId, role)
end

-- Home defense preempts offense: pull an army out of a battle it is ATTACKING in (it fights
-- from its own tile, so "leaving" is bookkeeping only) so it can defend its own tile. Never
-- valid for defenders -- a defender's battle IS at its tile. If it was the last attacker the
-- battle ends "attackers_withdrew": the attacker list is empty by then, so BattleResolved
-- carries a nil winner/loser pair and DiplomacySystem awards no war-score (no bait farming).
local function withdrawFromBattle(armyId, reason)
	local army = ctx.WorldState.getArmy(armyId)
	if not army or not army.battleId then return false, "not_in_battle" end
	local record = ctx.WorldState.getBattle(army.battleId)
	if not record then
		army.battleId = nil
		ctx.WorldState.setArmy(armyId, army)
		return true
	end
	local removed = false
	for i = #record.attackerArmyIds, 1, -1 do
		if record.attackerArmyIds[i] == armyId then
			table.remove(record.attackerArmyIds, i)
			removed = true
		end
	end
	if not removed then return false, "not_attacker" end
	if record.attackerOriginByArmyId then record.attackerOriginByArmyId[armyId] = nil end
	army.battleId = nil
	ctx.WorldState.setArmy(armyId, army)
	ctx.ArmySystem.setState(armyId, "idle")
	if #record.attackerArmyIds == 0 then
		endBattle(record, "defender", reason or "attackers_withdrew")
	else
		ctx.WorldState.setBattle(record.id, record)
	end
	return true
end

-- An army can be destroyed while a battle still lists it (annexation sweep, encirclement of a
-- co-belligerent, any future destroy path). Scrub it from every live battle so the record never
-- stalls with a dead id; a side left empty concedes. Records mid-endBattle are already removed
-- from WorldState (reentrancy guard), so the snapshot below never sees them.
local function onArmyDisbanded(payload)
	local armyId = payload and payload.armyId
	if not armyId then return end
	local records = {}
	for _, record in ctx.WorldState.allBattles() do
		records[#records + 1] = record
	end
	for _, record in ipairs(records) do
		if record.ending or not ctx.WorldState.getBattle(record.id) then continue end
		local changed = false
		local function scrub(list)
			for i = #list, 1, -1 do
				if list[i] == armyId then
					table.remove(list, i)
					changed = true
				end
			end
		end
		scrub(record.attackerArmyIds)
		scrub(record.defenderArmyIds)
		if record.attackerOriginByArmyId and record.attackerOriginByArmyId[armyId] ~= nil then
			record.attackerOriginByArmyId[armyId] = nil
			changed = true
		end
		if changed then
			if #record.attackerArmyIds == 0 then
				endBattle(record, "defender", "side_eliminated")
			elseif #record.defenderArmyIds == 0 then
				endBattle(record, "attacker", "side_eliminated")
			else
				ctx.WorldState.setBattle(record.id, record)
			end
		end
	end
end

function BattleManager.register(context)
	ctx = context
	context.EventBus.subscribe(context.Channels.ArmyDisbanded, onArmyDisbanded)
	local api = {
		startBattle = startBattle,
		joinBattle = joinBattle,
		reinforce = reinforce,
		withdrawFromBattle = withdrawFromBattle,
		findBattleAtProvince = findBattleAtProvince,
		tickBattle = tickBattle,
		endBattle = endBattle,
		effectiveWidthFor = effectiveWidthFor,
		statMultiplier = statMultiplier,
		buildSideInput = buildSideInput,
	}
	context.BattleManager = api
	for k, v in pairs(api) do BattleManager[k] = v end
end

return BattleManager 