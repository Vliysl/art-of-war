-- SettingsStore -- per-user persistence of the client settings a player controls in SettingsScreen (music
-- volume/mute, sound mute, formation audio, reduce motion, build watermark, tooltips, render distance, invert
-- drag, hide-others'-colors). On join it loads the saved allowlist and RE-APPLIES each value as a LocalPlayer
-- attribute BEFORE the client's controllers read them -- MusicController / UISound / RenderDistanceController
-- each seed a default only when their attribute is unset, so the restored value has to land first -- then sets
-- the SettingsSchema.ReadyAttribute sentinel the client waits on (SettingsSync). The client mirrors later
-- changes back over the SaveClientSettings remote (debounced client-side); this store re-validates every field
-- against SettingsSchema, coalesces writes per player, and flushes on PlayerRemoving / BindToClose. All
-- DataStore access is pcall-wrapped, so a store outage or a no-API-access Studio session degrades to
-- session-only (today's behavior) and never breaks boot. Gated by WorldConstants.PersistClientSettings
-- (default off): with the flag off, register() is a no-op -- nothing is loaded, applied, or saved. Modeled on
-- FormationRecordStore.

local SettingsStore = {}

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SettingsSchema = require(ReplicatedStorage.ArtOfWar.Shared.SettingsSchema)

local STORE_NAME = "AoW_ClientSettings"
local STORE_SCOPE = "v1"
local FLUSH_DELAY = 6

local records = {} -- userId -> { attrName = value } : the authoritative persisted record while the player is online
local dirty = {} -- userId -> true when the record changed since the last write
local flushScheduled = {} -- userId -> true while a coalescing flush is pending

local function keyFor(userId)
	return "u_" .. tostring(userId)
end

local function store()
	return DataStoreService:GetDataStore(STORE_NAME, STORE_SCOPE)
end

local function writeNow(userId)
	dirty[userId] = nil
	local record = records[userId]
	if not record then
		return
	end
	pcall(function()
		store():SetAsync(keyFor(userId), record)
	end)
end

local function persist(userId)
	dirty[userId] = true
	if flushScheduled[userId] then
		return
	end
	flushScheduled[userId] = true
	task.delay(FLUSH_DELAY, function()
		flushScheduled[userId] = nil
		if dirty[userId] then
			writeNow(userId)
		end
	end)
end

-- Keep only allowlisted, correctly-typed, in-range fields from an arbitrary table (a raw remote payload or a
-- raw DataStore blob): nothing else can reach a Player attribute or the store.
local function sanitize(raw)
	local clean = {}
	if type(raw) ~= "table" then
		return clean
	end
	for _, entry in SettingsSchema.Allow do
		local ok, value = SettingsSchema.validate(entry, raw[entry.name])
		if ok then
			clean[entry.name] = value
		end
	end
	return clean
end

local function loadFor(player)
	local userId = player.UserId
	local ok, data = pcall(function()
		return store():GetAsync(keyFor(userId))
	end)
	local record = (ok and type(data) == "table") and sanitize(data) or {}
	-- The player may have left while GetAsync yielded; handleLeave already ran, so don't leave a lingering
	-- record behind (set it only once we know they're still here).
	if player.Parent ~= Players then
		return
	end
	records[userId] = record
	-- Apply the restored values, THEN the sentinel, with no yield between, so the client sees the settings
	-- attributes at or before the sentinel it waits on.
	for _, entry in SettingsSchema.Allow do
		local value = record[entry.name]
		if value ~= nil then
			player:SetAttribute(entry.name, value)
		end
	end
	player:SetAttribute(SettingsSchema.ReadyAttribute, true)
end

-- Remote entry (bound in Bootstrap): merge a client's validated settings into its record and schedule a write.
function SettingsStore.save(player, incoming)
	local userId = player.UserId
	local record = records[userId]
	if not record then
		return -- not loaded yet (or already left): ignore rather than write a partial record
	end
	local changed = false
	for name, value in sanitize(incoming) do
		if record[name] ~= value then
			record[name] = value
			changed = true
		end
	end
	if changed then
		persist(userId)
	end
end

local function handleLeave(player)
	local userId = player.UserId
	if dirty[userId] then
		writeNow(userId)
	end
	records[userId] = nil
	dirty[userId] = nil
	flushScheduled[userId] = nil
end

function SettingsStore.register(context)
	if not (context.WorldConstants and context.WorldConstants.PersistClientSettings) then
		return -- flag off: no load / apply / save; behaves exactly as before persistence existed
	end
	Players.PlayerAdded:Connect(loadFor)
	Players.PlayerRemoving:Connect(handleLeave)
	for _, existing in Players:GetPlayers() do
		task.spawn(loadFor, existing) -- GetAsync yields; don't stall register on already-present players
	end
	game:BindToClose(function()
		for userId in dirty do
			writeNow(userId)
		end
	end)
	context.SettingsStore = SettingsStore
end

return SettingsStore
