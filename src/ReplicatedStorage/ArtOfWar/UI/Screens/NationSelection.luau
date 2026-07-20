local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

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
local Tooltip = require(Components.Tooltip) -- for the shared Tooltip.enabled() player setting only
local SectionDivider = require(Components.SectionDivider)

local HudWiring = require(UI.HudWiring)

local WorldConstants = require(ArtOfWar.Shared.WorldConstants)

local Modules = ArtOfWar.Modules
local CameraController = require(Modules.CameraController)
local ProvincePositions = require(Modules.ProvincePositions)

local Data = ArtOfWar.Data
local GovernmentTypes = require(Data.GovernmentTypes)
local Ideologies = require(Data.Ideologies)
local Religions = require(Data.Religions)
local Cultures = require(Data.Cultures)
local SuperRegions = require(Data.SuperRegions)
local Regions = require(Data.Regions)

local NationSelection = {}

local PANEL_W = 360
local CARD_W = 340 -- the right-hand dossier
local INNER = PANEL_W - Spacing.space4 * 2
local ROW_H = 64
local ROW_GAP = Spacing.space2
local LIST_TOP = 204
local BOTTOM_H = 92
local OVERLAP_MIN_W = 760

-- The filter block (continent chips + sort/size chips + pager) stacks to 92px and sits below the search box.
-- On a tall viewport it is always open and the list starts under it (LIST_TOP). On a short one there is no
-- room for both -- the inline list height is `viewportY - 388`, i.e. ~27px on a landscape phone -- so the
-- block collapses behind a toggle and floats over the list when opened, and the list starts right under that
-- toggle instead (LIST_TOP_COMPACT). See isCompact for why the switch is derived rather than a fixed height.
local FILTERS_TOP = 106
local FILTERS_H = 92
local TOGGLE_H = 28
local LIST_TOP_COMPACT = FILTERS_TOP + TOGGLE_H + Spacing.space1 -- toggle sits where the chips would have
local MIN_LIST_ROWS = 3 -- fewer than this seated by the inline layout -> collapse the chips instead
-- Collapsing the chips alone only takes the list from ~12px to ~93px on a landscape phone -- still under two
-- rows. The other hog is this bar: two FULL-WIDTH buttons stacked (46 + 8 + 46 = 100px crammed into 92). Side
-- by side they cost one button's height, which is the difference between a 1-row list and a usable one.
local BOTTOM_H_COMPACT = 52
-- Collapsing the chips gets a landscape phone's list to ~133px, which still only seats ONE 64px row. The rows
-- are the last thing in the way, so they shrink too. Everything a row draws is either centred (the swatch and
-- crest, which just need to fit) or laid out from these offsets, so one table drives the whole geometry.
local ROW_H_COMPACT = 48
local ROW_CREST_PX, ROW_CREST_PX_COMPACT = 40, 32
local ROW_NAME_Y, ROW_SUB_Y = 11, 33 -- name (h22) + sub (h16) centred in a 64px row
local ROW_NAME_Y_COMPACT, ROW_SUB_Y_COMPACT = 5, 27 -- ...and in a 48px one

-- Collapse based on what the inline layout would actually LEAVE the list, not on an arbitrary height. A fixed
-- breakpoint reads fine but inverts around itself: the collapsed layout always frees ~106px, so at a
-- breakpoint of 640 a 639px viewport got 5 rows and a 641px one got 3 -- growing the window shrank the list.
-- Deriving the switch from the starved-list threshold keeps the two layouts adjacent in value: we only
-- collapse once inline can no longer seat MIN_LIST_ROWS. (Module scope, not create-local: makeRow needs it,
-- and makeRow is defined long before the layout code.)
local function inlineListPx(vpY)
	local inner = (vpY - Spacing.space5 * 2) - Spacing.space4 * 2
	return inner - (LIST_TOP + BOTTOM_H + Spacing.space3)
end
local function isCompact()
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
	return inlineListPx(vp.Y) < MIN_LIST_ROWS * (ROW_H + ROW_GAP) - ROW_GAP
end

-- Resolve the responsive UIScale, which Responsive.attach puts on the SCREENGUI. This used to read
-- `inst.Parent` and assume that WAS the ScreenGui -- true for the tooltip (parented straight to the tooltip
-- layer) but false for detailCard, whose parent is `root`, a plain Frame. So it silently returned 1 for the
-- card and wideEnough() compared the viewport against a raw 760 instead of 760 x scale, letting the card
-- overlap the picker at large scales. Walk to the real ScreenGui instead of guessing at depth. (Module scope
-- so sizeDetailCard can use it -- it runs long before the create-local helpers are defined.)
local function layerScale(inst)
	local sg = inst and inst:FindFirstAncestorWhichIsA("ScreenGui")
	local us = sg and sg:FindFirstChildWhichIsA("UIScale")
	return (us and us.Scale) or 1
end

-- rowH, crest px, name y, sub y -- everything makeRow needs to lay a row out at the current size.
local function rowMetrics()
	if isCompact() then
		return ROW_H_COMPACT, ROW_CREST_PX_COMPACT, ROW_NAME_Y_COMPACT, ROW_SUB_Y_COMPACT
	end
	return ROW_H, ROW_CREST_PX, ROW_NAME_Y, ROW_SUB_Y
end

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

-- `key` is matched against vm.continentBucket. Five chips is what fits the 360px panel on one line -- a sixth
-- ("Recommended") pushed "Americas" off the edge, which is half of why it's gone; see powerBand below.
local CONTINENT_FILTERS = {
	{ key = nil, label = "All" },
	{ key = "europe", label = "Europe" },
	{ key = "asia", label = "Asia" },
	{ key = "africa", label = "Africa" },
	{ key = "americas", label = "Americas" },
}

-- Bands by territory, so "231 provinces" means something at a glance. Same shape as FormablesScreen's tierOf
-- (which bands formable goals by province count) -- that one is file-local and not exported, so this is a
-- deliberate sibling rather than a shared helper.
local GREAT_POWER_MIN = 100
local function powerBand(provinces)
	if provinces >= GREAT_POWER_MIN then
		return "Great Power"
	elseif provinces >= 25 then
		return "Regional Power"
	elseif provinces >= 5 then
		return "Minor Power"
	end
	return "Minor State"
end

-- (There was a "Recommended" filter here that showed only unclaimed great powers, and opened by default. It
-- is gone for a reason worth keeping written down: its eligibility included `not claimed`, so on a busy
-- server -- exactly when a new player is most likely to arrive -- every great power could be taken and the
-- DEFAULT view would be empty. A first screen that can render "nothing to pick" is worse than a long list.
-- The power bands below carry the same "where do I start?" information without ever being able to hide a
-- nation, so the guidance survives and the failure mode doesn't. The default filter is "All".)

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
	local filterBucket = nil -- "All": the default must never be a view that can come up empty
	local searchText = ""
	local pageSize = 25
	local pageIndex = 0
	local sortMode = "rank" -- "rank" (biggest realms first) or "name" (A-Z)
	local pageLabel -- "Page x / y" label, built with the pager; updated by rebuildList
	local viewModels = {}
	local rowByTag = {}
	local partsByOwner = {}
	local provinceIdsByOwner = {} -- [tag] = { provinceId, ... }; built with the view models, read by the camera
	local highlightSelected = {}
	local highlightHover = {}
	local chips = {}
	local destroyed = false
	local refreshPending = false
	local followConn, viewportConn, unsubCountries, unsubProvincesReady

	local selectCountry, rebuildList, renderDetail, updatePlay, refreshDetailVisibility
	-- relayout is defined once the filter block and its toggle exist, but the toggle's click handler closes
	-- over it; nothing can click before create() returns, so the forward declaration is safe.
	local relayout
	local filtersOpen = false

	local root = Instance.new("Frame")
	root.Name = "NationSelectRoot"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1

	-- No scrim: the map stays fully visible behind the selection panel (owner preference;
	-- picking a nation by clicking it on the map is a first-class flow, not a backdrop).

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

	-- The continent/sort/page-size chips and the pager live together in one host so a short viewport can
	-- collapse the whole block behind a toggle. On a landscape phone the panel is ~400px tall and the fixed
	-- chrome is ~376 of it, which left the nation list about 12px high -- the chips were the screen.
	-- Desktop keeps them inline (there is room); compact hides them and floats them OVER the list on demand.
	local filtersHost = Instance.new("Frame")
	filtersHost.Name = "FiltersHost"
	filtersHost.Position = UDim2.fromOffset(0, FILTERS_TOP)
	filtersHost.Size = UDim2.new(1, 0, 0, FILTERS_H)
	filtersHost.BackgroundColor3 = Colors.SurfaceOverlay or Colors.SurfaceElevated
	filtersHost.BackgroundTransparency = 1 -- opaque only in compact, where it overlaps the list
	filtersHost.BorderSizePixel = 0
	filtersHost.ZIndex = 3
	filtersHost.Parent = leftPanel
	local filtersStroke = Instance.new("UIStroke")
	filtersStroke.Color = Colors.BorderStrong
	filtersStroke.Thickness = 1
	filtersStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	filtersStroke.Enabled = false
	filtersStroke.Parent = filtersHost

	local filterRow = Instance.new("Frame")
	filterRow.Name = "Filters"
	filterRow.Position = UDim2.fromOffset(0, 0)
	filterRow.Size = UDim2.new(1, 0, 0, 30)
	filterRow.BackgroundTransparency = 1
	filterRow.ZIndex = 3
	filterRow.Parent = filtersHost
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
		Size = UDim2.fromOffset(CARD_W, 0), -- height is driven by sizeDetailCard, NOT AutomaticSize (see below)
		Visible = false,
		ZIndex = 2,
	})
	detailCard:SetAttribute("AoWInputSink", true)
	detailCard.Parent = root

	-- This screen mounts on the Modals layer, which sets IgnoreGuiInset = true. That is right for the centred
	-- dialogs that share the layer (their scrim must cover the whole screen) but wrong for the only
	-- top-anchored, full-height layout on it: y=0 is the TRUE top of the screen, so a 24px margin puts the
	-- title inside Roblox's ~36px topbar, under the logo and chat icons. Push both top-anchored surfaces down
	-- by the inset instead of flipping the layer's flag, which would break those dialogs. Same idea as
	-- Hud.placeTopBar / placeWatermark, just in the opposite direction (they LIFT off an inset-respecting
	-- layer; these SINK on an inset-ignoring one). The panel also has to give the height back, or it would
	-- overflow the bottom by exactly the inset.
	local sizeDetailCard -- assigned once cardBody/cardLayout exist; placeChrome runs before that on create
	local function placeChrome()
		local inset = GuiService:GetGuiInset().Y
		leftPanel.Position = UDim2.fromOffset(Spacing.space5, Spacing.space5 + inset)
		leftPanel.Size = UDim2.new(0, PANEL_W, 1, -(Spacing.space5 * 2 + inset))
		detailCard.Position = UDim2.new(1, -Spacing.space5, 0, Spacing.space5 + inset)
		if sizeDetailCard then
			sizeDetailCard() -- the inset eats into the card's height budget too
		end
	end
	placeChrome()
	local insetConn = GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(placeChrome)

	local cardPad = Instance.new("UIPadding")
	cardPad.PaddingTop = UDim.new(0, Spacing.space4)
	cardPad.PaddingBottom = UDim.new(0, Spacing.space4)
	cardPad.PaddingLeft = UDim.new(0, Spacing.space4)
	cardPad.PaddingRight = UDim.new(0, Spacing.space4)
	cardPad.Parent = detailCard

	-- The dossier is ~14 stacked rows and the card was AutomaticSize.Y with no ceiling, anchored to the TOP of
	-- an inset-ignoring layer -- so on a short viewport it simply grew off the bottom of the screen. A
	-- landscape phone is wide enough to pass wideEnough()'s X test but nowhere near tall enough to hold the
	-- card, which meant mobile players lost manpower/stability/legitimacy/provinces: precisely the numbers you
	-- pick a nation on. So the content lives in a scroller now, and the card is sized to its content but never
	-- taller than the space between the topbar and the screen bottom (see sizeDetailCard).
	local cardBody = Instance.new("ScrollingFrame")
	cardBody.Name = "CardBody"
	cardBody.Size = UDim2.fromScale(1, 1)
	cardBody.BackgroundTransparency = 1
	cardBody.BorderSizePixel = 0
	cardBody.ScrollBarThickness = 4
	cardBody.ScrollBarImageColor3 = Colors.BorderStrong
	cardBody.AutomaticCanvasSize = Enum.AutomaticSize.Y
	cardBody.CanvasSize = UDim2.new()
	cardBody.ZIndex = 3
	cardBody.Parent = detailCard

	local cardLayout = Instance.new("UIListLayout")
	cardLayout.FillDirection = Enum.FillDirection.Vertical
	cardLayout.SortOrder = Enum.SortOrder.LayoutOrder
	cardLayout.Padding = UDim.new(0, Spacing.space2)
	cardLayout.Parent = cardBody

	-- Grow to fit the dossier, stop at the viewport. AutomaticSize can't do this itself: it has no ceiling,
	-- and it can't measure through a ScrollingFrame (which has no intrinsic height), so the card is sized
	-- explicitly off the layout's real content height instead.
	function sizeDetailCard()
		local cam = workspace.CurrentCamera
		local vpY = (cam and cam.ViewportSize.Y) or 720
		local inset = GuiService:GetGuiInset().Y
		local scale = layerScale(detailCard)
		-- The card's own pixels are pre-UIScale, so convert the on-screen budget back into card space.
		local availableH = ((vpY - inset) / math.max(scale, 0.01)) - Spacing.space5 * 2
		local contentH = cardLayout.AbsoluteContentSize.Y / math.max(scale, 0.01) + Spacing.space4 * 2
		detailCard.Size = UDim2.fromOffset(CARD_W, math.max(0, math.min(contentH, availableH)))
	end
	sizeDetailCard()
	-- Re-size whenever the dossier's contents change (a different nation has longer names / a status line).
	cardLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(sizeDetailCard)

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
		-- Record-driven (single source of truth): read owner from the replicated province RECORD via
		-- province_id, not the part `owner` attribute, so the claimable-nation highlight matches the map +
		-- panel. Gated by RecordDrivenMapColoring; off = the original attribute read, byte-identical.
		local recordDriven = WorldConstants.RecordDrivenMapColoring and cache ~= nil and cache.getProvince ~= nil
		local function scan(folder)
			if not folder then
				return
			end
			for _, p in ipairs(folder:GetChildren()) do
				if p:IsA("BasePart") then
					local owner
					if recordDriven then
						local id = p:GetAttribute("province_id")
						local rec = id ~= nil and cache.getProvince(id)
						owner = rec and rec.ownerTag
					else
						owner = p:GetAttribute("owner")
					end
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
		-- Collect the ids per owner in the SAME pass that counts them. focusCountryCamera used to re-walk all
		-- ~5,713 provinces on every selection just to find the handful a nation owns; it can index instead.
		provinceIdsByOwner = {}
		for pid, p in pairs((cache and cache.allProvinces and cache.allProvinces()) or {}) do
			local owner = p.ownerTag
			if owner then
				provinceCount[owner] = (provinceCount[owner] or 0) + 1
				local bucket = provinceIdsByOwner[owner]
				if not bucket then
					bucket = {}
					provinceIdsByOwner[owner] = bucket
				end
				bucket[#bucket + 1] = pid
			end
		end
		for tag, c in pairs((cache and cache.allCountries and cache.allCountries()) or {}) do
			local continent, bucket, capital = continentOf(c)
			local provinces = provinceCount[tag] or 0
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
				provinces = provinces,
				band = powerBand(provinces),
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
			local va, vb = viewModels[a], viewModels[b]
			if sortMode == "rank" then
				-- Rank = biggest realm first: territory (provinces), then manpower, then name.
				if va.provinces ~= vb.provinces then
					return va.provinces > vb.provinces
				end
				local ma, mb = va.manpower or 0, vb.manpower or 0
				if ma ~= mb then
					return ma > mb
				end
			end
			return va.name < vb.name
		end)
		return tags
	end

	local function ensureRowVisible(index)
		if not index then
			return
		end
		local rowH = rowMetrics()
		local rowSpan = rowH + ROW_GAP
		local top = (index - 1) * rowSpan
		local viewH = listFrame.AbsoluteSize.Y
		local cur = listFrame.CanvasPosition.Y
		if top < cur then
			listFrame.CanvasPosition = Vector2.new(0, top)
		elseif top + rowH > cur + viewH then
			listFrame.CanvasPosition = Vector2.new(0, math.max(0, top + rowH - viewH))
		end
	end

	local function makeRow(vm, index)
		local rowH, crestPx, nameY, subY = rowMetrics()
		local btn = Instance.new("TextButton")
		btn.Name = vm.tag
		btn.Size = UDim2.new(1, 0, 0, rowH)
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
		swatch.Size = UDim2.fromOffset(6, crestPx) -- tracks the crest, or it overflows a compact row
		swatch.BackgroundColor3 = vm.color
		swatch.BorderSizePixel = 0
		swatch.ZIndex = 4
		local swatchCorner = Instance.new("UICorner")
		swatchCorner.CornerRadius = UDim.new(0, 2)
		swatchCorner.Parent = swatch
		swatch.Parent = btn

		-- The crest matches the colour accent swatch height so the two line up (was a fixed 44, then 40).
		local badge =
			CountryBadge.create({ code = vm.tag, countryColor = vm.color, size = "sm", px = crestPx, parent = btn })
		badge.AnchorPoint = Vector2.new(0, 0.5)
		badge.Position = UDim2.new(0, 26, 0.5, 0)
		badge.ZIndex = 4

		local name = Instance.new("TextLabel")
		name.Name = "CountryName"
		name.Position = UDim2.fromOffset(78, nameY)
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
		sub.Position = UDim2.fromOffset(78, subY)
		sub.Size = UDim2.new(1, -150, 0, 16)
		sub.BackgroundTransparency = 1
		-- Band first: of everything on this line it's the only fact that tells a newcomer whether this nation
		-- is a realistic first game. Ideology is dropped rather than truncated -- this line is ~178px, and
		-- three fields meant the government was clipped mid-word and the ideology never rendered at all. The
		-- dossier still shows both in full; the row only needs enough to choose between rows.
		sub.Text = vm.band .. "  \u{00B7}  " .. vm.government
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
		local total = #tags
		local pages = math.max(1, math.ceil(total / pageSize))
		pageIndex = math.clamp(pageIndex, 0, pages - 1)
		if pageLabel then
			pageLabel.Text = string.format("Page %d / %d", pageIndex + 1, pages)
		end
		for _, child in listFrame:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		rowByTag = {}
		-- Only the current page of rows is built, so a 700+-nation list never freezes the screen.
		local startIdx = pageIndex * pageSize
		local rowN = 0
		for i = startIdx + 1, math.min(startIdx + pageSize, total) do
			rowN += 1
			local tag = tags[i]
			local row = makeRow(viewModels[tag], rowN)
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
			-- "No nations match your search" is a lie when there is no search -- an empty continent should
			-- blame the filter, not send the player hunting for a typo they didn't make.
			if #tags == 0 and searchText == "" then
				emptyState.Text = "No nations here \u{2014} try another filter."
			else
				emptyState.Text = "No nations match your search."
			end
			emptyState.Visible = #tags == 0
			subCount.Text = string.format("%d available  \u{00B7}  %d taken", available, taken)
		end
	end

	-- If `tag` is in the current filtered list but not on the visible page, jump to its page (rebuilds).
	-- Returns true once a row for `tag` exists on the current page (false if it is filtered out entirely).
	local function ensureTagOnPage(tag)
		if rowByTag[tag] then
			return true
		end
		local ordered = filteredSortedTags()
		for i, t in ipairs(ordered) do
			if t == tag then
				pageIndex = math.floor((i - 1) / pageSize)
				rebuildList()
				return true
			end
		end
		return false
	end

	function renderDetail(vm)
		-- Clear the BODY, not the card: cardBody is itself a GuiObject child of detailCard, so the old
		-- "destroy every GuiObject in detailCard" would take the scroller (and its layout) with it.
		for _, child in cardBody:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		if not vm then
			return
		end

		-- (Removed: a 150px `slot_flag_rect` plate that was never given an image -- a picture frame with no
		-- picture, and the shell's only use in the repo. It read as a large empty black box at the top of the
		-- dossier. The nation's crest already prints in the header row directly below via CountryBadge, which
		-- resolves the decal itself, so filling the plate would only have duplicated it; the nation's colour is
		-- already carried by the row swatch and the map.)

		local headerRow = Instance.new("Frame")
		headerRow.Name = "CardHeader"
		headerRow.Size = UDim2.new(1, 0, 0, 48)
		headerRow.BackgroundTransparency = 1
		headerRow.LayoutOrder = 2
		headerRow.ZIndex = 3
		headerRow.Parent = cardBody
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
			opts.parent = cardBody
			opts.layoutOrder = order
			order += 1
			StatRow.create(opts)
		end
		local function section(label)
			SectionDivider.create({ parent = cardBody, label = label, layoutOrder = order })
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
		-- "231" alone means nothing to someone who has never seen this map; the band is what makes it a size.
		statRow({
			icon = "MapPolitical",
			label = "Provinces",
			value = string.format("%s  \u{00B7}  %s", num(vm.provinces), vm.band),
		})

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
			status.Parent = cardBody
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

	-- Pan the command camera to the selected country's CAPITAL, zoomed to frame its homeland (the
	-- capital's continent / superRegion), so small realms zoom in and large or transcontinental ones
	-- frame their home region instead of zooming out to the empty void.
	local function focusCountryCamera(tag)
		if not (cache and CameraController and CameraController.focusArea) then
			return
		end
		local country = cache.getCountry and cache.getCountry(tag)
		local capId = country and country.capitalProvinceId
		local capitalPos = capId and ProvincePositions.centerOf(capId)
		-- Homeland = owned provinces within HOMELAND_RADIUS of the capital (geographic, not region-tagged):
		-- realms with overseas colonies (Spain/Portugal in 1750) frame their core instead of the globe,
		-- and it's immune to the scrambled superRegion grouping (e.g. "iberia" includes Brazil in the data).
		local HOMELAND_RADIUS = 300
		local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
		local sumX, sumZ, count = 0, 0, 0
		-- Only this nation's provinces, indexed by buildViewModels (was: a walk over every province on the map,
		-- per selection -- and selection fires on every random pick and every arrow-key page change too).
		for _, pid in ipairs(provinceIdsByOwner[tag] or {}) do
			local pos = ProvincePositions.centerOf(pid)
			if pos and (not capitalPos or (pos - capitalPos).Magnitude <= HOMELAND_RADIUS) then
				minX = math.min(minX, pos.X)
				maxX = math.max(maxX, pos.X)
				minZ = math.min(minZ, pos.Z)
				maxZ = math.max(maxZ, pos.Z)
				sumX += pos.X
				sumZ += pos.Z
				count += 1
			end
		end
		local center = capitalPos
		if not center and count > 0 then
			center = Vector3.new(sumX / count, 0, sumZ / count)
		end
		if not center then
			return
		end
		local spread = (count > 0) and math.max(maxX - minX, maxZ - minZ) or 0
		CameraController.focusArea(center, spread)
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
		if not row and source ~= "list" then
			-- On another page (map/random/search): jump to its page if it is in the filtered list.
			ensureTagOnPage(tag)
			row = rowByTag[tag]
		end
		if row then
			row.setSelected(true)
			if source ~= "list" then
				local rowIndex = row.index
				task.defer(function()
					if not destroyed then
						ensureRowVisible(rowIndex)
					end
				end)
			end
		end
		renderDetail(vm)
		refreshDetailVisibility()
		updatePlay(vm)
		focusCountryCamera(tag)
	end

	local function setFilter(bucket)
		filterBucket = bucket
		pageIndex = 0
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
			if spec.onClick then
				spec.onClick()
			else
				setFilter(spec.key)
			end
		end)
		btn.Parent = spec.parent or filterRow
		return handle
	end

	for i, spec in ipairs(CONTINENT_FILTERS) do
		spec.order = i
		chips[#chips + 1] = makeChip(spec)
	end
	-- Light the chip that matches the ACTUAL default filter rather than assuming it is the first one. (It was
	-- `chips[1].setSelected(true)`, which only held while "All" happened to lead the list.)
	for _, chip in ipairs(chips) do
		chip.setSelected(chip.key == filterBucket)
	end

	-- Sort chips (Rank / A-Z) + page-size chips (10/25/50) + a page nav, so the 700+-nation list renders one
	-- page at a time. Default sort = Rank, so the biggest realms show first.
	local sortSizeRow = Instance.new("Frame")
	sortSizeRow.Name = "SortSize"
	sortSizeRow.Position = UDim2.fromOffset(0, 34) -- relative to filtersHost, not the panel
	sortSizeRow.Size = UDim2.new(1, 0, 0, 28)
	sortSizeRow.BackgroundTransparency = 1
	sortSizeRow.ZIndex = 3
	sortSizeRow.Parent = filtersHost
	local sortSizeLayout = Instance.new("UIListLayout")
	sortSizeLayout.FillDirection = Enum.FillDirection.Horizontal
	sortSizeLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	sortSizeLayout.SortOrder = Enum.SortOrder.LayoutOrder
	sortSizeLayout.Padding = UDim.new(0, Spacing.space1)
	sortSizeLayout.Parent = sortSizeRow

	local sortChips = {}
	local function setSort(mode)
		sortMode = mode
		pageIndex = 0
		for _, chip in ipairs(sortChips) do
			chip.setSelected(chip.key == mode)
		end
		rebuildList()
		if selectedTag and rowByTag[selectedTag] then
			rowByTag[selectedTag].setSelected(true)
		end
	end
	for i, spec in ipairs({ { key = "rank", label = "Rank" }, { key = "name", label = "A-Z" } }) do
		sortChips[#sortChips + 1] = makeChip({
			key = spec.key,
			label = spec.label,
			order = i,
			parent = sortSizeRow,
			onClick = function()
				setSort(spec.key)
			end,
		})
	end

	local sizeChips = {}
	local function setPageSize(n)
		pageSize = n
		pageIndex = 0
		for _, chip in ipairs(sizeChips) do
			chip.setSelected(chip.key == n)
		end
		rebuildList()
		if selectedTag and rowByTag[selectedTag] then
			rowByTag[selectedTag].setSelected(true)
		end
	end
	for i, n in ipairs({ 10, 25, 50 }) do
		sizeChips[#sizeChips + 1] = makeChip({
			key = n,
			label = tostring(n),
			order = 10 + i,
			parent = sortSizeRow,
			onClick = function()
				setPageSize(n)
			end,
		})
	end

	local pagerRow = Instance.new("Frame")
	pagerRow.Name = "Pager"
	pagerRow.Position = UDim2.fromOffset(0, 66) -- relative to filtersHost, not the panel
	pagerRow.Size = UDim2.new(1, 0, 0, 26)
	pagerRow.BackgroundTransparency = 1
	pagerRow.ZIndex = 3
	pagerRow.Parent = filtersHost
	local pagerLayout = Instance.new("UIListLayout")
	pagerLayout.FillDirection = Enum.FillDirection.Horizontal
	pagerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	pagerLayout.SortOrder = Enum.SortOrder.LayoutOrder
	pagerLayout.Padding = UDim.new(0, Spacing.space2)
	pagerLayout.Parent = pagerRow

	local function goPage(delta)
		pageIndex = pageIndex + delta -- clamped in rebuildList
		rebuildList()
		if selectedTag and rowByTag[selectedTag] then
			rowByTag[selectedTag].setSelected(true)
		end
	end
	makeChip({ key = "prev", label = "\u{2039}", order = 1, parent = pagerRow, onClick = function()
		goPage(-1)
	end })
	pageLabel = Instance.new("TextLabel")
	pageLabel.Name = "PageInfo"
	pageLabel.AutomaticSize = Enum.AutomaticSize.X
	pageLabel.Size = UDim2.fromOffset(0, 26)
	pageLabel.BackgroundTransparency = 1
	pageLabel.Text = "Page 1 / 1"
	pageLabel.TextColor3 = Colors.TextSecondary
	pageLabel.LayoutOrder = 2
	pageLabel.ZIndex = 3
	Typography.apply(pageLabel, "caption")
	pageLabel.Parent = pagerRow
	makeChip({ key = "next", label = "\u{203A}", order = 3, parent = pagerRow, onClick = function()
		goPage(1)
	end })

	-- Compact-only affordance. Built here (not next to filtersHost) because it needs makeChip's siblings to
	-- exist first; it is positioned absolutely on the panel, so code order doesn't matter.
	local filtersToggle = Button.create({
		parent = leftPanel,
		variant = "secondary",
		size = "sm",
		width = INNER,
		text = "Filters",
		onClick = function()
			filtersOpen = not filtersOpen
			relayout()
		end,
	})
	filtersToggle.Position = UDim2.fromOffset(0, FILTERS_TOP)
	filtersToggle.ZIndex = 4
	filtersToggle.Visible = false

	-- Single source of truth for where the list starts and how tall it is. Called on create and whenever the
	-- viewport changes, so rotating a phone or resizing a window re-flows instead of stranding the list.
	local lastCompact = nil
	function relayout()
		local compact = isCompact()
		-- Rows are built at the size that was current when makeRow ran, so crossing the threshold has to
		-- rebuild them or a rotate leaves 64px rows in a compact list (or vice versa). Only on a real change:
		-- relayout also runs on every resize frame, and rebuildList tears down and recreates every row.
		local sizeChanged = lastCompact ~= nil and lastCompact ~= compact
		lastCompact = compact
		filtersToggle.Visible = compact
		-- Plain "Filters": the triangle glyphs (U+25B4/U+25BE) aren't in the UI font and rendered as tofu
		-- boxes. The popover appearing is the open/closed feedback; it doesn't need a caret.
		if compact then
			local lbl = filtersToggle:FindFirstChild("Label")
			if lbl then
				lbl.Text = "Filters"
			end
		end

		-- Compact: the block floats OVER the list, so it needs an opaque surface and a border to read as a
		-- popover, and a ZIndex above the list. Inline: transparent, in flow, below the toggle's slot.
		filtersHost.Visible = (not compact) or filtersOpen
		filtersHost.Position = UDim2.fromOffset(0, compact and LIST_TOP_COMPACT or FILTERS_TOP)
		filtersHost.BackgroundTransparency = compact and 0 or 1
		filtersHost.ZIndex = compact and 8 or 3
		filtersStroke.Enabled = compact

		-- Actions: stacked full-width when there's room, side-by-side when there isn't.
		local barH = compact and BOTTOM_H_COMPACT or BOTTOM_H
		bottomBar.Size = UDim2.new(1, 0, 0, barH)
		local halfW = math.floor((INNER - Spacing.space2) / 2)
		if compact then
			randomBtn.AnchorPoint = Vector2.new(0, 1)
			randomBtn.Position = UDim2.fromScale(0, 1)
			randomBtn.Size = UDim2.fromOffset(halfW, randomBtn.Size.Y.Offset)
			playBtn.AnchorPoint = Vector2.new(1, 1)
			playBtn.Position = UDim2.fromScale(1, 1)
			playBtn.Size = UDim2.fromOffset(halfW, playBtn.Size.Y.Offset)
		else
			randomBtn.AnchorPoint = Vector2.new(0.5, 1)
			randomBtn.Position = UDim2.new(0.5, 0, 1, -(46 + Spacing.space2))
			randomBtn.Size = UDim2.fromOffset(INNER, randomBtn.Size.Y.Offset)
			playBtn.AnchorPoint = Vector2.new(0.5, 1)
			playBtn.Position = UDim2.fromScale(0.5, 1)
			playBtn.Size = UDim2.fromOffset(INNER, playBtn.Size.Y.Offset)
		end

		local top = compact and LIST_TOP_COMPACT or LIST_TOP
		listFrame.Position = UDim2.fromOffset(0, top)
		listFrame.Size = UDim2.new(1, 0, 1, -(top + barH + Spacing.space3))
		emptyState.Position = UDim2.fromOffset(0, top + 8)

		if sizeChanged and rebuildList then
			rebuildList()
			if selectedTag and rowByTag[selectedTag] then
				rowByTag[selectedTag].setSelected(true)
			end
		end
	end
	relayout()

	for _, chip in ipairs(sortChips) do
		chip.setSelected(chip.key == sortMode)
	end
	for _, chip in ipairs(sizeChips) do
		chip.setSelected(chip.key == pageSize)
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
			pageIndex = 0
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
		-- The hover HIGHLIGHT is not a tooltip -- it stays regardless of the setting; only the hover card obeys it.
		if vm and Tooltip.enabled() then
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
			if vm and tag ~= selectedTag then
				applyHighlight(tag, highlightHover, 0.22)
			end
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
		viewportConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			refreshDetailVisibility()
			relayout() -- a rotate/resize can cross the collapse threshold in either direction
			sizeDetailCard() -- ...and changes how much room the dossier has
		end)
	end

	local function scheduleRefresh()
		if refreshPending then
			return
		end
		refreshPending = true
		task.defer(function()
			refreshPending = false
			if destroyed then
				return
			end
			-- Give the map its colours back BEFORE re-indexing. applyHighlight memoises each part's original
			-- colour keyed by the part, and buildPartsIndex is about to re-derive which parts belong to whom --
			-- so restoring afterwards can hand a part back a colour that belonged to its PREVIOUS owner, or
			-- miss it entirely, leaving the map bleached. Restore, re-index, then re-apply to whatever is still
			-- live. (Residual: if MapRenderer recolours these parts in the same frame as this restore, the
			-- memo we replay is already stale. Holding the loading cover for provincesReady closes the common
			-- case -- the big political re-sweep now lands before the player can hover anything.)
			local hadHover = hoveredTag
			restoreHighlight(highlightHover)
			restoreHighlight(highlightSelected)
			buildViewModels()
			buildPartsIndex() -- ownership/records may have changed; rebuild the record-driven highlight index
			rebuildList()
			if selectedTag and viewModels[selectedTag] then
				applyHighlight(selectedTag, highlightSelected, 0.45)
			end
			if hadHover and hadHover ~= selectedTag and viewModels[hadHover] then
				applyHighlight(hadHover, highlightHover, 0.22)
			end
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
	end
	if cache and cache.onChangePrefix then
		unsubCountries = cache.onChangePrefix("countries", scheduleRefresh)
	end
	-- Provinces stream in AFTER this screen mounts (chunked replication), so the initial buildViewModels/
	-- buildPartsIndex ran against an incomplete province cache -> high-id tiles didn't highlight and counts
	-- were low (PLC showed 143 instead of 156). Re-index once the full province set finishes arriving.
	if cache and cache.onChange then
		unsubProvincesReady = cache.onChange("provincesReady", scheduleRefresh)
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
		if unsubProvincesReady then
			pcall(unsubProvincesReady)
		end
		if viewportConn then
			viewportConn:Disconnect()
		end
		if insetConn then
			insetConn:Disconnect()
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
