local EventBus = {}

local subscribers = {}
local queue = {}
local queueHead = 1
local queueTail = 0
local draining = false
local maxDrainIterations = 4096
local handlerIdCounter = 0

local function ensureChannel(channel)
	local list = subscribers[channel]
	if not list then
		list = { handlers = {}, count = 0 }
		subscribers[channel] = list
	end
	return list
end

function EventBus.subscribe(channel, handler)
	assert(type(channel) == "string" and channel ~= "", "EventBus.subscribe: channel must be non-empty string")
	assert(type(handler) == "function", "EventBus.subscribe: handler must be function")
	local list = ensureChannel(channel)
	handlerIdCounter += 1
	local id = handlerIdCounter
	list.handlers[id] = handler
	list.count += 1
	return function()
		local targetList = subscribers[channel]
		if not targetList then return end
		if targetList.handlers[id] then
			targetList.handlers[id] = nil
			targetList.count -= 1
			if targetList.count == 0 then
				subscribers[channel] = nil
			end
		end
	end
end

function EventBus.publish(channel, payload)
	assert(type(channel) == "string" and channel ~= "", "EventBus.publish: channel must be non-empty string")
	local list = subscribers[channel]
	if not list or list.count == 0 then return end
	queueTail += 1
	queue[queueTail] = { channel = channel, payload = payload or {} }
	if draining then return end
	draining = true
	local processed = 0
	while queueHead <= queueTail do
		processed += 1
		if processed > maxDrainIterations then
			queueHead = 1
			queueTail = 0
			draining = false
			error("EventBus: drain iteration cap hit, possible event loop on '" .. channel .. "'")
		end
		local entry = queue[queueHead]
		queue[queueHead] = nil
		queueHead += 1
		local entryList = subscribers[entry.channel]
		if entryList then
			for _, handler in entryList.handlers do
				local ok, err = pcall(handler, entry.payload)
				if not ok then
					warn(string.format("[EventBus] handler for '%s' failed: %s", entry.channel, tostring(err)))
				end
			end
		end
	end
	queueHead = 1
	queueTail = 0
	draining = false
end

function EventBus.publishImmediate(channel, payload)
	local list = subscribers[channel]
	if not list or list.count == 0 then return end
	for _, handler in list.handlers do
		local ok, err = pcall(handler, payload or {})
		if not ok then
			warn(string.format("[EventBus] immediate handler for '%s' failed: %s", channel, tostring(err)))
		end
	end
end

function EventBus.subscriberCount(channel)
	local list = subscribers[channel]
	return list and list.count or 0
end

function EventBus.clear(channel)
	if channel then
		subscribers[channel] = nil
	else
		subscribers = {}
	end
end

return EventBus
