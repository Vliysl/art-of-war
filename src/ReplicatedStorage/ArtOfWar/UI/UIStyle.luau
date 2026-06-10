local UIStyle = {}

UIStyle.Color = {
	Bg             = Color3.fromRGB( 18,  14,   9),
	Panel          = Color3.fromRGB( 36,  28,  17),
	PanelAlt       = Color3.fromRGB( 56,  44,  26),
	PanelHigh      = Color3.fromRGB( 78,  62,  36),
	PanelHeader    = Color3.fromRGB( 46,  36,  22),
	PanelDisabled  = Color3.fromRGB( 70,  58,  40),
	Border         = Color3.fromRGB(132,  96,  40),
	BorderStrong   = Color3.fromRGB(218, 168,  84),
	BorderDim      = Color3.fromRGB( 78,  60,  30),
	Text           = Color3.fromRGB(246, 238, 214),
	TextMuted      = Color3.fromRGB(196, 164, 110),
	TextDim        = Color3.fromRGB(132, 102,  62),
	Gold           = Color3.fromRGB(218, 168,  84),
	GoldBright     = Color3.fromRGB(250, 222, 138),
	GoldDim        = Color3.fromRGB(160, 112,  40),
	Cream          = Color3.fromRGB(222, 196, 138),
	CreamBright    = Color3.fromRGB(248, 240, 218),
	CreamPale      = Color3.fromRGB(232, 212, 156),
	Good           = Color3.fromRGB( 75, 183,  52),
	Bad            = Color3.fromRGB(190,  36,  26),
	Crisis         = Color3.fromRGB(218,  48,  38),
	Warn           = Color3.fromRGB(220, 176,  80),
	Info           = Color3.fromRGB(118, 158, 200),
	BadgeGreenBg   = Color3.fromRGB( 33,  58,  20),
	BadgeRedBg     = Color3.fromRGB( 70,  20,  18),
	ShieldGlow     = Color3.fromRGB(238, 208, 112),
	MapPolitical   = Color3.fromRGB(201, 162,  75),
	MapTerrain     = Color3.fromRGB(128, 168, 114),
	MapTrade       = Color3.fromRGB(180, 148, 102),
	MapCulture     = Color3.fromRGB(158, 128, 184),
	MapReligion    = Color3.fromRGB(214, 170,  94),
	MapDiplomatic  = Color3.fromRGB(118, 158, 200),

	SecondaryDefault   = Color3.fromRGB(248, 240, 218),
	SecondaryHover     = Color3.fromRGB(255, 252, 232),
	SecondaryDisabled  = Color3.fromRGB(140, 110,  70),
	CompactDefault     = Color3.fromRGB(244, 226, 184),
	CompactHover       = Color3.fromRGB(255, 244, 212),
	TooltipPrimary     = Color3.fromRGB(220, 176,  80),
	TooltipSecondary   = Color3.fromRGB(206, 180, 120),
	TooltipTertiary    = Color3.fromRGB(154, 120,  72),
	LedgerSection      = Color3.fromRGB(138,  90,  24),
	LedgerLabel        = Color3.fromRGB(154, 120,  72),
	LedgerValue        = Color3.fromRGB(200, 144,  58),
	LedgerPositive     = Color3.fromRGB(222, 202, 144),
	LedgerNegative     = Color3.fromRGB(150,  20,  20),
	LedgerStable       = Color3.fromRGB(222, 202, 144),
	LedgerCrisis       = Color3.fromRGB(184,  30,  30),
	LedgerStabilityPos = Color3.fromRGB( 59, 128,   0),
	General            = Color3.fromRGB(138,  90,  24),
}

UIStyle.Color.Parchment       = UIStyle.Color.PanelAlt
UIStyle.Color.ParchmentDark   = UIStyle.Color.Bg
UIStyle.Color.ParchmentShadow = UIStyle.Color.BorderDim
UIStyle.Color.Ink             = UIStyle.Color.Text
UIStyle.Color.InkMuted        = UIStyle.Color.TextMuted
UIStyle.Color.WoodFrame       = UIStyle.Color.Bg
UIStyle.Color.WoodFrameLight  = UIStyle.Color.BorderStrong
UIStyle.Color.StateGood       = UIStyle.Color.Good
UIStyle.Color.StateBad        = UIStyle.Color.Bad
UIStyle.Color.StateNeutral    = UIStyle.Color.TextMuted

UIStyle.Font = {
	Display  = Enum.Font.Garamond,
	Serif    = Enum.Font.Garamond,
	SerifAlt = Enum.Font.Antique,
	Bold     = Enum.Font.GothamBold,
	Semibold = Enum.Font.GothamSemibold,
	Regular  = Enum.Font.Gotham,
	Mono     = Enum.Font.RobotoMono,
}
UIStyle.Font.SansBold     = UIStyle.Font.Bold
UIStyle.Font.SansSemibold = UIStyle.Font.Semibold
UIStyle.Font.Sans         = UIStyle.Font.Regular

UIStyle.FontFace = {
	Cinzel       = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal),
	CinzelBold   = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Heavy, Enum.FontStyle.Normal),
	Inter        = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Regular, Enum.FontStyle.Normal),
	InterMedium  = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Medium, Enum.FontStyle.Normal),
	InterBold    = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal),
	InterItalic  = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Regular, Enum.FontStyle.Italic),
}

UIStyle.Type = {
	Display       = { font = UIStyle.Font.Serif,    size = 28 },
	H1            = { font = UIStyle.Font.Serif,    size = 24 },
	H2            = { font = UIStyle.Font.Serif,    size = 19 },
	Title         = { font = UIStyle.Font.Serif,    size = 21 },
	SectionHeader = { font = UIStyle.Font.Bold,     size = 13 },
	Eyebrow       = { font = UIStyle.Font.Semibold, size = 10 },
	Caption       = { font = UIStyle.Font.Semibold, size = 10 },
	CountryName   = { font = UIStyle.Font.Serif,    size = 20 },
	StatValue     = { font = UIStyle.Font.Bold,     size = 14 },
	Stat          = { font = UIStyle.Font.Bold,     size = 14 },
	StatLabel     = { font = UIStyle.Font.Regular,  size = 12 },
	TabActive     = { font = UIStyle.Font.Bold,     size = 13 },
	TabInactive   = { font = UIStyle.Font.Regular,  size = 13 },
	Button        = { font = UIStyle.Font.Semibold, size = 13 },
	ButtonPrimary = { font = UIStyle.Font.Bold,     size = 13 },
	Body          = { font = UIStyle.Font.Regular,  size = 13 },
	Small         = { font = UIStyle.Font.Regular,  size = 11 },
	Mono          = { font = UIStyle.Font.Mono,     size = 12 },
}

UIStyle.Size = {
	PanelPaddingX    = 12,
	PanelPaddingY    = 12,
	SectionHeaderH   = 30,
	StatRowH         = 22,
	ButtonH          = 28,
	DividerH         = 1,
	ShieldW          = 40,
	ShieldH          = 48,
	CrestSize        = 44,
	StrokeThin       = 1,
	StrokeMedium     = 1,
	StrokeFrame      = 1,
	CornerPanel      = 3,
	CornerButton     = 2,
	CornerPill       = 14,
	TopBarH          = 44,
	BottomBarH       = 44,
	LeftRailW        = 360,
	RightPanelW      = 400,
	ProvinceTooltipW = 280,
	ProvinceTooltipH = 128,
	ArmyPanelW       = 640,
	ArmyPanelH       = 104,
	MinimapW         = 300,
	MinimapH         = 216,
	PillH            = 26,
	ChipH            = 22,
	BadgeH           = 18,
	TabH             = 30,
	TooltipMaxW      = 280,
}

UIStyle.Z = {
	Background   = 1,
	Chrome       = 10,
	Content      = 20,
	Panel        = 20,
	PanelHeader  = 21,
	Accent       = 22,
	Transient    = 50,
	Window       = 60,
	Tooltip      = 50,
	Modal        = 100,
	Overlay      = 100,
	Toast        = 150,
}

UIStyle.Anchor = {
	UpperLeft    = Vector2.new(0, 0),
	UpperRight   = Vector2.new(1, 0),
	LowerLeft    = Vector2.new(0, 1),
	LowerRight   = Vector2.new(1, 1),
	Center       = Vector2.new(0.5, 0.5),
	CenterLeft   = Vector2.new(0, 0.5),
	CenterRight  = Vector2.new(1, 0.5),
	TopCenter    = Vector2.new(0.5, 0),
	BottomCenter = Vector2.new(0.5, 1),
}

UIStyle.Motion = {
	Hover  = { time = 0.10, style = Enum.EasingStyle.Quad,  dir = Enum.EasingDirection.Out },
	Fast   = { time = 0.14, style = Enum.EasingStyle.Quad,  dir = Enum.EasingDirection.Out },
	Medium = { time = 0.22, style = Enum.EasingStyle.Back,  dir = Enum.EasingDirection.Out },
	Panel  = { time = 0.28, style = Enum.EasingStyle.Cubic, dir = Enum.EasingDirection.Out },
	Slow   = { time = 0.40, style = Enum.EasingStyle.Quint, dir = Enum.EasingDirection.InOut },
}

UIStyle.ReduceMotion = false

UIStyle.Icon = {
	Treasury="", Manpower="", PowerProj="", Stability="", Legitimacy="", Prestige="",
	Research="", Trade="", Culture="", Religion="", Army="", Navy="", Province="",
	Development="", Autonomy="", Unrest="", Core="", Diplomacy="", War="",
	Pause="", Play="", FF1="", FF2="", FF3="", FF4="", FF5="",
	Menu="", Search="", Close="", Pin="", Check="", Warning="",
	ChevronDown="", ChevronUp="",
	MapPolitical="", MapTerrain="", MapTrade="", MapCulture="", MapReligion="",
	TabOverview="", TabFactions="", TabLeaders="", TabPolicies="", TabLaws="", TabDoctrines="",
}

UIStyle.IconFallback = {
	Treasury    = "$",
	Manpower    = "\u{25A0}",   -- black square
	PowerProj   = "\u{2605}",   -- black star
	Stability   = "\u{25B2}",   -- up triangle
	Legitimacy  = "\u{2666}",   -- diamond suit
	Prestige    = "\u{2606}",   -- white star
	Research    = "\u{25CF}",   -- black circle
	Trade       = "$",
	Culture     = "\u{25C6}",   -- black diamond (shape, not suit)
	Religion    = "+",
	Army        = "\u{25B2}",
	Navy        = "\u{25BD}",   -- down triangle
	Province    = "\u{25A1}",   -- white square
	Development = "\u{25B2}",
	Autonomy    = "\u{25CB}",   -- white circle
	Unrest      = "!",
	Core        = "\u{25CF}",
	Diplomacy   = "\u{25C6}",
	War         = "\u{2715}",   -- multiplication X
	Pause       = "II",
	Play        = "\u{25B6}",
	FF1 = "\u{25B6}", FF2 = "\u{00BB}", FF3 = "\u{00BB}\u{00BB}", FF4 = "\u{00BB}\u{00BB}\u{00BB}", FF5 = "\u{00BB}\u{00BB}\u{00BB}\u{00BB}",
	Menu        = "=",
	Search      = "?",
	Close       = "\u{2715}",
	Pin         = "\u{25C6}",
	Check       = "\u{2713}",
	Warning     = "!",
	ChevronDown = "\u{25BC}",
	ChevronUp   = "\u{25B2}",
	MapPolitical = "\u{25C6}",
	MapTerrain   = "\u{25B3}",
	MapTrade     = "$",
	MapCulture   = "\u{25C6}",
	MapReligion  = "+",
	TabOverview  = "i",
	TabFactions  = "\u{25C6}",
	TabLeaders   = "\u{2605}",
	TabPolicies  = "=",
	TabLaws      = "\u{00A7}",
	TabDoctrines = "\u{25B2}",
}

function UIStyle.applyType(label, token)
	if not token then return end
	if token.fontFace and typeof(token.fontFace) == "Font" then
		label.FontFace = token.fontFace
	elseif typeof(token.font) == "Font" then
		label.FontFace = token.font
	elseif token.font then
		label.Font = token.font
	end
	if token.size then label.TextSize = token.size end
	if label:IsA("TextLabel") or label:IsA("TextButton") or label:IsA("TextBox") then
		label.LineHeight = token.lineHeight or 1.1
		label.RichText = label.RichText or false
	end
end

function UIStyle.stateColor(delta)
	if type(delta) ~= "number" then return UIStyle.Color.TextMuted end
	if delta > 0 then return UIStyle.Color.Good end
	if delta < 0 then return UIStyle.Color.Bad end
	return UIStyle.Color.TextMuted
end

function UIStyle.tween(spec)
	spec = spec or UIStyle.Motion.Medium
	return TweenInfo.new(
		UIStyle.ReduceMotion and 0 or spec.time,
		spec.style or Enum.EasingStyle.Quad,
		spec.dir or Enum.EasingDirection.Out
	)
end

return UIStyle
