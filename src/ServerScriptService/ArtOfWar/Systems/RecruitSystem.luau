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
	if not country then return end
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
	if not queue then return 0 end
	local n = 0
	for _, t in queue do
		if t.provinceId == provinceId then n += 1 end
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
-- Manpower pools: Levies vs Professionals (spec 6.5.2 / B.5, Phase 4).
-- unit.class ("levy"|"professional") picks the country pool field:
--   levy -> country.levyManpower (capped by country.levyCap from provinces)
--   professional -> country.manpower (the existing pool; legacy behavior)
-- ---------------------------------------------------------------------
local function poolFieldForUnit(unit)
    if unit and unit.class == "levy" then return "levyManpower" end
    return "manpower"
end

local function isAcceptedCulture(country, cultureId)
    if not cultureId then return true end
    if country.primaryCulture == cultureId then return true end
    local accepted = country.acceptedCultures
    if type(accepted) == "table" then
        for _, c in ipairs(accepted) do
            if c == cultureId then return true end
        end
        if accepted[cultureId] then return true end
    end
    return false
end

local function provinceLevyContribution(province, country)
    local C = ctx.WorldConstants
    local baseMP = province.baseManpower or 0
    if baseMP <= 0 then return 0 end
    local devTier = province.devTier or 1
    local devFactor = 1 + math.max(0, devTier - 1) * (C.LevyDevFactorPerTier or 0.1)
    local cultureMod = isAcceptedCulture(country, province.culture) and 1 or (C.LevyForeignCultureMod or 0.5)
    local autonomy = math.clamp(province.autonomy or 0, 0, 1)
    local autonomyMod = 1 - autonomy * (C.LevyAutonomyMaxReduction or 1.0)
    local conscription = C.LevyConscriptionDefault or 1.0
    return baseMP * (C.LevyManpowerPerBaseMP or 250) * devFactor * cultureMod * autonomyMod * conscription
end

-- Recompute every country's levyCap from owned+controlled provinces (occupied or
-- foreign-controlled provinces contribute 0). Lazy-inits levyManpower (starts full)
-- and clamps it down when the cap shrinks (lost land -> lost levy reserve).
local function recomputeLevyCaps()
    local caps = {}
    for _, province in ctx.WorldState.allProvinces() do
        local owner = province.ownerTag
        if owner and province.controllerTag == owner then
            local country = ctx.WorldState.getCountry(owner)
            if country then
                caps[owner] = (caps[owner] or 0) + provinceLevyContribution(province, country)
            end
        end
    end
    for _, country in ctx.WorldState.allCountries() do
        local cap = math.floor(caps[country.tag] or 0)
        local changed = false
        if country.levyCap ~= cap then country.levyCap = cap; changed = true end
        if country.levyManpower == nil then
            country.levyManpower = cap; changed = true
        elseif country.levyManpower > cap then
            country.levyManpower = cap; changed = true
        end
        if changed then ctx.WorldState.setCountry(country.tag, country) end
    end
end

-- Monthly regen: levies regen LevyRegenPerMonthPct of cap; professionals only if a
-- professionalCap + ProfessionalRegenPerMonthPct are set (HOOK, off by default).
local function regenManpower()
    local C = ctx.WorldConstants
    recomputeLevyCaps()
    local levyPct = C.LevyRegenPerMonthPct or 0.05
    local proPct = C.ProfessionalRegenPerMonthPct or 0
    for _, country in ctx.WorldState.allCountries() do
        local changed = false
        local cap = country.levyCap or 0
        local cur = country.levyManpower or 0
        if cur < cap then
            country.levyManpower = math.min(cap, cur + cap * levyPct)
            changed = true
        end
        if proPct > 0 and country.professionalCap and (country.manpower or 0) < country.professionalCap then
            country.manpower = math.min(country.professionalCap, (country.manpower or 0) + country.professionalCap * proPct)
            changed = true
        end
        if changed then ctx.WorldState.setCountry(country.tag, country) end
    end
end

-- Fires every ManpowerRegenTickInterval but only ACTS on an in-game month change
-- (mirrors ArmySystem's year*12+month month-index pattern). First run inits caps.
local lastManpowerMonthIndex = nil
local function manpowerTick(systemCtx)
    local gd = systemCtx and systemCtx.gameDate
    local idx = gd and (gd.year * 12 + (gd.month - 1)) or nil
    if idx == nil then
        if lastManpowerMonthIndex == nil then lastManpowerMonthIndex = -1; recomputeLevyCaps() end
        return
    end
    if lastManpowerMonthIndex == nil then
        lastManpowerMonthIndex = idx
        recomputeLevyCaps()
        return
    end
    if idx > lastManpowerMonthIndex then
        lastManpowerMonthIndex = idx
        regenManpower()
    end
end

local function provinceSupportsRecruit(province, tag)
	if not province then return false end
	if province.ownerTag ~= tag then return false end
	if province.controllerTag ~= tag then return false end
	-- City + infrastructure-tier requirements lifted: any owned & controlled province may recruit.
	-- Production-line capacity (devTier-based) is still the natural pacing constraint.
	return true
end

local function canAfford(country, unit, count)
	local totalCost = unit.recruitCost * count
	local totalManpower = unit.recruitManpower * count
	if (country.treasury or 0) < totalCost then return false, "insufficient_treasury" end
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
	if not queue then return end
	for _, ticket in queue do
		ctx.EventBus.publish(ctx.Channels.RegimentRecruitCancelled, {
			tag = tag, ticketId = ticket.id, reason = reason or "cancelled",
		})
	end
	queuesByCountry[tag] = nil
end

local function enqueue(tag, provinceId, unitTypeId, count)
	if type(count) ~= "number" or count < 1 then return false, "bad_count" end
	count = math.floor(count)
	local unit = unitOf(unitTypeId)
	if not unit then return false, "unknown_unit" end
	if unit.unlockedByDefault == false then return false, "unit_locked" end

	local province = ctx.WorldState.getProvince(provinceId)
	if not province then return false, "unknown_province" end
	if not provinceSupportsRecruit(province, tag) then return false, "province_ineligible" end

	local country = ctx.WorldState.getCountry(tag)
	if not country then return false, "unknown_country" end

	local cap = math.max(1, province.devTier or 1)
	if totalLinesAt(tag, provinceId) >= cap then return false, "production_lines_full" end

	local ok, reason = canAfford(country, unit, count)
	if not ok then return false, reason end

	deduct(country, unit, count)
	ctx.WorldState.setCountry(tag, country)

	local completesAt = ctx.TickScheduler.getSimTime() + unit.recruitTicks * (ctx.WorldConstants.RecruitTickInterval or 3)
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
		tag = tag, ticketId = ticket.id,
		unitTypeId = unitTypeId, count = count, provinceId = provinceId,
		completesAt = completesAt,
	})
	return true, ticket.id
end

local function tickQueues()
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

local function cancelTicket(tag, ticketId)
	local queue = queuesByCountry[tag]
	if not queue then return false, "no_queue" end
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
			if #queue == 0 then queuesByCountry[tag] = nil end
			pruneCountryQueue(tag)
			ctx.EventBus.publish(ctx.Channels.RegimentRecruitCancelled, {
				tag = tag, ticketId = ticketId, reason = "cancelled",
			})
			return true
		end
	end
	return false, "no_ticket"
end

function RecruitSystem.register(context)
	ctx = context
	context.RecruitSystem = {
		enqueue = enqueue,
		queuesOf = queuesOf,
		queueLengthAt = queueLengthAt,
		cancelQueueForCountry = cancelQueueForCountry,
		cancelTicket = cancelTicket,
		recomputeLevyCaps = recomputeLevyCaps,
	}
	for k, v in pairs(context.RecruitSystem) do RecruitSystem[k] = v end
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
			if context.InputValidator and context.InputValidator.accept
				and not context.InputValidator.accept(player, "CancelRecruit", ticketId) then return end
			if not context.PlayerAuthority or not context.PlayerAuthority.tagFor then return end
			local tag = context.PlayerAuthority.tagFor(player)
			if not tag then return end
			cancelTicket(tag, ticketId)
		end)
	end
end

return RecruitSystem
