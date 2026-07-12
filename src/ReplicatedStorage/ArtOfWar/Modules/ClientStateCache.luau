local ClientStateCache = {}

local WorldConstants = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("WorldConstants"))

-- Province ids are canonically NUMERIC everywhere (store / delta / snapshot). Normalise on the way IN so a
-- stray string key from any channel can never create a SECOND, permanently-stale cache entry for the same
-- province (the "annexed tile still shows the old owner" class). Only provinces need this -- country tags
-- are strings.
local function provKey(collection, key)
	if collection == "provinces" then
		return tonumber(key) or key
	end
	return key
end

local cache = {
	revision = 0,
	provinces = {},
	countries = {},
	markets = {},
	tradeRoutes = {},
	armies = {},
	battles = {},
	fleets = {},
	wars = {},
	peaceProposals = {},
	tradeOrders = {},
	pacts = {},
	armyGroups = {},
}

local subscribers = {}
local prefixSubscribers = {}
local initialized = false

-- P0-e notify indexing. prefixSubscribers stays keyed by prefix (registration/unsub); prefixByFirstSeg
-- indexes those by the path's FIRST segment so firePrefix scans only the handful of prefixes that could
-- match a given path instead of ALL of them (each entry caches prefix.."." + #prefix to skip re-concat).
-- fieldSubscriberCount counts EXACT subscribers whose path has >=2 dots ("collection.id.field"); when it is
-- 0 (the normal case -- nothing subscribes to a single field today) mergeEntry skips the per-field loop
-- entirely instead of building a path string for every field of every changed record.
local prefixByFirstSeg = {}
local fieldSubscriberCount = 0

local function firstSegment(path)
	local dot = path:find(".", 1, true)
	return dot and path:sub(1, dot - 1) or path
end

local function isFieldPath(path)
	local first = path:find(".", 1, true)
	return first ~= nil and path:find(".", first + 1, true) ~= nil
end

local function fireExact(path, value)
	local list = subscribers[path]
	if not list then
		return
	end
	for _, cb in list do
		local ok, err = pcall(cb, value, path)
		if not ok then
			warn(string.format("[ClientStateCache] subscriber for '%s' errored: %s", path, tostring(err)))
		end
	end
end

local function firePrefix(path, value)
	local bucket = prefixByFirstSeg[firstSegment(path)]
	if not bucket then
		return
	end
	for prefix, meta in bucket do
		if path == prefix or path:sub(1, meta.plen + 1) == meta.dot then
			local list = prefixSubscribers[prefix]
			if list then
				for _, cb in list do
					local ok, err = pcall(cb, value, path)
					if not ok then
						warn(
							string.format(
								"[ClientStateCache] prefix subscriber for '%s' errored: %s",
								prefix,
								tostring(err)
							)
						)
					end
				end
			end
		end
	end
end

local function notify(path, value)
	fireExact(path, value)
	firePrefix(path, value)
end

local function mergeEntry(collection, key, record, basePath)
	key = provKey(collection, key)
	cache[collection][key] = record
	if WorldConstants.OwnershipReplicationDebug and collection == "provinces" then
		print(
			"[CSC merge] prov",
			key,
			typeof(key),
			"owner=",
			record and record.ownerTag,
			"ctrl=",
			record and record.controllerTag
		)
	end
	local recPath = basePath .. "." .. tostring(key)
	-- Record-level notify: exact-path AND prefix subscribers (e.g. onChangePrefix("countries"))
	-- fire exactly once for the changed record. The whole record is replaced on every delta,
	-- so prefix subscribers that inspect the path still extract the id from this record path.
	notify(recPath, record)
	-- C4: previously this fired notify() -- including an O(#prefixSubscribers) scan with string
	-- matching -- for EVERY field of every changed record (tens of thousands of ops per packet).
	-- Now fields only notify the cheap EXACT-path subscribers that are actually registered.
	if fieldSubscriberCount > 0 and type(record) == "table" then
		for field, fieldValue in record do
			local fp = recPath .. "." .. tostring(field)
			if subscribers[fp] then
				fireExact(fp, fieldValue)
			end
		end
	end
end

local function applyCollection(name, bucket)
	if not bucket then
		return
	end
	for key, record in bucket do
		mergeEntry(name, key, record, name)
	end
end

local REPLICATED_COLLECTIONS = {
	"provinces",
	"countries",
	"markets",
	"tradeRoutes",
	"armies",
	"battles",
	"fleets",
	"wars",
	"peaceProposals",
	"tradeOrders",
	"pacts",
	"armyGroups",
}

-- Collections streamed in chunks (omitted from the fullSnapshot, delivered via per-join chunk streams): the
-- snapshot flag that marks each so applyFullSnapshot skips pruning them (an omitted collection would else prune to
-- empty and wipe the streamed records).
local CHUNKED_COLLECTIONS = {
	provinces = "provincesChunked",
	armies = "armiesChunked",
	fleets = "fleetsChunked",
	armyGroups = "armyGroupsChunked",
}

-- Prune a chunk-streamed collection to the authoritative id set carried by its completion marker, so a record whose
-- removal delta we missed can't persist forever (the snapshot no longer prunes these). provKey normalises province
-- ids (numeric); other collections pass through as string keys.
local function pruneToIdSet(collection, ids)
	if type(ids) ~= "table" then
		return
	end
	local present = {}
	for _, id in ipairs(ids) do
		present[provKey(collection, id)] = true
	end
	local bucket = cache[collection]
	if not bucket then
		return
	end
	local stale = {}
	for k in bucket do
		if not present[k] then
			stale[#stale + 1] = k
		end
	end
	for _, k in ipairs(stale) do
		bucket[k] = nil
		notify(collection .. "." .. tostring(k), nil)
	end
end

local function applyRemovals(removed)
	if type(removed) ~= "table" then
		return
	end
	for _, name in ipairs(REPLICATED_COLLECTIONS) do
		local list = removed[name]
		if type(list) == "table" then
			local bucket = cache[name]
			if bucket then
				for _, key in ipairs(list) do
					local k = provKey(name, key)
					bucket[k] = nil
					notify(name .. "." .. tostring(k), nil)
				end
			end
		end
	end
end

-- Apply a fullSnapshot as "a delta over every record": MERGE each collection through applyCollection (so
-- keys are numeric-normalised and per-record subscribers -- map recolor, panel/tooltip refresh -- actually
-- fire), then PRUNE any cache key the snapshot no longer contains (the snapshot is authoritative on
-- membership). The old blanket `cache.provinces = packet.provinces` swapped the table WITHOUT firing
-- per-record notifications and could re-introduce a wrong-typed key -- so the reconcile heal below could
-- not repaint. The coarse revision guard (caller) still drops a wholly-stale snapshot.
local function applyFullSnapshot(packet)
	for _, name in ipairs(REPLICATED_COLLECTIONS) do
		-- Chunk-streamed collections (provinces/armies/fleets/armyGroups) are NOT in this snapshot; skip pruning
		-- them so the prune can't wipe chunk-delivered records (present would be empty -> it would delete every one).
		local chunkedFlag = CHUNKED_COLLECTIONS[name]
		if not (chunkedFlag and packet[chunkedFlag]) then
			local incoming = packet[name] or {}
			applyCollection(name, incoming)
			local present = {}
			for k in incoming do
				present[provKey(name, k)] = true
			end
			local bucket = cache[name]
			local stale = {}
			for k in bucket do
				if not present[k] then
					stale[#stale + 1] = k
				end
			end
			for _, k in ipairs(stale) do
				bucket[k] = nil
				notify(name .. "." .. tostring(k), nil)
			end
		end
	end
	cache.revision = math.max(cache.revision or 0, packet.revision or 0)
	initialized = true
	notify("snapshot", cache)
end

function ClientStateCache.applyDelta(packet)
	if type(packet) ~= "table" then
		return
	end
	if packet.fullSnapshot then
		if packet.revision and cache.revision and packet.revision < cache.revision then
			initialized = true
			notify("snapshot", cache)
			return
		end
		applyFullSnapshot(packet)
		return
	end
	applyCollection("provinces", packet.provinces)
	applyCollection("countries", packet.countries)
	applyCollection("markets", packet.markets)
	applyCollection("tradeRoutes", packet.tradeRoutes)
	applyCollection("armies", packet.armies)
	applyCollection("battles", packet.battles)
	applyCollection("fleets", packet.fleets)
	applyCollection("wars", packet.wars)
	applyCollection("peaceProposals", packet.peaceProposals)
	applyCollection("tradeOrders", packet.tradeOrders)
	applyCollection("pacts", packet.pacts)
	applyCollection("armyGroups", packet.armyGroups)
	applyRemovals(packet.removed)
	-- Completion markers for the chunk-streamed collections: prune each to its authoritative id set (self-heal for a
	-- removal delta we may have missed, since the snapshot no longer prunes these). Provinces additionally fire
	-- "provincesReady" so their one-shot consumers (political map re-sweep, nation-select) re-index; armies/fleets/
	-- armyGroups consumers are event-driven and reconcile per streamed record, so they need no signal.
	if packet.provincesComplete then
		pruneToIdSet("provinces", packet.provinceIds)
		notify("provincesReady", cache)
	end
	if packet.armiesComplete then
		pruneToIdSet("armies", packet.armyIds)
	end
	if packet.fleetsComplete then
		pruneToIdSet("fleets", packet.fleetIds)
	end
	if packet.armyGroupsComplete then
		pruneToIdSet("armyGroups", packet.armyGroupIds)
	end
	if packet.revision then
		cache.revision = packet.revision
	end
end

function ClientStateCache.onChange(path, callback)
	if type(path) ~= "string" or type(callback) ~= "function" then
		return function() end
	end
	local list = subscribers[path]
	if not list then
		list = {}
		subscribers[path] = list
	end
	table.insert(list, callback)
	local isField = isFieldPath(path)
	if isField then
		fieldSubscriberCount += 1
	end
	return function()
		local current = subscribers[path]
		if not current then
			return
		end
		for i, cb in current do
			if cb == callback then
				table.remove(current, i)
				if isField then
					fieldSubscriberCount -= 1
				end
				if #current == 0 then
					subscribers[path] = nil
				end
				return
			end
		end
	end
end

function ClientStateCache.onChangePrefix(prefix, callback)
	if type(prefix) ~= "string" or type(callback) ~= "function" then
		return function() end
	end
	local list = prefixSubscribers[prefix]
	if not list then
		list = {}
		prefixSubscribers[prefix] = list
		local seg = firstSegment(prefix)
		local bucket = prefixByFirstSeg[seg]
		if not bucket then
			bucket = {}
			prefixByFirstSeg[seg] = bucket
		end
		bucket[prefix] = { dot = prefix .. ".", plen = #prefix }
	end
	table.insert(list, callback)
	return function()
		local current = prefixSubscribers[prefix]
		if not current then
			return
		end
		for i, cb in current do
			if cb == callback then
				table.remove(current, i)
				if #current == 0 then
					prefixSubscribers[prefix] = nil
					local seg = firstSegment(prefix)
					local bucket = prefixByFirstSeg[seg]
					if bucket then
						bucket[prefix] = nil
						if next(bucket) == nil then
							prefixByFirstSeg[seg] = nil
						end
					end
				end
				return
			end
		end
	end
end

-- Coerce so a numeric-vs-string caller (part `province_id` attr is numeric; some callers pass strings)
-- always resolves the same canonical (numeric) cache entry -- the map and the panel can never read
-- different records for the same province.
function ClientStateCache.getProvince(id)
	return cache.provinces[id] or cache.provinces[tonumber(id)]
end

-- Self-heal backstop (OwnershipReconcile): given a compact server ownership digest `{ [id] = {o=,c=} }`,
-- patch ONLY provinces whose cached owner/controller drifted, in place, and fire the record notify so the
-- map recolor + panel/tooltip refresh. Unchanged provinces cost one compare and no notify. Guarantees a
-- single dropped delta can never leave a province permanently stale, whatever caused the drop. Returns the
-- number healed.
function ClientStateCache.reconcileProvinces(digest)
	if type(digest) ~= "table" then
		return 0
	end
	local healed = 0
	for key, oc in digest do
		local k = provKey("provinces", key)
		local cur = cache.provinces[k]
		if cur and (cur.ownerTag ~= oc.o or cur.controllerTag ~= oc.c) then
			cur.ownerTag = oc.o
			cur.controllerTag = oc.c
			notify("provinces." .. tostring(k), cur)
			healed += 1
			if WorldConstants.OwnershipReplicationDebug then
				print("[CSC reconcile] healed prov", k, "-> owner=", oc.o, "ctrl=", oc.c)
			end
		end
	end
	return healed
end
function ClientStateCache.getCountry(tag)
	return cache.countries[tag]
end
-- Tier 3: the player's OWN country's politics (leaders/factions) arrive on a separate per-player channel and are
-- stored HERE, NOT merged into cache.countries[tag] -- a later shared country delta replaces that whole record and
-- would wipe merged-in politics. PoliticsScreen overlays getOwnPolitics() onto its own country record.
function ClientStateCache.setOwnPolitics(packet)
	cache.ownPolitics = packet
	notify("ownPolitics", packet)
end
function ClientStateCache.getOwnPolitics()
	return cache.ownPolitics
end
function ClientStateCache.getMarket(id)
	return cache.markets[id]
end
function ClientStateCache.getTrade(id)
	return cache.tradeRoutes[id]
end
function ClientStateCache.getArmy(id)
	return cache.armies[id]
end
function ClientStateCache.getBattle(id)
	return cache.battles[id]
end
function ClientStateCache.getFleet(id)
	return cache.fleets[id]
end
function ClientStateCache.getWar(id)
	return cache.wars[id]
end
function ClientStateCache.getPeaceProposal(id)
	return cache.peaceProposals[id]
end
function ClientStateCache.getTradeOrder(id)
	return cache.tradeOrders[id]
end
function ClientStateCache.getPact(id)
	return cache.pacts[id]
end
function ClientStateCache.getArmyGroup(id)
	return cache.armyGroups[id]
end
function ClientStateCache.allProvinces()
	return cache.provinces
end
function ClientStateCache.allCountries()
	return cache.countries
end
function ClientStateCache.allMarkets()
	return cache.markets
end
function ClientStateCache.allTrades()
	return cache.tradeRoutes
end
function ClientStateCache.allArmies()
	return cache.armies
end
function ClientStateCache.allBattles()
	return cache.battles
end
function ClientStateCache.allFleets()
	return cache.fleets
end
function ClientStateCache.allWars()
	return cache.wars
end
function ClientStateCache.allPeaceProposals()
	return cache.peaceProposals
end
function ClientStateCache.allTradeOrders()
	return cache.tradeOrders
end
function ClientStateCache.allPacts()
	return cache.pacts
end
function ClientStateCache.allArmyGroups()
	return cache.armyGroups
end
function ClientStateCache.revision()
	return cache.revision
end
function ClientStateCache.isReady()
	return initialized
end

function ClientStateCache.proxy(basePath)
	local segments = {}
	for part in basePath:gmatch("[^.]+") do
		table.insert(segments, part)
	end
	return setmetatable({}, {
		__index = function(_, key)
			local node = cache
			for _, segment in segments do
				if type(node) ~= "table" then
					return nil
				end
				node = node[segment]
			end
			if type(node) ~= "table" then
				return nil
			end
			return node[key]
		end,
		__newindex = function() end,
	})
end

function ClientStateCache.clear()
	cache.revision = 0
	cache.provinces = {}
	cache.countries = {}
	cache.markets = {}
	cache.tradeRoutes = {}
	cache.armies = {}
	cache.battles = {}
	cache.fleets = {}
	cache.wars = {}
	cache.peaceProposals = {}
	cache.tradeOrders = {}
	cache.pacts = {}
	cache.armyGroups = {}
	cache.ownPolitics = nil
	initialized = false
end

return ClientStateCache
