local AdjacencyGraph = {}

local ctx
local positions = {}
local neighbors = {}

local function scanPositions()
	positions = {}
	local map = workspace:FindFirstChild("ArtOfWarMap")
	local folder = map and map:FindFirstChild("Provinces")
	if not folder then return end
	for _, part in folder:GetChildren() do
		if part:IsA("BasePart") then
			local provinceId = part:GetAttribute("province_id")
			if provinceId then
				positions[provinceId] = Vector2.new(part.Position.X, part.Position.Z)
			end
		end
	end
end

local function computeNeighbors()
	neighbors = {}
	local threshold = ctx.WorldConstants.AdjacencyThreshold
	local thresholdSq = threshold * threshold
	for idA, posA in positions do
		neighbors[idA] = {}
	end
	local ids = {}
	for id in positions do table.insert(ids, id) end
	for i = 1, #ids do
		local idA = ids[i]
		local posA = positions[idA]
		for j = i + 1, #ids do
			local idB = ids[j]
			local posB = positions[idB]
			local dx = posA.X - posB.X
			local dz = posA.Y - posB.Y
			if dx * dx + dz * dz <= thresholdSq then
				table.insert(neighbors[idA], idB)
				table.insert(neighbors[idB], idA)
			end
		end
	end
end

function AdjacencyGraph.build()
	scanPositions()
	computeNeighbors()
	local count = 0
	for _, list in neighbors do count += #list end
	local provinceCount = 0
	for _ in positions do provinceCount += 1 end
	print(string.format("[ArtOfWar] adjacency graph: %d provinces, %d directed edges", provinceCount, count))
end

function AdjacencyGraph.getNeighbors(provinceId)
	return neighbors[provinceId] or {}
end

function AdjacencyGraph.areNeighbors(a, b)
	local list = neighbors[a]
	if not list then return false end
	for _, id in list do
		if id == b then return true end
	end
	return false
end

function AdjacencyGraph.distance(a, b)
	local pa = positions[a]
	local pb = positions[b]
	if not pa or not pb then return math.huge end
	return (pa - pb).Magnitude
end

function AdjacencyGraph.position(provinceId)
	return positions[provinceId]
end

function AdjacencyGraph.isRegistered(provinceId)
	return positions[provinceId] ~= nil
end

-- BFS shortest path from start to goal through `passable(provinceId, prevProvinceId, ownerTag) -> boolean`.
-- If passable is nil, treat all provinces as passable. Returns { startId, ..., goalId } or nil if unreachable.
function AdjacencyGraph.findPath(startId, goalId, passable)
	if startId == goalId then return { startId } end
	if not neighbors[startId] or not neighbors[goalId] then return nil end
	local cameFrom = { [startId] = startId }  -- self-reference marks visited start
	local frontier = { startId }
	local found = false
	while #frontier > 0 do
		local nextFrontier = {}
		for _, current in ipairs(frontier) do
			for _, neigh in ipairs(neighbors[current]) do
				if not cameFrom[neigh] then
					if not passable or passable(neigh, current) then
						cameFrom[neigh] = current
						if neigh == goalId then found = true; break end
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
	-- Reconstruct
	local path = { goalId }
	local cur = goalId
	while cur ~= startId do
		cur = cameFrom[cur]
		table.insert(path, 1, cur)
	end
	return path
end

function AdjacencyGraph.register(context)
	ctx = context
	context.AdjacencyGraph = {
		build = AdjacencyGraph.build,
		getNeighbors = AdjacencyGraph.getNeighbors,
		areNeighbors = AdjacencyGraph.areNeighbors,
		distance = AdjacencyGraph.distance,
		position = AdjacencyGraph.position,
		isRegistered = AdjacencyGraph.isRegistered,
		findPath = AdjacencyGraph.findPath,
	}
end

return AdjacencyGraph
