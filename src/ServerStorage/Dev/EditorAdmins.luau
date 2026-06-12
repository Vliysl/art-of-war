local RunService = game:GetService("RunService")

local EditorAdmins = {}

EditorAdmins.userIds = {
	[1878164020] = true,
	[609222585] = true,
}

function EditorAdmins.isAllowed(player)
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

return EditorAdmins
