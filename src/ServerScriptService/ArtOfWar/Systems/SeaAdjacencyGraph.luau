local SeaAdjacencyGraph = {}

local ctx
local positions = {}
local coastalSet = {}

local function scan()
	table.clear(positions)
	table.clear(coastalSet)
	local adjacency = ctx.AdjacencyGraph
	if not adjacency or not adjacency.position then return end
	local provinces = ctx.WorldState.allProvinces()
	for id, prov in provinces do
		if prov.coastal == true then
			local pos = adjacency.position(id)
			if pos then
				positions[id] = pos
				coastalSet[id] = true
			end
		end
	end
end

function SeaAdjacencyGraph.build()
	scan()
	local count = 0
	for _ in coastalSet do count += 1 end
	print(string.format("[ArtOfWar] sea network: %d coastal provinces, NavalMovementSpeed=%d studs/s",
		count, ctx.WorldConstants.NavalMovementSpeed))
end

function SeaAdjacencyGraph.isCoastal(provinceId)
	return coastalSet[provinceId] == true
end

function SeaAdjacencyGraph.canReach(fromId, toId)
	return coastalSet[fromId] == true and coastalSet[toId] == true
end

function SeaAdjacencyGraph.distance(fromId, toId)
	local pa = positions[fromId]
	local pb = positions[toId]
	if not pa or not pb then return math.huge end
	return (pa - pb).Magnitude
end

function SeaAdjacencyGraph.travelTime(fromId, toId)
	local consts = ctx.WorldConstants
	local d = SeaAdjacencyGraph.distance(fromId, toId)
	if d == math.huge then return consts.NavalTravelMaxSeconds end
	local raw = d / consts.NavalMovementSpeed
	return math.clamp(raw, consts.NavalTravelMinSeconds, consts.NavalTravelMaxSeconds)
end

function SeaAdjacencyGraph.coastalIds()
	local out = {}
	for id in coastalSet do table.insert(out, id) end
	return out
end

function SeaAdjacencyGraph.register(context)
	ctx = context
	context.SeaAdjacencyGraph = {
		build = SeaAdjacencyGraph.build,
		isCoastal = SeaAdjacencyGraph.isCoastal,
		canReach = SeaAdjacencyGraph.canReach,
		distance = SeaAdjacencyGraph.distance,
		travelTime = SeaAdjacencyGraph.travelTime,
		coastalIds = SeaAdjacencyGraph.coastalIds,
	}
end

return SeaAdjacencyGraph
