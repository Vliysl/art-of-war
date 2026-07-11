-- SeaZoneGraph: the logical sea-zone network (foundation for the future naval +
-- troop-convoy systems). Loads the baked Data/SeaZones table produced by
-- Dev/AdjacencyGenerator. Sea zones are nodes; sea<->sea edges connect bordering
-- water regions; each zone lists the coastal land provinces that front it.
--
-- This is ADDITIVE and not yet wired into fleet movement (NavalSystem still uses
-- SeaAdjacencyGraph). It exists so naval/convoy work has true sea adjacency to
-- consume. An empty baked table simply means "no zones yet".

local ServerScriptService = game:GetService("ServerScriptService")

local SeaZoneGraph = {}

local zones = {}              -- [zoneKey] = zone record
local shoreByProvince = {}    -- [provinceId] = { zoneKey, ... }

local function loadZones()
	zones = {}
	shoreByProvince = {}
	local aow = ServerScriptService:FindFirstChild("ArtOfWar")
	local dataFolder = aow and aow:FindFirstChild("ServerData")
	local moduleScript = dataFolder and dataFolder:FindFirstChild("SeaZones")
	if not moduleScript then return end
	local ok, baked = pcall(require, moduleScript)
	if not ok or type(baked) ~= "table" then return end
	zones = baked
	for key, zone in baked do
		for _, pid in ipairs(zone.coastalProvinces or {}) do
			local list = shoreByProvince[pid]
			if not list then list = {}; shoreByProvince[pid] = list end
			table.insert(list, key)
		end
	end
end

function SeaZoneGraph.build()
	loadZones()
	local count = 0
	for _ in zones do count += 1 end
	print(string.format("[ArtOfWar] sea-zone graph: %d zones", count))
end

function SeaZoneGraph.getZone(zoneKey)
	return zones[zoneKey]
end

function SeaZoneGraph.zoneNeighbors(zoneKey)
	local z = zones[zoneKey]
	return z and z.seaNeighbors or {}
end

function SeaZoneGraph.coastalProvinces(zoneKey)
	local z = zones[zoneKey]
	return z and z.coastalProvinces or {}
end

function SeaZoneGraph.shoreZonesOf(provinceId)
	return shoreByProvince[provinceId] or {}
end

function SeaZoneGraph.position(zoneKey)
	local z = zones[zoneKey]
	return z and z.pos or nil
end

-- BFS over sea<->sea edges. `passable(zoneKey, prevZoneKey) -> boolean` optional.
function SeaZoneGraph.findSeaPath(startKey, goalKey, passable)
	if startKey == goalKey then return { startKey } end
	if not zones[startKey] or not zones[goalKey] then return nil end
	local cameFrom = { [startKey] = startKey }
	local frontier = { startKey }
	local found = false
	while #frontier > 0 do
		local nextFrontier = {}
		for _, current in ipairs(frontier) do
			for _, neigh in ipairs(zones[current].seaNeighbors or {}) do
				if not cameFrom[neigh] and zones[neigh] then
					if not passable or passable(neigh, current) then
						cameFrom[neigh] = current
						if neigh == goalKey then found = true; break end
						table.insert(nextFrontier, neigh)
					end
				end
			end
			if found then break end
		end
		if found then break end
		frontier = nextFrontier
	end
	if not found then return nil end
	local path = { goalKey }
	local cur = goalKey
	while cur ~= startKey do
		cur = cameFrom[cur]
		table.insert(path, 1, cur)
	end
	return path
end

function SeaZoneGraph.register(context)
	context.SeaZoneGraph = {
		build = SeaZoneGraph.build,
		getZone = SeaZoneGraph.getZone,
		zoneNeighbors = SeaZoneGraph.zoneNeighbors,
		coastalProvinces = SeaZoneGraph.coastalProvinces,
		shoreZonesOf = SeaZoneGraph.shoreZonesOf,
		position = SeaZoneGraph.position,
		findSeaPath = SeaZoneGraph.findSeaPath,
	}
end

return SeaZoneGraph
