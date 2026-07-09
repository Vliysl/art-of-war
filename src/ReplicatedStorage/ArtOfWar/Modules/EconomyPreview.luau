--!strict
-- Shared formula helpers used by both EconomySystem (server) and the UI
-- (EconomyWindow / ProvinceDetailPanel / ProvinceTooltip). Single source of
-- truth so client previews and server accumulation can never disagree.

local DistrictTypes = require(script.Parent.Parent.Data.DistrictTypes)

local EconomyPreview = {}

-- Summed level of extraction districts in `province` that can produce `goodId` (0 if none, or the good is
-- not extractable). Used to gate + scale extraction under GateExtractionOnDistricts.
function EconomyPreview.extractionLevelFor(province, goodId)
	local want = DistrictTypes.extractionDistrictFor(goodId)
	if not want then
		return 0
	end
	local districts = province and province.districts
	if not districts then
		return 0
	end
	local sum = 0
	for _, d in pairs(districts) do
		if type(d) == "table" and d.type == want then
			sum += (d.level or 0)
		end
	end
	return sum
end

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

-- District tax helpers (economy rework). Tax is AUTHORED per /month in WorldConstants.DistrictBaseTax;
-- taxOf converts to the engine's daily unit so ×daysAdvanced accumulation lands the /mo figure exactly.
-- Diminishing per-level multiplier D(L) = (1 - g^L)/(1 - g); with g<1 it asymptotes at 1/(1-g).
function EconomyPreview.districtLevelMult(level, g)
	level = math.max(0, level or 0)
	if level <= 0 then
		return 0
	end
	g = g or 0.6
	if g >= 1 or g < 0 then
		return level
	end
	return (1 - g ^ level) / (1 - g)
end

function EconomyPreview.districtMonthlyTax(districtType, level, wc)
	local baseTable = wc and wc.DistrictBaseTax
	local base = baseTable and baseTable[districtType]
	if not base or base <= 0 then
		return 0
	end
	return base * EconomyPreview.districtLevelMult(level, wc and wc.DistrictLevelDiminish)
end

-- Total MONTHLY tax from a province's districts (slot-indexed array; pairs() tolerates empty-slot holes).
function EconomyPreview.districtTaxOf(province, wc)
	local districts = province and province.districts
	if not districts then
		return 0
	end
	local sum = 0
	for _, d in pairs(districts) do
		if type(d) == "table" and d.type then
			sum += EconomyPreview.districtMonthlyTax(d.type, d.level or 0, wc)
		end
	end
	return sum
end

-- Daily tax for a single province, given the owning country's modifiers.
-- DistrictTax OFF (legacy): (population/1000) * devTier * TaxIncomePerThousand.
-- DistrictTax ON: (Σ district monthly tax + capital innate) / DaysPerMonth  (district-driven, no population).
-- Both then × economyPolicy.taxMult × additiveStack × capitalBonus × (1-autonomy) × (1-unrest*penalty).
function EconomyPreview.taxOf(province, country, wc, bundle, isCapital, addStack)
	if not province or not country then
		return 0
	end
	if province.ownerTag ~= country.tag or province.controllerTag ~= country.tag then
		return 0
	end

	local base
	if wc and wc.DistrictTax then
		local daysPerMonth = wc.DaysPerMonth or 30
		local monthly = EconomyPreview.districtTaxOf(province, wc)
		if isCapital then
			monthly += (wc.CapitalInnateTax or 0)
		end
		base = monthly / daysPerMonth
	else
		if (province.devTier or 0) <= 0 then
			return 0
		end
		local pop = province.population or 0
		local devTier = province.devTier or 0
		local perThousand = (wc and wc.TaxIncomePerThousand) or 0.05
		base = (pop / 1000) * devTier * perThousand
	end

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
	if not province or not country then
		return out
	end
	if province.ownerTag ~= country.tag or province.controllerTag ~= country.tag then
		return out
	end
	if (province.devTier or 0) <= 0 then
		return out
	end

	local infra = province.infraTier or 0
	local infraScale = (wc and wc.ResourceInfraScalePerTier) or 0.1
	local _, productionMult = policyMults(country, bundle)
	local stack = 1 + (addStack or 0)
	local scale = (1 + infraScale * infra) * productionMult * stack

	-- GateExtractionOnDistricts: a good is produced ONLY if the province hosts a matching extraction
	-- district (level >= 1), and the amount scales with that district level instead of infraTier.
	local gate = wc and wc.GateExtractionOnDistricts
	local levelBonusPer = (wc and wc.DistrictExtractionLevelBonus) or 0.25
	local function emit(goodId, baseAmount)
		if not (baseAmount and baseAmount > 0) then
			return
		end
		if gate then
			local exLevel = EconomyPreview.extractionLevelFor(province, goodId)
			if exLevel <= 0 then
				return -- no matching extraction district -> no output
			end
			local districtScale = (1 + levelBonusPer * (exLevel - 1)) * productionMult * stack
			out[goodId] = (out[goodId] or 0) + baseAmount * districtScale
		else
			out[goodId] = (out[goodId] or 0) + baseAmount * scale
		end
	end

	local goods = province.goods
	if goods and next(goods) ~= nil then
		for goodId, baseAmount in goods do
			emit(goodId, baseAmount)
		end
	else
		-- Legacy fallback: pre-migration provinces still have only tradeGood.
		local goodId = province.tradeGood
		if goodId and goodId ~= "" and goodId ~= "none" then
			emit(goodId, province.baseProduction or 0)
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
	table.sort(entries, function(a, b)
		return a.amount > b.amount
	end)
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
