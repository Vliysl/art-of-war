-- SuperEvent — the "a nation has formed / was released" announcement banner. A prominent, NON-blocking card
-- (crest/image + title + description + a single dismiss button + optional audio sting) shown top-centre to
-- everyone, auto-dismissing after a few seconds so it never freezes a busy/mobile server. Reusable: the game
-- shows it via Hud.showSuperEvent (broadcast from the server), and the Data Editor previews it locally.
--
-- payload = { title, body, buttonText?, imageId?, audioId?, tag?, color? }
--   imageId  -- banner crest/image; when blank, resolves the tag's crest (CountryBadge fallback -> colour+tag)
--   audioId  -- one-shot sting (blank = silent); played via UISound.playAssetId (honours the mute setting)
--   color    -- {r,g,b} accent (defaults to the DesignSystem accent)
-- opts = { ttl?, parent?, onDismiss? }

local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Spacing = DesignSystem.Spacing
local Components = script.Parent.Parent.Components
local Button = require(Components.Button)
local CountryBadge = require(Components.CountryBadge)
local UISound = require(script.Parent.Parent.UISound)

local SuperEvent = {}

local function toColor3(c)
	if typeof(c) == "Color3" then
		return c
	elseif type(c) == "table" and c[1] then
		return Color3.fromRGB(c[1], c[2] or 0, c[3] or 0)
	end
	return nil
end

-- Build + show the banner in `parentGui`. Returns { root, dismiss }.
function SuperEvent.show(parentGui, payload, opts)
	payload = payload or {}
	opts = opts or {}
	local ttl = opts.ttl or payload.ttl or 7
	local accent = toColor3(payload.color) or Colors.Accent

	local root = Instance.new("Frame")
	root.Name = "SuperEvent"
	root.AnchorPoint = Vector2.new(0.5, 0)
	root.Position = UDim2.new(0.5, 0, 0, 18)
	root.Size = UDim2.new(0, 440, 0, 0)
	root.AutomaticSize = Enum.AutomaticSize.Y
	root.BackgroundColor3 = Colors.SurfaceElevated or Colors.SurfaceBase
	root.BorderSizePixel = 0
	root.ZIndex = 60
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = root
	local stroke = Instance.new("UIStroke")
	stroke.Color = accent
	stroke.Thickness = 1
	stroke.Transparency = 0.3
	stroke.Parent = root
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Spacing.space3)
	pad.PaddingBottom = UDim.new(0, Spacing.space3)
	pad.PaddingLeft = UDim.new(0, Spacing.space4)
	pad.PaddingRight = UDim.new(0, Spacing.space3)
	pad.Parent = root

	local accentBar = Instance.new("Frame")
	accentBar.Name = "Accent"
	accentBar.Size = UDim2.new(0, 4, 1, 0)
	accentBar.Position = UDim2.fromOffset(0, 0)
	accentBar.BackgroundColor3 = accent
	accentBar.BorderSizePixel = 0
	accentBar.ZIndex = 61
	accentBar.Parent = root

	-- Crest / banner image on the left. CountryBadge resolves imageId -> tag crest -> colour+tag fallback.
	local crest = CountryBadge.create({
		parent = root,
		code = payload.tag,
		countryColor = payload.color,
		flag = payload.imageId,
		square = true,
		px = 56,
	})
	crest.Position = UDim2.fromOffset(10, 2)
	crest.ZIndex = 61

	-- Content column (title + body) to the right of the crest.
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Position = UDim2.fromOffset(78, 0)
	content.Size = UDim2.new(1, -78, 0, 0)
	content.AutomaticSize = Enum.AutomaticSize.Y
	content.BackgroundTransparency = 1
	content.ZIndex = 61
	content.Parent = root
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 3)
	list.Parent = content

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AutomaticSize = Enum.AutomaticSize.Y
	title.Size = UDim2.new(1, 0, 0, 0)
	title.BackgroundTransparency = 1
	title.Text = payload.title or "A New Power Rises"
	title.TextColor3 = Colors.TextPrimary
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextWrapped = true
	title.LayoutOrder = 1
	title.ZIndex = 61
	Typography.apply(title, "displayMd")
	title.Parent = content

	if payload.body and payload.body ~= "" then
		local body = Instance.new("TextLabel")
		body.Name = "Body"
		body.AutomaticSize = Enum.AutomaticSize.Y
		body.Size = UDim2.new(1, 0, 0, 0)
		body.BackgroundTransparency = 1
		body.Text = payload.body
		body.TextColor3 = Colors.TextSecondary
		body.TextXAlignment = Enum.TextXAlignment.Left
		body.TextWrapped = true
		body.LayoutOrder = 2
		body.ZIndex = 61
		Typography.apply(body, "bodySm")
		body.Parent = content
	end

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
	btnRow.Size = UDim2.new(1, 0, 0, 30)
	btnRow.BackgroundTransparency = 1
	btnRow.LayoutOrder = 3
	btnRow.ZIndex = 61
	btnRow.Parent = content
	local dismissBtn = Button.create({
		parent = btnRow,
		variant = "primary",
		text = payload.buttonText or "Continue",
		width = 120,
		size = "sm",
		onClick = dismiss,
	})
	dismissBtn.AnchorPoint = Vector2.new(1, 0.5)
	dismissBtn.Position = UDim2.new(1, 0, 0.5, 0)

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
