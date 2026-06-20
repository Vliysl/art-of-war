local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Spacing = DesignSystem.Spacing
local Shells = DesignSystem.Shells

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

	local root = Shells.create("tooltip_shell", {
		Name = "Tooltip",
		Size = UDim2.fromOffset(config.width or 250, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		ZIndex = config.zIndex or 80,
	})

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
	if DesignSystem.Responsive.isTouch() then
		return
	end
	local current
	local function clear()
		if current then
			current:Destroy()
			current = nil
		end
	end
	-- Cursor-follow that is UIScale-safe (divide by the host layer's ResponsiveScale) and clamps/
	-- flips inside the viewport, so the tooltip lands at the cursor on any resolution.
	local function place()
		if not current then
			return
		end
		local sg = current.Parent
		local us = sg and sg:FindFirstChildWhichIsA("UIScale")
		local scale = (us and us.Scale) or 1
		local cam = workspace.CurrentCamera
		local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
		local size = current.AbsoluteSize
		local w = size.X > 0 and size.X or current.Size.X.Offset * scale
		local h = size.Y > 0 and size.Y or 120 * scale
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
		local layer = layerOverride or target:FindFirstAncestorWhichIsA("ScreenGui")
		if not layer then
			return
		end
		current = builder()
		current:SetAttribute("AoWInputSink", false)
		current.Parent = layer
		place()
	end)
	target.MouseMoved:Connect(place)
	target.MouseLeave:Connect(clear)
	target.Destroying:Connect(clear)
end

return Tooltip
