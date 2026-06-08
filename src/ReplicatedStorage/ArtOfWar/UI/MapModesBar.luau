local ReplicatedStorage = game:GetService("ReplicatedStorage")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))

local MapModesBar = {}

local MODES = {
	{ key = "political", label = "Political", hint = "Owner colors" },
	{ key = "terrain",   label = "Terrain",   hint = "Geography" },
	{ key = "culture",   label = "Culture",   hint = "Cultural groups" },
	{ key = "religion",  label = "Religion",  hint = "State religions" },
	{ key = "trade",     label = "Trade",     hint = "Trade good produced" },
}

local CONTAINER_H = 30
local MINIMAP_GAP = 4

function MapModesBar.create(parent, onSelect)
	local minimapW = UIStyle.Size.MinimapW or 240
	local minimapH = UIStyle.Size.MinimapH or 180

	local container = Instance.new("Frame")
	container.Name = "MapModesBar"
	container.Size = UDim2.fromOffset(minimapW, CONTAINER_H)
	container.AnchorPoint = Vector2.new(1, 1)
	container.Position = UDim2.new(1, -12, 1, -(UIStyle.Size.BottomBarH + 12 + minimapH + MINIMAP_GAP))
	container.BackgroundColor3 = UIStyle.Color.Panel
	container.BorderSizePixel = 0
	container.ZIndex = UIStyle.Z.Chrome
	container.Parent = parent
	container:SetAttribute("AoWInputSink", true)
	UIBuilder.corner(container, 3)
	UIBuilder.stroke(container, 1, UIStyle.Color.Gold)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, 2)
	layout.Parent = container

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 4)
	pad.PaddingRight = UDim.new(0, 4)
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.Parent = container

	local buttons = {}
	local current = "political"

	local function applyVisuals()
		for key, btn in buttons do
			local active = key == current
			btn.BackgroundColor3 = active and UIStyle.Color.Bg or UIStyle.Color.PanelAlt
			btn.TextColor3 = active and UIStyle.Color.Gold or UIStyle.Color.TextMuted
			local stroke = btn:FindFirstChildOfClass("UIStroke")
			if stroke then stroke.Color = active and UIStyle.Color.Gold or UIStyle.Color.Border end
		end
	end

	for i, mode in ipairs(MODES) do
		local btn = Instance.new("TextButton")
		btn.AutomaticSize = Enum.AutomaticSize.X
		btn.Size = UDim2.fromOffset(0, 22)
		btn.BackgroundColor3 = UIStyle.Color.PanelAlt
		btn.BorderSizePixel = 0
		btn.AutoButtonColor = false
		btn.Text = mode.label
		btn.TextColor3 = UIStyle.Color.TextMuted
		btn.Font = UIStyle.Font.Semibold
		btn.TextSize = 11
		btn.LayoutOrder = i
		btn.ZIndex = UIStyle.Z.Chrome + 1
		btn.Parent = container
		UIBuilder.corner(btn, 2)
		UIBuilder.stroke(btn, 1, UIStyle.Color.Border)

		local btnPad = Instance.new("UIPadding")
		btnPad.PaddingLeft = UDim.new(0, 8)
		btnPad.PaddingRight = UDim.new(0, 8)
		btnPad.Parent = btn

		UIBuilder.tooltip(btn, function()
			return {
				{ header = mode.label .. " Map Mode" },
				{ body = mode.hint },
			}
		end)

		btn.MouseButton1Click:Connect(function()
			if current == mode.key then return end
			current = mode.key
			applyVisuals()
			if onSelect then onSelect(mode.key) end
		end)

		buttons[mode.key] = btn
	end

	applyVisuals()

	local visible = true
	local function setVisible(flag)
		visible = flag and true or false
		container.Visible = visible
	end

	local api = {}
	api.root = container
	api.setVisible = setVisible
	function api.isVisible() return visible end
	function api.toggleVisible()
		setVisible(not visible)
	end
	function api.setMode(key)
		if buttons[key] then
			current = key
			applyVisuals()
		end
	end
	function api.cycle()
		for i, mode in ipairs(MODES) do
			if mode.key == current then
				local next_i = (i % #MODES) + 1
				local nextKey = MODES[next_i].key
				current = nextKey
				applyVisuals()
				if onSelect then onSelect(nextKey) end
				return nextKey
			end
		end
	end
	function api.current() return current end
	return api
end

return MapModesBar
