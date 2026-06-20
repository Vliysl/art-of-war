local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Spacing = DesignSystem.Spacing
local Animations = DesignSystem.Animations
local Icons = DesignSystem.Icons
local Shells = DesignSystem.Shells

local NotificationCard = {}

local SEVERITY = {
	info = { color = Colors.Accent, icon = "Info" },
	success = { color = Colors.Positive, icon = "Check" },
	warning = { color = Colors.Warning, icon = "Warning" },
	danger = { color = Colors.Negative, icon = "Unrest" },
}

function NotificationCard.create(config)
	config = config or {}
	local sev = SEVERITY[config.severity or "info"] or SEVERITY.info
	local z = config.zIndex or 40

	local root = Shells.create("notification_shell", {
		Name = "Notification",
		Size = UDim2.fromOffset(config.width or 330, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		ZIndex = z,
	})

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Spacing.space3)
	pad.PaddingBottom = UDim.new(0, Spacing.space3)
	pad.PaddingLeft = UDim.new(0, Spacing.space3)
	pad.PaddingRight = UDim.new(0, Spacing.space3)
	pad.Parent = root

	local accent = Instance.new("Frame")
	accent.Name = "Accent"
	accent.Size = UDim2.new(0, 3, 1, 0)
	accent.Position = UDim2.fromOffset(-Spacing.space3 + 2, 0)
	accent.BackgroundColor3 = sev.color
	accent.BorderSizePixel = 0
	accent.ZIndex = z + 1
	accent.Parent = root

	local icon = Icons.create(config.icon or sev.icon, 20, sev.color)
	icon.AnchorPoint = Vector2.new(0, 0)
	icon.Position = UDim2.fromOffset(4, 2)
	icon.ZIndex = z + 1
	icon.Parent = root

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Position = UDim2.fromOffset(32, 0)
	body.Size = UDim2.new(1, -56, 0, 0)
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.BackgroundTransparency = 1
	body.ZIndex = z + 1
	body.Parent = root
	local bLayout = Instance.new("UIListLayout")
	bLayout.FillDirection = Enum.FillDirection.Vertical
	bLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bLayout.Padding = UDim.new(0, 2)
	bLayout.Parent = body

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AutomaticSize = Enum.AutomaticSize.Y
	title.Size = UDim2.new(1, 0, 0, 0)
	title.BackgroundTransparency = 1
	title.Text = config.title or ""
	title.TextColor3 = Colors.TextPrimary
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextWrapped = true
	title.LayoutOrder = 1
	title.ZIndex = z + 1
	Typography.apply(title, "label")
	title.Parent = body

	if config.body then
		local msg = Instance.new("TextLabel")
		msg.Name = "Message"
		msg.AutomaticSize = Enum.AutomaticSize.Y
		msg.Size = UDim2.new(1, 0, 0, 0)
		msg.BackgroundTransparency = 1
		msg.Text = config.body
		msg.TextColor3 = Colors.TextSecondary
		msg.TextXAlignment = Enum.TextXAlignment.Left
		msg.TextWrapped = true
		msg.LayoutOrder = 2
		msg.ZIndex = z + 1
		Typography.apply(msg, "bodySm")
		msg.Parent = body
	end

	local dismissed = false
	local function dismiss()
		if dismissed then
			return
		end
		dismissed = true
		Animations.tween(root, Animations.Default, { ImageTransparency = 1 })
		for _, d in root:GetDescendants() do
			if d:IsA("TextLabel") then
				Animations.tween(d, Animations.Default, { TextTransparency = 1 })
			elseif d:IsA("ImageLabel") then
				Animations.tween(d, Animations.Default, { ImageTransparency = 1 })
			elseif d:IsA("Frame") then
				Animations.tween(d, Animations.Default, { BackgroundTransparency = 1 })
			end
		end
		task.delay(Animations.Default.Time + 0.05, function()
			if config.onDismiss then
				config.onDismiss()
			end
			root:Destroy()
		end)
	end

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "Close"
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.fromScale(1, 0)
	closeBtn.Size = UDim2.fromOffset(20, 20)
	closeBtn.BackgroundTransparency = 1
	closeBtn.AutoButtonColor = false
	closeBtn.Text = ""
	closeBtn.ZIndex = z + 2
	closeBtn.Parent = root
	local x = Icons.create("Close", 14, Colors.TextTertiary)
	x.AnchorPoint = Vector2.new(0.5, 0.5)
	x.Position = UDim2.fromScale(0.5, 0.5)
	x.ZIndex = z + 2
	x.Parent = closeBtn
	closeBtn.MouseButton1Click:Connect(dismiss)
	closeBtn.MouseEnter:Connect(function()
		x.ImageColor3 = Colors.TextPrimary
	end)
	closeBtn.MouseLeave:Connect(function()
		x.ImageColor3 = Colors.TextTertiary
	end)

	if config.ttl and config.ttl > 0 then
		task.delay(config.ttl, dismiss)
	end

	if config.parent then
		root.Parent = config.parent
	end
	return { root = root, dismiss = dismiss }
end

return NotificationCard
