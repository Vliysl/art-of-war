local RunService = game:GetService("RunService")

local EditorAdmins = {}

-- MASTER GATE. While false, ONLY official editors (Studio / game creator / the dev user-IDs below) can
-- use the Data Editor. The RoN-style owner suite — VIP private-server owners + runtime-granted players —
-- stays OFF until we deliberately open the editor to players. Flip to true to enable that suite.
EditorAdmins.OWNER_SUITE_ENABLED = false

-- Official editors: the dev team. Always allowed AND may grant/revoke access (when the suite is on).
EditorAdmins.userIds = {
	[1878164020] = true,
	[609222585] = true,
}

-- Session-scoped grants (RoN-style, only honored when OWNER_SUITE_ENABLED): a manager can grant other
-- players editor access at runtime. Not persisted — reset on restart, never touch the DataStore.
local granted = {}

-- Official editors: Studio, the game's creator, and the hardcoded dev list. This tier is ALWAYS allowed,
-- regardless of OWNER_SUITE_ENABLED.
local function isOfficialEditor(player)
	if not player or typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end
	if RunService:IsStudio() then
		return true
	end
	if game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
		return true
	end
	return EditorAdmins.userIds[player.UserId] == true
end

-- Managers can use the editor AND manage who else can. Official editors always qualify; the VIP
-- private-server owner only qualifies when the owner suite is enabled.
function EditorAdmins.canManage(player)
	if isOfficialEditor(player) then
		return true
	end
	if EditorAdmins.OWNER_SUITE_ENABLED and player and typeof(player) == "Instance" and player:IsA("Player") then
		if game.PrivateServerOwnerId ~= 0 and player.UserId == game.PrivateServerOwnerId then
			return true
		end
	end
	return false
end

-- Anyone who may use the editor: a manager, or (only when the suite is on) a granted player.
function EditorAdmins.isAllowed(player)
	if EditorAdmins.canManage(player) then
		return true
	end
	if not EditorAdmins.OWNER_SUITE_ENABLED then
		return false
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
