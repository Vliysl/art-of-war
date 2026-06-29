-- Privileges — the active estate tradeoff. Granting a privilege gives the nation
-- an ongoing bonus (grantBonus, folded through ModifierStack like a policy) but
-- raises that estate's Influence (clout) and Loyalty while LOWERING the Crown
-- Authority cap (authorityCap, always <= 0). Revoking reverses loyalty/authority.
--
-- estateId must match a faction id in Factions.luau:
--   clergy · burghers · guilds · officer_corps · peasantry · colonial_merchants · philosophes
-- (the "crown" estate is the player and is never granted privileges).
--
-- Optional gates (ideologyGate / govGate / archetypeGate) restrict availability;
-- left nil here so the base set works for every government. Domains reuse the
-- same ModifierDomain strings as GovernmentTypes/Ideologies/Policies so the
-- bonuses actually take effect.

return {
	-- ── Clergy ──────────────────────────────────────────────────────────────
	clergy_religious_sanction = {
		id = "clergy_religious_sanction",
		displayName = "Religious Sanction",
		estateId = "clergy",
		grantBonus = { unrest_reduction = 0.15, base_stability = 0.05 },
		influenceGain = 0.05,
		authorityCap = -10,
		loyaltyGain = 15,
		description = "The Church blesses your reign from every pulpit — the faithful keep the peace, but the mitre answers to itself.",
	},
	clergy_tithe_rights = {
		id = "clergy_tithe_rights",
		displayName = "Tithe Collection Rights",
		estateId = "clergy",
		grantBonus = { tax_income = 0.08 },
		influenceGain = 0.05,
		authorityCap = -8,
		loyaltyGain = 12,
		description = "Let the clergy gather the tithe and a share flows to the treasury — at the price of a richer, prouder Church.",
	},

	-- ── Burghers ────────────────────────────────────────────────────────────
	burghers_town_charters = {
		id = "burghers_town_charters",
		displayName = "Town Charters",
		estateId = "burghers",
		grantBonus = { tax_income = 0.08, trade_efficiency = 0.10 },
		influenceGain = 0.06,
		authorityCap = -10,
		loyaltyGain = 14,
		description = "Chartered towns govern their own markets — commerce flourishes while the burghers guard their liberties jealously.",
	},
	burghers_civic_autonomy = {
		id = "burghers_civic_autonomy",
		displayName = "Civic Autonomy",
		estateId = "burghers",
		grantBonus = { investment_cost = -0.10, unrest_reduction = 0.05 },
		influenceGain = 0.05,
		authorityCap = -8,
		loyaltyGain = 10,
		description = "City magistrates run their own affairs — cheaper to build up, harder for the crown to overrule.",
	},

	-- ── Guilds ──────────────────────────────────────────────────────────────
	guilds_charter_monopoly = {
		id = "guilds_charter_monopoly",
		displayName = "Guild Monopolies",
		estateId = "guilds",
		grantBonus = { manufactory_output = 0.12 },
		influenceGain = 0.05,
		authorityCap = -8,
		loyaltyGain = 12,
		description = "Masters of the guild hold exclusive trades — fine workshops, but no upstart may compete.",
	},
	guilds_apprentice_statutes = {
		id = "guilds_apprentice_statutes",
		displayName = "Apprentice Statutes",
		estateId = "guilds",
		grantBonus = { building_speed = 0.10 },
		influenceGain = 0.04,
		authorityCap = -6,
		loyaltyGain = 10,
		description = "Sworn apprenticeships keep skilled hands plentiful and the builders busy.",
	},

	-- ── Officer Corps ───────────────────────────────────────────────────────
	officer_commissions = {
		id = "officer_commissions",
		displayName = "Officer Commissions",
		estateId = "officer_corps",
		grantBonus = { military_upkeep = -0.15 },
		influenceGain = 0.06,
		authorityCap = -10,
		loyaltyGain = 15,
		description = "Commissions sold and held for life bind the officer corps to your colours — and to their own privileges.",
	},
	officer_standing_regiments = {
		id = "officer_standing_regiments",
		displayName = "Standing Regiments",
		estateId = "officer_corps",
		grantBonus = { manpower_increase = 0.10, reinforcement_cost = -0.10 },
		influenceGain = 0.05,
		authorityCap = -8,
		loyaltyGain = 12,
		description = "Permanent regiments under their own colonels — a deeper manpower pool, in soldierly hands.",
	},

	-- ── Peasantry ───────────────────────────────────────────────────────────
	peasantry_common_rights = {
		id = "peasantry_common_rights",
		displayName = "Common Grazing Rights",
		estateId = "peasantry",
		grantBonus = { unrest_reduction = 0.12 },
		influenceGain = 0.04,
		authorityCap = -6,
		loyaltyGain = 12,
		description = "Guarantee the commons their fields and the countryside stays quiet.",
	},
	peasantry_militia_levy = {
		id = "peasantry_militia_levy",
		displayName = "Peasant Levy",
		estateId = "peasantry",
		grantBonus = { manpower_increase = 0.15 },
		influenceGain = 0.05,
		authorityCap = -8,
		loyaltyGain = 12,
		description = "Call up the village levies in time of war — vast numbers, if you keep the peasants content.",
	},

	-- ── Colonial Merchants ──────────────────────────────────────────────────
	colonial_trade_charters = {
		id = "colonial_trade_charters",
		displayName = "Trade Company Charters",
		estateId = "colonial_merchants",
		grantBonus = { trade_efficiency = 0.15 },
		influenceGain = 0.05,
		authorityCap = -8,
		loyaltyGain = 13,
		description = "Grant the great companies their charters and the wealth of distant coasts flows home.",
	},
	colonial_company_monopoly = {
		id = "colonial_company_monopoly",
		displayName = "Company Monopoly",
		estateId = "colonial_merchants",
		grantBonus = { tax_income = 0.10, naval_power = 0.05 },
		influenceGain = 0.06,
		authorityCap = -10,
		loyaltyGain = 14,
		description = "A monopoly on the colonial trade — golden revenues and a private fleet, beyond the crown's full reach.",
	},

	-- ── Philosophes ─────────────────────────────────────────────────────────
	philosophes_academy_patronage = {
		id = "philosophes_academy_patronage",
		displayName = "Academy Patronage",
		estateId = "philosophes",
		grantBonus = { research_output = 0.15 },
		influenceGain = 0.04,
		authorityCap = -6,
		loyaltyGain = 14,
		description = "Found royal academies and salons — the age of reason advances under your name.",
	},
	philosophes_salon_freedoms = {
		id = "philosophes_salon_freedoms",
		displayName = "Salon Freedoms",
		estateId = "philosophes",
		grantBonus = { research_output = 0.08, unrest_reduction = 0.05 },
		influenceGain = 0.05,
		authorityCap = -8,
		loyaltyGain = 12,
		description = "Let the salons debate freely — ideas flourish, though not always ideas the crown would choose.",
	},
}
