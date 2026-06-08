local GovernmentTransitionSystem = {}

local TICK_INTERVAL = 6
local COOLDOWN_DAYS_AFTER = 365 * 2

local ctx

local FACTION_DELTAS = {
	absolute_monarchy = {
		merchant_republic = { crown = -0.20, clergy = -0.10, burghers = 0.15, officer_corps = -0.05, peasantry = -0.05, colonial_merchants = 0.15, philosophes = 0.10 },
		constitutional_monarchy = { crown = -0.10, clergy = -0.05, burghers = 0.10, philosophes = 0.05 },
		parliamentary_monarchy = { crown = -0.18, clergy = -0.08, burghers = 0.12, philosophes = 0.12, peasantry = 0.02 },
		theocracy = { crown = -0.05, clergy = 0.25, burghers = -0.10 },
		despotism = { crown = 0.10, officer_corps = 0.10, philosophes = -0.10 },
	},
	constitutional_monarchy = {
		parliamentary_monarchy = { crown = -0.05, burghers = 0.05, philosophes = 0.05 },
		absolute_monarchy = { crown = 0.20, clergy = 0.10, burghers = -0.10, philosophes = -0.15 },
		merchant_republic = { crown = -0.25, burghers = 0.20, colonial_merchants = 0.10 },
	},
	tsardom = {
		absolute_monarchy = { crown = -0.05, clergy = 0.05 },
		constitutional_monarchy = { crown = -0.20, burghers = 0.10, philosophes = 0.15 },
	},
	sultanate = {
		caliphate = { clergy = 0.15, crown = -0.05 },
		absolute_monarchy = { clergy = -0.10, philosophes = 0.10 },
	},
}

local function gameDay()
	return ctx.GovernmentSystem and ctx.GovernmentSystem.currentDay() or 0
end

local function applyFactionDelta(country, fromGov, toGov)
	if not country.factions then return end
	local deltaTable = FACTION_DELTAS[fromGov] and FACTION_DELTAS[fromGov][toGov]
	if not deltaTable then return end
	for factionId, delta in deltaTable do
		local record = country.factions[factionId]
		if record then
			record.clout = math.clamp((record.clout or 0) + delta, 0, 1)
		end
	end
end

local function repealIncompatiblePolicies(country, newGov, newIdeology)
	if not country.activePolicies then return 0, 0 end
	local bundle = ctx.Bundle
	if not bundle or not bundle.policies then return 0, 0 end
	local repealed = 0
	for policyId in country.activePolicies do
		local policy = bundle.policies[policyId]
		if policy and policy.ideologyGate and policy.ideologyGate ~= "any" and policy.ideologyGate ~= newIdeology then
			country.activePolicies[policyId] = nil
			repealed += 1
			ctx.EventBus.publish(ctx.Channels.CountryPolicyRepealed, {
				tag = country.tag, policyId = policyId, reason = "transition",
			})
		end
	end
	local hitPerPolicy = ctx.WorldConstants.TransitionPolicyRepealStabilityHit or 0.05
	local cap = ctx.WorldConstants.TransitionPolicyRepealStabilityCap or 0.20
	local hit = math.min(repealed * hitPerPolicy, cap)
	return repealed, hit
end

local function cancelInProgressLaws(country)
	if not country.lawPasses then return 0 end
	local cancelled = 0
	local refund = 0
	local refundFraction = ctx.WorldConstants.TransitionLawCancelRefund or 0.5
	for lawId, record in country.lawPasses do
		if record.state == "in_progress" then
			refund += (record.ppSpent or 0) * refundFraction
			country.lawPasses[lawId] = nil
			cancelled += 1
			ctx.EventBus.publish(ctx.Channels.CountryTransitionProgressed, {
				tag = country.tag, lawCancelled = lawId,
			})
		end
	end
	return cancelled, refund
end

local function applyRollover(country, fromGov, toGov, targetIdeology, trigger)
	local repealed, stabilityHit = repealIncompatiblePolicies(country, toGov, targetIdeology)
	local cancelledLaws, refund = cancelInProgressLaws(country)
	if refund > 0 and ctx.PoliticalPower then
		ctx.PoliticalPower.credit(country.tag, refund, "law_cancelled_refund")
	end
	country.stability = math.clamp((country.stability or 0) - stabilityHit, ctx.WorldConstants.StabilityMin, ctx.WorldConstants.StabilityMax)

	applyFactionDelta(country, fromGov, toGov)

	local legitimacyHit = ctx.WorldConstants.TransitionLegitimacyHit or 25
	if trigger == "revolution" or trigger == "conquest" then
		country.legitimacy = ctx.WorldConstants.RevolutionLegitimacyFloor
		country.treasury = math.max(0, (country.treasury or 0) * (1 - (ctx.WorldConstants.RevolutionTreasuryHit or 0.30)))
		country.manpower = math.max(0, (country.manpower or 0) * (1 - (ctx.WorldConstants.RevolutionManpowerHit or 0.20)))
	else
		country.legitimacy = math.max(ctx.WorldConstants.LegitimacyMin, (country.legitimacy or 0) - legitimacyHit)
	end
	country.ideology = targetIdeology
	country.governmentForm = toGov
	country.transitionCooldowns = country.transitionCooldowns or {}
	country.transitionCooldowns[fromGov] = gameDay() + COOLDOWN_DAYS_AFTER
	return {
		policiesRepealed = repealed,
		lawsCancelled = cancelledLaws,
		stabilityHit = stabilityHit,
		legitimacyHit = trigger == "revolution" and (country.legitimacy or 0) or legitimacyHit,
	}
end

local function beginTransition(tag, toGov, opts)
	opts = opts or {}
	if not ctx.GovernmentSystem then return false, "system not ready" end
	local ok, ruleOrErr = ctx.GovernmentSystem.canTransition(tag, toGov, opts)
	if not ok then return false, ruleOrErr end
	local rule = ruleOrErr

	local country = ctx.WorldState.getCountry(tag)
	local trigger = opts.trigger or "voluntary"
	if trigger ~= "revolution" and trigger ~= "event" then
		if not ctx.PoliticalPower.spend(tag, rule.ppCost, "gov_transition") then
			return false, "insufficient political power"
		end
	end

	local years = rule.minYears or 2
	local startDay = gameDay()
	country.transition = {
		from = country.governmentForm,
		to = toGov,
		startedAtDay = startDay,
		completesAtDay = startDay + years * 365,
		ppSpent = (trigger == "revolution" or trigger == "event") and 0 or rule.ppCost,
		trigger = trigger,
		targetIdeology = opts.targetIdeology or country.ideology,
	}
	ctx.WorldState.setCountry(tag, country)
	ctx.EventBus.publish(ctx.Channels.CountryTransitionStarted, {
		tag = tag, from = country.transition.from, to = toGov, trigger = trigger,
		targetIdeology = country.transition.targetIdeology,
		completesAtDay = country.transition.completesAtDay,
	})
	return true
end

local function completeTransition(tag, country)
	local transition = country.transition
	if not transition then return end
	local rollover = applyRollover(country, transition.from, transition.to, transition.targetIdeology, transition.trigger)
	country.transition = nil
	ctx.WorldState.setCountry(tag, country)
	ctx.EventBus.publish(ctx.Channels.CountryTransitionCompleted, {
		tag = tag, from = transition.from, to = transition.to, trigger = transition.trigger,
		targetIdeology = transition.targetIdeology, rollover = rollover,
	})
	ctx.EventBus.publish(ctx.Channels.CountryGovernmentChanged, {
		tag = tag, previous = transition.from, current = transition.to, trigger = transition.trigger,
	})
	ctx.EventBus.publish(ctx.Channels.CountryIdeologyChanged, {
		tag = tag, previous = country.ideology, current = transition.targetIdeology, trigger = "transition",
	})
end

local function cancelTransition(tag)
	local country = ctx.WorldState.getCountry(tag)
	if not country or not country.transition then return false end
	local refundFraction = ctx.WorldConstants.TransitionCancelRefund or 0.5
	local refund = (country.transition.ppSpent or 0) * refundFraction
	local transition = country.transition
	country.transition = nil
	country.legitimacy = math.max(ctx.WorldConstants.LegitimacyMin, (country.legitimacy or 0) - 5)
	ctx.WorldState.setCountry(tag, country)
	if refund > 0 and ctx.PoliticalPower then
		ctx.PoliticalPower.credit(tag, refund, "transition_cancelled_refund")
	end
	ctx.EventBus.publish(ctx.Channels.CountryTransitionCancelled, {
		tag = tag, transition = transition, refund = refund,
	})
	return true
end

local function tickTransitions()
	local now = gameDay()
	for tag, country in ctx.WorldState.allCountries() do
		if country.transition and now >= country.transition.completesAtDay then
			completeTransition(tag, country)
		end
	end
end

function GovernmentTransitionSystem.register(context)
	ctx = context
	context.GovernmentTransitions = {
		begin = beginTransition,
		cancel = cancelTransition,
		isActive = function(tag)
			local c = context.WorldState.getCountry(tag)
			return c and c.transition ~= nil or false
		end,
	}
	context.TickScheduler.register({
		id = "GovernmentTransitionSystem",
		priority = 18,
		updateIntervalSeconds = TICK_INTERVAL,
		update = tickTransitions,
	})
end

return GovernmentTransitionSystem
