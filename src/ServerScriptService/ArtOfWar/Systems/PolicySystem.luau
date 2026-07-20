local PolicySystem = {}

local TICK_INTERVAL = 6

local ctx

local function policyOf(policyId)
	local bundle = ctx.Bundle
	return bundle and bundle.policies and bundle.policies[policyId] or nil
end

local function ideologyAllows(country, policy)
	local gate = policy.ideologyGate
	if not gate or gate == "any" then return true end
	return country.ideology == gate
end

local function isActive(tag, policyId)
	local country = ctx.WorldState.getCountry(tag)
	return country and country.activePolicies and country.activePolicies[policyId] ~= nil or false
end

local function enact(tag, policyId, trigger)
	local policy = policyOf(policyId)
	if not policy then return false, "unknown_policy" end
	local country = ctx.WorldState.getCountry(tag)
	if not country then return false, "unknown_country" end
	if not ideologyAllows(country, policy) then return false, "ideology_gate" end
	country.activePolicies = country.activePolicies or {}
	if country.activePolicies[policyId] then return false, "already_active" end

	if trigger ~= "transition" and trigger ~= "revolution" and trigger ~= "event" and trigger ~= "law_passed" then
		local ppCost = policy.ppCost
		-- Technology: policy_efficiency (capped reduction, gated by EnableTechTree; 0 while off).
		local rs = ctx.ResearchSystem
		if rs and rs.bonus then
			ppCost *= (1 - rs.bonus(tag, "policy_efficiency"))
		end
		if not ctx.PoliticalPower or not ctx.PoliticalPower.spend(tag, ppCost, "policy_enact") then
			return false, "insufficient_pp"
		end
	end

	country.activePolicies[policyId] = { enactedAt = ctx.TickScheduler.getSimTime() }
	ctx.WorldState.setCountry(tag, country)
	ctx.EventBus.publish(ctx.Channels.CountryPolicyEnacted, {
		tag = tag, policyId = policyId, trigger = trigger or "voluntary",
	})
	return true
end

local function repeal(tag, policyId, trigger)
	local country = ctx.WorldState.getCountry(tag)
	if not country or not country.activePolicies or not country.activePolicies[policyId] then
		return false, "not_active"
	end
	country.activePolicies[policyId] = nil
	ctx.WorldState.setCountry(tag, country)
	ctx.EventBus.publish(ctx.Channels.CountryPolicyRepealed, {
		tag = tag, policyId = policyId, trigger = trigger or "voluntary",
	})
	return true
end

local function countryUpkeep(country)
	if not country.activePolicies then return 0 end
	local bundle = ctx.Bundle
	if not bundle or not bundle.policies then return 0 end
	local total = 0
	for policyId in country.activePolicies do
		local policy = bundle.policies[policyId]
		if policy then total += (policy.ppUpkeep or 0) end
	end
	-- Technology: policy_efficiency (capped reduction, gated by EnableTechTree; 0 while off).
	local rs = ctx.ResearchSystem
	if rs and rs.bonus and country.tag then
		total *= (1 - rs.bonus(country.tag, "policy_efficiency"))
	end
	return total
end

local function autoRepealHeaviest(tag, country)
	local bundle = ctx.Bundle
	if not bundle or not bundle.policies then return end
	local heaviestId, heaviestUpkeep = nil, -1
	for policyId in country.activePolicies do
		local policy = bundle.policies[policyId]
		if policy and (policy.ppUpkeep or 0) > heaviestUpkeep then
			heaviestId = policyId
			heaviestUpkeep = policy.ppUpkeep or 0
		end
	end
	if heaviestId then repeal(tag, heaviestId, "pp_exhausted") end
end

local function tickUpkeep()
	if not ctx.PoliticalPower then return end
	for tag, country in ctx.WorldState.allCountries() do
		if country.activePolicies then
			local upkeep = countryUpkeep(country)
			if upkeep > 0 then
				local paid = ctx.PoliticalPower.spend(tag, upkeep, "policy_upkeep")
				if not paid then
					autoRepealHeaviest(tag, country)
				end
			end
		end
	end
end

local function activePolicies(tag)
	local country = ctx.WorldState.getCountry(tag)
	if not country or not country.activePolicies then return {} end
	local list = {}
	for policyId in country.activePolicies do table.insert(list, policyId) end
	table.sort(list)
	return list
end

function PolicySystem.register(context)
	ctx = context
	context.PolicySystem = {
		enact = enact,
		repeal = repeal,
		isActive = isActive,
		activePolicies = activePolicies,
		upkeepOf = function(tag)
			local country = context.WorldState.getCountry(tag)
			return country and countryUpkeep(country) or 0
		end,
	}
	for k, v in pairs(context.PolicySystem) do PolicySystem[k] = v end
	context.TickScheduler.register({
		id = "PolicySystem",
		priority = 17,
		updateIntervalSeconds = TICK_INTERVAL,
		update = tickUpkeep,
	})
end

return PolicySystem
