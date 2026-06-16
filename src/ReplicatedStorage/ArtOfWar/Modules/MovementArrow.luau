-- MovementArrow: HOI4-style on-map move arrows. For each of the local player's
-- armies with an active server movement, draws a world-space arrow from the origin
-- province to the destination that FILLS as the (server-timed, 7-tick) move
-- progresses -- progress = (SimClock.now() - startedAt) / (completesAt - startedAt),
-- so it respects pause/speed. Remaining queued legs (movementPath.steps) are drawn
-- faint. The army token itself waits at the origin (ArmyView) and hops on arrival.
--
-- Pure presentation: it only reads replicated state. Fails soft if anything is
-- missing (no map folder, no SimClock anchor) -- never errors the client.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local ClientStateCache = require(aow:WaitForChild("Modules"):WaitForChild("ClientStateCache"))
local SimClock = require(aow:WaitForChild("Modules"):WaitForChild("SimClock"))

local MovementArrow = {}

local LIFT = 6
local TRACK_THICK = 1.1
local FILL_THICK = 2.4
local COLOR_FILL = Color3.fromRGB(250, 222, 138)    -- bright gold (filled progress)
local COLOR_TRACK = Color3.fromRGB(150, 116, 56)    -- dim gold (unfilled track)
local COLOR_PLANNED = Color3.fromRGB(120, 150, 190) -- faint blue (queued legs)

local mapFolder, provincesFolder, arrowsFolder
local conn
local arrows = {}        -- [armyId] = { sig = string, fill = Part, statics = { Part, ... } }
local centerCache = {}

local function ensureFolders()
	if arrowsFolder and arrowsFolder.Parent then return true end
	mapFolder = workspace:FindFirstChild("ArtOfWarMap")
	if not mapFolder then return false end
	provincesFolder = mapFolder:FindFirstChild("Provinces")
	if not provincesFolder then return false end
	arrowsFolder = mapFolder:FindFirstChild("MoveArrows")
	if not arrowsFolder then
		arrowsFolder = Instance.new("Folder")
		arrowsFolder.Name = "MoveArrows"
		arrowsFolder.Parent = mapFolder
	end
	return true
end

local function provinceCenter(pid)
	if pid == nil then return nil end
	local cached = centerCache[pid]
	if cached then return cached end
	if not provincesFolder then return nil end
	for _, part in provincesFolder:GetChildren() do
		if part:IsA("BasePart") and part:GetAttribute("province_id") == pid then
			local c = Vector3.new(part.Position.X, part.Position.Y + part.Size.Y * 0.5 + LIFT, part.Position.Z)
			centerCache[pid] = c
			return c
		end
	end
	return nil
end

local function seg(a, b, color, thick, transparency)
	local dist = (b - a).Magnitude
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Massless = true
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = transparency or 0.1
	p.Size = Vector3.new(thick, thick, math.max(dist, 0.05))
	p.CFrame = CFrame.lookAt((a + b) * 0.5, b)
	p.Parent = arrowsFolder
	return p
end

local function marker(at, color, size)
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Massless = true
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = 0.05
	p.Size = Vector3.new(size, size, size)
	p.CFrame = CFrame.new(at)
	p.Parent = arrowsFolder
	return p
end

local function isLocallyOwned(ownerTag)
	local lp = Players.LocalPlayer
	if not ownerTag or not lp then return false end
	local country = ClientStateCache.getCountry(ownerTag)
	return country ~= nil and country.claimedBy == lp.UserId
end

local function routeSig(army)
	local mv = army.movement
	local s = tostring(mv.fromProvinceId) .. ">" .. tostring(mv.toProvinceId)
	local mp = army.movementPath
	if mp and mp.steps then
		for _, id in ipairs(mp.steps) do s = s .. "," .. tostring(id) end
	end
	return s
end

local function destroyArrow(armyId)
	local a = arrows[armyId]
	if not a then return end
	if a.fill and a.fill.Parent then a.fill:Destroy() end
	for _, p in ipairs(a.statics) do
		if p.Parent then p:Destroy() end
	end
	arrows[armyId] = nil
end

-- Build the static parts (track + destination marker + queued legs) for the route.
local function buildStatics(army, fromPos, toPos)
	local statics = {}
	statics[#statics + 1] = seg(fromPos, toPos, COLOR_TRACK, TRACK_THICK, 0.35)
	statics[#statics + 1] = marker(toPos, COLOR_FILL, 4)
	-- queued legs (multi-tile order): dest -> step2 -> step3 ...
	local mp = army.movementPath
	if mp and mp.steps and #mp.steps > 0 then
		local prev = toPos
		for _, id in ipairs(mp.steps) do
			local c = provinceCenter(id)
			if c then
				statics[#statics + 1] = seg(prev, c, COLOR_PLANNED, TRACK_THICK, 0.5)
				statics[#statics + 1] = marker(c, COLOR_PLANNED, 2.6)
				prev = c
			end
		end
	end
	return statics
end

local function updateArrow(armyId, army, now)
	local mv = army.movement
	local fromPos = provinceCenter(mv.fromProvinceId)
	local toPos = provinceCenter(mv.toProvinceId)
	if not fromPos or not toPos then
		destroyArrow(armyId)
		return
	end

	local sig = routeSig(army)
	local a = arrows[armyId]
	if not a or a.sig ~= sig then
		destroyArrow(armyId)
		a = { sig = sig, statics = buildStatics(army, fromPos, toPos), fill = nil }
		arrows[armyId] = a
	end

	-- progress 0..1 from the sim clock (falls back to 0 until a TimeSync anchor exists)
	local progress = 0
	local started = mv.startedAt or 0
	local completes = mv.completesAt or 0
	if now and completes > started then
		progress = math.clamp((now - started) / (completes - started), 0, 1)
	end

	local frontPos = fromPos:Lerp(toPos, progress)
	if a.fill and a.fill.Parent then
		local dist = (frontPos - fromPos).Magnitude
		a.fill.Size = Vector3.new(FILL_THICK, FILL_THICK, math.max(dist, 0.05))
		a.fill.CFrame = CFrame.lookAt((fromPos + frontPos) * 0.5, frontPos)
	else
		a.fill = seg(fromPos, frontPos, COLOR_FILL, FILL_THICK, 0.05)
	end
end

function MovementArrow.init()
	if conn then return end
	conn = RunService.RenderStepped:Connect(function()
		if not ensureFolders() then return end
		local now = SimClock.now()
		local active = {}
		for armyId, army in pairs(ClientStateCache.allArmies()) do
			if army.movement and isLocallyOwned(army.ownerTag) then
				active[armyId] = true
				updateArrow(armyId, army, now)
			end
		end
		for armyId in pairs(arrows) do
			if not active[armyId] then destroyArrow(armyId) end
		end
	end)
end

-- Optimistically remove an army's arrow immediately (e.g. on a cancel order),
-- before the cleared movement replicates back ~1.5s later.
function MovementArrow.clearArmy(armyId)
	destroyArrow(armyId)
end

function MovementArrow.destroy()
	if conn then conn:Disconnect(); conn = nil end
	for armyId in pairs(arrows) do destroyArrow(armyId) end
	if arrowsFolder and arrowsFolder.Parent then arrowsFolder:Destroy() end
	arrowsFolder = nil
	table.clear(centerCache)
end

return MovementArrow
