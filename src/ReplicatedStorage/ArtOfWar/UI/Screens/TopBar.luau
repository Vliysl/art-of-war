local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Shells = DesignSystem.Shells

local TopBar = {}

function TopBar.create(config)
	config = config or {}
	local z = config.zIndex or 5

	local root = Shells.create("date_speed_shell", {
		Name = "TopBar",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = config.position or UDim2.new(0.5, 0, 0, 12),
		Size = config.size or UDim2.fromOffset(248, 46),
		ZIndex = z,
	})
	root:SetAttribute("AoWInputSink", true)

	local date = Instance.new("TextLabel")
	date.Name = "Date"
	date.Size = UDim2.fromScale(1, 1)
	date.BackgroundTransparency = 1
	date.Text = config.date or ""
	date.TextColor3 = Colors.TextPrimary
	date.TextXAlignment = Enum.TextXAlignment.Center
	date.TextYAlignment = Enum.TextYAlignment.Center
	date.ZIndex = z + 1
	Typography.apply(date, "displayMd")
	date.Parent = root
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 18)
	pad.PaddingRight = UDim.new(0, 18)
	pad.Parent = root

	if config.parent then
		root.Parent = config.parent
	end

	return {
		root = root,
		setDate = function(d)
			if d then
				date.Text = d
			end
		end,
	}
end

return TopBar
