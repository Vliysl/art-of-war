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
		damageMultiplier = 0.4,
		moraleMultiplier = 1.15,
		entrenchAccrual = 0.05,
		favoredTags = {
			skirmisher = 1.30,
			light = 1.20,
			cavalry = 1.15,
			scout = 1.25,
		},
	}),
	phase({
		id = "fire",
		displayName = "Fire",
		duration = 3,
		damageMultiplier = 1.00,
		moraleMultiplier = 0.90,
		entrenchAccrual = 0,
		favoredTags = {
			ranged = 1.30,
			artillery = 1.40,
			line = 1.10,
		},
	}),
	phase({
		id = "shock",
		displayName = "Shock",
		duration = 2,
		damageMultiplier = 1.20,
		moraleMultiplier = 0.85,
		entrenchAccrual = -0.20,
		favoredTags = {
			cavalry = 1.50,
			shock = 1.40,
			melee = 1.30,
		},
	}),
	phase({
		id = "aftermath",
		displayName = "Aftermath",
		duration = 1,
		damageMultiplier = 0.30,
		moraleMultiplier = 1.40,
		entrenchAccrual = 0.10,
		favoredTags = {},
	}),
}

CombatPhases.naval = {
	phase({
		id = "approach",
		displayName = "Approach",
		duration = 1,
		damageMultiplier = 0.30,
		moraleMultiplier = 1.10,
		favoredTags = {
			fast = 1.30,
			frigate = 1.20,
			scout = 1.25,
		},
	}),
	phase({
		id = "broadside",
		displayName = "Broadside",
		duration = 4,
		damageMultiplier = 1.20,
		moraleMultiplier = 0.85,
		favoredTags = {
			capital = 1.40,
			heavy = 1.30,
			ship_of_the_line = 1.35,
		},
	}),
	phase({
		id = "boarding",
		displayName = "Boarding",
		duration = 1,
		damageMultiplier = 0.60,
		moraleMultiplier = 0.80,
		favoredTags = {
			marines = 1.50,
			transport = 1.20,
			melee = 1.20,
		},
	}),
	phase({
		id = "withdrawal",
		displayName = "Withdrawal",
		duration = 1,
		damageMultiplier = 0.20,
		moraleMultiplier = 1.40,
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
