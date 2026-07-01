-- Formable / releasable nation definitions (Phase 4). A definition is a nation you can FORM by holding
-- its required territory (you adopt its identity, core that land, and gain a bonus) and/or RELEASE from
-- your cores (as an independent nation or a puppet). Province ids are MAP PART NUMBERS (schema v3+).
-- Custom definitions authored in the owner suite (Phase 6) are stored in DataStore and merged on top of
-- these at runtime via FormableSystem.addDefinition.
--
-- Schema (keyed by an internal id/tag). NOTE: the FORMING nation keeps its OWN tag — forming only
-- adopts this definition's identity (name/colour/flag). The key is just the definition id (and the tag a
-- RELEASED nation is created under); the editor derives it from the display name, so it isn't authored.
--   [tag] = {
--     displayName         = string,             -- name shown once formed / released
--     color               = { r, g, b },        -- 0-255 map colour
--     flag                = string?,             -- "rbxassetid://..." crest (optional)
--     requiredProvinceIds = { ProvinceId },      -- provinces that must be held to form; also become its cores
--     formerTags          = { CountryTag }?,      -- whitelist of tags that may form it (e.g. {"POR","SPA"}
--                                                 --   for Iberia); nil/empty = any country holding the territory
--     formReqs            = { ... }?,             -- reserved for extra conditions (tech/culture/...); nil = none
--     formBonuses         = { stability = n? }?,  -- applied to the former on formation
--     canForm             = boolean?,             -- default true
--     canRelease          = boolean?,             -- default true
--   }
--
-- Example (fill requiredProvinceIds with real map-part numbers via the Data Editor / Phase 6 suite):
--   GBR_EMPIRE = {
--     displayName = "British Empire",
--     color = { 200, 40, 40 },
--     requiredProvinceIds = { 183, 184 },
--     formBonuses = { stability = 1 },
--     canForm = true,
--     canRelease = true,
--   },

return {
	-- Unite the Iberian peninsula. Formable by Portugal OR Spain once either holds the whole mainland
	-- (152 provinces; the Balearics, Canaries, Madeira, Ceuta and all overseas colonies are excluded).
	-- The forming nation keeps its own tag and adopts the Iberia identity. Province ids are map part
	-- numbers (schema v3+), derived geographically from the live map.
	IBERIA = {
		displayName = "Iberia",
		color = { 210, 170, 60 },
		formerTags = { "POR", "SPA" },
		formBonuses = { stability = 1 },
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
}
