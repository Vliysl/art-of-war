local MapWrapVisibility = {}

local BASE_TRANSPARENCY_ATTR = "_AoWWrapBaseTransparency"
local BASE_CANCOLLIDE_ATTR = "_AoWWrapBaseCanCollide"
local BASE_CANQUERY_ATTR = "_AoWWrapBaseCanQuery"
local BASE_DECAL_TRANSPARENCY_ATTR = "_AoWWrapBaseDecalTransparency"

local WRAP_COMMAND_TRANSPARENCY = 0.6

local WRAP_PATHS = {
	{ "LeftWrap" },
	{ "RightWrap" },
	{ "MapTextures", "Left" },
	{ "MapTextures", "Right" },
}

local cache = nil
local currentMode = nil

local function findRoot(map, path)
	local node = map
	for _, name in path do
		if not node then return nil end
		node = node:FindFirstChild(name)
	end
	return node
end

local function rememberPart(part)
	if part:GetAttribute(BASE_TRANSPARENCY_ATTR) == nil then
		part:SetAttribute(BASE_TRANSPARENCY_ATTR, part.Transparency)
		part:SetAttribute(BASE_CANCOLLIDE_ATTR, part.CanCollide)
		part:SetAttribute(BASE_CANQUERY_ATTR, part.CanQuery)
	end
end

local function rememberDecal(decal)
	if decal:GetAttribute(BASE_DECAL_TRANSPARENCY_ATTR) == nil then
		decal:SetAttribute(BASE_DECAL_TRANSPARENCY_ATTR, decal.Transparency)
	end
end

local function collect()
	if cache and (#cache.parts > 0 or #cache.decals > 0) then return cache end
	local map = workspace:FindFirstChild("ArtOfWarMap")
	if not map then return { parts = {}, decals = {} } end
	local parts = {}
	local decals = {}
	for _, path in WRAP_PATHS do
		local root = findRoot(map, path)
		if root then
			for _, descendant in root:GetDescendants() do
				if descendant:IsA("BasePart") then
					rememberPart(descendant)
					table.insert(parts, descendant)
				elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
					rememberDecal(descendant)
					table.insert(decals, descendant)
				end
			end
		end
	end
	if #parts > 0 or #decals > 0 then
		cache = { parts = parts, decals = decals }
	end
	return cache or { parts = {}, decals = {} }
end

local function applyField(bundle)
	for _, part in bundle.parts do
		part.Transparency = 1
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
	end
	for _, decal in bundle.decals do
		decal.Transparency = 1
	end
end

local function applyCommand(bundle)
	for _, part in bundle.parts do
		local baseT = part:GetAttribute(BASE_TRANSPARENCY_ATTR)
		local baseC = part:GetAttribute(BASE_CANCOLLIDE_ATTR)
		local baseQ = part:GetAttribute(BASE_CANQUERY_ATTR)
		local base = type(baseT) == "number" and baseT or 0
		part.Transparency = math.max(base, WRAP_COMMAND_TRANSPARENCY)
		part.CanCollide = baseC == nil and true or baseC
		part.CanQuery = baseQ == nil and true or baseQ
	end
	for _, decal in bundle.decals do
		local baseT = decal:GetAttribute(BASE_DECAL_TRANSPARENCY_ATTR)
		local base = type(baseT) == "number" and baseT or 0
		decal.Transparency = math.max(base, WRAP_COMMAND_TRANSPARENCY)
	end
end

local function apply(mode, bundle)
	if mode == "field" then applyField(bundle) else applyCommand(bundle) end
end

function MapWrapVisibility.setMode(mode)
	if mode ~= "field" and mode ~= "command" then return end
	currentMode = mode
	local bundle = collect()
	if #bundle.parts > 0 or #bundle.decals > 0 then
		apply(mode, bundle)
		return
	end
	task.spawn(function()
		local deadline = os.clock() + 30
		while os.clock() < deadline and currentMode == mode do
			task.wait(0.35)
			local retry = collect()
			if #retry.parts > 0 or #retry.decals > 0 then
				if currentMode == mode then apply(mode, retry) end
				return
			end
		end
	end)
end

function MapWrapVisibility.current()
	return currentMode
end

function MapWrapVisibility.refresh()
	cache = nil
	if not currentMode then return end
	local bundle = collect()
	if #bundle.parts > 0 or #bundle.decals > 0 then apply(currentMode, bundle) end
end

return MapWrapVisibility
