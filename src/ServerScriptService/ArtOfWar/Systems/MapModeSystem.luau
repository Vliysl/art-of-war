local MapModeSystem = {}

local Players = game:GetService("Players")

local ctx
local sync
local modes = {}

local function resolveMode(value)
	if value == "field" or value == "command" then return value end
	return nil
end

local function snapshot()
	local out = {}
	for userId, mode in modes do
		out[tostring(userId)] = mode
	end
	return out
end

local function broadcast(userId, mode)
	if not sync then return end
	sync:FireAllClients({
		kind = "single",
		userId = userId,
		mode = mode,
	})
end

local function sendFullTo(player)
	if not sync then return end
	sync:FireClient(player, {
		kind = "full",
		modes = snapshot(),
	})
end

function MapModeSystem.getMode(player)
	if not player then return nil end
	return modes[player.UserId]
end

function MapModeSystem.setMode(player, requested)
	local mode = resolveMode(requested)
	if not mode then return false end
	local previous = modes[player.UserId]
	if previous == mode then return true end
	modes[player.UserId] = mode
	broadcast(player.UserId, mode)
	if ctx and ctx.EventBus and ctx.Channels then
		ctx.EventBus.publish(ctx.Channels.PlayerMapModeChanged, {
			userId = player.UserId,
			mode = mode,
			previous = previous,
		})
	end
	return true
end

function MapModeSystem.setSync(remote)
	sync = remote
	if remote and not remote:GetAttribute("AoWHooked") then
		remote:SetAttribute("AoWHooked", true)
		remote.OnServerEvent:Connect(function(player, request)
			if request == "resync" then
				sendFullTo(player)
			end
		end)
	end
end

function MapModeSystem.handleJoin(player)
	local default = ctx and ctx.WorldConstants and ctx.WorldConstants.MapModeDefault or "field"
	modes[player.UserId] = default
	sendFullTo(player)
	broadcast(player.UserId, default)
end

function MapModeSystem.handleLeave(player)
	local userId = player.UserId
	if modes[userId] == nil then return end
	modes[userId] = nil
	if not sync then return end
	sync:FireAllClients({
		kind = "single",
		userId = userId,
		mode = nil,
	})
end

function MapModeSystem.register(context)
	ctx = context
	context.MapModeSystem = MapModeSystem

	Players.PlayerAdded:Connect(function(player)
		MapModeSystem.handleJoin(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		MapModeSystem.handleLeave(player)
	end)
	for _, existing in Players:GetPlayers() do
		MapModeSystem.handleJoin(existing)
	end
end

return MapModeSystem
