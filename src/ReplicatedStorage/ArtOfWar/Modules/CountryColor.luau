-- Central client resolver for a country's DISPLAY colour. Applies the "Custom Country Colors" gamepass
-- override (country.customColor) on top of the base colour (country.color), honouring the local viewer's
-- "hide other players' custom colours" setting (LocalPlayer attribute "HideOtherCustomColors"). Every client
-- surface (map fill, army tokens, crests, panels, markers) routes through here so custom colours appear
-- consistently and the hide toggle flips them all at once.
--
-- Colour shape note: country.color / customColor are {r,g,b} arrays (0-255), NOT Color3. A cleared custom
-- colour replicates as the sentinel `false` (never nil), so `type(custom) == "table"` is the "is set" test.

local Players = game:GetService("Players")

local aow = script.Parent.Parent -- ArtOfWar
local ClientStateCache = require(script.Parent.ClientStateCache)
local CountriesData = require(aow.Data.Countries)

local CountryColor = {}

local DEFAULT = Color3.fromRGB(150, 150, 150)

local function toColor3(arr)
	if type(arr) == "table" and typeof(arr[1]) == "number" then
		return Color3.fromRGB(arr[1], arr[2] or 0, arr[3] or 0)
	end
	return nil
end

-- Cached local-player country tag, so a viewer always sees THEIR OWN custom colour even with the hide toggle
-- on. Fast path validates the cached tag is still ours; only rescans after a claim/switch.
local cachedOwnTag = nil
local function ownTag()
	local lp = Players.LocalPlayer
	local uid = lp and lp.UserId
	if not uid then
		return nil
	end
	if cachedOwnTag then
		local c = ClientStateCache.getCountry(cachedOwnTag)
		if c and c.claimedBy == uid then
			return cachedOwnTag
		end
	end
	cachedOwnTag = nil
	for tag, c in pairs(ClientStateCache.allCountries() or {}) do
		if c.claimedBy == uid then
			cachedOwnTag = tag
			break
		end
	end
	return cachedOwnTag
end

local function hideOthers()
	local lp = Players.LocalPlayer
	return lp ~= nil and lp:GetAttribute("HideOtherCustomColors") == true
end

-- The {r,g,b} array a country should render as: its custom colour when set and permitted by the viewer's
-- hide toggle, else its base colour, else the static Data fallback. Returns nil only for a genuinely unknown
-- tag (callers already handle a nil colour).
function CountryColor.resolveArray(tag)
	if not tag then
		return nil
	end
	local rec = ClientStateCache.getCountry(tag) or CountriesData[tag]
	if not rec then
		return nil
	end
	local custom = rec.customColor
	if type(custom) == "table" and typeof(custom[1]) == "number" then
		if not (hideOthers() and tag ~= ownTag()) then
			return custom
		end
	end
	return rec.color
end

-- Color3 form used by most surfaces. Falls back to a neutral grey for unknown/empty records.
function CountryColor.resolve(tag)
	return toColor3(CountryColor.resolveArray(tag)) or DEFAULT
end

-- The image-decal crest a country should render, resolved from LIVE replicated state first (so editor-
-- authored crests and runtime formed/released nations show), then the static Data fallback (covers the
-- crest-bearing majors before live data arrives). Returns nil when the nation has no crest -- an intended
-- state for tribal/uncrested nations, whose callers fall back to the colour+tag badge. Mirrors resolveArray.
function CountryColor.resolveFlag(tag)
	if not tag then
		return nil
	end
	local rec = ClientStateCache.getCountry(tag) or CountriesData[tag]
	local flag = rec and rec.flagAssetId
	if flag == "" then
		return nil
	end
	return flag
end

return CountryColor
