local ScreenKit = require(script.Parent.ScreenKit)
local Components = script.Parent.Parent.Components
local Button = require(Components.Button)
local CountryBadge = require(Components.CountryBadge)
local Tooltip = require(Components.Tooltip)
local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Icons = DesignSystem.Icons
local SimClock = require(script.Parent.Parent.Parent.Modules.SimClock)
local WorldConstants = require(script.Parent.Parent.Parent.Shared.WorldConstants)
local RunService = game:GetService("RunService")

local ProvinceOverview = {}

local ROW_HEIGHT = 44
local BTN_SIZE = 36
local CONTENT_X = BTN_SIZE + 10
local GLYPH_SIZE = 22

-- Repeatable tier-upgrade buildings are surfaced as + buttons on the tier row, not as list rows.
local TIER_BUILDINGS = { improve_infrastructure = "infra", develop_province = "dev", walls = "fort" }

local function toHex(c)
	return string.format(
		"#%02X%02X%02X",
		math.floor(c.R * 255 + 0.5),
		math.floor(c.G * 255 + 0.5),
		math.floor(c.B * 255 + 0.5)
	)
end
local GRAY_HEX = toHex(Colors.TextSecondary)

local CATEGORY_LABELS = {
	economic = "Economic",
	military = "Military",
	cultural = "Cultural",
	industry = "Industry",
}

local function val(v)
	if v == nil or v == "" then
		return "\u{2014}"
	end
	return tostring(v)
end

local function titleCase(text)
	if not text then
		return ""
	end
	local s = tostring(text):gsub("_", " ")
	s = s:gsub("(%a)([%w']*)", function(a, b)
		return a:upper() .. b:lower()
	end)
	return s
end

-- Progress 0..1 of a queue ticket. Mirrors EconomyScreen's os.clock()-vs-sim-time approach so build and
-- recruit bars behave the same.
local function progressOf(startedAt, completesAt)
	if startedAt and completesAt and completesAt > startedAt then
		-- Tickets are stamped in server sim-time; SimClock tracks it (speed/pause-aware). Fall back to
		-- startedAt (0%) until the first TimeSync anchor arrives. Using os.clock() here read full instantly.
		local now = SimClock.now() or startedAt
		return math.clamp((now - startedAt) / (completesAt - startedAt), 0, 1)
	end
	return 0
end

local function buildingTooltipRows(def)
	local rows = {
		{ label = "Cost", value = (def.cost or 0) .. " gold" },
		{ label = "Build time", value = (def.buildDays or 0) .. " days" },
	}
	if (def.infraRequirement or 0) > 0 then
		rows[#rows + 1] = { label = "Needs infra", value = "Tier " .. def.infraRequirement }
	end
	if def.grantsDevTier then
		rows[#rows + 1] = { label = "Development", value = "+" .. def.grantsDevTier, color = "positive" }
	end
	if def.grantsInfraTier then
		rows[#rows + 1] = { label = "Infrastructure", value = "+" .. def.grantsInfraTier, color = "positive" }
	end
	if def.grantsFortTier then
		rows[#rows + 1] = { label = "Fortification", value = "+" .. def.grantsFortTier, color = "positive" }
	end
	if type(def.modifiers) == "table" then
		for k, v in pairs(def.modifiers) do
			if type(v) == "number" and v ~= 0 then
				rows[#rows + 1] = {
					label = titleCase(k),
					value = string.format("%s%g%%", v > 0 and "+" or "", v * 100),
					color = v > 0 and "positive" or "negative",
				}
			end
		end
	end
	return rows
end

local function unitTooltipRows(def)
	return {
		{ label = "Attack", value = val(def.attack) },
		{ label = "Defense", value = val(def.defense) },
		{ label = "Upkeep", value = val(def.upkeep) },
		{ label = "Cost", value = (def.recruitCost or 0) .. " gold" },
		{ label = "Manpower", value = val(def.recruitManpower) },
		{ label = "Class", value = titleCase(def.class) },
	}
end

-- A compact diamond action button (recruit/build "+" or cancel "×"). Reuses Button.create for the
-- variant fill/hover, rotates its background into a symmetric diamond, and draws the glyph as GEOMETRY
-- (centred bars) rather than a text glyph -- font metrics left a text +/× visibly off-centre in the
-- small diamond, but centre-anchored bars are pixel-perfect at any size.
local function squareButton(parent, variant, glyph, width, sizeKey, onClick, glyphSize)
	local btn = Button.create({
		parent = parent,
		variant = variant,
		text = glyph,
		width = width,
		size = sizeKey,
		onClick = onClick,
	})

	-- Diamond background: rotate a SQUARE 45° (the glyph is drawn separately, unrotated). The side comes
	-- from the SMALLER button dimension so the diamond is symmetric. Sharp points (no UICorner); a
	-- stronger outer border (variant stroke, thickened) + a paler inset inner border (skipped for the
	-- danger "×"). The TextButton isn't rotated, so the click area + hover fill tweens are unchanged.
	local bg = btn:FindFirstChild("Bg")
	if bg then
		local w, h = btn.Size.X.Offset, btn.Size.Y.Offset
		local side = math.min(w > 0 and w or h, h) * 0.72
		bg.AnchorPoint = Vector2.new(0.5, 0.5)
		bg.Position = UDim2.fromScale(0.5, 0.5)
		bg.Size = UDim2.fromOffset(side, side)
		bg.Rotation = 45
		local corner = bg:FindFirstChildOfClass("UICorner")
		if corner then corner:Destroy() end
		local outer = bg:FindFirstChildOfClass("UIStroke")
		if outer then outer.Thickness = 1.5 end
		if variant ~= "danger" then
			local inner = Instance.new("Frame")
			inner.Name = "InnerBorder"
			inner.AnchorPoint = Vector2.new(0.5, 0.5)
			inner.Position = UDim2.fromScale(0.5, 0.5)
			inner.Size = UDim2.new(1, -6, 1, -6)
			inner.BackgroundTransparency = 1
			inner.ZIndex = bg.ZIndex + 1
			local istroke = Instance.new("UIStroke")
			istroke.Color = Colors.BorderSubtle
			istroke.Thickness = 1
			istroke.Transparency = 0.15
			istroke.Parent = inner
			inner.Parent = bg
		end
	end

	-- Glyph as geometry: blank the text label (kept only as the variant colour source) and build the
	-- + / × from centre-anchored bars so it's perfectly centred regardless of font.
	local lbl = btn:FindFirstChild("Label")
	local glyphColor = (lbl and lbl.TextColor3) or Colors.TextPrimary
	if lbl then lbl.Text = "" end
	local gsize = glyphSize or GLYPH_SIZE
	local barLen = math.floor(gsize * 0.62 + 0.5)
	local barThick = math.max(2, math.floor(gsize * 0.10 + 0.5))
	local holder = Instance.new("Frame")
	holder.Name = "Glyph"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromOffset(gsize, gsize)
	holder.BackgroundTransparency = 1
	holder.ZIndex = btn.ZIndex + 2
	holder.Parent = btn
	local isCross = (glyph == "\u{00D7}") or (glyph == "x") or (glyph == "X")
	local function bar(rot, vertical)
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(0.5, 0.5)
		f.Size = vertical and UDim2.fromOffset(barThick, barLen) or UDim2.fromOffset(barLen, barThick)
		f.Rotation = rot
		f.BackgroundColor3 = glyphColor
		f.BorderSizePixel = 0
		f.ZIndex = holder.ZIndex
		f.Parent = holder
	end
	if isCross then
		bar(45, false)
		bar(-45, false)
	else
		bar(0, false)
		bar(0, true)
	end
	-- Dim the glyph when the button is inactive (mirrors the label's disabled fade).
	local function syncGlyph()
		local t = (btn.Active == false) and 0.55 or 0
		for _, f in ipairs(holder:GetChildren()) do
			f.BackgroundTransparency = t
		end
	end
	btn:GetPropertyChangedSignal("Active"):Connect(syncGlyph)
	syncGlyph()

	return btn
end

-- A single condensed list row: a square action button on the LEFT (recruit/build "+" or a red cancel
-- "×"), then icon + name, then either a right-aligned value (cost) or a thin progress bar. The row
-- itself carries the hover tooltip; the button sits above it (ZIndex) so it stays clickable.
local function actionRow(parent, cfg)
	local row = Instance.new("Frame")
	row.Name = "ActionRow"
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.BackgroundTransparency = 1
	row.LayoutOrder = cfg.order or 0
	row.Parent = parent

	local btn = squareButton(row, cfg.button.variant, cfg.button.text, BTN_SIZE, "md", cfg.button.onClick)
	btn.AnchorPoint = Vector2.new(0, 0.5)
	btn.Position = UDim2.fromScale(0, 0.5)
	btn.ZIndex = row.ZIndex + 5

	local labelX = CONTENT_X
	if cfg.icon then
		local icon = Icons.create(cfg.icon, 16, Colors.TextSecondary)
		icon.AnchorPoint = Vector2.new(0, 0.5)
		icon.Position = UDim2.new(0, CONTENT_X, 0.5, 0)
		icon.Parent = row
		labelX = CONTENT_X + 24
	end

	local hasProgress = cfg.progress ~= nil
	local progressFill
	local name = Instance.new("TextLabel")
	name.AnchorPoint = Vector2.new(0, hasProgress and 0 or 0.5)
	name.Position = hasProgress and UDim2.fromOffset(labelX, 6) or UDim2.new(0, labelX, 0.5, 0)
	name.Size = UDim2.new(1, -labelX - (cfg.value and 92 or 10), 0, hasProgress and 18 or 24)
	name.BackgroundTransparency = 1
	name.Text = cfg.label or ""
	name.TextColor3 = Colors.TextPrimary
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextYAlignment = Enum.TextYAlignment.Center
	name.TextTruncate = Enum.TextTruncate.AtEnd
	Typography.apply(name, "bodyMd")
	name.Parent = row

	if cfg.value then
		local value = Instance.new("TextLabel")
		value.AnchorPoint = Vector2.new(1, 0.5)
		value.Position = UDim2.fromScale(1, 0.5)
		value.Size = UDim2.new(0, 88, 1, 0)
		value.BackgroundTransparency = 1
		value.Text = cfg.value
		value.TextColor3 = Colors.TextPrimary
		value.TextXAlignment = Enum.TextXAlignment.Right
		Typography.apply(value, "value")
		value.Parent = row
	end

	if hasProgress then
		local pct = math.clamp((cfg.progress.value or 0) / (cfg.progress.max or 100), 0, 1)
		local track = Instance.new("Frame")
		track.AnchorPoint = Vector2.new(0, 1)
		track.Position = UDim2.new(0, labelX, 1, -8)
		track.Size = UDim2.new(1, -labelX - 10, 0, 6)
		track.BackgroundColor3 = Colors.SurfaceSunken
		track.BorderSizePixel = 0
		track.Parent = row
		-- Sharp corners (no UICorner) per design.
		local fill = Instance.new("Frame")
		fill.Size = UDim2.fromScale(pct, 1)
		fill.BackgroundColor3 = Colors.Warning
		fill.BorderSizePixel = 0
		fill.Parent = track
		progressFill = fill
	end

	if cfg.tooltip then
		Tooltip.attach(row, cfg.tooltip)
	end
	return row, progressFill
end

function ProvinceOverview.create(ctx)
	local prov = ctx.data or {}
	local registries = ctx.registries
	local conns = {}
	local handle
	local owns = prov.isOwn == true
	local currentTab = "information"
	-- Progress bars that advance every sim-tick are updated IN PLACE by a throttled loop, so a recruit/
	-- build tick never rebuilds the panel. Each entry = { fill = Frame, live = () -> 0..1 }; rebuilt only
	-- on a structural change (see contentSignature). Reset at the start of every render().
	local liveBars = {}

	local function liveProvince()
		return (ctx.cache and prov.id) and ctx.cache.getProvince(prov.id) or nil
	end
	local function country()
		return (ctx.tag and ctx.cache) and ctx.cache.getCountry(ctx.tag) or nil
	end
	local function unitTypes()
		return (registries and registries.UnitTypes) or {}
	end
	local function buildingTypes()
		return (registries and registries.BuildingTypes) or {}
	end

	-- Single-province version of EconomyScreen.buildableProvinces' inner eligibility test.
	local function canBuildHere(p, id, def)
		if not p then
			return false
		end
		if p.ownerTag ~= ctx.tag or p.controllerTag ~= ctx.tag then
			return false
		end
		if (p.infraTier or 0) < (def.infraRequirement or 0) then
			return false
		end
		if def.requiresCoastal and p.coastal ~= true then
			return false
		end
		local built = p.buildings or {}
		local function has(bid)
			for _, b in ipairs(built) do
				if b == bid then
					return true
				end
			end
			return false
		end
		if def.requires then
			for _, req in ipairs(def.requires) do
				if not has(req) then
					return false
				end
			end
		end
		if not def.repeatable and has(id) then
			return false
		end
		return true
	end

	-- The three province tiers in one row; each cell has a + that queues the matching repeatable upgrade
	-- (improve infrastructure / develop province / expand fortifications), gated by eligibility + cap.
	local function tierRow(parent, p, order)
		local row = Instance.new("Frame")
		row.Name = "Tiers"
		row.Size = UDim2.new(1, 0, 0, 56)
		row.BackgroundTransparency = 1
		row.LayoutOrder = order
		row.Parent = parent
		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = row

		local function cell(caption, value, max, buildingId, i)
			local atMax = value >= max
			local frame = Instance.new("Frame")
			frame.Size = UDim2.fromScale(1 / 3, 1)
			frame.BackgroundTransparency = 1
			frame.LayoutOrder = i
			frame.Parent = row

			local l = Instance.new("TextLabel")
			l.Size = UDim2.new(1, 0, 0, 14)
			l.Position = UDim2.fromOffset(0, 4)
			l.BackgroundTransparency = 1
			l.Text = caption
			l.TextColor3 = Colors.TextTertiary
			l.TextXAlignment = Enum.TextXAlignment.Center
			Typography.apply(l, "caption")
			l.Parent = frame

			-- A centred [value  +] group, so the + reads as part of THIS tier rather than floating at the
			-- cell edge next to the neighbour.
			local group = Instance.new("Frame")
			group.AnchorPoint = Vector2.new(0.5, 1)
			group.Position = UDim2.new(0.5, 0, 1, -4)
			group.Size = UDim2.new(1, 0, 0, 30)
			group.BackgroundTransparency = 1
			group.Parent = frame
			local glayout = Instance.new("UIListLayout")
			glayout.FillDirection = Enum.FillDirection.Horizontal
			glayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
			glayout.VerticalAlignment = Enum.VerticalAlignment.Center
			glayout.SortOrder = Enum.SortOrder.LayoutOrder
			glayout.Padding = UDim.new(0, 8)
			glayout.Parent = group

			-- White current level + a gray "/max" suffix (RichText font-colour override).
			local v = Instance.new("TextLabel")
			v.AutomaticSize = Enum.AutomaticSize.X
			v.Size = UDim2.fromScale(0, 1)
			v.BackgroundTransparency = 1
			v.RichText = true
			v.Text = string.format('%d<font color="%s">/%d</font>', value, GRAY_HEX, max)
			v.TextColor3 = Colors.TextPrimary
			v.TextYAlignment = Enum.TextYAlignment.Center
			v.LayoutOrder = 1
			Typography.apply(v, "displayMd")
			v.Parent = group

			local def = buildingTypes()[buildingId]
			if def then
				-- Lighter (ghost), a small glyph, forced into a true square so it centres beside the number.
				local plus = squareButton(group, "ghost", "+", 28, "sm", function()
					ctx.fire("BuildBuilding", prov.id, buildingId)
				end, 16)
				plus.Size = UDim2.fromOffset(28, 28)
				plus.LayoutOrder = 2
				plus.Active = (not atMax) and canBuildHere(p, buildingId, def)
				Tooltip.attach(plus, function()
					return Tooltip.create({
						title = def.displayName or buildingId,
						body = def.description,
						rows = buildingTooltipRows(def),
						width = 260,
					})
				end)
			end
		end

		local infraTier = (p and p.infraTier) or 0
		local devTier = (p and p.devTier) or 0
		local fortTier = (p and p.fortTier) or 0
		cell("INFRA", infraTier, WorldConstants.InfraTierMax or 10, "improve_infrastructure", 1)
		cell("DEV", devTier, WorldConstants.DevTierMax or 10, "develop_province", 2)
		cell("FORT", fortTier, WorldConstants.FortTierMax or 10, "walls", 3)
	end

	local renderers = {}

	function renderers.information(body)
		local badge = CountryBadge.create({
			code = prov.ownerTag or "\u{2014}",
			countryColor = prov.ownerColor,
			size = "md",
			layoutOrder = 1,
			parent = body,
		})
		badge.LayoutOrder = 1
		-- Clicking the owner crest deep-links to that country's diplomacy profile.
		if prov.ownerTag and ctx.openCountryProfile then
			badge.Active = true
			badge.InputBegan:Connect(function(input)
				if
					input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch
				then
					ctx.openCountryProfile(prov.ownerTag)
				end
			end)
		end

		ScreenKit.section(body, "Land", 2)
		ScreenKit.stat(body, { icon = "MapTerrain", label = "Terrain", value = val(prov.terrain), layoutOrder = 3 })
		ScreenKit.stat(
			body,
			{ icon = "Building", label = "Development", value = val(prov.devTotal), mono = true, layoutOrder = 4 }
		)
		ScreenKit.stat(body, {
			label = "Tax / Prod / Mp",
			value = string.format("%s / %s / %s", val(prov.devAdm), val(prov.devDip), val(prov.devMil)),
			mono = true,
			layoutOrder = 5,
		})
		ScreenKit.stat(body, { icon = "Goods", label = "Trade Good", value = val(prov.tradeGood), layoutOrder = 6 })
		ScreenKit.stat(body, { icon = "Fort", label = "Fort Level", value = val(prov.fortLevel or 0), layoutOrder = 7 })

		ScreenKit.section(body, "Society", 8)
		ScreenKit.stat(body, { icon = "MapCulture", label = "Culture", value = val(prov.culture), layoutOrder = 9 })
		ScreenKit.stat(body, { icon = "MapReligion", label = "Religion", value = val(prov.religion), layoutOrder = 10 })
		ScreenKit.stat(body, {
			icon = "Unrest",
			label = "Unrest",
			value = val(prov.unrest or 0),
			valueColor = (prov.unrest and prov.unrest > 0) and "negative" or nil,
			progress = { value = prov.unrest or 0, max = 10, color = "red" },
			layoutOrder = 11,
		})
		ScreenKit.stat(body, {
			icon = "Lock",
			label = "Autonomy",
			value = (prov.autonomy and prov.autonomy .. "%") or "\u{2014}",
			progress = { value = prov.autonomy or 0, max = 100, color = "amber" },
			layoutOrder = 12,
		})

		ScreenKit.section(body, "Output", 13)
		ScreenKit.stat(body, {
			icon = "Treasury",
			label = "Tax Income",
			value = val(prov.tax),
			valueColor = "positive",
			layoutOrder = 14,
		})
		ScreenKit.stat(body, {
			icon = "Factory",
			label = "Production",
			value = val(prov.production),
			valueColor = "positive",
			layoutOrder = 15,
		})
		-- National manpower as current / max with a bar (replaces the old static per-province baseManpower
		-- value), mirroring the dev/infra "value/max" presentation.
		local mpCountry = country()
		local function fmtMP(n)
			n = math.floor(tonumber(n) or 0)
			return (n >= 1000) and string.format("%.1fK", n / 1000) or tostring(n)
		end
		ScreenKit.stat(body, {
			icon = "Manpower",
			label = "Manpower",
			value = mpCountry and string.format("%s / %s", fmtMP(mpCountry.manpower), fmtMP(mpCountry.manpowerCap))
				or "\u{2014}",
			progress = mpCountry and {
				value = mpCountry.manpower or 0,
				max = math.max(1, mpCountry.manpowerCap or 1),
				color = "amber",
			} or nil,
			mono = true,
			layoutOrder = 16,
		})
	end

	function renderers.recruitment(body)
		ScreenKit.section(body, "Recruitment Queue", 1)
		local c = country()
		local queue = (c and c.recruitQueue) or {}
		-- Group this province's tickets by unit type into ONE row each (×N), so spamming the same unit
		-- reads "Irregular Forces ×3" instead of three rows. Progress = the ACTIVE (soonest-completing)
		-- ticket; the cancel ✕ drops the most-recently-queued ticket of the group (one at a time).
		local groups, groupOrder = {}, {}
		for _, item in ipairs(queue) do
			if item.provinceId == prov.id then
				local g = groups[item.unitTypeId]
				if not g then
					g = { unitTypeId = item.unitTypeId, count = 0, active = item, lastId = item.id, lastQueuedAt = -math.huge }
					groups[item.unitTypeId] = g
					groupOrder[#groupOrder + 1] = g
				end
				g.count += (item.count or 1)
				if (item.completesAt or math.huge) < (g.active.completesAt or math.huge) then
					g.active = item
				end
				if (item.queuedAt or 0) >= g.lastQueuedAt then
					g.lastQueuedAt = item.queuedAt or 0
					g.lastId = item.id
				end
			end
		end
		local order = 2
		for _, g in ipairs(groupOrder) do
			local def = unitTypes()[g.unitTypeId]
			local name = (def and def.displayName) or titleCase(g.unitTypeId)
			if g.count > 1 then
				name = name .. "  \u{00D7}" .. g.count
			end
			local active = g.active
			local _, fill = actionRow(body, {
				order = order,
				icon = "Army",
				label = name,
				progress = { value = progressOf(active.queuedAt, active.completesAt) * 100, max = 100 },
				button = {
					text = "\u{00D7}",
					variant = "danger",
					onClick = function()
						ctx.fire("CancelRecruit", g.lastId)
					end,
				},
			})
			if fill then
				liveBars[#liveBars + 1] =
					{ fill = fill, live = function() return progressOf(active.queuedAt, active.completesAt) end }
			end
			order += 1
		end
		if #groupOrder == 0 then
			ScreenKit.note(body, "No regiments recruiting here.", 2)
		end

		ScreenKit.section(body, "Available Units", 20)
		local pool = {}
		for id, def in pairs(unitTypes()) do
			if type(def) == "table" and def.recruitCost ~= nil and def.unlockedByDefault ~= false then
				pool[#pool + 1] = { id = id, def = def }
			end
		end
		table.sort(pool, function(a, b)
			return (a.def.displayName or a.id) < (b.def.displayName or b.id)
		end)
		local uo = 21
		for _, entry in ipairs(pool) do
			local def = entry.def
			actionRow(body, {
				order = uo,
				icon = "Army",
				label = def.displayName or titleCase(entry.id),
				value = (def.recruitCost or 0) .. " gold",
				tooltip = function()
					return Tooltip.create({
						title = def.displayName or entry.id,
						rows = unitTooltipRows(def),
						width = 230,
					})
				end,
				button = {
					text = "+",
					variant = "secondary",
					onClick = function()
						ctx.fire("RecruitUnit", prov.id, entry.id, 1)
					end,
				},
			})
			uo += 1
		end
	end

	function renderers.buildings(body)
		local p = liveProvince()
		tierRow(body, p, 1)

		ScreenKit.section(body, "Buildings", 10)
		local built = (p and p.buildings) or {}
		if #built == 0 then
			ScreenKit.note(body, "No buildings constructed yet.", 11)
		else
			local bo = 11
			for _, bid in ipairs(built) do
				local def = buildingTypes()[bid]
				local row = ScreenKit.stat(body, {
					icon = "Building",
					label = (def and def.displayName) or titleCase(bid),
					value = def and (CATEGORY_LABELS[def.category] or titleCase(def.category)) or "",
					layoutOrder = bo,
				})
				if def then
					Tooltip.attach(row, function()
						return Tooltip.create({
							title = def.displayName or bid,
							body = def.description,
							rows = buildingTooltipRows(def),
							width = 280,
						})
					end)
				end
				bo += 1
			end
		end

		ScreenKit.section(body, "Construction", 20)
		local c = country()
		local queue = (c and c.buildQueue) or {}
		local shown, qo = 0, 21
		for _, item in ipairs(queue) do
			if item.provinceId == prov.id then
				shown += 1
				local def = buildingTypes()[item.buildingId]
				local bItem = item
				local _, fill = actionRow(body, {
					order = qo,
					icon = "Building",
					label = (def and def.displayName) or titleCase(item.buildingId),
					progress = { value = progressOf(bItem.startedAt, bItem.completesAt) * 100, max = 100 },
					button = {
						text = "\u{00D7}",
						variant = "danger",
						onClick = function()
							ctx.fire("CancelBuilding", bItem.id)
						end,
					},
				})
				if fill then
					liveBars[#liveBars + 1] =
						{ fill = fill, live = function() return progressOf(bItem.startedAt, bItem.completesAt) end }
				end
				qo += 1
			end
		end
		if shown == 0 then
			ScreenKit.note(body, "Nothing under construction.", 21)
		end

		local groups = {}
		for id, def in pairs(buildingTypes()) do
			if type(def) == "table" and not TIER_BUILDINGS[id] and canBuildHere(p, id, def) then
				local cat = def.category or "other"
				groups[cat] = groups[cat] or {}
				table.insert(groups[cat], { id = id, def = def })
			end
		end
		local cats = {}
		for cat in pairs(groups) do
			cats[#cats + 1] = cat
		end
		table.sort(cats)
		local ao = 40
		if #cats == 0 then
			ScreenKit.note(body, "No buildings available here yet.", ao)
		else
			for _, cat in ipairs(cats) do
				ScreenKit.section(body, CATEGORY_LABELS[cat] or titleCase(cat), ao)
				ao += 1
				local items = groups[cat]
				table.sort(items, function(a, b)
					return (a.def.displayName or a.id) < (b.def.displayName or b.id)
				end)
				for _, entry in ipairs(items) do
					local def = entry.def
					actionRow(body, {
						order = ao,
						icon = "Building",
						label = def.displayName or titleCase(entry.id),
						value = (def.cost or 0) .. " gold",
						tooltip = function()
							return Tooltip.create({
								title = def.displayName or entry.id,
								body = def.description,
								rows = buildingTooltipRows(def),
								width = 280,
							})
						end,
						button = {
							text = "+",
							variant = "secondary",
							onClick = function()
								ctx.fire("BuildBuilding", prov.id, entry.id)
							end,
						},
					})
					ao += 1
				end
			end
		end
	end

	local function render(tab)
		currentTab = tab
		table.clear(liveBars) -- the old fills are about to be destroyed by clearBody()
		handle.clearBody()
		local fn = renderers[tab] or renderers.information
		fn(handle.body)
	end

	local lastSig = nil
	local dirty = false

	-- Hashes ONLY the STRUCTURE the current owned tab renders (ticket/unit/building id sets, counts,
	-- tiers) -- NOT progress, which is advanced in place by the liveBars loop. So a recruit/build/economy
	-- tick never rebuilds the panel; a rebuild happens only when a ticket is added/removed/completed, a
	-- unit unlocks, or a tier/building changes. Id sets are sorted for stability.
	local function contentSignature(tabKey)
		local parts = { tabKey }
		if tabKey == "recruitment" then
			local c = country()
			local queue = (c and c.recruitQueue) or {}
			local q = {}
			for _, item in ipairs(queue) do
				if item.provinceId == prov.id then
					q[#q + 1] = string.format(
						"%s:%s:%s",
						tostring(item.id),
						tostring(item.unitTypeId),
						tostring(item.count or 1)
					)
				end
			end
			table.sort(q)
			parts[#parts + 1] = "rq:" .. table.concat(q, ",")
			-- Available units come from the static registry, but include their ids so an unlock change reflects.
			local units = {}
			for id, def in pairs(unitTypes()) do
				if type(def) == "table" and def.recruitCost ~= nil and def.unlockedByDefault ~= false then
					units[#units + 1] = id
				end
			end
			table.sort(units)
			parts[#parts + 1] = "u:" .. table.concat(units, ",")
		elseif tabKey == "buildings" then
			local p = liveProvince()
			parts[#parts + 1] =
				string.format("t:%d:%d:%d", (p and p.infraTier) or 0, (p and p.devTier) or 0, (p and p.fortTier) or 0)
			-- Built buildings list (also feeds canBuildHere eligibility).
			local built = (p and p.buildings) or {}
			local bsorted = {}
			for _, bid in ipairs(built) do
				bsorted[#bsorted + 1] = bid
			end
			table.sort(bsorted)
			parts[#parts + 1] = "b:" .. table.concat(bsorted, ",")
			-- Construction queue for this province (ids + bucketed progress).
			local c = country()
			local queue = (c and c.buildQueue) or {}
			local q = {}
			for _, item in ipairs(queue) do
				if item.provinceId == prov.id then
					q[#q + 1] = string.format(
						"%s:%s",
						tostring(item.id),
						tostring(item.buildingId)
					)
				end
			end
			table.sort(q)
			parts[#parts + 1] = "cq:" .. table.concat(q, ",")
			-- Available-to-build building ids (canBuildHere depends on this province's infra/buildings/coastal).
			local avail = {}
			for id, def in pairs(buildingTypes()) do
				if type(def) == "table" and not TIER_BUILDINGS[id] and canBuildHere(p, id, def) then
					avail[#avail + 1] = id
				end
			end
			table.sort(avail)
			parts[#parts + 1] = "av:" .. table.concat(avail, ",")
		end
		return table.concat(parts, "|")
	end

	local TABS = { { key = "information", label = "Information" } }
	if owns then
		TABS[#TABS + 1] = { key = "recruitment", label = "Recruitment" }
		TABS[#TABS + 1] = { key = "buildings", label = "Buildings" }
	end

	handle = ScreenKit.open(ctx, {
		name = "ProvinceOverview",
		shell = "panel_medium_shell",
		title = prov.name or "Province",
		subtitle = (prov.ownerName and (prov.ownerName .. "  \u{00B7}  ") or "") .. ("#" .. tostring(prov.id or "?")),
		anchorPoint = Vector2.new(1, 0),
		position = UDim2.new(1, -16, 0, 16),
		size = UDim2.new(0, 380, 1, -132),
		tabs = owns and TABS or nil,
		activeTab = owns and "information" or nil,
		onTab = owns and function(key)
			render(key)
			lastSig = contentSignature(key)
		end or nil,
	})

	if owns then
		local function scheduleRefresh()
			if dirty then
				return
			end
			dirty = true
			task.defer(function()
				dirty = false
				if not (handle and handle.root and handle.root.Parent) then
					return
				end
				local sig = contentSignature(currentTab)
				if sig == lastSig then
					return
				end
				lastSig = sig
				render(currentTab)
			end)
		end
		if ctx.cache then
			table.insert(conns, ctx.cache.onChangePrefix("countries", scheduleRefresh))
			table.insert(conns, ctx.cache.onChangePrefix("provinces", scheduleRefresh))
		end
	end

	-- Advance live progress fills in place (~10Hz) so a recruit/build tick updates bars without a panel
	-- rebuild. Disconnected on destroy via conns.
	local liveAccum = 0
	local hbConn = RunService.Heartbeat:Connect(function(dt)
		liveAccum += dt
		if liveAccum < 0.1 then
			return
		end
		liveAccum = 0
		if not (handle and handle.root and handle.root.Parent) then
			return
		end
		for _, b in ipairs(liveBars) do
			if b.fill and b.fill.Parent then
				b.fill.Size = UDim2.fromScale(math.clamp(b.live(), 0, 1), 1)
			end
		end
	end)
	table.insert(conns, function()
		hbConn:Disconnect()
	end)

	render("information")
	if owns then
		lastSig = contentSignature(currentTab)
	end

	return {
		root = handle.root,
		destroy = function()
			for _, d in conns do
				pcall(d)
			end
			handle.destroy()
		end,
	}
end

return ProvinceOverview
