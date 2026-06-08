local LawSystem = {}

local TICK_INTERVAL = 6

local ctx
local rng

local function currentDay()
	local d = ctx.TickScheduler.getGameDate()
	return (d.year - 1) * 365 + (d.month - 1) * 30 + d.day
end

local function cooldownOf(country, policyId)
	return country.lawCooldowns and country.lawCooldowns[policyId] or 0
end

local function rollOutcome(country, policyId)
	local wc = ctx.WorldConstants
	local ideoPower = ctx.ModifierStack and ctx.ModifierStack.resolveAdditive(country.tag, "ideology_power") or 0
	local ideoShift = math.clamp(ideoPower, -wc.LawIdeologyPowerShiftMax, wc.LawIdeologyPowerShiftMax)
	local factionShift = ctx.FactionSystem and policyId and ctx.FactionSystem.factionLawShift(country.tag, policyId) or 0
	local totalShift = ideoShift + factionShift
	local successChance = math.clamp(wc.LawBaseSuccessChance + totalShift, 0.05, 0.90)
	local setbackChance = math.clamp(wc.LawBaseSetbackChance - totalShift * 0.5, 0.05, 0.60)
	local stallChance = 1 - successChance - setbackChance
	if stallChance < 0 then
		local overflow = -stallChance
		successChance -= overflow * 0.5
		setbackChance -= overflow * 0.5
		stallChance = 0
	end
	local roll = rng:NextNumber(0, 1)
	if roll < successChance then return "success" end
	if roll < successChance + stallChance then return "stall" end
	return "setback"
end

local function canStart(tag, policyId)
	local country = ctx.WorldState.getCountry(tag)
	if not country then return false, "unknown_country" end
	if country.lawPass then return false, "law_in_progress" end
	local bundle = ctx.Bundle
	if not bundle or not bundle.policies then return false, "bundle_missing" end
	local policy = bundle.policies[policyId]
	if not policy then return false, "unknown_policy" end
	if policy.ideologyGate and policy.ideologyGate ~= "any" and country.ideology ~= policy.ideologyGate then
		return false, "ideology_gate"
	end
	if country.activePolicies and country.activePolicies[policyId] then
		return false, "already_active"
	end
	if country.transition then return false, "government_in_transition" end
	if cooldownOf(country, policyId) > currentDay() then return false, "cooldown" end
	if (country.politicalPower or 0) < policy.ppCost then return false, "insufficient_pp" end
	return true, policy
end

local function startLawProcess(tag, policyId)
	local ok, result = canStart(tag, policyId)
	if not ok then return false, result end
	local policy = result

	if not ctx.PoliticalPower or not ctx.PoliticalPower.spend(tag, policy.ppCost, "law_started") then
		return false, "insufficient_pp"
	end

	local country = ctx.WorldState.getCountry(tag)
	local today = currentDay()
	local phaseDuration = ctx.WorldConstants.LawPhaseDurationDays
	country.lawPass = {
		policyId = policyId,
		phase = 1,
		setbacksTotal = 0,
		startedAtDay = today,
		nextCheckpointDay = today + phaseDuration,
		ppSpent = policy.ppCost,
		state = "in_progress",
		checkpoints = {},
	}
	ctx.WorldState.setCountry(tag, country)
	ctx.EventBus.publish(ctx.Channels.CountryLawStarted, {
		tag = tag, policyId = policyId, phase = 1, ppSpent = policy.ppCost,
	})
	return true
end

local function cancelLaw(tag, trigger)
	local country = ctx.WorldState.getCountry(tag)
	if not country or not country.lawPass then return false, "no_law" end
	local record = country.lawPass
	local refundFraction = ctx.WorldConstants.LawCancelRefund
	local refund = (record.ppSpent or 0) * refundFraction
	country.lawPass = nil
	ctx.WorldState.setCountry(tag, country)
	if refund > 0 and ctx.PoliticalPower then
		ctx.PoliticalPower.credit(tag, refund, "law_cancel_refund")
	end
	ctx.EventBus.publish(ctx.Channels.CountryLawCancelled, {
		tag = tag, policyId = record.policyId, refund = refund,
		trigger = trigger or "voluntary",
	})
	return true
end

local function onPhasePassed(tag, country, record)
	local wc = ctx.WorldConstants
	if record.phase >= wc.LawPhases then
		local policyId = record.policyId
		country.lawPass = nil
		ctx.WorldState.setCountry(tag, country)
		ctx.EventBus.publish(ctx.Channels.CountryLawPassed, {
			tag = tag, policyId = policyId, totalDays = currentDay() - record.startedAtDay,
		})
		if ctx.PolicySystem then
			ctx.PolicySystem.enact(tag, policyId, "law_passed")
		end
	else
		record.phase += 1
		record.nextCheckpointDay = currentDay() + wc.LawPhaseDurationDays
		ctx.WorldState.setCountry(tag, country)
		ctx.EventBus.publish(ctx.Channels.CountryLawProgressed, {
			tag = tag, policyId = record.policyId, phase = record.phase, outcome = "advance",
		})
	end
end

local function onSetback(tag, country, record)
	local wc = ctx.WorldConstants
	record.setbacksTotal += 1
	if record.setbacksTotal >= wc.LawSetbackLimit then
		local policyId = record.policyId
		country.lawCooldowns = country.lawCooldowns or {}
		country.lawCooldowns[policyId] = currentDay() + wc.LawCooldownDays
		country.lawPass = nil
		ctx.WorldState.setCountry(tag, country)
		ctx.EventBus.publish(ctx.Channels.CountryLawFailed, {
			tag = tag, policyId = policyId, setbacksTotal = record.setbacksTotal,
			cooldownUntilDay = country.lawCooldowns[policyId],
		})
	else
		record.nextCheckpointDay = currentDay() + wc.LawPhaseDurationDays
		ctx.WorldState.setCountry(tag, country)
		ctx.EventBus.publish(ctx.Channels.CountryLawProgressed, {
			tag = tag, policyId = record.policyId, phase = record.phase, outcome = "setback",
			setbacksTotal = record.setbacksTotal,
		})
	end
end

local function onStall(tag, country, record)
	record.nextCheckpointDay = currentDay() + ctx.WorldConstants.LawPhaseDurationDays
	ctx.WorldState.setCountry(tag, country)
	ctx.EventBus.publish(ctx.Channels.CountryLawProgressed, {
		tag = tag, policyId = record.policyId, phase = record.phase, outcome = "stall",
	})
end

local function processCheckpoint(tag, country)
	local record = country.lawPass
	if not record then return end
	if currentDay() < record.nextCheckpointDay then return end

	local outcome = rollOutcome(country, record.policyId)
	table.insert(record.checkpoints, {
		day = currentDay(),
		phase = record.phase,
		outcome = outcome,
	})

	if outcome == "success" then
		onPhasePassed(tag, country, record)
	elseif outcome == "setback" then
		onSetback(tag, country, record)
	else
		onStall(tag, country, record)
	end
end

local function sweepCooldowns(tag, country)
	if not country.lawCooldowns then return false end
	local today = currentDay()
	local cleaned = false
	for policyId, expiry in country.lawCooldowns do
		if expiry <= today then
			country.lawCooldowns[policyId] = nil
			cleaned = true
		end
	end
	return cleaned
end

local function tickLaws()
	for tag, country in ctx.WorldState.allCountries() do
		if country.lawPass then
			processCheckpoint(tag, country)
		end
		if sweepCooldowns(tag, country) then
			ctx.WorldState.setCountry(tag, country)
		end
	end
end

function LawSystem.register(context)
	ctx = context
	rng = Random.new()
	context.LawSystem = {
		startLawProcess = startLawProcess,
		cancelLaw = cancelLaw,
		canStart = canStart,
		getLawPass = function(tag)
			local c = context.WorldState.getCountry(tag)
			return c and c.lawPass or nil
		end,
		getCooldowns = function(tag)
			local c = context.WorldState.getCountry(tag)
			return c and c.lawCooldowns or {}
		end,
	}
	for k, v in pairs(context.LawSystem) do LawSystem[k] = v end
	context.TickScheduler.register({
		id = "LawSystem",
		priority = 16,
		updateIntervalSeconds = TICK_INTERVAL,
		update = tickLaws,
	})
end

return LawSystem
