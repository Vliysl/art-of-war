local CharacterHandler = {}

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local WorldConstants = require(ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Shared"):WaitForChild("WorldConstants"))

local currentMode = WorldConstants.MapModeDefault
local bodyConnection = nil
local sprintActive = false
local lastFieldPosition = nil

-- Field-mode toroidal X-wrap. The world is periodic in X (period MapWidth): the camera
-- (CameraController.wrapX) and the map visuals (LeftWrap/RightWrap, cloned at +/-MapWidth) already wrap,
-- but the walking character did not -- crossing a seam ran it off the FieldFloor into the cosmetic water.
-- Mirror the camera's wrap on the HumanoidRootPart so it teleports cleanly to the matching point on the
-- opposite edge. The client owns its own character, so the move replicates to the server and other players.
local WRAP_WIDTH = WorldConstants.MapWidth
local WRAP_HALF = WorldConstants.MapHalfWidth
local WRAP_CENTER_X = WorldConstants.MapCenterX
local seamWrapConnection = nil

local function wrapFieldCharacter()
	if currentMode ~= "field" then return end
	local player = Players.LocalPlayer
	local char = player and player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	local rel = hrp.Position.X - WRAP_CENTER_X
	if rel >= WRAP_HALF or rel < -WRAP_HALF then
		-- Shift the HRP by a whole number of map widths so X folds back into [-half, half) -- matching
		-- CameraController.wrapX and the LeftWrap/RightWrap clones (offset by +/-MapWidth). The shift is an
		-- EXACT integer multiple of MapWidth, so Y/Z, facing and velocity carry over and the destination
		-- terrain is identical to the source. floor() (not a single +/-width) resolves a multi-width
		-- lag-spike overshoot in one step.
		local widths = math.floor((rel + WRAP_HALF) / WRAP_WIDTH)
		hrp.CFrame = hrp.CFrame - Vector3.new(widths * WRAP_WIDTH, 0, 0)
	end
end

local function defaultSpawnCFrame()
	return CFrame.new(WorldConstants.MapCenterX, WorldConstants.FieldSpawnHeight, WorldConstants.MapCenterZ)
end

local function resumeSpawnCFrame()
	if lastFieldPosition then
		return CFrame.new(lastFieldPosition.X, WorldConstants.FieldSpawnHeight, lastFieldPosition.Z)
	end
	return defaultSpawnCFrame()
end

local function captureFieldPosition()
	local player = Players.LocalPlayer
	local char = player and player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp then
		lastFieldPosition = hrp.Position
	end
end

local function forEachBodyPart(char, fn)
	for _, d in char:GetDescendants() do
		if d:IsA("BasePart") then fn(d) end
	end
end

local function currentWalkSpeed()
	if sprintActive then return WorldConstants.FieldSprintSpeed end
	return WorldConstants.FieldWalkSpeed
end

local function applyFieldPresentation(char)
	local hum = char:FindFirstChildWhichIsA("Humanoid")
	if hum then
		pcall(function() hum.UseJumpPower = false end)
		hum.WalkSpeed = currentWalkSpeed()
		hum.JumpHeight = WorldConstants.FieldJumpHeight
		hum.AutoRotate = true
		hum.HealthDisplayDistance = 0
		hum.NameDisplayDistance = 100
		hum:SetStateEnabled(Enum.HumanoidStateType.Swimming, false) -- ocean is cosmetic terrain water; never swim (FieldFloor sits above the surface)
	end
	forEachBodyPart(char, function(p)
		p.Transparency = p:GetAttribute("AoWBaseTransparency") or p.Transparency
		p.Massless = false
		p.CanCollide = (p.Name == "HumanoidRootPart") and false or true
		p.CanQuery = false
	end)
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if hrp then
		hrp.Anchored = false
		hrp.CFrame = resumeSpawnCFrame()
	end
end

local function applyCommandPresentation(char)
	local hum = char:FindFirstChildWhichIsA("Humanoid")
	if hum then
		hum.WalkSpeed = 0
		hum.JumpHeight = 0
		hum.AutoRotate = false
		hum.HealthDisplayDistance = 0
		hum.NameDisplayDistance = 0
	end
	forEachBodyPart(char, function(p)
		p.Transparency = 1
		p.CanCollide = false
		p.CanQuery = false
		p.Massless = true
	end)
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if hrp then
		hrp.Anchored = true
		hrp.CFrame = CFrame.new(0, WorldConstants.CommandPerchHeight, 0)
	end
end

local function captureBaseTransparencies(char)
	forEachBodyPart(char, function(p)
		if p:GetAttribute("AoWBaseTransparency") == nil then
			p:SetAttribute("AoWBaseTransparency", p.Transparency)
		end
	end)
end

local function applyMode(char, mode)
	if not char or not char.Parent then return end
	if mode == "command" then
		applyCommandPresentation(char)
	else
		applyFieldPresentation(char)
	end
end

local function hookCharacter(char)
	captureBaseTransparencies(char)
	applyMode(char, currentMode)
	if bodyConnection then bodyConnection:Disconnect() end
	bodyConnection = char.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			if d:GetAttribute("AoWBaseTransparency") == nil then
				d:SetAttribute("AoWBaseTransparency", d.Transparency)
			end
			if currentMode == "command" then
				d.Transparency = 1
				d.CanCollide = false
				d.CanQuery = false
				d.Massless = true
			else
				d.CanQuery = false
			end
		end
	end)
end

function CharacterHandler.setMode(mode)
	if mode ~= "field" and mode ~= "command" then return end
	if currentMode == "field" and mode == "command" then
		captureFieldPosition()
	end
	currentMode = mode
	local player = Players.LocalPlayer
	if player and player.Character then
		applyMode(player.Character, mode)
	end
end

function CharacterHandler.getLastFieldPosition()
	return lastFieldPosition
end

function CharacterHandler.setSprint(active)
	sprintActive = active and true or false
	if currentMode ~= "field" then return end
	local player = Players.LocalPlayer
	local char = player and player.Character
	local hum = char and char:FindFirstChildWhichIsA("Humanoid")
	if hum then hum.WalkSpeed = currentWalkSpeed() end
end

function CharacterHandler.currentMode()
	return currentMode
end

function CharacterHandler.isSprinting()
	return sprintActive
end

function CharacterHandler.start()
	local player = Players.LocalPlayer

	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
	end)

	if player.Character then hookCharacter(player.Character) end
	player.CharacterAdded:Connect(hookCharacter)

	-- Wrap the field-mode character across the X seam each frame, after physics has moved it (no-op in
	-- command mode / when no character).
	if seamWrapConnection then seamWrapConnection:Disconnect() end
	seamWrapConnection = RunService.Heartbeat:Connect(wrapFieldCharacter)
end

return CharacterHandler
