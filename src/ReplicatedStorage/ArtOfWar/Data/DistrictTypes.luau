--!strict
-- DistrictTypes: the six slotted districts of the economy rework, plus the maps that gate them.
--
--   Extraction (Harbor / Mining / Agricultural): produce a province's raw tradeGood, but ONLY when the
--     province hosts the district matching that good's nature. Harbor additionally requires a coastal tile.
--   Manufactory (Industrial / Manufacturing): auto-run the best eligible recipe of their output family
--     (Industrial = metal/chemical/military outputs; Manufacturing = finished consumer outputs).
--   Military: no economic output -- gates recruitment of professional (non-levy) units.
--
-- Districts occupy province building SLOTS (= infraTier) and level up to a cap (= devTier). This module is
-- pure data + lookup helpers; BuildingSystem synthesises BuildingTypes-compatible entries from it at load
-- (Phase 3), mirroring how BuildingTypes already synthesises `manufactory_*`.

local TradeGoods = require(script.Parent.TradeGoods)

local DistrictTypes = {}

-- The six districts. `slotted` districts occupy a build slot; all six here are slotted (Infrastructure /
-- Development remain separate repeatable "meta" buildings, and forts/shipyard/university stay as
-- non-slot "special buildings" -- none of those live in this table).
DistrictTypes.types = {
	Harbor = {
		id = "Harbor",
		displayName = "Harbor District",
		description = "Docks, fisheries, and salt pans take advantage of the sea's natural bounty.",
		role = "extraction",
		requiresCoastal = true,
		icon = "Anchor",
		colorKey = "sea",
		order = 1,
	},
	Mining = {
		id = "Mining",
		displayName = "Mining District",
		description = "Mines and quarries extract raw minerals, metals, and stone.",
		role = "extraction",
		icon = "GoodCoal",
		colorKey = "earth",
		order = 2,
	},
	Agricultural = {
		id = "Agricultural",
		displayName = "Agricultural District",
		description = "Farms, pastures, and forestry harvest crops, livestock, and timber.",
		role = "extraction",
		icon = "GoodGrain",
		colorKey = "farm",
		order = 3,
	},
	Industrial = {
		id = "Industrial",
		displayName = "Industrial District",
		description = "Foundries and works refine raw minerals into steel, gunpowder, and weapons.",
		role = "manufactory",
		family = "Industrial",
		icon = "Factory",
		colorKey = "industry",
		order = 4,
	},
	Manufacturing = {
		id = "Manufacturing",
		displayName = "Manufacturing District",
		description = "Mills and workshops turn raw and refined goods into finished consumer products.",
		role = "manufactory",
		family = "Manufacturing",
		icon = "Market",
		colorKey = "industry",
		order = 5,
	},
	Military = {
		id = "Military",
		displayName = "Military District",
		description = "Barracks, stables, and drill yards muster professional troops.",
		role = "military",
		icon = "Military",
		colorKey = "military",
		order = 6,
	},
}

DistrictTypes.order = { "Harbor", "Mining", "Agricultural", "Industrial", "Manufacturing", "Military" }

-- Explicit RAW-good -> extraction district. Processed/manufactured goods are absent (they are produced by
-- manufactory districts, not extracted). Ambiguous by category (e.g. `staple` holds both grain->Agricultural
-- and fish->Harbor), so this map is the source of truth and the category fallback below only fills gaps.
DistrictTypes.extractionByGood = {
	-- Harbor (sea) -- also requires a coastal province
	fish = "Harbor",
	salt = "Harbor",
	whale_oil = "Harbor",
	fish_oil = "Harbor",

	-- Mining (minerals / stone / fossil fuel / mined luxuries)
	iron = "Mining",
	copper = "Mining",
	tin = "Mining",
	lead = "Mining",
	gold = "Mining",
	silver = "Mining",
	gems = "Mining",
	diamonds = "Mining",
	stone = "Mining",
	clay = "Mining",
	limestone = "Mining",
	marble = "Mining",
	coal = "Mining",
	peat = "Mining",
	sulfur = "Mining",
	saltpeter = "Mining",
	phosphate = "Mining",

	-- Agricultural (crops / pasture / forestry / plantation / hunting)
	grain = "Agricultural",
	vegetables = "Agricultural",
	fruit = "Agricultural",
	rice = "Agricultural",
	maize = "Agricultural",
	cassava = "Agricultural",
	dates = "Agricultural",
	livestock = "Agricultural",
	honey = "Agricultural",
	beeswax = "Agricultural",
	sugar = "Agricultural",
	tobacco = "Agricultural",
	coffee = "Agricultural",
	tea = "Agricultural",
	cocoa = "Agricultural",
	spices = "Agricultural",
	indigo = "Agricultural",
	cochineal = "Agricultural",
	wool = "Agricultural",
	cotton = "Agricultural",
	hemp = "Agricultural",
	flax = "Agricultural",
	silk = "Agricultural",
	wood = "Agricultural",
	timber = "Agricultural",
	tropical_wood = "Agricultural",
	ivory = "Agricultural",
	fur = "Agricultural",
	pelts = "Agricultural",
}

-- Category fallback for any raw good not explicitly mapped above.
local CATEGORY_EXTRACTION = {
	metal = "Mining",
	chemical = "Mining",
	construction = "Mining",
	staple = "Agricultural",
	textile = "Agricultural",
}

-- Which extraction district (if any) can produce this good. Returns "Harbor"|"Mining"|"Agricultural" or nil
-- (nil == not an extractable raw good; it must be manufactured instead).
function DistrictTypes.extractionDistrictFor(goodId)
	if not goodId then
		return nil
	end
	local explicit = DistrictTypes.extractionByGood[goodId]
	if explicit then
		return explicit
	end
	local def = TradeGoods[goodId]
	return def and CATEGORY_EXTRACTION[def.category] or nil
end

-- Which manufactory family hosts a recipe, by its OUTPUT good's category.
-- Industrial = metal / chemical / military; Manufacturing = everything else (finished consumer goods,
-- processed foods, textiles, luxuries).
local INDUSTRIAL_OUTPUT_CATEGORIES = { metal = true, chemical = true, military = true }

function DistrictTypes.manufactoryFamilyFor(outputGoodId)
	local def = outputGoodId and TradeGoods[outputGoodId]
	local category = def and def.category
	if category and INDUSTRIAL_OUTPUT_CATEGORIES[category] then
		return "Industrial"
	end
	return "Manufacturing"
end

function DistrictTypes.isExtraction(districtType)
	local d = DistrictTypes.types[districtType]
	return d ~= nil and d.role == "extraction"
end

function DistrictTypes.isManufactory(districtType)
	local d = DistrictTypes.types[districtType]
	return d ~= nil and d.role == "manufactory"
end

return DistrictTypes
