local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography

local CountryBadge = {}

local SIZES = {
	sm = { width = 36, height = 28, fontSize = 11 },
	md = { width = 48, height = 40, fontSize = 14 },
	lg = { width = 64, height = 52, fontSize = 18 },
}

function CountryBadge.create(config)
	config = config or {}
	local s = SIZES[config.size or "md"] or SIZES.md

	local raw = config.countryColor
	local color
	if typeof(raw) == "Color3" then
		color = raw
	elseif type(raw) == "table" and raw[1] then
		color = Color3.fromRGB(raw[1], raw[2], raw[3])
	else
		color = Color3.fromRGB(80, 80, 80)
	end
	local h, sat, v = Color3.toHSV(color)
	local darkBg = Color3.fromHSV(h, math.min(sat, 0.6), math.min(v, 0.35))

	local badge = Instance.new("Frame")
	badge.Name = "CountryBadge"
	badge.Size = UDim2.fromOffset(s.width, s.height)
	badge.BackgroundColor3 = darkBg
	badge.BorderSizePixel = 0
	badge.LayoutOrder = config.layoutOrder or 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = badge

	local stroke = Instance.new("UIStroke")
	stroke.Color = Colors.BorderSubtle
	stroke.Thickness = 1
	stroke.Transparency = 0.5
	stroke.Parent = badge

	local label = Instance.new("TextLabel")
	label.Name = "Code"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = string.upper(config.code or "XXX")
	label.TextColor3 = Colors.TextPrimary
	label.FontFace = Typography.Mono
	label.TextSize = s.fontSize
	label.Parent = badge

	if config.parent then
		badge.Parent = config.parent
	end
	return badge
end

return CountryBadge
