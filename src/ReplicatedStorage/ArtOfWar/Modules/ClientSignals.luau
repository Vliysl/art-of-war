-- ClientSignals -- a tiny client-only signal bus for cross-script UI events that should NOT round-trip the
-- server (e.g. the Settings "Open Data Editor" button asking the Data Editor script to open its window).
--
-- Each named signal is a lazily-created BindableEvent. Because ModuleScript results are cached per client
-- environment, every client script that requires this module shares the SAME BindableEvent per name, so one
-- script can :Fire() and another can connect to .Event. Not replicated; do not use for client<->server.
local ClientSignals = {}

local events = {}

function ClientSignals.get(name)
	assert(type(name) == "string" and name ~= "", "ClientSignals.get expects a non-empty string name")
	local ev = events[name]
	if not ev then
		ev = Instance.new("BindableEvent")
		ev.Name = "ClientSignal_" .. name
		events[name] = ev
	end
	return ev
end

-- Convenience: fire a named signal (no-op-safe).
function ClientSignals.fire(name, ...)
	ClientSignals.get(name):Fire(...)
end

-- Convenience: connect a handler to a named signal; returns the RBXScriptConnection.
function ClientSignals.connect(name, handler)
	return ClientSignals.get(name).Event:Connect(handler)
end

return ClientSignals
