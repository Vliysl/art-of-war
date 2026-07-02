-- PathPreview: the move-route PREVIEW(s) shown while hovering a destination with armies selected.
--
-- Server-authoritative: the client no longer maintains its own adjacency graph or pathfinder (which
-- could diverge from the server's actual movement). It asks the server for the exact route each army
-- would take (RequestPreviewPath -> MovementSystem.computePreviewPath, the same findPath +
-- traversability beginMovePath uses) and just renders it. Province world positions are resolved by
-- the stable part NAME via ProvincePositions (never the runtime province_id attribute).
--
-- DECLARATIVE RECONCILER (mirrors MoveArrowView): the desired state is data -- desiredTo (the last
-- valid hovered destination) plus the live army selection. A single idempotent reconcile() is the ONLY
-- thing that creates/destroys lanes and dispatches route requests; it is safe to call from the hover
-- entry points, the selection hook, every replicated army delta, and a slow Heartbeat backstop. Every
-- async continuation is guarded by an identity + generation check (lanes[key] == lane and lane.gen ==
-- gen), so a torn-down lane can never render or resurrect itself -- which is what makes orphaned
-- previews structurally impossible. Multi-select shows one "lane" per distinct ORIGIN province. A
-- selected unit that is already MARCHING previews a RE-ROUTE to the hovered tile (from its current
-- province) exactly like an idle unit, so the cyan preview tracks the cursor; the unit's committed
-- order stays shown by MoveArrowView's arrow.
--
-- Hover policy: a transient hover over no province (border / sea tile / unmapped wilderness) does NOT
-- clear -- the last valid route is kept until a new valid target, a deselect, or a committed move. A
-- short-TTL route cache makes re-hovering a recent destination instant (no server round-trip).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MoveArrowRender = require(script.Parent:WaitForChild("MoveArrowRender"))
local ProvincePositions = require(script.Parent:WaitForChild("ProvincePositions"))
local ClientStateCache = require(script.Parent:WaitForChild("ClientStateCache"))
local ArmyView = require(script.Parent:WaitForChild("ArmyView"))
local RunService = game:GetService("RunService")

local PathPreview = {}

local LINE_LIFT = 0.44   -- scaled for 2048 map (was 4)
local ARROW_WIDTH = 0.99 -- was 9
local ARROW_THICK = 0.044 -- was 0.4
local PATH_COLOR_FRIENDLY = Color3.fromRGB(120, 220, 255)
local PATH_COLOR_HOSTILE = Color3.fromRGB(220, 80, 80)
local PATH_COLOR_BLOCKED = Color3.fromRGB(180, 90, 90)
local INVOKE_TIMEOUT = 5 -- seconds before a lane's in-flight guard is force-released
local MAX_LANES = 12 -- bound the number of simultaneous hover requests during a big multi-select
local RECONCILE_INTERVAL = 0.5 -- backstop only; selection/army-delta events carry the latency-sensitive cases
local ROUTE_TTL = 4 -- seconds a cached (from,to) route stays fresh (instant re-hover, no round-trip)
local ROUTE_CACHE_MAX = 64 -- hard cap; oldest-first eviction keeps long hover sweeps from growing the table unbounded

local mapFolder = nil
local previewFolder = nil
local remoteFn = nil
-- [key] = { key, folder, lines, shownFrom, shownTo, reqFrom, reqTo, inFlight, gen }
-- key = origin province id. shownFrom/shownTo = what is actually rendered. reqFrom/reqTo = the last
-- target dispatched (success OR failure), so a reconcile triggered by an unrelated army delta does not
-- re-fire the same request. gen = the single cancel token bumped on every dispatch/cache-hit/destroy.
local lanes = {}
-- desiredTo is the province currently being hover-previewed (set by showMany, cleared by clear). The
-- desired ORIGINS are derived live from the selection inside reconcile(), so disband / move / deselect
-- self-heal automatically with no missable teardown event.
local desiredTo = nil
local reconcileConn = nil
local selectionConn = nil
local armiesSub = nil
local snapshotSub = nil
local reconcileAccum = 0
local routeCache = {} -- [cacheKey] = { nodes, color, expires, at }
local routeCacheCount = 0

local function ensurePreviewFolder()
	mapFolder = workspace:FindFirstChild("ArtOfWarMap")
	if not mapFolder then return nil end
	previewFolder = mapFolder:FindFirstChild("PathPreview")
	if not previewFolder then
		previewFolder = Instance.new("Folder")
		previewFolder.Name = "PathPreview"
		previewFolder.Parent = mapFolder
	end
	return previewFolder
end

local function ensureRemote()
	if remoteFn and remoteFn.Parent then return remoteFn end
	local aow = ReplicatedStorage:FindFirstChild("ArtOfWar")
	local remotes = aow and aow:FindFirstChild("Remotes")
	remoteFn = remotes and remotes:FindFirstChild("RequestPreviewPath")
	return remoteFn
end

local function laneFolder(lane)
	if not previewFolder or not previewFolder.Parent then
		if not ensurePreviewFolder() then return nil end
	end
	if lane.folder and lane.folder.Parent then return lane.folder end
	local f = Instance.new("Folder")
	f.Name = "lane_" .. tostring(lane.key)
	f.Parent = previewFolder
	lane.folder = f
	return f
end

local function clearLaneLines(lane)
	for _, part in ipairs(lane.lines) do
		if part.Parent then part:Destroy() end
	end
	lane.lines = {}
end

-- Color from the server reply (friendly / hostile / blocked). Shared by the live and cache render paths.
local function colorFor(res)
	if res.blocked then return PATH_COLOR_BLOCKED end
	if res.hostile then return PATH_COLOR_HOSTILE end
	return PATH_COLOR_FRIENDLY
end

-- Render a route (list of province ids) as the chunky ground arrow into this lane's folder. Positions
-- come from ProvincePositions (part-name keyed), so they are correct from the first frame.
local function renderLane(lane, nodes, color)
	clearLaneLines(lane)
	if not nodes or #nodes < 2 then return end
	local folder = laneFolder(lane)
	if not folder then return end
	local pts = {}
	for _, pid in ipairs(nodes) do
		local pos = ProvincePositions.centerOf(pid, LINE_LIFT)
		if pos then pts[#pts + 1] = pos end
	end
	if #pts < 2 then return end
	-- Seam-unfold so a route crossing the ±MapHalfWidth wrap draws one short ribbon over the wrap
	-- clones instead of streaking the long way back across the map.
	pts = MoveArrowRender.unfoldPoints(pts)
	local parts = MoveArrowRender.buildArrow(pts, {
		color = color,
		width = ARROW_WIDTH,
		thickness = ARROW_THICK,
		transparency = 0,
	})
	for _, part in ipairs(parts) do
		part.Name = "PathArrow"
		part.Parent = folder
		lane.lines[#lane.lines + 1] = part
	end
end

local function cacheKey(fromId, toId)
	return tostring(fromId) .. ">" .. tostring(toId)
end

local function cacheGet(fromId, toId)
	local k = cacheKey(fromId, toId)
	local entry = routeCache[k]
	if not entry then return nil end
	if os.clock() >= entry.expires then
		routeCache[k] = nil
		routeCacheCount -= 1
		return nil
	end
	return entry
end

local function cachePut(fromId, toId, nodes, color)
	local k = cacheKey(fromId, toId)
	if routeCache[k] == nil then
		if routeCacheCount >= ROUTE_CACHE_MAX then
			-- Evict the oldest entry (smallest insert time). Linear scan is fine at 64 entries.
			local oldestKey, oldestAt
			for key, entry in pairs(routeCache) do
				if oldestAt == nil or entry.at < oldestAt then
					oldestKey, oldestAt = key, entry.at
				end
			end
			if oldestKey then
				routeCache[oldestKey] = nil
				routeCacheCount -= 1
			end
		end
		routeCacheCount += 1
	end
	local now = os.clock()
	routeCache[k] = { nodes = nodes, color = color, expires = now + ROUTE_TTL, at = now }
end

-- Drop entries past their TTL. Called from clear() (end of a hover session) so dead routes do not
-- accumulate between sessions -- cacheGet only evicts the specific key it is asked for.
local function cachePurgeExpired()
	local now = os.clock()
	for k, entry in pairs(routeCache) do
		if now >= entry.expires then
			routeCache[k] = nil
			routeCacheCount -= 1
		end
	end
end

local function getLane(key)
	local lane = lanes[key]
	if not lane then
		lane = {
			key = key, folder = nil, lines = {},
			shownFrom = nil, shownTo = nil, reqFrom = nil, reqTo = nil,
			inFlight = false, gen = 0,
		}
		lanes[key] = lane
	end
	return lane
end

-- Fully neutralize a lane. Bumping gen invalidates any in-flight reply (its identity+gen guard fails),
-- and clearing req/shown means a later reconcile re-evaluates from scratch. Because the lane is removed
-- from `lanes`, no continuation can ever touch it again -> no orphan is possible.
local function destroyLane(key)
	local lane = lanes[key]
	if not lane then return end
	lane.gen += 1
	lane.inFlight = false
	lane.shownFrom, lane.shownTo = nil, nil
	lane.reqFrom, lane.reqTo = nil, nil
	clearLaneLines(lane)
	if lane.folder and lane.folder.Parent then lane.folder:Destroy() end
	lanes[key] = nil
end

-- Run one server request for a lane. gen is the cancel token: the watchdog and the reply BOTH re-check
-- that this lane is still the live one (lanes[key] == lane) and still this generation (lane.gen == gen)
-- before touching anything. There is no settle()/pending re-dispatch path, so a reply can never
-- resurrect a torn-down lane.
local function dispatchLane(lane, fromId, toId)
	local remote = ensureRemote()
	if not remote then return end
	lane.gen += 1
	local gen, key = lane.gen, lane.key
	lane.inFlight = true
	lane.reqFrom, lane.reqTo = fromId, toId
	task.delay(INVOKE_TIMEOUT, function()
		if lanes[key] == lane and lane.gen == gen then
			lane.inFlight = false -- release the guard; a hung reply will be dropped by its gen check
		end
	end)
	task.spawn(function()
		local ok, res = pcall(function()
			return remote:InvokeServer(fromId, toId)
		end)
		if lanes[key] ~= lane or lane.gen ~= gen then return end -- superseded or torn down: drop silently
		lane.inFlight = false
		if ok and type(res) == "table" and res.ok == true and res.nodes and #res.nodes >= 2 then
			local color = colorFor(res)
			renderLane(lane, res.nodes, color)
			lane.shownFrom, lane.shownTo = fromId, toId
			cachePut(fromId, toId, res.nodes, color)
		else
			-- failure (invoke error / malformed or rejected reply): clear the lane instead of leaving the
			-- PREVIOUS route on screen as a ghost arrow pointing at a stale target. reqFrom/reqTo stay set
			-- so a reconcile from an unrelated army delta does not re-spam this dead target. (Unreachable-
			-- but-valid targets are NOT this path -- the server answers ok=true + blocked, red stub.)
			clearLaneLines(lane)
			lane.shownFrom, lane.shownTo = nil, nil
		end
	end)
end

-- Ensure this lane is showing the route fromId->toId. No-op if it is already shown or already the
-- in-flight/last-attempted target. Cache hits render synchronously (instant re-hover, no round-trip).
local function ensureLane(key, fromId, toId)
	if not fromId or not toId or fromId == toId then return end
	local lane = getLane(key)
	if lane.shownFrom == fromId and lane.shownTo == toId then return end
	if lane.reqFrom == fromId and lane.reqTo == toId then return end
	local hit = cacheGet(fromId, toId)
	if hit then
		lane.gen += 1 -- supersede any in-flight reply for an older target
		lane.inFlight = false
		lane.reqFrom, lane.reqTo = fromId, toId
		renderLane(lane, hit.nodes, hit.color)
		lane.shownFrom, lane.shownTo = fromId, toId
		return
	end
	dispatchLane(lane, fromId, toId)
end

-- The single mutation entry point. Desired lanes = one HOVER lane per distinct ORIGIN province of a
-- live selected army (idle OR marching), routed to desiredTo. A marching unit therefore previews a
-- RE-ROUTE to the hovered tile from its current province, exactly like an idle unit, and the preview
-- tracks the cursor; its committed order keeps showing via MoveArrowView. Drops every lane not desired
-- and ensures every lane that is. Idempotent; safe to call from any event. A disbanded army
-- (getArmy == nil) contributes nothing, so its lane is dropped the same frame.
local function reconcile()
	if desiredTo == nil and next(lanes) == nil then return end
	local valid = {}
	local n = 0
	if desiredTo ~= nil then
		local sel = (ArmyView.getSelectedArmyIds and ArmyView.getSelectedArmyIds()) or {}
		for _, armyId in ipairs(sel) do
			if n >= MAX_LANES then break end
			local army = ClientStateCache.getArmy(armyId)
			if army and army.provinceId ~= nil and army.provinceId ~= desiredTo and not valid[army.provinceId] then
				valid[army.provinceId] = true
				n += 1
			end
		end
	end
	for key in pairs(lanes) do
		if not valid[key] then destroyLane(key) end
	end
	for key in pairs(valid) do
		ensureLane(key, key, desiredTo)
	end
end

function PathPreview.init()
	ensurePreviewFolder()
	if not reconcileConn then
		reconcileConn = RunService.Heartbeat:Connect(function(dt)
			reconcileAccum += dt
			if reconcileAccum < RECONCILE_INTERVAL then return end
			reconcileAccum = 0
			reconcile()
		end)
	end
	-- State-driven teardown (mirrors MoveArrowView): selection changes and replicated army deltas
	-- (disband fires armies.<id> = nil; a move sets army.movement) reconcile immediately, so a stale
	-- preview is gone within a frame rather than up to one backstop interval later.
	if not selectionConn and ArmyView.onArmySelected then
		selectionConn = ArmyView.onArmySelected(function() reconcile() end)
	end
	if not armiesSub and ClientStateCache.onChangePrefix then
		armiesSub = ClientStateCache.onChangePrefix("armies", function() reconcile() end)
	end
	if not snapshotSub and ClientStateCache.onChange then
		snapshotSub = ClientStateCache.onChange("snapshot", function() reconcile() end)
	end
end

-- Show one preview per request to the hovered destination. requests = { {id=key, from=provinceId}, ... }
-- is accepted for call-site compatibility, but reconcile() authoritatively recomputes the origins from
-- the live selection -- that is what keeps the preview correct through disband/move/deselect.
function PathPreview.showMany(_requests, toProvinceId)
	desiredTo = toProvinceId
	reconcile()
end

-- Back-compat single-route API (used by the legacy UIController). ClientStateCache/ownerTag are
-- accepted for call-site compatibility but unused -- the server resolves owner/traversability.
function PathPreview.show(fromProvinceId, toProvinceId, _ClientStateCache, _ownerTag)
	PathPreview.showMany({ { id = fromProvinceId, from = fromProvinceId } }, toProvinceId)
end

function PathPreview.clear()
	desiredTo = nil
	cachePurgeExpired()
	reconcile()
end

function PathPreview.destroy()
	if reconcileConn then reconcileConn:Disconnect(); reconcileConn = nil end
	if selectionConn then selectionConn(); selectionConn = nil end
	if armiesSub then armiesSub(); armiesSub = nil end
	if snapshotSub then snapshotSub(); snapshotSub = nil end
	PathPreview.clear()
	if previewFolder and previewFolder.Parent then previewFolder:Destroy() end
	previewFolder = nil
	remoteFn = nil
	table.clear(routeCache)
	routeCacheCount = 0
end

return PathPreview
