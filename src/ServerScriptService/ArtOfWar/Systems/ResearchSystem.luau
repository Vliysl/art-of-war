-- ResearchSystem: the leveled, multi-slot technology tree (2026-07 rework).
--
-- Supersedes the flat single-tech list. A country owns each node at a LEVEL (country.techLevel[id]); researching
-- advances one level at a time. Up to slotCount nodes research in parallel (HOI4-style), each accruing a FLAT
-- base rate per in-game day. Node effects fold into two per-country aggregates (see TechDomains):
--   * multiplicative FACTORS (per-unit-class combat: infantry/cavalry/artillery/ship) -> ResearchSystem.factor
--   * additive BONUSES (economy/political/research) -> ResearchSystem.bonus (capped) / .raw (uncapped, for ModifierStack)
-- Seeding grants starting levels by the country's technologyGroup start-era (Data/Countries.technologyGroup),
-- so less-advanced groups begin further left in the tree.
--
-- Gated by WorldConstants.EnableTechTree: seeding (starting techs + gates, needed by leader researchGate) always
-- runs, but no slot progresses and the client tree window is inert until the flag flips on.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- TechDomains is required LAZILY (first runtime use), never at module load -- so ResearchSystem's module has
-- ZERO cross-container dependencies at boot and can never error/hang if TechDomains is still mid-sync. Until the
-- real module is available, a fail-safe stub treats every key as unknown (aggregation empty, tech effects off)
-- and the next call retries. With Bootstrap's pcall isolation, tech cannot break server boot in any sync state.
local TechDomains
local TechDomainsSafe = {
	isKnown = function()
		return false
	end,
	isMultiplicative = function()
		return false
	end,
	capFor = function()
		return math.huge
	end,
}
local function techDomains()
	if not TechDomains then
		local ok, mod = pcall(function()
			return require(ReplicatedStorage.ArtOfWar.Shared.TechDomains)
		end)
		if ok and type(mod) == "table" then
			TechDomains = mod
		else
			return TechDomainsSafe
		end
	end
	return TechDomains
end

local ResearchSystem = {}

local ctx
local DEFAULT_RATE = 1

-- Per-country derived aggregates, server-only (never replicated / persisted). Rebuilt on seed, updated
-- incrementally on each level gained. techAgg[tag] = { mods = {[domain]=sum}, factors = {[domain]=product} }.
local techAgg = {}

local function techs()
	return (ctx.Bundle and ctx.Bundle.technologies) or {}
end

local function ensureState(country)
	country.techs = country.techs or {}
	country.techLevel = country.techLevel or {}
	country.research = country.research or {}
	country.research.progress = country.research.progress or {}
	country.research.slotCount = country.research.slotCount
		or (ctx.WorldConstants and ctx.WorldConstants.ResearchSlotsStart)
		or 2
	country.research.slots = country.research.slots or {}
	return country
end

local function maxLevelOf(def)
	return def.maxLevel or 1
end

local function costForLevel(def, level)
	local c = def.cost
	if type(c) == "table" then
		if c.base then
			return c.base * (c.growth or 1) ^ (level - 1)
		end
		return c[level] or c[#c] or 0
	elseif type(c) == "number" then
		return c
	end
	return 0
end

local function eraForLevel(def, level)
	if def.eraByLevel and def.eraByLevel[level] then
		return def.eraByLevel[level]
	end
	return def.era
end

local function prereqsMet(country, def)
	for _, p in ipairs(def.prerequisites or {}) do
		if not (country.techs and country.techs[p]) then
			return false
		end
	end
	return true
end

-- Fold every owned level's modifiers into a fresh aggregate. Only keys registered in TechDomains contribute;
-- an unregistered key is inert-by-design (guards the name-mismatch trap).
local function rebuildAgg(tag, country)
	local agg = { mods = {}, factors = {} }
	local T = techs()
	for id, lvl in country.techLevel or {} do
		local def = T[id]
		if def then
			for L = 1, lvl do
				local eff = def.effects and def.effects[L]
				if eff and eff.modifiers then
					for domain, v in eff.modifiers do
						if type(v) == "number" and techDomains().isKnown(domain) then
							agg.mods[domain] = (agg.mods[domain] or 0) + v
							agg.factors[domain] = (agg.factors[domain] or 1) * (1 + v)
						end
					end
				end
			end
		end
	end
	techAgg[tag] = agg
	return agg
end

local function getAgg(tag)
	local agg = techAgg[tag]
	if agg then
		return agg
	end
	local country = ctx.WorldState.getCountry(tag)
	if not country then
		return { mods = {}, factors = {} }
	end
	ensureState(country)
	return rebuildAgg(tag, country)
end

local function applyLevelToAgg(tag, def, level)
	local agg = techAgg[tag]
	if not agg then
		return
	end
	local eff = def.effects and def.effects[level]
	if eff and eff.modifiers then
		for domain, v in eff.modifiers do
			if type(v) == "number" and techDomains().isKnown(domain) then
				agg.mods[domain] = (agg.mods[domain] or 0) + v
				agg.factors[domain] = (agg.factors[domain] or 1) * (1 + v)
			end
		end
	end
end

-- Research slots are unlockable: a node level may carry `slots = N` in its effects to raise the country's
-- concurrent-research count (Research tab). Recompute from all owned levels so it stays consistent after
-- seeding and each completion; clamped to [start, ResearchSlotsMax].
local function recomputeSlots(country)
	local wc = ctx.WorldConstants
	local start = (wc and wc.ResearchSlotsStart) or 2
	local maxSlots = (wc and wc.ResearchSlotsMax) or 5
	local bonus = 0
	local T = techs()
	for id, lvl in country.techLevel or {} do
		local def = T[id]
		if def and def.effects then
			for L = 1, lvl do
				local eff = def.effects[L]
				if eff and eff.slots then
					bonus += eff.slots
				end
			end
		end
	end
	country.research.slotCount = math.clamp(start + bonus, start, maxSlots)
end

-- Multiplicative combat factor for a stat, clamped to [1, branch cap]. Deterministic (pure function of
-- country.techLevel): safe to call inside CombatEngine/BattleManager.
local function clampFactor(tag, stat)
	local f = getAgg(tag).factors[stat] or 1
	return math.clamp(f, 1, techDomains().capFor(stat, ctx.WorldConstants))
end

-- Additive bonus for a domain, clamped to [0, domain cap]. Used by economy/political consumers as (1 +/- bonus).
local function clampBonus(tag, domain)
	local s = getAgg(tag).mods[domain] or 0
	return math.clamp(s, 0, techDomains().capFor(domain, ctx.WorldConstants))
end

local function researchRate(tag)
	local base = (ctx.WorldConstants and ctx.WorldConstants.ResearchPointsPerDay) or DEFAULT_RATE
	local gain = clampBonus(tag, "research_power_gain")
	local legacy = getAgg(tag).mods["research_speed"] or 0
	return base * (1 + gain + legacy)
end

local function effectiveCost(tag, def, level)
	local base = costForLevel(def, level)
	return base * (1 - clampBonus(tag, "research_efficiency"))
end

-- HUD compatibility: mirror the first active slot onto research.active (HudWiring reads it for the top-bar
-- research label). Nil while no slot is researching -- exactly the pre-rework HUD state.
local function syncActiveMirror(country)
	local firstActive
	for i = 1, country.research.slotCount do
		local s = country.research.slots[i]
		if s and s.active then
			firstActive = s.active
			break
		end
	end
	country.research.active = firstActive
end

local function completeLevel(tag, country, def, level)
	country.techLevel[def.id] = level
	country.techs[def.id] = true
	for _, g in ipairs(def.gates or {}) do
		country.techs[g] = true
	end
	country.research.progress[def.id] = nil
	applyLevelToAgg(tag, def, level)
	recomputeSlots(country)

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
		local suffix = level > 1 and (" (Level " .. level .. ")") or ""
		nb.push({
			kind = "good",
			title = "Research Complete",
			body = "We have developed " .. (def.name or def.id) .. suffix .. ".",
			audience = "self",
			tag = tag,
			ttl = 6,
		})
	end

	if ctx.EventBus and ctx.Channels and ctx.Channels.TechCompleted then
		ctx.EventBus.publish(ctx.Channels.TechCompleted, { tag = tag, techId = def.id, level = level })
	end
end

local function applyDays(daysAdvanced)
	if not (ctx.WorldConstants and ctx.WorldConstants.EnableTechTree) then
		return
	end
	local days = daysAdvanced or 1
	if days <= 0 then
		return
	end
	-- Only claimed / at-war countries advance research (matches the S3 relevance gate elsewhere); frozen
	-- countries hold their progress. This runs on every DateAdvanced (~2.7x/sec at speed 4).
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
			local changed = false
			for i = 1, country.research.slotCount do
				local slot = country.research.slots[i]
				if slot and slot.active then
					local def = T[slot.active]
					local cur = country.techLevel[slot.active] or 0
					local target = slot.targetLevel or (cur + 1)
					if not def or cur >= target or cur >= maxLevelOf(def) or not prereqsMet(country, def) then
						country.research.slots[i] = nil
						changed = true
					else
						local acc = (country.research.progress[slot.active] or 0) + researchRate(tag) * days
						if acc >= effectiveCost(tag, def, target) then
							completeLevel(tag, country, def, target)
							country.research.slots[i] = nil
						else
							country.research.progress[slot.active] = acc
						end
						changed = true
					end
				end
			end
			if changed then
				syncActiveMirror(country)
				ctx.WorldState.setCountry(tag, country)
			end
		end
	end
end

local function startResearch(tag, slotIndex, techId)
	local country = ctx.WorldState.getCountry(tag)
	if not country then
		return false
	end
	ensureState(country)
	slotIndex = tonumber(slotIndex)
	if not slotIndex or slotIndex < 1 or slotIndex > country.research.slotCount then
		return false
	end
	local def = techs()[techId]
	if not def then
		return false
	end
	local cur = country.techLevel[techId] or 0
	if cur >= maxLevelOf(def) or not prereqsMet(country, def) then
		return false
	end
	country.research.slots[slotIndex] = { active = techId, targetLevel = cur + 1 }
	syncActiveMirror(country)
	ctx.WorldState.setCountry(tag, country)
	return true
end

local function clearSlot(tag, slotIndex)
	local country = ctx.WorldState.getCountry(tag)
	if not country then
		return false
	end
	ensureState(country)
	slotIndex = tonumber(slotIndex)
	if not slotIndex or not country.research.slots[slotIndex] then
		return false
	end
	country.research.slots[slotIndex] = nil
	syncActiveMirror(country)
	ctx.WorldState.setCountry(tag, country)
	return true
end

local function grantLevelsUpTo(country, def, level)
	local maxL = maxLevelOf(def)
	if level > maxL then
		level = maxL
	end
	if level <= (country.techLevel[def.id] or 0) then
		return
	end
	country.techLevel[def.id] = level
	country.techs[def.id] = true
	for _, g in ipairs(def.gates or {}) do
		country.techs[g] = true
	end
end

local function seedCountry(tag, country)
	ensureState(country)
	local wc = ctx.WorldConstants
	local startYear = (
		wc
		and wc.TechGroupStartYear
		and country.technologyGroup
		and wc.TechGroupStartYear[country.technologyGroup]
	)
		or (wc and wc.TechGroupStartYearDefault)
		or 1750
	local T = techs()
	for _, def in T do
		local grant = 0
		if def.starting then
			grant = math.max(grant, def.startingLevel or 1)
		end
		for L = 1, maxLevelOf(def) do
			local era = eraForLevel(def, L)
			if era and era <= startYear then
				grant = math.max(grant, L)
			end
		end
		if grant > 0 then
			grantLevelsUpTo(country, def, grant)
		end
	end
	-- Per-country explicit startingTechs from the Data Editor (grant at least level 1, ADDITIVE on top of era).
	for id in country.startingTechs or {} do
		local def = T[id]
		if def then
			grantLevelsUpTo(country, def, math.max(1, country.techLevel[id] or 0))
		end
	end
	recomputeSlots(country)
	rebuildAgg(tag, country)
end

local function seedAll()
	for tag in ctx.WorldState.allCountries() do
		local country = ctx.WorldState.getCountry(tag)
		if country then
			seedCountry(tag, country)
			ctx.WorldState.setCountry(tag, country)
		end
	end
end

function ResearchSystem.register(context)
	ctx = context
	context.ResearchSystem = {
		startResearch = startResearch,
		clearSlot = clearSlot,
		hasTech = function(tag, id)
			local c = ctx.WorldState.getCountry(tag)
			return (c and c.techs and c.techs[id] == true) or false
		end,
		techLevel = function(tag, id)
			local c = ctx.WorldState.getCountry(tag)
			return (c and c.techLevel and c.techLevel[id]) or 0
		end,
		-- Multiplicative combat factor for a per-unit-class stat, clamped to the branch cap. Returns the neutral
		-- 1 while EnableTechTree is off so the live game is unchanged even though seeding populates techLevel.
		factor = function(tag, stat)
			if not (ctx.WorldConstants and ctx.WorldConstants.EnableTechTree) then
				return 1
			end
			return clampFactor(tag, stat)
		end,
		-- Additive economy/political bonus for a domain, clamped to the domain cap (0 while the tree is off).
		bonus = function(tag, domain)
			if not (ctx.WorldConstants and ctx.WorldConstants.EnableTechTree) then
				return 0
			end
			return clampBonus(tag, domain)
		end,
		-- Uncapped additive sum (ModifierStack folds this so its own consumer clamps). 0 while the tree is off.
		raw = function(tag, domain)
			if not (ctx.WorldConstants and ctx.WorldConstants.EnableTechTree) then
				return 0
			end
			return getAgg(tag).mods[domain] or 0
		end,
		-- ModifierStack fold: 0 for multiplicative combat domains (handled in BattleManager, not here) and 0
		-- while the tree is off, else the capped additive bonus.
		additiveFold = function(tag, domain)
			if not (ctx.WorldConstants and ctx.WorldConstants.EnableTechTree) then
				return 0
			end
			if techDomains().isMultiplicative(domain) then
				return 0
			end
			return clampBonus(tag, domain)
		end,
		modifierTotal = function(tag, key)
			return getAgg(tag).mods[key] or 0
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
