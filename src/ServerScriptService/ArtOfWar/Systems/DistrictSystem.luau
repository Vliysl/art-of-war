--!strict
-- DistrictSystem: places, upgrades, aggregates, and seed-migrates the six economy-rework DISTRICTS.
--
-- Districts occupy province building SLOTS (= infraTier) and level up to a cap (= devTier). This system is
-- SEPARATE from BuildingSystem, which keeps handling the non-slot "special" buildings (walls / fortress /
-- shipyard / university) and the "meta" upgrades (develop_province / improve_infrastructure). So the two
-- queues never share the devTier line-cap: districts get their own DistrictBuildConcurrency.
--
-- Everything here is gated by WorldConstants.DistrictsPlayable -- with the flag off the system no-ops, so
-- boot behaviour is unchanged. Tax from districts is computed in EconomyPreview (Phase 2); this system only
-- owns the districts themselves + the country.districtStats aggregate the Economy tab reads.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AoW = ReplicatedStorage:WaitForChild("ArtOfWar")
local DistrictTypes = require(AoW:WaitForChild("Data"):WaitForChild("DistrictTypes"))
local EconomyPreview = require(AoW:WaitForChild("Modules"):WaitForChild("EconomyPreview"))

local DistrictSystem = {}

local ctx
local queuesByCountry = {} -- [tag] = { ticket, ... }
local nextSeq = 0

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function enabled()
	return ctx.WorldConstants and ctx.WorldConstants.DistrictsPlayable == true
end

local function generateTicketId(tag)
	nextSeq += 1
	return string.format("district_%s_%d", tostring(tag), nextSeq)
end

local function slotCount(province)
	return math.max(0, math.floor(province.infraTier or 0))
end

local function levelCap(province)
	return math.max(0, math.floor(province.devTier or 0))
end

local function districtAt(province, slotIndex)
	local d = province.districts
	return d and d[slotIndex] or nil
end

local function occupiedSlots(province)
	local n = 0
	if province.districts then
		for _, entry in pairs(province.districts) do
			if type(entry) == "table" and entry.type then
				n += 1
			end
		end
	end
	return n
end

-- Pending (queued, not yet complete) placements/upgrades at a province, so a slot can't be over-queued and
-- the concurrency cap is honoured.
local function pendingAt(tag, provinceId, onlyPlacements)
	local q = queuesByCountry[tag]
	local n = 0
	if q then
		for _, t in q do
			if t.provinceId == provinceId and (not onlyPlacements or not t.isUpgrade) then
				n += 1
			end
		end
	end
	return n
end

-- Extraction eligibility: an extraction district needs the province's tradeGood to match its type; Harbor
-- also needs a coastal tile. Manufactory/Military districts have no good gate.
local function extractionEligible(province, districtType)
	local def = DistrictTypes.types[districtType]
	if not def then
		return false, "unknown_district"
	end
	if def.requiresCoastal and province.coastal ~= true then
		return false, "requires_coastal"
	end
	if def.role == "extraction" then
		local want = DistrictTypes.extractionDistrictFor(province.tradeGood)
		if want ~= districtType then
			return false, "wrong_good_for_district"
		end
	end
	return true
end

local function districtCost(targetLevel, districtType)
	local wc = ctx.WorldConstants
	local c = (wc.DistrictBaseCost or 120) * ((wc.DistrictCostGrowth or 1.6) ^ math.max(0, targetLevel - 1))
	local def = DistrictTypes.types[districtType]
	if def and def.role == "manufactory" then
		c *= (wc.DistrictManufactoryCostMult or 1.25)
	end
	return math.floor(c + 0.5)
end

local function districtBuildDays(targetLevel)
	local wc = ctx.WorldConstants
	return (wc.DistrictBuildDaysBase or 60) + (wc.DistrictBuildDaysPerLevel or 30) * math.max(0, targetLevel - 1)
end

local function secondsPerDay()
	local wc = ctx.WorldConstants
	return wc.SecondsPerSimTick / (wc.DaysPerEarlyTick or 1)
end

-- Mirror the queue onto the (replicated) country record so the client grid can show build-in-progress.
local function pruneQueue(tag)
	local country = ctx.WorldState.getCountry(tag)
	if not country then
		return
	end
	local items = {}
	for _, t in (queuesByCountry[tag] or {}) do
		table.insert(items, {
			id = t.id,
			provinceId = t.provinceId,
			slotIndex = t.slotIndex,
			districtType = t.districtType,
			targetLevel = t.targetLevel,
			isUpgrade = t.isUpgrade,
			startedAt = t.startedAt,
			completesAt = t.completesAt,
		})
	end
	country.districtQueue = items
	ctx.WorldState.setCountry(tag, country)
end

-- ---------------------------------------------------------------------------
-- Aggregation: country.districtStats (drives the Economy tab totals + Upgrade-All macros)
-- ---------------------------------------------------------------------------

local function recomputeStats(tag)
	if not tag or tag == "NONE" then
		return
	end
	local country = ctx.WorldState.getCountry(tag)
	if not country then
		return
	end
	local byType, levelSum, monthlyTax, upgradable = {}, {}, {}, {}
	local provinceIds = (ctx.ProvinceRegistry and ctx.ProvinceRegistry.byOwner(tag)) or {}
	for _, pid in provinceIds do
		local p = ctx.WorldState.getProvince(pid)
		if p and p.controllerTag == tag and p.districts then
			local cap = levelCap(p)
			for _, d in pairs(p.districts) do
				if type(d) == "table" and d.type then
					byType[d.type] = (byType[d.type] or 0) + 1
					levelSum[d.type] = (levelSum[d.type] or 0) + (d.level or 0)
					monthlyTax[d.type] = (monthlyTax[d.type] or 0)
						+ EconomyPreview.districtMonthlyTax(d.type, d.level or 0, ctx.WorldConstants)
					if (d.level or 0) < cap then
						upgradable[d.type] = (upgradable[d.type] or 0) + 1
					end
				end
			end
		end
	end
	country.districtStats = {
		byType = byType,
		levelSumByType = levelSum,
		monthlyTaxByType = monthlyTax,
		upgradableByType = upgradable,
	}
	ctx.WorldState.setCountry(tag, country)
end

-- ---------------------------------------------------------------------------
-- Build / upgrade
-- ---------------------------------------------------------------------------

local function buildDistrict(tag, provinceId, slotIndex, districtType)
	if not enabled() then
		return false, "districts_disabled"
	end
	provinceId = tonumber(provinceId) or provinceId
	slotIndex = tonumber(slotIndex)
	if not slotIndex then
		return false, "invalid_slot"
	end
	local province = ctx.WorldState.getProvince(provinceId)
	if not province then
		return false, "unknown_province"
	end
	if province.ownerTag ~= tag then
		return false, "not_owner"
	end
	if province.controllerTag ~= tag then
		return false, "not_controller"
	end
	if not DistrictTypes.types[districtType] then
		return false, "unknown_district"
	end
	local slots = slotCount(province)
	if slotIndex < 1 or slotIndex > slots then
		return false, "invalid_slot"
	end
	if districtAt(province, slotIndex) then
		return false, "slot_occupied"
	end
	-- One in-flight ticket per slot (mirrors upgradeDistrict): without this a double BuildDistrict in
	-- one tick charges treasury twice for the same slot, and fulfil() drops the loser silently.
	for _, t in (queuesByCountry[tag] or {}) do
		if t.provinceId == provinceId and t.slotIndex == slotIndex then
			return false, "already_queued"
		end
	end
	if occupiedSlots(province) + pendingAt(tag, provinceId, true) >= slots then
		return false, "no_free_slot"
	end
	local ok, reason = extractionEligible(province, districtType)
	if not ok then
		return false, reason
	end
	if pendingAt(tag, provinceId, false) >= (ctx.WorldConstants.DistrictBuildConcurrency or 2) then
		return false, "build_queue_full"
	end
	local country = ctx.WorldState.getCountry(tag)
	if not country then
		return false, "unknown_country"
	end
	local price = districtCost(1, districtType)
	-- [tech] building_cost_reduction (REDUCTION, cap WorldConstants.TechCapBuildingCost)
	price = math.floor(price * (1 - (ctx.ResearchSystem and ctx.ResearchSystem.bonus and ctx.ResearchSystem.bonus(tag, "building_cost_reduction") or 0)) + 0.5)
	if (country.treasury or 0) < price then
		return false, "insufficient_treasury"
	end
	country.treasury = (country.treasury or 0) - price
	ctx.WorldState.setCountry(tag, country)

	local now = ctx.TickScheduler.getSimTime()
	local ticket = {
		id = generateTicketId(tag),
		tag = tag,
		provinceId = provinceId,
		slotIndex = slotIndex,
		districtType = districtType,
		targetLevel = 1,
		isUpgrade = false,
		startedAt = now,
		-- [tech] building_speed (REDUCTION of days = faster, cap WorldConstants.TechCapBuildingSpeed)
		completesAt = now + districtBuildDays(1) * (1 - (ctx.ResearchSystem and ctx.ResearchSystem.bonus and ctx.ResearchSystem.bonus(tag, "building_speed") or 0)) * secondsPerDay(),
	}
	local q = queuesByCountry[tag] or {}
	table.insert(q, ticket)
	queuesByCountry[tag] = q
	pruneQueue(tag)
	return true, ticket.id
end

local function upgradeDistrict(tag, provinceId, slotIndex)
	if not enabled() then
		return false, "districts_disabled"
	end
	provinceId = tonumber(provinceId) or provinceId
	slotIndex = tonumber(slotIndex)
	if not slotIndex then
		return false, "invalid_slot"
	end
	local province = ctx.WorldState.getProvince(provinceId)
	if not province then
		return false, "unknown_province"
	end
	if province.ownerTag ~= tag or province.controllerTag ~= tag then
		return false, "not_owner"
	end
	local d = districtAt(province, slotIndex)
	if not d then
		return false, "empty_slot"
	end
	local targetLevel = (d.level or 0) + 1
	if targetLevel > levelCap(province) then
		return false, "district_level_cap"
	end
	-- One in-flight ticket per slot.
	for _, t in (queuesByCountry[tag] or {}) do
		if t.provinceId == provinceId and t.slotIndex == slotIndex then
			return false, "already_queued"
		end
	end
	if pendingAt(tag, provinceId, false) >= (ctx.WorldConstants.DistrictBuildConcurrency or 2) then
		return false, "build_queue_full"
	end
	local country = ctx.WorldState.getCountry(tag)
	if not country then
		return false, "unknown_country"
	end
	local price = districtCost(targetLevel, d.type)
	-- [tech] building_cost_reduction (REDUCTION, cap WorldConstants.TechCapBuildingCost)
	price = math.floor(price * (1 - (ctx.ResearchSystem and ctx.ResearchSystem.bonus and ctx.ResearchSystem.bonus(tag, "building_cost_reduction") or 0)) + 0.5)
	if (country.treasury or 0) < price then
		return false, "insufficient_treasury"
	end
	country.treasury = (country.treasury or 0) - price
	ctx.WorldState.setCountry(tag, country)

	local now = ctx.TickScheduler.getSimTime()
	local ticket = {
		id = generateTicketId(tag),
		tag = tag,
		provinceId = provinceId,
		slotIndex = slotIndex,
		districtType = d.type,
		targetLevel = targetLevel,
		isUpgrade = true,
		startedAt = now,
		-- [tech] building_speed (REDUCTION of days = faster, cap WorldConstants.TechCapBuildingSpeed)
		completesAt = now + districtBuildDays(targetLevel) * (1 - (ctx.ResearchSystem and ctx.ResearchSystem.bonus and ctx.ResearchSystem.bonus(tag, "building_speed") or 0)) * secondsPerDay(),
	}
	local q = queuesByCountry[tag] or {}
	table.insert(q, ticket)
	queuesByCountry[tag] = q
	pruneQueue(tag)
	return true, ticket.id
end

-- Raze a district, freeing its slot. NO refund -- razing is a pure teardown. Also cancels an in-flight
-- build/upgrade ticket for the slot. Clean because districts have no permanent grants to unwind (their
-- tax/production/recruit effects are all read live from province.districts).
local function razeDistrict(tag, provinceId, slotIndex)
	if not enabled() then
		return false, "districts_disabled"
	end
	provinceId = tonumber(provinceId) or provinceId
	slotIndex = tonumber(slotIndex)
	if not slotIndex then
		return false, "invalid_slot"
	end
	local province = ctx.WorldState.getProvince(provinceId)
	if not province then
		return false, "unknown_province"
	end
	if province.ownerTag ~= tag or province.controllerTag ~= tag then
		return false, "not_owner"
	end
	local d = districtAt(province, slotIndex)
	-- A slot may hold a placed district OR just an in-flight build ticket (queued into an empty slot).
	local q = queuesByCountry[tag]
	local hasTicket = false
	if q then
		for _, t in q do
			if t.provinceId == provinceId and t.slotIndex == slotIndex then
				hasTicket = true
				break
			end
		end
	end
	if not d and not hasTicket then
		return false, "empty_slot"
	end
	-- Drop any queued ticket for this slot (build or upgrade) so nothing fulfils onto the cleared slot.
	if q then
		for i = #q, 1, -1 do
			if q[i].provinceId == provinceId and q[i].slotIndex == slotIndex then
				table.remove(q, i)
			end
		end
		queuesByCountry[tag] = (#q > 0) and q or nil
		pruneQueue(tag)
	end
	if d then
		ctx.WorldState.setProvinceDistrict(provinceId, slotIndex, nil)
	elseif ctx.Channels.ProvinceDistrictChanged then
		-- No district placed (only a build was canceled); nudge consumers so the grid rebuilds.
		ctx.EventBus.publish(ctx.Channels.ProvinceDistrictChanged, {
			provinceId = provinceId,
			slotIndex = slotIndex,
			cleared = true,
		})
	end
	return true
end

-- "Upgrade all" macro: enqueue an upgrade for every province of `tag` that hosts a district of the given
-- type below its dev cap and isn't already queued/afford-capped. Returns how many were queued.
local function upgradeDistrictAll(tag, districtType)
	if not enabled() then
		return 0
	end
	local provinceIds = (ctx.ProvinceRegistry and ctx.ProvinceRegistry.byOwner(tag)) or {}
	local queued = 0
	for _, pid in provinceIds do
		local p = ctx.WorldState.getProvince(pid)
		if p and p.controllerTag == tag and p.districts then
			for slotIndex, d in pairs(p.districts) do
				if type(d) == "table" and d.type == districtType then
					local ok = upgradeDistrict(tag, pid, slotIndex)
					if ok then
						queued += 1
					end
				end
			end
		end
	end
	return queued
end

local function fulfil(ticket)
	local province = ctx.WorldState.getProvince(ticket.provinceId)
	if not province then
		return
	end
	if ticket.isUpgrade then
		local d = districtAt(province, ticket.slotIndex)
		if not d or d.type ~= ticket.districtType then
			return
		end
		d.level = math.max(d.level or 0, ticket.targetLevel)
		ctx.WorldState.setProvinceDistrict(ticket.provinceId, ticket.slotIndex, d)
		ctx.EventBus.publish(ctx.Channels.DistrictUpgraded, {
			tag = ticket.tag,
			provinceId = ticket.provinceId,
			slotIndex = ticket.slotIndex,
			districtType = d.type,
			level = d.level,
		})
	else
		if districtAt(province, ticket.slotIndex) then
			return -- slot filled meanwhile; drop silently (treasury already spent -- rare)
		end
		ctx.WorldState.setProvinceDistrict(ticket.provinceId, ticket.slotIndex, {
			type = ticket.districtType,
			level = 1,
		})
	end
end

local function tickQueues()
	if not enabled() then
		return
	end
	local now = ctx.TickScheduler.getSimTime()
	for tag, q in queuesByCountry do
		local kept = {}
		local changed = false
		for _, t in q do
			if now >= t.completesAt then
				fulfil(t)
				changed = true
			else
				table.insert(kept, t)
			end
		end
		queuesByCountry[tag] = (#kept > 0) and kept or nil
		if changed then
			pruneQueue(tag)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Seed migration: existing province.buildings + tradeGood -> districts (idempotent, once per boot).
-- ---------------------------------------------------------------------------

local BUILDING_TO_DISTRICT = {
	marketplace = "Manufacturing",
	workshop = "Industrial",
	granary = "Agricultural",
	barracks = "Military",
	stables = "Military",
	trading_port = "Harbor",
	-- tax_office: absorbed into base tax (no district)
}

local function seedProvince(province)
	if not province then
		return false
	end
	if province.districts and next(province.districts) ~= nil then
		return false -- already seeded / player-built: skip (idempotent)
	end
	local slots = slotCount(province)
	if slots <= 0 then
		return false
	end
	province.districts = province.districts or {}
	local used = 0
	local seen = {}
	local function place(dtype)
		if used >= slots or not dtype or seen[dtype] then
			return
		end
		seen[dtype] = true
		used += 1
		province.districts[used] = { type = dtype, level = 1 }
	end

	-- Priority 1: the extraction district for the province's tradeGood, so output survives Phase-4 gating.
	local ext = DistrictTypes.extractionDistrictFor(province.tradeGood)
	if ext then
		local def = DistrictTypes.types[ext]
		if not (def.requiresCoastal and province.coastal ~= true) then
			place(ext)
		end
	end

	-- Priority 2+: map existing constructed buildings.
	local btypes = (ctx.Bundle and ctx.Bundle.buildingTypes) or {}
	local mfgs = (ctx.Bundle and ctx.Bundle.manufactories) or {}
	for _, bid in (province.buildings or {}) do
		local dtype = BUILDING_TO_DISTRICT[bid]
		if not dtype then
			local bdef = btypes[bid]
			if bdef and bdef.manufactoryId then
				local mdef = mfgs[bdef.manufactoryId]
				if mdef then
					dtype = DistrictTypes.manufactoryFamilyFor(mdef.output)
				end
			end
		end
		place(dtype)
	end
	return used > 0
end

local function seedMigration()
	if not enabled() then
		return
	end
	local touched = 0
	for id, province in ctx.WorldState.allProvinces() do
		if province.ownerTag and province.ownerTag ~= "NONE" then
			if seedProvince(province) then
				ctx.WorldState.setProvince(id, province)
				touched += 1
			end
		end
	end
	for tag in ctx.WorldState.allCountries() do
		recomputeStats(tag)
		-- Refresh EconomySystem's tax/production cache so the freshly-seeded districts are reflected,
		-- regardless of whether EconomySystem's own start-callback (seedAllCountries) ran before or after us.
		if ctx.EconomySystem and ctx.EconomySystem.recomputeFor then
			ctx.EconomySystem.recomputeFor(tag)
		end
	end
	if touched > 0 then
		print(string.format("[DistrictSystem] seed migration: seeded districts in %d provinces", touched))
	end
end

-- ---------------------------------------------------------------------------
-- Event reactions (keep districtStats fresh)
-- ---------------------------------------------------------------------------

local function onProvinceDistrictChanged(payload)
	if not payload or payload.provinceId == nil then
		return
	end
	local p = ctx.WorldState.getProvince(payload.provinceId)
	if p and p.ownerTag then
		recomputeStats(p.ownerTag)
	end
end

local function onOwnershipChanged(payload)
	if not payload then
		return
	end
	if payload.oldOwner then
		recomputeStats(payload.oldOwner)
	end
	if payload.newOwner then
		recomputeStats(payload.newOwner)
	end
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

DistrictSystem.buildDistrict = function(...)
	return buildDistrict(...)
end
DistrictSystem.upgradeDistrict = function(...)
	return upgradeDistrict(...)
end
DistrictSystem.upgradeDistrictAll = function(...)
	return upgradeDistrictAll(...)
end
DistrictSystem.razeDistrict = function(...)
	return razeDistrict(...)
end
DistrictSystem.recomputeStats = function(...)
	return recomputeStats(...)
end
DistrictSystem.seedMigration = function()
	return seedMigration()
end

function DistrictSystem.register(context)
	ctx = context
	context.DistrictSystem = {
		buildDistrict = buildDistrict,
		upgradeDistrict = upgradeDistrict,
		upgradeDistrictAll = upgradeDistrictAll,
		razeDistrict = razeDistrict,
		recomputeStats = recomputeStats,
		seedMigration = seedMigration,
	}

	context.EventBus.subscribe(context.Channels.ProvinceDistrictChanged, onProvinceDistrictChanged)
	context.EventBus.subscribe(context.Channels.DistrictUpgraded, function(payload)
		if payload and payload.tag then
			recomputeStats(payload.tag)
		end
	end)
	context.EventBus.subscribe(context.Channels.ProvinceOwnershipChanged, onOwnershipChanged)

	context.TickScheduler.register({
		id = "DistrictSystem",
		priority = 35,
		updateIntervalSeconds = context.WorldConstants.BuildingTickInterval or 3,
		update = tickQueues,
		start = seedMigration,
	})
end

return DistrictSystem
