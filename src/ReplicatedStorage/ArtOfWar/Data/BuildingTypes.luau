local Manufactories = require(script.Parent.Manufactories)
local BuildingTypes = {
	marketplace = {
		displayName = "Marketplace",
		description = "Stalls, exchanges, and accountants. Provincial trade revenue rises and goods move faster.",
		category = "economic",
		cost = 100,
		buildDays = 90,
		infraRequirement = 1,
		modifiers = {
			province_trade_value = 0.25,
			province_tax = 0.05,
		},
	},
	workshop = {
		displayName = "Workshop",
		description = "Master craftsmen organise production. Goods leave the gates faster and at higher quality.",
		category = "economic",
		cost = 120,
		buildDays = 100,
		infraRequirement = 1,
		modifiers = {
			province_production = 0.20,
		},
	},
	granary = {
		displayName = "Granary",
		description = "Stored harvests sustain the population through winters and lean years. Manpower regenerates faster.",
		category = "economic",
		cost = 80,
		buildDays = 75,
		infraRequirement = 1,
		modifiers = {
			province_manpower_regen = 0.20,
		},
	},
	tax_office = {
		displayName = "Tax Office",
		description = "Imperial collectors and a registry of households. The treasury fills more reliably.",
		category = "economic",
		cost = 140,
		buildDays = 110,
		infraRequirement = 2,
		modifiers = {
			province_tax = 0.20,
		},
	},
	barracks = {
		displayName = "Barracks",
		description = "Permanent quarters and a parade ground. Recruits arrive sooner and trained better.",
		category = "military",
		cost = 150,
		buildDays = 120,
		infraRequirement = 2,
		modifiers = {
			province_recruit_speed = 0.25,
			province_unit_starting_experience = 0.10,
		},
	},
	walls = {
		displayName = "Expand Fortifications",
		description = "Stone curtain walls and gate towers. The town becomes harder to assault and slower to siege.",
		category = "military",
		cost = 30,
		buildDays = 100,
		infraRequirement = 1,
		repeatable = true,
		grantsFortTier = 1,
		modifiers = {
			province_fort_defense = 0.25,
		},
	},
	fortress = {
		displayName = "Fortress",
		description = "Bastions, ravelins, and glacis in the trace italienne. A modern fortress holds for months.",
		category = "military",
		cost = 60,
		buildDays = 150,
		infraRequirement = 3,
		grantsFortTier = 2,
		requires = { "walls" },
		modifiers = {
			province_fort_defense = 0.50,
			province_garrison_size = 0.25,
		},
	},
	stables = {
		displayName = "Stables",
		description = "Pasture, breaking yards, and a remount depot. Cavalry are cheaper to raise and quicker on campaign.",
		category = "military",
		cost = 160,
		buildDays = 110,
		infraRequirement = 2,
		modifiers = {
			province_cavalry_recruit_cost = -0.15,
			province_cavalry_speed = 0.10,
		},
	},
	trading_port = {
		displayName = "Trading Port",
		description = "Bonded warehouses, customs, and a deep-water mole. Coastal commerce flourishes.",
		category = "economic",
		cost = 220,
		buildDays = 150,
		infraRequirement = 2,
		requiresCoastal = true,
		modifiers = {
			province_trade_value = 0.40,
		},
	},
	shipyard = {
		displayName = "Naval Shipyard",
		description = "Slipways, drydocks, and a rope walk. The province can build and refit ships of war.",
		category = "military",
		cost = 60,
		buildDays = 150,
		infraRequirement = 3,
		requiresCoastal = true,
		grantsShipyard = true,
		modifiers = {
			province_ship_build_speed = 0.15,
		},
	},
	university = {
		displayName = "University",
		description = "Scholars, libraries, a press. Research compounds across the realm.",
		category = "cultural",
		cost = 45,
		buildDays = 150,
		infraRequirement = 3,
		modifiers = {
			country_research_speed = 0.05,
		},
	},
	develop_province = {
		displayName = "Develop Province",
		description = "Schools, courts, civic works. Raises Development Tier by 1.",
		category = "economic",
		cost = 50,
		buildDays = 120,
		infraRequirement = 0,
		repeatable = true,
		grantsDevTier = 1,
	},
	improve_infrastructure = {
		displayName = "Improve Infrastructure",
		description = "Roads, bridges, surveys. Raises Infrastructure Tier by 1.",
		category = "economic",
		cost = 40,
		buildDays = 90,
		infraRequirement = 0,
		repeatable = true,
		grantsInfraTier = 1,
	},
}

-- Synthesize a building entry for each manufactory in Data.Manufactories so the
-- shared BuildingSystem can construct + track them like any other building. Uses
-- a "manufactory_" prefix so the IDs are stable and easy to filter on.
for mid, mdef in Manufactories do
	if mdef.unlockedByDefault ~= false then
		local outName = mdef.output and mdef.output:gsub("_", " ") or "goods"
		BuildingTypes["manufactory_" .. mid] = {
			displayName = mdef.displayName or mid,
			description = string.format(
				"Industrial workshop. Produces %s daily once supplied with raw inputs.",
				outName
			),
			category = "industry",
			cost = 120,
			buildDays = 80,
			infraRequirement = mdef.minInfraTier or 0,
			manufactoryId = mid,
			researchGate = mdef.researchGate,
		}
	end
end

for id, def in BuildingTypes do
	def.id = id
end

return BuildingTypes
