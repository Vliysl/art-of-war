-- MusicTracks (client, pure content/config)
-- The ONE file to edit to add/replace music, retune which nations share a theme, or tune fades/holds/volume.
-- Real Roblox audio plugs into the "" placeholders below with ZERO controller changes. Dependency-free
-- (no service/cache requires) so it stays pure + testable (see MusicTracks.spec.luau, runnable under lune).
-- The controller consumes: Phase, PhaseOrder, DefaultRegionKey, VolumeMin/Max, Tuning, regionKeysFor,
-- resolveCell, pickTrack, resolveSting, validate.

local MusicTracks = {}

-- Phase ids -- SHARED with MusicController. Menu/Loading are non-gameplay context; the four gameplay phases
-- (peacetime / war / war_losing / battle / battle_losing) escalate by intensity per PhaseOrder below.
MusicTracks.Phase = {
	Menu = "menu", -- nation-select, before a nation is claimed (region-agnostic)
	Loading = "loading", -- pre-map-ready / boot cover (region-agnostic)
	Peacetime = "peacetime", -- claimed, not at war (region-flavored -- where "your nation" sings)
	War = "war", -- at war, no battle focused, holding or winning
	WarLosing = "war_losing", -- at war and losing (negative war score / high exhaustion)
	Battle = "battle", -- actively engaged in a battle
	BattleLosing = "battle_losing", -- actively engaged and losing the battle (negative viewer tide)
}

-- Escalation order (least -> most intense). RANK in the controller is derived from this index, so phase
-- order lives in ONE place: escalating to a higher-index phase is immediate; dropping to a lower one waits a
-- min-hold (Tuning.HoldByPhase). Menu/Loading are handled as immediate context switches, not by rank.
MusicTracks.PhaseOrder = {
	MusicTracks.Phase.Menu,
	MusicTracks.Phase.Loading,
	MusicTracks.Phase.Peacetime,
	MusicTracks.Phase.War,
	MusicTracks.Phase.WarLosing,
	MusicTracks.Phase.Battle,
	MusicTracks.Phase.BattleLosing,
}

-- Player-facing volume slider range. The DEFAULT lives in WorldConstants.MusicDefaultVolume (single source
-- for the controller's first-join seed + the Settings getter), so it is not duplicated here.
MusicTracks.VolumeMin = 0
MusicTracks.VolumeMax = 1

-- The generic theme key: used for menu/loading and as the last fallback everywhere.
MusicTracks.DefaultRegionKey = "default"

-- Composer-facing tuning (the controller reads these; pure-engine timings like debounce stay in the
-- controller). Fade seconds are per-transition; HoldByPhase is the minimum seconds a phase is held before a
-- de-escalation is allowed (kills thrash from a 1s battle / declare-spam).
MusicTracks.Tuning = {
	FadeDefault = 1.5,
	FadeBattle = 0.8, -- snappier when escalating into a battle
	FadeStop = 0.4, -- fade-out on teardown / stop
	DuckFactor = 0.35, -- music bed gain multiplier while a sting/super-event plays
	DuckFade = 0.25, -- seconds to duck down / restore
	HoldByPhase = {
		[MusicTracks.Phase.War] = 8,
		[MusicTracks.Phase.WarLosing] = 8,
		[MusicTracks.Phase.Battle] = 5,
		[MusicTracks.Phase.BattleLosing] = 5,
	},
}

-- ============================ THEME MAPS (the levers to retune) ============================
-- A nation resolves to an ordered list of THEME KEYS by specificity: per-tag override > culture > geography
-- (the capital's superRegion) > tech group > "default". Author a Tracks cell at whatever granularity you
-- have; unmapped or unauthored levels fall through to the next. Merge nations into one theme by pointing
-- them at the same key; pin a single nation with ThemeOverrideByTag. Theme keys deliberately need NOT match
-- superRegion/culture ids (e.g. africa_sub -> "africa"), so add a Tracks column per key you actually use.

-- Coarse fallback: country.technologyGroup -> theme key. The 6 keys below are the only tech groups assigned
-- in Data/Countries.luau (western/eastern/muslim/sub_saharan/north_american/nomad) -- complete + correct.
MusicTracks.ThemeByTechGroup = {
	western = "europe",
	eastern = "eastern_europe",
	muslim = "near_east",
	sub_saharan = "africa",
	north_american = "north_america",
	nomad = "steppe",
}

-- Geography: capital province's superRegionId -> theme key. All 11 superRegion ids from Data/SuperRegions
-- are listed so no region silently collapses onto the wrong tech-group bed (e.g. an East-Asian nation would
-- otherwise map through tech group "eastern" to the Eastern-European bed). Edit the RHS to re-cluster.
MusicTracks.ThemeBySuperRegion = {
	europe = "europe",
	near_east = "near_east",
	central_asia = "steppe",
	east_asia = "east_asia",
	south_asia = "south_asia",
	southeast_asia = "southeast_asia",
	americas_north = "north_america",
	americas_south = "south_america",
	africa_north = "north_africa",
	africa_sub = "africa",
	oceania = "oceania",
}

-- Most specific: country.primaryCulture -> theme key. Pre-filled with the ~20 cultures actually assigned to
-- countries today (Data/Cultures.luau defines ~270, but only these are in use), clustered to finer culture
-- themes so distinct nations can sound distinct. Repoint any RHS to merge/split; a key with no authored
-- Tracks cell simply falls through to geography/tech.
MusicTracks.ThemeByCulture = {
	french = "france",
	english = "britain",
	castilian = "iberia",
	catalan = "iberia",
	portuguese = "iberia",
	sicilian = "italy",
	dutch = "low_countries",
	austrian = "germany",
	bavarian = "germany",
	hannoverian = "germany",
	prussian = "prussia",
	saxon = "germany",
	danish = "scandinavia",
	swedish = "scandinavia",
	polish = "poland",
	russian = "russia",
	turkish = "ottoman",
	tatar = "steppe",
	akan = "africa",
	iroquoian = "north_america",
}

-- Highest priority: pin ONE nation to any theme regardless of its culture/geo/tech.
MusicTracks.ThemeOverrideByTag = {
	-- ["TUR"] = "ottoman",
}

-- ============================ TRACK TABLE ============================
-- Tracks[phase][themeKey] = leaf, where a leaf is one of:
--   ""                                     -> not authored yet (silent; resolves down the fallback chain)
--   "rbxassetid://<id>"                    -> a single looping bed
--   { "rbxassetid://a", "rbxassetid://b" } -> a PLAYLIST (the controller varies between entries on entry)
--   { id = "rbxassetid://a", gain = 0.8, loopRegion = { 4.0, 92.0 } }  -> a bed with per-track loudness trim
--                                             (gain 0..1) and/or a seamless loop region { startSec, endSec }
--   { { id=..., gain=... }, { id=... } }   -> a playlist of descriptors
-- With every cell "", the whole system is fully functional and SILENT. Fill peacetime.default FIRST to give
-- every nation a bed, then override per theme. Only the theme keys referenced by the maps above need a cell;
-- anything missing falls through the ladder.
local BLANK_REGION_COLUMNS = {
	default = "",
	-- geography / tech themes
	europe = "",
	eastern_europe = "",
	near_east = "",
	africa = "",
	north_africa = "",
	north_america = "",
	south_america = "",
	steppe = "",
	east_asia = "",
	south_asia = "",
	southeast_asia = "",
	oceania = "",
	-- culture themes
	france = "",
	britain = "",
	iberia = "",
	italy = "",
	low_countries = "",
	germany = "",
	prussia = "",
	scandinavia = "",
	poland = "",
	russia = "",
	ottoman = "",
}

local function blankColumns()
	return table.clone(BLANK_REGION_COLUMNS)
end

MusicTracks.Tracks = {
	[MusicTracks.Phase.Menu] = { default = "" }, -- menu ignores region; only "default" is consulted
	[MusicTracks.Phase.Loading] = { default = "" }, -- optional boot-cover bed; falls back to menu
	[MusicTracks.Phase.Peacetime] = blankColumns(), -- fully region-flavored
	[MusicTracks.Phase.War] = { default = "" }, -- generic; add per-region cells only if wanted
	[MusicTracks.Phase.WarLosing] = { default = "" }, -- grimmer bed for a losing war
	[MusicTracks.Phase.Battle] = { default = "" }, -- universal high intensity
	[MusicTracks.Phase.BattleLosing] = { default = "" }, -- desperate variant when the tide is against you
}

-- One-shot STINGS layered over the bed on discrete events (played by the controller, ducking the bed under
-- them). Keys are the NotificationChannel eventType strings (+ a couple of controller-derived ones). "" =
-- silent until authored, same contract as Tracks.
MusicTracks.Stings = {
	["war.declared.attacker"] = "",
	["war.declared.defender"] = "",
	["battle.won"] = "",
	["battle.lost"] = "",
	["peace.concluded"] = "",
	["war.victory"] = "", -- derived: peace concluded in our favour
	["war.defeat"] = "", -- derived: peace concluded against us
	["nation.formed"] = "",
	["capital.lost"] = "", -- derived: our capital province fell to an enemy
	["capital.taken"] = "", -- derived: we captured an enemy capital
}

-- Regional claim flourish, resolved by the SAME theme ladder as beds (AnthemByTheme[themeKey]). Played once
-- when the local player claims a nation, over the incoming peacetime bed.
MusicTracks.AnthemByTheme = {
	-- france = "rbxassetid://...",
}

-- When a phase's own cells are blank, which broader phases may lend their track. Menu/Loading are their own
-- islands; the losing variants inherit their parent phase then the softer beds.
local PHASE_DESCENT = {
	menu = { "menu" },
	loading = { "loading", "menu" },
	peacetime = { "peacetime" },
	war = { "war", "peacetime" },
	war_losing = { "war_losing", "war", "peacetime" },
	battle = { "battle", "war", "peacetime" },
	battle_losing = { "battle_losing", "battle", "war", "peacetime" },
}

-- ============================ RESOLVERS (pure) ============================

local function appendKey(list, seen, key)
	if key ~= nil and key ~= "" and not seen[key] then
		seen[key] = true
		list[#list + 1] = key
	end
end

-- Ordered theme keys for a country, most-specific first, ALWAYS ending in DefaultRegionKey. `getProvince`
-- (optional) resolves the capital's superRegion for the geography layer; omit it and that layer is skipped.
function MusicTracks.regionKeysFor(country, getProvince)
	local keys, seen = {}, {}
	if country then
		appendKey(keys, seen, country.tag and MusicTracks.ThemeOverrideByTag[country.tag])
		appendKey(keys, seen, country.primaryCulture and MusicTracks.ThemeByCulture[country.primaryCulture])
		if getProvince and country.capitalProvinceId then
			local cap = getProvince(country.capitalProvinceId)
			local sr = cap and cap.superRegionId
			appendKey(keys, seen, sr and MusicTracks.ThemeBySuperRegion[sr])
		end
		appendKey(keys, seen, country.technologyGroup and MusicTracks.ThemeByTechGroup[country.technologyGroup])
	end
	appendKey(keys, seen, MusicTracks.DefaultRegionKey)
	return keys
end

-- Coerce one entry (a string id or a { id=, gain=, loopRegion= } table) to a { id, gain, loop } descriptor,
-- or nil if blank/invalid.
local function descriptorOf(entry)
	if type(entry) == "string" then
		return entry ~= "" and { id = entry } or nil
	elseif type(entry) == "table" then
		local id = entry.id
		if type(id) == "string" and id ~= "" then
			return { id = id, gain = tonumber(entry.gain), loop = entry.loopRegion }
		end
	end
	return nil
end

-- Normalize a leaf ("" | id | { entries } | descriptor) to an ordered list of { id, gain, loop } descriptors.
local function descriptorsOf(leaf)
	local out = {}
	if type(leaf) == "string" then
		local d = descriptorOf(leaf)
		if d then
			out[1] = d
		end
	elseif type(leaf) == "table" then
		if type(leaf.id) == "string" then -- a single descriptor cell
			local d = descriptorOf(leaf)
			if d then
				out[1] = d
			end
		else -- a playlist of strings and/or descriptors
			for _, entry in ipairs(leaf) do
				local d = descriptorOf(entry)
				if d then
					out[#out + 1] = d
				end
			end
		end
	end
	return out
end

-- Resolve the winning cell for (phase, orderedRegionKeys): walks the phase descent, then within each phase
-- the region keys in specificity order, returning the FIRST cell that has >=1 playable (non-disabled)
-- descriptor. Returns (cellKey, descriptors) or (nil, {}) when the whole ladder is empty. cellKey is a
-- stable "phase:themeKey" the controller uses to keep a per-cell playlist cursor. isDisabled(id) (optional)
-- filters ids that failed to load this session.
function MusicTracks.resolveCell(phase, regionKeys, isDisabled)
	local descent = PHASE_DESCENT[phase]
	if not descent then
		return nil, {}
	end
	regionKeys = regionKeys or { MusicTracks.DefaultRegionKey }
	for _, p in ipairs(descent) do
		local phaseTable = MusicTracks.Tracks[p]
		if phaseTable then
			for _, key in ipairs(regionKeys) do
				local playable = {}
				for _, d in ipairs(descriptorsOf(phaseTable[key])) do
					if not (isDisabled and isDisabled(d.id)) then
						playable[#playable + 1] = d
					end
				end
				if #playable > 0 then
					return p .. ":" .. key, playable
				end
			end
		end
	end
	return nil, {}
end

-- Convenience: the first playable id for (phase, regionKeys), or "" if none. Used by simple callers/tests;
-- the controller uses resolveCell to support playlists + per-track gain/loop.
function MusicTracks.pickTrack(phase, regionKeys, isDisabled)
	local _, descriptors = MusicTracks.resolveCell(phase, regionKeys, isDisabled)
	local first = descriptors[1]
	return first and first.id or ""
end

-- Resolve a one-shot sting/anthem id from a flat table (Stings or AnthemByTheme), honoring blanks/disabled.
local function resolveLeaf(leaf, isDisabled)
	for _, d in ipairs(descriptorsOf(leaf)) do
		if not (isDisabled and isDisabled(d.id)) then
			return d
		end
	end
	return nil
end

function MusicTracks.resolveSting(eventKey, isDisabled)
	return resolveLeaf(MusicTracks.Stings[eventKey], isDisabled)
end

function MusicTracks.resolveAnthem(regionKeys, isDisabled)
	for _, key in ipairs(regionKeys or {}) do
		local d = resolveLeaf(MusicTracks.AnthemByTheme[key], isDisabled)
		if d then
			return d
		end
	end
	return nil
end

-- Dev/test validator: every theme key referenced by the maps should have a Tracks.peacetime column (else it
-- silently resolves to a broader bed). Returns a list of human-readable warnings ({} == clean). Wire into
-- the spec and/or a MusicDebug require-time warn.
function MusicTracks.validate()
	local warnings = {}
	local columns = MusicTracks.Tracks[MusicTracks.Phase.Peacetime] or {}
	local function checkMap(name, map)
		for lhs, themeKey in pairs(map) do
			if type(themeKey) == "string" and themeKey ~= MusicTracks.DefaultRegionKey and columns[themeKey] == nil then
				warnings[#warnings + 1] = string.format(
					"%s[%q] -> %q has no Tracks.peacetime column (falls back)",
					name,
					tostring(lhs),
					themeKey
				)
			end
		end
	end
	checkMap("ThemeByCulture", MusicTracks.ThemeByCulture)
	checkMap("ThemeBySuperRegion", MusicTracks.ThemeBySuperRegion)
	checkMap("ThemeByTechGroup", MusicTracks.ThemeByTechGroup)
	checkMap("ThemeOverrideByTag", MusicTracks.ThemeOverrideByTag)
	return warnings
end

return MusicTracks
