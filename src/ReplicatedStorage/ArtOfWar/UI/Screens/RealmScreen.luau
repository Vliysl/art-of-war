local ScreenKit = require(script.Parent.ScreenKit)
local PoliticsScreen = require(script.Parent.PoliticsScreen)
local DiplomacyScreen = require(script.Parent.DiplomacyScreen)

local RealmScreen = {}

-- The "Realm" window opened from the CountryBar crest. One window, ONE flat tab bar with four peer tabs:
-- Court / Estates / Reforms (the three PoliticsScreen panes) + Diplomacy. It hosts two bodies below the
-- header -- a Politics body and a Diplomacy body -- each LAZY-MOUNTED the first time its tab is shown, then
-- shown/hidden per tab (so a controller's cache subscriptions + view state survive tab switches). Lazy mounting
-- matters: the Diplomacy list can hold 700+ countries, so building it on open (even when the user only wants
-- Court) freezes the window -- deferring it until the Diplomacy tab is actually clicked keeps opening snappy.
--   * Court/Estates/Reforms  -> show the Politics body, drive its pane via politicsCtrl.setPane(key)
--   * Diplomacy               -> show the Diplomacy body (its list/profile nav is internal)
local TABS = {
	{ key = "overview", label = "Court" },
	{ key = "estates", label = "Estates" },
	{ key = "reforms", label = "Reforms" },
	{ key = "diplomacy", label = "Diplomacy" },
}

-- Accept a tab key ("overview"/"estates"/"reforms"/"diplomacy") or a friendly name ("Diplomacy", "Court")
-- and resolve to a valid tab key; anything unknown falls back to Court.
local function normalizeTab(t)
	if type(t) ~= "string" then
		return "overview"
	end
	local low = string.lower(t)
	for _, tab in TABS do
		if tab.key == low then
			return tab.key
		end
	end
	if low == "court" then
		return "overview"
	end
	return "overview"
end

function RealmScreen.create(ctx)
	local data = ctx.data or {}
	local initial = normalizeTab(data.initialTab)

	-- Forward-declared so the tab bar's onChange (built inside ScreenKit.open) can call it; it's only ever
	-- invoked on a user tab click, by which point the panes + selectTab below have been assigned.
	local selectTab

	local win = ScreenKit.open(ctx, {
		name = "RealmScreen",
		title = "Realm",
		tabs = TABS,
		activeTab = initial,
		noBody = true,
		size = UDim2.new(0, 512, 1, -132),
		onTab = function(key)
			selectTab(key)
		end,
	})

	-- Two panes filling the content region under the header. Politics/Diplomacy each build their own scroll
	-- body inside their pane (via ScreenKit.body) when first mounted, so the panes start as empty frames.
	local function makePane()
		local p = Instance.new("Frame")
		p.BackgroundTransparency = 1
		p.BorderSizePixel = 0
		p.Position = UDim2.fromOffset(0, win.headerHeight)
		p.Size = UDim2.new(1, 0, 1, -win.headerHeight)
		p.ZIndex = 2
		p.Parent = win.root
		return p
	end
	local politicsPane = makePane()
	local diplomacyPane = makePane()

	-- Controllers are mounted lazily on first activation (see the module note re: the 700-country list).
	local politicsCtrl, diploCtrl

	selectTab = function(key)
		if key == "diplomacy" then
			politicsPane.Visible = false
			diplomacyPane.Visible = true
			if not diploCtrl then
				diploCtrl = DiplomacyScreen.mount(diplomacyPane, ctx)
			end
		else
			diplomacyPane.Visible = false
			politicsPane.Visible = true
			if not politicsCtrl then
				politicsCtrl = PoliticsScreen.mount(politicsPane, ctx)
			end
			if politicsCtrl.setPane then
				politicsCtrl.setPane(key)
			end
		end
	end
	selectTab(initial)

	return {
		root = win.root,
		destroy = function()
			if politicsCtrl and politicsCtrl.destroy then
				politicsCtrl.destroy()
			end
			if diploCtrl and diploCtrl.destroy then
				diploCtrl.destroy()
			end
			win.destroy()
		end,
	}
end

return RealmScreen
