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
local NotificationCard = require(Components.NotificationCard)
-- TopbarPlus (v3) icon library, installed at ReplicatedStorage.TopbarPlus. Drives the native-look topbar
-- Settings button that replaces the old on-screen gear. Client-only module (Hud is only required on the client).
-- Guarded: a bare WaitForChild would YIELD FOREVER if TopbarPlus is missing from a republished place (it is
-- not in Rojo/git; it survives only via $ignoreUnknownInstances), hanging every client behind the loading
-- screen. Time out + pcall so a missing/broken package degrades to "no topbar button" instead of a brick.
local TopbarIcon
do
	local tbp = ArtOfWar.Parent:WaitForChild("TopbarPlus", 10)
	local iconMod = tbp and tbp:WaitForChild("Icon", 10)
	if iconMod then
		local ok, mod = pcall(require, iconMod)
		if ok then
			TopbarIcon = mod
		else
			warn("[AoW Hud] TopbarPlus.Icon failed to load: " .. tostring(mod))
		end
	else
		warn("[AoW Hud] TopbarPlus not found -- settings topbar button disabled")
	end
end

local Hud = {}

local LAYER_ORDER = { Hud = 10, Screens = 20, Modals = 50, Notifications = 60, Tooltips = 80 }
-- Court/Estates/Reforms (the PoliticsScreen) were cut ahead of the public playtest, so key 1 (which opened the
-- standalone Politics window) is unbound and "Politics" is dropped from SCREEN_MODULES. The crest still opens
-- the Realm window (now Diplomacy-only). Key 4 opens the standalone Diplomacy list.
local MENU_KEYS = {
	[Enum.KeyCode.Two] = "Economy",
	[Enum.KeyCode.Three] = "Military",
	[Enum.KeyCode.Four] = "Diplomacy",
	[Enum.KeyCode.Five] = "Research",
	[Enum.KeyCode.Seven] = "Settings",
}
-- Missions (key 6) was hidden ahead of the public playtest: mission trees are an unpopulated placeholder and
-- the only real content (form Iberia) is gated behind ~152 provinces, so the screen reads as empty/broken.
-- FormableSystem stays intact server-side for a future reachable entry point.
local SCREEN_MODULES = {
	Realm = "RealmScreen",
	Economy = "EconomyScreen",
	Military = "MilitaryScreen",
	Diplomacy = "DiplomacyScreen",
	Research = "ResearchScreen",
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
		onCrest = function()
			Hud.openScreen("Realm")
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

	-- (Map-mode coloring buttons removed -- they were non-functional. The map stays in its boot political
	-- coloring; MapRenderer still applies it. Hud.setMapMode is now a no-op via the nil widget guard.)

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

	-- Settings button now lives on the native Roblox topbar (TopbarPlus, left-aligned) instead of an on-screen
	-- gear. oneClick makes it deselect immediately, so each click just toggles the Settings screen. Its enabled
	-- state mirrors the HUD layer, so it hides during nation selection (when that layer is disabled) exactly
	-- like the old gear did.
	if TopbarIcon then
		local ok, settingsIcon = pcall(function()
			return TopbarIcon.new()
				:setName("SettingsIcon")
				:align("Left")
				:setImage("rbxassetid://5912368763")
				:setCaption("Settings")
				:oneClick(true)
				:bindEvent("selected", function()
					Hud.openSettings()
				end)
		end)
		if ok and settingsIcon then
			local function syncTopbarVisible()
				settingsIcon:setEnabled(layers.Hud.Enabled)
			end
			syncTopbarVisible()
			layers.Hud:GetPropertyChangedSignal("Enabled"):Connect(syncTopbarVisible)
			widgets.settingsIcon = settingsIcon
		else
			warn("[AoW Hud] TopbarPlus Icon creation failed: " .. tostring(settingsIcon))
		end
	end
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
	if widgets.countryBar and widgets.countryBar.setActive then
		widgets.countryBar.setActive(nil)
	end
	if handle then
		if handle.destroy then
			handle.destroy()
		elseif handle.root then
			handle.root:Destroy()
		end
	end
end

local activeContext = nil
local activeContextName = nil
local nationSelect = nil

function Hud.closeContext()
	if not activeContext then
		return
	end
	local handle = activeContext
	activeContext = nil
	activeContextName = nil
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
	activeContextName = moduleName
	return activeContext
end

-- Name of the module backing the current context panel (nil if none). Lets callers (e.g. HudWiring's
-- province-ownership auto-refresh) confirm the province panel is still the active context before acting.
function Hud.getContextName()
	return activeContextName
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
-- Realm window on its Diplomacy tab focused on `tag`; openScreen toggles closed when re-invoked with the
-- active screen's name, so pre-close Realm if it is already open.
function Hud.openCountryProfile(tag)
	if not tag then
		return
	end
	if activeScreen and activeScreen.name == "Realm" then
		Hud.closeScreen()
	end
	return Hud.openScreen("Realm", { initialTab = "Diplomacy", focusTag = tag })
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

-- ── Political event alert (RoN-style) ───────────────────────────────────────
-- An event first appears as a small "!" chip above the bottom bar. Clicking it pops
-- out the full EventCard window (draggable, non-blocking). Closing that window collapses
-- back to the chip; choosing an option (or a server-side deadline auto-resolve) clears both.
local eventAlert = nil -- { event, chip, window }
local buildEventChip, openEventWindow

local function destroyEventChip()
	if eventAlert and eventAlert.chip then
		eventAlert.chip:Destroy()
		eventAlert.chip = nil
	end
end

local function destroyEventWindow()
	if eventAlert and eventAlert.window then
		if eventAlert.window.destroy then
			pcall(eventAlert.window.destroy)
		end
		eventAlert.window = nil
	end
end

function buildEventChip()
	if not eventAlert or eventAlert.chip then
		return
	end
	-- Small SQUARE chip in the game's procedural button style: sharp corners (no UICorner),
	-- surface fill + 1px border + subtle vertical gradient, amber accent to read as an alert.
	local SIZE = 44
	local chip = Instance.new("TextButton")
	chip.Name = "EventAlert"
	chip.AnchorPoint = Vector2.new(0, 1)
	chip.Position = UDim2.new(0, 16, 1, -(16 + 96 + 10)) -- just above the 96px country bar
	chip.Size = UDim2.fromOffset(SIZE, SIZE)
	chip.BackgroundTransparency = 1
	chip.AutoButtonColor = false
	chip.Text = ""
	chip.ZIndex = 41
	chip:SetAttribute("AoWInputSink", true)
	chip.Parent = layers.Hud

	local bg = Instance.new("Frame")
	bg.Name = "Bg"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Colors.SurfaceElevated
	bg.BorderSizePixel = 0
	bg.ZIndex = chip.ZIndex
	bg.Parent = chip
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(225, 225, 225)),
	})
	grad.Parent = bg
	local stroke = Instance.new("UIStroke")
	stroke.Color = Colors.Warning
	stroke.Thickness = 1.5
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = bg

	local bang = Instance.new("TextLabel")
	bang.Name = "Bang"
	bang.AnchorPoint = Vector2.new(0.5, 0.5)
	bang.Position = UDim2.fromScale(0.5, 0.5)
	bang.Size = UDim2.fromScale(1, 1)
	bang.BackgroundTransparency = 1
	bang.Text = "!"
	bang.TextColor3 = Colors.Warning
	bang.Font = Enum.Font.GothamBold
	bang.TextSize = 26
	bang.ZIndex = chip.ZIndex + 1
	bang.Parent = chip

	-- gentle border pulse so the alert catches the eye
	pcall(function()
		game:GetService("TweenService")
			:Create(
				stroke,
				TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ Transparency = 0.55 }
			)
			:Play()
	end)

	chip.MouseEnter:Connect(function()
		bg.BackgroundColor3 = Colors.SurfaceOverlay
	end)
	chip.MouseLeave:Connect(function()
		bg.BackgroundColor3 = Colors.SurfaceElevated
	end)
	chip.MouseButton1Click:Connect(function()
		openEventWindow()
	end)
	eventAlert.chip = chip
end

function openEventWindow()
	if not eventAlert then
		return
	end
	destroyEventChip()
	if eventAlert.window then
		return
	end
	local mod = Screens:FindFirstChild("EventCard")
	if not mod then
		return
	end
	local ok, screen = pcall(require, mod)
	if not ok or type(screen) ~= "table" or not screen.create then
		warn("[AoW Hud] EventCard failed: " .. tostring(screen))
		return
	end
	local ev = eventAlert.event
	eventAlert.window = screen.create(mergedCtx({
		parent = layers.Notifications, -- non-blocking layer → no scrim, map stays interactive
		data = {
			title = ev.title,
			body = ev.body,
			options = ev.options,
			onChoose = function(optionId)
				if ev.onChoose then
					ev.onChoose(optionId)
				end
			end,
			onMinimize = function()
				if eventAlert then
					eventAlert.window = nil
					buildEventChip() -- collapse back to the "!" alert
				end
			end,
		},
	}))
end

function Hud.showEventAlert(event)
	if not started then
		return
	end
	if eventAlert and eventAlert.event and eventAlert.event.eventId == event.eventId then
		return -- already alerting this event
	end
	Hud.hideEventAlert()
	eventAlert = { event = event }
	buildEventChip()
end

function Hud.hideEventAlert()
	destroyEventWindow()
	destroyEventChip()
	eventAlert = nil
end

function Hud.isStarted()
	return started
end

return Hud
