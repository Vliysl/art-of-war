local BuildingSystem = {}

local ctx
local nextTicketSeq = 0
local queuesByCountry = {}

local function generateTicketId(tag)
	nextTicketSeq += 1
	return string.format("build_%s_%d", tag, nextTicketSeq)
end

local function buildingOf(buildingId)
	local bundle = ctx.Bundle
	return bundle and bundle.buildingTypes and bundle.buildingTypes[buildingId] or nil
end

local function alreadyBuilt(province, buildingId)
	local list = province.buildings
	if not list then return false end
	for _, id in list do
		if id == buildingId then return true end
	end
	return false
end

local function meetsPrereqs(province, building)
	if not building.requires then return true end
	local list = province.buildings or {}
	local set = {}
	for _, id in list do set[id] = true end
	for _, prereq in building.requires do
		if not set[prereq] then return false, prereq end
	end
	return true
end

local function provinceSupportsBuild(province, building, tag)
	if not province then return false, "unknown_province" end
	if province.ownerTag ~= tag then return false, "not_owner" end
	if province.controllerTag ~= tag then return false, "not_controller" end
	if (province.infraTier or 0) < (building.infraRequirement or 0) then
		return false, "insufficient_infra"
	end
	if building.requiresCoastal and province.coastal ~= true then
		return false, "requires_coastal"
	end
	if not building.repeatable and alreadyBuilt(province, building.id) then return false, "already_built" end
	if building.grantsDevTier and (province.devTier or 0) >= (ctx.WorldConstants.DevTierMax or 10) then
		return false, "dev_tier_max"
	end
	if building.grantsInfraTier and (province.infraTier or 0) >= (ctx.WorldConstants.InfraTierMax or 10) then
		return false, "infra_tier_max"
	end
	local ok, missing = meetsPrereqs(province, building)
	if not ok then return false, "missing_prereq:" .. tostring(missing) end
	return true
end

local function canAfford(country, building)
	if (country.treasury or 0) < (building.cost or 0) then
		return false, "insufficient_treasury"
	end
	return true
end

local function pruneCountryQueue(tag)
	local country = ctx.WorldState.getCountry(tag)
	if not country then return end
	local items = {}
	local queue = queuesByCountry[tag] or {}
	for _, t in queue do
		table.insert(items, {
			id = t.id,
			buildingId = t.buildingId,
			provinceId = t.provinceId,
			startedAt = t.startedAt,
			completesAt = t.completesAt,
			paused = t.paused,
			remaining = t.remaining,
		})
	end
	country.buildQueue = items
	ctx.WorldState.setCountry(tag, country)
end

-- Occupation freeze (EnableOccupationFreeze): losing control of a province PAUSES its
-- construction (progress banked as `remaining`); recapture -- including white-peace
-- reversion, which publishes the same ProvinceOccupied channel -- resumes with the banked
-- time. Only the owner can hold tickets at a province, so the tag<->newController compare
-- is exact.
local function onProvinceOccupied(payload)
	if not ctx.WorldConstants.EnableOccupationFreeze then return end
	if not payload or payload.provinceId == nil then return end
	local pid = payload.provinceId
	local now = ctx.TickScheduler.getSimTime()
	for tag, queue in pairs(queuesByCountry) do
		local changed = false
		for _, t in queue do
			if t.provinceId == pid then
				if tag == payload.newController then
					if t.paused then
						t.completesAt = now + (t.remaining or 0)
						t.paused = nil
						t.remaining = nil
						changed = true
					end
				elseif not t.paused then
					t.paused = true
					t.remaining = math.max(0, t.completesAt - now)
					changed = true
				end
			end
		end
		if changed then pruneCountryQueue(tag) end
	end
end

-- One-time sweep when the freeze turns on (pause tickets in already-occupied provinces);
-- when it turns back off, unpause everything so no ticket is stranded.
local freezeSweepDone = false
local function occupationFreezeSweep()
	local now = ctx.TickScheduler.getSimTime()
	if not ctx.WorldConstants.EnableOccupationFreeze then
		freezeSweepDone = false
		for tag, queue in pairs(queuesByCountry) do
			local changed = false
			for _, t in queue do
				if t.paused then
					t.completesAt = now + (t.remaining or 0)
					t.paused = nil
					t.remaining = nil
					changed = true
				end
			end
			if changed then pruneCountryQueue(tag) end
		end
		return
	end
	if freezeSweepDone then return end
	freezeSweepDone = true
	for tag, queue in pairs(queuesByCountry) do
		local changed = false
		for _, t in queue do
			local prov = ctx.WorldState.getProvince(t.provinceId)
			if not t.paused and prov and prov.controllerTag ~= tag then
				t.paused = true
				t.remaining = math.max(0, t.completesAt - now)
				changed = true
			end
		end
		if changed then pruneCountryQueue(tag) end
	end
end

local function fulfilBuilding(ticket)
	local province = ctx.WorldState.getProvince(ticket.provinceId)
	if not province then return end
	if alreadyBuilt(province, ticket.buildingId) then return end
	local building = buildingOf(ticket.buildingId)
	if not (building and building.repeatable) then
		province.buildings = province.buildings or {}
		table.insert(province.buildings, ticket.buildingId)
	end
	if building then
		if building.grantsFortTier then
			province.fortTier = math.max(province.fortTier or 0, building.grantsFortTier)
		end
		if building.grantsShipyard then
			province.hasShipyard = true
		end
		if building.grantsDevTier then
			local cap = ctx.WorldConstants.DevTierMax or 10
			province.devTier = math.min(cap, (province.devTier or 0) + building.grantsDevTier)
			ctx.EventBus.publish(ctx.Channels.ProvinceDevelopmentChanged, {
				provinceId = ticket.provinceId,
				devTier = province.devTier,
			})
		end
		if building.grantsInfraTier then
			local cap = ctx.WorldConstants.InfraTierMax or 10
			province.infraTier = math.min(cap, (province.infraTier or 0) + building.grantsInfraTier)
		end
	end

	ctx.WorldState.setProvince(ticket.provinceId, province)
	ctx.EventBus.publish(ctx.Channels.BuildingCompleted, {
		tag = ticket.tag,
		buildingId = ticket.buildingId,
		provinceId = ticket.provinceId,
	})
end

local function totalLinesAt(tag, provinceId)
	local lines = 0
	local building = ctx.BuildingSystem
	if building and building.queueLengthAt then
		lines += building.queueLengthAt(tag, provinceId)
	end
	local recruit = ctx.RecruitSystem
	if recruit and recruit.queueLengthAt then
		lines += recruit.queueLengthAt(tag, provinceId)
	end
	local naval = ctx.NavalSystem
	if naval and naval.queueLengthAt then
		lines += naval.queueLengthAt(tag, provinceId)
	end
	return lines
end

local function enqueue(tag, provinceId, buildingId)
	local building = buildingOf(buildingId)
	if not building then return false, "unknown_building" end

	-- Economy rework: district-absorbed buildings (base buildings + manufactories, flagged in
	-- Data/BuildingTypes with absorbedByDistrict) are built as districts now, not through this system.
	-- Reject them at the remote so a crafted client call can't construct a phased-out building while
	-- DistrictsPlayable is on. Districts are seeded/placed directly, never via enqueue, so this is safe.
	if ctx.WorldConstants.DistrictsPlayable and building.absorbedByDistrict then
		return false, "absorbed_into_district"
	end

	local province = ctx.WorldState.getProvince(provinceId)
	local ok, reason = provinceSupportsBuild(province, building, tag)
	if not ok then return false, reason end

	local country = ctx.WorldState.getCountry(tag)
	if not country then return false, "unknown_country" end

	local cap = math.max(1, province.devTier or 1)
	if totalLinesAt(tag, provinceId) >= cap then
		return false, "production_lines_full"
	end

	local affordOk, affordReason = canAfford(country, building)
	if not affordOk then return false, affordReason end

	country.treasury = (country.treasury or 0) - (building.cost or 0)
	ctx.WorldState.setCountry(tag, country)

	local secondsPerDay = ctx.WorldConstants.SecondsPerSimTick / ctx.WorldConstants.DaysPerEarlyTick
	local completesAt = ctx.TickScheduler.getSimTime() + (building.buildDays or 90) * secondsPerDay
	local ticket = {
		id = generateTicketId(tag),
		tag = tag,
		provinceId = provinceId,
		buildingId = buildingId,
		startedAt = ctx.TickScheduler.getSimTime(),
		completesAt = completesAt,
	}
	local queue = queuesByCountry[tag] or {}
	table.insert(queue, ticket)
	queuesByCountry[tag] = queue
	pruneCountryQueue(tag)

	ctx.EventBus.publish(ctx.Channels.BuildingQueued, {
		tag = tag, ticketId = ticket.id,
		buildingId = buildingId, provinceId = provinceId,
		completesAt = completesAt,
	})
	return true, ticket.id
end

local function cancel(tag, ticketId)
	local queue = queuesByCountry[tag]
	if not queue then return false, "no_queue" end
	for i, t in queue do
		if t.id == ticketId then
			table.remove(queue, i)
			local building = buildingOf(t.buildingId)
			local country = ctx.WorldState.getCountry(tag)
			if country and building then
				country.treasury = (country.treasury or 0) + math.floor((building.cost or 0) * 0.5)
				ctx.WorldState.setCountry(tag, country)
			end
			pruneCountryQueue(tag)
			ctx.EventBus.publish(ctx.Channels.BuildingCancelled, {
				tag = tag, ticketId = ticketId,
				buildingId = t.buildingId, provinceId = t.provinceId,
			})
			return true
		end
	end
	return false, "ticket_not_found"
end

local function tickQueues()
	occupationFreezeSweep()
	local now = ctx.TickScheduler.getSimTime()
	for tag, queue in queuesByCountry do
		local kept = {}
		local fulfilled = false
		for _, t in queue do
			if t.paused then
				local prov = ctx.WorldState.getProvince(t.provinceId)
				if prov and prov.ownerTag ~= t.tag then
					-- The province was ceded away permanently (annex/peace), not just occupied:
					-- the paused ticket can never resume. Cancel with the manual-cancel refund.
					local building = buildingOf(t.buildingId)
					local country = ctx.WorldState.getCountry(t.tag)
					if country and building then
						country.treasury = (country.treasury or 0) + math.floor((building.cost or 0) * 0.5)
						ctx.WorldState.setCountry(t.tag, country)
					end
					ctx.EventBus.publish(ctx.Channels.BuildingCancelled, {
						tag = t.tag, ticketId = t.id,
						buildingId = t.buildingId, provinceId = t.provinceId,
						reason = "province_ceded",
					})
					fulfilled = true
				else
					table.insert(kept, t)
				end
			elseif now >= t.completesAt then
				fulfilBuilding(t)
				fulfilled = true
			else
				table.insert(kept, t)
			end
		end
		if #kept == 0 then
			queuesByCountry[tag] = nil
		else
			queuesByCountry[tag] = kept
		end
		if fulfilled then pruneCountryQueue(tag) end
	end
end

local function queueLengthAt(tag, provinceId)
	local queue = queuesByCountry[tag]
	if not queue then return 0 end
	local n = 0
	for _, t in queue do
		if t.provinceId == provinceId then n += 1 end
	end
	return n
end

local function queuesOf(tag)
	return queuesByCountry[tag] or {}
end

BuildingSystem.enqueue = function(...) return enqueue(...) end
BuildingSystem.cancel = function(...) return cancel(...) end
BuildingSystem.queuesOf = function(...) return queuesOf(...) end
BuildingSystem.queueLengthAt = function(...) return queueLengthAt(...) end

function BuildingSystem.register(context)
	ctx = context
	context.BuildingSystem = {
		enqueue = enqueue,
		cancel = cancel,
		queuesOf = queuesOf,
		queueLengthAt = queueLengthAt,
	}
	context.EventBus.subscribe(context.Channels.ProvinceOccupied, onProvinceOccupied)
	context.TickScheduler.register({
		id = "BuildingSystem",
		priority = 34,
		updateIntervalSeconds = context.WorldConstants.BuildingTickInterval or 3,
		update = tickQueues,
	})
end

return BuildingSystem
