if not game:IsLoaded() then game.Loaded:Wait() end

local rs = game:GetService("ReplicatedStorage")

local aow = rs:WaitForChild("ArtOfWar")
local mods = aow:WaitForChild("Modules", 10)
if not mods then return end

local function safeRequire(name)
	local module = mods:FindFirstChild(name)
	if not module then
		warn("[ArtOfWar] module not found: " .. name)
		return nil
	end
	local ok, result = pcall(require, module)
	if not ok then
		warn("[ArtOfWar] failed to require " .. name .. ": " .. tostring(result))
		return nil
	end
	return result
end

local function safeCall(mod, method, ...)
	if not mod or not mod[method] then return false end
	local ok, err = pcall(mod[method], ...)
	if not ok then
		warn("[ArtOfWar] " .. method .. " failed: " .. tostring(err))
	end
	return ok
end

local CharacterHandler    = safeRequire("CharacterHandler")
local CameraController    = safeRequire("CameraController")
local MapRenderer         = safeRequire("MapRenderer")
local MapStyling          = safeRequire("MapStyling")
local ProvinceInteraction = safeRequire("ProvinceInteraction")
local ClientStateCache    = safeRequire("ClientStateCache")
local PeerVisibility      = safeRequire("PeerVisibility")
local SprintController    = safeRequire("SprintController")
local MapModeController   = safeRequire("MapModeController")
local ChatCommands        = safeRequire("ChatCommands")
local ArmyView            = safeRequire("ArmyView")
local CombatView          = safeRequire("CombatView")
local SimClock            = safeRequire("SimClock")
local MoveArrowView       = safeRequire("MoveArrowView")

local map = workspace:WaitForChild("ArtOfWarMap", 120)
local provinces = map and map:WaitForChild("Provinces", 120)
if not provinces then return end

local deadline = os.clock() + 60
while #provinces:GetChildren() == 0 and os.clock() < deadline do
	task.wait(0.2)
end

safeCall(CharacterHandler, "start")
safeCall(CameraController, "init")
if CameraController then CameraController.disable() end
safeCall(MapRenderer, "init")

local countries = nil
local countriesMod = aow:FindFirstChild("Data") and aow.Data:FindFirstChild("Countries")
if countriesMod then
	local ok, loaded = pcall(require, countriesMod)
	if ok then countries = loaded end
end

local countryColors, countryNames = {}, {}
if countries then
	for tag, c in countries do
		if c.color then
			countryColors[tag] = Color3.fromRGB(c.color[1], c.color[2], c.color[3])
		end
		countryNames[tag] = c.displayName
	end
end

local Remotes = aow:WaitForChild("Remotes")
local StateSync = Remotes and Remotes:WaitForChild("StateSync", 120)
local RequestFullState = Remotes and Remotes:WaitForChild("RequestFullState", 120)

if StateSync and ClientStateCache then
	StateSync.OnClientEvent:Connect(function(packet)
		ClientStateCache.applyDelta(packet)
	end)
else
	warn(string.format("[ArtOfWar] StateSync wire failed: StateSync=%s cache=%s", tostring(StateSync), tostring(ClientStateCache)))
end

local Hud = nil
do
	local uiFolder = aow:FindFirstChild("UI")
	local hudMod = uiFolder and uiFolder:FindFirstChild("Hud")
	if hudMod then
		local ok, loaded = pcall(require, hudMod)
		if ok then Hud = loaded end
	end
end

-- Preload the ornate panel/pill/tab/notification shell textures before the HUD builds so their
-- 9-slice borders don't render against an undecoded image. Bounded wait behind the loading cover so a
-- slow asset can't hang boot; Shells.create's on-load self-heal backstops anything that lands late.
-- (Buttons no longer use shells -- they're procedural now -- so this only serves the decorative surfaces.)
do
	local ds = aow:FindFirstChild("DesignSystem")
	local shellsMod = ds and ds:FindFirstChild("Shells")
	if shellsMod then
		local ok, Shells = pcall(require, shellsMod)
		if ok and Shells and Shells.preload then
			local done = false
			task.spawn(function()
				Shells.preload()
				done = true
			end)
			local startedAt = os.clock()
			while not done and os.clock() - startedAt < 8 do
				task.wait()
			end
		end
	end
end

local NotificationChannel = Remotes and Remotes:WaitForChild("NotificationChannel", 120)
if NotificationChannel then
	NotificationChannel.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then return end
		if Hud and Hud.notify then
			Hud.notify({
				title = payload.title,
				body = payload.body,
				kind = payload.kind,
				ttl = payload.ttl,
			})
		end
	end)
end

safeCall(SimClock, "start")
safeCall(SprintController, "start")
safeCall(MapModeController, "start")
safeCall(ChatCommands, "start")

do
	local uiFolder = aow:FindFirstChild("UI")
	local wiringMod = uiFolder and uiFolder:FindFirstChild("HudWiring")
	if wiringMod then
		local ok, HudWiring = pcall(require, wiringMod)
		if ok and HudWiring and HudWiring.start then
			local started, err = pcall(function()
				HudWiring.start({
					ClientStateCache = ClientStateCache,
					MapModeController = MapModeController,
					ProvinceInteraction = ProvinceInteraction,
										ArmyView = ArmyView,
					PathPreview = safeRequire("PathPreview"),
					WaterBodies = safeRequire("WaterBodies"),
				})
			end)
			if not started then
				warn("[ArtOfWar] HudWiring.start failed: " .. tostring(err))
			end
		else
			warn("[ArtOfWar] HudWiring require failed: " .. tostring(HudWiring))
		end
	end
end

-- Wire default UI sounds to EVERY ScreenGui (the HUD builds its own ScreenGuis outside UIRoot,
-- so UIRoot.attachAll alone missed them -> no click/hover sounds).
do
	local uiFolder = aow:FindFirstChild("UI")
	local usMod = uiFolder and uiFolder:FindFirstChild("UISound")
	if usMod then
		local ok, UISound = pcall(require, usMod)
		if ok and UISound and UISound.start then pcall(UISound.start) end
	end
end

task.defer(function()
	if RequestFullState and ClientStateCache then
		local ok, snapshot = pcall(function()
			return RequestFullState:InvokeServer()
		end)
		if ok and type(snapshot) == "table" then
			ClientStateCache.applyDelta(snapshot)
		end
	end

	local stampDeadline = os.clock() + 30
	while not map:GetAttribute("provincesStamped") and os.clock() < stampDeadline do
		task.wait(0.1)
	end
	if ClientStateCache and ClientStateCache.allCountries then
		local live = ClientStateCache.allCountries() or {}
		for tag, country in pairs(live) do
			if type(country) == "table" then
				if country.color then
					countryColors[tag] = Color3.fromRGB(country.color[1], country.color[2], country.color[3])
				end
				if type(country.displayName) == "string" and country.displayName ~= "" then
					countryNames[tag] = country.displayName
				end
			end
		end
		if next(live) ~= nil then
			for tag in pairs(countryColors) do
				if not live[tag] then countryColors[tag] = nil end
			end
			for tag in pairs(countryNames) do
				if not live[tag] then countryNames[tag] = nil end
			end
		end
	end
	if MapRenderer then
		MapRenderer.setMode("political", { countryColors = countryColors })
	end
	if MapStyling then
		-- Always rebuild: buildCountryLabels self-destroys any existing folder first, and the
		-- old gate (build only if folder missing) preserved stale content from prior sessions.
		MapStyling.buildCountryLabels(map, countryNames)
		if CameraController then
			MapStyling.startLabelManager(CameraController.getZoom)
		end
		if MapModeController and MapStyling.setEnabled then
			MapStyling.setEnabled(MapModeController.current() == "command")
			MapModeController.onChange(function(mode)
				MapStyling.setEnabled(mode == "command")
			end)
		end
	end
	if map then
		map:SetAttribute("mapPainted", true)
	end
end)

safeCall(ProvinceInteraction, "init")
safeCall(ArmyView, "init")
safeCall(CombatView, "init")
safeCall(MoveArrowView, "init")

if Remotes then
	local Command = Remotes:FindFirstChild("Command")
	if Command then Command:FireServer("ready") end
end
