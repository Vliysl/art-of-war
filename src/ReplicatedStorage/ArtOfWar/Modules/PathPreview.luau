local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MoveArrowRender = require(script.Parent:WaitForChild("MoveArrowRender"))

local PathPreview = {}

local ADJACENCY_THRESHOLD = 300
local LINE_THICKNESS = 1.5
local LINE_LIFT = 4
local PATH_COLOR_FRIENDLY = Color3.fromRGB(120, 220, 255)
local PATH_COLOR_HOSTILE = Color3.fromRGB(220, 80, 80)
local PATH_COLOR_BLOCKED = Color3.fromRGB(180, 90, 90)

local provincesFolder = nil
local mapFolder = nil
local previewFolder = nil
local positions = {}
local neighbors = {}
local builtAdjacency = false
local activeLines = {}

local function ensurePreviewFolder()
	mapFolder = workspace:FindFirstChild("ArtOfWarMap")
	if not mapFolder then return nil end
	provincesFolder = mapFolder:FindFirstChild("Provinces")
	previewFolder = mapFolder:FindFirstChild("PathPreview")
	if not previewFolder then
		previewFolder = Instance.new("Folder")
		previewFolder.Name = "PathPreview"
		previewFolder.Parent = mapFolder
	end
	return previewFolder
end

local function bucketKey(x, z)
	return tostring(x) .. ":" .. tostring(z)
end

-- Render-only position scan (always runs; the path line needs province centroids).
-- Returns the list of province ids found.
local function scanPositions()
	positions = {}
	local ids = {}
	if not provincesFolder then return ids end
	for _, part in provincesFolder:GetChildren() do
		if part:IsA("BasePart") then
			local pid = part:GetAttribute("province_id")
			if pid then
				positions[pid] = Vector3.new(part.Position.X, part.Position.Y + part.Size.Y * 0.5, part.Position.Z)
				ids[#ids + 1] = pid
			end
		end
	end
	return ids
end

-- Consume the same baked true-adjacency table the server uses (land neighbors),
-- so the preview line matches the server's movement gate exactly. Returns true
-- if the baked table was present, non-empty, and matched the local provinces.
local function loadBakedNeighbors()
	local dataFolder = ReplicatedStorage:FindFirstChild("ArtOfWar")
	dataFolder = dataFolder and dataFolder:FindFirstChild("Data")
	local moduleScript = dataFolder and dataFolder:FindFirstChild("ProvinceAdjacency")
	if not moduleScript then return false end
	local ok, baked = pcall(require, moduleScript)
	if not ok or type(baked) ~= "table" then return false end
	local bakedCount = 0
	for _ in baked do bakedCount += 1 end
	if bakedCount == 0 then return false end

	local nbrs = {}
	local total = 0
	for pid in positions do nbrs[pid] = {}; total += 1 end
	local matched = 0
	for id, entry in baked do
		if positions[id] ~= nil and type(entry) == "table" then
			matched += 1
			local list = nbrs[id]
			for _, n in ipairs(entry.land or {}) do
				if positions[n] ~= nil then list[#list + 1] = n end
			end
		end
	end
	-- Parity with AdjacencyGraph: a too-stale table falls back to legacy.
	if total > 0 and (matched / total) < 0.5 then return false end
	neighbors = nbrs
	return true
end

-- Legacy 300-stud centroid rebuild. Fallback only (mirrors AdjacencyGraph's
-- legacy path so client and server agree when baked data is absent/stale).
local function computeLegacyNeighbors(ids)
	neighbors = {}
	local buckets = {}
	local cellSize = ADJACENCY_THRESHOLD
	for _, pid in ipairs(ids) do
		neighbors[pid] = {}
		local pos = positions[pid]
		local gx = math.floor(pos.X / cellSize)
		local gz = math.floor(pos.Z / cellSize)
		local key = bucketKey(gx, gz)
		local bucket = buckets[key]
		if not bucket then bucket = {}; buckets[key] = bucket end
		bucket[#bucket + 1] = pid
	end
	local thresholdSq = ADJACENCY_THRESHOLD * ADJACENCY_THRESHOLD
	for _, idA in ipairs(ids) do
		local pa = positions[idA]
		local gx = math.floor(pa.X / cellSize)
		local gz = math.floor(pa.Z / cellSize)
		local aKey = tostring(idA)
		for dx = -1, 1 do
			for dz = -1, 1 do
				local bucket = buckets[bucketKey(gx + dx, gz + dz)]
				if bucket then
					for _, idB in ipairs(bucket) do
						if idA ~= idB and aKey < tostring(idB) then
							local pb = positions[idB]
							local diffX = pa.X - pb.X
							local diffZ = pa.Z - pb.Z
							if diffX * diffX + diffZ * diffZ <= thresholdSq then
								neighbors[idA][#neighbors[idA] + 1] = idB
								neighbors[idB][#neighbors[idB] + 1] = idA
							end
						end
					end
				end
			end
		end
	end
end

local function buildAdjacency()
	if builtAdjacency then return end
	if not ensurePreviewFolder() or not provincesFolder then return end
	local ids = scanPositions()
	if #ids == 0 then return end
	if not loadBakedNeighbors() then
		computeLegacyNeighbors(ids)
	end
	builtAdjacency = true
end

local function provinceTraversable(provinceId, ClientStateCache, ownerTag)
	local p = ClientStateCache.getProvince(provinceId)
	if not p then return false end
	local controller = p.controllerTag
	if controller == ownerTag then return true end
	if not controller or controller == "NONE" or controller == "" then return true end
	local wars = ClientStateCache.allWars and ClientStateCache.allWars()
	if wars then
		for _, war in pairs(wars) do
			if war.status == "active"
				and ((war.attackerTag == ownerTag and war.defenderTag == controller)
					or (war.defenderTag == ownerTag and war.attackerTag == controller)) then
				return true
			end
		end
	end
	return false
end

local function findPath(startId, goalId, ClientStateCache, ownerTag)
	if not builtAdjacency then return nil end
	if startId == goalId then return { startId } end
	if not neighbors[startId] or not neighbors[goalId] then return nil end
	local cameFrom = { [startId] = startId }
	local frontier = { startId }
	local found = false
	while #frontier > 0 do
		local nextFrontier = {}
		for _, current in ipairs(frontier) do
			for _, neigh in ipairs(neighbors[current]) do
				if not cameFrom[neigh] then
					local passable = (neigh == goalId) or provinceTraversable(neigh, ClientStateCache, ownerTag)
					if passable then
						cameFrom[neigh] = current
						if neigh == goalId then found = true; break end
						nextFrontier[#nextFrontier + 1] = neigh
					end
				end
			end
			if found then break end
		end
		if found then break end
		frontier = nextFrontier
	end
	if not found then return nil end
	local path = { goalId }
	local cur = goalId
	while cur ~= startId do
		cur = cameFrom[cur]
		table.insert(path, 1, cur)
	end
	return path
end

local function clearLines()
	for _, line in ipairs(activeLines) do
		if line.Parent then line:Destroy() end
	end
	activeLines = {}
end

local ARROW_WIDTH = 9
local ARROW_THICK = 0.4

-- Draw the route as a chunky flat ground arrow (shaft per leg + chevron head at the destination),
-- tinted by friendly/hostile/blocked. Replaces the old thin neon line + dots.
local function renderPath(path, color)
	clearLines()
	if not path or #path < 2 then return end
	if not previewFolder then ensurePreviewFolder() end
	if not previewFolder then return end
	local pts = {}
	for _, pid in ipairs(path) do
		local pos = positions[pid]
		if pos then pts[#pts + 1] = pos + Vector3.new(0, LINE_LIFT, 0) end
	end
	if #pts < 2 then return end
	local parts = MoveArrowRender.buildArrow(pts, {
		color = color,
		width = ARROW_WIDTH,
		thickness = ARROW_THICK,
		transparency = 0,
	})
	for _, part in ipairs(parts) do
		part.Name = "PathArrow"
		part.Parent = previewFolder
		activeLines[#activeLines + 1] = part
	end
end

function PathPreview.init()
	ensurePreviewFolder()
end

function PathPreview.show(fromProvinceId, toProvinceId, ClientStateCache, ownerTag)
	if not builtAdjacency then buildAdjacency() end
	if not fromProvinceId or not toProvinceId or fromProvinceId == toProvinceId then
		clearLines()
		return
	end
	local path = findPath(fromProvinceId, toProvinceId, ClientStateCache, ownerTag)
	if not path then
		local a = positions[fromProvinceId]
		local b = positions[toProvinceId]
		if a and b then
			renderPath({ fromProvinceId, toProvinceId }, PATH_COLOR_BLOCKED)
		else
			clearLines()
		end
		return
	end
	local destProv = ClientStateCache.getProvince(toProvinceId)
	local hostile = destProv and destProv.controllerTag and destProv.controllerTag ~= ownerTag
		and destProv.controllerTag ~= "NONE" and destProv.controllerTag ~= ""
	renderPath(path, hostile and PATH_COLOR_HOSTILE or PATH_COLOR_FRIENDLY)
end

function PathPreview.clear()
	clearLines()
end

function PathPreview.destroy()
	clearLines()
	if previewFolder and previewFolder.Parent then previewFolder:Destroy() end
	previewFolder = nil
	builtAdjacency = false
end

return PathPreview