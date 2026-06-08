local FieldCollider = {}

local MAX_AXIS = 2048

local function stampGrid(parent, constants)
	local width = constants.MapWidth
	local depth = constants.MapDepth
	local centerX = constants.MapCenterX
	local centerZ = constants.MapCenterZ
	local thickness = constants.FieldColliderThickness or 4
	local topY = constants.FieldColliderTopY or 6
	local centerY = topY - thickness * 0.5

	local cols = math.ceil(width / MAX_AXIS)
	local rows = math.ceil(depth / MAX_AXIS)
	local tileW = width / cols
	local tileD = depth / rows

	local folder = Instance.new("Folder")
	folder.Name = "FieldFloor"
	folder.Parent = parent

	for ix = 0, cols - 1 do
		for iz = 0, rows - 1 do
			local part = Instance.new("Part")
			part.Name = string.format("FloorTile_%d_%d", ix, iz)
			part.Anchored = true
			part.CanCollide = true
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
			part.Transparency = 1
			part.TopSurface = Enum.SurfaceType.Smooth
			part.BottomSurface = Enum.SurfaceType.Smooth
			part.Material = Enum.Material.SmoothPlastic
			part.Size = Vector3.new(tileW, thickness, tileD)
			part.Position = Vector3.new(
				centerX - width * 0.5 + tileW * (ix + 0.5),
				centerY,
				centerZ - depth * 0.5 + tileD * (iz + 0.5)
			)
			part.Locked = true
			part.Archivable = false
			part.Parent = folder
		end
	end

	return cols * rows
end

function FieldCollider.register(context)
	local map = workspace:FindFirstChild("ArtOfWarMap")
	if not map then
		warn("[FieldCollider] ArtOfWarMap not present at register time")
		return
	end
	if map:FindFirstChild("FieldFloor") then return end
	local stamped = stampGrid(map, context.WorldConstants)
	context.FieldCollider = FieldCollider
	print(string.format("[ArtOfWar] field collider stamped %d tiles", stamped))
end

return FieldCollider
