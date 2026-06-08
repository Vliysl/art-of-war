--!strict
-- Shared formula helpers used by both EconomySystem (server) and the UI
-- (EconomyWindow / ProvinceDetailPanel / ProvinceTooltip). Single source of
-- truth so client previews and server accumulation can never disagree.

local EconomyPreview = {}

local function policyMults(country, bundle)
	local taxMult, productionMult = 1, 1
	if country and bundle and bundle.economyPolicies and country.economyPolicy then
		local def = bundle.economyPolicies[country.economyPolicy]
		if def then
			taxMult = def.taxMult or 1
			productionMult = def.productionMult or 1
		end
	end
	return taxMult, productionMult
end

-- Unrest/autonomy reduction. Returns the [0..1] multiplier applied to base tax.
function EconomyPreview.taxLossMultiplier(province, wc)
	local autonomyMult = 1
	if wc and wc.AutonomyAffectsTax ~= false then
		autonomyMult = math.clamp(1 - (province.autonomy or 0), 0, 1)
	end
	local unrestPenalty = (wc and wc.UnrestTaxPenaltyPerPoint) or 0.05
	local unrestMult = math.clamp(1 - (province.unrest or 0) * unrestPenalty, 0, 1)
	return autonomyMult * unrestMult, autonomyMult, unrestMult
end

-- Daily tax for a single province, given the owning country's modifiers.
-- Formula: (population/1000) * devTier * TaxIncomePerThousand
--          * economyPolicy.taxMult * additiveStack * capitalBonus
--          * (1 - autonomy) * (1 - unrest * UnrestTaxPenaltyPerPoint)
function EconomyPreview.taxOf(province, country, wc, bundle, isCapital, addStack)
	if not province or not country then return 0 end
	if (province.devTier or 0) <= 0 then return 0 end
	if province.ownerTag ~= country.tag or province.controllerTag ~= country.tag then
		return 0
	end
	local pop = province.population or 0
	local devTier = province.devTier or 0
	local perThousand = (wc and wc.TaxIncomePerThousand) or 0.05
	local base = (pop / 1000) * devTier * perThousand
	local taxMult = select(1, policyMults(country, bundle))
	local stack = 1 + (addStack or 0)
	local capitalMult = isCapital and ((wc and wc.CapitalTaxMultiplier) or 1.25) or 1
	local lossMult = EconomyPreview.taxLossMultiplier(province, wc)
	return base * taxMult * stack * capitalMult * lossMult
end

-- Daily resource production for a single province. Reads province.goods (the
-- canonical multi-resource field) and falls back to province.tradeGood for
-- provinces that haven't been migrated yet. Returns { [goodId] = amount }.
function EconomyPreview.productionOf(province, country, wc, bundle, addStack)
	local out = {}
	if not province or not country then return out end
	if province.ownerTag ~= country.tag or province.controllerTag ~= country.tag then
		return out
	end
	if (province.devTier or 0) <= 0 then return out end

	local infra = province.infraTier or 0
	local infraScale = (wc and wc.ResourceInfraScalePerTier) or 0.1
	local _, productionMult = policyMults(country, bundle)
	local stack = 1 + (addStack or 0)
	local scale = (1 + infraScale * infra) * productionMult * stack

	local goods = province.goods
	if goods and next(goods) ~= nil then
		for goodId, baseAmount in goods do
			if baseAmount and baseAmount > 0 then
				out[goodId] = (out[goodId] or 0) + baseAmount * scale
			end
		end
	else
		-- Legacy fallback: pre-migration provinces still have only tradeGood.
		local goodId = province.tradeGood
		if goodId and goodId ~= "" and goodId ~= "none" then
			out[goodId] = (province.baseProduction or 0) * scale
		end
	end
	return out
end

-- Pretty list of "GoodName: X.X / day" pairs for tooltips. Returns string[].
function EconomyPreview.formatProductionList(production, bundle, max)
	local entries = {}
	for id, amount in production do
		table.insert(entries, { id = id, amount = amount or 0 })
	end
	table.sort(entries, function(a, b) return a.amount > b.amount end)
	local out = {}
	for i = 1, math.min(#entries, max or 4) do
		local e = entries[i]
		local def = bundle and bundle.tradeGoods and bundle.tradeGoods[e.id]
		local name = def and def.displayName or e.id
		table.insert(out, string.format("%s %.1f", name, e.amount))
	end
	return out
end

return EconomyPreview
