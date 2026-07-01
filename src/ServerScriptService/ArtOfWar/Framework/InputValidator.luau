local InputValidator = {}

local MAX_STRING_LENGTH = 64
local MAX_TABLE_ENTRIES = 256
local TAG_LENGTH = 3

local configs = {}
local windows = {}

local function isString(v, maxLen)
	return type(v) == "string" and v ~= "" and #v <= (maxLen or MAX_STRING_LENGTH)
end

local function isInt(v)
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and v == math.floor(v)
end

local function isPositiveNumber(v)
	return type(v) == "number" and v == v and v > 0 and v < 1e15
end

local function isNonNegativeNumber(v)
	return type(v) == "number" and v == v and v >= 0 and v < 1e15
end

local function isCountryTag(v)
	return type(v) == "string" and #v == TAG_LENGTH and v == string.upper(v) and v:match("^[A-Z]+$") ~= nil
end

local function isTradeOffer(v)
	if type(v) ~= "table" then return false end
	if not isString(v.goodId) then return false end
	if not isPositiveNumber(v.amount) then return false end
	return true
end

local function isShallowTable(v)
	if type(v) ~= "table" then return false end
	local count = 0
	for key, value in v do
		count += 1
		if count > MAX_TABLE_ENTRIES then return false end
		if type(key) ~= "string" and type(key) ~= "number" then return false end
		local t = type(value)
		if t ~= "string" and t ~= "number" and t ~= "boolean" then return false end
	end
	return true
end

local PEACE_TERM_TYPES = { white_peace = true, annex_occupied = true, annex_all = true, vassalize = true, conference = true }
-- Peace terms: a known term type; a "conference" additionally carries a bounded list of demand tables
-- {type=string, provinceId=number?}. The server recomputes all costs from the provinceIds, so any costs
-- the client supplies are ignored -- this validator only gates the shape.
local function isPeaceTerms(v)
	if type(v) ~= "table" then return false end
	if not isString(v.type) or not PEACE_TERM_TYPES[v.type] then return false end
	if v.type == "conference" then
		if type(v.demands) ~= "table" then return false end
		local n = 0
		for _, d in v.demands do
			n += 1
			if n > MAX_TABLE_ENTRIES then return false end
			if type(d) ~= "table" then return false end
			if not isString(d.type) then return false end
			if d.provinceId ~= nil and type(d.provinceId) ~= "number" then return false end
		end
	end
	return true
end

local function isOptionalString(v)
	if v == nil then return true end
	return type(v) == "string" and #v <= MAX_STRING_LENGTH
end

local validators = {
	string = isString,
	optionalString = isOptionalString,
	integer = isInt,
	positiveNumber = isPositiveNumber,
	nonNegativeNumber = isNonNegativeNumber,
	countryTag = isCountryTag,
	policyId = isString,
	tradeGoodId = isString,
	tradeOffer = isTradeOffer,
	shallowTable = isShallowTable,
	peaceTerms = isPeaceTerms,
	any = function() return true end,
}

function InputValidator.register(remoteName, config)
	assert(type(remoteName) == "string" and remoteName ~= "", "remoteName required")
	assert(type(config) == "table", "config required")
	if config.schema then
		for _, field in config.schema do
			if not validators[field.type] then
				error(string.format("InputValidator: unknown type '%s' on field '%s' of '%s'", tostring(field.type), tostring(field.name), remoteName))
			end
		end
	end
	configs[remoteName] = config
end

local function checkSchema(remoteName, config, args)
	if not config.schema then return true end
	for i, field in config.schema do
		local value = args[i]
		local validator = validators[field.type]
		if not validator(value) then
			return false, string.format("%s: field %d '%s' failed type '%s'", remoteName, i, field.name, field.type)
		end
	end
	return true
end

local function checkRate(remoteName, player, config)
	if not config.rate then return true end
	local key = remoteName .. "|" .. tostring(player.UserId)
	local window = windows[key]
	local now = os.clock()
	if not window then
		window = { entries = {}, capacity = config.rate.count, span = config.rate.window }
		windows[key] = window
	end
	local cutoff = now - window.span
	local kept = {}
	for _, ts in window.entries do
		if ts >= cutoff then table.insert(kept, ts) end
	end
	if #kept >= window.capacity then
		window.entries = kept
		return false
	end
	table.insert(kept, now)
	window.entries = kept
	return true
end

function InputValidator.accept(player, remoteName, ...)
	local config = configs[remoteName]
	if not config then return true end
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return false end
	if not checkRate(remoteName, player, config) then return false end
	local args = table.pack(...)
	local ok = checkSchema(remoteName, config, args)
	return ok
end

function InputValidator.releaseWindows(userId)
	local suffix = "|" .. tostring(userId)
	for key in windows do
		if key:sub(-#suffix) == suffix then
			windows[key] = nil
		end
	end
end

function InputValidator.addValidator(name, fn)
	validators[name] = fn
end

return InputValidator
