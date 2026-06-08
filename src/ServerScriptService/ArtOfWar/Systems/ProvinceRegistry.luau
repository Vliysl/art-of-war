local ProvinceRegistry = {}

local ctx
local byArea, byRegion, bySuperRegion, byOwner, byCulture, byReligion, byTradeGood
local totals = { owner = {}, culture = {}, religion = {}, tradeGood = {} }
local ownerOf = {}    -- S5: provinceId -> indexed owner (reverse of byOwner) for incremental updates

local function rebuildOwnerIndex()
	byOwner = {}
	table.clear(ownerOf)
	local counts = {}
	for id, province in ctx.WorldState.allProvinces() do
		local owner = province.ownerTag
		local bucket = byOwner[owner] or {}
		table.insert(bucket, id)
		byOwner[owner] = bucket
		ownerOf[id] = owner
		counts[owner] = (counts[owner] or 0) + 1
	end
	totals.owner = counts
end

-- S5: incrementally move a single province between owner buckets on an ownership change,
-- instead of rescanning every province in the world. O(loser's province count) per flip.
local function updateOwnerFor(provinceId)
	local province = ctx.WorldState.getProvince(provinceId)
	if not province then return end
	local newOwner = province.ownerTag
	local oldOwner = ownerOf[provinceId]
	if oldOwner == newOwner then return end
	if oldOwner ~= nil and byOwner[oldOwner] then
		local b = byOwner[oldOwner]
		for i = #b, 1, -1 do
			if b[i] == provinceId then table.remove(b, i) break end
		end
		totals.owner[oldOwner] = math.max(0, (totals.owner[oldOwner] or 1) - 1)
	end
	local nb = byOwner[newOwner] or {}
	table.insert(nb, provinceId)
	byOwner[newOwner] = nb
	totals.owner[newOwner] = (totals.owner[newOwner] or 0) + 1
	ownerOf[provinceId] = newOwner
end

local function rebuildSecondaryIndices()
	byCulture, byReligion, byTradeGood = {}, {}, {}
	local culture, religion, good = {}, {}, {}
	for id, province in ctx.WorldState.allProvinces() do
		local cBucket = byCulture[province.culture] or {}
		table.insert(cBucket, id)
		byCulture[province.culture] = cBucket
		culture[province.culture] = (culture[province.culture] or 0) + 1

		local rBucket = byReligion[province.religion] or {}
		table.insert(rBucket, id)
		byReligion[province.religion] = rBucket
		religion[province.religion] = (religion[province.religion] or 0) + 1

		local gBucket = byTradeGood[province.tradeGood] or {}
		table.insert(gBucket, id)
		byTradeGood[province.tradeGood] = gBucket
		good[province.tradeGood] = (good[province.tradeGood] or 0) + 1
	end
	totals.culture = culture
	totals.religion = religion
	totals.tradeGood = good
end

local function bindOwnershipEvents()
	ctx.EventBus.subscribe(ctx.Channels.ProvinceOwnershipChanged, function(payload)
		if not payload or payload.provinceId == nil then return end
		updateOwnerFor(payload.provinceId)
	end)
end

function ProvinceRegistry.register(context)
	ctx = context
	ProvinceRegistry.api = {
		get = function(id) return ctx.WorldState.getProvince(id) end,
		all = function() return ctx.WorldState.allProvinces() end,
		byArea = function(areaId) return byArea[areaId] or {} end,
		byRegion = function(regionId) return byRegion[regionId] or {} end,
		bySuperRegion = function(superRegionId) return bySuperRegion[superRegionId] or {} end,
		byOwner = function(tag) return byOwner[tag] or {} end,
		byCulture = function(cultureId) return byCulture[cultureId] or {} end,
		byReligion = function(religionId) return byReligion[religionId] or {} end,
		byTradeGood = function(tradeGoodId) return byTradeGood[tradeGoodId] or {} end,
		ownerTotals = function() return totals.owner end,
		cultureTotals = function() return totals.culture end,
		religionTotals = function() return totals.religion end,
		tradeGoodTotals = function() return totals.tradeGood end,
	}
	ctx.ProvinceRegistry = ProvinceRegistry.api
end

function ProvinceRegistry.hydrate(provinces)
	byArea, byRegion, bySuperRegion = {}, {}, {}
	for id, record in provinces do
		local clone = table.clone(record)
		clone.cores = table.clone(record.cores)
		-- Multi-resource migration: synthesize province.goods from tradeGood + baseProduction
		-- when not explicitly set on the data row. Provinces with tradeGood "none" / nil get an
		-- empty map so they produce nothing (matches the spec).
		if clone.goods == nil then
			local g = {}
			local tg = clone.tradeGood
			if tg and tg ~= "" and tg ~= "none" then
				g[tg] = clone.baseProduction or 0
			end
			clone.goods = g
		else
			clone.goods = table.clone(clone.goods)
		end
		ctx.WorldState.setProvince(id, clone)

		local aBucket = byArea[record.areaId] or {}
		table.insert(aBucket, id)
		byArea[record.areaId] = aBucket

		local rBucket = byRegion[record.regionId] or {}
		table.insert(rBucket, id)
		byRegion[record.regionId] = rBucket

		local sBucket = bySuperRegion[record.superRegionId] or {}
		table.insert(sBucket, id)
		bySuperRegion[record.superRegionId] = sBucket
	end
	rebuildOwnerIndex()
	rebuildSecondaryIndices()
	bindOwnershipEvents()
end

return ProvinceRegistry
