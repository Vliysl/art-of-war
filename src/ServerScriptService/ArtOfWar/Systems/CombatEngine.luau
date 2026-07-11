-- CombatEngine - pure, deterministic, round-based, role-matched combat resolution.
-- No ctx and no side effects: call resolveRound(input) -> result (deltas + outcome).
-- Used by BattleManager for both land and naval. Unit-testable in isolation.
--
-- Model (spec Appendix G.1.2, luck term dropped for determinism):
--   per role: netToDefender += max(0, attackerOffense - defenderDefense)
--             netToAttacker += max(0, defenderDefense*CounterHi - attackerOffense*CounterLo)
--   offense/defense fold count, stat, discipline, morale-factor, terrain, fort, external mult.
--   casualties -> strength (ratio per formation), plus morale & org shifts. Resolve by ROUT.

local CombatEngine = {}

local CombatPhases = require(game:GetService("ServerScriptService").ArtOfWar.ServerData.CombatPhases)

local function num(v, d)
	if type(v) == "number" then return v end
	return d
end

local function constant(constants, key, default)
	if constants then
		local v = constants[key]
		if v ~= nil then return v end
	end
	return default
end

-- Role taxonomy: ground = infantry/cavalry/artillery; naval = capital/heavy/light/transport.
local function classifyRole(unit, roleSet)
	if unit.role then return unit.role end
	local tags = {}
	if unit.tags then for _, t in ipairs(unit.tags) do tags[t] = true end end
	if roleSet == "naval" then
		if tags.capital then return "capital" end
		if tags.heavy then return "heavy" end
		if tags.transport then return "transport" end
		return "light"
	end
	if tags.mounted then return "cavalry" end
	if tags.splash or tags.siege then return "artillery" end
	return "infantry"
end
CombatEngine.classifyRole = classifyRole

local function moraleFactor(formation)
	local mm = num(formation.moraleMax, 100)
	if mm <= 0 then return 0.1 end
	return math.clamp(num(formation.morale, mm) / mm, 0.1, 1)
end

local function unitTerrainMod(unit, terrain)
	if not terrain or not unit.terrainMods then return 0 end
	return num(unit.terrainMods[terrain.id], 0)
end

-- Frontline slotting: fill frontage (combat width) regiment-by-regiment from the
-- highest combat-value stacks; overflow regiments become reserves (rotate in next round).
local function slotSide(side, width, regStrength)
	local slots = {}
	for _, f in ipairs(side.formations or {}) do
		for _, u in ipairs(f.units or {}) do
			local c = num(u.count, 0)
			if c > 0 then
				-- perf: precompute sort value + tie-break keys once (was recomputed per comparator call)
				local cw = math.max(1, num(u.combatWidth, 2))
				table.insert(slots, {
					f = f, u = u, count = c,
					cv = (num(u.attack, 0) + num(u.defense, 0)) / cw,
					fId = tostring(f.id), tId = tostring(u.typeId),
				})
			end
		end
	end
	table.sort(slots, function(a, b)
		if a.cv ~= b.cv then return a.cv > b.cv end
		if a.fId ~= b.fId then return a.fId < b.fId end
		return a.tId < b.tId
	end)
	local remaining = width
	for _, s in ipairs(slots) do
		local cw = math.max(1, num(s.u.combatWidth, 2))
		local fit = 0
		if remaining >= cw then
			fit = math.min(s.count, math.floor(remaining / cw))
		end
		s.front = fit
		s.reserve = s.count - fit
		remaining -= fit * cw
		if remaining < 0 then remaining = 0 end
	end
	return slots
end
CombatEngine.slotSide = slotSide

local function sideStrength(side, regStrength)
	local total = 0
	for _, f in ipairs(side.formations or {}) do
		for _, u in ipairs(f.units or {}) do
			total += num(u.count, 0) * num(u.typeStrength, regStrength)
		end
	end
	return total
end
CombatEngine.sideStrength = sideStrength
-- Side-aggregate discipline (strength-weighted). Resists morale loss (spec G.1.4).
local function sideDiscipline(side, regStrength)
	local wsum, total = 0, 0
	for _, f in ipairs(side.formations or {}) do
		for _, u in ipairs(f.units or {}) do
			local st = num(u.count, 0) * num(u.typeStrength, regStrength)
			wsum += st * num(u.discipline, 1)
			total += st
		end
	end
	if total <= 0 then return 1 end
	return math.clamp(wsum / total, 0.5, 2.0)
end
CombatEngine.sideDiscipline = sideDiscipline

-- Side-aggregate officer morale-resistance (strength-weighted formation.moraleResist).
local function sideMoraleResist(side, regStrength)
	local wsum, total = 0, 0
	for _, f in ipairs(side.formations or {}) do
		local fStr = 0
		for _, u in ipairs(f.units or {}) do fStr += num(u.count, 0) * num(u.typeStrength, regStrength) end
		wsum += fStr * num(f.moraleResist, 0)
		total += fStr
	end
	if total <= 0 then return 0 end
	return math.max(-0.5, wsum / total)
end
CombatEngine.sideMoraleResist = sideMoraleResist

-- resolveRound(input) -> result
-- input = { constants, terrain, fortTier, roleSet, width?, regimentStrength?, attacker, defender }
-- side  = { formations = { { id, morale, moraleMax, organization, baseOrganization,
--                            atkMult?, defMult?, units = { {typeId,count,attack,defense,
--                            combatWidth,discipline?,role?,tags?,terrainMods?,typeStrength?} } } } }
function CombatEngine.resolveRound(input)
	local constants = input.constants or {}
	local terrain = input.terrain
	local roleSet = input.roleSet or "ground"
	local regStrength = num(input.regimentStrength, num(constant(constants, "ArmyRegimentStrength", 1000)))
	local fortTier = num(input.fortTier, 0)

	local scale       = num(input.scale, num(constant(constants, "CombatDamageScale", 10)))  -- per-call override (naval uses NavalDamageScale)
	local counterHi   = num(constant(constants, "CombatDefenderCounterHi", 0.6))
	local counterLo   = num(constant(constants, "CombatDefenderCounterLo", 0.3))
	local fortPerTier = num(constant(constants, "FortBattleDefensePerTier", 0.15))
	local roundCap    = num(constant(constants, "CombatRoundCasualtyCap", 0.20))
	local routFloor   = num(constant(constants, "CombatMoraleRoutFloor", 20))
	local orgBreak    = num(constant(constants, "CombatOrgBreakRatio", 0.20))
	local routFrac    = num(constant(constants, "CombatRoutFraction", 0.5))
	local moraleBase  = num(constant(constants, "CombatMoraleRoundBase", 2))
	local moraleScale = num(constant(constants, "CombatMoraleCasualtyScale", 60))
	local orgBase     = num(constant(constants, "CombatOrgRoundBase", 0.4))
	local orgScale    = num(constant(constants, "CombatOrgCasualtyScale", 8))

	local terrAtk = 1 + (terrain and num(terrain.attackerPenalty, 0) or 0)
	local terrDef = 1 + (terrain and num(terrain.defenderBonus, num(terrain and terrain.defenderMod, 0)) or 0)
	local fortMult = 1 + fortTier * fortPerTier
	local width = num(input.width, terrain and num(terrain.combatWidth, 60) or 60)

	local phaseSpec = input.phaseSpec
	if phaseSpec == nil and input.phaseIndex then
		phaseSpec = CombatPhases.getPhase(input.phaseCycle or roleSet, input.phaseIndex)
	end
	local phaseDmgMult = phaseSpec and num(phaseSpec.damageMultiplier, 1) or 1
	local phaseMorMult = phaseSpec and num(phaseSpec.moraleMultiplier, 1) or 1
	local function affinity(u)
		if not phaseSpec then return 1 end
		return CombatPhases.tagAffinity(phaseSpec, u.tags)
	end

	local atkSlots = slotSide(input.attacker, width, regStrength)
	local defSlots = slotSide(input.defender, width, regStrength)

	-- attacker offense per role (uses attack stat + attacker terrain penalty)
	local atkOff = {}
	for _, s in ipairs(atkSlots) do
		if s.front > 0 then
			local u, f = s.u, s.f
			local role = classifyRole(u, roleSet)
			local power = s.front * num(u.attack, 0) * num(u.discipline, 1) * moraleFactor(f)
				* (1 + unitTerrainMod(u, terrain)) * num(f.atkMult, 1) * terrAtk * affinity(u)
			atkOff[role] = (atkOff[role] or 0) + power
		end
	end
	-- defender defense per role (uses defense stat + defender terrain bonus + fort)
	local defDef = {}
	for _, s in ipairs(defSlots) do
		if s.front > 0 then
			local u, f = s.u, s.f
			local role = classifyRole(u, roleSet)
			local power = s.front * num(u.defense, 0) * num(u.discipline, 1) * moraleFactor(f)
				* (1 + unitTerrainMod(u, terrain)) * num(f.defMult, 1) * terrDef * fortMult * affinity(u)
			defDef[role] = (defDef[role] or 0) + power
		end
	end

	local roles = {}
	for r in pairs(atkOff) do roles[r] = true end
	for r in pairs(defDef) do roles[r] = true end

	local netToDefender, netToAttacker = 0, 0
	for r in pairs(roles) do
		local a = atkOff[r] or 0
		local d = defDef[r] or 0
		netToDefender += math.max(0, a - d)
		netToAttacker += math.max(0, d * counterHi - a * counterLo)
	end
	netToDefender *= scale
	netToAttacker *= scale
	netToDefender *= phaseDmgMult
	netToAttacker *= phaseDmgMult

	local atkStr = sideStrength(input.attacker, regStrength)
	local defStr = sideStrength(input.defender, regStrength)
	local atkRatio = atkStr > 0 and math.clamp(netToAttacker / atkStr, 0, roundCap) or 0
	local defRatio = defStr > 0 and math.clamp(netToDefender / defStr, 0, roundCap) or 0

	-- distribute side casualty ratio across formations by frontline strength share
	local function distribute(side, slots, sideRatio)
		local frontByF, totalFront = {}, 0
		for _, s in ipairs(slots) do
			if s.front > 0 then
				local st = s.front * num(s.u.typeStrength, regStrength)
				frontByF[s.f.id] = (frontByF[s.f.id] or 0) + st
				totalFront += st
			end
		end
		local per = {}
		local sideStr = 0
		for _, f in ipairs(side.formations or {}) do
			local fStr = 0
			for _, u in ipairs(f.units or {}) do fStr += num(u.count, 0) * num(u.typeStrength, regStrength) end
			sideStr += fStr
		end
		local removeTotal = sideRatio * sideStr
		for _, f in ipairs(side.formations or {}) do
			local fStr = 0
			for _, u in ipairs(f.units or {}) do fStr += num(u.count, 0) * num(u.typeStrength, regStrength) end
			local share = (totalFront > 0) and ((frontByF[f.id] or 0) / totalFront) or 0
			per[f.id] = fStr > 0 and math.clamp((removeTotal * share) / fStr, 0, 1) or 0
		end
		return per
	end

	local atkCas = distribute(input.attacker, atkSlots, atkRatio)
	local defCas = distribute(input.defender, defSlots, defRatio)

	local atkDisc = sideDiscipline(input.attacker, regStrength)
	local defDisc = sideDiscipline(input.defender, regStrength)
	local atkMR = 1 + sideMoraleResist(input.attacker, regStrength)
	local defMR = 1 + sideMoraleResist(input.defender, regStrength)
	local atkMoraleDelta = -(moraleBase + ((moraleScale * atkRatio) / (atkDisc * atkMR)) * phaseMorMult)
	local defMoraleDelta = -(moraleBase + ((moraleScale * defRatio) / (defDisc * defMR)) * phaseMorMult)
	local atkOrgDelta = -(orgBase + orgScale * atkRatio)
	local defOrgDelta = -(orgBase + orgScale * defRatio)

	-- rout on POST-delta morale/org: side breaks if >=routFrac of strength routed,
	-- or aggregate org ratio < orgBreak, or annihilated.
	local function evaluateRout(side, moraleDelta, orgDelta)
		local routedStr, totalStr, orgSum, baseSum = 0, 0, 0, 0
		for _, f in ipairs(side.formations or {}) do
			local fStr = 0
			for _, u in ipairs(f.units or {}) do fStr += num(u.count, 0) * num(u.typeStrength, regStrength) end
			totalStr += fStr
			local postMorale = num(f.morale, num(f.moraleMax, 100)) + moraleDelta
			if postMorale <= routFloor then routedStr += fStr end
			local base = num(f.baseOrganization, num(f.organization, 10))
			if base <= 0 then base = 1 end
			orgSum += math.max(0, num(f.organization, base) + orgDelta)
			baseSum += base
		end
		local annihilated = totalStr <= 0
		local moraleRout = totalStr > 0 and (routedStr / totalStr) >= routFrac
		local orgRout = baseSum > 0 and (orgSum / baseSum) < orgBreak
		return (annihilated or moraleRout or orgRout), {
			annihilated = annihilated, moraleRout = moraleRout, orgRout = orgRout, strength = totalStr,
		}
	end

	local atkBroke, atkInfo = evaluateRout(input.attacker, atkMoraleDelta, atkOrgDelta)
	local defBroke, defInfo = evaluateRout(input.defender, defMoraleDelta, defOrgDelta)

	local outcome, reason = nil, nil
	if atkBroke and defBroke then
		local aR = atkStr > 0 and (1 - atkRatio) or 0
		local dR = defStr > 0 and (1 - defRatio) or 0
		outcome = (aR > dR) and "attacker" or "defender"
		reason = "mutual_collapse"
	elseif atkBroke then
		outcome = "defender"; reason = atkInfo.annihilated and "attacker_annihilated" or "attacker_routed"
	elseif defBroke then
		outcome = "attacker"; reason = defInfo.annihilated and "defender_annihilated" or "defender_routed"
	end

	return {
		outcome = outcome,
		reason = reason,
		width = width,
		attacker = {
			casualtiesByFormation = atkCas, casualtyRatio = atkRatio,
			moraleDelta = atkMoraleDelta, orgDelta = atkOrgDelta,
			strengthBefore = atkStr, damageTaken = netToAttacker, info = atkInfo,
		},
		defender = {
			casualtiesByFormation = defCas, casualtyRatio = defRatio,
			moraleDelta = defMoraleDelta, orgDelta = defOrgDelta,
			strengthBefore = defStr, damageTaken = netToDefender, info = defInfo,
		},
	}
end

function CombatEngine.register(context)
	context.CombatEngine = CombatEngine
	return CombatEngine
end

return CombatEngine
