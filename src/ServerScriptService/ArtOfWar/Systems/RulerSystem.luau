-- RulerSystem — rulers as first-class characters who age, die / leave office, and hand power to a
-- successor per government archetype (hereditary heir + regency / elective / republican term /
-- tribal strongest). Reuses LeaderSystem's name/trait/portrait generators. Relevant-gated +
-- change-guarded; aging runs once per in-game year. NO rebel armies — disputed succession is a
-- legitimacy/stability penalty + an event card (UnrestSystem provides the army-free pressure valve).

local RulerSystem = {}

local ctx

local function currentDay()
	local d = ctx.TickScheduler.getGameDate()
	return (d.year - 1) * 365 + (d.month - 1) * 30 + d.day
end

local function LS()
	return ctx.LeaderSystem
end

-- bell-ish 0..6 ruler stat, typical 2..4
local function statRoll()
	local rng = LS().rng
	return math.clamp(rng:NextInteger(0, 3) + rng:NextInteger(0, 3), 0, 6)
end

local function successionKindOf(country)
	local ga = ctx.Bundle and ctx.Bundle.governmentArchetypes
	return (ga and ga.get and ga.get(country.governmentForm).successionKind) or "hereditary"
end

-- Era-appropriate court title per government (falls back to the archetype word). A fuller
-- culture/religion-aware RulerTitles data file is a Phase-4 polish item.
local RULER_TITLE_BY_GOV = {
	absolute_monarchy = "King", constitutional_monarchy = "King", parliamentary_monarchy = "King",
	elective_monarchy = "King", composite_monarchy = "King", margravate = "Margrave",
	duchy = "Duke", county = "Count", tsardom = "Tsar", sultanate = "Sultan",
	caliphate = "Caliph", shogunate = "Shogun", khanate = "Khan", tribal_chiefdom = "Chief",
	merchant_republic = "Doge", free_city = "Burgomaster", confederation = "President",
	theocracy = "High Priest", prince_bishopric = "Prince-Bishop", ecclesiastical = "Prelate",
	despotism = "Despot", imperial_bureaucracy = "Emperor",
}

local function rulerTitle(country)
	local t = RULER_TITLE_BY_GOV[country.governmentForm]
	if t then return t end
	local ga = ctx.Bundle and ctx.Bundle.governmentArchetypes
	local labels = ga and ga.labelsFor and ga.labelsFor(country.governmentForm)
	return (labels and labels.leaderWord) or "Ruler"
end

local function genTraits(country)
	local ls = LS()
	local pool, total = ls.buildTraitPool("__ruler__") -- sentinel slot → uniform-ish base weights
	local n = ls.rng:NextInteger(ctx.WorldConstants.LeaderTraitMinimum, ctx.WorldConstants.LeaderTraitMaximum)
	local traits, used = {}, {}
	for _ = 1, n do
		local t = ls.pickTrait(pool, total, used)
		if t then
			used[t] = true
			table.insert(traits, t)
		end
	end
	return traits
end

local function generateRuler(country, opts)
	opts = opts or {}
	local ls = LS()
	local first, last = ls.generateName(country)
	local age = opts.age or ls.rng:NextInteger(ctx.WorldConstants.RulerStartAgeMin, ctx.WorldConstants.RulerStartAgeMax)
	return {
		id = ls.allocId(),
		firstName = first,
		lastName = last or "",
		title = opts.title or rulerTitle(country),
		age = age,
		bornDay = currentDay() - age * 360,
		adm = statRoll(),
		dip = statRoll(),
		mil = statRoll(),
		traits = genTraits(country),
		legitimacyClaim = opts.legitimacyClaim or ls.rng:NextInteger(40, 95),
		isRegent = opts.isRegent,
		portraitId = ls.rng:NextInteger(1, ctx.WorldConstants.LeaderPortraitPoolSize),
	}
end

-- Hereditary realms keep a standing heir (same house). Other archetypes build candidates on vacancy.
local function generateHeir(country)
	if successionKindOf(country) ~= "hereditary" then
		return nil
	end
	local ls = LS()
	local heir = generateRuler(country, { age = ls.rng:NextInteger(0, 28), legitimacyClaim = ls.rng:NextInteger(70, 100) })
	if country.ruler then
		heir.lastName = country.ruler.lastName -- same dynasty
	end
	return heir
end

local function ensureRuler(country)
	local changed = false
	if not country.ruler then
		country.ruler = generateRuler(country)
		if successionKindOf(country) == "republican_term" then
			country.ruler.termEndDay = currentDay() + ctx.WorldConstants.RulerTermLengthDays
		end
		changed = true
	end
	if not country.heir then
		local h = generateHeir(country)
		if h then
			country.heir = h
			changed = true
		end
	end
	return changed
end

local function maybeDisputed(tag, country, newRuler)
	local wc = ctx.WorldConstants
	local weak = (country.legitimacy or 50) < wc.SuccessionDisputeLegitimacyFloor
		or (newRuler.legitimacyClaim or 50) < wc.SuccessionDisputeClaimFloor
	if not weak then
		return
	end
	country.legitimacy = math.clamp((country.legitimacy or 50) - wc.SuccessionDisputeLegitimacyHit, wc.LegitimacyMin, wc.LegitimacyMax)
	country.stability = math.clamp((country.stability or 0) - wc.SuccessionDisputeStabilityHit, wc.StabilityMin, wc.StabilityMax)
	if ctx.EventSystem and ctx.EventSystem.fireEvent then
		ctx.EventSystem.fireEvent(tag, "disputed_succession", { rulerName = newRuler.firstName })
	end
end

-- Install newRuler as the country's ruler (term stamp + heir regen + events). Writes the country.
local function install(tag, country, newRuler, opts)
	opts = opts or {}
	local wc = ctx.WorldConstants
	local kind = successionKindOf(country)
	newRuler.isRegent = opts.regent or nil
	country.ruler = newRuler
	if kind == "republican_term" then
		country.ruler.termEndDay = currentDay() + wc.RulerTermLengthDays
	end
	country.heir = generateHeir(country) -- nil for non-hereditary
	ctx.WorldState.setCountry(tag, country)
	ctx.EventBus.publish(ctx.Channels.SuccessionResolved, {
		tag = tag,
		kind = kind,
		rulerId = newRuler.id,
		rulerName = ((newRuler.firstName or "") .. " " .. (newRuler.lastName or "")):gsub("%s+$", ""),
		regency = opts.regent or false,
	})
	if opts.regent and ctx.EventSystem and ctx.EventSystem.fireEvent then
		ctx.EventSystem.fireEvent(tag, "regency_council", { rulerName = newRuler.firstName })
	end
	maybeDisputed(tag, country, newRuler)
end

local function buildCandidates(tag, country, kind)
	local ls = LS()
	local list = {}
	local count = ctx.WorldConstants.SuccessionCandidates
	if kind == "elective" then
		-- candidates championed by the most influential estates; claim ∝ estate clout + loyalty
		local estates = (ctx.EstateSystem and ctx.EstateSystem.getEstates and ctx.EstateSystem.getEstates(tag)) or country.factions or {}
		local ranked = {}
		for fid, rec in estates do
			if fid ~= "crown" then
				table.insert(ranked, { fid = fid, score = (rec.clout or 0) * 100 + (rec.loyalty or 50) * 0.2 })
			end
		end
		table.sort(ranked, function(a, b) return a.score > b.score end)
		for i = 1, math.min(#ranked, count) do
			local cand = generateRuler(country, { legitimacyClaim = math.clamp(40 + ranked[i].score, 0, 100) })
			cand.backingEstate = ranked[i].fid
			table.insert(list, cand)
		end
	elseif kind == "tribal_strongest" then
		for _ = 1, count do
			local cand = generateRuler(country)
			cand.legitimacyClaim = math.clamp(50 + (cand.mil - 3) * 10 + ls.rng:NextInteger(-10, 10), 0, 100)
			table.insert(list, cand)
		end
	else -- republican_term
		for _ = 1, count do
			table.insert(list, generateRuler(country, { title = "Head of State" }))
		end
	end
	if #list == 0 then
		table.insert(list, generateRuler(country))
	end
	return list
end

local function bestCandidate(list)
	local best = list[1]
	for _, c in list do
		if (c.legitimacyClaim or 0) > (best.legitimacyClaim or 0) then
			best = c
		end
	end
	return best
end

-- Power becomes vacant (death / term end). Hereditary promotes the heir (regency if a minor);
-- other archetypes auto-pick the strongest/estate-backed claimant. (Interactive candidate choice
-- is a future follow-up — see memory.)
local function beginVacancy(tag, country, reason, formerRuler)
	local wc = ctx.WorldConstants
	local kind = successionKindOf(country)
	if formerRuler then
		ctx.EventBus.publish(ctx.Channels.RulerDied, { tag = tag, ruler = formerRuler, reason = reason })
	end
	if kind == "hereditary" and country.heir then
		local heir = country.heir
		local minor = (heir.age or 99) < wc.RulerRegencyAge
		local swing = math.floor(((heir.legitimacyClaim or 50) - 50) / wc.HeirClaimLegitimacyDivisor)
		country.legitimacy = math.clamp((country.legitimacy or 50) + swing, wc.LegitimacyMin, wc.LegitimacyMax)
		install(tag, country, heir, { regent = minor })
		return true
	end
	local effectiveKind = (kind == "hereditary") and "elective" or kind -- no heir → contested
	local candidates = buildCandidates(tag, country, effectiveKind)
	ctx.EventBus.publish(ctx.Channels.SuccessionStarted, { tag = tag, kind = effectiveKind, candidates = #candidates })
	install(tag, country, bestCandidate(candidates))
	return true
end

local function deathChance(age)
	local wc = ctx.WorldConstants
	if age < wc.RulerDeathFloorAge then
		return wc.RulerDeathBaseChance
	end
	return math.min(wc.RulerDeathMaxChance, wc.RulerDeathBaseChance + (age - wc.RulerDeathFloorAge) * wc.RulerDeathChancePerYear)
end

local function ageCountry(tag, country)
	local r = country.ruler
	if not r then
		return ensureRuler(country)
	end
	r.age = (r.age or 30) + 1
	if country.heir then
		country.heir.age = (country.heir.age or 0) + 1
	end
	-- a regent steps aside once the ruler comes of age
	if r.isRegent and (r.age or 0) >= ctx.WorldConstants.RulerRegencyAge then
		r.isRegent = nil
	end
	local extra = 0
	for _, t in (r.traits or {}) do
		if t == "old_age" then
			extra = ctx.WorldConstants.RulerOldAgeExtraChance
		end
	end
	if LS().rng:NextNumber() < (deathChance(r.age) + extra) then
		beginVacancy(tag, country, "death", r)
		return true
	end
	return false
end

local function tickSuccession(tag, country, day)
	local r = country.ruler
	if r and successionKindOf(country) == "republican_term" and r.termEndDay and day >= r.termEndDay then
		beginVacancy(tag, country, "term_end", r)
		return true
	end
	return false
end

local lastAgedYear = nil
local function successionTick(sysCtx)
	local gd = sysCtx.gameDate
	local day = currentDay()
	local relevant = ctx.PlayerAuthority and ctx.PlayerAuthority.relevantSet and ctx.PlayerAuthority.relevantSet() or nil
	-- age + death roll only on year rollover
	local doAge = false
	if lastAgedYear == nil then
		lastAgedYear = gd.year
	elseif gd.year ~= lastAgedYear then
		doAge = true
		lastAgedYear = gd.year
	end
	for tag, country in ctx.WorldState.allCountries() do
		if relevant and not relevant[tag] then
			continue
		end
		if tag:sub(1, 4) == "REB_" then
			continue
		end
		local changed = false
		if not country.ruler then
			changed = ensureRuler(country) or changed
		end
		if doAge then
			changed = ageCountry(tag, country) or changed
		end
		changed = tickSuccession(tag, country, day) or changed
		if changed then
			ctx.WorldState.setCountry(tag, country)
		end
	end
end

function RulerSystem.register(context)
	ctx = context
	context.RulerSystem = {
		generateRuler = generateRuler,
		generateHeir = generateHeir,
		ensureRuler = ensureRuler,
	}
	context.TickScheduler.register({
		id = "RulerSystem",
		priority = 22, -- after EstateSystem(19)/UnrestSystem(20)/EventSystem(21)
		updateIntervalSeconds = context.WorldConstants.SuccessionTickInterval,
		-- start runs after every system's register (TickScheduler.start), so ctx.LeaderSystem exists.
		start = function()
			for tag, country in context.WorldState.allCountries() do
				if tag:sub(1, 4) ~= "REB_" and ensureRuler(country) then
					context.WorldState.setCountry(tag, country)
				end
			end
		end,
		update = successionTick,
	})
end

return RulerSystem
