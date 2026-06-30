-- FormableSystem (Phase 4): forming a nation by holding its required territory.
--
-- Forming does NOT create a new country or change the internal tag (the tag is the primary key used
-- everywhere -- ownerTag / controllerTag / claimedBy / wars / pacts). Instead the existing country ADOPTS
-- the formable's display identity (displayName / color / flag), CORES the required provinces (single
-- source of truth: province.cores), and gains a small bonus. Gated by WorldConstants.EnableFormables.
--
-- Definitions come from Data/Formables (static seed) merged with runtime/custom ones (Phase 6 owner suite
-- via addDefinition); a custom definition overrides a static one with the same tag.

local FormableSystem = {}

local ctx
local STATIC = {} -- static seed definitions (Data/Formables)
local custom = {} -- runtime/custom definitions (override STATIC on tag collision)

local function getDef(formableTag)
	return custom[formableTag] or STATIC[formableTag]
end

-- Iterate every effective definition exactly once (custom overrides static).
local function eachDef(fn)
	for tag, def in pairs(STATIC) do
		if custom[tag] == nil then
			fn(tag, def)
		end
	end
	for tag, def in pairs(custom) do
		fn(tag, def)
	end
end

local function ownsAll(tag, ids)
	if not ids or #ids == 0 then return false end
	for _, id in ipairs(ids) do
		local p = ctx.WorldState.getProvince(id)
		if not p or p.ownerTag ~= tag then return false end
	end
	return true
end

local function canForm(tag, formableTag)
	if not ctx.WorldConstants.EnableFormables then return false end
	local def = getDef(formableTag)
	if not def or def.canForm == false then return false end
	-- Can't form a nation you ARE already (identity already adopted), and the tag must exist.
	if not ctx.WorldState.getCountry(tag) then return false end
	return ownsAll(tag, def.requiredProvinceIds)
end

-- Tags of every formable `tag` currently qualifies to form. O(defs x required) -- definitions are few.
local function eligibleFor(tag)
	local out = {}
	if not ctx.WorldConstants.EnableFormables then return out end
	eachDef(function(formableTag)
		if canForm(tag, formableTag) then
			out[#out + 1] = formableTag
		end
	end)
	return out
end

-- Form `formableTag` as `tag`: adopt identity, core the required provinces, apply bonuses.
local function formNation(tag, formableTag)
	if not canForm(tag, formableTag) then return false, "cannot_form" end
	local def = getDef(formableTag)
	local country = ctx.WorldState.getCountry(tag)
	if not country then return false, "no_country" end

	-- Adopt the formable's display identity on the EXISTING country (internal tag unchanged).
	if def.displayName then country.displayName = def.displayName end
	if def.color then country.color = def.color end
	if def.flag then country.flagAssetId = def.flag end
	if def.formBonuses and type(def.formBonuses.stability) == "number" then
		country.stability = (country.stability or 0) + def.formBonuses.stability
	end
	ctx.WorldState.setCountry(tag, country)

	-- Core the required provinces to the former (single source of truth: province.cores).
	for _, id in ipairs(def.requiredProvinceIds or {}) do
		local p = ctx.WorldState.getProvince(id)
		if p then
			p.cores = p.cores or {}
			if not table.find(p.cores, tag) then
				table.insert(p.cores, tag)
				ctx.WorldState.setProvince(id, p)
			end
		end
	end

	if ctx.EventBus and ctx.Channels and ctx.Channels.NationFormed then
		ctx.EventBus.publish(ctx.Channels.NationFormed, { tag = tag, formableTag = formableTag })
	end
	return true
end

function FormableSystem.register(context)
	ctx = context
	local ok, defs = pcall(function()
		local rs = game:GetService("ReplicatedStorage")
		local data = rs:WaitForChild("ArtOfWar"):WaitForChild("Data")
		return require(data:WaitForChild("Formables", 10))
	end)
	if ok and type(defs) == "table" then
		STATIC = defs
	end

	context.FormableSystem = {
		canForm = canForm,
		eligibleFor = eligibleFor,
		formNation = formNation,
		getDefinition = getDef,
		allDefinitions = function()
			local merged = table.clone(STATIC)
			for k, v in pairs(custom) do merged[k] = v end
			return merged
		end,
		addDefinition = function(formableTag, def) custom[formableTag] = def end,
		removeDefinition = function(formableTag) custom[formableTag] = nil end,
	}
end

return FormableSystem
