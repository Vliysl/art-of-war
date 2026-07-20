-- TechDomains: the single registry of every technology modifier key, its cap, and how it folds.
--
-- Authoring a tech `effects[level].modifiers` key that is NOT listed here means the buff reaches no consumer
-- (the "name-mismatch trap" the economy already fell into: it reads country_tax_income while data authored
-- tax_income). ResearchSystem aggregates ONLY the keys defined here; anything else is inert-by-design.
--
-- mult = true  -> the tech factor is the MULTIPLICATIVE product of per-level (1 + bonus), clamped to [1, cap]
--                 (cap is a MAX MULTIPLIER, e.g. 3x). Read via ResearchSystem.factor(tag, key). Used by the
--                 per-unit-class combat buffs (infantry/cavalry/artillery/ship) applied in BattleManager/NavalSystem.
-- mult = false -> the tech bonus is the ADDITIVE SUM of per-level bonus, clamped to [0, cap] (cap is a MAX
--                 FRACTION, e.g. 0.30). Read via ResearchSystem.bonus(tag, key); each economy/political consumer
--                 applies it as (1 +/- capped). Also folded into ModifierStack.resolveAdditive for army-wide/economy
--                 domains that already have consumers.
--
-- capKey names a field on the merged WorldConstants table (shared + WorldConstantsServer); the cap is resolved
-- at runtime so tuning lives in one place. Missing capKey -> default (3 for mult, uncapped for additive).

local TechDomains = {}

local D = {
	-- ── Land per-unit-class combat (multiplicative, 3x) ──
	infantry_attack = { mult = true, capKey = "MultiplierCapTechPerBranch" },
	infantry_defense = { mult = true, capKey = "MultiplierCapTechPerBranch" },
	infantry_speed = { mult = true, capKey = "MultiplierCapTechPerBranch" },
	cavalry_attack = { mult = true, capKey = "MultiplierCapTechPerBranch" },
	cavalry_defense = { mult = true, capKey = "MultiplierCapTechPerBranch" },
	cavalry_speed = { mult = true, capKey = "MultiplierCapTechPerBranch" },

	-- ── Artillery sub-stats (multiplicative, 2x) ──
	artillery_attack = { mult = true, capKey = "MultiplierCapArtillerySubStat" },
	artillery_defense = { mult = true, capKey = "MultiplierCapArtillerySubStat" },
	artillery_range = { mult = true, capKey = "MultiplierCapArtillerySubStat" },
	artillery_speed = { mult = true, capKey = "MultiplierCapArtillerySubStat" },

	-- ── Naval (multiplicative; authored low = "nerfed RON", shares the 3x branch cap as a ceiling) ──
	ship_attack = { mult = true, capKey = "MultiplierCapTechPerBranch" },
	ship_defense = { mult = true, capKey = "MultiplierCapTechPerBranch" },
	ship_speed = { mult = true, capKey = "MultiplierCapTechPerBranch" },

	-- ── Economy (additive fraction) ──
	factory_output = { capKey = "TechCapFactoryOutput" },
	government_spending_reduction = { capKey = "TechCapGovSpend" },
	fuel_efficiency = { capKey = "TechCapFuel" },
	mining_output = { capKey = "TechCapMining" },
	building_cost_reduction = { capKey = "TechCapBuildingCost" },
	building_speed = { capKey = "TechCapBuildingSpeed" },
	country_tax_income = { capKey = "TechCapTaxIncome" }, -- exact key EconomySystem reads (do NOT rename to tax_income)

	-- ── Command / military training (additive; army-WIDE, folds into ModifierStack; BattleManager/MovementSystem
	--    already read these domains and re-clamp at MultiplierCapCombatStat, so this is the whole-army buff, distinct
	--    from the per-unit-class infantry_/cavalry_ multipliers above) ──
	army_attack = { capKey = "MultiplierCapCombatStat" },
	army_defense = { capKey = "MultiplierCapCombatStat" },
	army_movement_speed = { capKey = "MultiplierCapCombatStat" },

	-- ── Political (additive fraction) ──
	political_power_gain = { capKey = "TechCapPPGain" },
	policy_efficiency = { capKey = "TechCapPolicyEff" },
	unrest_reduction = { capKey = "TechCapUnrestReduction" },
	unrest_build_reduction = { capKey = "TechCapUnrestBuild" },
	base_stability = { capKey = "TechCapStability" }, -- Phase 2 consumer (stability drift tick)
	integration_speed = { capKey = "TechCapIntegration" }, -- Phase 2 consumer (integration timer)
	fort_defense = { capKey = "TechCapFortDefense" }, -- Phase 2 consumer (CapitalSystem/BattleManager.fortTierFor)
	doctrine_cost_reduction = { capKey = "TechCapDoctrineCost" },

	-- ── Research (additive fraction) ──
	research_efficiency = { capKey = "TechCapResearchEfficiency" }, -- reduces per-level cost
	research_power_gain = { capKey = "TechCapResearchPower" }, -- multiplies slot accrual rate
}

TechDomains.defs = D

function TechDomains.isKnown(domain)
	return D[domain] ~= nil
end

function TechDomains.isMultiplicative(domain)
	local d = D[domain]
	return d ~= nil and d.mult == true
end

-- Resolve a domain's cap against a WorldConstants table. Multiplicative domains default to 3 (per-branch);
-- additive domains default to math.huge (effectively uncapped) if unregistered or the capKey is missing.
function TechDomains.capFor(domain, worldConstants)
	local d = D[domain]
	if not d then
		return math.huge
	end
	local cap = worldConstants and d.capKey and worldConstants[d.capKey]
	if type(cap) == "number" then
		return cap
	end
	return d.mult and 3 or math.huge
end

return TechDomains
