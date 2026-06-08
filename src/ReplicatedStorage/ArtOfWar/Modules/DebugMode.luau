local DebugMode = {}

local Players = game:GetService("Players")
local localPlayer = Players.LocalPlayer

local enabled = false
local listeners = {}

local function fire()
	for _, fn in ipairs(listeners) do
		local ok, err = pcall(fn, enabled)
		if not ok then warn("[DebugMode] listener errored: " .. tostring(err)) end
	end
end

function DebugMode.isEnabled()
	return enabled
end

function DebugMode.isAdmin()
	return localPlayer ~= nil and localPlayer:GetAttribute("IsAdmin") == true
end

function DebugMode.canDebug()
	return enabled and DebugMode.isAdmin()
end

function DebugMode.setEnabled(value)
	value = value == true
	if enabled == value then return enabled end
	enabled = value
	fire()
	return enabled
end

function DebugMode.toggle()
	return DebugMode.setEnabled(not enabled)
end

function DebugMode.onChange(fn)
	if type(fn) ~= "function" then return function() end end
	table.insert(listeners, fn)
	return function()
		for index, listener in ipairs(listeners) do
			if listener == fn then
				table.remove(listeners, index)
				return
			end
		end
	end
end

function DebugMode.formatCountry(tag, country)
	if tag == nil or tag == "" or tag == "NONE" then
		return "Unclaimed"
	end
	local displayName = country and country.displayName or tag
	if DebugMode.canDebug() then
		return string.format("%s (%s)", displayName, tag)
	end
	return displayName
end

function DebugMode.formatCores(cores, lookup)
	if type(cores) ~= "table" or #cores == 0 then return "None" end
	local parts = {}
	for _, tag in ipairs(cores) do
		local country = lookup and lookup(tag) or nil
		table.insert(parts, DebugMode.formatCountry(tag, country))
	end
	return table.concat(parts, ", ")
end

return DebugMode
