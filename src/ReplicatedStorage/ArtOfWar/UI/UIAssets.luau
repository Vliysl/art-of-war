local function id(n)
	return "rbxassetid://" .. tostring(n)
end

local UIAssets = {}

UIAssets.Btn = {
	Panel = {
		Default  = id(85702156958072),
		Hover    = id(130016111534771),
		Disabled = id(137251282676150),
	},
	Stroke = {
		Default  = id(75720904781343),
		Hover    = id(112041046359091),
		Disabled = id(135849383720328),
	},
	Bracket = {
		TL = id(101772359800958),
		TR = id(91624005154949),
		BL = id(81066501291130),
		BR = id(139060617878581),
		Hover = {
			TL = id(97783803692944),
			TR = id(104174403841521),
			BL = id(135379791751754),
			BR = id(131917264895202),
		},
	},
}

UIAssets.Compact = {
	Panel = {
		Default = id(78909444956377),
		Hover   = id(103732157817274),
	},
	Stroke = {
		Default = id(87870390155259),
	},
	Arrow = {
		Default = id(91965816030791),
		Hover   = id(83972522663325),
	},
	IconHolder = {
		Default = id(126494941327662),
		Hover   = id(112983982839095),
	},
	Divider = {
		Default = id(111251760259335),
		Hover   = id(95852820212037),
	},
	TopLine = {
		Hover = id(86400074218848),
	},
}

return UIAssets
