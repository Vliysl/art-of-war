local WorldState = {}

local COLLECTIONS = { "provinces", "countries", "markets", "units", "fleets", "tradeRoutes", "ideologies", "leaders", "armies", "battles", "wars", "peaceProposals" }

local store
local dirty
local tombstones
local revision

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

function WorldState.deleteCountry(tag) tombstone("countries", tag) end
function WorldState.deleteProvince(id) tombstone("provinces", id) end

function WorldState.getRevision()
	return revision
end

function WorldState.bumpRevision()
	bump()
	return revision
end

function WorldState.setProvince(id, record)
	store.provinces[id] = record
	mark("provinces", id)
	bump()
end

function WorldState.getProvince(id)
	return store.provinces[id]
end

function WorldState.allProvinces()
	return store.provinces
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
	if not hasAny then return nil end
	drained.revision = revision
	drained.removed = removed
	return drained
end

function WorldState.markDirty(collection, key)
	if dirty[collection] then mark(collection, key) end
end

function WorldState.clear()
	resetStore()
end

return WorldState
