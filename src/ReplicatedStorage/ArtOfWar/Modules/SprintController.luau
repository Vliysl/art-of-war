local SprintController = {}

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CharacterHandler = require(ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Modules"):WaitForChild("CharacterHandler"))

local connections = {}
local eligible = true

local function isSprintKey(code)
	return code == Enum.KeyCode.LeftShift or code == Enum.KeyCode.RightShift
end

function SprintController.setEligible(flag)
	eligible = flag and true or false
	if not eligible then CharacterHandler.setSprint(false) end
end

function SprintController.start()
	connections[#connections + 1] = UserInputService.InputBegan:Connect(function(input)
		if not isSprintKey(input.KeyCode) then return end
		if not eligible then return end
		if UserInputService:GetFocusedTextBox() then return end
		CharacterHandler.setSprint(true)
	end)
	connections[#connections + 1] = UserInputService.InputEnded:Connect(function(input)
		if isSprintKey(input.KeyCode) then
			CharacterHandler.setSprint(false)
		end
	end)
end

function SprintController.destroy()
	for _, c in connections do c:Disconnect() end
	connections = {}
	CharacterHandler.setSprint(false)
end

return SprintController