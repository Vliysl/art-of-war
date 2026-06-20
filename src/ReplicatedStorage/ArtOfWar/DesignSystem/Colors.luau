local Colors = {
	SurfaceBase = Color3.fromRGB(15, 14, 11),
	SurfaceElevated = Color3.fromRGB(22, 20, 16),
	SurfaceOverlay = Color3.fromRGB(28, 25, 20),
	SurfaceSunken = Color3.fromRGB(10, 9, 7),

	BorderSubtle = Color3.fromRGB(58, 47, 31),
	BorderStrong = Color3.fromRGB(82, 67, 44),
	BorderActive = Color3.fromRGB(245, 210, 122),

	TextPrimary = Color3.fromRGB(245, 241, 232),
	TextSecondary = Color3.fromRGB(138, 126, 106),
	TextTertiary = Color3.fromRGB(107, 104, 98),
	TextDisabled = Color3.fromRGB(74, 71, 66),
	TextInverse = Color3.fromRGB(15, 14, 11),

	Positive = Color3.fromRGB(91, 143, 106),
	PositiveSubtle = Color3.fromRGB(45, 70, 53),
	Negative = Color3.fromRGB(196, 74, 69),
	NegativeSubtle = Color3.fromRGB(95, 35, 33),
	Warning = Color3.fromRGB(212, 166, 71),
	WarningSubtle = Color3.fromRGB(105, 82, 35),
	Accent = Color3.fromRGB(245, 210, 122),
	AccentHover = Color3.fromRGB(255, 220, 130),

	FactionMonarchist = Color3.fromRGB(146, 88, 142),
	FactionAristocrat = Color3.fromRGB(170, 117, 56),
	FactionClergy = Color3.fromRGB(180, 170, 150),
	FactionMerchant = Color3.fromRGB(86, 130, 156),
	FactionIntellectual = Color3.fromRGB(108, 124, 168),
	FactionPopulist = Color3.fromRGB(168, 81, 76),
	FactionMilitary = Color3.fromRGB(76, 96, 80),
}

local SEMANTIC = {
	positive = Colors.Positive,
	negative = Colors.Negative,
	warning = Colors.Warning,
	accent = Colors.Accent,
	primary = Colors.TextPrimary,
	secondary = Colors.TextSecondary,
	tertiary = Colors.TextTertiary,
}

function Colors.resolve(key)
	return SEMANTIC[key] or Colors.TextPrimary
end

function Colors.delta(value)
	if type(value) ~= "number" then
		return Colors.TextSecondary
	end
	if value > 0 then
		return Colors.Positive
	end
	if value < 0 then
		return Colors.Negative
	end
	return Colors.TextSecondary
end

return Colors
