-- WorldEventLog — a tiny client-side ring buffer of recent world events (formations / releases), so players
-- who dismissed or missed a super-event banner can still review what happened. Standalone (no Hud dependency)
-- so both Hud.showSuperEvent (which appends) and the Nation screen (which renders) can use it cycle-free.

local WorldEventLog = {}

local events = {}
local MAX = 20

-- Append a super-event payload (newest first), capped. Keeps only the display-relevant fields.
function WorldEventLog.add(payload)
	if type(payload) ~= "table" then
		return
	end
	table.insert(events, 1, {
		title = payload.title,
		body = payload.body,
		tag = payload.tag,
		imageId = payload.imageId,
		color = payload.color,
	})
	while #events > MAX do
		events[#events] = nil
	end
end

-- Newest-first list of recent events. Callers must not mutate the returned table.
function WorldEventLog.getAll()
	return events
end

return WorldEventLog
