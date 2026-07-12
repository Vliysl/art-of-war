local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("ArtOfWar"):WaitForChild("Shared")
local WorldConstants = require(Shared:WaitForChild("WorldConstants"))
local Events = require(game:GetService("ServerScriptService").ArtOfWar.Events.Channels)

local EventBus = require(script.Parent.EventBus)

local TickScheduler = {}

local systems = {}
local sortedSystems = {}
local sortedDirty = false
local running = false
local heartbeatConnection
local simStartClock = 0
local simTime = 0
local gameYear = WorldConstants.ScenarioStartYear
local gameMonth = WorldConstants.ScenarioStartMonth
local gameDay = WorldConstants.ScenarioStartDay
local dayAccumulator = 0
local lastTickClock = 0
local speedMultiplier = 1
local paused = false
local speedListeners = {}

local DaysInMonth = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

-- perf (herd fix, part 2): seconds between consecutive interval-groups' initial phase offsets. See start().
local PHASE_STEP = 0.37

-- dev profiling (off by default; toggled via TickScheduler.setProfile). Times each system + the whole step,
-- keeps the worst step-frame's per-system breakdown, and tracks the worst UNCLAMPED Heartbeat frame time.
-- Comparing maxFrameMs (whole frame) vs maxStepMs (sim only) localizes a stall to INSIDE vs OUTSIDE the tick
-- (GC / render / physics / autosave). The debug.profilebegin tags in step() are unconditional + near-free.
local function ms2(x)
	return math.floor(x * 100 + 0.5) / 100
end
local profileEnabled = false
local profileAccum = {} -- id -> { totalMs, calls }
local profileWorstStep = nil -- { totalMs, unaccountedMs, systems = { {id, ms}, ... } }
local profileFrames = 0
local profileMaxStepMs = 0
local profileMaxFrameMs = 0

local function isLeapYear(year)
	if year % 4 ~= 0 then
		return false
	end
	if year % 100 ~= 0 then
		return true
	end
	return year % 400 == 0
end

local function daysInMonth(year, month)
	if month == 2 and isLeapYear(year) then
		return 29
	end
	return DaysInMonth[month]
end

local function currentDaysPerTick()
	if gameYear <= WorldConstants.EarlyEraCutoffYear then
		return WorldConstants.DaysPerEarlyTick
	end
	return WorldConstants.DaysPerLateTick
end

local function advanceDate(days)
	local startMonth, startYear = gameMonth, gameYear
	gameDay += days
	while true do
		local monthLen = daysInMonth(gameYear, gameMonth)
		if gameDay <= monthLen then
			break
		end
		gameDay -= monthLen
		gameMonth += 1
		if gameMonth > 12 then
			gameMonth = 1
			gameYear += 1
		end
	end
	-- economy rework: signal to callers whether a new month (or year) began this advance
	return gameMonth ~= startMonth or gameYear ~= startYear
end

local function scenarioProgress()
	local spanYears = WorldConstants.ScenarioEndYear - WorldConstants.ScenarioStartYear
	local elapsedYears = (gameYear - WorldConstants.ScenarioStartYear) + ((gameMonth - 1) / 12) + ((gameDay - 1) / 365)
	return math.clamp(elapsedYears / spanYears, 0, 1)
end

local function rebuildSorted()
	table.clear(sortedSystems)
	for _, descriptor in systems do
		table.insert(sortedSystems, descriptor)
	end
	table.sort(sortedSystems, function(a, b)
		if a.priority == b.priority then
			return a.id < b.id
		end
		return a.priority < b.priority
	end)
	sortedDirty = false
end

function TickScheduler.register(descriptor)
	assert(type(descriptor) == "table", "TickScheduler.register: descriptor must be table")
	assert(type(descriptor.id) == "string" and descriptor.id ~= "", "TickScheduler.register: id required")
	assert(type(descriptor.update) == "function", "TickScheduler.register: update must be function")
	assert(not systems[descriptor.id], "TickScheduler.register: duplicate id " .. descriptor.id)

	systems[descriptor.id] = {
		id = descriptor.id,
		priority = descriptor.priority or 100,
		updateIntervalSeconds = math.max(descriptor.updateIntervalSeconds or WorldConstants.SecondsPerSimTick, 1 / 60),
		update = descriptor.update,
		start = descriptor.start,
		accumulator = 0,
	}
	sortedDirty = true
end

function TickScheduler.unregister(systemId)
	systems[systemId] = nil
	sortedDirty = true
end

function TickScheduler.getGameDate()
	return { year = gameYear, month = gameMonth, day = gameDay }
end

function TickScheduler.getSimTime()
	return simTime
end

function TickScheduler.setDate(year, month, day)
	gameYear = year
	gameMonth = month
	gameDay = day
end

function TickScheduler.setSpeed(multiplier)
	multiplier = tonumber(multiplier) or 1
	if multiplier < 0 then
		multiplier = 0
	end
	if multiplier > 32 then
		multiplier = 32
	end
	speedMultiplier = multiplier
	for _, cb in ipairs(speedListeners) do
		local ok, err = pcall(cb, speedMultiplier, paused)
		if not ok then
			warn("[TickScheduler] speed listener errored: " .. tostring(err))
		end
	end
end

function TickScheduler.setPaused(flag)
	paused = flag and true or false
	for _, cb in ipairs(speedListeners) do
		local ok, err = pcall(cb, speedMultiplier, paused)
		if not ok then
			warn("[TickScheduler] pause listener errored: " .. tostring(err))
		end
	end
end

function TickScheduler.getSpeed()
	return speedMultiplier
end

function TickScheduler.isPaused()
	return paused
end

function TickScheduler.onTimeControlChanged(callback)
	if type(callback) ~= "function" then
		return function() end
	end
	table.insert(speedListeners, callback)
	return function()
		for i, cb in ipairs(speedListeners) do
			if cb == callback then
				table.remove(speedListeners, i)
				return
			end
		end
	end
end

local function step(deltaSeconds)
	local effectiveDelta = paused and 0 or deltaSeconds * speedMultiplier
	if effectiveDelta <= 0 then
		return
	end

	simTime += effectiveDelta

	dayAccumulator += effectiveDelta / WorldConstants.SecondsPerSimTick
	local daysToAdvance = 0
	local daysPerTick = currentDaysPerTick()
	while dayAccumulator >= 1 do
		dayAccumulator -= 1
		daysToAdvance += daysPerTick
	end
	if daysToAdvance > 0 then
		local monthChanged = advanceDate(daysToAdvance)
		EventBus.publish(Events.DateAdvanced, {
			date = TickScheduler.getGameDate(),
			daysAdvanced = daysToAdvance,
		})
		-- economy rework: monthly income/resource commit hangs off this (see EconomySystem.applyMonthlyPayout).
		-- daysInMonth is the fixed accounting month (DaysPerMonth) so payout matches the /mo projection.
		if monthChanged then
			EventBus.publish(Events.MonthBoundaryReached, {
				date = TickScheduler.getGameDate(),
				daysInMonth = WorldConstants.DaysPerMonth or 30,
			})
		end
	end

	local ctx = {
		simTime = simTime,
		deltaSeconds = effectiveDelta,
		gameDate = TickScheduler.getGameDate(),
		scenarioProgress = scenarioProgress(),
	}

	EventBus.publish(Events.TickStarted, ctx)

	if sortedDirty then
		rebuildSorted()
	end
	local profiling = profileEnabled
	local stepStart = profiling and os.clock() or 0
	local frameBreak = profiling and {} or nil
	local frameSum = 0
	for _, descriptor in sortedSystems do
		descriptor.accumulator += effectiveDelta
		if descriptor.accumulator >= descriptor.updateIntervalSeconds then
			local stepDelta = descriptor.accumulator
			-- perf (herd fix, part 1 of 2 -- the enabler): keep the overshoot instead of resetting the
			-- accumulator to 0 on every fire. Resetting to 0 ERASES a system's phase, which would collapse
			-- the P1 group-stagger (per-group initial offsets) back into lockstep on the very first fire.
			-- Subtracting the interval PRESERVES each system's phase so that stagger persists. On its own
			-- this does not yet spread the herd -- every system currently seeds at accumulator=0 and gets
			-- the same delta, so same-interval systems still cross together -- but it is the safe
			-- precondition for the P1 initial-offset seeding, and it makes catch-up after a hitch exact
			-- (no dropped time). Clamp the carry to [0, interval] so a long hitch can only trigger a single
			-- catch-up fire next frame (step() fires each system at most once per frame -- no spiral).
			descriptor.accumulator = math.clamp(
				descriptor.accumulator - descriptor.updateIntervalSeconds,
				0,
				descriptor.updateIntervalSeconds
			)
			local systemCtx = {
				simTime = ctx.simTime,
				deltaSeconds = stepDelta,
				gameDate = ctx.gameDate,
				scenarioProgress = ctx.scenarioProgress,
			}
			debug.profilebegin(descriptor.id)
			local sysStart = profiling and os.clock() or 0
			local ok, err = pcall(descriptor.update, systemCtx)
			if profiling then
				local sysMs = (os.clock() - sysStart) * 1000
				frameSum += sysMs
				frameBreak[#frameBreak + 1] = { id = descriptor.id, ms = sysMs }
				local a = profileAccum[descriptor.id]
				if not a then
					a = { totalMs = 0, calls = 0 }
					profileAccum[descriptor.id] = a
				end
				a.totalMs += sysMs
				a.calls += 1
			end
			debug.profileend()
			if not ok then
				warn(string.format("[TickScheduler] system '%s' errored: %s", descriptor.id, tostring(err)))
			end
		end
	end

	if profiling then
		profileFrames += 1
		local stepMs = (os.clock() - stepStart) * 1000
		if stepMs > profileMaxStepMs then
			profileMaxStepMs = stepMs
		end
		if not profileWorstStep or stepMs > profileWorstStep.totalMs then
			table.sort(frameBreak, function(a, b)
				return a.ms > b.ms
			end)
			local top = {}
			for i = 1, math.min(6, #frameBreak) do
				top[i] = { id = frameBreak[i].id, ms = ms2(frameBreak[i].ms) }
			end
			profileWorstStep = { totalMs = ms2(stepMs), unaccountedMs = ms2(stepMs - frameSum), systems = top }
		end
	end

	EventBus.publish(Events.TickCompleted, ctx)
end

function TickScheduler.start()
	if running then
		return
	end
	running = true
	simStartClock = os.clock()
	lastTickClock = simStartClock
	if sortedDirty then
		rebuildSorted()
	end
	-- perf (herd fix, part 2 of 2): phase-stagger interval-GROUPS so different-cadence groups fire on
	-- different Heartbeats instead of all crossing their threshold on the same frame. Systems that share an
	-- interval get the SAME offset -- they stay together, in priority order, so intra-group producer->
	-- consumer ordering (Combat->AutoCapture->Siege, all interval 3) is preserved; only which FRAME a group
	-- first fires on changes. The P0 overshoot (accumulator -= interval) makes the offset PERSIST instead of
	-- collapsing back to lockstep on the first fire. Opt out with WorldConstants.TickPhaseStagger = false.
	if WorldConstants.TickPhaseStagger ~= false then
		local groupOffset = {}
		local groupCount = 0
		for _, descriptor in sortedSystems do
			local iv = descriptor.updateIntervalSeconds
			local off = groupOffset[iv]
			if off == nil then
				-- deterministic spread (no RNG): consecutive interval-groups start PHASE_STEP apart, wrapped
				-- into [0, interval) -- enough to break the alignment that clumped every group onto one frame.
				off = (groupCount * PHASE_STEP) % iv
				groupOffset[iv] = off
				groupCount += 1
			end
			descriptor.accumulator = off
		end
	end
	for _, descriptor in sortedSystems do
		if descriptor.start then
			local ok, err = pcall(descriptor.start)
			if not ok then
				warn(string.format("[TickScheduler] system '%s' start errored: %s", descriptor.id, tostring(err)))
			end
		end
	end
	heartbeatConnection = RunService.Heartbeat:Connect(function()
		local now = os.clock()
		local delta = now - lastTickClock
		lastTickClock = now
		if profileEnabled then
			local frameMs = delta * 1000
			if frameMs > profileMaxFrameMs then
				profileMaxFrameMs = frameMs
			end
		end
		if delta > 0.25 then
			delta = 0.25
		end
		step(delta)
	end)
end

function TickScheduler.stop()
	if not running then
		return
	end
	running = false
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
end

function TickScheduler.setProfile(on)
	profileEnabled = on and true or false
end

function TickScheduler.resetProfile()
	table.clear(profileAccum)
	profileWorstStep = nil
	profileFrames = 0
	profileMaxStepMs = 0
	profileMaxFrameMs = 0
end

-- Attribution snapshot: per-system accumulated self-time (steady-state cost, heaviest first), the worst
-- single step frame's breakdown, and the worst whole-frame time. maxFrameMs >> maxStepMs => the stall is
-- OUTSIDE the sim tick (GC / render / physics / autosave); else worstStep.systems names the owner.
function TickScheduler.getProfile()
	local accum = {}
	for id, a in profileAccum do
		accum[#accum + 1] =
			{ id = id, totalMs = ms2(a.totalMs), calls = a.calls, avgMs = ms2(a.totalMs / math.max(1, a.calls)) }
	end
	table.sort(accum, function(a, b)
		return a.totalMs > b.totalMs
	end)
	return {
		enabled = profileEnabled,
		frames = profileFrames,
		maxStepMs = ms2(profileMaxStepMs),
		maxFrameMs = ms2(profileMaxFrameMs),
		worstStep = profileWorstStep,
		accum = accum,
	}
end

return TickScheduler
