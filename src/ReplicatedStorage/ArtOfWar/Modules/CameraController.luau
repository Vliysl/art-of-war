local CameraController = {}

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")

local WorldConstants = require(ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Shared"):WaitForChild("WorldConstants"))
local InputGuard = require(ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Modules"):WaitForChild("InputGuard"))
local Platform = require(ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Modules"):WaitForChild("Platform"))

local function isMouseOverInputSink()
	local player = Players.LocalPlayer
	if not player then return false end
	local pg = player:FindFirstChildOfClass("PlayerGui")
	if not pg then return false end
	local mp = UserInputService:GetMouseLocation()
	local inset = GuiService:GetGuiInset()
	local x, y = mp.X, mp.Y - inset.Y
	local objects = pg:GetGuiObjectsAtPosition(x, y)
	for _, obj in objects do
		local cursor = obj
		while cursor and cursor:IsA("GuiObject") do
			local sink = cursor:GetAttribute("AoWInputSink")
			if sink == true then return true end
			if sink == false then break end
			if cursor:IsA("ScrollingFrame") then return true end
			cursor = cursor.Parent
		end
	end
	return false
end

local function inputBlocked()
	return InputGuard.isCameraBlocked() or isMouseOverInputSink()
end

local camera = workspace.CurrentCamera

local Config = {
	MAP_WIDTH        = WorldConstants.MapWidth,
	MAP_DEPTH        = WorldConstants.MapDepth,
	MAP_CENTER_X     = WorldConstants.MapCenterX,
	MAP_CENTER_Z     = WorldConstants.MapCenterZ,
	MAP_Y            = 0,
	MIN_ZOOM         = 20,    -- lowered so the camera can push in close for inspection (was 44)
	MAX_ZOOM         = 700,   -- capped so the camera can't pull back past the ~2048-wide map (was 2400)
	DEFAULT_ZOOM     = 500,   -- starting / wide view (was 990)
	ZOOM_SPEED       = 0.14,
	ZOOM_SMOOTHING   = 9,
	KEY_PAN_SPEED    = 770,   -- was 7000
	EDGE_PAN_SPEED   = 770,   -- was 7000
	EDGE_MARGIN      = 8,
	DRAG_SENSITIVITY = 1.0,
	PAN_SMOOTHING    = 11,
	UP_VECTOR        = Vector3.new(0, 0, 1),
	PAN_KEYS = {
		[Enum.KeyCode.W]     = Vector3.new(0, 0,  1),
		[Enum.KeyCode.S]     = Vector3.new(0, 0, -1),
		[Enum.KeyCode.A]     = Vector3.new( 1, 0, 0),
		[Enum.KeyCode.D]     = Vector3.new(-1, 0, 0),
		[Enum.KeyCode.Up]    = Vector3.new(0, 0,  1),
		[Enum.KeyCode.Down]  = Vector3.new(0, 0, -1),
		[Enum.KeyCode.Left]  = Vector3.new( 1, 0, 0),
		[Enum.KeyCode.Right] = Vector3.new(-1, 0, 0),
	},
}
-- <1 damps pinch-zoom; with the incremental pinch math (TouchPinch handler) this fixes the over-sensitive pinch.
Config.PINCH_SENSITIVITY = 0.6

local targetPos = Vector3.new(Config.MAP_CENTER_X, Config.MAP_Y, Config.MAP_CENTER_Z)
local targetZoom = Config.DEFAULT_ZOOM
local currentPos = targetPos
local currentZoom = targetZoom
local isDragging = false
local dragStart = Vector2.new(0, 0)
local dragCamStart = targetPos
local keysDown = {}
local connections = {}
local initialized = false
local active = false
local dragInverted = true -- "drag the map" feel (player-toggleable via the InvertDrag setting); default on
local lastPinchScale = 1

-- Drag-invert preference (LocalPlayer attribute "InvertDrag"; nil/true = inverted). Cached + live-updated.
task.spawn(function()
	local lp = Players.LocalPlayer
	while not lp do
		task.wait()
		lp = Players.LocalPlayer
	end
	local function refresh()
		dragInverted = lp:GetAttribute("InvertDrag") ~= false
	end
	refresh()
	lp:GetAttributeChangedSignal("InvertDrag"):Connect(refresh)
end)

local function wrapX(x)
	local halfW = Config.MAP_WIDTH / 2
	local cx = Config.MAP_CENTER_X
	local relX = x - cx
	relX = ((relX + halfW) % Config.MAP_WIDTH) - halfW
	return cx + relX
end

local function clampZ(z)
	local halfD = Config.MAP_DEPTH / 2
	local cz = Config.MAP_CENTER_Z
	return math.clamp(z, cz - halfD, cz + halfD)
end

local function speedScale()
	return currentZoom / Config.DEFAULT_ZOOM
end

local function updateCamera(dt)
	local panLerp = isDragging and 1 or math.min(1, dt * Config.PAN_SMOOTHING)
	local zoomLerp = math.min(1, dt * Config.ZOOM_SMOOTHING)
	local dx = targetPos.X - currentPos.X
	local halfW = Config.MAP_WIDTH / 2
	if dx > halfW then dx -= Config.MAP_WIDTH
	elseif dx < -halfW then dx += Config.MAP_WIDTH end
	local newX = wrapX(currentPos.X + dx * panLerp)
	local newZ = currentPos.Z + (targetPos.Z - currentPos.Z) * panLerp
	currentPos = Vector3.new(newX, Config.MAP_Y, newZ)
	currentZoom = currentZoom + (targetZoom - currentZoom) * zoomLerp

	local tinyOffset = 0.0001 * currentZoom
	local cameraPos = Vector3.new(
		currentPos.X,
		Config.MAP_Y + currentZoom,
		currentPos.Z + tinyOffset
	)
	local lookAt = Vector3.new(currentPos.X, Config.MAP_Y, currentPos.Z)

	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	if camera.CameraSubject ~= nil then
		camera.CameraSubject = nil
	end
	camera.CFrame = CFrame.lookAt(cameraPos, lookAt, Config.UP_VECTOR)

	local zoomT = math.clamp((currentZoom - Config.MIN_ZOOM) / (Config.MAX_ZOOM - Config.MIN_ZOOM), 0, 1)
	camera.FieldOfView = 55 + zoomT * 20
end

local function handleKeyPan(dt)
	local panDir = Vector3.zero
	for key, dir in Config.PAN_KEYS do
		if keysDown[key] then panDir += dir end
	end
	if panDir.Magnitude > 0 then
		local speed = Config.KEY_PAN_SPEED * dt * speedScale()
		local delta = panDir.Unit * speed
		targetPos = Vector3.new(wrapX(targetPos.X + delta.X), Config.MAP_Y, clampZ(targetPos.Z + delta.Z))
	end
end

local function handleEdgePan(dt)
	if isDragging then return end
	if Platform.isTouch then return end  -- no mouse on touch devices
	local mp = UserInputService:GetMouseLocation()
	local vp = camera.ViewportSize
	local margin = Config.EDGE_MARGIN
	local panDir = Vector3.zero
	if mp.X < margin then panDir += Vector3.new(1, 0, 0)
	elseif mp.X > vp.X - margin then panDir += Vector3.new(-1, 0, 0) end
	if mp.Y < margin then panDir += Vector3.new(0, 0, 1)
	elseif mp.Y > vp.Y - margin then panDir += Vector3.new(0, 0, -1) end
	if panDir.Magnitude > 0 then
		local speed = Config.EDGE_PAN_SPEED * dt * speedScale()
		local delta = panDir.Unit * speed
		targetPos = Vector3.new(wrapX(targetPos.X + delta.X), Config.MAP_Y, clampZ(targetPos.Z + delta.Z))
	end
end

local function wireConnections()
	connections[#connections + 1] = UserInputService.InputBegan:Connect(function(input, processed)
		if not active then return end
		if processed then return end
		if input.UserInputType == Enum.UserInputType.MouseButton3 then
			if inputBlocked() then return end
			isDragging = true
			dragStart = Vector2.new(input.Position.X, input.Position.Y)
			dragCamStart = targetPos
		end
		if input.UserInputType == Enum.UserInputType.Keyboard then
			keysDown[input.KeyCode] = true
		end
	end)

	connections[#connections + 1] = UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton3 then
			isDragging = false
		end
		if input.UserInputType == Enum.UserInputType.Keyboard then
			keysDown[input.KeyCode] = nil
		end
	end)

	connections[#connections + 1] = UserInputService.InputChanged:Connect(function(input)
		if not active then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement and isDragging then
			local delta = Vector2.new(input.Position.X, input.Position.Y) - dragStart
			local vp = camera.ViewportSize
			local worldPerPixel = (2 * currentZoom * math.tan(math.rad(camera.FieldOfView * 0.5))) / math.max(vp.Y, 1)
			local scale = worldPerPixel * Config.DRAG_SENSITIVITY
			targetPos = Vector3.new(
				wrapX(dragCamStart.X + (dragInverted and 1 or -1) * delta.X * scale),
				Config.MAP_Y,
				clampZ(dragCamStart.Z + (dragInverted and 1 or -1) * delta.Y * scale)
			)
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			if not active then return end
			if inputBlocked() then return end
			local scrollDir = -input.Position.Z
			local factor = 1 + scrollDir * Config.ZOOM_SPEED
			targetZoom = math.clamp(targetZoom * factor, Config.MIN_ZOOM, Config.MAX_ZOOM)
		end
	end)

	-- =========== Touch handlers ============
	-- One-finger pan
	connections[#connections + 1] = UserInputService.TouchPan:Connect(function(_, totalTranslation, _, state, processed)
		if not active or processed then return end
		if state == Enum.UserInputState.Begin then
			if inputBlocked() then return end
			isDragging = true
			dragCamStart = targetPos
		elseif state == Enum.UserInputState.Change and isDragging then
			local vp = camera.ViewportSize
			local worldPerPixel = (2 * currentZoom * math.tan(math.rad(camera.FieldOfView * 0.5))) / math.max(vp.Y, 1)
			local s = worldPerPixel * Config.DRAG_SENSITIVITY
			targetPos = Vector3.new(
				wrapX(dragCamStart.X + (dragInverted and 1 or -1) * totalTranslation.X * s),
				Config.MAP_Y,
				clampZ(dragCamStart.Z + (dragInverted and 1 or -1) * totalTranslation.Y * s)
			)
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			isDragging = false
		end
	end)

	-- Two-finger pinch to zoom
	connections[#connections + 1] = UserInputService.TouchPinch:Connect(function(_, scale, _, state, processed)
		if not active or processed then return end
		-- TouchPinch's `scale` is CUMULATIVE since the gesture began. Dividing the running targetZoom by it
		-- every event compounded (way over-sensitive); instead apply only the incremental ratio since the
		-- last event, damped by PINCH_SENSITIVITY (<1). scale > 1 = fingers spreading = zoom in.
		if state == Enum.UserInputState.Begin then
			lastPinchScale = (scale and scale > 0) and scale or 1
		elseif state == Enum.UserInputState.Change and scale and scale > 0 then
			local ratio = (lastPinchScale / scale) ^ Config.PINCH_SENSITIVITY
			lastPinchScale = scale
			targetZoom = math.clamp(targetZoom * ratio, Config.MIN_ZOOM, Config.MAX_ZOOM)
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			lastPinchScale = 1
		end
	end)

	connections[#connections + 1] = RunService.RenderStepped:Connect(function(dt)
		if not active then return end
		handleKeyPan(dt)
		handleEdgePan(dt)
		updateCamera(dt)
	end)
end

local function releaseHandoff()
	isDragging = false
	table.clear(keysDown)
	camera.CameraType = Enum.CameraType.Custom
	local player = Players.LocalPlayer
	if player and player.Character then
		local hum = player.Character:FindFirstChildWhichIsA("Humanoid")
		if hum then camera.CameraSubject = hum end
	end
end

function CameraController.init()
	if initialized then return end
	initialized = true
	wireConnections()
	CameraController.enable()
end

function CameraController.enable()
	if not initialized then
		initialized = true
		wireConnections()
	end
	active = true
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CameraSubject = nil
end

function CameraController.disable()
	if not active then return end
	active = false
	releaseHandoff()
end

function CameraController.isActive()
	return active
end

function CameraController.getPosition() return currentPos end
function CameraController.getZoom() return currentZoom end
function CameraController.setPosition(pos)
	targetPos = Vector3.new(wrapX(pos.X), Config.MAP_Y, clampZ(pos.Z))
end
function CameraController.setZoom(z)
	targetZoom = math.clamp(z, Config.MIN_ZOOM, Config.MAX_ZOOM)
end
function CameraController.snapTo(pos, zoom)
	if pos then
		local snapped = Vector3.new(wrapX(pos.X), Config.MAP_Y, clampZ(pos.Z))
		targetPos = snapped
		currentPos = snapped
	end
	if zoom then
		local snappedZ = math.clamp(zoom, Config.MIN_ZOOM, Config.MAX_ZOOM)
		targetZoom = snappedZ
		currentZoom = snappedZ
	end
end
-- Pan to centerPos and choose a zoom (eased) that frames a ground extent of `spread` studs. Used to
-- focus a country's homeland on selection: zoom scales with the realm's size but is clamped to a
-- comfortable focus range so a tiny country isn't uncomfortably close and a sprawling/transcontinental
-- one never zooms out to the empty void. setPosition/setZoom apply the usual wrap/clamp bounds.
function CameraController.focusArea(centerPos, spread)
	if centerPos then
		CameraController.setPosition(centerPos)
	end
	spread = math.max(0, spread or 0)
	CameraController.setZoom(math.clamp(spread * 1.3 + 80, 130, 1300))
end

function CameraController.getConfig() return table.clone(Config) end

function CameraController.destroy()
	for _, conn in connections do conn:Disconnect() end
	connections = {}
	initialized = false
	active = false
end

return CameraController
