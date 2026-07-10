-- EventSystem — data-driven political events (the drama / teaching / pacing spine).
--
-- One event at a time per country (country.activeEvent). Players resolve via the
-- ResolveEvent remote; AI countries auto-resolve immediately with the safest
-- highest-aiWeight option; unresolved player events auto-resolve on their deadline.
-- Firing is gated to relevant (claimed / at-war) countries and throttled by a
-- per-country event clock, so there is no O(countries × events) scan.

local EventSystem = {}

local ctx
local rng

local function currentDay()
	local d = ctx.TickScheduler.getGameDate()
	return (d.year - 1) * 365 + (d.month - 1) * 30 + d.day
end

local function isPlayer(tag)
	return ctx.PlayerAuthority and ctx.PlayerAuthority.playerFor and ctx.PlayerAuthority.playerFor(tag) ~= nil
end

local function estateDisplayName(estateId)
	local def = ctx.Bundle and ctx.Bundle.factions and ctx.Bundle.factions[estateId]
	return (def and def.displayName) or estateId or "the estates"
end

local function leaderWord(country)
	local ga = ctx.Bundle and ctx.Bundle.governmentArchetypes
	if ga and ga.labelsFor then
		local labels = ga.labelsFor(country.governmentForm)
		if labels and labels.leaderWord then return labels.leaderWord end
	end
	return "ruler"
end

local function applyTokens(s, country, context)
	if type(s) ~= "string" then return s end
	local estateName = (context and context.estateId) and estateDisplayName(context.estateId) or "the estates"
	s = s:gsub("%%ESTATE%%", estateName)
	s = s:gsub("%%COUNTRY%%", country.displayName or country.tag or "the realm")
	-- Until Phase 3 rulers exist, %LEADER% reads as the lowercase archetype word ("ruler"/"chief"/
	-- "head of state") so it embeds cleanly mid-sentence (data text supplies any leading "The ").
	local ruler = country.ruler and (country.ruler.title .. " " .. (country.ruler.firstName or "")) or leaderWord(country):lower()
	s = s:gsub("%%LEADER%%", ruler)
	return s
end

-- Replace the special "$estate" key in an estate-keyed map with the context estate.
local function resolveEstateMap(map, context)
	if not map then return nil end
	local out = {}
	for k, v in map do
		if k == "$estate" then
			if context and context.estateId then out[context.estateId] = v end
		else
			out[k] = v
		end
	end
	return out
end

-- Apply a declarative EventEffects table to a country.
local function applyEffects(tag, effects, context)
	if not effects then return end
	local wc = ctx.WorldConstants
	local country = ctx.WorldState.getCountry(tag)
	if not country then return end

	local authorityChanged, unrestChanged = false, false
	if effects.authority then
		local cap = country.crownAuthorityCap or wc.CrownAuthorityCapBase
		country.crownAuthority = math.clamp((country.crownAuthority or wc.CrownAuthorityBase) + effects.authority, wc.CrownAuthorityMin, cap)
		authorityChanged = true
	end
	if effects.legitimacy then
		country.legitimacy = math.clamp((country.legitimacy or wc.LegitimacyBase) + effects.legitimacy, wc.LegitimacyMin, wc.LegitimacyMax)
	end
	if effects.stability then
		country.stability = math.clamp((country.stability or 0) + effects.stability, wc.StabilityMin, wc.StabilityMax)
	end
	if effects.unrest then
		country.unrest = math.clamp((country.unrest or 0) + effects.unrest, wc.UnrestMin, wc.UnrestMax)
		unrestChanged = true
	end
	if effects.treasury then
		country.treasury = math.max(0, (country.treasury or 0) + effects.treasury)
	end
	ctx.WorldState.setCountry(tag, country)

	if authorityChanged then
		ctx.EventBus.publish(ctx.Channels.CountryAuthorityChanged, { tag = tag, total = country.crownAuthority, cap = country.crownAuthorityCap, source = "event" })
	end
	if unrestChanged then
		ctx.EventBus.publish(ctx.Channels.CountryUnrestChanged, { tag = tag, total = country.unrest, source = "event" })
	end

	-- Political power (delegated so caps/events stay consistent)
	if effects.politicalPower and ctx.PoliticalPower then
		if effects.politicalPower > 0 then
			ctx.PoliticalPower.credit(tag, effects.politicalPower, "event")
		else
			ctx.PoliticalPower.spend(tag, -effects.politicalPower, "event")
		end
	end

	-- Estate loyalty / influence (delegated to EstateSystem; each re-fetches + writes)
	local loy = resolveEstateMap(effects.estateLoyalty, context)
	if loy and ctx.EstateSystem then
		for estateId, delta in loy do ctx.EstateSystem.addLoyalty(tag, estateId, delta, "event") end
	end
	local inf = resolveEstateMap(effects.estateInfluence, context)
	if inf and ctx.EstateSystem and ctx.EstateSystem.applyDelta then
		for estateId, delta in inf do ctx.EstateSystem.applyDelta(tag, estateId, delta, "event") end
	end

	-- Structural effects
	if effects.grantPrivilege and ctx.EstateSystem then ctx.EstateSystem.grantPrivilege(tag, effects.grantPrivilege) end
	if effects.revokePrivilege and ctx.EstateSystem then ctx.EstateSystem.revokePrivilege(tag, effects.revokePrivilege) end
	if effects.enactPolicy and ctx.PolicySystem then ctx.PolicySystem.enact(tag, effects.enactPolicy, "event") end
	if effects.setIdeology and ctx.IdeologySystem then ctx.IdeologySystem.setIdeology(tag, effects.setIdeology, "event") end
	if effects.beginTransition and ctx.GovernmentTransitions then
		local c = ctx.WorldState.getCountry(tag)
		ctx.GovernmentTransitions.begin(tag, effects.beginTransition, { trigger = "event", targetIdeology = c and c.ideology })
	end
	if effects.spawnRebellion and ctx.RebellionSystem and ctx.RebellionSystem.spawn then
		ctx.RebellionSystem.spawn(tag, effects.spawnRebellion, context)
	end
end

local function setCooldown(country, def, day)
	if def.cooldownDays then
		country.eventCooldowns = country.eventCooldowns or {}
		country.eventCooldowns[def.id] = day + def.cooldownDays
	end
end

local function onCooldown(country, eventId, day)
	return (country.eventCooldowns and country.eventCooldowns[eventId] and country.eventCooldowns[eventId] > day) or false
end

local function optionById(def, optionId)
	for _, o in ipairs(def.options) do
		if o.id == optionId then return o end
	end
	return nil
end

local function defaultOption(def)
	for _, o in ipairs(def.options) do
		if o.isDefault then return o end
	end
	return def.options[1]
end

local function pickAiOption(def)
	local best, bestWeight
	for _, o in ipairs(def.options) do
		local w = o.aiWeight or (o.isDefault and 1.5 or 1.0)
		if not bestWeight or w > bestWeight then best, bestWeight = o, w end
	end
	return best
end

-- Forward declaration so chainEvent can re-enter firing.
local fireEvent

function fireEvent(tag, def, context)
	if def.disabled then
		return -- global kill-switch: a disabled event never surfaces via ANY path (chainEvent / RulerSystem / public API)
	end
	context = context or {}
	local country = ctx.WorldState.getCountry(tag)
	if not country then return end
	local day = currentDay()

	-- AI: resolve immediately with the safest/highest-weight option (never stalls)
	if not isPlayer(tag) then
		local choice = pickAiOption(def)
		if choice then applyEffects(tag, choice.effects, context) end
		local c2 = ctx.WorldState.getCountry(tag)
		if c2 then
			setCooldown(c2, def, day)
			ctx.WorldState.setCountry(tag, c2)
		end
		ctx.EventBus.publish(ctx.Channels.CountryEventResolved, { tag = tag, eventId = def.id, optionId = choice and choice.id, auto = true, ai = true })
		return
	end

	-- Player: present the card (effects resolved server-side at choice time)
	local opts = {}
	for _, o in ipairs(def.options) do
		table.insert(opts, {
			id = o.id,
			label = applyTokens(o.label, country, context),
			tooltip = applyTokens(o.tooltip, country, context),
		})
	end
	country.activeEvent = {
		eventId = def.id,
		firedDay = day,
		deadlineDay = def.deadlineDays and (day + def.deadlineDays) or nil,
		context = context,
		title = applyTokens(def.title, country, context),
		body = applyTokens(def.body, country, context),
		category = def.category,
		options = opts,
	}
	country.eventClock = country.eventClock or {}
	country.eventClock.lastFiredDay = day
	ctx.WorldState.setCountry(tag, country)
	ctx.EventBus.publish(ctx.Channels.CountryEventFired, { tag = tag, eventId = def.id, category = def.category })
end

local function resolveEvent(tag, eventId, optionId, isAuto)
	local country = ctx.WorldState.getCountry(tag)
	if not country or not country.activeEvent or country.activeEvent.eventId ~= eventId then return false end
	local context = country.activeEvent.context
	local def = ctx.Bundle and ctx.Bundle.events and ctx.Bundle.events[eventId]

	-- Always clear the active event first so applyEffects (which re-fetches + writes
	-- the country) cannot resurrect a stale card.
	country.activeEvent = nil
	if def then setCooldown(country, def, currentDay()) end
	ctx.WorldState.setCountry(tag, country)
	if not def then return false end

	local opt = optionById(def, optionId) or defaultOption(def)
	if opt then applyEffects(tag, opt.effects, context) end
	ctx.EventBus.publish(ctx.Channels.CountryEventResolved, {
		tag = tag, eventId = eventId, optionId = opt and opt.id, auto = isAuto or false,
	})
	if opt and opt.effects and opt.effects.chainEvent then
		local chainDef = ctx.Bundle.events[opt.effects.chainEvent]
		if chainDef then fireEvent(tag, chainDef, context) end
	end
	return true
end

-- Pick the least-loyal non-crown estate below `threshold`, if any.
local function disloyalEstate(country, threshold)
	if not country.factions then return nil end
	local worstId, worstLoyalty
	for fid, rec in country.factions do
		if fid ~= "crown" then
			local loy = rec.loyalty or ctx.WorldConstants.EstateLoyaltyBase
			if loy < threshold and (not worstLoyalty or loy < worstLoyalty) then
				worstId, worstLoyalty = fid, loy
			end
		end
	end
	return worstId
end

local function archetypeOf(country)
	local ga = ctx.Bundle and ctx.Bundle.governmentArchetypes
	return (ga and ga.archetypeOf and ga.archetypeOf(country.governmentForm)) or "monarchy"
end

-- Does this event's gov-archetype gate admit the country?
local function archetypeAdmits(def, country)
	if not def.govArchetype then return true end
	return def.govArchetype == archetypeOf(country)
end

local function tryFireFor(tag, country, day)
	local events = ctx.Bundle and ctx.Bundle.events
	if not events then return false end

	-- 1) Estate demand has priority when an estate is disloyal. (Skipped while flagged `disabled` -- the
	-- Estates UI is cut for the playtest, so this card would fire about factions the player cannot see.)
	local demandDef = events.estate_demands_privilege
	if demandDef and not demandDef.disabled and archetypeAdmits(demandDef, country) and not onCooldown(country, demandDef.id, day) then
		local threshold = (demandDef.trigger and demandDef.trigger.loyaltyBelow) or ctx.WorldConstants.EstateDemandLoyaltyThreshold
		local estateId = disloyalEstate(country, threshold)
		if estateId then
			fireEvent(tag, demandDef, { estateId = estateId })
			return true
		end
	end

	-- 2) Otherwise, an ambient random opportunity (chance-gated).
	if rng:NextNumber(0, 1) < ctx.WorldConstants.EventAmbientChance then
		local pool = {}
		for id, def in events do
			if def.trigger and def.trigger.type == "random_opportunity" and not def.disabled
				and archetypeAdmits(def, country) and not onCooldown(country, id, day) then
				table.insert(pool, def)
			end
		end
		if #pool > 0 then
			fireEvent(tag, pool[rng:NextInteger(1, #pool)], {})
			return true
		end
	end
	return false
end

local function tick()
	local relevant = ctx.PlayerAuthority and ctx.PlayerAuthority.relevantSet and ctx.PlayerAuthority.relevantSet() or nil
	local day = currentDay()
	for tag, country in ctx.WorldState.allCountries() do
		if relevant and not relevant[tag] then continue end

		if country.activeEvent then
			-- Deadline auto-resolve to the safe default.
			local dl = country.activeEvent.deadlineDay
			if dl and day >= dl then
				local def = ctx.Bundle and ctx.Bundle.events and ctx.Bundle.events[country.activeEvent.eventId]
				local optId = def and defaultOption(def) and defaultOption(def).id or nil
				resolveEvent(tag, country.activeEvent.eventId, optId, true)
			end
			continue -- one event at a time
		end

		-- Throttled ambient check.
		local nextCheck = (country.eventClock and country.eventClock.nextCheckDay) or 0
		if day >= nextCheck then
			tryFireFor(tag, country, day)
			local c2 = ctx.WorldState.getCountry(tag)
			if c2 then
				c2.eventClock = c2.eventClock or {}
				c2.eventClock.nextCheckDay = day + ctx.WorldConstants.EventAmbientCheckDays
				ctx.WorldState.setCountry(tag, c2)
			end
		end
	end
end

function EventSystem.register(context)
	ctx = context
	rng = Random.new()
	context.EventSystem = {
		resolveEvent = resolveEvent,
		applyEffects = applyEffects,
		fireEvent = function(tag, eventId, eventContext)
			local def = context.Bundle and context.Bundle.events and context.Bundle.events[eventId]
			if def then fireEvent(tag, def, eventContext or {}) end
		end,
	}
	context.TickScheduler.register({
		id = "EventSystem",
		priority = 21,
		updateIntervalSeconds = context.WorldConstants.EventTickInterval,
		update = tick,
	})
end

return EventSystem
