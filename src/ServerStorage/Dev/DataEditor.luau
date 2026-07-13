local DataEditor = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function dataFolder()
	return ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Data")
end

local function loadClone(modScript)
	local copy = modScript:Clone()
	copy.Parent = game:GetService("ServerStorage")
	local ok, result = pcall(require, copy)
	copy:Destroy()
	if not ok then
		return {}
	end
	return result or {}
end

local function deepClone(t)
	if type(t) ~= "table" then
		return t
	end
	local out = {}
	for k, v in pairs(t) do
		out[k] = deepClone(v)
	end
	return out
end

local countries = {}
local provinces = {}
local eu4Map = {}
local tileOwners = {}
local cultures = {}
local religions = {}
local ideologies = {}
local governments = {}
local loaded = false

-- Single shared editor world (one server + live sync + snapshot save). When true, ALL editors on this
-- (single) server mutate ONE shared in-memory world instead of the per-user isolated worlds that
-- setActiveUser swaps in/out, and Save takes a full snapshot instead of the diff/merge promote path.
-- Default OFF (flag-gated, unpublished) -- flip to true to exercise the new model; a Studio Team Test is a
-- single shared server. See .claude/plans/snapshot-save-single-server-live-sync.md.
local SINGLE_SERVER_EDITOR = false
function DataEditor.isSingleServerMode()
	return SINGLE_SERVER_EDITOR
end

local HISTORY_MAX = 8
local history = {}
local redoStack = {}
local baseline = nil
local batchActive = false
local pendingBatchLabel = nil
local pendingBatchSnapshot = nil

local ensureLoaded

local function captureSnapshot()
	return {
		countries = deepClone(countries),
		provinces = deepClone(provinces),
		eu4Map = deepClone(eu4Map),
		tileOwners = deepClone(tileOwners),
		cultures = deepClone(cultures),
		religions = deepClone(religions),
		ideologies = deepClone(ideologies),
		governments = deepClone(governments),
	}
end

local function restoreSnapshot(snap)
	countries = deepClone(snap.countries)
	provinces = deepClone(snap.provinces)
	eu4Map = deepClone(snap.eu4Map)
	tileOwners = deepClone(snap.tileOwners)
	cultures = deepClone(snap.cultures or {})
	religions = deepClone(snap.religions or {})
	ideologies = deepClone(snap.ideologies or {})
	governments = deepClone(snap.governments or {})
end

-- History entries are one of two kinds:
--   kind="full"   -> { snapshot = <whole-world deep clone> }  (broad mutations: add/remove, migrations, batches)
--   kind="record" -> { changes = { {collection, key, value}, ... } }  (hot single-record edits: paints/updates)
-- The record fast-path avoids deep-cloning all ~5713 provinces on every interactive paint click; it stores only
-- the touched record's before-image and reverse-applies it. Both kinds share one LIFO undo/redo below.
local function collectionByName(name)
	if name == "countries" then
		return countries
	elseif name == "provinces" then
		return provinces
	elseif name == "eu4Map" then
		return eu4Map
	elseif name == "tileOwners" then
		return tileOwners
	elseif name == "cultures" then
		return cultures
	elseif name == "religions" then
		return religions
	elseif name == "ideologies" then
		return ideologies
	elseif name == "governments" then
		return governments
	end
	return nil
end

-- Swap each recorded record to its stored value IN PLACE, returning the inverse entry (the values that were
-- there) so undo/redo are the same operation moving an entry between the two stacks. Resolves the collection by
-- name every call so it stays correct even after a full-snapshot restore reassigned the module-local table.
local function applyRecordEntry(entry)
	local inverse = {}
	for _, ch in ipairs(entry.changes) do
		local tbl = collectionByName(ch.collection)
		local current = nil
		if tbl then
			if tbl[ch.key] ~= nil then
				current = deepClone(tbl[ch.key])
			end
			tbl[ch.key] = (ch.value ~= nil) and deepClone(ch.value) or nil
		end
		inverse[#inverse + 1] = { collection = ch.collection, key = ch.key, value = current }
	end
	return { kind = "record", label = entry.label, at = os.time(), changes = inverse }
end

local function pushHistory(label)
	if not loaded then
		return
	end
	if batchActive then
		return
	end
	table.insert(history, {
		kind = "full",
		label = label or "edit",
		at = os.time(),
		snapshot = captureSnapshot(),
	})
	while #history > HISTORY_MAX do
		table.remove(history, 1)
	end
	table.clear(redoStack)
end

-- Record-level history for a mutation that touches exactly ONE record in ONE collection. Call it BEFORE the
-- mutation (like pushHistory) so it captures the pre-mutation value. Suppressed inside a batch: the batch's one
-- full snapshot already covers everything between beginBatch/endBatch.
local function pushRecordHistory(collection, key, label)
	if not loaded then
		return
	end
	if batchActive then
		return
	end
	local tbl = collectionByName(collection)
	local current = nil
	if tbl and tbl[key] ~= nil then
		current = deepClone(tbl[key])
	end
	table.insert(history, {
		kind = "record",
		label = label or "edit",
		at = os.time(),
		changes = { { collection = collection, key = key, value = current } },
	})
	while #history > HISTORY_MAX do
		table.remove(history, 1)
	end
	table.clear(redoStack)
end

function DataEditor.beginBatch(label)
	ensureLoaded()
	if batchActive then
		DataEditor.endBatch()
	end
	batchActive = true
	pendingBatchLabel = label or "batch"
	pendingBatchSnapshot = captureSnapshot()
end

function DataEditor.endBatch()
	if not batchActive then
		return
	end
	batchActive = false
	if pendingBatchSnapshot and loaded then
		table.insert(history, {
			kind = "full",
			label = pendingBatchLabel,
			at = os.time(),
			snapshot = pendingBatchSnapshot,
		})
		while #history > HISTORY_MAX do
			table.remove(history, 1)
		end
		table.clear(redoStack)
	end
	pendingBatchSnapshot = nil
	pendingBatchLabel = nil
end

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
	["goto"] = true,
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
	if type(s) ~= "string" then
		return false
	end
	if LUA_KEYWORDS[s] then
		return false
	end
	return s:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function escapeString(s)
	return string.format("%q", s)
end

local function normalizeFlag(value)
	if value == nil then
		return nil
	end
	local s = tostring(value):match("^%s*(.-)%s*$")
	if s == "" then
		return nil
	end
	if s:match("^rbxassetid://%d+$") or s:match("^rbxthumb://") or s:match("^http") then
		return s
	end
	local digits = s:match("^(%d+)$")
	if digits then
		return "rbxassetid://" .. digits
	end
	local embedded = s:match("(%d+)")
	if embedded then
		return "rbxassetid://" .. embedded
	end
	return nil
end

local function sortedKeys(tbl, numeric)
	local keys = {}
	for k in pairs(tbl) do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		if numeric then
			return (tonumber(a) or 0) < (tonumber(b) or 0)
		end
		return tostring(a) < tostring(b)
	end)
	return keys
end

local function loadTileOverlay()
	local services = game:GetService("ServerStorage"):FindFirstChild("Services")
	local overlayMod = services and services:FindFirstChild("DataOverlay")
	if not overlayMod then
		return {}
	end
	local ok, overlay = pcall(require, overlayMod)
	if not ok or not overlay or not overlay.getTileOverrides then
		return {}
	end
	local got = overlay.getTileOverrides()
	local out = {}
	for name, value in pairs(got or {}) do
		out[name] = value
	end
	return out
end

-- True when the world is on the collapsed (v3) schema: province ids ARE map part numbers, so new
-- content takes its part number as its id and there is no separate eu4Map bridge. Own overlay
-- require (this runs before overlayModule() is defined later in the file).
local function isCollapsedMode()
	local services = game:GetService("ServerStorage"):FindFirstChild("Services")
	local overlayMod = services and services:FindFirstChild("DataOverlay")
	if not overlayMod then
		return false
	end
	local ok, overlay = pcall(require, overlayMod)
	return ok and overlay and overlay.isCollapsed and overlay.isCollapsed() == true
end

function DataEditor.isCollapsed()
	return isCollapsedMode()
end

function DataEditor.load()
	local data = dataFolder()
	countries = deepClone(loadClone(data:WaitForChild("Countries")))
	provinces = deepClone(loadClone(data:WaitForChild("Provinces")))
	eu4Map = deepClone(loadClone(data:WaitForChild("EU4IDMap")))
	tileOwners = loadTileOverlay()
	cultures = deepClone(loadClone(data:WaitForChild("Cultures")))
	religions = deepClone(loadClone(data:WaitForChild("Religions")))
	ideologies = deepClone(loadClone(data:WaitForChild("Ideologies")))
	governments = deepClone(loadClone(data:WaitForChild("GovernmentTypes")))

	local services = game:GetService("ServerStorage"):FindFirstChild("Services")
	local overlayMod = services and services:FindFirstChild("DataOverlay")
	if overlayMod then
		local ok, overlay = pcall(require, overlayMod)
		if ok and overlay and overlay.snapshot then
			if overlay.isCollapsed and overlay.isCollapsed() then
				-- v3: the @v3 overlay snapshot is authoritative and part-id keyed. Discard the
				-- serial-keyed source so the editor's in-memory state is purely part-id keyed too.
				provinces = {}
				countries = {}
			end
			local snapOk, snap = pcall(overlay.snapshot, false)
			if snapOk and type(snap) == "table" then
				if type(snap.countries) == "table" then
					for tag, rec in pairs(snap.countries) do
						if type(rec) == "table" then
							countries[tag] = deepClone(rec)
						end
					end
				end
				if type(snap.provinces) == "table" then
					for id, rec in pairs(snap.provinces) do
						if type(rec) == "table" then
							local nid = tonumber(id) or id
							provinces[nid] = deepClone(rec)
						end
					end
				end
				if type(snap.eu4Map) == "table" then
					for id, partId in pairs(snap.eu4Map) do
						local nid = tonumber(id) or id
						eu4Map[nid] = partId
					end
				end
				if type(snap.cultures) == "table" then
					for id, rec in pairs(snap.cultures) do
						if type(rec) == "table" then
							cultures[id] = deepClone(rec)
						end
					end
				end
				if type(snap.religions) == "table" then
					for id, rec in pairs(snap.religions) do
						if type(rec) == "table" then
							religions[id] = deepClone(rec)
						end
					end
				end
				if type(snap.ideologies) == "table" then
					for id, rec in pairs(snap.ideologies) do
						if type(rec) == "table" then
							ideologies[id] = deepClone(rec)
						end
					end
				end
				if type(snap.governmentTypes) == "table" then
					for id, rec in pairs(snap.governmentTypes) do
						if type(rec) == "table" then
							governments[id] = deepClone(rec)
						end
					end
				end
				if type(snap.tombstones) == "table" then
					local tombs = snap.tombstones
					for tag in pairs(tombs.countries or {}) do
						countries[tag] = nil
					end
					for id in pairs(tombs.provinces or {}) do
						provinces[tonumber(id) or id] = nil
					end
					for id in pairs(tombs.eu4Map or {}) do
						eu4Map[tonumber(id) or id] = nil
					end
					for id in pairs(tombs.cultures or {}) do
						cultures[id] = nil
					end
					for id in pairs(tombs.religions or {}) do
						religions[id] = nil
					end
					for id in pairs(tombs.ideologies or {}) do
						ideologies[id] = nil
					end
					for id in pairs(tombs.governmentTypes or {}) do
						governments[id] = nil
					end
				end
			end
		end
	end

	loaded = true
	baseline = captureSnapshot()
	table.clear(history)
	table.clear(redoStack)
	return {
		countries = countries,
		provinces = provinces,
		eu4Map = eu4Map,
		tileOwners = tileOwners,
		cultures = cultures,
		religions = religions,
		ideologies = ideologies,
		governments = governments,
	}
end

-- Invert one history/redo entry in place and return its inverse (for the opposite stack). Record entries swap
-- just the touched record(s); full entries capture the current world THEN restore the snapshot.
local function invertEntry(entry)
	if entry.kind == "record" then
		return applyRecordEntry(entry)
	end
	local inverse = { kind = "full", label = entry.label, at = os.time(), snapshot = captureSnapshot() }
	restoreSnapshot(entry.snapshot)
	return inverse
end

function DataEditor.undo()
	ensureLoaded()
	local entry = table.remove(history)
	if not entry then
		return false, "nothing to undo"
	end
	table.insert(redoStack, invertEntry(entry))
	while #redoStack > HISTORY_MAX do
		table.remove(redoStack, 1)
	end
	return true, entry.label
end

function DataEditor.redo()
	ensureLoaded()
	local entry = table.remove(redoStack)
	if not entry then
		return false, "nothing to redo"
	end
	table.insert(history, invertEntry(entry))
	while #history > HISTORY_MAX do
		table.remove(history, 1)
	end
	return true, entry.label
end

function DataEditor.canUndo()
	return #history > 0
end

function DataEditor.canRedo()
	return #redoStack > 0
end

function DataEditor.historyDepth()
	return #history
end

function DataEditor.redoDepth()
	return #redoStack
end

local function recordsEqual(a, b)
	if a == b then
		return true
	end
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return false
	end
	for k, v in pairs(a) do
		if not recordsEqual(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function diffMap(currentMap, baselineMap)
	local added, modified, removed = 0, 0, 0
	for k, v in pairs(currentMap) do
		local prev = baselineMap[k]
		if prev == nil then
			added += 1
		elseif not recordsEqual(v, prev) then
			modified += 1
		end
	end
	for k in pairs(baselineMap) do
		if currentMap[k] == nil then
			removed += 1
		end
	end
	return { added = added, modified = modified, removed = removed }
end

function DataEditor.diffAgainstBaseline()
	ensureLoaded()
	if not baseline then
		return nil
	end
	local d = {
		countries = diffMap(countries, baseline.countries or {}),
		provinces = diffMap(provinces, baseline.provinces or {}),
		eu4Map = diffMap(eu4Map, baseline.eu4Map or {}),
		tileOwners = diffMap(tileOwners, baseline.tileOwners or {}),
		cultures = diffMap(cultures, baseline.cultures or {}),
		religions = diffMap(religions, baseline.religions or {}),
		ideologies = diffMap(ideologies, baseline.ideologies or {}),
		governments = diffMap(governments, baseline.governments or {}),
	}
	local total = 0
	for _, kindDiff in pairs(d) do
		total += kindDiff.added + kindDiff.modified + kindDiff.removed
	end
	d.totalChanges = total
	return d
end

ensureLoaded = function()
	if not loaded then
		DataEditor.load()
	end
end

local function requireKey(tbl, key, label)
	if not tbl[key] then
		error(string.format("%s %q does not exist", label, tostring(key)))
	end
end

function DataEditor.listCountries()
	ensureLoaded()
	for _, tag in ipairs(sortedKeys(countries)) do
		local c = countries[tag]
		print(string.format("  %-6s  %s  (cap=%s)", tag, c.displayName or "", tostring(c.capitalProvinceId)))
	end
end

function DataEditor.listProvinces()
	ensureLoaded()
	for _, id in ipairs(sortedKeys(provinces, true)) do
		local p = provinces[id]
		print(string.format("  [%3d]  %-20s  owner=%-6s", id, p.name or "", tostring(p.ownerTag)))
	end
end

function DataEditor.addCountry(tag, opts)
	ensureLoaded()
	assert(type(tag) == "string" and #tag >= 2, "tag must be a string of 2+ chars")
	assert(type(opts) == "table", "opts must be a table")
	if countries[tag] then
		error(("Country %q already exists"):format(tag))
	end
	local capId = tonumber(opts.capitalProvinceId)
	if not capId then
		error(("Country %q requires a numeric capitalProvinceId"):format(tag))
	end
	if not provinces[capId] then
		error(("Country %q capitalProvinceId %d does not exist"):format(tag, capId))
	end
	if type(opts.primaryCulture) ~= "string" or opts.primaryCulture == "" then
		error(("Country %q requires primaryCulture"):format(tag))
	end
	if type(opts.stateReligion) ~= "string" or opts.stateReligion == "" then
		error(("Country %q requires stateReligion"):format(tag))
	end
	if type(opts.governmentForm) ~= "string" or opts.governmentForm == "" then
		error(("Country %q requires governmentForm"):format(tag))
	end
	-- addCountry writes exactly one record (countries[tag]) and nothing else, so the record fast-path is
	-- sufficient and avoids deep-cloning all ~5.7k provinces for a one-country add. Undo captures the nil
	-- before-image and deletes the record. (removeCountry stays on the full snapshot: it also rewrites every
	-- province that referenced the tag.)
	pushRecordHistory("countries", tag, "addCountry " .. tag)
	countries[tag] = {
		tag = tag,
		displayName = opts.displayName or tag,
		capitalProvinceId = capId,
		primaryCulture = opts.primaryCulture,
		acceptedCultures = opts.acceptedCultures or {},
		stateReligion = opts.stateReligion,
		governmentForm = opts.governmentForm,
		ideology = opts.ideology,
		stability = opts.stability or 0,
		legitimacy = opts.legitimacy or 70,
		treasury = opts.treasury or 100,
		manpower = opts.manpower or 10000,
		politicalPower = opts.politicalPower or 80,
		technologyGroup = opts.technologyGroup or "western",
		historicalRivals = opts.historicalRivals or {},
		historicalFriends = opts.historicalFriends or {},
		color = opts.color or { 128, 128, 128 },
		flagAssetId = normalizeFlag(opts.flagAssetId),
		startingTechs = opts.startingTechs or {},
	}
	return countries[tag]
end

function DataEditor.updateCountry(tag, opts)
	ensureLoaded()
	requireKey(countries, tag, "Country")
	pushRecordHistory("countries", tag, "updateCountry " .. tag)
	for k, v in pairs(opts) do
		if k == "flagAssetId" then
			countries[tag][k] = normalizeFlag(v)
		else
			countries[tag][k] = v
		end
	end
	return countries[tag]
end

-- Per-country starting technologies. techMap is a { [techId] = true } set; every id is validated
-- against the Technologies registry and the call errors on the first invalid id (never silently
-- ignored). Stores a clean { [id] = true } map on the country record (the persisted data field),
-- distinct from the runtime country.techs set granted at boot by ResearchSystem.seedAll.
function DataEditor.setCountryStartingTechs(tag, techMap)
	ensureLoaded()
	requireKey(countries, tag, "Country")
	if type(techMap) ~= "table" then
		error("startingTechs must be a table of { [techId] = true }")
	end
	local technologies = loadClone(dataFolder():WaitForChild("Technologies"))
	local validated, count = {}, 0
	for id, on in pairs(techMap) do
		if on then
			if type(id) ~= "string" or not technologies[id] then
				error(string.format("Technology %q does not exist", tostring(id)))
			end
			validated[id] = true
			count += 1
			if count > 200 then
				error("Too many starting technologies (max 200)")
			end
		end
	end
	pushRecordHistory("countries", tag, "setStartingTechs " .. tag)
	countries[tag].startingTechs = validated
	return countries[tag]
end

function DataEditor.removeCountry(tag)
	ensureLoaded()
	requireKey(countries, tag, "Country")
	pushHistory("removeCountry " .. tag)
	countries[tag] = nil
	-- Strip the deleted tag from ownership AND all three membership arrays. cores/defaultCores/claims are the
	-- v4 list fields the unified paint tool writes; leaving the tag in defaultCores/claims would persist a
	-- dangling reference to a country that no longer exists (through Save -> DataStore).
	local TAG_ARRAY_FIELDS = { "cores", "defaultCores", "releasableCores", "claims" }
	for _, p in pairs(provinces) do
		if p.ownerTag == tag then
			p.ownerTag = "NONE"
		end
		if p.controllerTag == tag then
			p.controllerTag = "NONE"
		end
		for _, field in ipairs(TAG_ARRAY_FIELDS) do
			local arr = p[field]
			if type(arr) == "table" then
				local kept = {}
				for _, t in ipairs(arr) do
					if t ~= tag then
						table.insert(kept, t)
					end
				end
				p[field] = kept
			end
		end
	end
	for name, owner in pairs(tileOwners) do
		if owner == tag then
			tileOwners[name] = nil
		end
	end
	return true
end

local function primaryGood(goods)
	if type(goods) ~= "table" then
		return nil
	end
	local bestId, bestQty = nil, -math.huge
	for gid, qty in pairs(goods) do
		local n = tonumber(qty) or 0
		if n > bestQty then
			bestId, bestQty = gid, n
		end
	end
	return bestId
end

local function normalizeGoods(opts, fallbackTradeGood, fallbackQty)
	local goods = opts.goods
	if type(goods) == "table" then
		local clean = {}
		for gid, qty in pairs(goods) do
			local n = tonumber(qty) or 0
			if type(gid) == "string" and gid ~= "" and n > 0 then
				clean[gid] = n
			end
		end
		return clean
	end
	if fallbackTradeGood and fallbackTradeGood ~= "" and fallbackTradeGood ~= "none" then
		return { [fallbackTradeGood] = fallbackQty or 1 }
	end
	return {}
end

function DataEditor.addProvince(id, opts)
	ensureLoaded()
	id = tonumber(id)
	assert(id, "id must be a number")
	if provinces[id] then
		error(("Province %d already exists"):format(id))
	end
	pushHistory(string.format("addProvince %d", id))
	local goods = normalizeGoods(opts, opts.tradeGood, opts.baseProduction)
	local primary = primaryGood(goods) or opts.tradeGood or "grain"
	local ownerTag = opts.ownerTag or "NONE"
	provinces[id] = {
		id = id,
		name = opts.name or ("Province " .. id),
		displayCityName = opts.displayCityName or opts.name,
		areaId = opts.areaId,
		regionId = opts.regionId,
		superRegionId = opts.superRegionId,
		terrain = opts.terrain or "plains",
		climate = opts.climate or "temperate",
		baseTax = opts.baseTax or 1,
		baseProduction = opts.baseProduction or 1,
		baseManpower = opts.baseManpower or 1,
		culture = opts.culture,
		religion = opts.religion,
		tradeGood = primary,
		goods = goods,
		ownerTag = ownerTag,
		controllerTag = opts.controllerTag or ownerTag,
		cores = opts.cores or ((ownerTag ~= "NONE") and { ownerTag } or {}),
		releasableCores = opts.releasableCores or {},
		isCity = opts.isCity ~= false,
		centerOfTrade = opts.centerOfTrade,
		devTier = opts.devTier or 1,
		infraTier = opts.infraTier or 1,
		fortTier = opts.fortTier or 1,
		population = opts.population or 10000,
		coastal = opts.coastal == true,
		hasShipyard = opts.hasShipyard == true,
	}
	return provinces[id]
end

function DataEditor.updateProvince(id, opts)
	ensureLoaded()
	id = tonumber(id)
	requireKey(provinces, id, "Province")
	pushRecordHistory("provinces", id, string.format("updateProvince %d", id))
	for k, v in pairs(opts) do
		provinces[id][k] = v
	end
	if opts.goods ~= nil then
		local goods = normalizeGoods(opts, provinces[id].tradeGood, provinces[id].baseProduction)
		provinces[id].goods = goods
		local primary = primaryGood(goods)
		if primary then
			provinces[id].tradeGood = primary
		elseif next(goods) == nil then
			provinces[id].tradeGood = "none"
		end
	end
	return provinces[id]
end

local PAINT_TAG_FIELDS = { defaultCore = "defaultCores", releasableCore = "releasableCores", claim = "claims" }

-- Add/remove a single country tag on a province's cores / defaultCores / claims ARRAY. Idempotent: adding an
-- existing tag or removing an absent one is a no-op (no history entry). Parallels assignProvince but for the
-- multi-valued fields -- the editor's unified paint tool drives it (mode = "add" | "remove").
function DataEditor.paintProvinceTag(id, target, tag, mode)
	ensureLoaded()
	id = tonumber(id)
	requireKey(provinces, id, "Province")
	local field = PAINT_TAG_FIELDS[target]
	if not field then
		error("unknown paint target: " .. tostring(target))
	end
	if tag == nil or tag == "" then
		error("tag required")
	end
	-- cores/defaultCores/claims are country-MEMBERSHIP lists; NONE is the owner/controller "unowned" sentinel,
	-- not a country, and must never enter them. Require a real country tag (the UI only offers real tags -- this
	-- rejects a crafted paintTag/paintTagBatch payload carrying NONE).
	requireKey(countries, tag, "Country")
	local province = provinces[id]
	local list = province[field]
	if type(list) ~= "table" then
		list = {}
		province[field] = list
	end
	local idx
	for i, t in ipairs(list) do
		if t == tag then
			idx = i
			break
		end
	end
	if mode == "remove" then
		if idx then
			pushRecordHistory("provinces", id, string.format("paint -%s %d %s", target, id, tag))
			table.remove(list, idx)
		end
	else
		if not idx then
			pushRecordHistory("provinces", id, string.format("paint +%s %d %s", target, id, tag))
			table.insert(list, tag)
		end
	end
	return province
end

function DataEditor.removeProvince(id)
	ensureLoaded()
	id = tonumber(id)
	requireKey(provinces, id, "Province")
	pushHistory(string.format("removeProvince %d", id))
	provinces[id] = nil
	eu4Map[id] = nil
	return true
end

function DataEditor.promoteTile(opts)
	ensureLoaded()
	assert(type(opts) == "table" and type(opts.partName) == "string" and opts.partName ~= "", "partName required")
	local partName = opts.partName

	local eu4Pid = tonumber(partName:match("prov_(%d+)"))
	local collapsed = isCollapsedMode()

	-- Already promoted? v3: the part number IS the province id. v2: scan the eu4Map for the part.
	if collapsed then
		if eu4Pid and provinces[eu4Pid] then
			return { id = eu4Pid, existing = true }
		end
	elseif eu4Pid then
		for sid, mappedEu4 in pairs(eu4Map) do
			if mappedEu4 == eu4Pid then
				return { id = sid, existing = true }
			end
		end
	end

	-- Allocate the new id. v3: the part number itself (one id, no bridge). v2: one above the
	-- current max across the in-memory provinces AND the overlay snapshot.
	local newId
	if collapsed then
		if not eu4Pid then
			error("promoteTile: part '" .. partName .. "' has no prov_<N> number to use as a province id")
		end
		newId = eu4Pid
	else
		local maxId = 0
		for id in pairs(provinces) do
			local n = tonumber(id) or 0
			if n > maxId then
				maxId = n
			end
		end
		local services = game:GetService("ServerStorage"):FindFirstChild("Services")
		local overlayMod = services and services:FindFirstChild("DataOverlay")
		if overlayMod then
			local okOl, overlay = pcall(require, overlayMod)
			if okOl and overlay and overlay.snapshot then
				local okSn, snap = pcall(overlay.snapshot, false)
				if okSn and type(snap) == "table" and type(snap.provinces) == "table" then
					for id in pairs(snap.provinces) do
						local n = tonumber(id) or 0
						if n > maxId then
							maxId = n
						end
					end
				end
			end
		end
		newId = maxId + 1
	end

	local areaId, regionId, superRegionId, terrain, climate
	local map = workspace:FindFirstChild("ArtOfWarMap")
	local provs = map and map:FindFirstChild("Provinces")
	local targetPart = provs and provs:FindFirstChild(partName)
	if targetPart and provs then
		local partsByEU4 = {}
		for _, part in pairs(provs:GetChildren()) do
			if part:IsA("BasePart") then
				local pid = tonumber(part.Name:match("prov_(%d+)"))
				if pid then
					partsByEU4[pid] = part
				end
			end
		end
		local closestSeedId, closestDist = nil, math.huge
		if collapsed then
			-- v3: province id == part id, so look the seed's part up directly by province id.
			for pid in pairs(provinces) do
				local seedPart = partsByEU4[pid]
				if seedPart then
					local d = (seedPart.Position - targetPart.Position).Magnitude
					if d < closestDist then
						closestDist = d
						closestSeedId = pid
					end
				end
			end
		else
			for sid, mappedEu4 in pairs(eu4Map) do
				local seedPart = partsByEU4[mappedEu4]
				if seedPart then
					local d = (seedPart.Position - targetPart.Position).Magnitude
					if d < closestDist then
						closestDist = d
						closestSeedId = sid
					end
				end
			end
		end
		local closestProv = closestSeedId and provinces[closestSeedId]
		if closestProv then
			areaId = closestProv.areaId
			regionId = closestProv.regionId
			superRegionId = closestProv.superRegionId
			terrain = closestProv.terrain
			climate = closestProv.climate
		end
	end

	if not areaId or not regionId or not superRegionId then
		local data = dataFolder()
		local function loadMod(name)
			local mod = data:FindFirstChild(name)
			if not mod then
				return nil
			end
			local ok, t = pcall(loadClone, mod)
			if not ok or type(t) ~= "table" then
				return nil
			end
			return t
		end
		local areasMod = loadMod("Areas") or {}
		local regionsMod = loadMod("Regions") or {}
		local superRegionsMod = loadMod("SuperRegions") or {}
		if not areaId or areaId == "" or not areasMod[areaId] then
			local keys = {}
			for k in pairs(areasMod) do
				table.insert(keys, k)
			end
			table.sort(keys)
			areaId = keys[1] or ""
		end
		local areaRec = areasMod[areaId]
		if areaRec and areaRec.regionId and regionsMod[areaRec.regionId] then
			regionId = areaRec.regionId
		elseif not regionId or regionId == "" or not regionsMod[regionId] then
			local keys = {}
			for k in pairs(regionsMod) do
				table.insert(keys, k)
			end
			table.sort(keys)
			regionId = keys[1] or ""
		end
		local regionRec = regionsMod[regionId]
		if regionRec and regionRec.superRegionId and superRegionsMod[regionRec.superRegionId] then
			superRegionId = regionRec.superRegionId
		elseif not superRegionId or superRegionId == "" or not superRegionsMod[superRegionId] then
			local keys = {}
			for k in pairs(superRegionsMod) do
				table.insert(keys, k)
			end
			table.sort(keys)
			superRegionId = keys[1] or ""
		end
	end

	local pretty = (partName:gsub("^prov_%d+_", "")):gsub("_", " ")
	local ownerTag = opts.ownerTag or "NONE"
	pushHistory(string.format("promoteTile %s -> %d", partName, newId))
	provinces[newId] = {
		id = newId,
		name = pretty,
		displayCityName = pretty,
		areaId = areaId,
		regionId = regionId,
		superRegionId = superRegionId,
		terrain = terrain or opts.terrain or "plains",
		climate = climate or opts.climate or "temperate",
		baseTax = 1,
		baseProduction = 1,
		baseManpower = 1,
		culture = opts.culture,
		religion = opts.religion,
		tradeGood = "grain",
		goods = { grain = 1 },
		ownerTag = ownerTag,
		controllerTag = ownerTag,
		cores = (ownerTag ~= "NONE") and { ownerTag } or {},
		releasableCores = {},
		isCity = true,
		devTier = 1,
		infraTier = 1,
		fortTier = 1,
		population = 10000,
		coastal = false,
		hasShipyard = false,
	}
	-- v2 only: record the serial->part bridge. In v3 the id already IS the part number.
	if eu4Pid and not collapsed then
		eu4Map[newId] = eu4Pid
	end

	return {
		id = newId,
		existing = false,
		areaId = areaId,
		regionId = regionId,
		superRegionId = superRegionId,
	}
end

-- Reassign a province's owner+controller. DELIBERATELY does NOT touch province.cores — the unified paint tool
-- has separate Owner / Core / Default Core / Claim targets, so cores are painted independently (a reassigned
-- province can be owned-but-not-cored, e.g. a conquest). This differs from addProvince/promoteTile, which seed
-- a core because they CREATE a fresh province for the owner. If a scenario workflow ever wants owner-paint to
-- auto-seed a core, do it here (and decide whether to strip the previous owner's core).
function DataEditor.assignProvince(id, ownerTag)
	ensureLoaded()
	id = tonumber(id)
	requireKey(provinces, id, "Province")
	if ownerTag ~= "NONE" then
		requireKey(countries, ownerTag, "Country")
	end
	pushRecordHistory("provinces", id, string.format("assignProvince %d -> %s", id, tostring(ownerTag)))
	local province = provinces[id]
	province.ownerTag = ownerTag
	province.controllerTag = ownerTag
	if ownerTag ~= "NONE" then
		local country = countries[ownerTag]
		if country then
			-- Only SEED culture/religion when the province has none yet — never clobber a
			-- province's existing (possibly custom) culture/religion on an owner reassignment.
			if
				(province.culture == nil or province.culture == "")
				and type(country.primaryCulture) == "string"
				and country.primaryCulture ~= ""
			then
				province.culture = country.primaryCulture
			end
			if
				(province.religion == nil or province.religion == "")
				and type(country.stateReligion) == "string"
				and country.stateReligion ~= ""
			then
				province.religion = country.stateReligion
			end
		end
	end
	return province
end

function DataEditor.assignProvinceField(id, field, value)
	ensureLoaded()
	id = tonumber(id) or id
	requireKey(provinces, id, "Province")
	local province = provinces[id]
	if field == "culture" then
		if value ~= nil and value ~= "" and not cultures[value] then
			error(string.format("Culture %q does not exist", tostring(value)))
		end
		pushRecordHistory(
			"provinces",
			id,
			string.format("setCulture %s -> %s", tostring(id), tostring(value or "<nil>"))
		)
		province.culture = (value ~= nil and value ~= "") and value or nil
	elseif field == "religion" then
		if value ~= nil and value ~= "" and not religions[value] then
			error(string.format("Religion %q does not exist", tostring(value)))
		end
		pushRecordHistory(
			"provinces",
			id,
			string.format("setReligion %s -> %s", tostring(id), tostring(value or "<nil>"))
		)
		province.religion = (value ~= nil and value ~= "") and value or nil
	else
		error(string.format("Unsupported field %q (use 'culture' or 'religion')", tostring(field)))
	end
	return province
end

function DataEditor.mapProvinceToPart(seedId, btPartId)
	ensureLoaded()
	seedId = tonumber(seedId)
	btPartId = tonumber(btPartId)
	assert(seedId and btPartId, "both ids must be numbers")
	if isCollapsedMode() then
		-- v3: a province's id already IS its part number — there is no separate mapping. An identity
		-- mapping is a harmless no-op; pointing it at a DIFFERENT part would be a re-id (not supported).
		if seedId ~= btPartId then
			error(
				string.format(
					"collapsed schema: province %d is bound to its part by identity; cannot remap to part %d",
					seedId,
					btPartId
				)
			)
		end
		return true
	end
	pushHistory(string.format("mapProvinceToPart %d -> %d", seedId, btPartId))
	eu4Map[seedId] = btPartId
	return true
end

function DataEditor.setTileOwner(partName, ownerTag)
	ensureLoaded()
	assert(type(partName) == "string" and partName ~= "", "partName must be a non-empty string")
	local clearing = (ownerTag == nil or ownerTag == "" or ownerTag == "NONE")
	local current = tileOwners[partName]
	if clearing and current == nil then
		return true
	end
	if not clearing and current == ownerTag then
		return true
	end
	if not clearing and not countries[ownerTag] then
		error(string.format("Country %q does not exist", ownerTag))
	end
	pushRecordHistory("tileOwners", partName, "setTileOwner " .. partName)
	if clearing then
		tileOwners[partName] = nil
	else
		tileOwners[partName] = ownerTag
	end
	return true
end

function DataEditor.getTileOwners()
	ensureLoaded()
	return tileOwners
end

function DataEditor.tileOwnerOf(partName)
	ensureLoaded()
	return tileOwners[partName]
end

-- Read-only audit of the serial<->part (eu4Map) mapping. This is the HARD GATE for the
-- Phase C identity collapse (serial id -> part id): the collapse is only valid if eu4Map is a
-- BIJECTION over the live province set — every province maps to exactly one part (totality) and
-- no two provinces share a part (injectivity). It also surfaces orphan mappings and (in play
-- mode) provinces whose part never received a province_id stamp. Never mutates state.
function DataEditor.auditMapping()
	ensureLoaded()

	local function countOf(t)
		local n = 0
		for _ in pairs(t) do
			n += 1
		end
		return n
	end

	-- 1. Injectivity: detect parts targeted by more than one serial.
	local partToSerials = {}
	for sid, pid in pairs(eu4Map) do
		local bucket = partToSerials[pid]
		if not bucket then
			bucket = {}
			partToSerials[pid] = bucket
		end
		table.insert(bucket, sid)
	end
	local duplicateTargets = {}
	for pid, serials in pairs(partToSerials) do
		if #serials > 1 then
			table.sort(serials)
			table.insert(duplicateTargets, { partId = pid, serials = serials })
		end
	end
	table.sort(duplicateTargets, function(a, b)
		return (a.partId or 0) < (b.partId or 0)
	end)

	-- 2. Totality: every live province record has an eu4Map entry.
	local provincesWithoutMapping = {}
	for id in pairs(provinces) do
		if eu4Map[id] == nil then
			table.insert(provincesWithoutMapping, id)
		end
	end
	table.sort(provincesWithoutMapping)

	-- 3a. Orphans: a mapping whose serial has no province record.
	local mappingsWithoutRecord = {}
	for sid in pairs(eu4Map) do
		if provinces[sid] == nil then
			table.insert(mappingsWithoutRecord, sid)
		end
	end
	table.sort(mappingsWithoutRecord)

	-- 3b/4. Part-presence + stamp checks need the live map (play mode). Skipped in edit mode.
	local partIdsPresent, stampedByPart = nil, nil
	local map = workspace:FindFirstChild("ArtOfWarMap")
	local provs = map and map:FindFirstChild("Provinces")
	if provs then
		partIdsPresent, stampedByPart = {}, {}
		for _, part in pairs(provs:GetChildren()) do
			if part:IsA("BasePart") then
				local pid = tonumber(part.Name:match("prov_(%d+)"))
				if pid then
					partIdsPresent[pid] = part.Name
					stampedByPart[pid] = part:GetAttribute("province_id")
				end
			end
		end
	end

	-- 3b. Mapping targets a part that does not exist in the workspace map.
	local mappingsToMissingPart = {}
	if partIdsPresent then
		for sid, pid in pairs(eu4Map) do
			if partIdsPresent[pid] == nil then
				table.insert(mappingsToMissingPart, { serial = sid, partId = pid })
			end
		end
		table.sort(mappingsToMissingPart, function(a, b)
			return (a.serial or 0) < (b.serial or 0)
		end)
	end

	-- 4. Registered-but-unstamped: a province whose mapped part carries no province_id attribute.
	local registeredButUnstamped = {}
	if stampedByPart then
		for sid in pairs(provinces) do
			local pid = eu4Map[sid]
			if pid and stampedByPart[pid] == nil then
				table.insert(registeredButUnstamped, sid)
			end
		end
		table.sort(registeredButUnstamped)
	end

	local injective = #duplicateTargets == 0
	local total = #provincesWithoutMapping == 0
	return {
		injective = injective,
		total = total,
		collapseReady = injective and total,
		mapChecked = provs ~= nil, -- false in edit mode (part-presence/stamp checks skipped)
		duplicateTargets = duplicateTargets,
		provincesWithoutMapping = provincesWithoutMapping,
		mappingsWithoutRecord = mappingsWithoutRecord,
		mappingsToMissingPart = mappingsToMissingPart,
		registeredButUnstamped = registeredButUnstamped,
		counts = {
			provinces = countOf(provinces),
			mappings = countOf(eu4Map),
			duplicateTargets = #duplicateTargets,
			provincesWithoutMapping = #provincesWithoutMapping,
			mappingsWithoutRecord = #mappingsWithoutRecord,
			mappingsToMissingPart = #mappingsToMissingPart,
			registeredButUnstamped = #registeredButUnstamped,
		},
	}
end

-- Pretty-print the mapping audit to the console (developer convenience).
function DataEditor.printMappingAudit()
	local r = DataEditor.auditMapping()
	local c = r.counts
	print(
		string.format(
			"[MappingAudit] %d provinces, %d mappings | collapseReady=%s (injective=%s total=%s)%s",
			c.provinces,
			c.mappings,
			tostring(r.collapseReady),
			tostring(r.injective),
			tostring(r.total),
			r.mapChecked and "" or " [edit mode: part/stamp checks skipped]"
		)
	)
	if #r.duplicateTargets > 0 then
		print(
			string.format(
				"  DUPLICATE TARGETS (%d) — two provinces share one part (BLOCKS collapse):",
				#r.duplicateTargets
			)
		)
		for _, d in ipairs(r.duplicateTargets) do
			print(string.format("    part %s  <-  serials { %s }", tostring(d.partId), table.concat(d.serials, ", ")))
		end
	end
	if #r.provincesWithoutMapping > 0 then
		print(
			string.format(
				"  PROVINCES WITHOUT MAPPING (%d) — no part assigned (BLOCKS collapse): %s",
				#r.provincesWithoutMapping,
				table.concat(r.provincesWithoutMapping, ", ")
			)
		)
	end
	if #r.mappingsWithoutRecord > 0 then
		print(
			string.format(
				"  ORPHAN MAPPINGS (%d) — mapping with no province record (warn): %s",
				#r.mappingsWithoutRecord,
				table.concat(r.mappingsWithoutRecord, ", ")
			)
		)
	end
	if #r.mappingsToMissingPart > 0 then
		local bits = {}
		for _, m in ipairs(r.mappingsToMissingPart) do
			table.insert(bits, string.format("%s->part %s", m.serial, m.partId))
		end
		print(
			string.format(
				"  MAPPINGS TO MISSING PART (%d) — target part absent from map (warn): %s",
				#r.mappingsToMissingPart,
				table.concat(bits, ", ")
			)
		)
	end
	if #r.registeredButUnstamped > 0 then
		print(
			string.format(
				"  REGISTERED BUT UNSTAMPED (%d) — mapped part has no province_id stamp (warn): %s",
				#r.registeredButUnstamped,
				table.concat(r.registeredButUnstamped, ", ")
			)
		)
	end
	if r.collapseReady and #r.mappingsWithoutRecord == 0 and #r.registeredButUnstamped == 0 then
		print("  OK — mapping is a clean bijection; safe to collapse.")
	end
	return r
end

local function buildCountriesSource()
	local nl = string.char(10)
	local lines = { "return {" }
	for _, tag in ipairs(sortedKeys(countries)) do
		local c = countries[tag]
		local keyStr = isIdent(tag) and tag or ("[" .. escapeString(tag) .. "]")
		table.insert(lines, "	" .. keyStr .. " = {")
		table.insert(lines, string.format("		tag = %q,", c.tag or tag))
		table.insert(lines, string.format("		displayName = %q,", c.displayName or tag))
		table.insert(lines, string.format("		capitalProvinceId = %d,", c.capitalProvinceId or 1))
		if c.primaryCulture then
			table.insert(lines, string.format("		primaryCulture = %q,", c.primaryCulture))
		end
		local ac = {}
		for _, v in ipairs(c.acceptedCultures or {}) do
			table.insert(ac, escapeString(v))
		end
		table.insert(lines, "		acceptedCultures = { " .. table.concat(ac, ", ") .. " },")
		if c.stateReligion then
			table.insert(lines, string.format("		stateReligion = %q,", c.stateReligion))
		end
		if c.governmentForm then
			table.insert(lines, string.format("		governmentForm = %q,", c.governmentForm))
		end
		if c.ideology then
			table.insert(lines, string.format("		ideology = %q,", c.ideology))
		end
		table.insert(
			lines,
			string.format(
				"		stability = %d, legitimacy = %d, treasury = %d, manpower = %d, politicalPower = %d,",
				c.stability or 0,
				c.legitimacy or 70,
				c.treasury or 100,
				c.manpower or 10000,
				c.politicalPower or 80
			)
		)
		if c.technologyGroup then
			table.insert(lines, string.format("		technologyGroup = %q,", c.technologyGroup))
		end
		local rivals, friends = {}, {}
		for _, v in ipairs(c.historicalRivals or {}) do
			table.insert(rivals, escapeString(v))
		end
		for _, v in ipairs(c.historicalFriends or {}) do
			table.insert(friends, escapeString(v))
		end
		table.insert(lines, "		historicalRivals = { " .. table.concat(rivals, ", ") .. " },")
		table.insert(lines, "		historicalFriends = { " .. table.concat(friends, ", ") .. " },")
		local col = c.color or { 128, 128, 128 }
		table.insert(lines, string.format("		color = { %d, %d, %d },", col[1] or 128, col[2] or 128, col[3] or 128))
		if c.flagAssetId and c.flagAssetId ~= "" then
			table.insert(lines, string.format("		flagAssetId = %q,", tostring(c.flagAssetId)))
		end
		table.insert(lines, "	},")
	end
	table.insert(lines, "}")
	return table.concat(lines, nl) .. nl
end

local function buildProvincesSource()
	local nl = string.char(10)
	local lines = {
		"local function province(id, def)",
		"	def.id = id",
		"	return def",
		"end",
		"",
		"return {",
	}
	for _, id in ipairs(sortedKeys(provinces, true)) do
		local p = provinces[id]
		local parts = {}
		table.insert(parts, string.format("name = %q", p.name or ""))
		table.insert(parts, string.format("displayCityName = %q", p.displayCityName or p.name or ""))
		table.insert(parts, string.format("areaId = %q", p.areaId or ""))
		table.insert(parts, string.format("regionId = %q", p.regionId or ""))
		table.insert(parts, string.format("superRegionId = %q", p.superRegionId or ""))
		table.insert(parts, string.format("terrain = %q", p.terrain or "plains"))
		table.insert(parts, string.format("climate = %q", p.climate or "temperate"))
		table.insert(
			parts,
			string.format(
				"baseTax = %d, baseProduction = %d, baseManpower = %d",
				p.baseTax or 1,
				p.baseProduction or 1,
				p.baseManpower or 1
			)
		)
		table.insert(
			parts,
			string.format(
				"culture = %q, religion = %q, tradeGood = %q",
				p.culture or "",
				p.religion or "",
				p.tradeGood or "grain"
			)
		)
		if type(p.goods) == "table" and next(p.goods) ~= nil then
			local goodKeys = {}
			for k in pairs(p.goods) do
				table.insert(goodKeys, k)
			end
			table.sort(goodKeys)
			local goodParts = {}
			for _, k in ipairs(goodKeys) do
				table.insert(goodParts, string.format("[%q] = %d", k, tonumber(p.goods[k]) or 0))
			end
			table.insert(parts, "goods = { " .. table.concat(goodParts, ", ") .. " }")
		end
		table.insert(parts, string.format("ownerTag = %q", p.ownerTag or "NONE"))
		-- v4 province fields: emit cores/defaultCores/claims (arrays of country tags) when present so an
		-- export captures the unified-store data rather than silently dropping it.
		local function emitTagArray(field)
			local arr = p[field]
			if type(arr) == "table" and #arr > 0 then
				local tags = {}
				for _, tag in ipairs(arr) do
					table.insert(tags, escapeString(tostring(tag)))
				end
				table.insert(parts, field .. " = { " .. table.concat(tags, ", ") .. " }")
			end
		end
		emitTagArray("cores")
		emitTagArray("defaultCores")
		emitTagArray("releasableCores")
		emitTagArray("claims")
		if p.isCity ~= false then
			table.insert(parts, "isCity = true")
		end
		if p.centerOfTrade then
			table.insert(parts, "centerOfTrade = " .. tostring(p.centerOfTrade))
		end
		table.insert(
			parts,
			string.format(
				"devTier = %d, infraTier = %d, fortTier = %d",
				p.devTier or 1,
				p.infraTier or 1,
				p.fortTier or 1
			)
		)
		table.insert(parts, "population = " .. tostring(p.population or 10000))
		if p.coastal == true then
			table.insert(parts, "coastal = true")
		end
		if p.hasShipyard == true then
			table.insert(parts, "hasShipyard = true")
		end
		table.insert(lines, string.format("	[%d] = province(%d, { %s }),", id, id, table.concat(parts, ", ")))
	end
	table.insert(lines, "}")
	return table.concat(lines, nl) .. nl
end

local function buildEU4MapSource()
	local nl = string.char(10)
	local lines = { "return {" }
	local buf = {}
	for _, id in ipairs(sortedKeys(eu4Map, true)) do
		table.insert(buf, string.format("[%d] = %d", id, eu4Map[id]))
		if #buf == 4 then
			table.insert(lines, "	" .. table.concat(buf, ", ") .. ",")
			buf = {}
		end
	end
	if #buf > 0 then
		table.insert(lines, "	" .. table.concat(buf, ", ") .. ",")
	end
	table.insert(lines, "}")
	return table.concat(lines, nl) .. nl
end

local function buildIdentityRecordsSource(records, groupField)
	local nl = string.char(10)
	local lines = { "return {" }
	for _, id in ipairs(sortedKeys(records)) do
		local r = records[id]
		local keyStr = isIdent(id) and id or ("[" .. escapeString(id) .. "]")
		local groupVal = r and r[groupField]
		local groupStr = (type(groupVal) == "string" and groupVal ~= "") and groupVal or ""
		table.insert(
			lines,
			string.format(
				"	%s = { id = %q, displayName = %q, %s = %q },",
				keyStr,
				r.id or id,
				r.displayName or id,
				groupField,
				groupStr
			)
		)
	end
	table.insert(lines, "}")
	return table.concat(lines, nl) .. nl
end

local function buildCulturesSource()
	return buildIdentityRecordsSource(cultures, "groupId")
end
local function buildReligionsSource()
	return buildIdentityRecordsSource(religions, "group")
end

-- General Lua value serializer for nested record tables (ideologies/governments carry nested
-- `modifiers`/`transitions`/`color`). Handles strings, numbers, booleans, and tables with
-- string/number keys; arrays render inline-ish, maps render sorted for stable diffs.
local function serializeLua(value, indent)
	indent = indent or "\t"
	local t = type(value)
	if t == "string" then
		return escapeString(value)
	end
	if t == "number" or t == "boolean" then
		return tostring(value)
	end
	if t ~= "table" then
		return "nil"
	end
	local n, isArray = 0, true
	for k in pairs(value) do
		n += 1
		if type(k) ~= "number" then
			isArray = false
		end
	end
	if n == 0 then
		return "{}"
	end
	local inner = indent .. "\t"
	local parts = {}
	if isArray and #value == n then
		for _, v in ipairs(value) do
			table.insert(parts, inner .. serializeLua(v, inner))
		end
	else
		for _, k in ipairs(sortedKeys(value)) do
			local keyStr
			if type(k) == "string" and isIdent(k) then
				keyStr = k
			elseif type(k) == "number" then
				keyStr = "[" .. tostring(k) .. "]"
			else
				keyStr = "[" .. escapeString(tostring(k)) .. "]"
			end
			table.insert(parts, inner .. keyStr .. " = " .. serializeLua(value[k], inner))
		end
	end
	return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

local function buildRecordsModuleSource(records)
	local nl = string.char(10)
	local lines = { "return {" }
	for _, id in ipairs(sortedKeys(records)) do
		local keyStr = isIdent(id) and id or ("[" .. escapeString(id) .. "]")
		table.insert(lines, "\t" .. keyStr .. " = " .. serializeLua(records[id], "\t") .. ",")
	end
	table.insert(lines, "}")
	return table.concat(lines, nl) .. nl
end

local function buildIdeologiesSource()
	return buildRecordsModuleSource(ideologies)
end
local function buildGovernmentTypesSource()
	return buildRecordsModuleSource(governments)
end

local function buildTileOwnersSource()
	local nl = string.char(10)
	local lines = { "return {" }
	for _, name in ipairs(sortedKeys(tileOwners)) do
		table.insert(lines, string.format("\t[%s] = %s,", escapeString(name), escapeString(tostring(tileOwners[name]))))
	end
	table.insert(lines, "}")
	return table.concat(lines, nl) .. nl
end

local function trySetSource(script, source)
	local ok, err = pcall(function()
		script.Source = source
	end)
	return ok, err
end

local function overlayModule()
	local services = game:GetService("ServerStorage"):FindFirstChild("Services")
	if not services then
		return nil
	end
	local mod = services:FindFirstChild("DataOverlay")
	if not mod then
		return nil
	end
	local ok, overlay = pcall(require, mod)
	if not ok then
		return nil
	end
	return overlay
end

-- Convert every painted-but-unpromoted owned tile into a real seed province (+ EU4 mapping)
-- before a save persists anything. Both save paths MUST run this: a tile left as a raw
-- tileOwners override is saved owner-only, so at boot it receives an owner attribute but no
-- province record / eu4Map link / province_id and is invisible to movement, buildings, and
-- ownership lookups. Returns the number of tiles promoted. Data-driven (iterates tileOwners;
-- no country/province is named) and idempotent (already-seeded tiles are skipped).
local function promotePaintedTiles()
	local pending = {}
	local collapsed = isCollapsedMode()
	-- Build the set of already-seeded part ids ONCE (was an O(tiles x mappings) nested scan).
	local seededParts = {}
	if not collapsed then
		for _, mappedEu4 in pairs(eu4Map) do
			seededParts[mappedEu4] = true
		end
	end
	for partName, ownerTag in pairs(tileOwners) do
		if type(ownerTag) == "string" and ownerTag ~= "" and ownerTag ~= "NONE" then
			local eu4Pid = tonumber(partName:match("prov_(%d+)"))
			local skip
			if collapsed then
				-- v3: a tile is seeded when a province already exists at its part number. Tiles with
				-- no prov_<N> number can't become a part-id province, so skip them.
				skip = (eu4Pid == nil) or (provinces[eu4Pid] ~= nil)
			else
				skip = (eu4Pid ~= nil) and (seededParts[eu4Pid] == true)
			end
			if not skip then
				table.insert(pending, { partName = partName, ownerTag = ownerTag })
			end
		end
	end
	for _, t in ipairs(pending) do
		local country = countries[t.ownerTag]
		local ok, result = pcall(DataEditor.promoteTile, {
			partName = t.partName,
			culture = country and country.primaryCulture,
			religion = country and country.stateReligion,
			ownerTag = t.ownerTag,
		})
		if ok and type(result) == "table" and result.id and not result.existing then
			tileOwners[t.partName] = nil
		end
	end
	return #pending
end

function DataEditor.save()
	ensureLoaded()
	local overlay = overlayModule()
	if not overlay then
		return {
			mode = "error",
			error = "DataOverlay module not available — cannot save without it",
		}
	end

	promotePaintedTiles()

	local priorBaseline = baseline or {}
	local counts = { countries = 0, provinces = 0, eu4map = 0, tiles = 0, cultures = 0, religions = 0, tombstones = 0 }
	local edits = { countries = {}, provinces = {}, eu4map = {}, tiles = {}, cultures = {}, religions = {} }
	local TOMB = overlay.TOMBSTONE or false
	local previousTiles = overlay.getTileOverrides and overlay.getTileOverrides() or {}

	-- Journal only records that actually changed this session (differ from the session baseline), so
	-- DataOverlay's MERGE_SAVES flush overlays just our edits instead of our whole (possibly stale)
	-- world -- otherwise this path would revert co-editors' concurrent changes. DEAD while staging is
	-- on (save routes through promote()), but keep it merge-safe in case STAGING_ENABLED is flipped off.
	for tag, record in pairs(countries) do
		local prev = priorBaseline.countries and priorBaseline.countries[tag]
		if prev == nil or not recordsEqual(record, prev) then
			overlay.setCountry(tag, record)
			counts.countries += 1
			edits.countries[tag] = record
		end
	end
	for tag in pairs(priorBaseline.countries or {}) do
		if not countries[tag] then
			overlay.deleteCountry(tag)
			counts.tombstones += 1
			edits.countries[tag] = TOMB
		end
	end

	for id, record in pairs(provinces) do
		local prev = priorBaseline.provinces and priorBaseline.provinces[id]
		if prev == nil or not recordsEqual(record, prev) then
			overlay.setProvince(id, record)
			counts.provinces += 1
			edits.provinces[tostring(id)] = record
		end
	end
	for id in pairs(priorBaseline.provinces or {}) do
		if not provinces[id] then
			overlay.deleteProvince(id)
			counts.tombstones += 1
			edits.provinces[tostring(id)] = TOMB
		end
	end

	for id, part in pairs(eu4Map) do
		local prev = priorBaseline.eu4Map and priorBaseline.eu4Map[id]
		if prev == nil or not recordsEqual(part, prev) then
			overlay.setEU4Map(id, part)
			counts.eu4map += 1
			edits.eu4map[tostring(id)] = part
		end
	end
	for id in pairs(priorBaseline.eu4Map or {}) do
		if not eu4Map[id] then
			overlay.deleteEU4Map(id)
			counts.tombstones += 1
			edits.eu4map[tostring(id)] = TOMB
		end
	end

	for name, ownerTag in pairs(tileOwners) do
		local prev = priorBaseline.tileOwners and priorBaseline.tileOwners[name]
		if prev == nil or not recordsEqual(ownerTag, prev) then
			overlay.setTile(name, ownerTag)
			counts.tiles += 1
			edits.tiles[name] = ownerTag
		end
	end
	for name in pairs(previousTiles) do
		if tileOwners[name] == nil then
			overlay.deleteTile(name)
			counts.tombstones += 1
			edits.tiles[name] = TOMB
		end
	end

	for id, record in pairs(cultures) do
		local prev = priorBaseline.cultures and priorBaseline.cultures[id]
		if prev == nil or not recordsEqual(record, prev) then
			overlay.setCulture(id, record)
			counts.cultures += 1
			edits.cultures[id] = record
		end
	end
	for id in pairs(priorBaseline.cultures or {}) do
		if not cultures[id] then
			overlay.deleteCulture(id)
			counts.tombstones += 1
			edits.cultures[id] = TOMB
		end
	end

	for id, record in pairs(religions) do
		local prev = priorBaseline.religions and priorBaseline.religions[id]
		if prev == nil or not recordsEqual(record, prev) then
			overlay.setReligion(id, record)
			counts.religions += 1
			edits.religions[id] = record
		end
	end
	for id in pairs(priorBaseline.religions or {}) do
		if not religions[id] then
			overlay.deleteReligion(id)
			counts.tombstones += 1
			edits.religions[id] = TOMB
		end
	end

	counts.ideologies = 0
	edits.ideologies = {}
	if overlay.setIdeology then
		for id, record in pairs(ideologies) do
			local prev = priorBaseline.ideologies and priorBaseline.ideologies[id]
			if prev == nil or not recordsEqual(record, prev) then
				overlay.setIdeology(id, record)
				counts.ideologies += 1
				edits.ideologies[id] = record
			end
		end
		for id in pairs(priorBaseline.ideologies or {}) do
			if not ideologies[id] then
				overlay.deleteIdeology(id)
				counts.tombstones += 1
				edits.ideologies[id] = TOMB
			end
		end
	end

	counts.governments = 0
	edits.governmentTypes = {}
	if overlay.setGovernmentType then
		for id, record in pairs(governments) do
			local prev = priorBaseline.governments and priorBaseline.governments[id]
			if prev == nil or not recordsEqual(record, prev) then
				overlay.setGovernmentType(id, record)
				counts.governments += 1
				edits.governmentTypes[id] = record
			end
		end
		for id in pairs(priorBaseline.governments or {}) do
			if not governments[id] then
				overlay.deleteGovernmentType(id)
				counts.tombstones += 1
				edits.governmentTypes[id] = TOMB
			end
		end
	end

	local flush = overlay.flush and overlay.flush()
		or { attempted = 0, writes = 0, failures = 0, blocked = 0, skipped = 0, errors = {} }
	local writes = {
		countries = counts.countries,
		provinces = counts.provinces,
		eu4map = counts.eu4map,
		tiles = counts.tiles,
		cultures = counts.cultures,
		religions = counts.religions,
		tombstones = counts.tombstones,
		failures = flush.failures or 0,
		flushAttempted = flush.attempted or 0,
		flushWrites = flush.writes or 0,
		flushBlocked = flush.blocked or 0,
		flushSkipped = flush.skipped or 0,
		flushErrors = flush.errors,
	}

	local verify = nil
	if overlay.verifyWrites and writes.failures == 0 then
		verify = overlay.verifyWrites(edits)
	end

	local verifyText
	if verify and verify.total > 0 then
		if verify.verified == verify.total then
			verifyText = string.format("verified %d/%d", verify.verified, verify.total)
		else
			verifyText = string.format(
				"verified %d/%d (mismatch %d, missing %d, err %d)",
				verify.verified,
				verify.total,
				verify.mismatch,
				verify.missing,
				verify.errors
			)
		end
	else
		verifyText = "verify skipped"
	end

	if writes.failures == 0 then
		baseline = captureSnapshot()
		table.clear(history)
		table.clear(redoStack)
	end

	local failSuffix
	if writes.failures > 0 then
		local parts = { string.format("%d fail", writes.failures) }
		if writes.flushBlocked > 0 then
			table.insert(parts, string.format("%d blocked (load incomplete — wait for retry)", writes.flushBlocked))
		end
		if writes.flushSkipped > 0 then
			table.insert(parts, string.format("%d cooling", writes.flushSkipped))
		end
		failSuffix = " (" .. table.concat(parts, ", ") .. ")"
	else
		failSuffix = ""
	end

	return {
		mode = "datastore",
		writes = writes,
		verify = verify,
		message = string.format(
			"Saved: %dC %dP %dM %dT %dtomb%s · %s",
			writes.countries,
			writes.provinces,
			writes.eu4map,
			writes.tiles,
			writes.tombstones,
			failSuffix,
			verifyText
		),
	}
end

-- Single-server snapshot save: persist the ENTIRE shared world to the :edit aggregates as a full overwrite
-- (no diff, no per-record merge). Only used in SINGLE_SERVER_EDITOR mode, where one server owns the world so
-- a whole-world snapshot is always the complete authoritative state. Promotes painted tiles to real seeds
-- first (like the other save paths) so they persist as province records, not owner-only tile overrides.
function DataEditor.snapshotSave()
	ensureLoaded()
	local overlay = overlayModule()
	if not overlay or not overlay.writeFullSnapshot then
		return { ok = false, error = "DataOverlay.writeFullSnapshot unavailable (update DataOverlay first)" }
	end
	promotePaintedTiles()
	local world = {
		country = countries,
		province = provinces,
		eu4map = eu4Map,
		tile = tileOwners,
		culture = cultures,
		religion = religions,
		ideology = ideologies,
		government_type = governments,
	}
	local result = overlay.writeFullSnapshot(world)
	if result.ok then
		-- Re-baseline to the just-saved world and clear undo history so no inverse entry points across the
		-- save boundary (matches DataEditor.save's post-write reset).
		baseline = captureSnapshot()
		table.clear(history)
		table.clear(redoStack)
	end
	return result
end

local function stageOutputs(entries, clearAll)
	local folder = game:GetService("ServerStorage"):FindFirstChild("DataEditorOutput")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "DataEditorOutput"
		folder.Parent = game:GetService("ServerStorage")
	end
	if clearAll then
		for _, child in folder:GetChildren() do
			child:Destroy()
		end
	end
	for _, entry in ipairs(entries) do
		local existing = folder:FindFirstChild(entry.name .. ".lua")
		if existing then
			existing:Destroy()
		end
		local sv = Instance.new("StringValue")
		sv.Name = entry.name .. ".lua"
		sv.Value = entry.src
		sv.Parent = folder
	end
	return folder
end

function DataEditor.exportToLua()
	ensureLoaded()
	local data = dataFolder()
	-- Module-backed sources (written directly to their ModuleScript in edit mode).
	local sources = {
		{ name = "Countries", src = buildCountriesSource() },
		{ name = "Provinces", src = buildProvincesSource() },
		{ name = "EU4IDMap", src = buildEU4MapSource() },
		{ name = "Cultures", src = buildCulturesSource() },
		{ name = "Religions", src = buildReligionsSource() },
		{ name = "Ideologies", src = buildIdeologiesSource() },
		{ name = "GovernmentTypes", src = buildGovernmentTypesSource() },
	}
	-- Tile ownership has no source ModuleScript (it lives only in the DataOverlay), so it can't be
	-- written back to source. Always stage it as a recoverable StringValue so "export then commit"
	-- captures it rather than silently dropping it.
	local stageOnly = {
		{ name = "TileOwners", src = buildTileOwnersSource() },
	}

	local errors = {}
	local allOk = true
	for _, entry in ipairs(sources) do
		local target = data:FindFirstChild(entry.name)
		if not target then
			allOk = false
			table.insert(errors, entry.name .. ": ModuleScript not found")
		else
			local ok, err = trySetSource(target, entry.src)
			if not ok then
				allOk = false
				table.insert(errors, entry.name .. ": " .. tostring(err))
			end
		end
	end

	if allOk then
		stageOutputs(stageOnly, false)
		return {
			mode = "source",
			message = "Exported Countries/Provinces/EU4IDMap/Cultures/Religions/Ideologies/GovernmentTypes to ModuleScript source. TileOwners staged in ServerStorage.DataEditorOutput (no source module). Save the place (Ctrl+S) to persist across sessions.",
		}
	end

	-- Failure path (e.g. running on a live server): stage everything for recovery.
	local all = {}
	for _, e in ipairs(sources) do
		table.insert(all, e)
	end
	for _, e in ipairs(stageOnly) do
		table.insert(all, e)
	end
	stageOutputs(all, true)

	return {
		mode = "export",
		message = "Source ModuleScripts cannot be written from a running server. Stop the playtest (F8 or shift+F5), then run Export again from edit mode — the editor will write directly to the ModuleScript sources. The current playtest's edits (including Ideologies/GovernmentTypes/TileOwners) have been staged in ServerStorage.DataEditorOutput as a fallback if you need to recover them.",
		errors = errors,
	}
end

function DataEditor.getState()
	ensureLoaded()
	return {
		countries = countries,
		provinces = provinces,
		eu4Map = eu4Map,
		tileOwners = tileOwners,
		cultures = cultures,
		religions = religions,
		ideologies = ideologies,
		governments = governments,
	}
end

function DataEditor.addCulture(id, opts)
	ensureLoaded()
	assert(type(id) == "string" and id ~= "", "culture id required")
	assert(type(opts) == "table", "opts must be a table")
	if cultures[id] then
		error(("Culture %q already exists"):format(id))
	end
	-- Identity registry edits (cultures/religions/ideologies/governments) each touch exactly one record in one
	-- collection: add/update write the single record, and remove only deletes it after a read-only ref-check
	-- (the loops over provinces/countries just count references and error; they never mutate). So all of them
	-- use the record fast-path instead of a whole-world snapshot per edit.
	pushRecordHistory("cultures", id, "addCulture " .. id)
	cultures[id] = {
		id = id,
		displayName = opts.displayName or id,
		groupId = opts.groupId or "",
	}
	return cultures[id]
end

function DataEditor.updateCulture(id, opts)
	ensureLoaded()
	requireKey(cultures, id, "Culture")
	pushRecordHistory("cultures", id, "updateCulture " .. id)
	for k, v in pairs(opts) do
		cultures[id][k] = v
	end
	cultures[id].id = id
	return cultures[id]
end

function DataEditor.removeCulture(id)
	ensureLoaded()
	requireKey(cultures, id, "Culture")
	local refs = 0
	for _, p in pairs(provinces) do
		if p.culture == id then
			refs += 1
		end
	end
	for _, c in pairs(countries) do
		if c.primaryCulture == id then
			refs += 1
		end
		if type(c.acceptedCultures) == "table" then
			for _, ac in ipairs(c.acceptedCultures) do
				if ac == id then
					refs += 1
				end
			end
		end
	end
	if refs > 0 then
		error(string.format("Culture %q is still referenced by %d record(s) — reassign them first", id, refs))
	end
	pushRecordHistory("cultures", id, "removeCulture " .. id)
	cultures[id] = nil
	return true
end

function DataEditor.addReligion(id, opts)
	ensureLoaded()
	assert(type(id) == "string" and id ~= "", "religion id required")
	assert(type(opts) == "table", "opts must be a table")
	if religions[id] then
		error(("Religion %q already exists"):format(id))
	end
	pushRecordHistory("religions", id, "addReligion " .. id)
	religions[id] = {
		id = id,
		displayName = opts.displayName or id,
		group = opts.group or "",
	}
	return religions[id]
end

function DataEditor.updateReligion(id, opts)
	ensureLoaded()
	requireKey(religions, id, "Religion")
	pushRecordHistory("religions", id, "updateReligion " .. id)
	for k, v in pairs(opts) do
		religions[id][k] = v
	end
	religions[id].id = id
	return religions[id]
end

function DataEditor.removeReligion(id)
	ensureLoaded()
	requireKey(religions, id, "Religion")
	local refs = 0
	for _, p in pairs(provinces) do
		if p.religion == id then
			refs += 1
		end
	end
	for _, c in pairs(countries) do
		if c.stateReligion == id then
			refs += 1
		end
	end
	if refs > 0 then
		error(string.format("Religion %q is still referenced by %d record(s) — reassign them first", id, refs))
	end
	pushRecordHistory("religions", id, "removeReligion " .. id)
	religions[id] = nil
	return true
end

function DataEditor.addIdeology(id, opts)
	ensureLoaded()
	assert(type(id) == "string" and id ~= "", "ideology id required")
	assert(type(opts) == "table", "opts must be a table")
	if ideologies[id] then
		error(("Ideology %q already exists"):format(id))
	end
	pushRecordHistory("ideologies", id, "addIdeology " .. id)
	ideologies[id] = {
		id = id,
		displayName = opts.displayName or id,
		modifiers = type(opts.modifiers) == "table" and deepClone(opts.modifiers) or {},
		color = type(opts.color) == "table" and deepClone(opts.color) or { 200, 200, 200 },
	}
	return ideologies[id]
end

function DataEditor.updateIdeology(id, opts)
	ensureLoaded()
	requireKey(ideologies, id, "Ideology")
	pushRecordHistory("ideologies", id, "updateIdeology " .. id)
	for k, v in pairs(opts) do
		if k == "modifiers" or k == "color" then
			ideologies[id][k] = type(v) == "table" and deepClone(v) or v
		else
			ideologies[id][k] = v
		end
	end
	ideologies[id].id = id
	return ideologies[id]
end

function DataEditor.removeIdeology(id)
	ensureLoaded()
	requireKey(ideologies, id, "Ideology")
	local refs = 0
	for _, c in pairs(countries) do
		if c.ideology == id then
			refs += 1
		end
	end
	for _, gov in pairs(governments) do
		if type(gov.allowedIdeologies) == "table" then
			for _, allowed in ipairs(gov.allowedIdeologies) do
				if allowed == id then
					refs += 1
					break
				end
			end
		end
	end
	if refs > 0 then
		error(string.format("Ideology %q is still referenced by %d record(s) — reassign them first", id, refs))
	end
	pushRecordHistory("ideologies", id, "removeIdeology " .. id)
	ideologies[id] = nil
	return true
end

function DataEditor.addGovernmentType(id, opts)
	ensureLoaded()
	assert(type(id) == "string" and id ~= "", "government id required")
	assert(type(opts) == "table", "opts must be a table")
	if governments[id] then
		error(("Government %q already exists"):format(id))
	end
	pushRecordHistory("governments", id, "addGovernmentType " .. id)
	governments[id] = {
		id = id,
		displayName = opts.displayName or id,
		allowedIdeologies = type(opts.allowedIdeologies) == "table" and deepClone(opts.allowedIdeologies) or {},
		modifiers = type(opts.modifiers) == "table" and deepClone(opts.modifiers) or {},
		ppStartBonus = tonumber(opts.ppStartBonus) or 0,
		ppPerTick = tonumber(opts.ppPerTick) or 1.0,
		transitions = type(opts.transitions) == "table" and deepClone(opts.transitions) or {},
	}
	return governments[id]
end

function DataEditor.updateGovernmentType(id, opts)
	ensureLoaded()
	requireKey(governments, id, "Government")
	pushRecordHistory("governments", id, "updateGovernmentType " .. id)
	for k, v in pairs(opts) do
		if k == "allowedIdeologies" or k == "modifiers" or k == "transitions" then
			governments[id][k] = type(v) == "table" and deepClone(v) or v
		elseif k == "ppStartBonus" or k == "ppPerTick" then
			governments[id][k] = tonumber(v) or governments[id][k]
		else
			governments[id][k] = v
		end
	end
	governments[id].id = id
	return governments[id]
end

function DataEditor.removeGovernmentType(id)
	ensureLoaded()
	requireKey(governments, id, "Government")
	local refs = 0
	for _, c in pairs(countries) do
		if c.governmentForm == id then
			refs += 1
		end
	end
	for _, gov in pairs(governments) do
		if type(gov.transitions) == "table" and gov.transitions[id] ~= nil then
			refs += 1
		end
	end
	if refs > 0 then
		error(
			string.format(
				"Government %q is still referenced by %d record(s) — reassign or remove the transitions first",
				id,
				refs
			)
		)
	end
	pushRecordHistory("governments", id, "removeGovernmentType " .. id)
	governments[id] = nil
	return true
end

function DataEditor.dumpDataStore(forceRefresh)
	local overlay = overlayModule()
	if not overlay or not overlay.snapshot then
		return { mode = "error", error = "DataOverlay.snapshot unavailable" }
	end
	return overlay.snapshot(forceRefresh)
end

-- Named Save/Load map configs (RoN "Save/Load Map"). Thin wrappers over the DataOverlay implementation;
-- loadConfig also reloads the editor model so the UI reflects the freshly-loaded world immediately.
function DataEditor.saveConfig(name)
	local overlay = overlayModule()
	assert(overlay and overlay.saveNamedConfig, "DataOverlay.saveNamedConfig unavailable")
	return overlay.saveNamedConfig(name)
end

function DataEditor.listConfigs()
	local overlay = overlayModule()
	assert(overlay and overlay.listNamedConfigs, "DataOverlay.listNamedConfigs unavailable")
	return overlay.listNamedConfigs()
end

function DataEditor.deleteConfig(name)
	local overlay = overlayModule()
	assert(overlay and overlay.deleteNamedConfig, "DataOverlay.deleteNamedConfig unavailable")
	return overlay.deleteNamedConfig(name)
end

function DataEditor.loadConfig(name)
	local overlay = overlayModule()
	assert(overlay and overlay.loadNamedConfig, "DataOverlay.loadNamedConfig unavailable")
	local result = overlay.loadNamedConfig(name)
	DataEditor.load() -- rebuild the editor model from the freshly-loaded overlay cache
	return result
end

-- Publish the editor's working world (the ":edit" keys) to the LIVE keys the main game reads. Only the
-- explicit "Push to Live" action calls this; ordinary editor saves/loads never touch the live world.
function DataEditor.pushToLive()
	local overlay = overlayModule()
	if not overlay or not overlay.pushEditToLive then
		return { ok = false, error = "DataOverlay.pushEditToLive unavailable" }
	end
	return overlay.pushEditToLive()
end

function DataEditor.migrateLegacy()
	local overlay = overlayModule()
	if not overlay or not overlay.migrateLegacy then
		return { mode = "error", error = "DataOverlay.migrateLegacy unavailable" }
	end
	local report = overlay.migrateLegacy() or {}
	if report.busy then
		return {
			mode = "migrate",
			merged = report,
			flush = { attempted = 0, writes = 0, failures = 0 },
			message = "Migration already in progress — please wait for it to finish",
		}
	end
	if report.cooldown then
		return {
			mode = "migrate",
			merged = report,
			flush = { attempted = 0, writes = 0, failures = 0 },
			message = string.format(
				"Migration on cooldown after recent throttle — try again in %ds",
				report.cooldown
			),
		}
	end
	if report.error then
		return { mode = "error", error = "migrate failed: " .. tostring(report.error) }
	end
	local flush = overlay.flush and overlay.flush() or { writes = 0, failures = 0 }
	local message
	if (flush.skipped or 0) > 0 then
		message = string.format(
			"Legacy merged: +%dC +%dP +%dM +%dT +%dCu +%dRe · flush %d/%d (skipped %d cooling)",
			report.countries or 0,
			report.provinces or 0,
			report.eu4map or 0,
			report.tiles or 0,
			report.cultures or 0,
			report.religions or 0,
			flush.writes or 0,
			flush.attempted or 0,
			flush.skipped or 0
		)
	else
		message = string.format(
			"Legacy merged: +%dC +%dP +%dM +%dT +%dCu +%dRe · flush %d/%d",
			report.countries or 0,
			report.provinces or 0,
			report.eu4map or 0,
			report.tiles or 0,
			report.cultures or 0,
			report.religions or 0,
			flush.writes or 0,
			flush.attempted or (flush.writes or 0)
		)
	end
	return {
		mode = "migrate",
		merged = report,
		flush = flush,
		message = message,
	}
end

local function cloneStack(stack)
	local out = {}
	for i = 1, #stack do
		out[i] = stack[i]
	end
	return out
end

function DataEditor.captureFullState()
	return {
		countries = deepClone(countries),
		provinces = deepClone(provinces),
		eu4Map = deepClone(eu4Map),
		tileOwners = deepClone(tileOwners),
		cultures = deepClone(cultures),
		religions = deepClone(religions),
		ideologies = deepClone(ideologies),
		governments = deepClone(governments),
		history = cloneStack(history),
		redoStack = cloneStack(redoStack),
		baseline = baseline and deepClone(baseline) or nil,
		loaded = loaded,
	}
end

function DataEditor.restoreFullState(state)
	if type(state) ~= "table" then
		return false
	end
	countries = deepClone(state.countries or {})
	provinces = deepClone(state.provinces or {})
	eu4Map = deepClone(state.eu4Map or {})
	tileOwners = deepClone(state.tileOwners or {})
	cultures = deepClone(state.cultures or {})
	religions = deepClone(state.religions or {})
	ideologies = deepClone(state.ideologies or {})
	governments = deepClone(state.governments or {})
	history = cloneStack(state.history or {})
	redoStack = cloneStack(state.redoStack or {})
	baseline = state.baseline and deepClone(state.baseline) or nil
	loaded = state.loaded == true
	return true
end

local activeUser = nil
local userStates = {}

function DataEditor.setActiveUser(userId)
	if userId == nil then
		return
	end
	if SINGLE_SERVER_EDITOR then
		-- One shared world for every editor on this single server: no per-user swap. Just record who's
		-- active (edit attribution / presence) and ensure the shared world is loaded once. Never
		-- capture/restore per-user state or reload here.
		activeUser = userId
		ensureLoaded()
		return
	end
	if activeUser == userId then
		return
	end
	if activeUser ~= nil then
		userStates[activeUser] = DataEditor.captureFullState()
	end
	activeUser = userId
	if userStates[userId] then
		DataEditor.restoreFullState(userStates[userId])
		return
	end
	local ok, res = pcall(DataEditor.loadDraft)
	if not (ok and type(res) == "table" and res.ok == true) then
		DataEditor.load()
	end
	userStates[userId] = DataEditor.captureFullState()
end

function DataEditor.getActiveUser()
	return activeUser
end

function DataEditor.clearActiveUser()
	if SINGLE_SERVER_EDITOR then
		activeUser = nil
		return
	end
	if activeUser ~= nil then
		userStates[activeUser] = DataEditor.captureFullState()
		activeUser = nil
	end
end

function DataEditor.dropUserState(userId)
	if userId == nil then
		return
	end
	if SINGLE_SERVER_EDITOR then
		-- Shared world stays put when an editor leaves -- only clear their active-user attribution. Never set
		-- loaded=false here: that would drop the shared in-memory world and lose other editors' unsaved edits.
		if activeUser == userId then
			activeUser = nil
		end
		return
	end
	userStates[userId] = nil
	if activeUser == userId then
		activeUser = nil
		loaded = false
	end
end

local function draftOverlayModule()
	local services = game:GetService("ServerStorage"):FindFirstChild("Services")
	if not services then
		return nil
	end
	local mod = services:FindFirstChild("DraftOverlay")
	if not mod then
		return nil
	end
	local ok, draft = pcall(require, mod)
	if not ok then
		return nil
	end
	return draft
end

local function currentBundleForDraft()
	return {
		countries = deepClone(countries),
		provinces = deepClone(provinces),
		eu4Map = deepClone(eu4Map),
		tileOwners = deepClone(tileOwners),
		cultures = deepClone(cultures),
		religions = deepClone(religions),
		ideologies = deepClone(ideologies),
		governments = deepClone(governments),
	}
end

local function sharedSnapshotBundle()
	local overlay = overlayModule()
	if not overlay or not overlay.snapshot then
		return nil
	end
	local ok, snap = pcall(overlay.snapshot, false)
	if not ok or type(snap) ~= "table" then
		return nil
	end
	local data = dataFolder()
	local bundle = {
		countries = deepClone(loadClone(data:WaitForChild("Countries"))),
		provinces = deepClone(loadClone(data:WaitForChild("Provinces"))),
		eu4Map = deepClone(loadClone(data:WaitForChild("EU4IDMap"))),
		tileOwners = {},
		cultures = deepClone(loadClone(data:WaitForChild("Cultures"))),
		religions = deepClone(loadClone(data:WaitForChild("Religions"))),
		ideologies = deepClone(loadClone(data:WaitForChild("Ideologies"))),
		governments = deepClone(loadClone(data:WaitForChild("GovernmentTypes"))),
	}
	if overlay.getTileOverrides then
		for name, value in pairs(overlay.getTileOverrides() or {}) do
			bundle.tileOwners[name] = value
		end
	end
	if type(snap.countries) == "table" then
		for tag, rec in pairs(snap.countries) do
			if type(rec) == "table" then
				bundle.countries[tag] = deepClone(rec)
			end
		end
	end
	if type(snap.provinces) == "table" then
		for id, rec in pairs(snap.provinces) do
			if type(rec) == "table" then
				bundle.provinces[tonumber(id) or id] = deepClone(rec)
			end
		end
	end
	if type(snap.eu4Map) == "table" then
		for id, part in pairs(snap.eu4Map) do
			bundle.eu4Map[tonumber(id) or id] = part
		end
	end
	if type(snap.cultures) == "table" then
		for id, rec in pairs(snap.cultures) do
			if type(rec) == "table" then
				bundle.cultures[id] = deepClone(rec)
			end
		end
	end
	if type(snap.religions) == "table" then
		for id, rec in pairs(snap.religions) do
			if type(rec) == "table" then
				bundle.religions[id] = deepClone(rec)
			end
		end
	end
	if type(snap.ideologies) == "table" then
		for id, rec in pairs(snap.ideologies) do
			if type(rec) == "table" then
				bundle.ideologies[id] = deepClone(rec)
			end
		end
	end
	if type(snap.governmentTypes) == "table" then
		for id, rec in pairs(snap.governmentTypes) do
			if type(rec) == "table" then
				bundle.governments[id] = deepClone(rec)
			end
		end
	end
	if type(snap.tombstones) == "table" then
		local tombs = snap.tombstones
		for tag in pairs(tombs.countries or {}) do
			bundle.countries[tag] = nil
		end
		for id in pairs(tombs.provinces or {}) do
			bundle.provinces[tonumber(id) or id] = nil
		end
		for id in pairs(tombs.eu4Map or {}) do
			bundle.eu4Map[tonumber(id) or id] = nil
		end
		for id in pairs(tombs.cultures or {}) do
			bundle.cultures[id] = nil
		end
		for id in pairs(tombs.religions or {}) do
			bundle.religions[id] = nil
		end
		for id in pairs(tombs.ideologies or {}) do
			bundle.ideologies[id] = nil
		end
		for id in pairs(tombs.governmentTypes or {}) do
			bundle.governments[id] = nil
		end
	end
	return bundle
end

function DataEditor.saveDraft()
	if activeUser == nil then
		return { ok = false, error = "no active user" }
	end
	local draft = draftOverlayModule()
	if not draft then
		return { ok = false, error = "DraftOverlay unavailable" }
	end
	ensureLoaded()
	local bundle = currentBundleForDraft()
	local result = draft.saveDraft(activeUser, bundle)
	return result
end

function DataEditor.loadDraft()
	if activeUser == nil then
		return { ok = false, error = "no active user" }
	end
	local draft = draftOverlayModule()
	if not draft then
		return { ok = false, error = "DraftOverlay unavailable" }
	end
	local stored = draft.loadDraft(activeUser)
	if stored then
		DataEditor.restoreFullState({
			countries = stored.countries,
			provinces = stored.provinces,
			eu4Map = stored.eu4Map,
			tileOwners = stored.tileOwners,
			cultures = stored.cultures,
			religions = stored.religions,
			ideologies = stored.ideologies,
			governments = stored.governments,
			history = {},
			redoStack = {},
			baseline = nil,
			loaded = true,
		})
		baseline = sharedSnapshotBundle()
		return { ok = true, mode = "loaded_draft" }
	else
		DataEditor.load()
		baseline = sharedSnapshotBundle()
		return { ok = true, mode = "loaded_shared" }
	end
end

function DataEditor.computeDiffVsShared()
	local draft = draftOverlayModule()
	if not draft then
		return { ok = false, error = "DraftOverlay unavailable" }
	end
	ensureLoaded()
	local current = currentBundleForDraft()
	local shared = sharedSnapshotBundle()
	if not shared then
		return { ok = false, error = "could not snapshot shared" }
	end
	return { ok = true, diffs = draft.diffBundles(current, shared, baseline) }
end

function DataEditor.discardDraft()
	if activeUser == nil then
		return { ok = false, error = "no active user" }
	end
	local draft = draftOverlayModule()
	if not draft then
		return { ok = false, error = "DraftOverlay unavailable" }
	end
	local result = draft.discardDraft(activeUser)
	if result.ok then
		DataEditor.load()
		baseline = sharedSnapshotBundle()
		userStates[activeUser] = DataEditor.captureFullState()
	end
	return result
end

function DataEditor.pullFromShared()
	DataEditor.load()
	baseline = sharedSnapshotBundle()
	if activeUser ~= nil then
		userStates[activeUser] = DataEditor.captureFullState()
	end
	return { ok = true }
end

function DataEditor.promote(fieldSelections)
	if activeUser == nil then
		return { ok = false, error = "no active user" }
	end
	local overlay = overlayModule()
	if not overlay then
		return { ok = false, error = "DataOverlay unavailable" }
	end
	local draft = draftOverlayModule()
	if not draft then
		return { ok = false, error = "DraftOverlay unavailable" }
	end
	ensureLoaded()
	-- Promote painted tiles to real seeds first so the diff carries province + eu4map adds
	-- (which register) instead of raw owner-only tile overrides (which never register).
	promotePaintedTiles()
	local current = currentBundleForDraft()
	local shared = sharedSnapshotBundle()
	if not shared then
		return { ok = false, error = "could not snapshot shared" }
	end
	local allDiffs = draft.diffBundles(current, shared, baseline)
	local selectionSet = {}
	if type(fieldSelections) == "table" then
		for _, sel in ipairs(fieldSelections) do
			selectionSet[(sel.kind or "") .. ":" .. tostring(sel.key)] = true
		end
	else
		for _, d in ipairs(allDiffs) do
			selectionSet[d.kind .. ":" .. tostring(d.key)] = true
		end
	end
	local applied = {}
	local edits = {
		countries = {},
		provinces = {},
		eu4map = {},
		tiles = {},
		cultures = {},
		religions = {},
		ideologies = {},
		governmentTypes = {},
	}
	local TOMB = overlay.TOMBSTONE or false
	local editBucket = {
		country = edits.countries,
		province = edits.provinces,
		eu4map = edits.eu4map,
		tile = edits.tiles,
		culture = edits.cultures,
		religion = edits.religions,
		ideology = edits.ideologies,
		government_type = edits.governmentTypes,
	}
	for _, d in ipairs(allDiffs) do
		if selectionSet[d.kind .. ":" .. tostring(d.key)] then
			local kind, key = d.kind, d.key
			if d.action == "delete" then
				if kind == "country" then
					overlay.deleteCountry(key)
				elseif kind == "province" then
					overlay.deleteProvince(tonumber(key) or key)
				elseif kind == "eu4map" then
					overlay.deleteEU4Map(tonumber(key) or key)
				elseif kind == "tile" then
					overlay.deleteTile(key)
				elseif kind == "culture" then
					overlay.deleteCulture(key)
				elseif kind == "religion" then
					overlay.deleteReligion(key)
				elseif kind == "ideology" and overlay.deleteIdeology then
					overlay.deleteIdeology(key)
				elseif kind == "government_type" and overlay.deleteGovernmentType then
					overlay.deleteGovernmentType(key)
				end
				if editBucket[kind] then
					editBucket[kind][tostring(key)] = TOMB
				end
			else
				if kind == "country" then
					overlay.setCountry(key, d.draftValue)
				elseif kind == "province" then
					overlay.setProvince(tonumber(key) or key, d.draftValue)
				elseif kind == "eu4map" then
					overlay.setEU4Map(tonumber(key) or key, d.draftValue)
				elseif kind == "tile" then
					overlay.setTile(key, d.draftValue)
				elseif kind == "culture" then
					overlay.setCulture(key, d.draftValue)
				elseif kind == "religion" then
					overlay.setReligion(key, d.draftValue)
				elseif kind == "ideology" and overlay.setIdeology then
					overlay.setIdeology(key, d.draftValue)
				elseif kind == "government_type" and overlay.setGovernmentType then
					overlay.setGovernmentType(key, d.draftValue)
				end
				if editBucket[kind] then
					editBucket[kind][tostring(key)] = d.draftValue
				end
			end
			table.insert(applied, { kind = kind, key = key, action = d.action })
		end
	end
	local flush = overlay.flush and overlay.flush() or {}
	baseline = sharedSnapshotBundle()
	if activeUser ~= nil then
		userStates[activeUser] = DataEditor.captureFullState()
	end
	return { ok = (flush.failures == 0 or flush.failures == nil), promoted = applied, flush = flush }
end

-- Phase C orchestrator — build and write the part-id-keyed @v3 aggregates from the current
-- (v2, serial-keyed) merged state. ADDITIVE: the serial-keyed v2 keys are never touched, so
-- rollback is a single flag flip. Validates the bijection first and ABORTS if it is not clean.
-- Does NOT flip the schema flag (boot stays on v2) unless opts.commit == true — run a dry pass,
-- verify, then re-run with { commit = true }.
function DataEditor.collapseToPartIds(opts)
	opts = opts or {}
	ensureLoaded()
	local overlay = overlayModule()
	if not overlay or not overlay.writeCollapsedV3 then
		return { ok = false, error = "DataOverlay.writeCollapsedV3 unavailable (update DataOverlay first)" }
	end

	local audit = DataEditor.auditMapping()
	if not audit.collapseReady then
		return {
			ok = false,
			error = string.format(
				"mapping is not a clean bijection (%d duplicate target(s), %d unmapped province(s)) — resolve before collapsing",
				audit.counts.duplicateTargets,
				audit.counts.provincesWithoutMapping
			),
			audit = audit,
		}
	end

	local startedAt = os.time()
	-- Re-key provinces serial -> part. record.id must equal its new key (validateIndividual asserts).
	local provincesV3, provmapV3, sourceCount = {}, {}, 0
	for serialId, record in pairs(provinces) do
		local partId = eu4Map[serialId]
		if partId == nil then
			return {
				ok = false,
				error = string.format("province %s has no eu4Map entry", tostring(serialId)),
				audit = audit,
			}
		end
		if provincesV3[partId] ~= nil then
			return { ok = false, error = string.format("two provinces map to part %s", tostring(partId)), audit = audit }
		end
		local clone = deepClone(record)
		clone.id = partId
		provincesV3[partId] = clone
		provmapV3[partId] = serialId
		sourceCount += 1
	end

	-- Re-map capitalProvinceId serial -> part on every country (the only province-valued field).
	local countriesV3 = {}
	for tag, record in pairs(countries) do
		local clone = deepClone(record)
		local capSerial = clone.capitalProvinceId
		if capSerial ~= nil and eu4Map[capSerial] ~= nil then
			clone.capitalProvinceId = eu4Map[capSerial]
		end
		-- If a capital has no mapping it is left as-is; DataLoader validates + self-heals capitals.
		countriesV3[tag] = clone
	end

	local writeReport = overlay.writeCollapsedV3(provincesV3, countriesV3, provmapV3, {
		startedAt = startedAt,
		sourceCount = sourceCount,
	})
	local verify = overlay.verifyCollapsedV3 and overlay.verifyCollapsedV3(provincesV3, countriesV3) or nil

	local committed = false
	if opts.commit == true then
		if not (writeReport.ok and verify and verify.ok) then
			return {
				ok = false,
				error = "refusing to commit — @v3 write/verify did not pass",
				write = writeReport,
				verify = verify,
				audit = audit,
			}
		end
		local cOk, cErr = overlay.commitCollapse()
		if not cOk then
			return {
				ok = false,
				error = "commit (schema flip) failed: " .. tostring(cErr),
				write = writeReport,
				verify = verify,
			}
		end
		committed = true
	end

	return {
		ok = writeReport.ok and (verify == nil or verify.ok),
		committed = committed,
		write = writeReport,
		verify = verify,
		audit = audit,
		message = committed
				and string.format(
					"Collapsed to part-id schema (v3): %d provinces, %d countries. Schema flag flipped. Now regenerate ProvinceAdjacency/SeaZones in play mode, then verify per the runbook.",
					sourceCount,
					writeReport.countries.count
				)
			or string.format(
				"Wrote @v3 aggregates (additive, v2 intact): %d provinces, %d countries. NOT committed — verify, then re-run with { commit = true }.",
				sourceCount,
				writeReport.countries.count
			),
	}
end

-- Roll the schema flag back to v2 (the serial-keyed data, untouched, becomes authoritative again).
-- Re-publish the pre-collapse code commit afterward.
function DataEditor.rollbackCollapse()
	local overlay = overlayModule()
	if not overlay or not overlay.rollbackCollapse then
		return { ok = false, error = "DataOverlay.rollbackCollapse unavailable" }
	end
	local ok, err = overlay.rollbackCollapse()
	return {
		ok = ok,
		error = (not ok) and tostring(err) or nil,
		message = ok
				and "Schema flag flipped back to v2. The serial-keyed data is authoritative again — re-publish the pre-collapse code."
			or nil,
	}
end

-- ─────────────────────────── Phase 1B: v3 -> v4 store migration + seed import ───────────────────────────
-- Thin wrappers over the DataOverlay v4 machinery. ALL-OR-NOTHING + VERIFIED before the schema flag
-- flips: migrateV3toV4 writes @v4 (additive, @v3 untouched), verifies, and only commits on pass.

function DataEditor.migrateV3toV4(opts)
	opts = opts or {}
	local overlay = overlayModule()
	if not overlay or not overlay.migrateV3toV4 then
		return { ok = false, error = "DataOverlay.migrateV3toV4 unavailable (update DataOverlay first)" }
	end

	local write = overlay.migrateV3toV4()
	if not write.ok then
		return { ok = false, error = "@v4 write failed", write = write }
	end

	local verify = overlay.verifyMigrationSafe and overlay.verifyMigrationSafe() or nil
	if not (verify and verify.ok) then
		return {
			ok = false,
			error = "verify failed — partial @v4 keys were removed; @v3 is untouched",
			write = write,
			verify = verify,
		}
	end

	local committed = false
	if opts.commit == true then
		local cOk, cErr = overlay.commitV4()
		if not cOk then
			return {
				ok = false,
				error = "commit (schema flip to v4) failed: " .. tostring(cErr),
				write = write,
				verify = verify,
			}
		end
		committed = true
		DataEditor.load() -- rebuild the editor model from the freshly-committed @v4 cache
	end

	return {
		ok = true,
		committed = committed,
		write = write,
		verify = verify,
		message = committed
				and string.format(
					"Migrated to v4: %d provinces, %d countries. Schema flag flipped to v4 (acceptedCultures dropped; cores/defaultCores/claims defaulted).",
					write.provinces.written,
					write.countries.written
				)
			or string.format(
				"Wrote + verified @v4 (additive, @v3 intact): %d provinces, %d countries. NOT committed — re-run with { commit = true } to flip the schema flag.",
				write.provinces.written,
				write.countries.written
			),
	}
end

function DataEditor.rollbackV4()
	local overlay = overlayModule()
	if not overlay or not overlay.rollbackV4 then
		return { ok = false, error = "DataOverlay.rollbackV4 unavailable" }
	end
	local ok, err = overlay.rollbackV4()
	if ok then
		DataEditor.load() -- rebuild from the (frozen, untouched) @v3 cache
	end
	return {
		ok = ok,
		error = (not ok) and tostring(err) or nil,
		message = ok
				and "Schema flag flipped back to v3. The frozen @v3 data is authoritative again — the world reverts."
			or nil,
	}
end

-- First-boot seed: import the source Data/Countries + Data/Provinces modules into the @v4 keys.
function DataEditor.importSeed(opts)
	opts = opts or {}
	local overlay = overlayModule()
	if not overlay or not overlay.importSeed then
		return { ok = false, error = "DataOverlay.importSeed unavailable (update DataOverlay first)" }
	end
	local data = dataFolder()
	local sourceCountries = deepClone(loadClone(data:WaitForChild("Countries")))
	local sourceProvinces = deepClone(loadClone(data:WaitForChild("Provinces")))
	local result = overlay.importSeed(sourceCountries, sourceProvinces, { force = opts.force == true })
	if result.ok then
		result.message = string.format(
			"Seeded @v4 from source: %d provinces, %d countries. NOT committed — run migrateV3toV4({ commit = true }) or commit the v4 schema to activate.",
			result.provinces and result.provinces.written or 0,
			result.countries and result.countries.written or 0
		)
	end
	return result
end

function DataEditor.help()
	print([[
DataEditor API:
  Editor.load()                                - reload from source modules + overlay snapshot
  Editor.save()                                - flush all edits to overlay + verify
  Editor.exportToLua()                         - write source ModuleScripts (edit mode only)

  Editor.listCountries()                       - print country list
  Editor.listProvinces()                       - print province list

  Editor.addCountry(tag, opts)                 - add a new country
  Editor.updateCountry(tag, opts)              - patch a country
  Editor.removeCountry(tag)                    - remove a country

  Editor.addProvince(id, opts)                 - add a new province
  Editor.updateProvince(id, opts)              - patch a province
  Editor.removeProvince(id)                    - remove a province
  Editor.assignProvince(id, ownerTag)          - change province owner
  Editor.promoteTile(opts)                     - promote a painted tile into a real seed

  Editor.mapProvinceToPart(seedId, btPartId)   - map seed id to BT part id

  Editor.setTileOwner(partName, ownerTag)      - assign a raw map tile to a country
  Editor.getTileOwners()                       - read current tile ownership overlay
  Editor.tileOwnerOf(partName)                 - read owner tag for a single tile

  Editor.addCulture(id, opts)                  - add a culture (opts: displayName, groupId)
  Editor.updateCulture(id, opts)               - patch a culture
  Editor.removeCulture(id)                     - remove a culture

  Editor.addReligion(id, opts)                 - add a religion (opts: displayName, group)
  Editor.updateReligion(id, opts)              - patch a religion
  Editor.removeReligion(id)                    - remove a religion

  Editor.undo() / Editor.redo()                - traverse history (max 8 entries)
  Editor.canUndo() / Editor.canRedo()          - boolean checks
  Editor.diffAgainstBaseline()                 - return per-kind add/modify/remove counts
  Editor.dumpDataStore(forceRefresh)           - inspect current overlay snapshot
  Editor.migrateLegacy()                       - merge legacy per-key entries into aggregates
]])
end

return DataEditor
