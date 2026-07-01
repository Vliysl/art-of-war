local RunService = game:GetService("RunService")

local EditorAdmins = {}

-- Root managers: always allowed AND may grant/revoke editor access to others.
EditorAdmins.userIds = {
	[1878164020] = true,
	[609222585] = true,
}

-- Session-scoped grants (RoN-style): the private-server owner (or a dev) can grant other players
-- editor access at runtime. Not persisted — grants reset on server restart, and never touch the
-- DataStore. [userId] = true.
local granted = {}

-- Managers can use the editor AND manage who else can: Studio, the game's creator, the hardcoded
-- dev list, and — in a VIP/private server — that server's owner. This is the "grant" tier.
function EditorAdmins.canManage(player)
	if not player or typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end
	if RunService:IsStudio() then
		return true
	end
	if game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
		return true
	end
	if EditorAdmins.userIds[player.UserId] == true then
		return true
	end
	-- Private-server owner (VIP server): they own the suite in their own server only.
	if game.PrivateServerOwnerId ~= 0 and player.UserId == game.PrivateServerOwnerId then
		return true
	end
	return false
end

-- Anyone who may use the editor: a manager, or a player the owner has granted this session.
function EditorAdmins.isAllowed(player)
	if EditorAdmins.canManage(player) then
		return true
	end
	if not player or typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end
	return granted[player.UserId] == true
end

function EditorAdmins.grant(userId)
	userId = tonumber(userId)
	if userId then
		granted[userId] = true
	end
	return userId ~= nil
end

function EditorAdmins.revoke(userId)
	userId = tonumber(userId)
	if userId then
		granted[userId] = nil
	end
	return userId ~= nil
end

function EditorAdmins.isGranted(userId)
	userId = tonumber(userId)
	return userId ~= nil and granted[userId] == true
end

return EditorAdmins
