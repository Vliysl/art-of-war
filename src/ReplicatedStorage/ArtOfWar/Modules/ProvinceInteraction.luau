local ProvinceInteraction = {}

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")

local Platform = require(script.Parent:WaitForChild("Platform"))
local WorldConstants = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("WorldConstants"))

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
	local inset = GuiService:GetGuiInset()
	local x, y = mp.X, mp.Y - inset.Y
	local objects = pg:GetGuiObjectsAtPosition(x, y)
	for _, obj in objects do
		local cursor = obj
		while cursor and cursor:IsA("GuiObject") do
			local sink = cursor:GetAttribute("AoWInputSink")
			if sink == true then
				return true
			end
			if sink == false then
				break
			end
			if cursor:IsA("ScrollingFrame") then
				return true
			end
			cursor = cursor.Parent
		end
	end
	return false
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
local dragGui, dragFrame
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
	return dragFrame
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
end

local function hideDragRect()
	if dragFrame then
		dragFrame.Visible = false
	end
end

function ProvinceInteraction.init()
	ensureHighlights()
	rebuildFilter()

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
			touchDownPos = Vector2.new(input.Position.X, input.Position.Y)
			touchMoved = false
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape then
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
				if math.abs(mp.X - mb1DownPos.X) > CLICK_DRAG_THRESHOLD
					or math.abs(mp.Y - mb1DownPos.Y) > CLICK_DRAG_THRESHOLD then
					mb1Dragging = true
				end
			end
			if mb1Dragging then
				updateDragRect(mb1DownPos, Vector2.new(mp.X, mp.Y))
			end
		end
		-- Touch drag past the threshold = a pan (handled by CameraController.TouchPan), not a tap.
		if touchDownPos and input.UserInputType == Enum.UserInputType.Touch then
			local p = input.Position
			if math.abs(p.X - touchDownPos.X) > CLICK_DRAG_THRESHOLD
				or math.abs(p.Y - touchDownPos.Y) > CLICK_DRAG_THRESHOLD then
				touchMoved = true
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
			if not downPos or moved or processed then
				return
			end
			if isMouseOverUI() then
				return
			end
			-- 1) Tapped one of our own armies -> classifier selects/stacks it.
			if tryClassifierRaycasts() then
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
				onDragSelected(minV, maxV, shift)
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
		if not alt and tryClassifierRaycasts() then
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
		if WorldConstants.EnableNewInputScheme and not alt and ok3 and province
			and rightClickArmed() and not commandPending() then
			if onRightClicked then
				onRightClicked(province)
			end
			return
		end
		-- Alt-inspect must not drop the current army selection (that is its purpose); flagged
		-- for the duration of the synchronous setSelection dispatch so HudWiring can skip the
		-- army-deselect ripple.
		altInspecting = alt and WorldConstants.EnableNewInputScheme
		if ok3 and province then
			if shift then
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

return ProvinceInteraction
