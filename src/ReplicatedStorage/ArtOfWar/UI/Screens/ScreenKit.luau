local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Spacing = DesignSystem.Spacing
local Icons = DesignSystem.Icons
local Shells = DesignSystem.Shells
local Components = script.Parent.Parent.Components
local TabBar = require(Components.TabBar)
local SectionDivider = require(Components.SectionDivider)
local StatRow = require(Components.StatRow)

local ScreenKit = {}

function ScreenKit.open(ctx, opts)
	opts = opts or {}
	local hasSub = opts.subtitle ~= nil
	local hasTabs = opts.tabs ~= nil
	local headerHeight = (hasSub and 60 or 44) + (hasTabs and 38 or 0)

	local root = Shells.create(opts.shell or "panel_large_shell", {
		Name = opts.name or "Screen",
		AnchorPoint = opts.anchorPoint or Vector2.new(0, 0),
		Position = opts.position or UDim2.fromOffset(16, 16),
		Size = opts.size or UDim2.new(0, opts.width or 440, 1, -132),
		ZIndex = 1,
	})
	root:SetAttribute("AoWInputSink", true)

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, headerHeight)
	header.BackgroundTransparency = 1
	header.ZIndex = 2
	header.Parent = root
	local hPad = Instance.new("UIPadding")
	hPad.PaddingTop = UDim.new(0, Spacing.space4)
	hPad.PaddingLeft = UDim.new(0, Spacing.space5)
	hPad.PaddingRight = UDim.new(0, Spacing.space5)
	hPad.Parent = header

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, -36, 0, 28)
	title.BackgroundTransparency = 1
	title.Text = opts.title or ""
	title.TextColor3 = Colors.TextPrimary
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 3
	Typography.apply(title, "displayLg")
	title.Parent = header

	if hasSub then
		local sub = Instance.new("TextLabel")
		sub.Name = "Subtitle"
		sub.Position = UDim2.fromOffset(0, 28)
		sub.Size = UDim2.new(1, -36, 0, 16)
		sub.BackgroundTransparency = 1
		sub.Text = opts.subtitle
		sub.TextColor3 = Colors.TextSecondary
		sub.TextXAlignment = Enum.TextXAlignment.Left
		sub.ZIndex = 3
		Typography.apply(sub, "bodySm")
		sub.Parent = header
	end

	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.fromScale(1, 0)
	close.Size = UDim2.fromOffset(30, 30)
	close.BackgroundTransparency = 1
	close.AutoButtonColor = false
	close.Text = ""
	close.ZIndex = 3
	close.Parent = header
	local x = Icons.create("Close", 22, Colors.Accent)
	x.AnchorPoint = Vector2.new(0.5, 0.5)
	x.Position = UDim2.fromScale(0.5, 0.5)
	x.ZIndex = 3
	x.Parent = close
	close.MouseEnter:Connect(function()
		x.ImageColor3 = Colors.AccentHover
	end)
	close.MouseLeave:Connect(function()
		x.ImageColor3 = Colors.Accent
	end)
	if ctx.onClose then
		close.MouseButton1Click:Connect(ctx.onClose)
	end

	local tabHandle
	if hasTabs then
		local tabScroll = Instance.new("ScrollingFrame")
		tabScroll.Name = "Tabs"
		tabScroll.AnchorPoint = Vector2.new(0, 1)
		tabScroll.Position = UDim2.new(0, 0, 1, 0)
		tabScroll.Size = UDim2.new(1, 0, 0, 30)
		tabScroll.BackgroundTransparency = 1
		tabScroll.BorderSizePixel = 0
		tabScroll.ClipsDescendants = true
		tabScroll.ScrollingDirection = Enum.ScrollingDirection.X
		tabScroll.AutomaticCanvasSize = Enum.AutomaticSize.X
		tabScroll.CanvasSize = UDim2.new()
		tabScroll.ScrollBarThickness = 0
		tabScroll.ZIndex = 3
		tabScroll.Parent = header
		tabHandle = TabBar.create({
			parent = tabScroll,
			tabs = opts.tabs,
			style = "underline",
			align = "left",
			active = opts.activeTab,
			onChange = opts.onTab,
		})
		tabHandle.root.AutomaticSize = Enum.AutomaticSize.X
		tabHandle.root.Size = UDim2.new(0, 0, 1, 0)
	end

	local body = Instance.new("ScrollingFrame")
	body.Name = "Body"
	body.Position = UDim2.fromOffset(0, headerHeight)
	body.Size = UDim2.new(1, 0, 1, -headerHeight)
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.ScrollBarThickness = 4
	body.ScrollBarImageColor3 = Colors.BorderStrong
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.CanvasSize = UDim2.new()
	body.ScrollingDirection = Enum.ScrollingDirection.Y
	body.ZIndex = 2
	body.Parent = root
	local bPad = Instance.new("UIPadding")
	bPad.PaddingTop = UDim.new(0, Spacing.space2)
	bPad.PaddingBottom = UDim.new(0, Spacing.space5)
	bPad.PaddingLeft = UDim.new(0, Spacing.space5)
	bPad.PaddingRight = UDim.new(0, Spacing.space5)
	bPad.Parent = body
	local bLayout = Instance.new("UIListLayout")
	bLayout.FillDirection = Enum.FillDirection.Vertical
	bLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bLayout.Padding = UDim.new(0, Spacing.space2)
	bLayout.Parent = body

	if ctx.parent then
		root.Parent = ctx.parent
	end

	return {
		root = root,
		header = header,
		body = body,
		tabs = tabHandle,
		clearBody = function()
			for _, child in body:GetChildren() do
				if child:IsA("GuiObject") then
					child:Destroy()
				end
			end
		end,
		destroy = function()
			root:Destroy()
		end,
	}
end

function ScreenKit.section(parent, label, order)
	return SectionDivider.create({ parent = parent, label = label, layoutOrder = order })
end

function ScreenKit.stat(parent, cfg)
	cfg.parent = parent
	return StatRow.create(cfg)
end

function ScreenKit.buttonRow(parent, order)
	local row = Instance.new("Frame")
	row.Name = "ButtonRow"
	-- Width is constrained to the panel; height grows so wrapped buttons get their own line.
	row.Size = UDim2.new(1, 0, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.BackgroundTransparency = 1
	row.LayoutOrder = order or 0
	row.Parent = parent
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	-- Buttons flow to the next line instead of overflowing the panel edge.
	layout.Wraps = true
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Spacing.space2)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = row
	return row
end

function ScreenKit.note(parent, text, order)
	local l = Instance.new("TextLabel")
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.Size = UDim2.new(1, 0, 0, 0)
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextColor3 = Colors.TextSecondary
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextWrapped = true
	l.LayoutOrder = order or 0
	Typography.apply(l, "bodySm")
	l.Parent = parent
	return l
end

function ScreenKit.spacer(parent, height, order)
	local f = Instance.new("Frame")
	f.Name = "Spacer"
	f.Size = UDim2.new(1, 0, 0, height or Spacing.space2)
	f.BackgroundTransparency = 1
	f.LayoutOrder = order or 0
	f.Parent = parent
	return f
end

-- Leading-edge coalescing throttle: runs `fn` immediately on the first call after a quiet gap, then
-- at most once per `interval` seconds during a burst. So at normal game speed (ticks spaced apart)
-- every tick updates the screen with no delay; the interval only caps pathological per-frame bursts
-- (e.g. while fast-forwarding). Use for data-screen refreshes so an open screen never rebuilds its
-- whole body 60x/second.
function ScreenKit.throttle(fn, interval)
	interval = interval or 0.2
	local pending = false
	local lastClock = 0
	return function()
		if pending then
			return
		end
		pending = true
		local wait = math.max(0, interval - (os.clock() - lastClock))
		task.delay(wait, function()
			pending = false
			lastClock = os.clock()
			fn()
		end)
	end
end

return ScreenKit
