local GovernmentSystem = {}

local ctx

local function ideologyAllowed(gov, ideologyId)
	if not gov or not gov.allowedIdeologies then return false end
	for _, id in gov.allowedIdeologies do
		if id == ideologyId then return true end
	end
	return false
end

local function transitionRule(fromGovId, toGovId)
	local bundle = ctx.Bundle
	local gov = bundle and bundle.governmentTypes and bundle.governmentTypes[fromGovId]
	if not gov or not gov.transitions then return nil end
	return gov.transitions[toGovId]
end

local function factionClout(country, factionId)
	if not country.factions then return 0 end
	local record = country.factions[factionId]
	return (record and record.clout) or 0
end

local function hasTech(country, techId)
	return country.techs and country.techs[techId] == true
end

local function currentDay()
	local date = ctx.TickScheduler.getGameDate()
	return (date.year - 1) * 365 + (date.month - 1) * 30 + date.day
end

local function meetsRequirements(country, rule, ideologyOverride)
	if not rule.requires then return true end
	local req = rule.requires
	if req.ideology then
		local activeIdeology = ideologyOverride or country.ideology
		if activeIdeology ~= req.ideology then return false end
	end
	if req.religion and country.stateReligion ~= req.religion then return false end
	if req.minLegitimacy and (country.legitimacy or 0) < req.minLegitimacy then return false end
	if req.tech and not hasTech(country, req.tech) then return false end
	if req.faction then
		for factionId, threshold in req.faction do
			if factionClout(country, factionId) < threshold then return false end
		end
	end
	if req.cultureGroup then
		local bundle = ctx.Bundle
		local culture = bundle and bundle.cultures and bundle.cultures[country.primaryCulture]
		if not culture or culture.groupId ~= req.cultureGroup then
			if req.cultureGroup == "turkic_or_mongolic" then
				if not culture or (culture.groupId ~= "turkic" and culture.groupId ~= "mongolic") then
					return false
				end
			else
				return false
			end
		end
	end
	if req.cause and req.cause ~= (rule._trigger or "voluntary") then return false end
	return true
end

local function canTransition(tag, targetGovId, opts)
	local country = ctx.WorldState.getCountry(tag)
	if not country then return false, "unknown country" end
	if country.transition then return false, "transition already in progress" end
	if country.governmentForm == targetGovId then return false, "already that government" end
	local bundle = ctx.Bundle
	if not bundle or not bundle.governmentTypes or not bundle.governmentTypes[targetGovId] then
		return false, "unknown government type"
	end
	local rule = transitionRule(country.governmentForm, targetGovId)
	if not rule then return false, "no direct transition path" end
	if country.transitionCooldowns and country.transitionCooldowns[targetGovId] then
		if currentDay() < country.transitionCooldowns[targetGovId] then
			return false, "transition on cooldown"
		end
	end
	local targetIdeology = opts and opts.targetIdeology or country.ideology
	local targetGov = bundle.governmentTypes[targetGovId]
	if not ideologyAllowed(targetGov, targetIdeology) then
		return false, "target ideology not allowed by target government"
	end
	local testRule = { requires = rule.requires, _trigger = opts and opts.trigger or "voluntary" }
	if not meetsRequirements(country, testRule, targetIdeology) then
		return false, "requirements not met"
	end
	if opts and opts.trigger ~= "revolution" and opts.trigger ~= "event" then
		if not ctx.PoliticalPower then return false, "pp system unavailable" end
		if (country.politicalPower or 0) < rule.ppCost then
			return false, "insufficient political power"
		end
	end
	return true, rule
end

function GovernmentSystem.register(context)
	ctx = context
	context.GovernmentSystem = {
		canTransition = canTransition,
		transitionRule = transitionRule,
		ideologyAllowed = function(govId, ideologyId)
			local bundle = ctx.Bundle
			local gov = bundle and bundle.governmentTypes and bundle.governmentTypes[govId]
			return ideologyAllowed(gov, ideologyId)
		end,
		meetsRequirements = meetsRequirements,
		currentDay = currentDay,
	}
end

return GovernmentSystem
