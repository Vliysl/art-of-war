local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))
local UIRoot = require(uiFolder:WaitForChild("UIRoot"))
local Platform = require(ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Modules"):WaitForChild("Platform"))

local MovableWindow = {}

-- Shared module-level state
local _positions = {}   -- id -> UDim2 position memory (per session)
local _instances = {}   -- id -> handle (for byId lookup)
local _stack = {}       -- z-order, top-most last

local TITLE_BAR_H = Platform.isTouch and 48 or 42
local MIN_VISIBLE = 80   -- minimum px of title bar that must remain inside viewport

-- Bring this window's ScreenGui to the front of the window stack.
local function bringToFront(handle)
	-- Remove from stack if present, then re-append
	for i = #_stack, 1, -1 do
		if _stack[i] == handle then
			table.remove(_stack, i)
			break
		end
	end
	table.insert(_stack, handle)
	UIRoot.bumpWindowGui(handle.screenGui)
end

local function viewportSize(screenGui)
	if screenGui and screenGui.AbsoluteSize.X > 0 then
		return screenGui.AbsoluteSize
	end
	local cam = workspace.CurrentCamera
	return cam and cam.ViewportSize or Vector2.new(1920, 1080)
end

local function clampPosition(pos, size, vp)
	local s = UIRoot.uiScale()
	local w = size.X.Offset * s
	local minX = -(w - MIN_VISIBLE)
	local maxX = vp.X - MIN_VISIBLE
	local maxY = vp.Y - TITLE_BAR_H * s
	local x = math.clamp(pos.X.Offset, minX, maxX)
	local y = math.clamp(pos.Y.Offset, 0, maxY)
	return UDim2.fromOffset(x, y)
end

local function defaultCenter(size, vp)
	local s = UIRoot.uiScale()
	return UDim2.fromOffset(
		math.floor((vp.X - size.X.Offset * s) / 2),
		math.floor((vp.Y - size.Y.Offset * s) / 2)
	)
end

local function clampSize(size, vp)
	local s = UIRoot.uiScale()
	local margin = 24
	local maxW = math.max(280, (vp.X - margin) / s)
	local maxH = math.max(220, (vp.Y - margin) / s)
	local w = math.min(size.X.Offset, maxW)
	local h = math.min(size.Y.Offset, maxH)
	return UDim2.fromOffset(w, h)
end

function MovableWindow.byId(id)
	return _instances[id]
end

function MovableWindow.create(opts)
	opts = opts or {}
	assert(opts.id, "MovableWindow.create: opts.id is required")
	assert(opts.size, "MovableWindow.create: opts.size is required")

	-- Idempotency: return existing handle if already created
	if _instances[opts.id] then
		return _instances[opts.id]
	end

	-- Forward declaration so closures (titleBar drag, root click) capture
	-- the live handle table once we assign it below.
	local handle

	local screenGui = UIRoot.createWindowGui(opts.id)

	local root = Instance.new("Frame")
	root.Name = opts.id
	-- Cap to viewport: large windows that wouldn't fit on phones get shrunk to fit.
	do
		local cam = workspace.CurrentCamera
		local vp = (cam and cam.ViewportSize) or Vector2.new(1280, 720)
		root.Size = clampSize(opts.size, vp)
	end
	root.BackgroundColor3 = UIStyle.Color.Panel
	root.BorderSizePixel = 0
	root.Active = true
	root.Visible = false
	root.AutoLocalize = false
	root.Parent = screenGui
	UIRoot.registerScaled(root)
	UIBuilder.corner(root, 4)
	local rootStroke = UIBuilder.stroke(root, 1, UIStyle.Color.BorderStrong)
	rootStroke.Transparency = 0.1

	-- Drop shadow approximation: a slightly bigger panel behind it
	-- (skip if reduce motion / minimal mode)

	-- Title bar
	local titleBar = Instance.new("Frame")
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0, TITLE_BAR_H)
	titleBar.BackgroundColor3 = UIStyle.Color.PanelHeader
	titleBar.BorderSizePixel = 0
	titleBar.Active = true
	titleBar.Parent = root
	UIBuilder.corner(titleBar, 4)
	local titleGradient = Instance.new("UIGradient")
	titleGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, UIStyle.Color.PanelAlt),
		ColorSequenceKeypoint.new(1, UIStyle.Color.Bg),
	})
	titleGradient.Rotation = 90
	titleGradient.Parent = titleBar

	local titleLbl = Instance.new("TextLabel")
	titleLbl.Size = UDim2.new(1, -56, 1, 0)
	titleLbl.Position = UDim2.fromOffset(18, 0)
	titleLbl.BackgroundTransparency = 1
	titleLbl.Text = opts.title or opts.id
	titleLbl.TextColor3 = UIStyle.Color.CreamBright
	titleLbl.FontFace = UIStyle.FontFace.CinzelBold
	titleLbl.TextSize = 18
	titleLbl.TextXAlignment = Enum.TextXAlignment.Left
	titleLbl.TextYAlignment = Enum.TextYAlignment.Center
	titleLbl.Parent = titleBar

	-- Bottom hairline of the title bar
	local trim = Instance.new("Frame")
	trim.Size = UDim2.new(1, 0, 0, 1)
	trim.Position = UDim2.new(0, 0, 1, -1)
	trim.BackgroundColor3 = UIStyle.Color.BorderStrong
	trim.BackgroundTransparency = 0.35
	trim.BorderSizePixel = 0
	trim.Parent = titleBar

	local closeBtn = Instance.new("TextButton")
	local closeSize = Platform.isTouch and 32 or 26
	closeBtn.Size = UDim2.fromOffset(closeSize, closeSize)
	closeBtn.Position = UDim2.new(1, -10, 0.5, 0)
	closeBtn.AnchorPoint = Vector2.new(1, 0.5)
	closeBtn.BackgroundTransparency = 1
	closeBtn.BorderSizePixel = 0
	closeBtn.AutoButtonColor = false
	closeBtn.Text = "\u{2715}"
	closeBtn.TextColor3 = UIStyle.Color.GoldDim
	closeBtn.FontFace = UIStyle.FontFace.CinzelBold
	closeBtn.TextSize = 13
	closeBtn.Parent = titleBar

	closeBtn.MouseEnter:Connect(function()
		closeBtn.TextColor3 = UIStyle.Color.Bad
	end)
	closeBtn.MouseLeave:Connect(function()
		closeBtn.TextColor3 = UIStyle.Color.TextMuted
	end)

	-- Body
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = UDim2.new(1, 0, 1, -TITLE_BAR_H)
	body.Position = UDim2.fromOffset(0, TITLE_BAR_H)
	body.BackgroundTransparency = 1
	body.Parent = root

	-- ============ Drag handling ============
	local dragging = false
	local dragInput = nil
	local dragStart = nil
	local startPos = nil
	local moveConn = nil
	local endConn = nil

	local function stopDrag()
		dragging = false
		dragInput = nil
		if moveConn then moveConn:Disconnect(); moveConn = nil end
		if endConn then endConn:Disconnect(); endConn = nil end
		-- Persist position on drag-end
		_positions[opts.id] = root.Position
	end

	titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragInput = input
			dragStart = input.Position
			startPos = root.Position
			-- Bring to front on click
			task.defer(function() bringToFront(handle) end)
			endConn = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					stopDrag()
				end
			end)
			-- Drag-update connection lives only for the duration of this drag.
			-- This avoids 5 leaked module-level handlers (one per window).
			moveConn = UserInputService.InputChanged:Connect(function(other)
				if not dragging then return end
				if other ~= dragInput then
					if other.UserInputType ~= Enum.UserInputType.MouseMovement then return end
				end
				local delta = other.Position - dragStart
				local newPos = UDim2.fromOffset(
					startPos.X.Offset + delta.X,
					startPos.Y.Offset + delta.Y
				)
				local vp = viewportSize(screenGui)
				root.Position = clampPosition(newPos, root.Size, vp)
			end)
		end
	end)

	-- Click anywhere on the window to bring it to front
	root.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			bringToFront(handle)
		end
	end)

	-- Re-clamp on viewport resize (recompute size cap and position)
	screenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if not root.Visible then return end
		local vp = viewportSize(screenGui)
		root.Size = clampSize(opts.size, vp)
		root.Position = clampPosition(root.Position, root.Size, vp)
	end)

	-- ============ Lifecycle ============
	local isOpen = false

	local function tweenIn()
		if UIStyle.ReduceMotion then return end
		root.BackgroundTransparency = 0.4
		local startSize = UDim2.fromOffset(
			math.floor(root.Size.X.Offset * 0.94),
			math.floor(root.Size.Y.Offset * 0.94)
		)
		local targetSize = root.Size
		root.Size = startSize
		local info = UIStyle.tween(UIStyle.Motion.Fast)
		TweenService:Create(root, info, {
			Size = targetSize,
			BackgroundTransparency = 0,
		}):Play()
	end

	local function open(animated)
		if isOpen then
			bringToFront(handle)
			return
		end
		isOpen = true
		screenGui.Enabled = true
		-- Restore last position or default-center
		local vp = viewportSize(screenGui)
		local desired = _positions[opts.id] or defaultCenter(root.Size, vp)
		root.Position = clampPosition(desired, root.Size, vp)
		root.Visible = true
		if animated ~= false then tweenIn() end
		bringToFront(handle)
	end

	local function close(animated)
		if not isOpen then return end
		isOpen = false
		_positions[opts.id] = root.Position
		if animated ~= false and not UIStyle.ReduceMotion then
			local info = UIStyle.tween(UIStyle.Motion.Fast)
			local tween = TweenService:Create(root, info, {
				BackgroundTransparency = 0.4,
			})
			tween.Completed:Connect(function()
				root.Visible = false
				screenGui.Enabled = false
				root.BackgroundTransparency = 0
				if opts.onClose then pcall(opts.onClose) end
			end)
			tween:Play()
		else
			root.Visible = false
			screenGui.Enabled = false
			if opts.onClose then pcall(opts.onClose) end
		end
		-- Remove from stack
		for i = #_stack, 1, -1 do
			if _stack[i] == handle then
				table.remove(_stack, i)
				break
			end
		end
	end

	closeBtn.MouseButton1Click:Connect(function() close(true) end)

	-- ============ Public handle ============
	handle = {
		id = opts.id,
		screenGui = screenGui,
		root = root,
		body = body,
		titleBar = titleBar,
		closeBtn = closeBtn,

		open = open,
		close = close,
		toggle = function()
			if isOpen then close(true) else open(true) end
		end,
		isOpen = function() return isOpen end,
		bringToFront = function() bringToFront(handle) end,
		setTitle = function(t) titleLbl.Text = t or "" end,
		setSize = function(sz)
			local vp = viewportSize(screenGui)
			root.Size = clampSize(sz, vp)
			root.Position = clampPosition(root.Position, root.Size, vp)
		end,
		destroy = function()
			close(false)
			screenGui:Destroy()
			_instances[opts.id] = nil
		end,
	}

	_instances[opts.id] = handle
	return handle
end

-- Topmost open window (for Esc cascade)
function MovableWindow.topmostOpen()
	for i = #_stack, 1, -1 do
		local h = _stack[i]
		if h and h.isOpen() then return h end
	end
	return nil
end

return MovableWindow
