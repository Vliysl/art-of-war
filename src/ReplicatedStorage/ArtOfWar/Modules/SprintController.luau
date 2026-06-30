local SprintController = {}

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local CharacterHandler = require(aow:WaitForChild("Modules"):WaitForChild("CharacterHandler"))
local Platform = require(aow.Modules:WaitForChild("Platform"))

local connections = {}
local eligible = true

-- Touch auto-sprint: the on-screen thumbstick has no "run" key, so we sprint when it's pushed past
-- SPRINT_DEFLECTION. ControlModule:GetMoveVector()'s magnitude tracks thumbstick deflection -- ~0..1 for
-- the default DynamicThumbstick (clamped), and larger for the classic stick, so a fractional threshold
-- still trips once it's pushed far. Desktop keeps hold-Shift.
local SPRINT_DEFLECTION = 0.85
local controls = nil
local lastAutoSprint = false

local function isSprintKey(code)
	return code == Enum.KeyCode.LeftShift or code == Enum.KeyCode.RightShift
end

local function getControls()
	if controls then
		return controls
	end
	local lp = Players.LocalPlayer
	local ps = lp and lp:FindFirstChild("PlayerScripts")
	local pm = ps and ps:FindFirstChild("PlayerModule")
	if not pm then
		return nil
	end
	local ok, mod = pcall(require, pm)
	if not ok then
		return nil
	end
	local ok2, c = pcall(function()
		return mod:GetControls()
	end)
	if ok2 then
		controls = c
	end
	return controls
end

-- Lift the default mobile jump button above the country bar (it sits bottom-right by default, where the
-- bar covers it). Re-applied on respawn + viewport change because the engine re-lays-out its touch UI.
local function placeJumpButton()
	task.spawn(function()
		local lp = Players.LocalPlayer
		local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
		if not pg then
			return
		end
		local touchGui = pg:WaitForChild("TouchGui", 10)
		local frame = touchGui and touchGui:WaitForChild("TouchControlFrame", 5)
		local jump = frame and frame:WaitForChild("JumpButton", 5)
		if jump then
			jump.AnchorPoint = Vector2.new(1, 1)
			jump.Position = UDim2.new(1, -24, 1, -104)
		end
	end)
end

function SprintController.setEligible(flag)
	eligible = flag and true or false
	if not eligible then
		CharacterHandler.setSprint(false)
		lastAutoSprint = false
	end
end

function SprintController.start()
	-- Desktop sprint: hold Shift.
	connections[#connections + 1] = UserInputService.InputBegan:Connect(function(input)
		if not isSprintKey(input.KeyCode) then
			return
		end
		if not eligible then
			return
		end
		if UserInputService:GetFocusedTextBox() then
			return
		end
		CharacterHandler.setSprint(true)
	end)
	connections[#connections + 1] = UserInputService.InputEnded:Connect(function(input)
		if isSprintKey(input.KeyCode) then
			CharacterHandler.setSprint(false)
		end
	end)

	if Platform.isTouch then
		-- Touch auto-sprint from thumbstick deflection (only while in field mode / eligible).
		connections[#connections + 1] = RunService.Heartbeat:Connect(function()
			if not eligible then
				return
			end
			local c = getControls()
			if not c then
				return
			end
			local ok, mv = pcall(function()
				return c:GetMoveVector()
			end)
			if not ok or typeof(mv) ~= "Vector3" then
				return
			end
			local want = mv.Magnitude >= SPRINT_DEFLECTION
			if want ~= lastAutoSprint then
				lastAutoSprint = want
				CharacterHandler.setSprint(want)
			end
		end)

		placeJumpButton()
		if Players.LocalPlayer then
			connections[#connections + 1] = Players.LocalPlayer.CharacterAdded:Connect(placeJumpButton)
		end
		local cam = workspace.CurrentCamera
		if cam then
			connections[#connections + 1] = cam:GetPropertyChangedSignal("ViewportSize"):Connect(placeJumpButton)
		end
	end
end

function SprintController.destroy()
	for _, c in connections do
		c:Disconnect()
	end
	connections = {}
	CharacterHandler.setSprint(false)
end

return SprintController
