local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))
local UIRoot = require(uiFolder:WaitForChild("UIRoot"))

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local modulesFolder = aow:WaitForChild("Modules")

local InputGuard = require(modulesFolder:WaitForChild("InputGuard"))

local Minimap = {}
local minimapInstanceCount = 0

Minimap.DECAL_ID = "97466333148060"

local OPEN_SCALE_START = 0.94
local MIN_ZOOM = 1
local MAX_ZOOM = 10
local ZOOM_STEP = 1.25
local MARKER_PX = 6

local IMAGE_ASPECT = 2.439

local WORLD_X_AT_U0 = 9440
local WORLD_X_AT_U1 = -9444
local WORLD_Z_AT_V0 = 3879
local WORLD_Z_AT_V1 = -3884

local function uvToWorld(u, v)
	local x = WORLD_X_AT_U0 + u * (WORLD_X_AT_U1 - WORLD_X_AT_U0)
	local z = WORLD_Z_AT_V0 + v * (WORLD_Z_AT_V1 - WORLD_Z_AT_V0)
	return x, z
end

local function worldToUV(x, z)
	local u = (x - WORLD_X_AT_U0) / (WORLD_X_AT_U1 - WORLD_X_AT_U0)
	local v = (z - WORLD_Z_AT_V0) / (WORLD_Z_AT_V1 - WORLD_Z_AT_V0)
	return u, v
end

local function resolveDecalAsset()
	local attr = aow:GetAttribute("MinimapDecalId")
	local raw = tostring(attr or Minimap.DECAL_ID or "")
	if raw == "" or raw == "0" then return nil end
	if raw:match("^%d+$") then return "rbxassetid://" .. raw end
	return raw
end

local function lazyRequire(name)
	local module = modulesFolder:WaitForChild(name, 5)
	if not module then return nil end
	local ok, mod = pcall(require, module)
	return ok and mod or nil
end

local function isCommandMode()
	local modeMod = modulesFolder:FindFirstChild("MapModeController")
	if not modeMod then return false end
	local ok, mod = pcall(require, modeMod)
	if not ok or not mod or not mod.current then return false end
	return mod.current() == "command"
end

local function fallbackFieldPosition()
	local charMod = modulesFolder:FindFirstChild("CharacterHandler")
	if not charMod then return nil end
	local ok, mod = pcall(require, charMod)
	if not ok or not mod or not mod.getLastFieldPosition then return nil end
	return mod.getLastFieldPosition()
end

local function cameraWorldPosition()
	local camMod = modulesFolder:FindFirstChild("CameraController")
	if not camMod then return nil end
	local ok, mod = pcall(require, camMod)
	if not ok or not mod or not mod.getPosition then return nil end
	local p = mod.getPosition()
	return p
end

local function playerCharacterPosition()
	if isCommandMode() then
		local p = cameraWorldPosition()
		if p then return p end
		local fp = fallbackFieldPosition()
		if fp then return fp end
	end
	local player = Players.LocalPlayer
	if not player then return nil end
	local char = player.Character
	if not char then return nil end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end
	return hrp.Position
end

local function teleportPlayerTo(x, z)
	local player = Players.LocalPlayer
	if not player or not player.Character then return end
	local hrp = player.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	hrp.CFrame = CFrame.new(x, 60, z)
end

function Minimap.create(parent)
	local w = UIStyle.Size.MinimapW or 240
	local h = UIStyle.Size.MinimapH or 180
	local restingPosition = UDim2.new(1, -12, 1, -(UIStyle.Size.BottomBarH + 12))

	local frame = UIBuilder.panel(parent, {
		Name = "Minimap",
		AnchorPoint = Vector2.new(1, 1),
		Size = UDim2.fromOffset(w, h),
		Position = restingPosition,
		BackgroundColor3 = UIStyle.Color.Panel,
	})
	for _, c in frame:GetChildren() do
		if c:IsA("UIStroke") then c.Color = UIStyle.Color.Gold end
	end
	frame.ZIndex = UIStyle.Z.Content
	frame.Active = true
	frame.ClipsDescendants = true

	local titleBar = Instance.new("Frame")
	titleBar.Size = UDim2.new(1, 0, 0, 18)
	titleBar.BackgroundColor3 = UIStyle.Color.Bg
	titleBar.BorderSizePixel = 0
	titleBar.Parent = frame

	UIBuilder.label(titleBar, "Minimap", UIStyle.Type.Small, UIStyle.Color.Gold, {
		Size = UDim2.new(1, -28, 1, 0),
		Position = UDim2.fromOffset(8, 0),
		Font = UIStyle.Font.Bold,
		TextSize = 10,
	})

	local collapseBtn = Instance.new("TextButton")
	collapseBtn.Size = UDim2.fromOffset(18, 14)
	collapseBtn.Position = UDim2.new(1, -4, 0.5, 0)
	collapseBtn.AnchorPoint = Vector2.new(1, 0.5)
	collapseBtn.BackgroundColor3 = UIStyle.Color.PanelAlt
	collapseBtn.BorderSizePixel = 0
	collapseBtn.Text = "–"
	collapseBtn.TextColor3 = UIStyle.Color.Gold
	collapseBtn.Font = UIStyle.Font.Bold
	collapseBtn.TextSize = 12
	collapseBtn.AutoButtonColor = false
	collapseBtn.Parent = titleBar
	local collapseCorner = Instance.new("UICorner")
	collapseCorner.CornerRadius = UDim.new(0, 2)
	collapseCorner.Parent = collapseBtn

	-- View-mode toggle button (Field <-> Command). Sits between modesBtn and collapseBtn.
	local viewModeBtn = Instance.new("TextButton")
	viewModeBtn.Size = UDim2.fromOffset(18, 14)
	viewModeBtn.Position = UDim2.new(1, -26, 0.5, 0)
	viewModeBtn.AnchorPoint = Vector2.new(1, 0.5)
	viewModeBtn.BackgroundColor3 = UIStyle.Color.PanelAlt
	viewModeBtn.BorderSizePixel = 0
	viewModeBtn.Text = "\u{2194}"  -- left-right arrow
	viewModeBtn.TextColor3 = UIStyle.Color.Gold
	viewModeBtn.Font = UIStyle.Font.Bold
	viewModeBtn.TextSize = 12
	viewModeBtn.AutoButtonColor = false
	viewModeBtn.Parent = titleBar
	local viewModeCorner = Instance.new("UICorner")
	viewModeCorner.CornerRadius = UDim.new(0, 2)
	viewModeCorner.Parent = viewModeBtn

	viewModeBtn.MouseButton1Click:Connect(function()
		local mod = lazyRequire("MapModeController")
		if mod and mod.toggle then mod.toggle() end
	end)

	-- Reflect current mode in tint via MapModeController.onChange
	do
		local mod = lazyRequire("MapModeController")
		local function repaintMode(modeName)
			if modeName == "command" then
				viewModeBtn.TextColor3 = UIStyle.Color.Gold
			else
				viewModeBtn.TextColor3 = UIStyle.Color.TextMuted
			end
		end
		if mod then
			if mod.onChange then mod.onChange(repaintMode) end
			if mod.current then repaintMode(mod.current()) end
		end
	end

	local modesBtn = Instance.new("TextButton")
	modesBtn.Size = UDim2.fromOffset(20, 14)
	modesBtn.Position = UDim2.new(1, -48, 0.5, 0)
	modesBtn.AnchorPoint = Vector2.new(1, 0.5)
	modesBtn.BackgroundColor3 = UIStyle.Color.PanelAlt
	modesBtn.BorderSizePixel = 0
	modesBtn.Text = "\u{25BC}"
	modesBtn.TextColor3 = UIStyle.Color.Gold
	modesBtn.Font = UIStyle.Font.Bold
	modesBtn.TextSize = 9
	modesBtn.AutoButtonColor = false
	modesBtn.Parent = titleBar
	local modesCorner = Instance.new("UICorner")
	modesCorner.CornerRadius = UDim.new(0, 2)
	modesCorner.Parent = modesBtn
	local modesToggleHandler = nil
	modesBtn.MouseButton1Click:Connect(function()
		if modesToggleHandler then modesToggleHandler() end
	end)

	local body = Instance.new("Frame")
	body.Size = UDim2.new(1, -8, 1, -24)
	body.Position = UDim2.fromOffset(4, 22)
	body.BackgroundColor3 = Color3.fromRGB(16, 24, 48)
	body.BorderSizePixel = 0
	body.ClipsDescendants = true
	body.Parent = frame
	UIBuilder.corner(body, 2)
	UIBuilder.stroke(body, 1, UIStyle.Color.Border)

	local viewport = Instance.new("Frame")
	viewport.Name = "Viewport"
	viewport.BackgroundTransparency = 1
	viewport.BorderSizePixel = 0
	viewport.ZIndex = UIStyle.Z.Content
	viewport.ClipsDescendants = false
	viewport.Parent = body

	local function layoutViewport()
		local s = UIRoot.uiScale()
		local bodyW = body.AbsoluteSize.X / s
		local bodyH = body.AbsoluteSize.Y / s
		if bodyW <= 0 or bodyH <= 0 then return end
		local bodyAspect = bodyW / bodyH
		local vpW, vpH
		if bodyAspect >= IMAGE_ASPECT then
			vpH = bodyH
			vpW = bodyH * IMAGE_ASPECT
		else
			vpW = bodyW
			vpH = bodyW / IMAGE_ASPECT
		end
		viewport.Size = UDim2.fromOffset(vpW, vpH)
		viewport.Position = UDim2.fromOffset((bodyW - vpW) / 2, (bodyH - vpH) / 2)
	end

	layoutViewport()
	body:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutViewport)

	local mapImage = Instance.new("ImageButton")
	mapImage.Name = "MapImage"
	mapImage.Size = UDim2.fromScale(1, 1)
	mapImage.Position = UDim2.fromScale(0, 0)
	mapImage.BackgroundTransparency = 1
	mapImage.BorderSizePixel = 0
	mapImage.AutoButtonColor = false
	mapImage.ScaleType = Enum.ScaleType.Stretch
	mapImage.ImageTransparency = 0
	mapImage.ResampleMode = Enum.ResamplerMode.Default
	mapImage.ZIndex = UIStyle.Z.Content
	mapImage.Parent = viewport

	local imageClip = Instance.new("Frame")
	imageClip.Name = "ImageClip"
	imageClip.Size = UDim2.fromScale(1, 1)
	imageClip.BackgroundTransparency = 1
	imageClip.BorderSizePixel = 0
	imageClip.ClipsDescendants = true
	imageClip.ZIndex = UIStyle.Z.Content - 1
	imageClip.Parent = viewport

	mapImage.Parent = imageClip

	local placeholder = Instance.new("TextLabel")
	placeholder.Size = UDim2.fromScale(1, 1)
	placeholder.BackgroundTransparency = 1
	placeholder.Text = "Set ArtOfWar.MinimapDecalId to a rbxassetid to enable"
	placeholder.TextColor3 = UIStyle.Color.TextDim
	placeholder.TextWrapped = true
	placeholder.TextSize = 10
	placeholder.Font = UIStyle.Font.Regular
	placeholder.TextXAlignment = Enum.TextXAlignment.Center
	placeholder.TextYAlignment = Enum.TextYAlignment.Center
	placeholder.ZIndex = UIStyle.Z.Content + 1
	placeholder.Parent = body

	local function applyDecal()
		local asset = resolveDecalAsset()
		if asset then
			mapImage.Image = asset
			placeholder.Visible = false
		else
			mapImage.Image = ""
			placeholder.Visible = true
		end
	end
	applyDecal()
	aow:GetAttributeChangedSignal("MinimapDecalId"):Connect(applyDecal)

	local marker = Instance.new("Frame")
	marker.Name = "PlayerMarker"
	marker.Size = UDim2.fromOffset(MARKER_PX, MARKER_PX)
	marker.AnchorPoint = Vector2.new(0.5, 0.5)
	marker.BackgroundColor3 = Color3.fromRGB(255, 232, 110)
	marker.BorderSizePixel = 0
	marker.ZIndex = UIStyle.Z.Content + 3
	marker.Parent = imageClip
	local markerStroke = Instance.new("UIStroke")
	markerStroke.Thickness = 1
	markerStroke.Color = Color3.fromRGB(20, 16, 6)
	markerStroke.Parent = marker

	local zoom = 1
	local centerU = 0.5
	local centerV = 0.5

	local function clampCenter()
		local halfU = 0.5 / zoom
		local halfV = 0.5 / zoom
		centerU = math.clamp(centerU, halfU, 1 - halfU)
		centerV = math.clamp(centerV, halfV, 1 - halfV)
	end

	local function applyView()
		clampCenter()
		local halfU = 0.5 / zoom
		local halfV = 0.5 / zoom
		local minU = centerU - halfU
		local minV = centerV - halfV
		mapImage.Size = UDim2.fromScale(zoom, zoom)
		mapImage.Position = UDim2.fromScale(-minU * zoom, -minV * zoom)
	end

	local function updateMarker()
		local pos = playerCharacterPosition()
		if not pos then
			marker.Visible = false
			return
		end
		local u, v = worldToUV(pos.X, pos.Z)
		if u < 0 or u > 1 or v < 0 or v > 1 then
			marker.Visible = false
			return
		end
		local minU = centerU - 0.5 / zoom
		local minV = centerV - 0.5 / zoom
		local viewU = (u - minU) * zoom
		local viewV = (v - minV) * zoom
		if viewU < 0 or viewU > 1 or viewV < 0 or viewV > 1 then
			marker.Visible = false
			return
		end
		marker.Visible = true
		marker.Position = UDim2.fromScale(viewU, viewV)
	end

	minimapInstanceCount += 1
	local guardKey = "Minimap_" .. tostring(minimapInstanceCount)

	local function isMouseInsideFrame()
		if not frame.Visible then return false end
		local abs = frame.AbsolutePosition
		local size = frame.AbsoluteSize
		if size.X <= 0 or size.Y <= 0 then return false end
		local mouse = UserInputService:GetMouseLocation()
		local inset = GuiService:GetGuiInset()
		local mx = mouse.X
		local my = mouse.Y - inset.Y
		return mx >= abs.X and mx <= abs.X + size.X and my >= abs.Y and my <= abs.Y + size.Y
	end

	local function isMouseInside()
		if not body.Visible then return false end
		local abs = viewport.AbsolutePosition
		local size = viewport.AbsoluteSize
		if size.X <= 0 or size.Y <= 0 then return false end
		local mouse = UserInputService:GetMouseLocation()
		local inset = GuiService:GetGuiInset()
		local mx = mouse.X
		local my = mouse.Y - inset.Y
		return mx >= abs.X and mx <= abs.X + size.X and my >= abs.Y and my <= abs.Y + size.Y
	end

	InputGuard.register(guardKey, isMouseInsideFrame)
	frame.AncestryChanged:Connect(function(_, newParent)
		if newParent == nil then InputGuard.unregister(guardKey) end
	end)

	local function mouseToUV()
		local abs = viewport.AbsolutePosition
		local size = viewport.AbsoluteSize
		if size.X <= 0 or size.Y <= 0 then return nil, nil end
		local mouse = UserInputService:GetMouseLocation()
		local inset = GuiService:GetGuiInset()
		local localX = math.clamp(mouse.X - abs.X, 0, size.X)
		local localY = math.clamp(mouse.Y - inset.Y - abs.Y, 0, size.Y)
		local viewU = localX / size.X
		local viewV = localY / size.Y
		local minU = centerU - 0.5 / zoom
		local minV = centerV - 0.5 / zoom
		return minU + viewU / zoom, minV + viewV / zoom
	end

	local function doZoom(factor)
		if not isMouseInside() then return end
		local anchorU, anchorV = mouseToUV()
		if not anchorU then return end
		local newZoom = math.clamp(zoom * factor, MIN_ZOOM, MAX_ZOOM)
		if newZoom == zoom then return end
		local halfU = 0.5 / zoom
		local halfV = 0.5 / zoom
		local minU = centerU - halfU
		local minV = centerV - halfV
		local viewFracU = (anchorU - minU) / (2 * halfU)
		local viewFracV = (anchorV - minV) / (2 * halfV)
		zoom = newZoom
		local newHalfU = 0.5 / zoom
		local newHalfV = 0.5 / zoom
		centerU = anchorU - (viewFracU - 0.5) * 2 * newHalfU
		centerV = anchorV - (viewFracV - 0.5) * 2 * newHalfV
		applyView()
		updateMarker()
	end

	local tickConn = nil
	local function startTracking()
		if tickConn then return end
		tickConn = RunService.RenderStepped:Connect(function()
			if not frame.Visible or not body.Visible then return end
			updateMarker()
		end)
	end
	local function stopTracking()
		if tickConn then
			tickConn:Disconnect()
			tickConn = nil
		end
	end

	local inputConns = {}

	local viewportDragging = false
	local viewportDragButton = nil
	local viewportDragStartMouse = Vector2.zero
	local viewportDragStartCenter = Vector2.zero

	local function startViewportDrag(button)
		if viewportDragging then return end
		viewportDragging = true
		viewportDragButton = button
		local mouse = UserInputService:GetMouseLocation()
		viewportDragStartMouse = Vector2.new(mouse.X, mouse.Y)
		viewportDragStartCenter = Vector2.new(centerU, centerV)
	end

	local function onPanInputBegan(input)
		if input.UserInputType == Enum.UserInputType.MouseButton2
			or input.UserInputType == Enum.UserInputType.MouseButton3 then
			startViewportDrag(input.UserInputType)
		end
	end

	viewport.InputBegan:Connect(onPanInputBegan)
	mapImage.InputBegan:Connect(onPanInputBegan)

	table.insert(inputConns, UserInputService.InputEnded:Connect(function(input)
		if not viewportDragging then return end
		if input.UserInputType == viewportDragButton then
			viewportDragging = false
			viewportDragButton = nil
		end
	end))

	table.insert(inputConns, UserInputService.InputChanged:Connect(function(input)
		if not viewportDragging then return end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
		local size = viewport.AbsoluteSize
		if size.X <= 0 or size.Y <= 0 then return end
		local mouse = UserInputService:GetMouseLocation()
		local deltaX = mouse.X - viewportDragStartMouse.X
		local deltaY = mouse.Y - viewportDragStartMouse.Y
		centerU = viewportDragStartCenter.X - deltaX / (size.X * zoom)
		centerV = viewportDragStartCenter.Y - deltaY / (size.Y * zoom)
		applyView()
		updateMarker()
	end))

	mapImage.MouseWheelForward:Connect(function() doZoom(ZOOM_STEP) end)
	mapImage.MouseWheelBackward:Connect(function() doZoom(1 / ZOOM_STEP) end)
	-- Touch: single-finger drag pans, two-finger pinch zooms.
	local touchActive = false
	table.insert(inputConns, UserInputService.TouchPan:Connect(function(touchPositions, totalTranslation, _, state, processed)
		if processed and state == Enum.UserInputState.Begin then return end
		-- Only act on pans that started on the minimap viewport
		local function overViewport(pt)
			local pos = viewport.AbsolutePosition
			local sz = viewport.AbsoluteSize
			return pt.X >= pos.X and pt.X <= pos.X + sz.X and pt.Y >= pos.Y and pt.Y <= pos.Y + sz.Y
		end
		if state == Enum.UserInputState.Begin then
			if not touchPositions[1] or not overViewport(touchPositions[1]) then return end
			touchActive = true
			viewportDragging = true
			viewportDragStartCenter = Vector2.new(centerU, centerV)
		elseif state == Enum.UserInputState.Change and touchActive then
			local size = viewport.AbsoluteSize
			if size.X <= 0 or size.Y <= 0 then return end
			centerU = viewportDragStartCenter.X - totalTranslation.X / (size.X * zoom)
			centerV = viewportDragStartCenter.Y - totalTranslation.Y / (size.Y * zoom)
			applyView()
			updateMarker()
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			touchActive = false
			viewportDragging = false
		end
	end))

	table.insert(inputConns, UserInputService.TouchPinch:Connect(function(touchPositions, scale, _, state, processed)
		if processed then return end
		local function overViewport(pt)
			local pos = viewport.AbsolutePosition
			local sz = viewport.AbsoluteSize
			return pt.X >= pos.X and pt.X <= pos.X + sz.X and pt.Y >= pos.Y and pt.Y <= pos.Y + sz.Y
		end
		if state == Enum.UserInputState.Begin then
			if not touchPositions[1] or not overViewport(touchPositions[1]) then return end
		elseif state == Enum.UserInputState.Change then
			-- TouchPinch returns cumulative scale per delta. > 1 = pinch-out (zoom in to map = larger zoom value here).
			if scale and scale > 0 then
				doZoom(scale)
			end
		end
	end))


	mapImage.MouseButton1Click:Connect(function()
		if viewportDragging then return end
		local u, v = mouseToUV()
		if not u then return end
		local x, z = uvToWorld(u, v)
		local mapModeController = lazyRequire("MapModeController")
		local mode = mapModeController and mapModeController.current and mapModeController.current() or "field"
		if mode == "command" then
			local cam = lazyRequire("CameraController")
			if cam and cam.setPosition then
				cam.setPosition(Vector3.new(x, 0, z))
			end
		else
			teleportPlayerTo(x, z)
		end
	end)

	applyView()

	local expanded = false
	local expandTween = nil
	frame.Visible = false
	frame.Size = UDim2.fromOffset(w, 0)
	body.Visible = false

	local function cancelTween()
		if expandTween then
			expandTween:Cancel()
			expandTween = nil
		end
	end

	local function openTween()
		cancelTween()
		frame.Visible = true
		body.Visible = true
		frame.Size = UDim2.fromOffset(w * OPEN_SCALE_START, h)
		frame.Position = restingPosition
		expandTween = TweenService:Create(frame, UIStyle.tween(UIStyle.Motion.Panel or UIStyle.Motion.Medium), {
			Size = UDim2.fromOffset(w, h),
		})
		expandTween:Play()
		collapseBtn.Text = "–"
		task.defer(layoutViewport)
		startTracking()
	end

	local function closeTween()
		cancelTween()
		expandTween = TweenService:Create(frame, UIStyle.tween(UIStyle.Motion.Fast), {
			Size = UDim2.fromOffset(w, 18),
		})
		local thisTween = expandTween
		thisTween.Completed:Connect(function()
			if not expanded and expandTween == thisTween then
				body.Visible = false
				stopTracking()
			end
		end)
		thisTween:Play()
		collapseBtn.Text = "+"
	end

	local function setExpanded(flag)
		flag = flag and true or false
		if expanded == flag then return end
		expanded = flag
		if flag then openTween() else closeTween() end
	end

	collapseBtn.MouseButton1Click:Connect(function()
		setExpanded(not expanded)
	end)

	local visible = false
	local function setVisible(flag)
		flag = flag and true or false
		if visible == flag then return end
		visible = flag
		cancelTween()
		if flag then
			frame.Visible = true
			expanded = true
			body.Visible = true
			collapseBtn.Text = "–"
			frame.Size = UDim2.fromOffset(w * OPEN_SCALE_START, h * OPEN_SCALE_START)
			frame.Position = restingPosition
			expandTween = TweenService:Create(frame, UIStyle.tween(UIStyle.Motion.Panel or UIStyle.Motion.Medium), {
				Size = UDim2.fromOffset(w, h),
			})
			expandTween:Play()
			task.defer(layoutViewport)
			startTracking()
		else
			expandTween = TweenService:Create(frame, UIStyle.tween(UIStyle.Motion.Fast), {
				Size = UDim2.fromOffset(w * OPEN_SCALE_START, h * OPEN_SCALE_START),
			})
			local thisTween = expandTween
			thisTween.Completed:Connect(function()
				if not visible and expandTween == thisTween then
					frame.Visible = false
					stopTracking()
				end
			end)
			thisTween:Play()
		end
	end

	return {
		root = frame,
		setVisible = setVisible,
		isVisible = function() return visible end,
		setExpanded = setExpanded,
		isExpanded = function() return expanded end,
		applyDecal = applyDecal,
		bindModesToggle = function(fn) modesToggleHandler = fn end,
		setModesIndicator = function(open)
			modesBtn.Text = open and "\u{25B2}" or "\u{25BC}"
		end,
	}
end

return Minimap
