local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local uiFolder = aow:WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))
local UISound = require(uiFolder:WaitForChild("UISound"))
local ClientStateCache = require(aow:WaitForChild("Modules"):WaitForChild("ClientStateCache"))
local CombatPhases = require(aow:WaitForChild("Data"):WaitForChild("CombatPhases"))
local OfficerTraits = require(aow:WaitForChild("Data"):WaitForChild("OfficerTraits"))

local ArmyPanel = {}

local PANEL_W = 360
local PANEL_H = 600
local BOTTOM_INSET = (UIStyle.Size and UIStyle.Size.BottomBarH) or 44
local MINIMAP_W = (UIStyle.Size and UIStyle.Size.MinimapW) or 300
local MINIMAP_RIGHT_GAP = 12
local PANEL_TO_MINIMAP_GAP = 8
local PAD_X = 12
local PAD_Y = 12
local MORALE_MAX = 100
local REGIMENT_STRENGTH = 1000  -- WorldConstants.ArmyRegimentStrength (men per regiment)

-- Country colors in the data are {R,G,B} arrays (0-255), not Color3 values. Convert safely.
local function toColor3(c, fallback)
	if typeof(c) == "Color3" then return c end
	if type(c) == "table" and c[1] and c[2] and c[3] then
		return Color3.fromRGB(c[1], c[2], c[3])
	end
	return fallback or UIStyle.Color.Gold or Color3.fromRGB(218, 168, 84)
end

local function commafy(n)
	n = math.floor(tonumber(n) or 0)
	local out = tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

-- Country reserve pool for the Manpower line, levy/professional-aware (falls back to the
-- legacy single `manpower` pool). Kept short to fit the value column.
local function manpowerText(country)
	if not country then return "—" end
	if country.levyManpower ~= nil then
		return string.format("Levy %s", commafy(country.levyManpower or 0))
	end
	return commafy(country.manpower or 0)
end

local MODIFIER_LABELS = {
	attack = "atk",
	defense = "def",
	morale_recovery = "morale rec",
	morale_resistance = "morale res",
	org_recovery = "org rec",
	upkeep = "upkeep",
	attrition_resist = "attrition res",
	siege_speed = "siege",
	entrench_speed = "entrench",
	fire_bonus = "fire",
	shock_bonus = "shock",
	maneuver_bonus = "maneuver",
	broadside_bonus = "broadside",
	boarding_bonus = "boarding",
	naval_speed = "naval spd",
	naval_attack = "naval atk",
}

local MODIFIER_ORDER = {
	"attack", "defense",
	"morale_recovery", "morale_resistance", "org_recovery",
	"upkeep", "attrition_resist",
	"siege_speed", "entrench_speed",
	"fire_bonus", "shock_bonus", "maneuver_bonus",
	"broadside_bonus", "boarding_bonus",
	"naval_speed", "naval_attack",
}

local function titleCase(text)
	if not text then return "" end
	local s = (text or ""):gsub("_", " ")
	s = s:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b:lower() end)
	return s
end

local function dominantInfo(army, bundle)
	local domId, domWeight, total = nil, -1, 0
	local entries = {}
	for unitId, count in pairs(army.composition or {}) do
		if count > 0 then
			local unit = bundle and bundle.unitTypes and bundle.unitTypes[unitId]
			local weight = count * (unit and unit.attack or 0)
			table.insert(entries, { id = unitId, count = count, unit = unit, weight = weight })
			total = total + count
			if weight > domWeight then domWeight = weight; domId = unitId end
		end
	end
	table.sort(entries, function(a, b) return a.weight > b.weight end)
	local domUnit = bundle and bundle.unitTypes and bundle.unitTypes[domId]
	return {
		entries = entries,
		total = total,
		domId = domId,
		domName = (domUnit and domUnit.displayName) or titleCase(domId or "Force"),
	}
end

local function tierColor(pct)
	if pct > 0.6 then return UIStyle.Color.Good or Color3.fromRGB(140, 200, 140) end
	if pct > 0.3 then return UIStyle.Color.Warn or UIStyle.Color.Gold or Color3.fromRGB(220, 176, 80) end
	return UIStyle.Color.Bad or Color3.fromRGB(220, 80, 80)
end

local function battlePhaseLabel(battle)
	if not battle or not battle.phaseCycle then return nil end
	local spec, idx = CombatPhases.getPhase(battle.phaseCycle, battle.phaseIndex or 1)
	if not spec then return nil end
	local duration = spec.duration or 1
	local elapsed = battle.phaseElapsed or 0
	local tick = math.min(elapsed + 1, duration)
	local nextIdx = CombatPhases.next(battle.phaseCycle, idx or 1)
	local nextSpec = CombatPhases.getPhase(battle.phaseCycle, nextIdx)
	local nextName = (nextSpec and (nextSpec.displayName or nextSpec.id)) or "—"
	local dmgPct = math.floor((spec.damageMultiplier or 1) * 100 + 0.5)
	local morPct = math.floor((spec.moraleMultiplier or 1) * 100 + 0.5)
	return string.format("%s %d/%d → %s  ·  %d%% dmg  ·  %d%% mor",
		spec.displayName or spec.id, tick, duration, nextName, dmgPct, morPct)
end

local function listContains(list, id)
	for _, v in ipairs(list or {}) do
		if v == id then return true end
	end
	return false
end

local function combatWidthLabel(battle, army)
	if not battle or not army then return nil end
	local width = battle.width
	if type(width) ~= "number" or width <= 0 then return nil end
	local mySide
	if listContains(battle.attackerArmyIds, army.id) then
		mySide = battle.attackerArmyIds
	elseif listContains(battle.defenderArmyIds, army.id) then
		mySide = battle.defenderArmyIds
	end
	if not mySide then return nil end
	local total = 0
	for _, aid in ipairs(mySide) do
		local a = ClientStateCache.getArmy and ClientStateCache.getArmy(aid)
		if a and type(a.composition) == "table" then
			for _, count in pairs(a.composition) do
				total = total + (tonumber(count) or 0)
			end
		end
	end
	local front = math.min(total, width)
	local reserve = math.max(0, total - width)
	return string.format("Frontline %d / %d  ·  Reserve %d", front, width, reserve)
end

local function officerRollupText(traits)
	if type(traits) ~= "table" or #traits == 0 then return "" end
	local parts = {}
	for _, field in ipairs(MODIFIER_ORDER) do
		local sum = OfficerTraits.modifierSum(traits, field)
		if sum and math.abs(sum) > 0.0001 then
			local pct = math.floor(sum * 100 + (sum >= 0 and 0.5 or -0.5))
			if pct ~= 0 then
				local sign = pct > 0 and "+" or ""
				table.insert(parts, string.format("%s%d%% %s", sign, pct, MODIFIER_LABELS[field] or field))
			end
		end
	end
	return table.concat(parts, "  ·  ")
end

local function statusText(army, provinceName)
	if army.battleId then return "In battle" end
	if army.retreating then return "Retreating" end
	if army.movement then
		return string.format("Marching → %s", tostring(army.movement.toProvinceId))
	end
	return string.format("Stationed in %s", tostring(provinceName or army.provinceId or "?"))
end

-- Hero vital row: label + bold value on a top line, a thick (8px) color-graded bar below.
-- Returns { row, value, barFill, setPct(pct,color) } for in-place updates.
local function makeVitalRow(parent, labelText, order)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 30)
	row.BackgroundTransparency = 1
	row.LayoutOrder = order
	row.Parent = parent

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(0.6, 0, 0, 15)
	lbl.BackgroundTransparency = 1
	lbl.Text = labelText
	lbl.TextColor3 = UIStyle.Color.TextMuted
	lbl.Font = UIStyle.Font.Regular or Enum.Font.Gotham
	lbl.TextSize = 12
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextYAlignment = Enum.TextYAlignment.Center
	lbl.Parent = row

	local val = Instance.new("TextLabel")
	val.Size = UDim2.new(0.4, 0, 0, 15)
	val.Position = UDim2.new(1, 0, 0, 0)
	val.AnchorPoint = Vector2.new(1, 0)
	val.BackgroundTransparency = 1
	val.Text = "—"
	val.TextColor3 = UIStyle.Color.Text
	if UIStyle.FontFace and UIStyle.FontFace.Cinzel then val.FontFace = UIStyle.FontFace.Cinzel else val.Font = UIStyle.Font.Bold or Enum.Font.GothamBold end
	val.TextSize = 15
	val.TextXAlignment = Enum.TextXAlignment.Right
	val.TextYAlignment = Enum.TextYAlignment.Center
	val.Parent = row

	local track = Instance.new("Frame")
	track.AnchorPoint = Vector2.new(0, 1)
	track.Position = UDim2.new(0, 0, 1, -2)
	track.Size = UDim2.new(1, 0, 0, 8)
	track.BackgroundColor3 = UIStyle.Color.Bg
	track.BorderSizePixel = 0
	track.Parent = row
	UIBuilder.corner(track, 4)

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = UIStyle.Color.Good or Color3.fromRGB(120, 170, 90)
	fill.BorderSizePixel = 0
	fill.Parent = track
	UIBuilder.corner(fill, 4)

	return {
		row = row, value = val, barFill = fill,
		setPct = function(pct, color)
			fill.Size = UDim2.fromScale(math.clamp(pct or 0, 0, 1), 1)
			if color then fill.BackgroundColor3 = color end
		end,
	}
end

-- High-contrast action button (explicit fills + text, no multiply-gradient). Every
-- variant keeps a large value gap between label and fill (>=12:1 enabled, >=8:1 disabled)
-- so the text is always readable -- the #1 complaint about the old buttons. Returns
-- (button, setEnabled): disabled dims the FILL and uses a muted-but-legible label, never
-- a transparent one.
local ACTION_VARIANTS = {
	default = {
		fill = UIStyle.Color.Panel, text = UIStyle.Color.Text, stroke = UIStyle.Color.Gold,
		hoverFill = UIStyle.Color.PanelAlt, hoverText = UIStyle.Color.GoldBright,
	},
	destructive = {
		fill = UIStyle.Color.BadgeRedBg or Color3.fromRGB(70, 20, 18), text = UIStyle.Color.Text,
		stroke = Color3.fromRGB(150, 70, 60), hoverFill = Color3.fromRGB(96, 30, 26), hoverText = UIStyle.Color.GoldBright,
	},
}
local function makeActionButton(parent, opts)
	local v = ACTION_VARIANTS[opts.variant or "default"] or ACTION_VARIANTS.default
	local btn = Instance.new("TextButton")
	btn.Name = opts.name or opts.text or "ActionButton"
	btn.Size = opts.size or UDim2.fromOffset(72, 32)
	if opts.position then btn.Position = opts.position end
	if opts.anchorPoint then btn.AnchorPoint = opts.anchorPoint end
	btn.LayoutOrder = opts.layoutOrder or 0
	btn.AutoButtonColor = false
	btn.BackgroundColor3 = v.fill
	btn.BorderSizePixel = 0
	btn.Text = opts.text or ""
	btn.TextColor3 = v.text
	if UIStyle.FontFace and UIStyle.FontFace.Cinzel then btn.FontFace = UIStyle.FontFace.Cinzel else btn.Font = UIStyle.Font.Bold or Enum.Font.GothamBold end
	btn.TextSize = 14
	btn.ZIndex = (parent.ZIndex or 1) + 1
	btn.Parent = parent
	btn.TextStrokeTransparency = 1   -- no text outline
	UIBuilder.corner(btn, (UIStyle.Size and UIStyle.Size.CornerButton) or 4)
	local stroke = Instance.new("UIStroke")
	stroke.Color = v.stroke
	stroke.Thickness = 1
	stroke.Transparency = 0.2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border  -- outline the BUTTON rectangle, not the text glyphs
	stroke.Parent = btn

	local enabled = true
	btn.MouseEnter:Connect(function()
		if not enabled then return end
		btn.BackgroundColor3 = v.hoverFill
		btn.TextColor3 = v.hoverText
	end)
	btn.MouseLeave:Connect(function()
		if not enabled then return end
		btn.BackgroundColor3 = v.fill
		btn.TextColor3 = v.text
	end)

	local function setEnabled(flag)
		enabled = flag and true or false
		btn.Active = enabled
		if enabled then
			btn.BackgroundColor3 = v.fill
			btn.TextColor3 = v.text
			stroke.Transparency = 0.2
		else
			btn.BackgroundColor3 = UIStyle.Color.Bg
			btn.TextColor3 = UIStyle.Color.TextMuted   -- ~8:1 on Bg: dim but legible
			stroke.Transparency = 0.7
		end
	end
	return btn, setEnabled
end

function ArmyPanel.create(parent, callbacks)
	callbacks = callbacks or {}

	-- Position: anchored to bottom-right, offset to the LEFT of the minimap so both
	-- it and ProvinceDetailPanel (which still owns the right edge) can coexist.
	local panel = UIBuilder.framedPanel(parent, {
		Name = "ArmyPanel",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -(MINIMAP_W + MINIMAP_RIGHT_GAP + PANEL_TO_MINIMAP_GAP), 1, -(BOTTOM_INSET + 12)),
		Size = UDim2.fromOffset(PANEL_W, 0),   -- height auto-fits content (see AutomaticSize below)
		Visible = false,
	})
	panel.ZIndex = (UIStyle.Z and UIStyle.Z.Content) or 20
	panel:SetAttribute("AoWInputSink", true)

	-- framedPanel adds decorative TopTrim/BottomTrim hairlines (LayoutOrder 0) meant to sit at
	-- the panel's top/bottom edges. But this panel stacks its content with the UIListLayout below,
	-- which hijacks those LayoutOrder-0 frames and lays them out as two stray 1px lines at the very
	-- top, above the title. The gold border stroke already frames the panel -- drop the trim.
	for _, trimName in ipairs({ "TopTrim", "BottomTrim" }) do
		local trim = panel:FindFirstChild(trimName)
		if trim then trim:Destroy() end
	end

	-- Auto-fit the panel height to its content (the UIListLayout stack below). Anchored bottom-
	-- right, so it grows upward and the action buttons stay tucked under the content -- no fixed
	-- 600px frame with a dead gap for small armies.
	panel.AutomaticSize = Enum.AutomaticSize.Y

	-- Inner padding
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, PAD_X)
	pad.PaddingRight = UDim.new(0, PAD_X)
	pad.PaddingTop = UDim.new(0, PAD_Y)
	pad.PaddingBottom = UDim.new(0, PAD_Y)
	pad.Parent = panel

	-- Vertical stack
	local stack = Instance.new("UIListLayout")
	stack.FillDirection = Enum.FillDirection.Vertical
	stack.SortOrder = Enum.SortOrder.LayoutOrder
	stack.Padding = UDim.new(0, 10)
	stack.Parent = panel

	------------------------------------------------------------------
	-- HEADER (tab strip slot + identity + status hint)
	------------------------------------------------------------------
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 88)
	header.BackgroundTransparency = 1
	header.LayoutOrder = 1
	header.Parent = panel

	-- TabStrip slot (only filled when 2+ armies)
	local tabSlot = Instance.new("Frame")
	tabSlot.Name = "TabSlot"
	tabSlot.Size = UDim2.new(1, 0, 0, 0)
	tabSlot.Position = UDim2.fromOffset(0, 0)
	tabSlot.BackgroundTransparency = 1
	tabSlot.Visible = false
	tabSlot.Parent = header

	-- Identity row: name + state (crest removed -- the always-on CountryHeader already shows
	-- the nation, and this panel only opens for the player's own armies, so it was redundant).
	-- A thin country-color accent strip is the only identity cue.
	local identY = 0
	local accentStrip = Instance.new("Frame")
	accentStrip.Name = "Accent"
	accentStrip.Size = UDim2.new(0, 2, 0, 44)
	accentStrip.Position = UDim2.fromOffset(0, identY)
	accentStrip.BackgroundColor3 = UIStyle.Color.Gold or Color3.fromRGB(218, 168, 84)
	accentStrip.BorderSizePixel = 0
	accentStrip.ZIndex = panel.ZIndex + 1
	accentStrip.Parent = header

	local nameLbl = Instance.new("TextLabel")
	nameLbl.Name = "ArmyName"
	nameLbl.Size = UDim2.new(1, -10, 0, 24)
	nameLbl.Position = UDim2.fromOffset(10, identY)
	nameLbl.BackgroundTransparency = 1
	nameLbl.Text = "Selected Force"
	nameLbl.TextColor3 = UIStyle.Color.Cream or UIStyle.Color.Gold or Color3.fromRGB(206, 180, 120)
	if UIStyle.FontFace and UIStyle.FontFace.Cinzel then
		nameLbl.FontFace = UIStyle.FontFace.Cinzel
	else
		nameLbl.Font = UIStyle.Font.Display or Enum.Font.Garamond
	end
	nameLbl.TextSize = 18
	nameLbl.TextXAlignment = Enum.TextXAlignment.Left
	nameLbl.TextYAlignment = Enum.TextYAlignment.Bottom
	nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
	nameLbl.ZIndex = panel.ZIndex + 1
	nameLbl.Parent = header

	local stateLbl = Instance.new("TextLabel")
	stateLbl.Name = "State"
	stateLbl.Size = UDim2.new(1, -10, 0, 14)
	stateLbl.Position = UDim2.fromOffset(10, identY + 26)
	stateLbl.BackgroundTransparency = 1
	stateLbl.Text = ""
	stateLbl.TextColor3 = UIStyle.Color.TextMuted or Color3.fromRGB(154, 120, 72)
	stateLbl.Font = UIStyle.Font.Regular or Enum.Font.Gotham
	stateLbl.TextSize = 11
	stateLbl.TextXAlignment = Enum.TextXAlignment.Left
	stateLbl.ZIndex = panel.ZIndex + 1
	stateLbl.Parent = header

	-- right-click hint
	local hintLbl = Instance.new("TextLabel")
	hintLbl.Size = UDim2.new(1, 0, 0, 12)
	hintLbl.Position = UDim2.fromOffset(10, 48)
	hintLbl.BackgroundTransparency = 1
	hintLbl.Text = "right-click a tile to move"
	hintLbl.TextColor3 = UIStyle.Color.TextMuted or Color3.fromRGB(154, 120, 72)
	hintLbl.Font = UIStyle.Font.Regular or Enum.Font.Gotham
	hintLbl.TextSize = 10
	hintLbl.TextXAlignment = Enum.TextXAlignment.Left
	hintLbl.TextTransparency = 0.3
	hintLbl.ZIndex = panel.ZIndex + 1
	hintLbl.Parent = header

	------------------------------------------------------------------
	-- VITALS section
	------------------------------------------------------------------
	local vitals = Instance.new("Frame")
	vitals.Name = "Vitals"
	vitals.Size = UDim2.new(1, 0, 0, 18 + 134)
	vitals.BackgroundTransparency = 1
	vitals.LayoutOrder = 2
	vitals.Parent = panel

	UIBuilder.eyebrow(vitals, "Vitals", {
		Size = UDim2.new(1, 0, 0, 14),
		Position = UDim2.fromOffset(0, 0),
	})

	local vitalsList = Instance.new("Frame")
	vitalsList.Size = UDim2.new(1, 0, 0, 134)
	vitalsList.Position = UDim2.fromOffset(0, 18)
	vitalsList.BackgroundTransparency = 1
	vitalsList.Parent = vitals

	local vlist = Instance.new("UIListLayout")
	vlist.FillDirection = Enum.FillDirection.Vertical
	vlist.SortOrder = Enum.SortOrder.LayoutOrder
	vlist.Padding = UDim.new(0, 0)
	vlist.Parent = vitalsList

	-- Hero vitals: thick, color-graded bars for the at-a-glance status, then plain info lines.
	local moraleStat = makeVitalRow(vitalsList, "Morale", 1)
	local orgStat = makeVitalRow(vitalsList, "Organization", 2)
	local entStat = makeVitalRow(vitalsList, "Entrenchment", 3)
	-- Entrenchment is a defensive buildup, not a health stat -- gold bar so it doesn't read as a
	-- "low/bad" green bar. (refreshActive only updates its fill width, not color, so this sticks.)
	entStat.barFill.BackgroundColor3 = UIStyle.Color.Gold or Color3.fromRGB(218, 168, 84)
	local strengthStat = UIBuilder.statRowBar(vitalsList, {
		label = "Strength", value = "—",
		height = 22,
		props = { LayoutOrder = 4 },
	})
	local mpStat = UIBuilder.statRowBar(vitalsList, {
		label = "Manpower", value = "—",
		height = 22, divider = false,
		props = { LayoutOrder = 5 },
	})

	local battleStrip = Instance.new("Frame")
	battleStrip.Name = "BattleStrip"
	battleStrip.Size = UDim2.new(1, 0, 0, 40)
	battleStrip.BackgroundTransparency = 1
	battleStrip.LayoutOrder = 3
	battleStrip.Visible = false
	battleStrip.Parent = panel

	local battleStripBg = Instance.new("Frame")
	battleStripBg.Size = UDim2.fromScale(1, 1)
	battleStripBg.BackgroundColor3 = UIStyle.Color.PanelInk or Color3.fromRGB(28, 22, 14)
	battleStripBg.BackgroundTransparency = 0.55
	battleStripBg.BorderSizePixel = 0
	battleStripBg.ZIndex = panel.ZIndex
	battleStripBg.Parent = battleStrip
	local battleStripStroke = Instance.new("UIStroke")
	battleStripStroke.Color = UIStyle.Color.Gold or Color3.fromRGB(200, 160, 80)
	battleStripStroke.Transparency = 0.6
	battleStripStroke.Thickness = 1
	battleStripStroke.Parent = battleStripBg
	local battleStripCorner = Instance.new("UICorner")
	battleStripCorner.CornerRadius = UDim.new(0, 3)
	battleStripCorner.Parent = battleStripBg
	local battleStripPad = Instance.new("UIPadding")
	battleStripPad.PaddingLeft = UDim.new(0, 8)
	battleStripPad.PaddingRight = UDim.new(0, 8)
	battleStripPad.PaddingTop = UDim.new(0, 3)
	battleStripPad.PaddingBottom = UDim.new(0, 3)
	battleStripPad.Parent = battleStrip

	local phaseLbl = Instance.new("TextLabel")
	phaseLbl.Name = "Phase"
	phaseLbl.Size = UDim2.new(1, 0, 0, 16)
	phaseLbl.Position = UDim2.fromOffset(0, 0)
	phaseLbl.BackgroundTransparency = 1
	phaseLbl.Text = ""
	phaseLbl.TextColor3 = UIStyle.Color.Gold or Color3.fromRGB(220, 180, 110)
	phaseLbl.Font = UIStyle.Font.Regular or Enum.Font.Gotham
	phaseLbl.TextSize = 12
	phaseLbl.TextXAlignment = Enum.TextXAlignment.Left
	phaseLbl.TextTruncate = Enum.TextTruncate.AtEnd
	phaseLbl.ZIndex = panel.ZIndex + 1
	phaseLbl.Parent = battleStrip

	local widthLbl = Instance.new("TextLabel")
	widthLbl.Name = "Width"
	widthLbl.Size = UDim2.new(1, -64, 0, 14)
	widthLbl.Position = UDim2.fromOffset(0, 18)
	widthLbl.BackgroundTransparency = 1
	widthLbl.Text = ""
	widthLbl.TextColor3 = UIStyle.Color.TextMuted or Color3.fromRGB(180, 160, 120)
	widthLbl.Font = UIStyle.Font.Regular or Enum.Font.Gotham
	widthLbl.TextSize = 11
	widthLbl.TextXAlignment = Enum.TextXAlignment.Left
	widthLbl.TextTruncate = Enum.TextTruncate.AtEnd
	widthLbl.ZIndex = panel.ZIndex + 1
	widthLbl.Parent = battleStrip

	local logBtn = Instance.new("TextButton")
	logBtn.Name = "LogBtn"
	logBtn.Size = UDim2.fromOffset(56, 18)
	logBtn.Position = UDim2.new(1, -56, 0, 16)
	logBtn.BackgroundColor3 = UIStyle.Color.WoodFrame or Color3.fromRGB(46, 36, 22)
	logBtn.BackgroundTransparency = 0.2
	logBtn.BorderSizePixel = 0
	logBtn.AutoButtonColor = false
	logBtn.Text = "Log"
	logBtn.TextColor3 = UIStyle.Color.Gold or Color3.fromRGB(220, 180, 110)
	logBtn.Font = UIStyle.Font.Regular or Enum.Font.Gotham
	logBtn.TextSize = 11
	logBtn.ZIndex = panel.ZIndex + 2
	logBtn.Parent = battleStrip
	local logBtnCorner = Instance.new("UICorner")
	logBtnCorner.CornerRadius = UDim.new(0, 2)
	logBtnCorner.Parent = logBtn
	local logBtnStroke = Instance.new("UIStroke")
	logBtnStroke.Color = UIStyle.Color.Border or Color3.fromRGB(142, 84, 24)
	logBtnStroke.Transparency = 0.4
	logBtnStroke.Thickness = 1
	logBtnStroke.Parent = logBtn

	local logPopup = Instance.new("Frame")
	logPopup.Name = "BattleLog"
	logPopup.Size = UDim2.fromOffset(320, 280)
	logPopup.AnchorPoint = Vector2.new(1, 0)
	logPopup.Position = UDim2.new(0, -8, 0, 0)
	logPopup.BackgroundColor3 = UIStyle.Color.PanelInk or Color3.fromRGB(20, 16, 10)
	logPopup.BackgroundTransparency = 0.05
	logPopup.BorderSizePixel = 0
	logPopup.Visible = false
	logPopup.ZIndex = panel.ZIndex + 25
	logPopup.Parent = panel
	local logPopupCorner = Instance.new("UICorner")
	logPopupCorner.CornerRadius = UDim.new(0, 4)
	logPopupCorner.Parent = logPopup
	local logPopupStroke = Instance.new("UIStroke")
	logPopupStroke.Color = UIStyle.Color.Gold or Color3.fromRGB(200, 160, 80)
	logPopupStroke.Transparency = 0.45
	logPopupStroke.Thickness = 1
	logPopupStroke.Parent = logPopup
	local logPopupPad = Instance.new("UIPadding")
	logPopupPad.PaddingTop = UDim.new(0, 10)
	logPopupPad.PaddingBottom = UDim.new(0, 10)
	logPopupPad.PaddingLeft = UDim.new(0, 10)
	logPopupPad.PaddingRight = UDim.new(0, 10)
	logPopupPad.Parent = logPopup

	local logPopupTitle = Instance.new("TextLabel")
	logPopupTitle.Size = UDim2.new(1, -24, 0, 18)
	logPopupTitle.Position = UDim2.fromOffset(0, 0)
	logPopupTitle.BackgroundTransparency = 1
	logPopupTitle.Text = "Battle Log"
	logPopupTitle.TextColor3 = UIStyle.Color.Cream or UIStyle.Color.Gold or Color3.fromRGB(220, 200, 160)
	if UIStyle.FontFace and UIStyle.FontFace.Cinzel then
		logPopupTitle.FontFace = UIStyle.FontFace.Cinzel
	else
		logPopupTitle.Font = UIStyle.Font.Display or Enum.Font.Garamond
	end
	logPopupTitle.TextSize = 14
	logPopupTitle.TextXAlignment = Enum.TextXAlignment.Left
	logPopupTitle.ZIndex = logPopup.ZIndex + 1
	logPopupTitle.Parent = logPopup

	local logPopupClose = Instance.new("TextButton")
	logPopupClose.Size = UDim2.fromOffset(20, 18)
	logPopupClose.Position = UDim2.new(1, 0, 0, 0)
	logPopupClose.AnchorPoint = Vector2.new(1, 0)
	logPopupClose.BackgroundTransparency = 1
	logPopupClose.Text = "x"
	logPopupClose.TextColor3 = UIStyle.Color.TextMuted or Color3.fromRGB(180, 160, 120)
	logPopupClose.Font = UIStyle.Font.Regular or Enum.Font.Gotham
	logPopupClose.TextSize = 14
	logPopupClose.ZIndex = logPopup.ZIndex + 1
	logPopupClose.Parent = logPopup

	local logScroll = Instance.new("ScrollingFrame")
	logScroll.Size = UDim2.new(1, 0, 1, -24)
	logScroll.Position = UDim2.fromOffset(0, 22)
	logScroll.BackgroundTransparency = 1
	logScroll.BorderSizePixel = 0
	logScroll.ScrollBarThickness = 3
	logScroll.ScrollBarImageColor3 = UIStyle.Color.Border or Color3.fromRGB(142, 84, 24)
	logScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	logScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	logScroll.ZIndex = logPopup.ZIndex + 1
	logScroll.Parent = logPopup
	local logScrollLayout = Instance.new("UIListLayout")
	logScrollLayout.FillDirection = Enum.FillDirection.Vertical
	logScrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
	logScrollLayout.Padding = UDim.new(0, 2)
	logScrollLayout.Parent = logScroll

	local officerBlock = Instance.new("Frame")
	officerBlock.Name = "Officer"
	officerBlock.Size = UDim2.new(1, 0, 0, 96)
	officerBlock.BackgroundTransparency = 1
	officerBlock.LayoutOrder = 4
	officerBlock.Parent = panel

	UIBuilder.eyebrow(officerBlock, "Officer", {
		Size = UDim2.new(1, 0, 0, 14),
		Position = UDim2.fromOffset(0, 0),
	})

	local officerNameLbl = Instance.new("TextLabel")
	officerNameLbl.Name = "OfficerName"
	officerNameLbl.Size = UDim2.new(1, -56, 0, 20)
	officerNameLbl.Position = UDim2.fromOffset(0, 18)
	officerNameLbl.BackgroundTransparency = 1
	officerNameLbl.Text = "—"
	officerNameLbl.TextColor3 = UIStyle.Color.Cream or UIStyle.Color.Gold or Color3.fromRGB(206, 180, 120)
	if UIStyle.FontFace and UIStyle.FontFace.Cinzel then
		officerNameLbl.FontFace = UIStyle.FontFace.Cinzel
	else
		officerNameLbl.Font = UIStyle.Font.Display or Enum.Font.Garamond
	end
	officerNameLbl.TextSize = 14
	officerNameLbl.TextXAlignment = Enum.TextXAlignment.Left
	officerNameLbl.TextTruncate = Enum.TextTruncate.AtEnd
	officerNameLbl.ZIndex = panel.ZIndex + 1
	officerNameLbl.Parent = officerBlock

	local officerDomainLbl = Instance.new("TextLabel")
	officerDomainLbl.Name = "OfficerDomain"
	officerDomainLbl.Size = UDim2.fromOffset(54, 18)
	officerDomainLbl.Position = UDim2.new(1, -54, 0, 19)
	officerDomainLbl.BackgroundTransparency = 1
	officerDomainLbl.Text = ""
	officerDomainLbl.TextColor3 = UIStyle.Color.TextMuted or Color3.fromRGB(154, 120, 72)
	officerDomainLbl.Font = UIStyle.Font.Regular or Enum.Font.Gotham
	officerDomainLbl.TextSize = 10
	officerDomainLbl.TextXAlignment = Enum.TextXAlignment.Right
	officerDomainLbl.ZIndex = panel.ZIndex + 1
	officerDomainLbl.Parent = officerBlock

	local officerTraitsLbl = Instance.new("TextLabel")
	officerTraitsLbl.Name = "OfficerTraits"
	officerTraitsLbl.Size = UDim2.new(1, 0, 0, 22)
	officerTraitsLbl.Position = UDim2.fromOffset(0, 40)
	officerTraitsLbl.BackgroundTransparency = 1
	officerTraitsLbl.Text = ""
	officerTraitsLbl.TextColor3 = UIStyle.Color.TextMuted or Color3.fromRGB(154, 120, 72)
	officerTraitsLbl.Font = UIStyle.Font.Regular or Enum.Font.Gotham
	officerTraitsLbl.TextSize = 11
	officerTraitsLbl.TextWrapped = true
	officerTraitsLbl.TextXAlignment = Enum.TextXAlignment.Left
	officerTraitsLbl.TextYAlignment = Enum.TextYAlignment.Top
	officerTraitsLbl.ZIndex = panel.ZIndex + 1
	officerTraitsLbl.Parent = officerBlock

	local officerRollupLbl = Instance.new("TextLabel")
	officerRollupLbl.Name = "OfficerRollup"
	officerRollupLbl.Size = UDim2.new(1, 0, 0, 16)
	officerRollupLbl.Position = UDim2.fromOffset(0, 62)
	officerRollupLbl.BackgroundTransparency = 1
	officerRollupLbl.Text = ""
	officerRollupLbl.TextColor3 = UIStyle.Color.Gold or Color3.fromRGB(220, 180, 110)
	officerRollupLbl.Font = UIStyle.Font.Regular or Enum.Font.Gotham
	officerRollupLbl.TextSize = 10
	officerRollupLbl.TextTruncate = Enum.TextTruncate.AtEnd
	officerRollupLbl.TextXAlignment = Enum.TextXAlignment.Left
	officerRollupLbl.ZIndex = panel.ZIndex + 1
	officerRollupLbl.Parent = officerBlock

	local officerLvlLbl = Instance.new("TextLabel")
	officerLvlLbl.Name = "OfficerLevel"
	officerLvlLbl.Size = UDim2.new(1, 0, 0, 12)
	officerLvlLbl.Position = UDim2.fromOffset(0, 80)
	officerLvlLbl.BackgroundTransparency = 1
	officerLvlLbl.Text = ""
	officerLvlLbl.TextColor3 = UIStyle.Color.TextMuted or Color3.fromRGB(154, 120, 72)
	officerLvlLbl.Font = UIStyle.Font.Regular or Enum.Font.Gotham
	officerLvlLbl.TextSize = 10
	officerLvlLbl.TextXAlignment = Enum.TextXAlignment.Left
	officerLvlLbl.ZIndex = panel.ZIndex + 1
	officerLvlLbl.Parent = officerBlock

	local officerXpBarBg = Instance.new("Frame")
	officerXpBarBg.Name = "OfficerXpBg"
	officerXpBarBg.Size = UDim2.new(1, 0, 0, 4)
	officerXpBarBg.Position = UDim2.fromOffset(0, 92)
	officerXpBarBg.BackgroundColor3 = UIStyle.Color.PanelInk or Color3.fromRGB(40, 32, 20)
	officerXpBarBg.BackgroundTransparency = 0.4
	officerXpBarBg.BorderSizePixel = 0
	officerXpBarBg.ZIndex = panel.ZIndex + 1
	officerXpBarBg.Parent = officerBlock
	local officerXpBarFill = Instance.new("Frame")
	officerXpBarFill.Size = UDim2.new(0, 0, 1, 0)
	officerXpBarFill.BackgroundColor3 = UIStyle.Color.Gold or Color3.fromRGB(220, 180, 110)
	officerXpBarFill.BorderSizePixel = 0
	officerXpBarFill.ZIndex = panel.ZIndex + 2
	officerXpBarFill.Parent = officerXpBarBg

	------------------------------------------------------------------
	-- COMPOSITION section (scrolling)
	------------------------------------------------------------------
	local compBlock = Instance.new("Frame")
	compBlock.Name = "Composition"
	compBlock.Size = UDim2.new(1, 0, 0, 18)       -- min; grows with the list (AutomaticSize)
	compBlock.AutomaticSize = Enum.AutomaticSize.Y
	compBlock.BackgroundTransparency = 1
	compBlock.LayoutOrder = 5
	compBlock.Parent = panel

	UIBuilder.eyebrow(compBlock, "Composition", {
		Size = UDim2.new(1, 0, 0, 14),
		Position = UDim2.fromOffset(0, 0),
	})

	-- Composition rows fit their content (armies have only a handful of unit types), so no fixed
	-- height / scroll area -- the block sizes to the rows and the panel compacts accordingly.
	local compList = Instance.new("Frame")
	compList.Size = UDim2.new(1, 0, 0, 0)
	compList.AutomaticSize = Enum.AutomaticSize.Y
	compList.Position = UDim2.fromOffset(0, 18)
	compList.BackgroundTransparency = 1
	compList.BorderSizePixel = 0
	compList.Parent = compBlock

	local cLayout = Instance.new("UIListLayout")
	cLayout.FillDirection = Enum.FillDirection.Vertical
	cLayout.SortOrder = Enum.SortOrder.LayoutOrder
	cLayout.Padding = UDim.new(0, 2)
	cLayout.Parent = compList

	local compRows = {}        -- unitId -> ledgerRow handle, for in-place diffing (no teardown/rebuild)
	local compEmptyLbl = nil

	------------------------------------------------------------------
	-- FOOTER (actions)
	------------------------------------------------------------------
	local footer = Instance.new("Frame")
	footer.Name = "Footer"
	footer.Size = UDim2.new(1, 0, 0, 48)
	footer.BackgroundTransparency = 1
	footer.LayoutOrder = 99
	footer.Parent = panel

	local footerPad = Instance.new("UIPadding")
	footerPad.PaddingTop = UDim.new(0, 6)
	footerPad.PaddingBottom = UDim.new(0, 6)
	footerPad.Parent = footer

	local actionRow = Instance.new("Frame")
	actionRow.Name = "Actions"
	actionRow.Size = UDim2.fromScale(1, 1)
	actionRow.BackgroundTransparency = 1
	actionRow.Parent = footer

	local actionLayout = Instance.new("UIListLayout")
	actionLayout.FillDirection = Enum.FillDirection.Horizontal
	actionLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	actionLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	actionLayout.Padding = UDim.new(0, 8)
	actionLayout.Parent = actionRow

	local actionPad = Instance.new("UIPadding")
	actionPad.PaddingRight = UDim.new(0, 92)
	actionPad.Parent = actionRow

	local mergeBtn, setMergeEnabled = makeActionButton(actionRow, { size = UDim2.fromOffset(64, 32), text = "Merge", layoutOrder = 2 })
	local reassignBtn = makeActionButton(actionRow, { size = UDim2.fromOffset(80, 32), text = "Reassign", layoutOrder = 3 })
	local disbandBtn = makeActionButton(actionRow, { size = UDim2.fromOffset(76, 32), text = "Disband", layoutOrder = 4, variant = "destructive" })

	local deselectBtn = makeActionButton(footer, {
		size = UDim2.fromOffset(82, 32),
		position = UDim2.new(1, 0, 0.5, 0),
		anchorPoint = Vector2.new(1, 0.5),
		text = "Deselect",
	})

	local reassignModal = Instance.new("Frame")
	reassignModal.Name = "ReassignModal"
	reassignModal.Size = UDim2.fromOffset(300, 320)
	reassignModal.AnchorPoint = Vector2.new(1, 1)
	reassignModal.Position = UDim2.new(0, -8, 1, 0)
	reassignModal.BackgroundColor3 = UIStyle.Color.PanelInk or Color3.fromRGB(28, 22, 14)
	reassignModal.BackgroundTransparency = 0.04
	reassignModal.BorderSizePixel = 0
	reassignModal.ZIndex = panel.ZIndex + 20
	reassignModal.Visible = false
	reassignModal.Parent = panel
	local modalCorner = Instance.new("UICorner")
	modalCorner.CornerRadius = UDim.new(0, 4)
	modalCorner.Parent = reassignModal
	local modalStroke = Instance.new("UIStroke")
	modalStroke.Color = UIStyle.Color.Gold or Color3.fromRGB(200, 160, 80)
	modalStroke.Thickness = 1
	modalStroke.Transparency = 0.4
	modalStroke.Parent = reassignModal
	local modalPad = Instance.new("UIPadding")
	modalPad.PaddingTop = UDim.new(0, 12)
	modalPad.PaddingBottom = UDim.new(0, 10)
	modalPad.PaddingLeft = UDim.new(0, 12)
	modalPad.PaddingRight = UDim.new(0, 12)
	modalPad.Parent = reassignModal

	local modalTitle = Instance.new("TextLabel")
	modalTitle.Size = UDim2.new(1, 0, 0, 18)
	modalTitle.Position = UDim2.fromOffset(0, 0)
	modalTitle.BackgroundTransparency = 1
	modalTitle.Text = "Reassign Officer"
	modalTitle.TextColor3 = UIStyle.Color.Cream or UIStyle.Color.Gold or Color3.fromRGB(230, 200, 140)
	if UIStyle.FontFace and UIStyle.FontFace.Cinzel then
		modalTitle.FontFace = UIStyle.FontFace.Cinzel
	else
		modalTitle.Font = UIStyle.Font.Display or Enum.Font.Garamond
	end
	modalTitle.TextSize = 16
	modalTitle.TextXAlignment = Enum.TextXAlignment.Left
	modalTitle.ZIndex = reassignModal.ZIndex + 1
	modalTitle.Parent = reassignModal

	local modalSubtitle = Instance.new("TextLabel")
	modalSubtitle.Size = UDim2.new(1, 0, 0, 14)
	modalSubtitle.Position = UDim2.fromOffset(0, 18)
	modalSubtitle.BackgroundTransparency = 1
	modalSubtitle.Text = "Pick up to 5 traits · costs 25 PP"
	modalSubtitle.TextColor3 = UIStyle.Color.TextMuted or Color3.fromRGB(180, 160, 120)
	modalSubtitle.Font = UIStyle.Font.Regular or Enum.Font.Gotham
	modalSubtitle.TextSize = 11
	modalSubtitle.TextXAlignment = Enum.TextXAlignment.Left
	modalSubtitle.ZIndex = reassignModal.ZIndex + 1
	modalSubtitle.Parent = reassignModal

	local modalList = Instance.new("ScrollingFrame")
	modalList.Size = UDim2.new(1, 0, 1, -76)
	modalList.Position = UDim2.fromOffset(0, 36)
	modalList.BackgroundTransparency = 1
	modalList.BorderSizePixel = 0
	modalList.ScrollBarThickness = 3
	modalList.ScrollBarImageColor3 = UIStyle.Color.Border or Color3.fromRGB(142, 84, 24)
	modalList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	modalList.CanvasSize = UDim2.new(0, 0, 0, 0)
	modalList.ZIndex = reassignModal.ZIndex + 1
	modalList.Parent = reassignModal
	local modalListLayout = Instance.new("UIListLayout")
	modalListLayout.FillDirection = Enum.FillDirection.Vertical
	modalListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	modalListLayout.Padding = UDim.new(0, 3)
	modalListLayout.Parent = modalList

	local modalBtnRow = Instance.new("Frame")
	modalBtnRow.Size = UDim2.new(1, 0, 0, 30)
	modalBtnRow.Position = UDim2.new(0, 0, 1, -30)
	modalBtnRow.BackgroundTransparency = 1
	modalBtnRow.ZIndex = reassignModal.ZIndex + 1
	modalBtnRow.Parent = reassignModal
	local modalBtnLayout = Instance.new("UIListLayout")
	modalBtnLayout.FillDirection = Enum.FillDirection.Horizontal
	modalBtnLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	modalBtnLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	modalBtnLayout.Padding = UDim.new(0, 6)
	modalBtnLayout.Parent = modalBtnRow

	local modalCancelBtn = makeActionButton(modalBtnRow, { size = UDim2.fromOffset(72, 28), text = "Cancel", layoutOrder = 1 })
	local modalConfirmBtn = makeActionButton(modalBtnRow, { size = UDim2.fromOffset(86, 28), text = "Reassign", layoutOrder = 2 })
	modalCancelBtn.ZIndex = reassignModal.ZIndex + 2
	modalConfirmBtn.ZIndex = reassignModal.ZIndex + 2

	------------------------------------------------------------------
	-- State + behavior
	------------------------------------------------------------------
	local currentArmyIds = {}
	local activeArmyId = nil
	local lastList, lastBundle, lastProvinceName, lastCountry = nil, nil, nil, nil
	local existingTabStrip = nil

	local function getActiveArmy()
		if not lastList then return nil end
		for _, a in ipairs(lastList) do
			if a.id == activeArmyId then return a end
		end
		return lastList[1]
	end

	local function clearTabSlot()
		for _, c in ipairs(tabSlot:GetChildren()) do
			if c:IsA("Frame") or c:IsA("TextLabel") or c:IsA("TextButton") then c:Destroy() end
		end
		existingTabStrip = nil
	end

	local function updateMergeBtnState()
		-- High-contrast disabled state: dim the fill + muted-but-legible label (see makeActionButton),
		-- never the old 50%-transparent text that made the label unreadable.
		setMergeEnabled(#currentArmyIds >= 2)
	end

	local rebuildLog

	local function refreshActive()
		local army = getActiveArmy()
		if not army then return end
		local info = dominantInfo(army, lastBundle)

		-- Header — color the accent strip from the owning country (crest removed as redundant).
		local ownerCountry = lastBundle and lastBundle.countries and army.ownerTag and lastBundle.countries[army.ownerTag] or nil
		accentStrip.BackgroundColor3 = toColor3(ownerCountry and ownerCountry.color, UIStyle.Color.Gold)
		if info.total > 0 then
			nameLbl.Text = string.format("%s × %d", info.domName, info.total)
		else
			nameLbl.Text = info.domName
		end
		stateLbl.Text = statusText(army, lastProvinceName)

		-- Vitals
		local moralePct = math.clamp((army.morale or 0) / MORALE_MAX, 0, 1)
		moraleStat.value.Text = string.format("%d / %d", math.floor(army.morale or 0), MORALE_MAX)
		if moraleStat.barFill then
			moraleStat.barFill.Size = UDim2.fromScale(moralePct, 1)
			moraleStat.barFill.BackgroundColor3 = tierColor(moralePct)
		end

		local baseOrg = army.baseOrganization or 10
		local orgVal = army.organization or baseOrg
		local orgPct = baseOrg > 0 and math.clamp(orgVal / baseOrg, 0, 1) or 0
		orgStat.value.Text = string.format("%d / %d", math.floor(orgVal), math.floor(baseOrg))
		if orgStat.barFill then
			orgStat.barFill.Size = UDim2.fromScale(orgPct, 1)
			orgStat.barFill.BackgroundColor3 = tierColor(orgPct)
		end

		-- Strength = this army's men; Manpower = the country's reserve pool (levy/pro-aware).
		strengthStat.value.Text = string.format("%s men", commafy(info.total * REGIMENT_STRENGTH))
		mpStat.value.Text = manpowerText(lastCountry)

		local officer = army.officer
		if type(officer) == "table" then
			officerNameLbl.Text = (type(officer.name) == "string" and officer.name ~= "") and officer.name or "—"
			local dom = army.domain or officer.domain or "ground"
			officerDomainLbl.Text = string.upper(tostring(dom))
			local traitNames = {}
			for _, tid in ipairs(officer.traits or {}) do
				local def = OfficerTraits[tid]
				table.insert(traitNames, (def and def.displayName) or tostring(tid))
			end
			officerTraitsLbl.Text = #traitNames > 0 and table.concat(traitNames, "  ·  ") or "no traits"
			officerRollupLbl.Text = officerRollupText(officer.traits)

			local lvl = officer.level or 0
			local xp = officer.experience or 0
			local nextXp = OfficerTraits.xpForNextLevel and OfficerTraits.xpForNextLevel(lvl) or nil
			if nextXp then
				local floor = OfficerTraits.xpForLevel and OfficerTraits.xpForLevel(lvl) or 0
				local span = math.max(1, nextXp - floor)
				local prog = math.clamp((xp - floor) / span, 0, 1)
				officerLvlLbl.Text = string.format("Lvl %d  ·  XP %d / %d", lvl, math.floor(xp), nextXp)
				officerXpBarFill.Size = UDim2.fromScale(prog, 1)
			else
				officerLvlLbl.Text = string.format("Lvl %d  ·  XP %d (max)", lvl, math.floor(xp))
				officerXpBarFill.Size = UDim2.fromScale(1, 1)
			end
		else
			officerNameLbl.Text = "Unassigned"
			officerDomainLbl.Text = ""
			officerTraitsLbl.Text = ""
			officerRollupLbl.Text = ""
			officerLvlLbl.Text = ""
			officerXpBarFill.Size = UDim2.fromScale(0, 1)
		end

		if army.battleId then
			local battle = ClientStateCache.getBattle and ClientStateCache.getBattle(army.battleId)
			local phase = battlePhaseLabel(battle)
			local widthInfo = combatWidthLabel(battle, army)
			if phase or widthInfo then
				phaseLbl.Text = phase or ""
				widthLbl.Text = widthInfo or ""
				battleStrip.Visible = true
			else
				battleStrip.Visible = false
			end
			if logPopup.Visible then rebuildLog(army) end
		else
			battleStrip.Visible = false
			logPopup.Visible = false
		end

		local entMax = army.entrenchmentMax or 5
		local entVal = army.entrenchment or 0
		local entPct = entMax > 0 and math.clamp(entVal / entMax, 0, 1) or 0
		entStat.value.Text = string.format("%d / %d", math.floor(entVal), math.floor(entMax))
		if entStat.barFill then
			entStat.barFill.Size = UDim2.fromScale(entPct, 1)
		end

		-- Composition — diff in place: update existing rows, add new, remove stale. No
		-- teardown/rebuild of frames every refresh (the old churn this redo targets).
		local seen = {}
		for i, e in ipairs(info.entries) do
			seen[e.id] = true
			local name = (e.unit and e.unit.displayName) or titleCase(e.id)
			local rowH = compRows[e.id]
			if rowH then
				rowH.label.Text = name
				rowH.value.Text = string.format("× %d", e.count)
				rowH.root.LayoutOrder = i
			else
				compRows[e.id] = UIBuilder.ledgerRow(compList, {
					label = name,
					value = string.format("× %d", e.count),
					LayoutOrder = i,
				})
			end
		end
		for id, rowH in pairs(compRows) do
			if not seen[id] then
				rowH.root:Destroy()
				compRows[id] = nil
			end
		end
		if #info.entries == 0 then
			if not compEmptyLbl then
				compEmptyLbl = Instance.new("TextLabel")
				compEmptyLbl.Size = UDim2.new(1, 0, 0, 18)
				compEmptyLbl.BackgroundTransparency = 1
				compEmptyLbl.Text = "no regiments"
				compEmptyLbl.TextColor3 = UIStyle.Color.TextMuted or Color3.fromRGB(154, 120, 72)
				compEmptyLbl.Font = UIStyle.Font.Regular or Enum.Font.Gotham
				compEmptyLbl.TextSize = 11
				compEmptyLbl.TextXAlignment = Enum.TextXAlignment.Left
				compEmptyLbl.Parent = compList
			end
			compEmptyLbl.Visible = true
		elseif compEmptyLbl then
			compEmptyLbl.Visible = false
		end

		updateMergeBtnState()
	end

	local function show(armies, bundle, provinceName, country)
		if not armies then panel.Visible = false; currentArmyIds = {}; activeArmyId = nil; return end
		local list = (armies.id and armies.composition) and { armies } or armies
		if #list == 0 then panel.Visible = false; currentArmyIds = {}; activeArmyId = nil; return end

		currentArmyIds = {}
		for _, a in ipairs(list) do table.insert(currentArmyIds, a.id) end
		if not activeArmyId or not table.find(currentArmyIds, activeArmyId) then
			activeArmyId = list[1].id
		end

		lastList = list
		lastBundle = bundle
		lastProvinceName = provinceName
		lastCountry = country

		clearTabSlot()
		if #list > 1 then
			local tabDefs = {}
			for i, a in ipairs(list) do
				local info = dominantInfo(a, bundle)
				table.insert(tabDefs, { key = a.id, label = info.domName })
			end
			existingTabStrip = UIBuilder.tabStrip(tabSlot, tabDefs, function(key)
				activeArmyId = key
				refreshActive()
			end)
			tabSlot.Size = UDim2.new(1, 0, 0, 22)
			tabSlot.Visible = true
			accentStrip.Position = UDim2.fromOffset(0, 28)
			nameLbl.Position = UDim2.fromOffset(10, 28)
			stateLbl.Position = UDim2.fromOffset(10, 54)
			hintLbl.Position = UDim2.fromOffset(10, 76)
			header.Size = UDim2.new(1, 0, 0, 92)
		else
			tabSlot.Visible = false
			tabSlot.Size = UDim2.new(1, 0, 0, 0)
			accentStrip.Position = UDim2.fromOffset(0, 0)
			nameLbl.Position = UDim2.fromOffset(10, 0)
			stateLbl.Position = UDim2.fromOffset(10, 26)
			hintLbl.Position = UDim2.fromOffset(10, 48)
			header.Size = UDim2.new(1, 0, 0, 66)
		end

		refreshActive()
		panel.Visible = true
	end

	local function hide()
		panel.Visible = false
		reassignModal.Visible = false
		logPopup.Visible = false
		currentArmyIds = {}
		activeArmyId = nil
		lastList = nil
	end

	local phaseGoldColor = UIStyle.Color.Gold or Color3.fromRGB(220, 180, 110)
	local phaseFlashColor = Color3.fromRGB(255, 240, 210)
	local function flashPhaseLabel()
		if not phaseLbl.Parent then return end
		phaseLbl.TextColor3 = phaseFlashColor
		local restore = TweenService:Create(phaseLbl,
			TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
			{ TextColor3 = phaseGoldColor })
		restore:Play()
		if UISound and UISound.phase then
			UISound.phase()
		end
	end

	local remotes = ReplicatedStorage:FindFirstChild("ArtOfWar")
	remotes = remotes and remotes:FindFirstChild("Remotes")
	local phaseChannel = remotes and remotes:FindFirstChild("BattlePhaseChannel")
	if not phaseChannel then
		task.spawn(function()
			local r = remotes and remotes:WaitForChild("BattlePhaseChannel", 30)
			if r then phaseChannel = r end
			if phaseChannel then
				phaseChannel.OnClientEvent:Connect(function(data)
					if type(data) ~= "table" or not data.battleId then return end
					local current = getActiveArmy()
					if not current or current.battleId ~= data.battleId then return end
					local battle = ClientStateCache.getBattle and ClientStateCache.getBattle(data.battleId)
					phaseLbl.Text = battlePhaseLabel(battle) or phaseLbl.Text
					widthLbl.Text = combatWidthLabel(battle, current) or widthLbl.Text
					battleStrip.Visible = true
					flashPhaseLabel()
				end)
			end
		end)
	else
		phaseChannel.OnClientEvent:Connect(function(data)
			if type(data) ~= "table" or not data.battleId then return end
			local current = getActiveArmy()
			if not current or current.battleId ~= data.battleId then return end
			local battle = ClientStateCache.getBattle and ClientStateCache.getBattle(data.battleId)
			phaseLbl.Text = battlePhaseLabel(battle) or phaseLbl.Text
			widthLbl.Text = combatWidthLabel(battle, current) or widthLbl.Text
			battleStrip.Visible = true
			flashPhaseLabel()
		end)
	end

	deselectBtn.MouseButton1Click:Connect(function()
		if callbacks.onClear then callbacks.onClear() end
	end)

	mergeBtn.MouseButton1Click:Connect(function()
		if not callbacks.onMerge then return end
		if #currentArmyIds < 2 then return end
		local primary = activeArmyId or currentArmyIds[1]
		local others = {}
		for _, id in ipairs(currentArmyIds) do
			if id ~= primary then table.insert(others, id) end
		end
		if #others > 0 then
			callbacks.onMerge(primary, others)
		end
	end)

	disbandBtn.MouseButton1Click:Connect(function()
		if not callbacks.onDisband then return end
		local id = activeArmyId or currentArmyIds[1]
		if id then callbacks.onDisband(id) end
	end)

	local modalSelection = {}

	local function clearModalList()
		for _, c in ipairs(modalList:GetChildren()) do
			if c:IsA("Frame") or c:IsA("TextButton") or c:IsA("TextLabel") then c:Destroy() end
		end
	end

	local function buildModalRow(def, isSelected)
		local row = Instance.new("TextButton")
		row.Name = "Trait_" .. tostring(def.id)
		row.Size = UDim2.new(1, 0, 0, 44)
		row.BackgroundColor3 = UIStyle.Color.WoodFrame or Color3.fromRGB(40, 32, 22)
		row.BackgroundTransparency = isSelected and 0.0 or 0.45
		row.BorderSizePixel = 0
		row.Text = ""
		row.AutoButtonColor = false
		row.ZIndex = reassignModal.ZIndex + 2
		row.Parent = modalList
		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = UDim.new(0, 3)
		rowCorner.Parent = row
		local rowStroke = Instance.new("UIStroke")
		rowStroke.Color = isSelected and (UIStyle.Color.Gold or Color3.fromRGB(220, 180, 110)) or (UIStyle.Color.Border or Color3.fromRGB(80, 64, 40))
		rowStroke.Thickness = 1
		rowStroke.Transparency = isSelected and 0 or 0.5
		rowStroke.Parent = row
		local rowPad = Instance.new("UIPadding")
		rowPad.PaddingLeft = UDim.new(0, 8)
		rowPad.PaddingRight = UDim.new(0, 8)
		rowPad.PaddingTop = UDim.new(0, 4)
		rowPad.PaddingBottom = UDim.new(0, 4)
		rowPad.Parent = row

		local nameLine = Instance.new("TextLabel")
		nameLine.Size = UDim2.new(1, 0, 0, 14)
		nameLine.Position = UDim2.fromOffset(0, 0)
		nameLine.BackgroundTransparency = 1
		nameLine.Text = def.displayName or def.id
		nameLine.TextColor3 = isSelected and (UIStyle.Color.Gold or Color3.fromRGB(220, 180, 110)) or (UIStyle.Color.Cream or Color3.fromRGB(220, 200, 160))
		nameLine.Font = UIStyle.Font.Regular or Enum.Font.Gotham
		nameLine.TextSize = 12
		nameLine.TextXAlignment = Enum.TextXAlignment.Left
		nameLine.ZIndex = row.ZIndex + 1
		nameLine.Parent = row

		local descLine = Instance.new("TextLabel")
		descLine.Size = UDim2.new(1, 0, 0, 22)
		descLine.Position = UDim2.fromOffset(0, 14)
		descLine.BackgroundTransparency = 1
		descLine.Text = def.description or ""
		descLine.TextColor3 = UIStyle.Color.TextMuted or Color3.fromRGB(160, 140, 110)
		descLine.Font = UIStyle.Font.Regular or Enum.Font.Gotham
		descLine.TextSize = 10
		descLine.TextWrapped = true
		descLine.TextXAlignment = Enum.TextXAlignment.Left
		descLine.TextYAlignment = Enum.TextYAlignment.Top
		descLine.ZIndex = row.ZIndex + 1
		descLine.Parent = row

		return row
	end

	local function refreshModalRows(domain)
		clearModalList()
		local pool = OfficerTraits.byDomain and OfficerTraits.byDomain(domain or "ground") or {}
		table.sort(pool, function(a, b)
			return (a.displayName or a.id or "") < (b.displayName or b.id or "")
		end)
		for i, def in ipairs(pool) do
			local row = buildModalRow(def, modalSelection[def.id] == true)
			row.LayoutOrder = i
			row.MouseButton1Click:Connect(function()
				local maxTraits = OfficerTraits.MAX_TRAITS or 5
				if modalSelection[def.id] then
					modalSelection[def.id] = nil
				else
					local count = 0
					for _, v in pairs(modalSelection) do if v then count = count + 1 end end
					if count >= maxTraits then return end
					modalSelection[def.id] = true
				end
				refreshModalRows(domain)
			end)
		end
	end

	local function openReassignModal()
		local army = getActiveArmy()
		if not army then return end
		modalSelection = {}
		if type(army.officer) == "table" and type(army.officer.traits) == "table" then
			for _, tid in ipairs(army.officer.traits) do modalSelection[tid] = true end
		end
		local domain = army.domain or (army.officer and army.officer.domain) or "ground"
		refreshModalRows(domain)
		reassignModal.Visible = true
	end

	reassignBtn.MouseButton1Click:Connect(openReassignModal)

	modalCancelBtn.MouseButton1Click:Connect(function()
		reassignModal.Visible = false
	end)

	modalConfirmBtn.MouseButton1Click:Connect(function()
		local army = getActiveArmy()
		if not army then reassignModal.Visible = false; return end
		local picked = {}
		for tid, on in pairs(modalSelection) do
			if on then table.insert(picked, tid) end
		end
		if #picked == 0 then return end
		if callbacks.onOfficerReassign then
			callbacks.onOfficerReassign(army.id, picked)
		end
		reassignModal.Visible = false
	end)

	local function clearLogScroll()
		for _, c in ipairs(logScroll:GetChildren()) do
			if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
		end
	end

	function rebuildLog(army)
		clearLogScroll()
		if not army or not army.battleId then return end
		local battle = ClientStateCache.getBattle and ClientStateCache.getBattle(army.battleId)
		local entries = battle and battle.log
		if type(entries) ~= "table" or #entries == 0 then
			local empty = Instance.new("TextLabel")
			empty.Size = UDim2.new(1, 0, 0, 18)
			empty.BackgroundTransparency = 1
			empty.Text = "no log entries yet"
			empty.TextColor3 = UIStyle.Color.TextMuted or Color3.fromRGB(160, 140, 110)
			empty.Font = UIStyle.Font.Regular or Enum.Font.Gotham
			empty.TextSize = 11
			empty.TextXAlignment = Enum.TextXAlignment.Left
			empty.ZIndex = logScroll.ZIndex + 1
			empty.LayoutOrder = 0
			empty.Parent = logScroll
			return
		end
		for i = #entries, 1, -1 do
			local e = entries[i]
			local row = Instance.new("Frame")
			row.Size = UDim2.new(1, 0, 0, 18)
			row.BackgroundColor3 = (i % 2 == 0) and (UIStyle.Color.WoodFrame or Color3.fromRGB(40, 32, 22)) or Color3.fromRGB(28, 22, 14)
			row.BackgroundTransparency = 0.55
			row.BorderSizePixel = 0
			row.LayoutOrder = #entries - i
			row.ZIndex = logScroll.ZIndex + 1
			row.Parent = logScroll
			local rowCorner = Instance.new("UICorner")
			rowCorner.CornerRadius = UDim.new(0, 2)
			rowCorner.Parent = row
			local rowPad = Instance.new("UIPadding")
			rowPad.PaddingLeft = UDim.new(0, 6)
			rowPad.PaddingRight = UDim.new(0, 6)
			rowPad.Parent = row

			local tickLbl = Instance.new("TextLabel")
			tickLbl.Size = UDim2.fromOffset(36, 18)
			tickLbl.BackgroundTransparency = 1
			tickLbl.Text = string.format("T%d", e.tick or 0)
			tickLbl.TextColor3 = UIStyle.Color.Gold or Color3.fromRGB(220, 180, 110)
			tickLbl.Font = UIStyle.Font.Regular or Enum.Font.Gotham
			tickLbl.TextSize = 10
			tickLbl.TextXAlignment = Enum.TextXAlignment.Left
			tickLbl.ZIndex = row.ZIndex + 1
			tickLbl.Parent = row

			local phaseLblE = Instance.new("TextLabel")
			phaseLblE.Size = UDim2.fromOffset(72, 18)
			phaseLblE.Position = UDim2.fromOffset(36, 0)
			phaseLblE.BackgroundTransparency = 1
			phaseLblE.Text = tostring(e.phaseId or "?"):gsub("^%l", string.upper)
			phaseLblE.TextColor3 = UIStyle.Color.Cream or Color3.fromRGB(220, 200, 160)
			phaseLblE.Font = UIStyle.Font.Regular or Enum.Font.Gotham
			phaseLblE.TextSize = 10
			phaseLblE.TextXAlignment = Enum.TextXAlignment.Left
			phaseLblE.ZIndex = row.ZIndex + 1
			phaseLblE.Parent = row

			local casLbl = Instance.new("TextLabel")
			casLbl.Size = UDim2.new(1, -116, 1, 0)
			casLbl.Position = UDim2.fromOffset(112, 0)
			casLbl.BackgroundTransparency = 1
			casLbl.Text = string.format("atk %d / def %d", e.atkCasualties or 0, e.defCasualties or 0)
			casLbl.TextColor3 = UIStyle.Color.TextMuted or Color3.fromRGB(180, 160, 120)
			casLbl.Font = UIStyle.Font.Regular or Enum.Font.Gotham
			casLbl.TextSize = 10
			casLbl.TextXAlignment = Enum.TextXAlignment.Right
			casLbl.ZIndex = row.ZIndex + 1
			casLbl.Parent = row
		end
	end

	logBtn.MouseButton1Click:Connect(function()
		local army = getActiveArmy()
		if not army or not army.battleId then return end
		if logPopup.Visible then
			logPopup.Visible = false
		else
			rebuildLog(army)
			logPopup.Visible = true
		end
	end)
	logPopupClose.MouseButton1Click:Connect(function()
		logPopup.Visible = false
	end)

	return {
		root = panel,
		show = show,
		hide = hide,
		getCurrentIds = function() return currentArmyIds end,
		getCurrentId = function() return activeArmyId or currentArmyIds[1] end,
	}
end

return ArmyPanel
