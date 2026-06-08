local ModifierStack = {}

local ctx

local function sourceModifier(defTable, id, domain)
	if not defTable or not id then return 0 end
	local entry = defTable[id]
	if not entry or not entry.modifiers then return 0 end
	return entry.modifiers[domain] or 0
end

local function policyModifierSum(bundle, country, domain)
	if not country.activePolicies or not bundle.policies then return 0 end
	local sum = 0
	for policyId in country.activePolicies do
		local policy = bundle.policies[policyId]
		if policy and policy.modifiers then
			sum += policy.modifiers[domain] or 0
		end
	end
	return sum
end

local function leaderModifierSum(bundle, country, domain)
	if not country.leaders or not bundle.leaderTraits then return 0 end
	local sum = 0
	for _, leader in country.leaders do
		if leader and leader.traits then
			for _, traitId in leader.traits do
				local trait = bundle.leaderTraits[traitId]
				if trait and trait.modifiers then
					sum += trait.modifiers[domain] or 0
				end
			end
		end
	end
	return sum
end

local function doctrineSlotProduct(bundle, country, domain)
	local product = 1
	local applied = false
	if not bundle.doctrines then return product, applied end
	if country.doctrines then
		for _, doctrineId in country.doctrines do
			local d = bundle.doctrines[doctrineId]
			if d and d.modifiers then
				local v = d.modifiers[domain]
				if v and v ~= 0 then
					product *= (1 + v)
					applied = true
				end
			end
		end
	elseif country.doctrine then
		local d = bundle.doctrines[country.doctrine]
		if d and d.modifiers then
			local v = d.modifiers[domain]
			if v and v ~= 0 then
				product *= (1 + v)
				applied = true
			end
		end
	end
	return product, applied
end

local function doctrineSlotSum(bundle, country, domain)
	local sum = 0
	if not bundle.doctrines then return sum end
	if country.doctrines then
		for _, doctrineId in country.doctrines do
			local d = bundle.doctrines[doctrineId]
			if d and d.modifiers then
				sum += d.modifiers[domain] or 0
			end
		end
	elseif country.doctrine then
		local d = bundle.doctrines[country.doctrine]
		if d and d.modifiers then
			sum += d.modifiers[domain] or 0
		end
	end
	return sum
end

function ModifierStack.resolve(tag, domain)
	local country = ctx.WorldState.getCountry(tag)
	if not country then return 1 end
	local bundle = ctx.Bundle
	if not bundle then return 1 end

	local ideologyMod = sourceModifier(bundle.ideologies, country.ideology, domain)
	local govMod = sourceModifier(bundle.governmentTypes, country.governmentForm, domain)
	local policySum = policyModifierSum(bundle, country, domain)
	local leaderSum = leaderModifierSum(bundle, country, domain)
	local doctrineProduct = doctrineSlotProduct(bundle, country, domain)

	local stacked = (1 + ideologyMod) * (1 + govMod) * (1 + policySum) * (1 + leaderSum) * doctrineProduct
	local cap = ctx.WorldConstants.MultiplierCapEconomy
	if country.transition then
		local penalty = ctx.WorldConstants.TransitionStabilityPenalty or 0
		if domain == "base_stability" then stacked *= (1 + penalty) end
	end
	return math.clamp(stacked, 1 / cap, cap)
end

function ModifierStack.resolveAdditive(tag, domain)
	local country = ctx.WorldState.getCountry(tag)
	if not country then return 0 end
	local bundle = ctx.Bundle
	if not bundle then return 0 end
	local ideologyMod = sourceModifier(bundle.ideologies, country.ideology, domain)
	local govMod = sourceModifier(bundle.governmentTypes, country.governmentForm, domain)
	local policySum = policyModifierSum(bundle, country, domain)
	local leaderSum = leaderModifierSum(bundle, country, domain)
	local doctrineSum = doctrineSlotSum(bundle, country, domain)
	return ideologyMod + govMod + policySum + leaderSum + doctrineSum
end

function ModifierStack.register(context)
	ctx = context
	context.ModifierStack = {
		resolve = ModifierStack.resolve,
		resolveAdditive = ModifierStack.resolveAdditive,
	}
end

return ModifierStack
