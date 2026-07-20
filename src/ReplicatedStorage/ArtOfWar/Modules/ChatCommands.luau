local ChatCommands = {}

local TextChatService = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local MapModeController = require(aow:WaitForChild("Modules"):WaitForChild("MapModeController"))
local DebugMode = require(aow:WaitForChild("Modules"):WaitForChild("DebugMode"))
local MusicController = require(aow:WaitForChild("Modules"):WaitForChild("MusicController"))

local SYSTEM_CHANNEL = "RBXSystem"
local COMMANDS_FOLDER = "AoWChatCommands"

local function systemMessage(text)
	local channels = TextChatService:FindFirstChild("TextChannels")
	if not channels then return end
	local system = channels:FindFirstChild(SYSTEM_CHANNEL)
	if not system then return end
	pcall(function() system:DisplaySystemMessage(text) end)
end

local function describeMode(mode)
	if mode == "command" then return "Command Mode" end
	return "Field Mode"
end

local function ensureCommand(parent, primary, aliases, fn)
	local existing = parent:FindFirstChild(primary)
	if existing then existing:Destroy() end
	local cmd = Instance.new("TextChatCommand")
	cmd.Name = primary
	cmd.PrimaryAlias = "/" .. primary
	if aliases and aliases[1] then
		cmd.SecondaryAlias = "/" .. aliases[1]
	end
	cmd.AutocompleteVisible = true
	cmd.Enabled = true
	cmd.Parent = parent
	cmd.Triggered:Connect(function(_origin, text)
		local ok, err = pcall(fn, text)
		if not ok then
			warn("[ChatCommands] " .. primary .. " failed: " .. tostring(err))
		end
	end)
end

function ChatCommands.start()
	local folder = TextChatService:FindFirstChild(COMMANDS_FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = COMMANDS_FOLDER
		folder.Parent = TextChatService
	end

	ensureCommand(folder, "mode", nil, function()
		MapModeController.toggle()
	end)
	ensureCommand(folder, "field", nil, function()
		MapModeController.requestMode("field")
	end)
	ensureCommand(folder, "command", nil, function()
		MapModeController.requestMode("command")
	end)

	ensureCommand(folder, "debug", nil, function()
		if not DebugMode.isAdmin() then
			systemMessage("Debug mode is restricted to data-editor admins.")
			return
		end
		local now = DebugMode.toggle()
		systemMessage(string.format("Debug mode %s — country tags %s in tooltips and panels.",
			now and "enabled" or "disabled",
			now and "shown" or "hidden"))
	end)

	ensureCommand(folder, "music", nil, function(text)
		if not DebugMode.isAdmin() then
			systemMessage("Music audition is restricted to admins.")
			return
		end
		local args = {}
		for w in string.gmatch(tostring(text or ""), "%S+") do
			args[#args + 1] = w
		end
		local phase = args[2]
		if not phase or phase == "live" then
			MusicController.clearAudition()
			systemMessage("Music: resumed live resolution.")
			return
		end
		MusicController.previewPhase(phase, args[3])
		systemMessage(string.format("Music: forcing phase %q, region %q.", phase, args[3] or "default"))
	end)

	MapModeController.onChange(function(mode)
		systemMessage("Now in " .. describeMode(mode))
	end)
end

return ChatCommands
