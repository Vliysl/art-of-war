local CharacterScaler = {}

local Players = game:GetService("Players")

local ctx

local function applyScale(char)
	if not char or not char.Parent then return end
	local scale = ctx.WorldConstants.FieldBodyScale
	pcall(function() char:ScaleTo(scale) end)
end

local function hookPlayer(player)
	if player.Character then applyScale(player.Character) end
	player.CharacterAdded:Connect(applyScale)
	player.CharacterAppearanceLoaded:Connect(applyScale)
end

function CharacterScaler.register(context)
	ctx = context
	Players.PlayerAdded:Connect(hookPlayer)
	for _, existing in Players:GetPlayers() do
		hookPlayer(existing)
	end
end

return CharacterScaler
