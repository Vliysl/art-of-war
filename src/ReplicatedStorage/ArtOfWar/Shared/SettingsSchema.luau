-- SettingsSchema -- the single allowlist of per-user client settings that persist across sessions, shared by
-- the server SettingsStore (load / apply / validate) and the client SettingsSync (watch / save) so the
-- watched set and the persisted set can never drift. Every entry is a LocalPlayer attribute the player edits
-- in SettingsScreen; `kind` is "boolean" or "number" (numbers carry a clamp range whose single source is
-- MusicTracks / WorldConstants). validate() rejects a wrong type and clamps a number into range, so a tampered
-- SaveClientSettings remote can never write a garbage or out-of-range attribute.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local WorldConstants = require(aow:WaitForChild("Shared"):WaitForChild("WorldConstants"))
local MusicTracks = require(aow:WaitForChild("Data"):WaitForChild("MusicTracks"))

local SettingsSchema = {}

-- Sentinel LocalPlayer attribute the server sets AFTER it has applied the loaded values; the client waits on
-- it so the audio/render controllers read restored values instead of seeding a default (see
-- SettingsSync.awaitLoaded). Not itself persisted or watched.
SettingsSchema.ReadyAttribute = "AoWSettingsLoaded"

-- Names mirror SettingsScreen's SetAttribute calls exactly. Ordered so an apply/save pass is deterministic.
SettingsSchema.Allow = {
	{ name = "MusicVolume", kind = "number", min = MusicTracks.VolumeMin, max = MusicTracks.VolumeMax },
	{
		name = "RenderDistance",
		kind = "number",
		min = WorldConstants.RenderDistanceMin,
		max = WorldConstants.RenderDistanceMax,
	},
	{ name = "MusicMuted", kind = "boolean" },
	{ name = "SoundMuted", kind = "boolean" },
	{ name = "MuteEventAudio", kind = "boolean" },
	{ name = "ReduceMotion", kind = "boolean" },
	{ name = "InvertDrag", kind = "boolean" },
	{ name = "DisableTooltips", kind = "boolean" },
	{ name = "ShowWatermark", kind = "boolean" },
	{ name = "HideOtherCustomColors", kind = "boolean" },
}

-- (ok, value): validate `raw` against `entry`, coercing a number into its clamp range. Rejects wrong types
-- and NaN/inf so nothing invalid is ever applied to a Player or written to the store.
function SettingsSchema.validate(entry, raw)
	if entry.kind == "boolean" then
		if type(raw) == "boolean" then
			return true, raw
		end
		return false
	elseif entry.kind == "number" then
		if type(raw) ~= "number" or raw ~= raw or raw == math.huge or raw == -math.huge then
			return false
		end
		return true, math.clamp(raw, entry.min, entry.max)
	end
	return false
end

return SettingsSchema
