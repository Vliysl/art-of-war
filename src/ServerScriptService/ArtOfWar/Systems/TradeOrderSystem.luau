-- TradeOrderSystem: Rise-of-Nations-style currency trade. A nation buys or sells a basket of
-- resources to/from another nation for treasury gold (price = basePrice x multiplier). Orders are
-- one-time or recurring (every TradeOrderRecurringIntervalDays game-days). A player counterparty must
-- accept; unclaimed/AI nations auto-accept. Recurring orders auto-cancel when a side runs out of gold
-- or stock, or when the two nations go to war. Replaces the legacy goods-for-goods TradeSystem on the
-- client; that system is left in place but unused.

local TradeOrderSystem = {}

local ctx
local orders = {}
local nextId = 1
local gameDayCounter = 0

local PENDING_TTL_SECONDS = 120
local SWEEP_INTERVAL_SECONDS = 15
local TERMINAL_TTL_SECONDS = 60

local function allocId()
	local id = nextId
	nextId += 1
	return id
end

local function const(name, default)
	local v = ctx.WorldConstants and ctx.WorldConstants[name]
	if type(v) == "number" then
		return v
	end
	return default
end

local function basePriceOf(goodId)
	local bundle = ctx.Bundle
	local def = bundle and bundle.tradeGoods and bundle.tradeGoods[goodId]
	return def and def.basePrice or nil
end

local function displayName(tag)
	local country = ctx.WorldState.getCountry(tag)
	return (country and country.displayName) or tag
end

local function isPlayer(tag)
	return ctx.PlayerAuthority ~= nil
		and ctx.PlayerAuthority.playerFor ~= nil
		and ctx.PlayerAuthority.playerFor(tag) ~= nil
end

local function atWar(a, b)
	return ctx.DiplomacySystem ~= nil
		and ctx.DiplomacySystem.areAtWar ~= nil
		and ctx.DiplomacySystem.areAtWar(a, b) == true
end

local function stockpileOf(tag, goodId)
	if ctx.EconomySystem and ctx.EconomySystem.stockpileOf then
		return ctx.EconomySystem.stockpileOf(tag, goodId)
	end
	local country = ctx.WorldState.getCountry(tag)
	return (country and country.stockpiles and country.stockpiles[goodId]) or 0
end

local function adjustStockpile(tag, goodId, delta)
	if ctx.EconomySystem and ctx.EconomySystem.adjustStockpile then
		return ctx.EconomySystem.adjustStockpile(tag, goodId, delta)
	end
	return false
end

local function treasuryOf(tag)
	local country = ctx.WorldState.getCountry(tag)
	return (country and country.treasury) or 0
end

local function addTreasury(tag, delta)
	local country = ctx.WorldState.getCountry(tag)
	if not country then
		return
	end
	country.treasury = (country.treasury or 0) + delta
	ctx.WorldState.setCountry(tag, country)
end

local function notify(tag, kind, title, body)
	if not (tag and ctx.NotificationBroadcaster and ctx.NotificationBroadcaster.push) then
		return
	end
	if not isPlayer(tag) then
		return
	end
	ctx.NotificationBroadcaster.push({
		kind = kind,
		title = title,
		body = body,
		audience = "self",
		tag = tag,
		ttl = 12,
	})
end

local function persist(order)
	ctx.WorldState.setTradeOrder(order.id, order)
end

local function publish(channelName, order, extra)
	local channel = ctx.Channels[channelName]
	if not channel then
		return
	end
	local payload = extra or {}
	payload.orderId = order.id
	payload.order = order
	ctx.EventBus.publish(channel, payload)
end

-- Normalise raw client lines into {goodId, amount} (integer), merging duplicate goods, rejecting
-- unknown goods / bad amounts / over-long baskets.
local function buildLines(rawLines)
	if type(rawLines) ~= "table" then
		return nil
	end
	local maxLines = const("TradeOrderMaxLines", 8)
	local out = {}
	local index = {}
	for _, line in ipairs(rawLines) do
		if type(line) ~= "table" then
			return nil
		end
		local goodId = line.goodId
		local amount = line.amount
		if type(goodId) ~= "string" or basePriceOf(goodId) == nil then
			return nil
		end
		if type(amount) ~= "number" or amount ~= amount or amount <= 0 or amount > 1e9 then
			return nil
		end
		amount = math.floor(amount)
		if amount <= 0 then
			return nil
		end
		if index[goodId] then
			out[index[goodId]].amount += amount
		else
			out[#out + 1] = { goodId = goodId, amount = amount }
			index[goodId] = #out
			if #out > maxLines then
				return nil
			end
		end
	end
	if #out == 0 then
		return nil
	end
	return out
end

local function computeTotals(lines, multiplier)
	local unitPrices = {}
	local total = 0
	for _, line in ipairs(lines) do
		local base = basePriceOf(line.goodId) or 0
		unitPrices[line.goodId] = base
		total += line.amount * base
	end
	return unitPrices, total * multiplier
end

local function activeOrderCount(tag)
	local n = 0
	for _, order in orders do
		if
			(order.state == "Active" or order.state == "Pending")
			and (order.initiatorTag == tag or order.counterpartyTag == tag)
		then
			n += 1
		end
	end
	return n
end

-- Atomic pre-check: buyer can afford the whole total AND the seller holds every line in full. Checked
-- before any mutation because adjustStockpile clamps at >= 0 and would otherwise silently swallow an
-- over-draw.
local function canExecute(order)
	if atWar(order.buyerTag, order.sellerTag) then
		return false, "at war"
	end
	if treasuryOf(order.buyerTag) < order.totalCost then
		return false, "insufficient funds"
	end
	for _, line in ipairs(order.lines) do
		if stockpileOf(order.sellerTag, line.goodId) < line.amount then
			return false, "insufficient resources"
		end
	end
	return true
end

local function executeOnce(order)
	local ok, reason = canExecute(order)
	if not ok then
		return false, reason
	end
	for _, line in ipairs(order.lines) do
		adjustStockpile(order.sellerTag, line.goodId, -line.amount)
		adjustStockpile(order.buyerTag, line.goodId, line.amount)
	end
	addTreasury(order.buyerTag, -order.totalCost)
	addTreasury(order.sellerTag, order.totalCost)
	order.executionCount = (order.executionCount or 0) + 1
	order.lastExecutedAt = ctx.TickScheduler.getSimTime()
	publish("TradeOrderExecuted", order)
	return true
end

local function cancelOrder(order, reason, notifyTags)
	order.state = "Cancelled"
	order.reason = reason
	order.cancelledAt = ctx.TickScheduler.getSimTime()
	order.terminalAt = order.cancelledAt
	persist(order)
	publish("TradeOrderCancelled", order, { reason = reason })
	if notifyTags then
		notify(order.initiatorTag, "warn", "Trade Stopped", "A trade stopped: " .. reason .. ".")
		notify(order.counterpartyTag, "warn", "Trade Stopped", "A trade stopped: " .. reason .. ".")
	end
end

local function activate(order)
	local ok, reason = executeOnce(order)
	if not ok then
		cancelOrder(order, reason, false)
		notify(order.initiatorTag, "warn", "Trade Failed", "The trade could not be completed (" .. reason .. ").")
		return false
	end
	if order.recurring then
		order.state = "Active"
		order.nextExecuteDay = gameDayCounter + order.intervalDays
		persist(order)
		publish("TradeOrderActivated", order)
		notify(order.initiatorTag, "good", "Trade Active", "A recurring trade is now active.")
	else
		order.state = "Completed"
		order.completedAt = ctx.TickScheduler.getSimTime()
		order.terminalAt = order.completedAt
		persist(order)
		publish("TradeOrderActivated", order)
		notify(order.initiatorTag, "good", "Trade Complete", "The trade was completed.")
	end
	return true
end

local function place(initiatorTag, counterpartyTag, direction, rawLines, multiplier, recurring)
	if type(initiatorTag) ~= "string" or type(counterpartyTag) ~= "string" or initiatorTag == counterpartyTag then
		return nil
	end
	if direction ~= "buy" and direction ~= "sell" then
		return nil
	end
	if not ctx.WorldState.getCountry(initiatorTag) or not ctx.WorldState.getCountry(counterpartyTag) then
		return nil
	end
	if atWar(initiatorTag, counterpartyTag) then
		notify(initiatorTag, "warn", "Trade Blocked", "You cannot trade with a nation you are at war with.")
		return nil
	end
	if type(multiplier) ~= "number" or multiplier ~= multiplier then
		multiplier = 1
	end
	multiplier = math.clamp(multiplier, const("TradeOrderMultiplierMin", 0.25), const("TradeOrderMultiplierMax", 4))
	-- AI / unclaimed counterparties auto-accept unconditionally (below), so an initiator-chosen
	-- off-market multiplier would be a pure gold/goods pump. Against a non-player the price is always
	-- fair base (x1); the negotiable range is only meaningful between two consenting players.
	if not isPlayer(counterpartyTag) then
		multiplier = 1
	end
	local lines = buildLines(rawLines)
	if not lines then
		return nil
	end
	if activeOrderCount(initiatorTag) >= const("TradeOrderMaxActive", 20) then
		notify(initiatorTag, "warn", "Trade Limit", "You have too many active trade orders.")
		return nil
	end

	local buyerTag, sellerTag
	if direction == "buy" then
		buyerTag, sellerTag = initiatorTag, counterpartyTag
	else
		buyerTag, sellerTag = counterpartyTag, initiatorTag
	end

	local unitPrices, totalCost = computeTotals(lines, multiplier)
	local now = ctx.TickScheduler.getSimTime()
	local order = {
		id = allocId(),
		initiatorTag = initiatorTag,
		counterpartyTag = counterpartyTag,
		buyerTag = buyerTag,
		sellerTag = sellerTag,
		direction = direction,
		lines = lines,
		multiplier = multiplier,
		unitPrices = unitPrices,
		totalCost = totalCost,
		recurring = recurring == true,
		intervalDays = const("TradeOrderRecurringIntervalDays", 5),
		nextExecuteDay = nil,
		state = "Pending",
		createdAt = now,
		expiresAt = now + PENDING_TTL_SECONDS,
	}
	orders[order.id] = order
	persist(order)
	publish("TradeOrderPlaced", order)

	if isPlayer(counterpartyTag) then
		notify(
			counterpartyTag,
			"info",
			"Trade Offer",
			string.format("%s wants to trade with you.", displayName(initiatorTag))
		)
	else
		activate(order)
	end
	return order.id
end

local function accept(orderId, actingTag)
	local order = orders[orderId]
	if not order or order.state ~= "Pending" then
		return false
	end
	if order.counterpartyTag ~= actingTag then
		return false
	end
	return activate(order)
end

local function reject(orderId, actingTag)
	local order = orders[orderId]
	if not order or order.state ~= "Pending" then
		return false
	end
	if order.counterpartyTag ~= actingTag then
		return false
	end
	order.state = "Rejected"
	order.reason = "rejected"
	order.terminalAt = ctx.TickScheduler.getSimTime()
	persist(order)
	publish("TradeOrderRejected", order)
	notify(
		order.initiatorTag,
		"warn",
		"Trade Rejected",
		string.format("%s rejected your trade.", displayName(actingTag))
	)
	return true
end

local function cancel(orderId, actingTag)
	local order = orders[orderId]
	if not order or (order.state ~= "Pending" and order.state ~= "Active") then
		return false
	end
	if order.initiatorTag ~= actingTag and order.counterpartyTag ~= actingTag then
		return false
	end
	cancelOrder(order, "cancelled", false)
	return true
end

local function onDateAdvanced(payload)
	gameDayCounter += (payload and payload.daysAdvanced) or 1
	for _, order in orders do
		if order.state == "Active" and order.nextExecuteDay and gameDayCounter >= order.nextExecuteDay then
			local ok, reason = executeOnce(order)
			if ok then
				order.nextExecuteDay = gameDayCounter + order.intervalDays
				persist(order)
			else
				cancelOrder(order, reason, true)
			end
		end
	end
end

local function onWarDeclared(payload)
	if type(payload) ~= "table" then
		return
	end
	local a, b = payload.attackerTag, payload.defenderTag
	if not a or not b then
		return
	end
	for _, order in orders do
		if order.state == "Active" or order.state == "Pending" then
			local pair = (order.buyerTag == a and order.sellerTag == b)
				or (order.buyerTag == b and order.sellerTag == a)
			if pair then
				cancelOrder(order, "war", true)
			end
		end
	end
end

local function sweep()
	local now = ctx.TickScheduler.getSimTime()
	for id, order in orders do
		if order.state == "Pending" and order.expiresAt and now >= order.expiresAt then
			order.state = "Rejected"
			order.reason = "expired"
			order.terminalAt = now
			persist(order)
			publish("TradeOrderRejected", order)
			notify(order.initiatorTag, "warn", "Trade Expired", "A trade offer expired with no response.")
		elseif order.terminalAt and now - order.terminalAt >= TERMINAL_TTL_SECONDS then
			-- Terminal orders (completed / rejected / cancelled) linger only briefly so the client can
			-- render the final state, then drop from both the server table and the replicated collection
			-- so trade history can't grow without bound or slow the per-tick scans.
			orders[id] = nil
			ctx.WorldState.setTradeOrder(id, nil)
		end
	end
end

function TradeOrderSystem.register(context)
	ctx = context
	local api = {
		place = place,
		accept = accept,
		reject = reject,
		cancel = cancel,
		get = function(id)
			return orders[id]
		end,
	}
	ctx.TradeOrderSystem = api
	for k, v in pairs(api) do
		TradeOrderSystem[k] = v
	end

	ctx.EventBus.subscribe(ctx.Channels.DateAdvanced, onDateAdvanced)
	if ctx.Channels.WarDeclared then
		ctx.EventBus.subscribe(ctx.Channels.WarDeclared, onWarDeclared)
	end
	ctx.TickScheduler.register({
		id = "TradeOrderSystem",
		priority = 30,
		updateIntervalSeconds = SWEEP_INTERVAL_SECONDS,
		update = sweep,
	})
end

return TradeOrderSystem
