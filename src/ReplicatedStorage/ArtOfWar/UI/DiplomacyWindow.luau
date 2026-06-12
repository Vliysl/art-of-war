-- DiplomacyWindow: consolidated country-profile window.
-- Left rail = searchable, alphabetical country list. Right pane = profile of the
-- selected country: crest, ruler, overview stats, relation status, diplomatic
-- actions (war/peace), and -- for your own country -- the government pages
-- (Factions/Leaders/Policies/Laws/Doctrines) hosted on an embedded sub-screen.
-- This window absorbs the old PoliticsWindow; its tab modules mount here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local uiFolder = aow:WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))
local UIRoot = require(uiFolder:WaitForChild("UIRoot"))
local MovableWindow = require(uiFolder:WaitForChild("MovableWindow"))

local FactionsTab = require(uiFolder.Tabs:WaitForChild("FactionsTab"))
local LeadersTab = require(uiFolder.Tabs:WaitForChild("LeadersTab"))
local PoliciesTab = require(uiFolder.Tabs:WaitForChild("PoliciesTab"))
local LawsTab = require(uiFolder.Tabs:WaitForChild("LawsTab"))
local DoctrinesTab = require(uiFolder.Tabs:WaitForChild("DoctrinesTab"))

local ClientStateCache = require(aow:WaitForChild("Modules"):WaitForChild("ClientStateCache"))
local SimClock = require(aow:WaitForChild("Modules"):WaitForChild("SimClock"))
local WorldConstants = require(aow:WaitForChild("Shared"):WaitForChild("WorldConstants"))

local DiplomacyWindow = {}

local WINDOW_W, WINDOW_H = 840, 560
local RAIL_W = 252
local ROW_H = 38
local SEARCH_H = 28
local BACK_BAR_H = 34
local TAB_STRIP_H = 32

local POLITICS_TABS = {
	{ key = "Factions",  label = "Factions",  icon = "TabFactions"  },
	{ key = "Leaders",   label = "Leaders",   icon = "TabLeaders"   },
	{ key = "Policies",  label = "Policies",  icon = "TabPolicies"  },
	{ key = "Laws",      label = "Laws",      icon = "TabLaws"      },
	{ key = "Doctrines", label = "Doctrines", icon = "TabDoctrines" },
}

local MONTHS_SHORT = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- Brighter text tones for action buttons: button text must contrast hard with
-- the dark panel fill (UIStyle.Color.Bad etc. are tuned for fills, not text).
local TONE = {
	danger  = { text = Color3.fromRGB(240, 112, 94),  stroke = UIStyle.Color.Bad },
	good    = { text = Color3.fromRGB(152, 218, 112), stroke = UIStyle.Color.Good },
	gold    = { text = UIStyle.Color.GoldBright,      stroke = UIStyle.Color.Gold },
	neutral = { text = UIStyle.Color.CreamPale,       stroke = UIStyle.Color.Border },
}

local getMyTagCallback = nil
local function myTag()
	if getMyTagCallback then
		local ok, tag = pcall(getMyTagCallback)
		if ok then return tag end
	end
	local p = Players.LocalPlayer
	return p and p:GetAttribute("CountryTag") or nil
end

local function loadData(name)
	local dataFolder = aow:FindFirstChild("Data")
	local module = dataFolder and dataFolder:FindFirstChild(name)
	if not module then return nil end
	local ok, result = pcall(require, module)
	if ok then return result end
	return nil
end

local GovernmentTypes = loadData("GovernmentTypes")
local Ideologies = loadData("Ideologies")

local function clearChildren(parent)
	for _, c in parent:GetChildren() do
		if c:IsA("GuiObject") then c:Destroy() end
	end
end

local function nameOf(tag)
	local rec = ClientStateCache.getCountry(tag)
	return (rec and (rec.displayName or rec.name)) or tag or "?"
end

local function countryColor(country)
	local c = country and country.color
	if type(c) == "table" then
		return Color3.fromRGB(c[1] or 128, c[2] or 128, c[3] or 128)
	end
	return UIStyle.Color.PanelAlt
end

local function govLabelOf(country)
	if not country then return nil end
	local g = GovernmentTypes and country.governmentForm and GovernmentTypes[country.governmentForm]
	if g and g.displayName then return g.displayName end
	if country.governmentForm then return tostring(country.governmentForm):gsub("_", " ") end
	return nil
end

local function ideologyLabelOf(country)
	if not country then return nil end
	local i = Ideologies and country.ideology and Ideologies[country.ideology]
	if i and i.displayName then return i.displayName end
	if country.ideology then return tostring(country.ideology):gsub("_", " ") end
	return nil
end

local function rulerNameOf(country)
	local uid = country and country.claimedBy
	if not uid then return nil end
	local p = Players:GetPlayerByUserId(uid)
	if p then return p.DisplayName end
	return "Player " .. tostring(uid)
end

local function fmtInt(n)
	n = math.floor(tonumber(n) or 0)
	local sign = n < 0 and "-" or ""
	local s = tostring(math.abs(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
	out = out:gsub("^%s+", "")
	return sign .. out
end

-- Sim seconds -> in-game days (mirrors DiplomacySystem.dayToSeconds).
local function simSecondsToDays(seconds)
	local yearsPerSec = WorldConstants.YearsPerRealSecond or 0.05
	return seconds * yearsPerSec * 365
end

local function truceRemainingText(expiresAt)
	local now = SimClock.now()
	if not now then return "active" end
	local days = simSecondsToDays(math.max(expiresAt - now, 0))
	if days >= 365 then
		return string.format("%.1f years left", days / 365)
	end
	return string.format("%d days left", math.max(math.ceil(days), 1))
end

local function proposalExpiryText(expiresAt)
	local now = SimClock.now()
	if not now then return "pending" end
	local remaining = expiresAt - now
	if remaining <= 0 then return "expiring\u{2026}" end
	if SimClock.isPaused() then return "paused" end
	local speed = SimClock.getSpeed()
	if speed and speed > 0 then
		return string.format("expires in ~%ds", math.ceil(remaining / speed))
	end
	return "pending"
end

local function warDeclaredText(war)
	local idx = war and war.declaredMonthIndex
	if type(idx) ~= "number" then return "ongoing" end
	local year = math.floor(idx / 12)
	local month = (idx % 12) + 1
	return string.format("since %s %d", MONTHS_SHORT[month] or "?", year)
end

local function findActiveWarWith(otherTag, mineTag)
	if not mineTag or not otherTag then return nil end
	for _, war in pairs(ClientStateCache.allWars()) do
		if war.status == "active"
			and ((war.attackerTag == mineTag and war.defenderTag == otherTag)
				or (war.defenderTag == mineTag and war.attackerTag == otherTag)) then
			return war
		end
	end
	return nil
end

-- Relation of `otherTag` to the viewer. kind: "self" | "at_war" | "truce" | "peace" | "none"
local function statusFor(otherTag, mineTag)
	if not mineTag then return { kind = "none" } end
	if otherTag == mineTag then return { kind = "self" } end
	local war = findActiveWarWith(otherTag, mineTag)
	if war then return { kind = "at_war", war = war } end
	local mine = ClientStateCache.getCountry(mineTag)
	local truceEnds = mine and mine.truces and mine.truces[otherTag]
	if truceEnds then return { kind = "truce", truceEnds = truceEnds } end
	return { kind = "peace" }
end

local function warsInvolving(tag)
	local list = {}
	for _, war in pairs(ClientStateCache.allWars()) do
		if war.status == "active" and (war.attackerTag == tag or war.defenderTag == tag) then
			table.insert(list, war)
		end
	end
	table.sort(list, function(a, b) return (a.declaredAt or 0) < (b.declaredAt or 0) end)
	return list
end

local function pendingProposalsBetween(tagA, tagB)
	local list = {}
	for id, prop in pairs(ClientStateCache.allPeaceProposals()) do
		if prop.status == "pending"
			and ((prop.fromTag == tagA and prop.toTag == tagB)
				or (prop.fromTag == tagB and prop.toTag == tagA)) then
			table.insert(list, { id = id, prop = prop })
		end
	end
	table.sort(list, function(a, b) return (a.prop.proposedAt or 0) < (b.prop.proposedAt or 0) end)
	return list
end

local function pendingProposalsFor(tag)
	local list = {}
	for id, prop in pairs(ClientStateCache.allPeaceProposals()) do
		if prop.status == "pending" and (prop.fromTag == tag or prop.toTag == tag) then
			table.insert(list, { id = id, prop = prop })
		end
	end
	table.sort(list, function(a, b) return (a.prop.proposedAt or 0) < (b.prop.proposedAt or 0) end)
	return list
end

local function provinceStats(tag)
	local count, pop = 0, 0
	for _, province in pairs(ClientStateCache.allProvinces()) do
		if province.ownerTag == tag then
			count += 1
			pop += province.population or 0
		end
	end
	return count, pop
end

local function capitalNameOf(country)
	local capId = country and country.capitalProvinceId
	if not capId then return nil end
	local prov = ClientStateCache.getProvince(capId)
	if prov then return prov.displayCityName or prov.name end
	return nil
end

local termsLabel = {
	white_peace = "White Peace",
	annex_occupied = "Annex Occupied",
}

-- Shared lookups for live-label computes within one refresh pass (memo tables
-- are created fresh per pass, so several labels don't repeat the same scan).
local function liveCountry(memo, tag)
	local bucket = memo.countries
	if not bucket then
		bucket = {}
		memo.countries = bucket
	end
	local c = bucket[tag]
	if c == nil then
		c = ClientStateCache.getCountry(tag) or false
		bucket[tag] = c
	end
	return c or nil
end

local function liveStats(memo, tag)
	local bucket = memo.stats
	if not bucket then
		bucket = {}
		memo.stats = bucket
	end
	local s = bucket[tag]
	if not s then
		local count, pop = provinceStats(tag)
		s = { count, pop }
		bucket[tag] = s
	end
	return s[1], s[2]
end

-- Structural signature of everything the profile renders EXCEPT fast-moving
-- numbers (population, the treasury block, war scores/exhaustion, countdown
-- texts) -- those are live labels updated in place when the signature is
-- unchanged. Keep in sync with the render*Section builders.
local function profileSignature(tag, mineTag)
	local parts = { tostring(tag), tostring(mineTag) }
	local function push(v)
		parts[#parts + 1] = tostring(v)
	end
	local country = tag and ClientStateCache.getCountry(tag) or nil
	if not country then
		push("nodata")
		return table.concat(parts, "|")
	end
	push(country.displayName)
	push(country.claimedBy)
	push(country.governmentForm)
	push(country.ideology)
	push(country.flagAssetId)
	local c = country.color
	push(type(c) == "table" and ((c[1] or 0) .. "," .. (c[2] or 0) .. "," .. (c[3] or 0)) or "nocolor")
	push(country.primaryCulture)
	push(capitalNameOf(country))
	local status = statusFor(tag, mineTag)
	push(status.kind)
	if status.war then push(status.war.id) end
	if status.truceEnds then push(math.floor(status.truceEnds)) end
	for _, war in ipairs(warsInvolving(tag)) do
		push(tostring(war.id) .. ">" .. tostring(war.attackerTag) .. ":" .. tostring(war.defenderTag)
			.. ":" .. tostring(war.declaredMonthIndex))
	end
	if mineTag then
		if tag == mineTag then
			if country.truces then
				local tt = {}
				for otherTag, ends in pairs(country.truces) do
					tt[#tt + 1] = otherTag .. math.floor(tonumber(ends) or 0)
				end
				table.sort(tt)
				push(table.concat(tt, ","))
			end
			for _, e in ipairs(pendingProposalsFor(mineTag)) do
				push(e.id .. ":" .. tostring(e.prop.status) .. ":" .. tostring(e.prop.fromTag))
			end
		else
			for _, e in ipairs(pendingProposalsBetween(tag, mineTag)) do
				push(e.id .. ":" .. tostring(e.prop.status) .. ":" .. tostring(e.prop.fromTag))
			end
		end
	end
	return table.concat(parts, "|")
end

function DiplomacyWindow.create(callbacks)
	callbacks = callbacks or {}
	getMyTagCallback = callbacks.getMyTag

	local win = MovableWindow.create({
		id = "diplomacy",
		title = "Diplomacy",
		size = UDim2.fromOffset(WINDOW_W, WINDOW_H),
	})

	local selectedTag = nil
	local searchText = ""
	local screen = "main"          -- "main" | "politics"
	local pendingMainRender = false

	----------------------------------------------------------------
	-- MAIN SCREEN: country list rail + profile pane
	----------------------------------------------------------------
	local mainScreen = Instance.new("Frame")
	mainScreen.Name = "MainScreen"
	mainScreen.Size = UDim2.fromScale(1, 1)
	mainScreen.BackgroundTransparency = 1
	mainScreen.Parent = win.body

	local rail = Instance.new("Frame")
	rail.Name = "CountryRail"
	rail.Size = UDim2.new(0, RAIL_W, 1, 0)
	rail.BackgroundColor3 = UIStyle.Color.Bg
	rail.BackgroundTransparency = 0.25
	rail.BorderSizePixel = 0
	rail.Parent = mainScreen

	local railDivider = Instance.new("Frame")
	railDivider.Size = UDim2.new(0, 1, 1, 0)
	railDivider.Position = UDim2.new(1, 0, 0, 0)
	railDivider.AnchorPoint = Vector2.new(1, 0)
	railDivider.BackgroundColor3 = UIStyle.Color.Border
	railDivider.BackgroundTransparency = 0.45
	railDivider.BorderSizePixel = 0
	railDivider.Parent = rail

	local searchBox = Instance.new("TextBox")
	searchBox.Name = "CountrySearch"
	searchBox.Size = UDim2.new(1, -16, 0, SEARCH_H)
	searchBox.Position = UDim2.fromOffset(8, 8)
	searchBox.BackgroundColor3 = UIStyle.Color.Bg
	searchBox.BorderSizePixel = 0
	searchBox.Font = UIStyle.Font.Regular
	searchBox.TextSize = 13
	searchBox.TextColor3 = UIStyle.Color.Text
	searchBox.PlaceholderText = "Search nations\u{2026}"
	searchBox.PlaceholderColor3 = UIStyle.Color.TextMuted
	searchBox.Text = ""
	searchBox.ClearTextOnFocus = false
	searchBox.TextXAlignment = Enum.TextXAlignment.Left
	searchBox.ClipsDescendants = true
	searchBox.Parent = rail
	UIBuilder.corner(searchBox, 3)
	UIBuilder.stroke(searchBox, 1, UIStyle.Color.Border)
	do
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 10)
		pad.PaddingRight = UDim.new(0, 10)
		pad.Parent = searchBox
	end

	local listScroll = Instance.new("ScrollingFrame")
	listScroll.Name = "CountryList"
	listScroll.Size = UDim2.new(1, 0, 1, -(SEARCH_H + 16))
	listScroll.Position = UDim2.fromOffset(0, SEARCH_H + 16)
	listScroll.BackgroundTransparency = 1
	listScroll.BorderSizePixel = 0
	listScroll.ScrollBarThickness = 6
	listScroll.ScrollBarImageColor3 = UIStyle.Color.Gold
	listScroll.ScrollBarImageTransparency = 0.3
	listScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	listScroll.CanvasSize = UDim2.new()
	listScroll.Parent = rail
	do
		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Vertical
		layout.Padding = UDim.new(0, 4)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = listScroll
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 2)
		pad.PaddingLeft = UDim.new(0, 8)
		pad.PaddingRight = UDim.new(0, 8)
		pad.PaddingBottom = UDim.new(0, 8)
		pad.Parent = listScroll
	end

	local profilePane = Instance.new("Frame")
	profilePane.Name = "ProfilePane"
	profilePane.Size = UDim2.new(1, -RAIL_W, 1, 0)
	profilePane.Position = UDim2.fromOffset(RAIL_W, 0)
	profilePane.BackgroundTransparency = 1
	profilePane.ClipsDescendants = true
	profilePane.Parent = mainScreen

	local profileScroll = Instance.new("ScrollingFrame")
	profileScroll.Name = "ProfileScroll"
	profileScroll.Size = UDim2.fromScale(1, 1)
	profileScroll.BackgroundTransparency = 1
	profileScroll.BorderSizePixel = 0
	profileScroll.ScrollBarThickness = 6
	profileScroll.ScrollBarImageColor3 = UIStyle.Color.Gold
	profileScroll.ScrollBarImageTransparency = 0.3
	profileScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	profileScroll.CanvasSize = UDim2.new()
	profileScroll.Parent = profilePane
	do
		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Vertical
		layout.Padding = UDim.new(0, 10)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = profileScroll
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 10)
		pad.PaddingLeft = UDim.new(0, 12)
		pad.PaddingRight = UDim.new(0, 12)
		pad.PaddingBottom = UDim.new(0, 12)
		pad.Parent = profileScroll
	end

	----------------------------------------------------------------
	-- POLITICS SCREEN: back bar + tab strip + mounted tab pages
	----------------------------------------------------------------
	local politicsScreen = Instance.new("Frame")
	politicsScreen.Name = "PoliticsScreen"
	politicsScreen.Size = UDim2.fromScale(1, 1)
	politicsScreen.BackgroundTransparency = 1
	politicsScreen.Visible = false
	politicsScreen.Parent = win.body

	local backBar = Instance.new("Frame")
	backBar.Size = UDim2.new(1, 0, 0, BACK_BAR_H)
	backBar.BackgroundColor3 = UIStyle.Color.PanelHeader
	backBar.BorderSizePixel = 0
	backBar.Parent = politicsScreen

	local backBtn = Instance.new("TextButton")
	backBtn.Size = UDim2.fromOffset(92, 24)
	backBtn.Position = UDim2.new(0, 8, 0.5, 0)
	backBtn.AnchorPoint = Vector2.new(0, 0.5)
	backBtn.BackgroundColor3 = UIStyle.Color.PanelAlt
	backBtn.BorderSizePixel = 0
	backBtn.AutoButtonColor = false
	backBtn.Text = "\u{2190}  Profile"
	backBtn.TextColor3 = UIStyle.Color.GoldBright
	backBtn.FontFace = UIStyle.FontFace.Cinzel
	backBtn.TextSize = 12
	backBtn.Parent = backBar
	UIBuilder.corner(backBtn, 2)
	UIBuilder.stroke(backBtn, 1, UIStyle.Color.Gold)

	local politicsTitle = Instance.new("TextLabel")
	politicsTitle.Size = UDim2.new(1, -220, 1, 0)
	politicsTitle.Position = UDim2.fromOffset(112, 0)
	politicsTitle.BackgroundTransparency = 1
	politicsTitle.Text = "Government"
	politicsTitle.TextColor3 = UIStyle.Color.CreamBright
	politicsTitle.FontFace = UIStyle.FontFace.CinzelBold
	politicsTitle.TextSize = 14
	politicsTitle.TextXAlignment = Enum.TextXAlignment.Left
	politicsTitle.TextYAlignment = Enum.TextYAlignment.Center
	politicsTitle.TextTruncate = Enum.TextTruncate.AtEnd
	politicsTitle.Parent = backBar

	local tabStrip = Instance.new("Frame")
	tabStrip.Size = UDim2.new(1, 0, 0, TAB_STRIP_H)
	tabStrip.Position = UDim2.fromOffset(0, BACK_BAR_H)
	tabStrip.BackgroundColor3 = UIStyle.Color.Bg
	tabStrip.BorderSizePixel = 0
	tabStrip.Parent = politicsScreen

	local tabRow = Instance.new("Frame")
	tabRow.Size = UDim2.fromScale(1, 1)
	tabRow.BackgroundTransparency = 1
	tabRow.Parent = tabStrip
	do
		local tabLayout = Instance.new("UIListLayout")
		tabLayout.FillDirection = Enum.FillDirection.Horizontal
		tabLayout.Parent = tabRow
	end

	local underline = Instance.new("Frame")
	underline.Size = UDim2.fromOffset(0, 2)
	underline.Position = UDim2.new(0, 0, 1, -2)
	underline.BackgroundColor3 = UIStyle.Color.Gold
	underline.BorderSizePixel = 0
	underline.Parent = tabStrip

	local politicsContent = Instance.new("Frame")
	politicsContent.Size = UDim2.new(1, 0, 1, -(BACK_BAR_H + TAB_STRIP_H))
	politicsContent.Position = UDim2.fromOffset(0, BACK_BAR_H + TAB_STRIP_H)
	politicsContent.BackgroundTransparency = 1
	politicsContent.ClipsDescendants = true
	politicsContent.Parent = politicsScreen
	UIBuilder.padding(politicsContent, 10)

	local politicsTabs = {}
	local activePoliticsKey = nil
	local ensurePoliticsTabFresh -- assigned after the tab modules mount

	local function setPoliticsTab(key)
		if not politicsTabs[key] then return end
		if ensurePoliticsTabFresh then ensurePoliticsTabFresh(key) end
		for tabKey, data in politicsTabs do
			local active = tabKey == key
			data.page.Visible = active
			data.label.TextColor3 = active and UIStyle.Color.Gold or UIStyle.Color.TextMuted
		end
		activePoliticsKey = key
		task.defer(function()
			local data = politicsTabs[key]
			if not data or not data.button.Parent then return end
			local s = UIRoot.uiScale()
			local px = (data.button.AbsolutePosition.X - tabRow.AbsolutePosition.X) / s
			local sx = data.button.AbsoluteSize.X / s
			if UIStyle.ReduceMotion then
				underline.Position = UDim2.new(0, px, 1, -2)
				underline.Size = UDim2.fromOffset(sx, 2)
			else
				TweenService:Create(underline, UIStyle.tween(UIStyle.Motion.Fast), {
					Position = UDim2.new(0, px, 1, -2),
					Size = UDim2.fromOffset(sx, 2),
				}):Play()
			end
		end)
	end

	for i, def in ipairs(POLITICS_TABS) do
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1 / #POLITICS_TABS, 0, 1, 0)
		btn.BackgroundTransparency = 1
		btn.BorderSizePixel = 0
		btn.AutoButtonColor = false
		btn.Text = ""
		btn.LayoutOrder = i
		btn.Parent = tabRow

		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.BackgroundTransparency = 1
		lbl.Text = def.label
		lbl.TextColor3 = UIStyle.Color.TextMuted
		lbl.FontFace = UIStyle.FontFace.Cinzel
		lbl.TextSize = 12
		lbl.TextXAlignment = Enum.TextXAlignment.Center
		lbl.TextYAlignment = Enum.TextYAlignment.Center
		lbl.Parent = btn

		local page = Instance.new("Frame")
		page.Size = UDim2.fromScale(1, 1)
		page.BackgroundTransparency = 1
		page.Visible = false
		page.Parent = politicsContent

		politicsTabs[def.key] = { button = btn, label = lbl, page = page }
		btn.MouseButton1Click:Connect(function() setPoliticsTab(def.key) end)
	end

	local tabImpls = {}
	tabImpls.Factions = FactionsTab.mount(politicsTabs.Factions.page)
	tabImpls.Leaders = LeadersTab.mount(politicsTabs.Leaders.page,
		callbacks.fireDismiss, callbacks.fireAppoint)
	tabImpls.Policies = PoliciesTab.mount(politicsTabs.Policies.page,
		callbacks.fireEnact, callbacks.fireRepeal)
	tabImpls.Laws = LawsTab.mount(politicsTabs.Laws.page,
		callbacks.fireCancel)
	tabImpls.Doctrines = DoctrinesTab.mount(politicsTabs.Doctrines.page,
		callbacks.fireSetDoctrine)

	-- UIController pushes tab.update(country, bundle) on every countries delta,
	-- and every tab update destroys-and-rebuilds its page. Gate that on actual
	-- visibility: hidden pages just mark themselves stale and re-render when
	-- revealed (tab switch, politics screen shown, or window reopened).
	local lastTabPush = nil
	local tabStale = {}

	ensurePoliticsTabFresh = function(key)
		local impl = tabImpls[key]
		if tabStale[key] and lastTabPush and impl and impl.update then
			tabStale[key] = nil
			local ok, err = pcall(impl.update, lastTabPush.country, lastTabPush.bundle)
			if not ok then warn("[DiplomacyWindow] tab refresh errored: " .. tostring(err)) end
		end
	end

	local gatedTabImpls = {}
	for key, impl in pairs(tabImpls) do
		gatedTabImpls[key] = setmetatable({
			update = function(country, bundle)
				lastTabPush = { country = country, bundle = bundle }
				if win.isOpen() and screen == "politics" and activePoliticsKey == key then
					tabStale[key] = nil
					impl.update(country, bundle)
				else
					tabStale[key] = true
				end
			end,
		}, { __index = impl })
	end

	task.defer(function() setPoliticsTab("Factions") end)

	----------------------------------------------------------------
	-- Shared small builders
	----------------------------------------------------------------
	local renderMain -- forward decl

	local function showScreen(name)
		screen = name
		mainScreen.Visible = name == "main"
		politicsScreen.Visible = name == "politics"
		if name == "politics" then
			local mine = myTag()
			politicsTitle.Text = (mine and nameOf(mine) or "Realm") .. "  \u{00B7}  Government"
			if activePoliticsKey then setPoliticsTab(activePoliticsKey) end
		elseif pendingMainRender then
			renderMain()
		end
	end

	backBtn.MouseButton1Click:Connect(function() showScreen("main") end)

	-- Flat action button: dark fill, toned text/stroke, hover lift.
	local function actionButton(parent, text, tone, opts)
		opts = opts or {}
		local t = TONE[tone] or TONE.gold
		local btn = Instance.new("TextButton")
		btn.Size = opts.size or UDim2.new(1, 0, 1, 0)
		btn.Position = opts.position or UDim2.new()
		btn.AnchorPoint = opts.anchor or Vector2.new(0, 0)
		btn.BackgroundColor3 = UIStyle.Color.PanelAlt
		btn.BackgroundTransparency = 0.05
		btn.BorderSizePixel = 0
		btn.AutoButtonColor = false
		btn.Text = text
		btn.TextColor3 = t.text
		btn.FontFace = UIStyle.FontFace.Cinzel
		btn.TextSize = opts.textSize or 13
		btn.Parent = parent
		UIBuilder.corner(btn, 2)
		local stroke = UIBuilder.stroke(btn, 1, t.stroke)
		stroke.Transparency = 0.2

		if opts.disabled then
			btn.Active = false
			btn.BackgroundColor3 = UIStyle.Color.PanelDisabled
			btn.BackgroundTransparency = 0.45
			btn.TextColor3 = UIStyle.Color.TextDim
			stroke.Color = UIStyle.Color.BorderDim
			if opts.disabledNote then
				local note = Instance.new("TextLabel")
				note.Size = UDim2.new(0, 90, 1, 0)
				note.Position = UDim2.new(1, -8, 0, 0)
				note.AnchorPoint = Vector2.new(1, 0)
				note.BackgroundTransparency = 1
				note.Text = string.upper(opts.disabledNote)
				note.TextColor3 = UIStyle.Color.TextDim
				note.Font = UIStyle.Font.Semibold
				note.TextSize = 9
				note.TextXAlignment = Enum.TextXAlignment.Right
				note.Parent = btn
			end
		else
			btn.MouseEnter:Connect(function()
				btn.BackgroundColor3 = UIStyle.Color.PanelHigh
				stroke.Transparency = 0
			end)
			btn.MouseLeave:Connect(function()
				btn.BackgroundColor3 = UIStyle.Color.PanelAlt
				stroke.Transparency = 0.2
			end)
			if opts.onClick then
				btn.MouseButton1Click:Connect(opts.onClick)
			end
		end
		return btn
	end

	-- Section: eyebrow header + manually stacked rows inside a fixed-height frame.
	local sectionOrder = 0
	local function section(title)
		sectionOrder += 1
		local frame = Instance.new("Frame")
		frame.Size = UDim2.new(1, -4, 0, 22)
		frame.BackgroundTransparency = 1
		frame.LayoutOrder = sectionOrder
		frame.Parent = profileScroll

		local header = Instance.new("TextLabel")
		header.Size = UDim2.new(1, 0, 0, 14)
		header.BackgroundTransparency = 1
		header.Text = string.upper(title)
		header.TextColor3 = UIStyle.Color.LedgerSection
		header.FontFace = UIStyle.FontFace.Cinzel
		header.TextSize = 11
		header.TextXAlignment = Enum.TextXAlignment.Left
		header.Parent = frame

		local rule = Instance.new("Frame")
		rule.Size = UDim2.new(1, 0, 0, 1)
		rule.Position = UDim2.fromOffset(0, 17)
		rule.BackgroundColor3 = UIStyle.Color.BorderDim
		rule.BackgroundTransparency = 0.3
		rule.BorderSizePixel = 0
		rule.Parent = frame

		local sec = { frame = frame, y = 22 }
		function sec.row(h)
			local r = Instance.new("Frame")
			r.Size = UDim2.new(1, 0, 0, h)
			r.Position = UDim2.fromOffset(0, sec.y)
			r.BackgroundTransparency = 1
			r.Parent = frame
			sec.y += h
			frame.Size = UDim2.new(1, -4, 0, sec.y)
			return r
		end
		function sec.gap(h)
			sec.y += h
			frame.Size = UDim2.new(1, -4, 0, sec.y)
		end
		return sec
	end

	local function kvRow(sec, label, value, valueColor)
		local r = sec.row(20)
		local l = Instance.new("TextLabel")
		l.Size = UDim2.new(0.45, 0, 1, 0)
		l.BackgroundTransparency = 1
		l.Text = label
		l.TextColor3 = UIStyle.Color.TextMuted
		l.Font = UIStyle.Font.Regular
		l.TextSize = 12
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.Parent = r
		local v = Instance.new("TextLabel")
		v.Size = UDim2.new(0.55, 0, 1, 0)
		v.Position = UDim2.fromScale(0.45, 0)
		v.BackgroundTransparency = 1
		v.Text = value or "\u{2014}"
		v.TextColor3 = valueColor or UIStyle.Color.Text
		v.Font = UIStyle.Font.Semibold
		v.TextSize = 12
		v.TextXAlignment = Enum.TextXAlignment.Right
		v.TextTruncate = Enum.TextTruncate.AtEnd
		v.Parent = r
		return r, v
	end

	local function noteRow(sec, text, color)
		local r = sec.row(22)
		local l = Instance.new("TextLabel")
		l.Size = UDim2.fromScale(1, 1)
		l.BackgroundTransparency = 1
		l.Text = text
		l.TextColor3 = color or UIStyle.Color.TextMuted
		l.FontFace = UIStyle.FontFace.InterItalic
		l.TextSize = 12
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextWrapped = true
		l.Parent = r
		return r
	end

	-- Live labels: when a profile re-render is skipped (structural signature
	-- unchanged), these value labels are re-written in place instead -- zero
	-- instance churn for ticking numbers. computeText/computeColor receive the
	-- per-pass memo for shared lookups (liveCountry / liveStats).
	local profileLive = {}
	local liveMemo = {}

	local function registerLive(label, computeText, computeColor)
		profileLive[#profileLive + 1] = { label = label, text = computeText, color = computeColor }
		label.Text = computeText(liveMemo)
		if computeColor then
			local c = computeColor(liveMemo)
			if c then label.TextColor3 = c end
		end
	end

	local function runLiveUpdates()
		liveMemo = {}
		for _, entry in ipairs(profileLive) do
			if entry.label.Parent then
				local ok, err = pcall(function()
					entry.label.Text = entry.text(liveMemo)
					if entry.color then
						local c = entry.color(liveMemo)
						if c then entry.label.TextColor3 = c end
					end
				end)
				if not ok then warn("[DiplomacyWindow] live label update errored: " .. tostring(err)) end
			end
		end
	end

	local function kvLive(sec, labelText, computeText, computeColor)
		local _, v = kvRow(sec, labelText, "")
		registerLive(v, computeText, computeColor)
	end

	local function proposalCard(sec, entry, mineTag)
		local prop = entry.prop
		local incoming = prop.toTag == mineTag
		local other = incoming and prop.fromTag or prop.toTag
		local r = sec.row(58)
		local card = Instance.new("Frame")
		card.Size = UDim2.new(1, 0, 1, -6)
		card.BackgroundColor3 = UIStyle.Color.PanelAlt
		card.BackgroundTransparency = 0.15
		card.BorderSizePixel = 0
		card.Parent = r
		UIBuilder.corner(card, 3)
		local stroke = UIBuilder.stroke(card, 1, incoming and UIStyle.Color.Info or UIStyle.Color.Border)
		stroke.Transparency = 0.35

		local title = Instance.new("TextLabel")
		title.Size = UDim2.new(1, -180, 0, 18)
		title.Position = UDim2.fromOffset(10, 7)
		title.BackgroundTransparency = 1
		title.Text = string.format("%s %s: %s",
			incoming and "From" or "To",
			nameOf(other),
			termsLabel[prop.terms and prop.terms.type] or "Peace")
		title.TextColor3 = UIStyle.Color.Text
		title.FontFace = UIStyle.FontFace.Cinzel
		title.TextSize = 13
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.TextTruncate = Enum.TextTruncate.AtEnd
		title.Parent = card

		local detail = Instance.new("TextLabel")
		detail.Size = UDim2.new(1, -180, 0, 14)
		detail.Position = UDim2.fromOffset(10, 28)
		detail.BackgroundTransparency = 1
		detail.TextColor3 = UIStyle.Color.TextMuted
		detail.Font = UIStyle.Font.Regular
		detail.TextSize = 11
		detail.TextXAlignment = Enum.TextXAlignment.Left
		detail.Parent = card
		local proposalId = entry.id
		registerLive(detail, function()
			local p = ClientStateCache.getPeaceProposal(proposalId) or prop
			return (incoming and "Incoming offer  \u{00B7}  " or "Awaiting response  \u{00B7}  ")
				.. proposalExpiryText(p.expiresAt or 0)
		end)

		if incoming then
			actionButton(card, "Accept", "good", {
				size = UDim2.fromOffset(76, 24),
				position = UDim2.new(1, -90, 0.5, 0),
				anchor = Vector2.new(1, 0.5),
				textSize = 12,
				onClick = function()
					if callbacks.onAcceptPeace then callbacks.onAcceptPeace(entry.id) end
				end,
			})
			actionButton(card, "Reject", "danger", {
				size = UDim2.fromOffset(76, 24),
				position = UDim2.new(1, -8, 0.5, 0),
				anchor = Vector2.new(1, 0.5),
				textSize = 12,
				onClick = function()
					if callbacks.onRejectPeace then callbacks.onRejectPeace(entry.id) end
				end,
			})
		else
			actionButton(card, "Cancel", "neutral", {
				size = UDim2.fromOffset(76, 24),
				position = UDim2.new(1, -8, 0.5, 0),
				anchor = Vector2.new(1, 0.5),
				textSize = 12,
				onClick = function()
					if callbacks.onCancelProposal then callbacks.onCancelProposal(entry.id) end
				end,
			})
		end
		return r
	end

	local function warRow(sec, war, povTag, withActions)
		local opponent = war.attackerTag == povTag and war.defenderTag or war.attackerTag
		local role = war.attackerTag == povTag and "Aggressor" or "Defender"
		local warId = war.id
		local function liveWarScore(memo)
			local key = "war:" .. tostring(warId)
			local s = memo[key]
			if s == nil then
				local w = (warId and ClientStateCache.getWar(warId)) or war
				s = w.score or 0
				if w.defenderTag == povTag then s = -s end
				memo[key] = s
			end
			return s
		end
		local h = withActions and 66 or 44
		local r = sec.row(h)
		local card = Instance.new("Frame")
		card.Size = UDim2.new(1, 0, 1, -6)
		card.BackgroundColor3 = UIStyle.Color.PanelAlt
		card.BackgroundTransparency = 0.15
		card.BorderSizePixel = 0
		card.Parent = r
		UIBuilder.corner(card, 3)
		local stroke = UIBuilder.stroke(card, 1, UIStyle.Color.Bad)
		stroke.Transparency = 0.45

		local title = Instance.new("TextLabel")
		title.Size = UDim2.new(1, -110, 0, 18)
		title.Position = UDim2.fromOffset(10, 5)
		title.BackgroundTransparency = 1
		title.Text = string.format("War with %s", nameOf(opponent))
		title.TextColor3 = UIStyle.Color.Text
		title.FontFace = UIStyle.FontFace.Cinzel
		title.TextSize = 13
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.TextTruncate = Enum.TextTruncate.AtEnd
		title.Parent = card

		local detail = Instance.new("TextLabel")
		detail.Size = UDim2.new(1, -110, 0, 14)
		detail.Position = UDim2.fromOffset(10, 24)
		detail.BackgroundTransparency = 1
		detail.Text = string.format("%s  \u{00B7}  %s", role, warDeclaredText(war))
		detail.TextColor3 = UIStyle.Color.TextMuted
		detail.Font = UIStyle.Font.Regular
		detail.TextSize = 11
		detail.TextXAlignment = Enum.TextXAlignment.Left
		detail.Parent = card

		local scoreLbl = Instance.new("TextLabel")
		scoreLbl.Size = UDim2.fromOffset(94, 18)
		scoreLbl.Position = UDim2.new(1, -10, 0, 6)
		scoreLbl.AnchorPoint = Vector2.new(1, 0)
		scoreLbl.BackgroundTransparency = 1
		scoreLbl.Font = UIStyle.Font.Bold
		scoreLbl.TextSize = 12
		scoreLbl.TextXAlignment = Enum.TextXAlignment.Right
		scoreLbl.Parent = card
		registerLive(scoreLbl, function(memo)
			return string.format("%+d war score", math.floor(liveWarScore(memo)))
		end, function(memo)
			return liveWarScore(memo) >= 0 and UIStyle.Color.Good or UIStyle.Color.Bad
		end)

		if withActions then
			actionButton(card, "White Peace", "neutral", {
				size = UDim2.fromOffset(104, 24),
				position = UDim2.new(1, -126, 1, -8),
				anchor = Vector2.new(1, 1),
				textSize = 11,
				onClick = function()
					if callbacks.onProposePeace then callbacks.onProposePeace(opponent, { type = "white_peace" }) end
				end,
			})
			actionButton(card, "Annex Occupied", "gold", {
				size = UDim2.fromOffset(110, 24),
				position = UDim2.new(1, -8, 1, -8),
				anchor = Vector2.new(1, 1),
				textSize = 11,
				onClick = function()
					if callbacks.onProposePeace then callbacks.onProposePeace(opponent, { type = "annex_occupied" }) end
				end,
			})
		end
		return r
	end

	----------------------------------------------------------------
	-- PROFILE RENDER
	----------------------------------------------------------------
	local function renderProfileHeader(country, tag, status)
		sectionOrder += 1
		local head = Instance.new("Frame")
		head.Size = UDim2.new(1, -4, 0, 92)
		head.BackgroundColor3 = UIStyle.Color.Panel
		head.BackgroundTransparency = 0.25
		head.BorderSizePixel = 0
		head.LayoutOrder = sectionOrder
		head.Parent = profileScroll
		UIBuilder.corner(head, 4)
		local headStroke = UIBuilder.stroke(head, 1, UIStyle.Color.Border)
		headStroke.Transparency = 0.3

		local color = countryColor(country)
		local accent = Instance.new("Frame")
		accent.Size = UDim2.new(0, 4, 1, 0)
		accent.BackgroundColor3 = color
		accent.BorderSizePixel = 0
		accent.Parent = head
		UIBuilder.corner(accent, 4)

		local crestHolder = Instance.new("Frame")
		crestHolder.Size = UDim2.fromOffset(64, 64)
		crestHolder.Position = UDim2.new(0, 14, 0.5, 0)
		crestHolder.AnchorPoint = Vector2.new(0, 0.5)
		crestHolder.BackgroundTransparency = 1
		crestHolder.Parent = head
		UIBuilder.crest(crestHolder, color, tag, { size = 64, flag = country and country.flagAssetId })

		local nameLbl = Instance.new("TextLabel")
		nameLbl.Size = UDim2.new(1, -260, 0, 26)
		nameLbl.Position = UDim2.fromOffset(90, 12)
		nameLbl.BackgroundTransparency = 1
		nameLbl.Text = country and (country.displayName or tag) or tag
		nameLbl.TextColor3 = UIStyle.Color.CreamBright
		nameLbl.FontFace = UIStyle.FontFace.CinzelBold
		nameLbl.TextSize = 22
		nameLbl.TextXAlignment = Enum.TextXAlignment.Left
		nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
		nameLbl.Parent = head

		local ruler = rulerNameOf(country)
		local rulerLbl = Instance.new("TextLabel")
		rulerLbl.Size = UDim2.new(1, -260, 0, 16)
		rulerLbl.Position = UDim2.fromOffset(90, 40)
		rulerLbl.BackgroundTransparency = 1
		rulerLbl.Text = ruler and ("Ruler: " .. ruler) or "Unclaimed realm"
		rulerLbl.TextColor3 = ruler and UIStyle.Color.TextMuted or UIStyle.Color.TextDim
		rulerLbl.FontFace = UIStyle.FontFace.InterItalic
		rulerLbl.TextSize = 12
		rulerLbl.TextXAlignment = Enum.TextXAlignment.Left
		rulerLbl.Parent = head

		local badgeRow = Instance.new("Frame")
		badgeRow.Size = UDim2.new(1, -260, 0, UIStyle.Size.BadgeH)
		badgeRow.Position = UDim2.fromOffset(90, 62)
		badgeRow.BackgroundTransparency = 1
		badgeRow.Parent = head
		do
			local layout = Instance.new("UIListLayout")
			layout.FillDirection = Enum.FillDirection.Horizontal
			layout.Padding = UDim.new(0, 6)
			layout.VerticalAlignment = Enum.VerticalAlignment.Center
			layout.Parent = badgeRow
		end
		local gov = govLabelOf(country)
		local ideology = ideologyLabelOf(country)
		if gov then UIBuilder.badge(badgeRow, gov, "muted") end
		if ideology then UIBuilder.badge(badgeRow, ideology, "info") end

		-- Relation chip pinned top-right
		local chipText, chipTone = nil, nil
		if status.kind == "self" then
			chipText, chipTone = "Your Realm", "gold"
		elseif status.kind == "at_war" then
			chipText, chipTone = "At War", "bad"
		elseif status.kind == "truce" then
			chipText, chipTone = "Truce", "warn"
		elseif status.kind == "peace" then
			chipText, chipTone = "At Peace", "good"
		end
		if chipText then
			UIBuilder.badge(head, chipText, chipTone, {
				Position = UDim2.new(1, -12, 0, 12),
				AnchorPoint = Vector2.new(1, 0),
			})
		end
	end

	local function renderOverviewSection(country, tag)
		local sec = section("Overview")
		kvLive(sec, "Population", function(memo)
			local _, population = liveStats(memo, tag)
			return fmtInt(population)
		end)
		kvLive(sec, "Provinces", function(memo)
			return fmtInt((liveStats(memo, tag)))
		end)
		kvRow(sec, "Capital", capitalNameOf(country))
		local culture = country and country.primaryCulture
		if culture then
			kvRow(sec, "Culture", (tostring(culture):gsub("_", " "):gsub("^%l", string.upper)))
		end
		sec.gap(4)
	end

	local function renderTreasurySection(tag)
		local sec = section("Treasury & State")
		kvLive(sec, "Treasury", function(memo)
			local c = liveCountry(memo, tag)
			return fmtInt(c and c.treasury)
		end, function()
			return UIStyle.Color.Gold
		end)
		kvLive(sec, "Manpower", function(memo)
			local c = liveCountry(memo, tag)
			return fmtInt(c and c.manpower)
		end)
		kvLive(sec, "Political Power", function(memo)
			local c = liveCountry(memo, tag)
			return fmtInt(c and c.politicalPower)
		end)
		kvLive(sec, "Stability", function(memo)
			local c = liveCountry(memo, tag)
			return tostring(c and c.stability or 0)
		end, function(memo)
			local c = liveCountry(memo, tag)
			return UIStyle.stateColor(c and c.stability or 0)
		end)
		kvLive(sec, "Legitimacy", function(memo)
			local c = liveCountry(memo, tag)
			return fmtInt(c and c.legitimacy)
		end)
		sec.gap(4)
	end

	local function renderGovernmentNav()
		local sec = section("Government")
		for _, def in ipairs(POLITICS_TABS) do
			local r = sec.row(34)
			local btn = actionButton(r, def.label, "gold", {
				size = UDim2.new(1, 0, 1, -6),
				onClick = function()
					showScreen("politics")
					setPoliticsTab(def.key)
				end,
			})
			btn.TextXAlignment = Enum.TextXAlignment.Left
			do
				local pad = Instance.new("UIPadding")
				pad.PaddingLeft = UDim.new(0, 32)
				pad.Parent = btn
			end
			UIBuilder.icon(btn, def.icon, 14, {
				Position = UDim2.new(0, -22, 0.5, 0),
				AnchorPoint = Vector2.new(0, 0.5),
				ImageColor3 = UIStyle.Color.Gold,
			})
			local chevron = Instance.new("TextLabel")
			chevron.Size = UDim2.fromOffset(20, 20)
			chevron.Position = UDim2.new(1, -8, 0.5, 0)
			chevron.AnchorPoint = Vector2.new(1, 0.5)
			chevron.BackgroundTransparency = 1
			chevron.Text = "\u{203A}"
			chevron.TextColor3 = UIStyle.Color.GoldDim
			chevron.Font = UIStyle.Font.Bold
			chevron.TextSize = 16
			chevron.Parent = btn
		end
		sec.gap(4)
	end

	local function renderRelationsSection(country, tag, status, mineTag)
		local sec = section("Relations with " .. (country and country.displayName or tag))
		if status.kind == "at_war" then
			local war = status.war
			local warId = war.id
			local function liveWar(memo)
				if memo.relationsWar == nil then
					memo.relationsWar = (warId and ClientStateCache.getWar(warId)) or war
				end
				return memo.relationsWar
			end
			local function viewerScore(w)
				local score = w.score or 0
				if w.defenderTag == mineTag then score = -score end
				return score
			end
			kvRow(sec, "Status", "At War", UIStyle.Color.Bad)
			kvLive(sec, "War score (you)", function(memo)
				return string.format("%+d", math.floor(viewerScore(liveWar(memo))))
			end, function(memo)
				return viewerScore(liveWar(memo)) >= 0 and UIStyle.Color.Good or UIStyle.Color.Bad
			end)
			kvLive(sec, "War exhaustion", function(memo)
				local w = liveWar(memo)
				local myExh = w.attackerTag == mineTag and w.attackerExhaustion or w.defenderExhaustion
				local theirExh = w.attackerTag == mineTag and w.defenderExhaustion or w.attackerExhaustion
				return string.format("you %.1f  \u{00B7}  them %.1f", myExh or 0, theirExh or 0)
			end)
			kvRow(sec, "Declared", (warDeclaredText(war):gsub("^since ", "")))
		elseif status.kind == "truce" then
			kvRow(sec, "Status", "Truce", UIStyle.Color.Warn)
			local truceEnds = status.truceEnds
			kvLive(sec, "Truce expires", function()
				return truceRemainingText(truceEnds)
			end)
		else
			kvRow(sec, "Status", "At Peace", UIStyle.Color.Good)
		end
		kvRow(sec, "Alliance", "None")
		kvRow(sec, "Non-Aggression Pact", "None")

		local proposals = pendingProposalsBetween(tag, mineTag)
		if #proposals > 0 then
			sec.gap(6)
			for _, entry in ipairs(proposals) do
				proposalCard(sec, entry, mineTag)
			end
		end
		sec.gap(4)
	end

	local function renderActionsSection(tag, status, mineTag)
		local sec = section("Diplomatic Actions")
		if not mineTag then
			noteRow(sec, "Claim a country to conduct diplomacy.")
			sec.gap(4)
			return
		end
		local function actionRow(text, tone, opts)
			local r = sec.row(34)
			opts = opts or {}
			opts.size = UDim2.new(1, 0, 1, -6)
			actionButton(r, text, tone, opts)
		end
		if status.kind == "peace" then
			actionRow("Declare War", "danger", {
				onClick = function()
					if callbacks.onDeclareWar then callbacks.onDeclareWar(tag) end
				end,
			})
		elseif status.kind == "truce" then
			actionRow("Declare War", "danger", { disabled = true, disabledNote = "truce" })
		elseif status.kind == "at_war" then
			actionRow("Offer White Peace", "neutral", {
				onClick = function()
					if callbacks.onProposePeace then callbacks.onProposePeace(tag, { type = "white_peace" }) end
				end,
			})
			actionRow("Demand Occupied Lands", "gold", {
				onClick = function()
					if callbacks.onProposePeace then callbacks.onProposePeace(tag, { type = "annex_occupied" }) end
				end,
			})
		end
		actionRow("Form Alliance", "good", { disabled = true, disabledNote = "soon" })
		actionRow("Non-Aggression Pact", "neutral", { disabled = true, disabledNote = "soon" })
		actionRow("Make Puppet State", "gold", { disabled = true, disabledNote = "soon" })
		sec.gap(4)
	end

	local function renderWarsSection(tag, mineTag, own)
		local wars = warsInvolving(tag)
		local sec = section(own and "Your Wars" or "Active Wars")
		if #wars == 0 then
			noteRow(sec, own and "You are at peace with the world." or "Not engaged in any war.")
		else
			for _, war in ipairs(wars) do
				local withActions = own and (war.attackerTag == mineTag or war.defenderTag == mineTag)
				warRow(sec, war, tag, withActions)
			end
		end
		sec.gap(4)
	end

	local function renderTrucesSection(country)
		local truces = {}
		if country and country.truces then
			for otherTag, ends in pairs(country.truces) do
				table.insert(truces, { tag = otherTag, ends = ends })
			end
		end
		table.sort(truces, function(a, b) return (a.ends or 0) < (b.ends or 0) end)
		local sec = section("Truces")
		if #truces == 0 then
			noteRow(sec, "No standing truces.")
		else
			for _, t in ipairs(truces) do
				local ends = t.ends
				kvLive(sec, nameOf(t.tag), function()
					return truceRemainingText(ends)
				end, function()
					return UIStyle.Color.Warn
				end)
			end
		end
		sec.gap(4)
	end

	local function renderProposalInbox(mineTag)
		local proposals = pendingProposalsFor(mineTag)
		local sec = section("Peace Proposals")
		if #proposals == 0 then
			noteRow(sec, "No pending proposals. Offers you send or receive appear here.")
		else
			for _, entry in ipairs(proposals) do
				proposalCard(sec, entry, mineTag)
			end
		end
		sec.gap(4)
	end

	local lastProfileSignature = nil

	local function renderProfile()
		local mineTag = myTag()
		-- Same trick as the country list: skip the full rebuild when nothing
		-- structural changed; ticking numbers refresh in place as live labels.
		local signature = profileSignature(selectedTag, mineTag)
		if signature == lastProfileSignature then
			runLiveUpdates()
			return
		end
		lastProfileSignature = signature

		local priorPos = profileScroll.CanvasPosition
		clearChildren(profileScroll)
		sectionOrder = 0
		profileLive = {}
		liveMemo = {}

		local tag = selectedTag
		if not tag then
			UIBuilder.emptyState(profileScroll, {
				icon = "Diplomacy",
				title = "Select a nation",
				subtitle = "Choose a country from the list to view its profile.",
			})
			return
		end
		local country = ClientStateCache.getCountry(tag)
		if not country then
			UIBuilder.emptyState(profileScroll, {
				icon = "Diplomacy",
				title = "Awaiting world data",
				subtitle = "This nation has not been replicated yet.",
			})
			return
		end

		local status = statusFor(tag, mineTag)
		renderProfileHeader(country, tag, status)
		renderOverviewSection(country, tag)

		if status.kind == "self" then
			renderTreasurySection(tag)
			renderGovernmentNav()
			renderWarsSection(tag, mineTag, true)
			renderTrucesSection(country)
			renderProposalInbox(mineTag)
		else
			if mineTag then
				renderRelationsSection(country, tag, status, mineTag)
			end
			renderActionsSection(tag, status, mineTag)
			renderWarsSection(tag, mineTag, false)
		end

		task.defer(function()
			if profileScroll.Parent then profileScroll.CanvasPosition = priorPos end
		end)
	end

	----------------------------------------------------------------
	-- COUNTRY LIST RENDER
	----------------------------------------------------------------
	local rowRefs = {}
	-- Rebuilding ~130 rows on every 1.5s state delta is wasteful; skip the rebuild
	-- when nothing row-visible (membership, names, claims, statuses, selection) changed.
	local lastListSignature = nil

	local function applyFilter()
		local f = string.lower(searchText)
		for _, ref in ipairs(rowRefs) do
			ref.row.Visible = f == "" or ref.name:find(f, 1, true) ~= nil or ref.tag:find(f, 1, true) ~= nil
		end
	end

	local selectCountry -- forward decl

	local function countryRow(entry, order)
		local row = Instance.new("TextButton")
		row.Name = "row_" .. entry.tag
		row.Size = UDim2.new(1, 0, 0, ROW_H)
		row.BackgroundColor3 = entry.tag == selectedTag and UIStyle.Color.PanelHigh or UIStyle.Color.Panel
		row.BackgroundTransparency = 0.15
		row.BorderSizePixel = 0
		row.AutoButtonColor = false
		row.Text = ""
		row.LayoutOrder = order
		row.Parent = listScroll
		UIBuilder.corner(row, 3)
		local stroke = UIBuilder.stroke(row, 1, entry.tag == selectedTag and UIStyle.Color.Gold or UIStyle.Color.BorderDim)
		stroke.Transparency = entry.tag == selectedTag and 0 or 0.5

		local crestHolder = Instance.new("Frame")
		crestHolder.Size = UDim2.fromOffset(26, 26)
		crestHolder.Position = UDim2.new(0, 6, 0.5, 0)
		crestHolder.AnchorPoint = Vector2.new(0, 0.5)
		crestHolder.BackgroundTransparency = 1
		crestHolder.Parent = row
		UIBuilder.crest(crestHolder, countryColor(entry.country), entry.tag,
			{ size = 26, flag = entry.country and entry.country.flagAssetId })

		local status = entry.status
		local chipW = 0
		local chipText, chipTone = nil, nil
		if status.kind == "self" then
			chipText, chipTone = "YOU", nil -- default gold
		elseif status.kind == "at_war" then
			chipText, chipTone = "WAR", "bad"
		elseif status.kind == "truce" then
			chipText, chipTone = "TRUCE", "warn"
		end
		if chipText then
			UIBuilder.badge(row, chipText, chipTone, {
				Position = UDim2.new(1, -8, 0.5, 0),
				AnchorPoint = Vector2.new(1, 0.5),
			})
			chipW = 56
		end

		local nameLbl = Instance.new("TextLabel")
		nameLbl.Size = UDim2.new(1, -(40 + chipW + (entry.claimed and 14 or 0)), 1, 0)
		nameLbl.Position = UDim2.fromOffset(40, 0)
		nameLbl.BackgroundTransparency = 1
		nameLbl.Text = entry.name
		nameLbl.TextColor3 = entry.tag == selectedTag and UIStyle.Color.CreamBright or UIStyle.Color.Text
		nameLbl.FontFace = UIStyle.FontFace.Cinzel
		nameLbl.TextSize = 13
		nameLbl.TextXAlignment = Enum.TextXAlignment.Left
		nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
		nameLbl.Parent = row

		-- Player-claimed marker (skip on your own row; the YOU chip covers it)
		if entry.claimed and status.kind ~= "self" then
			local dot = Instance.new("Frame")
			dot.Size = UDim2.fromOffset(7, 7)
			dot.Position = UDim2.new(1, -(chipW > 0 and chipW + 12 or 12), 0.5, 0)
			dot.AnchorPoint = Vector2.new(1, 0.5)
			dot.BackgroundColor3 = UIStyle.Color.Info
			dot.BorderSizePixel = 0
			dot.Parent = row
			UIBuilder.corner(dot, 4)
		end

		row.MouseButton1Click:Connect(function()
			selectCountry(entry.tag)
		end)

		table.insert(rowRefs, {
			row = row,
			name = string.lower(entry.name),
			tag = string.lower(entry.tag),
		})
	end

	local function renderList()
		local mineTag = myTag()
		local own, others = nil, {}
		for tag, country in pairs(ClientStateCache.allCountries()) do
			local entry = {
				tag = tag,
				country = country,
				name = country.displayName or tag,
				claimed = country.claimedBy ~= nil,
				status = statusFor(tag, mineTag),
			}
			if tag == mineTag then
				own = entry
			else
				table.insert(others, entry)
			end
		end
		table.sort(others, function(a, b) return a.name < b.name end)

		local sigParts = { "sel=" .. tostring(selectedTag) }
		local function addSig(entry)
			sigParts[#sigParts + 1] = entry.tag .. (entry.claimed and "+" or "-") .. entry.status.kind .. entry.name
		end
		if own then addSig(own) end
		for _, entry in ipairs(others) do
			addSig(entry)
		end
		local signature = table.concat(sigParts, "|")
		if signature == lastListSignature then
			return
		end
		lastListSignature = signature

		local priorPos = listScroll.CanvasPosition
		clearChildren(listScroll)
		rowRefs = {}

		if not own and #others == 0 then
			UIBuilder.emptyState(listScroll, {
				icon = "Diplomacy",
				title = "No nations",
				subtitle = "Waiting for the world to replicate.",
			})
			return
		end

		local order = 0
		if own then
			order += 1
			countryRow(own, order)
		end
		for _, entry in ipairs(others) do
			order += 1
			countryRow(entry, order)
		end
		applyFilter()

		task.defer(function()
			if listScroll.Parent then listScroll.CanvasPosition = priorPos end
		end)
	end

	renderMain = function()
		pendingMainRender = false
		renderList()
		renderProfile()
	end

	selectCountry = function(tag)
		if selectedTag == tag and screen == "main" then return end
		selectedTag = tag
		if screen ~= "main" then
			showScreen("main")
		end
		if win.isOpen() then
			renderMain()
		else
			pendingMainRender = true
		end
	end

	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		searchText = searchBox.Text
		applyFilter()
	end)

	----------------------------------------------------------------
	-- Refresh plumbing
	----------------------------------------------------------------
	local refreshPending = false
	local function scheduleRefresh()
		if refreshPending then return end
		refreshPending = true
		task.defer(function()
			refreshPending = false
			if not win.isOpen() then
				pendingMainRender = true
				return
			end
			if screen == "main" then
				renderMain()
			else
				pendingMainRender = true
			end
		end)
	end
	ClientStateCache.onChangePrefix("countries", scheduleRefresh)
	ClientStateCache.onChangePrefix("wars", scheduleRefresh)
	ClientStateCache.onChangePrefix("peaceProposals", scheduleRefresh)

	----------------------------------------------------------------
	-- Public handle
	----------------------------------------------------------------
	local function openWindow(animated)
		if not selectedTag then
			selectedTag = myTag()
		end
		if screen == "main" then
			renderMain()
		elseif activePoliticsKey then
			ensurePoliticsTabFresh(activePoliticsKey)
		end
		win.open(animated)
	end

	local function openCountry(tag)
		if tag then
			selectedTag = tag
		end
		showScreen("main")
		renderMain()
		if not win.isOpen() then win.open() end
		win.bringToFront()
	end

	local function openOwnProfile()
		local mine = myTag()
		if mine then
			openCountry(mine)
		else
			openWindow()
		end
	end

	local function openPoliticsTab(tabName)
		local mine = myTag()
		if mine then selectedTag = mine end
		if politicsTabs[tabName] then
			showScreen("politics")
			setPoliticsTab(tabName)
		else
			showScreen("main")
			renderMain()
		end
		if not win.isOpen() then win.open() end
		win.bringToFront()
	end

	return {
		root = win.root,
		body = win.body,
		open = openWindow,
		close = win.close,
		toggle = function()
			if win.isOpen() then win.close() else openWindow() end
		end,
		isOpen = win.isOpen,
		bringToFront = win.bringToFront,
		refresh = function()
			if win.isOpen() and screen == "main" then renderMain() end
		end,
		selectCountry = selectCountry,
		openCountry = openCountry,
		openOwnProfile = openOwnProfile,
		openPoliticsTab = openPoliticsTab,
		setActiveTab = openPoliticsTab, -- legacy alias (politics tab names)
		getSelected = function() return selectedTag end,
		isShowingOwn = function()
			local mine = myTag()
			return win.isOpen() and screen == "main" and mine ~= nil and selectedTag == mine
		end,
		tabImpls = gatedTabImpls,
	}
end

return DiplomacyWindow
