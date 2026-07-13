-- SuperEvent — the "a nation has formed / was released" announcement, styled as a period BROADSHEET (a
-- Hearts-of-Iron-IV news-event front page) in Art of War's dark parchment + gold palette: an ornate framed
-- page with a Bodoni masthead, a ruled colophon (place + in-game date), a framed headline cut with a caption,
-- a gold event kicker, a flush-left serif headline + deck + drop-capped article body, an ornate end-mark, and
-- a single acknowledge button. Non-blocking and draggable, shown centre-screen to everyone and dismissed by
-- its button (no auto-dismiss); it scales down to always fit the viewport so the button is never off-screen.
-- Reusable: the game shows it via Hud.showSuperEvent (server broadcast); the Data Editor previews it locally.
--
-- payload = { title, body, buttonText?, imageId?, audioId?, tag?, subject?, color?, date?, eventType?, kicker?, deck?, caption? }
--   imageId   -- headline cut; when blank, resolves the tag's crest (CountryColor.resolveFlag), else placeholder
--   subject   -- the nation's display name (colophon place + photo caption); falls back to the tag
--   date      -- { year, month, day } in-game date for the colophon (omitted when absent)
--   eventType -- "nation.formed" | "nation.released"; drives the kicker + deck when not given explicitly
--   audioId   -- one-shot sting (blank = silent); UISound.playAssetId honours the Formation Audio mute
--   color     -- {r,g,b} nation accent (tints the masthead rule); defaults to gold
-- opts = { parent?, onDismiss? }

local UserInputService = game:GetService("UserInputService")

local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Shells = DesignSystem.Shells
local Responsive = DesignSystem.Responsive
local CountryColor = require(script.Parent.Parent.Parent.Modules.CountryColor)
local UISound = require(script.Parent.Parent.UISound)

local SuperEvent = {}

-- How many broadsheets are currently open, so concurrent ones cascade instead of stacking exactly (they no
-- longer auto-dismiss, so several can be up at once).
local openModals = 0

local MASTHEAD = "World News" -- the fixed broadsheet name
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

-- The small gold caps line above the headline + the one-line deck under it — derived from the event kind so
-- every broadsheet reads as FORMATION / INDEPENDENCE at a glance (an author may override via payload.kicker/deck).
local EVENT_KICKER = {
	["nation.formed"] = "Formation",
	["nation.released"] = "Independence",
}
local EVENT_DECK = {
	["nation.formed"] = "A new power takes its place among the nations of the world.",
	["nation.released"] = "A people reclaim their sovereignty and raise their own standard.",
}

local function toColor3(c)
	if typeof(c) == "Color3" then
		return c
	elseif type(c) == "table" and c[1] then
		return Color3.fromRGB(c[1], c[2] or 0, c[3] or 0)
	end
	return nil
end

local function toHex(c)
	return string.format(
		"#%02X%02X%02X",
		math.floor(c.R * 255 + 0.5),
		math.floor(c.G * 255 + 0.5),
		math.floor(c.B * 255 + 0.5)
	)
end
local GOLD_HEX = toHex(GOLD)

-- Escape RichText metacharacters so an authored body with & < > renders literally (we use RichText for the
-- drop-cap initial).
local function escapeRich(s)
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function formatDate(d)
	if type(d) ~= "table" or not d.year then
		return nil
	end
	local month = MONTHS[d.month or 1] or ""
	return string.upper(string.format("%d %s %d", d.day or 1, month, d.year))
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
	local accent = toColor3(payload.color) or GOLD
	local touch = Responsive.isTouch()

	-- Root sizes its height to the content column; the ornate shell fills it as the "page". Centred on screen
	-- and given a responsive width so it never runs past a phone's edges; concurrent broadsheets cascade
	-- slightly (bounded) so they don't land exactly on top of one another.
	local camera = workspace.CurrentCamera
	local viewport = (camera and camera.ViewportSize) or Vector2.new(1280, 720)
	local width = math.min(500, viewport.X - 24)
	local slot = openModals
	local casc = (slot % 6) * 22
	local root = Instance.new("Frame")
	root.Name = "SuperEvent"
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.new(0.5, casc, 0.5, casc)
	root.Size = UDim2.fromOffset(width, 0)
	root.AutomaticSize = Enum.AutomaticSize.Y
	root.BackgroundTransparency = 1
	root.ZIndex = 60
	-- Parent now, and only count broadsheets we actually show, so a nil-parent call can't leak the open-count.
	if parentGui then
		root.Parent = parentGui
		openModals += 1
	end

	-- Fit-to-viewport: a UIScale shrinks the whole page so it always fits within the screen (height AND width),
	-- guaranteeing the dismiss button is on-screen even on a short landscape phone. natural = AbsoluteSize/scale
	-- recovers the unscaled size, so this converges (the epsilon guard stops the AbsoluteSize<->scale loop).
	local uiScale = Instance.new("UIScale")
	uiScale.Scale = 1
	uiScale.Parent = root

	-- Ornate gilt-framed dark-parchment page (existing 9-slice shell). Fills the root behind the content and
	-- doubles as the drag handle: Active so it catches the press, while the dismiss button (also Active) sinks
	-- its own so clicking it never starts a drag.
	local page = Shells.create("panel_large_shell", { Name = "Page", Size = UDim2.fromScale(1, 1), ZIndex = 60 })
	page.Active = true
	page.Parent = root

	-- Drag-to-move: press anywhere on the page and drag (UserInputService tracks the pointer). Connections are
	-- kept so they can be torn down on dismiss — nothing leaks while several broadsheets are open at once.
	local dragConns = {}

	local function refit()
		if not camera then
			return
		end
		local s = uiScale.Scale
		if s <= 0.01 then
			s = 0.01
		end
		local nat = root.AbsoluteSize / s -- unscaled size
		if nat.X < 1 or nat.Y < 1 then
			return
		end
		local vp = camera.ViewportSize
		local target = math.min(1, (vp.X - 24) / nat.X, (vp.Y * 0.92) / nat.Y)
		if math.abs(target - uiScale.Scale) > 0.01 then
			uiScale.Scale = target
		end
	end
	table.insert(dragConns, root:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit))
	task.defer(refit)

	do
		local dragging, dragStart, startPos, dragInput
		table.insert(
			dragConns,
			page.InputBegan:Connect(function(input)
				if
					input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch
				then
					dragging = true
					dragStart = input.Position
					startPos = root.Position
					local endConn
					endConn = input.Changed:Connect(function()
						if input.UserInputState == Enum.UserInputState.End then
							dragging = false
							endConn:Disconnect()
						end
					end)
				end
			end)
		)
		table.insert(
			dragConns,
			page.InputChanged:Connect(function(input)
				if
					input.UserInputType == Enum.UserInputType.MouseMovement
					or input.UserInputType == Enum.UserInputType.Touch
				then
					dragInput = input
				end
			end)
		)
		table.insert(
			dragConns,
			UserInputService.InputChanged:Connect(function(input)
				if dragging and input == dragInput then
					local delta = input.Position - dragStart
					local vp = (camera and camera.ViewportSize) or viewport
					local half = root.AbsoluteSize / 2
					-- Keep the page reachable: fully on-screen when it fits, and pannable edge-to-edge when it
					-- is larger than the viewport, so the dismiss button can always be dragged back into view.
					local function clampAxis(off, vpLen, halfLen)
						local centre = 0.5 * vpLen + off
						local lo, hi = halfLen, vpLen - halfLen
						if lo > hi then
							lo, hi = hi, lo
						end
						return math.clamp(centre, lo, hi) - 0.5 * vpLen
					end
					root.Position = UDim2.new(
						0.5,
						clampAxis(startPos.X.Offset + delta.X, vp.X, half.X),
						0.5,
						clampAxis(startPos.Y.Offset + delta.Y, vp.Y, half.Y)
					)
				end
			end)
		)
	end

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

	local subject = payload.subject
	if (not subject or subject == "") and payload.tag then
		subject = payload.tag
	end

	-- 1) Masthead: the paper name in Bodoni (the loading-screen display face), centred.
	local mastheadRow = Instance.new("Frame")
	mastheadRow.Name = "Masthead"
	mastheadRow.Size = UDim2.new(1, 0, 0, 42)
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
	mCon.MaxTextSize = 38
	mCon.MinTextSize = 20
	mCon.Parent = masthead

	-- 2) Double rule under the masthead (existing gold double-line divider, tinted with the nation colour).
	local mastRule =
		Shells.create("divider_line_double", { Name = "MastRule", Size = UDim2.new(1, 0, 0, 6), ZIndex = 62 })
	mastRule.ImageColor3 = accent
	mastRule.LayoutOrder = 2
	mastRule.Parent = content

	-- 3) Colophon bar: place (subject) flush-left, in-game date flush-right — the Georgian nameplate line.
	local dateStr = formatDate(payload.date)
	if subject or dateStr then
		local bar = Instance.new("Frame")
		bar.Name = "Colophon"
		bar.Size = UDim2.new(1, 0, 0, 16)
		bar.BackgroundTransparency = 1
		bar.LayoutOrder = 3
		bar.ZIndex = 62
		bar.Parent = content
		if subject then
			local place = Instance.new("TextLabel")
			place.Name = "Place"
			place.AnchorPoint = Vector2.new(0, 0.5)
			place.Position = UDim2.fromScale(0, 0.5)
			place.Size = UDim2.fromScale(0.6, 1)
			place.BackgroundTransparency = 1
			place.Text = string.upper(subject)
			place.TextColor3 = SEPIA
			place.FontFace = Typography.Serif
			place.TextSize = 12
			place.TextXAlignment = Enum.TextXAlignment.Left
			place.TextTruncate = Enum.TextTruncate.AtEnd
			place.ZIndex = 62
			place.Parent = bar
		end
		if dateStr then
			local date = Instance.new("TextLabel")
			date.Name = "Dateline"
			date.AnchorPoint = Vector2.new(1, 0.5)
			date.Position = UDim2.fromScale(1, 0.5)
			date.Size = UDim2.fromScale(0.6, 1)
			date.BackgroundTransparency = 1
			date.Text = dateStr
			date.TextColor3 = SEPIA
			date.FontFace = Typography.Serif
			date.TextSize = 12
			date.TextXAlignment = Enum.TextXAlignment.Right
			date.ZIndex = 62
			date.Parent = bar
		end
		hairline(content, 4, 2)
	end

	-- 4) Headline cut: the event image, else the tag's crest, framed like a press engraving. A crest fallback
	-- is shown whole (Fit) on the sunken parchment; a real event photo is cropped to fill (Crop).
	local imageId = payload.imageId
	local isCrest = false
	if not imageId or imageId == "" then
		imageId = CountryColor.resolveFlag(payload.tag)
		isCrest = imageId ~= nil and imageId ~= ""
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
		img.Size = isCrest and UDim2.new(1, -18, 1, -18) or UDim2.fromScale(1, 1)
		img.Position = UDim2.fromScale(0.5, 0.5)
		img.AnchorPoint = Vector2.new(0.5, 0.5)
		img.BackgroundTransparency = 1
		img.Image = imageId
		img.ScaleType = isCrest and Enum.ScaleType.Fit or Enum.ScaleType.Crop
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

	-- 4b) Photo caption — the single strongest "this is a newspaper cut" signal.
	local captionText = payload.caption or subject
	if captionText and captionText ~= "" then
		local caption = Instance.new("TextLabel")
		caption.Name = "Caption"
		caption.Size = UDim2.new(1, 0, 0, 14)
		caption.BackgroundTransparency = 1
		caption.Text = captionText
		caption.TextColor3 = SEPIA
		caption.FontFace = Typography.Serif
		caption.TextSize = 11
		caption.TextTransparency = 0.1
		caption.TextXAlignment = Enum.TextXAlignment.Center
		caption.TextTruncate = Enum.TextTruncate.AtEnd
		caption.LayoutOrder = 6
		caption.ZIndex = 62
		caption.Parent = content
	end

	-- 5) Kicker: a small gold caps line naming the event class, flush-left above the headline.
	local kicker = payload.kicker or EVENT_KICKER[payload.eventType] or "Dispatch"
	local kick = Instance.new("TextLabel")
	kick.Name = "Kicker"
	kick.Size = UDim2.new(1, 0, 0, 14)
	kick.BackgroundTransparency = 1
	kick.Text = string.upper(kicker)
	kick.TextColor3 = GOLD
	kick.FontFace = Typography.SerifBold
	kick.TextSize = 12
	kick.TextXAlignment = Enum.TextXAlignment.Left
	kick.LayoutOrder = 7
	kick.ZIndex = 62
	kick.Parent = content

	-- 6) Headline (flush-left serif — the asymmetry is what reads as a front page rather than a poster).
	local headline = Instance.new("TextLabel")
	headline.Name = "Headline"
	headline.Size = UDim2.fromScale(1, 0)
	headline.AutomaticSize = Enum.AutomaticSize.Y
	headline.BackgroundTransparency = 1
	headline.Text = payload.title or "A New Power Rises"
	headline.TextColor3 = INK
	headline.TextXAlignment = Enum.TextXAlignment.Left
	headline.TextWrapped = true
	headline.LayoutOrder = 8
	headline.ZIndex = 62
	Typography.apply(headline, "displayLg")
	headline.Parent = content

	-- 7) Deck: a one-line summary under the headline (author override, else derived from the event kind).
	local deckText = payload.deck or EVENT_DECK[payload.eventType]
	if deckText and deckText ~= "" then
		local deck = Instance.new("TextLabel")
		deck.Name = "Deck"
		deck.Size = UDim2.fromScale(1, 0)
		deck.AutomaticSize = Enum.AutomaticSize.Y
		deck.BackgroundTransparency = 1
		deck.Text = deckText
		deck.TextColor3 = SEPIA
		deck.TextXAlignment = Enum.TextXAlignment.Left
		deck.TextWrapped = true
		deck.LayoutOrder = 9
		deck.ZIndex = 62
		Typography.apply(deck, "title")
		deck.Parent = content
	end

	-- 8) Article body (serif column text, flush-left, with a large gold drop-cap initial).
	if payload.body and payload.body ~= "" then
		local body = Instance.new("TextLabel")
		body.Name = "Body"
		body.Size = UDim2.fromScale(1, 0)
		body.AutomaticSize = Enum.AutomaticSize.Y
		body.BackgroundTransparency = 1
		body.RichText = true
		-- Split on the first full CODEPOINT (not byte) so a body starting with a multi-byte character -- e.g. a
		-- native nation name like "Österreich" or "Éire" -- drop-caps cleanly instead of splitting the sequence.
		local raw = payload.body
		local second = utf8.offset(raw, 2) or (#raw + 1)
		local first = escapeRich(string.sub(raw, 1, second - 1))
		local rest = escapeRich(string.sub(raw, second))
		body.Text = string.format('<font size="30" color="%s"><b>%s</b></font>%s', GOLD_HEX, first, rest)
		body.TextColor3 = INK
		body.TextXAlignment = Enum.TextXAlignment.Left
		body.TextYAlignment = Enum.TextYAlignment.Top
		body.TextWrapped = true
		body.FontFace = Typography.Serif
		body.TextSize = 16
		body.LineHeight = 1.12
		body.LayoutOrder = 10
		body.ZIndex = 62
		body.Parent = content
	end

	-- 9) Ornate end-mark (period "furniture" — replaces a plain rule before the button).
	local endMark =
		Shells.create("divider_ornate_diamond", { Name = "EndMark", Size = UDim2.fromOffset(240, 22), ZIndex = 62 })
	endMark.ImageColor3 = GOLD
	endMark.LayoutOrder = 11
	endMark.Parent = content

	-- 10) Dismiss: a bespoke gold-outlined serif button (sharp corners — no UICorner, per house style).
	-- Bookkeeping (drop the open-count, disconnect the drag/refit) rides on Destroying, so it runs exactly
	-- once whether the player clicks the button or the layer is torn down out from under us.
	root.Destroying:Connect(function()
		if parentGui then
			openModals = math.max(0, openModals - 1)
		end
		for _, c in ipairs(dragConns) do
			c:Disconnect()
		end
	end)
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

	local btnH = touch and 44 or 34
	local btnRow = Instance.new("Frame")
	btnRow.Name = "Actions"
	btnRow.Size = UDim2.new(1, 0, 0, btnH + 4)
	btnRow.BackgroundTransparency = 1
	btnRow.LayoutOrder = 12
	btnRow.ZIndex = 62
	btnRow.Parent = content
	local btn = Instance.new("TextButton")
	btn.Name = "Dismiss"
	btn.AnchorPoint = Vector2.new(0.5, 0.5)
	btn.Position = UDim2.fromScale(0.5, 0.5)
	btn.Size = UDim2.fromOffset(touch and 190 or 160, btnH)
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
	-- Border mode draws a rectangular border around the button; the default (Contextual) would instead
	-- outline the text glyphs, which is not what we want here.
	btnStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
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

	-- One-shot audio sting (honours the player's Formation Audio mute + the single-sting guard).
	if payload.audioId and payload.audioId ~= "" then
		UISound.playAssetId(payload.audioId)
	end

	return { root = root, dismiss = dismiss }
end

return SuperEvent
