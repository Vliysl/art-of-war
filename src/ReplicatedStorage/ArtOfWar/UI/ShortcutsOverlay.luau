local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))

local ShortcutsOverlay = {}

local SECTIONS = {
	{
		title = "Modes",
		rows = {
			{ "`",            "toggle Data Editor" },
			{ "/command",     "scriptable map camera" },
			{ "/field",       "walking avatar" },
			{ "/mode",        "toggle field/command" },
		},
	},
	{
		title = "Realm",
		rows = {
			{ "click crest", "toggle Realm panel (Overview)" },
			{ "Esc",         "close panels / windows" },
		},
	},
	{
		title = "Panel Windows",
		rows = {
			{ "G",   "Politics" },
			{ "E",   "Economy" },
			{ "Y",   "Research" },
			{ "V",   "Diplomacy" },
			{ "F10", "Settings menu" },
			{ "X",   "Close topmost window" },
		},
	},
	{
		title = "Province Panel",
		rows = {
			{ "I",   "Information" },
			{ "R",   "Recruitment" },
			{ "B",   "Buildings" },
		},
	},
	{
		title = "World",
		rows = {
			{ "M",     "toggle view mode (Field / Command)" },
			{ "Space", "pause / resume time (admin)" },
			{ "1",     "1× speed (admin)" },
			{ "2",     "2× speed (admin)" },
			{ "3",     "4× speed (admin)" },
			{ "4",     "8× speed (admin)" },
			{ "5",     "16× speed (admin)" },
			{ "F12",   "this shortcut list" },
		},
	},
	{
		title = "Province Panel",
		rows = {
			{ "I", "Information" },
			{ "R", "Recruitment" },
			{ "B", "Buildings" },
		},
	},
}

function ShortcutsOverlay.create(parent)
	local root = Instance.new("Frame")
	root.Name = "ShortcutsOverlay"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = UIStyle.Color.Bg
	root.BackgroundTransparency = 0.35
	root.BorderSizePixel = 0
	root.Visible = false
	root.ZIndex = UIStyle.Z.Modal
	root.Active = true
	root.Parent = parent
	root:SetAttribute("AoWInputSink", true)

	local panel = Instance.new("Frame")
	panel.Size = UDim2.fromOffset(640, 520)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.BackgroundColor3 = UIStyle.Color.Panel
	panel.BorderSizePixel = 0
	panel.ZIndex = UIStyle.Z.Modal + 1
	panel.Parent = root

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = UIStyle.Color.Gold
	stroke.Thickness = 2
	stroke.Parent = panel

	local header = UIBuilder.label(panel, "Keyboard Shortcuts", UIStyle.Type.H1, UIStyle.Color.Gold, {
		Size = UDim2.new(1, -48, 0, 40),
		Position = UDim2.fromOffset(24, 14),
		Font = UIStyle.Font.Bold,
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	local closeBtn = Instance.new("TextButton")
	closeBtn.Size = UDim2.fromOffset(30, 30)
	closeBtn.Position = UDim2.new(1, -12, 0, 12)
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.BackgroundColor3 = UIStyle.Color.Bad
	closeBtn.BorderSizePixel = 0
	closeBtn.Text = "×"
	closeBtn.TextColor3 = UIStyle.Color.Text
	closeBtn.Font = UIStyle.Font.Bold
	closeBtn.TextSize = 18
	closeBtn.AutoButtonColor = false
	closeBtn.ZIndex = UIStyle.Z.Modal + 2
	closeBtn.Parent = panel
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 4)
	closeCorner.Parent = closeBtn

	local body = Instance.new("Frame")
	body.Size = UDim2.new(1, -48, 1, -72)
	body.Position = UDim2.fromOffset(24, 64)
	body.BackgroundTransparency = 1
	body.ZIndex = UIStyle.Z.Modal + 1
	body.Parent = panel

	local grid = Instance.new("UIListLayout")
	grid.FillDirection = Enum.FillDirection.Horizontal
	grid.Padding = UDim.new(0, 16)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = body

	for idx, section in ipairs(SECTIONS) do
		local col = Instance.new("Frame")
		col.Size = UDim2.new(0, 192, 1, 0)
		col.BackgroundColor3 = UIStyle.Color.PanelAlt
		col.BorderSizePixel = 0
		col.LayoutOrder = idx
		col.ZIndex = UIStyle.Z.Modal + 1
		col.Parent = body
		local cc = Instance.new("UICorner")
		cc.CornerRadius = UDim.new(0, 4)
		cc.Parent = col
		local cs = Instance.new("UIStroke")
		cs.Color = UIStyle.Color.Border
		cs.Parent = col

		UIBuilder.label(col, section.title, UIStyle.Type.Small, UIStyle.Color.Gold, {
			Size = UDim2.new(1, -16, 0, 22),
			Position = UDim2.fromOffset(8, 6),
			Font = UIStyle.Font.Bold,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
		})

		local list = Instance.new("Frame")
		list.Size = UDim2.new(1, -16, 1, -36)
		list.Position = UDim2.fromOffset(8, 30)
		list.BackgroundTransparency = 1
		list.Parent = col

		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 4)
		layout.Parent = list

		for i, row in ipairs(section.rows) do
			local entry = Instance.new("Frame")
			entry.Size = UDim2.new(1, 0, 0, 20)
			entry.BackgroundTransparency = 1
			entry.LayoutOrder = i
			entry.Parent = list

			local key = Instance.new("TextLabel")
			key.Size = UDim2.fromOffset(64, 20)
			key.BackgroundColor3 = UIStyle.Color.Bg
			key.BorderSizePixel = 0
			key.Text = row[1]
			key.TextColor3 = UIStyle.Color.Gold
			key.Font = UIStyle.Font.Bold
			key.TextSize = 11
			key.Parent = entry
			local kc = Instance.new("UICorner")
			kc.CornerRadius = UDim.new(0, 3)
			kc.Parent = key
			local ks = Instance.new("UIStroke")
			ks.Color = UIStyle.Color.Border
			ks.Parent = key

			local desc = Instance.new("TextLabel")
			desc.Size = UDim2.new(1, -72, 1, 0)
			desc.Position = UDim2.fromOffset(70, 0)
			desc.BackgroundTransparency = 1
			desc.Text = row[2]
			desc.TextColor3 = UIStyle.Color.Text
			desc.Font = UIStyle.Font.Regular
			desc.TextSize = 12
			desc.TextXAlignment = Enum.TextXAlignment.Left
			desc.Parent = entry
		end
	end

	local visible = false
	local function setVisible(flag)
		flag = flag and true or false
		if visible == flag then return end
		visible = flag
		root.Visible = flag
		if flag then
			panel.Size = UDim2.fromOffset(620, 500)
			TweenService:Create(panel, TweenInfo.new(0.18, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
				{ Size = UDim2.fromOffset(640, 520) }):Play()
		end
	end
	closeBtn.MouseButton1Click:Connect(function() setVisible(false) end)

	return {
		root = root,
		setVisible = setVisible,
		isVisible = function() return visible end,
		toggle = function() setVisible(not visible) end,
	}
end

return ShortcutsOverlay
