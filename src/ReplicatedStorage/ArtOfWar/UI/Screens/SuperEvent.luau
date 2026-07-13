-- SuperEvent — the "a nation has formed / was released" announcement, styled as a period BROADSHEET (a
-- Hearts-of-Iron-IV news-event front page) in Art of War's dark parchment + gold palette: an ornate framed
-- page with a Bodoni masthead, double rule, a dateline (in-game date), a framed headline photo, a serif
-- headline + article body, and a single acknowledge button. Non-blocking, auto-dismissing, shown top-centre
-- to everyone. Reusable: the game shows it via Hud.showSuperEvent (server broadcast); the Data Editor
-- previews it locally.
--
-- payload = { title, body, buttonText?, imageId?, audioId?, tag?, color?, date?, ttl? }
--   imageId -- headline photo; when blank, resolves the tag's crest (CountryColor.resolveFlag), else placeholder
--   date    -- { year, month, day } in-game date for the dateline (blank => dateline without a day)
--   audioId -- one-shot sting (blank = silent); UISound.playAssetId honours the Formation Audio mute
--   color   -- {r,g,b} nation accent (tints the top rule); defaults to gold
-- opts = { ttl?, parent?, onDismiss? }

local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Shells = DesignSystem.Shells
local CountryColor = require(script.Parent.Parent.Parent.Modules.CountryColor)
local UISound = require(script.Parent.Parent.UISound)

local SuperEvent = {}

local MASTHEAD = "The Gazette" -- the fixed broadsheet name (period-accurate: London/France Gazettes, c.1750)
local INK = Colors.TextPrimary -- warm ivory, our "ink on the page"
local SEPIA = Colors.TextSecondary -- muted taupe for datelines/captions
local GOLD = Colors.Accent
local MONTHS = {
	"January",
	"February",
	"March",
	"April",
	"May",
	"June",
	"July",
	"August",
	"September",
	"October",
	"November",
	"December",
}

local function toColor3(c)
	if typeof(c) == "Color3" then
		return c
	elseif type(c) == "table" and c[1] then
		return Color3.fromRGB(c[1], c[2] or 0, c[3] or 0)
	end
	return nil
end

local function formatDate(d)
	if type(d) ~= "table" or not d.year then
		return nil
	end
	local month = MONTHS[d.month or 1] or ""
	return string.format("%d %s %d", d.day or 1, string.upper(month), d.year)
end

-- A thin gold hairline whose ends fade out (the loading-screen rule technique) — no asset needed.
local function hairline(parent, order, thickness)
	local rule = Instance.new("Frame")
	rule.Name = "Rule"
	rule.Size = UDim2.new(1, 0, 0, thickness or 2)
	rule.BackgroundColor3 = GOLD
	rule.BorderSizePixel = 0
	rule.LayoutOrder = order
	rule.ZIndex = 62
	rule.Parent = parent
	local grad = Instance.new("UIGradient")
	grad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	grad.Parent = rule
	return rule
end

-- Build + show the broadsheet in `parentGui`. Returns { root, dismiss }.
function SuperEvent.show(parentGui, payload, opts)
	payload = payload or {}
	opts = opts or {}
	local ttl = opts.ttl or payload.ttl or 10
	local accent = toColor3(payload.color) or GOLD

	-- Root sizes its height to the content column; the ornate shell fills it as the "page".
	local root = Instance.new("Frame")
	root.Name = "SuperEvent"
	root.AnchorPoint = Vector2.new(0.5, 0)
	root.Position = UDim2.new(0.5, 0, 0, 22)
	root.Size = UDim2.fromOffset(500, 0)
	root.AutomaticSize = Enum.AutomaticSize.Y
	root.BackgroundTransparency = 1
	root.ZIndex = 60

	-- Ornate gilt-framed dark-parchment page (existing 9-slice shell). Fills the root behind the content.
	local page = Shells.create("panel_large_shell", { Name = "Page", Size = UDim2.fromScale(1, 1), ZIndex = 60 })
	page.Parent = root

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.fromScale(1, 0)
	content.AutomaticSize = Enum.AutomaticSize.Y
	content.BackgroundTransparency = 1
	content.ZIndex = 61
	content.Parent = root
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 22)
	pad.PaddingBottom = UDim.new(0, 20)
	pad.PaddingLeft = UDim.new(0, 26)
	pad.PaddingRight = UDim.new(0, 26)
	pad.Parent = content
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.Padding = UDim.new(0, 6)
	list.Parent = content

	-- 1) Masthead: the paper name in Bodoni (the loading-screen display face), flanked by small taglines.
	local mastheadRow = Instance.new("Frame")
	mastheadRow.Name = "Masthead"
	mastheadRow.Size = UDim2.new(1, 0, 0, 40)
	mastheadRow.BackgroundTransparency = 1
	mastheadRow.LayoutOrder = 1
	mastheadRow.ZIndex = 62
	mastheadRow.Parent = content
	local masthead = Instance.new("TextLabel")
	masthead.Name = "Title"
	masthead.Size = UDim2.fromScale(1, 1)
	masthead.BackgroundTransparency = 1
	masthead.Text = MASTHEAD
	masthead.TextColor3 = GOLD
	masthead.Font = Enum.Font.Bodoni
	masthead.TextScaled = true
	masthead.ZIndex = 62
	masthead.Parent = mastheadRow
	local mCon = Instance.new("UITextSizeConstraint")
	mCon.MaxTextSize = 40
	mCon.MinTextSize = 20
	mCon.Parent = masthead
	local function tagline(text, anchorRight)
		local l = Instance.new("TextLabel")
		l.Size = UDim2.fromOffset(120, 14)
		l.AnchorPoint = Vector2.new(anchorRight and 1 or 0, 1)
		l.Position = UDim2.new(anchorRight and 1 or 0, 0, 1, -2)
		l.BackgroundTransparency = 1
		l.Text = text
		l.TextColor3 = SEPIA
		l.TextXAlignment = anchorRight and Enum.TextXAlignment.Right or Enum.TextXAlignment.Left
		l.TextTruncate = Enum.TextTruncate.AtEnd
		l.ZIndex = 62
		Typography.apply(l, "caption")
		l.Parent = mastheadRow
	end
	tagline("of every court", false)
	tagline("EXTRA EDITION", true)

	-- 2) Double rule under the masthead (existing gold double-line divider).
	local mastRule =
		Shells.create("divider_line_double", { Name = "MastRule", Size = UDim2.new(1, 0, 0, 6), ZIndex = 62 })
	mastRule.ImageColor3 = accent -- tint the top rule with the nation colour
	mastRule.LayoutOrder = 2
	mastRule.Parent = content

	-- 3) Dateline (in-game date · price).
	local dateStr = formatDate(payload.date)
	local dateline = Instance.new("TextLabel")
	dateline.Name = "Dateline"
	dateline.Size = UDim2.new(1, 0, 0, 15)
	dateline.BackgroundTransparency = 1
	dateline.Text = dateStr and (dateStr .. "  \u{00B7}  PRICE ONE PENNY") or "PRICE ONE PENNY"
	dateline.TextColor3 = SEPIA
	dateline.FontFace = Typography.Serif
	dateline.TextSize = 12
	dateline.TextXAlignment = Enum.TextXAlignment.Center
	dateline.LayoutOrder = 3
	dateline.ZIndex = 62
	dateline.Parent = content
	hairline(content, 4, 2)

	-- 4) Headline photo: the event image (or the tag's crest), framed like a press cut.
	local imageId = payload.imageId
	if not imageId or imageId == "" then
		imageId = CountryColor.resolveFlag(payload.tag)
	end
	local photo = Instance.new("Frame")
	photo.Name = "Photo"
	photo.Size = UDim2.new(1, 0, 0, 132)
	photo.BackgroundColor3 = Colors.SurfaceSunken or Colors.SurfaceBase
	photo.BorderSizePixel = 0
	photo.LayoutOrder = 5
	photo.ZIndex = 62
	photo.Parent = content
	local photoStroke = Instance.new("UIStroke")
	photoStroke.Color = GOLD
	photoStroke.Thickness = 1.5
	photoStroke.Transparency = 0.25
	photoStroke.Parent = photo
	if imageId and imageId ~= "" then
		local img = Instance.new("ImageLabel")
		img.Size = UDim2.fromScale(1, 1)
		img.BackgroundTransparency = 1
		img.Image = imageId
		img.ScaleType = Enum.ScaleType.Crop
		img.ZIndex = 62
		img.Parent = photo
	else
		-- Placeholder: a "cut" that never loaded — the tag over the parchment (mirrors a crest-less nation).
		local ph = Instance.new("TextLabel")
		ph.Size = UDim2.fromScale(1, 1)
		ph.BackgroundTransparency = 1
		ph.Text = string.upper(payload.tag or "\u{2014}")
		ph.TextColor3 = SEPIA
		ph.FontFace = Typography.Serif
		ph.TextSize = 22
		ph.ZIndex = 62
		ph.Parent = photo
	end

	-- 5) Headline (centered serif).
	local headline = Instance.new("TextLabel")
	headline.Name = "Headline"
	headline.Size = UDim2.fromScale(1, 0)
	headline.AutomaticSize = Enum.AutomaticSize.Y
	headline.BackgroundTransparency = 1
	headline.Text = payload.title or "A New Power Rises"
	headline.TextColor3 = INK
	headline.TextXAlignment = Enum.TextXAlignment.Center
	headline.TextWrapped = true
	headline.LayoutOrder = 6
	headline.ZIndex = 62
	Typography.apply(headline, "displayLg")
	headline.Parent = content

	-- 6) Article body (justified feel via serif; Roblox has no true justify, left-aligned reads as column text).
	if payload.body and payload.body ~= "" then
		local body = Instance.new("TextLabel")
		body.Name = "Body"
		body.Size = UDim2.fromScale(1, 0)
		body.AutomaticSize = Enum.AutomaticSize.Y
		body.BackgroundTransparency = 1
		body.Text = payload.body
		body.TextColor3 = INK
		body.TextTransparency = 0.08
		body.TextXAlignment = Enum.TextXAlignment.Left
		body.TextYAlignment = Enum.TextYAlignment.Top
		body.TextWrapped = true
		body.FontFace = Typography.Serif
		body.TextSize = 14
		body.LineHeight = 1.15
		body.LayoutOrder = 7
		body.ZIndex = 62
		body.Parent = content
	end

	hairline(content, 8, 2)

	-- 7) Dismiss: a bespoke gold-outlined serif button (sharp corners — no UICorner, per house style).
	local dismissed = false
	local function dismiss()
		if dismissed then
			return
		end
		dismissed = true
		if opts.onDismiss then
			pcall(opts.onDismiss)
		end
		root:Destroy()
	end

	local btnRow = Instance.new("Frame")
	btnRow.Name = "Actions"
	btnRow.Size = UDim2.new(1, 0, 0, 34)
	btnRow.BackgroundTransparency = 1
	btnRow.LayoutOrder = 9
	btnRow.ZIndex = 62
	btnRow.Parent = content
	local btn = Instance.new("TextButton")
	btn.Name = "Dismiss"
	btn.AnchorPoint = Vector2.new(0.5, 0.5)
	btn.Position = UDim2.fromScale(0.5, 0.5)
	btn.Size = UDim2.fromOffset(150, 30)
	btn.BackgroundColor3 = Colors.SurfaceOverlay or Colors.SurfaceElevated
	btn.BackgroundTransparency = 0.2
	btn.AutoButtonColor = false
	btn.Text = payload.buttonText or "Interesting."
	btn.TextColor3 = GOLD
	btn.FontFace = Typography.SerifBold
	btn.TextSize = 15
	btn.BorderSizePixel = 0
	btn.ZIndex = 62
	btn.Parent = btnRow
	local btnStroke = Instance.new("UIStroke")
	btnStroke.Color = GOLD
	btnStroke.Thickness = 1
	btnStroke.Transparency = 0.15
	btnStroke.Parent = btn
	btn.MouseEnter:Connect(function()
		btn.TextColor3 = Colors.AccentHover or GOLD
		btnStroke.Color = Colors.AccentHover or GOLD
	end)
	btn.MouseLeave:Connect(function()
		btn.TextColor3 = GOLD
		btnStroke.Color = GOLD
	end)
	btn.MouseButton1Click:Connect(dismiss)

	if parentGui then
		root.Parent = parentGui
	end

	-- One-shot audio sting (honours the player's Formation Audio mute + the single-sting guard).
	if payload.audioId and payload.audioId ~= "" then
		UISound.playAssetId(payload.audioId)
	end

	if ttl and ttl > 0 then
		task.delay(ttl, dismiss)
	end

	return { root = root, dismiss = dismiss }
end

return SuperEvent
