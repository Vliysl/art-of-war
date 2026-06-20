local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Spacing = DesignSystem.Spacing
local Shells = DesignSystem.Shells

local Panel = {}

local SHELL_BY_VARIANT = {
	small = "panel_small_shell",
	medium = "panel_medium_shell",
	large = "panel_large_shell",
	wide = "panel_wide_shell",
	sub = "panel_sub_shell",
	modal = "panel_modal_shell",
	tooltip = "panel_tooltip_shell",
}

function Panel.create(config)
	config = config or {}
	local shellName = config.shell or SHELL_BY_VARIANT[config.variant or "medium"] or "panel_medium_shell"
	local z = config.zIndex or 1

	local panel = Shells.create(shellName, {
		Name = config.name or "Panel",
		Size = config.size or UDim2.fromOffset(config.width or 320, config.height or 400),
		Position = config.position or UDim2.fromOffset(0, 0),
		AnchorPoint = config.anchorPoint or Vector2.new(0, 0),
		ZIndex = z,
	})

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.fromScale(1, 1)
	content.BackgroundTransparency = 1
	content.ZIndex = z + 1
	content.Parent = panel

	local pad = config.padding or Spacing.space4
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, pad)
	padding.PaddingBottom = UDim.new(0, pad)
	padding.PaddingLeft = UDim.new(0, pad)
	padding.PaddingRight = UDim.new(0, pad)
	padding.Parent = content

	if config.layout ~= false then
		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Vertical
		layout.Padding = UDim.new(0, config.gap or Spacing.space3)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = content
	end

	if config.title then
		local titleFrame = Instance.new("Frame")
		titleFrame.Name = "TitleBar"
		titleFrame.Size = UDim2.new(1, 0, 0, 34)
		titleFrame.BackgroundTransparency = 1
		titleFrame.ZIndex = z + 1
		titleFrame.LayoutOrder = 0
		titleFrame.Parent = content

		local titleText = Instance.new("TextLabel")
		titleText.Name = "Title"
		titleText.Size = UDim2.new(1, config.closable and -34 or 0, 1, 0)
		titleText.BackgroundTransparency = 1
		titleText.Text = config.title
		titleText.TextColor3 = Colors.TextPrimary
		titleText.TextXAlignment = Enum.TextXAlignment.Left
		titleText.TextYAlignment = Enum.TextYAlignment.Center
		titleText.ZIndex = z + 2
		Typography.apply(titleText, "displayLg")
		titleText.Parent = titleFrame

		if config.subtitle then
			titleText.Size = UDim2.new(1, config.closable and -34 or 0, 0, 26)
			local sub = Instance.new("TextLabel")
			sub.Name = "Subtitle"
			sub.Position = UDim2.fromOffset(0, 24)
			sub.Size = UDim2.new(1, 0, 0, 14)
			sub.BackgroundTransparency = 1
			sub.Text = config.subtitle
			sub.TextColor3 = Colors.TextSecondary
			sub.TextXAlignment = Enum.TextXAlignment.Left
			sub.ZIndex = z + 2
			Typography.apply(sub, "bodySm")
			sub.Parent = titleFrame
			titleFrame.Size = UDim2.new(1, 0, 0, 44)
		end

		if config.closable then
			local closeBtn = Instance.new("TextButton")
			closeBtn.Name = "Close"
			closeBtn.Size = UDim2.fromOffset(28, 28)
			closeBtn.Position = UDim2.new(1, 0, 0, 0)
			closeBtn.AnchorPoint = Vector2.new(1, 0)
			closeBtn.BackgroundTransparency = 1
			closeBtn.AutoButtonColor = false
			closeBtn.Text = ""
			closeBtn.ZIndex = z + 2
			closeBtn.Parent = titleFrame
			local x = DesignSystem.Icons.create("Close", 20, Colors.Accent)
			x.AnchorPoint = Vector2.new(0.5, 0.5)
			x.Position = UDim2.fromScale(0.5, 0.5)
			x.ZIndex = z + 3
			x.Parent = closeBtn
			closeBtn.MouseEnter:Connect(function()
				x.ImageColor3 = Colors.AccentHover
			end)
			closeBtn.MouseLeave:Connect(function()
				x.ImageColor3 = Colors.Accent
			end)
			if config.onClose then
				closeBtn.MouseButton1Click:Connect(config.onClose)
			end
		end
	end

	if config.children then
		for i, child in ipairs(config.children) do
			child.LayoutOrder = i + 1
			child.Parent = content
		end
	end

	if config.parent then
		panel.Parent = config.parent
	end
	return panel, content
end

return Panel
