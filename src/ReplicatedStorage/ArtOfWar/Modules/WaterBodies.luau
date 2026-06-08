local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldConstants = require(ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Shared"):WaitForChild("WorldConstants"))

local WaterBodies = {}

local LAT_SCALE  = 60
local LAT_OFFSET = -700
local LON_SCALE  = 52
local LON_OFFSET = 590

local function projX(lon)
	return -lon * LON_SCALE + LON_OFFSET
end

local function projZ(lat)
	return lat * LAT_SCALE + LAT_OFFSET
end

local function box(t, name, lat1, lat2, lon1, lon2)
	local zA, zB = projZ(lat1), projZ(lat2)
	local xA, xB = projX(lon1), projX(lon2)
	return {
		n = name, t = t,
		x1 = math.min(xA, xB), x2 = math.max(xA, xB),
		z1 = math.min(zA, zB), z2 = math.max(zA, zB),
	}
end

local bodies = {
	box("Strait",  "Strait of Gibraltar",  35,  37,   -6,   -3),
	box("Strait",  "English Channel",      49,  51,   -5,    2),
	box("Strait",  "Irish Sea",            52,  55,   -7,   -3),
	box("Strait",  "Skagerrak",            57,  59,    7,   12),
	box("Strait",  "Kattegat",             55,  58,   10,   13),
	box("Strait",  "Bosphorus",            40,  42,   28,   30),
	box("Strait",  "Dardanelles",          39,  41,   25,   27),
	box("Strait",  "Strait of Malacca",     0,   5,   99,  104),
	box("Strait",  "Bab-el-Mandeb",        11,  14,   42,   44),
	box("Strait",  "Strait of Hormuz",     25,  27,   55,   58),
	box("Strait",  "Bering Strait",        64,  68, -171, -168),

	box("Gulf",    "Persian Gulf",         24,  30,   48,   57),
	box("Gulf",    "Gulf of Mexico",       18,  30,  -97,  -82),
	box("Gulf",    "Gulf of Guinea",       -4,   5,   -6,    8),
	box("Gulf",    "Gulf of Aden",         11,  15,   44,   52),
	box("Gulf",    "Gulf of Oman",         22,  26,   58,   62),
	box("Gulf",    "Gulf of Bothnia",      60,  66,   18,   25),
	box("Gulf",    "Gulf of Finland",      59,  60.5, 22,   30),
	box("Gulf",    "Gulf of Riga",         56,  59.5, 22,   25),
	box("Gulf",    "Gulf of Thailand",      6,  13,   99,  105),
	box("Gulf",    "Gulf of California",   23,  31, -115, -108),
	box("Gulf",    "Gulf of St. Lawrence", 45,  52,  -68,  -58),

	box("Bay",     "Hudson Bay",           55,  64,  -95,  -75),
	box("Bay",     "Baffin Bay",           69,  78,  -75,  -55),
	box("Bay",     "Bay of Biscay",        43,  48,   -8,   -1),
	box("Bay",     "Bay of Bengal",         5,  22,   80,   95),
	box("Bay",     "Great Australian Bight",-39,-32, 118, 140),
	box("Bay",     "Chesapeake Bay",       36,  40,  -77,  -75),

	box("Sea",     "North Sea",            51,  60,   -4,    9),
	box("Sea",     "Baltic Sea",           54,  60,   10,   24),
	box("Sea",     "Norwegian Sea",        62,  73,   -5,   13),
	box("Sea",     "Barents Sea",          70,  80,   20,   60),
	box("Sea",     "White Sea",            63,  69,   33,   45),
	box("Sea",     "Mediterranean Sea",    30,  45,   -5,   36),
	box("Sea",     "Aegean Sea",           35,  41,   23,   28),
	box("Sea",     "Adriatic Sea",         40,  45,   12,   19),
	box("Sea",     "Tyrrhenian Sea",       38,  43,    9,   16),
	box("Sea",     "Ionian Sea",           35,  40,   15,   22),
	box("Sea",     "Ligurian Sea",         43,  44.5,  7,    9),
	box("Sea",     "Alboran Sea",          35,  37,   -5,    0),
	box("Sea",     "Black Sea",            41,  47,   27,   42),
	box("Sea",     "Sea of Azov",          45,  47,   34,   39),
	box("Sea",     "Caspian Sea",          36,  47,   47,   55),
	box("Sea",     "Red Sea",              12,  30,   32,   44),
	box("Sea",     "Arabian Sea",           5,  26,   53,   76),
	box("Sea",     "South China Sea",       0,  22,  104,  121),
	box("Sea",     "East China Sea",       24,  33,  120,  131),
	box("Sea",     "Yellow Sea",           32,  40,  119,  126),
	box("Sea",     "Sea of Japan",         34,  52,  128,  142),
	box("Sea",     "Sea of Okhotsk",       44,  60,  135,  160),
	box("Sea",     "Bering Sea",           52,  66,  160,  200),
	box("Sea",     "Laptev Sea",           70,  81,  100,  140),
	box("Sea",     "Kara Sea",             68,  80,   60,  100),
	box("Sea",     "East Siberian Sea",    69,  78,  140,  175),
	box("Sea",     "Chukchi Sea",          68,  75,  175,  200),
	box("Sea",     "Caribbean Sea",         9,  22,  -86,  -62),
	box("Sea",     "Labrador Sea",         53,  65,  -62,  -48),
	box("Sea",     "Philippine Sea",        5,  30,  121,  140),
	box("Sea",     "Tasman Sea",          -44, -30,  150,  170),
	box("Sea",     "Coral Sea",           -24, -10,  143,  164),
	box("Sea",     "Banda Sea",            -8,  -3,  123,  132),
	box("Sea",     "Java Sea",             -8,  -3,  105,  120),
	box("Sea",     "Celebes Sea",           0,   7,  117,  125),
	box("Sea",     "Sulu Sea",              6,  12,  118,  123),
	box("Sea",     "Timor Sea",           -12,  -9,  122,  130),
	box("Sea",     "Arafura Sea",          -9,  -3,  130,  141),
	box("Sea",     "Greenland Sea",        70,  80,  -15,   10),

	box("Ocean",   "North Atlantic Ocean", 10,  65,  -80,  -10),
	box("Ocean",   "South Atlantic Ocean",-55,  10,  -60,   20),
	box("Ocean",   "Indian Ocean",        -55,  25,   40,  100),
	box("Ocean",   "North Pacific Ocean",  10,  60,  130,  260),
	box("Ocean",   "South Pacific Ocean", -55,  10,  140,  290),
	box("Ocean",   "Arctic Ocean",         75,  90, -180,  180),
	box("Ocean",   "Southern Ocean",      -90, -55, -180,  180),
}

local PRIORITY = { Strait = 1, Gulf = 2, Bay = 3, Lake = 4, Sea = 5, Ocean = 6 }
table.sort(bodies, function(a, b)
	local pa = PRIORITY[a.t] or 9
	local pb = PRIORITY[b.t] or 9
	if pa ~= pb then return pa < pb end
	local areaA = (a.x2 - a.x1) * (a.z2 - a.z1)
	local areaB = (b.x2 - b.x1) * (b.z2 - b.z1)
	return areaA < areaB
end)

function WaterBodies.getWaterBodyAt(worldX, worldZ)
	local halfW = WorldConstants.MapHalfWidth
	local width = WorldConstants.MapWidth
	local cx = WorldConstants.MapCenterX
	local relX = worldX - cx
	relX = ((relX + halfW) % width) - halfW
	local x = cx + relX
	for _, b in bodies do
		if x >= b.x1 and x <= b.x2 and worldZ >= b.z1 and worldZ <= b.z2 then
			return b.n, b.t
		end
	end
	return nil, nil
end

return WaterBodies
