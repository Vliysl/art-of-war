local WorldState = {}

local COLLECTIONS = {
	"provinces",
	"countries",
	"markets",
	"units",
	"fleets",
	"tradeRoutes",
	"ideologies",
	"leaders",
	"armies",
	"battles",
	"wars",
	"peaceProposals",
	"tradeOrders",
	"pacts",
	"armyGroups",
}

local store
local dirty
local tombstones
local revision
-- Injected once from Bootstrap so the ownership chokepoint can publish the canonical events without
-- WorldState taking a hard dependency on the event framework.
local eventBus
local channels

local function resetStore()
	store = {}
	dirty = {}
	tombstones = {}
	for _, name in COLLECTIONS do
		store[name] = {}
		dirty[name] = {}
		tombstones[name] = {}
	end
	revision = 0
end

resetStore()

local function bump()
	revision += 1
end

local function mark(collection, key)
	dirty[collection][key] = true
end

local function tombstone(collection, key)
	store[collection][key] = nil
	dirty[collection][key] = nil
	tombstones[collection][key] = true
	bump()
end

-- Integrity guard (see the ownership-restructure): a country must NEVER be deleted while a province
-- still names it as owner -- otherwise that province is STRANDED owning a dead tag (the observed
-- "annexed nation gone from diplomacy, but the tile still shows it" orphan). Ownership lives in several
-- representations kept in sync by convention (record / byOwner index / part attributes / client cache);
-- if any desynced, annexCountry's index-driven transfer loop could miss a province. So before tombstoning
-- we sweep the AUTHORITATIVE province store and reassign any straggler to `reassignTo` (the annexer) or
-- "NONE", publishing the canonical event so the indices, stamper and clients self-heal. O(provinces) and
-- country deletion is rare; the loop finds 0 in the normal (index-consistent) case.
function WorldState.deleteCountry(tag, reassignTo)
	local successor = reassignTo or "NONE"
	for id, province in store.provinces do
		if province.ownerTag == tag then
			local oldController = province.controllerTag
			province.ownerTag = successor
			if province.controllerTag == tag then
				province.controllerTag = successor
			end
			mark("provinces", id)
			warn(
				string.format(
					"[WorldState] deleteCountry(%s): reassigned stranded province %s -> %s (ownership desync guard)",
					tostring(tag),
					tostring(id),
					tostring(successor)
				)
			)
			if eventBus and channels then
				eventBus.publish(channels.ProvinceOwnershipChanged, {
					provinceId = id,
					oldOwner = tag,
					newOwner = successor,
					oldController = oldController,
					reason = "orphan_guard",
				})
			end
		end
	end
	tombstone("countries", tag)
end
function WorldState.deleteProvince(id)
	tombstone("provinces", id)
end

function WorldState.getRevision()
	return revision
end

function WorldState.bumpRevision()
	bump()
	return revision
end

function WorldState.setProvince(id, record)
	-- Province ids are canonically NUMERIC (see ClientStateCache.provKey). Coerce defensively so the store,
	-- dirty set, and delta can never acquire a string-keyed province that reads would then miss.
	id = tonumber(id) or id
	store.provinces[id] = record
	mark("provinces", id)
	bump()
end

function WorldState.getProvince(id)
	return store.provinces[id] or store.provinces[tonumber(id)]
end

function WorldState.allProvinces()
	return store.provinces
end

-- Compact ownership snapshot for the client self-heal reconcile (OwnershipReconcile): owner + controller
-- only, so a client can cheaply detect + repair any province whose replicated record drifted from the
-- server without re-pulling full records. `{ [id] = { o = ownerTag, c = controllerTag } }`.
function WorldState.getOwnershipDigest()
	local out = {}
	for id, p in store.provinces do
		out[id] = { o = p.ownerTag, c = p.controllerTag }
	end
	return out
end

function WorldState.bindEvents(bus, chan)
	eventBus = bus
	channels = chan
end

-- The single chokepoint for province OWNERSHIP + OCCUPATION mutations. Fuses the record write with
-- the canonical event publish, so the WorldState record and every downstream representation (map
-- render, ProvinceRegistry byOwner/byController, economy/market/capital reactions, ...) stay in sync
-- by construction rather than by convention. `opts.owner`/`opts.controller` default to UNCHANGED when
-- nil (a controller-only change is an occupation; sites that conditionally follow the owner pass the
-- exact controller). Emits the SAME payloads the individual write sites used, so subscribers are
-- untouched. Returns whether anything actually changed.
function WorldState.setProvinceOwnership(id, opts)
	local record = store.provinces[id]
	if not record then
		return false
	end
	opts = opts or {}
	local oldOwner = record.ownerTag
	local oldController = record.controllerTag
	local newOwner = opts.owner ~= nil and opts.owner or oldOwner
	local newController = opts.controller ~= nil and opts.controller or oldController
	if newOwner == oldOwner and newController == oldController then
		return false
	end
	record.ownerTag = newOwner
	record.controllerTag = newController
	mark("provinces", id)
	bump()
	if eventBus and channels then
		if newOwner ~= oldOwner then
			local payload = { provinceId = id, oldOwner = oldOwner, newOwner = newOwner, reason = opts.reason }
			if type(opts.extra) == "table" then
				for k, v in pairs(opts.extra) do
					payload[k] = v
				end
			end
			eventBus.publish(channels.ProvinceOwnershipChanged, payload)
		else
			eventBus.publish(channels.ProvinceOccupied, {
				provinceId = id,
				newController = newController,
				oldController = oldController,
				ownerTag = newOwner,
				reason = opts.reason,
			})
		end
	end
	return true
end

function WorldState.setCountry(tag, record)
	store.countries[tag] = record
	mark("countries", tag)
	bump()
end

function WorldState.getCountry(tag)
	return store.countries[tag]
end

function WorldState.allCountries()
	return store.countries
end

function WorldState.setMarket(id, record)
	store.markets[id] = record
	mark("markets", id)
	bump()
end

function WorldState.getMarket(id)
	return store.markets[id]
end

function WorldState.allMarkets()
	return store.markets
end

function WorldState.setUnit(id, record)
	store.units[id] = record
	mark("units", id)
	bump()
end

function WorldState.getUnit(id)
	return store.units[id]
end

function WorldState.allUnits()
	return store.units
end

function WorldState.setFleet(id, record)
	if record == nil then
		tombstone("fleets", id)
		return
	end
	store.fleets[id] = record
	mark("fleets", id)
	bump()
end

function WorldState.getFleet(id)
	return store.fleets[id]
end

function WorldState.allFleets()
	return store.fleets
end

function WorldState.setTradeRoute(id, record)
	store.tradeRoutes[id] = record
	mark("tradeRoutes", id)
	bump()
end

function WorldState.getTradeRoute(id)
	return store.tradeRoutes[id]
end

function WorldState.allTradeRoutes()
	return store.tradeRoutes
end

function WorldState.setIdeology(id, record)
	store.ideologies[id] = record
	mark("ideologies", id)
	bump()
end

function WorldState.getIdeology(id)
	return store.ideologies[id]
end

function WorldState.allIdeologies()
	return store.ideologies
end

function WorldState.setLeader(id, record)
	store.leaders[id] = record
	mark("leaders", id)
	bump()
end

function WorldState.getLeader(id)
	return store.leaders[id]
end

function WorldState.allLeaders()
	return store.leaders
end

function WorldState.setArmy(id, record)
	-- nil record == removal: tombstone so the delta carries it in `removed` (a plain
	-- dirty mark would just emit a nil value that vanishes from the packet, leaving
	-- the army stranded on every client -- this was the broken disband path).
	if record == nil then
		tombstone("armies", id)
		return
	end
	store.armies[id] = record
	mark("armies", id)
	bump()
end

function WorldState.getArmy(id)
	return store.armies[id]
end

function WorldState.allArmies()
	return store.armies
end

function WorldState.setBattle(id, record)
	if record == nil then
		tombstone("battles", id)
		return
	end
	store.battles[id] = record
	mark("battles", id)
	bump()
end

function WorldState.getBattle(id)
	return store.battles[id]
end

function WorldState.allBattles()
	return store.battles
end

function WorldState.setWar(id, record)
	store.wars[id] = record
	mark("wars", id)
	bump()
end

function WorldState.getWar(id)
	return store.wars[id]
end

function WorldState.allWars()
	return store.wars
end

function WorldState.setPeaceProposal(id, record)
	store.peaceProposals[id] = record
	mark("peaceProposals", id)
	bump()
end

function WorldState.getPeaceProposal(id)
	return store.peaceProposals[id]
end

function WorldState.allPeaceProposals()
	return store.peaceProposals
end

function WorldState.setTradeOrder(id, record)
	store.tradeOrders[id] = record
	mark("tradeOrders", id)
	bump()
end

function WorldState.getTradeOrder(id)
	return store.tradeOrders[id]
end

function WorldState.allTradeOrders()
	return store.tradeOrders
end

function WorldState.setPact(id, record)
	store.pacts[id] = record
	mark("pacts", id)
	bump()
end

function WorldState.getPact(id)
	return store.pacts[id]
end

function WorldState.allPacts()
	return store.pacts
end

function WorldState.setArmyGroup(id, record)
	if record == nil then
		tombstone("armyGroups", id)
		return
	end
	store.armyGroups[id] = record
	mark("armyGroups", id)
	bump()
end

function WorldState.getArmyGroup(id)
	return store.armyGroups[id]
end

function WorldState.allArmyGroups()
	return store.armyGroups
end

function WorldState.snapshot()
	return {
		revision = revision,
		provinces = store.provinces,
		countries = store.countries,
		markets = store.markets,
		units = store.units,
		fleets = store.fleets,
		tradeRoutes = store.tradeRoutes,
		ideologies = store.ideologies,
		leaders = store.leaders,
		armies = store.armies,
		battles = store.battles,
		wars = store.wars,
		peaceProposals = store.peaceProposals,
		tradeOrders = store.tradeOrders,
		pacts = store.pacts,
		armyGroups = store.armyGroups,
	}
end

function WorldState.drainDirty()
	local drained = {}
	local removed = {}
	local hasAny = false
	for _, name in COLLECTIONS do
		local dirtyPool = dirty[name]
		local keys = {}
		for key in dirtyPool do
			table.insert(keys, key)
			hasAny = true
		end
		drained[name] = keys
		table.clear(dirtyPool)

		local tombPool = tombstones[name]
		local removedKeys = {}
		for key in tombPool do
			table.insert(removedKeys, key)
			hasAny = true
		end
		removed[name] = removedKeys
		table.clear(tombPool)
	end
	if not hasAny then
		return nil
	end
	drained.revision = revision
	drained.removed = removed
	return drained
end

function WorldState.markDirty(collection, key)
	if dirty[collection] then
		mark(collection, key)
	end
end

function WorldState.clear()
	resetStore()
end

return WorldState
