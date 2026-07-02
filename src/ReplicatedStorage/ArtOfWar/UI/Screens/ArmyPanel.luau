local ScreenKit = require(script.Parent.ScreenKit)
local Components = script.Parent.Parent.Components
local Button = require(Components.Button)
local CountryBadge = require(Components.CountryBadge)
local Modal = require(Components.Modal)
local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Icons = DesignSystem.Icons
local WorldConstants = require(script.Parent.Parent.Parent.Shared.WorldConstants)
local LeaderTraits = require(script.Parent.Parent.Parent.Data.LeaderTraits)

local ArmyPanel = {}

local REGIMENT_STRENGTH = 1000
local MORALE_MAX = 100

-- Combat depth A: entrenchment "L / max (+X% def)" so players see digging-in pays off. Combat
-- already applies this bonus; this only surfaces it. Bonus updates live with entrenchment.
local function entrenchValueText(army)
	local entMax = army.entrenchmentMax or 0
	local base = string.format("%d / %d", math.floor(army.entrenchment or 0), math.floor(entMax))
	if not WorldConstants.EnableDefenseBreakdown then return base end
	local bonus = (army.entrenchment or 0) * (WorldConstants.CombatEntrenchmentDefensePerLevel or 0.03)
	if bonus <= 0 then return base end
	return base .. string.format("  (+%d%% def)", math.floor(bonus * 100 + 0.5))
end

local function toHex(c)
	return string.format("#%02X%02X%02X", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end
local MUTED_HEX = toHex(Colors.TextSecondary)

local function val(v)
	if v == nil or v == "" then
		return "\u{2014}"
	end
	return tostring(v)
end

local function commafy(n)
	n = math.floor(tonumber(n) or 0)
	local out = tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

local function titleCase(text)
	if not text then
		return ""
	end
	local s = tostring(text):gsub("_", " ")
	s = s:gsub("(%a)([%w']*)", function(a, b)
		return a:upper() .. b:lower()
	end)
	return s
end

local function unitName(registries, id)
	local types = registries and registries.UnitTypes
	local def = types and types[id]
	return (def and def.displayName) or titleCase(id)
end

local function moraleColor(pct)
	if pct > 0.6 then
		return "green"
	elseif pct > 0.3 then
		return "amber"
	end
	return "red"
end

local function dominantInfo(army, registries)
	local domId, domCount, total = nil, -1, 0
	local entries = {}
	for unitId, count in pairs((army and army.composition) or {}) do
		if count > 0 then
			table.insert(entries, { id = unitId, count = count })
			total += count
			if count > domCount then
				domCount = count
				domId = unitId
			end
		end
	end
	table.sort(entries, function(a, b)
		return a.count > b.count
	end)
	return {
		entries = entries,
		total = total,
		domName = domId and unitName(registries, domId) or "Force",
	}
end

local function abbrev(n)
	n = math.floor(tonumber(n) or 0)
	if n >= 1000000 then
		return string.format("%.1fM", n / 1000000)
	elseif n >= 1000 then
		return string.format("%.0fK", n / 1000)
	end
	return tostring(n)
end

local function regimentsTotal(army)
	local n = 0
	for _, c in pairs((army and army.composition) or {}) do
		n += c
	end
	return n
end

-- Max regiments this army rebuilds toward (the server's reinforceTarget high-water mark); falls back to
-- current strength for armies without a target yet.
local function reinforceMax(army)
	local cur = regimentsTotal(army)
	local t = army and army.reinforceTarget
	if not t then
		return cur
	end
	local n = 0
	for _, c in pairs(t) do
		n += c
	end
	return math.max(n, cur)
end

local function stateLabel(army, resolveName)
	if not army then
		return "\u{2014}"
	end
	if army.movement and army.movement.toProvinceId then
		local dest = army.movement.toProvinceId
		local nm = resolveName and resolveName(dest)
		return string.format("Marching \u{2192} %s", nm or ("#" .. tostring(dest)))
	end
	local map = {
		idle = "Idle",
		moving = "Moving",
		attacking = "Attacking",
		defending = "Defending",
		retreating = "Retreating",
	}
	return map[army.state] or titleCase(army.state) or "Idle"
end

local function traitNames(registries, officer)
	local traits = officer and officer.traits
	local defs = registries and registries.OfficerTraits
	local names = {}
	if type(traits) == "table" then
		for _, tid in ipairs(traits) do
			local def = defs and defs[tid]
			table.insert(names, (def and def.displayName) or titleCase(tid))
		end
	end
	return names
end

-- Combat depth C: a roster general's "First Last" display name (title omitted to keep rows short).
local function generalName(g)
	if type(g) ~= "table" then
		return "\u{2014}"
	end
	local nm = string.format("%s %s", g.firstName or "", g.lastName or "")
	nm = (nm:gsub("^%s+", ""):gsub("%s+$", ""))
	return nm ~= "" and nm or "\u{2014}"
end

-- Combat depth C: a general's leader-trait display names (from Data/LeaderTraits), joined for a row.
local function generalTraitNames(g)
	local names = {}
	if type(g) == "table" and type(g.traits) == "table" then
		for _, tid in ipairs(g.traits) do
			local def = LeaderTraits[tid]
			names[#names + 1] = (def and def.displayName) or titleCase(tid)
		end
	end
	return names
end

local function modSummary(def)
	local parts = {}
	for k, v in pairs((def and def.modifiers) or {}) do
		if type(v) == "number" and v ~= 0 then
			parts[#parts + 1] = string.format("%s%g%% %s", v > 0 and "+" or "", v * 100, titleCase(k))
		end
	end
	table.sort(parts)
	return table.concat(parts, "  \u{00B7}  ")
end

-- Maps the "green"/"amber"/"red" bar keys (and passthrough Color3) used elsewhere to a fill colour.
local function barColor(name)
	if typeof(name) == "Color3" then
		return name
	elseif name == "green" then
		return Colors.Positive
	elseif name == "red" then
		return Colors.Negative
	elseif name == "amber" then
		return Colors.Warning
	end
	return Colors.Accent
end

local LABEL_W, VALUE_W = 90, 68

-- A dense one-line stat: label · inline bar · value (replaces ScreenKit.stat's bar-below-row layout).
local function inlineStat(parent, cfg)
	local row = Instance.new("Frame")
	row.Name = "InlineStat"
	row.Size = UDim2.new(1, 0, 0, 22)
	row.BackgroundTransparency = 1
	row.LayoutOrder = cfg.order or 0
	row.Parent = parent

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0, 0.5)
	label.Position = UDim2.fromScale(0, 0.5)
	label.Size = UDim2.fromOffset(LABEL_W, 22)
	label.Text = cfg.label or ""
	label.TextColor3 = Colors.TextSecondary
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	Typography.apply(label, "bodySm")
	label.Parent = row

	local value = Instance.new("TextLabel")
	value.BackgroundTransparency = 1
	value.AnchorPoint = Vector2.new(1, 0.5)
	value.Position = UDim2.fromScale(1, 0.5)
	value.Size = UDim2.fromOffset(VALUE_W, 22)
	value.Text = tostring(cfg.value or "")
	value.TextColor3 = Colors.TextPrimary
	value.TextXAlignment = Enum.TextXAlignment.Right
	Typography.apply(value, "value")
	value.Parent = row

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.new(0, LABEL_W + 8, 0.5, 0)
	track.Size = UDim2.new(1, -(LABEL_W + 8) - (VALUE_W + 8), 0, 6)
	track.BackgroundColor3 = Colors.SurfaceSunken
	track.BorderSizePixel = 0
	track.Parent = row
	local tc = Instance.new("UICorner")
	tc.CornerRadius = UDim.new(0, 3)
	tc.Parent = track

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(math.clamp(cfg.pct or 0, 0, 1), 1)
	fill.BackgroundColor3 = barColor(cfg.color)
	fill.BorderSizePixel = 0
	fill.Parent = track
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(0, 3)
	fc.Parent = fill

	-- In-place updater so live values (morale/org/entrench) can refresh without a full panel rebuild.
	local function set(pct, valueText, color)
		fill.Size = UDim2.fromScale(math.clamp(pct or 0, 0, 1), 1)
		if color then
			fill.BackgroundColor3 = barColor(color)
		end
		if valueText ~= nil then
			value.Text = tostring(valueText)
		end
	end
	return row, set
end

-- A small rounded label (trait, toggle state). Auto-widths to its text.
local function pill(parent, text, cfg)
	cfg = cfg or {}
	local p = Instance.new("Frame")
	p.Name = "Pill"
	p.AutomaticSize = Enum.AutomaticSize.X
	p.Size = UDim2.fromOffset(0, 20)
	p.BackgroundColor3 = cfg.bg or Colors.SurfaceSunken
	p.BorderSizePixel = 0
	p.LayoutOrder = cfg.order or 0
	p.Parent = parent
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 10)
	c.Parent = p
	if cfg.stroke then
		local s = Instance.new("UIStroke")
		s.Color = cfg.stroke
		s.Thickness = 1
		s.Parent = p
	end
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 9)
	pad.PaddingRight = UDim.new(0, 9)
	pad.Parent = p
	local l = Instance.new("TextLabel")
	l.AutomaticSize = Enum.AutomaticSize.X
	l.Size = UDim2.fromScale(0, 1)
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextColor3 = cfg.fg or Colors.TextPrimary
	Typography.apply(l, "caption")
	l.Parent = p
	return p
end

-- A bordered row: icon · label · right-aligned mono value (composition entry / aggregate stack).
local function chip(parent, cfg)
	local c = Instance.new("Frame")
	c.Name = "Chip"
	c.Size = UDim2.new(1, 0, 0, 34)
	c.BackgroundColor3 = Colors.SurfaceElevated
	c.BorderSizePixel = 0
	c.LayoutOrder = cfg.order or 0
	c.Parent = parent
	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0, 6)
	cc.Parent = c
	local st = Instance.new("UIStroke")
	st.Color = Colors.BorderSubtle
	st.Thickness = 1
	st.Parent = c
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = c
	local x = 0
	if cfg.icon then
		local ic = Icons.create(cfg.icon, 16, Colors.TextSecondary)
		ic.AnchorPoint = Vector2.new(0, 0.5)
		ic.Position = UDim2.fromScale(0, 0.5)
		ic.Parent = c
		x = 24
	end
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0, 0.5)
	label.Position = UDim2.new(0, x, 0.5, 0)
	label.Size = UDim2.new(0.55, -x, 1, 0)
	label.Text = cfg.label or ""
	label.TextColor3 = Colors.TextPrimary
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	Typography.apply(label, "bodyMd")
	label.Parent = c
	if cfg.value then
		local value = Instance.new("TextLabel")
		value.BackgroundTransparency = 1
		value.AnchorPoint = Vector2.new(1, 0.5)
		value.Position = UDim2.fromScale(1, 0.5)
		value.Size = UDim2.fromScale(0.45, 1)
		value.Text = cfg.value
		value.TextColor3 = Colors.TextSecondary
		value.TextXAlignment = Enum.TextXAlignment.Right
		Typography.apply(value, "mono")
		value.Parent = c
	end
	return c
end

-- A full-width stateful toggle row: name · state pill · key hint (gold-tinted when on).
local function toggleRow(parent, cfg)
	local row = Instance.new("TextButton")
	row.Name = "Toggle"
	row.AutoButtonColor = false
	row.Text = ""
	row.Size = UDim2.new(1, 0, 0, 32)
	row.BackgroundColor3 = cfg.on and Colors.Accent or Colors.SurfaceOverlay
	row.BackgroundTransparency = cfg.on and 0.86 or 0
	row.BorderSizePixel = 0
	row.LayoutOrder = cfg.order or 0
	row.Parent = parent
	local st = Instance.new("UIStroke")
	st.Color = cfg.on and Colors.BorderStrong or Colors.BorderSubtle
	st.Thickness = 1
	st.Parent = row
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = row

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0, 0.5)
	label.Position = UDim2.fromScale(0, 0.5)
	label.Size = UDim2.fromScale(0.6, 1)
	label.Text = cfg.label
	label.TextColor3 = Colors.TextPrimary
	label.TextXAlignment = Enum.TextXAlignment.Left
	Typography.apply(label, "bodyMd")
	label.Parent = row

	local key = Instance.new("TextLabel")
	key.BackgroundTransparency = 1
	key.AnchorPoint = Vector2.new(1, 0.5)
	key.Position = UDim2.fromScale(1, 0.5)
	key.Size = UDim2.fromOffset(12, 32)
	key.Text = cfg.key or ""
	key.TextColor3 = Colors.TextTertiary
	key.FontFace = Typography.Mono
	key.TextSize = Typography.caption
	key.TextXAlignment = Enum.TextXAlignment.Right
	key.Parent = row

	local statePill = pill(row, cfg.on and "On" or "Off", {
		bg = cfg.on and Colors.Accent or Colors.SurfaceSunken,
		fg = cfg.on and Colors.SurfaceBase or Colors.TextSecondary,
		stroke = (not cfg.on) and Colors.BorderSubtle or nil,
	})
	statePill.AnchorPoint = Vector2.new(1, 0.5)
	statePill.Position = UDim2.new(1, -22, 0.5, 0)

	if cfg.onClick then
		row.MouseButton1Click:Connect(cfg.onClick)
	end
	return row
end

-- A 2-column grid of compact action buttons (each label carries its hotkey hint).
local function actionGrid(parent, buttons, order)
	local wrap = Instance.new("Frame")
	wrap.Name = "ActionGrid"
	wrap.Size = UDim2.fromScale(1, 0)
	wrap.AutomaticSize = Enum.AutomaticSize.Y
	wrap.BackgroundTransparency = 1
	wrap.LayoutOrder = order or 0
	wrap.Parent = parent
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(0.5, -4, 0, 32)
	grid.CellPadding = UDim2.fromOffset(8, 8)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Left
	grid.Parent = wrap
	for i, b in ipairs(buttons) do
		local btn = Button.create({
			parent = wrap,
			variant = b.variant or "secondary",
			text = b.text,
			fill = true,
			size = "sm",
			disabled = b.disabled,
			onClick = b.onClick,
		})
		btn.AutomaticSize = Enum.AutomaticSize.None
		btn.LayoutOrder = i
	end
	return wrap
end

-- The prominent strength block: "cur / max men" + reinforcing tag, a bar, and a regiments sub-line.
local function strengthBlock(parent, cfg)
	local f = Instance.new("Frame")
	f.Name = "StrengthBlock"
	f.Size = UDim2.fromScale(1, 0)
	f.AutomaticSize = Enum.AutomaticSize.Y
	f.BackgroundTransparency = 1
	f.LayoutOrder = cfg.order or 0
	f.Parent = parent
	local lay = Instance.new("UIListLayout")
	lay.Padding = UDim.new(0, 4)
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.Parent = f

	local top = Instance.new("Frame")
	top.Size = UDim2.new(1, 0, 0, 20)
	top.BackgroundTransparency = 1
	top.LayoutOrder = 1
	top.Parent = f
	local men = Instance.new("TextLabel")
	men.BackgroundTransparency = 1
	men.AnchorPoint = Vector2.new(0, 0.5)
	men.Position = UDim2.fromScale(0, 0.5)
	men.Size = UDim2.fromScale(0.65, 1)
	men.RichText = true
	men.TextColor3 = Colors.TextPrimary
	men.TextXAlignment = Enum.TextXAlignment.Left
	Typography.apply(men, "bodyLg")
	men.Parent = top
	-- Always created; visibility/text toggled by set() so live updates need no rebuild.
	local tag = Instance.new("TextLabel")
	tag.BackgroundTransparency = 1
	tag.AnchorPoint = Vector2.new(1, 0.5)
	tag.Position = UDim2.fromScale(1, 0.5)
	tag.Size = UDim2.fromScale(0.5, 1)
	tag.TextXAlignment = Enum.TextXAlignment.Right
	Typography.apply(tag, "caption")
	tag.Parent = top

	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, 0, 0, 6)
	track.BackgroundColor3 = Colors.SurfaceSunken
	track.BorderSizePixel = 0
	track.LayoutOrder = 2
	track.Parent = f
	local tc = Instance.new("UICorner")
	tc.CornerRadius = UDim.new(0, 3)
	tc.Parent = track
	local fill = Instance.new("Frame")
	fill.BorderSizePixel = 0
	fill.Parent = track
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(0, 3)
	fc.Parent = fill

	local sub = Instance.new("TextLabel")
	sub.BackgroundTransparency = 1
	sub.Size = UDim2.new(1, 0, 0, 14)
	sub.LayoutOrder = 3
	sub.TextColor3 = Colors.TextTertiary
	sub.TextXAlignment = Enum.TextXAlignment.Left
	Typography.apply(sub, "caption")
	sub.Parent = f

	local function set(curMen, maxMen, reinforcing, enabled, regiments, reserve)
		men.Text = string.format("%s <font color=\"%s\">/ %s men</font>", commafy(curMen), MUTED_HEX, commafy(maxMen))
		tag.Visible = reinforcing == true
		tag.Text = enabled and "reinforcing" or "paused"
		tag.TextColor3 = enabled and Colors.Warning or Colors.TextSecondary
		fill.Size = UDim2.fromScale((maxMen > 0) and math.clamp(curMen / maxMen, 0, 1) or 1, 1)
		fill.BackgroundColor3 = reinforcing and Colors.Warning or Colors.Positive
		sub.Text = string.format(
			"%d regiment%s%s",
			regiments,
			regiments == 1 and "" or "s",
			reserve and (" \u{00B7} drawing from realm reserve (" .. abbrev(reserve) .. ")") or ""
		)
	end
	set(cfg.curMen, cfg.maxMen, cfg.reinforcing, cfg.enabled, cfg.regiments, cfg.reserve)
	return f, set
end

function ArmyPanel.create(ctx)
	local data = ctx.data or {}
	local registries = ctx.registries
	local conns = {}
	local handle

	local activeArmyId = data.armyId
	local provinceId = data.provinceId

	local function armyIds()
		if type(data.armyIds) == "table" and #data.armyIds > 0 then
			return data.armyIds
		end
		return { activeArmyId }
	end

	local function getArmy(id)
		return id and ctx.cache.getArmy(id) or nil
	end

	-- Recruit / Reassign open as non-blocking floating pickers (no scrim) anchored left of the panel;
	-- only one at a time, and re-clicking the same trigger toggles it shut.
	local picker
	local function closePicker()
		if picker then
			local p = picker
			picker = nil
			pcall(function()
				p.handle.close()
			end)
		end
	end

	local function openRecruit()
		local types = registries and registries.UnitTypes
		if not types or not provinceId then
			return
		end
		if picker and picker.kind == "recruit" then
			closePicker()
			return
		end
		closePicker()
		local pool = {}
		for id, def in pairs(types) do
			if def.recruitCost ~= nil then
				table.insert(pool, { id = id, def = def })
			end
		end
		table.sort(pool, function(a, b)
			return (a.def.displayName or a.id) < (b.def.displayName or b.id)
		end)

		local modal = Modal.create({
			parent = handle.root,
			floating = true,
			keepOpenOver = handle.root,
			anchorPoint = Vector2.new(1, 0),
			position = UDim2.fromOffset(-8, 0),
			name = "RecruitPicker",
			title = "Recruit Regiment",
			subtitle = "Province #" .. tostring(provinceId),
			width = 300,
			height = 360,
			onClose = function()
				picker = nil
			end,
		})
		picker = { handle = modal, kind = "recruit" }
		local list = Instance.new("ScrollingFrame")
		list.Size = UDim2.fromScale(1, 1)
		list.BackgroundTransparency = 1
		list.BorderSizePixel = 0
		list.ScrollBarThickness = 4
		list.AutomaticCanvasSize = Enum.AutomaticSize.Y
		list.CanvasSize = UDim2.new()
		list.Parent = modal.content
		local layout = Instance.new("UIListLayout")
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 6)
		layout.Parent = list

		for i, item in ipairs(pool) do
			local row = ScreenKit.stat(list, {
				icon = "Army",
				label = item.def.displayName or titleCase(item.id),
				value = string.format("%s gold", commafy(item.def.recruitCost)),
				mono = true,
				layoutOrder = i,
			})
			local add = Button.create({
				parent = row,
				variant = "secondary",
				text = "Add",
				width = 72,
				size = "sm",
				onClick = function()
					ctx.fire("RecruitUnit", provinceId, item.id, 1)
				end,
			})
			add.AnchorPoint = Vector2.new(1, 0.5)
			add.Position = UDim2.fromScale(1, 0.5)
		end
	end

	local function openOfficerTraits(army)
		local officer = army and army.officer
		local traitDefs = registries and registries.OfficerTraits
		if type(officer) ~= "table" or not traitDefs then
			return
		end
		if picker and picker.kind == "traits" then
			closePicker()
			return
		end
		closePicker()
		local MAX = (type(traitDefs.MAX_TRAITS) == "number" and traitDefs.MAX_TRAITS) or 5
		local domain = army.domain or "ground"
		local pool = {}
		for _, def in pairs(traitDefs) do
			if type(def) == "table" and def.id and (def.domain == "any" or def.domain == domain) then
				pool[#pool + 1] = def
			end
		end
		table.sort(pool, function(a, b)
			return (a.displayName or a.id) < (b.displayName or b.id)
		end)

		local selected = {}
		for _, tid in ipairs(officer.traits or {}) do
			selected[tid] = true
		end
		local function countSelected()
			local n = 0
			for _ in pairs(selected) do
				n += 1
			end
			return n
		end

		local modal = Modal.create({
			parent = handle.root,
			floating = true,
			keepOpenOver = handle.root,
			anchorPoint = Vector2.new(1, 0),
			position = UDim2.fromOffset(-8, 0),
			name = "TraitPicker",
			title = "Officer Traits",
			subtitle = val(officer.name),
			width = 380,
			height = 460,
			footer = true,
			onClose = function()
				picker = nil
			end,
		})
		picker = { handle = modal, kind = "traits" }
		local list = Instance.new("ScrollingFrame")
		list.Size = UDim2.fromScale(1, 1)
		list.BackgroundTransparency = 1
		list.BorderSizePixel = 0
		list.ScrollBarThickness = 4
		list.AutomaticCanvasSize = Enum.AutomaticSize.Y
		list.CanvasSize = UDim2.new()
		list.Parent = modal.content
		local layout = Instance.new("UIListLayout")
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 6)
		layout.Parent = list

		local function renderList()
			for _, child in list:GetChildren() do
				if child:IsA("GuiObject") then
					child:Destroy()
				end
			end
			local atCap = countSelected() >= MAX
			ScreenKit.note(list, string.format("Selected %d / %d traits", countSelected(), MAX), 0)
			for i, def in ipairs(pool) do
				local on = selected[def.id] == true
				local row = ScreenKit.stat(list, {
					icon = "Star",
					label = def.displayName or titleCase(def.id),
					layoutOrder = i * 2,
				})
				local btn = Button.create({
					parent = row,
					variant = on and "secondary" or "ghost",
					text = on and "Remove" or "Add",
					width = 84,
					size = "sm",
					disabled = (not on) and atCap,
					onClick = function()
						if on then
							selected[def.id] = nil
						elseif countSelected() < MAX then
							selected[def.id] = true
						end
						renderList()
					end,
				})
				btn.AnchorPoint = Vector2.new(1, 0.5)
				btn.Position = UDim2.fromScale(1, 0.5)
				local sum = modSummary(def)
				if sum ~= "" then
					ScreenKit.note(list, sum, i * 2 + 1)
				end
			end
		end
		renderList()

		Button.create({
			parent = modal.footer,
			variant = "ghost",
			text = "Cancel",
			layoutOrder = 1,
			onClick = function()
				modal.close()
			end,
		})
		Button.create({
			parent = modal.footer,
			variant = "primary",
			text = "Apply \u{00B7} 25 PP",
			layoutOrder = 2,
			onClick = function()
				local ids = {}
				for id in pairs(selected) do
					ids[#ids + 1] = id
				end
				ctx.fire("ReassignOfficer", activeArmyId, ids)
				modal.close()
			end,
		})
	end

	-- The full current selection (may span provinces, set by HudWiring); falls back to the stack.
	local function selectedIds()
		if type(data.selectedIds) == "table" and #data.selectedIds > 0 then
			return data.selectedIds
		end
		return armyIds()
	end
	local function liveTargets()
		local out = {}
		for _, id in ipairs(selectedIds()) do
			if getArmy(id) then
				out[#out + 1] = id
			end
		end
		if #out == 0 and activeArmyId then
			out[1] = activeArmyId
		end
		return out
	end

	-- Combat depth B: the group id shared by the WHOLE selection, or nil if the armies are ungrouped or
	-- span different groups. Only a single-group selection exposes rename/disband/general/cover actions.
	local function currentGroupId()
		local targets = liveTargets()
		if #targets == 0 then
			return nil
		end
		local gid = nil
		for _, id in ipairs(targets) do
			local a = getArmy(id)
			local g = a and a.groupId
			if not g then
				return nil
			end
			if gid == nil then
				gid = g
			elseif g ~= gid then
				return nil
			end
		end
		return gid
	end

	-- Combat depth B: at least one selected army the local player owns (Form Group prerequisite; the
	-- server also filters to owned armies, so this only gates the button's appearance).
	local function selectionHasOwned()
		for _, id in ipairs(liveTargets()) do
			local a = getArmy(id)
			if a and a.ownerTag == ctx.tag then
				return true
			end
		end
		return false
	end

	-- A single-field name-entry modal (floating, footer Confirm) used by Form Group / Rename Group. The
	-- TextBox seeds `default`; onConfirm receives the trimmed text (falls back to `default` when blank).
	local function openNameEntry(cfg)
		if picker and picker.kind == "name" then
			closePicker()
			return
		end
		closePicker()
		local modal = Modal.create({
			parent = handle.root,
			floating = true,
			keepOpenOver = handle.root,
			anchorPoint = Vector2.new(1, 0),
			position = UDim2.fromOffset(-8, 0),
			name = "NameEntry",
			title = cfg.title or "Name",
			subtitle = cfg.subtitle,
			width = 300,
			height = 150,
			footer = true,
			onClose = function()
				picker = nil
			end,
		})
		picker = { handle = modal, kind = "name" }
		local box = Instance.new("TextBox")
		box.Size = UDim2.new(1, 0, 0, 36)
		box.BackgroundColor3 = Colors.SurfaceSunken
		box.BorderSizePixel = 0
		box.Text = cfg.default or ""
		box.PlaceholderText = cfg.placeholder or "Enter a name"
		box.TextColor3 = Colors.TextPrimary
		box.PlaceholderColor3 = Colors.TextTertiary
		box.ClearTextOnFocus = false
		box.TextXAlignment = Enum.TextXAlignment.Left
		Typography.apply(box, "bodyMd")
		local bp = Instance.new("UIPadding")
		bp.PaddingLeft = UDim.new(0, 8)
		bp.PaddingRight = UDim.new(0, 8)
		bp.Parent = box
		local bc = Instance.new("UICorner")
		bc.CornerRadius = UDim.new(0, 6)
		bc.Parent = box
		box.Parent = modal.content
		local function confirm()
			local text = (box.Text or ""):gsub("^%s+", ""):gsub("%s+$", "")
			if text == "" then
				text = cfg.default or "Army Group"
			end
			cfg.onConfirm(text)
			modal.close()
		end
		box.FocusLost:Connect(function(enterPressed)
			if enterPressed then
				confirm()
			end
		end)
		Button.create({
			parent = modal.footer,
			variant = "primary",
			text = cfg.confirmText or "Confirm",
			layoutOrder = 1,
			onClick = confirm,
		})
	end

	-- Combat depth C: pick an UNASSIGNED (or already-this-group) roster general to command `groupId`.
	local function openGeneralPicker(groupId)
		if not groupId then
			return
		end
		if picker and picker.kind == "general" then
			closePicker()
			return
		end
		closePicker()
		local country = ctx.cache.getCountry(ctx.tag)
		local roster = country and country.generalRoster
		local pool = {}
		if type(roster) == "table" then
			for _, g in pairs(roster) do
				if type(g) == "table" and (g.assignedGroupId == nil or g.assignedGroupId == groupId) then
					pool[#pool + 1] = g
				end
			end
		end
		table.sort(pool, function(a, b)
			return generalName(a) < generalName(b)
		end)

		local modal = Modal.create({
			parent = handle.root,
			floating = true,
			keepOpenOver = handle.root,
			anchorPoint = Vector2.new(1, 0),
			position = UDim2.fromOffset(-8, 0),
			name = "GeneralPicker",
			title = "Assign General",
			subtitle = "Available generals",
			width = 360,
			height = 420,
			onClose = function()
				picker = nil
			end,
		})
		picker = { handle = modal, kind = "general" }
		local list = Instance.new("ScrollingFrame")
		list.Size = UDim2.fromScale(1, 1)
		list.BackgroundTransparency = 1
		list.BorderSizePixel = 0
		list.ScrollBarThickness = 4
		list.AutomaticCanvasSize = Enum.AutomaticSize.Y
		list.CanvasSize = UDim2.new()
		list.Parent = modal.content
		local layout = Instance.new("UIListLayout")
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 6)
		layout.Parent = list

		if #pool == 0 then
			ScreenKit.note(list, "No generals \u{2014} buy one from the Military screen.", 0)
		else
			for i, g in ipairs(pool) do
				local row = ScreenKit.stat(list, {
					icon = "Star",
					label = string.format("%s  \u{00B7}  Lvl %d", generalName(g), g.level or 0),
					layoutOrder = i * 2,
				})
				local assign = Button.create({
					parent = row,
					variant = "secondary",
					text = "Assign",
					width = 84,
					size = "sm",
					onClick = function()
						ctx.fire("AssignGeneral", groupId, g.id)
						modal.close()
					end,
				})
				assign.AnchorPoint = Vector2.new(1, 0.5)
				assign.Position = UDim2.fromScale(1, 0.5)
				local names = generalTraitNames(g)
				if #names > 0 then
					ScreenKit.note(list, table.concat(names, "  \u{00B7}  "), i * 2 + 1)
				end
			end
		end
	end

	-- Shared command actions; the command-bar buttons AND the hotkeys both call these, so they always
	-- operate on the whole current selection and stay in sync.
	local cmd = {}
	function cmd.toggleReinforce()
		local targets = liveTargets()
		local allOn = true
		for _, id in ipairs(targets) do
			local a = getArmy(id)
			if a and a.reinforceEnabled == false then
				allOn = false
				break
			end
		end
		for _, id in ipairs(targets) do
			ctx.fire("SetReinforce", id, not allOn)
		end
	end
	function cmd.toggleCapture()
		local targets = liveTargets()
		local allOn = true
		for _, id in ipairs(targets) do
			local a = getArmy(id)
			if a and not a.autoCapture then
				allOn = false
				break
			end
		end
		for _, id in ipairs(targets) do
			ctx.fire("SetAutoCapture", id, not allOn)
		end
	end
	function cmd.halt()
		for _, id in ipairs(liveTargets()) do
			local a = getArmy(id)
			if a and a.movement then
				ctx.fire("CancelMove", id)
			end
		end
	end
	function cmd.recruit()
		openRecruit()
	end
	function cmd.split()
		local targets = liveTargets()
		if #targets ~= 1 then
			return
		end
		local id = targets[1]
		local cur = getArmy(id)
		if not cur then
			return
		end
		local comp, peeled, bestId, bestCount = {}, 0, nil, 0
		for unitId, count in pairs(cur.composition or {}) do
			if count > 0 then
				local half = math.floor(count / 2)
				if half > 0 then
					comp[unitId] = half
					peeled += half
				end
				if count > bestCount then
					bestCount = count
					bestId = unitId
				end
			end
		end
		if peeled == 0 and bestId then
			comp[bestId] = 1
			peeled = 1
		end
		if peeled > 0 then
			ctx.fire("SplitArmy", id, comp)
		end
	end
	-- Merge is valid only when the whole selection sits on one province.
	local function mergeProvinceId()
		local targets = liveTargets()
		if #targets < 2 then
			return nil
		end
		local pid = getArmy(targets[1]) and getArmy(targets[1]).provinceId
		for _, id in ipairs(targets) do
			local a = getArmy(id)
			if not a or a.provinceId ~= pid then
				return nil
			end
		end
		return pid, targets
	end
	function cmd.merge()
		local pid, targets = mergeProvinceId()
		if not pid then
			return
		end
		local others = {}
		for i = 2, #targets do
			others[#others + 1] = targets[i]
		end
		ctx.fire("MergeArmies", targets[1], others)
	end
	function cmd.disband()
		for _, id in ipairs(liveTargets()) do
			ctx.fire("DisbandArmy", id)
		end
	end

	-- Combat depth B/C/D: "Groups & Command". UX choice (kept deliberately simple + reliable): Form Group
	-- is the sole prerequisite -- Assign General / Cover Border appear ONLY once the selection is a single
	-- group, so there is never an auto-form-then-re-invoke round trip. When ungrouped, only Form Group shows.
	local function buildGroupBar(parent, order)
		if not WorldConstants.EnableArmyGroups then
			return
		end
		local gid = currentGroupId()

		ScreenKit.section(parent, "Groups & Command", order)
		local wrap = Instance.new("Frame")
		wrap.Name = "GroupBar"
		wrap.Size = UDim2.fromScale(1, 0)
		wrap.AutomaticSize = Enum.AutomaticSize.Y
		wrap.BackgroundTransparency = 1
		wrap.LayoutOrder = order + 1
		wrap.Parent = parent
		local list = Instance.new("UIListLayout")
		list.Padding = UDim.new(0, 6)
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Parent = wrap

		if not gid then
			if not selectionHasOwned() then
				ScreenKit.note(wrap, "Select your own armies to form a group.", 1)
				return
			end
			local formBtn = Button.create({
				parent = wrap,
				variant = "secondary",
				text = "Form Group",
				fill = true,
				onClick = function()
					openNameEntry({
						title = "Form Army Group",
						subtitle = "Name the new group",
						default = "Army Group",
						confirmText = "Create",
						onConfirm = function(name)
							ctx.fire("FormArmyGroup", name, liveTargets())
						end,
					})
				end,
			})
			formBtn.LayoutOrder = 1
			return
		end

		local group = ctx.cache.getArmyGroup(gid)
		local name = (group and group.name) or "Army Group"
		chip(wrap, { icon = "Army", label = name, value = string.format("%d armies", group and #(group.memberArmyIds or {}) or #liveTargets()), order = 1 })

		-- Assigned general (Combat depth C): resolve the commander id against the roster for a name.
		if WorldConstants.EnableGenerals then
			local country = ctx.cache.getCountry(ctx.tag)
			local roster = country and country.generalRoster
			local commander = group and group.commanderId and roster and roster[group.commanderId]
			if commander then
				local unassignRow = Instance.new("Frame")
				unassignRow.Size = UDim2.new(1, 0, 0, 26)
				unassignRow.BackgroundTransparency = 1
				unassignRow.LayoutOrder = 2
				unassignRow.Parent = wrap
				local star = Icons.create("Star", 14, Colors.Accent)
				star.AnchorPoint = Vector2.new(0, 0.5)
				star.Position = UDim2.fromScale(0, 0.5)
				star.Parent = unassignRow
				local nm = Instance.new("TextLabel")
				nm.BackgroundTransparency = 1
				nm.AnchorPoint = Vector2.new(0, 0.5)
				nm.Position = UDim2.fromOffset(20, 0)
				nm.Size = UDim2.new(1, -110, 1, 0)
				nm.RichText = true
				nm.Text = string.format("%s <font color=\"%s\">\u{00B7} Lvl %d</font>", generalName(commander), MUTED_HEX, commander.level or 0)
				nm.TextColor3 = Colors.TextPrimary
				nm.TextXAlignment = Enum.TextXAlignment.Left
				nm.TextTruncate = Enum.TextTruncate.AtEnd
				Typography.apply(nm, "bodyMd")
				nm.Parent = unassignRow
				local unassign = Button.create({
					parent = unassignRow,
					variant = "ghost",
					text = "Unassign",
					width = 90,
					size = "sm",
					onClick = function()
						ctx.fire("UnassignGeneral", gid)
					end,
				})
				unassign.AnchorPoint = Vector2.new(1, 0.5)
				unassign.Position = UDim2.fromScale(1, 0.5)
			end
		end

		-- Border cover (Combat depth D): show the covered nation + a Clear when a target is set.
		if WorldConstants.EnableBorderCover and group and group.borderCoverTargetTag then
			local target = ctx.cache.getCountry(group.borderCoverTargetTag)
			local targetName = (target and target.displayName) or group.borderCoverTargetTag
			local coverRow = Instance.new("Frame")
			coverRow.Size = UDim2.new(1, 0, 0, 26)
			coverRow.BackgroundTransparency = 1
			coverRow.LayoutOrder = 3
			coverRow.Parent = wrap
			local cv = Instance.new("TextLabel")
			cv.BackgroundTransparency = 1
			cv.AnchorPoint = Vector2.new(0, 0.5)
			cv.Position = UDim2.fromScale(0, 0.5)
			cv.Size = UDim2.new(1, -90, 1, 0)
			cv.Text = string.format("Cover: %s", targetName)
			cv.TextColor3 = Colors.TextPrimary
			cv.TextXAlignment = Enum.TextXAlignment.Left
			cv.TextTruncate = Enum.TextTruncate.AtEnd
			Typography.apply(cv, "bodyMd")
			cv.Parent = coverRow
			local clearCover = Button.create({
				parent = coverRow,
				variant = "ghost",
				text = "Clear",
				width = 80,
				size = "sm",
				onClick = function()
					ctx.fire("ClearBorderCover", gid)
				end,
			})
			clearCover.AnchorPoint = Vector2.new(1, 0.5)
			clearCover.Position = UDim2.fromScale(1, 0.5)
		end

		local actions = {
			{ text = "Rename", variant = "secondary", onClick = function()
				openNameEntry({
					title = "Rename Group",
					subtitle = name,
					default = name,
					confirmText = "Rename",
					onConfirm = function(newName)
						ctx.fire("RenameArmyGroup", gid, newName)
					end,
				})
			end },
			{ text = "Disband Group", variant = "danger", onClick = function()
				ctx.fire("DisbandArmyGroup", gid)
			end },
		}
		if WorldConstants.EnableGenerals then
			actions[#actions + 1] = { text = "Assign General", variant = "secondary", onClick = function()
				openGeneralPicker(gid)
			end }
		end
		if WorldConstants.EnableBorderCover then
			actions[#actions + 1] = { text = "Cover Border", variant = "secondary", onClick = function()
				ctx.requestTarget({
					kind = "coverBorder",
					groupId = gid,
					hint = "Click the nation to cover the border against.",
				})
			end }
		end
		actionGrid(wrap, actions, 10)
	end

	-- Two-tier orders: stateful toggle rows (Reinforcements / Auto-capture) above a compact action grid +
	-- full-width Disband. Toggles show combined On/Off state; every control carries its hotkey hint.
	local function buildCommandBar(parent, order)
		local targets = liveTargets()
		local primaryArmy = getArmy(targets[1])
		local reAllOn, capAllOn, anyMoving = true, true, false
		for _, id in ipairs(targets) do
			local a = getArmy(id)
			if a then
				if a.reinforceEnabled == false then
					reAllOn = false
				end
				if not a.autoCapture then
					capAllOn = false
				end
				if a.movement then
					anyMoving = true
				end
			end
		end

		ScreenKit.section(parent, "Orders", order)
		local wrap = Instance.new("Frame")
		wrap.Name = "Orders"
		wrap.Size = UDim2.fromScale(1, 0)
		wrap.AutomaticSize = Enum.AutomaticSize.Y
		wrap.BackgroundTransparency = 1
		wrap.LayoutOrder = order + 1
		wrap.Parent = parent
		local list = Instance.new("UIListLayout")
		list.Padding = UDim.new(0, 6)
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Parent = wrap

		toggleRow(wrap, { label = "Reinforcements", on = reAllOn, key = "R", onClick = cmd.toggleReinforce, order = 1 })
		toggleRow(wrap, { label = "Auto-capture", on = capAllOn, key = "C", onClick = cmd.toggleCapture, order = 2 })

		-- Always render the full command grid so the layout is stable and the actions (and their hotkeys)
		-- are discoverable; disable the ones that don't apply to the current selection rather than hiding
		-- them (the cmd.* handlers also self-guard, so a disabled button is purely visual).
		local single = #targets == 1
		local actions = {
			{ text = "Recruit   T", variant = "secondary", onClick = cmd.recruit, disabled = provinceId == nil },
			{ text = "Halt   H", variant = "secondary", onClick = cmd.halt, disabled = not anyMoving },
			{ text = "Split   V", variant = "ghost", onClick = cmd.split, disabled = not (single and primaryArmy and regimentsTotal(primaryArmy) >= 2) },
			{ text = "Merge   G", variant = "ghost", onClick = cmd.merge, disabled = mergeProvinceId() == nil },
		}
		actionGrid(wrap, actions, 3)

		local disband = Button.create({ parent = wrap, variant = "danger", text = "Disband", fill = true, onClick = cmd.disband })
		disband.LayoutOrder = 4

		buildGroupBar(parent, order + 5)
	end

	-- Live-refresh machinery: a refresh only rebuilds the whole body when the STRUCTURE changes
	-- (composition / officer / movement / toggles / selection). Frequently-ticking values (morale, org,
	-- entrenchment, strength, realm reserve) are pushed into the existing widgets in place via liveUpdate.
	local lastSig
	local liveUpdate

	local function sigForArmy(a)
		if not a then
			return "nil"
		end
		local comp = {}
		for u, c in pairs(a.composition or {}) do
			comp[#comp + 1] = tostring(u) .. ":" .. tostring(c)
		end
		table.sort(comp)
		local off = a.officer
		local offSig = "none"
		if type(off) == "table" then
			offSig = (off.name or "")
				.. "|" .. tostring(off.level or 0)
				.. "|" .. tostring(off.experience or 0)
				.. "|" .. table.concat(off.traits or {}, ",")
		end
		return table.concat(comp, ";")
			.. "#" .. offSig
			.. "#mv:" .. (a.movement and tostring(a.movement.toProvinceId) or "0")
			.. "#re:" .. tostring(a.reinforceEnabled ~= false)
			.. "#ac:" .. tostring(a.autoCapture == true)
			.. "#gp:" .. tostring(a.groupId or "0")
	end
	-- Combat depth B/C/D: hash the selection's group record (name / commander / cover target) so the
	-- Groups & Command section rebuilds when any of those change (they live in the armyGroups collection).
	local function groupSig(targets)
		local gid = nil
		for _, id in ipairs(targets) do
			local a = getArmy(id)
			local g = a and a.groupId
			if not g then
				return "nogroup"
			end
			if gid == nil then
				gid = g
			elseif g ~= gid then
				return "mixed"
			end
		end
		if not gid then
			return "nogroup"
		end
		local group = ctx.cache.getArmyGroup(gid)
		if not group then
			return "g:" .. tostring(gid)
		end
		return string.format(
			"g:%s|n:%s|c:%s|b:%s",
			tostring(gid),
			tostring(group.name),
			tostring(group.commanderId or "0"),
			tostring(group.borderCoverTargetTag or "0")
		)
	end
	local function computeSig(targets)
		local base
		if #targets ~= 1 then
			local parts = { "agg", tostring(#targets) }
			for _, id in ipairs(targets) do
				parts[#parts + 1] = tostring(id) .. "=" .. sigForArmy(getArmy(id))
			end
			base = table.concat(parts, "|")
		else
			base = "single:" .. tostring(targets[1]) .. ":" .. sigForArmy(getArmy(targets[1]))
		end
		return base .. "##" .. groupSig(targets)
	end

	-- Aggregate view shown when more than one army is selected (RoN-style "N units selected").
	local function renderAggregate(body, targets)
		local totalReg, curMen, maxMen, worstMorale, worstOrg = 0, 0, 0, 1, 1
		local groups, order = {}, {}
		for _, id in ipairs(targets) do
			local a = getArmy(id)
			if a then
				local r = regimentsTotal(a)
				totalReg += r
				curMen += r * REGIMENT_STRENGTH
				maxMen += reinforceMax(a) * REGIMENT_STRENGTH
				worstMorale = math.min(worstMorale, (a.morale or 0) / MORALE_MAX)
				worstOrg = math.min(worstOrg, (a.organization or 0) / math.max(a.baseOrganization or 1, 1))
				local pid = a.provinceId
				local g = groups[pid]
				if not g then
					g = { pid = pid, reg = 0, men = 0, dom = dominantInfo(a, registries).domName }
					groups[pid] = g
					order[#order + 1] = g
				end
				g.reg += r
				g.men += r * REGIMENT_STRENGTH
			end
		end

		ScreenKit.section(body, string.format("%d units selected", #targets), 1)
		local _, setStr = strengthBlock(body, {
			curMen = curMen,
			maxMen = maxMen,
			reinforcing = curMen < maxMen,
			enabled = true,
			regiments = totalReg,
			order = 2,
		})
		local _, setMor = inlineStat(body, {
			label = "Lowest morale",
			value = string.format("%d%%", math.floor(worstMorale * 100)),
			pct = worstMorale,
			color = moraleColor(worstMorale),
			order = 3,
		})
		local _, setOrgA = inlineStat(body, {
			label = "Lowest org",
			value = string.format("%d%%", math.floor(worstOrg * 100)),
			pct = worstOrg,
			color = "amber",
			order = 4,
		})

		ScreenKit.section(body, "Stacks", 10)
		for i, g in ipairs(order) do
			chip(body, {
				icon = "Army",
				label = string.format("%s  \u{00B7}  #%s", g.dom, tostring(g.pid)),
				value = string.format("%d rgts \u{00B7} %s men", g.reg, commafy(g.men)),
				order = 10 + i,
			})
		end

		ScreenKit.note(body, "Right-click a tile to move all \u{00B7} an adjacent enemy to attack.", 39)
		buildCommandBar(body, 40)

		liveUpdate = function()
			local tReg, cMen, mMen, wMor, wOrg = 0, 0, 0, 1, 1
			for _, id in ipairs(targets) do
				local a = getArmy(id)
				if a then
					local r = regimentsTotal(a)
					tReg += r
					cMen += r * REGIMENT_STRENGTH
					mMen += reinforceMax(a) * REGIMENT_STRENGTH
					wMor = math.min(wMor, (a.morale or 0) / MORALE_MAX)
					wOrg = math.min(wOrg, (a.organization or 0) / math.max(a.baseOrganization or 1, 1))
				end
			end
			setStr(cMen, mMen, cMen < mMen, true, tReg, nil)
			setMor(wMor, string.format("%d%%", math.floor(wMor * 100)), moraleColor(wMor))
			setOrgA(wOrg, string.format("%d%%", math.floor(wOrg * 100)), "amber")
		end
	end

	local function render()
		handle.clearBody()
		local body = handle.body
		local targets = liveTargets()
		lastSig = computeSig(targets)
		liveUpdate = nil
		if #targets > 1 then
			renderAggregate(body, targets)
			return
		end
		activeArmyId = targets[1] or activeArmyId
		local army = getArmy(activeArmyId)
		if not army then
			ScreenKit.note(body, "This army no longer exists.", 1)
			return
		end

		local country = ctx.cache.getCountry(ctx.tag)

		ScreenKit.section(body, "Vitals", 2)
		local vitals = Instance.new("Frame")
		vitals.Name = "Vitals"
		vitals.Size = UDim2.fromScale(1, 0)
		vitals.AutomaticSize = Enum.AutomaticSize.Y
		vitals.BackgroundTransparency = 1
		vitals.LayoutOrder = 3
		vitals.Parent = body
		local vl = Instance.new("UIListLayout")
		vl.Padding = UDim.new(0, 2)
		vl.SortOrder = Enum.SortOrder.LayoutOrder
		vl.Parent = vitals
		local moralePct = math.clamp((army.morale or 0) / MORALE_MAX, 0, 1)
		local _, setMorale = inlineStat(vitals, {
			label = "Morale",
			value = string.format("%d / %d", math.floor(army.morale or 0), MORALE_MAX),
			pct = moralePct,
			color = moraleColor(moralePct),
			order = 1,
		})
		local baseOrg = army.baseOrganization or 0
		local _, setOrg = inlineStat(vitals, {
			label = "Organization",
			value = string.format("%d / %d", math.floor(army.organization or 0), math.floor(baseOrg)),
			pct = (army.organization or 0) / math.max(baseOrg, 1),
			color = "amber",
			order = 2,
		})
		local entMax = army.entrenchmentMax or 0
		local _, setEntrench = inlineStat(vitals, {
			label = "Entrenchment",
			value = entrenchValueText(army),
			pct = (army.entrenchment or 0) / math.max(entMax, 1),
			color = "amber",
			order = 3,
		})

		local info = dominantInfo(army, registries)
		local curR = info.total
		local maxR = reinforceMax(army)
		ScreenKit.section(body, "Strength", 6)
		local _, setStrength = strengthBlock(body, {
			curMen = curR * REGIMENT_STRENGTH,
			maxMen = maxR * REGIMENT_STRENGTH,
			reinforcing = curR < maxR,
			enabled = army.reinforceEnabled ~= false,
			regiments = curR,
			reserve = country and country.manpower or nil,
			order = 7,
		})

		local officer = army.officer
		if type(officer) == "table" then
			ScreenKit.section(body, "Officer", 9)
			local nameRow = Instance.new("Frame")
			nameRow.Size = UDim2.new(1, 0, 0, 26)
			nameRow.BackgroundTransparency = 1
			nameRow.LayoutOrder = 10
			nameRow.Parent = body
			local star = Icons.create("Star", 14, Colors.Accent)
			star.AnchorPoint = Vector2.new(0, 0.5)
			star.Position = UDim2.fromScale(0, 0.5)
			star.Parent = nameRow
			local nm = Instance.new("TextLabel")
			nm.BackgroundTransparency = 1
			nm.AnchorPoint = Vector2.new(0, 0.5)
			nm.Position = UDim2.fromOffset(20, 0)
			nm.Size = UDim2.new(1, -130, 1, 0)
			nm.RichText = true
			nm.Text = string.format("%s <font color=\"%s\">\u{00B7} Lvl %d</font>", val(officer.name), MUTED_HEX, officer.level or 0)
			nm.TextColor3 = Colors.TextPrimary
			nm.TextXAlignment = Enum.TextXAlignment.Left
			nm.TextTruncate = Enum.TextTruncate.AtEnd
			Typography.apply(nm, "bodyMd")
			nm.Parent = nameRow
			local canReassign = country and (country.politicalPower or 0) >= 25
			local reassign = Button.create({
				parent = nameRow,
				variant = "secondary",
				text = "Reassign \u{00B7} 25 PP",
				width = 110,
				size = "sm",
				disabled = not canReassign,
				onClick = function()
					openOfficerTraits(army)
				end,
			})
			reassign.AnchorPoint = Vector2.new(1, 0.5)
			reassign.Position = UDim2.fromScale(1, 0.5)

			local pillRow = Instance.new("Frame")
			pillRow.Size = UDim2.fromScale(1, 0)
			pillRow.AutomaticSize = Enum.AutomaticSize.Y
			pillRow.BackgroundTransparency = 1
			pillRow.LayoutOrder = 11
			pillRow.Parent = body
			local pl = Instance.new("UIListLayout")
			pl.FillDirection = Enum.FillDirection.Horizontal
			pl.Wraps = true
			pl.Padding = UDim.new(0, 6)
			pl.VerticalAlignment = Enum.VerticalAlignment.Center
			pl.Parent = pillRow
			local names = traitNames(registries, officer)
			if #names == 0 then
				pill(pillRow, "No traits", { bg = Colors.SurfaceSunken, fg = Colors.TextSecondary, stroke = Colors.BorderSubtle, order = 0 })
			else
				for i, nme in ipairs(names) do
					pill(pillRow, nme, { bg = Colors.Accent, fg = Colors.SurfaceBase, order = i })
				end
			end
			pill(pillRow, string.format("XP %s", commafy(officer.experience or 0)), { bg = Colors.SurfaceSunken, fg = Colors.TextSecondary, stroke = Colors.BorderSubtle, order = 99 })
		end

		ScreenKit.section(body, "Composition", 20)
		if #info.entries > 0 then
			for i, e in ipairs(info.entries) do
				chip(body, {
					icon = "Army",
					label = unitName(registries, e.id),
					value = string.format("\u{00D7}%d  \u{00B7}  %s men", e.count, commafy(e.count * REGIMENT_STRENGTH)),
					order = 20 + i,
				})
			end
		else
			ScreenKit.note(body, "No regiments in this army.", 21)
		end

		ScreenKit.note(body, "Right-click a tile to move \u{00B7} an adjacent enemy to attack.", 39)
		buildCommandBar(body, 40)

		liveUpdate = function()
			local a = getArmy(activeArmyId)
			if not a then
				return
			end
			local mp = math.clamp((a.morale or 0) / MORALE_MAX, 0, 1)
			setMorale(mp, string.format("%d / %d", math.floor(a.morale or 0), MORALE_MAX), moraleColor(mp))
			local bo = a.baseOrganization or 0
			setOrg((a.organization or 0) / math.max(bo, 1), string.format("%d / %d", math.floor(a.organization or 0), math.floor(bo)), "amber")
			local eM = a.entrenchmentMax or 0
			setEntrench((a.entrenchment or 0) / math.max(eM, 1), entrenchValueText(a), "amber")
			local inf = dominantInfo(a, registries)
			local cR, mR = inf.total, reinforceMax(a)
			local c2 = ctx.cache.getCountry(ctx.tag)
			setStrength(cR * REGIMENT_STRENGTH, mR * REGIMENT_STRENGTH, cR < mR, a.reinforceEnabled ~= false, cR, c2 and c2.manpower or nil)
		end
	end

	-- Header reflects the selection: the dominant unit for one army, an aggregate count for several.
	local function panelTitle()
		local targets = liveTargets()
		if #targets > 1 then
			local totReg = 0
			for _, id in ipairs(targets) do
				totReg += regimentsTotal(getArmy(id))
			end
			return string.format("%d units selected", #targets), string.format("%d regiments", totReg)
		end
		local army = getArmy(targets[1] or activeArmyId)
		local ownerCountry = army and army.ownerTag and ctx.cache.getCountry(army.ownerTag)
		local ownerName = (ownerCountry and ownerCountry.displayName) or (army and army.ownerTag) or "\u{2014}"
		local info = dominantInfo(army, registries)
		local resolveName = function(id)
			local p = ctx.cache.getProvince and ctx.cache.getProvince(id)
			return p and (p.displayCityName or p.name) or nil
		end
		return string.format("%s \u{00D7}%d", info.domName, info.total),
			string.format("%s  \u{00B7}  %s", stateLabel(army, resolveName), ownerName)
	end
	local titleStr, subtitleStr = panelTitle()

	handle = ScreenKit.open(ctx, {
		name = "ArmyPanel",
		shell = "panel_medium_shell",
		title = titleStr,
		subtitle = subtitleStr,
		anchorPoint = Vector2.new(1, 1),
		position = UDim2.new(1, -16, 1, -16),
		-- Fixed height matching the province panel (was autoHeight, which made it tiny for small armies).
		size = UDim2.fromOffset(360, 620),
	})

	-- Small owner crest tucked into the shell header, left of the title (the body no longer carries one).
	do
		local primary = getArmy(liveTargets()[1])
		local oc = primary and primary.ownerTag and ctx.cache.getCountry(primary.ownerTag)
		if primary and handle.header then
			local crest = CountryBadge.create({
				code = primary.ownerTag or "\u{2014}",
				countryColor = oc and oc.color,
				size = "sm",
				parent = handle.header,
			})
			crest.AnchorPoint = Vector2.new(0, 0)
			crest.Position = UDim2.fromOffset(0, 0)
			crest.ZIndex = 3
			local title = handle.header:FindFirstChild("Title")
			local sub = handle.header:FindFirstChild("Subtitle")
			if title then
				title.Position = UDim2.fromOffset(52, 0)
				title.Size = UDim2.new(1, -36 - 52, 0, 28)
			end
			if sub then
				sub.Position = UDim2.fromOffset(52, 28)
				sub.Size = UDim2.new(1, -36 - 52, 0, 16)
			end
		end
	end
	render()

	-- Command hotkeys (RoN-style); active only while the panel is open and not while typing. The cmd
	-- handlers self-guard, so a key is a no-op when its button wouldn't show. X/Esc deselect (HudWiring).
	local hotkeys = {
		[Enum.KeyCode.R] = cmd.toggleReinforce,
		[Enum.KeyCode.C] = cmd.toggleCapture,
		[Enum.KeyCode.H] = cmd.halt,
		[Enum.KeyCode.T] = cmd.recruit,
		[Enum.KeyCode.V] = cmd.split,
		[Enum.KeyCode.G] = cmd.merge,
	}
	local keyConn = game:GetService("UserInputService").InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if not (handle and handle.root and handle.root.Parent) then
			return
		end
		local fn = hotkeys[input.KeyCode]
		if fn then
			fn()
		end
	end)
	table.insert(conns, function()
		keyConn:Disconnect()
	end)

	-- Only rebuild the body when the STRUCTURE changes; otherwise push the live values in place. This
	-- stops the whole panel reflowing every tick as morale/org/entrenchment/strength/reserve update.
	local scheduleRefresh = ScreenKit.throttle(function()
		if not (handle and handle.root and handle.root.Parent) then
			return
		end
		if liveUpdate and computeSig(liveTargets()) == lastSig then
			liveUpdate()
		else
			render()
		end
	end)
	table.insert(conns, ctx.cache.onChangePrefix("armies", scheduleRefresh))
	table.insert(conns, ctx.cache.onChangePrefix("countries", scheduleRefresh))
	-- Combat depth B/C/D: group name / commander / cover live in the armyGroups collection, so watch it
	-- too (guarded so the section still works if the flags are off -- the subscription is just inert).
	if WorldConstants.EnableArmyGroups then
		table.insert(conns, ctx.cache.onChangePrefix("armyGroups", scheduleRefresh))
	end

	return {
		root = handle.root,
		destroy = function()
			closePicker()
			for _, d in conns do
				pcall(d)
			end
			handle.destroy()
		end,
	}
end

return ArmyPanel
