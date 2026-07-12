-- AISystem: a minimal reactive brain for non-player ("AI") countries. This first pass does two
-- things while an AI is at war:
--   1. RECRUITMENT — queues a cheap regiment at the AI's threatened border provinces (normal gold/
--      manpower cost & recruit time via RecruitSystem.enqueue, which validates & deducts).
--   2. DEFENSE — marches idle armies toward those border provinces (MovementSystem.beginMovePath).
--
-- It reacts immediately when war is declared (WarDeclared) and keeps acting on a slow tick. An AI
-- country is any country with no claimedBy (no player in control). Structured so an "offense"
-- behavior can later be added as another per-tag pass without reworking this.
local AISystem = {}

local ctx

local AI_TICK_SECONDS = 8        -- cadence of the maintenance pass
local RECRUIT_COOLDOWN = 20      -- min sim-seconds between recruit waves per AI (treasury pacing)
local RECRUIT_PER_TICK = 2       -- border provinces queued per AI per wave
local DEFENSE_MOVES_PER_TICK = 2 -- idle armies redeployed per AI per pass

local defaultUnitId = nil
local lastRecruitAt = {}         -- tag -> sim time of last recruit wave

local function isUnowned(tag)
	return tag == nil or tag == "" or tag == "NONE"
end

local function isAI(tag)
	local c = tag and ctx.WorldState.getCountry(tag)
	return c ~= nil and c.claimedBy == nil
end

local function atWar(a, b)
	local dipl = ctx.DiplomacySystem
	return (dipl and dipl.areAtWar and dipl.areAtWar(a, b)) == true
end

-- Cheapest default-unlocked regiment; cached after first resolve.
local function pickDefaultUnit()
	local types = ctx.Bundle and ctx.Bundle.unitTypes
	if not types then return nil end
	local bestId, bestCost
	for id, def in pairs(types) do
		if type(def) == "table" and def.unlockedByDefault ~= false and type(def.recruitCost) == "number" then
			if not bestCost or def.recruitCost < bestCost then
				bestId, bestCost = id, def.recruitCost
			end
		end
	end
	return bestId
end

-- Set of AI tags that are belligerents in some active war.
local function activeWarAITags()
	local set = {}
	for _, war in ctx.WorldState.allWars() do
		if war.status == "active" then
			if isAI(war.attackerTag) then set[war.attackerTag] = true end
			if isAI(war.defenderTag) then set[war.defenderTag] = true end
		end
	end
	return set
end

-- Per-tag list of border provinces (owned+controlled by the AI and adjacent to a province controlled by a
-- country it is at war with). Checks one owned province; shared by the fast + fallback paths below.
local function checkBorderProvince(borders, adj, tag, pid, prov)
	if prov.controllerTag ~= tag then
		return
	end
	for _, n in ipairs(adj.getNeighbors(pid)) do
		local np = ctx.WorldState.getProvince(n)
		local nc = np and np.controllerTag
		if nc and nc ~= tag and not isUnowned(nc) and atWar(tag, nc) then
			local list = borders[tag]
			if not list then
				list = {}
				borders[tag] = list
			end
			table.insert(list, pid)
			return
		end
	end
end

local function collectBorders(aiSet)
	local borders = {}
	local adj = ctx.AdjacencyGraph
	if not adj or not adj.getNeighbors then
		return borders
	end
	-- perf: iterate ONLY each at-war AI's owned provinces via the ProvinceRegistry byOwner index instead of
	-- sweeping all ~5713 provinces every tick (measured as a multi-hundred-ms / ~1.3s server stall at war
	-- scale). O(sum of AI-owned provinces) vs O(all provinces); identical result. Falls back to the full
	-- sweep only if the registry is unavailable.
	local registry = ctx.ProvinceRegistry
	if registry and registry.byOwner then
		for tag in aiSet do
			for _, pid in ipairs(registry.byOwner(tag)) do
				local prov = ctx.WorldState.getProvince(pid)
				if prov then
					checkBorderProvince(borders, adj, tag, pid, prov)
				end
			end
		end
		return borders
	end
	for pid, prov in ctx.WorldState.allProvinces() do
		if prov.ownerTag and aiSet[prov.ownerTag] then
			checkBorderProvince(borders, adj, prov.ownerTag, pid, prov)
		end
	end
	return borders
end

local function recruitAtBorders(tag, borderList, now)
	if not borderList or #borderList == 0 then return end
	if now - (lastRecruitAt[tag] or -math.huge) < RECRUIT_COOLDOWN then return end
	if defaultUnitId == nil then defaultUnitId = pickDefaultUnit() end
	if not defaultUnitId then return end
	local recruit = ctx.RecruitSystem and ctx.RecruitSystem.enqueue
	if not recruit then return end
	local queued = 0
	for _, pid in ipairs(borderList) do
		if queued >= RECRUIT_PER_TICK then break end
		if recruit(tag, pid, defaultUnitId, 1) then
			queued += 1
		end
	end
	if queued > 0 then
		lastRecruitAt[tag] = now
	end
end

local function redeployToBorders(tag, borderList)
	if not borderList or #borderList == 0 then return end
	if not (ctx.MovementSystem and ctx.MovementSystem.beginMovePath and ctx.ArmySystem) then return end
	local borderSet = {}
	for _, pid in ipairs(borderList) do
		borderSet[pid] = true
	end
	local moved = 0
	for _, army in ipairs(ctx.ArmySystem.armiesOfOwner(tag)) do
		if moved >= DEFENSE_MOVES_PER_TICK then break end
		if not army.movement and not army.battleId and not borderSet[army.provinceId] then
			-- Send it to the nearest border province (straight-line); beginMovePath does the routing.
			local best, bestD
			for _, pid in ipairs(borderList) do
				local d = ctx.AdjacencyGraph.distance(army.provinceId, pid)
				if d and (not bestD or d < bestD) then
					best, bestD = pid, d
				end
			end
			if best and ctx.MovementSystem.beginMovePath(army.id, best) then
				moved += 1
			end
		end
	end
end

local function runForTags(aiSet, now)
	if next(aiSet) == nil then return end
	local borders = collectBorders(aiSet)
	for tag in pairs(aiSet) do
		recruitAtBorders(tag, borders[tag], now)
		redeployToBorders(tag, borders[tag])
	end
end

local function tick()
	if not ctx.DiplomacySystem or not ctx.DiplomacySystem.areAtWar then return end
	local aiSet = activeWarAITags()
	runForTags(aiSet, ctx.TickScheduler.getSimTime())
end

-- React the instant war is declared so a player sees the AI mobilize without waiting a full tick, but
-- COALESCE the burst: one declaration fans out into several linked WarDeclared events (allies / guarantors
-- / subjects), and reacting synchronously to each re-ran a full border pass per event (the measured
-- call-to-arms stall). Accumulate the AI tags and run ONE pass via task.defer -- still the same frame, so
-- no perceptible mobilization delay, just one pass instead of N.
local pendingReactTags = nil
local function onWarDeclared(payload)
	if type(payload) ~= "table" then
		return
	end
	if not (isAI(payload.attackerTag) or isAI(payload.defenderTag)) then
		return
	end
	if not pendingReactTags then
		pendingReactTags = {}
		task.defer(function()
			local batch = pendingReactTags
			pendingReactTags = nil
			if batch and next(batch) then
				runForTags(batch, ctx.TickScheduler.getSimTime())
			end
		end)
	end
	if isAI(payload.attackerTag) then
		pendingReactTags[payload.attackerTag] = true
	end
	if isAI(payload.defenderTag) then
		pendingReactTags[payload.defenderTag] = true
	end
end

function AISystem.register(context)
	ctx = context
	context.AISystem = { tick = tick }

	if context.EventBus and context.EventBus.subscribe then
		context.EventBus.subscribe(context.Channels.WarDeclared, onWarDeclared)
	end

	context.TickScheduler.register({
		id = "AISystem",
		priority = 60,
		updateIntervalSeconds = AI_TICK_SECONDS,
		update = tick,
	})
end

return AISystem
