local CountryRegistry = {}

local ctx
local byTechGroup, byIdeology, byReligion

local function indexCountries()
	byTechGroup, byIdeology, byReligion = {}, {}, {}
	for tag, country in ctx.WorldState.allCountries() do
		if country.technologyGroup then
			local bucket = byTechGroup[country.technologyGroup] or {}
			table.insert(bucket, tag)
			byTechGroup[country.technologyGroup] = bucket
		end

		if country.ideology then
			local bucket = byIdeology[country.ideology] or {}
			table.insert(bucket, tag)
			byIdeology[country.ideology] = bucket
		end

		if country.stateReligion then
			local bucket = byReligion[country.stateReligion] or {}
			table.insert(bucket, tag)
			byReligion[country.stateReligion] = bucket
		end
	end
end

function CountryRegistry.register(context)
	ctx = context
	CountryRegistry.api = {
		get = function(tag) return ctx.WorldState.getCountry(tag) end,
		all = function() return ctx.WorldState.allCountries() end,
		byTechGroup = function(group) return byTechGroup[group] or {} end,
		byIdeology = function(ideology) return byIdeology[ideology] or {} end,
		byReligion = function(religion) return byReligion[religion] or {} end,
		getCapital = function(tag)
			local country = ctx.WorldState.getCountry(tag)
			if not country then return nil end
			return ctx.WorldState.getProvince(country.capitalProvinceId)
		end,
		countOwnedProvinces = function(tag)
			local totals = ctx.ProvinceRegistry and ctx.ProvinceRegistry.ownerTotals()
			return totals and totals[tag] or 0
		end,
	}
	ctx.CountryRegistry = CountryRegistry.api
end

local function cloneOr(source, fallback)
	if type(source) == "table" then return table.clone(source) end
	return fallback
end

function CountryRegistry.hydrate(countries)
	for tag, record in countries do
		local clone = table.clone(record)
		clone.acceptedCultures = cloneOr(record.acceptedCultures, {})
		clone.historicalRivals = cloneOr(record.historicalRivals, {})
		clone.historicalFriends = cloneOr(record.historicalFriends, {})
		clone.color = cloneOr(record.color, { 128, 128, 128 })
		ctx.WorldState.setCountry(tag, clone)
	end
	indexCountries()
end

return CountryRegistry
