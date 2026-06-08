local OfficerTraits = {
	aggressive = {
		id = "aggressive",
		displayName = "Aggressive",
		description = "Bold attacks, weaker defense.",
		modifiers = { attack = 0.10, defense = -0.05, morale = -0.05 },
		domain = "ground",
	},
	defensive = {
		id = "defensive",
		displayName = "Defensive",
		description = "Holds ground with discipline.",
		modifiers = { defense = 0.10, morale = 0.05, attack = -0.03 },
		domain = "ground",
	},
	disciplined = {
		id = "disciplined",
		displayName = "Disciplined",
		description = "Better organization and morale recovery.",
		modifiers = { discipline = 0.10, morale = 0.08 },
		domain = "any",
	},
	cunning = {
		id = "cunning",
		displayName = "Cunning",
		description = "Skilled at maneuver and ambush.",
		modifiers = { attack = 0.06, maneuver = 0.20 },
		domain = "ground",
	},
	logistician = {
		id = "logistician",
		displayName = "Logistician",
		description = "Reduced upkeep and supply attrition.",
		modifiers = { upkeep = -0.10, attrition_resist = 0.10 },
		domain = "any",
	},
	engineer = {
		id = "engineer",
		displayName = "Engineer",
		description = "Faster siege and fortification.",
		modifiers = { siege_speed = 0.20, entrench_speed = 0.25 },
		domain = "ground",
	},
	cavalier = {
		id = "cavalier",
		displayName = "Cavalier",
		description = "Heroic in the shock phase.",
		modifiers = { attack = 0.12, defense = -0.02 },
		domain = "ground",
	},
	marksman = {
		id = "marksman",
		displayName = "Marksman",
		description = "Superior firepower control.",
		modifiers = { attack = 0.10 },
		domain = "ground",
	},
	old_guard = {
		id = "old_guard",
		displayName = "Old Guard",
		description = "Steady veteran, slower but unbreakable.",
		modifiers = { defense = 0.08, morale = 0.12, maneuver = -0.05 },
		domain = "ground",
	},
	zealous = {
		id = "zealous",
		displayName = "Zealous",
		description = "Charismatic leader — inspires troops.",
		modifiers = { morale = 0.15, attack = 0.05 },
		domain = "any",
	},
	naval_commander = {
		id = "naval_commander",
		displayName = "Naval Commander",
		description = "Excels at fleet maneuvers.",
		modifiers = { attack = 0.05, defense = 0.05, naval_speed = 0.15 },
		domain = "naval",
	},
	broadside_master = {
		id = "broadside_master",
		displayName = "Broadside Master",
		description = "Devastating ship-of-the-line gunnery.",
		modifiers = { attack = 0.20 },
		domain = "naval",
	},
	boarder = {
		id = "boarder",
		displayName = "Boarder",
		description = "Marine assault specialist.",
		modifiers = { attack = 0.10, defense = 0.10, boarding = 0.30 },
		domain = "naval",
	},
}

function OfficerTraits.byDomain(domain)
	local out = {}
	for _, t in pairs(OfficerTraits) do
		if type(t) == "table" and (t.domain == "any" or t.domain == domain) then
			table.insert(out, t)
		end
	end
	return out
end

function OfficerTraits.modifierSum(trait_ids, field)
	local total = 0
	for _, id in ipairs(trait_ids or {}) do
		local t = OfficerTraits[id]
		if t and t.modifiers and t.modifiers[field] then
			total += t.modifiers[field]
		end
	end
	return total
end

OfficerTraits.LEVEL_THRESHOLDS = { 100, 300, 700, 1500 }
OfficerTraits.MAX_TRAITS = 5

function OfficerTraits.levelFor(xp)
	local x = tonumber(xp) or 0
	local level = 0
	for _, threshold in ipairs(OfficerTraits.LEVEL_THRESHOLDS) do
		if x >= threshold then level = level + 1 else break end
	end
	return level
end

function OfficerTraits.xpForLevel(level)
	if not level or level <= 0 then return 0 end
	return OfficerTraits.LEVEL_THRESHOLDS[level] or OfficerTraits.LEVEL_THRESHOLDS[#OfficerTraits.LEVEL_THRESHOLDS]
end

function OfficerTraits.xpForNextLevel(level)
	if not level or level < 0 then level = 0 end
	if level >= #OfficerTraits.LEVEL_THRESHOLDS then return nil end
	return OfficerTraits.LEVEL_THRESHOLDS[level + 1]
end

function OfficerTraits.pickEligibleTrait(officer, domain, rng)
	if not officer or type(officer.traits) ~= "table" then return nil end
	if #officer.traits >= OfficerTraits.MAX_TRAITS then return nil end
	local pool = OfficerTraits.byDomain(domain or "ground")
	if #pool == 0 then return nil end
	local owned = {}
	for _, tid in ipairs(officer.traits) do owned[tid] = true end
	local candidates = {}
	for _, def in ipairs(pool) do
		if def and def.id and not owned[def.id] then
			table.insert(candidates, def.id)
		end
	end
	if #candidates == 0 then return nil end
	rng = rng or Random.new()
	return candidates[rng:NextInteger(1, #candidates)]
end

return OfficerTraits
