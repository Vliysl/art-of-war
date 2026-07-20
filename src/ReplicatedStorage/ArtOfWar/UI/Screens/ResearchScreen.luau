-- ResearchScreen: the HOI4-style leveled technology tree (2026-07 rework). A MOVABLE, resizable window (drag the
-- title bar) with a left pillar rail and a pannable/zoomable node canvas. Nodes are laid out left->right by era
-- and grouped into branch rows; prerequisite lines are drawn automatically. Reads node defs from Data/Technologies
-- and the player's own tech state from the OwnResearch channel (ClientStateCache.getOwnResearch); research actions
-- fire SetResearch/ClearResearch (server-gated by EnableTechTree). Replaces the "coming soon" stub.

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Icons = DesignSystem.Icons
local ScreenKit = require(script.Parent.ScreenKit)
local Technologies = require(script.Parent.Parent.Parent.Data.Technologies)
local WorldConstants = require(script.Parent.Parent.Parent.Shared.WorldConstants)

local ResearchScreen = {}

local ERAS = { 1600, 1650, 1700, 1750, 1800, 1850, 1900 }
local ERA_W = 200
local PAD_X = 40
local PAD_Y = 54
local ROW_H = 150
local NODE_W = 176
local NODE_H = 96
local RAIL_W = 184
local SLOTBAR_H = 60
local MIN_ZOOM, MAX_ZOOM = 0.45, 1.6

local TAB_META = {
	infantry = { label = "Infantry", icon = "Army", order = 1 },
	armor = { label = "Cavalry & Armor", icon = "Shield", order = 2 },
	artillery = { label = "Artillery", icon = "Cannon", order = 3 },
	naval = { label = "Naval", icon = "Ship", order = 4 },
	economy = { label = "Economy", icon = "Economy", order = 5 },
	political = { label = "Political", icon = "Diplomacy", order = 6 },
	command = { label = "Command", icon = "Military", order = 7 },
	research = { label = "Research", icon = "Research", order = 8 },
}

local BRANCH_COLORS = {
	Colors.FactionPopulist,
	Colors.FactionMerchant,
	Colors.FactionAristocrat,
	Colors.FactionMilitary,
	Colors.FactionIntellectual,
	Colors.FactionMonarchist,
}
local function branchColor(name)
	local h = 0
	for i = 1, #name do
		h = (h + string.byte(name, i) * i) % #BRANCH_COLORS
	end
	return BRANCH_COLORS[h + 1]
end

-- ── Build the pillar/branch model from the data ────────────────────────────────
local function buildModel()
	local pillars = {}
	for _, def in Technologies do
		local tab = def.tab or "misc"
		local p = pillars[tab]
		if not p then
			p = { id = tab, nodes = {}, branches = {}, branchMinEra = {} }
			pillars[tab] = p
		end
		table.insert(p.nodes, def)
		local br = def.category or "general"
		if not p.branches[br] then
			p.branches[br] = true
			p.branchMinEra[br] = def.era or 9999
		elseif (def.era or 9999) < p.branchMinEra[br] then
			p.branchMinEra[br] = def.era or 9999
		end
	end
	-- order branches within a pillar by earliest era, then name -> stable row index
	for _, p in pillars do
		local names = {}
		for br in p.branches do
			table.insert(names, br)
		end
		table.sort(names, function(a, b)
			if p.branchMinEra[a] ~= p.branchMinEra[b] then
				return p.branchMinEra[a] < p.branchMinEra[b]
			end
			return a < b
		end)
		p.branchRow = {}
		for i, br in ipairs(names) do
			p.branchRow[br] = i - 1
		end
		p.rowCount = #names
	end
	-- ordered pillar list
	local order = {}
	for id in pillars do
		table.insert(order, id)
	end
	table.sort(order, function(a, b)
		local oa = (TAB_META[a] and TAB_META[a].order) or 99
		local ob = (TAB_META[b] and TAB_META[b].order) or 99
		if oa ~= ob then
			return oa < ob
		end
		return a < b
	end)
	return pillars, order
end

local function eraIndex(era)
	for i, e in ipairs(ERAS) do
		if era == e then
			return i - 1
		end
		if era and era < e then
			return math.max(0, i - 2)
		end
	end
	return #ERAS -- nil/modern -> past the last column
end

local function costForLevel(def, level)
	local c = def.cost
	if type(c) == "table" then
		if c.base then
			return c.base * (c.growth or 1) ^ (level - 1)
		end
		return c[level] or c[#c] or 0
	elseif type(c) == "number" then
		return c
	end
	return 0
end

local function stroke(inst, color, thickness)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness or 1
	s.Parent = inst
	return s
end

local function corner(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 5)
	c.Parent = inst
	return c
end

function ResearchScreen.create(ctx)
	local model, pillarOrder = buildModel()

	local viewport = (workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize) or Vector2.new(1280, 720)
	local winW = math.min(1040, viewport.X - 40)
	local winH = math.min(660, viewport.Y - 150)

	local win = ScreenKit.open(ctx, {
		name = "ResearchScreen",
		title = "Research",
		subtitle = "Technology",
		shell = "panel_large_shell",
		noBody = true,
		anchorPoint = Vector2.new(0, 0),
		position = UDim2.fromOffset(
			math.floor((viewport.X - winW) / 2),
			math.max(12, math.floor((viewport.Y - winH) / 2) - 20)
		),
		size = UDim2.fromOffset(winW, winH),
	})
	local root = win.root
	local headerH = win.headerHeight

	-- ── Movable window: drag by the header ─────────────────────────────────────
	do
		local dragging, dragStart, startPos
		win.header.InputBegan:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				dragging = true
				dragStart = input.Position
				startPos = root.Position
			end
		end)
		UserInputService.InputChanged:Connect(function(input)
			if not dragging then
				return
			end
			if
				input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch
			then
				local d = input.Position - dragStart
				root.Position =
					UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
			end
		end)
		UserInputService.InputEnded:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				dragging = false
			end
		end)
	end

	-- ── Content region: left rail + right pane ─────────────────────────────────
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Position = UDim2.fromOffset(0, headerH)
	content.Size = UDim2.new(1, 0, 1, -headerH)
	content.ZIndex = 2
	content.Parent = root

	local rail = Instance.new("Frame")
	rail.Name = "Rail"
	rail.BackgroundColor3 = Colors.SurfaceSunken
	rail.BackgroundTransparency = 0.25
	rail.BorderSizePixel = 0
	rail.Size = UDim2.new(0, RAIL_W, 1, 0)
	rail.ZIndex = 2
	rail.Parent = content
	local railList = Instance.new("UIListLayout")
	railList.Padding = UDim.new(0, 3)
	railList.SortOrder = Enum.SortOrder.LayoutOrder
	railList.Parent = rail
	local railPad = Instance.new("UIPadding")
	railPad.PaddingTop = UDim.new(0, 10)
	railPad.PaddingLeft = UDim.new(0, 10)
	railPad.PaddingRight = UDim.new(0, 10)
	railPad.Parent = rail

	local rightPane = Instance.new("Frame")
	rightPane.Name = "RightPane"
	rightPane.BackgroundTransparency = 1
	rightPane.Position = UDim2.fromOffset(RAIL_W, 0)
	rightPane.Size = UDim2.new(1, -RAIL_W, 1, 0)
	rightPane.ZIndex = 2
	rightPane.Parent = content

	local slotBar = Instance.new("Frame")
	slotBar.Name = "SlotBar"
	slotBar.BackgroundColor3 = Colors.SurfaceSunken
	slotBar.BackgroundTransparency = 0.4
	slotBar.BorderSizePixel = 0
	slotBar.Size = UDim2.new(1, 0, 0, SLOTBAR_H)
	slotBar.ZIndex = 3
	slotBar.Parent = rightPane
	local slotList = Instance.new("UIListLayout")
	slotList.FillDirection = Enum.FillDirection.Horizontal
	slotList.Padding = UDim.new(0, 8)
	slotList.VerticalAlignment = Enum.VerticalAlignment.Center
	slotList.SortOrder = Enum.SortOrder.LayoutOrder
	slotList.Parent = slotBar
	local slotPad = Instance.new("UIPadding")
	slotPad.PaddingLeft = UDim.new(0, 12)
	slotPad.PaddingRight = UDim.new(0, 12)
	slotPad.Parent = slotBar

	-- Stage = clip; World = panned/zoomed content
	local stage = Instance.new("Frame")
	stage.Name = "Stage"
	stage.BackgroundColor3 = Colors.SurfaceSunken
	stage.BackgroundTransparency = 0.55
	stage.BorderSizePixel = 0
	stage.ClipsDescendants = true
	stage.Position = UDim2.fromOffset(0, SLOTBAR_H)
	stage.Size = UDim2.new(1, 0, 1, -SLOTBAR_H)
	stage.ZIndex = 2
	stage.Active = true
	stage.Parent = rightPane

	local world = Instance.new("Frame")
	world.Name = "World"
	world.BackgroundTransparency = 1
	world.Position = UDim2.fromOffset(0, 0)
	world.Size = UDim2.fromOffset(4000, 2000)
	world.ZIndex = 2
	world.Parent = stage
	local worldScale = Instance.new("UIScale")
	worldScale.Scale = 1
	worldScale.Parent = world

	-- Era column header (pans horizontally with world, fixed vertically)
	local eraHeader = Instance.new("Frame")
	eraHeader.Name = "EraHeader"
	eraHeader.BackgroundColor3 = Colors.SurfaceSunken
	eraHeader.BackgroundTransparency = 0.15
	eraHeader.BorderSizePixel = 0
	eraHeader.Size = UDim2.new(1, 0, 0, 26)
	eraHeader.ZIndex = 6
	eraHeader.Parent = stage
	local eraHeaderInner = Instance.new("Frame")
	eraHeaderInner.BackgroundTransparency = 1
	eraHeaderInner.Size = UDim2.fromScale(1, 1)
	eraHeaderInner.ZIndex = 6
	eraHeaderInner.Parent = eraHeader

	-- ── Detail panel (right overlay) ───────────────────────────────────────────
	local detail = Instance.new("Frame")
	detail.Name = "Detail"
	detail.BackgroundColor3 = Colors.SurfaceElevated
	detail.BorderSizePixel = 0
	detail.AnchorPoint = Vector2.new(1, 0)
	detail.Position = UDim2.fromScale(1, 0)
	detail.Size = UDim2.new(0, 300, 1, 0)
	detail.Visible = false
	detail.ZIndex = 10
	detail.Parent = rightPane
	stroke(detail, Colors.BorderStrong, 1)
	local detailPad = Instance.new("UIPadding")
	detailPad.PaddingTop = UDim.new(0, 14)
	detailPad.PaddingBottom = UDim.new(0, 14)
	detailPad.PaddingLeft = UDim.new(0, 16)
	detailPad.PaddingRight = UDim.new(0, 16)
	detailPad.Parent = detail
	local detailList = Instance.new("UIListLayout")
	detailList.Padding = UDim.new(0, 8)
	detailList.SortOrder = Enum.SortOrder.LayoutOrder
	detailList.Parent = detail

	-- ── State + rendering ──────────────────────────────────────────────────────
	local activePillar = pillarOrder[1]
	local ownState = {} -- { techLevel = {}, research = {} }
	local nodeGuis = {}
	local railButtons = {}

	local function fetchOwn()
		local own = ctx.cache and ctx.cache.getOwnResearch and ctx.cache.getOwnResearch()
		ownState = own or {}
		ownState.techLevel = ownState.techLevel or {}
		ownState.research = ownState.research or {}
	end

	local function levelOf(id)
		return ownState.techLevel[id] or 0
	end
	local function maxLevelOf(def)
		return def.maxLevel or 1
	end
	local function prereqsMet(def)
		for _, p in ipairs(def.prerequisites or {}) do
			if levelOf(p) <= 0 then
				return false
			end
		end
		return true
	end
	local function activeSlotOf(id)
		local slots = ownState.research.slots
		if type(slots) ~= "table" then
			return nil
		end
		for i, s in slots do
			if s and s.active == id then
				return i, s
			end
		end
		return nil
	end
	local function nodeState(def)
		local lvl = levelOf(def.id)
		if lvl >= maxLevelOf(def) then
			return "maxed", lvl
		end
		if activeSlotOf(def.id) then
			return "researching", lvl
		end
		if prereqsMet(def) then
			return "available", lvl
		end
		return "locked", lvl
	end

	local function nodePos(pillar, def)
		local x = PAD_X + eraIndex(def.era) * ERA_W + 12
		local y = PAD_Y + (pillar.branchRow[def.category or "general"] or 0) * ROW_H
		return x, y
	end

	local detailContent = {}
	local function clearDetail()
		for _, c in detail:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
	end

	local function makeLabel(parent, text, role, color, order, wrap)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.AutomaticSize = Enum.AutomaticSize.Y
		l.Size = UDim2.new(1, 0, 0, 0)
		l.Text = text
		l.TextColor3 = color or Colors.TextPrimary
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextWrapped = wrap ~= false
		l.LayoutOrder = order or 0
		l.ZIndex = 11
		Typography.apply(l, role or "bodyMd")
		l.Parent = parent
		return l
	end

	local openDetailFor
	local function refreshDetail(id)
		if detailContent.id ~= id then
			return
		end
		openDetailFor(id)
	end

	openDetailFor = function(id)
		local def = Technologies[id]
		if not def then
			return
		end
		detailContent.id = id
		clearDetail()
		detail.Visible = true

		local head = Instance.new("Frame")
		head.BackgroundTransparency = 1
		head.Size = UDim2.new(1, 0, 0, 46)
		head.LayoutOrder = 1
		head.Parent = detail
		local br = makeLabel(head, string.upper(def.category or ""), "caption", branchColor(def.category or "x"), 1)
		br.Size = UDim2.new(1, -24, 0, 12)
		local nm = makeLabel(head, def.name or id, "title", Colors.TextPrimary, 2)
		nm.Position = UDim2.fromOffset(0, 14)
		nm.Size = UDim2.new(1, -24, 0, 24)
		local closeBtn = Instance.new("TextButton")
		closeBtn.AnchorPoint = Vector2.new(1, 0)
		closeBtn.Position = UDim2.fromScale(1, 0)
		closeBtn.Size = UDim2.fromOffset(22, 22)
		closeBtn.BackgroundTransparency = 1
		closeBtn.Text = "✕"
		closeBtn.TextColor3 = Colors.TextSecondary
		closeBtn.ZIndex = 12
		Typography.apply(closeBtn, "bodyMd")
		closeBtn.Parent = head
		closeBtn.MouseButton1Click:Connect(function()
			detail.Visible = false
			detailContent.id = nil
		end)

		local lvl = levelOf(id)
		local maxL = maxLevelOf(def)
		local eraTxt = def.era and ("Era " .. def.era) or "Modern"
		makeLabel(detail, eraTxt .. "  ·  " .. lvl .. " / " .. maxL, "caption", Colors.TextTertiary, 2)
		if def.description then
			makeLabel(detail, def.description, "bodySm", Colors.TextSecondary, 3)
		end

		makeLabel(detail, "LEVELS", "caption", Colors.Accent, 4)
		local levels = Instance.new("Frame")
		levels.BackgroundTransparency = 1
		levels.AutomaticSize = Enum.AutomaticSize.Y
		levels.Size = UDim2.new(1, 0, 0, 0)
		levels.LayoutOrder = 5
		levels.Parent = detail
		local ll = Instance.new("UIListLayout")
		ll.Padding = UDim.new(0, 4)
		ll.SortOrder = Enum.SortOrder.LayoutOrder
		ll.Parent = levels
		for L = 1, maxL do
			local eff = def.effects and def.effects[L]
			local row = Instance.new("Frame")
			row.BackgroundTransparency = 1
			row.AutomaticSize = Enum.AutomaticSize.Y
			row.Size = UDim2.new(1, 0, 0, 0)
			row.LayoutOrder = L
			row.Parent = levels
			local rowLayout = Instance.new("UIListLayout")
			rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
			rowLayout.Parent = row
			local done = L <= lvl
			local sum = (eff and eff.summary) or ("Level " .. L)
			local mods = {}
			if eff and eff.modifiers then
				for k, v in eff.modifiers do
					table.insert(mods, string.format("%+d%% %s", math.floor(v * 100 + 0.5), (k:gsub("_", " "))))
				end
			end
			local dot = done and "◆ " or "◇ "
			local rl =
				makeLabel(row, dot .. L .. ". " .. sum, "bodySm", done and Colors.Accent or Colors.TextSecondary, 1)
			rl.Position = UDim2.fromOffset(0, 0)
			if #mods > 0 then
				local ml = makeLabel(row, "     " .. table.concat(mods, ", "), "caption", Colors.Positive, 2)
				ml.Position = UDim2.fromOffset(0, 0)
			end
			local cost = costForLevel(def, L)
			makeLabel(row, "     ◇ " .. math.floor(cost) .. " research", "caption", Colors.TextTertiary, 3)
		end

		-- action footer
		local state = nodeState(def)
		local foot = Instance.new("Frame")
		foot.BackgroundTransparency = 1
		foot.Size = UDim2.new(1, 0, 0, 40)
		foot.LayoutOrder = 20
		foot.Parent = detail
		local fl = Instance.new("UIListLayout")
		fl.FillDirection = Enum.FillDirection.Horizontal
		fl.Padding = UDim.new(0, 8)
		fl.Parent = foot

		local function actionButton(text, primary, cb)
			local b = Instance.new("TextButton")
			b.Size = UDim2.new(0.5, -4, 1, 0)
			b.BackgroundColor3 = primary and Colors.Accent or Colors.SurfaceOverlay
			b.Text = text
			b.TextColor3 = primary and Colors.TextInverse or Colors.TextSecondary
			b.AutoButtonColor = true
			b.ZIndex = 12
			Typography.apply(b, "label")
			corner(b, 4)
			if not primary then
				stroke(b, Colors.BorderStrong, 1)
			end
			b.Parent = foot
			b.MouseButton1Click:Connect(cb)
			return b
		end

		if state == "maxed" then
			local b = actionButton("Fully researched", false, function() end)
			b.Size = UDim2.new(1, 0, 1, 0)
		elseif state == "locked" then
			local b = actionButton("Prerequisites not met", false, function() end)
			b.Size = UDim2.new(1, 0, 1, 0)
			b.Active = false
		else
			local slotCount = (ownState.research and ownState.research.slotCount)
				or WorldConstants.ResearchSlotsStart
				or 2
			local slotIdx = activeSlotOf(id)
			if slotIdx then
				local b = actionButton("Cancel research", false, function()
					if ctx.fire then
						ctx.fire("ClearResearch", slotIdx)
					end
				end)
				b.Size = UDim2.new(1, 0, 1, 0)
			else
				actionButton("Research Lv " .. (lvl + 1) .. " ▸ Slot 1", true, function()
					if ctx.fire then
						ctx.fire("SetResearch", 1, id)
					end
				end)
				if slotCount >= 2 then
					actionButton("Slot 2", false, function()
						if ctx.fire then
							ctx.fire("SetResearch", 2, id)
						end
					end)
				end
			end
		end
	end

	-- ── Node card ──────────────────────────────────────────────────────────────
	local STATE_STYLE = {
		maxed = { border = Colors.Accent, name = Colors.AccentHover },
		researching = { border = Colors.Accent, name = Colors.TextPrimary },
		available = { border = Colors.BorderStrong, name = Colors.TextPrimary },
		locked = { border = Colors.BorderSubtle, name = Colors.TextDisabled },
	}

	local function makeNode(pillar, def)
		local x, y = nodePos(pillar, def)
		local bc = branchColor(def.category or "x")
		local card = Instance.new("TextButton")
		card.Name = def.id
		card.AutoButtonColor = false
		card.Text = ""
		card.BackgroundColor3 = Colors.SurfaceOverlay
		card.BorderSizePixel = 0
		card.Position = UDim2.fromOffset(x, y)
		card.Size = UDim2.fromOffset(NODE_W, NODE_H)
		card.ZIndex = 4
		card.Parent = world
		corner(card, 6)
		local st = stroke(card, Colors.BorderStrong, 1)

		-- generative banner: branch-tinted gradient + icon watermark
		local banner = Instance.new("Frame")
		banner.Size = UDim2.new(1, 0, 0, 54)
		banner.BackgroundColor3 = bc
		banner.BackgroundTransparency = 0.55
		banner.BorderSizePixel = 0
		banner.ClipsDescendants = true
		banner.ZIndex = 4
		banner.Parent = card
		corner(banner, 6)
		local bg = Instance.new("UIGradient")
		bg.Rotation = 90
		bg.Color = ColorSequence.new(bc, Colors.SurfaceSunken)
		bg.Transparency = NumberSequence.new(0.35, 0.85)
		bg.Parent = banner
		local watermark =
			Icons.create((TAB_META[pillar.id] and TAB_META[pillar.id].icon) or "Research", 40, Colors.TextPrimary)
		watermark.AnchorPoint = Vector2.new(1, 0.5)
		watermark.Position = UDim2.new(1, -8, 0.5, -4)
		watermark.ImageTransparency = 0.7
		watermark.ZIndex = 4
		watermark.Parent = banner
		local scrim = Instance.new("Frame")
		scrim.BackgroundColor3 = Colors.SurfaceOverlay
		scrim.BorderSizePixel = 0
		scrim.AnchorPoint = Vector2.new(0, 1)
		scrim.Position = UDim2.fromScale(0, 1)
		scrim.Size = UDim2.new(1, 0, 0, 26)
		scrim.ZIndex = 4
		scrim.Parent = banner
		local sg = Instance.new("UIGradient")
		sg.Rotation = 90
		sg.Transparency = NumberSequence.new(1, 0)
		sg.Parent = scrim
		local nameLbl = Instance.new("TextLabel")
		nameLbl.BackgroundTransparency = 1
		nameLbl.AnchorPoint = Vector2.new(0, 1)
		nameLbl.Position = UDim2.new(0, 9, 1, -5)
		nameLbl.Size = UDim2.new(1, -18, 0, 16)
		nameLbl.Text = def.name or def.id
		nameLbl.TextColor3 = Colors.TextPrimary
		nameLbl.TextXAlignment = Enum.TextXAlignment.Left
		nameLbl.ZIndex = 5
		Typography.apply(nameLbl, "label")
		nameLbl.Parent = banner

		-- footer: era + pips
		local footer = Instance.new("Frame")
		footer.BackgroundTransparency = 1
		footer.Position = UDim2.fromOffset(9, 58)
		footer.Size = UDim2.new(1, -18, 0, 14)
		footer.ZIndex = 5
		footer.Parent = card
		local eraLbl = Instance.new("TextLabel")
		eraLbl.BackgroundTransparency = 1
		eraLbl.Size = UDim2.new(0.5, 0, 1, 0)
		eraLbl.Text = def.era and tostring(def.era) or "MODERN"
		eraLbl.TextColor3 = Colors.TextTertiary
		eraLbl.TextXAlignment = Enum.TextXAlignment.Left
		eraLbl.ZIndex = 5
		Typography.apply(eraLbl, "caption")
		eraLbl.Parent = footer
		local pips = Instance.new("Frame")
		pips.BackgroundTransparency = 1
		pips.AnchorPoint = Vector2.new(1, 0.5)
		pips.Position = UDim2.fromScale(1, 0.5)
		pips.Size = UDim2.new(0.6, 0, 0, 10)
		pips.ZIndex = 5
		pips.Parent = footer
		local pipList = Instance.new("UIListLayout")
		pipList.FillDirection = Enum.FillDirection.Horizontal
		pipList.HorizontalAlignment = Enum.HorizontalAlignment.Right
		pipList.Padding = UDim.new(0, 3)
		pipList.VerticalAlignment = Enum.VerticalAlignment.Center
		pipList.Parent = pips

		-- progress bar (for researching)
		local track = Instance.new("Frame")
		track.BackgroundColor3 = Colors.SurfaceSunken
		track.BorderSizePixel = 0
		track.Position = UDim2.fromOffset(9, 78)
		track.Size = UDim2.new(1, -18, 0, 4)
		track.ZIndex = 5
		track.Visible = false
		track.Parent = card
		corner(track, 2)
		local fill = Instance.new("Frame")
		fill.BackgroundColor3 = Colors.Accent
		fill.BorderSizePixel = 0
		fill.Size = UDim2.fromScale(0, 1)
		fill.ZIndex = 5
		fill.Parent = track
		corner(fill, 2)

		card.MouseButton1Click:Connect(function()
			openDetailFor(def.id)
		end)

		nodeGuis[def.id] = {
			card = card,
			stroke = st,
			nameLbl = nameLbl,
			banner = banner,
			pips = pips,
			pipList = pipList,
			track = track,
			fill = fill,
			def = def,
		}
	end

	local function refreshNode(id)
		local g = nodeGuis[id]
		if not g then
			return
		end
		local def = g.def
		local state, lvl = nodeState(def)
		local style = STATE_STYLE[state]
		g.stroke.Color = style.border
		g.stroke.Thickness = (state == "maxed" or state == "researching") and 1.6 or 1
		g.nameLbl.TextColor3 = style.name
		g.card.BackgroundTransparency = state == "locked" and 0.35 or 0
		g.banner.BackgroundTransparency = state == "locked" and 0.8 or 0.55
		-- pips
		for _, c in g.pips:GetChildren() do
			if c:IsA("Frame") then
				c:Destroy()
			end
		end
		local maxL = maxLevelOf(def)
		for i = 1, maxL do
			local pip = Instance.new("Frame")
			pip.Size = UDim2.fromOffset(8, 8)
			pip.BackgroundColor3 = i <= lvl and Colors.Accent or Colors.SurfaceSunken
			pip.BorderSizePixel = 0
			pip.LayoutOrder = i
			pip.Parent = g.pips
			corner(pip, 2)
			stroke(pip, i <= lvl and Colors.Accent or Colors.BorderStrong, 1)
		end
		-- progress
		local slotIdx, slot = activeSlotOf(id)
		if slotIdx then
			g.track.Visible = true
			local target = (slot and slot.targetLevel) or (lvl + 1)
			local prog = (ownState.research.progress and ownState.research.progress[id]) or 0
			local cost = costForLevel(def, target)
			local pct = cost > 0 and math.clamp(prog / cost, 0, 1) or 0
			g.fill.Size = UDim2.fromScale(pct, 1)
		else
			g.track.Visible = false
		end
	end

	-- ── Connector lines (orthogonal elbow, 3 segments) ─────────────────────────
	local function drawEdge(pillar, fromDef, toDef, met)
		local x1, y1 = nodePos(pillar, fromDef)
		local x2, y2 = nodePos(pillar, toDef)
		x1 = x1 + NODE_W
		y1 = y1 + NODE_H / 2
		y2 = y2 + NODE_H / 2
		local color = met and Colors.BorderActive or Colors.BorderSubtle
		local midX = x1 + math.max(14, (x2 - x1) / 2)
		local function seg(px, py, w, h)
			local s = Instance.new("Frame")
			s.BackgroundColor3 = color
			s.BorderSizePixel = 0
			s.Position = UDim2.fromOffset(px, py)
			s.Size = UDim2.fromOffset(w, h)
			s.ZIndex = 3
			s.Parent = world
		end
		seg(x1, y1 - 1, midX - x1, 2)
		local ya, yb = math.min(y1, y2), math.max(y1, y2)
		seg(midX - 1, ya, 2, yb - ya)
		seg(midX, y2 - 1, x2 - midX, 2)
	end

	-- ── Render a pillar ────────────────────────────────────────────────────────
	local function renderPillar(id)
		activePillar = id
		detail.Visible = false
		detailContent.id = nil
		for _, c in world:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		nodeGuis = {}
		for _, c in eraHeaderInner:GetChildren() do
			c:Destroy()
		end
		local pillar = model[id]
		if not pillar then
			return
		end
		-- era header ticks + grid columns
		for i, e in ipairs(ERAS) do
			local gx = PAD_X + (i - 1) * ERA_W
			local tick = Instance.new("TextLabel")
			tick.BackgroundTransparency = 1
			tick.Position = UDim2.fromOffset(gx + 12, 0)
			tick.Size = UDim2.fromOffset(80, 26)
			tick.Text = tostring(e)
			tick.TextColor3 = Colors.TextSecondary
			tick.TextXAlignment = Enum.TextXAlignment.Left
			tick.ZIndex = 6
			Typography.apply(tick, "mono")
			tick.Parent = eraHeaderInner
			local col = Instance.new("Frame")
			col.BackgroundColor3 = Colors.BorderSubtle
			col.BackgroundTransparency = 0.7
			col.BorderSizePixel = 0
			col.Position = UDim2.fromOffset(gx, 0)
			col.Size = UDim2.new(0, 1, 0, PAD_Y + pillar.rowCount * ROW_H)
			col.ZIndex = 2
			col.Parent = world
		end
		-- branch band labels
		for br, rowIdx in pillar.branchRow do
			local band = Instance.new("TextLabel")
			band.BackgroundTransparency = 1
			band.Position = UDim2.fromOffset(6, PAD_Y + rowIdx * ROW_H - 22)
			band.Size = UDim2.fromOffset(220, 14)
			band.Text = string.upper(br)
			band.TextColor3 = branchColor(br)
			band.TextXAlignment = Enum.TextXAlignment.Left
			band.ZIndex = 3
			Typography.apply(band, "caption")
			band.Parent = world
		end
		-- edges first (behind nodes)
		for _, def in ipairs(pillar.nodes) do
			for _, pid in ipairs(def.prerequisites or {}) do
				local pre = Technologies[pid]
				if pre and pre.tab == id then
					drawEdge(pillar, pre, def, levelOf(pid) > 0)
				end
			end
		end
		-- nodes
		for _, def in ipairs(pillar.nodes) do
			makeNode(pillar, def)
			refreshNode(def.id)
		end
		-- size the world to fit
		world.Size = UDim2.fromOffset(PAD_X + #ERAS * ERA_W + 120, PAD_Y + pillar.rowCount * ROW_H + 40)
	end

	-- ── Left rail buttons ──────────────────────────────────────────────────────
	local function selectPillar(id)
		for pid, entry in railButtons do
			local sel = pid == id
			entry.btn.BackgroundTransparency = sel and 0.85 or 1
			entry.stroke.Transparency = sel and 0 or 1
			entry.label.TextColor3 = sel and Colors.TextPrimary or Colors.TextSecondary
		end
		renderPillar(id)
		-- reset pan/zoom
		world.Position = UDim2.fromOffset(0, 0)
		worldScale.Scale = 1
	end

	for _, id in ipairs(pillarOrder) do
		local meta = TAB_META[id] or { label = id, icon = "Research" }
		local btn = Instance.new("TextButton")
		btn.Name = id
		btn.AutoButtonColor = false
		btn.Text = ""
		btn.BackgroundColor3 = Colors.BorderSubtle
		btn.BackgroundTransparency = 1
		btn.BorderSizePixel = 0
		btn.Size = UDim2.new(1, 0, 0, 38)
		btn.ZIndex = 3
		btn.Parent = rail
		corner(btn, 4)
		local bs = stroke(btn, Colors.BorderStrong, 1)
		bs.Transparency = 1
		local ico = Icons.create(meta.icon, 20, Colors.TextSecondary)
		ico.Position = UDim2.fromOffset(10, 9)
		ico.ZIndex = 3
		ico.Parent = btn
		local lbl = Instance.new("TextLabel")
		lbl.BackgroundTransparency = 1
		lbl.Position = UDim2.fromOffset(40, 0)
		lbl.Size = UDim2.new(1, -46, 1, 0)
		lbl.Text = meta.label
		lbl.TextColor3 = Colors.TextSecondary
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.ZIndex = 3
		Typography.apply(lbl, "label")
		lbl.Parent = btn
		railButtons[id] = { btn = btn, stroke = bs, label = lbl }
		btn.MouseButton1Click:Connect(function()
			selectPillar(id)
		end)
	end

	-- ── Slot bar rendering ─────────────────────────────────────────────────────
	local function renderSlots()
		for _, c in slotBar:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		local lbl = Instance.new("TextLabel")
		lbl.BackgroundTransparency = 1
		lbl.Size = UDim2.fromOffset(48, 40)
		lbl.Text = "SLOTS"
		lbl.TextColor3 = Colors.TextTertiary
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.LayoutOrder = 0
		Typography.apply(lbl, "caption")
		lbl.Parent = slotBar
		local slotCount = (ownState.research and ownState.research.slotCount) or WorldConstants.ResearchSlotsStart or 2
		local slots = ownState.research.slots or {}
		for i = 1, slotCount do
			local s = slots[i]
			local chip = Instance.new("Frame")
			chip.Size = UDim2.fromOffset(200, 44)
			chip.BackgroundColor3 = Colors.SurfaceOverlay
			chip.BorderSizePixel = 0
			chip.LayoutOrder = i
			chip.Parent = slotBar
			corner(chip, 4)
			stroke(chip, s and s.active and Colors.Accent or Colors.BorderSubtle, 1)
			local t = Instance.new("TextLabel")
			t.BackgroundTransparency = 1
			t.Position = UDim2.fromOffset(10, 6)
			t.Size = UDim2.new(1, -20, 0, 16)
			t.TextXAlignment = Enum.TextXAlignment.Left
			t.ZIndex = 4
			Typography.apply(t, "label")
			t.Parent = chip
			if s and s.active then
				local def = Technologies[s.active]
				t.Text = ((def and def.name) or s.active) .. " → Lv " .. (s.targetLevel or "?")
				t.TextColor3 = Colors.TextPrimary
				local track = Instance.new("Frame")
				track.BackgroundColor3 = Colors.SurfaceSunken
				track.BorderSizePixel = 0
				track.Position = UDim2.fromOffset(10, 30)
				track.Size = UDim2.new(1, -20, 0, 5)
				track.Parent = chip
				corner(track, 3)
				local fill = Instance.new("Frame")
				fill.BackgroundColor3 = Colors.Accent
				fill.BorderSizePixel = 0
				local prog = (ownState.research.progress and ownState.research.progress[s.active]) or 0
				local cost = costForLevel(def, s.targetLevel or 1)
				fill.Size = UDim2.fromScale(cost > 0 and math.clamp(prog / cost, 0, 1) or 0, 1)
				fill.Parent = track
				corner(fill, 3)
			else
				t.Text = "＋ Empty slot"
				t.TextColor3 = Colors.TextTertiary
			end
		end
	end

	-- ── Pan + zoom ─────────────────────────────────────────────────────────────
	do
		local panning, panStart, worldStart
		stage.InputBegan:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				panning = true
				panStart = input.Position
				worldStart = world.Position
			end
		end)
		UserInputService.InputChanged:Connect(function(input)
			if
				panning
				and (
					input.UserInputType == Enum.UserInputType.MouseMovement
					or input.UserInputType == Enum.UserInputType.Touch
				)
			then
				local d = input.Position - panStart
				world.Position = UDim2.fromOffset(worldStart.X.Offset + d.X, worldStart.Y.Offset + d.Y)
				eraHeaderInner.Position = UDim2.fromOffset(world.Position.X.Offset, 0)
			end
			if input.UserInputType == Enum.UserInputType.MouseWheel then
				local ns = math.clamp(worldScale.Scale * (input.Position.Z > 0 and 1.1 or 0.9), MIN_ZOOM, MAX_ZOOM)
				worldScale.Scale = ns
				eraHeaderInner.Position = UDim2.fromOffset(world.Position.X.Offset, 0)
			end
		end)
		UserInputService.InputEnded:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				panning = false
			end
		end)
	end

	-- ── Full refresh ───────────────────────────────────────────────────────────
	local function refreshAll()
		fetchOwn()
		renderSlots()
		for id in nodeGuis do
			refreshNode(id)
		end
		if detailContent.id then
			refreshDetail(detailContent.id)
		end
	end

	fetchOwn()
	selectPillar(activePillar)
	renderSlots()

	local unsub
	if ctx.cache and ctx.cache.onChange then
		unsub = ctx.cache.onChange("ownResearch", ScreenKit.throttle(refreshAll, 0.15))
	end

	return {
		root = root,
		destroy = function()
			if unsub then
				pcall(unsub)
			end
			win.destroy()
		end,
	}
end

return ResearchScreen
