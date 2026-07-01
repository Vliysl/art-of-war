local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

-- ConfigService (Roblox "Configs & Experiments", 2025) is SERVER-ONLY. This module lives in ServerStorage
-- and is required only by server scripts, so that is fine. Acquire it defensively: if the running build
-- predates ConfigService, we simply fall back to the hardcoded dev list below (never a hard error).
local ConfigService
do
	local ok, svc = pcall(function()
		return game:GetService("ConfigService")
	end)
	if ok then
		ConfigService = svc
	end
end

local EditorAdmins = {}

-- ACCESS IS CONFIG-DRIVEN. To grant/revoke Data Editor access you edit ONE JSON config in the Creator Hub
-- (Configs & Experiments) named CONFIG_KEY and press Publish — NO place republish is required (changes reach
-- live servers within ~5 min, and this module also refreshes automatically). The config value is a JSON
-- object of two user-id lists:
--     { "managers": [111, 222], "historians": [333, 444] }
--   * historians  -> mapper tier: may use the editor, paint the map, edit provinces/countries/identity, and
--                    author formables, and Save. This is the tier for our dedicated mappers.
--   * managers    -> full tier: everything a historian can do PLUS the destructive/admin actions
--                    (v3->v4 migration, named-config load/delete, granting session access). Optional — the
--                    dev team below already has this. Grant it sparingly; those actions can replace the world.
-- Ids may be numbers or numeric strings, and each list may instead be a map form { ["111"] = true }.
EditorAdmins.CONFIG_KEY = "data_editor_access"

-- MASTER GATE for the legacy RoN-style owner suite (VIP private-server owners + in-game session grants).
-- Config-driven managers/historians and the dev list below are honored regardless of this flag; only the
-- VIP-owner path and the in-game grant/revoke buttons depend on it. Flip to true to enable that suite.
EditorAdmins.OWNER_SUITE_ENABLED = false

-- Hardcoded fallback: the core dev team. ALWAYS managers, even if the config is empty, malformed, or the
-- config service is unavailable. This is the lockout safety net (a bad config can never lock the team out),
-- NOT the everyday grant path — add mappers via the CONFIG_KEY config, not here.
EditorAdmins.userIds = {
	[1878164020] = true,
	[609222585] = true,
}

-- Session-scoped grants (RoN-style, only honored when OWNER_SUITE_ENABLED): a manager can grant other
-- players editor access at runtime. Not persisted — reset on restart, never touch the DataStore.
local granted = {}

-- Config-derived sets, refreshed live from the CONFIG_KEY config (see loadConfig below).
local configManagers = {}
local configHistorians = {}
local configLoaded = false
local snapshot

-- Fired after each config (re)load so callers (e.g. Bootstrap) can react to a live access change.
local accessChangedCallbacks = {}
local function fireAccessChanged()
	for _, cb in ipairs(accessChangedCallbacks) do
		task.spawn(cb)
	end
end

local function isPlayer(player)
	return player and typeof(player) == "Instance" and player:IsA("Player")
end

-- Coerce one list (array of ids, array of numeric strings, or a { [id]=true } map) into a { [userId]=true } set.
local function toIdSet(list)
	local set = {}
	if type(list) ~= "table" then
		return set
	end
	for _, v in ipairs(list) do
		local id = tonumber(v)
		if id then
			set[id] = true
		end
	end
	for k, v in pairs(list) do
		if v == true then
			local id = tonumber(k)
			if id then
				set[id] = true
			end
		end
	end
	return set
end

-- The config value may arrive as a parsed Lua table OR as a JSON string (the docs don't guarantee which),
-- so normalize both into a Lua table before reading it.
local function normalize(raw)
	if type(raw) == "string" then
		local ok, decoded = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		if ok then
			return decoded
		end
		return nil
	end
	return raw
end

-- Re-read the cached snapshot into the manager/historian sets. Never throws; on any failure the sets stay
-- empty and only the hardcoded dev list / Studio / creator remain (fail-closed for everyone else).
local function applySnapshot()
	local managers, historians = {}, {}
	if snapshot then
		local ok, raw = pcall(function()
			return snapshot:GetValue(EditorAdmins.CONFIG_KEY)
		end)
		if ok then
			local data = normalize(raw)
			if type(data) == "table" then
				managers = toIdSet(data.managers)
				historians = toIdSet(data.historians)
			end
		end
	end
	configManagers = managers
	configHistorians = historians
	fireAccessChanged()
end

local function connectLiveUpdates(snap)
	-- Refresh the cache whenever the config changes live so grant/revoke takes effect without a republish
	-- and without waiting for the periodic backstop.
	local function onUpdate()
		pcall(function()
			snap:Refresh()
		end)
		applySnapshot()
	end
	pcall(function()
		if snap.UpdateAvailable then
			snap.UpdateAvailable:Connect(onUpdate)
		end
	end)
	pcall(function()
		local sig = snap:GetValueChangedSignal(EditorAdmins.CONFIG_KEY)
		if sig then
			sig:Connect(onUpdate)
		end
	end)
end

-- Fetch the config snapshot once and wire up live updates. GetConfigAsync yields and can throw, so this is
-- pcall'd and called off the hot path (never from isAllowed/canManage). Returns true once a snapshot exists.
local function loadConfig()
	if not ConfigService then
		return false
	end
	if snapshot then
		pcall(function()
			snapshot:Refresh()
		end)
		applySnapshot()
		return true
	end
	local ok, snap = pcall(function()
		return ConfigService:GetConfigAsync()
	end)
	if ok and snap then
		snapshot = snap
		applySnapshot()
		connectLiveUpdates(snap)
		configLoaded = true
		return true
	end
	return false
end

-- Force a fresh read (exposed for the editor's Access tab / manual reloads).
function EditorAdmins.reload()
	return loadConfig()
end

-- Subscribe to access-list changes (fired after each config (re)load). Used by Bootstrap to re-stamp the
-- per-player IsAdmin attribute so config-only managers/mappers get it once the snapshot lands / on live edits.
function EditorAdmins.onAccessChanged(cb)
	if type(cb) == "function" then
		accessChangedCallbacks[#accessChangedCallbacks + 1] = cb
	end
end

-- Official managers that never depend on the config: Studio, the game's creator, and the hardcoded dev list.
local function isOfficialManager(player)
	if not isPlayer(player) then
		return false
	end
	if RunService:IsStudio() then
		return true
	end
	if game.CreatorType == Enum.CreatorType.User then
		if player.UserId == game.CreatorId then
			return true
		end
	elseif game.CreatorType == Enum.CreatorType.Group then
		-- Group-owned place: the group owner (rank 255) is always a manager. pcall-guarded so a failed rank
		-- lookup falls through to the dev list rather than throwing. Other group admins get access via the
		-- config, not automatically.
		local ok, rank = pcall(function()
			return player:GetRankInGroup(game.CreatorId)
		end)
		if ok and rank == 255 then
			return true
		end
	end
	return EditorAdmins.userIds[player.UserId] == true
end

-- A config-listed historian (mapper tier). Config-driven, honored regardless of OWNER_SUITE_ENABLED.
local function isConfigHistorian(player)
	return isPlayer(player) and configHistorians[player.UserId] == true
end

-- Managers can use the editor AND run the destructive/admin actions and manage who else can. Official
-- managers always qualify; config-listed managers qualify; the VIP private-server owner qualifies only when
-- the owner suite is enabled.
function EditorAdmins.canManage(player)
	if isOfficialManager(player) then
		return true
	end
	if isPlayer(player) and configManagers[player.UserId] == true then
		return true
	end
	if EditorAdmins.OWNER_SUITE_ENABLED and isPlayer(player) then
		if game.PrivateServerOwnerId ~= 0 and player.UserId == game.PrivateServerOwnerId then
			return true
		end
	end
	return false
end

-- Anyone who may use the editor: a manager, a config-listed historian, or (only when the suite is on) a
-- session-granted player.
function EditorAdmins.isAllowed(player)
	if EditorAdmins.canManage(player) then
		return true
	end
	if isConfigHistorian(player) then
		return true
	end
	if EditorAdmins.OWNER_SUITE_ENABLED and isPlayer(player) then
		return granted[player.UserId] == true
	end
	return false
end

-- "manager" | "historian" | "none" — for display in the Access tab / server logs.
function EditorAdmins.classify(player)
	if EditorAdmins.canManage(player) then
		return "manager"
	end
	if isConfigHistorian(player) then
		return "historian"
	end
	if EditorAdmins.OWNER_SUITE_ENABLED and isPlayer(player) and granted[player.UserId] == true then
		return "granted"
	end
	return "none"
end

-- Snapshot of the effective access config (for the editor's Access tab and diagnostics).
function EditorAdmins.getAccessInfo()
	local managers, historians = {}, {}
	for id in pairs(configManagers) do
		managers[#managers + 1] = id
	end
	for id in pairs(configHistorians) do
		historians[#historians + 1] = id
	end
	local devIds = {}
	for id in pairs(EditorAdmins.userIds) do
		devIds[#devIds + 1] = id
	end
	return {
		configKey = EditorAdmins.CONFIG_KEY,
		configLoaded = configLoaded,
		configAvailable = ConfigService ~= nil,
		managers = managers,
		historians = historians,
		devUserIds = devIds,
		ownerSuiteEnabled = EditorAdmins.OWNER_SUITE_ENABLED,
	}
end

function EditorAdmins.grant(userId)
	userId = tonumber(userId)
	if userId then
		granted[userId] = true
	end
	return userId ~= nil
end

function EditorAdmins.revoke(userId)
	userId = tonumber(userId)
	if userId then
		granted[userId] = nil
	end
	return userId ~= nil
end

function EditorAdmins.isGranted(userId)
	userId = tonumber(userId)
	return userId ~= nil and granted[userId] == true
end

-- Kick off the config load during a real session. Retry a few times in case ConfigService isn't ready at
-- boot, then keep a slow backstop refresh (configs propagate in ~5 min; the live events above normally beat
-- this, so it's just a safety net). Guarded to IsRunning so transient edit-mode requires don't spin a loop.
if ConfigService and RunService:IsRunning() then
	task.spawn(function()
		for _ = 1, 5 do
			if loadConfig() then
				break
			end
			task.wait(5)
		end
		while true do
			task.wait(300)
			loadConfig()
		end
	end)
end

return EditorAdmins
