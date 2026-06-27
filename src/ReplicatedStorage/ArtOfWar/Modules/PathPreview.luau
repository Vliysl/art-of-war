-- PathPreview: the move-route PREVIEW(s) shown while hovering a destination with armies selected.
--
-- Server-authoritative: the client no longer maintains its own adjacency graph or pathfinder (which
-- could diverge from the server's actual movement). It asks the server for the exact route each army
-- would take (RequestPreviewPath -> MovementSystem.computePreviewPath, the same findPath +
-- traversability beginMovePath uses) and just renders it. Province world positions are resolved by
-- the stable part NAME via ProvincePositions (never the runtime province_id attribute).
--
-- Multi-select: one preview "lane" per distinct ORIGIN province (so a multi-selection shows one route
-- per origin, matching how each committed move gets its own MoveArrowView arrow). Each lane has its own
-- single-flight guard + coalescing + watchdog, so a slow/hung reply for one lane can't wedge the others.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MoveArrowRender = require(script.Parent:WaitForChild("MoveArrowRender"))
local ProvincePositions = require(script.Parent:WaitForChild("ProvincePositions"))

local PathPreview = {}

local LINE_LIFT = 4
local ARROW_WIDTH = 9
local ARROW_THICK = 0.4
local PATH_COLOR_FRIENDLY = Color3.fromRGB(120, 220, 255)
local PATH_COLOR_HOSTILE = Color3.fromRGB(220, 80, 80)
local PATH_COLOR_BLOCKED = Color3.fromRGB(180, 90, 90)
local INVOKE_TIMEOUT = 5 -- seconds before a lane's in-flight guard is force-released
local MAX_LANES = 12 -- bound the number of simultaneous hover requests during a big multi-select

local mapFolder = nil
local previewFolder = nil
local remoteFn = nil
local lanes = {} -- [key] = { key, folder, lines, lastFrom, lastTo, inFlight, seq, pendingFrom, pendingTo }

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

local function getLane(key)
	local lane = lanes[key]
	if not lane then
		lane = { key = key, folder = nil, lines = {}, lastFrom = nil, lastTo = nil, inFlight = false, seq = 0 }
		lanes[key] = lane
	end
	return lane
end

local function destroyLane(key)
	local lane = lanes[key]
	if not lane then return end
	lane.seq += 1 -- invalidate any in-flight reply for this lane
	clearLaneLines(lane)
	if lane.folder and lane.folder.Parent then lane.folder:Destroy() end
	lanes[key] = nil
end

-- Run exactly one server request for a lane. lane.inFlight is held until this settles (reply OR
-- watchdog), so a hung reply can never permanently wedge the lane. Only the lane's latest seq draws.
local function dispatchLane(lane, fromId, toId)
	local remote = ensureRemote()
	if not remote then
		clearLaneLines(lane)
		return
	end
	lane.inFlight = true
	lane.seq += 1
	local seq = lane.seq
	local settled = false
	local function settle()
		if settled then return end -- reply and watchdog race; first wins
		settled = true
		lane.inFlight = false
		if lane.pendingTo then -- a newer target arrived while this was in flight
			local f, t = lane.pendingFrom, lane.pendingTo
			lane.pendingFrom, lane.pendingTo = nil, nil
			dispatchLane(lane, f, t)
		end
	end
	task.delay(INVOKE_TIMEOUT, function()
		if not settled then
			if seq == lane.seq then lane.lastFrom, lane.lastTo = nil, nil end
			settle()
		end
	end)
	task.spawn(function()
		local ok, res = pcall(function()
			return remote:InvokeServer(fromId, toId)
		end)
		if seq == lane.seq then -- not superseded by a newer hover / clear for this lane
			if ok and type(res) == "table" and res.ok == true and res.nodes and #res.nodes >= 2 then
				local color = res.blocked and PATH_COLOR_BLOCKED
					or (res.hostile and PATH_COLOR_HOSTILE or PATH_COLOR_FRIENDLY)
				renderLane(lane, res.nodes, color)
			else
				clearLaneLines(lane)
				lane.lastFrom, lane.lastTo = nil, nil -- let the next hover retry a failed target
			end
		end
		settle()
	end)
end

local function showLane(key, fromId, toId)
	local lane = getLane(key)
	if not fromId or not toId or fromId == toId then
		lane.seq += 1
		lane.lastFrom, lane.lastTo, lane.pendingFrom, lane.pendingTo = nil, nil, nil, nil
		clearLaneLines(lane)
		return
	end
	if fromId == lane.lastFrom and toId == lane.lastTo then
		return -- already showing / requesting this exact route
	end
	lane.lastFrom, lane.lastTo = fromId, toId
	if lane.inFlight then
		lane.pendingFrom, lane.pendingTo = fromId, toId
		return
	end
	dispatchLane(lane, fromId, toId)
end

function PathPreview.init()
	ensurePreviewFolder()
end

-- Show one preview per request to the hovered destination. requests = { {id=key, from=provinceId}, ... }
-- (callers pass one entry per distinct origin province). Lanes not present in `requests` are dropped.
function PathPreview.showMany(requests, toProvinceId)
	requests = requests or {}
	local active = {}
	local n = 0
	for _, r in ipairs(requests) do
		if n >= MAX_LANES then break end
		if r.id ~= nil and r.from ~= nil then
			n += 1
			active[r.id] = true
			showLane(r.id, r.from, toProvinceId)
		end
	end
	for key in pairs(lanes) do
		if not active[key] then destroyLane(key) end
	end
end

-- Back-compat single-route API (used by the legacy UIController). ClientStateCache/ownerTag are
-- accepted for call-site compatibility but unused -- the server resolves owner/traversability.
function PathPreview.show(fromProvinceId, toProvinceId, _ClientStateCache, _ownerTag)
	PathPreview.showMany({ { id = "_single", from = fromProvinceId } }, toProvinceId)
end

function PathPreview.clear()
	for key in pairs(lanes) do
		destroyLane(key)
	end
end

function PathPreview.destroy()
	PathPreview.clear()
	if previewFolder and previewFolder.Parent then previewFolder:Destroy() end
	previewFolder = nil
	remoteFn = nil
end

return PathPreview
