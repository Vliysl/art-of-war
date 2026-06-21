local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local UI = script.Parent
local ArtOfWar = UI.Parent
local DesignSystem = require(ArtOfWar.DesignSystem)
local Responsive = DesignSystem.Responsive
local Spacing = DesignSystem.Spacing
local Colors = DesignSystem.Colors
local Icons = DesignSystem.Icons

local Screens = UI.Screens
local Components = UI.Components
local CountryBar = require(Screens.CountryBar)
local TopBar = require(Screens.TopBar)
local MapModeGrid = require(Screens.MapModeGrid)
local NotificationCard = require(Components.NotificationCard)

local Hud = {}

local LAYER_ORDER = { Hud = 10, Screens = 20, Modals = 50, Notifications = 60, Tooltips = 80 }
local MENU_KEYS = {
	[Enum.KeyCode.One] = "Politics",
	[Enum.KeyCode.Two] = "Economy",
	[Enum.KeyCode.Three] = "Military",
	[Enum.KeyCode.Four] = "Diplomacy",
	[Enum.KeyCode.Five] = "Research",
	[Enum.KeyCode.Six] = "Missions",
}
local SCREEN_MODULES = {
	Politics = "PoliticsScreen",
	Economy = "EconomyScreen",
	Military = "MilitaryScreen",
	Diplomacy = "DiplomacyScreen",
	Research = "ResearchScreen",
	Missions = "MissionsScreen",
	Settings = "SettingsScreen",
}

local started = false
local layers = {}
local widgets = {}
local handlers = {}
local notifications = {}
local activeScreen = nil
local countryData = {}
local screenContext = {}

local function targetGui(override)
	if override then
		return override
	end
	local lp = Players.LocalPlayer
	return lp and lp:WaitForChild("PlayerGui")
end

local function makeLayer(name, ignoreInset, parentGui)
	local sg = Instance.new("ScreenGui")
	sg.Name = "AoW_" .. name
	sg.ResetOnSpawn = false
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.IgnoreGuiInset = ignoreInset == true
	sg.DisplayOrder = LAYER_ORDER[name] or 10
	sg.Parent = parentGui
	Responsive.attach(sg)
	return sg
end

local function buildCountryBar()
	if widgets.countryBar and widgets.countryBar.root then
		widgets.countryBar.root:Destroy()
	end
	widgets.countryBar = CountryBar.create({
		parent = layers.Hud,
		tooltipLayer = layers.Tooltips,
		code = countryData.code or "",
		name = countryData.name or "Unclaimed",
		government = countryData.government,
		culture = countryData.culture,
		color = countryData.color,
		resources = countryData.resources or {},
		onMenu = function(menu)
			Hud.openScreen(menu)
		end,
	})
	if activeScreen then
		widgets.countryBar.setActive(activeScreen.name)
	end
end

local function mountPersistent(opts)
	widgets.topBar = TopBar.create({
		parent = layers.Hud,
		date = opts.date or "",
		onTogglePause = function()
			if handlers.onTimeControl then
				handlers.onTimeControl({ action = "togglePause" })
			end
		end,
		onSetSpeed = function(n)
			if handlers.onTimeControl then
				handlers.onTimeControl({ action = "setSpeed", speed = n })
			end
		end,
	})
	-- The date capsule lives on the inset-respecting Hud layer (so it hides with the rest of the
	-- HUD during nation selection), but should sit at the true top-center. Lift it by the GUI inset
	-- so it lands near the top edge regardless of the topbar inset / resolution.
	local function placeTopBar()
		local bar = widgets.topBar and widgets.topBar.root
		if bar then
			local inset = GuiService:GetGuiInset()
			bar.Position = UDim2.new(0.5, 0, 0, 6 - inset.Y)
		end
	end
	placeTopBar()
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(placeTopBar)

	widgets.mapModeGrid = MapModeGrid.create({
		parent = layers.Hud,
		modes = opts.mapModes,
		active = opts.mapMode or "political",
		onChange = function(mode)
			if handlers.onMapMode then
				handlers.onMapMode(mode)
			end
		end,
	})

	buildCountryBar()

	local holder = Instance.new("Frame")
	holder.Name = "Notifications"
	holder.AnchorPoint = Vector2.new(1, 0)
	holder.Position = UDim2.new(1, -16, 0, 96)
	holder.Size = UDim2.new(0, 340, 1, -200)
	holder.BackgroundTransparency = 1
	holder.Parent = layers.Notifications
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Spacing.space2)
	layout.Parent = holder
	widgets.notifHolder = holder

	local gear = Instance.new("ImageButton")
	gear.Name = "SettingsGear"
	gear.AnchorPoint = Vector2.new(0, 0)
	gear.Position = UDim2.fromOffset(16, 16)
	gear.Size = UDim2.fromOffset(Responsive.tapHeight(36), Responsive.tapHeight(36))
	gear.BackgroundTransparency = 1
	gear.AutoButtonColor = false
	gear.Image = ""
	gear:SetAttribute("AoWInputSink", true)
	gear.Parent = layers.Hud
	local gicon = Icons.create("Settings", 22, Colors.TextSecondary)
	gicon.AnchorPoint = Vector2.new(0.5, 0.5)
	gicon.Position = UDim2.fromScale(0.5, 0.5)
	gicon.Parent = gear
	gear.MouseEnter:Connect(function()
		gicon.ImageColor3 = Colors.TextPrimary
	end)
	gear.MouseLeave:Connect(function()
		gicon.ImageColor3 = Colors.TextSecondary
	end)
	gear.MouseButton1Click:Connect(function()
		Hud.openSettings()
	end)
	widgets.gear = gear
end

local function bindHotkeys()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		local code = input.KeyCode
		if code == Enum.KeyCode.Escape then
			Hud.closeScreen()
			Hud.closeContext()
		elseif MENU_KEYS[code] then
			Hud.openScreen(MENU_KEYS[code])
		end
	end)
end

function Hud.bind(map)
	for k, v in map do
		handlers[k] = v
	end
end

function Hud.setContext(t)
	if type(t) ~= "table" then
		return
	end
	for k, v in t do
		screenContext[k] = v
	end
end

local function mergedCtx(extra)
	local ctx = {
		handlers = handlers,
		modalLayer = layers.Modals,
		parent = layers.Screens,
		hudLayer = layers.Hud,
		tooltipLayer = layers.Tooltips,
	}
	for k, v in screenContext do
		ctx[k] = v
	end
	if extra then
		for k, v in extra do
			ctx[k] = v
		end
	end
	return ctx
end

function Hud.getLayer(name)
	return layers[name]
end

function Hud.start(opts)
	if started then
		return Hud
	end
	started = true
	opts = opts or {}
	local gui = targetGui(opts.parentGui)
	if not gui then
		started = false
		return Hud
	end
	if opts.code or opts.name or opts.resources then
		countryData = {
			code = opts.code,
			name = opts.name,
			government = opts.government,
			culture = opts.culture,
			color = opts.color,
			resources = opts.resources,
		}
	end
	layers.Hud = makeLayer("Hud", false, gui)
	layers.Screens = makeLayer("Screens", false, gui)
	layers.Modals = makeLayer("Modals", true, gui)
	layers.Notifications = makeLayer("Notifications", false, gui)
	layers.Tooltips = makeLayer("Tooltips", true, gui)
	mountPersistent(opts)
	bindHotkeys()
	return Hud
end

function Hud.setCountry(data)
	countryData = data or {}
	if started then
		-- Mutate the existing bar in place; only fall back to a full rebuild if it isn't built yet.
		if widgets.countryBar and widgets.countryBar.update then
			widgets.countryBar.update(countryData)
		else
			buildCountryBar()
		end
	end
end

function Hud.setClock(date)
	if widgets.topBar and date ~= nil then
		widgets.topBar.setDate(date)
	end
end

function Hud.setTime(packet)
	if widgets.topBar and widgets.topBar.setTime then
		widgets.topBar.setTime(packet)
	end
end

function Hud.setMapMode(key)
	if widgets.mapModeGrid then
		widgets.mapModeGrid.setActive(key)
	end
end

function Hud.notify(payload)
	if not started or not widgets.notifHolder then
		return
	end
	payload = payload or {}
	local KIND_ALIAS = {
		warn = "warning",
		warning = "warning",
		error = "danger",
		danger = "danger",
		success = "success",
		info = "info",
	}
	local card = NotificationCard.create({
		parent = widgets.notifHolder,
		severity = KIND_ALIAS[payload.kind or payload.severity or "info"] or "info",
		title = payload.title or "",
		body = payload.body,
		ttl = payload.ttl or 8,
		width = 332,
		onDismiss = function()
			for i, c in ipairs(notifications) do
				if c == card then
					table.remove(notifications, i)
					break
				end
			end
		end,
	})
	table.insert(notifications, card)
	return card
end

function Hud.openScreen(name, props)
	if not started then
		return
	end
	if activeScreen and activeScreen.name == name then
		Hud.closeScreen()
		return
	end
	Hud.closeScreen()

	local modName = SCREEN_MODULES[name]
	local mod = modName and Screens:FindFirstChild(modName)
	if not mod then
		return
	end
	local ok, screen = pcall(require, mod)
	if not ok or type(screen) ~= "table" or not screen.create then
		warn("[AoW Hud] screen failed: " .. name .. " -> " .. tostring(screen))
		return
	end
	local handle = screen.create(mergedCtx({
		data = props or countryData,
		onClose = function()
			Hud.closeScreen()
		end,
	}))
	activeScreen = { name = name, handle = handle }
	if widgets.countryBar then
		widgets.countryBar.setActive(name)
	end
end

function Hud.closeScreen()
	if not activeScreen then
		return
	end
	local handle = activeScreen.handle
	activeScreen = nil
	if handle then
		if handle.destroy then
			handle.destroy()
		elseif handle.root then
			handle.root:Destroy()
		end
	end
end

local activeContext = nil
local nationSelect = nil

function Hud.closeContext()
	if not activeContext then
		return
	end
	local handle = activeContext
	activeContext = nil
	if handle.destroy then
		handle.destroy()
	elseif handle.root then
		handle.root:Destroy()
	end
end

local function openContext(moduleName, data)
	if not started then
		return
	end
	Hud.closeContext()
	local mod = Screens:FindFirstChild(moduleName)
	if not mod then
		return
	end
	local ok, screen = pcall(require, mod)
	if not ok or type(screen) ~= "table" or not screen.create then
		warn("[AoW Hud] " .. moduleName .. " failed: " .. tostring(screen))
		return
	end
	activeContext = screen.create(mergedCtx({
		data = data,
		onClose = function()
			Hud.closeContext()
		end,
	}))
	return activeContext
end

Hud.closeProvince = Hud.closeContext

function Hud.openProvince(provinceData)
	return openContext("ProvinceOverview", provinceData)
end

function Hud.openArmyPanel(armyData)
	return openContext("ArmyPanel", armyData)
end

function Hud.openFleetPanel(fleetData)
	return openContext("FleetPanel", fleetData)
end

-- Deep-link to a country's diplomacy profile (e.g. from the province-panel crest). Force-(re)opens the
-- Diplomacy screen focused on `tag`; openScreen toggles closed when re-invoked with the active screen's
-- name, so pre-close Diplomacy if it is already open.
function Hud.openCountryProfile(tag)
	if not tag then
		return
	end
	if activeScreen and activeScreen.name == "Diplomacy" then
		Hud.closeScreen()
	end
	return Hud.openScreen("Diplomacy", { focusTag = tag })
end

function Hud.openSettings()
	return Hud.openScreen("Settings")
end

function Hud.openNationSelection(opts)
	if not started then
		return
	end
	local mod = Screens:FindFirstChild("NationSelection")
	if not mod then
		return
	end
	local ok, screen = pcall(require, mod)
	if not ok or type(screen) ~= "table" or not screen.create then
		warn("[AoW Hud] NationSelection failed: " .. tostring(screen))
		return
	end
	Hud.closeNationSelection()
	nationSelect = screen.create(mergedCtx({ parent = layers.Modals, data = opts }))
	return nationSelect
end

function Hud.closeNationSelection()
	if nationSelect then
		nationSelect.destroy()
		nationSelect = nil
	end
end

function Hud.openPeaceTreaty(treaty)
	if not started then
		return
	end
	local mod = Screens:FindFirstChild("PeaceTreaty")
	if not mod then
		return
	end
	local ok, screen = pcall(require, mod)
	if not ok or type(screen) ~= "table" or not screen.create then
		warn("[AoW Hud] PeaceTreaty failed: " .. tostring(screen))
		return
	end
	return screen.create(mergedCtx({ parent = layers.Modals, data = treaty, onClose = function() end }))
end

function Hud.openTradeOffer(order)
	if not started then
		return
	end
	local mod = Screens:FindFirstChild("TradeOffer")
	if not mod then
		return
	end
	local ok, screen = pcall(require, mod)
	if not ok or type(screen) ~= "table" or not screen.create then
		warn("[AoW Hud] TradeOffer failed: " .. tostring(screen))
		return
	end
	return screen.create(mergedCtx({ parent = layers.Modals, data = order, onClose = function() end }))
end

function Hud.openDiplomaticOffer(pact)
	if not started then
		return
	end
	local mod = Screens:FindFirstChild("DiplomaticOffer")
	if not mod then
		return
	end
	local ok, screen = pcall(require, mod)
	if not ok or type(screen) ~= "table" or not screen.create then
		warn("[AoW Hud] DiplomaticOffer failed: " .. tostring(screen))
		return
	end
	return screen.create(mergedCtx({ parent = layers.Modals, data = pact, onClose = function() end }))
end

function Hud.isStarted()
	return started
end

return Hud
