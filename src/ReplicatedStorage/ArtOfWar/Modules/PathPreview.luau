-- PathPreview: the move-route PREVIEW shown while hovering a destination with an army selected.
--
-- Server-authoritative: the client no longer maintains its own adjacency graph or pathfinder (which
-- could diverge from the server's actual movement). It asks the server for the exact route the army
-- would take (RequestPreviewPath -> MovementSystem.computePreviewPath, the same findPath +
-- traversability beginMovePath uses) and just renders it. Province world positions are resolved by
-- the stable part NAME via ProvincePositions (never the runtime province_id attribute).
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

local mapFolder = nil
local previewFolder = nil
local activeLines = {}
local requestSeq = 0 -- bumped on every dispatch/clear(); only the latest hover's response is drawn
local remoteFn = nil

-- Request throttling. Sweeping the cursor fires show() on every hovered-province change (~30/s);
-- each used to spawn its own blocking InvokeServer with no guard, so a slow/hung reply could stack
-- requests and wedge the preview until the unit was reselected. Now at most ONE invoke is in flight;
-- newer targets coalesce into pending and fire when it returns, and a watchdog releases the guard if
-- the server never replies.
local inFlight = false        -- true while an InvokeServer is outstanding
local pendingFrom, pendingTo  -- latest target requested while a call was in flight (coalesced)
local lastFrom, lastTo        -- target currently shown / requested (dedupe identical re-requests)
local INVOKE_TIMEOUT = 5      -- seconds before the in-flight guard is force-released

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

local function clearLines()
	for _, line in ipairs(activeLines) do
		if line.Parent then line:Destroy() end
	end
	activeLines = {}
end

-- Render a route (list of province ids) as the chunky ground arrow. Positions come from
-- ProvincePositions (part-name keyed), so they are correct from the first frame.
local function renderPath(nodes, color)
	clearLines()
	if not nodes or #nodes < 2 then return end
	if not previewFolder or not previewFolder.Parent then
		if not ensurePreviewFolder() then return end
	end
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
		part.Parent = previewFolder
		activeLines[#activeLines + 1] = part
	end
end

function PathPreview.init()
	ensurePreviewFolder()
end

local dispatch -- forward declaration (flushPending calls dispatch, dispatch calls flushPending)

-- If a target was requested while a call was in flight, fire it now that the guard is free.
local function flushPending()
	if inFlight then return end
	local f, t = pendingFrom, pendingTo
	pendingFrom, pendingTo = nil, nil
	if f and t then dispatch(f, t) end
end

-- Run exactly one server request. inFlight is held until this call settles (reply OR watchdog),
-- so it can never permanently wedge. Only the latest (requestSeq) response is allowed to draw.
function dispatch(fromProvinceId, toProvinceId)
	local remote = ensureRemote()
	if not remote then
		clearLines()
		return
	end
	inFlight = true
	requestSeq += 1
	local seq = requestSeq
	local settled = false
	local function settle()
		if settled then return end -- the reply and the watchdog race; first one wins
		settled = true
		inFlight = false
		flushPending()
	end
	-- Watchdog: if the invoke never returns, release the guard (and let a re-hover retry) so the
	-- preview can't get stuck. A late reply is dropped by the seq check below.
	task.delay(INVOKE_TIMEOUT, function()
		if not settled then
			if seq == requestSeq then lastFrom, lastTo = nil, nil end
			settle()
		end
	end)
	task.spawn(function()
		local ok, res = pcall(function()
			return remote:InvokeServer(fromProvinceId, toProvinceId)
		end)
		if seq == requestSeq then -- not superseded by a newer hover / clear
			if ok and type(res) == "table" and res.ok == true and res.nodes and #res.nodes >= 2 then
				local color = res.blocked and PATH_COLOR_BLOCKED
					or (res.hostile and PATH_COLOR_HOSTILE or PATH_COLOR_FRIENDLY)
				renderPath(res.nodes, color)
			else
				clearLines()
				lastFrom, lastTo = nil, nil -- let the next hover retry a failed target
			end
		end
		settle()
	end)
end

-- Ask the SERVER for the route from the selected army's province to the hovered province, and draw
-- it. Identical consecutive targets are deduped; while a request is in flight, newer targets coalesce
-- into a single pending one (no request pile-up). Only the most recent response is rendered.
-- ClientStateCache/ownerTag params are accepted for call-site compatibility but unused -- the server
-- resolves the owner and traversability authoritatively.
function PathPreview.show(fromProvinceId, toProvinceId, _ClientStateCache, _ownerTag)
	if not fromProvinceId or not toProvinceId or fromProvinceId == toProvinceId then
		PathPreview.clear()
		return
	end
	if fromProvinceId == lastFrom and toProvinceId == lastTo then
		return -- already showing / requesting this exact route
	end
	lastFrom, lastTo = fromProvinceId, toProvinceId
	if inFlight then
		pendingFrom, pendingTo = fromProvinceId, toProvinceId
		return
	end
	dispatch(fromProvinceId, toProvinceId)
end

function PathPreview.clear()
	requestSeq += 1 -- invalidate any in-flight request so its late response doesn't draw
	lastFrom, lastTo = nil, nil
	pendingFrom, pendingTo = nil, nil
	clearLines()
end

function PathPreview.destroy()
	requestSeq += 1
	inFlight = false
	lastFrom, lastTo = nil, nil
	pendingFrom, pendingTo = nil, nil
	clearLines()
	if previewFolder and previewFolder.Parent then previewFolder:Destroy() end
	previewFolder = nil
	remoteFn = nil
end

return PathPreview
