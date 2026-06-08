local roblox = require("@lune/roblox")
local fs = require("@lune/fs")
local process = require("@lune/process")

local placePath = process.args[1]
if not placePath then
	error("usage: lune run tools/extract -- <place.rbxl>")
end

local place = roblox.deserializePlace(fs.readFile(placePath))

local SERVICES = {
	"ServerScriptService",
	"ReplicatedStorage",
	"ReplicatedFirst",
	"StarterPlayer",
	"StarterGui",
	"ServerStorage",
}

local EXCLUDE = {
	["ServerStorage/Dev/RelayConfig"] = true,
	["ReplicatedStorage/Fonts"] = true,
}

local written = {}
local count = 0

local function suffix(inst)
	if inst.ClassName == "Script" then
		return ".server.luau"
	elseif inst.ClassName == "LocalScript" then
		return ".client.luau"
	end
	return ".luau"
end

local function initName(inst)
	if inst.ClassName == "Script" then
		return "init.server.luau"
	elseif inst.ClassName == "LocalScript" then
		return "init.client.luau"
	end
	return "init.luau"
end

local function hasScripts(inst)
	if inst:IsA("LuaSourceContainer") then
		return true
	end
	for _, descendant in ipairs(inst:GetDescendants()) do
		if descendant:IsA("LuaSourceContainer") then
			return true
		end
	end
	return false
end

local function emit(filePath, source)
	if written[filePath] then
		error("name collision at " .. filePath)
	end
	written[filePath] = true
	fs.writeFile(filePath, source)
	count += 1
end

local function write(inst, dir, key)
	if EXCLUDE[key] then
		return
	end
	if inst:IsA("LuaSourceContainer") then
		local children = inst:GetChildren()
		if #children == 0 then
			emit(dir .. "/" .. inst.Name .. suffix(inst), inst.Source)
		else
			local folder = dir .. "/" .. inst.Name
			fs.writeDir(folder)
			emit(folder .. "/" .. initName(inst), inst.Source)
			for _, child in ipairs(children) do
				if hasScripts(child) then
					write(child, folder, key .. "/" .. child.Name)
				end
			end
		end
	else
		local folder = dir .. "/" .. inst.Name
		fs.writeDir(folder)
		for _, child in ipairs(inst:GetChildren()) do
			if hasScripts(child) then
				write(child, folder, key .. "/" .. child.Name)
			end
		end
	end
end

local function cleanLuau(dir)
	for _, entry in ipairs(fs.readDir(dir)) do
		local entryPath = dir .. "/" .. entry
		if fs.isDir(entryPath) then
			cleanLuau(entryPath)
		elseif string.sub(entry, -5) == ".luau" then
			fs.removeFile(entryPath)
		end
	end
end

if fs.isDir("src") then
	cleanLuau("src")
else
	fs.writeDir("src")
end

for _, serviceName in ipairs(SERVICES) do
	local service = place:GetService(serviceName)
	local children = service:GetChildren()
	local relevant = false
	for _, child in ipairs(children) do
		if not EXCLUDE[serviceName .. "/" .. child.Name] and hasScripts(child) then
			relevant = true
			break
		end
	end
	if relevant then
		fs.writeDir("src/" .. serviceName)
		for _, child in ipairs(children) do
			if hasScripts(child) then
				write(child, "src/" .. serviceName, serviceName .. "/" .. child.Name)
			end
		end
	end
end

print(string.format("extracted %d script files to src/", count))
