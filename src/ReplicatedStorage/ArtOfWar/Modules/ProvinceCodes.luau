local ProvinceCodes = {}

local CODE_LEN = 5
local CACHE = {}

local PROFANE = {
	"CUM", "SEX", "FUK", "FUC", "FUCK", "ASS", "TIT", "DICK", "COCK",
	"RAPE", "FAG", "NIG", "KKK", "SHIT", "PISS", "BTCH", "PUSS", "PUSY",
	"ANAL", "PORN", "JIZZ", "WHOR", "CUNT", "TWAT", "SLUT", "FART",
	"GAY", "HOMO", "TARD", "RTRD", "WANK", "MILF",
}

local function clean(s)
	return (s or ""):gsub("[^%a]", ""):upper()
end

local function findProfanity(code)
	if not code then return nil, nil end
	for _, bad in ipairs(PROFANE) do
		local s, e = code:find(bad, 1, true)
		if s then return s, e end
	end
	return nil, nil
end

local function pad(part, len)
	if #part >= len then return part:sub(1, len) end
	return part .. string.rep("X", len - #part)
end

local function deriveBase(words)
	local n = #words
	if n == 0 then return string.rep("X", CODE_LEN) end
	if n == 1 then return pad(words[1], CODE_LEN) end
	if n == 2 then return pad(words[1], 3) .. pad(words[2], 2) end
	if n == 3 then return pad(words[1], 2) .. pad(words[2], 2) .. pad(words[3], 1) end
	if n == 4 then
		return pad(words[1], 2) .. pad(words[2], 1) .. pad(words[3], 1) .. pad(words[4], 1)
	end
	local s = ""
	for i = 1, CODE_LEN do s = s .. words[i]:sub(1, 1) end
	return s
end

local function sanitize(code)
	for _ = 1, CODE_LEN + 1 do
		local s, e = findProfanity(code)
		if not s then return code end
		local mid = math.floor((s + e) / 2)
		code = code:sub(1, mid - 1) .. "X" .. code:sub(mid + 1)
	end
	return code
end

local function deriveFromName(name)
	local words = {}
	for w in (name or ""):gmatch("%a+") do
		table.insert(words, w:upper())
	end
	if #words == 0 then return string.rep("X", CODE_LEN) end

	local primary = deriveBase(words)
	if not findProfanity(primary) then return primary end

	local stripped = clean(name)
	if #stripped >= CODE_LEN then
		for start = 1, #stripped - (CODE_LEN - 1) do
			local candidate = stripped:sub(start, start + CODE_LEN - 1)
			if not findProfanity(candidate) then return candidate end
		end
	end

	if #words >= 2 then
		local reversed = {}
		for i = #words, 1, -1 do table.insert(reversed, words[i]) end
		local rev = deriveBase(reversed)
		if not findProfanity(rev) then return rev end
	end

	return sanitize(primary)
end

local function normalizeStored(code)
	if type(code) ~= "string" or code == "" then return nil end
	local upper = code:upper():gsub("[^%w]", "")
	if upper == "" then return nil end
	if findProfanity(upper) then return sanitize(upper) end
	return upper
end

function ProvinceCodes.fromPartName(partName)
	if type(partName) ~= "string" or partName == "" then
		return string.rep("?", CODE_LEN)
	end
	local cached = CACHE[partName]
	if cached then return cached end
	local rawName = partName:gsub("^prov_%d+_", "")
	if rawName == "" or rawName == partName then rawName = partName end
	local code = deriveFromName(rawName)
	CACHE[partName] = code
	return code
end

function ProvinceCodes.fromRecord(record, partName)
	if type(record) == "table" then
		local stored = normalizeStored(record.code)
		if stored then return stored end
		if type(record.name) == "string" and record.name ~= "" then
			return deriveFromName(record.name)
		end
	end
	if partName then return ProvinceCodes.fromPartName(partName) end
	return string.rep("?", CODE_LEN)
end

function ProvinceCodes.deriveFromName(name)
	return deriveFromName(name)
end

function ProvinceCodes.sanitize(code)
	local stripped = (code or ""):upper():gsub("[^%w]", "")
	return findProfanity(stripped) and sanitize(stripped) or stripped
end

function ProvinceCodes.isProfane(code)
	if type(code) ~= "string" then return false end
	return findProfanity(code:upper()) ~= nil
end

function ProvinceCodes.length()
	return CODE_LEN
end

function ProvinceCodes.format(code, name)
	if not code or code == "" then return tostring(name or "?") end
	if not name or name == "" then return code end
	return code .. " · " .. name
end

return ProvinceCodes
