local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UIBridge = {}

local remoteRoot
local commandEvent
local commandHandlers = {}

local function ensureRemotes()
	if remoteRoot then return end
	local root = ReplicatedStorage.ArtOfWar:FindFirstChild("Remotes")
	if not root then
		root = Instance.new("Folder")
		root.Name = "Remotes"
		root.Parent = ReplicatedStorage.ArtOfWar
	end
	remoteRoot = root

	local existing = root:FindFirstChild("Command")
	if existing then
		commandEvent = existing
	else
		commandEvent = Instance.new("RemoteEvent")
		commandEvent.Name = "Command"
		commandEvent.Parent = root
	end
end

function UIBridge.init()
	ensureRemotes()

	commandEvent.OnServerEvent:Connect(function(player, command, payload)
		if type(command) ~= "string" then return end
		local handler = commandHandlers[command]
		if handler then
			local ok, err = pcall(handler, player, payload)
			if not ok then
				warn(string.format("[UIBridge] command '%s' handler errored: %s", command, tostring(err)))
			end
		end
	end)
end

function UIBridge.registerCommand(command, handler)
	assert(type(command) == "string" and command ~= "", "UIBridge.registerCommand: command required")
	assert(type(handler) == "function", "UIBridge.registerCommand: handler required")
	commandHandlers[command] = handler
end

return UIBridge
