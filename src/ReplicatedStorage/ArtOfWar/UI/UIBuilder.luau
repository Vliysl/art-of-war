local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local UIStyle = require(script.Parent:WaitForChild("UIStyle"))
local UIAssets = require(script.Parent:WaitForChild("UIAssets"))
local Platform = require(script.Parent.Parent:WaitForChild("Modules"):WaitForChild("Platform"))
-- UIRoot only used by UIBuilder.tooltip; safe to require eagerly.
local UIRoot = nil
local function getUIRoot() if not UIRoot then UIRoot = require(script.Parent:WaitForChild("UIRoot")) end; return UIRoot end
local UISound = require(script.Parent:WaitForChild("UISound"))

local UIBuilder = {}

local function apply(obj, props)
	if not props then return end
	for key, value in props do
		obj[key] = value
	end
end

local function newStroke(parent, thickness, color)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = thickness or 1
	stroke.Color = color or UIStyle.Color.Border
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
	return stroke
end

local function newCorner(parent, radius)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
	return corner
end

local function newPadding(parent, top, right, bottom, left)
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, top)
	padding.PaddingRight = UDim.new(0, right or top)
	padding.PaddingBottom = UDim.new(0, bottom or top)
	padding.PaddingLeft = UDim.new(0, left or right or top)
	padding.Parent = parent
	return padding
end

local function addPanelTrim(parent)
	local z = (parent.ZIndex or UIStyle.Z.Panel) + 1
	local top = Instance.new("Frame")
	top.Name = "TopTrim"
	top.Size = UDim2.new(1, -18, 0, 1)
	top.Position = UDim2.fromOffset(9, 1)
	top.BackgroundColor3 = UIStyle.Color.BorderStrong
	top.BackgroundTransparency = 0.55
	top.BorderSizePixel = 0
	top.ZIndex = z
	top.Parent = parent

	local bottom = top:Clone()
	bottom.Name = "BottomTrim"
	bottom.Position = UDim2.new(0, 9, 1, -2)
	bottom.Parent = parent
end

-- PANEL: dark solid, gold hairline stroke, subtle top highlight
function UIBuilder.panel(parent, props)
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = UIStyle.Color.Panel
	frame.BackgroundTransparency = 0
	frame.BorderSizePixel = 0
	frame.ZIndex = UIStyle.Z.Panel
	frame:SetAttribute("AoWInputSink", true)
	frame.Parent = parent
	newStroke(frame, UIStyle.Size.StrokeFrame, UIStyle.Color.Border)
	newCorner(frame, UIStyle.Size.CornerPanel)
	apply(frame, props)

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, UIStyle.Color.PanelHigh),
		ColorSequenceKeypoint.new(0.55, UIStyle.Color.Panel),
		ColorSequenceKeypoint.new(1, UIStyle.Color.PanelAlt),
	})
	gradient.Rotation = 90
	gradient.Parent = frame
	addPanelTrim(frame)

	return frame
end

function UIBuilder.sectionHeader(parent, title, yOffset)
	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(1, 0, 0, UIStyle.Size.SectionHeaderH)
	bar.Position = UDim2.fromOffset(0, yOffset or 0)
	bar.BackgroundColor3 = UIStyle.Color.PanelHeader
	bar.BorderSizePixel = 0
	bar.ZIndex = UIStyle.Z.PanelHeader
	bar.Parent = parent

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, UIStyle.Color.Bg),
		ColorSequenceKeypoint.new(0.5, UIStyle.Color.PanelAlt),
		ColorSequenceKeypoint.new(1, UIStyle.Color.Bg),
	})
	gradient.Rotation = 0
	gradient.Parent = bar

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -24, 1, 0)
	label.Position = UDim2.fromOffset(14, 0)
	label.BackgroundTransparency = 1
	label.Text = string.upper(title or "")
	label.TextColor3 = UIStyle.Color.LedgerSection
	label.FontFace = UIStyle.FontFace.Cinzel
	label.TextSize = 11
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.ZIndex = UIStyle.Z.PanelHeader + 1
	label.Parent = bar

	local trim = Instance.new("Frame")
	trim.Size = UDim2.new(1, -20, 0, UIStyle.Size.DividerH)
	trim.Position = UDim2.new(0, 10, 1, 0)
	trim.AnchorPoint = Vector2.new(0, 1)
	trim.BackgroundColor3 = UIStyle.Color.BorderStrong
	trim.BackgroundTransparency = 0.45
	trim.BorderSizePixel = 0
	trim.ZIndex = UIStyle.Z.PanelHeader + 1
	trim.Parent = bar

	return bar
end

-- STAT ROW
function UIBuilder.statRow(parent, yOffset, iconText, label, value, valueColor)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, UIStyle.Size.StatRowH)
	row.Position = UDim2.fromOffset(0, yOffset or 0)
	row.BackgroundTransparency = 1
	row.ZIndex = UIStyle.Z.Content
	row.Parent = parent

	local icon = Instance.new("TextLabel")
	icon.Size = UDim2.fromOffset(20, UIStyle.Size.StatRowH)
	icon.Position = UDim2.fromOffset(0, 0)
	icon.BackgroundTransparency = 1
	icon.Text = iconText or ""
	icon.TextColor3 = UIStyle.Color.Gold
	icon.TextXAlignment = Enum.TextXAlignment.Left
	icon.TextYAlignment = Enum.TextYAlignment.Center
	icon.ZIndex = UIStyle.Z.Content
	UIStyle.applyType(icon, UIStyle.Type.StatValue)
	icon.Parent = row

	local labelObj = Instance.new("TextLabel")
	labelObj.Size = UDim2.new(0.55, -24, 1, 0)
	labelObj.Position = UDim2.fromOffset(24, 0)
	labelObj.BackgroundTransparency = 1
	labelObj.Text = label
	labelObj.TextColor3 = UIStyle.Color.TextMuted
	labelObj.TextXAlignment = Enum.TextXAlignment.Left
	labelObj.TextYAlignment = Enum.TextYAlignment.Center
	labelObj.ZIndex = UIStyle.Z.Content
	UIStyle.applyType(labelObj, UIStyle.Type.StatLabel)
	labelObj.Parent = row

	local valueObj = Instance.new("TextLabel")
	valueObj.Size = UDim2.new(0.45, 0, 1, 0)
	valueObj.Position = UDim2.new(1, 0, 0, 0)
	valueObj.AnchorPoint = Vector2.new(1, 0)
	valueObj.BackgroundTransparency = 1
	valueObj.Text = value or ""
	valueObj.TextColor3 = valueColor or UIStyle.Color.Text
	valueObj.TextXAlignment = Enum.TextXAlignment.Right
	valueObj.TextYAlignment = Enum.TextYAlignment.Center
	valueObj.ZIndex = UIStyle.Z.Content
	UIStyle.applyType(valueObj, UIStyle.Type.StatValue)
	valueObj.Parent = row

	return { row = row, icon = icon, label = labelObj, value = valueObj }
end

function UIBuilder.divider(parent, yOffset)
	local line = Instance.new("Frame")
	line.Size = UDim2.new(1, 0, 0, UIStyle.Size.DividerH)
	line.Position = UDim2.fromOffset(0, yOffset or 0)
	line.BackgroundColor3 = UIStyle.Color.Border
	line.BorderSizePixel = 0
	line.BackgroundTransparency = 0.5
	line.ZIndex = UIStyle.Z.Content
	line.Parent = parent
	return line
end

-- BUTTON
function UIBuilder.button(parent, props, primary)
	local btn = Instance.new("TextButton")
	local baseBg = primary and UIStyle.Color.PanelHigh or UIStyle.Color.PanelAlt
	local baseStroke = primary and UIStyle.Color.GoldBright or UIStyle.Color.Gold
	local baseText = primary and UIStyle.Color.GoldBright or UIStyle.Color.SecondaryDefault
	btn.BackgroundColor3 = baseBg
	btn.BackgroundTransparency = 0
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = false
	btn.TextColor3 = baseText
	btn.TextStrokeColor3 = UIStyle.Color.Bg
	btn.TextStrokeTransparency = 0.85
	btn.ZIndex = UIStyle.Z.Content
	UIStyle.applyType(btn, primary and UIStyle.Type.ButtonPrimary or UIStyle.Type.Button)
	btn.FontFace = UIStyle.FontFace.Cinzel
	btn.Parent = parent

	local stroke = newStroke(btn, 1, baseStroke)
	newCorner(btn, UIStyle.Size.CornerButton)
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, primary and UIStyle.Color.PanelHigh or UIStyle.Color.PanelHigh),
		ColorSequenceKeypoint.new(1, primary and UIStyle.Color.PanelAlt or UIStyle.Color.Panel),
	})
	gradient.Rotation = 90
	gradient.Parent = btn
	apply(btn, props)

	local function setVisual(bg, strokeColor, textColor)
		btn.BackgroundColor3 = bg
		stroke.Color = strokeColor
		btn.TextColor3 = textColor
	end

	if not Platform.isTouch then
		btn.MouseEnter:Connect(function()
			if btn.Active == false then return end
			if primary then
				setVisual(UIStyle.Color.PanelHigh, UIStyle.Color.GoldBright, UIStyle.Color.GoldBright)
			else
				setVisual(UIStyle.Color.PanelHigh, UIStyle.Color.GoldBright, UIStyle.Color.SecondaryHover)
			end
		end)
		btn.MouseLeave:Connect(function()
			setVisual(baseBg, baseStroke, baseText)
		end)
	end

	return btn
end

-- SHIELD (legacy) / CREST
local function buildCrest(parent, countryColor, tag, size)
	local px = size or UIStyle.Size.CrestSize
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(px, px)
	frame.BackgroundTransparency = 1
	frame.ZIndex = UIStyle.Z.Accent
	frame.Parent = parent

	local body = Instance.new("Frame")
	body.Size = UDim2.fromScale(1, 1)
	body.Position = UDim2.fromScale(0, 0)
	body.BackgroundColor3 = countryColor or UIStyle.Color.PanelAlt
	body.BorderSizePixel = 0
	body.ZIndex = UIStyle.Z.Accent
	body.Parent = frame
	newCorner(body, math.floor(px * 0.18))
	newStroke(body, 1, UIStyle.Color.Gold)

	local gloss = Instance.new("UIGradient")
	gloss.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
		ColorSequenceKeypoint.new(1, Color3.new(0, 0, 0)),
	})
	gloss.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.7),
		NumberSequenceKeypoint.new(0.5, 0.9),
		NumberSequenceKeypoint.new(1, 0.6),
	})
	gloss.Rotation = 90
	gloss.Parent = body

	if tag then
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = tag
		label.TextColor3 = UIStyle.Color.Text
		label.TextStrokeTransparency = 0.2
		label.TextStrokeColor3 = UIStyle.Color.Bg
		label.Font = UIStyle.Font.Bold
		label.TextSize = math.floor(px * 0.42)
		label.ZIndex = UIStyle.Z.Accent + 1
		label.Parent = frame
	end

	return frame
end

local function stripSize(props)
	if not props then return nil end
	local out = {}
	for k, v in props do
		if k ~= "size" then out[k] = v end
	end
	return out
end

function UIBuilder.crest(parent, countryColor, tag, props)
	local size = props and props.size
	local flag = props and props.flag
	if flag and flag ~= "" then
		local px = size or UIStyle.Size.ShieldH or 48
		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromOffset(px, px)
		frame.BackgroundTransparency = 1
		frame.ZIndex = UIStyle.Z.Accent
		frame.Parent = parent
		local img = Instance.new("ImageLabel")
		img.Size = UDim2.fromScale(1, 1)
		img.BackgroundColor3 = countryColor or UIStyle.Color.PanelAlt
		img.BorderSizePixel = 0
		img.Image = flag
		img.ScaleType = Enum.ScaleType.Fit
		img.ZIndex = UIStyle.Z.Accent
		img.Parent = frame
		newCorner(img, math.floor(px * 0.18))
		newStroke(img, 1, UIStyle.Color.Gold)
		apply(frame, stripSize(props))
		return frame
	end
	local f = buildCrest(parent, countryColor, tag, size)
	apply(f, stripSize(props))
	return f
end

-- Legacy shield wrapper
function UIBuilder.shield(parent, countryColor, tag, props)
	local f = buildCrest(parent, countryColor, tag, (props and props.size) or UIStyle.Size.ShieldH)
	apply(f, stripSize(props))
	return f
end

-- LABEL
function UIBuilder.label(parent, text, typeToken, color, props)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Text = text or ""
	label.TextColor3 = color or UIStyle.Color.Text
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.ZIndex = UIStyle.Z.Content
	UIStyle.applyType(label, typeToken or UIStyle.Type.Body)
	label.Parent = parent
	apply(label, props)
	return label
end

-- SCROLLING LIST
function UIBuilder.scrollingList(parent, props)
	local frame = Instance.new("ScrollingFrame")
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.CanvasSize = UDim2.new()
	frame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	frame.ScrollBarThickness = 6
	frame.ScrollBarImageColor3 = UIStyle.Color.Gold
	frame.ScrollBarImageTransparency = 0.3
	frame.ZIndex = UIStyle.Z.Content
	frame.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame

	apply(frame, props)
	return frame, layout
end

-- ICON: ImageLabel with rbxassetid or ASCII fallback
function UIBuilder.icon(parent, iconKey, size, props)
	local px = size or 16
	local assetId = UIStyle.Icon[iconKey]
	local colorHint = nil
	local cleaned = nil
	if props then
		cleaned = {}
		for k, v in props do
			if k == "ImageColor3" or k == "color" then
				colorHint = v
			else
				cleaned[k] = v
			end
		end
	end
	if assetId and assetId ~= "" then
		local img = Instance.new("ImageLabel")
		img.Size = UDim2.fromOffset(px, px)
		img.BackgroundTransparency = 1
		img.Image = assetId
		img.ImageColor3 = colorHint or UIStyle.Color.Gold
		img.ZIndex = UIStyle.Z.Content
		img.Parent = parent
		apply(img, cleaned)
		return img
	else
		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.fromOffset(px, px)
		lbl.BackgroundTransparency = 1
		lbl.Text = UIStyle.IconFallback[iconKey] or "?"
		lbl.TextColor3 = colorHint or UIStyle.Color.Gold
		lbl.Font = UIStyle.Font.Bold
		lbl.TextSize = math.floor(px * 0.7)
		lbl.TextXAlignment = Enum.TextXAlignment.Center
		lbl.TextYAlignment = Enum.TextYAlignment.Center
		lbl.ZIndex = UIStyle.Z.Content
		lbl.Parent = parent
		apply(lbl, cleaned)
		return lbl
	end
end

-- PROGRESS BAR
function UIBuilder.progressBar(parent, opts)
	opts = opts or {}
	local value = opts.value or 0
	local max = opts.max or 100
	local pct = math.clamp(max > 0 and value / max or 0, 0, 1)
	local color = opts.color or UIStyle.Color.Gold
	local height = opts.height or 8

	local root = Instance.new("Frame")
	root.Size = opts.size or UDim2.new(1, 0, 0, height + (opts.label and 16 or 0))
	root.BackgroundTransparency = 1
	root.ZIndex = UIStyle.Z.Content
	root.Parent = parent
	apply(root, opts.props)

	local labelRowH = 14
	local labelGap = 4
	local valueLbl
	if opts.label then
		UIBuilder.label(root, opts.label, UIStyle.Type.StatLabel, UIStyle.Color.TextMuted, {
			Size = UDim2.new(0.6, 0, 0, labelRowH),
			Position = UDim2.fromOffset(0, 0),
			TextYAlignment = Enum.TextYAlignment.Center,
		})
		valueLbl = UIBuilder.label(root, opts.valueText or tostring(math.floor(value + 0.5)),
			UIStyle.Type.StatLabel, UIStyle.Color.Text, {
				Size = UDim2.new(0.4, 0, 0, labelRowH),
				Position = UDim2.new(1, 0, 0, 0),
				AnchorPoint = Vector2.new(1, 0),
				TextXAlignment = Enum.TextXAlignment.Right,
				TextYAlignment = Enum.TextYAlignment.Center,
				Font = UIStyle.Font.Semibold,
			})
	end

	local bg = Instance.new("Frame")
	bg.Size = UDim2.new(1, 0, 0, height)
	bg.Position = UDim2.fromOffset(0, opts.label and (labelRowH + labelGap) or 0)
	bg.BackgroundColor3 = UIStyle.Color.Bg
	bg.BorderSizePixel = 0
	bg.ZIndex = UIStyle.Z.Content
	bg.Parent = root
	newCorner(bg, math.floor(height / 2))
	newStroke(bg, 1, UIStyle.Color.Border)

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(pct, 1)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.ZIndex = UIStyle.Z.Content + 1
	fill.Parent = bg
	newCorner(fill, math.floor(height / 2))

	return {
		root = root,
		fill = fill,
		valueLabel = valueLbl,
		setValue = function(v, m, suppressText)
			local cap = m or max
			local p = math.clamp(cap > 0 and v / cap or 0, 0, 1)
			TweenService:Create(fill, UIStyle.tween(UIStyle.Motion.Fast),
				{ Size = UDim2.fromScale(p, 1) }):Play()
			if valueLbl and not suppressText then
				valueLbl.Text = string.format("%d", math.floor((v or 0) + 0.5))
			end
		end,
		setColor = function(c) fill.BackgroundColor3 = c end,
		setText = function(text) if valueLbl then valueLbl.Text = text end end,
		setValueText = function(text) if valueLbl then valueLbl.Text = text end end,
		setValueColor = function(color) if valueLbl then valueLbl.TextColor3 = color end end,
	}
end

-- BADGE: small colored label (ideology/government tag)
function UIBuilder.badge(parent, text, tone, props)
	local toneColor = UIStyle.Color.Gold
	if tone == "good" then toneColor = UIStyle.Color.Good
	elseif tone == "bad" then toneColor = UIStyle.Color.Bad
	elseif tone == "warn" then toneColor = UIStyle.Color.Warn
	elseif tone == "info" then toneColor = UIStyle.Color.Info
	elseif tone == "muted" then toneColor = UIStyle.Color.TextMuted
	end

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(0, UIStyle.Size.BadgeH)
	frame.AutomaticSize = Enum.AutomaticSize.X
	frame.BackgroundColor3 = UIStyle.Color.PanelAlt
	frame.BackgroundTransparency = 0.12
	frame.BorderSizePixel = 0
	frame.ZIndex = UIStyle.Z.Content
	frame.Parent = parent
	newCorner(frame, 2)
	local stroke = newStroke(frame, 1, toneColor)
	stroke.Transparency = 0.25

	local lbl = Instance.new("TextLabel")
	lbl.AutomaticSize = Enum.AutomaticSize.X
	lbl.Size = UDim2.new(0, 0, 1, 0)
	lbl.BackgroundTransparency = 1
	lbl.Text = "  " .. string.upper(tostring(text or "")) .. "  "
	lbl.TextColor3 = toneColor
	lbl.FontFace = UIStyle.FontFace.Cinzel
	lbl.TextSize = 10
	lbl.TextXAlignment = Enum.TextXAlignment.Center
	lbl.TextYAlignment = Enum.TextYAlignment.Center
	lbl.ZIndex = UIStyle.Z.Content + 1
	lbl.Parent = frame

	apply(frame, props)
	return frame
end

-- PILL: icon + text + optional delta (used in TopBar resource cells, BottomBar map modes)
function UIBuilder.pill(parent, opts)
	opts = opts or {}
	local frame = Instance.new("Frame")
	frame.Size = opts.size or UDim2.fromOffset(110, UIStyle.Size.PillH)
	frame.BackgroundColor3 = opts.bg or UIStyle.Color.PanelAlt
	frame.BorderSizePixel = 0
	frame.ZIndex = UIStyle.Z.Content
	frame.Parent = parent
	newCorner(frame, 3)
	local stroke = newStroke(frame, 1, opts.stroke or UIStyle.Color.Border)
	stroke.Transparency = 0.2

	local iconObj
	if opts.icon then
		iconObj = UIBuilder.icon(frame, opts.icon, 14, {
			Position = UDim2.fromOffset(8, (UIStyle.Size.PillH - 14) / 2),
			ImageColor3 = opts.iconColor or UIStyle.Color.Gold,
		})
		if iconObj:IsA("TextLabel") then
			iconObj.TextColor3 = opts.iconColor or UIStyle.Color.Gold
		end
	end

	local textX = opts.icon and 26 or 10
	local valueLbl = Instance.new("TextLabel")
	valueLbl.Size = UDim2.new(1, -(textX + 6), 1, 0)
	valueLbl.Position = UDim2.fromOffset(textX, 0)
	valueLbl.BackgroundTransparency = 1
	valueLbl.Text = opts.text or ""
	valueLbl.TextColor3 = opts.color or UIStyle.Color.CreamBright
	valueLbl.FontFace = UIStyle.FontFace.Cinzel
	valueLbl.TextSize = 13
	valueLbl.TextXAlignment = Enum.TextXAlignment.Left
	valueLbl.TextYAlignment = Enum.TextYAlignment.Center
	valueLbl.ZIndex = UIStyle.Z.Content + 1
	valueLbl.Parent = frame

	apply(frame, opts.props)

	return {
		root = frame,
		setText = function(t) valueLbl.Text = t or "" end,
		setColor = function(c) valueLbl.TextColor3 = c end,
		setStroke = function(c) (frame:FindFirstChildOfClass("UIStroke") or {}).Color = c end,
	}
end

-- KEY HINT: small rounded square showing keyboard key
function UIBuilder.keyHint(parent, keyText, props)
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(18, 18)
	frame.BackgroundColor3 = UIStyle.Color.Bg
	frame.BorderSizePixel = 0
	frame.ZIndex = UIStyle.Z.Content
	frame.Parent = parent
	newCorner(frame, 2)
	local stroke = newStroke(frame, 1, UIStyle.Color.Border)
	stroke.Transparency = 0.25

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundTransparency = 1
	lbl.Text = keyText or "?"
	lbl.TextColor3 = UIStyle.Color.Gold
	lbl.FontFace = UIStyle.FontFace.Cinzel
	lbl.TextSize = 10
	lbl.TextXAlignment = Enum.TextXAlignment.Center
	lbl.TextYAlignment = Enum.TextYAlignment.Center
	lbl.ZIndex = UIStyle.Z.Content + 1
	lbl.Parent = frame

	apply(frame, props)
	return frame
end

-- ICON BUTTON: square button with icon
function UIBuilder.iconButton(parent, iconKey, opts)
	opts = opts or {}
	local size = opts.size or 28
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.fromOffset(size, size)
	btn.BackgroundColor3 = opts.bg or UIStyle.Color.Bg
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = false
	btn.Text = ""
	btn.ZIndex = UIStyle.Z.Content
	btn.Parent = parent
	newCorner(btn, UIStyle.Size.CornerButton)
	local stroke = newStroke(btn, 1, UIStyle.Color.Border)
	stroke.Transparency = 0.2

	UIBuilder.icon(btn, iconKey, math.floor(size * 0.55), {
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ImageColor3 = opts.iconColor or UIStyle.Color.Gold,
	})

	if not Platform.isTouch then
		btn.MouseEnter:Connect(function()
			if btn.Active == false then return end
			btn.BackgroundColor3 = UIStyle.Color.PanelHigh
			stroke.Color = UIStyle.Color.GoldBright
			stroke.Transparency = 0
		end)
		btn.MouseLeave:Connect(function()
			btn.BackgroundColor3 = opts.bg or UIStyle.Color.Bg
			stroke.Color = UIStyle.Color.Border
			stroke.Transparency = 0.2
		end)
	end

	apply(btn, opts.props)
	return btn
end

-- DIM: full-size dark overlay
function UIBuilder.dim(parent, alpha, props)
	local overlay = Instance.new("Frame")
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = UIStyle.Color.Bg
	overlay.BackgroundTransparency = 1 - (alpha or 0.75)
	overlay.BorderSizePixel = 0
	overlay.ZIndex = UIStyle.Z.Modal
	overlay.Parent = parent
	apply(overlay, props)
	return overlay
end

-- COLLAPSIBLE SECTION: guaranteed-visible title, chevron, tweened body
function UIBuilder.collapsibleSection(parent, title, opts)
	opts = opts or {}
	local expanded = opts.expanded ~= false

	local container = Instance.new("Frame")
	container.Name = "CollapsibleSection"
	container.Size = UDim2.new(1, 0, 0, UIStyle.Size.SectionHeaderH)
	container.AutomaticSize = Enum.AutomaticSize.Y
	container.BackgroundTransparency = 1
	container.ZIndex = UIStyle.Z.Content
	container.Parent = parent

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, UIStyle.Size.SectionHeaderH)
	header.BackgroundColor3 = UIStyle.Color.PanelAlt
	header.BorderSizePixel = 0
	header.ZIndex = UIStyle.Z.PanelHeader
	header.Parent = container
	newCorner(header, 2)
	local stroke = newStroke(header, 1, UIStyle.Color.Border)
	stroke.Transparency = 0.25

	local titleLbl = Instance.new("TextLabel")
	titleLbl.Name = "Title"
	titleLbl.Size = UDim2.new(1, -40, 1, 0)
	titleLbl.Position = UDim2.fromOffset(12, 0)
	titleLbl.BackgroundTransparency = 1
	titleLbl.Text = title or ""
	titleLbl.TextColor3 = UIStyle.Color.Gold
	titleLbl.FontFace = UIStyle.FontFace.Cinzel
	titleLbl.TextSize = 13
	titleLbl.TextXAlignment = Enum.TextXAlignment.Left
	titleLbl.TextYAlignment = Enum.TextYAlignment.Center
	titleLbl.ZIndex = UIStyle.Z.PanelHeader + 2
	titleLbl.Parent = header

	local chevron = Instance.new("TextLabel")
	chevron.Name = "Chevron"
	chevron.Size = UDim2.fromOffset(20, UIStyle.Size.SectionHeaderH)
	chevron.Position = UDim2.new(1, -8, 0, 0)
	chevron.AnchorPoint = Vector2.new(1, 0)
	chevron.BackgroundTransparency = 1
	chevron.Text = expanded and "\u{25BC}" or "\u{25B6}"
	chevron.TextColor3 = UIStyle.Color.Gold
	chevron.FontFace = UIStyle.FontFace.Cinzel
	chevron.TextSize = 11
	chevron.TextXAlignment = Enum.TextXAlignment.Center
	chevron.TextYAlignment = Enum.TextYAlignment.Center
	chevron.ZIndex = UIStyle.Z.PanelHeader + 2
	chevron.Parent = header

	local clickOverlay = Instance.new("TextButton")
	clickOverlay.Size = UDim2.fromScale(1, 1)
	clickOverlay.BackgroundTransparency = 1
	clickOverlay.Text = ""
	clickOverlay.AutoButtonColor = false
	clickOverlay.ZIndex = UIStyle.Z.PanelHeader + 3
	clickOverlay.Parent = header

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = UDim2.new(1, 0, 0, 0)
	body.Position = UDim2.fromOffset(0, UIStyle.Size.SectionHeaderH + 4)
	body.BackgroundTransparency = 1
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.Visible = expanded
	body.ZIndex = UIStyle.Z.Content
	body.Parent = container

	local function setExpanded(flag)
		expanded = flag and true or false
		body.Visible = expanded
		chevron.Text = expanded and "\u{25BC}" or "\u{25B6}"
	end

	clickOverlay.MouseButton1Click:Connect(function() setExpanded(not expanded) end)

	return {
		container = container,
		body = body,
		setExpanded = setExpanded,
		isExpanded = function() return expanded end,
	}
end

-- TAB STRIP: pill tabs w/ animated underline
function UIBuilder.tabStrip(parent, tabDefs, onSelect)
	local strip = Instance.new("Frame")
	strip.Size = UDim2.new(1, 0, 0, UIStyle.Size.TabH)
	strip.BackgroundColor3 = UIStyle.Color.Bg
	strip.BorderSizePixel = 0
	strip.ZIndex = UIStyle.Z.PanelHeader
	strip.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.Padding = UDim.new(0, 0)
	layout.Parent = strip

	local underline = Instance.new("Frame")
	underline.Size = UDim2.fromOffset(0, 2)
	underline.Position = UDim2.new(0, 0, 1, -2)
	underline.BackgroundColor3 = UIStyle.Color.GoldBright
	underline.BorderSizePixel = 0
	underline.ZIndex = UIStyle.Z.PanelHeader + 2
	underline.Parent = strip

	local buttons = {}
	local currentKey = nil

	local function setActive(key)
		currentKey = key
		for k, btn in buttons do
			local active = k == key
			btn.TextColor3 = active and UIStyle.Color.GoldBright or UIStyle.Color.TextMuted
			btn.BackgroundTransparency = active and 0.75 or 1
			if active then
				local s = getUIRoot().uiScale()
				local tween = TweenService:Create(underline, UIStyle.tween(UIStyle.Motion.Fast), {
					Position = UDim2.new(0, (btn.AbsolutePosition.X - strip.AbsolutePosition.X) / s, 1, -2),
					Size = UDim2.fromOffset(btn.AbsoluteSize.X / s, 2),
				})
				tween:Play()
			end
		end
		if onSelect then onSelect(key) end
	end

	for i, def in tabDefs do
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1 / #tabDefs, 0, 1, 0)
		btn.BackgroundColor3 = UIStyle.Color.PanelAlt
		btn.BackgroundTransparency = 1
		btn.BorderSizePixel = 0
		btn.AutoButtonColor = false
		btn.Text = def.label or def.key
		btn.TextColor3 = UIStyle.Color.TextMuted
		btn.FontFace = UIStyle.FontFace.Cinzel
		btn.TextSize = 12
		btn.LayoutOrder = i
		btn.ZIndex = UIStyle.Z.PanelHeader + 1
		btn.Parent = strip
		buttons[def.key] = btn

		btn.MouseButton1Click:Connect(function() setActive(def.key) end)
	end

	task.defer(function()
		if tabDefs[1] then setActive(tabDefs[1].key) end
	end)

	return { strip = strip, setActive = setActive, getActive = function() return currentKey end, buttons = buttons }
end

-- TOOLTIP: attach hover to a target, render content at mouse
local activeTooltip = nil

local function renderTooltipContent(frame, rows)
	for _, c in frame:GetChildren() do
		if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
	end
	for _, r in rows do
		if r.header then
			local h = UIBuilder.label(frame, r.header, UIStyle.Type.SectionHeader, UIStyle.Color.Gold, {
				Size = UDim2.new(1, 0, 0, 20),
				AutomaticSize = Enum.AutomaticSize.Y,
				TextWrapped = true,
				TextTruncate = Enum.TextTruncate.None,
			})
			h.LineHeight = 1.1
		elseif r.body then
			UIBuilder.label(frame, r.body, UIStyle.Type.Small, UIStyle.Color.TextMuted, {
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				TextWrapped = true,
				TextTruncate = Enum.TextTruncate.None,
			})
		else
			local row = Instance.new("Frame")
			row.Size = UDim2.new(1, 0, 0, 0)
			row.AutomaticSize = Enum.AutomaticSize.Y
			row.BackgroundTransparency = 1
			row.Parent = frame
			UIBuilder.label(row, r.label or "", UIStyle.Type.Small, UIStyle.Color.TextMuted, {
				Size = UDim2.new(0, 90, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				TextWrapped = true,
				TextTruncate = Enum.TextTruncate.None,
				TextYAlignment = Enum.TextYAlignment.Top,
			})
			UIBuilder.label(row, r.value or "", UIStyle.Type.Small, r.tone or UIStyle.Color.Text, {
				Size = UDim2.new(1, -96, 0, 0),
				Position = UDim2.new(1, 0, 0, 0),
				AnchorPoint = Vector2.new(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				TextWrapped = true,
				TextTruncate = Enum.TextTruncate.None,
				TextXAlignment = Enum.TextXAlignment.Right,
				TextYAlignment = Enum.TextYAlignment.Top,
				Font = UIStyle.Font.Bold,
			})
		end
	end
end

function UIBuilder.tooltip(target, contentFn)
	-- UIBuilder.tooltip skip on touch: hover-driven tooltips are inaccessible on touch
	-- devices; long-press equivalents are out of scope for round 3. Bail early.
	if Platform.isTouch then return end
	local followConn = nil

	local function makeFrame()
		local layer = getUIRoot().tooltipLayer()
		local f = Instance.new("Frame")
		f.Size = UDim2.fromOffset(300, 0)
		f.AutomaticSize = Enum.AutomaticSize.Y
		f.BackgroundColor3 = UIStyle.Color.Panel
		f.BorderSizePixel = 0
		f.Visible = false
		f.ZIndex = UIStyle.Z.Transient
		f.Parent = layer
		newCorner(f, 3)
		local stroke = newStroke(f, 1, UIStyle.Color.BorderStrong)
		stroke.Transparency = 0.15
		newPadding(f, 10)
		addPanelTrim(f)

		local list = Instance.new("UIListLayout")
		list.FillDirection = Enum.FillDirection.Vertical
		list.Padding = UDim.new(0, 4)
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Parent = f

		return f
	end

	local frame = nil
	local connEnter, connLeave, ancestryConn
	local alive = true

	local function hide()
		if frame then frame.Visible = false end
		if followConn then followConn:Disconnect() followConn = nil end
	end

	local function disconnectAll()
		if not alive then return end
		alive = false
		hide()
		if connEnter then connEnter:Disconnect() connEnter = nil end
		if connLeave then connLeave:Disconnect() connLeave = nil end
		if ancestryConn then ancestryConn:Disconnect() ancestryConn = nil end
		if frame then frame:Destroy() frame = nil end
	end

	local function targetAlive()
		return alive and target and target.Parent ~= nil
	end

	local function placeAt(m)
		if not frame then return end
		local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)
		local sz = frame.AbsoluteSize
		local px = m.X + 14
		if px + sz.X + 8 > vp.X then px = m.X - sz.X - 14 end
		local py = m.Y + 18
		if py + sz.Y + 8 > vp.Y then py = m.Y - sz.Y - 18 end
		px = math.clamp(px, 8, math.max(8, vp.X - sz.X - 8))
		py = math.clamp(py, 8, math.max(8, vp.Y - sz.Y - 8))
		frame.Position = UDim2.fromOffset(px, py)
	end

	local function show()
		if not targetAlive() then return end
		if not frame then frame = makeFrame() end
		local rows = {}
		if contentFn then
			local ok, r = pcall(contentFn)
			if ok and type(r) == "table" then rows = r end
		end
		renderTooltipContent(frame, rows)
		frame.Visible = false
		placeAt(UserInputService:GetMouseLocation())
		task.defer(function()
			if not targetAlive() or not frame then return end
			placeAt(UserInputService:GetMouseLocation())
			frame.Visible = true
		end)
		followConn = UserInputService.InputChanged:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
			if not targetAlive() then hide() return end
			placeAt(UserInputService:GetMouseLocation())
		end)
	end

	connEnter = target.MouseEnter:Connect(show)
	connLeave = target.MouseLeave:Connect(hide)
	ancestryConn = target.AncestryChanged:Connect(function(_, parent)
		if not parent then disconnectAll() end
	end)

	return { disconnect = disconnectAll }
end

function UIBuilder.framedPanel(parent, props)
	local frame = UIBuilder.panel(parent, props)
	local stroke = frame:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = UIStyle.Color.Border
		stroke.Transparency = 0.15
	end
	return frame
end

function UIBuilder.eyebrow(parent, text, props)
	local lbl = Instance.new("TextLabel")
	lbl.AutomaticSize = Enum.AutomaticSize.None
	lbl.BackgroundTransparency = 1
	local raw = tostring(text or "")
	local spaced = raw:upper():gsub(".", function(ch)
		if ch:match("%S") then return ch .. " " end
		return ch
	end)
	lbl.Text = spaced:gsub("%s+$", "")
	lbl.TextColor3 = UIStyle.Color.LedgerSection
	lbl.FontFace = UIStyle.FontFace.Cinzel
	lbl.TextSize = 11
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextYAlignment = Enum.TextYAlignment.Center
	lbl.ZIndex = UIStyle.Z.Content
	lbl.Parent = parent
	pcall(function() lbl.RichText = false end)
	apply(lbl, props)
	return lbl
end

function UIBuilder.captionDivider(parent, text, props)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 22)
	row.BackgroundTransparency = 1
	row.ZIndex = UIStyle.Z.Content
	row.Parent = parent

	local raw = tostring(text or "")
	local spaced = raw:upper():gsub(".", function(ch)
		if ch:match("%S") then return ch .. " " end
		return ch
	end):gsub("%s+$", "")

	local pad = 12
	local labelW = math.max(60, #raw * 8)

	local function rule(left)
		local line = Instance.new("Frame")
		line.AnchorPoint = Vector2.new(left and 0 or 1, 0.5)
		line.Position = UDim2.new(left and 0 or 1, left and pad or -pad, 0.5, 0)
		line.Size = UDim2.new(0.5, -(pad + labelW / 2 + 8), 0, 1)
		line.BackgroundColor3 = UIStyle.Color.BorderStrong
		line.BackgroundTransparency = 0.55
		line.BorderSizePixel = 0
		line.ZIndex = UIStyle.Z.Content
		line.Parent = row
		return line
	end
	rule(true)
	rule(false)

	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromOffset(labelW, 18)
	label.BackgroundTransparency = 1
	label.Text = spaced
	label.TextColor3 = UIStyle.Color.TextMuted
	label.Font = UIStyle.Font.Semibold
	label.TextSize = 10
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.ZIndex = UIStyle.Z.Content + 1
	label.Parent = row
	pcall(function() label.RichText = false end)

	apply(row, props)
	return row
end

function UIBuilder.tagChip(parent, text, color, props)
	local size = (props and props.size) or 38
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(size, size)
	frame.BackgroundColor3 = UIStyle.Color.Bg
	frame.BorderSizePixel = 0
	frame.ZIndex = UIStyle.Z.Content
	frame.Parent = parent
	newCorner(frame, 3)
	newStroke(frame, 1, color or UIStyle.Color.BorderStrong)

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundTransparency = 1
	lbl.Text = tostring(text or "")
	lbl.TextColor3 = UIStyle.Color.Text
	lbl.Font = UIStyle.Font.Bold
	lbl.TextSize = math.floor(size * 0.32)
	lbl.TextXAlignment = Enum.TextXAlignment.Center
	lbl.TextYAlignment = Enum.TextYAlignment.Center
	lbl.ZIndex = UIStyle.Z.Content + 1
	lbl.Parent = frame

	if props then
		local cleaned = {}
		for k, v in props do
			if k ~= "size" then cleaned[k] = v end
		end
		apply(frame, cleaned)
	end
	return frame
end

function UIBuilder.statRowBar(parent, opts)
	opts = opts or {}
	local rowH = opts.height or 30
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, rowH)
	row.BackgroundTransparency = 1
	row.ZIndex = UIStyle.Z.Content
	row.Parent = parent

	local labelObj = Instance.new("TextLabel")
	labelObj.Size = UDim2.new(0.42, 0, 1, 0)
	labelObj.BackgroundTransparency = 1
	labelObj.Text = opts.label or ""
	labelObj.TextColor3 = UIStyle.Color.TextMuted
	labelObj.TextXAlignment = Enum.TextXAlignment.Left
	labelObj.TextYAlignment = Enum.TextYAlignment.Center
	labelObj.Font = UIStyle.Font.Regular
	labelObj.TextSize = 13
	labelObj.ZIndex = UIStyle.Z.Content
	labelObj.Parent = row

	local valueObj = Instance.new("TextLabel")
	valueObj.Size = UDim2.new(0.20, 0, 1, 0)
	valueObj.Position = UDim2.new(1, 0, 0, 0)
	valueObj.AnchorPoint = Vector2.new(1, 0)
	valueObj.BackgroundTransparency = 1
	valueObj.Text = opts.value or ""
	valueObj.TextColor3 = opts.valueColor or UIStyle.Color.Text
	valueObj.Font = UIStyle.Font.Bold
	valueObj.TextSize = 14
	valueObj.TextXAlignment = Enum.TextXAlignment.Right
	valueObj.TextYAlignment = Enum.TextYAlignment.Center
	valueObj.ZIndex = UIStyle.Z.Content
	valueObj.Parent = row

	local barTrack, fill
	if opts.bar then
		local pct = math.clamp(opts.bar.value or 0, 0, opts.bar.max or 1)
		local cap = opts.bar.max or 1
		local p = cap > 0 and pct / cap or 0
		local trackHeight = 3

		barTrack = Instance.new("Frame")
		barTrack.AnchorPoint = Vector2.new(0, 0.5)
		barTrack.Position = UDim2.new(0.44, 0, 0.5, 0)
		barTrack.Size = UDim2.new(0.36, 0, 0, trackHeight)
		barTrack.BackgroundColor3 = UIStyle.Color.Bg
		barTrack.BorderSizePixel = 0
		barTrack.ZIndex = UIStyle.Z.Content
		barTrack.Parent = row
		newCorner(barTrack, 1)

		fill = Instance.new("Frame")
		fill.Size = UDim2.fromScale(p, 1)
		fill.BackgroundColor3 = opts.bar.color or UIStyle.Color.Good
		fill.BorderSizePixel = 0
		fill.ZIndex = UIStyle.Z.Content + 1
		fill.Parent = barTrack
		newCorner(fill, 1)
	end

	if opts.divider ~= false then
		local sep = Instance.new("Frame")
		sep.AnchorPoint = Vector2.new(0, 1)
		sep.Position = UDim2.new(0, 0, 1, 0)
		sep.Size = UDim2.new(1, 0, 0, 1)
		sep.BackgroundColor3 = UIStyle.Color.Border
		sep.BackgroundTransparency = 0.75
		sep.BorderSizePixel = 0
		sep.ZIndex = UIStyle.Z.Content
		sep.Parent = row
	end

	apply(row, opts.props)
	return { row = row, label = labelObj, value = valueObj, barTrack = barTrack, barFill = fill }
end

function UIBuilder.tweenTo(obj, spec, props)
	local info = UIStyle.tween(spec or UIStyle.Motion.Medium)
	local t = TweenService:Create(obj, info, props)
	t:Play()
	return t
end

UIBuilder.stroke  = newStroke
UIBuilder.corner  = newCorner
UIBuilder.padding = newPadding


-- EMPTY STATE: centered placeholder for stub tabs / pending features
function UIBuilder.emptyState(parent, opts)
	opts = opts or {}
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundTransparency = 1
	frame.ZIndex = UIStyle.Z.Content
	frame.Parent = parent

	local stack = Instance.new("Frame")
	stack.Size = UDim2.fromOffset(360, 140)
	stack.Position = UDim2.fromScale(0.5, 0.5)
	stack.AnchorPoint = Vector2.new(0.5, 0.5)
	stack.BackgroundTransparency = 1
	stack.ZIndex = UIStyle.Z.Content
	stack.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, 12)
	layout.Parent = stack

	local iconKey = opts.icon or "Warning"
	UIBuilder.icon(stack, iconKey, 48, {
		LayoutOrder = 1,
		ImageColor3 = UIStyle.Color.Gold,
	})

	UIBuilder.label(stack, opts.title or "No entries", UIStyle.Type.H2, UIStyle.Color.Gold, {
		Size = UDim2.new(1, 0, 0, 22),
		Font = UIStyle.Font.Bold,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Center,
		LayoutOrder = 2,
	})

	if opts.subtitle then
		UIBuilder.label(stack, opts.subtitle, UIStyle.Type.Body, UIStyle.Color.TextMuted, {
			Size = UDim2.new(1, 0, 0, 36),
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextWrapped = true,
			LayoutOrder = 3,
		})
	end

	return frame
end

local function cornerBracket(parent, anchor, color, inset)
	inset = inset or 2
	local f = Instance.new("Frame")
	f.Size = UDim2.fromOffset(7, 7)
	f.AnchorPoint = anchor
	local px, py = anchor.X, anchor.Y
	local ox = px == 0 and inset or -inset
	local oy = py == 0 and inset or -inset
	f.Position = UDim2.new(px, ox, py, oy)
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	f.ZIndex = (parent.ZIndex or 1) + 1
	f.Parent = parent
	return f
end

local function imageLayer(parent, image, props)
	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(1, 1)
	img.ScaleType = Enum.ScaleType.Stretch
	img.Image = image
	img.ZIndex = (parent.ZIndex or 1) + 1
	img.Parent = parent
	apply(img, props)
	return img
end

local HOVER_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function fade(obj, props)
	TweenService:Create(obj, HOVER_TWEEN, props):Play()
end

function UIBuilder.preloadHoverAssets()
	local cp = game:GetService("ContentProvider")
	local list = {
		UIAssets.Btn.Panel.Hover, UIAssets.Btn.Panel.Disabled,
		UIAssets.Btn.Stroke.Hover, UIAssets.Btn.Stroke.Disabled,
		UIAssets.Btn.Bracket.Hover.TL, UIAssets.Btn.Bracket.Hover.TR,
		UIAssets.Btn.Bracket.Hover.BL, UIAssets.Btn.Bracket.Hover.BR,
		UIAssets.Compact.Panel.Hover, UIAssets.Compact.Arrow.Hover,
		UIAssets.Compact.IconHolder.Hover, UIAssets.Compact.Divider.Hover,
		UIAssets.Compact.TopLine.Hover,
	}
	pcall(function() cp:PreloadAsync(list) end)
end

function UIBuilder.secondaryButton(parent, opts)
	opts = opts or {}
	local container = Instance.new("Frame")
	container.Size = opts.Size or UDim2.fromOffset(220, 38)
	container.Position = opts.Position or UDim2.fromScale(0, 0)
	container.AnchorPoint = opts.AnchorPoint or Vector2.new(0, 0)
	container.BackgroundTransparency = 1
	container.ZIndex = opts.ZIndex or 5
	container.Parent = parent

	local function layer(image, alpha, z)
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1
		img.Size = UDim2.fromScale(1, 1)
		img.ScaleType = Enum.ScaleType.Stretch
		img.Image = image
		img.ImageTransparency = alpha
		img.ZIndex = container.ZIndex + z
		img.Parent = container
		return img
	end

	local panelDefault  = layer(UIAssets.Btn.Panel.Default,  0, 1)
	local panelHover    = layer(UIAssets.Btn.Panel.Hover,    1, 1)
	local panelDisabled = layer(UIAssets.Btn.Panel.Disabled, 1, 1)
	local strokeDefault  = layer(UIAssets.Btn.Stroke.Default,  0, 2)
	local strokeHover    = layer(UIAssets.Btn.Stroke.Hover,    1, 2)
	local strokeDisabled = layer(UIAssets.Btn.Stroke.Disabled, 1, 2)

	local function corner(anchor, image, inset)
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1
		img.Size = UDim2.fromOffset(12, 12)
		img.AnchorPoint = anchor
		local ox = anchor.X == 0 and inset or -inset
		local oy = anchor.Y == 0 and inset or -inset
		img.Position = UDim2.new(anchor.X, ox, anchor.Y, oy)
		img.Image = image
		img.ImageTransparency = 0
		img.ScaleType = Enum.ScaleType.Fit
		img.ZIndex = container.ZIndex + 3
		img.Parent = container
		return img
	end

	local INSET = 3
	local brackets = {
		corner(Vector2.new(0, 0), UIAssets.Btn.Bracket.TL, INSET),
		corner(Vector2.new(1, 0), UIAssets.Btn.Bracket.TR, INSET),
		corner(Vector2.new(0, 1), UIAssets.Btn.Bracket.BL, INSET),
		corner(Vector2.new(1, 1), UIAssets.Btn.Bracket.BR, INSET),
	}

	local btn = Instance.new("TextButton")
	btn.Size = UDim2.fromScale(1, 1)
	btn.BackgroundTransparency = 1
	btn.AutoButtonColor = false
	btn.Text = opts.Text or ""
	btn.TextColor3 = UIStyle.Color.SecondaryDefault
	btn.FontFace = UIStyle.FontFace.Cinzel
	btn.TextSize = opts.TextSize or 14
	btn.TextXAlignment = Enum.TextXAlignment.Center
	btn.TextYAlignment = Enum.TextYAlignment.Center
	btn.ZIndex = container.ZIndex + 4
	btn.Parent = container

	local enabled = true
	local active = false

	local function fadeTo(state)
		local pH, pD, sH, sD, bA = 1, 1, 1, 1, 0
		local color = UIStyle.Color.SecondaryDefault
		if state == "hover" then
			pH, sH = 0, 0
			bA = 1
			color = UIStyle.Color.SecondaryHover
		elseif state == "disabled" then
			pD, sD = 0, 0
			bA = 1
			color = UIStyle.Color.SecondaryDisabled
		end
		fade(panelHover,    { ImageTransparency = pH })
		fade(panelDisabled, { ImageTransparency = pD })
		fade(strokeHover,   { ImageTransparency = sH })
		fade(strokeDisabled, { ImageTransparency = sD })
		for _, b in brackets do
			fade(b, { ImageTransparency = bA })
		end
		fade(btn, { TextColor3 = color })
	end

	btn.MouseEnter:Connect(function()
		if enabled then fadeTo("hover") end
	end)
	btn.MouseLeave:Connect(function()
		if enabled then fadeTo(active and "hover" or "default") end
	end)

	local api = {
		root = container,
		button = btn,
		setEnabled = function(flag)
			enabled = flag and true or false
			btn.Active = enabled
			if enabled then
				fadeTo(active and "hover" or "default")
			else
				fadeTo("disabled")
			end
		end,
		setActive = function(flag)
			active = flag and true or false
			if enabled then
				fadeTo(active and "hover" or "default")
			end
		end,
		setText = function(t) btn.Text = t or "" end,
		clicked = function(fn) btn.MouseButton1Click:Connect(function() if enabled then fn() end end) end,
	}
	if opts.Disabled then api.setEnabled(false) end
	return api
end

function UIBuilder.compactIconLabel(parent, opts)
	opts = opts or {}
	local container = Instance.new("Frame")
	container.Size = opts.Size or UDim2.fromOffset(160, 36)
	container.Position = opts.Position or UDim2.fromScale(0, 0)
	container.AnchorPoint = opts.AnchorPoint or Vector2.new(0, 0)
	container.BackgroundTransparency = 1
	container.ZIndex = opts.ZIndex or 5
	container.Parent = parent

	local function fillLayer(image, alpha, z)
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1
		img.Size = UDim2.fromScale(1, 1)
		img.ScaleType = Enum.ScaleType.Stretch
		img.Image = image
		img.ImageTransparency = alpha
		img.ZIndex = container.ZIndex + z
		img.Parent = container
		return img
	end

	local panelDefault = fillLayer(UIAssets.Compact.Panel.Default, 0, 1)
	local panelHover   = fillLayer(UIAssets.Compact.Panel.Hover,   1, 1)
	fillLayer(UIAssets.Compact.Stroke.Default, 0, 2)

	local topLine = Instance.new("ImageLabel")
	topLine.BackgroundTransparency = 1
	topLine.Size = UDim2.new(1, -20, 0, 1)
	topLine.Position = UDim2.fromOffset(10, 1)
	topLine.Image = UIAssets.Compact.TopLine.Hover
	topLine.ScaleType = Enum.ScaleType.Stretch
	topLine.ImageTransparency = 1
	topLine.ZIndex = container.ZIndex + 3
	topLine.Parent = container

	local iconHolderDefault = Instance.new("ImageLabel")
	iconHolderDefault.BackgroundTransparency = 1
	iconHolderDefault.Size = UDim2.new(0, 30, 1, -10)
	iconHolderDefault.Position = UDim2.fromOffset(6, 5)
	iconHolderDefault.Image = UIAssets.Compact.IconHolder.Default
	iconHolderDefault.ScaleType = Enum.ScaleType.Stretch
	iconHolderDefault.ImageTransparency = 0
	iconHolderDefault.ZIndex = container.ZIndex + 3
	iconHolderDefault.Parent = container

	local iconHolderHover = iconHolderDefault:Clone()
	iconHolderHover.Image = UIAssets.Compact.IconHolder.Hover
	iconHolderHover.ImageTransparency = 1
	iconHolderHover.Parent = container

	local arrowDefault, arrowHover, iconText
	if opts.iconText then
		iconText = Instance.new("TextLabel")
		iconText.BackgroundTransparency = 1
		iconText.Size = UDim2.fromScale(1, 1)
		iconText.Text = opts.iconText
		iconText.TextColor3 = UIStyle.Color.SecondaryDefault
		iconText.FontFace = UIStyle.FontFace.CinzelBold
		iconText.TextSize = 14
		iconText.TextXAlignment = Enum.TextXAlignment.Center
		iconText.TextYAlignment = Enum.TextYAlignment.Center
		iconText.ZIndex = container.ZIndex + 5
		iconText.Parent = iconHolderHover
	else
		arrowDefault = Instance.new("ImageLabel")
		arrowDefault.BackgroundTransparency = 1
		arrowDefault.Size = UDim2.fromScale(0.55, 0.55)
		arrowDefault.Position = UDim2.fromScale(0.5, 0.5)
		arrowDefault.AnchorPoint = Vector2.new(0.5, 0.5)
		arrowDefault.Image = UIAssets.Compact.Arrow.Default
		arrowDefault.ScaleType = Enum.ScaleType.Fit
		arrowDefault.ImageTransparency = 0
		arrowDefault.ZIndex = container.ZIndex + 4
		arrowDefault.Parent = iconHolderDefault

		arrowHover = arrowDefault:Clone()
		arrowHover.Image = UIAssets.Compact.Arrow.Hover
		arrowHover.ImageTransparency = 1
		arrowHover.Parent = iconHolderHover
	end

	local dividerDefault = Instance.new("ImageLabel")
	dividerDefault.BackgroundTransparency = 1
	dividerDefault.Size = UDim2.new(0, 1, 1, -12)
	dividerDefault.Position = UDim2.fromOffset(42, 6)
	dividerDefault.Image = UIAssets.Compact.Divider.Default
	dividerDefault.ScaleType = Enum.ScaleType.Stretch
	dividerDefault.ImageTransparency = 0
	dividerDefault.ZIndex = container.ZIndex + 3
	dividerDefault.Parent = container

	local dividerHover = dividerDefault:Clone()
	dividerHover.Image = UIAssets.Compact.Divider.Hover
	dividerHover.ImageTransparency = 1
	dividerHover.Parent = container

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -52, 1, 0)
	label.Position = UDim2.fromOffset(48, 0)
	label.BackgroundTransparency = 1
	label.Text = opts.Text or ""
	label.TextColor3 = UIStyle.Color.CompactDefault
	label.FontFace = UIStyle.FontFace.Cinzel
	label.TextSize = opts.TextSize or 13
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.ZIndex = container.ZIndex + 3
	label.Parent = container

	local btn = Instance.new("TextButton")
	btn.Size = UDim2.fromScale(1, 1)
	btn.BackgroundTransparency = 1
	btn.Text = ""
	btn.AutoButtonColor = false
	btn.ZIndex = container.ZIndex + 6
	btn.Parent = container

	local active = false

	local function fadeTo(state)
		local hoverAlpha = state == "hover" and 0 or 1
		local lineAlpha = state == "hover" and 0 or 1
		local labelColor = state == "hover" and UIStyle.Color.CompactHover or UIStyle.Color.CompactDefault
		local iconTextColor = state == "hover" and UIStyle.Color.SecondaryHover or UIStyle.Color.SecondaryDefault
		fade(panelHover, { ImageTransparency = hoverAlpha })
		fade(iconHolderHover, { ImageTransparency = hoverAlpha })
		fade(dividerHover, { ImageTransparency = hoverAlpha })
		fade(topLine, { ImageTransparency = lineAlpha })
		if arrowHover then fade(arrowHover, { ImageTransparency = hoverAlpha }) end
		fade(label, { TextColor3 = labelColor })
		if iconText then fade(iconText, { TextColor3 = iconTextColor }) end
	end

	btn.MouseEnter:Connect(function() fadeTo("hover") end)
	btn.MouseLeave:Connect(function() fadeTo(active and "hover" or "default") end)

	return {
		root = container,
		button = btn,
		label = label,
		setText = function(t) label.Text = t or "" end,
		setActive = function(flag)
			active = flag and true or false
			fadeTo(active and "hover" or "default")
		end,
		clicked = function(fn) btn.MouseButton1Click:Connect(fn) end,
	}
end

function UIBuilder.bracketedPanel(parent, props, bracketSize, bracketInset)
	local panel = UIBuilder.panel(parent, props)
	local size = bracketSize or 16
	local inset = bracketInset or 6
	local function bracket(anchor, image)
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1
		img.Size = UDim2.fromOffset(size, size)
		img.AnchorPoint = anchor
		local ox = anchor.X == 0 and inset or -inset
		local oy = anchor.Y == 0 and inset or -inset
		img.Position = UDim2.new(anchor.X, ox, anchor.Y, oy)
		img.Image = image
		img.ScaleType = Enum.ScaleType.Fit
		img.ZIndex = (panel.ZIndex or 1) + 5
		img.Parent = panel
		return img
	end
	bracket(Vector2.new(0, 0), UIAssets.Btn.Bracket.TL)
	bracket(Vector2.new(1, 0), UIAssets.Btn.Bracket.TR)
	bracket(Vector2.new(0, 1), UIAssets.Btn.Bracket.BL)
	bracket(Vector2.new(1, 1), UIAssets.Btn.Bracket.BR)
	return panel
end

function UIBuilder.dotCircle(parent, opts)
	opts = opts or {}
	local img = Instance.new("ImageLabel")
	img.Size = opts.Size or UDim2.fromOffset(8, 8)
	img.Position = opts.Position or UDim2.fromScale(0, 0.5)
	img.AnchorPoint = opts.AnchorPoint or Vector2.new(0, 0.5)
	img.BackgroundTransparency = 1
	img.Image = UIAssets.DotCircle
	img.ImageColor3 = opts.color or UIStyle.Color.LedgerSection
	img.ImageTransparency = opts.transparency or 0
	img.ScaleType = Enum.ScaleType.Fit
	img.ZIndex = opts.ZIndex or ((parent.ZIndex or 1) + 1)
	img.Parent = parent
	return img
end

function UIBuilder.dividerOrnament(parent, opts)
	opts = opts or {}
	local frame = Instance.new("Frame")
	frame.Size = opts.Size or UDim2.new(1, 0, 0, 12)
	frame.Position = opts.Position or UDim2.fromScale(0, 0)
	frame.BackgroundTransparency = 1
	frame.ZIndex = (parent.ZIndex or 1) + 1
	frame.Parent = parent

	local color = opts.color or UIStyle.Color.Border

	local leftLine = Instance.new("Frame")
	leftLine.Size = UDim2.new(0.4, -16, 0, 1)
	leftLine.Position = UDim2.new(0, 0, 0.5, 0)
	leftLine.AnchorPoint = Vector2.new(0, 0.5)
	leftLine.BackgroundColor3 = color
	leftLine.BackgroundTransparency = 0.15
	leftLine.BorderSizePixel = 0
	leftLine.ZIndex = frame.ZIndex
	leftLine.Parent = frame

	local rightLine = leftLine:Clone()
	rightLine.Position = UDim2.new(1, 0, 0.5, 0)
	rightLine.AnchorPoint = Vector2.new(1, 0.5)
	rightLine.Parent = frame

	local function diamond(parent2, x)
		local d = Instance.new("Frame")
		d.Size = UDim2.fromOffset(7, 7)
		d.Position = UDim2.new(x, 0, 0.5, 0)
		d.AnchorPoint = Vector2.new(0.5, 0.5)
		d.BackgroundColor3 = color
		d.BorderSizePixel = 0
		d.Rotation = 45
		d.ZIndex = frame.ZIndex
		d.Parent = parent2
		return d
	end
	diamond(frame, 0.42)
	local center = diamond(frame, 0.5)
	center.Size = UDim2.fromOffset(11, 11)
	diamond(frame, 0.58)

	return frame
end

function UIBuilder.ledgerSection(parent, title, opts)
	opts = opts or {}
	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 0, 22)
	frame.Position = opts.Position or UDim2.fromOffset(0, 0)
	frame.BackgroundTransparency = 1
	frame.LayoutOrder = opts.LayoutOrder or 0
	frame.ZIndex = (parent.ZIndex or 1) + 1
	frame.Parent = parent

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 14)
	label.Position = UDim2.fromOffset(0, 0)
	label.BackgroundTransparency = 1
	label.Text = string.upper(title or "")
	label.TextColor3 = UIStyle.Color.LedgerSection
	label.FontFace = UIStyle.FontFace.Cinzel
	label.TextSize = 11
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.ZIndex = frame.ZIndex
	label.Parent = frame

	local rule = Instance.new("Frame")
	rule.Size = UDim2.new(1, 0, 0, 1)
	rule.Position = UDim2.new(0, 0, 1, -2)
	rule.BackgroundColor3 = UIStyle.Color.LedgerSection
	rule.BackgroundTransparency = 0.5
	rule.BorderSizePixel = 0
	rule.ZIndex = frame.ZIndex
	rule.Parent = frame

	return frame
end

function UIBuilder.ledgerRow(parent, opts)
	opts = opts or {}
	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 0, 20)
	frame.Position = opts.Position or UDim2.fromOffset(0, 0)
	frame.BackgroundTransparency = 1
	frame.LayoutOrder = opts.LayoutOrder or 0
	frame.ZIndex = (parent.ZIndex or 1) + 1
	frame.Parent = parent

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(0.55, 0, 1, 0)
	label.Position = UDim2.fromOffset(0, 0)
	label.BackgroundTransparency = 1
	label.Text = opts.label or ""
	label.TextColor3 = UIStyle.Color.LedgerLabel
	label.FontFace = UIStyle.FontFace.Inter
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.ZIndex = frame.ZIndex
	label.Parent = frame

	local value = Instance.new("TextLabel")
	value.Size = UDim2.new(0.45, 0, 1, 0)
	value.Position = UDim2.new(1, 0, 0, 0)
	value.AnchorPoint = Vector2.new(1, 0)
	value.BackgroundTransparency = 1
	value.Text = opts.value or ""
	value.TextColor3 = opts.valueColor or UIStyle.Color.LedgerValue
	value.FontFace = UIStyle.FontFace.Cinzel
	value.TextSize = 14
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.TextYAlignment = Enum.TextYAlignment.Center
	value.ZIndex = frame.ZIndex
	value.Parent = frame

	return {
		root = frame,
		label = label,
		value = value,
		setValue = function(text, color)
			value.Text = text or ""
			if color then value.TextColor3 = color end
		end,
	}
end

function UIBuilder.ledgerNumberColor(delta)
	if type(delta) ~= "number" then return UIStyle.Color.LedgerValue end
	if delta > 0 then return UIStyle.Color.LedgerStabilityPos end
	if delta < 0 then return UIStyle.Color.LedgerNegative end
	return UIStyle.Color.LedgerValue
end

function UIBuilder.tooltipFrame(parent, opts)
	opts = opts or {}
	local frame = Instance.new("Frame")
	frame.Size = opts.Size or UDim2.fromOffset(240, 120)
	frame.Position = opts.Position or UDim2.fromScale(0, 0)
	frame.AnchorPoint = opts.AnchorPoint or Vector2.new(0, 0)
	frame.BackgroundColor3 = UIStyle.Color.Panel
	frame.BorderSizePixel = 0
	frame.ZIndex = opts.ZIndex or UIStyle.Z.Tooltip
	frame.Parent = parent
	newCorner(frame, 3)
	local stroke = newStroke(frame, 1, UIStyle.Color.Border)
	stroke.Transparency = 0.1

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, UIStyle.Color.PanelAlt),
		ColorSequenceKeypoint.new(1, UIStyle.Color.Panel),
	})
	gradient.Rotation = 90
	gradient.Parent = frame

	cornerBracket(frame, Vector2.new(0, 0), UIStyle.Color.Border, 3)
	cornerBracket(frame, Vector2.new(1, 0), UIStyle.Color.Border, 3)
	cornerBracket(frame, Vector2.new(0, 1), UIStyle.Color.Border, 3)
	cornerBracket(frame, Vector2.new(1, 1), UIStyle.Color.Border, 3)
	return frame
end

function UIBuilder.tooltipTitle(parent, text, opts)
	opts = opts or {}
	local label = Instance.new("TextLabel")
	label.Size = opts.Size or UDim2.new(1, -20, 0, 18)
	label.Position = opts.Position or UDim2.fromOffset(10, 8)
	label.BackgroundTransparency = 1
	label.Text = string.upper(text or "")
	label.TextColor3 = UIStyle.Color.TooltipPrimary
	label.FontFace = UIStyle.FontFace.CinzelBold
	label.TextSize = opts.TextSize or 14
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.ZIndex = (parent.ZIndex or 1) + 1
	label.Parent = parent
	return label
end

function UIBuilder.tooltipBody(parent, text, opts)
	opts = opts or {}
	local label = Instance.new("TextLabel")
	label.Size = opts.Size or UDim2.new(1, -20, 0, 16)
	label.Position = opts.Position or UDim2.fromOffset(10, 30)
	label.BackgroundTransparency = 1
	label.Text = text or ""
	label.TextColor3 = UIStyle.Color.TooltipSecondary
	label.FontFace = UIStyle.FontFace.Inter
	label.TextSize = opts.TextSize or 12
	label.TextXAlignment = opts.TextXAlignment or Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextWrapped = opts.TextWrapped or false
	label.ZIndex = (parent.ZIndex or 1) + 1
	label.Parent = parent
	return label
end

function UIBuilder.tooltipFlavor(parent, text, opts)
	opts = opts or {}
	local label = Instance.new("TextLabel")
	label.Size = opts.Size or UDim2.new(1, -20, 0, 14)
	label.Position = opts.Position or UDim2.fromOffset(10, 60)
	label.BackgroundTransparency = 1
	label.Text = text or ""
	label.TextColor3 = UIStyle.Color.TooltipTertiary
	label.FontFace = UIStyle.FontFace.InterItalic
	label.TextSize = opts.TextSize or 11
	label.TextXAlignment = opts.TextXAlignment or Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextWrapped = opts.TextWrapped or false
	label.ZIndex = (parent.ZIndex or 1) + 1
	label.Parent = parent
	return label
end

function UIBuilder.generalLabel(parent, text, opts)
	opts = opts or {}
	local label = Instance.new("TextLabel")
	label.Size = opts.Size or UDim2.new(1, 0, 0, 14)
	label.Position = opts.Position or UDim2.fromOffset(0, 0)
	label.BackgroundTransparency = 1
	label.Text = text or ""
	label.TextColor3 = opts.color or UIStyle.Color.General
	label.FontFace = UIStyle.FontFace.Cinzel
	label.TextSize = opts.TextSize or 11
	label.TextXAlignment = opts.TextXAlignment or Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.ZIndex = (parent.ZIndex or 1) + 1
	label.Parent = parent
	return label
end

return UIBuilder
