-- TradeOffer: the accept/reject modal a player sees when another nation directs a trade order at
-- them (the counterparty). Opened by HudWiring when a Pending tradeOrders record targets the local
-- player. Buy/sell is shown from the viewer's point of view.

local ScreenKit = require(script.Parent.ScreenKit)
local Components = script.Parent.Parent.Components
local Modal = require(Components.Modal)
local Button = require(Components.Button)
local SectionDivider = require(Components.SectionDivider)

local TradeOffer = {}

local function prettify(id)
	if type(id) ~= "string" or id == "" then
		return tostring(id)
	end
	local out = {}
	for word in id:gmatch("[^_%s]+") do
		out[#out + 1] = word:sub(1, 1):upper() .. word:sub(2)
	end
	return table.concat(out, " ")
end

local function money(n)
	n = tonumber(n) or 0
	return string.format("\u{00A3}%g", math.floor(n * 100 + 0.5) / 100)
end

function TradeOffer.create(ctx)
	local order = ctx.data or {}
	local registries = ctx.registries or {}
	local goods = registries.TradeGoods or {}
	local mine = ctx.tag

	local function goodName(id)
		local def = goods[id]
		return (def and def.displayName) or prettify(id)
	end
	local function nationName(tag)
		local country = ctx.cache and ctx.cache.getCountry(tag)
		return (country and country.displayName) or tag or "?"
	end

	local iAmBuyer = order.buyerTag == mine
	local verb = iAmBuyer and "sell to" or "buy from"
	local modal = Modal.create({
		parent = ctx.parent,
		title = "Trade Offer",
		subtitle = string.format("%s wants to %s you", nationName(order.initiatorTag), verb),
		width = 480,
		height = 440,
		footer = true,
		dismissable = false,
		onClose = ctx.onClose,
	})

	local body = Instance.new("ScrollingFrame")
	body.Size = UDim2.fromScale(1, 1)
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.ScrollBarThickness = 4
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.CanvasSize = UDim2.new()
	body.Parent = modal.content
	local pad = Instance.new("UIPadding")
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = body
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = body

	SectionDivider.create({ parent = body, label = iAmBuyer and "You Receive" or "You Give", layoutOrder = 1 })
	local lines = order.lines or {}
	for i, line in ipairs(lines) do
		ScreenKit.stat(body, {
			icon = "Goods",
			label = goodName(line.goodId),
			value = string.format("\u{00D7}%s", tostring(line.amount)),
			mono = true,
			layoutOrder = 1 + i,
		})
	end
	if #lines == 0 then
		ScreenKit.note(body, "No resources in this offer.", 2)
	end

	SectionDivider.create({ parent = body, label = "Payment", layoutOrder = 20 })
	ScreenKit.stat(body, {
		icon = "Treasury",
		label = iAmBuyer and "You pay" or "You receive",
		value = money(order.totalCost),
		valueColor = iAmBuyer and "negative" or "positive",
		mono = true,
		layoutOrder = 21,
	})
	ScreenKit.note(
		body,
		order.recurring and "Recurring \u{2014} repeats every 5 days until cancelled." or "One-time deal.",
		22
	)

	local function finish(remote)
		if order.id then
			ctx.fire(remote, order.id)
		end
		modal.close()
	end

	Button.create({
		parent = modal.footer,
		variant = "danger",
		text = "Reject",
		layoutOrder = 1,
		onClick = function()
			finish("RejectTradeOrder")
		end,
	})
	Button.create({
		parent = modal.footer,
		variant = "success",
		text = "Accept",
		layoutOrder = 2,
		onClick = function()
			finish("AcceptTradeOrder")
		end,
	})

	return modal
end

return TradeOffer
