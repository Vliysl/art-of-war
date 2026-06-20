local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Animations = DesignSystem.Animations
local Shells = DesignSystem.Shells
local Responsive = DesignSystem.Responsive

local Button = {}

local TEXT_COLOR = {
	primary = Colors.SurfaceBase,
	secondary = Colors.TextPrimary,
	ghost = Colors.TextSecondary,
	success = Colors.TextPrimary,
	danger = Colors.TextPrimary,
}

local SIZE_HEIGHT = { sm = 30, md = 38, lg = 46 }

function Button.create(config)
	config = config or {}
	local variant = config.variant or "secondary"
	local height = Responsive.tapHeight(SIZE_HEIGHT[config.size or "md"] or 38)
	local z = config.zIndex or 1

	local btn = Instance.new("TextButton")
	btn.Name = "Button"
	btn.AutomaticSize = config.width and Enum.AutomaticSize.None or Enum.AutomaticSize.X
	btn.Size = UDim2.new(0, config.width or 0, 0, height)
	btn.BackgroundTransparency = 1
	btn.AutoButtonColor = false
	btn.Text = ""
	btn.ZIndex = z + 4
	btn.LayoutOrder = config.layoutOrder or 0

	local bgZ = btn.ZIndex - 2
	local bgDefault = Shells.create("button_" .. variant .. "_default", { ZIndex = bgZ })
	bgDefault.Name = "BgDefault"
	bgDefault.Parent = btn
	local bgHover = Shells.create("button_" .. variant .. "_hover", { ZIndex = bgZ, ImageTransparency = 1 })
	bgHover.Name = "BgHover"
	bgHover.Parent = btn
	local bgDisabled = Shells.create("button_" .. variant .. "_disabled", { ZIndex = bgZ + 1, ImageTransparency = 1 })
	bgDisabled.Name = "BgDisabled"
	bgDisabled.Parent = btn

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.AutomaticSize = config.width and Enum.AutomaticSize.None or Enum.AutomaticSize.X
	label.Size = config.width and UDim2.fromScale(1, 1) or UDim2.new(0, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = config.text or "Button"
	label.TextColor3 = TEXT_COLOR[variant] or Colors.TextPrimary
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.ZIndex = btn.ZIndex
	Typography.apply(label, "label")
	label.Parent = btn

	local lpad = Instance.new("UIPadding")
	lpad.PaddingLeft = UDim.new(0, 18)
	lpad.PaddingRight = UDim.new(0, 18)
	lpad.Parent = label

	local function refreshDisabled()
		local off = btn.Active == false
		bgDisabled.ImageTransparency = off and 0 or 1
		bgDefault.ImageTransparency = off and 1 or 0
		label.TextTransparency = off and 0.45 or 0
		if off then
			bgHover.ImageTransparency = 1
		end
	end
	btn:GetPropertyChangedSignal("Active"):Connect(refreshDisabled)
	if config.disabled then
		btn.Active = false
	end
	refreshDisabled()

	if not Responsive.isTouch() then
		btn.MouseEnter:Connect(function()
			if btn.Active ~= false then
				Animations.tween(bgHover, Animations.Fast, { ImageTransparency = 0 })
			end
		end)
		btn.MouseLeave:Connect(function()
			if btn.Active ~= false then
				Animations.tween(bgHover, Animations.Fast, { ImageTransparency = 1 })
			end
		end)
	end
	if config.onClick then
		btn.MouseButton1Click:Connect(function()
			if btn.Active ~= false then
				config.onClick()
			end
		end)
	end

	if config.parent then
		btn.Parent = config.parent
	end
	return btn
end

return Button
