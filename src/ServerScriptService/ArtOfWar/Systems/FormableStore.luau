-- FormableStore (Phase 6): persistence + replication for OWNER-AUTHORED custom formable/releasable
-- definitions (the static ones live in Data/Formables). Custom defs are:
--   * loaded from DataStore at boot and applied to FormableSystem (so FormNation/ReleaseNation see them),
--   * mirrored to a ReplicatedStorage StringValue (JSON) so the client (Missions/Politics + editor) can
--     list them, and
--   * written back to DataStore + FormableSystem + the StringValue whenever the owner edits one.
-- All DataStore access is pcall-wrapped so a store outage (or Studio without API access) degrades to
-- in-memory + replicated only, never breaking boot.

local FormableStore = {}

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local STORE_NAME = "AoW_Formables"
local STORE_SCOPE = "v4"
local KEY = "all"

local FLUSH_DELAY = 6 -- seconds; coalesce bursty edits into one SetAsync

-- B9: structurally sanitize an OWNER-AUTHORED custom def before it is persisted + JSON-replicated to every
-- client. set() used to accept any table, so a config-listed editor could push arbitrary asset ids (rendered/
-- played on every client -- HANDOFF rule 10 content-policy landmine), unbounded text, or a huge/garbage
-- requiredProvinceIds (which RebellionSystem indexes). Build a FRESH allowlisted copy (coerce/clamp/drop per
-- field, keep only known keys per the Data/Formables schema); hard-reject only a non-table or a def with no
-- usable displayName. Bypass with the server-only kill-switch WorldConstants.EnforceFormableDefValidation=false.
local ASSET_ID_PATTERNS = { "^rbxassetid://%d+$", "^rbxthumb://", "^rbxasset://" }

local function cleanAssetId(v)
	if type(v) ~= "string" then
		return nil
	end
	for _, pat in ipairs(ASSET_ID_PATTERNS) do
		if string.match(v, pat) then
			return v
		end
	end
	return nil
end

local function cleanStr(v, maxLen)
	if type(v) ~= "string" then
		return nil
	end
	local s = (v:gsub("^%s*(.-)%s*$", "%1"))
	if s == "" then
		return nil
	end
	return (#s > maxLen) and string.sub(s, 1, maxLen) or s
end

local function cleanColor(v)
	if type(v) ~= "table" then
		return { 150, 150, 150 }
	end
	local out = {}
	for i = 1, 3 do
		out[i] = math.clamp(math.floor(tonumber(v[i]) or 150), 0, 255)
	end
	return out
end

local function cleanProvinceIds(v)
	local out = {}
	if type(v) == "table" then
		for _, id in ipairs(v) do
			local n = tonumber(id)
			if n and n > 0 then
				out[#out + 1] = math.floor(n)
				if #out >= 512 then
					break
				end
			end
		end
	end
	return out
end

local function cleanFormerTags(v)
	if type(v) ~= "table" then
		return nil
	end
	local out = {}
	for _, tag in ipairs(v) do
		if type(tag) == "string" then
			local t = (string.upper(tag):gsub("[^%w]", ""))
			if t ~= "" then
				out[#out + 1] = string.sub(t, 1, 8)
				if #out >= 64 then
					break
				end
			end
		end
	end
	return (#out > 0) and out or nil
end

local function sanitizeDef(def)
	if type(def) ~= "table" then
		return nil, "not_table"
	end
	local name = cleanStr(def.displayName, 64)
	if not name then
		return nil, "no_display_name"
	end
	local clean = {
		displayName = name,
		color = cleanColor(def.color),
		requiredProvinceIds = cleanProvinceIds(def.requiredProvinceIds),
		flag = cleanAssetId(def.flag),
		formerTags = cleanFormerTags(def.formerTags),
		description = cleanStr(def.description, 500),
		eventTitle = cleanStr(def.eventTitle, 80),
		eventDesc = cleanStr(def.eventDesc, 500),
		eventButton = cleanStr(def.eventButton, 80),
		eventImageId = cleanAssetId(def.eventImageId),
		eventAudioId = cleanAssetId(def.eventAudioId),
	}
	if type(def.canForm) == "boolean" then
		clean.canForm = def.canForm
	end
	if type(def.canRelease) == "boolean" then
		clean.canRelease = def.canRelease
	end
	if type(def.secret) == "boolean" then
		clean.secret = def.secret
	end
	local minP = tonumber(def.minProvinces)
	if minP then
		clean.minProvinces = math.max(0, math.floor(minP))
	end
	local pct = tonumber(def.percentRequired)
	if pct then
		clean.percentRequired = math.clamp(pct, 1, 100)
	end
	local stab = type(def.formBonuses) == "table" and tonumber(def.formBonuses.stability)
	if stab then
		clean.formBonuses = { stability = math.clamp(stab, -5, 5) }
	end
	if def.eventAudience == "global" or def.eventAudience == "personal" then
		clean.eventAudience = def.eventAudience
	end
	-- A non-JSON-encodable or oversized def would break replicate()'s JSONEncode and blank the WHOLE client
	-- mirror of customs; reject rather than let one bad def wipe them all.
	local ok, json = pcall(function()
		return HttpService:JSONEncode(clean)
	end)
	if not ok or #json > 8192 then
		return nil, "too_large"
	end
	return clean
end

local ctx
local custom = {} -- tag -> definition
local dirty = false -- a persist is pending (edits since last write)
local flushScheduled = false -- a task.delay flush is in flight

-- Mirror the custom set to ReplicatedStorage/ArtOfWar/FormablesRuntime (JSON) for clients.
local function replicate()
	local aow = ReplicatedStorage:FindFirstChild("ArtOfWar")
	if not aow then
		return
	end
	local sv = aow:FindFirstChild("FormablesRuntime")
	if not sv then
		sv = Instance.new("StringValue")
		sv.Name = "FormablesRuntime"
		sv.Parent = aow
	end
	local ok, json = pcall(function()
		return HttpService:JSONEncode(custom)
	end)
	sv.Value = ok and json or "{}"
end

local function applyAll()
	if ctx.FormableSystem and ctx.FormableSystem.addDefinition then
		for tag, def in pairs(custom) do
			ctx.FormableSystem.addDefinition(tag, def)
		end
	end
end

-- Write the current custom set to the DataStore once (blocking). Only call from a flush.
local function writeNow()
	dirty = false
	pcall(function()
		DataStoreService:GetDataStore(STORE_NAME, STORE_SCOPE):SetAsync(KEY, custom)
	end)
end

-- Mark the store dirty and schedule a single coalesced flush; bursty edits collapse into one write.
local function persist()
	dirty = true
	if flushScheduled then
		return
	end
	flushScheduled = true
	task.delay(FLUSH_DELAY, function()
		flushScheduled = false
		if dirty then
			writeNow()
		end
	end)
end

local function load()
	local ok, data = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME, STORE_SCOPE):GetAsync(KEY)
	end)
	if ok and type(data) == "table" then
		custom = data
	end
end

function FormableStore.register(context)
	ctx = context
	load()
	replicate()
	-- Don't lose a pending coalesced write when the server shuts down.
	game:BindToClose(function()
		if dirty then
			writeNow()
		end
	end)
	-- Apply after the register loop so FormableSystem is guaranteed registered (order-independent).
	task.defer(applyAll)

	context.FormableStore = {
		set = function(tag, def)
			if type(tag) ~= "string" or tag == "" or type(def) ~= "table" then
				return false, "bad_args"
			end
			if ctx.WorldConstants.EnforceFormableDefValidation ~= false then
				local clean, reason = sanitizeDef(def)
				if not clean then
					return false, reason
				end
				def = clean
			end
			custom[tag] = def
			if ctx.FormableSystem and ctx.FormableSystem.addDefinition then
				ctx.FormableSystem.addDefinition(tag, def)
			end
			replicate()
			persist()
			return true
		end,
		remove = function(tag)
			custom[tag] = nil
			if ctx.FormableSystem and ctx.FormableSystem.removeDefinition then
				ctx.FormableSystem.removeDefinition(tag)
			end
			replicate()
			persist()
			return true
		end,
		list = function()
			return custom
		end,
	}
end

return FormableStore
