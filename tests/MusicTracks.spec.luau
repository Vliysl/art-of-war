-- Pure unit tests for Data/MusicTracks resolvers. Dev-only (outside src/, so Rojo never syncs it into the
-- game). Run from the repo root: lune run tests/MusicTracks.spec.luau
-- MusicTracks is dependency-free pure Luau, so it loads under lune with zero Roblox runtime.

local MusicTracks = require("../src/ReplicatedStorage/ArtOfWar/Data/MusicTracks")

local passed, failed = 0, 0
local function check(name, cond)
	if cond then
		passed += 1
	else
		failed += 1
		print("  FAIL: " .. name)
	end
end

local function last(t)
	return t[#t]
end
local function contains(t, v)
	for _, x in ipairs(t) do
		if x == v then
			return true
		end
	end
	return false
end
local function count(t, v)
	local n = 0
	for _, x in ipairs(t) do
		if x == v then
			n += 1
		end
	end
	return n
end

-- The shipped theme maps should have no orphan keys (every RHS has a Tracks.peacetime column).
check("validate() clean", #MusicTracks.validate() == 0)
check("PhaseOrder has 7 phases", #MusicTracks.PhaseOrder == 7)

-- regionKeysFor: nil country -> {default}; always ends in default; specificity order; dedup.
do
	local keys = MusicTracks.regionKeysFor(nil, nil)
	check("nil country -> {default}", #keys == 1 and keys[1] == MusicTracks.DefaultRegionKey)
end
do
	local c = { tag = "FRA", primaryCulture = "french", technologyGroup = "western", capitalProvinceId = 1 }
	local keys = MusicTracks.regionKeysFor(c, function()
		return { superRegionId = "europe" }
	end)
	check("ends with default", last(keys) == MusicTracks.DefaultRegionKey)
	check("culture is most specific", keys[1] == "france")
	check("geo/tech theme present", contains(keys, "europe"))
	check("europe deduped (geo + tech collapse)", count(keys, "europe") == 1)
end
do
	local saved = MusicTracks.ThemeOverrideByTag.ZZZ
	MusicTracks.ThemeOverrideByTag.ZZZ = "ottoman"
	local keys = MusicTracks.regionKeysFor({ tag = "ZZZ", primaryCulture = "french", technologyGroup = "western" }, nil)
	check("per-tag override wins", keys[1] == "ottoman")
	MusicTracks.ThemeOverrideByTag.ZZZ = saved
end

-- pickTrack: everything blank today -> ""; unknown phase -> "".
do
	local keys = { "france", "europe", "default" }
	check("all-blank peacetime -> ''", MusicTracks.pickTrack("peacetime", keys) == "")
	check("unknown phase -> ''", MusicTracks.pickTrack("nonsense", keys) == "")
end

-- resolveCell: region-specificity + playlist + disabled-skip + fallback (inject temp tracks, then restore).
do
	local saved = MusicTracks.Tracks.peacetime.europe
	MusicTracks.Tracks.peacetime.europe = { "rbxassetid://111", "rbxassetid://222" }
	local keys = { "france", "europe", "default" } -- france blank -> europe playlist
	local cellKey, descriptors = MusicTracks.resolveCell("peacetime", keys)
	check("resolveCell finds europe cell", cellKey == "peacetime:europe" and #descriptors == 2)
	check("pickTrack returns first entry", MusicTracks.pickTrack("peacetime", keys) == "rbxassetid://111")
	local disabled = { ["rbxassetid://111"] = true }
	local isDis = function(id)
		return disabled[id] == true
	end
	check("disabled first -> second", MusicTracks.pickTrack("peacetime", keys, isDis) == "rbxassetid://222")
	disabled["rbxassetid://222"] = true
	check("all disabled -> fallback ''", MusicTracks.pickTrack("peacetime", keys, isDis) == "")
	MusicTracks.Tracks.peacetime.europe = saved
end

-- Phase descent: battle -> war -> peacetime; menu is an island; loading falls to menu.
do
	local saved = MusicTracks.Tracks.peacetime.default
	MusicTracks.Tracks.peacetime.default = "rbxassetid://bed"
	check("battle descends to peacetime bed", MusicTracks.pickTrack("battle", { "default" }) == "rbxassetid://bed")
	check("battle_losing descends too", MusicTracks.pickTrack("battle_losing", { "default" }) == "rbxassetid://bed")
	check("menu does NOT inherit peacetime", MusicTracks.pickTrack("menu", { "default" }) == "")
	MusicTracks.Tracks.peacetime.default = saved
end

-- Rich descriptor: gain + loopRegion parse.
do
	local saved = MusicTracks.Tracks.war.default
	MusicTracks.Tracks.war.default = { id = "rbxassetid://w", gain = 0.7, loopRegion = { 2, 90 } }
	local _, d = MusicTracks.resolveCell("war", { "default" })
	check("descriptor gain parsed", d[1] ~= nil and d[1].gain == 0.7)
	check("descriptor loopRegion parsed", d[1] ~= nil and d[1].loop[1] == 2 and d[1].loop[2] == 90)
	MusicTracks.Tracks.war.default = saved
end

-- Stings resolve by event key.
do
	local saved = MusicTracks.Stings["battle.won"]
	MusicTracks.Stings["battle.won"] = "rbxassetid://sting"
	local d = MusicTracks.resolveSting("battle.won")
	check("sting resolves", d ~= nil and d.id == "rbxassetid://sting")
	check("unknown sting -> nil", MusicTracks.resolveSting("no.such.event") == nil)
	MusicTracks.Stings["battle.won"] = saved
end

print(string.format("MusicTracks.spec: %d passed, %d failed", passed, failed))
if failed > 0 then
	error(failed .. " test(s) failed")
end
