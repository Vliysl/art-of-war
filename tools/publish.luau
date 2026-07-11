local roblox = require("@lune/roblox")
local fs = require("@lune/fs")
local net = require("@lune/net")
local serde = require("@lune/serde")
local process = require("@lune/process")

local Instance = roblox.Instance

local basePath = nil
local dryRun = false
local obfuscate = false
for _, arg in ipairs(process.args) do
	if arg == "--dry-run" then
		dryRun = true
	elseif arg == "--obfuscate" then
		obfuscate = true
	elseif arg ~= "--" and not basePath then
		basePath = arg
	end
end
if not basePath then
	error("usage: lune run tools/publish -- <base.rbxl> [--dry-run] [--obfuscate]")
end

-- With --obfuscate, stage + transform the client subtrees first and overlay from the
-- staged tree instead of src/ (server code is staged verbatim, so the snapshot is coherent).
local srcRoot = "src"
if obfuscate then
	srcRoot = require("./obfuscate")
end

local place = roblox.deserializePlace(fs.readFile(basePath))

local SUFFIXES = { ".server.luau", ".client.luau", ".luau" }
local CLASS = {
	[".server.luau"] = "Script",
	[".client.luau"] = "LocalScript",
	[".luau"] = "ModuleScript",
}

local function classAndName(filename)
	for _, suffix in ipairs(SUFFIXES) do
		if #filename > #suffix and filename:sub(-#suffix) == suffix then
			return CLASS[suffix], filename:sub(1, #filename - #suffix)
		end
	end
	return nil, nil
end

local count = 0

local function overlay(dir, parent)
	for _, entry in ipairs(fs.readDir(dir)) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			local child = parent:FindFirstChild(entry)
			if not child then
				child = Instance.new("Folder")
				child.Name = entry
				child.Parent = parent
			end
			overlay(path, child)
		elseif entry:sub(-10) ~= ".meta.json" then
			local class, name = classAndName(entry)
			if class then
				local inst = parent:FindFirstChild(name)
				if inst and inst.ClassName ~= class then
					inst:Destroy()
					inst = nil
				end
				if not inst then
					inst = Instance.new(class)
					inst.Name = name
					inst.Parent = parent
				end
				inst.Source = fs.readFile(path)
				count += 1
			end
		end
	end
end

for _, serviceName in ipairs(fs.readDir(srcRoot)) do
	if fs.isDir(srcRoot .. "/" .. serviceName) then
		overlay(srcRoot .. "/" .. serviceName, place:GetService(serviceName))
	end
end

print(string.format("overlaid %d scripts onto the base place", count))

local bytes = roblox.serializePlace(place)
if not fs.isDir("build") then
	fs.writeDir("build")
end
fs.writeFile("build/publish.rbxl", bytes)
print(string.format("built build/publish.rbxl (%d bytes)", #bytes))

if dryRun then
	print("dry-run complete; nothing uploaded")
	return
end

local key = process.env.ROBLOX_OPEN_CLOUD_KEY
if not key or #key == 0 then
	error("ROBLOX_OPEN_CLOUD_KEY is not set")
end

local config = serde.decode("json", fs.readFile("tools/publish.config.json"))
for _, target in ipairs(config.targets) do
	if not target.placeId or target.placeId == 0 then
		print(string.format("%s: placeId not configured, skipping", target.label))
	else
		local url = string.format(
			"https://apis.roblox.com/universes/v1/%s/places/%s/versions?versionType=Published",
			tostring(target.universeId),
			tostring(target.placeId)
		)
		local response = net.request({
			url = url,
			method = "POST",
			headers = {
				["x-api-key"] = key,
				["Content-Type"] = "application/octet-stream",
			},
			body = bytes,
		})
		print(string.format("%s -> HTTP %d  %s", target.label, response.statusCode, response.body:sub(1, 200)))
	end
end
