local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local CountryColor = require(script.Parent.Parent.Parent.Modules.CountryColor)

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
	-- Decal: explicit config.flag wins; otherwise resolve the country's crest from LIVE replicated state
	-- (CountryColor.resolveFlag: authored/formed/released crests), falling back to the static Data table.
	-- Empty -> the colour + tag show through (the intended state for uncrested/tribal nations).
	local flag = config.flag
	if (not flag or flag == "") and config.code then
		flag = CountryColor.resolveFlag(config.code)
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

	-- Persistent "formed" marker (RON-style): a small gold star in the corner when this nation has adopted a
	-- formable identity. Suppress with config.noFormedMarker (e.g. tiny/dense surfaces).
	if config.code and not config.noFormedMarker and CountryColor.isFormed(config.code) then
		local star = Instance.new("TextLabel")
		star.Name = "FormedMark"
		star.AnchorPoint = Vector2.new(1, 0)
		star.Position = UDim2.new(1, -1, 0, 0)
		star.Size = UDim2.fromOffset(12, 12)
		star.BackgroundTransparency = 1
		star.Text = "\u{2605}" -- ★
		star.TextColor3 = Color3.fromRGB(212, 175, 55)
		star.TextScaled = true
		star.ZIndex = 4
		star.Parent = badge
	end

	if config.parent then
		badge.Parent = config.parent
	end
	return badge
end

return CountryBadge
