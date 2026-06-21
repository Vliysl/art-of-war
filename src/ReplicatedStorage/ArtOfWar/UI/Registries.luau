local ArtOfWar = script.Parent.Parent
local Data = ArtOfWar:FindFirstChild("Data")

local cache = {}

local function load(name)
	if cache[name] ~= nil then
		return cache[name] or nil
	end
	local mod = Data and Data:FindFirstChild(name)
	if not mod or not mod:IsA("ModuleScript") then
		cache[name] = false
		return nil
	end
	local ok, value = pcall(require, mod)
	if not ok then
		warn("[AoW Registries] failed to load '" .. name .. "': " .. tostring(value))
	end
	cache[name] = (ok and value) or false
	return cache[name] or nil
end

local Registries = {}

function Registries.get(name)
	return load(name)
end

return setmetatable(Registries, {
	__index = function(_, key)
		return load(key)
	end,
})
