-- Incoming peace-offer popup. Data (from HudWiring) is peace-specific:
--   { warName, warStanding = { score, me, them }?, terms = { {icon,label,value,tone}, ... },
--     onAccept, onRefuse, acceptText?, refuseText? }
-- Terms come from PeaceInfo.describeTerms; tone drives the value colour (loss=red, gain=green).
local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Spacing = DesignSystem.Spacing
local Components = script.Parent.Parent.Components
local Modal = require(Components.Modal)
local Button = require(Components.Button)
local StatRow = require(Components.StatRow)
local SectionDivider = require(Components.SectionDivider)

local PeaceTreaty = {}

local TONE_COLOR = { loss = "negative", gain = "positive" }

local function val(v)
	if v == nil or v == "" then
		return "\u{2014}"
	end
	return tostring(v)
end

function PeaceTreaty.create(ctx)
	local t = ctx.data or {}

	local modal = Modal.create({
		parent = ctx.parent,
		title = "Peace Offer",
		subtitle = t.warName or "Ongoing War",
		width = 520,
		height = 440,
		footer = true,
		dismissable = false,
		onClose = ctx.onClose,
	})

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Spacing.space1)
	layout.Parent = modal.content

	local order = 0
	local function nextOrder()
		order += 1
		return order
	end

	-- War standing: the key context for judging an offer (your score + both sides' exhaustion).
	local ws = t.warStanding
	if ws then
		SectionDivider.create({ parent = modal.content, label = "War standing", layoutOrder = nextOrder() })
		local score = math.floor(ws.score or 0)
		StatRow.create({
			parent = modal.content,
			icon = "War",
			label = "War score",
			value = string.format("%s%d", score > 0 and "+" or "", score),
			valueColor = score > 0 and "positive" or (score < 0 and "negative" or nil),
			mono = true,
			layoutOrder = nextOrder(),
		})
		StatRow.create({
			parent = modal.content,
			label = "War exhaustion",
			value = string.format("you %d%%  \u{00B7}  them %d%%", ws.me or 0, ws.them or 0),
			layoutOrder = nextOrder(),
		})
	end

	-- Terms: exactly what accepting means for you (toned loss/gain/neutral).
	SectionDivider.create({ parent = modal.content, label = "Terms", layoutOrder = nextOrder() })
	local terms = t.terms or {}
	if #terms > 0 then
		for _, d in ipairs(terms) do
			StatRow.create({
				parent = modal.content,
				icon = d.icon or "Diplomacy",
				label = d.label or "Term",
				value = val(d.value),
				valueColor = TONE_COLOR[d.tone],
				layoutOrder = nextOrder(),
			})
		end
	else
		local none = Instance.new("TextLabel")
		none.Size = UDim2.new(1, 0, 0, 28)
		none.BackgroundTransparency = 1
		none.Text = "Negotiated peace."
		none.TextColor3 = Colors.TextSecondary
		none.TextXAlignment = Enum.TextXAlignment.Left
		none.LayoutOrder = nextOrder()
		Typography.apply(none, "bodySm")
		none.Parent = modal.content
	end

	local function finish(callback)
		if callback then
			callback()
		end
		modal.close()
	end

	-- "Later" dismisses without responding (the offer stays pending in the Diplomacy screen).
	Button.create({
		parent = modal.footer,
		variant = "ghost",
		text = "Later",
		layoutOrder = 1,
		onClick = function()
			modal.close()
		end,
	})
	Button.create({
		parent = modal.footer,
		variant = "danger",
		text = t.refuseText or "Refuse",
		layoutOrder = 2,
		onClick = function()
			finish(t.onRefuse)
		end,
	})
	Button.create({
		parent = modal.footer,
		variant = "primary",
		text = t.acceptText or "Accept",
		layoutOrder = 3,
		onClick = function()
			finish(t.onAccept)
		end,
	})

	return modal
end

return PeaceTreaty
