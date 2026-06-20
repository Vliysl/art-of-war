local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Spacing = DesignSystem.Spacing
local Animations = DesignSystem.Animations
local Shells = DesignSystem.Shells
local Responsive = DesignSystem.Responsive

local TabBar = {}

function TabBar.create(config)
	config = config or {}
	local tabs = config.tabs or {}
	local height = Responsive.tapHeight(config.height or 34)
	local underlineStyle = config.style ~= "segment"

	local root = Instance.new("Frame")
	root.Name = "TabBar"
	root.Size = config.size or UDim2.new(1, 0, 0, height)
	root.BackgroundTransparency = 1
	root.LayoutOrder = config.layoutOrder or 0

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = config.align == "left" and Enum.HorizontalAlignment.Left
		or Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, underlineStyle and Spacing.space3 or Spacing.space1)
	layout.Parent = root

	local entries = {}
	local active = nil

	local function setActive(key)
		active = key
		for k, e in entries do
			local on = k == key
			e.label.TextColor3 = on and (underlineStyle and Colors.Accent or Colors.TextPrimary) or Colors.TextSecondary
			if e.underline then
				e.underline.ImageTransparency = on and 0 or 1
			end
			if e.bgActive then
				Animations.tween(e.bgActive, Animations.Fast, { ImageTransparency = on and 0 or 1 })
			end
		end
	end

	for i, tab in ipairs(tabs) do
		local key = tab.key or tab.label
		local btn = Instance.new("TextButton")
		btn.Name = key
		btn.AutomaticSize = underlineStyle and Enum.AutomaticSize.X or Enum.AutomaticSize.None
		btn.Size = underlineStyle and UDim2.new(0, 0, 1, 0) or UDim2.new(0, tab.width or 120, 1, 0)
		btn.BackgroundTransparency = 1
		btn.AutoButtonColor = false
		btn.Text = ""
		btn.LayoutOrder = i
		btn.Parent = root

		local entry = {}
		if not underlineStyle then
			local idle = Shells.create("tab_horizontal_idle", { Name = "BgIdle" })
			idle.Parent = btn
			local hover = Shells.create("tab_horizontal_hover", { Name = "BgHover", ImageTransparency = 1 })
			hover.Parent = btn
			local act = Shells.create("tab_horizontal_active", { Name = "BgActive", ImageTransparency = 1 })
			act.Parent = btn
			entry.bgActive = act
			entry.bgHover = hover
		end

		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.Size = UDim2.fromScale(1, 1)
		label.AutomaticSize = underlineStyle and Enum.AutomaticSize.X or Enum.AutomaticSize.None
		label.BackgroundTransparency = 1
		label.Text = (tab.label or key):upper()
		label.TextColor3 = Colors.TextSecondary
		label.TextXAlignment = Enum.TextXAlignment.Center
		Typography.apply(label, "caption")
		label.Parent = btn
		entry.label = label

		if underlineStyle then
			local underline = Shells.create("underline_focus", { Name = "Underline", ImageTransparency = 1 })
			underline.AnchorPoint = Vector2.new(0.5, 1)
			underline.Position = UDim2.new(0.5, 0, 1, 0)
			underline.Size = UDim2.new(1, 8, 0, 3)
			underline.Parent = btn
			entry.underline = underline
		end

		entries[key] = entry
		btn.MouseEnter:Connect(function()
			if active ~= key then
				label.TextColor3 = Colors.TextPrimary
				if entry.bgHover then
					Animations.tween(entry.bgHover, Animations.Fast, { ImageTransparency = 0 })
				end
			end
		end)
		btn.MouseLeave:Connect(function()
			if active ~= key then
				label.TextColor3 = Colors.TextSecondary
				if entry.bgHover then
					Animations.tween(entry.bgHover, Animations.Fast, { ImageTransparency = 1 })
				end
			end
		end)
		btn.MouseButton1Click:Connect(function()
			if active == key then
				return
			end
			setActive(key)
			if config.onChange then
				config.onChange(key)
			end
		end)
	end

	if config.active then
		setActive(config.active)
	elseif tabs[1] then
		setActive(tabs[1].key or tabs[1].label)
	end

	if config.parent then
		root.Parent = config.parent
	end
	return { root = root, setActive = setActive, entries = entries }
end

return TabBar
