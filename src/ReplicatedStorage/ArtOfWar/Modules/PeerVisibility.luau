local PeerVisibility = {}

local Players = game:GetService("Players")

local localPlayer = Players.LocalPlayer
local localMode = "field"
local peerModes = {}
local connections = {}
local descendantHooks = {}

local function forEachLimb(char, fn)
	for _, d in char:GetDescendants() do
		if d:IsA("BasePart") then fn(d) end
	end
end

local function applyVisibility(char, hidden)
	if not char or not char.Parent then return end
	local hum = char:FindFirstChildWhichIsA("Humanoid")
	if hum then
		hum.NameDisplayDistance = hidden and 0 or 100
		hum.HealthDisplayDistance = 0
	end
	forEachLimb(char, function(p)
		p.LocalTransparencyModifier = hidden and 1 or 0
		p.CanQuery = false
	end)
end

local function shouldHide(player)
	if player == localPlayer then return false end
	local peerMode = peerModes[player.UserId] or "field"
	return peerMode ~= localMode
end

local function hookCharacter(player, char)
	local hidden = shouldHide(player)
	applyVisibility(char, hidden)
	local existing = descendantHooks[player.UserId]
	if existing then existing:Disconnect() end
	descendantHooks[player.UserId] = char.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = shouldHide(player) and 1 or 0
			d.CanQuery = false
		end
	end)
end

local function refreshPlayer(player)
	if player == localPlayer then return end
	local char = player.Character
	if char then
		applyVisibility(char, shouldHide(player))
	end
end

local function refreshAll()
	for _, p in Players:GetPlayers() do
		refreshPlayer(p)
	end
end

local function bindPlayer(player)
	if player == localPlayer then return end
	if player.Character then hookCharacter(player, player.Character) end
	connections[#connections + 1] = player.CharacterAdded:Connect(function(char)
		hookCharacter(player, char)
	end)
end

function PeerVisibility.setLocalMode(mode)
	if mode ~= "field" and mode ~= "command" then return end
	if localMode == mode then return end
	localMode = mode
	refreshAll()
end

function PeerVisibility.setPeerMode(userId, mode)
	if mode == nil then
		peerModes[userId] = nil
		return
	end
	if mode ~= "field" and mode ~= "command" then return end
	peerModes[userId] = mode
	local player = Players:GetPlayerByUserId(userId)
	if player then refreshPlayer(player) end
end

function PeerVisibility.applyFull(modeTable)
	peerModes = {}
	for userIdStr, mode in modeTable do
		local userId = tonumber(userIdStr)
		if userId then peerModes[userId] = mode end
	end
	refreshAll()
end

function PeerVisibility.start()
	for _, p in Players:GetPlayers() do
		bindPlayer(p)
	end
	connections[#connections + 1] = Players.PlayerAdded:Connect(bindPlayer)
	connections[#connections + 1] = Players.PlayerRemoving:Connect(function(player)
		peerModes[player.UserId] = nil
		local hook = descendantHooks[player.UserId]
		if hook then
			hook:Disconnect()
			descendantHooks[player.UserId] = nil
		end
	end)
end

function PeerVisibility.destroy()
	for _, c in connections do c:Disconnect() end
	for _, c in descendantHooks do c:Disconnect() end
	connections = {}
	descendantHooks = {}
	peerModes = {}
end

return PeerVisibility
