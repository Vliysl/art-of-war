local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TimeController = {}

local ALLOWED_SPEEDS = { 1, 2, 4, 8, 16 }
local DEFAULT_SPEED = 1

local ctx
local timeSync
local lastRequestAt = {}
local REQUEST_COOLDOWN = 0.1

local function buildPacket()
	local date = ctx.TickScheduler.getGameDate()
	return {
		year = date.year,
		month = date.month,
		day = date.day,
		speed = ctx.TickScheduler.getSpeed(),
		paused = ctx.TickScheduler.isPaused(),
		simTime = ctx.TickScheduler.getSimTime(),
	}
end

local function broadcast()
	if not timeSync then return end
	timeSync:FireAllClients(buildPacket())
end

local function isAllowedSpeed(value)
	value = tonumber(value)
	if not value then return false end
	for _, s in ipairs(ALLOWED_SPEEDS) do
		if s == value then return true end
	end
	return false
end

local function isClaimedPlayer(player)
	if not player then return false end
	if not ctx.PlayerAuthority or not ctx.PlayerAuthority.tagFor then return true end
	local tag = ctx.PlayerAuthority.tagFor(player)
	return tag ~= nil and tag ~= ""
end

local function rateLimit(player)
	local now = os.clock()
	local prev = lastRequestAt[player.UserId] or 0
	if now - prev < REQUEST_COOLDOWN then return false end
	lastRequestAt[player.UserId] = now
	return true
end

local function isAdminPlayer(player)
	if ctx and ctx.isAdminPlayer then return ctx.isAdminPlayer(player) end
	return true
end

local function handleRequest(player, payload)
	if not player or not isClaimedPlayer(player) then return end
	if not isAdminPlayer(player) then return end
	if type(payload) ~= "table" then return end
	if not rateLimit(player) then return end
	if payload.action == "pause" then
		ctx.TickScheduler.setPaused(true)
	elseif payload.action == "resume" then
		ctx.TickScheduler.setPaused(false)
	elseif payload.action == "togglePause" then
		ctx.TickScheduler.setPaused(not ctx.TickScheduler.isPaused())
	elseif payload.action == "setSpeed" then
		if isAllowedSpeed(payload.speed) then
			ctx.TickScheduler.setSpeed(payload.speed)
			ctx.TickScheduler.setPaused(false)
		end
	end
end

function TimeController.register(context)
	ctx = context
	ctx.TickScheduler.setSpeed(DEFAULT_SPEED)
	ctx.TickScheduler.setPaused(false)

	ctx.TickScheduler.onTimeControlChanged(function()
		broadcast()
		ctx.EventBus.publish(ctx.Channels.TimeControlChanged, buildPacket())
	end)

	ctx.EventBus.subscribe(ctx.Channels.DateAdvanced, function()
		broadcast()
	end)

	ctx.EventBus.subscribe(ctx.Channels.PlayerReady, function()
		task.delay(0.1, broadcast)
	end)

	game:GetService("Players").PlayerRemoving:Connect(function(player)
		lastRequestAt[player.UserId] = nil
	end)

	ctx.TimeController = {
		broadcast = broadcast,
		setSync = function(remote) timeSync = remote end,
		handleRequest = handleRequest,
		buildPacket = buildPacket,
		allowedSpeeds = ALLOWED_SPEEDS,
	}
end

return TimeController
