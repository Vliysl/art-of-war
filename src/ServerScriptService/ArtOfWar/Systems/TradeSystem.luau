local TradeSystem = {}

local ctx
local trades = {}
local nextId = 1

local PROPOSAL_TTL_SECONDS = 300
local SWEEP_INTERVAL_SECONDS = 15

local function allocId()
	local id = nextId
	nextId += 1
	return id
end

local function priceOf(goodId)
	local market = ctx.MarketSystem
	if not market then return nil end
	return market.priceOf(goodId)
end

local function valueOf(goodId, amount)
	local price = priceOf(goodId)
	if not price then return nil end
	return amount * price
end

local function isKnownGood(goodId)
	local bundle = ctx.Bundle
	return bundle and bundle.tradeGoods and bundle.tradeGoods[goodId] ~= nil
end

local function withinPriceCap(offer, request)
	local cap = ctx.WorldConstants.PlayerResourceTradeCap
	local offerValue = valueOf(offer.goodId, offer.amount)
	local requestValue = valueOf(request.goodId, request.amount)
	if not offerValue or not requestValue then return false end
	if offerValue <= 0 or requestValue <= 0 then return false end
	local ratio = math.max(offerValue / requestValue, requestValue / offerValue)
	return ratio <= cap
end

local function propose(fromTag, toTag, offer, request)
	if type(fromTag) ~= "string" or type(toTag) ~= "string" or fromTag == toTag then return nil end
	if type(offer) ~= "table" or type(request) ~= "table" then return nil end
	if not isKnownGood(offer.goodId) or not isKnownGood(request.goodId) then return nil end
	if type(offer.amount) ~= "number" or offer.amount <= 0 then return nil end
	if type(request.amount) ~= "number" or request.amount <= 0 then return nil end
	if not ctx.WorldState.getCountry(fromTag) or not ctx.WorldState.getCountry(toTag) then return nil end
	if not withinPriceCap(offer, request) then return nil end

	local id = allocId()
	local now = ctx.TickScheduler.getSimTime()
	local record = {
		id = id,
		fromTag = fromTag,
		toTag = toTag,
		offer = { goodId = offer.goodId, amount = offer.amount },
		request = { goodId = request.goodId, amount = request.amount },
		state = "Proposed",
		createdAt = now,
		expiresAt = now + PROPOSAL_TTL_SECONDS,
	}
	trades[id] = record
	ctx.WorldState.setTradeRoute(id, record)
	ctx.EventBus.publish(ctx.Channels.TradeRouteEstablished, { tradeId = id, trade = record })
	return id
end

local function accept(tradeId, accepterTag)
	local record = trades[tradeId]
	if not record or record.state ~= "Proposed" then return false end
	if record.toTag ~= accepterTag then return false end

	local from = ctx.WorldState.getCountry(record.fromTag)
	local to = ctx.WorldState.getCountry(record.toTag)
	if not from or not to then return false end

	local offerValue = valueOf(record.offer.goodId, record.offer.amount)
	local requestValue = valueOf(record.request.goodId, record.request.amount)
	if not offerValue or not requestValue then return false end

	if (from.treasury or 0) < offerValue then return false end
	if (to.treasury or 0) < requestValue then return false end

	from.treasury = (from.treasury or 0) - offerValue + requestValue
	to.treasury = (to.treasury or 0) - requestValue + offerValue
	ctx.WorldState.setCountry(record.fromTag, from)
	ctx.WorldState.setCountry(record.toTag, to)

	record.state = "Completed"
	record.completedAt = ctx.TickScheduler.getSimTime()
	ctx.WorldState.setTradeRoute(tradeId, record)

	ctx.EventBus.publish(ctx.Channels.TradeRouteCompleted, {
		tradeId = tradeId,
		trade = record,
		offerValue = offerValue,
		requestValue = requestValue,
	})
	return true
end

local function cancel(tradeId, cancellerTag)
	local record = trades[tradeId]
	if not record or record.state ~= "Proposed" then return false end
	if record.fromTag ~= cancellerTag and record.toTag ~= cancellerTag then return false end
	record.state = "Cancelled"
	record.cancelledAt = ctx.TickScheduler.getSimTime()
	ctx.WorldState.setTradeRoute(tradeId, record)
	ctx.EventBus.publish(ctx.Channels.TradeRouteCancelled, {
		tradeId = tradeId, trade = record, cancellerTag = cancellerTag,
	})
	return true
end

local function sweepExpired()
	local now = ctx.TickScheduler.getSimTime()
	for id, record in trades do
		if record.state == "Proposed" and record.expiresAt and now >= record.expiresAt then
			record.state = "Expired"
			record.cancelledAt = now
			ctx.WorldState.setTradeRoute(id, record)
			ctx.EventBus.publish(ctx.Channels.TradeRouteExpired, { tradeId = id, trade = record })
		end
	end
end

function TradeSystem.register(context)
	ctx = context
	ctx.TradeSystem = {
		propose = propose,
		accept = accept,
		cancel = cancel,
		get = function(id) return trades[id] end,
	}
	for k, v in pairs(ctx.TradeSystem) do TradeSystem[k] = v end
	ctx.TickScheduler.register({
		id = "TradeSystem",
		priority = 30,
		updateIntervalSeconds = SWEEP_INTERVAL_SECONDS,
		update = sweepExpired,
	})
end

return TradeSystem
