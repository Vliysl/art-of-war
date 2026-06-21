local StateReplicator = {}

local BROADCAST_INTERVAL = 1.5
local COLLECTIONS = { "provinces", "countries", "markets", "tradeRoutes", "armies", "battles", "fleets", "wars", "peaceProposals", "tradeOrders", "pacts" }
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
}

local ctx
local stateSync

local function buildDeltaFrom(drained)
	if not drained then return nil end
	local packet = { revision = drained.revision }
	local anyField = false
	for _, name in COLLECTIONS do
		local keys = drained[name]
		if keys and #keys > 0 then
			local bucket = {}
			local getter = GETTERS[name]
			for _, key in keys do
				bucket[key] = ctx.WorldState[getter](key)
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
	if not anyField then return nil end
	return packet
end

local function buildSnapshot()
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
	return snapshot
end

local function broadcast()
	if not stateSync then return end
	local drained = ctx.WorldState.drainDirty()
	if not drained then return end
	local packet = buildDeltaFrom(drained)
	if not packet then return end
	stateSync:FireAllClients(packet)
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
		setStateSync = function(remote) stateSync = remote end,
	}
	ctx.TickScheduler.register({
		id = "StateReplicator",
		priority = 50,
		updateIntervalSeconds = BROADCAST_INTERVAL,
		update = tickReplicator,
	})
end

return StateReplicator
