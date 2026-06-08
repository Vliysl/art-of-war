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

local function buildAdjacency()
	if builtAdjacency then return end
	if not ensurePreviewFolder() or not provincesFolder then return end

	positions = {}
	neighbors = {}
	local ids = {}
	local buckets = {}
	local cellSize = ADJACENCY_THRESHOLD

	for _, part in provincesFolder:GetChildren() do
		if part:IsA("BasePart") then
			local pid = part:GetAttribute("province_id")
			if pid then
				local pos = Vector3.new(part.Position.X, part.Position.Y + part.Size.Y * 0.5, part.Position.Z)
				positions[pid] = pos
				neighbors[pid] = {}
				ids[#ids + 1] = pid
				local gx = math.floor(pos.X / cellSize)
				local gz = math.floor(pos.Z / cellSize)
				local key = bucketKey(gx, gz)
				local bucket = buckets[key]
				if not bucket then
					bucket = {}
					buckets[key] = bucket
				end
				bucket[#bucket + 1] = pid
			end
		end
	end

	if #ids == 0 then return end

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

local function renderPath(path, color)
	clearLines()
	if not path or #path < 2 then return end
	if not previewFolder then ensurePreviewFolder() end
	if not previewFolder then return end
	for i = 1, #path - 1 do
		local a = positions[path[i]]
		local b = positions[path[i + 1]]
		if a and b then
			local mid = (a + b) * 0.5 + Vector3.new(0, LINE_LIFT, 0)
			local diff = b - a
			local dist = diff.Magnitude
			local part = Instance.new("Part")
			part.Name = "PathSeg"
			part.Size = Vector3.new(LINE_THICKNESS, LINE_THICKNESS, dist)
			part.Color = color
			part.Material = Enum.Material.Neon
			part.Anchored = true
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
			part.Massless = true
			part.CastShadow = false
			part.Transparency = 0.05
			part.CFrame = CFrame.lookAt(mid, b + Vector3.new(0, LINE_LIFT, 0))
			part.Parent = previewFolder
			activeLines[#activeLines + 1] = part

			local dot = Instance.new("Part")
			dot.Name = "PathDot"
			dot.Shape = Enum.PartType.Ball
			dot.Size = Vector3.new(4, 4, 4)
			dot.Color = color
			dot.Material = Enum.Material.Neon
			dot.Anchored = true
			dot.CanCollide = false
			dot.CanTouch = false
			dot.CanQuery = false
			dot.Massless = true
			dot.CastShadow = false
			dot.Transparency = 0.05
			dot.CFrame = CFrame.new(b + Vector3.new(0, LINE_LIFT, 0))
			dot.Parent = previewFolder
			activeLines[#activeLines + 1] = dot
		end
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