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
-- Army records are ~3x heavier than provinces (~600 B slim, up to ~1.5-2.5 KB with a large composition/officer),
-- so armies use a SMALLER per-chunk count to keep each sub-packet ~0.15-0.4 MB (well under the transit limit) even
-- for heavy endgame armies. Measured: 250 armies ≈ 0.145 MB at ~600 B/record.
local ARMY_CHUNK = 250
-- Large id-keyed collections that broadcast() splits when a single delta would risk truncation, with the per-chunk
-- count (provinces are uniform ~500 B -> 800; the heavier/variable ones use ARMY_CHUNK).
local CHUNKED_DELTA = {
	{ field = "provinces", size = CHUNK },
	{ field = "armies", size = ARMY_CHUNK },
	{ field = "fleets", size = ARMY_CHUNK },
	{ field = "armyGroups", size = ARMY_CHUNK },
}
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

-- Army-record projection for the wire: drop server-only fields with ZERO live-client reads. The heavy `composition`
-- table is KEPT (chunking is the primary defense; this slim is secondary). CRITICAL: `reinforceTarget`,
-- `reinforceEnabled`, `domain`, `officer`, `entrenchment`, `entrenchmentMax`, `movementPath` are NOT dropped -- the
-- live UI/Screens/ArmyPanel reads them. Shallow copy -- never mutates the WorldState record.
local ARMY_DROP = {
	createdAt = true,
	battleMoraleMod = true,
	casualtyDebt = true,
	reinforceProgress = true,
	hqId = true,
}

local function projectArmy(rec)
	if type(rec) ~= "table" then
		return rec
	end
	local out = {}
	for k, v in rec do
		if not ARMY_DROP[k] then
			out[k] = v
		end
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
				elseif name == "armies" then
					rec = projectArmy(rec)
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
	-- Armies stream per-join via pushArmiesTo (chunked + projected): the collection is string-keyed and ~1.5 KB/
	-- record, so it can exceed the transit limit at war scale. `armiesChunked` tells the client to skip pruning
	-- armies from this armies-omitting snapshot (mirrors provincesChunked).
	snapshot.armiesChunked = true
	snapshot.battles = ctx.WorldState.allBattles()
	-- Fleets + armyGroups stream per-join via pushFleetsTo / pushArmyGroupsTo (chunked, string-keyed) -- same
	-- transit-truncation class as armies. Their `*Chunked` markers tell the client to skip pruning them here.
	snapshot.fleetsChunked = true
	snapshot.wars = ctx.WorldState.allWars()
	snapshot.peaceProposals = ctx.WorldState.allPeaceProposals()
	snapshot.tradeOrders = ctx.WorldState.allTradeOrders()
	snapshot.pacts = ctx.WorldState.allPacts()
	snapshot.armyGroupsChunked = true
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

-- Stream the full army set to one joining client in id-keyed chunks (mirrors pushProvincesTo). Armies are
-- string-keyed and can exceed the transit limit at war scale, so they are omitted from the snapshot and streamed
-- here (each record projected). These are ordinary delta packets -> the client's applyDelta reassembles them.
local function pushArmiesTo(player)
	if not stateSync or not player then
		return
	end
	local armies = ctx.WorldState.allArmies()
	local revision = ctx.WorldState.getRevision()
	local chunk, n = {}, 0
	for id, rec in armies do
		chunk[id] = projectArmy(rec)
		n += 1
		if n >= ARMY_CHUNK then
			stateSync:FireClient(player, { revision = revision, armies = chunk })
			chunk, n = {}, 0
			task.wait()
		end
	end
	if n > 0 then
		stateSync:FireClient(player, { revision = revision, armies = chunk })
	end
	-- Completion marker with the full CURRENT army id set so the client can prune a stale army whose removal delta
	-- it missed. Recomputed at completion (not stream start) so an army created mid-stream isn't wrongly pruned.
	local finalIds = {}
	for id in ctx.WorldState.allArmies() do
		finalIds[#finalIds + 1] = id
	end
	stateSync:FireClient(player, {
		revision = ctx.WorldState.getRevision(),
		armiesComplete = true,
		armyIds = finalIds,
	})
end

-- Generic per-join chunked streamer for a string-keyed collection (used for fleets + armyGroups). Provinces and
-- armies keep their own streamers above -- provinces sort numeric ids, armies apply projectArmy -- but these two
-- need neither, so they share this. Mirrors the same chunk + completion-marker shape.
local function pushCollectionChunked(player, allFn, field, completeKey, idsKey, chunkSize)
	if not stateSync or not player then
		return
	end
	local records = allFn()
	local revision = ctx.WorldState.getRevision()
	local chunk, n = {}, 0
	for id, rec in records do
		chunk[id] = rec
		n += 1
		if n >= chunkSize then
			stateSync:FireClient(player, { revision = revision, [field] = chunk })
			chunk, n = {}, 0
			task.wait()
		end
	end
	if n > 0 then
		stateSync:FireClient(player, { revision = revision, [field] = chunk })
	end
	local finalIds = {}
	for id in allFn() do
		finalIds[#finalIds + 1] = id
	end
	stateSync:FireClient(player, {
		revision = ctx.WorldState.getRevision(),
		[completeKey] = true,
		[idsKey] = finalIds,
	})
end

local function pushFleetsTo(player)
	pushCollectionChunked(player, ctx.WorldState.allFleets, "fleets", "fleetsComplete", "fleetIds", ARMY_CHUNK)
end

local function pushArmyGroupsTo(player)
	pushCollectionChunked(player, ctx.WorldState.allArmyGroups, "armyGroups", "armyGroupsComplete", "armyGroupIds", ARMY_CHUNK)
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

-- Fire an oversized id-keyed collection as <=chunkSize sub-packets on the shared channel (used by broadcast for
-- both provinces and armies so a single delta never carries a truncation-prone table). chunkSize differs per
-- collection (provinces uniform ~500 B -> 800; armies heavier -> ARMY_CHUNK).
local function fireChunkedDelta(field, records, revision, chunkSize)
	local chunk, n = {}, 0
	for k, v in records do
		chunk[k] = v
		n += 1
		if n >= chunkSize then
			stateSync:FireAllClients({ revision = revision, [field] = chunk })
			chunk, n = {}, 0
		end
	end
	if n > 0 then
		stateSync:FireAllClients({ revision = revision, [field] = chunk })
	end
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
	-- Chunk oversized deltas for the large id-keyed collections so no single packet carries a truncation-prone
	-- table. Null every overflowing collection from the base packet, fire the base exactly ONCE (it still carries
	-- the small collections + removed), then stream each as <=size sub-packets. Provinces drain ALL ~5.7k dirty on
	-- the first post-hydrate tick; armies/fleets can mass-dirty via the regen tick / annex disband at war scale.
	local pending = {}
	for _, spec in ipairs(CHUNKED_DELTA) do
		local t = packet[spec.field]
		if t then
			local c = 0
			for _ in t do
				c += 1
			end
			if c > spec.size then
				pending[#pending + 1] = { field = spec.field, records = t, size = spec.size }
				packet[spec.field] = nil
			end
		end
	end
	stateSync:FireAllClients(packet)
	for _, p in ipairs(pending) do
		fireChunkedDelta(p.field, p.records, packet.revision, p.size)
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
		pushArmiesTo = pushArmiesTo,
		pushFleetsTo = pushFleetsTo,
		pushArmyGroupsTo = pushArmyGroupsTo,
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
