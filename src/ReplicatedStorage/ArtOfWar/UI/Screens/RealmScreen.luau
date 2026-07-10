local ScreenKit = require(script.Parent.ScreenKit)
local DiplomacyScreen = require(script.Parent.DiplomacyScreen)

local RealmScreen = {}

-- The "Realm" window opened from the CountryBar crest (and via Hud.openCountryProfile deep-links). Court /
-- Estates / Reforms -- the three PoliticsScreen panes -- were CUT ahead of the public playtest (undercooked);
-- Diplomacy is now the sole pane. Kept as a single-tab window so the crest -> Realm -> Diplomacy flow and
-- DiplomacyScreen's internal list/profile navigation (incl. ctx.data.focusTag deep-links) are unchanged.
local TABS = {
	{ key = "diplomacy", label = "Diplomacy" },
}

function RealmScreen.create(ctx)
	local win = ScreenKit.open(ctx, {
		name = "RealmScreen",
		title = "Realm",
		tabs = TABS,
		activeTab = "diplomacy",
		noBody = true,
		size = UDim2.new(0, 512, 1, -132),
		onTab = function() end,
	})

	-- Single Diplomacy pane filling the content region under the header. DiplomacyScreen.mount builds its own
	-- scroll body inside the pane and owns its list/profile nav; ctx (incl. ctx.data.focusTag) is passed
	-- through unchanged so province-crest deep-links still land on the right profile.
	local pane = Instance.new("Frame")
	pane.BackgroundTransparency = 1
	pane.BorderSizePixel = 0
	pane.Position = UDim2.fromOffset(0, win.headerHeight)
	pane.Size = UDim2.new(1, 0, 1, -win.headerHeight)
	pane.ZIndex = 2
	pane.Parent = win.root

	local diploCtrl = DiplomacyScreen.mount(pane, ctx)

	return {
		root = win.root,
		destroy = function()
			if diploCtrl and diploCtrl.destroy then
				diploCtrl.destroy()
			end
			win.destroy()
		end,
	}
end

return RealmScreen
