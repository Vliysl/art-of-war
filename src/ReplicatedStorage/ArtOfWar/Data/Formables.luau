-- Formable / releasable nation definitions. A definition is a national IDENTITY a country can FORM by holding
-- enough of its required territory (you keep your own tag, adopt its name/colour/crest, core that land, and
-- gain a small bonus). Releasing breakaway nations is now driven by per-province "Releasable Cores" (painted
-- in the Data Editor), NOT by these defs -- see DiplomacySystem.releaseNation.
--
-- Custom definitions authored in the Data Editor's Formables tab are stored in DataStore and merged on top of
-- these at runtime (custom wins on key collision), so this file is the LAUNCH SLATE that the owner completes
-- in-editor by filling each formable's territory (shift-select tiles -> "Add map selection") and crest.
--
-- Schema (keyed by an internal id; the editor derives the key from the display name, so keep the key equal to
-- displayName:upper() with non-alphanumerics as "_", so editing a skeleton overrides THIS entry):
--   [KEY] = {
--     displayName         = string,              -- name shown once formed
--     color               = { r, g, b },          -- 0-255 map colour adopted on formation
--     flag                = string?,              -- "rbxassetid://..." crest (optional; author in-editor)
--     requiredProvinceIds = { ProvinceId },        -- provinces that count toward the goal (map part numbers,
--                                                  --   schema v3+). {} on a skeleton until the owner fills it;
--                                                  --   a formable with no territory is hidden from players.
--     minProvinces        = number?,              -- hold at least N of requiredProvinceIds (else default: ALL)
--     percentRequired     = number?,              -- OR hold at least this % of them (minProvinces wins if both)
--     formerTags          = { CountryTag }?,        -- whitelist of tags that may form it; nil/empty = any holder
--     formBonuses         = { stability = n? }?,    -- small, roughly-equal across formables (avoid meta-slaving)
--     canForm             = boolean?,             -- default true
--     canRelease          = boolean?,             -- default true
--     secret              = boolean?,             -- hidden until the FULL territory is held (a discovery goal)
--   }
--
-- DIFFICULTY BANDS (mirror UI/Screens/FormablesScreen tiers): Early <=15 required, Major <=40, Grand >40.
-- The slate is intentionally weighted toward many achievable EARLY goals, a handful of MAJOR ones, and only a
-- couple of GRAND trophies -- so there is always a near-term goal and nobody is gated behind "own everything".

return {
	-- ─────────────────────────── GRAND TROPHIES (rare, aspirational) ───────────────────────────
	-- Unite the Iberian peninsula. Formable by Portugal OR Spain. Keeps its full historical province list but
	-- only needs 70% of it, so a single obscure island/enclave can't block the achievement.
	IBERIA = {
		displayName = "Iberia",
		color = { 210, 170, 60 },
		formerTags = { "POR", "SPA" },
		formBonuses = { stability = 1 },
		percentRequired = 70,
		canForm = true,
		canRelease = false,
		requiredProvinceIds = {
			206, 207, 208, 209, 210, 211, 212, 213, 214, 215, 216, 217, 218, 219, 220, 221,
			222, 223, 224, 225, 227, 228, 229, 230, 231, 232, 335, 1745, 1746, 1747, 1748, 1749,
			1750, 1851, 2751, 2754, 2755, 2987, 2988, 2989, 2990, 3095, 3099, 3104, 3108, 4150, 4154, 4546,
			4547, 4548, 4549, 4550, 4551, 4552, 4553, 4554, 4555, 4556, 4557, 4558, 4787, 4788, 4789, 5545,
			7903, 7920, 7929, 8016, 8026, 8033, 8034, 8035, 8036, 8037, 8038, 8039, 8040, 8041, 8042, 8043,
			8044, 8045, 8047, 8048, 8049, 8050, 8051, 8052, 8053, 8054, 8055, 8056, 8057, 8058, 8059, 8060,
			8061, 8062, 8063, 8064, 8065, 8066, 8067, 8068, 8069, 8070, 8071, 8072, 8073, 8075, 8076, 8077,
			8078, 8079, 8080, 8081, 8082, 8083, 8084, 8085, 8086, 8087, 8088, 8089, 8090, 8091, 8092, 8093,
			8094, 8095, 8096, 8097, 8098, 8099, 8100, 8101, 8102, 8103, 8104, 8105, 8106, 8107, 8108, 8109,
			8110, 8111, 8113, 8114, 8115, 8116, 8117, 8121,
		},
	},
	-- Restore the Roman Empire. A secret, continent-spanning ambition revealed only once its full territory is
	-- held. TODO(owner): author the Mediterranean core provinces; percentRequired keeps it aspirational-but-fair.
	ROME = {
		displayName = "Rome",
		color = { 150, 30, 40 },
		formBonuses = { stability = 2 },
		percentRequired = 80,
		secret = true,
		canForm = true,
		canRelease = false,
		requiredProvinceIds = {},
	},

	-- ─────────────────────────── MAJOR GOALS (regional powers, a week's play) ───────────────────────────
	GERMANY = {
		displayName = "Germany",
		color = { 40, 40, 40 },
		formerTags = { "PRU", "BAV", "SAX", "HAN" },
		formBonuses = { stability = 1 },
		minProvinces = 30,
		requiredProvinceIds = {},
	},
	ITALY = {
		displayName = "Italy",
		color = { 70, 150, 80 },
		formerTags = { "SIC" },
		formBonuses = { stability = 1 },
		minProvinces = 25,
		requiredProvinceIds = {},
	},
	SCANDINAVIA = {
		displayName = "Scandinavia",
		color = { 60, 110, 190 },
		formerTags = { "SWE", "DAN" },
		formBonuses = { stability = 1 },
		minProvinces = 22,
		requiredProvinceIds = {},
	},
	["POLAND_LITHUANIA"] = {
		displayName = "Poland-Lithuania",
		color = { 200, 60, 60 },
		formerTags = { "PLC" },
		formBonuses = { stability = 1 },
		minProvinces = 24,
		requiredProvinceIds = {},
	},
	["GREATER_NETHERLANDS"] = {
		displayName = "Greater Netherlands",
		color = { 230, 130, 40 },
		formerTags = { "NED" },
		formBonuses = { stability = 1 },
		minProvinces = 18,
		requiredProvinceIds = {},
	},
	["DANUBIAN_MONARCHY"] = {
		displayName = "Danubian Monarchy",
		color = { 190, 170, 60 },
		formerTags = { "HAB" },
		formBonuses = { stability = 1 },
		minProvinces = 30,
		requiredProvinceIds = {},
	},
	["GREAT_BRITAIN"] = {
		displayName = "Great Britain",
		color = { 60, 60, 140 },
		formerTags = { "GBR", "HAN" },
		formBonuses = { stability = 1 },
		minProvinces = 20,
		requiredProvinceIds = {},
	},
	["BALKAN_FEDERATION"] = {
		displayName = "Balkan Federation",
		color = { 120, 90, 160 },
		formBonuses = { stability = 1 },
		minProvinces = 22,
		requiredProvinceIds = {},
	},

	-- ─────────────────────────── EARLY GOALS (small unifications, one session) ───────────────────────────
	SWITZERLAND = {
		displayName = "Switzerland",
		color = { 200, 50, 50 },
		formBonuses = { stability = 1 },
		minProvinces = 6,
		requiredProvinceIds = {},
	},
	IRELAND = {
		displayName = "Ireland",
		color = { 60, 150, 90 },
		formBonuses = { stability = 1 },
		minProvinces = 6,
		requiredProvinceIds = {},
	},
	SCOTLAND = {
		displayName = "Scotland",
		color = { 70, 90, 160 },
		formBonuses = { stability = 1 },
		minProvinces = 6,
		requiredProvinceIds = {},
	},
	BRITTANY = {
		displayName = "Brittany",
		color = { 40, 40, 40 },
		formBonuses = { stability = 1 },
		minProvinces = 5,
		requiredProvinceIds = {},
	},
	CATALONIA = {
		displayName = "Catalonia",
		color = { 210, 170, 40 },
		formBonuses = { stability = 1 },
		minProvinces = 6,
		requiredProvinceIds = {},
	},
	ARAGON = {
		displayName = "Aragon",
		color = { 220, 190, 60 },
		formBonuses = { stability = 1 },
		minProvinces = 8,
		requiredProvinceIds = {},
	},
	ANDALUSIA = {
		displayName = "Andalusia",
		color = { 90, 160, 70 },
		formBonuses = { stability = 1 },
		minProvinces = 8,
		requiredProvinceIds = {},
	},
	NAPLES = {
		displayName = "Naples",
		color = { 230, 200, 70 },
		formBonuses = { stability = 1 },
		minProvinces = 8,
		requiredProvinceIds = {},
	},
	VENETIA = {
		displayName = "Venetia",
		color = { 150, 40, 60 },
		formBonuses = { stability = 1 },
		minProvinces = 7,
		requiredProvinceIds = {},
	},
	TUSCANY = {
		displayName = "Tuscany",
		color = { 180, 170, 150 },
		formBonuses = { stability = 1 },
		minProvinces = 6,
		requiredProvinceIds = {},
	},
	["PIEDMONT_SARDINIA"] = {
		displayName = "Piedmont-Sardinia",
		color = { 90, 110, 190 },
		formBonuses = { stability = 1 },
		minProvinces = 8,
		requiredProvinceIds = {},
	},
	BAVARIA = {
		displayName = "Bavaria",
		color = { 90, 150, 210 },
		formerTags = { "BAV" },
		formBonuses = { stability = 1 },
		minProvinces = 8,
		requiredProvinceIds = {},
	},
	SAXONY = {
		displayName = "Saxony",
		color = { 120, 200, 90 },
		formerTags = { "SAX" },
		formBonuses = { stability = 1 },
		minProvinces = 8,
		requiredProvinceIds = {},
	},
	HANOVER = {
		displayName = "Hanover",
		color = { 200, 210, 90 },
		formerTags = { "HAN" },
		formBonuses = { stability = 1 },
		minProvinces = 8,
		requiredProvinceIds = {},
	},
	RHINELAND = {
		displayName = "Rhineland",
		color = { 150, 120, 90 },
		formBonuses = { stability = 1 },
		minProvinces = 8,
		requiredProvinceIds = {},
	},
	FLANDERS = {
		displayName = "Flanders",
		color = { 230, 200, 40 },
		formBonuses = { stability = 1 },
		minProvinces = 6,
		requiredProvinceIds = {},
	},
	WALLACHIA = {
		displayName = "Wallachia",
		color = { 170, 100, 60 },
		formBonuses = { stability = 1 },
		minProvinces = 8,
		requiredProvinceIds = {},
	},
	SERBIA = {
		displayName = "Serbia",
		color = { 160, 70, 70 },
		formBonuses = { stability = 1 },
		minProvinces = 8,
		requiredProvinceIds = {},
	},
	GREECE = {
		displayName = "Greece",
		color = { 70, 120, 200 },
		formBonuses = { stability = 1 },
		minProvinces = 10,
		requiredProvinceIds = {},
	},
	CRIMEA = {
		displayName = "Crimea",
		color = { 120, 160, 170 },
		formerTags = { "CRI" },
		formBonuses = { stability = 1 },
		minProvinces = 6,
		requiredProvinceIds = {},
	},
	MOROCCO = {
		displayName = "Morocco",
		color = { 150, 40, 50 },
		formBonuses = { stability = 1 },
		minProvinces = 10,
		requiredProvinceIds = {},
	},
	BOHEMIA = {
		displayName = "Bohemia",
		color = { 190, 90, 90 },
		formBonuses = { stability = 1 },
		minProvinces = 8,
		requiredProvinceIds = {},
	},
}
