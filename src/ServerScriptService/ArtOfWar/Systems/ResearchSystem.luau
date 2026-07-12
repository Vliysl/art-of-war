local ResearchSystem = {}

local ctx
local DEFAULT_RATE = 1

local function techs()
	return (ctx.Bundle and ctx.Bundle.technologies) or {}
end

local function ensureState(country)
	country.techs = country.techs or {}
	country.research = country.research or {}
	country.research.progress = country.research.progress or {}
	return country
end

local function hasTech(country, id)
	return country.techs and country.techs[id] == true
end

local function prereqsMet(country, def)
	for _, p in ipairs(def.prerequisites or {}) do
		if not hasTech(country, p) then
			return false
		end
	end
	return true
end

local function aggregateModifier(country, key)
	local total = 0
	local T = techs()
	for id in country.techs or {} do
		local def = T[id]
		if def and def.effects and def.effects.modifiers then
			local v = def.effects.modifiers[key]
			if type(v) == "number" then
				total += v
			end
		end
	end
	return total
end

local function researchRate(country)
	local base = (ctx.WorldConstants and ctx.WorldConstants.ResearchPointsPerDay) or DEFAULT_RATE
	return base * (1 + aggregateModifier(country, "research_speed"))
end

local function applyGates(country, def)
	country.techs[def.id] = true
	for _, g in ipairs(def.gates or {}) do
		country.techs[g] = true
	end
end

local function grantStarting(country)
	for _, def in techs() do
		if def.starting then
			applyGates(country, def)
		end
	end
end

local function completeTech(tag, country, def)
	applyGates(country, def)
	country.research.progress[def.id] = nil
	if country.research.active == def.id then
		country.research.active = nil
	end

	local leaderSys = ctx.LeaderSystem
	if leaderSys and leaderSys.unlockSlot and ctx.Bundle and ctx.Bundle.leaderSlots then
		for slotId, slotDef in ctx.Bundle.leaderSlots do
			if slotDef.researchGate and country.techs[slotDef.researchGate] then
				pcall(leaderSys.unlockSlot, tag, slotId)
			end
		end
	end

	local nb = ctx.NotificationBroadcaster
	if nb and nb.push then
		nb.push({
			kind = "good",
			title = "Research Complete",
			body = "We have discovered " .. (def.name or def.id) .. ".",
			audience = "self",
			tag = tag,
			ttl = 6,
		})
	end

	if ctx.EventBus and ctx.Channels and ctx.Channels.TechCompleted then
		ctx.EventBus.publish(ctx.Channels.TechCompleted, { tag = tag, techId = def.id })
	end
end

local function applyDays(daysAdvanced)
	local days = daysAdvanced or 1
	if days <= 0 then
		return
	end
	-- S3: only relevant (claimed / at-war) countries advance research; frozen countries hold their
	-- progress (no AI researches for them, and a claimant sees their seeded starting techs). This loop
	-- runs on every DateAdvanced (~2.7x/sec at speed 4), so gating it drops it from all ~104 countries
	-- to the ~players-relevant set -- the last ungated economy-adjacent per-day walk (matches S3 elsewhere).
	local relevant = ctx.PlayerAuthority and ctx.PlayerAuthority.relevantSet and ctx.PlayerAuthority.relevantSet()
		or nil
	local T = techs()
	for tag in ctx.WorldState.allCountries() do
		if relevant and not relevant[tag] then
			continue
		end
		local country = ctx.WorldState.getCountry(tag)
		if country then
			ensureState(country)
			local active = country.research.active
			local def = active and T[active]
			if def and not hasTech(country, active) then
				if prereqsMet(country, def) then
					local current = (country.research.progress[active] or 0) + researchRate(country) * days
					if current >= (def.cost or 0) then
						completeTech(tag, country, def)
					else
						country.research.progress[active] = current
					end
				else
					country.research.active = nil
				end
				ctx.WorldState.setCountry(tag, country)
			end
		end
	end
end

local function startResearch(tag, techId)
	local country = ctx.WorldState.getCountry(tag)
	if not country then
		return false
	end
	ensureState(country)
	local def = techs()[techId]
	if not def or hasTech(country, techId) or not prereqsMet(country, def) then
		return false
	end
	country.research.active = techId
	ctx.WorldState.setCountry(tag, country)
	return true
end

local function seedAll()
	local T = techs()
	for tag in ctx.WorldState.allCountries() do
		local country = ctx.WorldState.getCountry(tag)
		if country then
			ensureState(country)
			grantStarting(country)
			-- Per-country starting techs from the Data Editor, granted ADDITIVELY on top of the
			-- global starting set. Unknown/stale ids are silently skipped (def guard).
			for id in country.startingTechs or {} do
				local def = T[id]
				if def then
					applyGates(country, def)
				end
			end
			ctx.WorldState.setCountry(tag, country)
		end
	end
end

function ResearchSystem.register(context)
	ctx = context
	context.ResearchSystem = {
		startResearch = startResearch,
		hasTech = function(tag, id)
			local c = ctx.WorldState.getCountry(tag)
			return (c and hasTech(c, id)) or false
		end,
		modifierTotal = function(tag, key)
			local c = ctx.WorldState.getCountry(tag)
			return (c and aggregateModifier(c, key)) or 0
		end,
	}
	for k, v in context.ResearchSystem do
		ResearchSystem[k] = v
	end

	if context.Channels and context.Channels.DateAdvanced then
		context.EventBus.subscribe(context.Channels.DateAdvanced, function(payload)
			applyDays(payload and payload.daysAdvanced)
		end)
	end

	context.TickScheduler.register({
		id = "ResearchSystem",
		priority = 30,
		updateIntervalSeconds = (context.WorldConstants and context.WorldConstants.SecondsPerSimTick) or 3,
		update = function() end,
		start = seedAll,
	})
end

return ResearchSystem
