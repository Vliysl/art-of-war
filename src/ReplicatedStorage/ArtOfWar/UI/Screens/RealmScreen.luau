local ScreenKit = require(script.Parent.ScreenKit)
local DiplomacyScreen = require(script.Parent.DiplomacyScreen)
local FormablesScreen = require(script.Parent.FormablesScreen)

local RealmScreen = {}

-- The "Realm" window opened from the CountryBar crest (and via Hud.openCountryProfile deep-links). This is the
-- touch-reachable home for "your nation": a Diplomacy pane and a Nation pane (formables + releasables). The
-- Nation tab makes the formables goal loop reachable on mobile, where there is no keyboard (hotkey 6) or
-- hamburger. Court / Estates / Reforms (the old PoliticsScreen panes) remain cut. ctx.data.focusTag still
-- deep-links into the Diplomacy pane.
local TABS = {
	{ key = "diplomacy", label = "Diplomacy" },
	{ key = "nation", label = "Nation" },
}

local function makePane(win)
	local pane = Instance.new("Frame")
	pane.BackgroundTransparency = 1
	pane.BorderSizePixel = 0
	pane.Position = UDim2.fromOffset(0, win.headerHeight)
	pane.Size = UDim2.new(1, 0, 1, -win.headerHeight)
	pane.ZIndex = 2
	pane.Parent = win.root
	return pane
end

function RealmScreen.create(ctx)
	-- Forward-declare the panes so the onTab handler (captured by the TabBar at creation) can toggle them.
	local diploPane, nationPane
	local function selectTab(key)
		if diploPane then
			diploPane.Visible = (key == "diplomacy")
		end
		if nationPane then
			nationPane.Visible = (key == "nation")
		end
	end

	local win = ScreenKit.open(ctx, {
		name = "RealmScreen",
		title = "Realm",
		tabs = TABS,
		activeTab = "diplomacy",
		noBody = true,
		size = UDim2.new(0, 512, 1, -132),
		onTab = selectTab,
	})

	-- Both panes fill the content region under the header; one is Visible at a time. Each screen's mount()
	-- builds its own scroll body and owns its internal nav. Diplomacy shows first (matches activeTab).
	diploPane = makePane(win)
	nationPane = makePane(win)
	nationPane.Visible = false

	local diploCtrl = DiplomacyScreen.mount(diploPane, ctx)
	local nationCtrl = FormablesScreen.mount(nationPane, ctx)

	return {
		root = win.root,
		destroy = function()
			if diploCtrl and diploCtrl.destroy then
				diploCtrl.destroy()
			end
			if nationCtrl and nationCtrl.destroy then
				nationCtrl.destroy()
			end
			win.destroy()
		end,
	}
end

return RealmScreen
