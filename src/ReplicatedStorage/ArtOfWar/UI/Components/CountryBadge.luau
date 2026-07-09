local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local CountriesData = require(script.Parent.Parent.Parent.Data.Countries)

local CountryBadge = {}

-- All crests are a uniform 44x44 SQUARE (matching the on-map unit-banner crest in
-- Modules/ArmyView.luau buildBannerGui), so they can later be swapped for image decals.
-- The sm/md/lg keys are kept for back-compat but only select the tag font size now.
local CREST_SIZE = 44
local FONT_SIZE = { sm = 14, md = 16, lg = 18 }

function CountryBadge.create(config)
	config = config or {}
	local fontSize = FONT_SIZE[config.size or "md"] or FONT_SIZE.md
	local crestSize = config.px or CREST_SIZE -- 44 default; callers (e.g. the country bar) may fill a larger slot

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
	badge.Size = UDim2.fromOffset(crestSize, crestSize)
	badge.BackgroundColor3 = darkBg
	badge.BorderSizePixel = 0
	badge.LayoutOrder = config.layoutOrder or 0

	if not config.square then
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 4)
		corner.Parent = badge
	end

	local stroke = Instance.new("UIStroke")
	stroke.Color = Colors.BorderSubtle
	stroke.Thickness = 1
	stroke.Transparency = 0.5
	stroke.Parent = badge

	-- Decal slot (coat of arms). Empty today -> the colour + tag show through; set config.flag to an
	-- asset id later and the cropped image covers the colour+tag, exactly like the unit-banner crest.
	local crestImg = Instance.new("ImageLabel")
	crestImg.Name = "CrestImage"
	crestImg.Size = UDim2.fromScale(1, 1)
	crestImg.BackgroundTransparency = 1
	-- Decal: explicit config.flag wins; otherwise pull the country's flagAssetId from replicated state
	-- (set in Data/Countries.luau). Empty -> the colour + tag show through.
	local flag = config.flag
	if (not flag or flag == "") and config.code then
		local cd = CountriesData[config.code]
		flag = (cd and cd.flagAssetId) or nil
	end
	crestImg.Image = flag or ""
	crestImg.ScaleType = Enum.ScaleType.Crop
	crestImg.ZIndex = 2
	crestImg.Parent = badge
	if not config.square then
		local crestImgCorner = Instance.new("UICorner")
		crestImgCorner.CornerRadius = UDim.new(0, 4)
		crestImgCorner.Parent = crestImg
	end

	local label = Instance.new("TextLabel")
	label.Name = "Code"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = string.upper(config.code or "XXX")
	label.TextColor3 = Colors.TextPrimary
	label.FontFace = Typography.Mono
	label.TextSize = fontSize
	label.ZIndex = 3
	-- When a decal is present, the coat of arms replaces the 3-letter tag.
	label.Visible = (flag == nil or flag == "")
	label.Parent = badge

	if config.parent then
		badge.Parent = config.parent
	end
	return badge
end

return CountryBadge
