local ScreenKit = require(script.Parent.ScreenKit)

local ResearchScreen = {}

-- Research is being reworked ahead of the public playtest: the flat technology-list system was CUT (it is not
-- the intended design for the game). The screen now shows a single "coming soon" placeholder. The server-side
-- ResearchSystem is left running but is now unreachable from the UI (no tech can be selected), so no state
-- regresses -- research simply does not progress until the rework lands.
function ResearchScreen.create(ctx)
	local handle = ScreenKit.open(ctx, {
		name = "ResearchScreen",
		title = "Research",
		subtitle = "Technology",
		size = UDim2.new(0, 440, 0, 0),
		autoHeight = true,
	})

	ScreenKit.section(handle.body, "Coming Soon", 1)
	ScreenKit.note(
		handle.body,
		"Research is being reworked and will return in a future update. Technology is disabled for this playtest.",
		2
	)

	return {
		root = handle.root,
		destroy = function()
			handle.destroy()
		end,
	}
end

return ResearchScreen
