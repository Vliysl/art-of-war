local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Spacing = DesignSystem.Spacing
local Icons = DesignSystem.Icons
local Shells = DesignSystem.Shells
local CountryBadge = require(script.Parent.Parent.Components.CountryBadge)
local Tooltip = require(script.Parent.Parent.Components.Tooltip)

local CountryBar = {}

local MENUS = { "Politics", "Economy", "Military", "Diplomacy", "Research", "Missions", "Settings" }
local PILL_W = 104
local NAME_W = 200
local PILLS_RESERVE = 300

local STAT_TIPS = {
	Treasury = { title = "Treasury", body = "Gold in your treasury. The green value is your monthly income." },
	Manpower = { title = "Manpower", body = "Recruits available to raise and reinforce regiments." },
	PowerProj = { title = "Political Power", body = "Spent on laws, policies, diplomacy, and national actions." },
	Stability = {
		title = "Stability",
		body = "National stability. Higher stability improves income and lowers unrest.",
	},
	Legitimacy = {
		title = "Legitimacy",
		body = "Government legitimacy. Low legitimacy raises unrest and weakens your rule.",
	},
}

local function text(parent, str, role, color, props)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Text = str or ""
	l.TextColor3 = color or Colors.TextPrimary
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Center
	l.TextTruncate = Enum.TextTruncate.AtEnd
	Typography.apply(l, role)
	for k, v in props or {} do
		l[k] = v
	end
	if not (props and props.Parent) then
		l.Parent = parent
	end
	return l
end

-- Builds one stat pill and returns handles to its mutable labels. The value/delta text is set later
-- (and on every change) via CountryBar.update -> setResources, so the bar never needs to be rebuilt.
local function statPill(parent, iconKey, order, withDelta, tooltipLayer)
	-- Sharp procedural pill (Frame + UIStroke), not the rounded `stat_pill_shell` 9-slice -- matches the
	-- owner's sharp-corner preference for the rest of the UI.
	local pill = Instance.new("Frame")
	pill.Name = "StatPill"
	pill.Size = UDim2.fromOffset(PILL_W, 36)
	pill.LayoutOrder = order
	pill.BackgroundColor3 = Colors.SurfaceElevated
	pill.BorderSizePixel = 0
	pill.Parent = parent
	local pillStroke = Instance.new("UIStroke")
	pillStroke.Color = Colors.BorderStrong
	pillStroke.Thickness = 1
	pillStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	pillStroke.Parent = pill

	local icon = Icons.create(iconKey, 14, Colors.TextSecondary)
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.new(0, 12, 0.5, 0)
	icon.Parent = pill

	local valueLabel = text(pill, "", "value", Colors.TextPrimary, {
		Parent = pill,
		Position = UDim2.fromOffset(34, withDelta and 4 or 0),
		Size = UDim2.new(1, -42, 0, withDelta and 16 or 36),
		TextYAlignment = withDelta and Enum.TextYAlignment.Bottom or Enum.TextYAlignment.Center,
	})
	local deltaLabel
	if withDelta then
		deltaLabel = text(pill, "", "caption", Colors.TextSecondary, {
			Parent = pill,
			Position = UDim2.fromOffset(34, 19),
			Size = UDim2.new(1, -42, 0, 13),
		})
	end

	local tip = STAT_TIPS[iconKey]
	if tip and tooltipLayer then
		local hit = Instance.new("TextButton")
		hit.Name = "Hit"
		hit.Size = UDim2.fromScale(1, 1)
		hit.BackgroundTransparency = 1
		hit.AutoButtonColor = false
		hit.Text = ""
		hit.ZIndex = 10
		hit.Parent = pill

		-- Anchor the tooltip ABOVE the pill with a fixed gap (it does NOT follow the cursor). The
		-- cursor stays inside the pill, always below the tooltip, so it can never occlude the cursor
		-- and cause a hover leave/re-enter flicker loop.
		local current
		local function clearTip()
			if current then
				current:Destroy()
				current = nil
			end
		end
		local function anchor()
			if not current then
				return
			end
			local us = tooltipLayer:FindFirstChildWhichIsA("UIScale")
			local scale = (us and us.Scale) or 1
			local cam = workspace.CurrentCamera
			local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
			local tw = current.AbsoluteSize.X > 0 and current.AbsoluteSize.X or 196 * scale
			local th = current.AbsoluteSize.Y > 0 and current.AbsoluteSize.Y or 64 * scale
			local pp, ps = pill.AbsolutePosition, pill.AbsoluteSize
			local x = pp.X + ps.X / 2 - tw / 2
			local y = pp.Y - th - 8
			if y < 8 then
				y = pp.Y + ps.Y + 8
			end
			x = math.clamp(x, 8, math.max(8, vp.X - tw - 8))
			current.Position = UDim2.fromOffset(x / scale, y / scale)
		end
		hit.MouseEnter:Connect(function()
			clearTip()
			current = Tooltip.create({ title = tip.title, body = tip.body, width = 196, compact = true })
			current:SetAttribute("AoWInputSink", false)
			current.Parent = tooltipLayer
			anchor()
			task.defer(anchor)
		end)
		hit.MouseLeave:Connect(clearTip)
		hit.Destroying:Connect(clearTip)
	end
	return { pill = pill, value = valueLabel, delta = deltaLabel }
end

function CountryBar.create(config)
	config = config or {}
	local r = config.resources or {}
	local z = config.zIndex or 5

	local root = Instance.new("Frame")
	root.Name = "CountryStrip"
	root.AnchorPoint = Vector2.new(0, 1)
	root.Position = config.position or UDim2.new(0, 16, 1, -16)
	root.Size = config.size or UDim2.fromOffset(900, 96)
	root.BackgroundTransparency = 1
	root.ZIndex = z
	root:SetAttribute("AoWInputSink", true)

	local bg = Shells.create("hud_country_bar_bg", { ZIndex = z })
	bg.Name = "Bg"
	bg.Parent = root

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.fromScale(1, 1)
	content.BackgroundTransparency = 1
	content.ZIndex = z + 1
	content.Parent = root
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, Spacing.space4)
	pad.PaddingRight = UDim.new(0, Spacing.space4)
	pad.PaddingTop = UDim.new(0, Spacing.space3)
	pad.PaddingBottom = UDim.new(0, Spacing.space2)
	pad.Parent = content

	-- The crest recess is baked into the bar background image, so there is no recess instance to parent
	-- into. `CrestRecess` IS that recess as a real element: a transparent square positioned over the
	-- baked recess. The crest is then a CHILD of it, filling it edge-to-edge (fromScale 1,1) -- so the
	-- crest's size/position is driven entirely by this one container (tune the container, not the crest).
	local recess = Instance.new("Frame")
	recess.Name = "CrestRecess"
	-- Measured directly from the bg art (rbxassetid://101174527323084) against a bar-unit grid: the
	-- recess opening (inside the gold bezel) is ~x[15,87] y[15,82] of the 900x96 bar -> offset (15,15)
	-- size 72x67, vertically centred. The crest (child) fills this 1:1.
	recess.AnchorPoint = Vector2.new(0, 0)
	recess.Position = UDim2.fromOffset(15, 15)
	recess.Size = UDim2.fromOffset(72, 67)
	recess.BackgroundTransparency = 1
	recess.Parent = bg

	local flag = CountryBadge.create({ code = config.code or "XXX", countryColor = config.color, size = "lg" })
	flag.AnchorPoint = Vector2.new(0.5, 0.5)
	flag.Position = UDim2.fromScale(0.5, 0.5)
	flag.Size = UDim2.fromScale(1, 1)
	flag.Parent = recess

	local nameLabel = text(content, config.name or "Unknown", "displayMd", Colors.TextPrimary, {
		Position = UDim2.fromOffset(94, 0),
		Size = UDim2.fromOffset(NAME_W, 24),
	})
	local cult = config.culture and ("  \u{00B7}  " .. config.culture) or ""
	local govLabel = text(content, (config.government or "") .. cult, "bodySm", Colors.TextSecondary, {
		Position = UDim2.fromOffset(94, 26),
		Size = UDim2.fromOffset(NAME_W, 16),
	})

	local pills = Instance.new("Frame")
	pills.Name = "Pills"
	pills.AnchorPoint = Vector2.new(1, 0)
	pills.Position = UDim2.new(1, 0, 0, 2)
	pills.Size = UDim2.new(1, -PILLS_RESERVE, 0, 36)
	pills.BackgroundTransparency = 1
	pills.Parent = content
	local pl = Instance.new("UIListLayout")
	pl.FillDirection = Enum.FillDirection.Horizontal
	pl.HorizontalAlignment = Enum.HorizontalAlignment.Right
	pl.SortOrder = Enum.SortOrder.LayoutOrder
	pl.Padding = UDim.new(0, Spacing.space2)
	pl.VerticalAlignment = Enum.VerticalAlignment.Center
	pl.Parent = pills

	local tipLayer = config.tooltipLayer
	local statPills = {
		treasury = statPill(pills, "Treasury", 1, true, tipLayer),
		manpower = statPill(pills, "Manpower", 2, false, tipLayer),
		pp = statPill(pills, "PowerProj", 3, false, tipLayer),
		stability = statPill(pills, "Stability", 4, false, tipLayer),
		legitimacy = statPill(pills, "Legitimacy", 5, false, tipLayer),
	}

	local function setResources(res)
		res = res or {}
		statPills.treasury.value.Text = res.treasury or "0"
		statPills.treasury.delta.Text = res.treasuryDelta or ""
		statPills.treasury.delta.TextColor3 = Colors.delta(res.treasuryDeltaNum or 0)
		statPills.manpower.value.Text = res.manpower or "0"
		statPills.pp.value.Text = res.pp or "0"
		statPills.stability.value.Text = res.stability or "0"
		statPills.legitimacy.value.Text = res.legitimacy or "0"
	end
	setResources(r)

	local menuRow = Instance.new("Frame")
	menuRow.Name = "MenuRow"
	menuRow.AnchorPoint = Vector2.new(0, 1)
	menuRow.Position = UDim2.new(0, 94, 1, 0)
	menuRow.Size = UDim2.new(1, -94, 0, 22)
	menuRow.BackgroundTransparency = 1
	menuRow.Parent = content
	local ml = Instance.new("UIListLayout")
	ml.FillDirection = Enum.FillDirection.Horizontal
	ml.HorizontalAlignment = Enum.HorizontalAlignment.Left
	ml.SortOrder = Enum.SortOrder.LayoutOrder
	ml.Padding = UDim.new(0, Spacing.space5)
	ml.VerticalAlignment = Enum.VerticalAlignment.Center
	ml.Parent = menuRow

	local buttons = {}
	local active = nil
	local function setActive(key)
		active = key
		for k, b in buttons do
			local on = k == key
			b.label.TextColor3 = on and Colors.Accent or Colors.TextSecondary
			b.underline.BackgroundTransparency = on and 0 or 1
		end
	end

	for i, name in ipairs(MENUS) do
		local btn = Instance.new("TextButton")
		btn.Name = name
		btn.AutomaticSize = Enum.AutomaticSize.X
		btn.Size = UDim2.new(0, 0, 1, 0)
		btn.BackgroundTransparency = 1
		btn.AutoButtonColor = false
		btn.Text = ""
		btn.LayoutOrder = i
		btn.Parent = menuRow

		local lbl = text(btn, name:upper(), "caption", Colors.TextSecondary, {
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.new(0, 0, 1, 0),
		})
		local underline = Instance.new("Frame")
		underline.Name = "Underline"
		underline.AnchorPoint = Vector2.new(0, 1)
		underline.Position = UDim2.new(0, 0, 1, 0)
		underline.Size = UDim2.new(1, 0, 0, 2)
		underline.BackgroundColor3 = Colors.Accent
		underline.BackgroundTransparency = 1
		underline.BorderSizePixel = 0
		underline.Parent = btn

		buttons[name] = { label = lbl, underline = underline }
		btn.MouseEnter:Connect(function()
			if active ~= name then
				lbl.TextColor3 = Colors.TextPrimary
			end
		end)
		btn.MouseLeave:Connect(function()
			if active ~= name then
				lbl.TextColor3 = Colors.TextSecondary
			end
		end)
		btn.MouseButton1Click:Connect(function()
			setActive(name)
			if config.onMenu then
				config.onMenu(name)
			end
		end)
	end
	setActive("Politics")

	-- In-place update: mutate the existing labels/flag instead of destroying + recreating the whole
	-- bar on every economy/army delta. Name/government/flag only change on a (rare) country switch.
	local currentCode = config.code
	local function update(cfg)
		cfg = cfg or {}
		nameLabel.Text = cfg.name or "Unknown"
		local c = cfg.culture and ("  \u{00B7}  " .. cfg.culture) or ""
		govLabel.Text = (cfg.government or "") .. c
		if cfg.code and cfg.code ~= currentCode then
			currentCode = cfg.code
			flag:Destroy()
			flag = CountryBadge.create({ code = cfg.code, countryColor = cfg.color, size = "lg" })
			flag.AnchorPoint = Vector2.new(0.5, 0.5)
			flag.Position = UDim2.fromScale(0.5, 0.5)
			flag.Size = UDim2.fromScale(1, 1)
			flag.Parent = recess
		end
		setResources(cfg.resources)
	end

	if config.parent then
		root.Parent = config.parent
	end
	return { root = root, setActive = setActive, buttons = buttons, update = update }
end

return CountryBar
