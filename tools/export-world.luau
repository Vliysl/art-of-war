-- export-world — bake the live world DataStore into committed Luau modules.
--
-- Fetches the 8 v4 aggregate keys (provinces/countries/cultures/religions/ideologies/
-- government_types/eu4map/tiles) from the world DataStore via the Open Cloud standard-
-- DataStore API and writes deterministic baked modules to
--   src/ServerScriptService/ArtOfWar/ServerData/World/
-- which the game loads at boot (instead of DataStore) when the server flag
-- WorldConstantsServer.UseBakedWorldData is true — see Framework/BakedWorld.luau.
--
-- Usage (from the repo root):
--   lune run tools/export-world -- --probe            # find which universe hosts the store
--   lune run tools/export-world -- [--edit] [--verify] [--dry-run]
--                                  [--universe <id>] [--datastore <name>] [--scope <scope>]
--
-- Config resolution:
--   API key:        env ROBLOX_OPEN_CLOUD_KEY (needs standard-DataStore READ for the universe)
--   store name/scope: --datastore/--scope > env AOW_DATASTORE_NAME/AOW_DATASTORE_SCOPE
--                     > parsed from src/ServerStorage/Dev/RelayConfig.luau (gitignored, local)
--   universe id:    --universe > tools/export-world.config.json (run --probe once to identify)
--
-- WORKFLOW: the baked files are a snapshot. After any Data Editor "push to live"
-- (DataOverlay.pushEditToLive), re-run this tool and commit the diff, or the published
-- game (in baked mode) will keep booting the older world.

local fs = require("@lune/fs")
local net = require("@lune/net")
local serde = require("@lune/serde")
local process = require("@lune/process")
local luauRt = require("@lune/luau")

local WorldNormalize = require("../src/ServerScriptService/ArtOfWar/Framework/WorldNormalize")

local OUT_DIR = "src/ServerScriptService/ArtOfWar/ServerData/World"
local CONFIG_PATH = "tools/export-world.config.json"
local PUBLISH_CONFIG_PATH = "tools/publish.config.json"
local RELAY_CONFIG_PATH = "src/ServerStorage/Dev/RelayConfig.luau"
local SCHEMA_KEY = "meta:schema_version"
local PAGE_SIZE = 800 -- provinces per baked page module (fixed id ranges keep diffs stable)

-- Kind table mirroring DataOverlay's key map. mode:
--   complete = full snapshot, tombstones dropped (v4 provinces/countries)
--   overlay  = merged onto seed modules at load; tombstones PRESERVED (they delete seeds)
--   map      = side tables read by ProvinceStamper, tombstones dropped
local KINDS = {
	{ kind = "province", key = "aggregate:provinces@v4", module = "Provinces", numeric = true, mode = "complete" },
	{ kind = "country", key = "aggregate:countries@v4", module = "Countries", numeric = false, mode = "complete" },
	{ kind = "culture", key = "aggregate:cultures", module = "Cultures", numeric = false, mode = "overlay" },
	{ kind = "religion", key = "aggregate:religions", module = "Religions", numeric = false, mode = "overlay" },
	{ kind = "ideology", key = "aggregate:ideologies", module = "Ideologies", numeric = false, mode = "overlay" },
	{
		kind = "government_type",
		key = "aggregate:government_types",
		module = "GovernmentTypes",
		numeric = false,
		mode = "overlay",
	},
	{ kind = "eu4map", key = "aggregate:eu4map", module = "EU4Map", numeric = true, mode = "map" },
	{ kind = "tile", key = "aggregate:tiles", module = "Tiles", numeric = false, mode = "map" },
}

-- ── CLI args ─────────────────────────────────────────────────────────────────────────────────────

local flags = { probe = false, edit = false, verify = false, dryRun = false }
local universeArg, datastoreArg, scopeArg
do
	local i = 1
	local args = process.args
	while i <= #args do
		local a = args[i]
		if a == "--probe" then
			flags.probe = true
		elseif a == "--edit" then
			flags.edit = true
		elseif a == "--verify" then
			flags.verify = true
		elseif a == "--dry-run" then
			flags.dryRun = true
		elseif a == "--universe" then
			i += 1
			universeArg = tonumber(args[i]) or error("--universe expects a numeric universe id")
		elseif a == "--datastore" then
			i += 1
			datastoreArg = args[i] or error("--datastore expects a name")
		elseif a == "--scope" then
			i += 1
			scopeArg = args[i] or error("--scope expects a scope")
		elseif a ~= "--" then
			error("unknown argument: " .. tostring(a))
		end
		i += 1
	end
end

-- ── Config resolution ────────────────────────────────────────────────────────────────────────────

local function parseRelayConfig()
	if not fs.isFile(RELAY_CONFIG_PATH) then
		return nil
	end
	local src = fs.readFile(RELAY_CONFIG_PATH)
	local ok, result = pcall(function()
		return luauRt.load(src)()
	end)
	if ok and type(result) == "table" and type(result.DATASTORE_NAME) == "string" then
		return { name = result.DATASTORE_NAME, scope = result.DATASTORE_SCOPE }
	end
	-- RelayConfig may reference Roblox globals Lune lacks — fall back to pattern matching.
	local name = src:match('DATASTORE_NAME%s*=%s*"([^"]+)"')
	local scope = src:match('DATASTORE_SCOPE%s*=%s*"([^"]*)"')
	if name then
		return { name = name, scope = scope }
	end
	return nil
end

local apiKey = process.env.ROBLOX_OPEN_CLOUD_KEY
if not apiKey or #apiKey == 0 then
	error("ROBLOX_OPEN_CLOUD_KEY is not set")
end

local relay = parseRelayConfig()
local datastoreName = datastoreArg or process.env.AOW_DATASTORE_NAME or (relay and relay.name)
local datastoreScope = scopeArg or process.env.AOW_DATASTORE_SCOPE or (relay and relay.scope)
if not datastoreName then
	error(
		"could not resolve the DataStore name: pass --datastore, set AOW_DATASTORE_NAME, or make sure "
			.. RELAY_CONFIG_PATH
			.. " exists locally"
	)
end

local toolConfig = {}
if fs.isFile(CONFIG_PATH) then
	toolConfig = serde.decode("json", fs.readFile(CONFIG_PATH))
end
local universeId = universeArg or tonumber(toolConfig.universeId)

-- ── Open Cloud entry reads ───────────────────────────────────────────────────────────────────────

local function urlEncode(s)
	return (tostring(s):gsub("[^%w%-%._~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function entryUrl(universe, key)
	local scopePart = ""
	if datastoreScope and #tostring(datastoreScope) > 0 then
		scopePart = "&scope=" .. urlEncode(datastoreScope)
	end
	return string.format(
		"https://apis.roblox.com/datastores/v1/universes/%s/standard-datastores/datastore/entries/entry?datastoreName=%s%s&entryKey=%s",
		tostring(universe),
		urlEncode(datastoreName),
		scopePart,
		urlEncode(key)
	)
end

-- Returns the decoded value or nil when the key doesn't exist. Aggregates are stored as
-- JSON-encoded STRINGS (DataOverlay SetAsyncs the encoded payload), so the Open Cloud body
-- decodes to a string that must be decoded a second time — mirror of DataOverlay.decodeValue.
local function getEntry(universe, key)
	local resp = net.request({
		url = entryUrl(universe, key),
		method = "GET",
		headers = { ["x-api-key"] = apiKey },
	})
	if resp.statusCode == 404 then
		return nil
	end
	if resp.statusCode == 401 or resp.statusCode == 403 then
		error(
			string.format(
				"Open Cloud key was rejected for universe %s (HTTP %d) — the key needs standard-DataStore READ permission for that universe: %s",
				tostring(universe),
				resp.statusCode,
				resp.body:sub(1, 300)
			)
		)
	end
	if not resp.ok then
		error(string.format("GET %s failed: HTTP %d %s", key, resp.statusCode, resp.body:sub(1, 300)))
	end
	local decoded = serde.decode("json", resp.body)
	if type(decoded) == "string" then
		local ok, inner = pcall(serde.decode, "json", decoded)
		if ok then
			return inner
		end
		return decoded
	end
	return decoded
end

local function schemaVersionOf(value)
	if type(value) == "table" and value.version ~= nil then
		return tostring(value.version)
	end
	if type(value) == "string" then
		return value
	end
	return nil
end

local function countRecords(map)
	local n = 0
	for _ in pairs(map) do
		n += 1
	end
	return n
end

-- ── Probe mode ───────────────────────────────────────────────────────────────────────────────────

if flags.probe then
	local candidates, seen = {}, {}
	local function addCandidate(id, label)
		id = tonumber(id)
		if id and id > 0 and not seen[id] then
			seen[id] = true
			table.insert(candidates, { id = id, label = label })
		end
	end
	addCandidate(universeId, "export-world.config.json")
	if fs.isFile(PUBLISH_CONFIG_PATH) then
		local publishConfig = serde.decode("json", fs.readFile(PUBLISH_CONFIG_PATH))
		for _, target in ipairs(publishConfig.targets or {}) do
			addCandidate(target.universeId, "publish target '" .. tostring(target.label) .. "'")
		end
	end
	if #candidates == 0 then
		error("no candidate universes: pass --universe or fill tools/publish.config.json")
	end
	print(string.format("probing datastore '%s' (scope '%s')", datastoreName, tostring(datastoreScope or "global")))
	for _, candidate in ipairs(candidates) do
		print(string.format("\nuniverse %d (%s):", candidate.id, candidate.label))
		local ok, err = pcall(function()
			local schema = schemaVersionOf(getEntry(candidate.id, SCHEMA_KEY))
			local provinces = getEntry(candidate.id, "aggregate:provinces@v4")
			local countries = getEntry(candidate.id, "aggregate:countries@v4")
			local provincesEdit = getEntry(candidate.id, "aggregate:provinces@v4:edit")
			print(string.format("  schema:            %s", tostring(schema)))
			print(
				string.format(
					"  provinces@v4:      %s records",
					type(provinces) == "table" and countRecords(provinces) or "no"
				)
			)
			print(
				string.format(
					"  countries@v4:      %s records",
					type(countries) == "table" and countRecords(countries) or "no"
				)
			)
			print(
				string.format(
					"  provinces@v4:edit: %s records",
					type(provincesEdit) == "table" and countRecords(provincesEdit) or "no"
				)
			)
		end)
		if not ok then
			print("  " .. tostring(err))
		end
	end
	print("\nset the authoritative universe id in " .. CONFIG_PATH .. " (the one with schema v4 + ~5713 provinces)")
	return
end

if not universeId or universeId <= 0 then
	error(
		"universe id not configured: run --probe to identify it, then set it in "
			.. CONFIG_PATH
			.. " or pass --universe"
	)
end

-- ── Fetch + normalize ────────────────────────────────────────────────────────────────────────────

local keyFamily = flags.edit and "edit" or "live"
local function familyKey(base)
	return flags.edit and (base .. ":edit") or base
end

local schema = schemaVersionOf(getEntry(universeId, SCHEMA_KEY))
if schema ~= "v4" then
	error(
		string.format(
			"store schema is '%s', but this exporter only supports v4 — refusing to bake (wrong universe, or the store migrated; update the exporter deliberately)",
			tostring(schema)
		)
	)
end

local worldByModule = {} -- module name -> normalized records table
for _, kindInfo in ipairs(KINDS) do
	local raw = getEntry(universeId, familyKey(kindInfo.key))
	if raw ~= nil and type(raw) ~= "table" then
		error(string.format("aggregate '%s' decoded to %s, expected table", kindInfo.key, type(raw)))
	end
	local records = {}
	for k, v in pairs(raw or {}) do
		local key = kindInfo.numeric and (tonumber(k) or k) or k
		if WorldNormalize.isTombstone(v) then
			if kindInfo.mode == "overlay" then
				records[key] = { __deleted = true } -- must survive the bake: deletes a seed record at load
			end
		else
			if kindInfo.kind == "province" then
				v = WorldNormalize.normalizeProvince(v)
			end
			records[key] = v
		end
	end
	worldByModule[kindInfo.module] = records
	print(string.format("fetched %-22s %5d records", familyKey(kindInfo.key), countRecords(records)))
end

if countRecords(worldByModule.Provinces) == 0 or countRecords(worldByModule.Countries) == 0 then
	error("provinces or countries came back empty — wrong universe/key family? refusing to bake a torn world")
end

-- ── Deterministic Luau serialization ─────────────────────────────────────────────────────────────

local LUA_KEYWORDS = {
	["and"] = true,
	["break"] = true,
	["do"] = true,
	["else"] = true,
	["elseif"] = true,
	["end"] = true,
	["false"] = true,
	["for"] = true,
	["function"] = true,
	["if"] = true,
	["in"] = true,
	["local"] = true,
	["nil"] = true,
	["not"] = true,
	["or"] = true,
	["repeat"] = true,
	["return"] = true,
	["then"] = true,
	["true"] = true,
	["until"] = true,
	["while"] = true,
	["continue"] = true,
}

local function isIdent(s)
	return type(s) == "string" and not LUA_KEYWORDS[s] and s:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local STRING_ESCAPES = { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function escapeString(s)
	return '"'
		.. s:gsub('[%c\\"]', function(c)
			return STRING_ESCAPES[c] or string.format("\\%03d", string.byte(c))
		end)
		.. '"'
end

local function fmtNumber(v)
	if v ~= v or v == math.huge or v == -math.huge then
		error("non-finite number in world data: " .. tostring(v))
	end
	if v % 1 == 0 and math.abs(v) <= 2 ^ 53 then
		return string.format("%d", v)
	end
	local s = string.format("%.14g", v)
	if tonumber(s) ~= v then
		s = string.format("%.17g", v)
	end
	return s
end

local function sortedKeys(t)
	local nums, strs = {}, {}
	for k in pairs(t) do
		if type(k) == "number" then
			table.insert(nums, k)
		else
			table.insert(strs, k)
		end
	end
	table.sort(nums)
	table.sort(strs)
	table.move(strs, 1, #strs, #nums + 1, nums)
	return nums
end

local function isArray(t)
	local n = #t
	local count = 0
	for k in pairs(t) do
		if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > n then
			return false
		end
		count += 1
	end
	return count == n
end

local function serializeValue(v)
	local vt = type(v)
	if vt == "string" then
		return escapeString(v)
	elseif vt == "number" then
		return fmtNumber(v)
	elseif vt == "boolean" then
		return tostring(v)
	elseif vt == "table" then
		if isArray(v) then
			if #v == 0 then
				return "{}"
			end
			local parts = {}
			for _, item in ipairs(v) do
				table.insert(parts, serializeValue(item))
			end
			return "{ " .. table.concat(parts, ", ") .. " }"
		end
		local parts = {}
		for _, k in ipairs(sortedKeys(v)) do
			local keyStr
			if type(k) == "number" then
				keyStr = "[" .. fmtNumber(k) .. "]"
			elseif isIdent(k) then
				keyStr = k
			else
				keyStr = "[" .. escapeString(k) .. "]"
			end
			table.insert(parts, keyStr .. " = " .. serializeValue(v[k]))
		end
		return "{ " .. table.concat(parts, ", ") .. " }"
	end
	error("unsupported value type in world data: " .. vt)
end

local function buildModuleSource(label, records)
	local lines = {
		string.format("-- BAKED world data (%s) — generated by tools/export-world.luau from the v4 DataStore", label),
		"-- aggregate. DO NOT hand-edit; re-run `lune run tools/export-world` to refresh.",
		"return {",
	}
	for _, k in ipairs(sortedKeys(records)) do
		local keyStr
		if type(k) == "number" then
			keyStr = "[" .. fmtNumber(k) .. "]"
		elseif isIdent(k) then
			keyStr = k
		else
			keyStr = "[" .. escapeString(k) .. "]"
		end
		table.insert(lines, "\t" .. keyStr .. " = " .. serializeValue(records[k]) .. ",")
	end
	table.insert(lines, "}")
	table.insert(lines, "")
	return table.concat(lines, "\n")
end

-- ── Plan output files ────────────────────────────────────────────────────────────────────────────

local planned = {} -- filename (no extension) -> { source, records }

-- Provinces: fixed 800-id pages so page membership never shifts between exports.
local provincePages = {} -- pageName -> records
for id, rec in pairs(worldByModule.Provinces) do
	local numericId = tonumber(id)
	local pageIndex = numericId and math.max(0, math.floor((numericId - 1) / PAGE_SIZE)) or 0
	local pageName = string.format("Provinces_%05d_%05d", pageIndex * PAGE_SIZE + 1, (pageIndex + 1) * PAGE_SIZE)
	provincePages[pageName] = provincePages[pageName] or {}
	provincePages[pageName][id] = rec
end
local pageNames = sortedKeys(provincePages)
for _, pageName in ipairs(pageNames) do
	planned[pageName] =
		{ source = buildModuleSource(pageName, provincePages[pageName]), records = provincePages[pageName] }
end
for _, kindInfo in ipairs(KINDS) do
	if kindInfo.module ~= "Provinces" then
		planned[kindInfo.module] = {
			source = buildModuleSource(kindInfo.module, worldByModule[kindInfo.module]),
			records = worldByModule[kindInfo.module],
		}
	end
end

-- ── Diff against disk, write ─────────────────────────────────────────────────────────────────────

local function normalizeNewlines(s)
	return (s:gsub("\r\n", "\n"))
end

local existing = {}
if fs.isDir(OUT_DIR) then
	for _, entry in ipairs(fs.readDir(OUT_DIR)) do
		if entry:sub(-5) == ".luau" then
			existing[entry:sub(1, -6)] = true
		end
	end
end

local changed, stalePages = {}, {}
for name, plan in pairs(planned) do
	local path = OUT_DIR .. "/" .. name .. ".luau"
	if not fs.isFile(path) or normalizeNewlines(fs.readFile(path)) ~= plan.source then
		table.insert(changed, name)
	end
end
for name in pairs(existing) do
	if name:match("^Provinces_") and not planned[name] then
		table.insert(stalePages, name)
	end
end
table.sort(changed)
table.sort(stalePages)

if #changed == 0 and #stalePages == 0 then
	print("\nno changes — baked world already matches the store; nothing written")
else
	if flags.dryRun then
		print(string.format("\ndry-run: would write %d module(s), delete %d stale page(s)", #changed, #stalePages))
		for _, name in ipairs(changed) do
			print("  write  " .. name .. ".luau")
		end
		for _, name in ipairs(stalePages) do
			print("  delete " .. name .. ".luau")
		end
	else
		if not fs.isDir(OUT_DIR) then
			fs.writeDir(OUT_DIR)
		end
		for _, name in ipairs(changed) do
			fs.writeFile(OUT_DIR .. "/" .. name .. ".luau", planned[name].source)
			print("wrote  " .. name .. ".luau")
		end
		for _, name in ipairs(stalePages) do
			fs.removeFile(OUT_DIR .. "/" .. name .. ".luau")
			print("removed stale " .. name .. ".luau")
		end
		local counts = {}
		for _, kindInfo in ipairs(KINDS) do
			counts[kindInfo.module] = countRecords(worldByModule[kindInfo.module])
		end
		local meta = {
			schemaVersion = schema,
			universeId = universeId,
			keyFamily = keyFamily,
			exportedAt = os.time(),
			exportedAtIso = os.date("!%Y-%m-%dT%H:%M:%SZ"),
			counts = counts,
			pages = pageNames,
		}
		fs.writeFile(OUT_DIR .. "/_meta.luau", buildModuleSource("_meta", meta))
		print("wrote  _meta.luau")
	end
end

-- ── Verify (parity: written source round-trips to the fetched data) ──────────────────────────────

if flags.verify then
	local function deepEquals(a, b, path)
		if a == b then
			return true
		end
		if type(a) ~= "table" or type(b) ~= "table" then
			return false, string.format("%s: %s ~= %s", path, tostring(a), tostring(b))
		end
		for k, v in pairs(a) do
			local ok, why = deepEquals(v, b[k], path .. "." .. tostring(k))
			if not ok then
				return false, why
			end
		end
		for k in pairs(b) do
			if a[k] == nil then
				return false, path .. "." .. tostring(k) .. ": missing on left"
			end
		end
		return true
	end

	local mismatches = 0
	for name, plan in pairs(planned) do
		local loaded = luauRt.load(plan.source, { debugName = name })()
		local ok, why = deepEquals(plan.records, loaded, name)
		if not ok then
			mismatches += 1
			print("VERIFY MISMATCH: " .. tostring(why))
		end
	end

	-- Reference scan: country tags referenced by provinces must exist in the baked countries
	-- (countries are a COMPLETE snapshot; culture/religion refs are not checked here because
	-- their baked modules are overlays on seed data the exporter can't see).
	local tags = worldByModule.Countries
	local danglingTags = 0
	local function checkTag(tag, label)
		if type(tag) == "string" and tag ~= "" and tag ~= "NONE" and tags[tag] == nil then
			danglingTags += 1
			if danglingTags <= 20 then
				print("VERIFY WARNING: " .. label .. " references unknown country '" .. tag .. "'")
			end
		end
	end
	for id, rec in pairs(worldByModule.Provinces) do
		if type(rec) == "table" then
			checkTag(rec.ownerTag, "province " .. tostring(id) .. ".ownerTag")
			checkTag(rec.controllerTag, "province " .. tostring(id) .. ".controllerTag")
			for _, field in ipairs({ "cores", "defaultCores", "releasableCores", "claims" }) do
				if type(rec[field]) == "table" then
					for _, tag in ipairs(rec[field]) do
						checkTag(tag, "province " .. tostring(id) .. "." .. field)
					end
				end
			end
		end
	end
	if danglingTags > 20 then
		print(string.format("VERIFY WARNING: ... and %d more dangling country refs", danglingTags - 20))
	end

	if mismatches > 0 then
		error(string.format("verification FAILED: %d module(s) did not round-trip", mismatches))
	end
	print(
		string.format(
			"verified: %d modules round-trip exactly%s",
			countRecords(planned),
			danglingTags > 0 and string.format(" (%d dangling country-ref warnings)", danglingTags) or ""
		)
	)
end
