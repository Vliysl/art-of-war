local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Icons = DesignSystem.Icons
local Button = require(script.Parent.Button)
local Tooltip = require(script.Parent.Tooltip)

local PickerRow = {}

-- One selectable item in a picker list: a leading icon, a name with a detail line beneath it, and a trailing
-- action button. Used by the Military recruit list and the Fleet build-ships list.
--
-- Exists because the obvious construction is subtly wrong. StatRow right-aligns its Value against the row's
-- RIGHT edge -- which is exactly where a trailing button goes -- so the two occupy the same pixels and the
-- value is clipped by the button ("Needs Mil..."). Measured on the live recruit list: value spanned 236..432
-- and the button 346..432, i.e. the button sat ENTIRELY on top of the value's text. It hides whenever the
-- value happens to be short enough to fit left of the button, which is why it survived in the older pickers.
-- FleetPanel had additionally raised the button's ZIndex above the row, which paints over the collision
-- rather than removing it.
--
-- The fix here is structural, not tuned: the text column's width subtracts the button's width outright, so it
-- can never reach the button at any panel width.
--
-- cfg = {
--   parent, order,
--   icon        -- Icons key for the leading glyph
--   label       -- primary name
--   sub         -- detail line under the name (cost / requirement / reason)
--   buttonText, buttonWidth (default 86),
--   locked      -- greys the name, tints `sub` amber, and disables the button
--   onClick, tooltip (builder fn for Tooltip.attach), height (default 46),
-- }
local ICON_GUTTER = 26 -- 16px glyph + 10px gap
local GAP = 12 -- breathing room between the text column and the button

function PickerRow.create(cfg)
	cfg = cfg or {}
	local btnW = cfg.buttonWidth or 86

	local row = Instance.new("Frame")
	row.Name = "PickerRow"
	row.Size = UDim2.new(1, 0, 0, cfg.height or 46)
	row.BackgroundTransparency = 1
	row.LayoutOrder = cfg.order or 0

	if cfg.icon then
		local icon = Icons.create(cfg.icon, 16, cfg.locked and Colors.TextDisabled or Colors.TextSecondary)
		icon.AnchorPoint = Vector2.new(0, 0.5)
		icon.Position = UDim2.fromScale(0, 0.5)
		icon.Parent = row
	end

	-- The whole point: reserve the button's width so the text can never run under it.
	local textW = -(ICON_GUTTER + btnW + GAP)

	local name = Instance.new("TextLabel")
	name.Name = "Label"
	name.Position = UDim2.fromOffset(ICON_GUTTER, 4)
	name.Size = UDim2.new(1, textW, 0, 18)
	name.BackgroundTransparency = 1
	name.Text = cfg.label or ""
	name.TextColor3 = cfg.locked and Colors.TextDisabled or Colors.TextPrimary
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextTruncate = Enum.TextTruncate.AtEnd
	Typography.apply(name, "bodyMd")
	name.Parent = row

	if cfg.sub then
		local sub = Instance.new("TextLabel")
		sub.Name = "Sub"
		sub.Position = UDim2.fromOffset(ICON_GUTTER, 23)
		sub.Size = UDim2.new(1, textW, 0, 16)
		sub.BackgroundTransparency = 1
		sub.Text = cfg.sub
		-- Amber when locked: the subline carries the REASON, so it should read as a warning, not as flavour.
		sub.TextColor3 = cfg.locked and Colors.Warning or (Colors.TextTertiary or Colors.TextSecondary)
		sub.TextXAlignment = Enum.TextXAlignment.Left
		sub.TextTruncate = Enum.TextTruncate.AtEnd
		Typography.apply(sub, "bodySm")
		sub.Parent = row
	end

	if cfg.buttonText then
		local btn = Button.create({
			parent = row,
			variant = "secondary",
			text = cfg.buttonText,
			width = btnW,
			size = "sm",
			disabled = cfg.locked, -- greys the button + blocks its onClick (Button.create gates on Active)
			onClick = cfg.onClick,
		})
		btn.AnchorPoint = Vector2.new(1, 0.5)
		btn.Position = UDim2.fromScale(1, 0.5)
	end

	if cfg.tooltip then
		Tooltip.attach(row, cfg.tooltip)
	end

	if cfg.parent then
		row.Parent = cfg.parent
	end
	return row
end

return PickerRow
