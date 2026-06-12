local ClientStateCache = {}

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
}

local subscribers = {}
local prefixSubscribers = {}
local initialized = false

local function fireExact(path, value)
	local list = subscribers[path]
	if not list then return end
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
					warn(string.format("[ClientStateCache] prefix subscriber for '%s' errored: %s", prefix, tostring(err)))
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
	cache[collection][key] = record
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
			if subscribers[fp] then fireExact(fp, fieldValue) end
		end
	end
end

local function applyCollection(name, bucket)
	if not bucket then return end
	for key, record in bucket do
		mergeEntry(name, key, record, name)
	end
end

local REPLICATED_COLLECTIONS = { "provinces", "countries", "markets", "tradeRoutes", "armies", "battles", "fleets", "wars", "peaceProposals" }

local function applyRemovals(removed)
	if type(removed) ~= "table" then return end
	for _, name in ipairs(REPLICATED_COLLECTIONS) do
		local list = removed[name]
		if type(list) == "table" then
			local bucket = cache[name]
			if bucket then
				for _, key in ipairs(list) do
					bucket[key] = nil
					notify(name .. "." .. tostring(key), nil)
				end
			end
		end
	end
end

function ClientStateCache.applyDelta(packet)
	if type(packet) ~= "table" then return end
	if packet.fullSnapshot then
		if packet.revision and cache.revision and packet.revision < cache.revision then
			initialized = true
			notify("snapshot", cache)
			return
		end
		cache.provinces = packet.provinces or {}
		cache.countries = packet.countries or {}
		cache.markets = packet.markets or {}
		cache.tradeRoutes = packet.tradeRoutes or {}
		cache.armies = packet.armies or {}
		cache.battles = packet.battles or {}
		cache.fleets = packet.fleets or {}
		cache.wars = packet.wars or {}
		cache.peaceProposals = packet.peaceProposals or {}
		cache.revision = packet.revision or 0
		initialized = true
		notify("snapshot", cache)
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
	applyRemovals(packet.removed)
	if packet.revision then
		cache.revision = packet.revision
	end
end

function ClientStateCache.onChange(path, callback)
	if type(path) ~= "string" or type(callback) ~= "function" then return function() end end
	local list = subscribers[path]
	if not list then list = {} subscribers[path] = list end
	table.insert(list, callback)
	return function()
		local current = subscribers[path]
		if not current then return end
		for i, cb in current do
			if cb == callback then
				table.remove(current, i)
				if #current == 0 then subscribers[path] = nil end
				return
			end
		end
	end
end

function ClientStateCache.onChangePrefix(prefix, callback)
	if type(prefix) ~= "string" or type(callback) ~= "function" then return function() end end
	local list = prefixSubscribers[prefix]
	if not list then list = {} prefixSubscribers[prefix] = list end
	table.insert(list, callback)
	return function()
		local current = prefixSubscribers[prefix]
		if not current then return end
		for i, cb in current do
			if cb == callback then
				table.remove(current, i)
				if #current == 0 then prefixSubscribers[prefix] = nil end
				return
			end
		end
	end
end

function ClientStateCache.getProvince(id) return cache.provinces[id] end
function ClientStateCache.getCountry(tag) return cache.countries[tag] end
function ClientStateCache.getMarket(id) return cache.markets[id] end
function ClientStateCache.getTrade(id) return cache.tradeRoutes[id] end
function ClientStateCache.getArmy(id) return cache.armies[id] end
function ClientStateCache.getBattle(id) return cache.battles[id] end
function ClientStateCache.getFleet(id) return cache.fleets[id] end
function ClientStateCache.getWar(id) return cache.wars[id] end
function ClientStateCache.getPeaceProposal(id) return cache.peaceProposals[id] end
function ClientStateCache.allProvinces() return cache.provinces end
function ClientStateCache.allCountries() return cache.countries end
function ClientStateCache.allMarkets() return cache.markets end
function ClientStateCache.allTrades() return cache.tradeRoutes end
function ClientStateCache.allArmies() return cache.armies end
function ClientStateCache.allBattles() return cache.battles end
function ClientStateCache.allFleets() return cache.fleets end
function ClientStateCache.allWars() return cache.wars end
function ClientStateCache.allPeaceProposals() return cache.peaceProposals end
function ClientStateCache.revision() return cache.revision end
function ClientStateCache.isReady() return initialized end

function ClientStateCache.proxy(basePath)
	local segments = {}
	for part in basePath:gmatch("[^.]+") do
		table.insert(segments, part)
	end
	return setmetatable({}, {
		__index = function(_, key)
			local node = cache
			for _, segment in segments do
				if type(node) ~= "table" then return nil end
				node = node[segment]
			end
			if type(node) ~= "table" then return nil end
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
	initialized = false
end

return ClientStateCache
