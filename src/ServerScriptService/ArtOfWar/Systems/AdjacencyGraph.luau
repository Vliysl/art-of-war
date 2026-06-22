-- AdjacencyGraph: province adjacency for land movement & combat.
--
-- Neighbors come from a BAKED, true-geometric-bordering table
-- (ReplicatedStorage.ArtOfWar.Data.ProvinceAdjacency, produced by
-- Dev/AdjacencyGenerator). The legacy 300-stud centroid-radius computation is
-- retained as a FALLBACK so the server always boots and armies always move even
-- if the baked data is missing, empty, or stale (id-set diverged from the
-- stamped provinces). `AdjacencyGraph.setMode("baked"|"legacy"|"auto")` overrides
-- the auto choice for debugging.
--
-- Public API is unchanged (getNeighbors/areNeighbors/distance/position/
-- isRegistered/findPath), so MovementSystem/CombatSystem/BattleManager need no
-- edits; only the neighbor SET changes (true bordering). `isCoastal`/`getShore`
-- are additive (used by SeaAdjacencyGraph and the future naval/convoy systems).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AdjacencyGraph = {}

local ctx
local positions = {}
local neighbors = {}
local coastalSet = {}
local shoreByProvince = {}
local bakedIds = {}       -- set of province ids present in the baked table (whatever its land set)
local mode = "auto"       -- "auto" | "baked" | "legacy"
local activeSource = "none"

-- Minimum fraction of baked province ids that must match the stamped id-set for
-- the baked table to be trusted in "auto" mode; below this we treat it as stale.
local BAKED_MATCH_MIN = 0.5

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

local function registeredCount()
	local n = 0
	for _ in positions do n += 1 end
	return n
end

-- LEGACY: 300-stud centroid radius. Fallback only.
local function computeNeighborsLegacy()
	neighbors = {}
	local threshold = ctx.WorldConstants.AdjacencyThreshold
	local thresholdSq = threshold * threshold
	for idA in positions do
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
	-- Legacy has no coastal data; fall back to authored province.coastal so
	-- isCoastal() still answers for the naval layer.
	coastalSet = {}
	shoreByProvince = {}
	if ctx.WorldState and ctx.WorldState.allProvinces then
		for id, prov in ctx.WorldState.allProvinces() do
			if prov.coastal == true and positions[id] ~= nil then
				coastalSet[id] = true
			end
		end
	end
end

-- Try to load the baked table. Returns (ok, bakedCount, matchedCount).
local function tryLoadBaked()
	local dataFolder = ReplicatedStorage:FindFirstChild("ArtOfWar")
	dataFolder = dataFolder and dataFolder:FindFirstChild("Data")
	local moduleScript = dataFolder and dataFolder:FindFirstChild("ProvinceAdjacency")
	if not moduleScript then return false, 0, 0 end
	local ok, baked = pcall(require, moduleScript)
	if not ok or type(baked) ~= "table" then return false, 0, 0 end

	local bakedCount, matchedCount = 0, 0
	for _ in baked do bakedCount += 1 end
	if bakedCount == 0 then return false, 0, 0 end

	local nbrs, coastal, shore, ids = {}, {}, {}, {}
	for id in positions do nbrs[id] = {} end
	for id, entry in baked do
		ids[id] = true
		if positions[id] ~= nil and type(entry) == "table" then
			matchedCount += 1
			local list = nbrs[id]
			for _, n in ipairs(entry.land or {}) do
				-- Keep only neighbors that are actually registered this boot.
				if positions[n] ~= nil then table.insert(list, n) end
			end
			if entry.coastal == true then coastal[id] = true end
			if entry.shore then shore[id] = entry.shore end
		end
	end
	-- Stage into module state only after a successful parse.
	neighbors, coastalSet, shoreByProvince, bakedIds = nbrs, coastal, shore, ids
	return true, bakedCount, matchedCount
end

-- When the baked table is used, any registered province NOT present in it (e.g. a tile
-- promoted/reconciled after the table was last generated) would otherwise be a node with
-- no neighbors -- an unreachable island. Link each such province to its closest registered
-- provinces (bidirectionally) so it is reachable. We take the nearest few within the radius
-- rather than every province in range, because the bare centroid radius badly over-connects
-- (a province can have 100+ others within 300 studs); the cap approximates true bordering and
-- keeps these provinces from becoming movement super-hubs. Provinces the baked table DOES know
-- about (incl. genuine islands with an empty land set) are left untouched, so no false land
-- bridges are created across water. Regenerate Data/ProvinceAdjacency to replace this with true
-- bordering.
local MAX_SYNTH_BORDERS = 8

local function linkUnbakedRegistered()
	local threshold = ctx.WorldConstants.AdjacencyThreshold
	local thresholdSq = threshold * threshold
	local patched, edges = 0, 0
	for idA, posA in positions do
		if not bakedIds[idA] then
			local candidates = {}
			for idB, posB in positions do
				if idB ~= idA then
					local dx = posA.X - posB.X
					local dz = posA.Y - posB.Y
					local distSq = dx * dx + dz * dz
					if distSq <= thresholdSq then
						table.insert(candidates, { id = idB, distSq = distSq })
					end
				end
			end
			table.sort(candidates, function(a, b)
				return a.distSq < b.distSq
			end)

			neighbors[idA] = neighbors[idA] or {}
			local existing = {}
			for _, n in ipairs(neighbors[idA]) do
				existing[n] = true
			end
			local linked = 0
			for _, cand in ipairs(candidates) do
				if linked >= MAX_SYNTH_BORDERS then
					break
				end
				local idB = cand.id
				if not existing[idB] then
					table.insert(neighbors[idA], idB)
					existing[idB] = true
					neighbors[idB] = neighbors[idB] or {}
					local back = false
					for _, n in ipairs(neighbors[idB]) do
						if n == idA then
							back = true
							break
						end
					end
					if not back then
						table.insert(neighbors[idB], idA)
					end
					edges += 1
					linked += 1
				end
			end
			if linked > 0 then
				patched += 1
			end
		end
	end
	if patched > 0 then
		print(
			string.format(
				"[AdjacencyGraph] geometry-linked %d registered province(s) absent from the baked table (%d edges) -- regenerate Data/ProvinceAdjacency to bake them",
				patched,
				edges
			)
		)
	end
end

function AdjacencyGraph.build()
	scanPositions()
	local total = registeredCount()

	local useBaked = false
	if mode ~= "legacy" then
		local ok, bakedCount, matchedCount = tryLoadBaked()
		if ok then
			local ratio = total > 0 and (matchedCount / total) or 0
			if mode == "baked" or ratio >= BAKED_MATCH_MIN then
				useBaked = true
				activeSource = "baked"
				if ratio < BAKED_MATCH_MIN then
					warn(string.format(
						"[AdjacencyGraph] baked table matches only %d/%d stamped provinces (%.0f%%) but mode=baked; using it anyway -- REGENERATE Data/ProvinceAdjacency",
						matchedCount, total, ratio * 100))
				elseif matchedCount < bakedCount then
					warn(string.format(
						"[AdjacencyGraph] baked table has %d entries, %d matched stamped provinces; %d unmatched (map may have changed)",
						bakedCount, matchedCount, bakedCount - matchedCount))
				end
			else
				warn(string.format(
					"[AdjacencyGraph] baked table matches only %d/%d stamped provinces (%.0f%% < %.0f%%) -- treating as STALE, falling back to legacy 300-stud graph. Regenerate Data/ProvinceAdjacency.",
					matchedCount, total, ratio * 100, BAKED_MATCH_MIN * 100))
			end
		elseif mode == "baked" then
			warn("[AdjacencyGraph] mode=baked but Data/ProvinceAdjacency is missing/empty -- falling back to legacy graph.")
		end
	end

	if not useBaked then
		activeSource = "legacy"
		computeNeighborsLegacy()
	else
		-- Legacy already links every node by geometry; in baked mode only patch the
		-- registered provinces the baked table doesn't cover.
		linkUnbakedRegistered()
	end

	local edgeCount = 0
	for _, list in neighbors do edgeCount += #list end
	local coastalCount = 0
	for _ in coastalSet do coastalCount += 1 end
	print(string.format("[ArtOfWar] adjacency graph: %d provinces, %d directed edges, %d coastal (source=%s)",
		total, edgeCount, coastalCount, activeSource))
end

function AdjacencyGraph.setMode(m)
	if m == "auto" or m == "baked" or m == "legacy" then mode = m end
end

function AdjacencyGraph.getSource()
	return activeSource
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

function AdjacencyGraph.isCoastal(provinceId)
	return coastalSet[provinceId] == true
end

function AdjacencyGraph.getShore(provinceId)
	return shoreByProvince[provinceId] or {}
end

-- BFS shortest path from start to goal through `passable(provinceId, prevProvinceId) -> boolean`.
-- If passable is nil, treat all provinces as passable. Returns { startId, ..., goalId } or nil.
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
		isCoastal = AdjacencyGraph.isCoastal,
		getShore = AdjacencyGraph.getShore,
		findPath = AdjacencyGraph.findPath,
		setMode = AdjacencyGraph.setMode,
		getSource = AdjacencyGraph.getSource,
	}
end

return AdjacencyGraph
