local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Screens = script.Parent
local UI = Screens.Parent
local ArtOfWar = UI.Parent

local DesignSystem = require(ArtOfWar.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Spacing = DesignSystem.Spacing
local Shells = DesignSystem.Shells
local Icons = DesignSystem.Icons
local Animations = DesignSystem.Animations

local Components = UI.Components
local Button = require(Components.Button)
local CountryBadge = require(Components.CountryBadge)
local StatRow = require(Components.StatRow)
local SectionDivider = require(Components.SectionDivider)

local HudWiring = require(UI.HudWiring)

local Data = ArtOfWar.Data
local GovernmentTypes = require(Data.GovernmentTypes)
local Ideologies = require(Data.Ideologies)
local Religions = require(Data.Religions)
local Cultures = require(Data.Cultures)
local SuperRegions = require(Data.SuperRegions)
local Regions = require(Data.Regions)

local NationSelection = {}

local PANEL_W = 360
local INNER = PANEL_W - Spacing.space4 * 2
local ROW_H = 64
local ROW_GAP = Spacing.space2
local LIST_TOP = 144
local BOTTOM_H = 92
local OVERLAP_MIN_W = 760

local CONTINENT_BUCKET = {
	europe = "europe",
	near_east = "asia",
	central_asia = "asia",
	east_asia = "asia",
	south_asia = "asia",
	southeast_asia = "asia",
	oceania = "asia",
	africa_north = "africa",
	africa_sub = "africa",
	americas_north = "americas",
	americas_south = "americas",
}

local CONTINENT_FILTERS = {
	{ key = nil, label = "All" },
	{ key = "europe", label = "Europe" },
	{ key = "asia", label = "Asia" },
	{ key = "africa", label = "Africa" },
	{ key = "americas", label = "Americas" },
}

local function prettify(id)
	if type(id) ~= "string" or id == "" then
		return nil
	end
	local out = {}
	for word in id:gmatch("[^_%s]+") do
		out[#out + 1] = word:sub(1, 1):upper() .. word:sub(2)
	end
	return table.concat(out, " ")
end

local function registryName(registry, id)
	local entry = id and registry[id]
	return (entry and entry.displayName) or prettify(id) or "Unknown"
end

local function colorOf(raw)
	if typeof(raw) == "Color3" then
		return raw
	end
	if type(raw) == "table" and raw[1] then
		return Color3.fromRGB(raw[1], raw[2], raw[3])
	end
	return Color3.fromRGB(120, 116, 108)
end

local function commas(n)
	if type(n) ~= "number" then
		return "\u{2014}"
	end
	local s = tostring(math.floor(n + 0.5))
	local k
	repeat
		s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
	until k == 0
	return s
end

-- Player-facing number: whole numbers stay whole, fractions clamp to one decimal (so a raw
-- 54.78333333333333 reads as "54.8" rather than a float string). Used for every numeric stat.
local function num(n)
	if type(n) ~= "number" then
		return "\u{2014}"
	end
	if n % 1 == 0 then
		return tostring(n)
	end
	return string.format("%.1f", n)
end

local function signed(n)
	if type(n) ~= "number" then
		return "\u{2014}"
	end
	if n == 0 then
		return "0"
	end
	local mag = (n % 1 == 0) and tostring(math.abs(n)) or string.format("%.1f", math.abs(n))
	return (n > 0 and "+" or "-") .. mag
end

function NationSelection.create(ctx)
	ctx = ctx or {}
	local cache = ctx.cache
	local localPlayer = Players.LocalPlayer
	local localUserId = localPlayer and localPlayer.UserId

	local selectedTag, hoveredTag = nil, nil
	local filterBucket = nil
	local searchText = ""
	local viewModels = {}
	local rowByTag = {}
	local partsByOwner = {}
	local highlightSelected = {}
	local highlightHover = {}
	local chips = {}
	local destroyed = false
	local refreshPending = false
	local followConn, viewportConn, unsubCountries

	local selectCountry, rebuildList, renderDetail, updatePlay, refreshDetailVisibility

	local root = Instance.new("Frame")
	root.Name = "NationSelectRoot"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1

	-- Dim the map behind the selection so the panel reads as a modal instead of floating in midair.
	-- AoWInputSink=false (and a non-Active Frame) keeps map hover/click working, so you can still
	-- pick a nation by clicking it on the map.
	local scrim = Instance.new("Frame")
	scrim.Name = "Scrim"
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.BackgroundColor3 = Colors.SurfaceSunken
	scrim.BackgroundTransparency = 0.4
	scrim.BorderSizePixel = 0
	scrim.ZIndex = 1
	scrim:SetAttribute("AoWInputSink", false)
	scrim.Parent = root

	local leftPanel = Shells.create("panel_large_shell", {
		Name = "LeftPanel",
		Position = UDim2.fromOffset(Spacing.space5, Spacing.space5),
		Size = UDim2.new(0, PANEL_W, 1, -Spacing.space5 * 2),
		ZIndex = 2,
	})
	leftPanel:SetAttribute("AoWInputSink", true)
	leftPanel.Parent = root
	local panelPad = Instance.new("UIPadding")
	panelPad.PaddingTop = UDim.new(0, Spacing.space4)
	panelPad.PaddingBottom = UDim.new(0, Spacing.space4)
	panelPad.PaddingLeft = UDim.new(0, Spacing.space4)
	panelPad.PaddingRight = UDim.new(0, Spacing.space4)
	panelPad.Parent = leftPanel

	local header = Instance.new("TextLabel")
	header.Name = "Header"
	header.Position = UDim2.fromOffset(0, 0)
	header.Size = UDim2.new(1, 0, 0, 28)
	header.BackgroundTransparency = 1
	header.Text = "Select a Nation"
	header.TextColor3 = Colors.TextPrimary
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.ZIndex = 3
	Typography.apply(header, "displayLg")
	header.Parent = leftPanel

	local subCount = Instance.new("TextLabel")
	subCount.Name = "SubCount"
	subCount.Position = UDim2.fromOffset(0, 30)
	subCount.Size = UDim2.new(1, 0, 0, 14)
	subCount.BackgroundTransparency = 1
	subCount.Text = "Choose your starting country in 1750."
	subCount.TextColor3 = Colors.TextSecondary
	subCount.TextXAlignment = Enum.TextXAlignment.Left
	subCount.ZIndex = 3
	Typography.apply(subCount, "bodySm")
	subCount.Parent = leftPanel

	local divider = Shells.create("divider_line_thin", {
		Name = "Divider",
		Position = UDim2.fromOffset(0, 50),
		Size = UDim2.new(1, 0, 0, 2),
		ZIndex = 3,
	})
	divider.Parent = leftPanel

	local search = Shells.create("search_box_shell", {
		Name = "Search",
		Position = UDim2.fromOffset(0, 60),
		Size = UDim2.new(1, 0, 0, 38),
		ZIndex = 3,
	})
	search.Parent = leftPanel
	local searchStroke = Instance.new("UIStroke")
	searchStroke.Color = Colors.BorderActive
	searchStroke.Thickness = 1
	searchStroke.Transparency = 1
	searchStroke.Parent = search
	local searchIcon = Icons.create("Search", 16, Colors.TextSecondary)
	searchIcon.AnchorPoint = Vector2.new(0, 0.5)
	searchIcon.Position = UDim2.new(0, 12, 0.5, 0)
	searchIcon.ZIndex = 4
	searchIcon.Parent = search
	local searchBox = Instance.new("TextBox")
	searchBox.Name = "Input"
	searchBox.Position = UDim2.fromOffset(36, 0)
	searchBox.Size = UDim2.new(1, -48, 1, 0)
	searchBox.BackgroundTransparency = 1
	searchBox.Text = ""
	searchBox.PlaceholderText = "Search nations"
	searchBox.PlaceholderColor3 = Colors.TextTertiary
	searchBox.TextColor3 = Colors.TextPrimary
	searchBox.TextXAlignment = Enum.TextXAlignment.Left
	searchBox.ClearTextOnFocus = false
	searchBox.ClipsDescendants = true
	searchBox.ZIndex = 4
	Typography.apply(searchBox, "bodyMd")
	searchBox.Parent = search

	local filterRow = Instance.new("Frame")
	filterRow.Name = "Filters"
	filterRow.Position = UDim2.fromOffset(0, 106)
	filterRow.Size = UDim2.new(1, 0, 0, 30)
	filterRow.BackgroundTransparency = 1
	filterRow.ZIndex = 3
	filterRow.Parent = leftPanel
	local filterLayout = Instance.new("UIListLayout")
	filterLayout.FillDirection = Enum.FillDirection.Horizontal
	filterLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	filterLayout.SortOrder = Enum.SortOrder.LayoutOrder
	filterLayout.Padding = UDim.new(0, Spacing.space1)
	filterLayout.Parent = filterRow

	local listFrame = Instance.new("ScrollingFrame")
	listFrame.Name = "List"
	listFrame.Position = UDim2.fromOffset(0, LIST_TOP)
	listFrame.Size = UDim2.new(1, 0, 1, -(LIST_TOP + BOTTOM_H + Spacing.space3))
	listFrame.BackgroundTransparency = 1
	listFrame.BorderSizePixel = 0
	listFrame.ScrollBarThickness = 4
	listFrame.ScrollBarImageColor3 = Colors.BorderStrong
	listFrame.CanvasSize = UDim2.new()
	listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	listFrame.ZIndex = 3
	listFrame.Parent = leftPanel
	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Vertical
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, ROW_GAP)
	listLayout.Parent = listFrame

	local emptyState = Instance.new("TextLabel")
	emptyState.Name = "Empty"
	emptyState.Position = UDim2.fromOffset(0, LIST_TOP + 8)
	emptyState.Size = UDim2.new(1, 0, 0, 40)
	emptyState.BackgroundTransparency = 1
	emptyState.Text = "Loading nations\u{2026}"
	emptyState.TextColor3 = Colors.TextTertiary
	emptyState.TextXAlignment = Enum.TextXAlignment.Left
	emptyState.TextWrapped = true
	emptyState.Visible = false
	emptyState.ZIndex = 3
	Typography.apply(emptyState, "bodyMd")
	emptyState.Parent = leftPanel

	local bottomBar = Instance.new("Frame")
	bottomBar.Name = "Actions"
	bottomBar.AnchorPoint = Vector2.new(0.5, 1)
	bottomBar.Position = UDim2.new(0.5, 0, 1, 0)
	bottomBar.Size = UDim2.new(1, 0, 0, BOTTOM_H)
	bottomBar.BackgroundTransparency = 1
	bottomBar.ZIndex = 3
	bottomBar.Parent = leftPanel

	local randomBtn = Button.create({
		variant = "secondary",
		size = "md",
		width = INNER,
		text = "Random Nation",
		zIndex = 3,
	})
	randomBtn.AnchorPoint = Vector2.new(0.5, 1)
	randomBtn.Position = UDim2.new(0.5, 0, 1, -(46 + Spacing.space2))
	randomBtn.Parent = bottomBar

	local playBtn = Button.create({
		variant = "primary",
		size = "lg",
		width = INNER,
		text = "Select a Nation",
		disabled = true,
		zIndex = 3,
	})
	playBtn.AnchorPoint = Vector2.new(0.5, 1)
	playBtn.Position = UDim2.new(0.5, 0, 1, 0)
	playBtn.Parent = bottomBar
	local playLabel = playBtn:FindFirstChild("Label")

	local detailCard = Shells.create("panel_card_tall_shell", {
		Name = "DetailCard",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -Spacing.space5, 0, Spacing.space5),
		Size = UDim2.fromOffset(340, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = false,
		ZIndex = 2,
	})
	detailCard:SetAttribute("AoWInputSink", true)
	detailCard.Parent = root
	local cardPad = Instance.new("UIPadding")
	cardPad.PaddingTop = UDim.new(0, Spacing.space4)
	cardPad.PaddingBottom = UDim.new(0, Spacing.space4)
	cardPad.PaddingLeft = UDim.new(0, Spacing.space4)
	cardPad.PaddingRight = UDim.new(0, Spacing.space4)
	cardPad.Parent = detailCard
	local cardLayout = Instance.new("UIListLayout")
	cardLayout.FillDirection = Enum.FillDirection.Vertical
	cardLayout.SortOrder = Enum.SortOrder.LayoutOrder
	cardLayout.Padding = UDim.new(0, Spacing.space2)
	cardLayout.Parent = detailCard

	local tooltipLayer = ctx.tooltipLayer or root
	local tooltip = Shells.create("tooltip_shell", {
		Name = "NationTooltip",
		Size = UDim2.fromOffset(224, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = false,
		ZIndex = 90,
	})
	tooltip:SetAttribute("AoWInputSink", false)
	local ttPad = Instance.new("UIPadding")
	ttPad.PaddingTop = UDim.new(0, Spacing.space3)
	ttPad.PaddingBottom = UDim.new(0, Spacing.space3)
	ttPad.PaddingLeft = UDim.new(0, Spacing.space4)
	ttPad.PaddingRight = UDim.new(0, Spacing.space4)
	ttPad.Parent = tooltip
	local ttLayout = Instance.new("UIListLayout")
	ttLayout.SortOrder = Enum.SortOrder.LayoutOrder
	ttLayout.Padding = UDim.new(0, 2)
	ttLayout.Parent = tooltip
	local function ttLine(role, color, order)
		local l = Instance.new("TextLabel")
		l.AutomaticSize = Enum.AutomaticSize.Y
		l.Size = UDim2.new(1, 0, 0, 0)
		l.BackgroundTransparency = 1
		l.Text = ""
		l.TextColor3 = color
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextWrapped = true
		l.LayoutOrder = order
		l.ZIndex = 91
		Typography.apply(l, role)
		l.Parent = tooltip
		return l
	end
	local ttTitle = ttLine("title", Colors.TextPrimary, 1)
	local ttLine1 = ttLine("bodySm", Colors.TextSecondary, 2)
	local ttLine2 = ttLine("caption", Colors.TextTertiary, 3)
	local ttLine3 = ttLine("caption", Colors.Accent, 4)
	tooltip.Parent = tooltipLayer

	local function layerScale(inst)
		local sg = inst and inst.Parent
		local us = sg and sg:FindFirstChildWhichIsA("UIScale")
		return (us and us.Scale) or 1
	end

	local function positionTooltip()
		local cam = workspace.CurrentCamera
		local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
		local scale = layerScale(tooltip)
		local size = tooltip.AbsoluteSize
		if size.X <= 0 or size.Y <= 0 then
			return
		end
		local w = size.X
		local h = size.Y
		local mp = UserInputService:GetMouseLocation()
		local x = mp.X + 16
		local y = mp.Y + 18
		if x + w > vp.X - 8 then
			x = mp.X - 16 - w
		end
		if y + h > vp.Y - 8 then
			y = mp.Y - 18 - h
		end
		x = math.clamp(x, 8, math.max(8, vp.X - w - 8))
		y = math.clamp(y, 8, math.max(8, vp.Y - h - 8))
		tooltip.Position = UDim2.fromOffset(x / scale, y / scale)
	end

	local function startFollow()
		positionTooltip()
		if not followConn then
			followConn = RunService.RenderStepped:Connect(positionTooltip)
		end
	end
	local function stopFollow()
		if followConn then
			followConn:Disconnect()
			followConn = nil
		end
	end

	local function buildPartsIndex()
		partsByOwner = {}
		local map = workspace:FindFirstChild("ArtOfWarMap")
		if not map then
			return
		end
		local function scan(folder)
			if not folder then
				return
			end
			for _, p in ipairs(folder:GetChildren()) do
				if p:IsA("BasePart") then
					local owner = p:GetAttribute("owner")
					if owner and owner ~= "" and owner ~= "NONE" then
						local bucket = partsByOwner[owner]
						if not bucket then
							bucket = {}
							partsByOwner[owner] = bucket
						end
						bucket[#bucket + 1] = p
					end
				end
			end
		end
		scan(map:FindFirstChild("Provinces"))
		local lw = map:FindFirstChild("LeftWrap")
		scan(lw and lw:FindFirstChild("Provinces"))
		local rw = map:FindFirstChild("RightWrap")
		scan(rw and rw:FindFirstChild("Provinces"))
	end

	local function applyHighlight(tag, store, amount)
		local bucket = tag and partsByOwner[tag]
		if not bucket then
			return
		end
		for _, p in ipairs(bucket) do
			if store[p] == nil then
				store[p] = p.Color
				p.Color = p.Color:Lerp(Color3.new(1, 1, 1), amount)
			end
		end
	end

	local function restoreHighlight(store)
		for p, original in pairs(store) do
			if p.Parent then
				p.Color = original
			end
		end
		table.clear(store)
	end

	local function continentOf(rec)
		local cap = rec.capitalProvinceId and cache and cache.getProvince(rec.capitalProvinceId)
		local superId = cap and cap.superRegionId
		if not superId and cap and cap.regionId then
			local region = Regions[cap.regionId]
			superId = region and region.superRegionId
		end
		local display = (superId and SuperRegions[superId] and SuperRegions[superId].displayName) or "Unknown"
		local bucket = (superId and CONTINENT_BUCKET[superId]) or "other"
		local capitalName = (cap and (cap.displayCityName or cap.name)) or "Unknown"
		return display, bucket, capitalName
	end

	local function buildViewModels()
		viewModels = {}
		local provinceCount = {}
		for _, p in pairs((cache and cache.allProvinces and cache.allProvinces()) or {}) do
			local owner = p.ownerTag
			if owner then
				provinceCount[owner] = (provinceCount[owner] or 0) + 1
			end
		end
		for tag, c in pairs((cache and cache.allCountries and cache.allCountries()) or {}) do
			local continent, bucket, capital = continentOf(c)
			viewModels[tag] = {
				tag = tag,
				name = c.displayName or tag,
				color = colorOf(c.color),
				government = registryName(GovernmentTypes, c.governmentForm),
				ideology = registryName(Ideologies, c.ideology),
				religion = registryName(Religions, c.stateReligion),
				culture = registryName(Cultures, c.primaryCulture),
				capital = capital,
				continent = continent,
				continentBucket = bucket,
				provinces = provinceCount[tag] or 0,
				treasury = c.treasury,
				manpower = c.manpower,
				politicalPower = c.politicalPower,
				stability = c.stability,
				legitimacy = c.legitimacy,
				claimed = c.claimedBy ~= nil,
				claimedByMe = c.claimedBy == localUserId,
			}
		end
	end

	local function matchesSearch(vm)
		if searchText == "" then
			return true
		end
		local hay = (vm.name .. " " .. vm.tag .. " " .. vm.continent .. " " .. vm.government .. " " .. vm.ideology):lower()
		return hay:find(searchText, 1, true) ~= nil
	end

	local function passesFilter(vm)
		if filterBucket and vm.continentBucket ~= filterBucket then
			return false
		end
		return matchesSearch(vm)
	end

	local function filteredSortedTags()
		local tags = {}
		for tag, vm in pairs(viewModels) do
			if passesFilter(vm) then
				tags[#tags + 1] = tag
			end
		end
		table.sort(tags, function(a, b)
			return viewModels[a].name < viewModels[b].name
		end)
		return tags
	end

	local function ensureRowVisible(index)
		if not index then
			return
		end
		local rowSpan = ROW_H + ROW_GAP
		local top = (index - 1) * rowSpan
		local viewH = listFrame.AbsoluteSize.Y
		local cur = listFrame.CanvasPosition.Y
		if top < cur then
			listFrame.CanvasPosition = Vector2.new(0, top)
		elseif top + ROW_H > cur + viewH then
			listFrame.CanvasPosition = Vector2.new(0, math.max(0, top + ROW_H - viewH))
		end
	end

	local function makeRow(vm, index)
		local btn = Instance.new("TextButton")
		btn.Name = vm.tag
		btn.Size = UDim2.new(1, 0, 0, ROW_H)
		btn.BackgroundTransparency = 1
		btn.AutoButtonColor = false
		btn.Text = ""
		btn.LayoutOrder = index
		btn.ZIndex = 3

		local normal = Shells.create("nation_list_row_shell", { Name = "Normal", ZIndex = 3 })
		normal.Parent = btn
		local selected =
			Shells.create("nation_list_row_selected", { Name = "Selected", ImageTransparency = 1, ZIndex = 3 })
		selected.Parent = btn

		local swatch = Instance.new("Frame")
		swatch.Name = "Swatch"
		swatch.AnchorPoint = Vector2.new(0, 0.5)
		swatch.Position = UDim2.new(0, 12, 0.5, 0)
		swatch.Size = UDim2.fromOffset(6, 40)
		swatch.BackgroundColor3 = vm.color
		swatch.BorderSizePixel = 0
		swatch.ZIndex = 4
		local swatchCorner = Instance.new("UICorner")
		swatchCorner.CornerRadius = UDim.new(0, 2)
		swatchCorner.Parent = swatch
		swatch.Parent = btn

		local badge = CountryBadge.create({ code = vm.tag, countryColor = vm.color, size = "sm", parent = btn })
		badge.AnchorPoint = Vector2.new(0, 0.5)
		badge.Position = UDim2.new(0, 26, 0.5, 0)
		badge.ZIndex = 4

		local name = Instance.new("TextLabel")
		name.Name = "CountryName"
		name.Position = UDim2.fromOffset(78, 11)
		name.Size = UDim2.new(1, -150, 0, 22)
		name.BackgroundTransparency = 1
		name.Text = vm.name
		name.TextColor3 = Colors.TextPrimary
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.ZIndex = 4
		Typography.apply(name, "displayMd")
		name.Parent = btn

		local sub = Instance.new("TextLabel")
		sub.Name = "Sub"
		sub.Position = UDim2.fromOffset(78, 33)
		sub.Size = UDim2.new(1, -150, 0, 16)
		sub.BackgroundTransparency = 1
		sub.Text = vm.government .. "  \u{00B7}  " .. vm.ideology
		sub.TextColor3 = Colors.TextSecondary
		sub.TextXAlignment = Enum.TextXAlignment.Left
		sub.TextTruncate = Enum.TextTruncate.AtEnd
		sub.ZIndex = 4
		Typography.apply(sub, "bodySm")
		sub.Parent = btn

		if vm.claimed then
			local pill = Shells.create("pill_grey", {
				Name = "Taken",
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -12, 0.5, 0),
				Size = UDim2.fromOffset(56, 22),
				ZIndex = 4,
			})
			pill.Parent = btn
			local pillLabel = Instance.new("TextLabel")
			pillLabel.Size = UDim2.fromScale(1, 1)
			pillLabel.BackgroundTransparency = 1
			pillLabel.Text = vm.claimedByMe and "You" or "Taken"
			pillLabel.TextColor3 = Colors.TextSecondary
			pillLabel.ZIndex = 5
			Typography.apply(pillLabel, "caption")
			pillLabel.Parent = pill
		end

		local handle = { btn = btn, normal = normal, selected = selected, index = index }
		function handle.setSelected(on)
			Animations.tween(selected, Animations.Fast, { ImageTransparency = on and 0 or 1 })
		end
		btn.MouseEnter:Connect(function()
			if selectedTag ~= vm.tag then
				Animations.tween(normal, Animations.Fast, { ImageTransparency = 0.15 })
			end
		end)
		btn.MouseLeave:Connect(function()
			Animations.tween(normal, Animations.Fast, { ImageTransparency = 0 })
		end)
		btn.MouseButton1Click:Connect(function()
			selectCountry(vm.tag, "list")
		end)
		return handle
	end

	function rebuildList()
		local tags = filteredSortedTags()
		for _, child in listFrame:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		rowByTag = {}
		for i, tag in ipairs(tags) do
			local row = makeRow(viewModels[tag], i)
			row.btn.Parent = listFrame
			rowByTag[tag] = row
			if tag == selectedTag then
				row.setSelected(true)
			end
		end

		local available, taken = 0, 0
		for _, vm in pairs(viewModels) do
			if vm.claimed then
				taken += 1
			else
				available += 1
			end
		end
		if next(viewModels) == nil then
			emptyState.Text = "Loading nations\u{2026}"
			emptyState.Visible = true
			subCount.Text = "Choose your starting country in 1750."
		else
			emptyState.Text = "No nations match your search."
			emptyState.Visible = #tags == 0
			subCount.Text = string.format("%d available  \u{00B7}  %d taken", available, taken)
		end
	end

	function renderDetail(vm)
		for _, child in detailCard:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		if not vm then
			return
		end

		local flag = Shells.create(
			"slot_flag_rect",
			{ Name = "Flag", Size = UDim2.new(1, 0, 0, 150), LayoutOrder = 1, ZIndex = 3 }
		)
		flag.Parent = detailCard
		local flagSwatch = Instance.new("Frame")
		flagSwatch.AnchorPoint = Vector2.new(0.5, 1)
		flagSwatch.Position = UDim2.new(0.5, 0, 1, -10)
		flagSwatch.Size = UDim2.new(1, -28, 0, 4)
		flagSwatch.BackgroundColor3 = vm.color
		flagSwatch.BorderSizePixel = 0
		flagSwatch.ZIndex = 4
		flagSwatch.Parent = flag

		local headerRow = Instance.new("Frame")
		headerRow.Name = "CardHeader"
		headerRow.Size = UDim2.new(1, 0, 0, 48)
		headerRow.BackgroundTransparency = 1
		headerRow.LayoutOrder = 2
		headerRow.ZIndex = 3
		headerRow.Parent = detailCard
		local cardBadge =
			CountryBadge.create({ code = vm.tag, countryColor = vm.color, size = "md", parent = headerRow })
		cardBadge.AnchorPoint = Vector2.new(0, 0.5)
		cardBadge.Position = UDim2.new(0, 0, 0.5, 0)
		cardBadge.ZIndex = 4
		local cardName = Instance.new("TextLabel")
		cardName.Position = UDim2.fromOffset(60, 0)
		cardName.Size = UDim2.new(1, -60, 1, 0)
		cardName.BackgroundTransparency = 1
		cardName.Text = vm.name
		cardName.TextColor3 = Colors.TextPrimary
		cardName.TextXAlignment = Enum.TextXAlignment.Left
		cardName.TextYAlignment = Enum.TextYAlignment.Center
		cardName.TextTruncate = Enum.TextTruncate.AtEnd
		cardName.ZIndex = 4
		Typography.apply(cardName, "displayLg")
		cardName.Parent = headerRow

		local order = 3
		local function statRow(opts)
			opts.parent = detailCard
			opts.layoutOrder = order
			order += 1
			StatRow.create(opts)
		end
		local function section(label)
			SectionDivider.create({ parent = detailCard, label = label, layoutOrder = order })
			order += 1
		end

		section("Government")
		statRow({ label = "Government", value = vm.government })
		statRow({ label = "Ideology", value = vm.ideology })
		statRow({ label = "Religion", value = vm.religion })
		statRow({ label = "Culture", value = vm.culture })
		statRow({ label = "Capital", value = vm.capital })
		statRow({ label = "Continent", value = vm.continent })

		section("State")
		statRow({ icon = "Treasury", label = "Treasury", value = commas(vm.treasury), mono = true })
		statRow({ icon = "Manpower", label = "Manpower", value = commas(vm.manpower), mono = true })
		statRow({ icon = "PowerProj", label = "Political Power", value = num(vm.politicalPower or 0) })
		statRow({ icon = "Stability", label = "Stability", value = signed(vm.stability) })
		statRow({ icon = "Legitimacy", label = "Legitimacy", value = num(vm.legitimacy or 0) })
		statRow({ icon = "MapPolitical", label = "Provinces", value = num(vm.provinces) })

		if vm.claimed then
			local status = Instance.new("TextLabel")
			status.Size = UDim2.new(1, 0, 0, 20)
			status.BackgroundTransparency = 1
			status.Text = vm.claimedByMe and "Your nation" or "Taken by another player"
			status.TextColor3 = vm.claimedByMe and Colors.Positive or Colors.Negative
			status.TextXAlignment = Enum.TextXAlignment.Left
			status.LayoutOrder = order
			status.ZIndex = 3
			Typography.apply(status, "bodySm")
			status.Parent = detailCard
		end
	end

	local function wideEnough()
		local cam = workspace.CurrentCamera
		local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
		return vp.X >= OVERLAP_MIN_W * layerScale(detailCard)
	end

	function refreshDetailVisibility()
		detailCard.Visible = (not destroyed) and selectedTag ~= nil and wideEnough()
	end

	function updatePlay(vm)
		if vm and not vm.claimed then
			playBtn.Active = true
			if playLabel then
				playLabel.Text = "Play as " .. vm.name
			end
		else
			playBtn.Active = false
			if playLabel then
				playLabel.Text = (vm and vm.claimed and (vm.name .. " is taken")) or "Select a Nation"
			end
		end
	end

	function selectCountry(tag, source)
		if destroyed then
			return
		end
		local vm = tag and viewModels[tag]
		if not vm or tag == selectedTag then
			return
		end
		restoreHighlight(highlightSelected)
		restoreHighlight(highlightHover)
		applyHighlight(tag, highlightSelected, 0.45)
		hoveredTag = nil
		if selectedTag and rowByTag[selectedTag] then
			rowByTag[selectedTag].setSelected(false)
		end
		selectedTag = tag
		local row = rowByTag[tag]
		if row then
			row.setSelected(true)
			if source ~= "list" then
				ensureRowVisible(row.index)
			end
		end
		renderDetail(vm)
		refreshDetailVisibility()
		updatePlay(vm)
	end

	local function setFilter(bucket)
		filterBucket = bucket
		for _, chip in ipairs(chips) do
			chip.setSelected(chip.key == bucket)
		end
		rebuildList()
		if selectedTag and rowByTag[selectedTag] then
			rowByTag[selectedTag].setSelected(true)
		end
	end

	local function makeChip(spec)
		local btn = Instance.new("TextButton")
		btn.Name = "Chip_" .. spec.label
		btn.AutomaticSize = Enum.AutomaticSize.X
		btn.Size = UDim2.new(0, 0, 0, 28)
		btn.BackgroundTransparency = 1
		btn.AutoButtonColor = false
		btn.Text = ""
		btn.LayoutOrder = spec.order
		btn.ZIndex = 3
		-- Procedural chip surface (Frame + UICorner + UIStroke) with a small corner so the region
		-- filters read as tight chips, not fully-rounded capsules. Also avoids the 9-slice load race.
		local bg = Instance.new("Frame")
		bg.Name = "Bg"
		bg.Size = UDim2.fromScale(1, 1)
		bg.BackgroundColor3 = Colors.SurfaceElevated
		bg.BackgroundTransparency = 1
		bg.BorderSizePixel = 0
		bg.ZIndex = 3
		bg.Parent = btn
		local bgCorner = Instance.new("UICorner")
		bgCorner.CornerRadius = UDim.new(0, 4)
		bgCorner.Parent = bg
		local stroke = Instance.new("UIStroke")
		stroke.Color = Colors.BorderSubtle
		stroke.Thickness = 1
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = bg
		local label = Instance.new("TextLabel")
		label.AutomaticSize = Enum.AutomaticSize.X
		label.Size = UDim2.new(0, 0, 1, 0)
		label.BackgroundTransparency = 1
		label.Text = spec.label
		label.TextColor3 = Colors.TextSecondary
		label.ZIndex = 5
		Typography.apply(label, "caption")
		label.Parent = btn
		local labelPad = Instance.new("UIPadding")
		labelPad.PaddingLeft = UDim.new(0, 12)
		labelPad.PaddingRight = UDim.new(0, 12)
		labelPad.Parent = label

		local handle = { key = spec.key, selected = false }
		function handle.setSelected(on)
			handle.selected = on
			bg.BackgroundColor3 = Colors.SurfaceOverlay
			Animations.tween(bg, Animations.Fast, { BackgroundTransparency = on and 0 or 1 })
			Animations.tween(stroke, Animations.Fast, { Color = on and Colors.BorderActive or Colors.BorderSubtle })
			label.TextColor3 = on and Colors.Accent or Colors.TextSecondary
		end
		btn.MouseEnter:Connect(function()
			if not handle.selected then
				bg.BackgroundColor3 = Colors.SurfaceElevated
				Animations.tween(bg, Animations.Fast, { BackgroundTransparency = 0.4 })
			end
		end)
		btn.MouseLeave:Connect(function()
			if not handle.selected then
				Animations.tween(bg, Animations.Fast, { BackgroundTransparency = 1 })
			end
		end)
		btn.MouseButton1Click:Connect(function()
			setFilter(spec.key)
		end)
		btn.Parent = filterRow
		return handle
	end

	for i, spec in ipairs(CONTINENT_FILTERS) do
		spec.order = i
		chips[#chips + 1] = makeChip(spec)
	end
	if chips[1] then
		chips[1].setSelected(true)
	end

	randomBtn.MouseButton1Click:Connect(function()
		local pool = {}
		for tag, vm in pairs(viewModels) do
			if not vm.claimed and passesFilter(vm) then
				pool[#pool + 1] = tag
			end
		end
		if #pool == 0 then
			for tag, vm in pairs(viewModels) do
				if not vm.claimed then
					pool[#pool + 1] = tag
				end
			end
		end
		if #pool > 0 then
			selectCountry(pool[math.random(1, #pool)], "random")
		end
	end)

	playBtn.MouseButton1Click:Connect(function()
		if not selectedTag then
			return
		end
		local vm = viewModels[selectedTag]
		if vm and not vm.claimed and ctx.data and ctx.data.onPlay then
			ctx.data.onPlay(selectedTag)
		end
	end)

	searchBox.Focused:Connect(function()
		searchStroke.Transparency = 0
	end)
	searchBox.FocusLost:Connect(function(enterPressed)
		searchStroke.Transparency = 1
		if enterPressed then
			local tags = filteredSortedTags()
			if tags[1] then
				selectCountry(tags[1], "search")
			end
		end
	end)
	-- Debounce the list rebuild so rapid typing doesn't re-sort + rebuild all ~131 rows on every
	-- keystroke; rebuild once the user pauses. searchText updates immediately so an Enter (FocusLost)
	-- still matches against the latest query.
	local searchDebounce
	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		searchText = searchBox.Text:lower()
		if searchDebounce then
			task.cancel(searchDebounce)
		end
		searchDebounce = task.delay(0.12, function()
			searchDebounce = nil
			rebuildList()
			if selectedTag and rowByTag[selectedTag] then
				rowByTag[selectedTag].setSelected(true)
			end
		end)
	end)

	local api = {}
	function api.setCandidateFromMap(tag)
		selectCountry(tag, "map")
	end
	function api.hoverCountry(tag)
		if destroyed then
			return
		end
		if tag == "" or tag == "NONE" then
			tag = nil
		end
		if tag == hoveredTag then
			return
		end
		restoreHighlight(highlightHover)
		hoveredTag = tag
		local vm = tag and viewModels[tag]
		if vm then
			if tag ~= selectedTag then
				applyHighlight(tag, highlightHover, 0.22)
			end
			ttTitle.Text = vm.name
			ttLine1.Text = vm.government .. "  \u{00B7}  " .. vm.religion .. "  \u{00B7}  " .. vm.culture
			ttLine2.Text = vm.continent .. "  \u{00B7}  " .. vm.provinces .. " provinces"
			ttLine3.Text = vm.claimed and (vm.claimedByMe and "Your nation" or "Taken") or "Click to select"
			ttLine3.TextColor3 = vm.claimed and Colors.Negative or Colors.Accent
			tooltip.Position = UDim2.fromOffset(-4000, -4000)
			tooltip.Visible = true
			startFollow()
		else
			tooltip.Visible = false
			stopFollow()
		end
	end

	buildViewModels()
	buildPartsIndex()
	rebuildList()
	HudWiring.setNationSelectApi(api)

	local cam = workspace.CurrentCamera
	if cam then
		viewportConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(refreshDetailVisibility)
	end

	if cache and cache.onChangePrefix then
		unsubCountries = cache.onChangePrefix("countries", function()
			if refreshPending then
				return
			end
			refreshPending = true
			task.defer(function()
				refreshPending = false
				if destroyed then
					return
				end
				buildViewModels()
				rebuildList()
				if selectedTag then
					local vm = viewModels[selectedTag]
					if vm then
						if rowByTag[selectedTag] then
							rowByTag[selectedTag].setSelected(true)
						end
						renderDetail(vm)
						updatePlay(vm)
					else
						selectedTag = nil
						restoreHighlight(highlightSelected)
						updatePlay(nil)
					end
				end
				refreshDetailVisibility()
			end)
		end)
	end

	if ctx.parent then
		root.Parent = ctx.parent
	end

	local function destroy()
		if destroyed then
			return
		end
		destroyed = true
		stopFollow()
		restoreHighlight(highlightSelected)
		restoreHighlight(highlightHover)
		if unsubCountries then
			pcall(unsubCountries)
		end
		if viewportConn then
			viewportConn:Disconnect()
		end
		HudWiring.setNationSelectActive(false)
		HudWiring.setNationSelectApi(nil)
		if ctx.hudLayer then
			ctx.hudLayer.Enabled = true
		end
		if tooltip then
			tooltip:Destroy()
		end
		root:Destroy()
	end

	return { root = root, destroy = destroy }
end

return NationSelection
