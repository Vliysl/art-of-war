-- Events — data-driven political event cards. The EventSystem fires one at a
-- time per country (country.activeEvent), the player picks an option, and its
-- `effects` are applied via the shared applyEffects resolver.
--
-- Schema (PoliticalEventDef): { id, title, body, category?, trigger?, govArchetype?,
--   cooldownDays?, weight?, deadlineDays?, options = { CountryEventOption } }
-- Option: { id, label, tooltip?, effects?, aiWeight?, isDefault? }
--
-- EffectEffects keys: authority, legitimacy, stability, unrest, politicalPower,
--   treasury (flat deltas) · estateLoyalty/estateInfluence maps keyed by faction id ·
--   grantPrivilege/revokePrivilege/enactPolicy/setIdeology/beginTransition/spawnRebellion/chainEvent.
--
-- Tokens: body/label/tooltip may contain %LEADER% (ruler/leader title+name),
--   %ESTATE% (the demanding estate's display name), %COUNTRY%. In estateLoyalty/
--   estateInfluence maps the special key "$estate" is replaced at resolve time
--   with the event's context estate (context.estateId).
--
-- trigger.type values understood by EventSystem (Phase 1+):
--   "estate_demand"       — fires when some estate's loyalty < trigger.loyaltyBelow
--   "random_opportunity"  — ambient draw on the per-country event clock
--   (more crisis/succession triggers are added in later phases)

return {
	-- ── Estate demand (the core loop driver) ─────────────────────────────────
	estate_demands_privilege = {
		id = "estate_demands_privilege",
		-- Playtest: the Estates UI was cut, so this orphaned estate-demand card fires about factions the player
		-- can no longer see, with effects (loyalty/authority) that have no visible readout. EventSystem skips
		-- defs flagged `disabled`. Re-enable when the Estates screen returns.
		disabled = true,
		title = "A Demand from the %ESTATE%",
		body = "The %ESTATE% grow restless and press the %LEADER% to confirm their ancient privileges. Concede, and they will be loyal but emboldened; refuse, and resentment will simmer.",
		category = "estate_demand",
		trigger = { type = "estate_demand", loyaltyBelow = 40 },
		cooldownDays = 180,
		deadlineDays = 60,
		weight = 1,
		options = {
			{
				id = "grant",
				label = "Grant their privileges",
				tooltip = "+Loyalty and +Influence for the estate, −Crown Authority.",
				effects = {
					estateLoyalty = { ["$estate"] = 18 },
					estateInfluence = { ["$estate"] = 0.03 },
					authority = -6,
				},
				aiWeight = 2,
				isDefault = true,
			},
			{
				id = "refuse",
				label = "Refuse them",
				tooltip = "−Loyalty and rising Unrest, but you keep (and gain) Authority.",
				effects = {
					estateLoyalty = { ["$estate"] = -12 },
					authority = 4,
					unrest = 5,
				},
				aiWeight = 1,
			},
			{
				id = "bribe",
				label = "Buy them off with gold",
				tooltip = "Spend from the treasury to keep the peace without conceding power.",
				effects = {
					estateLoyalty = { ["$estate"] = 8 },
					treasury = -50,
				},
				aiWeight = 1,
			},
		},
	},

	-- ── Enlightenment opportunity (teaching: reform pleases some, angers others) ──
	enlightenment_salon = {
		id = "enlightenment_salon",
		-- Playtest: references the cut Estates (clergy/philosophes) with no visible feedback -> disabled.
		disabled = true,
		title = "The Spirit of the Age",
		body = "Fashionable salons buzz with the new philosophy. The %LEADER% may patronise the philosophes and ride the tide of reason — at the cost of clerical goodwill.",
		category = "enlightenment",
		trigger = { type = "random_opportunity" },
		cooldownDays = 365,
		deadlineDays = 90,
		weight = 1,
		options = {
			{
				id = "embrace",
				label = "Patronise the philosophes",
				tooltip = "The philosophes warm to you; the clergy bristle.",
				effects = {
					estateLoyalty = { philosophes = 12, clergy = -8 },
					legitimacy = 3,
				},
				aiWeight = 1,
			},
			{
				id = "rebuke",
				label = "Stand with the Church",
				tooltip = "The clergy approve; the philosophes are disappointed.",
				effects = {
					estateLoyalty = { clergy = 8, philosophes = -8 },
					stability = 0,
				},
				aiWeight = 1,
				isDefault = true,
			},
		},
	},

	-- ── Flavor crisis (teaching: stability/loyalty vs. treasury) ─────────────
	bountiful_harvest = {
		id = "bountiful_harvest",
		title = "A Bountiful Harvest",
		body = "The granaries overflow this year. The %LEADER% may relieve the common folk, or fill the treasury against leaner times.",
		category = "crisis",
		trigger = { type = "random_opportunity" },
		cooldownDays = 365,
		deadlineDays = 90,
		weight = 1,
		options = {
			{
				id = "relieve",
				label = "Relieve the people",
				tooltip = "Lower unrest and win the peasantry's gratitude.",
				effects = {
					unrest = -8,
					estateLoyalty = { peasantry = 10 },
				},
				aiWeight = 1,
				isDefault = true,
			},
			{
				id = "tax",
				label = "Tax the surplus",
				tooltip = "A windfall for the treasury; the peasants grumble.",
				effects = {
					treasury = 80,
					estateLoyalty = { peasantry = -5 },
				},
				aiWeight = 1,
			},
		},
	},

	-- ── Succession (Phase 3) — fired on demand by RulerSystem, not ambiently ──
	regency_council = {
		id = "regency_council",
		title = "A Regency Council",
		body = "%LEADER% is too young to rule. A council of regents governs %COUNTRY% in their name until they come of age.",
		category = "dynasty",
		deadlineDays = 90,
		options = {
			{
				id = "trust",
				label = "Trust the regency council",
				tooltip = "Let the appointed regents govern; the realm settles.",
				effects = { legitimacy = 4 },
				aiWeight = 2,
				isDefault = true,
			},
			{
				id = "favourites",
				label = "Rule through court favourites",
				tooltip = "Seize the reins behind the throne \u{2014} more Authority, but resented.",
				effects = { authority = 8, legitimacy = -5 },
				aiWeight = 1,
			},
		},
	},
	disputed_succession = {
		id = "disputed_succession",
		title = "A Disputed Succession",
		body = "Rivals contest %LEADER%'s claim. Whispers of a pretender spread through the court, and %COUNTRY% grows uneasy.",
		category = "dynasty",
		deadlineDays = 90,
		options = {
			{
				id = "rally",
				label = "Rally the loyalists",
				tooltip = "Assert your right by force of will \u{2014} Authority up, but it costs goodwill.",
				effects = { authority = 8, legitimacy = -2 },
				aiWeight = 1,
				isDefault = true,
			},
			{
				id = "buyoff",
				label = "Buy off the magnates",
				tooltip = "Gold quiets the loudest claims.",
				effects = { treasury = -80, legitimacy = 6 },
				aiWeight = 1,
			},
		},
	},
}
