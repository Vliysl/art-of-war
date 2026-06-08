local NavalMissions = {}

NavalMissions.types = {
	patrol = {
		id = "patrol",
		displayName = "Patrol",
		description = "Watch a sea zone for hostile activity.",
		engageHostile = true,
		blockTradeOfTarget = false,
		raidEconomy = false,
		moraleDrainPerTick = 0,
		treasuryEffectPerTick = 0,
		minDuration = 0,
		requiresAdjacentTarget = false,
	},
	blockade = {
		id = "blockade",
		displayName = "Blockade",
		description = "Suffocate a coastal province's trade and bleed its treasury.",
		engageHostile = true,
		blockTradeOfTarget = true,
		raidEconomy = false,
		moraleDrainPerTick = 0.5,
		treasuryEffectPerTick = -1.5,
		treasuryEffectGoesToMission = false,
		minDuration = 3,
		requiresAdjacentTarget = true,
	},
	raid = {
		id = "raid",
		displayName = "Raid Trade",
		description = "Plunder merchant shipping for treasury at the cost of relations.",
		engageHostile = true,
		blockTradeOfTarget = false,
		raidEconomy = true,
		moraleDrainPerTick = 0.4,
		treasuryEffectPerTick = -1.0,
		treasuryEffectGoesToMission = true,
		infamyPerTick = 0.05,
		minDuration = 2,
		requiresAdjacentTarget = false,
	},
	transport = {
		id = "transport",
		displayName = "Transport",
		description = "Ferry friendly armies between coastal provinces.",
		engageHostile = false,
		blockTradeOfTarget = false,
		raidEconomy = false,
		moraleDrainPerTick = 0,
		treasuryEffectPerTick = 0,
		minDuration = 0,
		requiresAdjacentTarget = false,
		requiresPaired = true,
	},
	escort = {
		id = "escort",
		displayName = "Escort",
		description = "Protect a friendly fleet from interception.",
		engageHostile = true,
		blockTradeOfTarget = false,
		raidEconomy = false,
		moraleDrainPerTick = 0.1,
		treasuryEffectPerTick = 0,
		minDuration = 0,
		requiresAdjacentTarget = false,
		requiresPaired = true,
	},
	intercept = {
		id = "intercept",
		displayName = "Intercept",
		description = "Hunt down a specific hostile fleet.",
		engageHostile = true,
		blockTradeOfTarget = false,
		raidEconomy = false,
		moraleDrainPerTick = 0.2,
		treasuryEffectPerTick = 0,
		minDuration = 1,
		requiresAdjacentTarget = false,
		requiresTargetFleet = true,
	},
}

function NavalMissions.get(typeId)
	return NavalMissions.types[typeId]
end

function NavalMissions.allowed()
	local out = {}
	for id in pairs(NavalMissions.types) do table.insert(out, id) end
	return out
end

return NavalMissions
