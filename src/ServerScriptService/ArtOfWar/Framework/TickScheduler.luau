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
	for _, descriptor in sortedSystems do
		descriptor.accumulator += effectiveDelta
		if descriptor.accumulator >= descriptor.updateIntervalSeconds then
			local stepDelta = descriptor.accumulator
			descriptor.accumulator = 0
			local systemCtx = {
				simTime = ctx.simTime,
				deltaSeconds = stepDelta,
				gameDate = ctx.gameDate,
				scenarioProgress = ctx.scenarioProgress,
			}
			local ok, err = pcall(descriptor.update, systemCtx)
			if not ok then
				warn(string.format("[TickScheduler] system '%s' errored: %s", descriptor.id, tostring(err)))
			end
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

return TickScheduler
