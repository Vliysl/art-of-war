local InputGuard = {}

local blockers = {}

function InputGuard.register(name, predicate)
	assert(type(name) == "string" and name ~= "", "name required")
	assert(type(predicate) == "function", "predicate required")
	blockers[name] = predicate
end

function InputGuard.unregister(name)
	blockers[name] = nil
end

function InputGuard.isCameraBlocked()
	for _, predicate in pairs(blockers) do
		local ok, blocked = pcall(predicate)
		if ok and blocked then return true end
	end
	return false
end

return InputGuard
