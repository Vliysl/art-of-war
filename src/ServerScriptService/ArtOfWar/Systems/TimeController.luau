local TimeController = {}

-- Engine rate multipliers (unchanged so sim balance / per-tier tick rates stay identical). The UI
-- relabels these as rate/4 -> 0.25x / 0.5x / 1x / 2x / 4x, so the default of 4 is shown as "1x" and
-- runs at the old "4x" pace -- i.e. 4x faster than the previous default of 1.
local ALLOWED_SPEEDS = { 1, 2, 4, 8, 16 }
local DEFAULT_SPEED = 4

local ctx
local timeSync
local lastRequestAt = {}
local REQUEST_COOLDOWN = 0.1

-- perf (clock fire-rate): the per-day DateAdvanced broadcast fires ~2.7x/sec at speed 4 and ~10x/sec at the
-- top speed; times every player that is ~135-535 FireAllClients/sec purely for the date HUD, on the sim
-- thread. Coalesce the DateAdvanced-driven broadcast to at most one per BROADCAST_MIN_INTERVAL, with a
-- trailing fire so the latest date always lands. SimClock extrapolates simTime between packets, so the
-- lower packet rate does NOT reduce clock / progress-bar accuracy. Speed/pause/join changes still broadcast
-- immediately via broadcast().
local BROADCAST_MIN_INTERVAL = 0.5
local lastBroadcastAt = 0
local pendingBroadcast = false

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

-- Immediate/authoritative broadcast -- used for speed/pause changes and joins, which must reflect at once.
local function broadcast()
	if not timeSync then return end
	lastBroadcastAt = os.clock()
	pendingBroadcast = false
	timeSync:FireAllClients(buildPacket())
end

-- Coalesced broadcast for the high-frequency per-day DateAdvanced tick: at most one fire per
-- BROADCAST_MIN_INTERVAL, with a single trailing fire scheduled so the latest date always lands.
local function broadcastThrottled()
	if not timeSync then return end
	local elapsed = os.clock() - lastBroadcastAt
	if elapsed >= BROADCAST_MIN_INTERVAL then
		broadcast()
	elseif not pendingBroadcast then
		pendingBroadcast = true
		task.delay(BROADCAST_MIN_INTERVAL - elapsed, function()
			if pendingBroadcast then
				broadcast()
			end
		end)
	end
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
		broadcastThrottled()
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
