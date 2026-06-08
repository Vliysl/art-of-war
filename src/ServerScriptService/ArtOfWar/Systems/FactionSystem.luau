local FactionSystem = {}

local ctx

local function tierOf(clout)
	local wc = ctx.WorldConstants
	if clout < wc.FactionTierMarginalized then return "marginalized" end
	if clout < wc.FactionTierInfluential then return "influential" end
	return "powerful"
end

local function normalizeClouts(factions)
	local total = 0
	for _, record in factions do
		total += math.max(0, record.clout or 0)
	end
	if total <= 0 then return end
	for _, record in factions do
		record.clout = math.max(0, record.clout or 0) / total
	end
end

local function targetClout(factionDef, country)
	local target = factionDef.baseClout
	local ideoBonus = factionDef.ideologyAffinity and factionDef.ideologyAffinity[country.ideology] or 0
	local govBonus = factionDef.governmentAffinity and factionDef.governmentAffinity[country.governmentForm] or 0
	return math.clamp(target + ideoBonus + govBonus, ctx.WorldConstants.FactionCloutMin, ctx.WorldConstants.FactionCloutMax)
end

local function initFactions(country)
	local bundle = ctx.Bundle
	if not bundle or not bundle.factions then return end
	country.factions = country.factions or {}
	local raw = {}
	for factionId, def in bundle.factions do
		local target = targetClout(def, country)
		country.factions[factionId] = {
			id = factionId,
			clout = target,
			tier = tierOf(target),
			lastDelta = 0,
		}
		raw[factionId] = target
	end
	normalizeClouts(country.factions)
	for _, record in country.factions do
		record.tier = tierOf(record.clout)
	end
end

local function computeLegitimacy(country)
	local bundle = ctx.Bundle
	if not bundle or not bundle.factions or not country.factions then return country.legitimacy or 50 end
	local wc = ctx.WorldConstants
	local alignment = 0
	for factionId, record in country.factions do
		local def = bundle.factions[factionId]
		local affinity = def and def.ideologyAffinity and def.ideologyAffinity[country.ideology] or 0
		alignment += record.clout * affinity
	end
	local legit = wc.LegitimacyBase + alignment * wc.LegitimacyAlignmentScale
	return math.clamp(legit, wc.LegitimacyMin, wc.LegitimacyMax)
end

local function applyDelta(tag, factionId, amount, reason)
	local country = ctx.WorldState.getCountry(tag)
	if not country or not country.factions or not country.factions[factionId] then return false end
	local record = country.factions[factionId]
	local prevClout = record.clout
	local prevTier = record.tier
	record.clout = math.clamp(record.clout + amount, ctx.WorldConstants.FactionCloutMin, ctx.WorldConstants.FactionCloutMax)
	record.lastDelta = amount
	normalizeClouts(country.factions)
	for _, r in country.factions do r.tier = tierOf(r.clout) end

	local prevLegit = country.legitimacy or 50
	country.legitimacy = computeLegitimacy(country)
	ctx.WorldState.setCountry(tag, country)

	ctx.EventBus.publish(ctx.Channels.FactionCloutChanged, {
		tag = tag, factionId = factionId, delta = record.clout - prevClout,
		clout = record.clout, reason = reason,
	})
	if record.tier ~= prevTier then
		ctx.EventBus.publish(ctx.Channels.FactionTierChanged, {
			tag = tag, factionId = factionId, from = prevTier, to = record.tier,
		})
	end
	if math.abs(country.legitimacy - prevLegit) > 0.5 then
		ctx.EventBus.publish(ctx.Channels.CountryLegitimacyChanged, {
			tag = tag, previous = prevLegit, current = country.legitimacy,
		})
	end
	return true
end

local function applyReactions(tag, reactionTable, reason)
	if not reactionTable then return end
	local bundle = ctx.Bundle
	if not bundle or not bundle.factions then return end
	for factionId, _ in bundle.factions do
		local reaction = reactionTable[factionId]
		if reaction and reaction ~= 0 then
			applyDelta(tag, factionId, reaction, reason)
		end
	end
end

local function reactToPolicyEvent(tag, policyId, sign, reason)
	local bundle = ctx.Bundle
	if not bundle or not bundle.factions then return end
	local anyReaction = false
	for factionId, def in bundle.factions do
		local r = def.policyReactions and def.policyReactions[policyId]
		if r and r ~= 0 then
			applyDelta(tag, factionId, r * sign, reason)
			anyReaction = true
		end
	end
	if anyReaction then
		ctx.EventBus.publish(ctx.Channels.FactionReactionTriggered, {
			tag = tag, policyId = policyId, sign = sign, reason = reason,
		})
	end
end

local function reactToIdeologyChange(tag, previousIdeology, newIdeology)
	local bundle = ctx.Bundle
	if not bundle or not bundle.factions then return end
	for factionId, def in bundle.factions do
		if def.ideologyAffinity then
			local prev = def.ideologyAffinity[previousIdeology] or 0
			local now = def.ideologyAffinity[newIdeology] or 0
			local delta = (now - prev) * 0.5
			if delta ~= 0 then applyDelta(tag, factionId, delta, "ideology_change") end
		end
	end
end

local function driftFactions(country)
	local bundle = ctx.Bundle
	if not bundle or not bundle.factions or not country.factions then return false end
	local drift = ctx.WorldConstants.FactionDriftPerTick
	-- S1: snapshot clouts so we can tell whether this tick produced any NET movement.
	-- At the settled fixed point (clout proportional to target, which is where initFactions
	-- places them) drift + renormalize maps the values back onto themselves, so we skip the
	-- write. Only genuine perturbations (ideology/government change, applyDelta) write.
	local before = {}
	for fid, rec in country.factions do before[fid] = rec.clout end
	for factionId, record in country.factions do
		local def = bundle.factions[factionId]
		if def then
			local target = targetClout(def, country)
			local gap = target - record.clout
			if math.abs(gap) > 0.001 then
				record.clout = record.clout + gap * drift
			end
		end
	end
	normalizeClouts(country.factions)
	local changed = false
	for fid, rec in country.factions do
		if math.abs(rec.clout - (before[fid] or 0)) > 1e-5 then changed = true break end
	end
	if changed then
		for _, record in country.factions do record.tier = tierOf(record.clout) end
	end
	return changed
end

local function tickFactions()
	-- S3: only relevant (claimed / at-war) countries drift factions per-tick.
	local relevant = ctx.PlayerAuthority and ctx.PlayerAuthority.relevantSet and ctx.PlayerAuthority.relevantSet() or nil
	for tag, country in ctx.WorldState.allCountries() do
		if relevant and not relevant[tag] then continue end
		if country.factions then
			local prevLegit = country.legitimacy or 50
			local changed = driftFactions(country)
			local newLegit = computeLegitimacy(country)
			-- S1 guard: only write + replicate when factions actually moved or legitimacy
			-- changed (was an unconditional write for every country every faction tick).
			if changed or math.abs(newLegit - prevLegit) > 1e-6 then
				country.legitimacy = newLegit
				ctx.WorldState.setCountry(tag, country)
				if math.abs(newLegit - prevLegit) > 0.5 then
					ctx.EventBus.publish(ctx.Channels.CountryLegitimacyChanged, {
						tag = tag, previous = prevLegit, current = newLegit,
					})
				end
			end
		end
	end
end

local function factionLawShift(tag, policyId)
	local bundle = ctx.Bundle
	local country = ctx.WorldState.getCountry(tag)
	if not bundle or not bundle.factions or not country or not country.factions then return 0 end
	local shift = 0
	for factionId, record in country.factions do
		local def = bundle.factions[factionId]
		local reaction = def and def.policyReactions and def.policyReactions[policyId] or 0
		shift += reaction * record.clout
	end
	local cap = ctx.WorldConstants.LawFactionInfluenceMax
	return math.clamp(shift, -cap, cap)
end

local function bindEvents()
	ctx.EventBus.subscribe(ctx.Channels.CountryPolicyEnacted, function(payload)
		if payload and payload.tag and payload.policyId then
			reactToPolicyEvent(payload.tag, payload.policyId, 1, "policy_enacted")
		end
	end)
	ctx.EventBus.subscribe(ctx.Channels.CountryPolicyRepealed, function(payload)
		if payload and payload.tag and payload.policyId then
			reactToPolicyEvent(payload.tag, payload.policyId, -0.5, "policy_repealed")
		end
	end)
	ctx.EventBus.subscribe(ctx.Channels.CountryIdeologyChanged, function(payload)
		if payload and payload.tag and payload.previous and payload.current then
			reactToIdeologyChange(payload.tag, payload.previous, payload.current)
		end
	end)
end

function FactionSystem.register(context)
	ctx = context
	for tag, country in context.WorldState.allCountries() do
		initFactions(country)
		country.legitimacy = computeLegitimacy(country)
		context.WorldState.setCountry(tag, country)
	end
	bindEvents()
	context.FactionSystem = {
		applyDelta = applyDelta,
		applyReactions = applyReactions,
		computeLegitimacy = computeLegitimacy,
		tierOf = tierOf,
		factionLawShift = factionLawShift,
		getClout = function(tag, factionId)
			local c = context.WorldState.getCountry(tag)
			return c and c.factions and c.factions[factionId] and c.factions[factionId].clout or 0
		end,
		getFactions = function(tag)
			local c = context.WorldState.getCountry(tag)
			return c and c.factions or {}
		end,
	}
	context.TickScheduler.register({
		id = "FactionSystem",
		priority = 19,
		updateIntervalSeconds = context.WorldConstants.FactionTickInterval,
		update = tickFactions,
	})
end

return FactionSystem
