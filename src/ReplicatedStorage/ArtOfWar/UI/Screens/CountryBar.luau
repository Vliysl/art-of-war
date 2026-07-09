local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Spacing = DesignSystem.Spacing
local Icons = DesignSystem.Icons
local Typography = DesignSystem.Typography
local Shells = DesignSystem.Shells
local Responsive = DesignSystem.Responsive
local CountryBadge = require(script.Parent.Parent.Components.CountryBadge)
local HeroButton = require(script.Parent.Parent.Components.HeroButton)
local Tooltip = require(script.Parent.Parent.Components.Tooltip)

local CountryBar = {}

-- Redesigned CountryBar: a small set of large value/icon buttons instead of the old name/gov text + five stat
-- pills + seven text tabs. Layout (left -> right): [crest] [£ Economy] [Manpower] [Research] [2x2 stat grid].
--   * crest        -> opens the Realm window (Court/Estates/Reforms/Diplomacy) via config.onCrest; hover shows name+gov
--   * Economy (£)  -> config.onMenu("Economy"); shows live treasury + income delta; hover = treasury/income
--   * Manpower     -> config.onMenu("Military"); shows live manpower; hover = manpower / cap
--   * Research     -> config.onMenu("Research"); icon only; hover = active tech + %
--   * stat cells   -> PP / Stability / Legitimacy / Prestige; hover = explanation; click opens Realm (Court)
-- Settings is reached via the persistent top-left gear; Missions is folded into Politics. Composed frame (dark
-- surface + dimmed-gold stroke + gold corner brackets), not the old baked raster, so it reflows.

-- Hover/tap tooltips for the secondary stat cells (title + one-line explanation).
local STAT_TIPS = {
	PowerProj = { title = "Political Power", body = "Spent on laws, policies, diplomacy, and national actions." },
	Stability = { title = "Stability", body = "National stability. Higher stability improves income and lowers unrest." },
	Legitimacy = { title = "Legitimacy", body = "Government legitimacy. Low legitimacy raises unrest and weakens your rule." },
	Prestige = { title = "Prestige", body = "National prestige, earned through war and diplomacy. Lifts your standing." },
}

local CREST_W = 72
local ECON_W = 168
local MANPOWER_W = 168
local RESEARCH_W = 96
local STAT_CELL_W = 82
local STAT_CELL_H = 32
-- The bar hugs its content: L/R padding + crest + 3 buttons + the 2x2 stat grid + the four gaps between the
-- five row items. Keep this in sync if the widths above (or the stat grid) change.
local BAR_W = Spacing.space4 * 2
	+ CREST_W
	+ ECON_W
	+ MANPOWER_W
	+ RESEARCH_W
	+ (STAT_CELL_W * 2 + Spacing.space3)
	+ Spacing.space3 * 4

-- On phones the fill-width bar is oversized; render it at ~half that size (still pinned bottom-left).
local MOBILE_BAR_SCALE = 0.5

-- Parents four gold corner-bracket sprites (corner_* fit-mode shells) to `parent`. Single sprites, no
-- SliceCenter -> no 9-slice decode race. Used for the bar frame and the stat cells; HeroButtons carry their own.
local function addCorners(parent, sizePx, inset, zi)
	local defs = {
		{ "corner_tl", Vector2.new(0, 0), UDim2.fromOffset(inset, inset) },
		{ "corner_tr", Vector2.new(1, 0), UDim2.new(1, -inset, 0, inset) },
		{ "corner_bl", Vector2.new(0, 1), UDim2.new(0, inset, 1, -inset) },
		{ "corner_br", Vector2.new(1, 1), UDim2.new(1, -inset, 1, -inset) },
	}
	for _, d in defs do
		local img = Shells.create(d[1])
		img.Name = d[1]
		img.Size = UDim2.fromOffset(sizePx, sizePx)
		img.AnchorPoint = d[2]
		img.Position = d[3]
		img.ZIndex = zi
		img.Parent = parent
	end
end

function CountryBar.create(config)
	config = config or {}
	local r = config.resources or {}
	local z = config.zIndex or 5
	local tipLayer = config.tooltipLayer

	-- Latest data the tooltips read at show-time (refreshed by setResources / update).
	local latestRes = r
	local latestName = config.name or "Realm"
	local latestGov = config.government
	local latestCulture = config.culture

	local root = Instance.new("Frame")
	root.Name = "CountryStrip"
	root.AnchorPoint = Vector2.new(0, 1)
	root.Position = config.position or UDim2.new(0, 16, 1, -8)
	root.Size = config.size or UDim2.fromOffset(BAR_W, 96)
	root.BackgroundTransparency = 1
	root.ZIndex = z
	root:SetAttribute("AoWInputSink", true)

	-- On touch, scale the whole bar (relative to the HUD's own Responsive UIScale) toward the phone width, then
	-- take MOBILE_BAR_SCALE of that so it sits at ~half size in the bottom-left instead of dominating the screen.
	if Responsive.isTouch() then
		local fit = Instance.new("UIScale")
		fit.Name = "TouchFit"
		fit.Parent = root
		local function refit()
			local cam = workspace.CurrentCamera
			local vpX = (cam and cam.ViewportSize.X) or 1280
			local barW = (config.size and config.size.X.Offset > 0 and config.size.X.Offset) or BAR_W
			fit.Scale = MOBILE_BAR_SCALE * math.clamp((vpX - 24) / (barW * Responsive.computeScale()), 0.5, 1.8)
		end
		refit()
		local cam = workspace.CurrentCamera
		if cam then
			local conn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(refit)
			root.Destroying:Connect(function()
				conn:Disconnect()
			end)
		end
	end

	-- Composed bar frame: dark surface + dimmed-gold stroke + gold corner brackets.
	local bg = Instance.new("Frame")
	bg.Name = "Bg"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Colors.SurfaceBase
	bg.BorderSizePixel = 0
	bg.ZIndex = z
	bg.Parent = root
	local bgStroke = Instance.new("UIStroke")
	bgStroke.Color = Color3.fromRGB(178, 150, 86) -- dimmed gold accent (softer than the bright Colors.Accent)
	bgStroke.Thickness = 1.5
	bgStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	bgStroke.Parent = bg
	addCorners(bg, 26, 1, z + 1)

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.fromScale(1, 1)
	content.BackgroundTransparency = 1
	content.ZIndex = z + 2
	content.Parent = root
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, Spacing.space4)
	pad.PaddingRight = UDim.new(0, Spacing.space4)
	pad.PaddingTop = UDim.new(0, Spacing.space3)
	pad.PaddingBottom = UDim.new(0, Spacing.space3)
	pad.Parent = content
	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.HorizontalAlignment = Enum.HorizontalAlignment.Left
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Padding = UDim.new(0, Spacing.space3)
	row.Parent = content

	-- Tooltip helper: `provider()` returns { title, body } (or nil to skip), computed at show-time so the
	-- tooltip always reflects the latest values. Anchored ABOVE the host (never follows the cursor).
	local function attachTip(host, provider)
		if not tipLayer then
			return
		end
		local current
		local function clearTip()
			if current then
				current:Destroy()
				current = nil
			end
		end
		local function anchorTip()
			if not current then
				return
			end
			local us = tipLayer:FindFirstChildWhichIsA("UIScale")
			local scale = (us and us.Scale) or 1
			local cam = workspace.CurrentCamera
			local vp = (cam and cam.ViewportSize) or Vector2.new(1280, 720)
			local tw = current.AbsoluteSize.X > 0 and current.AbsoluteSize.X or 220 * scale
			local th = current.AbsoluteSize.Y > 0 and current.AbsoluteSize.Y or 64 * scale
			local hp, hs = host.AbsolutePosition, host.AbsoluteSize
			local x = hp.X + hs.X / 2 - tw / 2
			local y = hp.Y - th - 8
			if y < 8 then
				y = hp.Y + hs.Y + 8
			end
			x = math.clamp(x, 8, math.max(8, vp.X - tw - 8))
			current.Position = UDim2.fromOffset(x / scale, y / scale)
		end
		local function showTip()
			local tip = provider()
			if not tip then
				return
			end
			clearTip()
			current = Tooltip.create({ title = tip.title, body = tip.body, width = 220, compact = true })
			current:SetAttribute("AoWInputSink", false)
			current.Parent = tipLayer
			anchorTip()
			task.defer(anchorTip)
		end
		host.MouseEnter:Connect(showTip)
		host.MouseLeave:Connect(clearTip)
		host.Destroying:Connect(clearTip)
		host.InputBegan:Connect(function(io)
			if io.UserInputType == Enum.UserInputType.Touch then
				showTip()
				local mine = current
				task.delay(2.5, function()
					if current == mine then
						clearTip()
					end
				end)
			end
		end)
	end

	-- Crest -> Realm (clickable), rebuilt only on a country switch. Hover/tap shows the country name + government.
	local crestBtn = Instance.new("TextButton")
	crestBtn.Name = "Crest"
	crestBtn.Size = UDim2.fromOffset(CREST_W, CREST_W) -- 1x1 square, same height as the buttons
	crestBtn.BackgroundColor3 = Colors.SurfaceElevated
	crestBtn.BorderSizePixel = 0
	crestBtn.AutoButtonColor = false
	crestBtn.Text = ""
	crestBtn.LayoutOrder = 0
	crestBtn.ZIndex = z + 2
	crestBtn.Parent = content
	local crestStroke = Instance.new("UIStroke")
	crestStroke.Color = Colors.BorderStrong
	crestStroke.Thickness = 1
	crestStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	crestStroke.Parent = crestBtn

	local flag
	local function buildCrest(code, color)
		if flag then
			flag:Destroy()
		end
		-- Fill the crest cell (square, SAME HEIGHT as the buttons) with sharp corners (square = true) -- larger
		-- and uniform with the HeroButtons instead of a small rounded badge.
		flag = CountryBadge.create({ code = code or "XXX", countryColor = color, size = "lg", square = true })
		flag.AnchorPoint = Vector2.new(0.5, 0.5)
		flag.Position = UDim2.fromScale(0.5, 0.5)
		flag.Size = UDim2.new(1, -6, 1, -6)
		flag.ZIndex = z + 3
		flag.Parent = crestBtn
	end
	buildCrest(config.code, config.color)
	crestBtn.MouseButton1Click:Connect(function()
		if config.onCrest then
			config.onCrest()
		end
	end)
	attachTip(crestBtn, function()
		local body = latestGov or ""
		if latestCulture and latestCulture ~= "" then
			body = (body ~= "" and (body .. "  \u{00B7}  " .. latestCulture)) or latestCulture
		end
		return { title = latestName or "Realm", body = (body ~= "" and body) or "Open your realm." }
	end)

	local function openMenu(name)
		if config.onMenu then
			config.onMenu(name)
		end
	end

	local economy = HeroButton.create({
		parent = content,
		zIndex = z + 2,
		layoutOrder = 1,
		size = UDim2.new(0, ECON_W, 1, 0),
		icon = "Treasury",
		iconPosition = "left",
		value = r.treasury or "0",
		delta = "",
		caption = "Economy",
		onClick = function()
			openMenu("Economy")
		end,
	})
	attachTip(economy.root, function()
		return {
			title = "Economy",
			body = "Treasury: "
				.. (latestRes.treasury or "0")
				.. "\nIncome: "
				.. (latestRes.treasuryDelta or "0")
				.. " / month",
		}
	end)

	local manpower = HeroButton.create({
		parent = content,
		zIndex = z + 2,
		layoutOrder = 2,
		size = UDim2.new(0, MANPOWER_W, 1, 0),
		icon = "Army",
		iconPosition = "left",
		value = r.manpower or "0",
		caption = "Manpower",
		onClick = function()
			openMenu("Military")
		end,
	})
	attachTip(manpower.root, function()
		local body = "Recruits: " .. (latestRes.manpower or "0")
		if latestRes.manpowerCap and latestRes.manpowerCap ~= "" then
			body = body .. " / " .. latestRes.manpowerCap
		end
		return { title = "Manpower", body = body }
	end)

	local research = HeroButton.create({
		parent = content,
		zIndex = z + 2,
		layoutOrder = 3,
		size = UDim2.new(0, RESEARCH_W, 1, 0),
		icon = "Research",
		caption = "Research",
		onClick = function()
			openMenu("Research")
		end,
	})
	attachTip(research.root, function()
		return { title = "Research", body = latestRes.research or "No active research." }
	end)

	-- Keyed by the SCREEN NAME each button opens, so Hud.setActive(screenName) highlights the right one.
	local buttons = { Economy = economy, Military = manpower, Research = research }

	-- Secondary stat CELLS in a 2x2 grid, in the row right AFTER the Research button. Each is a compact
	-- button-styled cell (dark surface + stroke + gold corner brackets) with a hover/tap tooltip; clicking one
	-- opens the Realm window (Court) where these stats are detailed. PP + Stability top; Legitimacy + Prestige below.
	local statGrid = Instance.new("Frame")
	statGrid.Name = "Stats"
	statGrid.Size = UDim2.fromOffset(0, 0)
	statGrid.AutomaticSize = Enum.AutomaticSize.XY
	statGrid.BackgroundTransparency = 1
	statGrid.LayoutOrder = 4
	statGrid.ZIndex = z + 2
	statGrid.Parent = content
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(STAT_CELL_W, STAT_CELL_H)
	grid.CellPadding = UDim2.fromOffset(Spacing.space3, Spacing.space1)
	grid.FillDirectionMaxCells = 2
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Left
	grid.VerticalAlignment = Enum.VerticalAlignment.Center
	grid.Parent = statGrid

	local function statCell(iconKey, order)
		-- Compact button-styled cell (mirrors HeroButton: dark surface + stroke + gold corner brackets).
		local cell = Instance.new("TextButton")
		cell.Name = iconKey
		cell.AutoButtonColor = false
		cell.Text = ""
		cell.BackgroundColor3 = Colors.SurfaceElevated
		cell.BorderSizePixel = 0
		cell.LayoutOrder = order
		cell.ZIndex = z + 2
		cell:SetAttribute("AoWInputSink", true)
		cell.Parent = statGrid
		local cs = Instance.new("UIStroke")
		cs.Color = Colors.BorderStrong
		cs.Thickness = 1
		cs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		cs.Parent = cell
		addCorners(cell, 9, 1, z + 4)
		local inner = Instance.new("Frame")
		inner.Name = "Content"
		inner.Size = UDim2.fromScale(1, 1)
		inner.BackgroundTransparency = 1
		inner.ZIndex = z + 3
		inner.Parent = cell
		local il = Instance.new("UIListLayout")
		il.FillDirection = Enum.FillDirection.Horizontal
		il.HorizontalAlignment = Enum.HorizontalAlignment.Center
		il.VerticalAlignment = Enum.VerticalAlignment.Center
		il.SortOrder = Enum.SortOrder.LayoutOrder
		il.Padding = UDim.new(0, 5)
		il.Parent = inner
		local icon = Icons.create(iconKey, 16, Colors.TextSecondary)
		icon.LayoutOrder = 1
		icon.ZIndex = z + 3
		icon.Parent = inner
		local value = Instance.new("TextLabel")
		value.Name = "Value"
		value.BackgroundTransparency = 1
		value.AutomaticSize = Enum.AutomaticSize.X
		value.Size = UDim2.fromScale(0, 1)
		value.Text = "0"
		value.TextColor3 = Colors.TextPrimary
		value.TextXAlignment = Enum.TextXAlignment.Left
		value.TextYAlignment = Enum.TextYAlignment.Center
		value.LayoutOrder = 2
		value.ZIndex = z + 3
		Typography.apply(value, "value")
		value.Parent = inner
		cell.MouseButton1Click:Connect(function()
			if config.onCrest then
				config.onCrest()
			end
		end)
		attachTip(cell, function()
			return STAT_TIPS[iconKey]
		end)
		return value
	end
	local statPP = statCell("PowerProj", 1)
	local statStability = statCell("Stability", 2)
	local statLegitimacy = statCell("Legitimacy", 3)
	local statPrestige = statCell("Prestige", 4)

	local function setResources(res)
		res = res or {}
		latestRes = res
		economy.setValue(res.treasury or "0")
		economy.setDelta(res.treasuryDelta or "", Colors.delta(res.treasuryDeltaNum or 0))
		manpower.setValue(res.manpower or "0")
		statPP.Text = res.pp or "0"
		statStability.Text = res.stability or "0"
		statLegitimacy.Text = res.legitimacy or "0"
		statPrestige.Text = res.prestige or "0"
	end
	setResources(r)

	-- Highlight the button matching the open screen (Economy / Military / Research); any other screen
	-- (Realm, Settings, ...) clears all highlights. Kept callable because Hud.openScreen relies on it.
	local function setActive(name)
		for key, ctrl in buttons do
			ctrl.setActive(key == name)
		end
	end

	-- In-place update on economy/army deltas: mutate values; rebuild the crest only on a country switch.
	local currentCode = config.code
	local function update(cfg)
		cfg = cfg or {}
		latestName = cfg.name or latestName
		latestGov = cfg.government or latestGov
		latestCulture = cfg.culture or latestCulture
		if cfg.code and cfg.code ~= currentCode then
			currentCode = cfg.code
			buildCrest(cfg.code, cfg.color)
		end
		setResources(cfg.resources)
	end

	if config.parent then
		root.Parent = config.parent
	end
	return { root = root, setActive = setActive, buttons = buttons, update = update }
end

return CountryBar
