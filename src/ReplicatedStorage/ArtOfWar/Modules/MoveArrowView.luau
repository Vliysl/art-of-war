-- MoveArrowView: the active on-map move arrow (Conquer-the-World style). For each of the local
-- player's armies with a server-side movement, draws a chunky dark ground arrow from the origin
-- province to the destination (plus faint queued legs) and a YELLOW fill plank that grows from the
-- origin toward the front as the (server-timed) move completes:
--   progress = (SimClock.now() - startedAt) / (completesAt - startedAt)
-- so it respects pause/speed. When full, the server completes the move and the army token hops to
-- the destination (ArmyView). Pure presentation: reads only replicated state, fails soft.
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local Modules = aow:WaitForChild("Modules")
local ClientStateCache = require(Modules:WaitForChild("ClientStateCache"))
local SimClock = require(Modules:WaitForChild("SimClock"))
local MoveArrowRender = require(Modules:WaitForChild("MoveArrowRender"))
local ProvincePositions = require(Modules:WaitForChild("ProvincePositions"))

local MoveArrowView = {}

local LIFT = MoveArrowRender.DEFAULT_LIFT or 0.22
local FILL_LIFT_EPS = 0.033  -- scaled for 2048 map (was 0.3)
local WIDTH = MoveArrowRender.DEFAULT_WIDTH or 0.77
local THICK = 0.05  -- was 0.45
local FILL_WIDTH = WIDTH * 0.72

local COLOR_SHAFT = Color3.fromRGB(34, 32, 40)   -- dark body / unfilled track
local COLOR_FILL = Color3.fromRGB(245, 205, 70)   -- yellow "charging" fill

local mapFolder, provincesFolder, arrowsFolder
local conn
local armiesSub, snapshotSub
local arrows = {}    -- [armyId] = { sig = string, statics = { Part, ... }, fill = Part }
local centerCache = {}
-- perf: index of armyIds that currently have an active server movement, maintained from the
-- "armies" replication deltas (the only place army.movement is created/cleared). The per-frame
-- loop iterates this tiny set instead of scanning ALL armies (allArmies()) at 60Hz. Ownership is
-- still re-checked per-frame against the live cache, so behaviour is identical to the full scan.
local movers = {}    -- [armyId] = true

local function ensureFolders()
	if arrowsFolder and arrowsFolder.Parent then return true end
	mapFolder = workspace:FindFirstChild("ArtOfWarMap")
	if not mapFolder then return false end
	provincesFolder = mapFolder:FindFirstChild("Provinces")
	if not provincesFolder then return false end
	arrowsFolder = mapFolder:FindFirstChild("MoveArrowsV2")
	if not arrowsFolder then
		arrowsFolder = Instance.new("Folder")
		arrowsFolder.Name = "MoveArrowsV2"
		arrowsFolder.Parent = mapFolder
	end
	return true
end

local function provinceCenter(pid)
	if pid == nil then return nil end
	local cached = centerCache[pid]
	if cached then return cached end
	-- Resolve by the stable part NAME (via ProvincePositions), never the stale province_id attribute,
	-- so the cached centre is correct from the first frame (no ocean drift after the boot re-stamp).
	local c = ProvincePositions.centerOf(pid, LIFT)
	if c then centerCache[pid] = c end
	return c
end

local function isLocallyOwned(ownerTag)
	local lp = Players.LocalPlayer
	if not ownerTag or not lp then return false end
	local country = ClientStateCache.getCountry(ownerTag)
	return country ~= nil and country.claimedBy == lp.UserId
end

local function routeSig(army)
	local mv = army.movement
	local s = tostring(mv.fromProvinceId) .. ">" .. tostring(mv.toProvinceId)
	local mp = army.movementPath
	if mp and mp.steps then
		for _, id in ipairs(mp.steps) do s = s .. "," .. tostring(id) end
	end
	return s
end

local function destroyArrow(armyId)
	local a = arrows[armyId]
	if not a then return end
	if a.fill and a.fill.Parent then a.fill:Destroy() end
	for _, p in ipairs(a.statics) do
		if p.Parent then p:Destroy() end
	end
	arrows[armyId] = nil
end

-- Dark smoothed banner over the whole route (current leg + any queued steps) ending in a solid
-- arrowhead at the final tile. Uses the SAME smoothed geometry as the hover preview
-- (MoveArrowRender.buildArrow: Chaikin + resample + overlapping two-layer ribbon) so the committed
-- arrow flows as one continuous banner instead of zig-zagging plank-to-plank between centroids.
local function buildStatics(army, fromPos, toPos)
	local statics = {}
	-- Ordered route: current leg (fromPos -> toPos), then any queued steps.
	local points = { fromPos, toPos }
	local mp = army.movementPath
	if mp and mp.steps then
		for _, id in ipairs(mp.steps) do
			local c = provinceCenter(id)
			if c then points[#points + 1] = c end
		end
	end

	for _, p in ipairs(MoveArrowRender.buildArrow(points, {
		color = COLOR_SHAFT,
		width = WIDTH,
		thickness = THICK,
		transparency = 0.05,
	})) do
		p.Parent = arrowsFolder
		statics[#statics + 1] = p
	end
	return statics
end

local function updateArrow(armyId, army, now)
	local mv = army.movement
	local fromPos = provinceCenter(mv.fromProvinceId)
	local toPos = provinceCenter(mv.toProvinceId)
	if not fromPos or not toPos then
		destroyArrow(armyId)
		return
	end

	local sig = routeSig(army)
	local a = arrows[armyId]
	if not a or a.sig ~= sig then
		destroyArrow(armyId)
		a = { sig = sig, statics = buildStatics(army, fromPos, toPos), fill = nil }
		arrows[armyId] = a
	end

	local progress = 0
	local started = mv.startedAt or 0
	local completes = mv.completesAt or 0
	if now and completes > started then
		progress = math.clamp((now - started) / (completes - started), 0, 1)
	end

	-- Yellow fill grows along the CURRENT leg only (origin -> front); queued legs stay dark.
	local front = fromPos:Lerp(toPos, progress)
	local fa = fromPos + Vector3.new(0, FILL_LIFT_EPS, 0)
	local fb = front + Vector3.new(0, FILL_LIFT_EPS, 0)
	local dist = (fb - fa).Magnitude
	if dist < 0.05 then
		if a.fill and a.fill.Parent then a.fill:Destroy() end
		a.fill = nil
		return
	end
	if a.fill and a.fill.Parent then
		a.fill.Size = Vector3.new(FILL_WIDTH, THICK, dist)
		a.fill.CFrame = CFrame.lookAt((fa + fb) * 0.5, fb)
	else
		a.fill = MoveArrowRender.plank(fa, fb, { color = COLOR_FILL, width = FILL_WIDTH, thickness = THICK, transparency = 0 })
		if a.fill then a.fill.Parent = arrowsFolder end
	end
end

-- perf: rebuild the movers index from scratch (used on full snapshots, which replace cache.armies
-- wholesale instead of firing per-army deltas).
local function rebuildMovers()
	table.clear(movers)
	for armyId, army in pairs(ClientStateCache.allArmies()) do
		if army.movement then movers[armyId] = true end
	end
end

-- perf: keep the movers index in lockstep with one army's replicated state. army.movement is only
-- ever created/cleared via an "armies" delta (or removal -> record == nil), so this is the complete
-- invalidation surface for the index.
local function syncMover(record, path)
	-- Army ids are string keys (e.g. "army_FRA_1"); use the raw match so the index key is byte-equal
	-- to the cache key (no numeric coercion).
	local armyId = path:match("^armies%.(.+)$")
	if armyId == nil then return end
	if type(record) == "table" and record.movement then
		movers[armyId] = true
	else
		movers[armyId] = nil
	end
end

function MoveArrowView.init()
	if conn then return end
	rebuildMovers()
	-- Maintain the movers index off the existing replication stream (no per-frame allArmies scan).
	armiesSub = ClientStateCache.onChangePrefix("armies", syncMover)
	snapshotSub = ClientStateCache.onChange("snapshot", rebuildMovers)
	conn = RunService.RenderStepped:Connect(function()
		-- perf: nothing to draw and nothing to tear down -> skip the whole frame.
		if next(movers) == nil and next(arrows) == nil then return end
		if not ensureFolders() then return end
		local now = SimClock.now()
		local active = {}
		-- Iterate only armies known to have a movement, not the entire army table.
		for armyId in pairs(movers) do
			local army = ClientStateCache.getArmy(armyId)
			if army and army.movement and isLocallyOwned(army.ownerTag) then
				active[armyId] = true
				updateArrow(armyId, army, now)
			end
		end
		for armyId in pairs(arrows) do
			if not active[armyId] then destroyArrow(armyId) end
		end
	end)
end

-- Optimistically drop an army's arrow immediately (e.g. on a cancel order) before the cleared
-- movement replicates back.
function MoveArrowView.clearArmy(armyId)
	destroyArrow(armyId)
end

function MoveArrowView.destroy()
	if conn then conn:Disconnect(); conn = nil end
	-- perf: drop the movers-index subscriptions so they stop firing after teardown.
	if armiesSub then armiesSub(); armiesSub = nil end
	if snapshotSub then snapshotSub(); snapshotSub = nil end
	table.clear(movers)
	for armyId in pairs(arrows) do destroyArrow(armyId) end
	if arrowsFolder and arrowsFolder.Parent then arrowsFolder:Destroy() end
	arrowsFolder = nil
	table.clear(centerCache)
end

return MoveArrowView
