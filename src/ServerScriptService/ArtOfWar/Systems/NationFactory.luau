-- NationFactory (Phase 4): create a valid CountryRecord at runtime for newly-formed nations -- released
-- nations (DiplomacySystem.releaseNation) and rebel breakaways (RebellionSystem). It only builds + stores
-- the country record (required fields + sane defaults); the caller transfers provinces afterwards.
--
-- Country.cores does NOT exist in v4 (cores live on the province, single source of truth), so this never
-- sets it. Culture/religion default to the capital province's when the caller doesn't override.

local NationFactory = {}

local ctx

local function create(tag, opts)
	opts = opts or {}
	local capId = opts.capitalProvinceId
	local capProv = capId and ctx.WorldState.getProvince(capId) or nil

	local country = {
		tag = tag,
		displayName = opts.displayName or tag,
		capitalProvinceId = capId,
		primaryCulture = opts.primaryCulture or (capProv and capProv.culture) or "none",
		stateReligion = opts.stateReligion or (capProv and capProv.religion) or "none",
		governmentForm = opts.governmentForm or "monarchy",
		ideology = opts.ideology or "traditionalist",
		stability = opts.stability or 0,
		legitimacy = opts.legitimacy or (ctx.WorldConstants.LegitimacyBase or 50),
		treasury = opts.treasury or 0,
		manpower = opts.manpower or 0,
		politicalPower = opts.politicalPower or 0,
		color = opts.color or { 150, 150, 150 },
	}
	if opts.flag then
		country.flagAssetId = opts.flag
	end

	ctx.WorldState.setCountry(tag, country)
	return country
end

function NationFactory.register(context)
	ctx = context
	context.NationFactory = { create = create }
end

return NationFactory
