local LeaderSystem = {}

local ctx
local rng
local leaderIdCounter = 0

local function allocId()
	leaderIdCounter += 1
	return string.format("L%06d", leaderIdCounter)
end

local function namePoolFor(cultureGroupId)
	local pools = ctx.Bundle and ctx.Bundle.leaderNames
	if not pools then return nil end
	return pools[cultureGroupId] or pools.default
end

local function cultureGroupOf(country)
	local bundle = ctx.Bundle
	if not bundle or not bundle.cultures then return nil end
	local culture = bundle.cultures[country.primaryCulture]
	return culture and culture.groupId or nil
end

local function pickFrom(list)
	if not list or #list == 0 then return nil end
	return list[rng:NextInteger(1, #list)]
end

local function generateName(country)
	local pool = namePoolFor(cultureGroupOf(country))
	if not pool then pool = ctx.Bundle.leaderNames.default end
	local first = pickFrom(pool.first) or "Unnamed"
	local last = pickFrom(pool.last)
	if last and last ~= "" then
		return first, last
	end
	return first, ""
end

local function resolveTitle(country, slotId)
	local titles = ctx.Bundle and ctx.Bundle.leaderTitles
	local entry = titles and titles[slotId]
	if not entry then return slotId end
	if entry.perCountry and entry.perCountry[country.tag] then
		return entry.perCountry[country.tag]
	end
	if entry.perGovernment and entry.perGovernment[country.governmentForm] then
		return entry.perGovernment[country.governmentForm]
	end
	if entry.perCulture and entry.perCulture[cultureGroupOf(country)] then
		return entry.perCulture[cultureGroupOf(country)]
	end
	return entry.default or slotId
end

local function traitWeightForSlot(trait, slotId)
	local base = trait.weight or 1
	if not trait.preferredSlots or #trait.preferredSlots == 0 then return base end
	for _, preferred in trait.preferredSlots do
		if preferred == slotId then return base * 3 end
	end
	return base * 0.25
end

local function buildTraitPool(slotId)
	local bundle = ctx.Bundle
	if not bundle or not bundle.leaderTraits then return {} end
	local entries = {}
	local total = 0
	for traitId, trait in bundle.leaderTraits do
		local w = traitWeightForSlot(trait, slotId)
		if w > 0 then
			total += w
			table.insert(entries, { traitId = traitId, weight = w, cum = total })
		end
	end
	return entries, total
end

local function pickTrait(pool, total, used)
	for _ = 1, 12 do
		local roll = rng:NextNumber(0, total)
		for _, entry in pool do
			if roll <= entry.cum then
				if not used[entry.traitId] then
					return entry.traitId
				end
				break
			end
		end
	end
	for _, entry in pool do
		if not used[entry.traitId] then return entry.traitId end
	end
	return nil
end

local function generateLeader(country, slotId, slotDef)
	local traitCount = rng:NextInteger(ctx.WorldConstants.LeaderTraitMinimum, ctx.WorldConstants.LeaderTraitMaximum)
	local pool, total = buildTraitPool(slotId)
	local traits = {}
	local used = {}
	for _ = 1, traitCount do
		local traitId = pickTrait(pool, total, used)
		if traitId then
			used[traitId] = true
			table.insert(traits, traitId)
		end
	end

	local first, last = generateName(country)
	return {
		id = allocId(),
		firstName = first,
		lastName = last,
		title = resolveTitle(country, slotId),
		slot = slotId,
		traits = traits,
		portraitId = rng:NextInteger(1, ctx.WorldConstants.LeaderPortraitPoolSize),
		appointedAt = ctx.TickScheduler.getSimTime(),
	}
end

local function slotUnlocked(country, slotDef)
	if slotDef.unlockedByDefault then return true end
	if not slotDef.researchGate then return false end
	return country.techs and country.techs[slotDef.researchGate] == true or false
end

local function initLeaders(country)
	country.leaders = country.leaders or {}
	country.leaderCandidates = country.leaderCandidates or {}
	local slots = ctx.Bundle and ctx.Bundle.leaderSlots
	if not slots then return end
	for slotId, slotDef in slots do
		if slotUnlocked(country, slotDef) and not country.leaders[slotId] then
			country.leaders[slotId] = generateLeader(country, slotId, slotDef)
		end
	end
end

local function generateCandidates(country, slotId, slotDef)
	local count = ctx.WorldConstants.LeaderCandidatesPerSlot
	local list = {}
	for _ = 1, count do
		table.insert(list, generateLeader(country, slotId, slotDef))
	end
	country.leaderCandidates = country.leaderCandidates or {}
	country.leaderCandidates[slotId] = list
	return list
end

local function appoint(tag, slotId, candidateIndex)
	local country = ctx.WorldState.getCountry(tag)
	if not country then return false, "unknown_country" end
	local slotDef = ctx.Bundle and ctx.Bundle.leaderSlots and ctx.Bundle.leaderSlots[slotId]
	if not slotDef then return false, "unknown_slot" end
	if not slotUnlocked(country, slotDef) then return false, "slot_locked" end
	country.leaderCandidates = country.leaderCandidates or {}
	local candidates = country.leaderCandidates[slotId]
	if not candidates or not candidates[candidateIndex] then
		return false, "unknown_candidate"
	end
	if not ctx.PoliticalPower.spend(tag, ctx.WorldConstants.LeaderAppointmentCost, "leader_appointment") then
		return false, "insufficient_pp"
	end
	local chosen = candidates[candidateIndex]
	chosen.title = resolveTitle(country, slotId)
	chosen.appointedAt = ctx.TickScheduler.getSimTime()
	local previous = country.leaders and country.leaders[slotId]
	country.leaders = country.leaders or {}
	country.leaders[slotId] = chosen
	country.leaderCandidates[slotId] = nil
	ctx.WorldState.setCountry(tag, country)
	ctx.EventBus.publish(ctx.Channels.LeaderAppointed, {
		tag = tag, slot = slotId, leader = chosen, previous = previous,
	})
	return true
end

local function dismiss(tag, slotId)
	local country = ctx.WorldState.getCountry(tag)
	if not country then return false, "unknown_country" end
	local slotDef = ctx.Bundle and ctx.Bundle.leaderSlots and ctx.Bundle.leaderSlots[slotId]
	if not slotDef then return false, "unknown_slot" end
	if not slotUnlocked(country, slotDef) then return false, "slot_locked" end
	if not country.leaders or not country.leaders[slotId] then return false, "no_leader" end
	if not ctx.PoliticalPower.spend(tag, ctx.WorldConstants.LeaderDismissalCost, "leader_dismissal") then
		return false, "insufficient_pp"
	end
	local dismissed = country.leaders[slotId]
	country.leaders[slotId] = nil
	local candidates = generateCandidates(country, slotId, slotDef)
	ctx.WorldState.setCountry(tag, country)
	ctx.EventBus.publish(ctx.Channels.LeaderDismissed, {
		tag = tag, slot = slotId, dismissed = dismissed,
	})
	ctx.EventBus.publish(ctx.Channels.LeaderCandidatesGenerated, {
		tag = tag, slot = slotId, candidates = candidates,
	})
	return true
end

local function unlockSlot(tag, slotId)
	local country = ctx.WorldState.getCountry(tag)
	if not country then return false end
	local slotDef = ctx.Bundle and ctx.Bundle.leaderSlots and ctx.Bundle.leaderSlots[slotId]
	if not slotDef then return false end
	country.leaders = country.leaders or {}
	if country.leaders[slotId] then return false end
	country.leaders[slotId] = generateLeader(country, slotId, slotDef)
	ctx.WorldState.setCountry(tag, country)
	ctx.EventBus.publish(ctx.Channels.LeaderSlotUnlocked, {
		tag = tag, slot = slotId, leader = country.leaders[slotId],
	})
	return true
end

function LeaderSystem.register(context)
	ctx = context
	rng = Random.new()
	for tag, country in context.WorldState.allCountries() do
		initLeaders(country)
		context.WorldState.setCountry(tag, country)
	end
	context.LeaderSystem = {
		appoint = appoint,
		dismiss = dismiss,
		unlockSlot = unlockSlot,
		resolveTitle = resolveTitle,
		generateCandidates = generateCandidates,
		slotUnlocked = slotUnlocked,
		getLeader = function(tag, slotId)
			local c = context.WorldState.getCountry(tag)
			return c and c.leaders and c.leaders[slotId] or nil
		end,
	}
	for k, v in pairs(context.LeaderSystem) do LeaderSystem[k] = v end
end

return LeaderSystem
