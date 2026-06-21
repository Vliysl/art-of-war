local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Spacing = DesignSystem.Spacing

local SectionDivider = {}

function SectionDivider.create(config)
	config = config or {}

	local frame = Instance.new("Frame")
	frame.Name = "SectionDivider"
	frame.Size = UDim2.new(1, 0, 0, 24)
	frame.BackgroundTransparency = 1
	frame.ClipsDescendants = true
	frame.LayoutOrder = config.layoutOrder or 0

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	-- Without this the layout defaults to SortOrder.Name, which orders the two same-named "Frame" rules
	-- before the "Label" (ignoring LayoutOrder 1/2/3) -- rendering "-- -- TEXT" instead of "-- TEXT --".
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, Spacing.space3)
	layout.Parent = frame

	-- The two rules flex to share whatever width is left after the centered label + gaps, so the
	-- header always fits its frame regardless of label length or UIScale (fixed-width rules used to
	-- overflow the card on longer labels like "GOVERNMENT").
	local function rule(order)
		local line = Instance.new("Frame")
		line.Size = UDim2.new(0, 0, 0, 1)
		line.BackgroundColor3 = Colors.BorderSubtle
		line.BackgroundTransparency = 0.3
		line.BorderSizePixel = 0
		line.LayoutOrder = order
		local flex = Instance.new("UIFlexItem")
		flex.FlexMode = Enum.UIFlexMode.Fill
		flex.Parent = line
		line.Parent = frame
	end
	rule(1)

	local raw = config.label or ""
	local spaced = ""
	for i = 1, #raw do
		spaced = spaced .. raw:sub(i, i)
		if i < #raw then
			spaced = spaced .. " "
		end
	end

	local labelText = Instance.new("TextLabel")
	labelText.Name = "Label"
	labelText.AutomaticSize = Enum.AutomaticSize.X
	labelText.Size = UDim2.new(0, 0, 1, 0)
	labelText.BackgroundTransparency = 1
	labelText.Text = string.upper(spaced)
	labelText.TextColor3 = Colors.TextTertiary
	labelText.FontFace = Typography.SansBold
	labelText.TextSize = Typography.caption
	labelText.LayoutOrder = 2
	labelText.Parent = frame

	rule(3)

	if config.parent then
		frame.Parent = config.parent
	end
	return frame
end

return SectionDivider
