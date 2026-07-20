-- FormationRecordStore -- the global, persistent "fastest time to form each nation" leaderboard (RON-style).
-- Per formable it keeps the SINGLE best (smallest) time-to-form and who set it, persisted in a DataStore and
-- mirrored to a ReplicatedStorage StringValue (JSON) so the Nation-screen catalog can show "Fastest: <t> by X".
-- "Time to form" = os.time() at formation minus the former's country.claimedAt (stamped in PlayerAuthority).
-- All DataStore access is pcall-wrapped so a store outage / no-API-access Studio degrades to in-memory +
-- replicated only, never breaking boot. UpdateAsync keeps the min so concurrent servers don't clobber a
-- faster record. Mirrors FormableStore's coalesced-write + replicate pattern.

local FormationRecordStore = {}

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local STORE_NAME = "AoW_FormationRecords"
local STORE_SCOPE = "v1"
local KEY = "all"
local FLUSH_DELAY = 6

local ctx
local records = {} -- formableTag -> { seconds, holder, holderTag, at }
local dirty = false
local flushScheduled = false

local function replicate()
	local aow = ReplicatedStorage:FindFirstChild("ArtOfWar")
	if not aow then
		return
	end
	local sv = aow:FindFirstChild("FormationRecordsRuntime")
	if not sv then
		sv = Instance.new("StringValue")
		sv.Name = "FormationRecordsRuntime"
		sv.Parent = aow
	end
	local ok, json = pcall(function()
		return HttpService:JSONEncode(records)
	end)
	sv.Value = ok and json or "{}"
end

-- Merge-write keeping the per-formable MINIMUM across servers, then adopt any faster records the store already
-- holds so our local copy (and replicate) reflects the global best.
local function writeNow()
	dirty = false
	pcall(function()
		DataStoreService:GetDataStore(STORE_NAME, STORE_SCOPE):UpdateAsync(KEY, function(old)
			old = (type(old) == "table") and old or {}
			for tag, rec in pairs(records) do
				local prev = old[tag]
				if type(rec) == "table" and (type(prev) ~= "table" or rec.seconds < prev.seconds) then
					old[tag] = rec
				end
			end
			for tag, rec in pairs(old) do
				local mine = records[tag]
				if type(rec) == "table" and (type(mine) ~= "table" or rec.seconds < mine.seconds) then
					records[tag] = rec
				end
			end
			return old
		end)
	end)
	replicate()
end

local function persist()
	dirty = true
	if flushScheduled then
		return
	end
	flushScheduled = true
	task.delay(FLUSH_DELAY, function()
		flushScheduled = false
		if dirty then
			writeNow()
		end
	end)
end

local function load()
	local ok, data = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME, STORE_SCOPE):GetAsync(KEY)
	end)
	if ok and type(data) == "table" then
		records = data
	end
end

-- On formation, record the former's time-to-form if it beats the current record. data = { tag, formableTag }.
local function onNationFormed(data)
	if not data or not data.tag or not data.formableTag then
		return
	end
	local country = ctx.WorldState.getCountry(data.tag)
	local claimedAt = country and country.claimedAt
	if type(claimedAt) ~= "number" then
		return -- can't time it (unclaimed/AI or a pre-timestamp claim); skip rather than write a bogus record
	end
	local seconds = math.max(0, os.time() - claimedAt)
	local holderName = "A ruler"
	local player = ctx.PlayerAuthority and ctx.PlayerAuthority.playerFor and ctx.PlayerAuthority.playerFor(data.tag)
	if player then
		holderName = player.DisplayName or player.Name
	end
	local prev = records[data.formableTag]
	if type(prev) ~= "table" or seconds < prev.seconds then
		records[data.formableTag] = { seconds = seconds, holder = holderName, holderTag = data.tag, at = os.time() }
		replicate()
		persist()
	end
end

function FormationRecordStore.register(context)
	ctx = context
	load()
	replicate()
	game:BindToClose(function()
		if dirty then
			writeNow()
		end
	end)
	if context.EventBus and context.Channels and context.Channels.NationFormed then
		context.EventBus.subscribe(context.Channels.NationFormed, onNationFormed)
	end
	context.FormationRecordStore = {
		list = function()
			return records
		end,
	}
end

return FormationRecordStore
