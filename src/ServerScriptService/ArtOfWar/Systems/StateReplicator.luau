local StateReplicator = {}

local BROADCAST_INTERVAL = 1.5
-- perf: cache the full-state snapshot so concurrent joiners (RequestFullState)
-- reuse one re-serialized world instead of each rebuilding it. Invalidated on
-- every broadcast tick + bounded by a short TTL; a joiner may see state up to
-- ~SNAPSHOT_TTL old, which the next delta corrects. Delta path is untouched.
local SNAPSHOT_TTL = 2
local COLLECTIONS = {
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
local GETTERS = {
	provinces = "getProvince",
	countries = "getCountry",
	markets = "getMarket",
	tradeRoutes = "getTradeRoute",
	armies = "getArmy",
	battles = "getBattle",
	fleets = "getFleet",
	wars = "getWar",
	peaceProposals = "getPeaceProposal",
	tradeOrders = "getTradeOrder",
	pacts = "getPact",
	armyGroups = "getArmyGroup",
}

local ctx
local stateSync

-- perf: cached snapshot + the os.clock() time it was built (nil = stale)
local cachedSnapshot = nil
local cachedSnapshotAt = nil

local function buildDeltaFrom(drained)
	if not drained then
		return nil
	end
	local packet = { revision = drained.revision }
	local anyField = false
	local replDebug = ctx.WorldConstants and ctx.WorldConstants.OwnershipReplicationDebug
	for _, name in COLLECTIONS do
		local keys = drained[name]
		if keys and #keys > 0 then
			local bucket = {}
			local getter = GETTERS[name]
			local isProv = name == "provinces"
			for _, key in keys do
				-- Canonical numeric province keys so the client never double-keys the same province.
				local k = isProv and (tonumber(key) or key) or key
				local rec = ctx.WorldState[getter](k)
				bucket[k] = rec
				if replDebug and isProv then
					print(
						"[Repl delta] prov",
						k,
						typeof(k),
						"owner=",
						rec and rec.ownerTag,
						"ctrl=",
						rec and rec.controllerTag
					)
				end
			end
			packet[name] = bucket
			anyField = true
		end
	end
	local removed = drained.removed
	if removed then
		local removedPacket = {}
		local hasRemoved = false
		for _, name in COLLECTIONS do
			local list = removed[name]
			if list and #list > 0 then
				removedPacket[name] = list
				hasRemoved = true
			end
		end
		if hasRemoved then
			packet.removed = removedPacket
			anyField = true
		end
	end
	if not anyField then
		return nil
	end
	return packet
end

local function buildSnapshotUncached()
	local snapshot = { revision = ctx.WorldState.getRevision(), fullSnapshot = true }
	snapshot.provinces = ctx.WorldState.allProvinces()
	snapshot.countries = ctx.WorldState.allCountries()
	snapshot.markets = ctx.WorldState.allMarkets()
	snapshot.tradeRoutes = ctx.WorldState.allTradeRoutes()
	snapshot.armies = ctx.WorldState.allArmies()
	snapshot.battles = ctx.WorldState.allBattles()
	snapshot.fleets = ctx.WorldState.allFleets()
	snapshot.wars = ctx.WorldState.allWars()
	snapshot.peaceProposals = ctx.WorldState.allPeaceProposals()
	snapshot.tradeOrders = ctx.WorldState.allTradeOrders()
	snapshot.pacts = ctx.WorldState.allPacts()
	snapshot.armyGroups = ctx.WorldState.allArmyGroups()
	return snapshot
end

-- perf: serve joiners a recently-built snapshot when one is fresh enough.
-- The collection fields are live references to WorldState's store tables and the
-- snapshot is read-only on the client, so sharing one object across concurrent
-- joins is safe; only the captured `revision` may lag (<= SNAPSHOT_TTL).
local function buildSnapshot()
	local now = os.clock()
	if cachedSnapshot and cachedSnapshotAt and (now - cachedSnapshotAt) < SNAPSHOT_TTL then
		return cachedSnapshot
	end
	cachedSnapshot = buildSnapshotUncached()
	cachedSnapshotAt = now
	return cachedSnapshot
end

local function broadcast()
	if not stateSync then
		return
	end
	local drained = ctx.WorldState.drainDirty()
	if not drained then
		return
	end
	local packet = buildDeltaFrom(drained)
	if not packet then
		return
	end
	stateSync:FireAllClients(packet)
	-- perf: world advanced this tick -> drop the cached snapshot so the next
	-- joiner rebuilds against the just-broadcast revision (lazy rebuild).
	cachedSnapshot = nil
	cachedSnapshotAt = nil
	ctx.EventBus.publish(ctx.Channels.StateReplicated, {
		revision = packet.revision,
	})
end

local function tickReplicator()
	broadcast()
end

function StateReplicator.register(context)
	ctx = context
	ctx.StateReplicator = {
		broadcast = broadcast,
		buildSnapshot = buildSnapshot,
		setStateSync = function(remote)
			stateSync = remote
		end,
	}
	ctx.TickScheduler.register({
		id = "StateReplicator",
		priority = 50,
		updateIntervalSeconds = BROADCAST_INTERVAL,
		update = tickReplicator,
	})
end

return StateReplicator
