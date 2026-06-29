local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Spacing = DesignSystem.Spacing

local Tooltip = {}

local function line(parent, str, role, color, order, wrap)
	local l = Instance.new("TextLabel")
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.Size = UDim2.new(1, 0, 0, 0)
	l.BackgroundTransparency = 1
	l.Text = str or ""
	l.TextColor3 = color
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.TextWrapped = wrap == true
	l.LayoutOrder = order
	Typography.apply(l, role)
	l.Parent = parent
	return l
end

function Tooltip.create(config)
	config = config or {}

	-- Build the surface from a themed Frame (sharp corners + a hairline border) instead of the
	-- `tooltip_shell` 9-slice: that asset is a speech-bubble callout with a downward pointer tail, so
	-- slicing it stretched the tail into a band and clipped the body's bottom row (mirrors the same fix
	-- already made in ProvinceTooltip).
	local root = Instance.new("Frame")
	root.Name = "Tooltip"
	root.Size = UDim2.fromOffset(config.width or 250, 0)
	root.AutomaticSize = Enum.AutomaticSize.Y
	root.BackgroundColor3 = Colors.SurfaceOverlay
	root.BackgroundTransparency = 0.02
	root.BorderSizePixel = 0
	root.ZIndex = config.zIndex or 80
	root:SetAttribute("AoWInputSink", false)

	local stroke = Instance.new("UIStroke")
	stroke.Color = Colors.BorderStrong
	stroke.Thickness = 1
	stroke.Parent = root

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Spacing.space3)
	pad.PaddingBottom = UDim.new(0, Spacing.space3)
	pad.PaddingLeft = UDim.new(0, Spacing.space4)
	pad.PaddingRight = UDim.new(0, Spacing.space4)
	pad.Parent = root

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Spacing.space1)
	layout.Parent = root

	if config.title then
		line(root, config.title, config.compact and "label" or "title", Colors.TextPrimary, 1, true)
	end
	if config.body then
		line(root, config.body, "bodySm", Colors.TextSecondary, 2, true)
	end

	if config.rows then
		for i, row in ipairs(config.rows) do
			local r = Instance.new("Frame")
			r.Name = "Row"
			r.Size = UDim2.new(1, 0, 0, 18)
			r.BackgroundTransparency = 1
			r.LayoutOrder = 10 + i
			r.Parent = root
			local lbl = Instance.new("TextLabel")
			lbl.Size = UDim2.new(0.6, 0, 1, 0)
			lbl.BackgroundTransparency = 1
			lbl.Text = row.label or ""
			lbl.TextColor3 = Colors.TextSecondary
			lbl.TextXAlignment = Enum.TextXAlignment.Left
			Typography.apply(lbl, "bodySm")
			lbl.Parent = r
			local val = Instance.new("TextLabel")
			val.AnchorPoint = Vector2.new(1, 0)
			val.Position = UDim2.fromScale(1, 0)
			val.Size = UDim2.new(0.4, 0, 1, 0)
			val.BackgroundTransparency = 1
			val.Text = tostring(row.value or "")
			val.TextColor3 = row.color and (type(row.color) == "string" and Colors.resolve(row.color) or row.color)
				or Colors.TextPrimary
			val.TextXAlignment = Enum.TextXAlignment.Right
			Typography.apply(val, "value")
			val.Parent = r
		end
	end

	if config.parent then
		root.Parent = config.parent
	end
	return root
end

function Tooltip.attach(target, builder, layerOverride)
	local UserInputService = game:GetService("UserInputService")
	local RunService = game:GetService("RunService")
	if DesignSystem.Responsive.isTouch() then
		return
	end
	local current
	local primeConn
	local function stopPrime()
		if primeConn then
			primeConn:Disconnect()
			primeConn = nil
		end
	end
	local function clear()
		stopPrime()
		if current then
			current:Destroy()
			current = nil
		end
	end
	-- Cursor-follow that is UIScale-safe (divide by the host layer's ResponsiveScale) and clamps/
	-- flips inside the viewport, so the tooltip lands at the cursor on any resolution. Positioning needs
	-- the tooltip's REAL height: the shell is AutomaticSize.Y, so AbsoluteSize is 0 on the frame it is
	-- parented -- placing then (with a guessed height) made tall tooltips skip the bottom-edge flip and
	-- clip. So `place` no-ops while AbsoluteSize is 0 (the tooltip stays parked offscreen), and the
	-- RenderStepped follow snaps it to the cursor once the layout settles (mirrors ProvinceTooltip).
	local function place()
		if not current then
			return
		end
		local size = current.AbsoluteSize
		if size.Y <= 0 then
			return
		end
		local sg = current.Parent
		local us = sg and sg:FindFirstChildWhichIsA("UIScale")
		local scale = (us and us.Scale) or 1
		local cam = workspace.CurrentCamera
		local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
		local w, h = size.X, size.Y
		local m = UserInputService:GetMouseLocation()
		local x = m.X + 14
		local y = m.Y + 16
		if x + w > vp.X - 8 then
			x = m.X - 14 - w
		end
		if y + h > vp.Y - 8 then
			y = m.Y - 16 - h
		end
		x = math.clamp(x, 8, math.max(8, vp.X - w - 8))
		y = math.clamp(y, 8, math.max(8, vp.Y - h - 8))
		current.Position = UDim2.fromOffset(x / scale, y / scale)
	end
	target.MouseEnter:Connect(function()
		clear()
		-- Tooltips MUST host on the dedicated AoW_Tooltips layer (IgnoreGuiInset = true), not the row's
		-- AoW_Screens ancestor (IgnoreGuiInset = false): GetMouseLocation + the cursor math in `place` are
		-- in true top-left pixels, so an inset-respecting host shifts the tooltip ~36px down (the reported
		-- offset + bottom clip). The layers are siblings under PlayerGui; fall back to the ancestor.
		local sg = target:FindFirstAncestorWhichIsA("ScreenGui")
		local tips = sg and sg.Parent and sg.Parent:FindFirstChild("AoW_Tooltips")
		local layer = layerOverride or tips or sg
		if not layer then
			return
		end
		current = builder()
		current:SetAttribute("AoWInputSink", false)
		-- Park far offscreen (not Visible = false) while the AutomaticSize settles, then `place` snaps it to
		-- the cursor every frame: avoids the one-frame top-left flash when ViewportSize is momentarily (0,0)
		-- and the clamp would pin it to (8, 8). Mirrors ProvinceTooltip's showProvince/follow.
		current.Position = UDim2.fromOffset(-4000, -4000)
		current.Visible = true
		current.Parent = layer
		place()
		primeConn = RunService.RenderStepped:Connect(place)
	end)
	target.MouseLeave:Connect(clear)
	target.Destroying:Connect(clear)
end

return Tooltip
