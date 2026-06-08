local MapRenderer = {}

local MODES = {
	POLITICAL = "political",
	TERRAIN   = "terrain",
	CULTURE   = "culture",
	RELIGION  = "religion",
	TRADE     = "trade",
}

local TERRAIN_PALETTE = {
	plains    = Color3.fromRGB(118, 140, 86),
	farmland  = Color3.fromRGB(140, 165, 90),
	grassland = Color3.fromRGB(110, 155, 80),
	forest    = Color3.fromRGB(60, 90, 52),
	hills     = Color3.fromRGB(122, 118, 78),
	mountain  = Color3.fromRGB(98, 88, 76),
	mountains = Color3.fromRGB(98, 88, 76),
	desert    = Color3.fromRGB(190, 172, 122),
	drylands  = Color3.fromRGB(165, 155, 110),
	marsh     = Color3.fromRGB(96, 116, 92),
	jungle    = Color3.fromRGB(46, 92, 50),
	steppe    = Color3.fromRGB(155, 150, 105),
	taiga     = Color3.fromRGB(82, 118, 96),
	tundra    = Color3.fromRGB(170, 180, 190),
	savanna   = Color3.fromRGB(172, 168, 104),
	coastal   = Color3.fromRGB(130, 160, 120),
	highlands = Color3.fromRGB(130, 122, 90),
	plateau   = Color3.fromRGB(140, 130, 100),
	arctic    = Color3.fromRGB(210, 216, 220),
	unknown   = Color3.fromRGB(78, 76, 70),
}

local TRADE_PALETTE = {
	grain   = Color3.fromRGB(208, 190, 110),
	wheat   = Color3.fromRGB(208, 190, 110),
	fish    = Color3.fromRGB(100, 148, 178),
	wool    = Color3.fromRGB(210, 204, 180),
	cloth   = Color3.fromRGB(178, 138, 174),
	iron    = Color3.fromRGB(120, 122, 138),
	copper  = Color3.fromRGB(176, 116,  74),
	gold    = Color3.fromRGB(224, 184,  84),
	salt    = Color3.fromRGB(224, 220, 210),
	fur     = Color3.fromRGB(122,  96,  70),
	furs    = Color3.fromRGB(122,  96,  70),
	pelts   = Color3.fromRGB(140, 106,  80),
	silk    = Color3.fromRGB(200, 158, 210),
	spices  = Color3.fromRGB(196, 104,  72),
	sugar   = Color3.fromRGB(240, 226, 196),
	tobacco = Color3.fromRGB(146, 118,  74),
	cotton  = Color3.fromRGB(222, 226, 228),
	coffee  = Color3.fromRGB(112,  78,  54),
	tea     = Color3.fromRGB(148, 170, 110),
	slaves  = Color3.fromRGB( 98,  72,  80),
	ivory   = Color3.fromRGB(232, 220, 180),
	horses  = Color3.fromRGB(158, 122,  90),
	cocoa   = Color3.fromRGB(104,  72,  54),
	cochineal = Color3.fromRGB(186,  58,  64),
	maize   = Color3.fromRGB(232, 196,  96),
	cassava = Color3.fromRGB(200, 188, 140),
	tropical_wood = Color3.fromRGB( 98, 112,  66),
	naval_supplies = Color3.fromRGB( 92, 110, 130),
	gems    = Color3.fromRGB(158, 104, 170),
	wood    = Color3.fromRGB(108,  86,  62),
	fruit   = Color3.fromRGB(224, 124,  90),
	livestock = Color3.fromRGB(182, 148, 108),
}

local NEUTRAL_LAND   = Color3.fromRGB(184, 168, 134)
local UNASSIGNED_DIM = Color3.fromRGB(146, 134, 108)
local OCEAN_HINT     = Color3.fromRGB( 40,  48,  68)

local currentMode = MODES.POLITICAL
local colorCache = {}
local bundleRef = nil

local function getProvinceFolders()
	local map = workspace:FindFirstChild("ArtOfWarMap")
	if not map then return {} end
	local folders = {}
	local main = map:FindFirstChild("Provinces")
	if main then folders[#folders + 1] = main end
	local lw = map:FindFirstChild("LeftWrap")
	if lw then
		local p = lw:FindFirstChild("Provinces")
		if p then folders[#folders + 1] = p end
	end
	local rw = map:FindFirstChild("RightWrap")
	if rw then
		local p = rw:FindFirstChild("Provinces")
		if p then folders[#folders + 1] = p end
	end
	return folders
end

local function each(fn)
	for _, folder in getProvinceFolders() do
		for _, p in folder:GetChildren() do
			if p:IsA("BasePart") then fn(p) end
		end
	end
end

local function hashString(s)
	if not s then return 0 end
	local h = 2166136261
	for i = 1, #s do
		h = bit32.bxor(h, string.byte(s, i)) * 16777619
		h = h % 4294967296
	end
	return h
end

local function paletteFromHash(s, satBase, valBase)
	local h = hashString(s or "")
	local hue = (h % 360) / 360
	local sat = satBase + ((math.floor(h / 360)) % 100) / 280
	local val = valBase + ((math.floor(h / 36000)) % 100) / 320
	return Color3.fromHSV(hue, sat, val)
end

local function colorForTag(tag)
	if colorCache[tag] then return colorCache[tag] end
	local c = paletteFromHash(tag, 0.45, 0.50)
	colorCache[tag] = c
	return c
end

local function muted(c)
	local avg = (c.R + c.G + c.B) / 3
	local mix = 0.05
	local r = c.R * (1 - mix) + avg * mix
	local g = c.G * (1 - mix) + avg * mix
	local b = c.B * (1 - mix) + avg * mix
	return Color3.new(r * 0.96 + 0.01, g * 0.96 + 0.01, b * 0.96 + 0.01)
end

local function occupiedTint(c)
	local avg = (c.R + c.G + c.B) / 3
	local mix = 0.4
	local r = c.R * (1 - mix) + avg * mix
	local g = c.G * (1 - mix) + avg * mix
	local b = c.B * (1 - mix) + avg * mix
	return Color3.new(r * 0.85, g * 0.85, b * 0.85)
end

local function isOwned(owner)
	return owner and owner ~= "" and owner ~= "NONE"
end

local function apply(fn)
	each(fn)
end

-- Incremental live recolor (C2): one AttributeChanged connection per province part so that
-- when ProvinceStamper updates a part's owner/controller/etc. (server-side, on conquest or
-- occupation) ONLY that part is recolored, instead of a full ~17k-part sweep. The full
-- apply() sweep below now runs only on explicit mode switch / first paint (via setMode).
local liveConns = {}       -- one AttributeChanged connection per province part
local folderWatchers = {}  -- DescendantAdded per province folder (parts streamed in later)
local liveAttrs = {}       -- set of attribute names relevant to the current mode
local liveRecolor = nil    -- active mode's recolor(part) closure
local partsById = {}       -- province_id -> { parts } for targeted recolor
local indexBuilt = false

local function detachLiveTint()
	for _, c in ipairs(liveConns) do c:Disconnect() end
	table.clear(liveConns)
	for _, c in ipairs(folderWatchers) do c:Disconnect() end
	table.clear(folderWatchers)
	liveRecolor = nil
end

local function watchPart(p)
	if not p:IsA("BasePart") then return end
	liveConns[#liveConns + 1] = p.AttributeChanged:Connect(function(attr)
		if liveRecolor and liveAttrs[attr] then liveRecolor(p) end
	end)
end

-- (Re)bind the active mode's recolor + relevant attributes. Part connections are created
-- once (first call) and reused across mode switches -- only the active recolor/attr set is
-- swapped, so switching modes is O(1) in connections.
local function attachLiveTint(attrNames, recolor)
	if type(attrNames) == "string" then attrNames = { attrNames } end
	liveAttrs = {}
	for _, a in ipairs(attrNames) do liveAttrs[a] = true end
	liveRecolor = recolor
	if #liveConns == 0 then
		for _, folder in getProvinceFolders() do
			for _, p in folder:GetChildren() do watchPart(p) end
			folderWatchers[#folderWatchers + 1] = folder.DescendantAdded:Connect(function(d)
				watchPart(d)
				if liveRecolor and d:IsA("BasePart") then liveRecolor(d) end
			end)
		end
	end
end

function MapRenderer.setBundle(bundle) bundleRef = bundle end

function MapRenderer.applyPolitical(countryColors)
	local function recolor(p)
		local owner = p:GetAttribute("owner")
		if not isOwned(owner) then
			p.Color = NEUTRAL_LAND
			return
		end
		local controller = p:GetAttribute("controller")
		local isOccupied = isOwned(controller) and controller ~= owner
		local effectiveTag = isOccupied and controller or owner
		local color = countryColors and countryColors[effectiveTag]
		if not color then
			p.Color = NEUTRAL_LAND
			return
		end
		if isOccupied then
			p.Color = occupiedTint(color)
		else
			p.Color = muted(color)
		end
	end
	apply(recolor)
	attachLiveTint({"owner", "controller"}, recolor)
	currentMode = MODES.POLITICAL
end

function MapRenderer.applyTerrain()
	local function recolor(p)
		local t = p:GetAttribute("terrain") or "unknown"
		p.Color = TERRAIN_PALETTE[t] or TERRAIN_PALETTE.unknown
	end
	apply(recolor)
	attachLiveTint("terrain", recolor)
	currentMode = MODES.TERRAIN
end

function MapRenderer.applyCulture()
	local function recolor(p)
		local culture = p:GetAttribute("culture")
		if not culture or culture == "" then
			p.Color = UNASSIGNED_DIM
			return
		end
		p.Color = paletteFromHash("c:" .. culture, 0.50, 0.58)
	end
	apply(recolor)
	attachLiveTint("culture", recolor)
	currentMode = MODES.CULTURE
end

function MapRenderer.applyReligion()
	local function recolor(p)
		local religion = p:GetAttribute("religion")
		if not religion or religion == "" then
			p.Color = UNASSIGNED_DIM
			return
		end
		p.Color = paletteFromHash("r:" .. religion, 0.42, 0.55)
	end
	apply(recolor)
	attachLiveTint("religion", recolor)
	currentMode = MODES.RELIGION
end

function MapRenderer.applyTrade()
	local function recolor(p)
		local good = p:GetAttribute("trade_good")
		if not good or good == "" then
			p.Color = UNASSIGNED_DIM
			return
		end
		p.Color = TRADE_PALETTE[good] or paletteFromHash("g:" .. good, 0.55, 0.62)
	end
	apply(recolor)
	attachLiveTint("trade_good", recolor)
	currentMode = MODES.TRADE
end

function MapRenderer.setMode(mode, opts)
	if mode == MODES.POLITICAL then return MapRenderer.applyPolitical(opts and opts.countryColors) end
	if mode == MODES.TERRAIN   then return MapRenderer.applyTerrain() end
	if mode == MODES.CULTURE   then return MapRenderer.applyCulture() end
	if mode == MODES.RELIGION  then return MapRenderer.applyReligion() end
	if mode == MODES.TRADE     then return MapRenderer.applyTrade() end
end

function MapRenderer.getMode() return currentMode end
function MapRenderer.getModes() return MODES end

function MapRenderer.getTerrainType(province)
	if typeof(province) == "Instance" and province:IsA("BasePart") then
		return province:GetAttribute("terrain") or "Unknown"
	end
	return "Unknown"
end

function MapRenderer.init()
	currentMode = MODES.POLITICAL
end

function MapRenderer.destroy()
	detachLiveTint()
	colorCache = {}
	bundleRef = nil
end
-- Reliable incremental recolor driven by the replicated province delta (UIController calls this
-- on a province change). Independent of the per-part AttributeChanged watcher: it looks up the
-- changed province's part(s) and reapplies the current mode's recolor, reading the (already
-- replicated) part attributes. Fixes occupation/ownership changes not recoloring the map.
local function buildIndex()
	table.clear(partsById)
	for _, folder in getProvinceFolders() do
		for _, p in folder:GetChildren() do
			if p:IsA("BasePart") then
				local id = p:GetAttribute("province_id")
				if id ~= nil then
					local list = partsById[id]
					if not list then list = {}; partsById[id] = list end
					list[#list + 1] = p
				end
			end
		end
	end
	indexBuilt = true
end

function MapRenderer.recolorProvince(provinceId)
	if not liveRecolor or provinceId == nil then return end
	if not indexBuilt then buildIndex() end
	local list = partsById[provinceId] or partsById[tonumber(provinceId)]
	if not list then return end
	for _, p in ipairs(list) do
		if p.Parent then liveRecolor(p) end
	end
end

return MapRenderer
