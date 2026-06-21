local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Animations = DesignSystem.Animations
local Responsive = DesignSystem.Responsive

local Button = {}

local CORNER = 6

-- Buttons render their surface PROCEDURALLY (a Frame + UICorner + UIStroke + UIGradient) instead of
-- 9-slice image shells. A 9-slice can't map its pixel-space SliceCenter until the texture decodes, so
-- the gold border rendered inset/overflowing intermittently (asset-cache/timing dependent -- correct
-- on the first play, wrong on the second). A vector surface is correct on frame 0, every time, with no
-- texture to download. Each variant is a fill/stroke/text colour plus hover + disabled deltas; state
-- changes are property tweens, not asset swaps.
local VARIANTS = {
	primary = {
		fill = Colors.Accent,
		stroke = Colors.AccentHover,
		text = Colors.SurfaceBase,
		hover = { fill = Colors.AccentHover, stroke = Colors.AccentHover },
		disabled = { fill = Colors.SurfaceSunken, stroke = Colors.BorderSubtle, text = Colors.TextSecondary },
	},
	secondary = {
		fill = Colors.SurfaceElevated,
		stroke = Colors.BorderStrong,
		text = Colors.TextPrimary,
		hover = { fill = Colors.SurfaceOverlay, stroke = Colors.BorderActive },
		disabled = { fill = Colors.SurfaceSunken, stroke = Colors.BorderSubtle, text = Colors.TextSecondary },
	},
	ghost = {
		fill = Colors.SurfaceBase,
		fillT = 1,
		stroke = Colors.BorderSubtle,
		text = Colors.TextSecondary,
		hover = { fillT = 0, fill = Colors.SurfaceElevated, stroke = Colors.BorderStrong, text = Colors.TextPrimary },
		disabled = { fillT = 1, stroke = Colors.BorderSubtle, strokeT = 0.4, text = Colors.TextSecondary },
	},
	danger = {
		fill = Colors.Negative,
		stroke = Colors.Negative,
		text = Colors.TextPrimary,
		hover = { fill = Color3.fromRGB(214, 92, 87), stroke = Color3.fromRGB(214, 92, 87) },
		disabled = { fill = Colors.NegativeSubtle, stroke = Colors.NegativeSubtle, text = Colors.TextSecondary },
	},
	success = {
		fill = Colors.Positive,
		stroke = Colors.Positive,
		text = Colors.TextPrimary,
		hover = { fill = Color3.fromRGB(109, 161, 124), stroke = Color3.fromRGB(109, 161, 124) },
		disabled = { fill = Colors.PositiveSubtle, stroke = Colors.PositiveSubtle, text = Colors.TextSecondary },
	},
}

local SIZE_HEIGHT = { sm = 30, md = 38, lg = 46 }

function Button.create(config)
	config = config or {}
	local variant = config.variant or "secondary"
	local style = VARIANTS[variant] or VARIANTS.secondary
	local height = Responsive.tapHeight(SIZE_HEIGHT[config.size or "md"] or 38)
	local z = config.zIndex or 1

	-- Three sizing modes:
	--   fill   -> stretches to the parent width (centered label)
	--   width  -> fixed pixel width (centered label, truncates if too long)
	--   else   -> hugs its text and grows with it (the structural default; never clips)
	local fill = config.fill == true
	local fixedW = (not fill) and config.width or nil
	local sized = fill or fixedW ~= nil

	local btn = Instance.new("TextButton")
	btn.Name = "Button"
	btn.AutomaticSize = sized and Enum.AutomaticSize.None or Enum.AutomaticSize.X
	btn.Size = fill and UDim2.new(1, 0, 0, height) or UDim2.new(0, fixedW or 0, 0, height)
	btn.BackgroundTransparency = 1
	btn.AutoButtonColor = false
	btn.Text = ""
	btn.ZIndex = z + 4
	btn.LayoutOrder = config.layoutOrder or 0

	local bgZ = btn.ZIndex - 2
	local bg = Instance.new("Frame")
	bg.Name = "Bg"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = style.fill
	bg.BackgroundTransparency = style.fillT or 0
	bg.BorderSizePixel = 0
	bg.ZIndex = bgZ
	bg.Parent = btn

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, CORNER)
	corner.Parent = bg

	local stroke = Instance.new("UIStroke")
	stroke.Color = style.stroke
	stroke.Thickness = 1
	stroke.Transparency = style.strokeT or 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = bg

	-- Subtle vertical depth on filled variants (ghost has no fill to shade). A gradient is a vector
	-- tint, so unlike the old 9-slice art it carries no texture-load race.
	if (style.fillT or 0) < 1 then
		local grad = Instance.new("UIGradient")
		grad.Rotation = 90
		grad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(225, 225, 225)),
		})
		grad.Parent = bg
	end

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.AutomaticSize = sized and Enum.AutomaticSize.None or Enum.AutomaticSize.X
	label.Size = sized and UDim2.fromScale(1, 1) or UDim2.new(0, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = config.text or "Button"
	label.TextColor3 = style.text
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.ZIndex = btn.ZIndex
	Typography.apply(label, "label")
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Parent = btn

	local lpad = Instance.new("UIPadding")
	lpad.PaddingLeft = UDim.new(0, 18)
	lpad.PaddingRight = UDim.new(0, 18)
	lpad.Parent = label

	local hovering = false

	-- Resolve the visual for the current state (disabled > hover > default) and either snap or tween
	-- the surface properties. No textures, so the border is correct on the very first frame.
	local function applyState(animated)
		local off = btn.Active == false
		local s = (off and (style.disabled or {})) or (hovering and (style.hover or {})) or {}
		local fillColor = s.fill or style.fill
		local fillT = s.fillT ~= nil and s.fillT or (style.fillT or 0)
		local strokeColor = s.stroke or style.stroke
		local strokeT = s.strokeT ~= nil and s.strokeT or (style.strokeT or 0)
		local textColor = s.text or style.text
		local textT = off and 0.45 or 0
		if animated then
			Animations.tween(bg, Animations.Fast, { BackgroundColor3 = fillColor, BackgroundTransparency = fillT })
			Animations.tween(stroke, Animations.Fast, { Color = strokeColor, Transparency = strokeT })
			Animations.tween(label, Animations.Fast, { TextColor3 = textColor, TextTransparency = textT })
		else
			bg.BackgroundColor3 = fillColor
			bg.BackgroundTransparency = fillT
			stroke.Color = strokeColor
			stroke.Transparency = strokeT
			label.TextColor3 = textColor
			label.TextTransparency = textT
		end
	end

	local function refreshDisabled()
		if btn.Active == false then
			hovering = false
		end
		applyState(false)
	end
	btn:GetPropertyChangedSignal("Active"):Connect(refreshDisabled)
	if config.disabled then
		btn.Active = false
	end
	applyState(false)

	if not Responsive.isTouch() then
		btn.MouseEnter:Connect(function()
			if btn.Active ~= false then
				hovering = true
				applyState(true)
			end
		end)
		btn.MouseLeave:Connect(function()
			if btn.Active ~= false then
				hovering = false
				applyState(true)
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
