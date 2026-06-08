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

local NotificationChannel = Remotes and Remotes:WaitForChild("NotificationChannel", 120)
if NotificationChannel then
	NotificationChannel.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then return end
		local uiFolder = aow:FindFirstChild("UI")
		local uiModule = uiFolder and uiFolder:FindFirstChild("UIController")
		if uiModule then
			local ok, UI = pcall(require, uiModule)
			if ok and UI and UI.notify then
				UI.notify({
					title = payload.title,
					body = payload.body,
					kind = payload.kind,
					ttl = payload.ttl,
				})
			end
		end
	end)
end

safeCall(SimClock, "start")
safeCall(SprintController, "start")
safeCall(MapModeController, "start")
safeCall(ChatCommands, "start")

local UIController = nil
local uiFolder = aow:FindFirstChild("UI")
if uiFolder then
	local uiModule = uiFolder:FindFirstChild("UIController")
	if uiModule then
		local ok, loaded = pcall(require, uiModule)
		if ok then UIController = loaded end
	end
end
safeCall(UIController, "start")

task.spawn(function()
	local uiFolder = aow:FindFirstChild("UI")
	local builderMod = uiFolder and uiFolder:FindFirstChild("UIBuilder")
	if not builderMod then return end
	local ok, builder = pcall(require, builderMod)
	if ok and builder and builder.preloadHoverAssets then
		builder.preloadHoverAssets()
	end
end)

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

if Remotes then
	local Command = Remotes:FindFirstChild("Command")
	if Command then Command:FireServer("ready") end
end
