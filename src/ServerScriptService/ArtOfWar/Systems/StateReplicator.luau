local StateReplicator = {}

local BROADCAST_INTERVAL = 1.5
-- perf: cache the full-state snapshot so concurrent joiners (RequestFullState)
-- reuse one re-serialized world instead of each rebuilding it. Invalidated on
-- every broadcast tick + bounded by a short TTL; a joiner may see state up to
-- ~SNAPSHOT_TTL old, which the next delta corrects. Delta path is untouched.
local SNAPSHOT_TTL = 2
-- Max records per replication packet. The full province set (~5.7k, ~2.6 MB, sparse numeric-keyed)
-- truncates in Roblox remote transit (only ids ~1..1249 survive; countries at ~1 MB survive). So provinces
-- are streamed in id-keyed sub-buckets of this size (~0.37 MB each, well under the limit) instead of whole.
local CHUNK = 800
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
local ownPoliticsSync

-- perf: cached snapshot + the os.clock() time it was built (nil = stale)
local cachedSnapshot = nil
local cachedSnapshotAt = nil

-- Replication projection for country records. The full record is ~2.6 KB; ~75% of that is politics data (leaders,
-- factions) that a verified audit found NO live client consumer reads except PoliticsScreen/MilitaryScreen, and only
-- for the player's OWN country. Here (Tier 1/2) we keep every field on the wire but (1) DROP fields no live client
-- reads at all and (2) SLIM the leaders/factions sub-records (redundant keys, server-only float precision).
-- CRITICAL: the snapshot/delta fields are live references to WorldState's store tables -- we must NEVER mutate a
-- record in place, so projection always shallow-COPIES.
local COUNTRY_DROP = {
	-- static AI-seed data, read nowhere in the live client stack (kept server-side + in the Data source)
	historicalFriends = true,
	historicalRivals = true,
	acceptedCultures = true,
	startingTechs = true,
	technologyGroup = true,
	-- Tier 3: politics data that a verified audit found ONLY PoliticsScreen reads, and only for the player's OWN
	-- country. ~75% of the country payload. Stripped from the shared broadcast and delivered per-player via the
	-- OwnPolitics channel instead (buildOwnPolitics + pushOwnPoliticsTo below).
	leaders = true,
	factions = true,
}

local function slimLeader(l)
	if type(l) ~= "table" then
		return l
	end
	-- keep only what PoliticsScreen renders/hashes; drop `slot` (== map key), `appointedAt`, `portraitId` (unread).
	return {
		id = l.id,
		firstName = l.firstName,
		lastName = l.lastName,
		title = l.title,
		traits = l.traits,
	}
end

local function slimFaction(f)
	if type(f) ~= "table" then
		return f
	end
	-- drop `id` (== map key) and `lastDelta` (0 at rest, unread); round clout to 4 dp (client renders integer %,
	-- server keeps its full-precision authoritative copy).
	local clout = f.clout
	if type(clout) == "number" then
		clout = math.floor(clout * 1e4 + 0.5) / 1e4
	end
	return {
		loyalty = f.loyalty,
		tier = f.tier,
		clout = clout,
	}
end

local function projectCountry(rec)
	if type(rec) ~= "table" then
		return rec
	end
	local out = {}
	for k, v in rec do
		if not COUNTRY_DROP[k] then
			out[k] = v
		end
	end
	return out
end

local function projectCountries(all)
	local out = {}
	for tag, rec in all do
		out[tag] = projectCountry(rec)
	end
	return out
end

-- Tier 3: the per-player politics packet for the player's OWN country (leaders + factions, slimmed). Delivered
-- via the OwnPolitics channel and stored SEPARATELY on the client (ClientStateCache.setOwnPolitics) so a later
-- shared broadcast delta -- which replaces the whole country record and no longer carries politics -- cannot
-- clobber it. PoliticsScreen overlays this onto the broadcast record.
local function buildOwnPolitics(tag)
	local rec = ctx.WorldState.getCountry(tag)
	if type(rec) ~= "table" then
		return nil
	end
	local out = { tag = tag }
	if type(rec.leaders) == "table" then
		local L = {}
		for slot, l in rec.leaders do
			L[slot] = slimLeader(l)
		end
		out.leaders = L
	end
	if type(rec.factions) == "table" then
		local F = {}
		for id, f in rec.factions do
			F[id] = slimFaction(f)
		end
		out.factions = F
	end
	return out
end

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
				if name == "countries" then
					rec = projectCountry(rec)
				end
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
	-- Provinces are NOT sent here: the full set is a ~2.6 MB sparse table that truncates in remote transit.
	-- They stream separately via pushProvincesTo (chunked). `provincesChunked` tells the client's fullSnapshot
	-- handler to SKIP pruning provinces, so an omitted-provinces snapshot can't wipe chunks that already arrived.
	snapshot.provincesChunked = true
	-- Countries are projected (dead fields dropped, leaders/factions slimmed) to keep the collection well under the
	-- remote transit limit. A shared projected copy is fine -- it is read-only on every client.
	snapshot.countries = projectCountries(ctx.WorldState.allCountries())
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

-- Stream the full province set to one joining client in id-keyed chunks (each <= CHUNK, ~0.37 MB) via the
-- StateSync delta channel, then a completion marker. These are ordinary delta packets, so the client's
-- existing applyDelta reassembles them (and fires the per-record recolor notifies). This is the fix for the
-- sparse full-snapshot truncation that dropped ~3k high-id provinces client-side.
local function pushProvincesTo(player)
	if not stateSync or not player then
		return
	end
	local provinces = ctx.WorldState.allProvinces()
	local ids = {}
	for id in provinces do
		ids[#ids + 1] = id
	end
	table.sort(ids, function(a, b)
		return (tonumber(a) or 0) < (tonumber(b) or 0)
	end)
	local revision = ctx.WorldState.getRevision()
	local chunk, n = {}, 0
	for _, id in ipairs(ids) do
		chunk[id] = provinces[id]
		n += 1
		if n >= CHUNK then
			stateSync:FireClient(player, { revision = revision, provinces = chunk })
			chunk, n = {}, 0
			task.wait()
		end
	end
	if n > 0 then
		stateSync:FireClient(player, { revision = revision, provinces = chunk })
	end
	-- Completion marker carries the full CURRENT province id set so the client can prune any province it still
	-- holds that no longer exists server-side (a delete-delta it may have missed) -- applyFullSnapshot no longer
	-- prunes provinces. Recomputed here (not the start-of-stream `ids`) so a province added mid-stream via a
	-- concurrent delta isn't pruned. A flat array of ~5.7k numeric ids is tiny (~30 KB), never near the limit.
	local finalIds = {}
	for id in ctx.WorldState.allProvinces() do
		finalIds[#finalIds + 1] = id
	end
	stateSync:FireClient(player, {
		revision = ctx.WorldState.getRevision(),
		provincesComplete = true,
		provinceIds = finalIds,
	})
end

-- Push a player their own country's politics (leaders/factions). No-op if they have not claimed yet -- the claim
-- itself dirties the country, so broadcast() delivers it on the next tick.
local function pushOwnPoliticsTo(player)
	if not ownPoliticsSync or not player then
		return
	end
	local tag = ctx.PlayerAuthority and ctx.PlayerAuthority.tagFor(player)
	if not tag then
		return
	end
	local pol = buildOwnPolitics(tag)
	if pol then
		ownPoliticsSync:FireClient(player, pol)
	end
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
	-- Chunk an oversized province delta so a single packet never carries the truncation-prone full sparse
	-- table. The first post-hydrate tick drains ALL ~5.7k provinces as dirty; a large annex can too.
	local provs = packet.provinces
	local pcount = 0
	if provs then
		for _ in provs do
			pcount += 1
		end
	end
	if pcount > CHUNK then
		packet.provinces = nil
		stateSync:FireAllClients(packet)
		local chunk, n = {}, 0
		for k, v in provs do
			chunk[k] = v
			n += 1
			if n >= CHUNK then
				stateSync:FireAllClients({ revision = packet.revision, provinces = chunk })
				chunk, n = {}, 0
			end
		end
		if n > 0 then
			stateSync:FireAllClients({ revision = packet.revision, provinces = chunk })
		end
	else
		stateSync:FireAllClients(packet)
	end
	-- Tier 3: leaders/factions are stripped from the shared broadcast above. Push the owning player their own
	-- country's politics whenever that country changed this tick (claim dirties it, and later politics/economy
	-- ticks re-dirty it), so PoliticsScreen stays current. playerFor() is nil for unclaimed tags -> skipped.
	if ownPoliticsSync and ctx.PlayerAuthority then
		local dirtyCountries = drained.countries
		if type(dirtyCountries) == "table" then
			for _, tag in ipairs(dirtyCountries) do
				local owner = ctx.PlayerAuthority.playerFor(tag)
				if owner then
					local pol = buildOwnPolitics(tag)
					if pol then
						ownPoliticsSync:FireClient(owner, pol)
					end
				end
			end
		end
	end
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
		pushProvincesTo = pushProvincesTo,
		pushOwnPoliticsTo = pushOwnPoliticsTo,
		setStateSync = function(remote)
			stateSync = remote
		end,
		setOwnPoliticsSync = function(remote)
			ownPoliticsSync = remote
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
