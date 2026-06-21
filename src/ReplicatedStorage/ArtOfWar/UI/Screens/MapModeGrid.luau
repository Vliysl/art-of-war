local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Animations = DesignSystem.Animations
local Icons = DesignSystem.Icons
local Responsive = DesignSystem.Responsive
local Tooltip = require(script.Parent.Parent.Components.Tooltip)

local MapModeGrid = {}

local DEFAULT_MODES = {
	{ key = "political", icon = "MapPolitical", label = "Political" },
	{ key = "terrain", icon = "MapTerrain", label = "Terrain" },
	{ key = "culture", icon = "MapCulture", label = "Culture" },
	{ key = "religion", icon = "MapReligion", label = "Religion" },
	{ key = "trade", icon = "MapTrade", label = "Trade Goods" },
	{ key = "diplomatic", icon = "Diplomacy", label = "Diplomatic" },
	{ key = "development", icon = "Building", label = "Development" },
	{ key = "fronts", icon = "War", label = "Fronts" },
	{ key = "goods", icon = "Goods", label = "Resources" },
}

function MapModeGrid.create(config)
	config = config or {}
	local modes = config.modes or DEFAULT_MODES
	local z = config.zIndex or 5
	local columns = config.columns or 3
	local cell = Responsive.tapHeight(config.cellSize or 48)
	local gap = 4

	local rows = math.ceil(#modes / columns)
	local root = Instance.new("Frame")
	root.Name = "MapModeGrid"
	root.AnchorPoint = config.anchorPoint or Vector2.new(1, 1)
	root.Position = config.position or UDim2.new(1, -16, 1, -16)
	root.Size = UDim2.fromOffset(columns * cell + (columns - 1) * gap, rows * cell + (rows - 1) * gap)
	root.BackgroundTransparency = 1
	root.ZIndex = z
	root:SetAttribute("AoWInputSink", true)

	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(cell, cell)
	grid.CellPadding = UDim2.fromOffset(gap, gap)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.FillDirectionMaxCells = columns
	grid.Parent = root

	local entries = {}
	local active = nil

	local function setActive(key)
		active = key
		for k, e in entries do
			local on = k == key
			local fill = on and Colors.SurfaceOverlay or Colors.SurfaceElevated
			local rim = on and Colors.BorderActive or Colors.BorderStrong
			Animations.tween(e.bg, Animations.Fast, { BackgroundColor3 = fill })
			Animations.tween(e.stroke, Animations.Fast, { Color = rim })
			e.icon.ImageColor3 = on and Colors.Accent or Colors.TextSecondary
		end
	end

	for i, mode in ipairs(modes) do
		local btn = Instance.new("TextButton")
		btn.Name = mode.key
		btn.BackgroundTransparency = 1
		btn.AutoButtonColor = false
		btn.Text = ""
		btn.LayoutOrder = i
		btn.ZIndex = z + 1
		btn.Parent = root

		local bg = Instance.new("Frame")
		bg.Name = "Bg"
		bg.Size = UDim2.fromScale(1, 1)
		bg.BackgroundColor3 = Colors.SurfaceElevated
		bg.BorderSizePixel = 0
		bg.ZIndex = z + 1
		bg.Parent = btn
		local bgCorner = Instance.new("UICorner")
		bgCorner.CornerRadius = UDim.new(0, 6)
		bgCorner.Parent = bg
		local stroke = Instance.new("UIStroke")
		stroke.Color = Colors.BorderStrong
		stroke.Thickness = 1
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = bg
		local icon = Icons.create(mode.icon, 22, Colors.TextSecondary)
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.ZIndex = z + 2
		icon.Parent = btn

		entries[mode.key] = { bg = bg, stroke = stroke, icon = icon }
		btn.MouseEnter:Connect(function()
			if active ~= mode.key then
				icon.ImageColor3 = Colors.TextPrimary
			end
		end)
		btn.MouseLeave:Connect(function()
			if active ~= mode.key then
				icon.ImageColor3 = Colors.TextSecondary
			end
		end)
		btn.MouseButton1Click:Connect(function()
			setActive(mode.key)
			if config.onChange then
				config.onChange(mode.key)
			end
		end)
		Tooltip.attach(btn, function()
			return Tooltip.create({ title = mode.label, width = 140 })
		end)
	end

	setActive(config.active or modes[1].key)

	if config.parent then
		root.Parent = config.parent
	end
	return { root = root, setActive = setActive, entries = entries }
end

return MapModeGrid
