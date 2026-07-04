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
	for prefix, list in prefixSubscribers do
		if path == prefix or path:sub(1, #prefix + 1) == prefix .. "." then
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
	if type(record) == "table" then
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
		-- Provinces and armies stream in chunks (provincesChunked / armiesChunked) and are NOT in this snapshot;
		-- skip pruning them so the prune can't wipe chunk-delivered records (present would be empty -> it would
		-- delete every one).
		if
			not (
				(name == "provinces" and packet.provincesChunked)
				or (name == "armies" and packet.armiesChunked)
			)
		then
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
	-- Server finished streaming the chunked province set -> tell consumers (political map re-sweep,
	-- nation-select re-index) that the province cache is now complete.
	if packet.provincesComplete then
		-- The chunk stream is authoritative on province MEMBERSHIP. Since an omitted-provinces fullSnapshot no
		-- longer prunes provinces (provincesChunked), a province deleted server-side while we were connected --
		-- whose delete-delta we might have missed -- would otherwise persist forever. Prune any cached province
		-- absent from the completion id-set to restore that self-heal.
		local ids = packet.provinceIds
		if type(ids) == "table" then
			local present = {}
			for _, id in ipairs(ids) do
				present[provKey("provinces", id)] = true
			end
			local stale = {}
			for k in cache.provinces do
				if not present[k] then
					stale[#stale + 1] = k
				end
			end
			for _, k in ipairs(stale) do
				cache.provinces[k] = nil
				notify("provinces." .. tostring(k), nil)
			end
		end
		notify("provincesReady", cache)
	end
	-- Armies stream in chunks too (armiesChunked); mirror the province membership prune so a stale army whose
	-- removal delta we missed can't persist. String-keyed -> no provKey. No "ready" signal is needed: army
	-- consumers are event-driven and already reconcile per streamed record as chunks arrive.
	if packet.armiesComplete then
		local aids = packet.armyIds
		if type(aids) == "table" then
			local present = {}
			for _, id in ipairs(aids) do
				present[id] = true
			end
			local stale = {}
			for k in cache.armies do
				if not present[k] then
					stale[#stale + 1] = k
				end
			end
			for _, k in ipairs(stale) do
				cache.armies[k] = nil
				notify("armies." .. tostring(k), nil)
			end
		end
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
	return function()
		local current = subscribers[path]
		if not current then
			return
		end
		for i, cb in current do
			if cb == callback then
				table.remove(current, i)
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
