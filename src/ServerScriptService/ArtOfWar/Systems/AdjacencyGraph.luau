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
local bakedIds = {} -- set of province ids present in the baked table (whatever its land set)
local mode = "auto" -- "auto" | "baked" | "legacy"
local activeSource = "none"

-- Minimum fraction of baked province ids that must match the stamped id-set for
-- the baked table to be trusted in "auto" mode; below this we treat it as stale.
local BAKED_MATCH_MIN = 0.5

-- Fallback land<->sea transition cost for findPath when WorldConstants.SeaPathEmbarkPenalty is
-- absent. Keep in sync with that default. See WorldConstants for the land-preference rationale.
local DEFAULT_EMBARK_PENALTY = 10

local function scanPositions()
	positions = {}
	local map = workspace:FindFirstChild("ArtOfWarMap")
	local folder = map and map:FindFirstChild("Provinces")
	if not folder then
		return
	end
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
	for _ in positions do
		n += 1
	end
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
	for id in positions do
		table.insert(ids, id)
	end
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
	if not moduleScript then
		return false, 0, 0
	end
	local ok, baked = pcall(require, moduleScript)
	if not ok or type(baked) ~= "table" then
		return false, 0, 0
	end

	local bakedCount, matchedCount = 0, 0
	for _ in baked do
		bakedCount += 1
	end
	if bakedCount == 0 then
		return false, 0, 0
	end

	local nbrs, coastal, shore, ids = {}, {}, {}, {}
	for id in positions do
		nbrs[id] = {}
	end
	for id, entry in baked do
		ids[id] = true
		if positions[id] ~= nil and type(entry) == "table" then
			matchedCount += 1
			local list = nbrs[id]
			for _, n in ipairs(entry.land or {}) do
				-- Keep only neighbors that are actually registered this boot.
				if positions[n] ~= nil then
					table.insert(list, n)
				end
			end
			if entry.coastal == true then
				coastal[id] = true
			end
			if entry.shore then
				shore[id] = entry.shore
			end
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

-- C9 sea transport: load the tile-level sea bake (Data/SeaTileAdjacency) into the same
-- graph as negative node ids (sea part n -> node -n; see Shared/SeaNodes). MUST run AFTER
-- linkUnbakedRegistered -- sea ids are absent from the province bake, so loading them first
-- would let the linker geometry-bridge open water to random coastal provinces. Flag OFF (or
-- an empty bake) leaves the graph byte-identical to land-only.
local function loadSeaTiles()
	if not ctx.WorldConstants.EnableSeaTransport then
		return 0, 0
	end
	local dataFolder = ReplicatedStorage:FindFirstChild("ArtOfWar")
	dataFolder = dataFolder and dataFolder:FindFirstChild("Data")
	local moduleScript = dataFolder and dataFolder:FindFirstChild("SeaTileAdjacency")
	if not moduleScript then
		return 0, 0
	end
	local ok, baked = pcall(require, moduleScript)
	if not ok or type(baked) ~= "table" then
		return 0, 0
	end
	local tiles, edges = 0, 0
	for n, entry in baked do
		if type(n) == "number" and type(entry) == "table" then
			tiles += 1
			positions[-n] = Vector2.new(entry.x or 0, entry.z or 0)
		end
	end
	for n, entry in baked do
		if type(n) == "number" and type(entry) == "table" then
			local sid = -n
			local list = {}
			for _, m in ipairs(entry.sea or {}) do
				if positions[-m] ~= nil then
					list[#list + 1] = -m
					edges += 1
				end
			end
			for _, pid in ipairs(entry.shore or {}) do
				-- Shore edges are land<->sea and bidirectional; only link provinces that
				-- actually registered this boot.
				if type(pid) == "number" and pid > 0 and positions[pid] ~= nil then
					list[#list + 1] = pid
					edges += 1
					neighbors[pid] = neighbors[pid] or {}
					table.insert(neighbors[pid], sid)
					edges += 1
				end
			end
			neighbors[sid] = list
		end
	end
	return tiles, edges
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
					warn(
						string.format(
							"[AdjacencyGraph] baked table matches only %d/%d stamped provinces (%.0f%%) but mode=baked; using it anyway -- REGENERATE Data/ProvinceAdjacency",
							matchedCount,
							total,
							ratio * 100
						)
					)
				elseif matchedCount < bakedCount then
					warn(
						string.format(
							"[AdjacencyGraph] baked table has %d entries, %d matched stamped provinces; %d unmatched (map may have changed)",
							bakedCount,
							matchedCount,
							bakedCount - matchedCount
						)
					)
				end
			else
				warn(
					string.format(
						"[AdjacencyGraph] baked table matches only %d/%d stamped provinces (%.0f%% < %.0f%%) -- treating as STALE, falling back to legacy 300-stud graph. Regenerate Data/ProvinceAdjacency.",
						matchedCount,
						total,
						ratio * 100,
						BAKED_MATCH_MIN * 100
					)
				)
			end
		elseif mode == "baked" then
			warn(
				"[AdjacencyGraph] mode=baked but Data/ProvinceAdjacency is missing/empty -- falling back to legacy graph."
			)
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

	local seaTiles, seaEdges = loadSeaTiles()

	local edgeCount = 0
	for _, list in neighbors do
		edgeCount += #list
	end
	local coastalCount = 0
	for _ in coastalSet do
		coastalCount += 1
	end
	print(
		string.format(
			"[ArtOfWar] adjacency graph: %d provinces, %d directed edges, %d coastal, %d sea tiles (%d sea edges) (source=%s)",
			total,
			edgeCount,
			coastalCount,
			seaTiles,
			seaEdges,
			activeSource
		)
	)
end

function AdjacencyGraph.setMode(m)
	if m == "auto" or m == "baked" or m == "legacy" then
		mode = m
	end
end

function AdjacencyGraph.getSource()
	return activeSource
end

function AdjacencyGraph.getNeighbors(provinceId)
	return neighbors[provinceId] or {}
end

function AdjacencyGraph.areNeighbors(a, b)
	local list = neighbors[a]
	if not list then
		return false
	end
	for _, id in list do
		if id == b then
			return true
		end
	end
	return false
end

function AdjacencyGraph.distance(a, b)
	local pa = positions[a]
	local pb = positions[b]
	if not pa or not pb then
		return math.huge
	end
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

function AdjacencyGraph.isSeaNode(id)
	return type(id) == "number" and id < 0 and positions[id] ~= nil
end

function AdjacencyGraph.getShore(provinceId)
	return shoreByProvince[provinceId] or {}
end

-- Weighted shortest path from start to goal through `passable(provinceId, prevProvinceId) -> boolean`.
-- If passable is nil, every province is passable. Returns { startId, ..., goalId } or nil.
--
-- Cost model -- this is what makes troops prefer LAND over needless sea crossings: every step costs 1,
-- EXCEPT a land<->sea transition (embark or disembark) which costs `embarkPenalty`. A sea crossing thus
-- carries a ~2*penalty surcharge (embark + disembark), so a land route up to that many tiles longer than
-- a sea shortcut still wins -- an army marches around a bay or along a peninsula instead of embarking to
-- cut the corner. Sea is still chosen when it is the ONLY route (an island has no land path, so the sea
-- path is the sole finite-cost one) or when the land alternative is dramatically longer. Uniform-cost
-- (Dijkstra) search with a binary min-heap; BFS's hop-count objective was what sent armies across water
-- to save a hop even when a contiguous land route existed.
function AdjacencyGraph.findPath(startId, goalId, passable)
	if startId == goalId then
		return { startId }
	end
	if not neighbors[startId] or not neighbors[goalId] then
		return nil
	end

	local C = ctx and ctx.WorldConstants
	local embarkPenalty = (C and C.SeaPathEmbarkPenalty) or DEFAULT_EMBARK_PENALTY
	local function stepCost(fromId, toId)
		-- id < 0 is a sea node (Shared/SeaNodes); a land<->sea edge is the costly embark/disembark leg.
		if (fromId < 0) ~= (toId < 0) then
			return embarkPenalty
		end
		return 1
	end

	local dist = { [startId] = 0 }
	local cameFrom = { [startId] = startId } -- self-reference marks the start
	local heap = {} -- binary min-heap of { cost, provinceId }
	local function heapPush(cost, id)
		local i = #heap + 1
		heap[i] = { cost, id }
		while i > 1 do
			local parent = i // 2
			if heap[parent][1] <= heap[i][1] then
				break
			end
			heap[parent], heap[i] = heap[i], heap[parent]
			i = parent
		end
	end
	local function heapPop()
		local top = heap[1]
		local n = #heap
		heap[1] = heap[n]
		heap[n] = nil
		n -= 1
		local i = 1
		while true do
			local l, r, smallest = i * 2, i * 2 + 1, i
			if l <= n and heap[l][1] < heap[smallest][1] then
				smallest = l
			end
			if r <= n and heap[r][1] < heap[smallest][1] then
				smallest = r
			end
			if smallest == i then
				break
			end
			heap[i], heap[smallest] = heap[smallest], heap[i]
			i = smallest
		end
		return top
	end

	heapPush(0, startId)
	while #heap > 0 do
		local node = heapPop()
		local cost, current = node[1], node[2]
		if current == goalId then
			break
		end
		if cost <= (dist[current] or math.huge) then -- skip stale heap entries
			for _, neigh in ipairs(neighbors[current]) do
				if not passable or passable(neigh, current) then
					local nc = cost + stepCost(current, neigh)
					if nc < (dist[neigh] or math.huge) then
						dist[neigh] = nc
						cameFrom[neigh] = current
						heapPush(nc, neigh)
					end
				end
			end
		end
	end

	if not cameFrom[goalId] then
		return nil
	end
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
		isSeaNode = AdjacencyGraph.isSeaNode,
		getShore = AdjacencyGraph.getShore,
		findPath = AdjacencyGraph.findPath,
		setMode = AdjacencyGraph.setMode,
		getSource = AdjacencyGraph.getSource,
	}
end

return AdjacencyGraph
