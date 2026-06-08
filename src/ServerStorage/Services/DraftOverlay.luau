local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")

local RelayConfig = require(ServerStorage:WaitForChild("Dev"):WaitForChild("RelayConfig"))

local DraftOverlay = {}

local KIND_COUNTRIES   = "country"
local KIND_PROVINCES   = "province"
local KIND_EU4MAP      = "eu4map"
local KIND_TILES       = "tile"
local KIND_CULTURES    = "culture"
local KIND_RELIGIONS   = "religion"
local KIND_IDEOLOGIES  = "ideology"
local KIND_GOVERNMENTS = "government_type"

local DRAFT_AGGREGATE_PREFIX = {
	[KIND_COUNTRIES]   = "draft:%d:countries",
	[KIND_PROVINCES]   = "draft:%d:provinces",
	[KIND_EU4MAP]      = "draft:%d:eu4map",
	[KIND_TILES]       = "draft:%d:tiles",
	[KIND_CULTURES]    = "draft:%d:cultures",
	[KIND_RELIGIONS]   = "draft:%d:religions",
	[KIND_IDEOLOGIES]  = "draft:%d:ideologies",
	[KIND_GOVERNMENTS] = "draft:%d:government_types",
}

local ALL_KINDS = { KIND_COUNTRIES, KIND_PROVINCES, KIND_EU4MAP, KIND_TILES, KIND_CULTURES, KIND_RELIGIONS, KIND_IDEOLOGIES, KIND_GOVERNMENTS }

local KIND_TO_BUNDLE_FIELD = {
	[KIND_COUNTRIES]   = "countries",
	[KIND_PROVINCES]   = "provinces",
	[KIND_EU4MAP]      = "eu4Map",
	[KIND_TILES]       = "tileOwners",
	[KIND_CULTURES]    = "cultures",
	[KIND_RELIGIONS]   = "religions",
	[KIND_IDEOLOGIES]  = "ideologies",
	[KIND_GOVERNMENTS] = "governments",
}

local MAX_RETRIES  = 4
local BASE_BACKOFF = 0.4

local function store()
	return DataStoreService:GetDataStore(RelayConfig.DATASTORE_NAME, RelayConfig.DATASTORE_SCOPE)
end

local function readBudget()
	local ok, budget = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.GetAsync)
	end)
	return (ok and budget) or 0
end

local function draftKey(kind, userId)
	local fmt = DRAFT_AGGREGATE_PREFIX[kind]
	if not fmt then return nil end
	return string.format(fmt, tonumber(userId) or 0)
end

local function encodeValue(value)
	if value == nil then return nil end
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, value)
	if ok then return encoded end
	return nil
end

local function decodeValue(raw)
	if raw == nil then return nil end
	if type(raw) == "string" then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
		if ok then return decoded end
		return nil
	end
	return raw
end

local function withRetries(fn)
	local attempt = 0
	local lastErr
	while attempt < MAX_RETRIES do
		attempt = attempt + 1
		local ok, result = pcall(fn)
		if ok then return true, result end
		lastErr = result
		task.wait(BASE_BACKOFF * (2 ^ (attempt - 1)))
	end
	return false, lastErr
end

local function getAggregate(kind, userId)
	local key = draftKey(kind, userId)
	if not key then return nil end
	local ok, raw = withRetries(function() return store():GetAsync(key) end)
	if not ok then return nil end
	local decoded = decodeValue(raw)
	if type(decoded) ~= "table" then return {} end
	return decoded
end

local function setAggregate(kind, userId, value)
	local key = draftKey(kind, userId)
	if not key then return false, "unknown kind" end
	local payload = value
	if type(payload) == "table" and next(payload) == nil then
		payload = nil
	end
	local encoded = payload ~= nil and encodeValue(payload) or nil
	local ok, err = withRetries(function() return store():SetAsync(key, encoded) end)
	return ok, err
end

local function bundleToAggregates(bundle)
	if type(bundle) ~= "table" then bundle = {} end
	local out = {}
	for _, kind in ipairs(ALL_KINDS) do
		local field = KIND_TO_BUNDLE_FIELD[kind]
		local data = bundle[field]
		if type(data) == "table" then
			local copy = {}
			for k, v in pairs(data) do copy[tostring(k)] = v end
			out[kind] = copy
		else
			out[kind] = {}
		end
	end
	return out
end

local function aggregatesToBundle(aggregates)
	local bundle = {
		countries   = {},
		provinces   = {},
		eu4Map      = {},
		tileOwners  = {},
		cultures    = {},
		religions   = {},
		ideologies  = {},
		governments = {},
	}
	if type(aggregates) ~= "table" then return bundle end
	for _, kind in ipairs(ALL_KINDS) do
		local field = KIND_TO_BUNDLE_FIELD[kind]
		local data = aggregates[kind]
		if type(data) == "table" then
			for k, v in pairs(data) do
				if kind == KIND_PROVINCES or kind == KIND_EU4MAP then
					bundle[field][tonumber(k) or k] = v
				else
					bundle[field][k] = v
				end
			end
		end
	end
	return bundle
end

function DraftOverlay.loadDraft(userId)
	if userId == nil then return nil end
	if readBudget() < #ALL_KINDS then return nil end
	local aggregates = {}
	local anyData = false
	for _, kind in ipairs(ALL_KINDS) do
		local agg = getAggregate(kind, userId)
		if agg and next(agg) ~= nil then anyData = true end
		aggregates[kind] = agg or {}
	end
	if not anyData then return nil end
	return aggregatesToBundle(aggregates)
end

function DraftOverlay.saveDraft(userId, bundle)
	if userId == nil then return { ok = false, error = "userId required" } end
	local aggregates = bundleToAggregates(bundle)
	local writes, failures = {}, {}
	for _, kind in ipairs(ALL_KINDS) do
		local ok, err = setAggregate(kind, userId, aggregates[kind])
		if ok then
			table.insert(writes, kind)
		else
			table.insert(failures, { kind = kind, error = tostring(err) })
		end
	end
	return {
		ok = #failures == 0,
		writes = writes,
		failures = failures,
	}
end

function DraftOverlay.discardDraft(userId)
	if userId == nil then return { ok = false, error = "userId required" } end
	local writes, failures = {}, {}
	for _, kind in ipairs(ALL_KINDS) do
		local key = draftKey(kind, userId)
		if key then
			local ok, err = withRetries(function() return store():SetAsync(key, nil) end)
			if ok then
				table.insert(writes, kind)
			else
				table.insert(failures, { kind = kind, error = tostring(err) })
			end
		end
	end
	return {
		ok = #failures == 0,
		writes = writes,
		failures = failures,
	}
end

function DraftOverlay.hasDraft(userId)
	if userId == nil then return false end
	if readBudget() < 1 then return false end
	for _, kind in ipairs(ALL_KINDS) do
		local agg = getAggregate(kind, userId)
		if agg and next(agg) ~= nil then return true end
	end
	return false
end

local function deepEquals(a, b)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for k, v in pairs(a) do
		if not deepEquals(v, b[k]) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

function DraftOverlay.diffBundles(draftBundle, sharedBundle, baselineBundle)
	local diffs = {}
	if type(draftBundle) ~= "table" then return diffs end
	if type(sharedBundle) ~= "table" then sharedBundle = {} end
	local hasBaseline = type(baselineBundle) == "table"
	for _, kind in ipairs(ALL_KINDS) do
		local field = KIND_TO_BUNDLE_FIELD[kind]
		local draftMap = draftBundle[field] or {}
		local sharedMap = sharedBundle[field] or {}
		local baselineMap = hasBaseline and (baselineBundle[field] or {}) or nil
		local seen = {}
		for key, draftValue in pairs(draftMap) do
			seen[key] = true
			local sharedValue = sharedMap[key]
			if not deepEquals(draftValue, sharedValue) then
				local action
				if sharedValue == nil then action = "add"
				else action = "update" end
				table.insert(diffs, {
					kind = kind,
					field = field,
					key = key,
					action = action,
					draftValue = draftValue,
					sharedValue = sharedValue,
				})
			end
		end
		if next(draftMap) ~= nil then
			for key, sharedValue in pairs(sharedMap) do
				if not seen[key] and (baselineMap == nil or baselineMap[key] ~= nil) then
					table.insert(diffs, {
						kind = kind,
						field = field,
						key = key,
						action = "delete",
						draftValue = nil,
						sharedValue = sharedValue,
					})
				end
			end
		end
	end
	return diffs
end

return DraftOverlay
