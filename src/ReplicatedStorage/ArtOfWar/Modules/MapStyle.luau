-- MapStyle: optional, fully-reversible OCEAN restyle. The MapBase ocean parts are deepened and given a
-- touch of sky reflectance + a faint surface texture so the sea stops looking like flat bright plastic.
-- Client-side and reversible: setEnabled(false) restores Color/Reflectance from cached attributes and
-- removes the added texture. Press F7 in-game to toggle and compare. Delete this module + its ClientBoot
-- call to remove the feature entirely.
-- (A per-terrain land-material pass lived here too but was reverted by request; see git history.)
local UserInputService = game:GetService("UserInputService")

local MapStyle = {}

MapStyle.ENABLED_BY_DEFAULT = true

local OCEAN_REFLECTANCE = 0.08
local OCEAN_TEXTURE = "rbxassetid://123345823845958" -- same subtle grain the land tiles use, very faint
local YIELD_EVERY = 600

local function mapFolder()
	return workspace:FindFirstChild("ArtOfWarMap")
end

-- Ocean: deepen colour + add slight reflectance + a faint surface texture (or restore the originals).
function MapStyle.styleOcean(on)
	local map = mapFolder()
	local base = map and map:FindFirstChild("MapBase")
	if not base then return end
	local n = 0
	for _, p in ipairs(base:GetChildren()) do
		if p:IsA("BasePart") and p.Name:sub(1, 5) == "Ocean" then
			if on then
				-- Cache the baked originals once so we can restore exactly.
				if p:GetAttribute("aowBaseR") == nil then
					p:SetAttribute("aowBaseR", p.Color.R)
					p:SetAttribute("aowBaseG", p.Color.G)
					p:SetAttribute("aowBaseB", p.Color.B)
					p:SetAttribute("aowBaseRefl", p.Reflectance)
				end
				local c = p.Color
				-- Deepen + nudge bluer (keeps the deep/near two-tone depth gradient).
				p.Color = Color3.new(c.R * 0.82, c.G * 0.86, math.min(1, c.B * 1.06 + 0.02))
				p.Reflectance = OCEAN_REFLECTANCE
				if not p:FindFirstChild("AoWWaterTex") then
					local tex = Instance.new("Texture")
					tex.Name = "AoWWaterTex"
					tex.Face = Enum.NormalId.Top
					tex.Texture = OCEAN_TEXTURE
					tex.Transparency = 0.86
					tex.StudsPerTileU = 350
					tex.StudsPerTileV = 350
					tex.Parent = p
				end
			else
				local r = p:GetAttribute("aowBaseR")
				if r ~= nil then
					p.Color = Color3.new(r, p:GetAttribute("aowBaseG"), p:GetAttribute("aowBaseB"))
					p.Reflectance = p:GetAttribute("aowBaseRefl") or 0
				end
				local tex = p:FindFirstChild("AoWWaterTex")
				if tex then tex:Destroy() end
			end
			n += 1
			if n % YIELD_EVERY == 0 then task.wait() end
		end
	end
end

local enabled = false
function MapStyle.setEnabled(on)
	on = on and true or false
	enabled = on
	MapStyle.styleOcean(on)
end

function MapStyle.toggle()
	MapStyle.setEnabled(not enabled)
end

local inited = false
function MapStyle.init()
	if inited then return end
	inited = true
	-- F7 toggles the whole restyle live so the look can be compared / disabled if it doesn't land.
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode == Enum.KeyCode.F7 then
			MapStyle.toggle()
		end
	end)
end

return MapStyle
