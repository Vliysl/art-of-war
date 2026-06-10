 local BattleManager = {}

local ctx
local nextBattleSeq = 0

local CombatPhases = require(game:GetService("ReplicatedStorage").ArtOfWar.Data.CombatPhases)

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
	local tactic, entrench = 1, 1
	if sideRole == "attack" then
		tactic = 1 + tacticBonusForCountry(country, "offensive")
	else
		tactic = 1 + tacticBonusForCountry(country, "defensive")
		entrench = 1 + (army.entrenchment or 0) * (ctx.WorldConstants.CombatEntrenchmentDefensePerLevel or 0.02)
	end
	return mod * training * spec * officer * tactic * entrench
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

local function chooseRetreatProvince(army)
	local adjacency = ctx.AdjacencyGraph
	local owner = army.ownerTag
	local origin = army.originProvinceId
	if origin and origin ~= army.provinceId then
		local p = ctx.WorldState.getProvince(origin)
		if p and p.controllerTag == owner then
			return origin
		end
	end
	local candidates = adjacency.getNeighbors(army.provinceId)
	for _, candidateId in candidates do
		local province = ctx.WorldState.getProvince(candidateId)
		if province and province.controllerTag == owner then
			return candidateId
		end
	end
	return nil
end

-- ===== Battle lifecycle =====================================================

local function endBattle(record, winnerSide, reason)
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

	local function processLosers(armyIds)
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
						ctx.ArmySystem.destroyArmy(armyId, "annihilated")
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
				end
			end
		end
	end

	if winnerSide == "attacker" then
		processLosers(record.defenderArmyIds)
		processWinners(record.attackerArmyIds, true)
	elseif winnerSide == "defender" then
		processLosers(record.attackerArmyIds)
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

	ctx.WorldState.setBattle(battleId, nil)
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
local function buildSideInput(armyIds, terrain)
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
				table.insert(formations, {
					id = armyId,
					morale = army.morale or moraleMax,
					moraleMax = ctx.ArmySystem.effectiveMoraleMax(army),
					organization = army.organization or (army.baseOrganization or orgMax),
					baseOrganization = army.baseOrganization or orgMax,
					atkMult = statMultiplier(army, terrain, "attack"),
					defMult = statMultiplier(army, terrain, "defense"),
					moraleResist = officerModifierFor(army, "morale") + officerModifierFor(army, "discipline"),
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

	local attackerSide = buildSideInput(record.attackerArmyIds, terrain)
	local defenderSide = buildSideInput(record.defenderArmyIds, terrain)

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

	record.round = (record.round or 0) + 1
	record.lastDamageRoll = { attacker = result.attacker.damageTaken, defender = result.defender.damageTaken }

	local activeSpec = phaseSpec or CombatPhases.getPhase(record.phaseCycle, record.phaseIndex or 1)
	local phaseDuration = math.max(1, (activeSpec and activeSpec.duration) or 1)
	record.phaseElapsed = (record.phaseElapsed or 0) + 1
	if record.phaseElapsed >= phaseDuration then
		record.phaseIndex = CombatPhases.next(record.phaseCycle, record.phaseIndex or 1)
		record.phaseElapsed = 0
		local nextSpec, nextIdx = CombatPhases.getPhase(record.phaseCycle, record.phaseIndex)
		ctx.EventBus.publish(ctx.Channels.BattlePhaseChanged, {
			battleId = record.id,
			provinceId = record.provinceId,
			phaseCycle = record.phaseCycle,
			phaseIndex = nextIdx or record.phaseIndex,
			phaseName = nextSpec and (nextSpec.displayName or nextSpec.id) or nil,
		})
	end

	if type(record.log) ~= "table" then record.log = {} end
	table.insert(record.log, {
		round = record.round,
		simTime = ctx.TickScheduler.getSimTime(),
		atkCasualtyRatio = result.attacker.casualtyRatio,
		defCasualtyRatio = result.defender.casualtyRatio,
		reason = result.reason,
	})
	while #record.log > 60 do table.remove(record.log, 1) end

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

function BattleManager.register(context)
	ctx = context
	local api = {
		startBattle = startBattle,
		joinBattle = joinBattle,
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