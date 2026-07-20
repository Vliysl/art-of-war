-- SettingsSync (client) -- bridges the per-user settings the player changes in SettingsScreen to the server
-- SettingsStore for cross-session persistence. Client attributes never replicate upward, so the
-- SaveClientSettings remote is the ONLY way the server learns a changed setting. awaitLoaded() blocks
-- (bounded) until the server has applied the saved values and set its sentinel, so the audio/render
-- controllers read restored values instead of briefly seeding a default; start() then watches the
-- SettingsSchema allowlist of LocalPlayer attributes and, debounced, ships their current values to the
-- server. Both are no-ops unless WorldConstants.PersistClientSettings is on, so with the flag off the client
-- behaves exactly as before.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local WorldConstants = require(aow:WaitForChild("Shared"):WaitForChild("WorldConstants"))
local SettingsSchema = require(aow:WaitForChild("Shared"):WaitForChild("SettingsSchema"))

local SettingsSync = {}

local SAVE_REMOTE = "SaveClientSettings"
local DEBOUNCE = 1 -- coalesce a burst of changes (e.g. dragging the volume slider) into one save
local LOAD_TIMEOUT = 5 -- bounded like every ClientBoot gate: a slow/absent store must not hang boot

local started = false
local flushToken = 0
local saveRemote = nil

local function enabled()
	return WorldConstants.PersistClientSettings == true
end

local function remote()
	if saveRemote and saveRemote.Parent then
		return saveRemote
	end
	local remotes = aow:FindFirstChild("Remotes")
	saveRemote = remotes and remotes:FindFirstChild(SAVE_REMOTE)
	return saveRemote
end

-- Ship the current value of every SET allowlisted attribute. The server merges + re-validates, so sending the
-- live snapshot (rather than a diff) is simplest and self-healing.
local function flush()
	local lp = Players.LocalPlayer
	if not lp then
		return
	end
	local r = remote()
	if not r then
		return
	end
	local snapshot = {}
	for _, entry in SettingsSchema.Allow do
		local value = lp:GetAttribute(entry.name)
		if value ~= nil then
			snapshot[entry.name] = value
		end
	end
	if next(snapshot) then
		r:FireServer(snapshot)
	end
end

local function scheduleFlush()
	flushToken += 1
	local myToken = flushToken
	task.delay(DEBOUNCE, function()
		if myToken == flushToken then
			flush()
		end
	end)
end

-- Called BEFORE the audio/render controllers start: wait until the server has applied the saved settings
-- (sentinel attribute) so those controllers read restored values, not freshly-seeded defaults.
function SettingsSync.awaitLoaded()
	if not enabled() then
		return
	end
	local lp = Players.LocalPlayer
	if not lp then
		return
	end
	local ready = SettingsSchema.ReadyAttribute
	local deadline = os.clock() + LOAD_TIMEOUT
	while lp:GetAttribute(ready) ~= true and os.clock() < deadline do
		task.wait(0.05)
	end
end

-- Called AFTER the controllers have applied/seeded their attributes: watch the allowlist and debounce-save
-- genuine changes. Connecting here (after awaitLoaded) means the server's join-time apply-writes already
-- happened, so they never echo back as saves.
function SettingsSync.start()
	if started or not enabled() then
		return
	end
	local lp = Players.LocalPlayer
	if not lp then
		return
	end
	started = true
	for _, entry in SettingsSchema.Allow do
		lp:GetAttributeChangedSignal(entry.name):Connect(scheduleFlush)
	end
end

return SettingsSync
