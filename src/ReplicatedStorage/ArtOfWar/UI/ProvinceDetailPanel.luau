local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))
local UIRoot = require(uiFolder:WaitForChild("UIRoot"))
local UIKeybindings = require(uiFolder:WaitForChild("UIKeybindings"))
local Platform = require(ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Modules"):WaitForChild("Platform"))
local WorldConstants = require(ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Shared"):WaitForChild("WorldConstants"))
local EconomyPreview = require(ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Modules"):WaitForChild("EconomyPreview"))
local DebugMode = require(ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Modules"):WaitForChild("DebugMode"))
local SimClock = require(ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Modules"):WaitForChild("SimClock"))
local RunService = game:GetService("RunService")

local ProvinceDetailPanel = {}

local PANEL_W = 380
local PANEL_H = 560
local HEADER_H = 64
local SIBLING_STRIP_H = 28
local TAB_STRIP_H = 30
local LINES_H = 24

local TAB_KEY = {
	Recruitment = "Recruitment",
	Buildings   = "Buildings",
	Information = "Information",
}

local TAB_DEFS = {
	{ key = TAB_KEY.Information, label = "Information", hint = "I" },
	{ key = TAB_KEY.Recruitment, label = "Recruitment", hint = "R" },
	{ key = TAB_KEY.Buildings,   label = "Buildings",   hint = "B" },
}

local CATEGORY_ORDER = { "economic", "military", "industry", "cultural", "other" }

local function titleCase(text)
	if not text then return "-" end
	-- gsub returns (string, count); assign first so callers don't accidentally
	-- forward the count as a varargs argument (e.g. table.insert positional bug).
	local out = (text:gsub("_", " "))
	out = (out:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b:lower() end))
	return out
end

local function addInfoSection(parent, title, height, layoutOrder)
	local section = Instance.new("Frame")
	section.Size = UDim2.new(1, -16, 0, height)
	section.BackgroundColor3 = UIStyle.Color.PanelAlt
	section.BorderSizePixel = 0
	section.LayoutOrder = layoutOrder
	section.ZIndex = UIStyle.Z.Content
	section.Parent = parent
	UIBuilder.corner(section, 2)
	UIBuilder.stroke(section, 1, UIStyle.Color.Border)

	local titleLbl = Instance.new("TextLabel")
	titleLbl.Size = UDim2.new(1, -16, 0, 14)
	titleLbl.Position = UDim2.fromOffset(8, 6)
	titleLbl.BackgroundTransparency = 1
	titleLbl.Text = string.upper(title or "")
	titleLbl.TextColor3 = UIStyle.Color.LedgerSection
	titleLbl.FontFace = UIStyle.FontFace.Cinzel
	titleLbl.TextSize = 11
	titleLbl.TextXAlignment = Enum.TextXAlignment.Left
	titleLbl.TextYAlignment = Enum.TextYAlignment.Center
	titleLbl.ZIndex = UIStyle.Z.Content + 1
	titleLbl.Parent = section

	local trim = Instance.new("Frame")
	trim.Size = UDim2.new(1, -16, 0, 1)
	trim.Position = UDim2.fromOffset(8, 24)
	trim.BackgroundColor3 = UIStyle.Color.LedgerSection
	trim.BackgroundTransparency = 0.5
	trim.BorderSizePixel = 0
	trim.ZIndex = UIStyle.Z.Content
	trim.Parent = section
	return section
end

local function addKeyValue(section, label, value, yOffset, valueColor)
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromOffset(140, 18)
	lbl.Position = UDim2.fromOffset(8, yOffset)
	lbl.BackgroundTransparency = 1
	lbl.Text = label or ""
	lbl.TextColor3 = UIStyle.Color.LedgerLabel
	lbl.FontFace = UIStyle.FontFace.Inter
	lbl.TextSize = 12
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextYAlignment = Enum.TextYAlignment.Center
	lbl.ZIndex = UIStyle.Z.Content + 1
	lbl.Parent = section

	local val = Instance.new("TextLabel")
	val.Size = UDim2.new(1, -156, 0, 18)
	val.Position = UDim2.new(1, -8, 0, yOffset)
	val.AnchorPoint = Vector2.new(1, 0)
	val.BackgroundTransparency = 1
	val.Text = value or "-"
	val.TextColor3 = valueColor or UIStyle.Color.LedgerValue
	val.FontFace = UIStyle.FontFace.Cinzel
	val.TextSize = 13
	val.TextXAlignment = Enum.TextXAlignment.Right
	val.TextYAlignment = Enum.TextYAlignment.Center
	val.ZIndex = UIStyle.Z.Content + 1
	val.Parent = section
	return val
end

local function addProgressKeyValue(section, label, value, max, yOffset, color, valueText)
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromOffset(140, 18)
	lbl.Position = UDim2.fromOffset(8, yOffset)
	lbl.BackgroundTransparency = 1
	lbl.Text = label or ""
	lbl.TextColor3 = UIStyle.Color.LedgerLabel
	lbl.FontFace = UIStyle.FontFace.Inter
	lbl.TextSize = 12
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextYAlignment = Enum.TextYAlignment.Center
	lbl.ZIndex = UIStyle.Z.Content + 1
	lbl.Parent = section

	local container = Instance.new("Frame")
	container.Size = UDim2.new(1, -156, 0, 18)
	container.Position = UDim2.new(1, -8, 0, yOffset)
	container.AnchorPoint = Vector2.new(1, 0)
	container.BackgroundTransparency = 1
	container.ZIndex = UIStyle.Z.Content
	container.Parent = section

	local valueLbl = Instance.new("TextLabel")
	valueLbl.Size = UDim2.new(0.4, -4, 1, 0)
	valueLbl.Position = UDim2.new(1, 0, 0, 0)
	valueLbl.AnchorPoint = Vector2.new(1, 0)
	valueLbl.BackgroundTransparency = 1
	valueLbl.Text = valueText or tostring(value or "-")
	valueLbl.TextColor3 = UIStyle.Color.LedgerPositive
	valueLbl.FontFace = UIStyle.FontFace.Cinzel
	valueLbl.TextSize = 12
	valueLbl.TextXAlignment = Enum.TextXAlignment.Right
	valueLbl.TextYAlignment = Enum.TextYAlignment.Center
	valueLbl.ZIndex = UIStyle.Z.Content + 1
	valueLbl.Parent = container

	local barBg = Instance.new("Frame")
	barBg.Size = UDim2.new(0.6, -4, 0, 6)
	barBg.Position = UDim2.new(0, 0, 0.5, 0)
	barBg.AnchorPoint = Vector2.new(0, 0.5)
	barBg.BackgroundColor3 = UIStyle.Color.Bg
	barBg.BorderSizePixel = 0
	barBg.ZIndex = UIStyle.Z.Content
	barBg.Parent = container
	UIBuilder.corner(barBg, 3)
	UIBuilder.stroke(barBg, 1, UIStyle.Color.Border)

	local cap = max or 0
	local pct = math.clamp(cap > 0 and (value or 0) / cap or 0, 0, 1)
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(pct, 1)
	fill.BackgroundColor3 = color or UIStyle.Color.Gold
	fill.BorderSizePixel = 0
	fill.ZIndex = UIStyle.Z.Content + 1
	fill.Parent = barBg
	UIBuilder.corner(fill, 3)

	return valueLbl
end

local function buildTabBody(parent)
	local body, layout = UIBuilder.scrollingList(parent, {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
	})
	UIBuilder.padding(body, 8)
	if layout then layout.Padding = UDim.new(0, 6) end
	return body
end

local function clearChildren(frame)
	for _, c in frame:GetChildren() do
		if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then
			c:Destroy()
		end
	end
end

local function eligibleUnits(unitTypes)
	local list = {}
	for id, def in unitTypes do
		if def.unlockedByDefault ~= false then
			table.insert(list, { id = id, def = def })
		end
	end
	table.sort(list, function(a, b) return (a.def.displayName or a.id) < (b.def.displayName or b.id) end)
	return list
end

local function buildingsByCategory(buildingTypes)
	local groups = {}
	for _, cat in CATEGORY_ORDER do groups[cat] = {} end
	for id, def in buildingTypes do
		local cat = def.category or "other"
		if not groups[cat] then groups[cat] = {} end
		table.insert(groups[cat], { id = id, def = def })
	end
	for _, list in groups do
		table.sort(list, function(a, b) return (a.def.displayName or a.id) < (b.def.displayName or b.id) end)
	end
	return groups
end

function ProvinceDetailPanel.create(parent, onClose, callbacks)
	callbacks = callbacks or {}

	-- Live recruit-progress bars. Each entry: { fill, timeLbl, queuedAt, completesAt }.
	-- A single RenderStepped loop re-reads SimClock each frame so bars advance smoothly
	-- between the 1.5s state broadcasts and stay correct at any game speed (or paused).
	local liveTickets = {}
	local liveTickConn = nil

	local function clearLiveTickets()
		liveTickets = {}
	end

	local function refreshLiveTicket(entry, simNow)
		local span = math.max(0.0001, (entry.completesAt or 0) - (entry.queuedAt or 0))
		local progress = math.clamp((simNow - (entry.queuedAt or 0)) / span, 0, 1)
		entry.fill.Size = UDim2.fromScale(progress, 1)
		if entry.timeLbl then
			local secsPerTick = WorldConstants.SecondsPerSimTick or 1.5
			local remainingSim = math.max(0, (entry.completesAt or 0) - simNow)
			local realSecs = remainingSim * secsPerTick / math.max(0.0001, SimClock.getSpeed() or 1)
			if SimClock.isPaused() then
				entry.timeLbl.Text = "paused"
			elseif remainingSim <= 0 then
				entry.timeLbl.Text = "ready"
			elseif realSecs >= 60 then
				entry.timeLbl.Text = string.format("%dm%02ds", math.floor(realSecs / 60), math.floor(realSecs % 60))
			else
				entry.timeLbl.Text = string.format("%ds", math.ceil(realSecs))
			end
		end
	end

	local function ensureLiveTickLoop()
		if liveTickConn then return end
		liveTickConn = RunService.RenderStepped:Connect(function()
			if #liveTickets == 0 then return end
			local simNow = SimClock.now()
			if not simNow then return end
			for _, entry in ipairs(liveTickets) do
				if entry.fill and entry.fill.Parent then
					refreshLiveTicket(entry, simNow)
				end
			end
		end)
	end

	local panel = UIBuilder.panel(parent, {
		Name = "ProvinceDetailPanel",
		Size = UDim2.fromOffset(PANEL_W, PANEL_H),
		Position = UDim2.new(1, -14, 0, UIStyle.Size.TopBarH + 14),
		AnchorPoint = Vector2.new(1, 0),
		Visible = false,
	})
	UIRoot.registerScaled(panel)

	local header = Instance.new("Frame")
	header.Size = UDim2.new(1, 0, 0, HEADER_H)
	header.BackgroundColor3 = UIStyle.Color.Bg
	header.BorderSizePixel = 0
	header.ZIndex = UIStyle.Z.PanelHeader
	header.Parent = panel

	local titleLbl = Instance.new("TextLabel")
	titleLbl.Size = UDim2.new(1, -90, 0, 30)
	titleLbl.Position = UDim2.fromOffset(18, 8)
	titleLbl.BackgroundTransparency = 1
	titleLbl.Text = "Province"
	titleLbl.TextColor3 = UIStyle.Color.Text
	titleLbl.FontFace = UIStyle.FontFace.CinzelBold
	titleLbl.TextSize = 20
	titleLbl.TextXAlignment = Enum.TextXAlignment.Left
	titleLbl.TextYAlignment = Enum.TextYAlignment.Bottom
	titleLbl.ZIndex = UIStyle.Z.PanelHeader + 1
	titleLbl.Parent = header

	local subtitleLbl = Instance.new("TextLabel")
	subtitleLbl.Size = UDim2.new(1, -90, 0, 16)
	subtitleLbl.Position = UDim2.fromOffset(18, 38)
	subtitleLbl.BackgroundTransparency = 1
	subtitleLbl.Text = ""
	subtitleLbl.TextColor3 = UIStyle.Color.TooltipTertiary
	subtitleLbl.FontFace = UIStyle.FontFace.InterItalic
	subtitleLbl.TextSize = 12
	subtitleLbl.TextXAlignment = Enum.TextXAlignment.Left
	subtitleLbl.TextYAlignment = Enum.TextYAlignment.Center
	subtitleLbl.ZIndex = UIStyle.Z.PanelHeader + 1
	subtitleLbl.Parent = header

	local closeBtn = UIBuilder.iconButton(header, "Close", {
		size = 22,
		props = {
			Position = UDim2.new(1, -8, 0.5, 0),
			AnchorPoint = Vector2.new(1, 0.5),
			ZIndex = UIStyle.Z.PanelHeader + 2,
		},
	})

	local headerTrim = Instance.new("Frame")
	headerTrim.Size = UDim2.new(1, 0, 0, 1)
	headerTrim.Position = UDim2.new(0, 0, 1, 0)
	headerTrim.AnchorPoint = Vector2.new(0, 1)
	headerTrim.BackgroundColor3 = UIStyle.Color.Border
	headerTrim.BackgroundTransparency = 0.4
	headerTrim.BorderSizePixel = 0
	headerTrim.ZIndex = UIStyle.Z.PanelHeader + 2
	headerTrim.Parent = header

	local siblingStripFrame = Instance.new("Frame")
	siblingStripFrame.Size = UDim2.new(1, 0, 0, SIBLING_STRIP_H)
	siblingStripFrame.Position = UDim2.fromOffset(0, HEADER_H)
	siblingStripFrame.BackgroundColor3 = UIStyle.Color.PanelAlt
	siblingStripFrame.BorderSizePixel = 0
	siblingStripFrame.ZIndex = UIStyle.Z.PanelHeader
	siblingStripFrame.Visible = false
	siblingStripFrame.Parent = panel

	local siblingScroll = Instance.new("ScrollingFrame")
	siblingScroll.Size = UDim2.fromScale(1, 1)
	siblingScroll.BackgroundTransparency = 1
	siblingScroll.BorderSizePixel = 0
	siblingScroll.ScrollingDirection = Enum.ScrollingDirection.X
	siblingScroll.AutomaticCanvasSize = Enum.AutomaticSize.X
	siblingScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	siblingScroll.ScrollBarThickness = 4
	siblingScroll.ZIndex = UIStyle.Z.PanelHeader + 1
	siblingScroll.Parent = siblingStripFrame

	local siblingLayout = Instance.new("UIListLayout")
	siblingLayout.FillDirection = Enum.FillDirection.Horizontal
	siblingLayout.Padding = UDim.new(0, 4)
	siblingLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	siblingLayout.SortOrder = Enum.SortOrder.LayoutOrder
	siblingLayout.Parent = siblingScroll

	local siblingPad = Instance.new("UIPadding")
	siblingPad.PaddingLeft = UDim.new(0, 6)
	siblingPad.PaddingRight = UDim.new(0, 6)
	siblingPad.PaddingTop = UDim.new(0, 4)
	siblingPad.PaddingBottom = UDim.new(0, 4)
	siblingPad.Parent = siblingScroll

	local tabStripFrame = Instance.new("Frame")
	tabStripFrame.Size = UDim2.new(1, 0, 0, TAB_STRIP_H)
	tabStripFrame.Position = UDim2.fromOffset(0, HEADER_H)
	tabStripFrame.BackgroundColor3 = UIStyle.Color.Bg
	tabStripFrame.BorderSizePixel = 0
	tabStripFrame.ClipsDescendants = true
	tabStripFrame.ZIndex = UIStyle.Z.PanelHeader
	tabStripFrame.Parent = panel

	local tabsRow = Instance.new("Frame")
	tabsRow.Size = UDim2.fromScale(1, 1)
	tabsRow.BackgroundTransparency = 1
	tabsRow.Parent = tabStripFrame

	local tabLayout = Instance.new("UIGridLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.CellPadding = UDim2.fromOffset(0, 0)
	tabLayout.CellSize = UDim2.new(1 / #TAB_DEFS, 0, 1, 0)
	tabLayout.FillDirectionMaxCells = #TAB_DEFS
	tabLayout.Parent = tabsRow

	local underline = Instance.new("Frame")
	underline.Size = UDim2.fromOffset(0, 2)
	underline.Position = UDim2.new(0, 0, 1, -2)
	underline.BackgroundColor3 = UIStyle.Color.Gold
	underline.BorderSizePixel = 0
	underline.ZIndex = UIStyle.Z.PanelHeader + 3
	underline.Parent = tabStripFrame

	local linesBar = Instance.new("Frame")
	linesBar.Size = UDim2.new(1, 0, 0, LINES_H)
	linesBar.Position = UDim2.fromOffset(0, HEADER_H + TAB_STRIP_H)
	linesBar.BackgroundColor3 = UIStyle.Color.PanelAlt
	linesBar.BorderSizePixel = 0
	linesBar.ZIndex = UIStyle.Z.PanelHeader
	linesBar.Parent = panel

	local linesLbl = UIBuilder.label(linesBar, "Production lines: 0 / 1", UIStyle.Type.Small, UIStyle.Color.TextMuted, {
		Size = UDim2.new(1, -16, 1, 0),
		Position = UDim2.fromOffset(10, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextSize = 11,
		Font = UIStyle.Font.Semibold,
	})

	local content = Instance.new("Frame")
	content.Size = UDim2.new(1, 0, 1, -(HEADER_H + TAB_STRIP_H + LINES_H))
	content.Position = UDim2.fromOffset(0, HEADER_H + TAB_STRIP_H + LINES_H)
	content.BackgroundTransparency = 1
	content.ZIndex = UIStyle.Z.Content
	content.ClipsDescendants = true
	content.Parent = panel

	local siblingClickCb = nil

	local function applyLayout(siblingsVisible)
		local extra = siblingsVisible and SIBLING_STRIP_H or 0
		siblingStripFrame.Visible = siblingsVisible
		tabStripFrame.Position = UDim2.fromOffset(0, HEADER_H + extra)
		linesBar.Position = UDim2.fromOffset(0, HEADER_H + extra + TAB_STRIP_H)
		content.Position = UDim2.fromOffset(0, HEADER_H + extra + TAB_STRIP_H + LINES_H)
		content.Size = UDim2.new(1, 0, 1, -(HEADER_H + extra + TAB_STRIP_H + LINES_H))
	end

	local function clearSiblingButtons()
		for _, c in ipairs(siblingScroll:GetChildren()) do
			if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then
				c:Destroy()
			end
		end
	end

	local function renderSiblings(siblings)
		clearSiblingButtons()
		if not siblings or #siblings < 2 then
			applyLayout(false)
			return
		end
		applyLayout(true)
		for i, sib in ipairs(siblings) do
			local label = sib.record and sib.record.code or "?"
			if sib.record and sib.record.name then
				label = label .. " · " .. sib.record.name
			end
			local btn = Instance.new("TextButton")
			btn.Size = UDim2.fromOffset(math.max(64, 8 + #label * 6), SIBLING_STRIP_H - 8)
			btn.AutomaticSize = Enum.AutomaticSize.X
			btn.LayoutOrder = i
			btn.BackgroundColor3 = sib.focused and UIStyle.Color.Gold or UIStyle.Color.Bg
			btn.BorderSizePixel = 0
			btn.Text = label
			btn.TextColor3 = sib.focused and UIStyle.Color.Bg or UIStyle.Color.Text
			btn.Font = sib.focused and UIStyle.Font.Bold or UIStyle.Font.Semibold
			btn.TextSize = 12
			btn.AutoButtonColor = false
			btn.ZIndex = UIStyle.Z.PanelHeader + 2
			btn.Parent = siblingScroll
			UIBuilder.corner(btn, 3)
			UIBuilder.padding(btn, 2, 8)
			btn.MouseButton1Click:Connect(function()
				if siblingClickCb then siblingClickCb(sib.part) end
			end)
		end
	end

	local recruitmentBody = buildTabBody(content)
	local buildingsBody   = buildTabBody(content)
	local informationBody = buildTabBody(content)

	local tabs = {}
	local update  -- forward decl so inner closures can refresh
	local activeTab = TAB_KEY.Recruitment
	local buildingsFilter = ""

	local function setActive(name)
		if not tabs[name] then return end
		activeTab = name
		for tabName, data in tabs do
			local active = tabName == name
			data.label.TextColor3 = active and UIStyle.Color.Gold or UIStyle.Color.TextMuted
			data.body.Visible = active
			if active and data.button.AbsoluteSize.X > 0 then
				local s = UIRoot.uiScale()
				local px = (data.button.AbsolutePosition.X - tabStripFrame.AbsolutePosition.X) / s
				local sx = data.button.AbsoluteSize.X / s
				TweenService:Create(underline, UIStyle.tween(UIStyle.Motion.Fast), {
					Position = UDim2.new(0, px, 1, -2),
					Size = UDim2.fromOffset(sx, 2),
				}):Play()
			end
		end
	end

	for i, def in ipairs(TAB_DEFS) do
		local btn = Instance.new("TextButton")
		btn.BackgroundTransparency = 1
		btn.AutoButtonColor = false
		btn.ClipsDescendants = true
		btn.Text = ""
		btn.LayoutOrder = i
		btn.ZIndex = UIStyle.Z.PanelHeader + 2
		btn.Parent = tabsRow

		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.new(1, -22, 1, 0)
		lbl.Position = UDim2.fromOffset(2, 0)
		lbl.BackgroundTransparency = 1
		lbl.Text = def.label
		lbl.TextColor3 = UIStyle.Color.TextMuted
		lbl.Font = UIStyle.Font.Semibold
		lbl.TextSize = 11
		lbl.TextXAlignment = Enum.TextXAlignment.Center
		lbl.TextYAlignment = Enum.TextYAlignment.Center
		lbl.TextTruncate = Enum.TextTruncate.AtEnd
		lbl.ZIndex = UIStyle.Z.PanelHeader + 2
		lbl.Parent = btn

		if def.hint then
			UIBuilder.keyHint(btn, def.hint, {
				Position = UDim2.new(1, -4, 0.5, 0),
				AnchorPoint = Vector2.new(1, 0.5),
				Size = UDim2.fromOffset(15, 15),
			})
		end

		local body = (def.key == TAB_KEY.Recruitment and recruitmentBody)
			or (def.key == TAB_KEY.Buildings and buildingsBody)
			or informationBody

		tabs[def.key] = { button = btn, label = lbl, body = body }
		btn.MouseButton1Click:Connect(function() setActive(def.key) end)
	end

	local function isVisible() return panel.Visible end

	UIKeybindings.register(Enum.KeyCode.R, function()
		if not isVisible() then return false end
		setActive(TAB_KEY.Recruitment)
		return true
	end, "province")
	UIKeybindings.register(Enum.KeyCode.B, function()
		if not isVisible() then return false end
		setActive(TAB_KEY.Buildings)
		return true
	end, "province")
	UIKeybindings.register(Enum.KeyCode.I, function()
		if not isVisible() then return false end
		setActive(TAB_KEY.Information)
		return true
	end, "province")

	closeBtn.MouseButton1Click:Connect(function()
		panel.Visible = false
		if onClose then onClose() end
	end)

	local function refreshLinesBar(province, country)
		if not province then linesLbl.Text = "—" return end
		local cap = math.max(1, province.devTier or 1)
		local active = 0
		if country then
			if country.recruitQueue then
				for _, t in country.recruitQueue do
					if t.provinceId == province.id then active += 1 end
				end
			end
			if country.buildQueue then
				for _, t in country.buildQueue do
					if t.provinceId == province.id then active += 1 end
				end
			end
		end
		local color = active >= cap and UIStyle.Color.Warn or UIStyle.Color.TextMuted
		linesLbl.Text = string.format("Production lines: %d / %d", active, cap)
		linesLbl.TextColor3 = color
	end

	local function buildRecruitmentTab(province, country, bundle)
		clearChildren(recruitmentBody)
		clearLiveTickets()
		if not province or not bundle or not bundle.unitTypes then
			UIBuilder.label(recruitmentBody, "No data.", UIStyle.Type.Small, UIStyle.Color.TextMuted, {
				Size = UDim2.new(1, 0, 0, 18),
			})
			return
		end


		local ownsThis = country and province.ownerTag == country.tag and province.controllerTag == country.tag
		if not ownsThis then
			UIBuilder.label(recruitmentBody, "You do not control this province.", UIStyle.Type.Small, UIStyle.Color.TextMuted, {
				Size = UDim2.new(1, 0, 0, 18),
				TextWrapped = true,
			})
			return
		end

		local order = 0
		local function nextOrder() order += 1; return order end

		----------------------------------------------------------------
		-- 1) Province budget header
		----------------------------------------------------------------
		local capLines = math.max(1, province.devTier or 1)
		local activeRecruit = 0
		local activeBuild = 0
		if country.recruitQueue then
			for _, t in country.recruitQueue do
				if t.provinceId == province.id then activeRecruit += 1 end
			end
		end
		if country.buildQueue then
			for _, t in country.buildQueue do
				if t.provinceId == province.id then activeBuild += 1 end
			end
		end
		local activeLines = activeRecruit + activeBuild
		local freeLines = math.max(0, capLines - activeLines)

		local headerCard = Instance.new("Frame")
		headerCard.Size = UDim2.new(1, 0, 0, 44)
		headerCard.BackgroundColor3 = UIStyle.Color.PanelAlt or Color3.fromRGB(30, 36, 45)
		headerCard.BorderSizePixel = 0
		headerCard.LayoutOrder = nextOrder()
		headerCard.Parent = recruitmentBody
		UIBuilder.corner(headerCard, 4)

		local treasuryLbl = UIBuilder.label(headerCard, string.format("Treasury %d gold", math.floor(country.treasury or 0)),
			UIStyle.Type.Small, UIStyle.Color.Gold or Color3.fromRGB(201, 162, 75), {
				Size = UDim2.new(0.5, -8, 0, 18),
				Position = UDim2.fromOffset(8, 4),
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left,
			})
		local manpowerLbl = UIBuilder.label(headerCard, string.format("Manpower %d", math.floor(country.manpower or 0)),
			UIStyle.Type.Small, UIStyle.Color.Text or Color3.fromRGB(232, 220, 192), {
				Size = UDim2.new(0.5, -8, 0, 18),
				Position = UDim2.new(0.5, 0, 0, 4),
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left,
			})
		local linesLbl2 = UIBuilder.label(headerCard, string.format("Lines: %d/%d (%d free)", activeLines, capLines, freeLines),
			UIStyle.Type.Small, freeLines > 0 and (UIStyle.Color.StateGood or Color3.fromRGB(140, 200, 140)) or (UIStyle.Color.Warn or Color3.fromRGB(220, 180, 80)), {
				Size = UDim2.new(1, -16, 0, 16),
				Position = UDim2.fromOffset(8, 22),
				TextSize = 11,
				TextXAlignment = Enum.TextXAlignment.Left,
			})

		----------------------------------------------------------------
		-- 2) Production Queue section (always visible)
		----------------------------------------------------------------
		UIBuilder.label(recruitmentBody, "Production Queue", UIStyle.Type.SectionHeader,
			UIStyle.Color.Gold or Color3.fromRGB(201, 162, 75), {
				Size = UDim2.new(1, 0, 0, 18),
				LayoutOrder = nextOrder(),
				TextSize = 12,
			})

		-- Collect tickets at this province
		local provinceTickets = {}
		if country.recruitQueue then
			for _, t in country.recruitQueue do
				if t.provinceId == province.id then table.insert(provinceTickets, t) end
			end
		end
		-- Sort by queuedAt ascending
		table.sort(provinceTickets, function(a, b) return (a.queuedAt or 0) < (b.queuedAt or 0) end)

		-- Render each recruitment slot
		for slotIdx = 1, capLines do
			local ticket = provinceTickets[slotIdx]
			local slot = Instance.new("Frame")
			slot.Size = UDim2.new(1, 0, 0, 38)
			slot.BackgroundColor3 = UIStyle.Color.PanelAlt or Color3.fromRGB(30, 36, 45)
			slot.BackgroundTransparency = ticket and 0 or 0.5
			slot.BorderSizePixel = 0
			slot.LayoutOrder = nextOrder()
			slot.Parent = recruitmentBody
			UIBuilder.corner(slot, 3)
			if not ticket then
				-- Dashed-style empty slot
				UIBuilder.stroke(slot, 1, UIStyle.Color.Border or Color3.fromRGB(80, 90, 100))
			end

			if not ticket then
				UIBuilder.label(slot, slotIdx <= activeBuild and "Building (other tab)" or "— empty slot —",
					UIStyle.Type.Small,
					UIStyle.Color.TextMuted or Color3.fromRGB(140, 140, 140), {
						Size = UDim2.new(1, -16, 1, 0),
						Position = UDim2.fromOffset(8, 0),
						TextSize = 12,
						TextXAlignment = Enum.TextXAlignment.Left,
					})
			else
				local unit = bundle.unitTypes[ticket.unitTypeId]
				local name = (unit and unit.displayName) or ticket.unitTypeId

				-- Title row
				UIBuilder.label(slot, string.format("× %d %s", ticket.count or 1, name),
					UIStyle.Type.Small,
					UIStyle.Color.Text or Color3.fromRGB(232, 220, 192), {
						Size = UDim2.new(1, -56, 0, 16),
						Position = UDim2.fromOffset(8, 4),
						TextSize = 12,
						TextXAlignment = Enum.TextXAlignment.Left,
						Font = UIStyle.Font.SansBold or Enum.Font.GothamBold,
					})

				-- Progress bar
				local barBg = Instance.new("Frame")
				barBg.Size = UDim2.new(1, -56, 0, 6)
				barBg.Position = UDim2.fromOffset(8, 22)
				barBg.BackgroundColor3 = UIStyle.Color.Bg or Color3.fromRGB(20, 24, 31)
				barBg.BorderSizePixel = 0
				barBg.Parent = slot
				UIBuilder.corner(barBg, 2)

				local barFill = Instance.new("Frame")
				barFill.Size = UDim2.fromScale(0, 1)
				barFill.BackgroundColor3 = UIStyle.Color.Gold or Color3.fromRGB(201, 162, 75)
				barFill.BorderSizePixel = 0
				barFill.Parent = barBg
				UIBuilder.corner(barFill, 2)

				-- Time remaining text (driven live each frame by the SimClock tick loop)
				local timeLbl = UIBuilder.label(slot, "—",
					UIStyle.Type.Small,
					UIStyle.Color.TextMuted or Color3.fromRGB(140, 140, 140), {
						Size = UDim2.new(0, 48, 0, 12),
						Position = UDim2.new(1, -90, 0, 22),
						TextSize = 10,
						TextXAlignment = Enum.TextXAlignment.Right,
					})

				local entry = {
					fill = barFill,
					timeLbl = timeLbl,
					queuedAt = ticket.queuedAt or 0,
					completesAt = ticket.completesAt or 0,
				}
				table.insert(liveTickets, entry)
				local simNow0 = SimClock.now()
				if simNow0 then refreshLiveTicket(entry, simNow0) end
				ensureLiveTickLoop()

				-- Cancel button
				if callbacks.onCancelRecruit then
					local cancelBtn = Instance.new("TextButton")
					cancelBtn.Size = UDim2.fromOffset(40, 24)
					cancelBtn.Position = UDim2.new(1, -44, 0.5, -12)
					cancelBtn.BackgroundColor3 = UIStyle.Color.StateBad or Color3.fromRGB(180, 70, 70)
					cancelBtn.BorderSizePixel = 0
					cancelBtn.Text = "✕"
					cancelBtn.Font = Enum.Font.GothamBold
					cancelBtn.TextSize = 13
					cancelBtn.TextColor3 = Color3.fromRGB(240, 240, 240)
					cancelBtn.Parent = slot
					UIBuilder.corner(cancelBtn, 3)
					local ticketIdCapture = ticket.id
					cancelBtn.MouseButton1Click:Connect(function()
						callbacks.onCancelRecruit(ticketIdCapture)
					end)
				end
			end
		end

		----------------------------------------------------------------
		-- 3) Available Units section
		----------------------------------------------------------------
		UIBuilder.label(recruitmentBody, "Available Units", UIStyle.Type.SectionHeader,
			UIStyle.Color.Gold or Color3.fromRGB(201, 162, 75), {
				Size = UDim2.new(1, 0, 0, 18),
				LayoutOrder = nextOrder(),
				TextSize = 12,
			})

		for _, entry in eligibleUnits(bundle.unitTypes) do
			local unit = entry.def
			local row = Instance.new("Frame")
			row.Size = UDim2.new(1, 0, 0, 60)
			row.BackgroundColor3 = UIStyle.Color.PanelAlt or Color3.fromRGB(30, 36, 45)
			row.BorderSizePixel = 0
			row.ClipsDescendants = true
			row.LayoutOrder = nextOrder()
			row.Parent = recruitmentBody
			UIBuilder.corner(row, 3)
			UIBuilder.stroke(row, 1, UIStyle.Color.Border or Color3.fromRGB(80, 90, 100))

			-- Affordability check
			local cost = unit.recruitCost or 0
			local mp = unit.recruitManpower or 0
			local canAfford = (country.treasury or 0) >= cost and (country.manpower or 0) >= mp
			local hasFreeLine = freeLines > 0

			UIBuilder.label(row, unit.displayName or entry.id, UIStyle.Type.StatValue,
				canAfford and (UIStyle.Color.Text or Color3.fromRGB(232, 220, 192)) or (UIStyle.Color.TextMuted or Color3.fromRGB(140, 140, 140)), {
					Size = UDim2.new(1, -130, 0, 20),
					Position = UDim2.fromOffset(8, 6),
					TextSize = 13,
					Font = UIStyle.Font.SansBold or Enum.Font.GothamBold,
				})
			UIBuilder.label(row, string.format("%d gold · %d mp · %d ticks",
				cost, mp, unit.recruitTicks or 0),
				UIStyle.Type.Small,
				canAfford and (UIStyle.Color.TextMuted or Color3.fromRGB(160, 160, 160)) or (UIStyle.Color.Warn or Color3.fromRGB(220, 180, 80)), {
					Size = UDim2.new(1, -16, 0, 14),
					Position = UDim2.fromOffset(8, 26),
					TextSize = 10,
				})
			UIBuilder.label(row, string.format("Atk %d · Def %d · Speed %.1f · Width %d",
				unit.attack or 0, unit.defense or 0, unit.speed or 0, unit.combatWidth or 2),
				UIStyle.Type.Small,
				UIStyle.Color.TextMuted or Color3.fromRGB(140, 140, 140), {
					Size = UDim2.new(1, -16, 0, 14),
					Position = UDim2.fromOffset(8, 42),
					TextSize = 10,
				})

			local qtyBox = Instance.new("TextBox")
			qtyBox.Size = UDim2.fromOffset(40, 22)
			qtyBox.Position = UDim2.new(1, -78, 0, 8)
			qtyBox.AnchorPoint = Vector2.new(0, 0)
			qtyBox.BackgroundColor3 = UIStyle.Color.Bg or Color3.fromRGB(20, 24, 31)
			qtyBox.BorderSizePixel = 0
			qtyBox.Font = UIStyle.Font.Bold or Enum.Font.GothamBold
			qtyBox.TextSize = 12
			qtyBox.TextColor3 = UIStyle.Color.Text or Color3.fromRGB(232, 220, 192)
			qtyBox.Text = "1"
			qtyBox.PlaceholderText = "Qty"
			qtyBox.PlaceholderColor3 = UIStyle.Color.TextMuted or Color3.fromRGB(140, 140, 140)
			qtyBox.ClearTextOnFocus = false
			qtyBox.ZIndex = UIStyle.Z.Content + 1
			qtyBox.Parent = row
			UIBuilder.corner(qtyBox, 2)
			UIBuilder.stroke(qtyBox, 1, UIStyle.Color.Border or Color3.fromRGB(80, 90, 100))

			local btn = UIBuilder.button(row, {
				Size = UDim2.fromOffset(Platform.isTouch and 36 or 30, Platform.isTouch and 32 or 22),
				Position = UDim2.new(1, -8, 0, 8),
				AnchorPoint = Vector2.new(1, 0),
				Text = "+",
			}, true)
			btn.Active = canAfford and hasFreeLine
			if not (canAfford and hasFreeLine) then
				btn.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
				btn.AutoButtonColor = false
			end
			btn.MouseButton1Click:Connect(function()
				if not (canAfford and hasFreeLine) then
					return
				end
				local qty = math.max(1, math.floor(tonumber(qtyBox.Text) or 1))
				if callbacks.onRecruitUnit then
					callbacks.onRecruitUnit(province.id, entry.id, qty)
				end
			end)
		end
	end

	local function buildBuildingsTab(province, country, bundle)
		clearChildren(buildingsBody)
		if not province or not bundle or not bundle.buildingTypes then
			UIBuilder.label(buildingsBody, "No data.", UIStyle.Type.Small, UIStyle.Color.TextMuted, {
				Size = UDim2.new(1, 0, 0, 18),
			})
			return
		end

		local ownsThis = country and province.ownerTag == country.tag and province.controllerTag == country.tag
		if not ownsThis then
			UIBuilder.label(buildingsBody, "You do not control this province.", UIStyle.Type.Small, UIStyle.Color.TextMuted, {
				Size = UDim2.new(1, 0, 0, 18),
				TextWrapped = true,
			})
			return
		end

		local order = 0
		local function nextOrder() order += 1; return order end

		local constructed = province.buildings or {}
		local builtSet = {}
		for _, id in constructed do builtSet[id] = true end

		local function makeSectionHeader(title)
			UIBuilder.label(buildingsBody, title, UIStyle.Type.SectionHeader, UIStyle.Color.Gold, {
				Size = UDim2.new(1, 0, 0, 20),
				LayoutOrder = nextOrder(),
				TextSize = 12,
			})
			local sep = Instance.new("Frame")
			sep.Size = UDim2.new(1, -4, 0, 1)
			sep.BackgroundColor3 = UIStyle.Color.Gold
			sep.BackgroundTransparency = 0.5
			sep.BorderSizePixel = 0
			sep.LayoutOrder = nextOrder()
			sep.Parent = buildingsBody
		end

		----------------------------------------------------------------------
		-- Section 1: Existing (development levels + constructed buildings)
		----------------------------------------------------------------------
		makeSectionHeader("Existing")

		local levels = Instance.new("Frame")
		levels.Size = UDim2.new(1, 0, 0, 28)
		levels.BackgroundColor3 = UIStyle.Color.PanelAlt
		levels.BorderSizePixel = 0
		levels.LayoutOrder = nextOrder()
		levels.Parent = buildingsBody
		UIBuilder.corner(levels, 2)
		UIBuilder.stroke(levels, 1, UIStyle.Color.Border)
		local lLayout = Instance.new("UIListLayout")
		lLayout.FillDirection = Enum.FillDirection.Horizontal
		lLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
		lLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		lLayout.Padding = UDim.new(0, 12)
		lLayout.Parent = levels
		local lPad = Instance.new("UIPadding")
		lPad.PaddingLeft = UDim.new(0, 10); lPad.PaddingRight = UDim.new(0, 10)
		lPad.Parent = levels
		local function tierBadge(name, value, max, color)
			local label = UIBuilder.label(levels, string.format("%s %d / %d", name, value, max),
				UIStyle.Type.StatValue, color, {
					Size = UDim2.fromOffset(120, 18),
					TextSize = 12, Font = UIStyle.Font.Semibold,
					TextXAlignment = Enum.TextXAlignment.Left,
				})
			label.LayoutOrder = nextOrder()
		end
		tierBadge("Development", province.devTier or 0, WorldConstants.DevTierMax or 10, UIStyle.Color.Good)
		tierBadge("Infrastructure", province.infraTier or 0, WorldConstants.InfraTierMax or 10, UIStyle.Color.Gold)
		tierBadge("Fort", province.fortTier or 0, 5, UIStyle.Color.Warn)

		if #constructed == 0 then
			UIBuilder.label(buildingsBody, "No buildings yet.", UIStyle.Type.Small, UIStyle.Color.TextMuted, {
				Size = UDim2.new(1, 0, 0, 16),
				LayoutOrder = nextOrder(),
				TextSize = 10,
			})
		else
			for _, id in constructed do
				local def = bundle.buildingTypes[id]
				local row = Instance.new("Frame")
				row.Size = UDim2.new(1, 0, 0, 22)
				row.BackgroundColor3 = UIStyle.Color.PanelAlt
				row.BorderSizePixel = 0
				row.ClipsDescendants = true
				row.LayoutOrder = nextOrder()
				row.Parent = buildingsBody
				UIBuilder.corner(row, 2)
				UIBuilder.label(row, def and def.displayName or id, UIStyle.Type.Small, UIStyle.Color.Text, {
					Size = UDim2.new(0.6, -16, 1, 0),
					Position = UDim2.fromOffset(8, 0),
					TextSize = 11,
				})
				UIBuilder.label(row, def and titleCase(def.category or "") or "", UIStyle.Type.Small, UIStyle.Color.TextMuted, {
					Size = UDim2.new(0.4, -8, 1, 0),
					Position = UDim2.new(1, -8, 0, 0),
					AnchorPoint = Vector2.new(1, 0),
					TextXAlignment = Enum.TextXAlignment.Right,
					TextSize = 10,
				})
			end
		end

		----------------------------------------------------------------------
		-- Section 2: In Progress (build queue)
		----------------------------------------------------------------------
		makeSectionHeader("In Progress")

		local buildQueue = country.buildQueue or {}
		local hasInProgress = false
		for _, t in buildQueue do
			if t.provinceId == province.id then hasInProgress = true; break end
		end
		if not hasInProgress then
			UIBuilder.label(buildingsBody, "No constructions in progress.", UIStyle.Type.Small, UIStyle.Color.TextMuted, {
				Size = UDim2.new(1, 0, 0, 16),
				LayoutOrder = nextOrder(),
				TextSize = 10,
			})
		else
			for _, t in buildQueue do
				if t.provinceId == province.id then
					local def = bundle.buildingTypes[t.buildingId]
					local row = Instance.new("Frame")
					row.Size = UDim2.new(1, 0, 0, 26)
					row.BackgroundColor3 = UIStyle.Color.PanelAlt
					row.BorderSizePixel = 0
					row.ClipsDescendants = true
					row.LayoutOrder = nextOrder()
					row.Parent = buildingsBody
					UIBuilder.corner(row, 2)
					UIBuilder.label(row, def and def.displayName or t.buildingId, UIStyle.Type.Small, UIStyle.Color.Text, {
						Size = UDim2.new(1, -68, 1, 0),
						Position = UDim2.fromOffset(8, 0),
						TextSize = 12,
					})
					local cancelBtn = UIBuilder.button(row, {
						Size = UDim2.fromOffset(Platform.isTouch and 64 or 54, Platform.isTouch and 28 or 18),
						Position = UDim2.new(1, -6, 0.5, 0),
						AnchorPoint = Vector2.new(1, 0.5),
						Text = "Cancel",
					})
					local ticketId = t.id
					cancelBtn.MouseButton1Click:Connect(function()
						if callbacks.onCancelBuilding then callbacks.onCancelBuilding(ticketId) end
					end)
				end
			end
		end

		----------------------------------------------------------------------
		-- Section 3: Available (tier upgrades + categorized buildings)
		----------------------------------------------------------------------
		makeSectionHeader("Available")

		-- Filter input: type to narrow the list (especially useful with 38 manufactories).
		do
			local filterRow = Instance.new("Frame")
			filterRow.Size = UDim2.new(1, 0, 0, 28)
			filterRow.BackgroundColor3 = UIStyle.Color.Bg
			filterRow.BorderSizePixel = 0
			filterRow.LayoutOrder = nextOrder()
			filterRow.Parent = buildingsBody
			UIBuilder.corner(filterRow, 2)
			UIBuilder.stroke(filterRow, 1, UIStyle.Color.Border)

			local box = Instance.new("TextBox")
			box.Size = UDim2.new(1, -36, 1, -4)
			box.Position = UDim2.fromOffset(8, 2)
			box.BackgroundTransparency = 1
			box.Font = UIStyle.Font.Regular
			box.PlaceholderText = "Filter buildings..."
			box.PlaceholderColor3 = UIStyle.Color.TextMuted
			box.TextColor3 = UIStyle.Color.Text
			box.TextSize = 12
			box.TextXAlignment = Enum.TextXAlignment.Left
			box.Text = buildingsFilter
			box.ClearTextOnFocus = false
			box.Parent = filterRow

			local clearBtn = Instance.new("TextButton")
			clearBtn.Size = UDim2.fromOffset(24, 24)
			clearBtn.Position = UDim2.new(1, -28, 0.5, 0)
			clearBtn.AnchorPoint = Vector2.new(0, 0.5)
			clearBtn.BackgroundTransparency = 1
			clearBtn.AutoButtonColor = false
			clearBtn.Text = "\u{2715}"
			clearBtn.TextColor3 = UIStyle.Color.TextMuted
			clearBtn.Font = UIStyle.Font.Bold
			clearBtn.TextSize = 12
			clearBtn.Parent = filterRow
			clearBtn.Visible = buildingsFilter ~= ""

			box:GetPropertyChangedSignal("Text"):Connect(function()
				buildingsFilter = box.Text or ""
				clearBtn.Visible = buildingsFilter ~= ""
				-- Repaint by re-invoking buildBuildingsTab via the panel's update path.
				-- Simplest: trigger via setActive to keep tab visible.
				if update then update(province, country, bundle) end
			end)
			clearBtn.MouseButton1Click:Connect(function()
				box.Text = ""
			end)
		end

		local upgrades = {
			{ id = "develop_province", label = "Upgrade Development",
				tier = province.devTier or 0, cap = WorldConstants.DevTierMax or 10 },
			{ id = "improve_infrastructure", label = "Upgrade Infrastructure",
				tier = province.infraTier or 0, cap = WorldConstants.InfraTierMax or 10 },
		}
		local inProgress = {}
		for _, t in buildQueue do
			if t.provinceId == province.id then inProgress[t.buildingId] = true end
		end
		for _, up in upgrades do
			local def = bundle.buildingTypes[up.id]
			local atCap = up.tier >= up.cap
			local queued = inProgress[up.id] == true
			local locked = atCap or queued

			local row = Instance.new("Frame")
			row.Size = UDim2.new(1, 0, 0, 60)
			row.BackgroundColor3 = locked and UIStyle.Color.Bg or UIStyle.Color.PanelAlt
			row.BackgroundTransparency = locked and 0.4 or 0
			row.BorderSizePixel = 0
			row.ClipsDescendants = true
			row.LayoutOrder = nextOrder()
			row.Parent = buildingsBody
			UIBuilder.corner(row, 2)
			UIBuilder.stroke(row, 1, locked and UIStyle.Color.Border or UIStyle.Color.BorderStrong)

			local headerText = atCap
				and string.format("%s (Tier %d \u{2014} Maximum)", up.label, up.tier)
				or string.format("%s (Tier %d \u{2192} %d)", up.label, up.tier, up.tier + 1)
			UIBuilder.label(row, headerText, UIStyle.Type.StatValue,
				locked and UIStyle.Color.TextMuted or UIStyle.Color.Text, {
					Size = UDim2.new(1, -94, 0, 18),
					Position = UDim2.fromOffset(8, 6),
					TextSize = 13,
				})
			local meta = def and string.format("%d gold \u{2022} %d days \u{2022} repeatable",
				def.cost or 0, def.buildDays or 0) or "\u{2014}"
			UIBuilder.label(row, meta, UIStyle.Type.Small, UIStyle.Color.TextMuted, {
				Size = UDim2.new(1, -16, 0, 14),
				Position = UDim2.fromOffset(8, 26),
				TextSize = 10,
			})
			local note = (def and def.description) or ""
			if atCap then note = "This province is at the maximum tier."
			elseif queued then note = "An upgrade is already in progress." end
			UIBuilder.label(row, note, UIStyle.Type.Small,
				locked and UIStyle.Color.Bad or UIStyle.Color.TextDim, {
					Size = UDim2.new(1, -16, 0, 14),
					Position = UDim2.fromOffset(8, 42),
					TextSize = 10,
				})
			local btn = UIBuilder.button(row, {
				Size = UDim2.fromOffset(Platform.isTouch and 88 or 76, Platform.isTouch and 32 or 22),
				Position = UDim2.new(1, -8, 0, 8),
				AnchorPoint = Vector2.new(1, 0),
				Text = atCap and "Maxed" or (queued and "Queued" or "Build"),
			}, not locked)
			btn.Active = not locked
			if not locked then
				local upId = up.id
				btn.MouseButton1Click:Connect(function()
					if callbacks.onBuildBuilding then callbacks.onBuildBuilding(province.id, upId) end
				end)
			end
		end

		local groups = buildingsByCategory(bundle.buildingTypes)
		for _, cat in CATEGORY_ORDER do
			local list = groups[cat]
			if list and #list > 0 then
				UIBuilder.label(buildingsBody, titleCase(cat), UIStyle.Type.Small, UIStyle.Color.TextMuted, {
					Size = UDim2.new(1, 0, 0, 14),
					LayoutOrder = nextOrder(),
					TextSize = 10,
				})
				for _, entry in list do
					if entry.id == "develop_province" or entry.id == "improve_infrastructure" then
						-- Surfaced under Tier Upgrades; skip in the generic list.
					elseif buildingsFilter ~= "" and not (entry.def.displayName or entry.id):lower():find(buildingsFilter:lower(), 1, true) then
						-- Filtered out by user search.
					elseif not builtSet[entry.id] then
						local def = entry.def
						local infraOK = (province.infraTier or 0) >= (def.infraRequirement or 0)
						local coastalOK = not def.requiresCoastal or province.coastal == true
						local prereqOK = true
						local missingPrereq = nil
						if def.requires then
							for _, prereq in def.requires do
								if not builtSet[prereq] then
									prereqOK = false
									missingPrereq = prereq
									break
								end
							end
						end
						local locked = not (infraOK and coastalOK and prereqOK)

						local row = Instance.new("Frame")
						row.Size = UDim2.new(1, 0, 0, 64)
						row.BackgroundColor3 = locked and UIStyle.Color.Bg or UIStyle.Color.PanelAlt
						row.BackgroundTransparency = locked and 0.4 or 0
						row.BorderSizePixel = 0
						row.ClipsDescendants = true
						row.LayoutOrder = nextOrder()
						row.Parent = buildingsBody
						UIBuilder.corner(row, 2)
						UIBuilder.stroke(row, 1, locked and UIStyle.Color.Border or UIStyle.Color.BorderStrong)

						UIBuilder.label(row, def.displayName or entry.id, UIStyle.Type.StatValue,
							locked and UIStyle.Color.TextMuted or UIStyle.Color.Text, {
								Size = UDim2.new(1, -94, 0, 18),
								Position = UDim2.fromOffset(8, 6),
								TextSize = 13,
							})
						local meta = string.format("%d gold \u{2022} %d days \u{2022} Infra \u{2265} %d",
							def.cost or 0, def.buildDays or 0, def.infraRequirement or 0)
						if def.requiresCoastal then meta = meta .. " \u{2022} coastal" end
						if def.grantsFortTier then meta = meta .. string.format(" \u{2022} grants Fort %d", def.grantsFortTier) end
						if def.grantsShipyard then meta = meta .. " \u{2022} grants shipyard" end
						if def.manufactoryId then meta = meta .. " \u{2022} industrial" end
						UIBuilder.label(row, meta, UIStyle.Type.Small, UIStyle.Color.TextMuted, {
							Size = UDim2.new(1, -16, 0, 14),
							Position = UDim2.fromOffset(8, 26),
							TextSize = 10,
						})
						local note = def.description or ""
						if not infraOK then
							note = string.format("Requires Infra \u{2265} %d (have %d).", def.infraRequirement or 0, province.infraTier or 0)
						elseif not coastalOK then
							note = "Requires a coastal province."
						elseif missingPrereq then
							local m = bundle.buildingTypes[missingPrereq]
							note = string.format("Requires %s first.", m and m.displayName or missingPrereq)
						end
						UIBuilder.label(row, note, UIStyle.Type.Small,
							locked and UIStyle.Color.Bad or UIStyle.Color.TextDim, {
								Size = UDim2.new(1, -16, 0, 14),
								Position = UDim2.fromOffset(8, 44),
								TextSize = 10,
							})
						local btn = UIBuilder.button(row, {
							Size = UDim2.fromOffset(Platform.isTouch and 88 or 76, Platform.isTouch and 32 or 22),
							Position = UDim2.new(1, -8, 0, 8),
							AnchorPoint = Vector2.new(1, 0),
							Text = locked and "Locked" or "Build",
						}, not locked)
						btn.Active = not locked
						if not locked then
							btn.MouseButton1Click:Connect(function()
								if callbacks.onBuildBuilding then
									callbacks.onBuildBuilding(province.id, entry.id)
								end
							end)
						end
					end
				end
			end
		end
	end

	local function buildShipSection(parent, province, bundle, layoutOrder)
		local rec = addInfoSection(parent, "Build Ship", 96, layoutOrder)

		local typeBtn = Instance.new("TextButton")
		typeBtn.Size = UDim2.new(0.62, -10, 0, 22)
		typeBtn.Position = UDim2.fromOffset(8, 32)
		typeBtn.BackgroundColor3 = UIStyle.Color.PanelHigh
		typeBtn.BorderSizePixel = 0
		typeBtn.AutoButtonColor = false
		typeBtn.Font = UIStyle.Font.Regular
		typeBtn.TextSize = 12
		typeBtn.TextColor3 = UIStyle.Color.Text
		typeBtn.ZIndex = UIStyle.Z.Content + 1
		typeBtn.Parent = rec
		UIBuilder.corner(typeBtn, 2)
		UIBuilder.stroke(typeBtn, 1, UIStyle.Color.Border)

		local shipOrder = {}
		for id, ship in bundle.shipTypes do
			table.insert(shipOrder, { id = id, name = ship.displayName or id, infra = ship.infraRequirement or 0 })
		end
		table.sort(shipOrder, function(a, b) return a.name < b.name end)
		local typeIndex = 1
		local function applyType()
			if shipOrder[typeIndex] then typeBtn.Text = shipOrder[typeIndex].name end
		end
		applyType()
		typeBtn.MouseButton1Click:Connect(function()
			typeIndex = (typeIndex % math.max(1, #shipOrder)) + 1
			applyType()
		end)

		local countBox = Instance.new("TextBox")
		countBox.Size = UDim2.new(0.18, -4, 0, 22)
		countBox.Position = UDim2.new(0.62, 4, 0, 32)
		countBox.BackgroundColor3 = UIStyle.Color.Bg
		countBox.BorderSizePixel = 0
		countBox.Font = UIStyle.Font.Bold
		countBox.TextSize = 12
		countBox.TextColor3 = UIStyle.Color.Text
		countBox.PlaceholderText = "Qty"
		countBox.PlaceholderColor3 = UIStyle.Color.TextMuted
		countBox.Text = "1"
		countBox.ClearTextOnFocus = false
		countBox.ZIndex = UIStyle.Z.Content + 1
		countBox.Parent = rec
		UIBuilder.corner(countBox, 2)
		UIBuilder.stroke(countBox, 1, UIStyle.Color.Border)

		local fireBtn = UIBuilder.button(rec, {
			Size = UDim2.new(0.20, -4, 0, 22),
			Position = UDim2.new(0.80, 4, 0, 32),
			Text = "Build",
		}, true)

		UIBuilder.label(rec, string.format("Shipyard active. Infra %d.", province.infraTier or 0),
			UIStyle.Type.Small, UIStyle.Color.TextMuted, {
				Size = UDim2.new(1, -16, 0, 14),
				Position = UDim2.fromOffset(8, 60),
				TextXAlignment = Enum.TextXAlignment.Left,
			})

		fireBtn.MouseButton1Click:Connect(function()
			local entry = shipOrder[typeIndex]
			local qty = math.max(1, tonumber(countBox.Text) or 1)
			if entry and callbacks.onRecruitShip then
				callbacks.onRecruitShip(province.id, entry.id, qty)
			end
		end)
	end

	local function buildInformationTab(province, country, bundle)
		clearChildren(informationBody)
		if not province then return end

		local infoTitle = province.displayCityName or province.name or ("Province " .. tostring(province.id))
		if province.code and province.code ~= "" then infoTitle = province.code .. " · " .. infoTitle end
		UIBuilder.label(informationBody, infoTitle,
			UIStyle.Type.Title, UIStyle.Color.Text, {
				Size = UDim2.new(1, -16, 0, 28),
				LayoutOrder = 1,
				TextSize = 20,
			})
		local headerOwnerCountry = bundle and bundle.countries and province.ownerTag and bundle.countries[province.ownerTag]
		local headerControllerCountry = bundle and bundle.countries and province.controllerTag and bundle.countries[province.controllerTag]
		local ownerText = DebugMode.formatCountry(province.ownerTag, headerOwnerCountry)
		if province.controllerTag and province.controllerTag ~= province.ownerTag then
			ownerText = string.format("%s \u{2014} occupied by %s", ownerText, DebugMode.formatCountry(province.controllerTag, headerControllerCountry))
		end
		UIBuilder.label(informationBody, ownerText, UIStyle.Type.Body, UIStyle.Color.TextMuted, {
			Size = UDim2.new(1, -16, 0, 18),
			LayoutOrder = 2,
		})

		local pol = addInfoSection(informationBody, "Political", 110, 3)
		local lookupCountry = function(t)
			return bundle and bundle.countries and t and bundle.countries[t] or nil
		end
		addKeyValue(pol, "Owner", DebugMode.formatCountry(province.ownerTag, headerOwnerCountry), 30)
		addKeyValue(pol, "Controller", DebugMode.formatCountry(province.controllerTag, headerControllerCountry), 50)
		addKeyValue(pol, "Cores", DebugMode.formatCores(province.cores, lookupCountry), 70)
		addProgressKeyValue(pol, "Autonomy", (province.autonomy or 0), 1, 90, UIStyle.Color.Warn, string.format("%.0f%%", (province.autonomy or 0) * 100))

		local dev = addInfoSection(informationBody, "Development", 134, 4)
		addKeyValue(dev, "Base Tax", tostring(province.baseTax or 0), 30)
		addKeyValue(dev, "Base Production", tostring(province.baseProduction or 0), 50)
		addKeyValue(dev, "Base Manpower", tostring(province.baseManpower or 0), 70)
		addProgressKeyValue(dev, "Development Tier", province.devTier or 0, 10, 90, UIStyle.Color.Good, tostring(province.devTier or 0))
		addKeyValue(dev, "Infrastructure", tostring(province.infraTier or 0), 110)

		local econ = addInfoSection(informationBody, "Economic", 190, 5)
		do
			-- Trade goods list (multi-resource ready)
			local goodsMap = province.goods
			if not goodsMap or next(goodsMap) == nil then
				if province.tradeGood and province.tradeGood ~= "" and province.tradeGood ~= "none" then
					goodsMap = { [province.tradeGood] = province.baseProduction or 0 }
				else
					goodsMap = {}
				end
			end
			local goodsList = {}
			for gid, amt in goodsMap do
				if amt and amt > 0 then table.insert(goodsList, titleCase(gid)) end
			end
			table.sort(goodsList)
			local goodsText = #goodsList > 0 and table.concat(goodsList, ", ") or "None"
			addKeyValue(econ, "Trade Goods", goodsText, 30)
		end
		addKeyValue(econ, "Center of Trade", tostring(province.centerOfTrade or 0), 50)
		addKeyValue(econ, "Urban Center", province.isCity and "Yes" or "No", 70)
		do
			local isCapital = country and country.capitalProvinceId == province.id
			local taxAmount = country and EconomyPreview.taxOf(province, country, WorldConstants, bundle, isCapital, 0) or 0
			local taxText = string.format("%.1f / day", taxAmount)
			if isCapital then taxText = taxText .. " (capital +25%)" end
			addKeyValue(econ, "Daily Tax", taxText, 90,
				taxAmount > 0 and UIStyle.Color.Good or UIStyle.Color.TextMuted)

			-- Tax modifier breakdown: autonomy + unrest reductions
			local effective, autonomyMult, unrestMult = EconomyPreview.taxLossMultiplier(province, WorldConstants)
			local modParts = {}
			if autonomyMult < 1 then
				table.insert(modParts, string.format("Autonomy -%d%%", math.floor((1 - autonomyMult) * 100 + 0.5)))
			end
			if unrestMult < 1 then
				table.insert(modParts, string.format("Unrest -%d%%", math.floor((1 - unrestMult) * 100 + 0.5)))
			end
			local modText = #modParts > 0 and table.concat(modParts, " \u{2022} ") or "None"
			local modColor = effective < 1 and UIStyle.Color.Bad or UIStyle.Color.TextMuted
			addKeyValue(econ, "Tax Penalties", modText, 110, modColor)

			-- Daily output: list ALL produced goods (multi-resource)
			local prod = country and EconomyPreview.productionOf(province, country, WorldConstants, bundle, 0) or {}
			local outputParts = {}
			for gid, amt in prod do
				if amt and amt > 0 then
					table.insert(outputParts, { id = gid, amount = amt })
				end
			end
			table.sort(outputParts, function(a, b) return a.amount > b.amount end)
			local outputText
			if #outputParts > 0 then
				local pieces = {}
				for i = 1, math.min(#outputParts, 3) do
					local e = outputParts[i]
					table.insert(pieces, string.format("%.1f %s", e.amount, titleCase(e.id)))
				end
				outputText = table.concat(pieces, ", ") .. " / day"
			elseif (province.devTier or 0) <= 0 then
				outputText = "None (devTier 0)"
			else
				outputText = "None"
			end
			addKeyValue(econ, "Daily Output", outputText, 130,
				#outputParts > 0 and UIStyle.Color.Good or UIStyle.Color.TextMuted)

			-- Constructed manufactories summary (if any)
			local mfgCount = 0
			if province.buildings then
				for _, bid in province.buildings do
					local def = bundle and bundle.buildingTypes and bundle.buildingTypes[bid]
					if def and def.manufactoryId then mfgCount += 1 end
				end
			end
			addKeyValue(econ, "Manufactories", tostring(mfgCount), 150,
				mfgCount > 0 and UIStyle.Color.Gold or UIStyle.Color.TextMuted)
		end

		local demo = addInfoSection(informationBody, "Demography", 90, 6)
		addKeyValue(demo, "Population", string.format("%d", math.floor(province.population or 0)), 30)
		addKeyValue(demo, "Culture", titleCase(province.culture), 50)
		addKeyValue(demo, "Religion", titleCase(province.religion), 70)

		local geo = addInfoSection(informationBody, "Geography", 130, 7)
		addKeyValue(geo, "Terrain", titleCase(province.terrain), 30)
		addKeyValue(geo, "Climate", titleCase(province.climate), 50)
		addKeyValue(geo, "Area", titleCase(province.areaId), 70)
		local coastalText = province.coastal == true and (province.hasShipyard == true and "Coast — Shipyard" or "Coast") or "Inland"
		local coastalColor = province.coastal == true and UIStyle.Color.Gold or UIStyle.Color.TextMuted
		addKeyValue(geo, "Coastline", coastalText, 90, coastalColor)

		local mil = addInfoSection(informationBody, "Military", 90, 8)
		addKeyValue(mil, "Fort Tier", tostring(province.fortTier or 0), 30)
		addProgressKeyValue(mil, "Unrest", province.unrest or 0, 10, 50, UIStyle.stateColor(-(province.unrest or 0)), string.format("%.1f", province.unrest or 0))
		addKeyValue(mil, "Garrison", "—", 70, UIStyle.Color.TextMuted)

		local ownsThis = country and province.ownerTag == country.tag and province.controllerTag == country.tag
		if ownsThis and province.hasShipyard == true and bundle and bundle.shipTypes and callbacks.onRecruitShip then
			buildShipSection(informationBody, province, bundle, 9)
		end
	end

	update = function(province, country, bundle)
		if not province then return end
		do
			titleLbl.Text = province.displayCityName or province.name or ("Province " .. tostring(province.id))
			local ownerName = country and (country.displayName or country.tag) or "Unclaimed"
			local areaName = province.areaId and tostring(province.areaId):gsub("_", " ") or ""
			if areaName ~= "" then
				subtitleLbl.Text = ownerName .. "  \u{00B7}  " .. areaName
			else
				subtitleLbl.Text = ownerName
			end
		end
		refreshLinesBar(province, country)
		buildRecruitmentTab(province, country, bundle)
		buildBuildingsTab(province, country, bundle)
		buildInformationTab(province, country, bundle)
	end

	local function show(province, country, bundle, siblings)
		if not province then panel.Visible = false; return end
		update(province, country, bundle)
		renderSiblings(siblings)
		panel.Visible = true
		task.defer(function() setActive(activeTab) end)
	end

	local function hide()
		panel.Visible = false
		clearLiveTickets()
	end

	task.defer(function() setActive(TAB_KEY.Information) end)

	return {
		root = panel,
		show = show,
		hide = hide,
		update = update,
		setActive = setActive,
		getActiveTab = function() return activeTab end,
		onSiblingClick = function(cb) siblingClickCb = cb end,
	}
end

return ProvinceDetailPanel
