local ProvinceInteraction = {}

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")

local Platform = require(script.Parent:WaitForChild("Platform"))
local WorldConstants = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("WorldConstants"))
local SeaNodes = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("SeaNodes"))
local InputGuard = require(script.Parent:WaitForChild("InputGuard"))

local DEBOUNCE_FRAMES = 1
local HOVER_INTERVAL = 1 / 30
local RAY_LENGTH = 200000
local HOVER_FILL = Color3.fromRGB(255, 220, 140)
local HOVER_OUTLINE = Color3.fromRGB(255, 235, 180)
local SELECT_FILL = Color3.fromRGB(120, 220, 255)
local SELECT_OUTLINE = Color3.fromRGB(180, 235, 255)

local hoveredProvince = nil
local selectedProvince = nil
local hoverHighlight = nil
local selectHighlight = nil
local connections = {}
local lastTarget = nil
local targetFrames = 0
local hoverClock = 0

local onHovered, onSelected, onWater, onRightClicked = nil, nil, nil, nil
local onDragSelected = nil
local selectListeners = {}
local multiSelectListeners = {}
local hoverListeners = {}

local multiSelection = {}
local multiHighlights = {}

local raycastFolders = {}
local screenSelectors = {}

local MULTI_FILL = Color3.fromRGB(120, 220, 255)
local MULTI_OUTLINE = Color3.fromRGB(180, 235, 255)

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true
local filterList = {}

local function rebuildFilter()
	table.clear(filterList)
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(filterList, p.Character)
		end
	end
	local map = workspace:FindFirstChild("ArtOfWarMap")
	if map then
		local floor = map:FindFirstChild("FieldFloor")
		if floor then
			table.insert(filterList, floor)
		end
		local armies = map:FindFirstChild("Armies")
		if armies then
			table.insert(filterList, armies)
		end
	end
	raycastParams.FilterDescendantsInstances = filterList
end

local function ensureHighlights()
	if hoverHighlight and hoverHighlight.Parent then
		return
	end
	hoverHighlight = Instance.new("Highlight")
	hoverHighlight.Name = "AoWHover"
	hoverHighlight.FillColor = HOVER_FILL
	hoverHighlight.OutlineColor = HOVER_OUTLINE
	hoverHighlight.FillTransparency = 0.7
	hoverHighlight.OutlineTransparency = 0.1
	hoverHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hoverHighlight.Adornee = nil
	hoverHighlight.Parent = workspace.CurrentCamera

	selectHighlight = Instance.new("Highlight")
	selectHighlight.Name = "AoWSelect"
	selectHighlight.FillColor = SELECT_FILL
	selectHighlight.OutlineColor = SELECT_OUTLINE
	selectHighlight.FillTransparency = 0.6
	selectHighlight.OutlineTransparency = 0
	selectHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	selectHighlight.Adornee = nil
	selectHighlight.Parent = workspace.CurrentCamera
end

local function isProvincePart(inst)
	if not inst or not inst:IsA("BasePart") then
		return false
	end
	local parent = inst.Parent
	if not parent then
		return false
	end
	-- Only land provinces are selectable. Sea tiles fall through to the onWater hover
	-- signal and, on click, resolve to no selection (closing the province panel).
	return parent.Name == "Provinces"
end

local function activeCamera()
	return workspace.CurrentCamera
end

-- perf: GetGuiObjectsAtPosition walks the whole PlayerGui tree and is called per input event AND
-- from the 30Hz hover loop. Cache the result keyed on cursor position for a short window so a burst
-- of same-frame calls (and a stationary cursor) reuse one walk instead of re-walking each time.
local uiCacheResult = false
local uiCacheX, uiCacheY = nil, nil
local uiCacheClock = -math.huge
local UI_CACHE_TTL = 0.05
local UI_CACHE_MOVE = 8
local function isMouseOverUI()
	local player = Players.LocalPlayer
	if not player then
		return false
	end
	local pg = player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return false
	end
	local mp = UserInputService:GetMouseLocation()
	local now = os.clock()
	if
		uiCacheX
		and (now - uiCacheClock) < UI_CACHE_TTL
		and math.abs(mp.X - uiCacheX) < UI_CACHE_MOVE
		and math.abs(mp.Y - uiCacheY) < UI_CACHE_MOVE
	then
		return uiCacheResult
	end
	uiCacheX, uiCacheY, uiCacheClock = mp.X, mp.Y, now
	local inset = GuiService:GetGuiInset()
	local x, y = mp.X, mp.Y - inset.Y
	local objects = pg:GetGuiObjectsAtPosition(x, y)
	local result = false
	for _, obj in objects do
		local cursor = obj
		while cursor and cursor:IsA("GuiObject") do
			local sink = cursor:GetAttribute("AoWInputSink")
			if sink == true then
				result = true
				break
			end
			if sink == false then
				break
			end
			if cursor:IsA("ScrollingFrame") then
				result = true
				break
			end
			cursor = cursor.Parent
		end
		if result then
			break
		end
	end
	uiCacheResult = result
	return result
end

local CLICK_DRAG_THRESHOLD = 6
local mb1DownPos = nil
local mb1Dragging = false
local mb2Down = false
local mb2DownProvince = nil
local mb2Moved = false
local mb2Accum = 0
local touchDownPos = nil
local touchMoved = false
local rightClickArmed = function()
	return true
end
-- New input scheme (EnableNewInputScheme): a pending targeted command (HudWiring requestTarget,
-- e.g. fleet attack) must consume the next map click via the select pipeline, NOT the LMB-move
-- branch. HudWiring installs the probe.
local commandPending = function()
	return false
end
-- True only while an Alt+LMB inspect is dispatching its setSelection, so HudWiring's select
-- listener can keep the current army selection alive (the whole point of Alt-inspect).
local altInspecting = false
-- Multi-province selection cap (server-side batch remotes reject larger lists; the panel
-- title surfaces the cap). Touch has no modifier keys: multiSelectMode makes plain taps
-- toggle provinces instead (on-screen toggle in HudWiring).
local MULTI_SELECT_MAX = 25
local multiSelectMode = false
-- Phase C touch-gesture state (flag-gated). dragMoveProbe: fn(screenPos,maxPx)->selected army provinceId near
-- the point (set by ArmyView) for drag-to-move; dragMoveFrom: province the current drag started on. Long-press
-- (radial) uses a token to cancel + a fired flag to consume the release.
local dragMoveProbe = nil
local dragMoveFrom = nil
local onLongPressed = nil
local longPressToken = 0
local longPressFired = false
local LONG_PRESS_TIME = 0.35
local dragSelectTarget = "units" -- A3: "units" | "provinces"; touch on-screen sub-toggle (PC uses Alt)

local function getProvinceAtMouse(skipUiCheck)
	local cam = activeCamera()
	if not cam then
		return nil
	end
	if not skipUiCheck and isMouseOverUI() then
		return nil
	end
	local mp = UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(mp.X, mp.Y)
	local result = workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, raycastParams)
	if not result then
		return nil
	end
	if isProvincePart(result.Instance) then
		return result.Instance
	end
	return nil
end

local function getMouseWorldPlanePosition()
	local cam = activeCamera()
	if not cam then
		return nil
	end
	local mp = UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(mp.X, mp.Y)
	if math.abs(ray.Direction.Y) < 1e-6 then
		return nil
	end
	local t = (0 - ray.Origin.Y) / ray.Direction.Y
	if t < 0 then
		return nil
	end
	local hit = ray.Origin + ray.Direction * t
	return hit.X, hit.Z
end

-- Sea move target (C9 sea transport): the sea meshes are zero-thickness (and
-- RenderDistanceController turns culled parts' CanQuery off), so a click raycast can never
-- resolve them -- the Y=0 plane intersection + nearest baked sea node IS the mechanism.
-- Consulted ONLY when a click/tap with armies selected resolved no province; sea is never
-- selectable/inspectable, so the plain select paths still deselect over water. Returns the
-- (negative) node id, or nil (flag off / no bake / too far -> callers keep today's behavior).
local SEA_TARGET_MAX_DIST = 60
local function getSeaMoveTarget()
	if not WorldConstants.EnableSeaTransport then
		return nil
	end
	local wx, wz = getMouseWorldPlanePosition()
	if not wx then
		return nil
	end
	return SeaNodes.nearestNode(wx, wz, SEA_TARGET_MAX_DIST)
end

local function setHover(province)
	if province == hoveredProvince then
		return
	end
	hoveredProvince = province
	hoverHighlight.Adornee = province
	if onHovered then
		onHovered(province)
	end
	for listener in pairs(hoverListeners) do
		local ok, err = pcall(listener, province)
		if not ok then
			warn("[ProvinceInteraction] hover listener errored: " .. tostring(err))
		end
	end
end

local function setSelection(province)
	selectedProvince = province
	selectHighlight.Adornee = province
	if onSelected then
		onSelected(province)
	end
	for listener in pairs(selectListeners) do
		listener(province)
	end
end

local function clearSelectionSilent()
	-- Clear province selection state + highlight WITHOUT firing onSelected/selectListeners.
	-- Used when a unit click is consumed by a classifier so the freshly-selected unit is
	-- not immediately deselected by the onSelectProvince(nil) cascade.
	selectedProvince = nil
	if selectHighlight then
		selectHighlight.Adornee = nil
	end
end

local function notifyMultiSelectionChanged()
	for listener in pairs(multiSelectListeners) do
		local ok, err = pcall(listener, multiSelection)
		if not ok then
			warn("[ProvinceInteraction] multi-select listener errored: " .. tostring(err))
		end
	end
end

local function clearMultiSelection()
	for _, hl in pairs(multiHighlights) do
		if hl.Parent then
			hl:Destroy()
		end
	end
	table.clear(multiHighlights)
	if #multiSelection > 0 then
		multiSelection = {}
		notifyMultiSelectionChanged()
	end
end

local function applyMultiHighlights()
	local present = {}
	for _, part in ipairs(multiSelection) do
		present[part] = true
	end
	for part, hl in pairs(multiHighlights) do
		if not present[part] then
			if hl.Parent then
				hl:Destroy()
			end
			multiHighlights[part] = nil
		end
	end
	for _, part in ipairs(multiSelection) do
		if not multiHighlights[part] then
			local hl = Instance.new("Highlight")
			hl.Name = "AoWMultiSelect"
			hl.FillColor = MULTI_FILL
			hl.OutlineColor = MULTI_OUTLINE
			hl.FillTransparency = 0.78
			hl.OutlineTransparency = 0.25
			hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			hl.Adornee = part
			hl.Parent = workspace.CurrentCamera
			multiHighlights[part] = hl
		end
	end
end

local function toggleInMultiSelection(province)
	if not province then
		return
	end
	for i, p in ipairs(multiSelection) do
		if p == province then
			table.remove(multiSelection, i)
			applyMultiHighlights()
			notifyMultiSelectionChanged()
			return
		end
	end
	if #multiSelection >= MULTI_SELECT_MAX then
		return
	end
	table.insert(multiSelection, province)
	applyMultiHighlights()
	notifyMultiSelectionChanged()
end

local function tryClassifierRaycasts()
	if #raycastFolders == 0 then
		return false
	end
	local cam = activeCamera()
	if not cam then
		return false
	end
	if isMouseOverUI() then
		return false
	end
	local mp = UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(mp.X, mp.Y)
	for _, entry in ipairs(raycastFolders) do
		if entry.folder and entry.folder.Parent then
			local result = workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, entry.params)
			if result and result.Instance then
				local ok, classification = pcall(entry.classifier, result.Instance)
				if ok and classification == "consumed" then
					return true
				end
			end
		end
	end
	return false
end

-- Screen-space selectors (touch-friendly, army-beats-province): unlike the raycast classifiers, these receive the
-- tap point + a pixel radius and may select the NEAREST matching thing (e.g. the nearest owned army token) even
-- when a precise raycast would miss it and fall through to the province. Returns true if one consumed the tap.
local function tryScreenSelectors()
	if #screenSelectors == 0 then
		return false
	end
	if isMouseOverUI() then
		return false
	end
	local mp = UserInputService:GetMouseLocation()
	local screenPos = Vector2.new(mp.X, mp.Y)
	local maxPx = Platform.isTouch and 44 or 10 -- forgiving on touch; near-exact on desktop
	-- B4: in touch box-select mode a plain tap ADDS to the selection (touch has no Shift).
	local additive = (Platform.isTouch and multiSelectMode)
		or UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
	for _, fn in ipairs(screenSelectors) do
		local ok, consumed = pcall(fn, screenPos, maxPx, additive)
		if ok and consumed then
			return true
		end
	end
	return false
end

function ProvinceInteraction.addScreenSelector(fn)
	if type(fn) == "function" then
		table.insert(screenSelectors, fn)
	end
end

-- B3: a callback (registered by ArmyView) returning how many stacks fall inside a viewport rect, for the
-- live "N selected" marquee count.
function ProvinceInteraction.setDragCountProvider(fn)
	dragCountProvider = (type(fn) == "function") and fn or nil
end

function ProvinceInteraction.addRaycastFolder(folder, classifierFn)
	if not folder or type(classifierFn) ~= "function" then
		return
	end
	for _, entry in ipairs(raycastFolders) do
		if entry.folder == folder then
			return
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { folder }
	params.IgnoreWater = true
	table.insert(raycastFolders, { folder = folder, classifier = classifierFn, params = params })
	rebuildFilter()
end

function ProvinceInteraction.clearSelection()
	setSelection(nil)
end

function ProvinceInteraction.clearSelectionSilent()
	clearSelectionSilent()
end

-- Drag-select rectangle. A small 2D box drawn while the player left-drags over the map. The GUI uses
-- IgnoreGuiInset so its (0,0) matches GetMouseLocation / WorldToViewportPoint space, keeping the box
-- aligned with the cursor and consistent with the army hit-test (ArmyView.selectArmiesInScreenRect).
local dragGui, dragFrame, dragCountLabel
local dragCountProvider = nil
local function ensureDragGui()
	if dragFrame and dragFrame.Parent then
		return dragFrame
	end
	local player = Players.LocalPlayer
	local pg = player and player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return nil
	end
	dragGui = Instance.new("ScreenGui")
	dragGui.Name = "AoWDragSelect"
	dragGui.ResetOnSpawn = false
	dragGui.IgnoreGuiInset = true
	dragGui.DisplayOrder = 50
	dragGui.Parent = pg

	dragFrame = Instance.new("Frame")
	dragFrame.Name = "Box"
	dragFrame.BackgroundColor3 = SELECT_FILL
	dragFrame.BackgroundTransparency = 0.8
	dragFrame.BorderSizePixel = 0
	dragFrame.Visible = false
	dragFrame.ZIndex = 10
	local stroke = Instance.new("UIStroke")
	stroke.Color = SELECT_OUTLINE
	stroke.Thickness = 1.5
	stroke.Transparency = 0.1
	stroke.Parent = dragFrame
	dragFrame.Parent = dragGui
	dragCountLabel = Instance.new("TextLabel")
	dragCountLabel.Name = "Count"
	dragCountLabel.BackgroundColor3 = SELECT_OUTLINE
	dragCountLabel.BackgroundTransparency = 0.15
	dragCountLabel.TextColor3 = Color3.new(0, 0, 0)
	dragCountLabel.Font = Enum.Font.GothamBold
	dragCountLabel.TextSize = 14
	dragCountLabel.AnchorPoint = Vector2.new(0.5, 1)
	dragCountLabel.Size = UDim2.fromOffset(130, 22)
	dragCountLabel.Visible = false
	dragCountLabel.ZIndex = 12
	local lc = Instance.new("UICorner")
	lc.CornerRadius = UDim.new(0, 6)
	lc.Parent = dragCountLabel
	dragCountLabel.Parent = dragGui
	return dragFrame
end

-- B3: which thing the current drag will box-select (drives the live count label + is set by Alt on PC /
-- the on-screen target toggle on touch).
local function currentDragTargetIsProvinces()
	if Platform.isTouch then
		return dragSelectTarget == "provinces"
	end
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt)
end

local function updateDragRect(a, b)
	local frame = ensureDragGui()
	if not frame then
		return
	end
	local minX, minY = math.min(a.X, b.X), math.min(a.Y, b.Y)
	frame.Position = UDim2.fromOffset(minX, minY)
	frame.Size = UDim2.fromOffset(math.abs(a.X - b.X), math.abs(a.Y - b.Y))
	frame.Visible = true
	if dragCountLabel then
		-- B3: live count above the current finger/cursor (b) so the box target is legible under the finger.
		local off = Platform.isTouch and 46 or 20
		dragCountLabel.Position = UDim2.fromOffset(b.X, b.Y - off)
		if currentDragTargetIsProvinces() then
			dragCountLabel.Text = "Provinces"
		elseif dragCountProvider then
			local mnX, mnY = math.min(a.X, b.X), math.min(a.Y, b.Y)
			local mxX, mxY = math.max(a.X, b.X), math.max(a.Y, b.Y)
			local ok, cnt = pcall(dragCountProvider, Vector2.new(mnX, mnY), Vector2.new(mxX, mxY))
			local n2 = (ok and cnt) or 0
			dragCountLabel.Text = n2 .. (n2 == 1 and " army" or " armies")
		else
			dragCountLabel.Text = ""
		end
		dragCountLabel.Visible = true
	end
end

local function hideDragRect()
	if dragFrame then
		dragFrame.Visible = false
	end
	if dragCountLabel then
		dragCountLabel.Visible = false
	end
end

-- Camera-freeze predicate (InputGuard "dragSelect"): freeze the map camera while box-select mode is on, OR
-- (C2) while a touch is starting on a SELECTED army so a finger-drag becomes a MOVE order instead of a pan.
-- A fresh hit-test each check (no stored flag) so it never races the camera controller's own InputBegan.
local function cameraShouldFreeze()
	if multiSelectMode then
		return true
	end
	-- C2: freeze for the WHOLE drag once it armed on a selected army (dragMoveFrom set in InputBegan). Do NOT
	-- re-probe the live cursor here: TouchPan.Begin fires on the FIRST movement, by which point the finger may
	-- already be past the token, so a live probe would miss and let the map pan mid-move (the intermittent bug).
	if dragMoveFrom ~= nil then
		return true
	end
	return false
end

function ProvinceInteraction.init()
	ensureHighlights()
	rebuildFilter()

	-- Freeze the camera while drag-select mode is on (mobile): CameraController.TouchPan bails whenever
	-- InputGuard.isCameraBlocked(), so a finger-drag draws the unit marquee instead of panning the map.
	InputGuard.register("dragSelect", cameraShouldFreeze)

	connections[#connections + 1] = Players.PlayerAdded:Connect(function(p)
		rebuildFilter()
		connections[#connections + 1] = p.CharacterAdded:Connect(rebuildFilter)
	end)
	connections[#connections + 1] = Players.PlayerRemoving:Connect(rebuildFilter)
	for _, p in Players:GetPlayers() do
		connections[#connections + 1] = p.CharacterAdded:Connect(rebuildFilter)
	end

	connections[#connections + 1] = RunService.RenderStepped:Connect(function(dt)
		-- No cursor hover on touch: GetMouseLocation reports the last TAP, so this loop would constantly
		-- "hover" the last-tapped tile (spurious tooltip / path-preview). Touch users get info from the
		-- tap -> province panel instead.
		if Platform.isTouch then
			return
		end
		hoverClock += dt
		if hoverClock < HOVER_INTERVAL then
			return
		end
		hoverClock = 0

		if isMouseOverUI() then
			setHover(nil)
			if onWater then
				onWater(nil, nil)
			end
			lastTarget = nil
			targetFrames = 0
			return
		end

		local ok, province = pcall(getProvinceAtMouse, true)
		if not ok then
			return
		end

		if province then
			if province == lastTarget then
				targetFrames += 1
			else
				lastTarget = province
				targetFrames = 1
			end
			if targetFrames >= DEBOUNCE_FRAMES then
				setHover(province)
			end
		else
			setHover(nil)
			if onWater then
				local wx, wz = getMouseWorldPlanePosition()
				if wx then
					onWater(wx, wz)
				else
					onWater(nil, nil)
				end
			end
			lastTarget = nil
			targetFrames = 0
		end
	end)

	connections[#connections + 1] = UserInputService.InputBegan:Connect(function(input, processed)
		-- Right-click: capture on press (any map mode), resolve on release as a CLICK vs DRAG.
		-- Legacy scheme: click = move order, armed only while a unit is selected (with nothing
		-- selected MB2 is left entirely to the camera); drag = field-camera rotate.
		-- New scheme (EnableNewInputScheme): click = select/inspect (always armed); drag = map
		-- camera pan (CameraController's MB2 handler). gameProcessedEvent is ignored here because
		-- the Classic field camera marks MB2 processed.
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			mb2Down, mb2DownProvince, mb2Moved, mb2Accum = false, nil, false, 0
			if not WorldConstants.EnableNewInputScheme and not rightClickArmed() then
				return
			end
			if isMouseOverUI() then
				return
			end
			mb2Down = true
			local ok2, province = pcall(getProvinceAtMouse, true)
			mb2DownProvince = ok2 and province or nil
			return
		end
		if processed then
			return
		end
		-- Touch tap: track the press; resolve as a tap (select/move) or a drag (camera pan) on release.
		if input.UserInputType == Enum.UserInputType.Touch then
			-- Capture the touch point from input.Position + GUI inset -> the true-top-left space the drag box and
			-- WorldToViewportPoint hit-tests use. input.Position is reliable on the touch-BEGIN frame (GetMouseLocation
			-- can be stale then), so the marquee anchor AND the drag-to-move probe do not intermittently miss.
			local gi = GuiService:GetGuiInset()
			touchDownPos = Vector2.new(input.Position.X + gi.X, input.Position.Y + gi.Y)
			touchMoved = false
			-- C2: if the press starts on a SELECTED army (and not in box-select mode), arm drag-to-move; the
			-- camera is frozen for this drag by cameraShouldFreeze, so a finger-drag to a province is a move.
			dragMoveFrom = nil
			if WorldConstants.EnableDragToMove and dragMoveProbe and not multiSelectMode then
				dragMoveFrom = dragMoveProbe(touchDownPos, 44)
			end
			-- C1: begin a long-press timer; a stationary hold opens the radial order menu.
			longPressFired = false
			if WorldConstants.EnableRadialOrders and onLongPressed and not multiSelectMode then
				longPressToken += 1
				local myToken = longPressToken
				local pos = touchDownPos
				task.delay(LONG_PRESS_TIME, function()
					if myToken == longPressToken and touchDownPos and not touchMoved then
						longPressFired = onLongPressed(pos) == true
					end
				end)
			end
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape then
			clearMultiSelection()
			setSelection(nil)
			return
		end
		if isMouseOverUI() then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			local mp = UserInputService:GetMouseLocation()
			mb1DownPos = Vector2.new(mp.X, mp.Y)
			mb1Dragging = false
		end
	end)

	connections[#connections + 1] = UserInputService.InputChanged:Connect(function(input)
		if mb2Down and input.UserInputType == Enum.UserInputType.MouseMovement then
			mb2Accum += math.abs(input.Delta.X) + math.abs(input.Delta.Y)
			if mb2Accum > CLICK_DRAG_THRESHOLD then
				mb2Moved = true
			end
		end
		-- Left-drag = box select. Once the press travels past the click threshold, draw the
		-- selection rectangle and keep it tracking the cursor until release.
		if mb1DownPos and input.UserInputType == Enum.UserInputType.MouseMovement then
			local mp = UserInputService:GetMouseLocation()
			if not mb1Dragging then
				if
					math.abs(mp.X - mb1DownPos.X) > CLICK_DRAG_THRESHOLD
					or math.abs(mp.Y - mb1DownPos.Y) > CLICK_DRAG_THRESHOLD
				then
					mb1Dragging = true
				end
			end
			if mb1Dragging then
				updateDragRect(mb1DownPos, Vector2.new(mp.X, mp.Y))
			end
		end
		-- Touch drag: in drag-select mode it draws the unit marquee (camera is frozen by the InputGuard
		-- predicate); otherwise it's a pan (handled by CameraController.TouchPan) and just disqualifies
		-- the press from being a tap.
		if touchDownPos and input.UserInputType == Enum.UserInputType.Touch then
			local gic = GuiService:GetGuiInset()
			local p = Vector2.new(input.Position.X + gic.X, input.Position.Y + gic.Y)
			if
				math.abs(p.X - touchDownPos.X) > CLICK_DRAG_THRESHOLD
				or math.abs(p.Y - touchDownPos.Y) > CLICK_DRAG_THRESHOLD
			then
				touchMoved = true
				longPressToken += 1 -- C1: a moved touch isn't a long-press
			end
			if multiSelectMode and touchMoved then
				updateDragRect(touchDownPos, Vector2.new(p.X, p.Y))
			end
		end
	end)

	connections[#connections + 1] = UserInputService.InputEnded:Connect(function(input, processed)
		-- Touch tap = select / move (mirrors left-click + the tap-to-move rule). A moved touch was a drag
		-- (camera pan), not a tap. GetMouseLocation tracks the last touch, so the existing raycast helpers
		-- resolve at the tap point (same coordinate space as the desktop path).
		if input.UserInputType == Enum.UserInputType.Touch then
			local downPos = touchDownPos
			local moved = touchMoved
			touchDownPos = nil
			touchMoved = false
			-- Capture + clear the drag-to-move arm on EVERY touch-end path so an early return (long-press /
			-- box-select) can never leak a stale dragMoveFrom (which would keep the camera frozen).
			local fromArmy = dragMoveFrom
			dragMoveFrom = nil
			-- C1: a long-press already opened the radial; consume this release so it doesn't also tap/move.
			if longPressFired then
				longPressFired = false
				return
			end
			-- 0) Drag-select mode (on-screen toggle; camera is frozen): a finger-DRAG resolves the marquee
			--    into a unit box-select (mirrors the mouse mb1 marquee); a plain TAP falls through to the
			--    normal select path below (touch has no modifier keys, so drag always replaces).
			if multiSelectMode and moved then
				hideDragRect()
				if downPos and not processed and onDragSelected then
					local gie = GuiService:GetGuiInset()
					local p = Vector2.new(input.Position.X + gie.X, input.Position.Y + gie.Y)
					local minV = Vector2.new(math.min(downPos.X, p.X), math.min(downPos.Y, p.Y))
					local maxV = Vector2.new(math.max(downPos.X, p.X), math.max(downPos.Y, p.Y))
					if dragSelectTarget == "provinces" and WorldConstants.EnableMultiProvinceActions then
						ProvinceInteraction.selectProvincesInScreenRect(minV, maxV, false)
					else
						onDragSelected(minV, maxV, false)
					end
				end
				return
			end
			-- C2: a drag that started on a selected army resolves as a MOVE to the release province (or sea node).
			if fromArmy ~= nil then
				if moved and not processed and not isMouseOverUI() then
					local okm, prov = pcall(getProvinceAtMouse, true)
					if okm and prov and onRightClicked then
						onRightClicked(prov)
						return
					end
					if not (okm and prov) then
						local seaNodeId = getSeaMoveTarget()
						if seaNodeId and onRightClicked then
							onRightClicked({ seaNodeId = seaNodeId })
							return
						end
					end
				end
			end
			if not downPos or moved or processed then
				return
			end
			if isMouseOverUI() then
				return
			end
			-- 1) Tapped one of our own armies -> classifier selects/stacks it.
			if tryScreenSelectors() or tryClassifierRaycasts() then
				clearSelectionSilent()
				clearMultiSelection()
				return
			end
			local ok, province = pcall(getProvinceAtMouse, true)
			-- 2) Units already selected + tapped a province -> MOVE there (tap-to-move).
			if ok and province and rightClickArmed() then
				if onRightClicked then
					onRightClicked(province)
				end
				return
			end
			-- 2b) Units selected + tapped open water -> sail to the nearest baked sea node
			--     (C9; without this mobile can't sail -- tapping water would just deselect).
			if not (ok and province) and rightClickArmed() then
				local seaNodeId = getSeaMoveTarget()
				if seaNodeId and onRightClicked then
					onRightClicked({ seaNodeId = seaNodeId })
					return
				end
			end
			-- 3) Otherwise select/inspect the tapped province (or deselect on empty water).
			clearMultiSelection()
			setSelection(ok and province or nil)
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			local wasDown, province, moved = mb2Down, mb2DownProvince, mb2Moved
			mb2Down, mb2DownProvince, mb2Moved, mb2Accum = false, nil, false, 0
			if not wasDown then
				return
			end
			if moved then
				return
			end -- right-drag = camera (new scheme: map pan; legacy: field-camera rotate)
			if isMouseOverUI() then
				return
			end
			if WorldConstants.EnableNewInputScheme then
				-- RMB click = select/inspect with the OLD left-click semantics, including the
				-- army-deselect ripple through the select listeners (symmetric button swap).
				clearMultiSelection()
				setSelection(province)
				return
			end
			if province and onRightClicked then
				onRightClicked(province)
			end
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		local downPos = mb1DownPos
		local wasDragging = mb1Dragging
		mb1DownPos = nil
		mb1Dragging = false
		-- Box-select takes priority: a drag resolves the rectangle and skips single-click selection.
		if wasDragging then
			hideDragRect()
			if downPos and onDragSelected then
				local mp = UserInputService:GetMouseLocation()
				local minV = Vector2.new(math.min(downPos.X, mp.X), math.min(downPos.Y, mp.Y))
				local maxV = Vector2.new(math.max(downPos.X, mp.X), math.max(downPos.Y, mp.Y))
				local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
					or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
				local boxAlt = UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt)
					or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt)
				if boxAlt and WorldConstants.EnableMultiProvinceActions then
					ProvinceInteraction.selectProvincesInScreenRect(minV, maxV, shift)
				else
					onDragSelected(minV, maxV, shift)
				end
			end
			return
		end
		if not downPos or processed then
			return
		end
		if isMouseOverUI() then
			return
		end
		local alt = UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt)
		-- Alt bypasses unit selection so a click selects the TILE under a unit (the underlying
		-- province is inspectable even when an army token sits on top of it).
		if not alt and (tryScreenSelectors() or tryClassifierRaycasts()) then
			-- A classifier (e.g. ArmyView) already handled this click and selected a unit.
			-- Clear the province highlight silently so we don't deselect that unit; the
			-- province detail panel is hidden by the army-selected listener in UIController.
			clearSelectionSilent()
			clearMultiSelection()
			return
		end
		local ok3, province = pcall(getProvinceAtMouse, true)
		local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		-- New scheme: with units selected, a plain left-click on a province IS the move order --
		-- the same routing the touch tap-to-move rule uses. Alt keeps inspecting; a pending
		-- targeted command (fleet attack etc.) keeps priority and resolves through the select
		-- pipeline below; empty clicks fall through to deselect.
		if
			WorldConstants.EnableNewInputScheme
			and not alt
			and ok3
			and province
			and rightClickArmed()
			and not commandPending()
		then
			if onRightClicked then
				onRightClicked(province)
			end
			return
		end
		-- Sea move (C9): with units selected, an empty click that resolves NO province but sits
		-- near a baked sea node is a move order onto that node instead of a deselect. Sea stays
		-- unselectable -- with nothing selected (or no node in range) water still deselects below.
		if
			WorldConstants.EnableNewInputScheme
			and not alt
			and not (ok3 and province)
			and rightClickArmed()
			and not commandPending()
		then
			local seaNodeId = getSeaMoveTarget()
			if seaNodeId and onRightClicked then
				onRightClicked({ seaNodeId = seaNodeId })
				return
			end
		end
		-- Alt-inspect must not drop the current army selection (that is its purpose); flagged
		-- for the duration of the synchronous setSelection dispatch so HudWiring can skip the
		-- army-deselect ripple.
		altInspecting = alt and WorldConstants.EnableNewInputScheme
		local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
		if ok3 and province then
			if (shift or ctrl) and WorldConstants.EnableMultiProvinceActions then
				-- Multi-province toggle only: the aggregate panel is driven by the multi-select
				-- listener; a setSelection here would immediately replace it with the single
				-- province panel.
				toggleInMultiSelection(province)
			elseif shift then
				toggleInMultiSelection(province)
				setSelection(province)
			else
				clearMultiSelection()
				setSelection(province)
			end
		else
			clearMultiSelection()
			setSelection(nil)
		end
		altInspecting = false
	end)
end

function ProvinceInteraction.onHover(cb)
	onHovered = cb
end
function ProvinceInteraction.onSelect(cb)
	onSelected = cb
end
function ProvinceInteraction.onWater(cb)
	onWater = cb
end
function ProvinceInteraction.onRightClick(cb)
	onRightClicked = cb
end
-- cb(rectMin: Vector2, rectMax: Vector2, additive: boolean) fired when a left-drag box select ends.
-- Coordinates are in viewport space (GetMouseLocation / WorldToViewportPoint).
function ProvinceInteraction.onDragSelect(cb)
	onDragSelected = cb
end

-- C2: probe registered by ArmyView -- given a screen point, returns the provinceId of a SELECTED owned army
-- token near it (or nil), used to arm drag-to-move and to freeze the camera for that gesture.
function ProvinceInteraction.setDragMoveProbe(fn)
	dragMoveProbe = (type(fn) == "function") and fn or nil
end

-- C1: callback fired on a stationary long-press (screenPos). HudWiring opens the radial order menu.
function ProvinceInteraction.onLongPress(cb)
	onLongPressed = cb
end
function ProvinceInteraction.setRightClickPredicate(fn)
	rightClickArmed = (type(fn) == "function") and fn or function()
		return false
	end
end
function ProvinceInteraction.setCommandPredicate(fn)
	commandPending = (type(fn) == "function") and fn or function()
		return false
	end
end
function ProvinceInteraction.isAltInspecting()
	return altInspecting
end
function ProvinceInteraction.getSelected()
	return selectedProvince
end
function ProvinceInteraction.getHovered()
	return hoveredProvince
end

function ProvinceInteraction.addSelectListener(cb)
	selectListeners[cb] = true
	return function()
		selectListeners[cb] = nil
	end
end

function ProvinceInteraction.addHoverListener(cb)
	hoverListeners[cb] = true
	return function()
		hoverListeners[cb] = nil
	end
end

function ProvinceInteraction.addMultiSelectListener(cb)
	multiSelectListeners[cb] = true
	return function()
		multiSelectListeners[cb] = nil
	end
end

function ProvinceInteraction.getMultiSelection()
	local out = {}
	for i, p in ipairs(multiSelection) do
		out[i] = p
	end
	return out
end

function ProvinceInteraction.clearMultiSelection()
	clearMultiSelection()
end

function ProvinceInteraction.setMultiSelectMode(on)
	multiSelectMode = on == true
	if not multiSelectMode then
		clearMultiSelection()
	end
end

function ProvinceInteraction.getMultiSelectMode()
	return multiSelectMode
end

function ProvinceInteraction.focusPart(part)
	setSelection(part)
end

function ProvinceInteraction.setSelectColor(fillColor, outlineColor)
	ensureHighlights()
	if fillColor then
		selectHighlight.FillColor = fillColor
	end
	if outlineColor then
		selectHighlight.OutlineColor = outlineColor
	end
end

function ProvinceInteraction.resetSelectColor()
	ensureHighlights()
	selectHighlight.FillColor = SELECT_FILL
	selectHighlight.OutlineColor = SELECT_OUTLINE
end

function ProvinceInteraction.destroy()
	for _, conn in connections do
		conn:Disconnect()
	end
	connections = {}
	if hoverHighlight then
		hoverHighlight:Destroy()
		hoverHighlight = nil
	end
	if selectHighlight then
		selectHighlight:Destroy()
		selectHighlight = nil
	end
	hoveredProvince, selectedProvince = nil, nil
end

-- A3: box-select PROVINCES (Alt+drag on PC, or the Provinces drag-target on touch). Projects province parts into
-- the viewport rect and adds those inside it to the multi-province selection (which drives the aggregate panel).
-- `additive` keeps the current multi-selection; otherwise it replaces it. Returns the multi-selection size.
function ProvinceInteraction.selectProvincesInScreenRect(rectMin, rectMax, additive)
	local cam = activeCamera()
	if not cam then
		return 0
	end
	local map = workspace:FindFirstChild("ArtOfWarMap")
	local folder = map and map:FindFirstChild("Provinces")
	if not folder then
		return 0
	end
	if not additive then
		clearMultiSelection()
	end
	local present = {}
	for _, part in ipairs(multiSelection) do
		present[part] = true
	end
	local added = false
	for _, part in ipairs(folder:GetChildren()) do
		if part:IsA("BasePart") and not present[part] and #multiSelection < MULTI_SELECT_MAX then
			local sp, onScreen = cam:WorldToViewportPoint(part.Position)
			if onScreen and sp.X >= rectMin.X and sp.X <= rectMax.X and sp.Y >= rectMin.Y and sp.Y <= rectMax.Y then
				table.insert(multiSelection, part)
				present[part] = true
				added = true
			end
		end
	end
	if added then
		applyMultiHighlights()
		notifyMultiSelectionChanged()
	end
	return #multiSelection
end

function ProvinceInteraction.setDragSelectTarget(target)
	dragSelectTarget = (target == "provinces") and "provinces" or "units"
end

function ProvinceInteraction.getDragSelectTarget()
	return dragSelectTarget
end

return ProvinceInteraction
