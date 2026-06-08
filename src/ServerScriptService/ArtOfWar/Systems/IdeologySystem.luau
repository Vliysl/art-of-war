local IdeologySystem = {}

local SHIFT_PP_COST = 60

local ctx

local function isAllowedByGov(bundle, governmentId, ideologyId)
	local gov = bundle.governmentTypes and bundle.governmentTypes[governmentId]
	if not gov or not gov.allowedIdeologies then return false end
	for _, allowed in gov.allowedIdeologies do
		if allowed == ideologyId then return true end
	end
	return false
end

local function setIdeology(tag, ideologyId, trigger)
	local bundle = ctx.Bundle
	if not bundle then return false end
	local country = ctx.WorldState.getCountry(tag)
	if not country then return false end
	if not bundle.ideologies[ideologyId] then return false end
	if country.ideology == ideologyId then return true end
	if not isAllowedByGov(bundle, country.governmentForm, ideologyId) then return false end

	if trigger ~= "transition" and trigger ~= "revolution" and trigger ~= "event" then
		if not ctx.PoliticalPower or not ctx.PoliticalPower.spend(tag, SHIFT_PP_COST, "ideology_shift") then
			return false
		end
	end

	local previous = country.ideology
	country.ideology = ideologyId
	ctx.WorldState.setCountry(tag, country)
	ctx.EventBus.publish(ctx.Channels.CountryIdeologyChanged, {
		tag = tag, previous = previous, current = ideologyId, trigger = trigger or "voluntary",
	})
	return true
end

function IdeologySystem.register(context)
	ctx = context
	context.IdeologySystem = {
		setIdeology = setIdeology,
		isAllowedByGovernment = function(govId, ideologyId)
			return isAllowedByGov(context.Bundle, govId, ideologyId)
		end,
		ppCost = SHIFT_PP_COST,
	}
	for k, v in pairs(context.IdeologySystem) do IdeologySystem[k] = v end
end

return IdeologySystem
