local SprintController = {}

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local CharacterHandler = require(aow:WaitForChild("Modules"):WaitForChild("CharacterHandler"))
local Players = game:GetService("Players")
local Platform = require(aow.Modules:WaitForChild("Platform"))
local Button = require(aow:WaitForChild("UI"):WaitForChild("Components"):WaitForChild("Button"))

local connections = {}
local eligible = true
local sprintGui = nil
local sprintBtn = nil
local sprintOn = false

local function isSprintKey(code)
	return code == Enum.KeyCode.LeftShift or code == Enum.KeyCode.RightShift
end

-- Touch sprint is a TOGGLE (there's no key to hold). The button exists only on touch and only while
-- sprint is eligible (field mode); Shift still works on desktop.
local function setSprintLabel()
	if sprintBtn then
		local lbl = sprintBtn:FindFirstChild("Label")
		if lbl then
			lbl.Text = sprintOn and "Sprinting" or "Sprint"
		end
	end
end

local function ensureSprintGui()
	if sprintGui or not Platform.isTouch then
		return
	end
	local lp = Players.LocalPlayer
	local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end
	sprintGui = Instance.new("ScreenGui")
	sprintGui.Name = "AoW_SprintControl"
	sprintGui.ResetOnSpawn = false
	sprintGui.DisplayOrder = 15
	sprintGui.Enabled = false
	sprintGui.Parent = pg
	sprintBtn = Button.create({
		parent = sprintGui,
		variant = "secondary",
		text = "Sprint",
		onClick = function()
			sprintOn = not sprintOn
			CharacterHandler.setSprint(sprintOn)
			setSprintLabel()
		end,
	})
	sprintBtn.Name = "TouchSprint"
	sprintBtn.AnchorPoint = Vector2.new(1, 1)
	sprintBtn.Position = UDim2.new(1, -16, 1, -120)
	sprintBtn:SetAttribute("AoWInputSink", true)
end

function SprintController.setEligible(flag)
	eligible = flag and true or false
	if not eligible then
		CharacterHandler.setSprint(false)
		sprintOn = false
		setSprintLabel()
		if sprintGui then
			sprintGui.Enabled = false
		end
		return
	end
	ensureSprintGui()
	if sprintGui then
		sprintGui.Enabled = true
	end
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