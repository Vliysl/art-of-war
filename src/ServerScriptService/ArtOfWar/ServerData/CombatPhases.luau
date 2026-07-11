local CombatPhases = {}

local function phase(spec)
	spec.favoredTags = spec.favoredTags or {}
	return spec
end

CombatPhases.ground = {
	phase({
		id = "maneuver",
		displayName = "Maneuver",
		duration = 2,
		damageMultiplier = 0.7,
		moraleMultiplier = 1.1,
		favoredTags = {
			skirmisher = 1.2,
			mounted = 1.15,
			irregular = 1.15,
		},
	}),
	phase({
		id = "fire",
		displayName = "Fire",
		duration = 3,
		damageMultiplier = 1.05,
		moraleMultiplier = 0.92,
		favoredTags = {
			siege = 1.25,
			ranged = 1.2,
			line = 1.1,
		},
	}),
	phase({
		id = "shock",
		displayName = "Shock",
		duration = 2,
		damageMultiplier = 1.15,
		moraleMultiplier = 0.88,
		favoredTags = {
			shock = 1.25,
			mounted = 1.18,
			melee = 1.15,
		},
	}),
	phase({
		id = "aftermath",
		displayName = "Aftermath",
		duration = 1,
		damageMultiplier = 0.6,
		moraleMultiplier = 1.2,
		favoredTags = {},
	}),
}

CombatPhases.naval = {
	phase({
		id = "approach",
		displayName = "Approach",
		duration = 1,
		damageMultiplier = 0.7,
		moraleMultiplier = 1.1,
		favoredTags = {
			light = 1.2,
		},
	}),
	phase({
		id = "broadside",
		displayName = "Broadside",
		duration = 4,
		damageMultiplier = 1.15,
		moraleMultiplier = 0.88,
		favoredTags = {
			capital = 1.22,
			heavy = 1.18,
		},
	}),
	phase({
		id = "boarding",
		displayName = "Boarding",
		duration = 1,
		damageMultiplier = 0.85,
		moraleMultiplier = 0.85,
		favoredTags = {
			transport = 1.15,
			heavy = 1.1,
		},
	}),
	phase({
		id = "withdrawal",
		displayName = "Withdrawal",
		duration = 1,
		damageMultiplier = 0.6,
		moraleMultiplier = 1.2,
		favoredTags = {},
	}),
}

function CombatPhases.getCycle(cycleId)
	return CombatPhases[cycleId or "ground"]
end

function CombatPhases.getPhase(cycleId, index)
	local cycle = CombatPhases[cycleId or "ground"]
	if not cycle or #cycle == 0 then return nil end
	local i = ((index or 1) - 1) % #cycle + 1
	return cycle[i], i
end

function CombatPhases.next(cycleId, index)
	local cycle = CombatPhases[cycleId or "ground"]
	if not cycle or #cycle == 0 then return 1 end
	return ((index or 1)) % #cycle + 1
end

function CombatPhases.cycleLength(cycleId)
	local cycle = CombatPhases[cycleId or "ground"]
	return cycle and #cycle or 0
end

function CombatPhases.tagAffinity(phaseSpec, tags)
	if not phaseSpec or not phaseSpec.favoredTags then return 1 end
	if type(tags) ~= "table" then return 1 end
	local best = 1
	for _, tag in ipairs(tags) do
		local mult = phaseSpec.favoredTags[tag]
		if mult and mult > best then best = mult end
	end
	return best
end

return CombatPhases
