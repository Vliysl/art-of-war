local Typography = {}

Typography.Serif =
	Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Regular, Enum.FontStyle.Normal)
Typography.SerifBold =
	Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.SemiBold, Enum.FontStyle.Normal)
Typography.Sans = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Regular, Enum.FontStyle.Normal)
Typography.SansMedium =
	Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium, Enum.FontStyle.Normal)
Typography.SansBold = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal)
Typography.Mono = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal)

Typography.displayXl = 32
Typography.displayLg = 24
Typography.displayMd = 18
Typography.bodyLg = 16
Typography.bodyMd = 14
Typography.bodySm = 12
Typography.caption = 11

local ROLES = {
	displayXl = { Typography.SerifBold, 32 },
	displayLg = { Typography.SerifBold, 24 },
	displayMd = { Typography.Serif, 18 },
	title = { Typography.SerifBold, 20 },
	bodyLg = { Typography.SansMedium, 16 },
	bodyMd = { Typography.Sans, 14 },
	label = { Typography.SansMedium, 13 },
	value = { Typography.SansBold, 14 },
	bodySm = { Typography.Sans, 12 },
	caption = { Typography.SansBold, 11 },
	mono = { Typography.Mono, 14 },
}

function Typography.apply(label, role)
	local r = ROLES[role or "bodyMd"]
	if not r then
		return
	end
	label.FontFace = r[1]
	label.TextSize = r[2]
end

return Typography
