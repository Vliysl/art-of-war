local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")

local RelayConfig = require(ServerStorage:WaitForChild("Dev"):WaitForChild("RelayConfig"))
local RunService = game:GetService("RunService")

-- ── Editor vs Live world isolation ───────────────────────────────────────────────────────────────
-- The Map Editor place (and Studio) must never edit the live game world directly. In an editor
-- environment EVERY aggregate read/write is redirected to a parallel ":edit" key set (see keyFor),
-- seeded from the live keys the first time it is empty. The main game reads the un-suffixed live keys
-- and is never touched by editing; only an explicit DataOverlay.pushEditToLive() copies edit -> live.
local MAP_EDITOR_PLACE_ID = 104399454095233
do
	local ok, wc = pcall(function()
		return require(game:GetService("ReplicatedStorage").ArtOfWar.Shared.WorldConstants)
	end)
	if ok and type(wc) == "table" and tonumber(wc.MapEditorPlaceId) then
		MAP_EDITOR_PLACE_ID = tonumber(wc.MapEditorPlaceId)
	end
end
local IS_EDITOR_ENV = (game.PlaceId == MAP_EDITOR_PLACE_ID) or RunService:IsStudio()
local EDIT_SUFFIX = ":edit"

-- DataStore per-key value cap is ~4 MB. Stay well under so an oversized aggregate fails loudly with a
-- clear error instead of erroring at the API (or appearing to save). See writeAggregateToKey.
local MAX_AGGREGATE_BYTES = 3900000

local DataOverlay = {}

local KIND_COUNTRIES = "country"
local KIND_PROVINCES = "province"
local KIND_EU4MAP = "eu4map"
local KIND_TILES = "tile"
local KIND_CULTURES = "culture"
local KIND_RELIGIONS = "religion"
local KIND_IDEOLOGIES = "ideology"
local KIND_GOVERNMENTS = "government_type"

local AGGREGATE_KEYS = {
	[KIND_COUNTRIES] = "aggregate:countries",
	[KIND_PROVINCES] = "aggregate:provinces",
	[KIND_EU4MAP] = "aggregate:eu4map",
	[KIND_TILES] = "aggregate:tiles",
	[KIND_CULTURES] = "aggregate:cultures",
	[KIND_RELIGIONS] = "aggregate:religions",
	[KIND_IDEOLOGIES] = "aggregate:ideologies",
	[KIND_GOVERNMENTS] = "aggregate:government_types",
}

local ALL_KINDS = {
	KIND_COUNTRIES,
	KIND_PROVINCES,
	KIND_EU4MAP,
	KIND_TILES,
	KIND_CULTURES,
	KIND_RELIGIONS,
	KIND_IDEOLOGIES,
	KIND_GOVERNMENTS,
}

local SCHEMA_KEY = "meta:schema_version"
local SCHEMA_VERSION = "v2"

-- Identity-collapse (Phase C) schema. When the stored schema == COLLAPSED_VERSION the world is
-- keyed by the map PART id (prov_<N>): provinces/countries are read from parallel "@v3" keys while
-- the original serial-keyed v2 keys are left completely intact, so a rollback is a single schema
-- flag flip. eu4Map is no longer consulted (the part number IS the id).
local COLLAPSED_VERSION = "v3"
local COLLAPSED_KEYS = {
	[KIND_PROVINCES] = "aggregate:provinces@v3",
	[KIND_COUNTRIES] = "aggregate:countries@v3",
}
local PROVMAP_KEY = "aggregate:provmap@v3" -- partId -> serialId (inverse lineage)
local MIGRATION_META_KEY = "meta:migration@v3"

-- Phase 1B — v3 -> v4 store migration. v4 is the unified province/country store: provinces gain
-- cores/defaultCores/claims defaults and countries DROP the dormant acceptedCultures field. As with
-- the v3 collapse, the v4 writers are ADDITIVE — they write parallel "@v4" keys and NEVER touch the
-- @v3 keys, so the schema flag flip (commitV4) is the single atomic commit and rollbackV4 is a flip
-- back to the frozen, untouched @v3 data. Non-province/country kinds keep their shared keys.
local V4_VERSION = "v4"
local V4_KEYS = {
	[KIND_PROVINCES] = "aggregate:provinces@v4",
	[KIND_COUNTRIES] = "aggregate:countries@v4",
}
local MIGRATION_META_KEY_V4 = "meta:migration@v4"

local TOMBSTONE_MARKER = { __deleted = true }
DataOverlay.TOMBSTONE = TOMBSTONE_MARKER

local MAX_RETRIES = 5
local BASE_BACKOFF = 0.5
local SCAN_PACE = 0.12
local FLUSH_COOLDOWN = 30
local MIGRATE_COOLDOWN = 30
local SCAN_PAGE_LIMIT = 10

-- Concurrency-safe saves. When true, flush() UpdateAsync-MERGES each session's per-record changes into
-- the CURRENT DataStore aggregate instead of SetAsync-overwriting the whole aggregate with this server's
-- (session-start) in-memory copy. Fixes the two-editor lost update: with the blind overwrite, an editor
-- who loaded before a co-editor saved would revert the co-editor's work on their own next save (e.g.
-- "adding N. American tribes, then a Europe edit reverts the tribes"). Each Roblox server instance has
-- its own cache, and editors rarely share an instance, so this raced constantly. Flip to false to restore
-- the legacy blind overwrite. Same-record simultaneous edits remain last-writer-wins (needs locking to fix).
local MERGE_SAVES = true

-- Per-record change journals (cache.pending[kind][key] = record | TOMBSTONE_MARKER) powering MERGE_SAVES:
-- exactly which records THIS session changed since its last successful flush.
local function freshPending()
	local p = {}
	for _, kind in ipairs(ALL_KINDS) do
		p[kind] = {}
	end
	return p
end

local cache = {
	loaded = false,
	data = {
		[KIND_COUNTRIES] = {},
		[KIND_PROVINCES] = {},
		[KIND_EU4MAP] = {},
		[KIND_TILES] = {},
		[KIND_CULTURES] = {},
		[KIND_RELIGIONS] = {},
		[KIND_IDEOLOGIES] = {},
		[KIND_GOVERNMENTS] = {},
	},
	loadStatus = {
		[KIND_COUNTRIES] = nil,
		[KIND_PROVINCES] = nil,
		[KIND_EU4MAP] = nil,
		[KIND_TILES] = nil,
		[KIND_CULTURES] = nil,
		[KIND_RELIGIONS] = nil,
		[KIND_IDEOLOGIES] = nil,
		[KIND_GOVERNMENTS] = nil,
	},
	lastRetryAt = {},
	dirty = {},
	coolingUntil = {},
	migrated = false,
	migrating = false,
	collapsed = false, -- true when schema == COLLAPSED_VERSION (part-id keyed world)
	schemaVersion = nil, -- live schema flag as read by load() ("v2" / "v3" / "v4" / nil)
	pending = freshPending(), -- per-record change journal for the MERGE_SAVES flush path
}

-- Resolve the live DataStore key for a kind, honoring the live schema. cache.schemaVersion /
-- cache.collapsed are set by load() (which reads the schema flag FIRST) before any read/write runs.
-- Precedence: v4 remaps provinces/countries to @v4; else v3 remaps them to @v3; else shared keys.
local function liveKeyFor(kind)
	if cache.schemaVersion == V4_VERSION and V4_KEYS[kind] then
		return V4_KEYS[kind]
	end
	if cache.collapsed and COLLAPSED_KEYS[kind] then
		return COLLAPSED_KEYS[kind]
	end
	return AGGREGATE_KEYS[kind]
end

-- The key THIS environment reads/writes. In an editor environment (Map Editor place or Studio) every
-- aggregate is redirected to a parallel ":edit" key so editing never touches the live game world; the
-- main game uses the un-suffixed live key. pushEditToLive() uses liveKeyFor to publish edit -> live.
local function keyFor(kind)
	local base = liveKeyFor(kind)
	if IS_EDITOR_ENV then
		return base .. EDIT_SUFFIX
	end
	return base
end

local lastMigrateAt = 0

local migrationListeners = {}

local function store()
	return DataStoreService:GetDataStore(RelayConfig.DATASTORE_NAME, RelayConfig.DATASTORE_SCOPE)
end

local function decodeValue(raw)
	if raw == nil then
		return nil
	end
	if type(raw) == "string" then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
		if ok then
			return decoded
		end
		return nil
	end
	return raw
end

local function isTombstone(value)
	return type(value) == "table" and value.__deleted == true
end

local function numericKeyFor(kind)
	return kind == KIND_PROVINCES or kind == KIND_EU4MAP
end

local function coerceKey(kind, k)
	if numericKeyFor(kind) then
		return tonumber(k) or k
	end
	return k
end

local function isThrottleError(err)
	local s = tostring(err or ""):lower()
	return s:find("throttl", 1, true) ~= nil
		or s:find("toomanyrequests", 1, true) ~= nil
		or s:find("too many requests", 1, true) ~= nil
		or s:find("queue full", 1, true) ~= nil
		or s:find("queue, further requests will be dropped", 1, true) ~= nil
		or s:find("301:", 1, true) ~= nil
		or s:find("302:", 1, true) ~= nil
		or s:find("502:", 1, true) ~= nil
end

local function withRetry(op, label, attempts)
	attempts = attempts or MAX_RETRIES
	local lastErr
	for attempt = 1, attempts do
		local ok, result = pcall(op)
		if ok then
			return true, result
		end
		lastErr = result
		if isThrottleError(result) then
			warn(
				string.format(
					"[DataOverlay] %s throttled — abandoning at attempt %d/%d to let the queue drain",
					label,
					attempt,
					attempts
				)
			)
			return false, lastErr
		end
		if attempt < attempts then
			task.wait(BASE_BACKOFF * (2 ^ (attempt - 1)))
		end
	end
	warn(string.format("[DataOverlay] %s failed after %d attempts: %s", label, attempts, tostring(lastErr)))
	return false, lastErr
end

local function readAggregate(kind, overrideKey)
	local ds = store()
	local k = overrideKey or keyFor(kind)
	local ok, raw = withRetry(function()
		return ds:GetAsync(k)
	end, "GetAsync " .. k)
	if not ok then
		return {}, "read_failed"
	end
	if raw == nil then
		return {}, "empty"
	end
	local decoded = decodeValue(raw)
	if type(decoded) ~= "table" then
		return {}, "empty"
	end
	local out = {}
	for k, v in pairs(decoded) do
		out[coerceKey(kind, k)] = v
	end
	return out, "loaded"
end

local function writeAggregateToKey(k, kind, map)
	local ds = store()
	local serializable = {}
	for key, v in pairs(map) do
		serializable[tostring(key)] = v
	end
	local encodeOk, payload = pcall(HttpService.JSONEncode, HttpService, serializable)
	if not encodeOk then
		warn("[DataOverlay] failed to encode " .. kind .. ": " .. tostring(payload))
		return false, "encode_failed"
	end
	if #payload > MAX_AGGREGATE_BYTES then
		local msg = string.format(
			"aggregate '%s' is %d bytes, over the %d-byte safety limit (DataStore ~4MB cap) — refusing to write so it can't silently fail; the store needs chunking",
			kind,
			#payload,
			MAX_AGGREGATE_BYTES
		)
		warn("[DataOverlay] " .. msg)
		return false, msg
	end
	return withRetry(function()
		ds:SetAsync(k, payload)
	end, "SetAsync " .. k)
end

local function writeAggregate(kind, map)
	return writeAggregateToKey(keyFor(kind), kind, map)
end

-- Concurrency-safe aggregate write for MERGE_SAVES. UpdateAsync reads the CURRENT stored aggregate and
-- overlays ONLY this session's journaled records, so a save can never revert records a co-editor persisted
-- meanwhile -- only the exact keys in `pending` are touched. The transform is pure (table merge + JSON, no
-- yields) as UpdateAsync requires, and re-runs automatically if the value changed between read and write.
-- Returns ok, err, mergedTable (the post-merge value, for refreshing the in-memory cache).
local function writeAggregateMerged(kind, pending)
	local ds = store()
	local k = keyFor(kind)
	local merged
	local ok, err = withRetry(function()
		return ds:UpdateAsync(k, function(raw)
			local current = decodeValue(raw)
			if type(current) ~= "table" then
				current = {}
			end
			-- Stored aggregates are string-keyed (JSON); journal keys may be numeric (province ids). A
			-- record value already carries TOMBSTONE_MARKER for a delete, so a single assignment covers both.
			for key, value in pairs(pending) do
				current[tostring(key)] = value
			end
			merged = current
			local encodeOk, payload = pcall(HttpService.JSONEncode, HttpService, current)
			if not encodeOk then
				error("encode_failed: " .. tostring(payload))
			end
			if #payload > MAX_AGGREGATE_BYTES then
				error(
					string.format(
						"aggregate '%s' too large: %d > %d bytes (DataStore ~4MB cap) — needs chunking",
						kind,
						#payload,
						MAX_AGGREGATE_BYTES
					)
				)
			end
			return payload
		end)
	end, "UpdateAsync " .. k)
	return ok, err, merged
end

local function readSchemaVersion()
	local ds = store()
	local ok, raw = withRetry(function()
		return ds:GetAsync(SCHEMA_KEY)
	end, "GetAsync " .. SCHEMA_KEY, 3)
	if not ok then
		return nil
	end
	if type(raw) == "string" then
		local decoded = decodeValue(raw)
		if type(decoded) == "string" then
			return decoded
		end
		if type(decoded) == "table" and decoded.version then
			return tostring(decoded.version)
		end
		return raw
	end
	return nil
end

local function writeSchemaVersion(version)
	local ds = store()
	local payload = HttpService:JSONEncode({ version = version, stampedAt = os.time() })
	return withRetry(function()
		ds:SetAsync(SCHEMA_KEY, payload)
	end, "SetAsync " .. SCHEMA_KEY, 3)
end

local retryFailedKinds -- forward declaration, assigned below

local function ensureLoaded()
	if not cache.loaded then
		DataOverlay.load()
	end
	if retryFailedKinds then
		retryFailedKinds()
	end
end

function DataOverlay.kindLoaded(kind)
	return cache.loadStatus[kind] == "loaded" or cache.loadStatus[kind] == "empty"
end

function DataOverlay.loadStatuses()
	local out = {}
	for _, kind in ipairs(ALL_KINDS) do
		out[kind] = cache.loadStatus[kind]
	end
	return out
end

local function scanLegacyKeys(kind, onEntry)
	local ds = store()
	local out = {}
	local listOk, page = withRetry(function()
		return ds:ListKeysAsync(kind .. ":", 100)
	end, "ListKeysAsync " .. kind, 2)
	if not listOk or not page then
		return out
	end

	local pages = 0
	while page and pages < SCAN_PAGE_LIMIT do
		pages += 1
		local entries = page:GetCurrentPage()
		for _, info in ipairs(entries) do
			local name = info.KeyName
			local kindPart, rest = name:match("^([^:]+):(.+)$")
			if kindPart == kind and rest then
				local readOk, raw = withRetry(function()
					return ds:GetAsync(name)
				end, "legacy GetAsync " .. name, 1)
				if readOk and raw ~= nil then
					local decoded = decodeValue(raw)
					if decoded ~= nil and not isTombstone(decoded) then
						local key = coerceKey(kind, rest)
						out[key] = decoded
						if onEntry then
							onEntry(key, decoded)
						end
					end
				end
				task.wait(SCAN_PACE)
			end
		end
		if page.IsFinished then
			break
		end
		local advOk, advErr = pcall(function()
			page:AdvanceToNextPageAsync()
		end)
		if not advOk then
			if advErr then
				warn(string.format("[DataOverlay] AdvanceToNextPageAsync %s failed: %s", kind, tostring(advErr)))
			end
			break
		end
	end
	return out
end

local LOAD_RETRY_INTERVAL = 30

function DataOverlay.load()
	if cache.loaded then
		return cache
	end
	-- Read the schema flag FIRST: cache.collapsed selects which key family every aggregate read
	-- below uses (v2 serial keys vs the @v3 part-id keys). Committing to ONE family per boot.
	local schema = readSchemaVersion()
	cache.schemaVersion = schema
	-- v4 is built on top of the part-id-keyed world, so it is "collapsed" in the applyTo sense
	-- (provinces/countries are authoritative + part-id keyed, source is discarded) just like v3.
	cache.collapsed = (schema == COLLAPSED_VERSION) or (schema == V4_VERSION)
	cache.migrated = (schema == SCHEMA_VERSION) or cache.collapsed
	local kinds = ALL_KINDS
	for _, kind in ipairs(kinds) do
		local data, status = readAggregate(kind)
		if IS_EDITOR_ENV and status == "empty" and next(data) == nil then
			-- First time editing: the ":edit" world is empty, so seed it from the live world (read the
			-- un-suffixed live key) so editors start from the current published map. Held in memory only;
			-- it persists to ":edit" on the first save. Never auto-writes at boot.
			local liveData, liveStatus = readAggregate(kind, liveKeyFor(kind))
			if liveStatus == "loaded" and next(liveData) ~= nil then
				data = liveData
				status = "seeded_from_live"
			end
		end
		cache.data[kind] = data
		cache.loadStatus[kind] = status
		cache.lastRetryAt[kind] = os.clock()
	end
	cache.loaded = true
	local function tally(t)
		local n = 0
		for _ in pairs(t or {}) do
			n += 1
		end
		return n
	end
	local anyFailed = false
	for _, kind in ipairs(kinds) do
		if cache.loadStatus[kind] == "read_failed" then
			anyFailed = true
			break
		end
	end
	local function tallyOrMark(kind)
		return cache.loadStatus[kind] == "read_failed" and "?" or tostring(tally(cache.data[kind]))
	end
	if anyFailed then
		warn(
			string.format(
				"[DataOverlay] universe=%s gameId=%d — partial load (some aggregates throttled): %sC %sP %sM %sT %sCu %sRe — DataStore is preserved; will retry on next access. Saves are guarded — failed kinds will not be flushed until reload succeeds.",
				tostring(RelayConfig.universeLabel()),
				game.GameId,
				tallyOrMark(KIND_COUNTRIES),
				tallyOrMark(KIND_PROVINCES),
				tallyOrMark(KIND_EU4MAP),
				tallyOrMark(KIND_TILES),
				tallyOrMark(KIND_CULTURES),
				tallyOrMark(KIND_RELIGIONS)
			)
		)
	else
		print(
			string.format(
				"[DataOverlay] universe=%s gameId=%d — DataStore loaded: %dC %dP %dM %dT %dCu %dRe (preserved across publish; place files do not touch DataStore)",
				tostring(RelayConfig.universeLabel()),
				game.GameId,
				tally(cache.data[KIND_COUNTRIES]),
				tally(cache.data[KIND_PROVINCES]),
				tally(cache.data[KIND_EU4MAP]),
				tally(cache.data[KIND_TILES]),
				tally(cache.data[KIND_CULTURES]),
				tally(cache.data[KIND_RELIGIONS])
			)
		)
	end
	return cache
end

retryFailedKinds = function()
	local now = os.clock()
	for _, kind in ipairs(ALL_KINDS) do
		if cache.loadStatus[kind] == "read_failed" then
			local last = cache.lastRetryAt[kind] or 0
			if now - last >= LOAD_RETRY_INTERVAL then
				cache.lastRetryAt[kind] = now
				local data, status = readAggregate(kind)
				if status == "loaded" or status == "empty" then
					cache.data[kind] = data
					cache.loadStatus[kind] = status
					print(
						string.format(
							"[DataOverlay] %s recovered after throttle (now %s)",
							kind,
							status == "loaded" and "loaded" or "confirmed empty"
						)
					)
				end
			end
		end
	end
end

function DataOverlay.retryNow()
	local recovered = 0
	for _, kind in ipairs(ALL_KINDS) do
		if cache.loadStatus[kind] == "read_failed" then
			cache.lastRetryAt[kind] = os.clock()
			local data, status = readAggregate(kind)
			if status == "loaded" or status == "empty" then
				cache.data[kind] = data
				cache.loadStatus[kind] = status
				recovered += 1
			end
		end
	end
	return recovered
end

function DataOverlay.onMigrated(callback)
	if type(callback) ~= "function" then
		return function() end
	end
	table.insert(migrationListeners, callback)
	return function()
		for i, cb in ipairs(migrationListeners) do
			if cb == callback then
				table.remove(migrationListeners, i)
				return
			end
		end
	end
end

local function fireMigrated(report)
	for _, cb in ipairs(migrationListeners) do
		local ok, err = pcall(cb, report)
		if not ok then
			warn("[DataOverlay] migration listener errored: " .. tostring(err))
		end
	end
end

local function mergeLegacy()
	local report = { countries = 0, provinces = 0, eu4map = 0, tiles = 0, cultures = 0, religions = 0 }
	local kinds = ALL_KINDS
	for _, kind in ipairs(kinds) do
		local legacy = scanLegacyKeys(kind)
		local merged = 0
		for k, v in pairs(legacy) do
			if cache.data[kind][k] == nil then
				cache.data[kind][k] = v
				merged += 1
			end
		end
		if kind == KIND_COUNTRIES then
			report.countries = merged
		elseif kind == KIND_PROVINCES then
			report.provinces = merged
		elseif kind == KIND_EU4MAP then
			report.eu4map = merged
		elseif kind == KIND_TILES then
			report.tiles = merged
		elseif kind == KIND_CULTURES then
			report.cultures = merged
		elseif kind == KIND_RELIGIONS then
			report.religions = merged
		end
		if merged > 0 then
			cache.dirty[kind] = true
		end
	end
	return report
end

local function emptyReport()
	return { countries = 0, provinces = 0, eu4map = 0, tiles = 0, cultures = 0, religions = 0 }
end

function DataOverlay.migrateLegacy()
	ensureLoaded()
	if cache.migrating then
		local r = emptyReport()
		r.busy = true
		return r
	end
	local now = os.clock()
	local elapsed = now - lastMigrateAt
	if elapsed < MIGRATE_COOLDOWN then
		local r = emptyReport()
		r.cooldown = math.ceil(MIGRATE_COOLDOWN - elapsed)
		return r
	end
	cache.migrating = true
	lastMigrateAt = now
	local ok, reportOrErr = pcall(mergeLegacy)
	cache.migrating = false
	if not ok then
		local r = emptyReport()
		r.error = tostring(reportOrErr)
		return r
	end
	return reportOrErr
end

function DataOverlay.hasMigrationMarker()
	ensureLoaded()
	return cache.migrated == true
end

local function aggregatesPopulated()
	for _, kind in ipairs(ALL_KINDS) do
		if next(cache.data[kind]) ~= nil then
			return true
		end
	end
	return false
end

function DataOverlay.autoMigrate()
	ensureLoaded()
	if cache.migrating then
		return
	end
	if cache.migrated and aggregatesPopulated() then
		return
	end
	local now = os.clock()
	if now - lastMigrateAt < MIGRATE_COOLDOWN then
		return
	end
	cache.migrating = true
	lastMigrateAt = now
	task.spawn(function()
		local startedAt = os.clock()
		local mergeOk, report = pcall(mergeLegacy)
		if not mergeOk then
			warn("[DataOverlay] auto-migration mergeLegacy errored: " .. tostring(report))
			report = emptyReport()
		end
		local flushOk, flush = pcall(DataOverlay.flush)
		if not flushOk then
			warn("[DataOverlay] auto-migration flush errored: " .. tostring(flush))
			flush = { attempted = 0, writes = 0, failures = 1, errors = {} }
		end
		if flush.failures == 0 then
			writeSchemaVersion(SCHEMA_VERSION)
			cache.migrated = true
		end
		cache.migrating = false
		local elapsed = math.floor((os.clock() - startedAt) * 10) / 10
		print(
			string.format(
				"[DataOverlay] auto-migration complete in %ss: +%dC +%dP +%dM +%dT +%dCu +%dRe (flush %d/%d, skipped %d)",
				tostring(elapsed),
				report.countries,
				report.provinces,
				report.eu4map,
				report.tiles,
				report.cultures or 0,
				report.religions or 0,
				flush.writes or 0,
				flush.attempted or 0,
				flush.skipped or 0
			)
		)
		fireMigrated({
			report = report,
			flush = flush,
			elapsed = elapsed,
		})
	end)
end

local function set(kind, key, value)
	ensureLoaded()
	if value == nil then
		cache.data[kind][key] = TOMBSTONE_MARKER
	else
		cache.data[kind][key] = value
	end
	cache.dirty[kind] = true
	-- Journal the exact record this session touched (upsert or tombstone) so flush() can UpdateAsync-merge
	-- only these into the live aggregate rather than blind-overwriting the whole thing (the co-editor
	-- clobber fix). Mirrors cache.data's value: the record, or TOMBSTONE_MARKER for a delete.
	local journal = cache.pending[kind]
	if journal then
		journal[key] = cache.data[kind][key]
	end
	return true
end

function DataOverlay.setCountry(tag, value)
	return set(KIND_COUNTRIES, tag, value)
end
function DataOverlay.setCulture(id, value)
	return set(KIND_CULTURES, id, value)
end
function DataOverlay.setReligion(id, value)
	return set(KIND_RELIGIONS, id, value)
end
function DataOverlay.setProvince(id, value)
	return set(KIND_PROVINCES, tonumber(id) or id, value)
end
function DataOverlay.setEU4Map(id, value)
	return set(KIND_EU4MAP, tonumber(id) or id, value)
end
function DataOverlay.setTile(name, value)
	return set(KIND_TILES, name, value)
end
function DataOverlay.setIdeology(id, value)
	return set(KIND_IDEOLOGIES, id, value)
end
function DataOverlay.setGovernmentType(id, value)
	return set(KIND_GOVERNMENTS, id, value)
end
function DataOverlay.deleteCountry(tag)
	return set(KIND_COUNTRIES, tag, nil)
end
function DataOverlay.deleteCulture(id)
	return set(KIND_CULTURES, id, nil)
end
function DataOverlay.deleteReligion(id)
	return set(KIND_RELIGIONS, id, nil)
end
function DataOverlay.deleteProvince(id)
	return set(KIND_PROVINCES, tonumber(id) or id, nil)
end
function DataOverlay.deleteEU4Map(id)
	return set(KIND_EU4MAP, tonumber(id) or id, nil)
end
function DataOverlay.deleteTile(name)
	return set(KIND_TILES, name, nil)
end
function DataOverlay.deleteIdeology(id)
	return set(KIND_IDEOLOGIES, id, nil)
end
function DataOverlay.deleteGovernmentType(id)
	return set(KIND_GOVERNMENTS, id, nil)
end

function DataOverlay.flush()
	ensureLoaded()
	local now = os.clock()
	local result = { attempted = 0, writes = 0, failures = 0, skipped = 0, blocked = 0, errors = {} }
	local toClear = {}
	for kind in pairs(cache.dirty) do
		local pending = cache.pending[kind]
		local useMerge = MERGE_SAVES and pending ~= nil and next(pending) ~= nil
		local loadFailed = cache.loadStatus[kind] == "read_failed"
		local cacheEmpty = next(cache.data[kind]) == nil
		-- The blind-overwrite path would wipe real data if our local cache is empty because a read failed.
		-- The merge path is immune -- UpdateAsync reads the live aggregate and overlays only the journaled
		-- records, so it can never overwrite with nothing -- so only block the non-merge path.
		if loadFailed and cacheEmpty and not useMerge then
			result.blocked += 1
			result.failures += 1
			table.insert(result.errors, {
				kind = kind,
				error = "refusing to flush: the existing aggregate could not be read AND local cache is empty — flushing now would overwrite real DataStore data with nothing. Wait for the retry to succeed (logged when it does), then save again.",
			})
		else
			local cooldownEnd = cache.coolingUntil[kind]
			if cooldownEnd and now < cooldownEnd then
				result.skipped += 1
				result.failures += 1
				table.insert(result.errors, {
					kind = kind,
					error = string.format("cooling for %ds after recent throttle", math.ceil(cooldownEnd - now)),
				})
			else
				result.attempted += 1
				local ok, err, merged
				if useMerge then
					ok, err, merged = writeAggregateMerged(kind, pending)
				else
					ok, err = writeAggregate(kind, cache.data[kind])
				end
				if ok then
					result.writes += 1
					cache.coolingUntil[kind] = nil
					toClear[kind] = true
					if useMerge then
						-- Adopt the merged result so our in-memory view reflects co-editors' concurrent changes
						-- too, and drop the now-persisted journal. Re-key to the cache's canonical key type
						-- (numeric for provinces/eu4map) so downstream reads stay consistent.
						if type(merged) == "table" then
							local adopted = {}
							for key, value in pairs(merged) do
								adopted[coerceKey(kind, key)] = value
							end
							cache.data[kind] = adopted
						end
						cache.pending[kind] = {}
					end
				else
					result.failures += 1
					table.insert(result.errors, { kind = kind, error = tostring(err) })
					if isThrottleError(err) then
						cache.coolingUntil[kind] = now + FLUSH_COOLDOWN
					end
				end
			end
		end
	end
	for kind in pairs(toClear) do
		cache.dirty[kind] = nil
	end
	return result
end

-- Publish the editor's working world (the ":edit" keys, held in cache.data) to the LIVE keys the main
-- game reads. Editor-environment ONLY — this is the single path that writes the live world from the
-- editor; normal editor saves/loads only ever touch ":edit". Full authoritative write per kind (the
-- live world is never concurrently edited), with per-kind failure reporting. Callers should promote/
-- save the current draft into ":edit" first so cache.data reflects the latest edits.
function DataOverlay.pushEditToLive()
	ensureLoaded()
	if not IS_EDITOR_ENV then
		return {
			ok = false,
			writes = 0,
			failures = 1,
			kinds = {},
			errors = { { error = "pushToLive is only available in the Map Editor environment" } },
		}
	end
	-- Gather what to publish: re-read the persisted ":edit" world FRESH (so a co-editor's committed work
	-- on another server is captured too), falling back to the in-memory editor world if ":edit" has not
	-- been persisted yet (seeded-but-unsaved) so we never publish an empty aggregate.
	local payloads = {}
	for _, kind in ipairs(ALL_KINDS) do
		local editData, status = readAggregate(kind) -- keyFor -> ":edit" in the editor env
		if status == "read_failed" then
			return {
				ok = false,
				writes = 0,
				failures = 1,
				kinds = {},
				errors = { { kind = kind, error = "editor aggregate '" .. kind .. "' could not be read; retry the push" } },
			}
		end
		if next(editData) == nil then
			editData = cache.data[kind] or {}
		end
		payloads[kind] = editData
	end
	-- Sanity: never blank the live world. Provinces/countries must be non-empty to publish.
	if next(payloads[KIND_PROVINCES]) == nil or next(payloads[KIND_COUNTRIES]) == nil then
		return {
			ok = false,
			writes = 0,
			failures = 1,
			kinds = {},
			errors = { { error = "refusing to push: the editor world is empty (provinces/countries) — this would blank the live map. Save something first." } },
		}
	end
	local result = { ok = true, writes = 0, failures = 0, kinds = {}, errors = {} }
	for _, kind in ipairs(ALL_KINDS) do
		local ok, err = writeAggregateToKey(liveKeyFor(kind), kind, payloads[kind])
		if ok then
			result.writes += 1
			result.kinds[#result.kinds + 1] = kind
		else
			result.ok = false
			result.failures += 1
			result.errors[#result.errors + 1] = { kind = kind, error = tostring(err) }
		end
	end
	return result
end

-- ─────────────────────────── named Save/Load map configs (RoN "Save/Load Map") ───────────────────────────
-- A named config is a full snapshot of every kind's aggregate, stored under namespaced keys so each fits
-- the DataStore value limit exactly like the live aggregates do, plus an index key tracking names + metadata.
-- Loading writes the config back into the LIVE aggregate keys (via cache + flush) so it applies on the next
-- server boot -- mirroring RoN's map load (a fresh boot avoids dangling army/war references that a live
-- full-world swap would leave). loadNamedConfig auto-backs up the current world first for reversibility.
local CONFIG_INDEX_KEY = "save:__index"
local CONFIG_NAME_MAX = 25 -- keeps "save:<name>:<kind>" within the 50-char DataStore key limit
local AUTO_BACKUP_NAME = "auto- before last load"

-- Memoized copy of the config index (module-level upvalue). readConfigIndex/listNamedConfigs return
-- this if present; save/delete update or invalidate it whenever they write CONFIG_INDEX_KEY so we
-- avoid a GetAsync on every listing.
local configIndexMemo = nil

-- Only [%w _%-] (letters/digits/space/underscore/hyphen) — rejects ':' (our key separator) and any
-- control chars, and enforces the length cap so "save:<name>:<kind>" stays inside the key limit.
local function validateConfigName(name)
	assert(type(name) == "string" and name ~= "", "config name required")
	assert(#name <= CONFIG_NAME_MAX, "config name too long (max " .. CONFIG_NAME_MAX .. " chars)")
	assert(name:match("^[%w _%-]+$") ~= nil, "config name has invalid characters (allowed: letters, digits, space, _ , -)")
end

local function configKey(name, kind)
	return "save:" .. name .. ":" .. kind
end
local function configMetaKey(name)
	return "save:" .. name .. ":meta"
end
local function countMap(map)
	local n = 0
	for _ in pairs(map or {}) do
		n += 1
	end
	return n
end
local function readConfigIndex(ds)
	if configIndexMemo ~= nil then
		return configIndexMemo
	end
	local ok, raw = withRetry(function()
		return ds:GetAsync(CONFIG_INDEX_KEY)
	end, "GetAsync " .. CONFIG_INDEX_KEY)
	if not ok then
		return nil
	end
	local decoded = decodeValue(raw)
	local idx = (type(decoded) == "table") and decoded or {}
	configIndexMemo = idx
	return idx
end

-- Atomically upsert (or remove, when entry == nil) the given name in the config index via
-- UpdateAsync, then refresh the memo. Never calls readConfigIndex inside the transform.
local function updateConfigIndexEntry(ds, name, entry)
	local ok, newIdx = withRetry(function()
		return ds:UpdateAsync(CONFIG_INDEX_KEY, function(raw)
			local idx = (decodeValue(raw)) or {}
			idx[name] = entry
			return HttpService:JSONEncode(idx)
		end)
	end, "UpdateAsync " .. CONFIG_INDEX_KEY)
	if ok then
		local decoded = decodeValue(newIdx)
		configIndexMemo = (type(decoded) == "table") and decoded or nil
	else
		configIndexMemo = nil -- unknown state: force a fresh read next time
	end
	return ok
end

function DataOverlay.saveNamedConfig(name)
	validateConfigName(name)
	ensureLoaded()
	-- All-or-nothing: if ANY kind failed to load its aggregate, snapshotting cache.data[kind] (which
	-- is {} for a failed kind) would silently bake an empty aggregate into the config → data loss.
	for _, kind in ipairs(ALL_KINDS) do
		if cache.loadStatus[kind] == "read_failed" then
			error(
				"refusing to save config '"
					.. name
					.. "': aggregate '"
					.. kind
					.. "' failed to load — saving now would snapshot it as empty. Wait for the retry to recover it, then save again."
			)
		end
	end
	local ds = store()
	local counts = {}
	for _, kind in ipairs(ALL_KINDS) do
		counts[kind] = countMap(cache.data[kind] or {})
	end
	local meta = {
		name = name,
		savedAt = os.time(),
		savedAtStr = os.date("!%Y-%m-%d %H:%M UTC"),
		countries = counts[KIND_COUNTRIES],
		provinces = counts[KIND_PROVINCES],
		schema = cache.collapsed and COLLAPSED_VERSION or SCHEMA_VERSION,
		counts = counts, -- per-kind counts, consulted by loadNamedConfig to refuse empty-over-real
		status = "pending", -- flipped to "complete" only after every kind write succeeds
	}
	-- Publish the pending index entry + meta BEFORE writing kinds, so a crash mid-loop leaves a
	-- clearly-incomplete marker that listNamedConfigs/loadNamedConfig ignore (never a torn "complete").
	local idxOk = updateConfigIndexEntry(ds, name, {
		savedAt = meta.savedAt,
		savedAtStr = meta.savedAtStr,
		countries = meta.countries,
		provinces = meta.provinces,
		status = "pending",
	})
	if not idxOk then
		error("write failed for config index (pending) '" .. name .. "'")
	end
	withRetry(function()
		ds:SetAsync(configMetaKey(name), HttpService:JSONEncode(meta))
	end, "SetAsync config meta " .. name)

	local writtenKinds = {}
	for _, kind in ipairs(ALL_KINDS) do
		local map = cache.data[kind] or {}
		local serializable = {}
		for k, v in pairs(map) do
			serializable[tostring(k)] = v
		end
		local encodeOk, payload = pcall(HttpService.JSONEncode, HttpService, serializable)
		if encodeOk and #payload > MAX_AGGREGATE_BYTES then
			encodeOk = false
			payload = string.format(
				"config kind '%s' is %d bytes, over the %d-byte safety limit (DataStore ~4MB cap)",
				kind,
				#payload,
				MAX_AGGREGATE_BYTES
			)
		end
		local ok, err
		if encodeOk then
			ok, err = withRetry(function()
				ds:SetAsync(configKey(name, kind), payload)
			end, "SetAsync config " .. name .. ":" .. kind)
		end
		if not (encodeOk and ok) then
			-- Best-effort roll back the partial write from THIS attempt, then re-error.
			for _, wk in ipairs(writtenKinds) do
				withRetry(function()
					ds:RemoveAsync(configKey(name, wk))
				end, "RemoveAsync partial config " .. name .. ":" .. wk)
			end
			updateConfigIndexEntry(ds, name, nil)
			withRetry(function()
				ds:RemoveAsync(configMetaKey(name))
			end, "RemoveAsync partial config meta " .. name)
			if not encodeOk then
				error("failed to encode " .. kind .. " for config '" .. name .. "'")
			end
			error("write failed for " .. kind .. ": " .. tostring(err))
		end
		table.insert(writtenKinds, kind)
	end

	-- All 8 kinds landed — flip meta + index to "complete".
	meta.status = "complete"
	withRetry(function()
		ds:SetAsync(configMetaKey(name), HttpService:JSONEncode(meta))
	end, "SetAsync config meta complete " .. name)
	local completeOk = updateConfigIndexEntry(ds, name, {
		savedAt = meta.savedAt,
		savedAtStr = meta.savedAtStr,
		countries = meta.countries,
		provinces = meta.provinces,
		status = "complete",
	})
	if not completeOk then
		error("write failed for config index (complete) '" .. name .. "'")
	end
	return { name = name, savedAt = meta.savedAtStr, countries = meta.countries, provinces = meta.provinces }
end

function DataOverlay.listNamedConfigs()
	local ds = store()
	local idx = readConfigIndex(ds)
	assert(idx ~= nil, "could not read the config index")
	local out = {}
	for cname, meta in pairs(idx) do
		-- Ignore torn/in-progress saves (status ~= "complete"). Legacy entries predating the status
		-- field have status == nil; treat those as complete for backward compatibility.
		if meta.status == nil or meta.status == "complete" then
			out[#out + 1] = {
				name = cname,
				savedAt = meta.savedAtStr or (meta.savedAt and tostring(meta.savedAt)) or "?",
				savedAtEpoch = meta.savedAt or 0,
				countries = meta.countries,
				provinces = meta.provinces,
			}
		end
	end
	table.sort(out, function(a, b)
		return (a.savedAtEpoch or 0) > (b.savedAtEpoch or 0)
	end)
	return { configs = out }
end

function DataOverlay.deleteNamedConfig(name)
	validateConfigName(name)
	local ds = store()
	for _, kind in ipairs(ALL_KINDS) do
		withRetry(function()
			ds:RemoveAsync(configKey(name, kind))
		end, "RemoveAsync config " .. name .. ":" .. kind)
	end
	withRetry(function()
		ds:RemoveAsync(configMetaKey(name))
	end, "RemoveAsync config meta " .. name)
	updateConfigIndexEntry(ds, name, nil)
	return { name = name }
end

-- Overwrite the live aggregate keys with a saved config (auto-backing up the current world first).
-- Reads every kind up front so a mid-read failure aborts before anything is mutated. Applies on the next
-- server boot; also refreshes the in-memory cache so the editor reflects the loaded world immediately.
function DataOverlay.loadNamedConfig(name)
	validateConfigName(name)
	ensureLoaded()
	local ds = store()
	local mok, mraw = withRetry(function()
		return ds:GetAsync(configMetaKey(name))
	end, "GetAsync config meta " .. name)
	if not mok then
		error("could not read config '" .. name .. "'")
	end
	local meta = decodeValue(mraw)
	if type(meta) ~= "table" then
		error("config '" .. name .. "' not found")
	end
	-- Refuse torn/in-progress saves. Legacy configs predating the status field have status == nil.
	if meta.status ~= nil and meta.status ~= "complete" then
		error("config '" .. name .. "' is incomplete (a previous save did not finish); refusing to load it")
	end
	local metaCounts = type(meta.counts) == "table" and meta.counts or {}
	local loaded = {}
	for _, kind in ipairs(ALL_KINDS) do
		local ok, raw = withRetry(function()
			return ds:GetAsync(configKey(name, kind))
		end, "GetAsync config " .. name .. ":" .. kind)
		if not ok then
			error("read failed for " .. kind)
		end
		local decoded = decodeValue(raw)
		local map = {}
		if type(decoded) == "table" then
			for k, v in pairs(decoded) do
				map[coerceKey(kind, k)] = v
			end
		end
		-- Guard against wiping a real aggregate with an empty snapshot: if the config was saved with
		-- a non-zero count for this kind but decoded to nothing, the stored value is corrupt/torn.
		local expected = tonumber(metaCounts[kind]) or 0
		if expected > 0 and countMap(map) == 0 then
			error(
				"config '"
					.. name
					.. "' expected "
					.. expected
					.. " '"
					.. kind
					.. "' records but decoded none — refusing to overwrite the live world with an empty snapshot"
			)
		end
		loaded[kind] = map
	end
	local backupOk = pcall(DataOverlay.saveNamedConfig, AUTO_BACKUP_NAME)
	if not backupOk then
		error("aborting load of '" .. name .. "': auto-backup failed, live world untouched")
	end
	for _, kind in ipairs(ALL_KINDS) do
		cache.data[kind] = loaded[kind]
		cache.dirty[kind] = true
		-- Loading a config is a wholesale REPLACE, not an incremental edit: drop any journaled per-record
		-- edits so flush() takes the full-overwrite path (empty pending) instead of merging stale changes.
		cache.pending[kind] = {}
	end
	local flushResult = DataOverlay.flush()
	return {
		name = name,
		backedUp = backupOk,
		flush = flushResult,
		message = string.format(
			"Loaded '%s' into storage%s. Restart the server or rejoin to apply it to the live map.",
			name,
			backupOk and (" (current world backed up as '" .. AUTO_BACKUP_NAME .. "')") or ""
		),
	}
end

local PROVINCE_REF_FIELDS = {
	areaId = "areas",
	regionId = "regions",
	superRegionId = "superRegions",
	terrain = "terrains",
	climate = "climates",
	culture = "cultures",
	religion = "religions",
	tradeGood = "tradeGoods",
	ownerTag = "countries",
	controllerTag = "countries",
}

local COUNTRY_REF_FIELDS = {
	economyPolicy = "economyPolicies",
	governmentForm = "governmentTypes",
	capitalProvinceId = "provinces",
	primaryCulture = "cultures",
	stateReligion = "religions",
	ideology = "ideologies",
}

local PROVINCE_REF_ARRAY_FIELDS = { cores = "countries", defaultCores = "countries", claims = "countries" }
-- acceptedCultures dropped in v4 (dormant field); no longer validated/self-healed.
local COUNTRY_REF_ARRAY_FIELDS = {
	historicalRivals = "countries",
	historicalFriends = "countries",
}

local REF_SENTINELS = {
	countries = { NONE = true },
}

local function isValidRef(refTable, value, refKind)
	if value == nil or refTable == nil then
		return true
	end
	local sentinels = refKind and REF_SENTINELS[refKind]
	if sentinels and sentinels[value] then
		return true
	end
	return refTable[value] ~= nil
end

local function rawMerge(source, overlay)
	if type(overlay) ~= "table" then
		return overlay
	end
	local merged = {}
	if type(source) == "table" then
		for k, v in pairs(source) do
			merged[k] = v
		end
	end
	for k, v in pairs(overlay) do
		merged[k] = v
	end
	return merged
end

local function validateRefs(record, source, scalarFields, arrayFields, bundle, label, healings)
	if type(record) ~= "table" then
		return record
	end
	for k, v in pairs(record) do
		local refKind = scalarFields[k]
		if refKind then
			local refTable = bundle[refKind]
			if refTable and not isValidRef(refTable, v, refKind) then
				local sourceVal = source and source[k]
				if isValidRef(refTable, sourceVal, refKind) then
					record[k] = sourceVal
					table.insert(
						healings,
						string.format(
							"%s.%s: '%s' invalid → fell back to '%s'",
							label,
							k,
							tostring(v),
							tostring(sourceVal)
						)
					)
				end
			end
		elseif arrayFields[k] and type(v) == "table" then
			local arrayRefKind = arrayFields[k]
			local refTable = bundle[arrayRefKind]
			if refTable then
				local kept, dropped = {}, {}
				for _, item in ipairs(v) do
					if isValidRef(refTable, item, arrayRefKind) then
						table.insert(kept, item)
					else
						table.insert(dropped, tostring(item))
					end
				end
				record[k] = kept
				if #dropped > 0 then
					table.insert(
						healings,
						string.format("%s.%s: dropped invalid entries [%s]", label, k, table.concat(dropped, ", "))
					)
				end
			end
		end
	end
	return record
end

local DELETE_BREAKER_FLOOR = 4
local DELETE_BREAKER_FRACTION = 1 / 3
local DELETE_BREAKER_CAP = 200
local DELETE_BREAKER_SMALL_KIND = 50

local BUNDLE_FIELD = {
	[KIND_PROVINCES] = "provinces",
	[KIND_EU4MAP] = "eu4Map",
	[KIND_COUNTRIES] = "countries",
	[KIND_CULTURES] = "cultures",
	[KIND_RELIGIONS] = "religions",
	[KIND_IDEOLOGIES] = "ideologies",
	[KIND_GOVERNMENTS] = "governmentTypes",
}

local function deletesAreSafe(kind, bundle)
	local present = {}
	local field = BUNDLE_FIELD[kind]
	local src = field and bundle[field]
	if type(src) == "table" then
		for k in pairs(src) do
			present[tostring(k)] = true
		end
	end
	local tombstones = 0
	for k, rec in pairs(cache.data[kind]) do
		local key = tostring(k)
		if isTombstone(rec) then
			if present[key] then
				tombstones += 1
				present[key] = nil
			end
		else
			present[key] = true
		end
	end
	local survivors = 0
	for _ in pairs(present) do
		survivors += 1
	end
	local total = survivors + tombstones
	local allowed
	if total <= DELETE_BREAKER_SMALL_KIND then
		allowed = math.max(0, total - 1)
	else
		allowed = math.min(DELETE_BREAKER_CAP, math.max(DELETE_BREAKER_FLOOR, DELETE_BREAKER_FRACTION * total))
	end
	if tombstones <= allowed then
		return true
	end
	warn(
		string.format(
			"[DataOverlay] mass-deletion breaker TRIPPED for '%s': overlay would delete %d of %d records (limit %d). Keeping source data and skipping these deletions — investigate possible tampering.",
			kind,
			tombstones,
			total,
			math.floor(allowed)
		)
	)
	return false
end

function DataOverlay.applyTo(bundle)
	ensureLoaded()
	if cache.collapsed then
		-- v3: provinces & countries are authoritative and COMPLETE in the @v3 overlay (part-id keyed,
		-- written by the migration). Discard the serial-keyed source for these two kinds so the merged
		-- bundle ends up purely part-id keyed. (bundle.eu4Map is never populated by loadBundle, so the
		-- eu4Map merge below is already a no-op.)
		bundle.provinces = {}
		bundle.countries = {}
	end
	local healings = {}
	local allowDelete = {
		[KIND_PROVINCES] = deletesAreSafe(KIND_PROVINCES, bundle),
		[KIND_EU4MAP] = deletesAreSafe(KIND_EU4MAP, bundle),
		[KIND_COUNTRIES] = deletesAreSafe(KIND_COUNTRIES, bundle),
		[KIND_CULTURES] = deletesAreSafe(KIND_CULTURES, bundle),
		[KIND_RELIGIONS] = deletesAreSafe(KIND_RELIGIONS, bundle),
		[KIND_IDEOLOGIES] = deletesAreSafe(KIND_IDEOLOGIES, bundle),
		[KIND_GOVERNMENTS] = deletesAreSafe(KIND_GOVERNMENTS, bundle),
	}

	local sourceProvinces, sourceCountries = {}, {}
	if type(bundle.provinces) == "table" then
		for k, v in pairs(bundle.provinces) do
			sourceProvinces[k] = v
		end
	end
	if type(bundle.countries) == "table" then
		for k, v in pairs(bundle.countries) do
			sourceCountries[k] = v
		end
	end

	if bundle.eu4Map then
		for id, part in pairs(cache.data[KIND_EU4MAP]) do
			local nid = tonumber(id) or id
			if isTombstone(part) then
				if allowDelete[KIND_EU4MAP] then
					bundle.eu4Map[nid] = nil
				end
			else
				bundle.eu4Map[nid] = part
			end
		end
	end
	if bundle.countries then
		for tag, rec in pairs(cache.data[KIND_COUNTRIES]) do
			if isTombstone(rec) then
				if allowDelete[KIND_COUNTRIES] then
					bundle.countries[tag] = nil
				end
			else
				bundle.countries[tag] = rawMerge(sourceCountries[tag], rec)
			end
		end
	end
	if bundle.cultures then
		for id, rec in pairs(cache.data[KIND_CULTURES]) do
			if isTombstone(rec) then
				if allowDelete[KIND_CULTURES] then
					bundle.cultures[id] = nil
				end
			else
				bundle.cultures[id] = rawMerge(bundle.cultures[id], rec)
			end
		end
	end
	if bundle.religions then
		for id, rec in pairs(cache.data[KIND_RELIGIONS]) do
			if isTombstone(rec) then
				if allowDelete[KIND_RELIGIONS] then
					bundle.religions[id] = nil
				end
			else
				bundle.religions[id] = rawMerge(bundle.religions[id], rec)
			end
		end
	end
	if bundle.ideologies then
		for id, rec in pairs(cache.data[KIND_IDEOLOGIES]) do
			if isTombstone(rec) then
				if allowDelete[KIND_IDEOLOGIES] then
					bundle.ideologies[id] = nil
				end
			else
				bundle.ideologies[id] = rawMerge(bundle.ideologies[id], rec)
			end
		end
	end
	if bundle.governmentTypes then
		for id, rec in pairs(cache.data[KIND_GOVERNMENTS]) do
			if isTombstone(rec) then
				if allowDelete[KIND_GOVERNMENTS] then
					bundle.governmentTypes[id] = nil
				end
			else
				bundle.governmentTypes[id] = rawMerge(bundle.governmentTypes[id], rec)
			end
		end
	end

	-- perf: merge + ref-validate provinces in a SINGLE walk (was two passes over cache.data).
	-- This block is intentionally placed AFTER the country/culture/religion/etc. merges so that
	-- validateRefs sees the same fully-merged bundle.* ref tables it did when validation was a
	-- separate trailing pass — result is identical, the provinces table is just walked once.
	if bundle.provinces then
		for id, rec in pairs(cache.data[KIND_PROVINCES]) do
			local nid = tonumber(id) or id
			if isTombstone(rec) then
				if allowDelete[KIND_PROVINCES] then
					bundle.provinces[nid] = nil
				end
			else
				local incoming = rec
				if type(rec) == "table" then
					local owner = rec.ownerTag
					if rec.controllerTag == nil or rec.cores == nil or rec.claims == nil or rec.defaultCores == nil then
						incoming = table.clone(rec)
						if incoming.controllerTag == nil then
							incoming.controllerTag = owner
						end
						if incoming.cores == nil then
							incoming.cores = (owner and owner ~= "NONE") and { owner } or {}
						end
						if incoming.claims == nil then
							incoming.claims = {}
						end
						if incoming.defaultCores == nil then
							incoming.defaultCores = table.clone(incoming.cores) -- homeland cores default to seed cores
						end
					end
				end
				bundle.provinces[nid] = rawMerge(sourceProvinces[nid], incoming)
				validateRefs(
					bundle.provinces[nid],
					sourceProvinces[nid],
					PROVINCE_REF_FIELDS,
					PROVINCE_REF_ARRAY_FIELDS,
					bundle,
					"Province " .. tostring(nid),
					healings
				)
			end
		end
	end
	if bundle.countries then
		for tag, rec in pairs(cache.data[KIND_COUNTRIES]) do
			if not isTombstone(rec) then
				validateRefs(
					bundle.countries[tag],
					sourceCountries[tag],
					COUNTRY_REF_FIELDS,
					COUNTRY_REF_ARRAY_FIELDS,
					bundle,
					"Country " .. tostring(tag),
					healings
				)
			end
		end
	end

	if #healings > 0 then
		warn(
			string.format(
				"[DataOverlay] self-healed %d invalid overlay reference(s); falling back to source values:",
				#healings
			)
		)
		for _, msg in ipairs(healings) do
			warn("  · " .. msg)
		end
	end
	return bundle
end

function DataOverlay.getEU4MapOverrides()
	ensureLoaded()
	local out = {}
	for k, v in pairs(cache.data[KIND_EU4MAP]) do
		if not isTombstone(v) then
			out[k] = v
		end
	end
	return out
end

function DataOverlay.getTileOverrides()
	ensureLoaded()
	local out = {}
	for k, v in pairs(cache.data[KIND_TILES]) do
		if not isTombstone(v) then
			out[k] = v
		end
	end
	return out
end

local KIND_FOR_EDIT = {
	countries = KIND_COUNTRIES,
	provinces = KIND_PROVINCES,
	eu4map = KIND_EU4MAP,
	tiles = KIND_TILES,
	cultures = KIND_CULTURES,
	religions = KIND_RELIGIONS,
	ideologies = KIND_IDEOLOGIES,
	governmentTypes = KIND_GOVERNMENTS,
}

local function canonicalJson(value)
	if value == nil then
		return nil
	end
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, value)
	if not ok then
		return nil
	end
	return encoded
end

function DataOverlay.verifyWrites(edits)
	local summary = { total = 0, verified = 0, mismatch = 0, missing = 0, errors = 0 }
	if type(edits) ~= "table" then
		return summary
	end
	local ds = store()
	local liveByKind = {}
	local function loadLive(kind)
		if liveByKind[kind] ~= nil then
			return liveByKind[kind]
		end
		local vk = keyFor(kind)
		local ok, raw = withRetry(function()
			return ds:GetAsync(vk)
		end, "verify " .. vk, 3)
		if not ok then
			liveByKind[kind] = false
		else
			local decoded = decodeValue(raw)
			liveByKind[kind] = type(decoded) == "table" and decoded or {}
		end
		return liveByKind[kind]
	end
	for editKind, entries in pairs(edits) do
		local kind = KIND_FOR_EDIT[editKind]
		if kind and type(entries) == "table" then
			local live = loadLive(kind)
			for key, expected in pairs(entries) do
				summary.total += 1
				if live == false then
					summary.errors += 1
				else
					local actual = live[tostring(key)]
					local isDeletion = (expected == false) or isTombstone(expected)
					if isDeletion then
						if actual == nil or isTombstone(actual) then
							summary.verified += 1
						else
							summary.mismatch += 1
						end
					else
						if actual == nil or isTombstone(actual) then
							summary.missing += 1
						else
							local expectedJson = canonicalJson(expected)
							local actualJson = canonicalJson(actual)
							if expectedJson and actualJson and expectedJson == actualJson then
								summary.verified += 1
							else
								summary.mismatch += 1
							end
						end
					end
				end
			end
		end
	end
	return summary
end

-- Cross-universe relay REMOVED 2026-06-25: dev + prod are now a single shared experience, so there
-- is nothing to mirror. Saving/loading is pure Roblox DataStore. (Was: pushToRelay → Cloudflare worker.)

function DataOverlay.snapshot(forceRefresh)
	if forceRefresh then
		-- Safety: never silently drop unsaved edits. If this session has journaled (un-flushed) changes,
		-- persist them first so a hard reload can't lose work.
		local hasPending = false
		for _, journal in pairs(cache.pending) do
			if next(journal) ~= nil then
				hasPending = true
				break
			end
		end
		if hasPending then
			pcall(DataOverlay.flush)
		end
		cache.loaded = false
		cache.data = {
			[KIND_COUNTRIES] = {},
			[KIND_PROVINCES] = {},
			[KIND_EU4MAP] = {},
			[KIND_TILES] = {},
			[KIND_CULTURES] = {},
			[KIND_RELIGIONS] = {},
			[KIND_IDEOLOGIES] = {},
			[KIND_GOVERNMENTS] = {},
		}
		cache.dirty = {}
		cache.pending = freshPending() -- edits were persisted above; safe to reset the journal for reload
	end
	ensureLoaded()
	local function liveCopy(tbl)
		local out = {}
		for k, v in pairs(tbl or {}) do
			if not isTombstone(v) then
				out[k] = v
			end
		end
		return out
	end
	local function tombKeys(tbl)
		local out = {}
		for k, v in pairs(tbl or {}) do
			if isTombstone(v) then
				out[k] = true
			end
		end
		return out
	end
	return {
		universe = RelayConfig.universeLabel(),
		gameId = game.GameId,
		placeId = game.PlaceId,
		scope = RelayConfig.DATASTORE_SCOPE,
		name = RelayConfig.DATASTORE_NAME,
		countries = liveCopy(cache.data[KIND_COUNTRIES]),
		cultures = liveCopy(cache.data[KIND_CULTURES]),
		religions = liveCopy(cache.data[KIND_RELIGIONS]),
		provinces = liveCopy(cache.data[KIND_PROVINCES]),
		eu4Map = liveCopy(cache.data[KIND_EU4MAP]),
		tiles = liveCopy(cache.data[KIND_TILES]),
		ideologies = liveCopy(cache.data[KIND_IDEOLOGIES]),
		governmentTypes = liveCopy(cache.data[KIND_GOVERNMENTS]),
		tombstones = {
			countries = tombKeys(cache.data[KIND_COUNTRIES]),
			cultures = tombKeys(cache.data[KIND_CULTURES]),
			religions = tombKeys(cache.data[KIND_RELIGIONS]),
			provinces = tombKeys(cache.data[KIND_PROVINCES]),
			eu4Map = tombKeys(cache.data[KIND_EU4MAP]),
			tiles = tombKeys(cache.data[KIND_TILES]),
			ideologies = tombKeys(cache.data[KIND_IDEOLOGIES]),
			governmentTypes = tombKeys(cache.data[KIND_GOVERNMENTS]),
		},
		fetchedAt = os.time(),
		migrated = cache.migrated == true,
		migrating = cache.migrating == true,
		dirty = (function()
			local out = {}
			for k in pairs(cache.dirty) do
				out[k] = true
			end
			return out
		end)(),
	}
end

-- ===========================================================================================
-- Phase C — reversible identity collapse (serial id -> part id). All writers below are ADDITIVE:
-- they write parallel @v3 keys and NEVER touch the serial-keyed v2 keys, so rollback is a single
-- schema flag flip. The actual flip (commitCollapse) is a deliberate, separately-invoked step.
-- ===========================================================================================

function DataOverlay.isCollapsed()
	ensureLoaded()
	return cache.collapsed == true
end

local function countOf(t)
	local n = 0
	for _ in pairs(t or {}) do
		n += 1
	end
	return n
end

local function rawWriteKey(key, map)
	local ds = store()
	local serializable = {}
	for k, v in pairs(map) do
		serializable[tostring(k)] = v
	end
	local encodeOk, payload = pcall(HttpService.JSONEncode, HttpService, serializable)
	if not encodeOk then
		return false, "encode_failed"
	end
	return withRetry(function()
		ds:SetAsync(key, payload)
	end, "SetAsync " .. key, 3)
end

local function rawReadKey(key)
	local ds = store()
	local ok, raw = withRetry(function()
		return ds:GetAsync(key)
	end, "GetAsync " .. key, 3)
	if not ok then
		return nil, "read_failed"
	end
	local decoded = decodeValue(raw)
	if type(decoded) ~= "table" then
		return {}, "empty"
	end
	return decoded, "loaded"
end

-- Write the part-id-keyed @v3 aggregates + the partId->serial lineage map + a migration-meta
-- stamp. Purely additive (never overwrites v2 keys). Does NOT flip the schema flag and does NOT
-- push to the relay. The caller must have validated the bijection (DataEditor.auditMapping).
function DataOverlay.writeCollapsedV3(provincesV3, countriesV3, provmapV3, meta)
	assert(type(provincesV3) == "table", "provincesV3 table required")
	assert(type(countriesV3) == "table", "countriesV3 table required")
	assert(type(provmapV3) == "table", "provmapV3 table required")
	local okP, errP = rawWriteKey(COLLAPSED_KEYS[KIND_PROVINCES], provincesV3)
	local okC, errC = rawWriteKey(COLLAPSED_KEYS[KIND_COUNTRIES], countriesV3)
	local okM, errM = rawWriteKey(PROVMAP_KEY, provmapV3)
	local stamp = {
		startedAt = meta and meta.startedAt or os.time(),
		completedAt = os.time(),
		sourceCount = meta and meta.sourceCount or nil,
		writtenCount = countOf(provincesV3),
		countries = countOf(countriesV3),
	}
	rawWriteKey(MIGRATION_META_KEY, stamp)
	return {
		ok = okP and okC and okM,
		provinces = { ok = okP, count = countOf(provincesV3), err = errP },
		countries = { ok = okC, count = countOf(countriesV3), err = errC },
		provmap = { ok = okM, count = countOf(provmapV3), err = errM },
		meta = stamp,
	}
end

-- Re-read the @v3 keys and confirm they match the expected sets by count + per-key presence.
function DataOverlay.verifyCollapsedV3(expectedProvinces, expectedCountries)
	local liveP = rawReadKey(COLLAPSED_KEYS[KIND_PROVINCES]) or {}
	local liveC = rawReadKey(COLLAPSED_KEYS[KIND_COUNTRIES]) or {}
	local function presenceMatch(expected, live)
		local missing = 0
		for k in pairs(expected or {}) do
			if live[tostring(k)] == nil then
				missing += 1
			end
		end
		return missing
	end
	local pMissing = presenceMatch(expectedProvinces, liveP)
	local cMissing = presenceMatch(expectedCountries, liveC)
	return {
		ok = pMissing == 0
			and cMissing == 0
			and countOf(liveP) == countOf(expectedProvinces)
			and countOf(liveC) == countOf(expectedCountries),
		provinces = { expected = countOf(expectedProvinces), actual = countOf(liveP), missing = pMissing },
		countries = { expected = countOf(expectedCountries), actual = countOf(liveC), missing = cMissing },
	}
end

function DataOverlay.readProvmapV3()
	return (rawReadKey(PROVMAP_KEY)) or {}
end

-- Flip the schema flag to v3 (the atomic commit point) / back to v2 (rollback). Boot reads this
-- flag first and selects the key family accordingly. Neither call moves any aggregate data.
function DataOverlay.commitCollapse()
	local ok, err = writeSchemaVersion(COLLAPSED_VERSION)
	if ok then
		cache.collapsed = true
		-- Invalidate so the next read reloads aggregates from the @v3 key family (the in-memory
		-- cache still holds v2 serial-keyed data; a save now would write it to the wrong keys).
		cache.loaded = false
	end
	return ok, err
end

function DataOverlay.rollbackCollapse()
	local ok, err = writeSchemaVersion(SCHEMA_VERSION)
	if ok then
		cache.collapsed = false
		cache.loaded = false
	end
	return ok, err
end

-- ===========================================================================================
-- Phase 1B — reversible v3 -> v4 store migration + first-boot seed import. Same safety contract as
-- the collapse: every writer is ADDITIVE (writes @v4 keys, never SetAsync/mutates the @v3 keys),
-- the migration is ALL-OR-NOTHING and VERIFIED before the schema flag is flipped, and rollback is a
-- single flip back to the frozen @v3 data. Invoked as ADMIN commands only — never auto at boot.
-- ===========================================================================================

DataOverlay.V4_VERSION = V4_VERSION

function DataOverlay.isV4()
	ensureLoaded()
	return cache.schemaVersion == V4_VERSION
end

-- Normalize a single province record for v4: ensure cores/defaultCores/claims defaults derived from
-- the owner (mirrors the on-read healing in applyTo). Returns a fresh table; never mutates `rec`.
local function normalizeProvinceV4(rec)
	if type(rec) ~= "table" then
		return rec
	end
	local out = table.clone(rec)
	local owner = out.ownerTag
	if out.controllerTag == nil then
		out.controllerTag = owner
	end
	if type(out.cores) ~= "table" then
		out.cores = (owner and owner ~= "NONE") and { owner } or {}
	end
	if type(out.defaultCores) ~= "table" then
		out.defaultCores = table.clone(out.cores) -- homeland cores default to seed cores
	end
	if type(out.claims) ~= "table" then
		out.claims = {}
	end
	return out
end

-- Copy a country record for v4, DROPPING the dormant acceptedCultures field. Fresh table.
local function normalizeCountryV4(rec)
	if type(rec) ~= "table" then
		return rec
	end
	local out = table.clone(rec)
	out.acceptedCultures = nil
	return out
end

-- Read the CURRENT authoritative province/country aggregates (from whichever key family the live
-- schema selects — normally @v3). Uses keyFor() so this respects the live schema at call time.
local function readCurrentProvincesCountries()
	local provinces, pStatus = rawReadKey(keyFor(KIND_PROVINCES))
	local countries, cStatus = rawReadKey(keyFor(KIND_COUNTRIES))
	-- readOk distinguishes a genuine empty source from a throttled/failed read, so callers never treat a
	-- transient DataStore read failure as "source is empty" (which would wrongly wipe/skip @v4).
	local readOk = pStatus ~= "read_failed" and cStatus ~= "read_failed"
	return provinces or {}, countries or {}, readOk
end

-- Migrate the current @v3 provinces/countries into the @v4 keys. Purely ADDITIVE (never touches the
-- @v3 keys). Idempotent: if @v4 already holds matching counts it is treated as done and skipped.
-- Does NOT flip the schema flag (call verifyV4 then commitV4). Non-province/country kinds are shared.
function DataOverlay.migrateV3toV4()
	ensureLoaded()
	local srcProvinces, srcCountries, readOk = readCurrentProvincesCountries()
	if not readOk then
		return { ok = false, error = "source (@v3) unreadable — DataStore throttled; retry", retryable = true }
	end
	local srcP, srcC = countOf(srcProvinces), countOf(srcCountries)

	-- Idempotence: if @v4 already matches the source counts, do not re-write.
	local liveV4P = rawReadKey(V4_KEYS[KIND_PROVINCES]) or {}
	local liveV4C = rawReadKey(V4_KEYS[KIND_COUNTRIES]) or {}
	if countOf(liveV4P) == srcP and countOf(liveV4C) == srcC and srcP > 0 then
		return {
			ok = true,
			skipped = true,
			provinces = { source = srcP, written = countOf(liveV4P) },
			countries = { source = srcC, written = countOf(liveV4C) },
			message = "@v4 already populated with matching counts — nothing to do",
		}
	end

	local provincesV4 = {}
	for id, rec in pairs(srcProvinces) do
		provincesV4[id] = normalizeProvinceV4(rec)
	end
	local countriesV4 = {}
	for tag, rec in pairs(srcCountries) do
		countriesV4[tag] = normalizeCountryV4(rec)
	end

	local okP, errP = rawWriteKey(V4_KEYS[KIND_PROVINCES], provincesV4)
	local okC, errC = rawWriteKey(V4_KEYS[KIND_COUNTRIES], countriesV4)
	local stamp = {
		startedAt = os.time(),
		completedAt = os.time(),
		sourceProvinces = srcP,
		sourceCountries = srcC,
		writtenProvinces = countOf(provincesV4),
		writtenCountries = countOf(countriesV4),
	}
	if okP and okC then
		-- Only stamp the migration meta once BOTH @v4 writes actually landed.
		rawWriteKey(MIGRATION_META_KEY_V4, stamp)
	end

	return {
		ok = okP and okC,
		skipped = false,
		provinces = { source = srcP, written = countOf(provincesV4), err = errP },
		countries = { source = srcC, written = countOf(countriesV4), err = errC },
		meta = stamp,
	}
end

-- Re-read the @v4 keys and confirm they match the current @v3 source by count, AND confirm the @v3
-- keys are UNTOUCHED (their counts still match what migrateV3toV4 saw). On any mismatch this REMOVES
-- the partial @v4 keys (so a failed migration leaves no half-written v4 store) and returns ok=false.
function DataOverlay.verifyV4()
	local srcProvinces, srcCountries, readOk = readCurrentProvincesCountries()
	if not readOk then
		-- A throttled @v3 read must NOT be treated as "source empty" — that would delete good @v4. Abort.
		return { ok = false, error = "source (@v3) unreadable — DataStore throttled; retry", retryable = true, removedPartial = false }
	end
	local srcP, srcC = countOf(srcProvinces), countOf(srcCountries)

	local liveV4P = rawReadKey(V4_KEYS[KIND_PROVINCES]) or {}
	local liveV4C = rawReadKey(V4_KEYS[KIND_COUNTRIES]) or {}
	local v4P, v4C = countOf(liveV4P), countOf(liveV4C)

	local function presenceMissing(expected, live)
		local missing = 0
		for k in pairs(expected or {}) do
			if live[tostring(k)] == nil and live[tonumber(k) or k] == nil then
				missing += 1
			end
		end
		return missing
	end
	local pMissing = presenceMissing(srcProvinces, liveV4P)
	local cMissing = presenceMissing(srcCountries, liveV4C)

	local ok = srcP > 0 and v4P == srcP and v4C == srcC and pMissing == 0 and cMissing == 0

	if not ok then
		-- All-or-nothing: never leave a partial @v4 store behind. Remove both @v4 keys. The @v3 keys
		-- are never touched by this whole flow, so removing @v4 is a full, safe undo of the write.
		local ds = store()
		withRetry(function()
			ds:RemoveAsync(V4_KEYS[KIND_PROVINCES])
		end, "RemoveAsync partial " .. V4_KEYS[KIND_PROVINCES], 3)
		withRetry(function()
			ds:RemoveAsync(V4_KEYS[KIND_COUNTRIES])
		end, "RemoveAsync partial " .. V4_KEYS[KIND_COUNTRIES], 3)
	end

	return {
		ok = ok,
		provinces = { source = srcP, actual = v4P, missing = pMissing },
		countries = { source = srcC, actual = v4C, missing = cMissing },
		removedPartial = not ok,
	}
end

-- verifyMigrationSafe is the caller-facing verify: it captures the @v3 counts, runs verifyV4, and
-- returns its report (verifyV4 already RemoveAsyncs the partial @v4 keys on mismatch).
function DataOverlay.verifyMigrationSafe()
	return DataOverlay.verifyV4()
end

-- Flip the schema flag to v4 — the atomic commit point. ONLY call after verifyV4().ok. Invalidates
-- the cache so the next read reloads from the @v4 key family.
function DataOverlay.commitV4()
	local ok, err = writeSchemaVersion(V4_VERSION)
	if ok then
		cache.schemaVersion = V4_VERSION
		cache.collapsed = true
		cache.loaded = false -- next read reloads aggregates from the @v4 key family
	end
	return ok, err
end

-- Roll the schema flag back to v3. The frozen @v3 data (never touched by the migration) becomes
-- authoritative again, so the world reverts. Does not remove the @v4 keys (re-running migrate is a
-- no-op via idempotence); the flip is the whole rollback.
function DataOverlay.rollbackV4()
	local ok, err = writeSchemaVersion(COLLAPSED_VERSION)
	if ok then
		cache.schemaVersion = COLLAPSED_VERSION
		cache.collapsed = true
		cache.loaded = false
	end
	return ok, err
end

-- First-boot seed import: write the source Data/Countries + Data/Provinces bundles straight into the
-- @v4 keys. ADDITIVE (never touches @v3). Countries drop acceptedCultures; provinces get v4 defaults.
-- Idempotent guard: refuses to overwrite a NON-EMPTY @v4 store (so a real world is never clobbered by
-- a re-seed) unless opts.force is set. Does NOT flip the schema flag — commit separately.
function DataOverlay.importSeed(sourceCountries, sourceProvinces, opts)
	opts = opts or {}
	assert(type(sourceCountries) == "table", "sourceCountries table required")
	assert(type(sourceProvinces) == "table", "sourceProvinces table required")

	local liveV4P = rawReadKey(V4_KEYS[KIND_PROVINCES]) or {}
	local liveV4C = rawReadKey(V4_KEYS[KIND_COUNTRIES]) or {}
	if not opts.force and (countOf(liveV4P) > 0 or countOf(liveV4C) > 0) then
		return {
			ok = false,
			error = "refusing to seed: @v4 already holds data (pass { force = true } to overwrite)",
			provinces = { existing = countOf(liveV4P) },
			countries = { existing = countOf(liveV4C) },
		}
	end

	local provincesV4 = {}
	for id, rec in pairs(sourceProvinces) do
		provincesV4[tonumber(id) or id] = normalizeProvinceV4(rec)
	end
	local countriesV4 = {}
	for tag, rec in pairs(sourceCountries) do
		countriesV4[tag] = normalizeCountryV4(rec)
	end

	local okP, errP = rawWriteKey(V4_KEYS[KIND_PROVINCES], provincesV4)
	local okC, errC = rawWriteKey(V4_KEYS[KIND_COUNTRIES], countriesV4)
	rawWriteKey(MIGRATION_META_KEY_V4, {
		seededAt = os.time(),
		writtenProvinces = countOf(provincesV4),
		writtenCountries = countOf(countriesV4),
		source = "importSeed",
	})

	return {
		ok = okP and okC,
		provinces = { written = countOf(provincesV4), err = errP },
		countries = { written = countOf(countriesV4), err = errC },
	}
end

function DataOverlay.invalidate()
	cache.loaded = false
end

return DataOverlay
