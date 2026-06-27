local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")

local RelayConfig = require(ServerStorage:WaitForChild("Dev"):WaitForChild("RelayConfig"))

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

local TOMBSTONE_MARKER = { __deleted = true }
DataOverlay.TOMBSTONE = TOMBSTONE_MARKER

local MAX_RETRIES = 5
local BASE_BACKOFF = 0.5
local SCAN_PACE = 0.12
local FLUSH_COOLDOWN = 30
local MIGRATE_COOLDOWN = 30
local SCAN_PAGE_LIMIT = 10

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
}

-- Resolve the live DataStore key for a kind, honoring collapse mode. cache.collapsed is set by
-- load() (which reads the schema flag FIRST) before any readAggregate/writeAggregate runs.
local function keyFor(kind)
	if cache.collapsed and COLLAPSED_KEYS[kind] then
		return COLLAPSED_KEYS[kind]
	end
	return AGGREGATE_KEYS[kind]
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

local function readAggregate(kind)
	local ds = store()
	local k = keyFor(kind)
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

local function writeAggregate(kind, map)
	local ds = store()
	local serializable = {}
	for k, v in pairs(map) do
		serializable[tostring(k)] = v
	end
	local encodeOk, payload = pcall(HttpService.JSONEncode, HttpService, serializable)
	if not encodeOk then
		warn("[DataOverlay] failed to encode " .. kind .. ": " .. tostring(payload))
		return false, "encode_failed"
	end
	local k = keyFor(kind)
	return withRetry(function()
		ds:SetAsync(k, payload)
	end, "SetAsync " .. k)
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
	cache.collapsed = (schema == COLLAPSED_VERSION)
	cache.migrated = (schema == SCHEMA_VERSION) or cache.collapsed
	local kinds = ALL_KINDS
	for _, kind in ipairs(kinds) do
		local data, status = readAggregate(kind)
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
		local loadFailed = cache.loadStatus[kind] == "read_failed"
		local cacheEmpty = next(cache.data[kind]) == nil
		if loadFailed and cacheEmpty then
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
				local ok, err = writeAggregate(kind, cache.data[kind])
				if ok then
					result.writes += 1
					cache.coolingUntil[kind] = nil
					toClear[kind] = true
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

local PROVINCE_REF_ARRAY_FIELDS = { cores = "countries" }
local COUNTRY_REF_ARRAY_FIELDS = {
	acceptedCultures = "cultures",
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
					if rec.controllerTag == nil or rec.cores == nil then
						incoming = table.clone(rec)
						if incoming.controllerTag == nil then
							incoming.controllerTag = owner
						end
						if incoming.cores == nil then
							incoming.cores = (owner and owner ~= "NONE") and { owner } or {}
						end
					end
				end
				bundle.provinces[nid] = rawMerge(sourceProvinces[nid], incoming)
			end
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

	if bundle.provinces then
		for id, rec in pairs(cache.data[KIND_PROVINCES]) do
			if not isTombstone(rec) then
				local nid = tonumber(id) or id
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

function DataOverlay.invalidate()
	cache.loaded = false
end

return DataOverlay
