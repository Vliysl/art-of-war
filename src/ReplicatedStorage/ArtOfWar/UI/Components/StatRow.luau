local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Icons = DesignSystem.Icons
local ProgressBar = require(script.Parent.ProgressBar)

local StatRow = {}

local function resolveColor(c)
	if type(c) == "string" then
		return Colors.resolve(c)
	end
	return c
end

function StatRow.create(config)
	config = config or {}
	local hasDelta = config.delta ~= nil and config.delta ~= ""
	local hasProgress = config.progress ~= nil

	local frame = Instance.new("Frame")
	frame.Name = "StatRow"
	frame.Size = UDim2.new(1, 0, 0, config.height or 36)
	frame.BackgroundTransparency = 1
	frame.LayoutOrder = config.layoutOrder or 0

	local leftPad = 0
	if config.icon then
		local icon = Icons.create(config.icon, 16, resolveColor(config.iconColor) or Colors.TextSecondary)
		icon.AnchorPoint = Vector2.new(0, 0.5)
		icon.Position = UDim2.new(0, 0, 0.5, hasProgress and -3 or 0)
		icon.Parent = frame
		leftPad = 26
	end

	local labelHeight = hasProgress and -6 or 0
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Position = UDim2.fromOffset(leftPad, 0)
	label.Size = UDim2.new(0.5, -leftPad, 1, labelHeight)
	label.BackgroundTransparency = 1
	label.Text = config.label or ""
	label.TextColor3 = Colors.TextSecondary
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	Typography.apply(label, "bodyMd")
	label.Parent = frame

	local valueColor = resolveColor(config.valueColor) or Colors.TextPrimary
	local value = Instance.new("TextLabel")
	value.Name = "Value"
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.new(1, 0, 0, 0)
	value.Size = UDim2.new(0.5, 0, hasDelta and 0.62 or 1, labelHeight)
	value.BackgroundTransparency = 1
	value.Text = tostring(config.value or "")
	value.TextColor3 = valueColor
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.TextYAlignment = hasDelta and Enum.TextYAlignment.Bottom or Enum.TextYAlignment.Center
	Typography.apply(value, config.mono and "mono" or "value")
	value.Parent = frame

	if hasDelta then
		local delta = Instance.new("TextLabel")
		delta.Name = "Delta"
		delta.AnchorPoint = Vector2.new(1, 0)
		delta.Position = UDim2.new(1, 0, 0.62, labelHeight)
		delta.Size = UDim2.new(0.5, 0, 0.38, 0)
		delta.BackgroundTransparency = 1
		delta.Text = config.delta
		delta.TextColor3 = config.deltaColor and resolveColor(config.deltaColor) or Colors.delta(config.deltaNum or 0)
		delta.TextXAlignment = Enum.TextXAlignment.Right
		delta.TextYAlignment = Enum.TextYAlignment.Top
		Typography.apply(delta, "caption")
		delta.Parent = frame
	end

	if hasProgress then
		local bar = ProgressBar.create({
			value = config.progress.value,
			min = config.progress.min,
			max = config.progress.max,
			color = config.progress.color,
			height = 4,
			parent = frame,
		})
		bar.AnchorPoint = Vector2.new(0, 1)
		bar.Position = UDim2.new(0, leftPad, 1, 0)
		bar.Size = UDim2.new(1, -leftPad, 0, 4)
	end

	if config.parent then
		frame.Parent = config.parent
	end
	return frame, value
end

return StatRow
