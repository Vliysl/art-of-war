if not game:IsLoaded() then
	game.Loaded:Wait()
end

local rs = game:GetService("ReplicatedStorage")

local aow = rs:WaitForChild("ArtOfWar")
local mods = aow:WaitForChild("Modules", 10)
if not mods then
	return
end

-- Lock to landscape: the HUD is laid out for landscape, so portrait would break it.
do
	local lp = game:GetService("Players").LocalPlayer
	local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
	if pg then
		pcall(function()
			pg.ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor
		end)
	end
end

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
	if not mod or not mod[method] then
		return false
	end
	local ok, err = pcall(mod[method], ...)
	if not ok then
		warn("[ArtOfWar] " .. method .. " failed: " .. tostring(err))
	end
	return ok
end

local CharacterHandler = safeRequire("CharacterHandler")
local CameraController = safeRequire("CameraController")
local MapRenderer = safeRequire("MapRenderer")
local MapStyling = safeRequire("MapStyling")
local ProvinceInteraction = safeRequire("ProvinceInteraction")
local ClientStateCache = safeRequire("ClientStateCache")
local PeerVisibility = safeRequire("PeerVisibility")
local SprintController = safeRequire("SprintController")
local MapModeController = safeRequire("MapModeController")
local ChatCommands = safeRequire("ChatCommands")
local ArmyView = safeRequire("ArmyView")
local CombatView = safeRequire("CombatView")
local SimClock = safeRequire("SimClock")
local MoveArrowView = safeRequire("MoveArrowView")
local CapitalMarkerView = safeRequire("CapitalMarkerView")
local WorldConstants = require(aow:WaitForChild("Shared"):WaitForChild("WorldConstants"))
local provinceRecolorWired = false

local map = workspace:WaitForChild("ArtOfWarMap", 120)
local provinces = map and map:WaitForChild("Provinces", 120)
if not provinces then
	return
end

local deadline = os.clock() + 60
while #provinces:GetChildren() == 0 and os.clock() < deadline do
	task.wait(0.2)
end

safeCall(CharacterHandler, "start")
safeCall(CameraController, "init")
if CameraController then
	CameraController.disable()
end
safeCall(MapRenderer, "init")

local countries = nil
local countriesMod = aow:FindFirstChild("Data") and aow.Data:FindFirstChild("Countries")
if countriesMod then
	local ok, loaded = pcall(require, countriesMod)
	if ok then
		countries = loaded
	end
end

local CountryColor = safeRequire("CountryColor")
local countryColors, countryNames = {}, {}
if countries then
	for tag, c in countries do
		if c.color then
			countryColors[tag] = (CountryColor and CountryColor.resolve(tag)) or Color3.fromRGB(c.color[1], c.color[2], c.color[3])
		end
		countryNames[tag] = c.displayName
	end
end

local Remotes = aow:WaitForChild("Remotes")
local StateSync = Remotes and Remotes:WaitForChild("StateSync", 120)
local RequestFullState = Remotes and Remotes:WaitForChild("RequestFullState", 120)
local RequestOwnershipDigest = Remotes and Remotes:WaitForChild("RequestOwnershipDigest", 120)

-- Tier 3: the player's own country's politics (leaders/factions) arrive here, stripped from the shared StateSync
-- broadcast to keep the countries payload under the transit limit. Stored separately (PoliticsScreen overlays it).
local OwnPolitics = Remotes and Remotes:WaitForChild("OwnPolitics", 120)
if OwnPolitics and ClientStateCache then
	OwnPolitics.OnClientEvent:Connect(function(packet)
		if type(packet) == "table" then
			ClientStateCache.setOwnPolitics(packet)
		end
	end)
end

-- Fog of war: this player's own armies arrive in full detail here, stripped from the fogged shared StateSync
-- broadcast when EnableFogOfWar is on. ClientStateCache overlays them so own armies show full, enemies fogged.
local OwnArmies = Remotes and Remotes:WaitForChild("OwnArmies", 120)
if OwnArmies and ClientStateCache then
	OwnArmies.OnClientEvent:Connect(function(packet)
		if type(packet) == "table" then
			ClientStateCache.setOwnArmies(packet)
		end
	end)
end

if StateSync and ClientStateCache then
	StateSync.OnClientEvent:Connect(function(packet)
		ClientStateCache.applyDelta(packet)
	end)
else
	warn(
		string.format(
			"[ArtOfWar] StateSync wire failed: StateSync=%s cache=%s",
			tostring(StateSync),
			tostring(ClientStateCache)
		)
	)
end

local Hud = nil
do
	local uiFolder = aow:FindFirstChild("UI")
	local hudMod = uiFolder and uiFolder:FindFirstChild("Hud")
	if hudMod then
		local ok, loaded = pcall(require, hudMod)
		if ok then
			Hud = loaded
		end
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

-- Preload the icon textures the same way (async, non-blocking): each icon is otherwise fetched lazily on
-- first render, so on a cold cache / flaky CDN they intermittently fail to appear. Icons.preload warms them
-- all into the texture cache up-front and retries the odd transient failure.
do
	local ds = aow:FindFirstChild("DesignSystem")
	local iconsMod = ds and ds:FindFirstChild("Icons")
	if iconsMod then
		local ok, Icons = pcall(require, iconsMod)
		if ok and Icons and Icons.preload then
			task.spawn(Icons.preload)
		end
	end
end

-- Nation crests, for the selection screen's first page. BOUNDED-BLOCKING like Shells above, not
-- fire-and-forget like Icons: the whole point is that the crests are in the cache before the first page
-- draws, and this is the last chance to guarantee that -- the screen mounts inside the task.defer below.
-- ~9 static assets, so the wait is short in practice and the cap only bounds a cold/flaky CDN.
if CountryColor and CountryColor.preloadCrests then
	local done = false
	task.spawn(function()
		CountryColor.preloadCrests()
		done = true
	end)
	local startedAt = os.clock()
	while not done and os.clock() - startedAt < 5 do
		task.wait()
	end
end

local NotificationChannel = Remotes and Remotes:WaitForChild("NotificationChannel", 120)
if NotificationChannel then
	NotificationChannel.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		-- Formation/release announcements ride the same channel as toasts but render as a prominent,
		-- non-blocking banner (crest + title + body + dismiss + audio) instead of a corner toast.
		if payload.kind == "superevent" and Hud and Hud.showSuperEvent then
			Hud.showSuperEvent(payload)
			return
		end
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
		if ok and UISound and UISound.start then
			pcall(UISound.start)
		end
	end
end

task.defer(function()
	-- Cinematic intro: start zoomed in (behind the loading screen) so the reveal is a smooth zoom-out
	-- to the wide view once the map has fully loaded (the ease-out happens after mapPainted, below).
	if CameraController and CameraController.snapTo then
		CameraController.snapTo(Vector3.new(0, 0, 0), 250)
	end
	if RequestFullState and ClientStateCache then
		local ok, snapshot = pcall(function()
			return RequestFullState:InvokeServer()
		end)
		if ok and type(snapshot) == "table" then
			ClientStateCache.applyDelta(snapshot)
		end
	end

	-- Self-heal reconcile (OwnershipReconcile): periodically pull the compact server ownership digest and
	-- repair any province whose cached record drifted from the server -- a backstop so a single dropped
	-- ownership delta can never leave a tile/panel permanently stale. Cheap: the digest is owner+controller
	-- only, and reconcileProvinces notifies ONLY the provinces that actually changed.
	if
		WorldConstants.OwnershipReconcile
		and RequestOwnershipDigest
		and ClientStateCache
		and ClientStateCache.reconcileProvinces
	then
		task.spawn(function()
			while true do
				task.wait(15)
				local okD, digest = pcall(function()
					return RequestOwnershipDigest:InvokeServer()
				end)
				if okD and type(digest) == "table" then
					ClientStateCache.reconcileProvinces(digest)
				end
			end
		end)
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
					countryColors[tag] = (CountryColor and CountryColor.resolve(tag))
						or Color3.fromRGB(country.color[1], country.color[2], country.color[3])
				end
				if type(country.displayName) == "string" and country.displayName ~= "" then
					countryNames[tag] = country.displayName
				end
			end
		end
		if next(live) ~= nil then
			for tag in pairs(countryColors) do
				if not live[tag] then
					countryColors[tag] = nil
				end
			end
			for tag in pairs(countryNames) do
				if not live[tag] then
					countryNames[tag] = nil
				end
			end
		end
	end
	if MapRenderer then
		-- Record-driven political coloring (single source of truth): read ownership from the replicated
		-- province RECORD, not the part attributes, so the map can't show a stale owner (the annex /
		-- Mecca / Tibet divergence class). Gated by WorldConstants.RecordDrivenMapColoring; off = the
		-- original attribute path, byte-identical.
		local getProvinceRecord = nil
		if WorldConstants.RecordDrivenMapColoring and ClientStateCache and ClientStateCache.getProvince then
			getProvinceRecord = function(id)
				return ClientStateCache.getProvince(id) or ClientStateCache.getProvince(tonumber(id))
			end
		end
		local function reapplyPolitical()
			-- Only re-sweep while the political map mode is active, so this never overrides a user-selected mode.
			if MapRenderer.getMode and MapRenderer.getMode() ~= "political" then
				return
			end
			MapRenderer.setMode("political", { countryColors = countryColors, getProvinceRecord = getProvinceRecord })
		end
		reapplyPolitical()
		-- Backstop for the high-id / AI-generated tail (HRE + high-id PLC tiles etc.): the sweep above runs
		-- after `provincesStamped` (a SERVER signal), which can precede full client RECORD replication. A
		-- province whose record lands after the sweep -- and whose per-record recolor notify fired before the
		-- subscriber below was wired -- would otherwise stay stuck at its swept (neutral) colour even though
		-- its record (and the panel) are correct. Re-run the full political sweep when the snapshot (re)lands
		-- and a couple of times shortly after so those late records get their colour (equivalent to a
		-- map-mode toggle, but automatic). A sweep is cheap and idempotent.
		if ClientStateCache and ClientStateCache.onChange then
			ClientStateCache.onChange("snapshot", reapplyPolitical)
				ClientStateCache.onChange("provincesReady", reapplyPolitical)
		end
		task.delay(3, reapplyPolitical)
		task.delay(8, reapplyPolitical)
		-- Record-driven mode has no per-part attribute watchers, so drive incremental recolors off the
		-- replicated province delta. (UIController carries a copy of this wiring but is dead in the live
		-- boot path, so it must be wired here.)
		if getProvinceRecord and ClientStateCache.onChangePrefix and not provinceRecolorWired then
			provinceRecolorWired = true
			ClientStateCache.onChangePrefix("provinces", function(_, path)
				local idStr = typeof(path) == "string" and path:match("^provinces%.([^%.]+)")
				if idStr then
					MapRenderer.recolorProvince(idStr)
				end
			end)
		end

		-- Custom Country Colors (+ the viewer's hide toggle) change a country's DISPLAY colour with NO province
		-- delta, so the map needs its own countries hook (the dead UIController carried this; the live boot path
		-- did not). Gated on an ACTUAL colour change -- countries deltas fire every economy tick -- then a full
		-- re-sweep, cheap and rare given the 60s per-player recolor cooldown.
		local function refreshCountryColor(ctag)
			if not ctag then
				return
			end
			local rec = ClientStateCache.getCountry and ClientStateCache.getCountry(ctag)
			local newColor = (rec and CountryColor) and CountryColor.resolve(ctag) or nil
			if newColor == countryColors[ctag] then
				return
			end
			countryColors[ctag] = newColor
			reapplyPolitical()
		end
		if CountryColor and ClientStateCache.onChangePrefix then
			ClientStateCache.onChangePrefix("countries", function(_, path)
				local ctag = typeof(path) == "string" and path:match("^countries%.([^%.]+)")
				if ctag then
					refreshCountryColor(ctag)
				end
			end)
		end
		local hideTogglePlayer = game:GetService("Players").LocalPlayer
		if CountryColor and hideTogglePlayer then
			hideTogglePlayer:GetAttributeChangedSignal("HideOtherCustomColors"):Connect(function()
				for ctag in pairs(countryColors) do
					countryColors[ctag] = CountryColor.resolve(ctag)
				end
				reapplyPolitical()
			end)
		end
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
	-- Tiles are stamped + coloured now; start the render-distance culler (per-device default applied
	-- on first join; XZ-distance tile hiding driven by the Settings slider).
	local RenderDistanceController = safeRequire("RenderDistanceController")
	safeCall(RenderDistanceController, "init")

	-- Preload the CENTER province meshes in the BACKGROUND so the map fills in at ANY zoom instead of
	-- streaming tiles in by camera proximity (far tiles otherwise stay bare ocean until you zoom onto
	-- them, regardless of distance). LeftWrap/RightWrap are clones with identical MeshIds, so warming the
	-- center folder caches their assets too. There are ~5713 unique meshes -- far too many to block the
	-- loading screen on (a 20s+ stall) -- so this runs async: PreloadAsync force-loads every tile
	-- regardless of camera, so they all appear within seconds (cold) or instantly (cached), masked by the
	-- cinematic zoom-out below. This is the real fix; the camera move is just polish.
	local provincesFolder = map and map:FindFirstChild("Provinces")
	if provincesFolder then
		task.spawn(function()
			local toPreload = {}
			for _, p in ipairs(provincesFolder:GetChildren()) do
				if p:IsA("BasePart") then
					toPreload[#toPreload + 1] = p
				end
			end
			if #toPreload > 0 then
				pcall(function()
					game:GetService("ContentProvider"):PreloadAsync(toPreload)
				end)
			end
		end)
	end
	if map then
		map:SetAttribute("mapPainted", true)
	end
	-- Ease the cinematic camera out from the close intro to the default wide view; the background
	-- preload above keeps filling tiles in as the view widens.
	if CameraController and CameraController.setZoom then
		local cfg = CameraController.getConfig and CameraController.getConfig()
		CameraController.setZoom(cfg and cfg.DEFAULT_ZOOM or 990)
	end
end)

safeCall(ProvinceInteraction, "init")
safeCall(ArmyView, "init")
safeCall(CombatView, "init")
safeCall(MoveArrowView, "init")
safeCall(CapitalMarkerView, "init")

if Remotes then
	local Command = Remotes:FindFirstChild("Command")
	if Command then
		Command:FireServer("ready")
	end
end

-- Hold the loading cover until the client is genuinely RENDERED, not just data-ready. The HUD is built
-- synchronously above (HudWiring.start) and the map is painted in the deferred task; the old 2-frame wait
-- was too short, so the HUD/colours hadn't drawn yet and the UI "popped in" after the cover faded. Now:
-- wait for mapPainted, confirm the HUD ScreenGui is present, then let several REAL render frames pass
-- (layout + first GPU draw) before signalling. The loading screen's 75s deadline + Skip are fallbacks.
task.spawn(function()
	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local plr = Players.LocalPlayer

	-- Province RECORDS are chunk-streamed and land independently of the map being painted: `mapPainted` only
	-- tracks the SERVER's province stamping, so it says nothing about whether THIS client has its records yet.
	-- The cover therefore used to lift onto a nation-selection screen where every nation read 0 provinces, the
	-- "biggest realm first" sort was meaningless, every continent filter (bucketed off the capital's province)
	-- returned nothing, and the map highlight was inert -- then the whole list reordered in front of the player.
	-- Subscribing HERE is what makes this safe: task.spawn runs this body synchronously up to the first yield,
	-- so the subscription is registered while the main flow is still running -- and RequestFullState, which is
	-- what makes the server start pushing chunks, lives in the task.defer above and cannot run until the main
	-- flow finishes. The signal can never fire before we are listening for it.
	local provincesReady = false
	local unsubProvinces
	if ClientStateCache and ClientStateCache.onChange then
		unsubProvinces = ClientStateCache.onChange("provincesReady", function()
			provincesReady = true
		end)
	else
		provincesReady = true -- no cache -> nothing to wait for; never block boot on a missing module
	end

	local stopAt = os.clock() + 75
	while os.clock() < stopAt do
		if map and map:GetAttribute("mapPainted") then
			break
		end
		task.wait(0.1)
	end

	-- Bounded like every other gate here (mapPainted 75s, AoW_Hud 5s): a slow or dropped chunk stream must
	-- degrade to "the old behaviour" -- an honest-ish screen a moment early -- never to a black screen.
	-- NationSelection keeps its own provincesReady subscription, which repairs the list if this expires.
	local provDeadline = os.clock() + 20
	while os.clock() < provDeadline and not provincesReady do
		task.wait(0.1)
	end
	if unsubProvinces then
		pcall(unsubProvinces)
	end
	if not provincesReady then
		warn("[AoW Boot] province stream did not complete within 20s -- uncovering with partial province data")
	end
	-- Confirm the persistent HUD ScreenGui exists (built synchronously in the main flow above). Bounded so
	-- a failed HUD build can't hang boot -- the render-frame settle + deadline still uncover the map.
	local pg = plr and plr:FindFirstChildOfClass("PlayerGui")
	if pg then
		local hudDeadline = os.clock() + 5
		while os.clock() < hudDeadline and not pg:FindFirstChild("AoW_Hud") do
			task.wait(0.05)
		end
	end
	-- Several rendered frames so the HUD lays out (UIListLayout / AutomaticSize / UIScale) and the map
	-- colours are actually on-screen before the cover fades.
	for _ = 1, 12 do
		RunService.RenderStepped:Wait()
	end
	if plr then
		plr:SetAttribute("AoWBootComplete", true)
	end
end)
