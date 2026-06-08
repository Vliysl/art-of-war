local CapitalSystem = {}

local ctx
local capitalIndex = {}

local function resetCapitalBonuses(province)
	province.capitalTaxMult = nil
	province.capitalManpowerMult = nil
	province.capitalUnrestReduction = nil
	province.effectiveFortTier = province.fortTier or 0
end

local function applyCapitalBonuses(province)
	local wc = ctx.WorldConstants
	province.capitalTaxMult = wc.CapitalTaxMultiplier
	province.capitalManpowerMult = wc.CapitalManpowerMultiplier
	province.capitalUnrestReduction = wc.CapitalUnrestReduction
	province.effectiveFortTier = (province.fortTier or 0) + wc.CapitalFortBonus
end

local function rebuildCapitalIndex()
	table.clear(capitalIndex)
	for tag, country in ctx.WorldState.allCountries() do
		capitalIndex[tag] = country.capitalProvinceId
	end
end

local function relocateCapital(tag, oldCapitalId)
	local country = ctx.WorldState.getCountry(tag)
	if not country then return end

	local oldProvince = ctx.WorldState.getProvince(oldCapitalId)
	if oldProvince then
		resetCapitalBonuses(oldProvince)
		ctx.WorldState.setProvince(oldCapitalId, oldProvince)
	end

	local ownedIds = ctx.ProvinceRegistry and ctx.ProvinceRegistry.byOwner(tag) or {}
	local candidates = {}
	for _, id in ownedIds do
		local p = ctx.WorldState.getProvince(id)
		if p and p.isCity then
			table.insert(candidates, { id = id, dev = (p.baseTax or 0) + (p.baseProduction or 0) + (p.baseManpower or 0) })
		end
	end
	if #candidates == 0 then
		country.capitalProvinceId = nil
		capitalIndex[tag] = nil
		ctx.WorldState.setCountry(tag, country)
		ctx.EventBus.publish(ctx.Channels.ProvinceOwnershipChanged, {
			provinceId = oldCapitalId,
			capitalRelocated = true,
			country = tag,
			newCapitalId = nil,
		})
		return
	end

	table.sort(candidates, function(a, b) return a.dev > b.dev end)
	local newCapitalId = candidates[1].id
	country.capitalProvinceId = newCapitalId
	capitalIndex[tag] = newCapitalId
	ctx.WorldState.setCountry(tag, country)

	local newProvince = ctx.WorldState.getProvince(newCapitalId)
	if newProvince then
		applyCapitalBonuses(newProvince)
		ctx.WorldState.setProvince(newCapitalId, newProvince)
	end

	ctx.EventBus.publish(ctx.Channels.ProvinceOwnershipChanged, {
		provinceId = oldCapitalId,
		capitalRelocated = true,
		country = tag,
		newCapitalId = newCapitalId,
	})
end

local function tickCapitalBonuses()
	for tag, capitalId in capitalIndex do
		if not capitalId then continue end
		local province = ctx.WorldState.getProvince(capitalId)
		if not province then continue end
		if province.ownerTag ~= tag then
			relocateCapital(tag, capitalId)
			continue
		end
		local wc = ctx.WorldConstants
		if province.capitalTaxMult ~= wc.CapitalTaxMultiplier then
			applyCapitalBonuses(province)
			ctx.WorldState.setProvince(province.id, province)
		end
	end
end

function CapitalSystem.register(context)
	ctx = context
	ctx.TickScheduler.register({
		id = "CapitalSystem",
		priority = 10,
		updateIntervalSeconds = ctx.WorldConstants.SecondsPerEconomyUpdate,
		update = tickCapitalBonuses,
		start = rebuildCapitalIndex,
	})
	ctx.EventBus.subscribe(ctx.Channels.ProvinceOwnershipChanged, function(payload)
		if not payload or payload.capitalRelocated then return end
		rebuildCapitalIndex()
	end)
end

return CapitalSystem
