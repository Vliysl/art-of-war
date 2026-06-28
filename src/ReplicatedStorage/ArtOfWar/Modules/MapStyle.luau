-- MapStyle: optional, fully-reversible visual restyle of the map.
--   1) Land province tiles get a Roblox MATERIAL chosen by their `terrain` attribute (instead of the
--      flat default Concrete), so plains read as grass, deserts as sand, mountains as slate, etc. Only
--      the Material changes -- map-mode recolouring (which only sets Color) is untouched.
--   2) The MapBase ocean parts are deepened and given a touch of sky reflectance + a faint surface
--      texture so the sea stops looking like flat bright plastic.
--
-- Everything is CLIENT-SIDE and reversible: setEnabled(false) restores the originals (province material
-- back to Concrete; ocean Color/Reflectance restored from cached attributes and the added texture
-- removed). Press F7 in-game to toggle and compare. Delete this module + its ClientBoot call to remove
-- the feature entirely.
local UserInputService = game:GetService("UserInputService")

local MapStyle = {}

MapStyle.ENABLED_BY_DEFAULT = true

local PROV_DEFAULT_MATERIAL = Enum.Material.Concrete -- what ProvinceStamper sets; restore target

-- terrain attribute (Data/Terrains.luau ids) -> part Material. Unmapped/unknown keep the default.
local TERRAIN_MATERIAL = {
	plains = Enum.Material.Grass,
	grassland = Enum.Material.Grass,
	farmland = Enum.Material.Ground,
	forest = Enum.Material.LeafyGrass,
	jungle = Enum.Material.LeafyGrass,
	taiga = Enum.Material.LeafyGrass,
	hills = Enum.Material.Rock,
	highlands = Enum.Material.Rock,
	mountain = Enum.Material.Slate,
	plateau = Enum.Material.Sandstone,
	marsh = Enum.Material.Mud,
	desert = Enum.Material.Sand,
	drylands = Enum.Material.Sandstone,
	steppe = Enum.Material.Ground,
	savanna = Enum.Material.Ground,
	tundra = Enum.Material.Snow,
	arctic = Enum.Material.Glacier,
	coast = Enum.Material.Sand,
	coastal = Enum.Material.Sand,
}

local OCEAN_REFLECTANCE = 0.08
local OCEAN_TEXTURE = "rbxassetid://123345823845958" -- same subtle grain the land tiles use, very faint
local YIELD_EVERY = 600

local function mapFolder()
	return workspace:FindFirstChild("ArtOfWarMap")
end

-- Land: set each province part's Material from its terrain (or restore Concrete).
function MapStyle.applyTerrainMaterials(on)
	local map = mapFolder()
	local provinces = map and map:FindFirstChild("Provinces")
	if not provinces then return end
	local n = 0
	for _, p in ipairs(provinces:GetChildren()) do
		if p:IsA("BasePart") then
			if on then
				p.Material = TERRAIN_MATERIAL[p:GetAttribute("terrain")] or PROV_DEFAULT_MATERIAL
			else
				p.Material = PROV_DEFAULT_MATERIAL
			end
			n += 1
			if n % YIELD_EVERY == 0 then task.wait() end
		end
	end
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
	MapStyle.applyTerrainMaterials(on)
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
