local RecruitSystem = {}

local ctx
local nextTicketSeq = 0
local queuesByCountry = {}

local function generateTicketId(tag)
	nextTicketSeq += 1
	return string.format("recruit_%s_%d", tag, nextTicketSeq)
end

local function pruneCountryQueue(tag)
	local country = ctx.WorldState.getCountry(tag)
	if not country then
		return
	end
	local items = {}
	local queue = queuesByCountry[tag] or {}
	for _, t in queue do
		table.insert(items, {
			id = t.id,
			unitTypeId = t.unitTypeId,
			count = t.count,
			provinceId = t.provinceId,
			queuedAt = t.queuedAt,
			completesAt = t.completesAt,
		})
	end
	country.recruitQueue = items
	ctx.WorldState.setCountry(tag, country)
end

local function queueLengthAt(tag, provinceId)
	local queue = queuesByCountry[tag]
	if not queue then
		return 0
	end
	local n = 0
	for _, t in queue do
		if t.provinceId == provinceId then
			n += 1
		end
	end
	return n
end

local function totalLinesAt(tag, provinceId)
	local lines = queueLengthAt(tag, provinceId)
	if ctx.BuildingSystem and ctx.BuildingSystem.queueLengthAt then
		lines += ctx.BuildingSystem.queueLengthAt(tag, provinceId)
	end
	if ctx.NavalSystem and ctx.NavalSystem.queueLengthAt then
		lines += ctx.NavalSystem.queueLengthAt(tag, provinceId)
	end
	return lines
end

local function unitOf(unitTypeId)
	local bundle = ctx.Bundle
	return bundle and bundle.unitTypes and bundle.unitTypes[unitTypeId] or nil
end

-- ---------------------------------------------------------------------
-- Manpower: a single UNIFIED national pool (country.manpower) capped by
-- country.manpowerCap. The cap is population-based -- each owned+controlled
-- province contributes floor(population * ManpowerPopFraction), then a nation
-- holding any land is floored at ManpowerNationFloor. The old levy/professional split is gone: every unit
-- draws from country.manpower. Regen is continuous (RoN-style) toward the cap.
-- (The legacy province baseManpower factor is no longer used.)
-- ---------------------------------------------------------------------
local function poolFieldForUnit(_unit)
	return "manpower"
end

local function provinceManpowerContribution(province)
	local C = ctx.WorldConstants
	local pop = province.population or 0
	local frac = C.ManpowerPopFraction or 0.02
	return math.floor(pop * frac) -- no per-province floor; the 5K floor is applied per-NATION below
end

-- Recompute every country's manpowerCap from owned+controlled provinces (occupied or
-- foreign-controlled provinces contribute 0). Clamps current manpower down when the cap
-- shrinks (lost land -> lost reserve).
local function recomputeManpowerCaps(relevant)
	local caps = {}
	-- A nation holding ANY owned+controlled land is floored at ManpowerNationFloor (5K by default); a landless
	-- nation stays at 0. (This replaced the old per-province 5K floor, which scaled the minimum with tile count.)
	local nationFloor = ctx.WorldConstants.ManpowerNationFloor or 5000
	-- perf: iterate each country's owned provinces via the O(1) registry instead of scanning all
	-- ~5713 provinces. byOwner is the owned set; still require controllerTag == owner (occupied
	-- provinces contribute 0). Falls back to a full scan if the registry is unavailable.
	-- S3: `relevant` (the claimed / at-war set) gates the walk to hot countries -- the monthly
	-- all-907-country recompute was a measured server-frame spike at high sim speed. nil = compute every
	-- country (used on first boot to seed all pools; see manpowerTick).
	local registry = ctx.ProvinceRegistry
	if registry and registry.byOwner then
		for _, country in ctx.WorldState.allCountries() do
			local tag = country.tag
			if relevant and not relevant[tag] then
				continue
			end
			local total, ownsAny = 0, false
			for _, id in ipairs(registry.byOwner(tag)) do
				local province = ctx.WorldState.getProvince(id)
				if province and province.controllerTag == tag then
					ownsAny = true
					total += provinceManpowerContribution(province)
				end
			end
			caps[tag] = ownsAny and math.max(total, nationFloor) or 0
		end
	else
		for _, province in ctx.WorldState.allProvinces() do
			local owner = province.ownerTag
			if owner and province.controllerTag == owner then
				caps[owner] = (caps[owner] or 0) + provinceManpowerContribution(province)
			end
		end
		-- Any owner present in `caps` holds >=1 controlled province, so floor its national cap.
		for owner, total in caps do
			caps[owner] = math.max(total, nationFloor)
		end
	end
	for _, country in ctx.WorldState.allCountries() do
		if relevant and not relevant[country.tag] then
			continue
		end
		local cap = math.floor(caps[country.tag] or 0)
		local changed = false
		if country.manpowerCap ~= cap then
			country.manpowerCap = cap
			changed = true
		end
		if (country.manpower or 0) > cap then
			country.manpower = cap
			changed = true
		end
		if changed then
			ctx.WorldState.setCountry(country.tag, country)
		end
	end
end

-- Convert a system tick's sim-second delta into in-game days (mirrors TickScheduler's
-- dayAccumulator: 1 unit of effectiveDelta/SecondsPerSimTick == daysPerTick days).
local function inGameDaysFromDelta(deltaSeconds, year)
	local C = ctx.WorldConstants
	local secs = C.SecondsPerSimTick or 1.5
	if secs <= 0 or not deltaSeconds or deltaSeconds <= 0 then
		return 0
	end
	local daysPerTick = (year <= (C.EarlyEraCutoffYear or 0)) and (C.DaysPerEarlyTick or 1) or (C.DaysPerLateTick or 1)
	return (deltaSeconds / secs) * daysPerTick
end

-- Continuous (RoN-style) regen of the unified pool toward the cap, paced by in-game days so it
-- respects pause/speed. Also clamps current down if the cap shrank.
local function regenManpower(systemCtx)
	local C = ctx.WorldConstants
	local perDay = C.ManpowerRegenPerDay or 0.003
	local year = (systemCtx and systemCtx.gameDate and systemCtx.gameDate.year) or 0
	local frac = perDay * inGameDaysFromDelta(systemCtx and systemCtx.deltaSeconds, year)
	-- S3: only relevant (claimed / at-war) countries regen manpower per tick; frozen countries hold their
	-- pool (no AI recruits for them, and it is re-derived on claim). This is a per-tick all-countries walk,
	-- so gating it matches the S3 freeze applied in Economy/Faction/Unrest. (The monthly cap recompute is
	-- intentionally left ungated: on first boot relevantSet() is empty, and it seeds every country's pool.)
	local relevant = ctx.PlayerAuthority and ctx.PlayerAuthority.relevantSet and ctx.PlayerAuthority.relevantSet()
		or nil
	for _, country in ctx.WorldState.allCountries() do
		if relevant and not relevant[country.tag] then
			continue
		end
		local cap = country.manpowerCap or 0
		local cur = country.manpower or 0
		local newCur = cur
		if cur > cap then
			newCur = cap
		elseif cur < cap and frac > 0 then
			newCur = math.min(cap, cur + cap * frac)
		end
		if newCur ~= cur then
			country.manpower = newCur
			ctx.WorldState.setCountry(country.tag, country)
		end
	end
end

-- Recompute caps on first run + each in-game month (land changes are rare); regen continuously every
-- tick. On first run, start every country at full manpower (discards the static data-editor seed).
local lastManpowerMonthIndex = nil
local manpowerInited = false
local function manpowerTick(systemCtx)
	local gd = systemCtx and systemCtx.gameDate
	local idx = gd and (gd.year * 12 + (gd.month - 1)) or nil
	if not manpowerInited or (idx and idx ~= lastManpowerMonthIndex) then
		-- Gate the monthly recompute to relevant (claimed / at-war) countries -- the ~907-country monthly
		-- sweep was a measured spike at high sim speed. EXCEPT on first boot: relevantSet() is empty then, so
		-- pass nil to compute EVERY country's cap once (that first pass seeds all the pools below).
		local relevant = manpowerInited
				and ctx.PlayerAuthority
				and ctx.PlayerAuthority.relevantSet
				and ctx.PlayerAuthority.relevantSet()
			or nil
		recomputeManpowerCaps(relevant)
		lastManpowerMonthIndex = idx
	end
	if not manpowerInited then
		manpowerInited = true
		for _, country in ctx.WorldState.allCountries() do
			country.manpower = country.manpowerCap or 0
			ctx.WorldState.setCountry(country.tag, country)
		end
		return
	end
	regenManpower(systemCtx)
end

local function provinceSupportsRecruit(province, tag)
	if not province then
		return false
	end
	if province.ownerTag ~= tag then
		return false
	end
	if province.controllerTag ~= tag then
		return false
	end
	-- City + infrastructure-tier requirements lifted: any owned & controlled province may recruit.
	-- Production-line capacity (devTier-based) is still the natural pacing constraint.
	return true
end

local function canAfford(country, unit, count)
	local totalCost = unit.recruitCost * count
	local totalManpower = unit.recruitManpower * count
	if (country.treasury or 0) < totalCost then
		return false, "insufficient_treasury"
	end
	local pool = poolFieldForUnit(unit)
	if (country[pool] or 0) < totalManpower then
		return false, (pool == "levyManpower") and "insufficient_levies" or "insufficient_manpower"
	end
	return true
end

local function deduct(country, unit, count)
	country.treasury = (country.treasury or 0) - (unit.recruitCost * count)
	local pool = poolFieldForUnit(unit)
	country[pool] = (country[pool] or 0) - (unit.recruitManpower * count)
end

local function fulfilTicket(ticket)
	local tag = ticket.tag
	local army = ctx.ArmySystem.findFriendlyArmyAt(tag, ticket.provinceId)
	if not army then
		local composition = { [ticket.unitTypeId] = ticket.count }
		army = ctx.ArmySystem.createArmy(tag, ticket.provinceId, composition)
	else
		ctx.ArmySystem.addRegiments(army.id, ticket.unitTypeId, ticket.count)
	end
	ctx.EventBus.publish(ctx.Channels.RegimentRecruited, {
		tag = tag,
		unitTypeId = ticket.unitTypeId,
		count = ticket.count,
		provinceId = ticket.provinceId,
		armyId = army and army.id or nil,
	})
	pruneCountryQueue(tag)
end

local function cancelQueueForCountry(tag, reason)
	local queue = queuesByCountry[tag]
	if not queue then
		return
	end
	for _, ticket in queue do
		ctx.EventBus.publish(ctx.Channels.RegimentRecruitCancelled, {
			tag = tag,
			ticketId = ticket.id,
			reason = reason or "cancelled",
		})
	end
	queuesByCountry[tag] = nil
end

-- Economy rework (D4): professional units need a Military district; only levy (militia/irregular) do not.
local function provinceHasMilitaryDistrict(province)
	local districts = province and province.districts
	if not districts then
		return false
	end
	for _, entry in pairs(districts) do
		if type(entry) == "table" and entry.type == "Military" and (entry.level or 0) >= 1 then
			return true
		end
	end
	return false
end

local function enqueue(tag, provinceId, unitTypeId, count)
	if type(count) ~= "number" or count < 1 then
		return false, "bad_count"
	end
	count = math.floor(count)
	local unit = unitOf(unitTypeId)
	if not unit then
		return false, "unknown_unit"
	end
	if unit.unlockedByDefault == false then
		return false, "unit_locked"
	end

	local province = ctx.WorldState.getProvince(provinceId)
	if not province then
		return false, "unknown_province"
	end
	if not provinceSupportsRecruit(province, tag) then
		return false, "province_ineligible"
	end

	-- GateRecruitOnMilitary: without a Military district a province may raise ONLY levy (militia/irregular).
	if ctx.WorldConstants and ctx.WorldConstants.GateRecruitOnMilitary then
		local needsMilitary = unit.requiresDistrict == "Military" or unit.class ~= "levy"
		if needsMilitary and not provinceHasMilitaryDistrict(province) then
			return false, "district_required:Military"
		end
	end

	local country = ctx.WorldState.getCountry(tag)
	if not country then
		return false, "unknown_country"
	end

	local cap = math.max(1, province.devTier or 1)
	if totalLinesAt(tag, provinceId) >= cap then
		return false, "production_lines_full"
	end

	local ok, reason = canAfford(country, unit, count)
	if not ok then
		return false, reason
	end

	deduct(country, unit, count)
	ctx.WorldState.setCountry(tag, country)

	local completesAt = ctx.TickScheduler.getSimTime()
		+ unit.recruitTicks * (ctx.WorldConstants.RecruitTickInterval or 3)
	local ticket = {
		id = generateTicketId(tag),
		tag = tag,
		provinceId = provinceId,
		unitTypeId = unitTypeId,
		count = count,
		queuedAt = ctx.TickScheduler.getSimTime(),
		completesAt = completesAt,
	}
	local queue = queuesByCountry[tag] or {}
	table.insert(queue, ticket)
	queuesByCountry[tag] = queue
	pruneCountryQueue(tag)
	ctx.EventBus.publish(ctx.Channels.RegimentRecruitQueued, {
		tag = tag,
		ticketId = ticket.id,
		unitTypeId = unitTypeId,
		count = count,
		provinceId = provinceId,
		completesAt = completesAt,
	})
	return true, ticket.id
end

local function cancelTicket(tag, ticketId, reason)
	local queue = queuesByCountry[tag]
	if not queue then
		return false, "no_queue"
	end
	for i, ticket in ipairs(queue) do
		if ticket.id == ticketId then
			-- Refund treasury + manpower (full refund — design choice for v1)
			local country = ctx.WorldState.getCountry(tag)
			local unit = unitOf(ticket.unitTypeId)
			if country and unit then
				country.treasury = (country.treasury or 0) + unit.recruitCost * ticket.count
				local pool = poolFieldForUnit(unit)
				country[pool] = (country[pool] or 0) + unit.recruitManpower * ticket.count
				ctx.WorldState.setCountry(tag, country)
			end
			table.remove(queue, i)
			if #queue == 0 then
				queuesByCountry[tag] = nil
			end
			pruneCountryQueue(tag)
			ctx.EventBus.publish(ctx.Channels.RegimentRecruitCancelled, {
				tag = tag,
				ticketId = ticketId,
				reason = reason or "cancelled",
				provinceId = ticket.provinceId,
				unitTypeId = ticket.unitTypeId,
				count = ticket.count,
			})
			return true
		end
	end
	return false, "no_ticket"
end

-- Occupation freeze (EnableOccupationFreeze): losing control of a province CANCELS its
-- recruitment (full refund via cancelTicket) -- the levies scatter. Only the owner can ever
-- hold tickets at a province (enqueue requires owner+controller), so cancelling every
-- non-new-controller ticket at the tile is exact.
local function cancelTicketsAt(provinceId, keepTag, reason)
	local pending = {}
	for tag, queue in pairs(queuesByCountry) do
		if tag ~= keepTag then
			for _, ticket in ipairs(queue) do
				if ticket.provinceId == provinceId then
					pending[#pending + 1] = { tag = tag, id = ticket.id }
				end
			end
		end
	end
	for _, entry in ipairs(pending) do
		cancelTicket(entry.tag, entry.id, reason)
	end
end

local function onProvinceOccupied(payload)
	if not ctx.WorldConstants.EnableOccupationFreeze then
		return
	end
	if not payload or payload.provinceId == nil then
		return
	end
	cancelTicketsAt(payload.provinceId, payload.newController, "occupied")
end

-- One-time sweep when the freeze turns on: cancel tickets in provinces that were already
-- occupied before the flag shipped (the subscription only catches future flips).
local occupationSweepDone = false
local function occupationFreezeSweep()
	if not ctx.WorldConstants.EnableOccupationFreeze then
		occupationSweepDone = false
		return
	end
	if occupationSweepDone then
		return
	end
	occupationSweepDone = true
	local pending = {}
	for tag, queue in pairs(queuesByCountry) do
		for _, ticket in ipairs(queue) do
			local prov = ctx.WorldState.getProvince(ticket.provinceId)
			if prov and prov.controllerTag ~= tag then
				pending[#pending + 1] = { tag = tag, id = ticket.id }
			end
		end
	end
	for _, entry in ipairs(pending) do
		cancelTicket(entry.tag, entry.id, "occupied")
	end
end

local function tickQueues()
	occupationFreezeSweep()
	local now = ctx.TickScheduler.getSimTime()
	for tag, queue in queuesByCountry do
		local kept = {}
		local hadFulfilment = false
		for _, ticket in queue do
			if now >= ticket.completesAt then
				fulfilTicket(ticket)
				hadFulfilment = true
			else
				table.insert(kept, ticket)
			end
		end
		if #kept == 0 then
			queuesByCountry[tag] = nil
		else
			queuesByCountry[tag] = kept
		end
		-- Re-publish country.recruitQueue AFTER queuesByCountry is updated, so completed tickets
		-- are removed from the replicated view. fulfilTicket() prunes earlier but with the stale queue.
		if hadFulfilment then
			pruneCountryQueue(tag)
		end
	end
end

local function queuesOf(tag)
	return queuesByCountry[tag] or {}
end

function RecruitSystem.register(context)
	ctx = context
	context.RecruitSystem = {
		enqueue = enqueue,
		queuesOf = queuesOf,
		queueLengthAt = queueLengthAt,
		cancelQueueForCountry = cancelQueueForCountry,
		cancelTicket = cancelTicket,
		recomputeManpowerCaps = recomputeManpowerCaps,
	}
	for k, v in pairs(context.RecruitSystem) do
		RecruitSystem[k] = v
	end
	context.EventBus.subscribe(context.Channels.ProvinceOccupied, onProvinceOccupied)
	context.TickScheduler.register({
		id = "RecruitSystem",
		priority = 32,
		updateIntervalSeconds = context.WorldConstants.RecruitTickInterval or 3,
		update = tickQueues,
	})

	context.TickScheduler.register({
		id = "ManpowerRegen",
		priority = 33,
		updateIntervalSeconds = context.WorldConstants.ManpowerRegenTickInterval or 6,
		update = manpowerTick,
	})

	-- Self-register CancelRecruit remote (idempotent — skips if Bootstrap created it)
	local rs = game:GetService("ReplicatedStorage")
	local aow = rs:FindFirstChild("ArtOfWar")
	local remotes = aow and aow:FindFirstChild("Remotes")
	if remotes and not remotes:FindFirstChild("CancelRecruit") then
		if context.InputValidator and context.InputValidator.register then
			context.InputValidator.register("CancelRecruit", {
				schema = { { name = "ticketId", type = "string" } },
				rate = { count = 6, window = 15 },
			})
		end
		local r = Instance.new("RemoteEvent")
		r.Name = "CancelRecruit"
		r.Parent = remotes
		r.OnServerEvent:Connect(function(player, ticketId)
			if
				context.InputValidator
				and context.InputValidator.accept
				and not context.InputValidator.accept(player, "CancelRecruit", ticketId)
			then
				return
			end
			if not context.PlayerAuthority or not context.PlayerAuthority.tagFor then
				return
			end
			local tag = context.PlayerAuthority.tagFor(player)
			if not tag then
				return
			end
			cancelTicket(tag, ticketId)
		end)
	end
end

return RecruitSystem
