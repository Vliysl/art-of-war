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
local requestSeq = 0 -- bumped on every show()/clear(); only the latest hover's response is drawn
local remoteFn = nil

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

-- Ask the SERVER for the route from the selected army's province to the hovered province, and draw
-- it. Non-blocking: the request runs in a task and only the most recent hover's response is rendered
-- (older responses are dropped via requestSeq), so fast hovering never paints a stale path.
-- ClientStateCache/ownerTag params are accepted for call-site compatibility but unused -- the server
-- resolves the owner and traversability authoritatively.
function PathPreview.show(fromProvinceId, toProvinceId, _ClientStateCache, _ownerTag)
	requestSeq += 1
	local seq = requestSeq
	if not fromProvinceId or not toProvinceId or fromProvinceId == toProvinceId then
		clearLines()
		return
	end
	local remote = ensureRemote()
	if not remote then
		clearLines()
		return
	end
	task.spawn(function()
		local ok, res = pcall(function()
			return remote:InvokeServer(fromProvinceId, toProvinceId)
		end)
		if seq ~= requestSeq then return end -- a newer hover superseded this request
		if not ok or type(res) ~= "table" or res.ok ~= true or not res.nodes or #res.nodes < 2 then
			clearLines()
			return
		end
		local color = res.blocked and PATH_COLOR_BLOCKED
			or (res.hostile and PATH_COLOR_HOSTILE or PATH_COLOR_FRIENDLY)
		renderPath(res.nodes, color)
	end)
end

function PathPreview.clear()
	requestSeq += 1 -- invalidate any in-flight request so its late response doesn't draw
	clearLines()
end

function PathPreview.destroy()
	requestSeq += 1
	clearLines()
	if previewFolder and previewFolder.Parent then previewFolder:Destroy() end
	previewFolder = nil
	remoteFn = nil
end

return PathPreview
