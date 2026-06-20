local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Animations = DesignSystem.Animations
local Icons = DesignSystem.Icons
local Shells = DesignSystem.Shells
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
			Animations.tween(e.activeBg, Animations.Fast, { ImageTransparency = on and 0 or 1 })
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

		local idle = Shells.create("map_mode_button_shell", { Name = "Idle", ZIndex = z + 1 })
		idle.Parent = btn
		local activeBg =
			Shells.create("map_mode_button_active", { Name = "Active", ImageTransparency = 1, ZIndex = z + 1 })
		activeBg.Parent = btn
		local icon = Icons.create(mode.icon, 22, Colors.TextSecondary)
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.ZIndex = z + 2
		icon.Parent = btn

		entries[mode.key] = { activeBg = activeBg, icon = icon }
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
