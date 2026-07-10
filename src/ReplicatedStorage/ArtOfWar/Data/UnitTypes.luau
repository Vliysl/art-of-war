-- Four ground unit types, each with a distinct battlefield function (see CombatEngine):
--   Irregular Infantry - cheap levy screen; rough-terrain specialist, weak in the open, breaks fast.
--   Line Infantry      - the durable anchor; high org holds the whole stack together in fire & shock.
--   Artillery          - glass cannon; huge fire-phase damage, almost no defense/org, must be screened.
--   Cavalry            - shock & mobility; fast operational movement, wins the open, useless in the rough.
-- Differentiation axes the engine actually reads: role (infantry/cavalry/artillery), combatWidth
-- (frontage + slot priority), organization (rout timer, averaged across the stack), discipline
-- (flat offense/defense + morale multiplier), terrainMods, speed (map movement), and phase tags.

local UnitTypes = {
	-- LEVY. The only unit recruitable without a Military district, so it stays the cheapest/default
	-- (AI + un-districted provinces raise it). Skirmisher tag => maneuver-phase king; irregular tag
	-- backs it up. Low combatWidth (1) => high slot priority, screens the front cheaply, but org 5 +
	-- discipline 0.7 mean it is ground down and routs first. Strong in rough terrain, penalised in the open.
	irregular_infantry = {
		id = "irregular_infantry",
		displayName = "Irregular Infantry",
		class = "levy",
		discipline = 0.7,
		attack = 7,
		defense = 8,
		speed = 1.25,
		upkeep = 0.06,
		recruitCost = 12,
		recruitManpower = 1000,
		recruitTicks = 6,
		organization = 5,
		combatWidth = 1,
		-- Terrain mods are large enough to actually overcome Line's 1.15/0.7 discipline edge (~1.64x) on
		-- rough ground; without this the "rough specialist" identity is only cosmetic and Line out-fights
		-- it everywhere. Open-terrain penalties keep it clearly the worse choice in the field.
		terrainMods = {
			forest = 0.30,
			jungle = 0.28,
			hills = 0.22,
			marsh = 0.18,
			mountain = 0.18,
			plains = -0.10,
			grassland = -0.05,
			farmland = -0.05,
		},
		tags = { "skirmisher", "irregular" },
		unlockedByDefault = true,
	},

	-- PROFESSIONAL backbone. Highest organization (11) => holds the line for the whole battle and props
	-- up stack org when brigaded with fragile artillery. Best infantry-role defense (13) blocks enemy
	-- infantry offense. line tag (fire) + melee tag (shock) => present and effective in both later phases.
	-- combatWidth 2 keeps it a solid front presence. Discipline 1.15 = the reliable regular.
	line_infantry = {
		id = "line_infantry",
		displayName = "Line Infantry",
		class = "professional",
		discipline = 1.15,
		attack = 11,
		defense = 13,
		speed = 1.0,
		upkeep = 0.32,
		requiresDistrict = "Military",
		recruitCost = 28,
		recruitManpower = 1000,
		recruitTicks = 14,
		organization = 11,
		combatWidth = 2,
		terrainMods = {
			grassland = 0.05,
			plains = 0.05,
			farmland = 0.05,
			hills = -0.05,
			forest = -0.10,
			marsh = -0.10,
			mountain = -0.15,
		},
		tags = { "melee", "line" },
		unlockedByDefault = true,
	},

	-- PROFESSIONAL glass cannon. High attack (16) with siege+ranged tags => fire-phase king (16*1.25 = 20,
	-- top damage in the game) and the premier unblocked-damage role (enemy artillery defense is ~nil). Kept
	-- at 16 (not higher) so cavalry still owns the shock phase and artillery stays a FIRE specialist rather
	-- than an all-phase threat. Paid for with defense 3 and organization 2.5: it routs almost immediately
	-- and its low org drags the whole stack's rout timer down.
	-- ENGINE CAVEAT: reserves do not fire and artillery has the lowest slot priority (cv), so an over-large
	-- cheap screen crowds the guns into reserve where they contribute nothing -- field artillery in focused
	-- combined-arms stacks under the combat width, not doomstacks. (A back-row-fire rule would fix this
	-- properly; see the combat notes.) combatWidth 3 => few fire per round; speed 0.6 => the slow siege
	-- train. Wants open ground, crippled in forest/mountain.
	artillery = {
		id = "artillery",
		displayName = "Artillery",
		class = "professional",
		discipline = 1.0,
		attack = 16,
		defense = 3,
		speed = 0.6,
		upkeep = 0.55,
		requiresDistrict = "Military",
		recruitCost = 60,
		recruitManpower = 400,
		recruitTicks = 22,
		organization = 2.5,
		combatWidth = 3,
		terrainMods = {
			plains = 0.10,
			farmland = 0.10,
			hills = 0.10,
			grassland = 0.05,
			marsh = -0.25,
			jungle = -0.30,
			forest = -0.30,
			mountain = -0.35,
		},
		tags = { "siege", "splash", "ranged" },
		unlockedByDefault = true,
	},

	-- PROFESSIONAL shock & maneuver arm. mounted tag => own role (must be answered by enemy cavalry or
	-- eat unblocked shock damage) + maneuver presence; shock tag => shock-phase king (1.25). Speed 1.7 =>
	-- the operational tool: flank, raid, and run down routed enemies. Attack 14 / defense 7 / org 7 =>
	-- hits hard but is a hammer, not an anvil (def 7 keeps it from doubling as a durable wall AND the top
	-- open-ground dealer). combatWidth 3 => fewer up front, spikes when its phase comes.
	-- Dominates open/steppe ground, badly penalised in forest/mountain/marsh.
	cavalry = {
		id = "cavalry",
		displayName = "Cavalry",
		class = "professional",
		discipline = 1.05,
		attack = 14,
		defense = 7,
		speed = 1.7,
		upkeep = 0.46,
		requiresDistrict = "Military",
		recruitCost = 42,
		recruitManpower = 600,
		recruitTicks = 18,
		organization = 7,
		combatWidth = 3,
		terrainMods = {
			steppe = 0.25,
			grassland = 0.20,
			plains = 0.15,
			farmland = 0.10,
			hills = -0.10,
			forest = -0.25,
			jungle = -0.30,
			mountain = -0.35,
			marsh = -0.30,
		},
		tags = { "shock", "mounted" },
		unlockedByDefault = true,
	},
}

for id, def in UnitTypes do
	def.id = id
end

return UnitTypes
