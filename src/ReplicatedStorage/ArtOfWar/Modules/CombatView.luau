-- Worldspace combat & siege overlays. Reads the synced ClientStateCache only —
-- battles from allBattles(), sieges from each province's .occupation record — and
-- floats a billboard meter above the contested province. No server authority here;
-- this is a pure read-through visualization, mirroring ArmyView's reconcile pattern.

local CombatView = {}

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
	local _, bg = makePlate(anchor, 168, 46)

	txt(bg, {
		Text = "\u{2694} BATTLE", TextColor3 = SWORDS, TextSize = 11,
		Size = UDim2.new(1, -12, 0, 12), Position = UDim2.fromOffset(6, 2),
		TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Center,
	})
	local leftCount = txt(bg, {
		Text = "0", TextSize = 15, Font = Enum.Font.GothamBold,
		Size = UDim2.new(0.5, -10, 0, 18), Position = UDim2.fromOffset(8, 13),
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center,
	})
	local rightCount = txt(bg, {
		Text = "0", TextSize = 15, Font = Enum.Font.GothamBold,
		Size = UDim2.new(0.5, -10, 0, 18), Position = UDim2.new(1, -8, 0, 13),
		AnchorPoint = Vector2.new(1, 0),
		TextXAlignment = Enum.TextXAlignment.Right, TextYAlignment = Enum.TextYAlignment.Center,
	})

	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, -16, 0, 9)
	track.Position = UDim2.fromOffset(8, 33)
	track.BackgroundColor3 = TRACK
	track.BorderSizePixel = 0
	track.Parent = bg

	local attFill = Instance.new("Frame")
	attFill.AnchorPoint = Vector2.new(0, 0)
	attFill.Position = UDim2.fromScale(0, 0)
	attFill.Size = UDim2.fromScale(0.5, 1)
	attFill.BorderSizePixel = 0
	attFill.Parent = track

	local defFill = Instance.new("Frame")
	defFill.AnchorPoint = Vector2.new(1, 0)
	defFill.Position = UDim2.fromScale(1, 0)
	defFill.Size = UDim2.fromScale(0.5, 1)
	defFill.BorderSizePixel = 0
	defFill.Parent = track

	return { kind = "battle", anchor = anchor, leftCount = leftCount, rightCount = rightCount,
		attFill = attFill, defFill = defFill, sig = nil }
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
	local sig = string.format("%d,%d,%s,%s", attMen, defMen, tostring(attTag), tostring(defTag))
	if marker.sig == sig then return end
	marker.sig = sig

	local attColor = ownerColor(attTag)
	local defColor = ownerColor(defTag)
	marker.leftCount.Text = tostring(attMen)
	marker.leftCount.TextColor3 = attColor
	marker.rightCount.Text = tostring(defMen)
	marker.rightCount.TextColor3 = defColor

	local total = attMen + defMen
	local frac = total > 0 and (attMen / total) or 0.5
	frac = math.clamp(frac, 0.06, 0.94)
	marker.attFill.Size = UDim2.fromScale(frac, 1)
	marker.attFill.BackgroundColor3 = attColor
	marker.defFill.Size = UDim2.fromScale(1 - frac, 1)
	marker.defFill.BackgroundColor3 = defColor
end

local function updateSiege(marker, occ)
	local byTag = occ.byTag
	local progress = occ.progress or 0
	local sig = string.format("%s,%.2f", tostring(byTag), progress)
	if marker.sig == sig then return end
	marker.sig = sig

	marker.name.Text = ownerName(byTag)
	marker.name.TextColor3 = ownerColor(byTag)
	marker.frac.Text = string.format("%d / %d", math.floor(progress + 0.5), REQUIRED)
	local f = math.clamp(REQUIRED > 0 and (progress / REQUIRED) or 0, 0, 1)
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
	local center = provinceCenter(battle.provinceId)
	if not center then scheduleRetry("battle", battleId); return end
	if not marker then
		marker = buildBattleMarker(center)
		battleMarkers[battleId] = marker
	end
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