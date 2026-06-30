-- RenderDistanceController (client)
-- Hides map tiles whose HORIZONTAL (XZ) distance from the camera's ground focus exceeds the player's
-- render-distance setting. XZ-only is deliberate: a prior attempt measured 3D distance, which includes
-- the camera's zoom height (Y), so zooming out culled everything. The camera (CameraController.wrapX)
-- and the map already work in XZ; this matches.
--
-- Owns ONLY the main ArtOfWarMap.Provinces (+ Sea) transparency. The wraps are left to MapWrapVisibility
-- (it toggles them by mode; double-ownership would conflict, and they only show near the seam).
-- Improves render/FPS (toggles Transparency/CanQuery); does NOT free RAM (tiles stay loaded).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local modules = aow:WaitForChild("Modules")
local WorldConstants = require(aow:WaitForChild("Shared"):WaitForChild("WorldConstants"))
local CameraController = require(modules:WaitForChild("CameraController"))
local Platform = require(modules:WaitForChild("Platform"))
local MapModeController = require(modules:WaitForChild("MapModeController"))

local RenderDistanceController = {}

local ATTR = "RenderDistance"
local BASE_TRANSPARENCY_ATTR = "_AoWCullBaseTransparency"
local BASE_CANQUERY_ATTR = "_AoWCullBaseCanQuery"

local MAX = WorldConstants.RenderDistanceMax
-- Recompute only when the focus has moved at least this far (squared), to avoid a full scan every frame.
local FOCUS_MOVE_THRESHOLD2 = 24 * 24
-- Cap state changes per frame so a big reclassification (slider jump / mode switch) spreads over frames.
local FLIP_BUDGET = 800

local localPlayer = Players.LocalPlayer

local tiles = nil -- array of { part = BasePart, x = number, z = number }
local culled = nil -- [part] = bool (currently hidden)
local started = false
local dirty = true -- force a full recompute on the next pass
local lastFocusX, lastFocusZ = nil, nil

local function rememberPart(part)
	if part:GetAttribute(BASE_TRANSPARENCY_ATTR) == nil then
		part:SetAttribute(BASE_TRANSPARENCY_ATTR, part.Transparency)
		part:SetAttribute(BASE_CANQUERY_ATTR, part.CanQuery)
	end
end

local function collectTiles()
	local map = workspace:FindFirstChild("ArtOfWarMap")
	if not map then
		return nil
	end
	local list = {}
	local function addFolder(folder)
		if not folder then
			return
		end
		for _, p in folder:GetChildren() do
			if p:IsA("BasePart") then
				rememberPart(p)
				list[#list + 1] = { part = p, x = p.Position.X, z = p.Position.Z }
			end
		end
	end
	addFolder(map:FindFirstChild("Provinces"))
	addFolder(map:FindFirstChild("Sea"))
	if #list == 0 then
		return nil
	end
	return list
end

local function restore(part)
	local baseT = part:GetAttribute(BASE_TRANSPARENCY_ATTR)
	local baseQ = part:GetAttribute(BASE_CANQUERY_ATTR)
	part.Transparency = type(baseT) == "number" and baseT or 0
	part.CanQuery = baseQ == nil and true or baseQ
end

local function hide(part)
	part.Transparency = 1
	part.CanQuery = false
end

local function getDistance()
	local v = localPlayer:GetAttribute(ATTR)
	if type(v) ~= "number" then
		return MAX
	end
	return v
end

-- The cull center, in XZ. Command mode: the camera's ground target. Field mode: the local character
-- (the camera follows it; cull around where the player actually is).
local function getFocusXZ()
	if MapModeController.current() == "field" then
		local char = localPlayer.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp then
			return hrp.Position.X, hrp.Position.Z
		end
	end
	local pos = CameraController.getPosition()
	if pos then
		return pos.X, pos.Z
	end
	return 0, 0
end

-- One (possibly partial, flip-budgeted) reclassification pass.
local function runPass(dist, fx, fz)
	local noCull = dist >= MAX
	local r2 = dist * dist
	local flips = 0
	local budgetHit = false
	for _, t in tiles do
		local desiredVisible
		if noCull then
			desiredVisible = true
		else
			local dx, dz = fx - t.x, fz - t.z
			desiredVisible = (dx * dx + dz * dz) <= r2
		end
		local isCulled = culled[t.part]
		if desiredVisible and isCulled then
			restore(t.part)
			culled[t.part] = false
			flips += 1
		elseif (not desiredVisible) and (not isCulled) then
			hide(t.part)
			culled[t.part] = true
			flips += 1
		end
		if flips >= FLIP_BUDGET then
			budgetHit = true
			break
		end
	end
	if budgetHit then
		dirty = true -- more to flip next frame; keep recomputing
	else
		dirty = false
		lastFocusX, lastFocusZ = fx, fz
	end
end

local function pass()
	if not tiles then
		tiles = collectTiles()
		if not tiles then
			return -- map not ready yet; retry next frame
		end
		culled = {}
		for _, t in tiles do
			culled[t.part] = false
		end
	end

	local dist = getDistance()

	if not dirty then
		-- Idle: nothing pending. At Max there's nothing to do; otherwise re-scan only once the focus moves.
		if dist >= MAX then
			return
		end
		local fx, fz = getFocusXZ()
		if lastFocusX then
			local dx, dz = fx - lastFocusX, fz - lastFocusZ
			if dx * dx + dz * dz < FOCUS_MOVE_THRESHOLD2 then
				return
			end
		end
		runPass(dist, fx, fz)
		return
	end

	-- dirty: forced full recompute (distance changed, mode changed, or first run)
	local fx, fz = getFocusXZ()
	runPass(dist, fx, fz)
end

function RenderDistanceController.init()
	if started then
		return
	end
	started = true
	localPlayer = Players.LocalPlayer

	-- Per-device default on first join (no DataStore persistence; resets each session).
	if localPlayer:GetAttribute(ATTR) == nil then
		local default
		if Platform.isMobile then
			default = WorldConstants.RenderDistanceDefaultMobile
		elseif Platform.isTablet then
			default = WorldConstants.RenderDistanceDefaultTablet
		else
			default = WorldConstants.RenderDistanceDefaultDesktop
		end
		localPlayer:SetAttribute(ATTR, default)
	end

	localPlayer:GetAttributeChangedSignal(ATTR):Connect(function()
		dirty = true
	end)
	MapModeController.onChange(function()
		dirty = true
	end)

	RunService.Heartbeat:Connect(pass)
end

return RenderDistanceController
