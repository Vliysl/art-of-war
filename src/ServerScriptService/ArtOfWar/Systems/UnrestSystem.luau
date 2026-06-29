-- UnrestSystem — country-level unrest (the politics "pressure" meter). Unrest drifts toward a
-- target = pressure − relief each tick, exactly mirroring FactionSystem's settling-point + change-
-- guard discipline so a content realm is a no-write fixed point. Crossing the rebellion threshold
-- publishes RebellionTriggered (RebellionSystem, Phase 2B, listens). Relevant-only + change-guarded
-- (perf-cascade history: never write every country every tick).
--
-- Pressure: disloyal high-influence estates, low legitimacy, negative stability, war exhaustion,
--           being mid-transition (over-reform).
-- Relief:   base decay, high legitimacy, positive stability, strong Crown Authority.

local UnrestSystem = {}

local ctx

local function currentDay()
	local d = ctx.TickScheduler.getGameDate()
	return (d.year - 1) * 365 + (d.month - 1) * 30 + d.day
end

local function clampUnrest(v)
	return math.clamp(v, ctx.WorldConstants.UnrestMin, ctx.WorldConstants.UnrestMax)
end

-- Max exhaustion this country carries across its active (non-rebel) wars, normalized 0..1.
-- Rebel ("REB_") wars are excluded so a rebellion's own war-exhaustion can't feed back into the
-- unrest that spawned it (runaway-loop guard).
local function warExhaustion01(tag)
	if not ctx.WorldState.allWars then
		return 0
	end
	local maxEx = 0
	for _, war in ctx.WorldState.allWars() do
		if war.status == "active"
			and war.attackerTag and war.attackerTag:sub(1, 4) ~= "REB_"
			and war.defenderTag and war.defenderTag:sub(1, 4) ~= "REB_"
		then
			if war.attackerTag == tag then
				maxEx = math.max(maxEx, war.attackerExhaustion or 0)
			elseif war.defenderTag == tag then
				maxEx = math.max(maxEx, war.defenderExhaustion or 0)
			end
		end
	end
	return math.clamp(maxEx / (ctx.WorldConstants.WarExhaustionMax or 100), 0, 1)
end

local function authority01(country)
	local cap = country.crownAuthorityCap or ctx.WorldConstants.CrownAuthorityCapBase or 100
	if cap <= 0 then
		return 0
	end
	return math.clamp((country.crownAuthority or 0) / cap, 0, 1)
end

local function worstEstate(country)
	if not country.factions then
		return nil
	end
	local worstId, worstLoy
	for fid, rec in country.factions do
		if fid ~= "crown" then
			local loy = rec.loyalty or ctx.WorldConstants.EstateLoyaltyBase
			if not worstLoy or loy < worstLoy then
				worstId, worstLoy = fid, loy
			end
		end
	end
	return worstId
end

local function hasActiveRebellion(country)
	if not country.rebellions then
		return false
	end
	for _ in country.rebellions do
		return true
	end
	return false
end

local function targetUnrest(tag, country)
	local wc = ctx.WorldConstants
	local legit = country.legitimacy or wc.LegitimacyBase or 50
	local stab = country.stability or 0

	-- pressure (raises unrest)
	local pressure = 0
	if country.factions then
		for fid, rec in country.factions do
			if fid ~= "crown" then
				local loy = rec.loyalty or wc.EstateLoyaltyBase
				-- the dangerous combo is "powerful AND angry": disloyalty scaled by the estate's share
				local disloyalty = math.max(0, (wc.UnrestEstateLoyaltyPivot - loy) / wc.UnrestEstateLoyaltyPivot)
				pressure += disloyalty * (rec.clout or 0) * wc.UnrestEstateCloutWeight
			end
		end
	end
	pressure += math.max(0, (wc.UnrestLegitimacyPivot - legit) / wc.UnrestLegitimacyPivot) * wc.UnrestLegitimacyWeight
	pressure += math.max(0, -stab) * wc.UnrestStabilityWeight
	pressure += warExhaustion01(tag) * wc.UnrestWarExhaustionWeight
	if country.transition then
		pressure += wc.UnrestActiveTransitionFlat
	end

	-- relief (lowers unrest)
	local relief = wc.UnrestBaseDecay
	relief += math.max(0, (legit - wc.UnrestLegitimacyPivot) / wc.UnrestLegitimacyPivot) * wc.UnrestGoodGovReliefWeight
	relief += math.max(0, stab) * wc.UnrestStabilityReliefWeight
	relief += authority01(country) * wc.UnrestAuthorityReliefWeight

	return clampUnrest(pressure - relief)
end

local function tick()
	-- relevant-only (claimed / at-war); frozen countries never compute unrest
	local relevant = ctx.PlayerAuthority and ctx.PlayerAuthority.relevantSet and ctx.PlayerAuthority.relevantSet() or nil
	local wc = ctx.WorldConstants
	local day = currentDay()
	for tag, country in ctx.WorldState.allCountries() do
		if relevant and not relevant[tag] then
			continue
		end
		if tag:sub(1, 4) == "REB_" then
			continue -- synthetic rebel countries never simulate unrest
		end
		local prev = country.unrest or 0
		local target = targetUnrest(tag, country)
		local newUnrest = clampUnrest(prev + (target - prev) * wc.UnrestDriftPerTick)

		local crossedUp = prev < wc.UnrestRebellionThreshold and newUnrest >= wc.UnrestRebellionThreshold

		-- change-guard: only write/replicate when it actually moved (or we just crossed a threshold)
		if math.abs(newUnrest - prev) > 1e-4 or crossedUp then
			country.unrest = newUnrest
			ctx.WorldState.setCountry(tag, country)
			if math.abs(newUnrest - prev) > 0.5 then
				ctx.EventBus.publish(ctx.Channels.CountryUnrestChanged, {
					tag = tag, total = newUnrest, previous = prev,
				})
			end
		end

		if crossedUp then
			local onCooldown = (country.rebellionCooldownDay or 0) > day
			if not onCooldown and not hasActiveRebellion(country) then
				ctx.EventBus.publish(ctx.Channels.RebellionTriggered, {
					tag = tag, unrest = newUnrest, day = day, estateId = worstEstate(country),
				})
			end
		end
	end
end

function UnrestSystem.register(context)
	ctx = context
	context.UnrestSystem = {
		getUnrest = function(tag)
			local c = context.WorldState.getCountry(tag)
			return (c and c.unrest) or 0
		end,
		targetUnrest = function(tag)
			local c = context.WorldState.getCountry(tag)
			return (c and targetUnrest(tag, c)) or 0
		end,
		worstEstate = function(tag)
			local c = context.WorldState.getCountry(tag)
			return c and worstEstate(c) or nil
		end,
	}
	context.TickScheduler.register({
		id = "UnrestSystem",
		priority = 20, -- after FactionSystem(19) settles loyalty/clout, before EventSystem(21)
		updateIntervalSeconds = context.WorldConstants.UnrestTickInterval,
		update = tick,
	})
end

return UnrestSystem
