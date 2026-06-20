local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))
local Platform = require(ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Modules"):WaitForChild("Platform"))

local CountryHeader = {}

local WIDGET_W = 380
local WIDGET_H = 78
local CREST_SIZE = 56
local ACCENT_W = 4

local function makeTintedBadge(parent, text, toneColor, layoutOrder)
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(0, UIStyle.Size.BadgeH)
	frame.AutomaticSize = Enum.AutomaticSize.X
	frame.BackgroundColor3 = toneColor
	frame.BackgroundTransparency = 0.82
	frame.BorderSizePixel = 0
	frame.ZIndex = UIStyle.Z.Chrome + 3
	frame.LayoutOrder = layoutOrder or 1
	frame.Parent = parent
	UIBuilder.corner(frame, 3)
	UIBuilder.stroke(frame, 1, toneColor)

	local lbl = Instance.new("TextLabel")
	lbl.AutomaticSize = Enum.AutomaticSize.X
	lbl.Size = UDim2.new(0, 0, 1, 0)
	lbl.BackgroundTransparency = 1
	lbl.Text = "  " .. string.upper(text or "") .. "  "
	lbl.TextColor3 = toneColor
	lbl.Font = UIStyle.Font.Bold
	lbl.TextSize = 10
	lbl.TextXAlignment = Enum.TextXAlignment.Center
	lbl.TextYAlignment = Enum.TextYAlignment.Center
	lbl.ZIndex = UIStyle.Z.Chrome + 4
	lbl.Parent = frame

	return frame, lbl
end

function CountryHeader.create(parent, onActivated)
	local btn = Instance.new("TextButton")
	btn.Name = "CountryHeader"
	btn.Size = UDim2.fromOffset(WIDGET_W, WIDGET_H)
	btn.Position = UDim2.new(0, 12, 1, -(UIStyle.Size.BottomBarH + 12))
	btn.AnchorPoint = Vector2.new(0, 1)
	btn.BackgroundColor3 = UIStyle.Color.Panel
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = false
	btn.Text = ""
	btn.ZIndex = UIStyle.Z.Chrome + 2
	btn.ClipsDescendants = true
	btn.Visible = false
	btn.Parent = parent
	UIBuilder.corner(btn, 4)
	local stroke = UIBuilder.stroke(btn, 1, UIStyle.Color.Border)

	local glowStroke = Instance.new("UIStroke")
	glowStroke.Thickness = 2
	glowStroke.Color = UIStyle.Color.Gold
	glowStroke.Transparency = 1
	glowStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	glowStroke.Parent = btn

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = btn

	-- Country-color accent strip
	local accent = Instance.new("Frame")
	accent.Name = "Accent"
	accent.Size = UDim2.new(0, ACCENT_W, 1, 0)
	accent.Position = UDim2.fromOffset(0, 0)
	accent.BackgroundColor3 = UIStyle.Color.PanelAlt
	accent.BorderSizePixel = 0
	accent.ZIndex = UIStyle.Z.Chrome + 3
	accent.Parent = btn

	-- Crest -- vertically centered after the accent strip
	local crestHolder = Instance.new("Frame")
	crestHolder.Size = UDim2.fromOffset(CREST_SIZE, CREST_SIZE)
	crestHolder.Position = UDim2.new(0, ACCENT_W + 10, 0.5, 0)
	crestHolder.AnchorPoint = Vector2.new(0, 0.5)
	crestHolder.BackgroundTransparency = 1
	crestHolder.ZIndex = UIStyle.Z.Chrome + 3
	crestHolder.Parent = btn

	local crest = UIBuilder.crest(crestHolder, UIStyle.Color.PanelAlt, "---", { size = CREST_SIZE })

	-- Info area (two rows: name on top, badges on bottom)
	local infoLeft = ACCENT_W + CREST_SIZE + 18
	local CHEVRON_RESERVE = 44
	local infoBox = Instance.new("Frame")
	infoBox.Size = UDim2.new(1, -(infoLeft + CHEVRON_RESERVE), 1, 0)
	infoBox.Position = UDim2.fromOffset(infoLeft, 0)
	infoBox.BackgroundTransparency = 1
	infoBox.ZIndex = UIStyle.Z.Chrome + 3
	infoBox.Parent = btn

	-- Row 1: Country name (top, bigger font)
	local nameLbl = Instance.new("TextLabel")
	nameLbl.Name = "Title"
	nameLbl.Size = UDim2.new(1, 0, 0, 26)
	nameLbl.Position = UDim2.fromOffset(0, 14)
	nameLbl.BackgroundTransparency = 1
	nameLbl.Text = "Realm"
	nameLbl.TextColor3 = UIStyle.Color.CreamBright
	nameLbl.FontFace = UIStyle.FontFace.CinzelBold
	nameLbl.TextSize = 21
	nameLbl.TextXAlignment = Enum.TextXAlignment.Left
	nameLbl.TextYAlignment = Enum.TextYAlignment.Center
	nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
	nameLbl.ZIndex = UIStyle.Z.Chrome + 4
	nameLbl.Parent = infoBox

	-- Row 2: Badge row aligned to crest bottom
	-- Crest bottom = WIDGET_H/2 + CREST_SIZE/2 = 39 + 28 = 67
	-- Badge row height = BadgeH (22). Position.Y = 67 - 22 = 45.
	local crestBottom = math.floor(WIDGET_H / 2 + CREST_SIZE / 2)
	local badgeRow = Instance.new("Frame")
	badgeRow.Size = UDim2.new(1, 0, 0, UIStyle.Size.BadgeH)
	badgeRow.Position = UDim2.fromOffset(0, crestBottom - UIStyle.Size.BadgeH - 6)
	badgeRow.BackgroundTransparency = 1
	badgeRow.ZIndex = UIStyle.Z.Chrome + 3
	badgeRow.Parent = infoBox

	local badgeLayout = Instance.new("UIListLayout")
	badgeLayout.FillDirection = Enum.FillDirection.Horizontal
	badgeLayout.Padding = UDim.new(0, 6)
	badgeLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	badgeLayout.SortOrder = Enum.SortOrder.LayoutOrder
	badgeLayout.Parent = badgeRow

	-- Larger circular chevron on the right
	local chevronBtn = Instance.new("Frame")
	chevronBtn.Size = UDim2.fromOffset(28, 28)
	chevronBtn.Position = UDim2.new(1, -12, 0.5, 0)
	chevronBtn.AnchorPoint = Vector2.new(1, 0.5)
	chevronBtn.BackgroundColor3 = UIStyle.Color.PanelAlt
	chevronBtn.BorderSizePixel = 0
	chevronBtn.ZIndex = UIStyle.Z.Chrome + 3
	chevronBtn.Parent = btn
	UIBuilder.corner(chevronBtn, 14)
	UIBuilder.stroke(chevronBtn, 1, UIStyle.Color.Gold)

	local chevron = Instance.new("TextLabel")
	chevron.Size = UDim2.fromScale(1, 1)
	chevron.BackgroundTransparency = 1
	chevron.Text = "\u{25B2}"
	chevron.TextColor3 = UIStyle.Color.Gold
	chevron.Font = UIStyle.Font.Bold
	chevron.TextSize = 14
	chevron.TextXAlignment = Enum.TextXAlignment.Center
	chevron.TextYAlignment = Enum.TextYAlignment.Center
	chevron.ZIndex = UIStyle.Z.Chrome + 4
	chevron.Parent = chevronBtn

	-- Hover lift + gold inner glow
	local hoverInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	if not Platform.isTouch then
		btn.MouseEnter:Connect(function()
			stroke.Color = UIStyle.Color.Gold
			btn.BackgroundColor3 = UIStyle.Color.PanelAlt
			if not UIStyle.ReduceMotion then
				TweenService:Create(scale, hoverInfo, { Scale = 1.02 }):Play()
				TweenService:Create(glowStroke, hoverInfo, { Transparency = 0.55 }):Play()
			else
				scale.Scale = 1.02
				glowStroke.Transparency = 0.55
			end
		end)
		btn.MouseLeave:Connect(function()
			stroke.Color = UIStyle.Color.Border
			btn.BackgroundColor3 = UIStyle.Color.Panel
			if not UIStyle.ReduceMotion then
				TweenService:Create(scale, hoverInfo, { Scale = 1 }):Play()
				TweenService:Create(glowStroke, hoverInfo, { Transparency = 1 }):Play()
			else
				scale.Scale = 1
				glowStroke.Transparency = 1
			end
		end)
	end

	if onActivated then
		btn.Activated:Connect(onActivated)
	end

	local function setCountry(tag, displayName, colorRGB, govLabel, ideologyLabel, flagAssetId)
		if not tag then
			btn.Visible = false
			return
		end
		btn.Visible = true
		local color = colorRGB and Color3.fromRGB(colorRGB[1], colorRGB[2], colorRGB[3]) or UIStyle.Color.PanelAlt
		accent.BackgroundColor3 = color

		if crest then crest:Destroy() end
		crest = UIBuilder.crest(crestHolder, color, tag, { size = CREST_SIZE, flag = flagAssetId })
		nameLbl.Text = displayName or tag or "Realm"

		for _, c in badgeRow:GetChildren() do
			if c:IsA("Frame") then c:Destroy() end
		end
		if govLabel and govLabel ~= "" then
			makeTintedBadge(badgeRow, govLabel, UIStyle.Color.TextMuted, 1)
		end
		if ideologyLabel and ideologyLabel ~= "" then
			makeTintedBadge(badgeRow, ideologyLabel, UIStyle.Color.Info, 2)
		end
	end

	local function setOpenState(isOpen)
		chevron.Text = isOpen and "\u{25BC}" or "\u{25B2}"
	end

	local function setVisible(flag)
		btn.Visible = flag and true or false
	end

	return {
		root = btn,
		setCountry = setCountry,
		setVisible = setVisible,
		setOpenState = setOpenState,
		width = WIDGET_W,
		height = WIDGET_H,
	}
end

CountryHeader.WIDTH = WIDGET_W
CountryHeader.HEIGHT = WIDGET_H

return CountryHeader
