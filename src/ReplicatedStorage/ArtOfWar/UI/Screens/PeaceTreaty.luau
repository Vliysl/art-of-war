local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Spacing = DesignSystem.Spacing
local Components = script.Parent.Parent.Components
local Modal = require(Components.Modal)
local Button = require(Components.Button)
local StatRow = require(Components.StatRow)
local SectionDivider = require(Components.SectionDivider)

local PeaceTreaty = {}

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
		title = "Peace Treaty",
		subtitle = t.warName or "Ongoing War",
		width = 580,
		height = 460,
		footer = true,
		dismissable = false,
		onClose = ctx.onClose,
	})

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Spacing.space1)
	layout.Parent = modal.content

	SectionDivider.create({ parent = modal.content, label = "Demands", layoutOrder = 1 })
	local demands = t.demands or {}
	if #demands > 0 then
		for i, d in ipairs(demands) do
			StatRow.create({
				parent = modal.content,
				icon = d.icon or "Core",
				label = d.label,
				value = val(d.value),
				valueColor = "positive",
				layoutOrder = 1 + i,
			})
		end
	else
		local none = Instance.new("TextLabel")
		none.Size = UDim2.new(1, 0, 0, 28)
		none.BackgroundTransparency = 1
		none.Text = "No demands."
		none.TextColor3 = DesignSystem.Colors.TextSecondary
		none.TextXAlignment = Enum.TextXAlignment.Left
		none.LayoutOrder = 2
		DesignSystem.Typography.apply(none, "bodySm")
		none.Parent = modal.content
	end

	SectionDivider.create({ parent = modal.content, label = "Cost", layoutOrder = 20 })
	local costs = t.costs or {}
	for i, c in ipairs(costs) do
		StatRow.create({
			parent = modal.content,
			icon = c.icon or "Stability",
			label = c.label,
			value = val(c.value),
			valueColor = "negative",
			layoutOrder = 20 + i,
		})
	end

	local function finish(callback)
		if callback then
			callback()
		end
		modal.close()
	end

	Button.create({
		parent = modal.footer,
		variant = "ghost",
		text = "Cancel",
		width = 110,
		layoutOrder = 1,
		onClick = function()
			modal.close()
		end,
	})
	Button.create({
		parent = modal.footer,
		variant = "danger",
		text = "Refuse",
		width = 130,
		layoutOrder = 2,
		onClick = function()
			finish(t.onRefuse)
		end,
	})
	Button.create({
		parent = modal.footer,
		variant = "primary",
		text = "Accept Terms",
		width = 170,
		layoutOrder = 3,
		onClick = function()
			finish(t.onAccept)
		end,
	})

	return modal
end

return PeaceTreaty
