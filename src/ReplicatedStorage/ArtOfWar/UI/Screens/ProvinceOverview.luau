local ScreenKit = require(script.Parent.ScreenKit)
local Components = script.Parent.Parent.Components
local Button = require(Components.Button)
local CountryBadge = require(Components.CountryBadge)
local Tooltip = require(Components.Tooltip)
local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Icons = DesignSystem.Icons
local Responsive = DesignSystem.Responsive
local Modal = require(Components.Modal)
local SimClock = require(script.Parent.Parent.Parent.Modules.SimClock)
local CountryColor = require(script.Parent.Parent.Parent.Modules.CountryColor)
local WorldConstants = require(script.Parent.Parent.Parent.Shared.WorldConstants)
local Terrains = require(script.Parent.Parent.Parent.Data.Terrains)
local DistrictTypes = require(script.Parent.Parent.Parent.Data.DistrictTypes)
local EconomyPreview = require(script.Parent.Parent.Parent.Modules.EconomyPreview)
local RecruitGate = require(script.Parent.Parent.Parent.Modules.RecruitGate)
local RunService = game:GetService("RunService")

-- Economy rework: buildings absorbed into districts (base buildings + manufactories) carry
-- def.absorbedByDistrict (set in Data/BuildingTypes -- the single source of truth). When DistrictsPlayable is
-- on they are hidden from the legacy build catalogs; they live in the district grid instead.

-- District accent color by colorKey -> one warm-palette color. Drives the left spine + icon tint ONLY (never
-- the border fill), so each district TYPE gets a restrained identity and Military(olive)/Harbor(blue) never
-- read as an error state. farm/industry have no faction color, so Positive/Warning are the natural in-palette reads.
local DISTRICT_ACCENT = {
	sea = Colors.FactionMerchant, -- Harbor: blue
	earth = Colors.FactionAristocrat, -- Mining: bronze
	farm = Colors.Positive, -- Agricultural: green
	industry = Colors.Warning, -- Industrial / Manufacturing: amber
	military = Colors.FactionMilitary, -- Military: olive
}
local function districtAccent(def)
	return (def and DISTRICT_ACCENT[def.colorKey]) or Colors.BorderStrong
end

-- "Harbor District" -> "Harbor" (the section header already says "Districts").
local function districtShortName(def, fallback)
	local dn = (def and def.displayName) or fallback or ""
	return (dn:gsub("%s*District$", ""))
end

-- A 3px accent spine down the left inner edge -- the district's single color hit on a warm-neutral tile.
local function addDistrictSpine(cell, accent)
	local spine = Instance.new("Frame")
	spine.Name = "Spine"
	spine.AnchorPoint = Vector2.new(0, 0.5)
	spine.Position = UDim2.fromScale(0, 0.5)
	spine.Size = UDim2.new(0, 3, 1, -2)
	spine.BackgroundColor3 = accent
	spine.BorderSizePixel = 0
	spine.ZIndex = 2
	spine.Parent = cell
end

-- Combat depth A: the defender bonus a terrain/fort grants in battle, shown as a small caption under
-- the value (combat already applies it; this just surfaces it). Returns "+X% def", or nil when the
-- flag is off / there is no bonus.
local function defDelta(fraction)
	if not WorldConstants.EnableDefenseBreakdown or not fraction or fraction <= 0 then
		return nil
	end
	return string.format("+%d%% def", math.floor(fraction * 100 + 0.5))
end

local ProvinceOverview = {}

-- Recruit/build rows are a little larger on touch (taller row, bigger diamond + glyph + font) so they're
-- comfortable to tap and read on a phone. Button.create already makes the button >=44 tall on touch, so
-- bumping BTN_SIZE (the width) is what actually enlarges the width-limited diamond.
local TOUCH = Responsive.isTouch()
local ROW_HEIGHT = TOUCH and 52 or 44
local BTN_SIZE = TOUCH and 44 or 36
local CONTENT_X = BTN_SIZE + 10
local GLYPH_SIZE = TOUCH and 28 or 22

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
		if corner then
			corner:Destroy()
		end
		local outer = bg:FindFirstChildOfClass("UIStroke")
		if outer then
			outer.Thickness = 1.5
		end
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
	if lbl then
		lbl.Text = ""
	end
	local gsize = glyphSize or GLYPH_SIZE
	local barLen = math.floor(gsize * 0.42 + 0.5)
	local barThick = math.max(1, math.floor(gsize * 0.06 + 0.5))
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

	-- Note: the rotated diamond escapes a ScrollingFrame's clip, but the ScreenKit scroll body wraps its
	-- content in a CanvasGroup which clips it correctly -- so no per-button clipping is needed here.
	return btn
end

-- A single condensed list row: a square action button on the LEFT (recruit/build "+" or a red cancel
-- "×"), then icon + name, then either a right-aligned value (cost) or a thin progress bar. The row
-- itself carries the hover tooltip; the button sits above it (ZIndex) so it stays clickable. When
-- cfg.disabled, the button is inert (Button.create Active=false blocks the click + greys fill/glyph) and
-- the label/value are dimmed so an ineligible action reads as unavailable.
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
	if cfg.disabled then
		btn.Active = false -- greys the diamond + glyph and blocks the click (Button.create gates onClick on Active)
	end
	local textColor = cfg.disabled and Colors.TextDisabled or Colors.TextPrimary

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
	name.TextColor3 = textColor
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextYAlignment = Enum.TextYAlignment.Center
	name.TextTruncate = Enum.TextTruncate.AtEnd
	Typography.apply(name, "bodyMd")
	if TOUCH then
		name.TextSize = name.TextSize + 2
	end
	name.Parent = row

	if cfg.value then
		local value = Instance.new("TextLabel")
		value.AnchorPoint = Vector2.new(1, 0.5)
		value.Position = UDim2.fromScale(1, 0.5)
		value.Size = UDim2.new(0, 88, 1, 0)
		value.BackgroundTransparency = 1
		value.Text = cfg.value
		value.TextColor3 = cfg.disabled and Colors.Warning or Colors.TextPrimary
		value.TextXAlignment = Enum.TextXAlignment.Right
		Typography.apply(value, "value")
		if TOUCH then
			value.TextSize = value.TextSize + 2
		end
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

-- Aggregate mode (C6 multi-province selection): ctx.data = { multi=true, ids={...}, ownedIds={...} }.
-- One flat body (no tabs): union recruit list + union build list over the OWNED selection, each row
-- firing the batched remote; per-province validation happens server-side, so partial application
-- ("Queued in 4/7 provinces") is reported by the server toast, not here. HudWiring re-fires
-- openProvince on every selection toggle, so this panel is rebuilt live and holds no signature state.
local function createMulti(ctx)
	local data = ctx.data or {}
	local ids = data.ids or {}
	local ownedIds = data.ownedIds or {}
	local registries = ctx.registries
	local handle

	local function cacheProvince(id)
		return ctx.cache and ctx.cache.getProvince(id) or nil
	end

	-- Mirror of create()'s canBuildHere, minus the closure state (same eligibility rules).
	local function canBuildAt(p, id, def)
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
		local has = {}
		for _, b in ipairs(built) do
			has[b] = true
		end
		if not def.repeatable and has[id] then
			return false
		end
		for _, prereq in ipairs(def.requires or {}) do
			if not has[prereq] then
				return false
			end
		end
		return true
	end

	local totalDev = 0
	for _, id in ipairs(ownedIds) do
		local p = cacheProvince(id)
		totalDev += (p and p.devTier) or 0
	end

	handle = ScreenKit.open(ctx, {
		name = "ProvinceOverview",
		shell = "panel_medium_shell",
		title = string.format("%d provinces selected", #ids),
		subtitle = string.format("%d owned  \u{00B7}  total dev %d  \u{00B7}  max 25", #ownedIds, totalDev),
		anchorPoint = Vector2.new(1, 1),
		position = UDim2.new(1, -16, 1, -16),
		size = UDim2.fromOffset(360, 620),
	})

	local body = handle.body
	if #ownedIds == 0 then
		ScreenKit.note(
			body,
			"None of the selected provinces are yours \u{2014} batch actions need owned, controlled land.",
			1
		)
	else
		ScreenKit.section(body, string.format("Recruit in all (%d owned)", #ownedIds), 10)
		-- Union semantics: a professional unit is greyed only when NONE of the owned selected provinces has a
		-- Military district (if any does, the batched remote still queues it there and skips the rest).
		local anyMilitary = false
		for _, id in ipairs(ownedIds) do
			if RecruitGate.provinceHasMilitaryDistrict(cacheProvince(id)) then
				anyMilitary = true
				break
			end
		end
		local pool = {}
		for id, def in pairs((registries and registries.UnitTypes) or {}) do
			if type(def) == "table" and def.recruitCost ~= nil and def.unlockedByDefault ~= false then
				pool[#pool + 1] = { id = id, def = def }
			end
		end
		RecruitGate.sortPool(pool) -- levy (militia/irregular) on top, then professional; each alphabetical
		local uo = 11
		for _, entry in ipairs(pool) do
			local def = entry.def
			local locked = RecruitGate.unitNeedsMilitaryDistrict(def) and not anyMilitary
			actionRow(body, {
				order = uo,
				icon = "Army",
				label = def.displayName or titleCase(entry.id),
				value = locked and "Needs Military" or string.format("%d gold ea", def.recruitCost or 0),
				disabled = locked,
				tooltip = function()
					return Tooltip.create({
						title = def.displayName or entry.id,
						body = locked and "No selected province has a Military district." or nil,
						rows = unitTooltipRows(def),
						width = 230,
					})
				end,
				button = {
					text = "+1 ea",
					variant = "secondary",
					onClick = function()
						ctx.fire("RecruitUnitMulti", ownedIds, entry.id, 1)
					end,
				},
			})
			uo += 1
		end

		ScreenKit.section(body, "Build in all (where eligible)", 30)
		-- Union: a building shows when ANY owned selected province can take it; the batched
		-- remote validates per province, so ineligible tiles just count as failures in the toast.
		-- District-absorbed buildings (and manufactories) are hidden once the district economy is on --
		-- they are built as districts, not here (matches the single-province + Economy build catalogs).
		local districtsOn = WorldConstants.DistrictsPlayable
		local buildable = {}
		for id, def in pairs((registries and registries.BuildingTypes) or {}) do
			if type(def) == "table" and not TIER_BUILDINGS[id] and not (districtsOn and def.absorbedByDistrict) then
				for _, pid in ipairs(ownedIds) do
					if canBuildAt(cacheProvince(pid), id, def) then
						buildable[#buildable + 1] = { id = id, def = def }
						break
					end
				end
			end
		end
		table.sort(buildable, function(a, b)
			return (a.def.displayName or a.id) < (b.def.displayName or b.id)
		end)
		if #buildable == 0 then
			ScreenKit.note(body, "Nothing buildable on the selected provinces.", 31)
		else
			local bo = 31
			for _, entry in ipairs(buildable) do
				local def = entry.def
				actionRow(body, {
					order = bo,
					icon = "Building",
					label = def.displayName or titleCase(entry.id),
					value = string.format("%d gold ea", def.cost or 0),
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
							ctx.fire("ConstructBuildingMulti", ownedIds, entry.id)
						end,
					},
				})
				bo += 1
			end
		end
	end

	return {
		root = handle.root,
		destroy = function()
			handle.destroy()
		end,
	}
end

function ProvinceOverview.create(ctx)
	local prov = ctx.data or {}
	if prov.multi then
		return createMulti(ctx)
	end
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
				local plusSz = Responsive.isTouch() and 44 or 28 -- D2: 44px tap target on touch
				local plus = squareButton(group, "ghost", "+", plusSz, "sm", function()
					ctx.fire("BuildBuilding", prov.id, buildingId)
				end, 16)
				plus.Size = UDim2.fromOffset(plusSz, plusSz)
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

	-- ===================== Districts (economy rework) =====================
	local function districtTaxLabel(dtype, level)
		local v = EconomyPreview.districtMonthlyTax(dtype, level, WorldConstants)
		if not v or v <= 0 then
			return "\u{2014}"
		end
		return string.format("+%.1f/mo", v)
	end

	-- Client mirror of the server's placement eligibility (slot/afford re-checked server-side).
	local function eligibleDistrictTypes(pp)
		local out = {}
		for _, dtype in DistrictTypes.order do
			local def = DistrictTypes.types[dtype]
			local ok = true
			if def.requiresCoastal and (not pp or pp.coastal ~= true) then
				ok = false
			end
			if ok and def.role == "extraction" then
				ok = DistrictTypes.extractionDistrictFor(pp and pp.tradeGood) == dtype
			end
			if ok then
				out[#out + 1] = dtype
			end
		end
		return out
	end

	local function districtQueueBySlot()
		local c = country()
		local bySlot = {}
		for _, t in ((c and c.districtQueue) or {}) do
			if t.provinceId == prov.id then
				bySlot[t.slotIndex] = t
			end
		end
		return bySlot
	end

	local function openDistrictPicker(slotIndex, pp)
		local eligible = eligibleDistrictTypes(pp)
		local modal = Modal.create({
			parent = ctx.modalLayer or ctx.parent,
			title = "Build District",
			subtitle = string.format("%s  \u{00B7}  slot %d", prov.name or "Province", slotIndex),
			width = 340,
			height = 300,
		})
		local content = modal.content
		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 6)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = content
		if #eligible == 0 then
			ScreenKit.note(content, "No districts can be built on this tile.", 1)
			return
		end
		for i, dtype in eligible do
			local def = DistrictTypes.types[dtype]
			local row = ScreenKit.buttonRow(content, i)
			Button.create({
				parent = row,
				variant = "secondary",
				text = string.format("%s   (%s)", def.displayName, districtTaxLabel(dtype, 1)),
				onClick = function()
					ctx.fire("BuildDistrict", prov.id, slotIndex, dtype)
					modal.close()
				end,
			})
		end
	end

	-- Confirmation popup before razing. Resolves the slot's district (or its in-flight build) so both the
	-- filled-cell and in-progress "x" can call confirmRaze(slot) identically.
	local function confirmRaze(slotIndex)
		local p = liveProvince()
		local d = p and p.districts and p.districts[slotIndex]
		local dtype = d and d.type
		if not dtype then
			local c = country()
			for _, t in ((c and c.districtQueue) or {}) do
				if t.provinceId == prov.id and t.slotIndex == slotIndex then
					dtype = t.districtType
					break
				end
			end
		end
		local def = dtype and DistrictTypes.types[dtype]
		local name = (def and def.displayName) or "this district"
		local modal = Modal.create({
			parent = ctx.modalLayer or ctx.parent,
			title = "Raze District",
			subtitle = prov.name or "Province",
			width = 320,
			height = 200,
		})
		local content = modal.content
		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 10)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = content
		ScreenKit.note(content, string.format("Raze %s? This clears the slot with NO refund.", name), 1)
		local row = ScreenKit.buttonRow(content, 2)
		Button.create({
			parent = row,
			variant = "danger",
			text = "Raze",
			onClick = function()
				ctx.fire("RazeDistrict", prov.id, slotIndex)
				modal.close()
			end,
		})
		Button.create({
			parent = row,
			variant = "ghost",
			text = "Cancel",
			onClick = function()
				modal.close()
			end,
		})
	end

	-- Raze control: a plain red "x" glyph (NO diamond) tucked in the cell's top-right corner.
	local RAZE_HOVER = Colors.Negative:Lerp(Color3.new(1, 1, 1), 0.25)
	local function makeRazeX(cell, slotIndex)
		local x = Instance.new("TextButton")
		x.Name = "Raze"
		x.AnchorPoint = Vector2.new(1, 0)
		x.Position = UDim2.new(1, -4, 0, 3)
		x.Size = UDim2.fromOffset(18, 18)
		x.BackgroundTransparency = 1
		x.AutoButtonColor = false
		x.Text = "\u{00D7}"
		x.TextColor3 = Colors.Negative
		x.TextSize = 18
		x.FontFace = Typography.SansBold
		x.ZIndex = 5
		x.Parent = cell
		x.MouseButton1Click:Connect(function()
			confirmRaze(slotIndex)
		end)
		x.MouseEnter:Connect(function()
			x.TextColor3 = RAZE_HOVER
		end)
		x.MouseLeave:Connect(function()
			x.TextColor3 = Colors.Negative
		end)
		return x
	end

	local function progressTrack(cell, ticket, accent)
		local track = Instance.new("Frame")
		track.AnchorPoint = Vector2.new(0.5, 1)
		track.Position = UDim2.new(0.5, 2, 1, -4) -- +2 x clears the 3px left spine
		track.Size = UDim2.new(1, -14, 0, 4)
		track.BackgroundColor3 = Colors.SurfaceSunken
		track.BorderSizePixel = 0
		track.ZIndex = 3
		track.Parent = cell
		local fill = Instance.new("Frame")
		fill.Size = UDim2.fromScale(progressOf(ticket.startedAt, ticket.completesAt), 1)
		fill.BackgroundColor3 = accent or Colors.Warning
		fill.BorderSizePixel = 0
		fill.Parent = track
		liveBars[#liveBars + 1] = {
			fill = fill,
			live = function()
				return progressOf(ticket.startedAt, ticket.completesAt)
			end,
		}
	end

	local function fillDistrictCell(cell, slot, d, ticket, cap)
		local def = DistrictTypes.types[d.type]
		local accent = districtAccent(def)
		addDistrictSpine(cell, accent)

		-- Icon (accent-tinted) top-left -- the district's color identity, no extra chrome.
		local icon = Icons.create(def and def.icon or "Building", 20, accent)
		icon.AnchorPoint = Vector2.new(0, 0)
		icon.Position = UDim2.fromOffset(11, 8)
		icon.Parent = cell

		-- Name, to the right of the icon (short form -- "Harbor", not "Harbor District").
		local name = Instance.new("TextLabel")
		name.BackgroundTransparency = 1
		name.AnchorPoint = Vector2.new(0, 0)
		name.Position = UDim2.fromOffset(37, 8)
		name.Size = UDim2.new(1, -43, 0, 15)
		name.Text = districtShortName(def, d.type)
		name.TextColor3 = Colors.TextPrimary
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextTruncate = Enum.TextTruncate.AtEnd
		Typography.apply(name, "bodySm")
		name.Parent = cell

		-- Income (+X.X/mo) under the name.
		local inc = Instance.new("TextLabel")
		inc.BackgroundTransparency = 1
		inc.AnchorPoint = Vector2.new(0, 0)
		inc.Position = UDim2.fromOffset(37, 25)
		inc.Size = UDim2.new(1, -43, 0, 12)
		inc.Text = districtTaxLabel(d.type, d.level or 1)
		inc.TextColor3 = Colors.Positive
		inc.TextXAlignment = Enum.TextXAlignment.Left
		Typography.apply(inc, "caption")
		inc.Parent = cell

		-- Raze: a plain red "x" (no diamond) in the top-right corner. Confirm modal is the safety gate.
		makeRazeX(cell, slot)

		if ticket then
			-- Filled AND re-building (upgrade in progress): accent progress bar, skip level/upgrade.
			progressTrack(cell, ticket, accent)
			return
		end

		local maxed = (d.level or 0) >= cap

		-- Level, bottom-left. Gold when maxed (pairs with the auto-dimmed upgrade diamond).
		local lvl = Instance.new("TextLabel")
		lvl.BackgroundTransparency = 1
		lvl.AnchorPoint = Vector2.new(0, 1)
		lvl.Position = UDim2.new(0, 11, 1, -7)
		lvl.Size = UDim2.new(0.55, 0, 0, 13)
		lvl.Text = string.format("L%d/%d", d.level or 1, cap)
		lvl.TextColor3 = maxed and Colors.BorderActive or Colors.TextSecondary
		lvl.TextXAlignment = Enum.TextXAlignment.Left
		Typography.apply(lvl, "caption")
		lvl.Parent = cell

		-- Upgrade (primary action), bottom-right, inset so the diamond never crosses the stroke.
		local up = squareButton(cell, "secondary", "+", 22, "sm", function()
			ctx.fire("UpgradeDistrict", prov.id, slot)
		end, 13)
		up.AnchorPoint = Vector2.new(1, 1)
		up.Position = UDim2.new(1, -6, 1, -6)
		up.Size = UDim2.fromOffset(22, 22)
		up.Active = not maxed
	end

	local function renderDistrictGrid(body, pp, order)
		local slots = math.max(0, math.floor((pp and pp.infraTier) or 0))
		local cap = math.max(0, math.floor((pp and pp.devTier) or 0))
		local used = 0
		if pp and pp.districts then
			for _, d in pairs(pp.districts) do
				if type(d) == "table" and d.type then
					used += 1
				end
			end
		end
		ScreenKit.section(body, string.format("Districts   %d / %d slots", used, slots), order)
		if slots <= 0 then
			ScreenKit.note(body, "No building slots \u{2014} raise Infrastructure to unlock slots.", order + 1)
			return
		end
		local grid = Instance.new("Frame")
		grid.Name = "DistrictGrid"
		grid.BackgroundTransparency = 1
		grid.Size = UDim2.fromScale(1, 0)
		grid.AutomaticSize = Enum.AutomaticSize.Y
		grid.LayoutOrder = order + 1
		grid.Parent = body
		local g = Instance.new("UIGridLayout")
		-- Two tiles per row: each is half the grid width (minus its share of the 8px gap) so a PAIR fills the
		-- row on any panel width, CENTERED so a lone slot reads as a deliberate centered tile. Cell content is
		-- edge-anchored, so the wider tile simply gains breathing room. 3+ slots wrap to a centered next row.
		g.CellSize = UDim2.new(0.5, -6, 0, 92)
		g.CellPadding = UDim2.fromOffset(8, 8)
		g.FillDirection = Enum.FillDirection.Horizontal
		g.FillDirectionMaxCells = 2
		g.HorizontalAlignment = Enum.HorizontalAlignment.Center
		g.SortOrder = Enum.SortOrder.LayoutOrder
		g.Parent = grid

		local queued = districtQueueBySlot()
		for slot = 1, slots do
			local d = pp.districts and pp.districts[slot]
			local ticket = queued[slot]

			local cell = Instance.new("Frame")
			cell.Name = "Slot" .. slot
			-- Filled/building tiles ELEVATE; an empty slot stays recessed (a "well") with its border faded back.
			cell.BackgroundColor3 = (d or ticket) and Colors.SurfaceElevated or Colors.SurfaceSunken
			cell.BorderSizePixel = 0
			cell.LayoutOrder = slot
			cell.Parent = grid
			local stroke = Instance.new("UIStroke")
			stroke.Color = Colors.BorderSubtle
			stroke.Transparency = d and 0.15 or (ticket and 0.35 or 0.55)
			stroke.Parent = cell
			if d then
				fillDistrictCell(cell, slot, d, ticket, cap)
			elseif ticket then
				local def = DistrictTypes.types[ticket.districtType]
				local accent = districtAccent(def)
				addDistrictSpine(cell, accent)

				-- Ghosted "target" icon (accent-tinted) so you can see WHAT is being built.
				local icon = Icons.create(def and def.icon or "Building", 24, accent)
				icon.AnchorPoint = Vector2.new(0.5, 0.5)
				icon.Position = UDim2.new(0.5, 2, 0.42, 0) -- +2 x clears the spine
				icon.ImageTransparency = 0.45
				icon.Parent = cell

				local building = Instance.new("TextLabel")
				building.BackgroundTransparency = 1
				building.AnchorPoint = Vector2.new(0.5, 0)
				building.Position = UDim2.new(0.5, 2, 0.62, 0)
				building.Size = UDim2.new(1, -18, 0, 12)
				building.Text = "Building\u{2026}"
				building.TextColor3 = Colors.TextSecondary
				building.TextXAlignment = Enum.TextXAlignment.Center
				Typography.apply(building, "caption")
				building.Parent = cell

				progressTrack(cell, ticket, accent)

				-- Cancel: same plain red "x" as raze, top-right.
				makeRazeX(cell, slot)
			else
				-- Recessed empty "well" (fill/stroke set above). No spine -- no district, no identity yet.
				local plus = squareButton(cell, "ghost", "+", 30, "sm", function()
					openDistrictPicker(slot, pp)
				end, 18)
				plus.AnchorPoint = Vector2.new(0.5, 0.5)
				plus.Position = UDim2.new(0.5, 0, 0.5, -6)
				plus.Size = UDim2.fromOffset(32, 32)

				local hint = Instance.new("TextLabel")
				hint.BackgroundTransparency = 1
				hint.AnchorPoint = Vector2.new(0.5, 1)
				hint.Position = UDim2.new(0.5, 0, 1, -8)
				hint.Size = UDim2.new(1, -12, 0, 12)
				hint.Text = "Build"
				hint.TextColor3 = Colors.TextTertiary
				hint.TextXAlignment = Enum.TextXAlignment.Center
				Typography.apply(hint, "caption")
				hint.Parent = cell
			end
		end
	end

	local renderers = {}

	function renderers.information(body)
		-- The owner crest now sits in the shell header, left of the title (added after ScreenKit.open,
		-- mirroring the army panel) -- so the Information body leads with the Cores row.

		-- Cores row (RoN-style): a small crest per core, GOLD-outlined for default/homeland cores and
		-- un-outlined for acquired ones. Read from the live replicated record (prov lacks cores/claims).
		local live = liveProvince()

		-- Occupation status (occupation is NOT ownership): when the province is held by someone other than
		-- its owner, lead with an explicit banner so the lighter map tint / stripes are never mistaken for a
		-- conquest. If WE occupy but do not own it, spell out why Build/Recruit are unavailable (annex at peace).
		do
			local ownerTag = (live and live.ownerTag) or prov.ownerTag
			local controllerTag = live and live.controllerTag
			if controllerTag and ownerTag and controllerTag ~= ownerTag then
				local function nameOf(tag)
					local c = ctx.cache and ctx.cache.getCountry and ctx.cache.getCountry(tag)
					return (c and (c.displayName or c.name)) or tag
				end
				local occName = nameOf(controllerTag)
				local ownName = (ownerTag == prov.ownerTag and prov.ownerName) or nameOf(ownerTag)
				ScreenKit.stat(body, {
					icon = "Fort",
					label = "Occupied by",
					value = occName,
					valueColor = "negative",
					layoutOrder = -2,
				})
				if controllerTag == ctx.tag and ownerTag ~= ctx.tag then
					ScreenKit.note(
						body,
						string.format(
							"You occupy this province but %s still owns it. Annex it in a peace deal to build or recruit here.",
							ownName
						),
						-1
					)
				else
					ScreenKit.note(body, string.format("Owned by %s.", ownName), -1)
				end
			end
		end

		local cores = (live and live.cores) or {}
		local defaultCores = (live and live.defaultCores) or {}
		if #cores > 0 then
			local coresRow = Instance.new("Frame")
			coresRow.Name = "CoresRow"
			coresRow.BackgroundTransparency = 1
			coresRow.Size = UDim2.new(1, 0, 0, 28)
			coresRow.LayoutOrder = 0
			coresRow.Parent = body
			local hl = Instance.new("UIListLayout")
			hl.FillDirection = Enum.FillDirection.Horizontal
			hl.Padding = UDim.new(0, 4)
			hl.VerticalAlignment = Enum.VerticalAlignment.Center
			hl.SortOrder = Enum.SortOrder.LayoutOrder
			hl.Parent = coresRow

			local lbl = Instance.new("TextLabel")
			lbl.Name = "CoresLabel"
			lbl.BackgroundTransparency = 1
			lbl.Text = "Cores"
			lbl.TextXAlignment = Enum.TextXAlignment.Left
			lbl.TextColor3 = Colors.TextSecondary
			lbl.Size = UDim2.fromOffset(52, 28)
			lbl.LayoutOrder = 0
			Typography.apply(lbl, "label")
			lbl.Parent = coresRow

			local defaultSet = {}
			for _, t in ipairs(defaultCores) do
				defaultSet[t] = true
			end

			for i, tag in ipairs(cores) do
				local flagBadge = CountryBadge.create({
					code = tag,
					countryColor = tag and CountryColor.resolve(tag) or nil,
					px = 24,
					size = "sm",
					layoutOrder = i,
					parent = coresRow,
				})
				local stroke = flagBadge:FindFirstChildOfClass("UIStroke")
				if stroke then
					if defaultSet[tag] then
						stroke.Color = Color3.fromRGB(212, 175, 55) -- gold: default / homeland core
						stroke.Thickness = 2
						stroke.Transparency = 0
					else
						stroke.Enabled = false -- acquired core: no outline
					end
				end
			end
		end

		ScreenKit.section(body, "Land", 2)
		local terrainDef = prov.terrain and Terrains[prov.terrain]
		ScreenKit.stat(body, {
			icon = "MapTerrain",
			label = "Terrain",
			value = val(prov.terrain),
			delta = defDelta(terrainDef and terrainDef.defenderBonus),
			deltaColor = "positive",
			layoutOrder = 3,
		})
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
		local fortTier = prov.effectiveFortTier or prov.fortTier or 0
		local fortValue = tostring(math.floor(fortTier))
		if
			WorldConstants.EnableDefenseBreakdown
			and prov.effectiveFortTier
			and prov.fortTier
			and prov.effectiveFortTier > prov.fortTier
		then
			fortValue = fortValue .. "  \u{2605}capital"
		end
		ScreenKit.stat(body, {
			icon = "Fort",
			label = "Fort",
			value = fortValue,
			delta = defDelta(fortTier * (WorldConstants.FortBattleDefensePerTier or 0.2)),
			deltaColor = "positive",
			layoutOrder = 7,
		})

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
		-- This province's manpower CONTRIBUTION to its owner's national pool -- NOT the whole national pool
		-- (which is identical on every province). Mirrors RecruitSystem.provinceManpowerContribution:
		-- floor(population * ManpowerPopFraction). (The 5K floor is now per-NATION, applied to the pooled cap.)
		local mpLive = liveProvince()
		local mpPop = (mpLive and mpLive.population) or 0
		local mpContribution = math.floor(mpPop * (WorldConstants.ManpowerPopFraction or 0.02))
		local function fmtMP(n)
			n = math.floor(tonumber(n) or 0)
			return (n >= 1000) and string.format("%.1fK", n / 1000) or tostring(n)
		end
		ScreenKit.stat(body, {
			icon = "Manpower",
			label = "Manpower",
			value = fmtMP(mpContribution),
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
					g = {
						unitTypeId = item.unitTypeId,
						count = 0,
						active = item,
						lastId = item.id,
						lastQueuedAt = -math.huge,
					}
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
				liveBars[#liveBars + 1] = {
					fill = fill,
					live = function()
						return progressOf(active.queuedAt, active.completesAt)
					end,
				}
			end
			order += 1
		end
		if #groupOrder == 0 then
			ScreenKit.note(body, "No regiments recruiting here.", 2)
		end

		ScreenKit.section(body, "Available Units", 20)
		-- Professional (non-levy) units need a Military district here; without one they're greyed + unclickable,
		-- mirroring the server's GateRecruitOnMilitary check so the UI never offers a recruit the server rejects.
		local hasMilitary = RecruitGate.provinceHasMilitaryDistrict(liveProvince() or prov)
		local pool = {}
		for id, def in pairs(unitTypes()) do
			if type(def) == "table" and def.recruitCost ~= nil and def.unlockedByDefault ~= false then
				pool[#pool + 1] = { id = id, def = def }
			end
		end
		RecruitGate.sortPool(pool) -- levy (militia/irregular) on top, then professional; each alphabetical
		local uo = 21
		for _, entry in ipairs(pool) do
			local def = entry.def
			local locked = RecruitGate.unitNeedsMilitaryDistrict(def) and not hasMilitary
			actionRow(body, {
				order = uo,
				icon = "Army",
				label = def.displayName or titleCase(entry.id),
				value = locked and "Needs Military" or ((def.recruitCost or 0) .. " gold"),
				disabled = locked,
				tooltip = function()
					-- Reason goes in `body` (a WRAPPING full-width line), not a row value (which doesn't wrap
					-- and overflowed the tooltip edge).
					return Tooltip.create({
						title = def.displayName or entry.id,
						body = locked and "Build a Military district here to recruit this unit." or nil,
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

		local districtsOn = WorldConstants.DistrictsPlayable
		if districtsOn then
			renderDistrictGrid(body, p, 5)
		end

		-- Buildings absorbed into districts (base + manufactories, flagged in Data/BuildingTypes) drop out of
		-- the legacy catalog + built list when the district system is on; only special buildings
		-- (fortress/shipyard/university) remain here.
		local function absorbed(_bid, def)
			return districtsOn and def ~= nil and def.absorbedByDistrict == true
		end

		ScreenKit.section(body, districtsOn and "Special Buildings" or "Buildings", 10)
		local built = (p and p.buildings) or {}
		local shownBuilt, bo = 0, 11
		for _, bid in ipairs(built) do
			local def = buildingTypes()[bid]
			if not absorbed(bid, def) then
				shownBuilt += 1
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
		if shownBuilt == 0 then
			ScreenKit.note(
				body,
				districtsOn and "No special buildings constructed." or "No buildings constructed yet.",
				11
			)
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
				-- Occupation freeze: a paused ticket's completesAt is stale, so the live
				-- progressOf extrapolation would climb past 100%. Render a STATIC fill from
				-- the banked remaining time instead, and skip the live updater.
				local paused = bItem.paused == true
				local staticProgress = 0
				if paused then
					local total = (bItem.completesAt or 0) - (bItem.startedAt or 0)
					local remaining = bItem.remaining or total
					staticProgress = total > 0 and math.clamp((total - remaining) / total, 0, 1) or 0
				end
				local _, fill = actionRow(body, {
					order = qo,
					icon = "Building",
					label = ((def and def.displayName) or titleCase(item.buildingId))
						.. (paused and " — Paused (occupied)" or ""),
					progress = {
						value = (paused and staticProgress or progressOf(bItem.startedAt, bItem.completesAt)) * 100,
						max = 100,
					},
					button = {
						text = "\u{00D7}",
						variant = "danger",
						onClick = function()
							ctx.fire("CancelBuilding", bItem.id)
						end,
					},
				})
				if fill and not paused then
					liveBars[#liveBars + 1] = {
						fill = fill,
						live = function()
							return progressOf(bItem.startedAt, bItem.completesAt)
						end,
					}
				end
				qo += 1
			end
		end
		if shown == 0 then
			ScreenKit.note(body, "Nothing under construction.", 21)
		end

		local groups = {}
		for id, def in pairs(buildingTypes()) do
			if
				type(def) == "table"
				and not TIER_BUILDINGS[id]
				and not absorbed(id, def)
				and canBuildHere(p, id, def)
			then
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
			-- Districts (economy rework): slot -> type@level, so placing/upgrading rebuilds the grid.
			local dparts = {}
			if p and p.districts then
				for slot, d in pairs(p.districts) do
					if type(d) == "table" and d.type then
						dparts[#dparts + 1] = string.format("%s=%s@%d", tostring(slot), tostring(d.type), d.level or 0)
					end
				end
			end
			table.sort(dparts)
			parts[#parts + 1] = "d:" .. table.concat(dparts, ",")
			-- District build/upgrade queue PRESENCE (no progress -- liveBars advances the fill in place, so a
			-- rebuild happens only when a ticket is added/removed/completed, not every frame).
			local c0 = country()
			local dq = {}
			for _, t in ((c0 and c0.districtQueue) or {}) do
				if t.provinceId == prov.id then
					dq[#dq + 1] = string.format("%s:%s", tostring(t.id), tostring(t.slotIndex))
				end
			end
			table.sort(dq)
			parts[#parts + 1] = "dq:" .. table.concat(dq, ",")
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
						"%s:%s%s",
						tostring(item.id),
						tostring(item.buildingId),
						item.paused and ":p" or ""
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
		elseif tabKey == "information" then
			-- The Cores row is the only runtime-mutable structure here (cores/defaultCores change on
			-- war/peace). Fold their SORTED ids in (both arrays are unordered) so the tab rebuilds when
			-- they change; other Information stats live-update via prov, no rebuild needed.
			local live = liveProvince()
			local cores = {}
			for _, t in ipairs((live and live.cores) or {}) do
				cores[#cores + 1] = t
			end
			table.sort(cores)
			parts[#parts + 1] = "co:" .. table.concat(cores, ",")
			local dcores = {}
			for _, t in ipairs((live and live.defaultCores) or {}) do
				dcores[#dcores + 1] = t
			end
			table.sort(dcores)
			parts[#parts + 1] = "dc:" .. table.concat(dcores, ",")
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
		anchorPoint = Vector2.new(1, 1),
		position = UDim2.new(1, -16, 1, -16),
		-- Fixed height (not autoHeight) so the panel stays one size across Information/Recruitment/Buildings;
		-- the ScreenKit body scrolls when a tab's content is taller. Matched to the unit panel's typical
		-- auto-height (ArmyPanel content ~= 620px) so the two panels read as the same size. Tunable.
		size = UDim2.fromOffset(360, 620),
		tabs = owns and TABS or nil,
		activeTab = owns and "information" or nil,
		onTab = owns and function(key)
			render(key)
			lastSig = contentSignature(key)
		end or nil,
	})

	-- Owner crest tucked into the shell header, left of the title (mirrors the army panel; the Information
	-- body no longer carries one). Clicking it deep-links to the country's diplomacy profile.
	if prov.ownerTag and handle.header then
		local crest = CountryBadge.create({
			code = prov.ownerTag or "\u{2014}",
			countryColor = prov.ownerColor,
			size = "sm",
			parent = handle.header,
		})
		crest.AnchorPoint = Vector2.new(0, 0)
		crest.Position = UDim2.fromOffset(0, 0)
		crest.ZIndex = 3
		local title = handle.header:FindFirstChild("Title")
		local sub = handle.header:FindFirstChild("Subtitle")
		if title then
			title.Position = UDim2.fromOffset(52, 0)
			title.Size = UDim2.new(1, -36 - 52, 0, 28)
		end
		if sub then
			sub.Position = UDim2.fromOffset(52, 28)
			sub.Size = UDim2.new(1, -36 - 52, 0, 16)
		end
		if ctx.openCountryProfile then
			crest.Active = true
			crest.InputBegan:Connect(function(input)
				if
					input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch
				then
					ctx.openCountryProfile(prov.ownerTag)
				end
			end)
		end
	end

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
