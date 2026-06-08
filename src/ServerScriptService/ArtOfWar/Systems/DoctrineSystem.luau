local DoctrineSystem = {}

local ctx

local function bundle()
	return ctx and ctx.Bundle or nil
end

local function doctrineOf(doctrineId)
	local b = bundle()
	return b and b.doctrines and b.doctrines[doctrineId] or nil
end

local function slotOf(slotId)
	local b = bundle()
	return b and b.doctrineSlots and b.doctrineSlots[slotId] or nil
end

local function adoptedSlots(country)
	if not country or not country.doctrines then return {} end
	local out = {}
	for slot, doctrineId in country.doctrines do
		if doctrineId and slotOf(slot) then
			out[slot] = doctrineId
		end
	end
	return out
end

local function higherTierCount(country, targetTier)
	local n = 0
	for slot, _ in adoptedSlots(country) do
		local slotDef = slotOf(slot)
		if slotDef and slotDef.tier > targetTier then n += 1 end
	end
	return n
end

local function switchCostFor(country, slotDef)
	local base = slotDef.baseSwitchCost or 40
	local mult = ctx.WorldConstants.DoctrineCostMultiplierPerHigherTier or 1.6
	local floor = ctx.WorldConstants.DoctrineSwitchCostFloor or 10
	local n = higherTierCount(country, slotDef.tier)
	return math.max(floor, math.floor(base * (mult ^ n) + 0.5))
end

local function currentDoctrines(tag)
	local country = ctx.WorldState.getCountry(tag)
	return country and adoptedSlots(country) or {}
end

local function setDoctrine(tag, doctrineId, trigger)
	local country = ctx.WorldState.getCountry(tag)
	if not country then return false, "unknown_country" end
	local doctrine = doctrineOf(doctrineId)
	if not doctrine then return false, "unknown_doctrine" end
	local slotDef = slotOf(doctrine.slot)
	if not slotDef then return false, "unknown_slot" end
	if slotDef.unlockedByDefault == false then
		return false, "slot_locked"
	end

	country.doctrines = country.doctrines or {}
	local previous = country.doctrines[doctrine.slot]
	if previous == doctrineId then return false, "already_set" end

	local cost = 0
	if trigger == nil or trigger == "player" then
		cost = switchCostFor(country, slotDef)
		local pool = country.politicalPower or 0
		if pool < cost then
			return false, "insufficient_political_power"
		end
	end

	country.doctrines[doctrine.slot] = doctrineId
	country.doctrine = doctrineId

	if cost > 0 then
		if ctx.PoliticalPower and ctx.PoliticalPower.spend then
			ctx.PoliticalPower.spend(tag, cost, "doctrine_switch")
		else
			country.politicalPower = math.max(0, (country.politicalPower or 0) - cost)
		end
	end

	ctx.WorldState.setCountry(tag, country)
	ctx.EventBus.publish(ctx.Channels.CountryDoctrineChanged, {
		tag = tag,
		slot = doctrine.slot,
		doctrineId = doctrineId,
		previous = previous,
		cost = cost,
		trigger = trigger or "player",
	})
	return true
end

local function seedDefaults()
	local b = bundle()
	if not b or not b.doctrines or not b.doctrineSlots then return end

	local defaultsBySlot = {}
	for id, def in b.doctrines do
		if def.slot and not defaultsBySlot[def.slot] then
			defaultsBySlot[def.slot] = id
		end
	end

	for tag, country in ctx.WorldState.allCountries() do
		country.doctrines = country.doctrines or {}
		for slotId, slotDef in b.doctrineSlots do
			if slotDef.unlockedByDefault ~= false and not country.doctrines[slotId] then
				local fallback = defaultsBySlot[slotId]
				if fallback then
					country.doctrines[slotId] = fallback
				end
			end
		end
		country.doctrine = country.doctrines.infantry or country.doctrines.base or country.doctrine
		ctx.WorldState.setCountry(tag, country)
	end
end

function DoctrineSystem.register(context)
	ctx = context
	context.DoctrineSystem = {
		setDoctrine = setDoctrine,
		current = currentDoctrines,
		switchCostFor = function(tag, doctrineId)
			local country = ctx.WorldState.getCountry(tag)
			local doctrine = doctrineOf(doctrineId)
			if not country or not doctrine then return 0 end
			local slotDef = slotOf(doctrine.slot)
			if not slotDef then return 0 end
			return switchCostFor(country, slotDef)
		end,
	}
	for k, v in pairs(context.DoctrineSystem) do DoctrineSystem[k] = v end
	task.defer(seedDefaults)
end

return DoctrineSystem
