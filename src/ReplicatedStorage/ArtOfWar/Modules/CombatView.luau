-- Worldspace combat & siege overlays. Reads the synced ClientStateCache only —
-- battles from allBattles(), sieges from each province's .occupation record — and
-- floats a billboard meter above the contested province. No server authority here;
-- this is a pure read-through visualization, mirroring ArmyView's reconcile pattern.

local CombatView = {}

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local ClientStateCache = require(aow:WaitForChild("Modules"):WaitForChild("ClientStateCache"))
local WorldConstants = require(aow:WaitForChild("Shared"):WaitForChild("WorldConstants"))
local Countries = require(aow:WaitForChild("Data"):WaitForChild("Countries"))

local PLATE_BG  = Color3.fromRGB(18, 12, 8)
local HAIRLINE  = Color3.fromRGB(60, 40, 22)
local CREAM     = Color3.fromRGB(234, 216, 176)
local MUTED     = Color3.fromRGB(206, 180, 120)
local TRACK     = Color3.fromRGB(44, 32, 18)
local FALLBACK  = Color3.fromRGB(150, 150, 150)
local SWORDS    = Color3.fromRGB(224, 120, 96)
local GOOD      = Color3.fromRGB(75, 183, 52)   -- local player winning
local BAD       = Color3.fromRGB(190, 36, 26)   -- local player losing
local NEUTRAL   = Color3.fromRGB(218, 168, 84)  -- gold (uninvolved / even)

local LIFT = 52
local REQUIRED = WorldConstants.OccupationProgressRequired or 12

local markersFolder, mapFolder, provincesFolder
local battleMarkers = {}
local siegeMarkers = {}
local dirtyBattles = {}
local dirtySieges = {}
local pendingRetry = {}
local provinceCenterCache = {}
local heartbeatConn
local battleSub, provinceSub, snapshotSub
local started = false

local function ensureFolders()
	if markersFolder and markersFolder.Parent then return true end
	mapFolder = workspace:FindFirstChild("ArtOfWarMap")
	if not mapFolder then return false end
	provincesFolder = mapFolder:FindFirstChild("Provinces")
	if not provincesFolder then return false end
	markersFolder = mapFolder:FindFirstChild("CombatMarkers")
	if not markersFolder then
		markersFolder = Instance.new("Folder")
		markersFolder.Name = "CombatMarkers"
		markersFolder.Parent = mapFolder
	end
	return true
end

local function locateProvincePart(provinceId)
	if not provincesFolder then
		mapFolder = workspace:FindFirstChild("ArtOfWarMap")
		provincesFolder = mapFolder and mapFolder:FindFirstChild("Provinces")
	end
	if not provincesFolder then return nil end
	for _, part in provincesFolder:GetChildren() do
		if part:IsA("BasePart") and part:GetAttribute("province_id") == provinceId then
			return part
		end
	end
	return nil
end

local function provinceCenter(provinceId)
	local cached = provinceCenterCache[provinceId]
	if cached then return cached end
	local part = locateProvincePart(provinceId)
	if not part then return nil end
	local center = Vector3.new(part.Position.X, part.Position.Y + part.Size.Y * 0.5 + LIFT, part.Position.Z)
	provinceCenterCache[provinceId] = center
	return center
end

local function ownerColor(tag)
	local c = ClientStateCache.getCountry and ClientStateCache.getCountry(tag)
	if c and c.color then return Color3.fromRGB(c.color[1] or 150, c.color[2] or 150, c.color[3] or 150) end
	local s = tag and Countries[tag]
	if s and s.color then return Color3.fromRGB(s.color[1] or 150, s.color[2] or 150, s.color[3] or 150) end
	return FALLBACK
end

local function ownerName(tag)
	if not tag then return "?" end
	local c = ClientStateCache.getCountry and ClientStateCache.getCountry(tag)
	if c then
		local n = c.displayName or c.name
		if type(n) == "string" and n ~= "" then return n end
	end
	local s = Countries[tag]
	if s and type(s.displayName) == "string" and s.displayName ~= "" then return s.displayName end
	return tostring(tag)
end

local function sideStrength(armyIds)
	if type(armyIds) ~= "table" then return 0 end
	local total = 0
	for _, id in ipairs(armyIds) do
		local army = ClientStateCache.getArmy and ClientStateCache.getArmy(id)
		if army and army.composition then
			for _, c in pairs(army.composition) do total += c end
		end
	end
	return total
end

local function firstOwner(armyIds)
	if type(armyIds) ~= "table" then return nil end
	for _, id in ipairs(armyIds) do
		local army = ClientStateCache.getArmy and ClientStateCache.getArmy(id)
		if army and army.ownerTag then return army.ownerTag end
	end
	return nil
end

local function hasBattleAt(provinceId)
	for _, battle in pairs(ClientStateCache.allBattles()) do
		if battle and battle.provinceId == provinceId then return true end
	end
	return false
end

local function localTag()
	local lp = Players.LocalPlayer
	return lp and lp:GetAttribute("CountryTag") or nil
end

-- Where the attack comes FROM (for the bubble's position + direction arrow).
local function attackerOriginId(battle)
	local first = battle.attackerArmyIds and battle.attackerArmyIds[1]
	if first and battle.attackerOriginByArmyId and battle.attackerOriginByArmyId[first] then
		return battle.attackerOriginByArmyId[first]
	end
	if first then
		local a = ClientStateCache.getArmy and ClientStateCache.getArmy(first)
		if a and a.provinceId then return a.provinceId end
	end
	return battle.provinceId
end

-- Tide from the LOCAL player's perspective: +1 my side dominating, -1 losing.
-- Returns (perspectiveTide, role) where role is "attacker"|"defender"|"neutral".
local function playerTide(battle)
	local tide = battle.tide or 0
	local me = localTag()
	if not me then return tide, "neutral" end
	local function sideHas(ids)
		if type(ids) ~= "table" then return false end
		for _, id in ipairs(ids) do
			local a = ClientStateCache.getArmy and ClientStateCache.getArmy(id)
			if a and a.ownerTag == me then return true end
		end
		return false
	end
	if sideHas(battle.attackerArmyIds) then return tide, "attacker" end
	if sideHas(battle.defenderArmyIds) then return -tide, "defender" end
	return tide, "neutral"
end

local function txt(parent, props)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.Garamond
	l.TextColor3 = CREAM
	l.TextStrokeTransparency = 0.25
	l.TextStrokeColor3 = PLATE_BG
	for k, v in pairs(props) do l[k] = v end
	l.Parent = parent
	return l
end

local function makeAnchor(center)
	local anchor = Instance.new("Part")
	anchor.Name = "Marker"
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.Massless = true
	anchor.CastShadow = false
	anchor.Locked = true
	anchor.Position = center
	anchor.Parent = markersFolder
	return anchor
end

local function makePlate(parent, w, h)
	local bb = Instance.new("BillboardGui")
	bb.Name = "CombatBar"
	bb.Size = UDim2.fromOffset(w, h)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 0
	bb.Parent = parent

	local bg = Instance.new("Frame")
	bg.Name = "Bg"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = PLATE_BG
	bg.BackgroundTransparency = 0.15
	bg.BorderSizePixel = 0
	bg.Parent = bb

	local stroke = Instance.new("UIStroke")
	stroke.Color = HAIRLINE
	stroke.Thickness = 1
	stroke.Transparency = 0.3
	stroke.Parent = bg
	return bb, bg
end

local function buildBattleMarker(center)
	local anchor = makeAnchor(center)
	local _, bg = makePlate(anchor, 132, 50)
	bg.BackgroundTransparency = 0.1

	-- Direction chevron: rotated per-frame to point in the on-screen attack direction.
	local chevron = txt(bg, {
		Text = "\u{25B6}", TextColor3 = SWORDS, TextSize = 14, Font = Enum.Font.GothamBold,
		Size = UDim2.fromOffset(16, 14), Position = UDim2.new(0.5, 0, 0, 1), AnchorPoint = Vector2.new(0.5, 0),
		TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Center,
	})
	local leftCount = txt(bg, {
		Text = "0", TextSize = 14, Font = Enum.Font.GothamBold,
		Size = UDim2.new(0.5, -10, 0, 16), Position = UDim2.fromOffset(8, 15),
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center,
	})
	local rightCount = txt(bg, {
		Text = "0", TextSize = 14, Font = Enum.Font.GothamBold,
		Size = UDim2.new(0.5, -10, 0, 16), Position = UDim2.new(1, -8, 0, 15),
		AnchorPoint = Vector2.new(1, 0),
		TextXAlignment = Enum.TextXAlignment.Right, TextYAlignment = Enum.TextYAlignment.Center,
	})

	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, -16, 0, 9)
	track.Position = UDim2.fromOffset(8, 35)
	track.BackgroundColor3 = TRACK
	track.BorderSizePixel = 0
	track.Parent = bg
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0, 4)
	trackCorner.Parent = track

	-- Single tide bar: fills toward the local player's favour, coloured green/red.
	local fill = Instance.new("Frame")
	fill.AnchorPoint = Vector2.new(0, 0)
	fill.Position = UDim2.fromScale(0, 0)
	fill.Size = UDim2.fromScale(0.5, 1)
	fill.BorderSizePixel = 0
	fill.BackgroundColor3 = NEUTRAL
	fill.Parent = track
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = fill

	-- Centre tick marking the even point.
	local tick = Instance.new("Frame")
	tick.AnchorPoint = Vector2.new(0.5, 0.5)
	tick.Position = UDim2.fromScale(0.5, 0.5)
	tick.Size = UDim2.new(0, 1, 1, 2)
	tick.BackgroundColor3 = CREAM
	tick.BackgroundTransparency = 0.4
	tick.BorderSizePixel = 0
	tick.ZIndex = 3
	tick.Parent = track

	return { kind = "battle", anchor = anchor, chevron = chevron, leftCount = leftCount,
		rightCount = rightCount, fill = fill, sig = nil, atkWorld = nil, defWorld = nil }
end

local function buildSiegeMarker(center)
	local anchor = makeAnchor(center)
	local _, bg = makePlate(anchor, 152, 46)

	txt(bg, {
		Text = "SIEGE", TextColor3 = MUTED, TextSize = 9, Font = Enum.Font.GothamSemibold,
		Size = UDim2.new(1, -12, 0, 11), Position = UDim2.fromOffset(8, 2),
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center,
	})
	local name = txt(bg, {
		Text = "—", TextSize = 14,
		Size = UDim2.new(0.62, -8, 0, 16), Position = UDim2.fromOffset(8, 13),
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	local frac = txt(bg, {
		Text = "0 / " .. REQUIRED, TextColor3 = MUTED, TextSize = 13,
		Size = UDim2.new(0.4, -8, 0, 16), Position = UDim2.new(1, -8, 0, 13),
		AnchorPoint = Vector2.new(1, 0),
		TextXAlignment = Enum.TextXAlignment.Right, TextYAlignment = Enum.TextYAlignment.Center,
	})

	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, -16, 0, 9)
	track.Position = UDim2.fromOffset(8, 33)
	track.BackgroundColor3 = TRACK
	track.BorderSizePixel = 0
	track.Parent = bg

	local fill = Instance.new("Frame")
	fill.AnchorPoint = Vector2.new(0, 0)
	fill.Position = UDim2.fromScale(0, 0)
	fill.Size = UDim2.fromScale(0, 1)
	fill.BorderSizePixel = 0
	fill.Parent = track

	return { kind = "siege", anchor = anchor, name = name, frac = frac, fill = fill, sig = nil }
end

local function destroyMarker(marker)
	if marker and marker.anchor and marker.anchor.Parent then
		marker.anchor:Destroy()
	end
end

local function updateBattle(marker, battle)
	local attTag = firstOwner(battle.attackerArmyIds)
	local defTag = firstOwner(battle.defenderArmyIds)
	local attMen = sideStrength(battle.attackerArmyIds)
	local defMen = sideStrength(battle.defenderArmyIds)
	local pTide, role = playerTide(battle)
	local sig = string.format("%d,%d,%s,%s,%.3f,%s", attMen, defMen, tostring(attTag), tostring(defTag), pTide, role)
	if marker.sig == sig then return end
	marker.sig = sig

	marker.leftCount.Text = tostring(attMen)
	marker.leftCount.TextColor3 = ownerColor(attTag)
	marker.rightCount.Text = tostring(defMen)
	marker.rightCount.TextColor3 = ownerColor(defTag)

	-- Bar fills toward the viewer's advantage; colour green winning / red losing,
	-- gold when the local player isn't involved (or it's dead even).
	local advantage = math.clamp((pTide + 1) * 0.5, 0.04, 0.96)
	marker.fill.Size = UDim2.fromScale(advantage, 1)
	local col = NEUTRAL
	if role ~= "neutral" then
		if pTide > 0.03 then col = GOOD
		elseif pTide < -0.03 then col = BAD end
	end
	marker.fill.BackgroundColor3 = col
end

local function updateSiege(marker, occ)
	local byTag = occ.byTag
	local progress = occ.progress or 0
	-- Prefer the replicated authoritative required value; fall back to the constant only if absent.
	local required = (occ.required and occ.required > 0) and occ.required or REQUIRED
	local sig = string.format("%s,%.2f,%d", tostring(byTag), progress, required)
	if marker.sig == sig then return end
	marker.sig = sig

	marker.name.Text = ownerName(byTag)
	marker.name.TextColor3 = ownerColor(byTag)
	marker.frac.Text = string.format("%d / %d", math.floor(progress + 0.5), required)
	local f = math.clamp(required > 0 and (progress / required) or 0, 0, 1)
	marker.fill.Size = UDim2.fromScale(f, 1)
	marker.fill.BackgroundColor3 = ownerColor(byTag)
end

local function scheduleRetry(kind, id)
	local key = kind .. ":" .. tostring(id)
	if pendingRetry[key] then return end
	pendingRetry[key] = true
	task.delay(0.3, function()
		pendingRetry[key] = nil
		if kind == "battle" then dirtyBattles[id] = true else dirtySieges[id] = true end
	end)
end

local function reconcileBattle(battleId)
	local battle = ClientStateCache.getBattle and ClientStateCache.getBattle(battleId)
	local marker = battleMarkers[battleId]
	if not battle then
		if marker then destroyMarker(marker); battleMarkers[battleId] = nil end
		return
	end
	if not ensureFolders() then return end
	local defCenter = provinceCenter(battle.provinceId)
	if not defCenter then scheduleRetry("battle", battleId); return end
	-- Bubble sits on the front line: midpoint of attacker origin -> defender province.
	local atkCenter = provinceCenter(attackerOriginId(battle))
	local center = (atkCenter and (atkCenter + defCenter) * 0.5) or defCenter
	if not marker then
		marker = buildBattleMarker(center)
		battleMarkers[battleId] = marker
	end
	if marker.anchor and marker.anchor.Parent then marker.anchor.Position = center end
	marker.atkWorld = atkCenter or defCenter
	marker.defWorld = defCenter
	updateBattle(marker, battle)
	-- A battle suspends siege accrual on its province; hide any siege meter there.
	dirtySieges[battle.provinceId] = true
end

local function reconcileSiege(provinceId)
	local prov = ClientStateCache.getProvince and ClientStateCache.getProvince(provinceId)
	local occ = prov and prov.occupation
	local marker = siegeMarkers[provinceId]
	if occ and hasBattleAt(provinceId) then occ = nil end
	if not occ then
		if marker then destroyMarker(marker); siegeMarkers[provinceId] = nil end
		return
	end
	if not ensureFolders() then return end
	local center = provinceCenter(provinceId)
	if not center then scheduleRetry("siege", provinceId); return end
	if not marker then
		marker = buildSiegeMarker(center)
		siegeMarkers[provinceId] = marker
	end
	updateSiege(marker, occ)
end

local function fullRescan()
	for id in pairs(battleMarkers) do dirtyBattles[id] = true end
	for id in pairs(ClientStateCache.allBattles()) do dirtyBattles[id] = true end
	for pid in pairs(siegeMarkers) do dirtySieges[pid] = true end
	for pid, prov in pairs(ClientStateCache.allProvinces()) do
		if type(prov) == "table" and prov.occupation then dirtySieges[pid] = true end
	end
end

function CombatView.init()
	if started then return end
	if not ensureFolders() then task.defer(CombatView.init); return end
	started = true

	if ClientStateCache.onChangePrefix then
		battleSub = ClientStateCache.onChangePrefix("battles", function(_, path)
			local id = path:match("^battles%.([^%.]+)")
			if id then dirtyBattles[id] = true end
		end)
		provinceSub = ClientStateCache.onChangePrefix("provinces", function(_, path)
			local idStr = path:match("^provinces%.([^%.]+)$") or path:match("^provinces%.([^%.]+)%.occupation$")
			if idStr then dirtySieges[tonumber(idStr) or idStr] = true end
		end)
	end
	if ClientStateCache.onChange then
		snapshotSub = ClientStateCache.onChange("snapshot", fullRescan)
	end

	heartbeatConn = RunService.Heartbeat:Connect(function()
		if next(dirtyBattles) then
			for id in pairs(dirtyBattles) do reconcileBattle(id) end
			table.clear(dirtyBattles)
		end
		if next(dirtySieges) then
			for id in pairs(dirtySieges) do reconcileSiege(id) end
			table.clear(dirtySieges)
		end
		-- Keep each battle bubble's chevron pointing in the on-screen attack
		-- direction (attacker origin -> defender) as the camera moves. Cheap: a
		-- handful of battles at most.
		local cam = workspace.CurrentCamera
		if cam and next(battleMarkers) then
			for _, marker in pairs(battleMarkers) do
				if marker.chevron and marker.atkWorld and marker.defWorld then
					local a = cam:WorldToViewportPoint(marker.atkWorld)
					local d = cam:WorldToViewportPoint(marker.defWorld)
					local dx, dy = d.X - a.X, d.Y - a.Y
					if (dx * dx + dy * dy) > 1 then
						marker.chevron.Rotation = math.deg(math.atan2(dy, dx))
					end
				end
			end
		end
	end)

	if ClientStateCache.isReady and ClientStateCache.isReady() then
		fullRescan()
	end
end

function CombatView.destroy()
	if heartbeatConn then heartbeatConn:Disconnect(); heartbeatConn = nil end
	if battleSub then battleSub(); battleSub = nil end
	if provinceSub then provinceSub(); provinceSub = nil end
	if snapshotSub then snapshotSub(); snapshotSub = nil end
	for _, marker in pairs(battleMarkers) do destroyMarker(marker) end
	for _, marker in pairs(siegeMarkers) do destroyMarker(marker) end
	battleMarkers = {}
	siegeMarkers = {}
	dirtyBattles = {}
	dirtySieges = {}
	pendingRetry = {}
	provinceCenterCache = {}
	if markersFolder and markersFolder.Parent then markersFolder:Destroy() end
	markersFolder = nil
	started = false
end

return CombatView