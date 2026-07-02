-- Sea-node id convention (C9 sea transport): the movement graph addresses sea tiles as
-- NEGATIVE part numbers (map part `sea_<n>_*` -> node id -n). Every graph id stays a plain
-- number (zero replication/Types churn) and land/sea distinction is free (id < 0). The
-- tile-level adjacency itself is baked to Data/SeaTileAdjacency by Dev/AdjacencyGenerator;
-- until a bake exists the data is an empty table and every helper degrades to "no sea".
local WorldConstants = require(script.Parent:WaitForChild("WorldConstants"))

local SeaNodes = {}

local baked = nil
local function data()
	if baked == nil then
		local ok, t = pcall(function()
			return require(script.Parent.Parent:WaitForChild("Data"):WaitForChild("SeaTileAdjacency"))
		end)
		baked = (ok and type(t) == "table") and t or {}
	end
	return baked
end

function SeaNodes.isSea(id)
	return type(id) == "number" and id < 0
end

function SeaNodes.toNodeId(partNumber)
	return -partNumber
end

function SeaNodes.partNumber(id)
	return id < 0 and -id or id
end

-- Baked record { sea = {n...}, shore = {provinceId...}, x, z } for a node id or part number.
function SeaNodes.entryOf(id)
	return data()[SeaNodes.partNumber(id)]
end

function SeaNodes.shoreOf(id)
	local e = SeaNodes.entryOf(id)
	return (e and e.shore) or {}
end

function SeaNodes.tiles()
	return data()
end

-- Nearest baked sea node to a world XZ point, seam-aware (X wraps every MapWidth). Used for
-- client sea targeting: the sea meshes are zero-thickness so click/hover raycasts cannot be
-- trusted -- the Y=0 plane intersection + this lookup is the reliable path. Linear over the
-- ~633 baked tiles. Returns nil when no tile is within maxDist (or no bake exists).
function SeaNodes.nearestNode(x, z, maxDist)
	local bestId, bestDistSq = nil, nil
	local maxSq = maxDist and (maxDist * maxDist) or math.huge
	local width, half = WorldConstants.MapWidth, WorldConstants.MapHalfWidth
	for n, e in data() do
		local dx = (e.x or 0) - x
		dx = ((dx + half) % width) - half
		local dz = (e.z or 0) - z
		local d = dx * dx + dz * dz
		if d <= maxSq and (bestDistSq == nil or d < bestDistSq) then
			bestId, bestDistSq = -n, d
		end
	end
	return bestId
end

return SeaNodes
