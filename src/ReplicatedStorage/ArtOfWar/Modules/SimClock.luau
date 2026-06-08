-- Client-side estimate of the server's simulation clock. The server stamps every
-- TimeSync packet with its current simTime; this module anchors to that reading and
-- extrapolates between packets using the broadcast speed (frozen while paused), so
-- progress bars keyed on sim-time fields (recruitTicket.queuedAt / .completesAt) read
-- correctly at any game speed and survive the panel being reopened mid-build.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SimClock = {}

local anchorSim = 0
local anchorClock = os.clock()
local speed = 1
local paused = false
local hasAnchor = false
local conn

function SimClock.apply(packet)
	if type(packet) ~= "table" then return end
	speed = tonumber(packet.speed) or speed
	paused = packet.paused == true
	if type(packet.simTime) == "number" then
		anchorSim = packet.simTime
		anchorClock = os.clock()
		hasAnchor = true
	end
end

function SimClock.now()
	if not hasAnchor then return nil end
	if paused then return anchorSim end
	return anchorSim + (os.clock() - anchorClock) * speed
end

function SimClock.hasReading()
	return hasAnchor
end

function SimClock.getSpeed()
	return speed
end

function SimClock.isPaused()
	return paused
end

function SimClock.start()
	if conn then return end
	local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
	local remotes = aow:WaitForChild("Remotes")
	local timeSync = remotes:WaitForChild("TimeSync", 30)
	if not timeSync then return end
	conn = timeSync.OnClientEvent:Connect(SimClock.apply)
end

function SimClock.stop()
	if conn then conn:Disconnect(); conn = nil end
end

return SimClock