--!strict
-- EconomySystem: per-day budget engine with pluggable income/expense providers.
-- Built-ins: tax_income, exports, army_upkeep, government_spending, imports.
-- Other systems can EconomySystem.registerIncomeProvider("manufactory_sales", fn)
-- and have it auto-summed and replicated as part of the country budget.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Modules")
local EconomyPreview = require(Modules:WaitForChild("EconomyPreview"))

local EconomySystem = {}

local ctx
local incomeProviders = {}    -- [id] = function(country, ctx, daysAdvanced) -> daily number
local expenseProviders = {}   -- [id] = function(country, ctx, daysAdvanced) -> daily number
local providerOrder = { income = {}, expense = {} }

local cachedDailyTax = {}
local cachedDailyProduction = {}
local upkeepByOwner = {}    -- S2: per-owner army upkeep, rebuilt once per applyDays (was O(countries x armies))

local function ensureCountryFields(country)
	country.stockpiles = country.stockpiles or {}
	country.dailyProduction = country.dailyProduction or {}
	country.dailyConsumption = country.dailyConsumption or {}
	country.incomeBreakdown = country.incomeBreakdown or {}
	country.expenseBreakdown = country.expenseBreakdown or {}
	country.totalIncome = country.totalIncome or 0
	country.totalExpenses = country.totalExpenses or 0
	return country
end

local function isCapital(country, province)
	return country.capitalProvinceId == province.id
end

local function recomputeProductionFor(tag)
	local country = ctx.WorldState.getCountry(tag)
	if not country then
		cachedDailyTax[tag] = 0
		cachedDailyProduction[tag] = {}
		return 0, {}
	end
	ensureCountryFields(country)

	local taxAdd = ctx.ModifierStack and ctx.ModifierStack.resolveAdditive
		and ctx.ModifierStack.resolveAdditive(tag, "country_tax_income") or 0
	local prodAdd = ctx.ModifierStack and ctx.ModifierStack.resolveAdditive
		and ctx.ModifierStack.resolveAdditive(tag, "country_production") or 0

	local provinceIds = (ctx.ProvinceRegistry and ctx.ProvinceRegistry.byOwner(tag)) or {}
	local dailyTax = 0
	local dailyProduction = {}
	for _, pid in provinceIds do
		local province = ctx.WorldState.getProvince(pid)
		if province then
			local cap = isCapital(country, province)
			dailyTax += EconomyPreview.taxOf(province, country, ctx.WorldConstants, ctx.Bundle, cap, taxAdd)
			local prod = EconomyPreview.productionOf(province, country, ctx.WorldConstants, ctx.Bundle, prodAdd)
			for goodId, amount in prod do
				dailyProduction[goodId] = (dailyProduction[goodId] or 0) + amount
			end
		end
	end

	cachedDailyTax[tag] = dailyTax
	cachedDailyProduction[tag] = dailyProduction
	country.dailyProduction = table.clone(dailyProduction)  -- S1: keep cache pure (Manufactory merges into country copy)
	ctx.WorldState.setCountry(tag, country)
	return dailyTax, dailyProduction
end

-- Built-in providers ----------------------------------------------------------

-- High unrest suppresses tax collection. (UnrestTaxPenaltyPerPoint was declared in WorldConstants
-- but never read until now — this is what gives unrest its economic teeth.)
local function unrestTaxFactor(country)
	local unrest = (country and country.unrest) or 0
	local penalty = math.clamp(unrest * (ctx.WorldConstants.UnrestTaxPenaltyPerPoint or 0), 0, 1)
	return 1 - penalty
end

local function provider_taxIncome(country, _ctx, _days)
	return (cachedDailyTax[country.tag] or 0) * unrestTaxFactor(country)
end

local function provider_exports(country, _ctx, _days)
	-- Placeholder: future MarketSystem-driven export sales.
	return 0
end

local function provider_armyUpkeep(country, _c, _days)
	-- S2: read the per-owner total built in one O(armies) pass in applyDays, instead of
	-- scanning ALL armies for every country (was O(countries x armies) every tick).
	return upkeepByOwner[country.tag] or 0
end

local function provider_governmentSpending(country, c, _days)
	-- Placeholder for fixed admin costs by government type. Returns 0 today.
	return 0
end

local function provider_imports(country, _c, _days)
	-- Placeholder: future MarketSystem-driven foreign purchases.
	return 0
end

-- Registry --------------------------------------------------------------------

local function registerIncomeProvider(id, fn)
	if not incomeProviders[id] then
		table.insert(providerOrder.income, id)
	end
	incomeProviders[id] = fn
end

local function registerExpenseProvider(id, fn)
	if not expenseProviders[id] then
		table.insert(providerOrder.expense, id)
	end
	expenseProviders[id] = fn
end

local function unregisterIncomeProvider(id)
	incomeProviders[id] = nil
	for i, k in ipairs(providerOrder.income) do
		if k == id then table.remove(providerOrder.income, i); break end
	end
end

local function unregisterExpenseProvider(id)
	expenseProviders[id] = nil
	for i, k in ipairs(providerOrder.expense) do
		if k == id then table.remove(providerOrder.expense, i); break end
	end
end

-- Daily accumulation ----------------------------------------------------------

local function applyDays(daysAdvanced)
	if not daysAdvanced or daysAdvanced <= 0 then return end
	local daysPerMonth = (ctx.WorldConstants and ctx.WorldConstants.DaysPerMonth) or 30

	-- S2: build per-owner army upkeep in ONE O(armies) pass (was an O(countries x armies)
	-- scan run inside provider_armyUpkeep for every country, every tick).
	table.clear(upkeepByOwner)
	do
		local mult = (ctx.WorldConstants and ctx.WorldConstants.ArmyUpkeepBaseMultiplier) or 0.1
		local unitTypes = (ctx.Bundle and ctx.Bundle.unitTypes) or {}
		for _, army in ctx.WorldState.allArmies() do
			if army.ownerTag and army.composition then
				local sum = 0
				for unitTypeId, count in army.composition do
					local def = unitTypes[unitTypeId]
					if def and def.upkeep and count and count > 0 then
						sum += def.upkeep * count * mult
					end
				end
				if sum ~= 0 then
					upkeepByOwner[army.ownerTag] = (upkeepByOwner[army.ownerTag] or 0) + sum
				end
			end
		end
	end

	-- S3: only simulate player-relevant countries (claimed / at-war); others are frozen.
	local relevant = ctx.PlayerAuthority and ctx.PlayerAuthority.relevantSet and ctx.PlayerAuthority.relevantSet() or nil
	for tag, _ in ctx.WorldState.allCountries() do
		local country = ctx.WorldState.getCountry(tag)
		if country and (not relevant or relevant[tag]) then
			ensureCountryFields(country)
			-- S1: use cached province tax/production (recomputed lazily only on province
			-- mutation, via onProvinceMutated) instead of recomputing every country's
			-- provinces from scratch every tick. dailyProductionOf() also warms cachedDailyTax
			-- for provider_taxIncome. `prod` is the PURE province-output cache (read-only here).
			if cachedDailyProduction[tag] == nil then recomputeProductionFor(tag) end
			local prod = cachedDailyProduction[tag] or {}

			-- Sum income / expense providers
			local totalIncome = 0
			local incomeBreakdown = {}
			for _, id in ipairs(providerOrder.income) do
				local fn = incomeProviders[id]
				local amount = 0
				if fn then
					local ok, result = pcall(fn, country, ctx, daysAdvanced)
					if ok and type(result) == "number" then amount = result end
				end
				incomeBreakdown[id] = amount
				totalIncome += amount
			end

			local totalExpenses = 0
			local expenseBreakdown = {}
			for _, id in ipairs(providerOrder.expense) do
				local fn = expenseProviders[id]
				local amount = 0
				if fn then
					local ok, result = pcall(fn, country, ctx, daysAdvanced)
					if ok and type(result) == "number" then amount = result end
				end
				expenseBreakdown[id] = amount
				totalExpenses += amount
			end

			local netDaily = totalIncome - totalExpenses

			-- S1 guard: a country with no income, no expenses and no production has nothing to
			-- update this tick -- skip the write + replication. (Active countries still write
			-- every tick; relevance-gating of idle AI is S3.)
			if totalIncome ~= 0 or totalExpenses ~= 0 or next(prod) ~= nil then
				country.totalIncome = totalIncome
				country.totalExpenses = totalExpenses
				country.incomeBreakdown = incomeBreakdown
				country.expenseBreakdown = expenseBreakdown
				country.lastIncome = netDaily * daysPerMonth
				country.treasury = (country.treasury or 0) + netDaily * daysAdvanced

				-- Fresh clone of province output so the Manufactory merge below does not
				-- pollute the shared production cache.
				country.dailyProduction = table.clone(prod)
				for goodId, amount in country.dailyProduction do
					country.stockpiles[goodId] = (country.stockpiles[goodId] or 0) + amount * daysAdvanced
				end

				ctx.WorldState.setCountry(tag, country)
				if netDaily ~= 0 then
					ctx.EventBus.publish(ctx.Channels.CountryTreasuryChanged, {
						tag = tag,
						treasury = country.treasury,
						delta = netDaily * daysAdvanced,
					})
				end
			end
		end
	end

	-- Manufactories layer on top of province output: consume inputs from
	-- stockpiles, produce outputs into them, and merge into dailyProduction
	-- so the UI shows a combined daily total.
	if ctx.ManufactorySystem and ctx.ManufactorySystem.applyDays then
		local ok, err = pcall(ctx.ManufactorySystem.applyDays, daysAdvanced)
		if not ok then warn("[EconomySystem] ManufactorySystem.applyDays failed: " .. tostring(err)) end
	end
end

-- Player commands -------------------------------------------------------------

local function setEconomyPolicy(tag, policyId)
	local country = ctx.WorldState.getCountry(tag)
	if not country then return false end
	local bundle = ctx.Bundle
	if policyId ~= nil and (not bundle or not bundle.economyPolicies or not bundle.economyPolicies[policyId]) then
		return false
	end
	country.economyPolicy = policyId
	ctx.WorldState.setCountry(tag, country)
	recomputeProductionFor(tag)
	ctx.EventBus.publish(ctx.Channels.CountryPolicyEnacted, {
		tag = tag, policyId = policyId, kind = "economy",
	})
	return true
end

local function setConsumerGoods(tag, priorities)
	local country = ctx.WorldState.getCountry(tag)
	if not country then return false end
	if priorities ~= nil and type(priorities) ~= "table" then return false end
	country.consumerGoodsPriority = priorities
	ctx.WorldState.setCountry(tag, country)
	return true
end

-- Read-only getters used by the UI -------------------------------------------

local function dailyTaxOf(tag)
	if cachedDailyTax[tag] == nil then recomputeProductionFor(tag) end
	return (cachedDailyTax[tag] or 0) * unrestTaxFactor(ctx.WorldState.getCountry(tag))
end

local function dailyProductionOf(tag)
	if cachedDailyProduction[tag] == nil then recomputeProductionFor(tag) end
	return cachedDailyProduction[tag] or {}
end

local function stockpileOf(tag, goodId)
	local country = ctx.WorldState.getCountry(tag)
	if not country or not country.stockpiles then return 0 end
	return country.stockpiles[goodId] or 0
end

local function adjustStockpile(tag, goodId, delta)
	local country = ctx.WorldState.getCountry(tag)
	if not country then return false end
	ensureCountryFields(country)
	country.stockpiles[goodId] = (country.stockpiles[goodId] or 0) + delta
	if country.stockpiles[goodId] < 0 then country.stockpiles[goodId] = 0 end
	ctx.WorldState.setCountry(tag, country)
	return true
end

local function breakdownOf(tag)
	local country = ctx.WorldState.getCountry(tag)
	if not country then return { byProvince = {}, income = {}, expense = {} } end
	local taxAdd = ctx.ModifierStack and ctx.ModifierStack.resolveAdditive
		and ctx.ModifierStack.resolveAdditive(tag, "country_tax_income") or 0
	local prodAdd = ctx.ModifierStack and ctx.ModifierStack.resolveAdditive
		and ctx.ModifierStack.resolveAdditive(tag, "country_production") or 0
	local provinceIds = (ctx.ProvinceRegistry and ctx.ProvinceRegistry.byOwner(tag)) or {}
	local rows = {}
	for _, pid in provinceIds do
		local province = ctx.WorldState.getProvince(pid)
		if province then
			local cap = isCapital(country, province)
			rows[pid] = {
				tax = EconomyPreview.taxOf(province, country, ctx.WorldConstants, ctx.Bundle, cap, taxAdd),
				production = EconomyPreview.productionOf(province, country, ctx.WorldConstants, ctx.Bundle, prodAdd),
				isCapital = cap,
			}
		end
	end
	return {
		byProvince = rows,
		income = country.incomeBreakdown or {},
		expense = country.expenseBreakdown or {},
	}
end

local function listProviders()
	return {
		income = table.clone(providerOrder.income),
		expense = table.clone(providerOrder.expense),
	}
end

local function seedAllCountries()
	for tag in ctx.WorldState.allCountries() do
		recomputeProductionFor(tag)
	end
end

local function onDateAdvanced(payload)
	if not payload then return end
	applyDays(payload.daysAdvanced or 1)
end

local function onProvinceMutated()
	table.clear(cachedDailyTax)
	table.clear(cachedDailyProduction)
end

-- Module-table API mirror (so loadedSystems.EconomySystem.x works in Bootstrap)
EconomySystem.setEconomyPolicy = function(...) return setEconomyPolicy(...) end
EconomySystem.setConsumerGoods = function(...) return setConsumerGoods(...) end
EconomySystem.dailyTaxOf = function(...) return dailyTaxOf(...) end
EconomySystem.dailyProductionOf = function(...) return dailyProductionOf(...) end
EconomySystem.stockpileOf = function(...) return stockpileOf(...) end
EconomySystem.adjustStockpile = function(...) return adjustStockpile(...) end
EconomySystem.breakdownOf = function(...) return breakdownOf(...) end
EconomySystem.recomputeFor = function(...) return recomputeProductionFor(...) end
EconomySystem.registerIncomeProvider = function(...) return registerIncomeProvider(...) end
EconomySystem.registerExpenseProvider = function(...) return registerExpenseProvider(...) end
EconomySystem.unregisterIncomeProvider = function(...) return unregisterIncomeProvider(...) end
EconomySystem.unregisterExpenseProvider = function(...) return unregisterExpenseProvider(...) end
EconomySystem.listProviders = function() return listProviders() end

function EconomySystem.register(context)
	ctx = context
	context.EconomySystem = {
		setEconomyPolicy = setEconomyPolicy,
		setConsumerGoods = setConsumerGoods,
		dailyTaxOf = dailyTaxOf,
		dailyProductionOf = dailyProductionOf,
		stockpileOf = stockpileOf,
		adjustStockpile = adjustStockpile,
		breakdownOf = breakdownOf,
		recomputeFor = recomputeProductionFor,
		registerIncomeProvider = registerIncomeProvider,
		registerExpenseProvider = registerExpenseProvider,
		unregisterIncomeProvider = unregisterIncomeProvider,
		unregisterExpenseProvider = unregisterExpenseProvider,
		listProviders = listProviders,
	}

	-- Built-in providers (insertion order = display order in UI)
	registerIncomeProvider("tax_income", provider_taxIncome)
	registerIncomeProvider("exports", provider_exports)
	registerExpenseProvider("army_upkeep", provider_armyUpkeep)
	registerExpenseProvider("government_spending", provider_governmentSpending)
	registerExpenseProvider("imports", provider_imports)

	context.EventBus.subscribe(context.Channels.DateAdvanced, onDateAdvanced)
	context.EventBus.subscribe(context.Channels.ProvinceOwnershipChanged, onProvinceMutated)
	context.EventBus.subscribe(context.Channels.ProvinceDevelopmentChanged, onProvinceMutated)
	context.EventBus.subscribe(context.Channels.BuildingCompleted, onProvinceMutated)
	context.EventBus.subscribe(context.Channels.CountryClaimed, onProvinceMutated)

	context.TickScheduler.register({
		id = "EconomySystem",
		priority = 28,
		updateIntervalSeconds = (context.WorldConstants.SecondsPerEconomyUpdate or 3),
		update = function() end,
		start = seedAllCountries,
	})
end

return EconomySystem
