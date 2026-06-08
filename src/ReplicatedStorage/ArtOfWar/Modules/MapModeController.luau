local MapModeController = {}

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local modules = aow:WaitForChild("Modules")

local CameraController = require(modules:WaitForChild("CameraController"))
local CharacterHandler = require(modules:WaitForChild("CharacterHandler"))
local PeerVisibility = require(modules:WaitForChild("PeerVisibility"))
local SprintController = require(modules:WaitForChild("SprintController"))
local MapWrapVisibility = require(modules:WaitForChild("MapWrapVisibility"))
local WorldConstants = require(ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Shared"):WaitForChild("WorldConstants"))

local FIELD_MAX_ZOOM = 600
local FIELD_MIN_ZOOM = 30

local localPlayer = Players.LocalPlayer
local currentMode = WorldConstants.MapModeDefault
local setMapMode = nil
local listeners = {}

local function applyInputSettings(mode)
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	if not localPlayer then return end
	if mode == "field" then
		localPlayer.CameraMode = Enum.CameraMode.Classic
		localPlayer.CameraMaxZoomDistance = FIELD_MAX_ZOOM
		localPlayer.CameraMinZoomDistance = FIELD_MIN_ZOOM
	end
end

local function capturePlannedCameraTarget()
	local char = localPlayer and localPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp then return hrp.Position end
	return nil
end

local function applyLocalMode(mode)
	if mode ~= "field" and mode ~= "command" then return end
	local enteringCommand = mode == "command" and currentMode ~= "command"
	local plannedTarget = enteringCommand and capturePlannedCameraTarget() or nil
	currentMode = mode
	CharacterHandler.setMode(mode)
	MapWrapVisibility.setMode(mode)
	if mode == "command" then
		CameraController.enable()
		if plannedTarget then
			CameraController.snapTo(plannedTarget, nil)
		end
		SprintController.setEligible(false)
	else
		CameraController.disable()
		SprintController.setEligible(true)
	end
	applyInputSettings(mode)
	PeerVisibility.setLocalMode(mode)
	for _, cb in listeners do
		local ok, err = pcall(cb, mode)
		if not ok then warn("[MapModeController] listener errored: " .. tostring(err)) end
	end
end

function MapModeController.requestMode(mode)
	if not setMapMode then return end
	if mode ~= "field" and mode ~= "command" then return end
	setMapMode:FireServer(mode)
end

function MapModeController.toggle()
	local target = currentMode == "field" and "command" or "field"
	MapModeController.requestMode(target)
end

function MapModeController.current()
	return currentMode
end

function MapModeController.onChange(callback)
	if type(callback) ~= "function" then return function() end end
	table.insert(listeners, callback)
	return function()
		for i, cb in listeners do
			if cb == callback then
				table.remove(listeners, i)
				return
			end
		end
	end
end

local function handlePacket(packet)
	if type(packet) ~= "table" then return end
	if packet.kind == "full" and type(packet.modes) == "table" then
		PeerVisibility.applyFull(packet.modes)
		local myId = tostring(localPlayer.UserId)
		local mine = packet.modes[myId]
		if mine then applyLocalMode(mine) end
		return
	end
	if packet.kind == "single" then
		local userId = packet.userId
		local mode = packet.mode
		if userId == localPlayer.UserId then
			if mode then applyLocalMode(mode) end
			return
		end
		PeerVisibility.setPeerMode(userId, mode)
	end
end

function MapModeController.start()
	local remotes = aow:WaitForChild("Remotes", 30)
	if not remotes then
		warn("[MapModeController] remotes missing")
		return
	end
	setMapMode = remotes:WaitForChild("SetMapMode", 10)
	local sync = remotes:WaitForChild("MapModeSync", 10)
	PeerVisibility.start()
	applyLocalMode(WorldConstants.MapModeDefault)
	if sync then
		sync.OnClientEvent:Connect(handlePacket)
		task.defer(function()
			sync:FireServer("resync")
		end)
	end
end

return MapModeController
