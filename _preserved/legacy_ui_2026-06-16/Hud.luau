local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local UI = script.Parent
local ArtOfWar = UI.Parent
local DesignSystem = require(ArtOfWar.DesignSystem)
local Responsive = DesignSystem.Responsive
local Spacing = DesignSystem.Spacing

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
	[Enum.KeyCode.Four] = "Research",
	[Enum.KeyCode.Five] = "Missions",
}
local SCREEN_MODULES = {
	Politics = "PoliticsScreen",
	Economy = "EconomyScreen",
	Military = "MilitaryScreen",
	Research = "ResearchScreen",
	Missions = "MissionsScreen",
}

local started = false
local layers = {}
local widgets = {}
local handlers = {}
local notifications = {}
local activeScreen = nil
local countryData = {}

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
		speed = opts.speed or 3,
		paused = opts.paused or false,
		onPause = function(p)
			if handlers.onPause then
				handlers.onPause(p)
			end
		end,
		onSpeedChange = function(s)
			if handlers.onSpeed then
				handlers.onSpeed(s)
			end
		end,
	})

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
end

local function bindHotkeys()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		local code = input.KeyCode
		if code == Enum.KeyCode.Escape then
			Hud.closeScreen()
			Hud.closeProvince()
		elseif code == Enum.KeyCode.Space then
			if widgets.topBar then
				widgets.topBar.togglePause()
			end
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
		buildCountryBar()
	end
end

function Hud.setClock(date, speed, paused)
	if not widgets.topBar then
		return
	end
	if date ~= nil then
		widgets.topBar.setDate(date)
	end
	if speed ~= nil then
		widgets.topBar.setSpeed(speed)
	end
	if paused ~= nil then
		widgets.topBar.setPaused(paused)
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
	local handle = screen.create({
		parent = layers.Screens,
		modalLayer = layers.Modals,
		data = props or countryData,
		handlers = handlers,
		onClose = function()
			Hud.closeScreen()
		end,
	})
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

local activeProvince = nil
local nationSelect = nil

function Hud.openProvince(provinceData)
	if not started then
		return
	end
	Hud.closeProvince()
	local mod = Screens:FindFirstChild("ProvinceOverview")
	if not mod then
		return
	end
	local ok, screen = pcall(require, mod)
	if not ok or type(screen) ~= "table" or not screen.create then
		warn("[AoW Hud] ProvinceOverview failed: " .. tostring(screen))
		return
	end
	activeProvince = screen.create({
		parent = layers.Screens,
		data = provinceData,
		handlers = handlers,
		onClose = function()
			Hud.closeProvince()
		end,
	})
	return activeProvince
end

function Hud.closeProvince()
	if not activeProvince then
		return
	end
	local handle = activeProvince
	activeProvince = nil
	if handle.destroy then
		handle.destroy()
	elseif handle.root then
		handle.root:Destroy()
	end
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
	nationSelect = screen.create({ parent = layers.Modals, data = opts })
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
	return screen.create({ parent = layers.Modals, data = treaty, onClose = function() end })
end

function Hud.isStarted()
	return started
end

return Hud
