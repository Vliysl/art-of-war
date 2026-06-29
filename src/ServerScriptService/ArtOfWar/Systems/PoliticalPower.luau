local PoliticalPower = {}

local ctx

local function govOf(country)
	local bundle = ctx.Bundle
	return bundle and bundle.governmentTypes and bundle.governmentTypes[country.governmentForm] or nil
end

local function capFor(country)
	local base = ctx.WorldConstants.PoliticalPowerCap
	local gov = govOf(country)
	local bonus = gov and gov.ppStartBonus or 0
	return base + math.max(0, bonus * 0.25)
end

local function generateFor(tag, country)
	local gov = govOf(country)
	local base = ctx.WorldConstants.PoliticalPowerBasePerTick
	local rate = gov and gov.ppPerTick or base
	local stabBoost = 1 + math.clamp((country.stability or 0) * 0.10, -0.30, 0.40)
	local gen = rate * stabBoost
	if country.transition then
		gen *= (ctx.WorldConstants.TransitionPpGenerationPenalty or 0.5)
	end
	return gen
end

local function tickPower(tickCtx)
	-- S3: only relevant (claimed / at-war) countries generate political power per-tick.
	local relevant = ctx.PlayerAuthority and ctx.PlayerAuthority.relevantSet and ctx.PlayerAuthority.relevantSet() or nil
	for tag, country in ctx.WorldState.allCountries() do
		if relevant and not relevant[tag] then continue end
		local cap = capFor(country)
		country.politicalPowerCap = cap
		local gen = generateFor(tag, country)
		local prev = country.politicalPower or 0
		local next = math.min(cap, prev + gen)
		if next ~= prev then
			country.politicalPower = next
			ctx.WorldState.setCountry(tag, country)
			ctx.EventBus.publish(ctx.Channels.CountryPoliticalPowerChanged, {
				tag = tag, delta = next - prev, total = next, cap = cap, source = "generation",
			})
		end

		-- Crown Authority: passive drift toward the cap (cap is owned by EstateSystem and
		-- lowered by granted privileges). Change-guarded just like PP above.
		local wc = ctx.WorldConstants
		local aCap = country.crownAuthorityCap or wc.CrownAuthorityCapBase
		local aPrev = country.crownAuthority or wc.CrownAuthorityBase
		local aNext = math.clamp(aPrev + wc.CrownAuthorityRegenPerTick, wc.CrownAuthorityMin, aCap)
		if aNext ~= aPrev then
			country.crownAuthority = aNext
			ctx.WorldState.setCountry(tag, country)
			ctx.EventBus.publish(ctx.Channels.CountryAuthorityChanged, {
				tag = tag, total = aNext, cap = aCap, source = "regen",
			})
		end
	end
end

local function spend(tag, amount, reason)
	if type(amount) ~= "number" or amount <= 0 then return false end
	local country = ctx.WorldState.getCountry(tag)
	if not country then return false end
	local pp = country.politicalPower or 0
	if pp < amount then return false end
	country.politicalPower = pp - amount
	ctx.WorldState.setCountry(tag, country)
	ctx.EventBus.publish(ctx.Channels.CountryPoliticalPowerChanged, {
		tag = tag, delta = -amount, total = country.politicalPower, cap = capFor(country), source = reason or "spend",
	})
	return true
end

local function credit(tag, amount, reason)
	if type(amount) ~= "number" or amount <= 0 then return false end
	local country = ctx.WorldState.getCountry(tag)
	if not country then return false end
	local cap = capFor(country)
	local prev = country.politicalPower or 0
	local next = math.min(cap, prev + amount)
	country.politicalPower = next
	ctx.WorldState.setCountry(tag, country)
	ctx.EventBus.publish(ctx.Channels.CountryPoliticalPowerChanged, {
		tag = tag, delta = next - prev, total = next, cap = cap, source = reason or "credit",
	})
	return true
end

local function spendAuthority(tag, amount, reason)
	if type(amount) ~= "number" or amount <= 0 then return false end
	local country = ctx.WorldState.getCountry(tag)
	if not country then return false end
	local a = country.crownAuthority or ctx.WorldConstants.CrownAuthorityBase
	if a < amount then return false end
	country.crownAuthority = a - amount
	ctx.WorldState.setCountry(tag, country)
	ctx.EventBus.publish(ctx.Channels.CountryAuthorityChanged, {
		tag = tag, total = country.crownAuthority, cap = country.crownAuthorityCap, source = reason or "spend",
	})
	return true
end

local function creditAuthority(tag, amount, reason)
	if type(amount) ~= "number" or amount <= 0 then return false end
	local country = ctx.WorldState.getCountry(tag)
	if not country then return false end
	local cap = country.crownAuthorityCap or ctx.WorldConstants.CrownAuthorityCapBase
	local prev = country.crownAuthority or ctx.WorldConstants.CrownAuthorityBase
	country.crownAuthority = math.clamp(prev + amount, ctx.WorldConstants.CrownAuthorityMin, cap)
	ctx.WorldState.setCountry(tag, country)
	ctx.EventBus.publish(ctx.Channels.CountryAuthorityChanged, {
		tag = tag, total = country.crownAuthority, cap = cap, source = reason or "credit",
	})
	return true
end

local function snapshot(tag)
	local country = ctx.WorldState.getCountry(tag)
	if not country then return nil end
	return {
		current = country.politicalPower or 0,
		cap = capFor(country),
		generation = generateFor(tag, country),
	}
end

function PoliticalPower.register(context)
	ctx = context
	context.PoliticalPower = {
		spend = spend,
		credit = credit,
		spendAuthority = spendAuthority,
		creditAuthority = creditAuthority,
		snapshot = snapshot,
	}
	context.TickScheduler.register({
		id = "PoliticalPower",
		priority = 15,
		updateIntervalSeconds = context.WorldConstants.PoliticalPowerTickInterval,
		update = tickPower,
	})
end

return PoliticalPower
