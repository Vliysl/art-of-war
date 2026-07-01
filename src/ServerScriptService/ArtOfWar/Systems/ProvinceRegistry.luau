local ProvinceRegistry = {}

local ctx
local byArea, byRegion, bySuperRegion, byOwner, byController, byCulture, byReligion, byTradeGood
local totals = { owner = {}, culture = {}, religion = {}, tradeGood = {} }
local ownerOf = {}    -- S5: provinceId -> indexed owner (reverse of byOwner) for incremental updates
-- perf: provinceId -> its index within byOwner[ownerOf[id]] so removal is O(1) swap-and-pop
-- instead of an O(n) linear scan + table.remove shift. Kept in sync at every byOwner mutation
-- site (rebuildOwnerIndex / updateOwnerFor / registerProvince).
local ownerSlot = {}
-- byController mirrors byOwner for the CONTROLLER tag (occupier), so annex/peace can iterate a winner's
-- occupied provinces in O(controlled) instead of scanning the whole world. Same O(1) swap-and-pop
-- bookkeeping (controllerOf reverse map + controllerSlot index).
local controllerOf = {}
local controllerSlot = {}

-- perf: append id to its owner bucket and record its slot index. Mirror of table.insert.
local function ownerBucketPush(bucket, id)
	local n = #bucket + 1
	bucket[n] = id
	ownerSlot[id] = n
end

-- perf: O(1) swap-and-pop removal of id from its owner bucket using ownerSlot. Order may
-- change (the last element is moved into the gap) but membership is preserved exactly.
local function ownerBucketRemove(bucket, id)
	local i = ownerSlot[id]
	if i == nil then return end
	local n = #bucket
	local last = bucket[n]
	if last ~= id then
		bucket[i] = last
		ownerSlot[last] = i
	end
	bucket[n] = nil
	ownerSlot[id] = nil
end

local function controllerBucketPush(bucket, id)
	local n = #bucket + 1
	bucket[n] = id
	controllerSlot[id] = n
end

local function controllerBucketRemove(bucket, id)
	local i = controllerSlot[id]
	if i == nil then return end
	local n = #bucket
	local last = bucket[n]
	if last ~= id then
		bucket[i] = last
		controllerSlot[last] = i
	end
	bucket[n] = nil
	controllerSlot[id] = nil
end

local function rebuildOwnerIndex()
	byOwner = {}
	table.clear(ownerOf)
	table.clear(ownerSlot)
	local counts = {}
	for id, province in ctx.WorldState.allProvinces() do
		local owner = province.ownerTag
		local bucket = byOwner[owner] or {}
		byOwner[owner] = bucket
		ownerBucketPush(bucket, id)
		ownerOf[id] = owner
		counts[owner] = (counts[owner] or 0) + 1
	end
	totals.owner = counts
end

-- S5: incrementally move a single province between owner buckets on an ownership change,
-- instead of rescanning every province in the world. perf: now O(1) per flip via ownerSlot.
local function updateOwnerFor(provinceId)
	local province = ctx.WorldState.getProvince(provinceId)
	if not province then return end
	local newOwner = province.ownerTag
	local oldOwner = ownerOf[provinceId]
	if oldOwner == newOwner then return end
	if oldOwner ~= nil and byOwner[oldOwner] then
		ownerBucketRemove(byOwner[oldOwner], provinceId)
		totals.owner[oldOwner] = math.max(0, (totals.owner[oldOwner] or 1) - 1)
	end
	local nb = byOwner[newOwner] or {}
	byOwner[newOwner] = nb
	ownerBucketPush(nb, provinceId)
	totals.owner[newOwner] = (totals.owner[newOwner] or 0) + 1
	ownerOf[provinceId] = newOwner
end

local function rebuildControllerIndex()
	byController = {}
	table.clear(controllerOf)
	table.clear(controllerSlot)
	for id, province in ctx.WorldState.allProvinces() do
		local controller = province.controllerTag or province.ownerTag
		local bucket = byController[controller] or {}
		byController[controller] = bucket
		controllerBucketPush(bucket, id)
		controllerOf[id] = controller
	end
end

-- Incrementally move a province between controller buckets on an occupation/ownership change. O(1).
local function updateControllerFor(provinceId)
	local province = ctx.WorldState.getProvince(provinceId)
	if not province then return end
	local newController = province.controllerTag or province.ownerTag
	local oldController = controllerOf[provinceId]
	if oldController == newController then return end
	if oldController ~= nil and byController[oldController] then
		controllerBucketRemove(byController[oldController], provinceId)
	end
	local nb = byController[newController] or {}
	byController[newController] = nb
	controllerBucketPush(nb, provinceId)
	controllerOf[provinceId] = newController
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

-- Insert a single province into every index after hydrate has already run, mirroring the
-- per-record bookkeeping in hydrate + the rebuild passes. Used by the boot reconciler to
-- enrol provinces it registers from owned-but-unmapped map tiles. Returns false if the
-- registry has not been hydrated yet.
local function registerProvince(id, record)
	if not byOwner or not byArea then
		return false
	end
	local clone = table.clone(record)
	clone.cores = table.clone(record.cores or {})
	clone.defaultCores = table.clone(record.defaultCores or {})
	clone.claims = table.clone(record.claims or {})
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

	local function push(index, key)
		if key == nil then
			return
		end
		local bucket = index[key] or {}
		table.insert(bucket, id)
		index[key] = bucket
	end
	local function bump(counter, key)
		if key == nil then
			return
		end
		counter[key] = (counter[key] or 0) + 1
	end

	push(byArea, clone.areaId)
	push(byRegion, clone.regionId)
	push(bySuperRegion, clone.superRegionId)
	-- perf: route the owner bucket through ownerBucketPush so ownerSlot stays in sync
	if clone.ownerTag ~= nil then
		local oBucket = byOwner[clone.ownerTag] or {}
		byOwner[clone.ownerTag] = oBucket
		ownerBucketPush(oBucket, id)
	end
	local controllerTag = clone.controllerTag or clone.ownerTag
	if controllerTag ~= nil then
		local cBucket = byController[controllerTag] or {}
		byController[controllerTag] = cBucket
		controllerBucketPush(cBucket, id)
		controllerOf[id] = controllerTag
	end
	push(byCulture, clone.culture)
	push(byReligion, clone.religion)
	push(byTradeGood, clone.tradeGood)
	ownerOf[id] = clone.ownerTag
	bump(totals.owner, clone.ownerTag)
	bump(totals.culture, clone.culture)
	bump(totals.religion, clone.religion)
	bump(totals.tradeGood, clone.tradeGood)
	return true
end

local function bindOwnershipEvents()
	ctx.EventBus.subscribe(ctx.Channels.ProvinceOwnershipChanged, function(payload)
		if not payload or payload.provinceId == nil then return end
		updateOwnerFor(payload.provinceId)
		updateControllerFor(payload.provinceId) -- annex sets controller=winner too
	end)
	ctx.EventBus.subscribe(ctx.Channels.ProvinceOccupied, function(payload)
		if not payload or payload.provinceId == nil then return end
		updateControllerFor(payload.provinceId)
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
		byController = function(tag) return byController[tag] or {} end,
		byCulture = function(cultureId) return byCulture[cultureId] or {} end,
		byReligion = function(religionId) return byReligion[religionId] or {} end,
		byTradeGood = function(tradeGoodId) return byTradeGood[tradeGoodId] or {} end,
		ownerTotals = function() return totals.owner end,
		cultureTotals = function() return totals.culture end,
		religionTotals = function() return totals.religion end,
		tradeGoodTotals = function() return totals.tradeGood end,
		registerProvince = registerProvince,
	}
	ctx.ProvinceRegistry = ProvinceRegistry.api
end

function ProvinceRegistry.hydrate(provinces)
	byArea, byRegion, bySuperRegion = {}, {}, {}
	for id, record in provinces do
		local clone = table.clone(record)
		clone.cores = table.clone(record.cores)
		clone.defaultCores = table.clone(record.defaultCores or record.cores or {})
		clone.claims = table.clone(record.claims or {})
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
	rebuildControllerIndex()
	rebuildSecondaryIndices()
	bindOwnershipEvents()
end

return ProvinceRegistry
