local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Animations = DesignSystem.Animations
local Responsive = DesignSystem.Responsive
local Icons = DesignSystem.Icons
local Shells = DesignSystem.Shells

local HeroButton = {}

-- A large HUD "hero" button for the redesigned CountryBar: an optional icon, a big value, a small caption,
-- and an optional coloured delta line, stacked and centred, with four gold corner-bracket adornments.
--
-- Style: the BODY is procedural (Frame + UIStroke, NO UICorner) exactly like Components/Button.luau -- correct
-- on frame 0 with no texture to decode, so it never flashes the 9-slice inset-border artefact and it honours the
-- project's sharp-corner-buttons rule. The ONLY images are the corner brackets, which are single fit-mode sprites
-- (no SliceCenter), so they carry no 9-slice load race either. Preloaded at boot via Shells.preload.
--
-- config = {
--   parent, zIndex, layoutOrder, size (UDim2, default 150x72),
--   icon (icon key), iconSize (default 30),
--   value (big text), caption (small caps label), delta (small line), deltaColor (Color3),
--   onClick (fn), active (bool),
-- }
-- returns { root, setValue, setCaption, setDelta, setActive }

local CORNER = 18 -- corner-bracket sprite size (px, at the 900-canvas scale)
local CORNER_INSET = 1 -- near-flush so the bracket hugs the corner (a UIStroke never shifts children; the gap was inset)

local STYLE = {
	fill = Colors.SurfaceElevated,
	stroke = Colors.BorderStrong,
	hover = { fill = Colors.SurfaceOverlay, stroke = Colors.BorderActive },
	active = { stroke = Colors.Accent }, -- selected screen -> gold border, keep fill
}

function HeroButton.create(config)
	config = config or {}
	local z = config.zIndex or 1

	local btn = Instance.new("TextButton")
	btn.Name = "HeroButton"
	btn.Size = config.size or UDim2.fromOffset(150, 72)
	btn.AutomaticSize = Enum.AutomaticSize.None
	btn.BackgroundTransparency = 1
	btn.AutoButtonColor = false
	btn.Text = ""
	btn.ZIndex = z + 4
	btn.LayoutOrder = config.layoutOrder or 0
	btn:SetAttribute("AoWInputSink", true)
	-- Optional per-button click sound (UISound.attachButton reads AoWClickSound on click).
	if config.clickSound then
		btn:SetAttribute("AoWClickSound", config.clickSound)
	end

	-- Procedural body (no UICorner). Correct on the first frame, no texture race.
	local bg = Instance.new("Frame")
	bg.Name = "Bg"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = STYLE.fill
	bg.BorderSizePixel = 0
	bg.ZIndex = btn.ZIndex - 2
	bg.Parent = btn

	local stroke = Instance.new("UIStroke")
	stroke.Color = STYLE.stroke
	stroke.Thickness = 1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = bg

	-- Subtle vertical depth (a vector tint, no texture).
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(224, 224, 224)),
	})
	grad.Parent = bg

	-- Four gold corner brackets. Each corner_* shell is a single fit-mode sprite (aspect-locked square), so
	-- setting a fixed px Size keeps it square; no SliceCenter -> no 9-slice decode race.
	local corners = {
		{ "corner_tl", Vector2.new(0, 0), UDim2.fromOffset(CORNER_INSET, CORNER_INSET) },
		{ "corner_tr", Vector2.new(1, 0), UDim2.new(1, -CORNER_INSET, 0, CORNER_INSET) },
		{ "corner_bl", Vector2.new(0, 1), UDim2.new(0, CORNER_INSET, 1, -CORNER_INSET) },
		{ "corner_br", Vector2.new(1, 1), UDim2.new(1, -CORNER_INSET, 1, -CORNER_INSET) },
	}
	for _, c in corners do
		local img = Shells.create(c[1])
		img.Name = c[1]
		img.Size = UDim2.fromOffset(CORNER, CORNER)
		img.AnchorPoint = c[2]
		img.Position = c[3]
		img.ZIndex = btn.ZIndex - 1
		img.Parent = btn
	end

	-- Content: normally a centred VERTICAL stack (icon on top, then value/delta/caption). With
	-- iconPosition == "left" it becomes a centred HORIZONTAL group -- a leading icon beside a vertical text
	-- stack -- so a money/army icon sits to the left of the value while the whole group stays centred.
	local leading = config.iconPosition == "left" and config.icon ~= nil

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.fromScale(1, 1)
	content.BackgroundTransparency = 1
	content.ZIndex = btn.ZIndex
	content.Parent = btn
	local cpad = Instance.new("UIPadding")
	cpad.PaddingLeft = UDim.new(0, 8)
	cpad.PaddingRight = UDim.new(0, 8)
	cpad.PaddingTop = UDim.new(0, 6)
	cpad.PaddingBottom = UDim.new(0, 6)
	cpad.Parent = content
	local list = Instance.new("UIListLayout")
	list.FillDirection = leading and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, leading and 8 or 2)
	list.Parent = content

	-- In leading mode the value/caption go in their own vertical stack to the RIGHT of the icon; otherwise
	-- they stack directly in `content` (below a top icon, if any).
	local textParent = content
	if leading then
		local stack = Instance.new("Frame")
		stack.Name = "TextStack"
		stack.AutomaticSize = Enum.AutomaticSize.XY
		stack.Size = UDim2.fromOffset(0, 0)
		stack.BackgroundTransparency = 1
		stack.LayoutOrder = 2
		stack.ZIndex = content.ZIndex
		stack.Parent = content
		local sl = Instance.new("UIListLayout")
		sl.FillDirection = Enum.FillDirection.Vertical
		sl.HorizontalAlignment = Enum.HorizontalAlignment.Center
		sl.VerticalAlignment = Enum.VerticalAlignment.Center
		sl.SortOrder = Enum.SortOrder.LayoutOrder
		sl.Padding = UDim.new(0, 2)
		sl.Parent = stack
		textParent = stack
	end

	local function mkLabel(role, color, order, str)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Text = str or ""
		l.TextColor3 = color
		l.TextXAlignment = Enum.TextXAlignment.Center
		l.TextYAlignment = Enum.TextYAlignment.Center
		l.TextTruncate = Enum.TextTruncate.AtEnd
		l.AutomaticSize = Enum.AutomaticSize.XY
		l.Size = UDim2.fromOffset(0, 0)
		l.LayoutOrder = order
		l.ZIndex = content.ZIndex
		Typography.apply(l, role)
		l.Parent = textParent
		return l
	end

	local iconImg
	if config.icon then
		iconImg = Icons.create(config.icon, config.iconSize or (leading and 28 or 30), Colors.TextPrimary)
		iconImg.LayoutOrder = 1
		iconImg.ZIndex = content.ZIndex
		iconImg.Parent = content
	end

	local valueLabel = config.value ~= nil and mkLabel("title", Colors.TextPrimary, 2, config.value) or nil
	local deltaLabel = config.delta ~= nil and mkLabel("caption", config.deltaColor or Colors.TextSecondary, 3, config.delta)
		or nil
	local captionLabel = config.caption ~= nil
			and mkLabel("caption", Colors.TextSecondary, 4, string.upper(config.caption))
		or nil

	-- State: disabled/active/hover, resolved like Components/Button.applyState (property tweens, no textures).
	local hovering = false
	local isActive = config.active == true
	local function applyState(animated)
		local s = (isActive and STYLE.active) or (hovering and STYLE.hover) or {}
		local fillColor = s.fill or STYLE.fill
		local strokeColor = s.stroke or STYLE.stroke
		if animated then
			Animations.tween(bg, Animations.Fast, { BackgroundColor3 = fillColor })
			Animations.tween(stroke, Animations.Fast, { Color = strokeColor })
		else
			bg.BackgroundColor3 = fillColor
			stroke.Color = strokeColor
		end
	end
	applyState(false)

	if not Responsive.isTouch() then
		btn.MouseEnter:Connect(function()
			hovering = true
			applyState(true)
		end)
		btn.MouseLeave:Connect(function()
			hovering = false
			applyState(true)
		end)
	end

	if config.onClick then
		btn.MouseButton1Click:Connect(config.onClick)
	end

	if config.parent then
		btn.Parent = config.parent
	end

	return {
		root = btn,
		setValue = function(str)
			if valueLabel then
				valueLabel.Text = str or ""
			end
		end,
		setCaption = function(str)
			if captionLabel then
				captionLabel.Text = string.upper(str or "")
			end
		end,
		setDelta = function(str, color)
			if deltaLabel then
				deltaLabel.Text = str or ""
				if color then
					deltaLabel.TextColor3 = color
				end
			end
		end,
		setActive = function(on)
			isActive = on and true or false
			applyState(true)
		end,
	}
end

return HeroButton
