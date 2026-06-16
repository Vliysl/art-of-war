local ArmyView = {}

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local ClientStateCache = require(aow.Modules:WaitForChild("ClientStateCache"))
local ProvinceInteraction = require(aow.Modules:WaitForChild("ProvinceInteraction"))
local MapModeController = require(aow.Modules:WaitForChild("MapModeController"))
local Countries = require(aow:WaitForChild("Data"):WaitForChild("Countries"))

local STATE_ICON = {
	idle = "",
	moving = "→",
	attacking = "⚔",
	defending = "🛡",
	retreating = "↩",
}

local TINT_BY_STATE = {
	idle       = nil,
	moving     = nil,
	attacking  = Color3.fromRGB(220, 60, 60),
	defending  = Color3.fromRGB(201, 162, 75),
	retreating = Color3.fromRGB(220, 220, 220),
}

local FACTION_FALLBACK = Color3.fromRGB(140, 140, 140)
local POLE_COLOR = Color3.fromRGB(40, 40, 50)

-- Unit IDs that get the placeholder Musketeer model. All other unit types use the
-- generic Banner-Pin (disc + pole + flag). Cavalry/dragoons/artillery stay generic
-- until their own placeholder models are added.
local INFANTRY_UNIT_IDS = {
	line_infantry = true,
	light_infantry = true,
	militia_forces = true,
	irregular_forces = true,
	professional_infantry = true,
}

local MUSKETEER_TEMPLATE = nil
local MUSKETEER_TARGET_HEIGHT = 12  -- world studs (model spans this much vertically after scaling)

local function getMusketeerTemplate()
	if MUSKETEER_TEMPLATE then return MUSKETEER_TEMPLATE end
	local rs = game:GetService("ReplicatedStorage")
	local models = rs:FindFirstChild("Models")
	local m = models and models:FindFirstChild("Musketeer")
	if m then MUSKETEER_TEMPLATE = m end
	return MUSKETEER_TEMPLATE
end

local function modelTypeFor(unitTypeId)
	if unitTypeId and INFANTRY_UNIT_IDS[unitTypeId] then return "musketeer" end
	return "banner_pin"
end


local BASE_LIFT = 1
local MOVING_LIFT = 4
local RETREAT_LIFT = 6
-- HOI4-style movement: the token WAITS at its origin while the move arrow fills
-- (server-timed), then plays this quick cosmetic "hop" into the new tile on arrival.
local HOP_TIME = 0.35
local HOP_ARC = 7

-- On-map vitals strip normalization + tier colouring (matches ArmyPanel's bars).
local ARMY_MORALE_MAX = 100
local function tierColor(pct)
	if pct >= 0.6 then return Color3.fromRGB(110, 180, 80) end   -- green
	if pct >= 0.3 then return Color3.fromRGB(214, 178, 70) end   -- amber
	return Color3.fromRGB(200, 70, 56)                            -- red
end

-- Reduced sizes — disc fits comfortably inside an ~86-stud province.
-- The Base cylinder is laid flat: Cylinder shape's axis is along its X-axis.
-- We bake CFrame.Angles(0,0,pi/2) into Base's offset so it lies flat.
local BASE_SIZE   = Vector3.new(2, 28, 28)   -- 2 tall, 28 diameter
local POLE_SIZE   = Vector3.new(0.8, 30, 0.8)
local FLAG_SIZE   = Vector3.new(10, 6, 0.4)

-- Local-space offsets relative to a hidden Anchor part at (0,0,0)
local BASE_OFFSET_Y = BASE_SIZE.X * 0.5         -- = 1
local POLE_OFFSET_Y = BASE_SIZE.X + POLE_SIZE.Y * 0.5  -- = 17
local FLAG_OFFSET   = Vector3.new(5, BASE_SIZE.X + POLE_SIZE.Y - 4, 0)  -- near top of pole, offset to side
local BB_STUDS_OFFSET = Vector3.new(0, BASE_SIZE.X + POLE_SIZE.Y + 8, 0)

-- Module state
local armyParts = {}
local animTracks = {}                -- [armyId] = { Idle, Walk, Shoot, Reload }  AnimationTrack table
local animState = {}                 -- [armyId] = currently-playing state name (cached to avoid restarting tracks)
local combatAnimConns = {}           -- [armyId] = { shoot = conn, reload = conn }  signal handles for the shoot/reload loop
local combatAnimGen = {}             -- [armyId] = generation counter — increments to invalidate pending task.delay callbacks
local lastKnownState = {}
local dirtyArmies = {}
local hopState = {}                 -- [armyId] = { from = Vector3, to = Vector3, t0 = os.clock() } (arrival hop)
local provinceCenterCache = {}
local stackInfo = {}                -- [provinceId..":"..ownerTag] = { armyIds (sorted), strongestId }
local pulseTweens = {}
local selectedArmyId = nil
local selectedArmyIds = {}          -- multi-selection set
local armiesFolder = nil
local mapFolder = nil
local provincesFolder = nil
local heartbeatConn = nil
local renderConn = nil
local stateSub, battleSub, countriesSub, snapshotSub
local cameraSub
local cameraMode = "field"
local onArmySelectedListeners = {}
local recentRetryArmies = {}
local hoverProvinceId = nil
local bundleRef = nil               -- set by ArmyView.setBundle for unit-type names

local function ensureFolder()
	if armiesFolder and armiesFolder.Parent then return armiesFolder end
	mapFolder = workspace:FindFirstChild("ArtOfWarMap")
	if not mapFolder then return nil end
	provincesFolder = mapFolder:FindFirstChild("Provinces")
	armiesFolder = mapFolder:FindFirstChild("Armies")
	if not armiesFolder then
		armiesFolder = Instance.new("Folder")
		armiesFolder.Name = "Armies"
		armiesFolder.Parent = mapFolder
	end
	return armiesFolder
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
	local topY = part.Position.Y + part.Size.Y * 0.5
	local center = { x = part.Position.X, z = part.Position.Z, topY = topY }
	provinceCenterCache[provinceId] = center
	return center
end

local function deriveState(army)
	if not army then return nil end
	if army.state then return army.state end
	if army.battleId then
		local b = ClientStateCache.getBattle and ClientStateCache.getBattle(army.battleId)
		if b then
			if b.attackerArmyIds then
				for _, id in ipairs(b.attackerArmyIds) do if id == army.id then return "attacking" end end
			end
			if b.defenderArmyIds then
				for _, id in ipairs(b.defenderArmyIds) do if id == army.id then return "defending" end end
			end
		end
	end
	if army.retreating then return "retreating" end
	if army.movement then return "moving" end
	return "idle"
end

local function compositionCount(army)
	if not army or not army.composition then return 0 end
	local total = 0
	for _, c in pairs(army.composition) do total += c end
	return total
end

local function getOwnerColor(ownerTag)
	local country = ClientStateCache.getCountry and ClientStateCache.getCountry(ownerTag)
	if country and country.color then
		return Color3.fromRGB(country.color[1], country.color[2], country.color[3])
	end
	return FACTION_FALLBACK
end

local function getOwnerName(ownerTag)
	if not ownerTag then return "?" end
	local country = ClientStateCache.getCountry and ClientStateCache.getCountry(ownerTag)
	if country then
		local named = country.displayName or country.name
		if type(named) == "string" and named ~= "" then return named end
	end
	local static = Countries[ownerTag]
	if static and type(static.displayName) == "string" and static.displayName ~= "" then
		return static.displayName
	end
	return tostring(ownerTag)
end

local function dominantUnit(army)
	if not army or not army.composition then return nil, 0 end
	local bestId, bestCount = nil, 0
	for unitId, count in pairs(army.composition) do
		if count > bestCount then bestId, bestCount = unitId, count end
	end
	return bestId, bestCount
end

local function unitDisplayName(unitTypeId)
	if not unitTypeId then return "Army" end
	if bundleRef and bundleRef.unitTypes and bundleRef.unitTypes[unitTypeId] then
		return bundleRef.unitTypes[unitTypeId].displayName or unitTypeId
	end
	return unitTypeId
end

-- Compute "combat value" for stacking: highest attack+defense * count
local function armyStrength(army)
	if not army or not army.composition then return 0 end
	local total = 0
	for unitId, count in pairs(army.composition) do
		local def = bundleRef and bundleRef.unitTypes and bundleRef.unitTypes[unitId]
		local atk = def and def.attack or 5
		local d = def and def.defense or 5
		total += (atk + d) * count
	end
	return total
end

local function rebuildStacks()
	stackInfo = {}
	for armyId, army in pairs(ClientStateCache.allArmies()) do
		if army then
			local key = tostring(army.provinceId) .. ":" .. tostring(army.ownerTag)
			local s = stackInfo[key]
			if not s then s = { armyIds = {}, strongestId = nil, strongestStrength = -1 } end
			table.insert(s.armyIds, armyId)
			local strength = armyStrength(army)
			if strength > s.strongestStrength then
				s.strongestStrength = strength
				s.strongestId = armyId
			end
			stackInfo[key] = s
		end
	end
	for _, s in pairs(stackInfo) do table.sort(s.armyIds) end
end

local function isVisibleInStack(armyId, army)
	if not army then return false end
	local key = tostring(army.provinceId) .. ":" .. tostring(army.ownerTag)
	local s = stackInfo[key]
	if not s then return true end
	-- Always show movers/battlers; otherwise only the strongest in each stack.
	-- (Hover-expand removed per design: only one model per stack, ever.)
	if army.movement or army.battleId then return true end
	return s.strongestId == armyId
end

local function destroyModelFor(armyId)
	if combatAnimConns[armyId] then
		local c = combatAnimConns[armyId]
		if c.shoot then c.shoot:Disconnect() end
		if c.reload then c.reload:Disconnect() end
		combatAnimConns[armyId] = nil
	end
	combatAnimGen[armyId] = (combatAnimGen[armyId] or 0) + 1
	local model = armyParts[armyId]
	if model and model.Parent then model:Destroy() end
	armyParts[armyId] = nil
	lastKnownState[armyId] = nil
	hopState[armyId] = nil
	animTracks[armyId] = nil
	animState[armyId] = nil
	if pulseTweens[armyId] then pulseTweens[armyId]:Cancel(); pulseTweens[armyId] = nil end
	if selectedArmyId == armyId then selectedArmyId = nil end
	selectedArmyIds[armyId] = nil
end

-- Sleek serif banner. Single-line text "[TAG] UnitName (#Count)". No corners, thin
-- bottom-rule in the faction color, near-flat dark plate. Adornee/offset/parent are caller-supplied.
local function buildBannerGui(adornee, studsOffset, factionColor)
	local bb = Instance.new("BillboardGui")
	bb.Name = "Label"
	bb.Adornee = adornee
	bb.Size = UDim2.fromOffset(220, 42)
	bb.StudsOffset = studsOffset
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 0
	bb.Enabled = false

	local bg = Instance.new("Frame")
	bg.Name = "Bg"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(18, 12, 8)
	bg.BackgroundTransparency = 0.18
	bg.BorderSizePixel = 0
	bg.Parent = bb

	-- Thin faction-colored rule along the bottom edge (period flair, no corners).
	local rule = Instance.new("Frame")
	rule.Name = "Rule"
	rule.AnchorPoint = Vector2.new(0, 1)
	rule.Position = UDim2.new(0, 0, 1, 0)
	rule.Size = UDim2.new(1, 0, 0, 1)
	rule.BackgroundColor3 = factionColor
	rule.BackgroundTransparency = 0
	rule.BorderSizePixel = 0
	rule.Parent = bg

	-- Subtle outer hairline so the plate reads against any background.
	local stroke = Instance.new("UIStroke")
	stroke.Name = "Hairline"
	stroke.Color = Color3.fromRGB(60, 40, 22)
	stroke.Thickness = 1
	stroke.Transparency = 0.35
	stroke.Parent = bg

	-- Compact state pip on the right edge (drawn but blank by default; reconcileOne fills it).
	local stateIcon = Instance.new("TextLabel")
	stateIcon.Name = "StateIcon"
	stateIcon.AnchorPoint = Vector2.new(1, 0.5)
	stateIcon.Position = UDim2.new(1, -6, 0.5, 0)
	stateIcon.Size = UDim2.fromOffset(16, 16)
	stateIcon.BackgroundTransparency = 1
	stateIcon.Text = ""
	stateIcon.TextColor3 = Color3.fromRGB(206, 180, 120)
	stateIcon.TextScaled = true
	stateIcon.Font = Enum.Font.GothamBold
	stateIcon.TextStrokeTransparency = 0
	stateIcon.TextStrokeColor3 = Color3.fromRGB(20, 12, 8)
	stateIcon.Parent = bg

	-- Single-line caption: "[TAG] UnitType (#Count)" in serif.
	local caption = Instance.new("TextLabel")
	caption.Name = "UnitName"  -- name kept so reconcileOne :FindFirstChild("UnitName") still works
	caption.Size = UDim2.new(1, -28, 0, 22)  -- top row; bottom reserved for the vitals strip
	caption.Position = UDim2.fromOffset(8, 0)
	caption.BackgroundTransparency = 1
	caption.Text = ""
	caption.TextColor3 = Color3.fromRGB(234, 216, 176)
	caption.Font = Enum.Font.Garamond  -- serif; matches UIStyle.FontFace.Cinzel which aliases to Garamond
	caption.TextSize = 16
	caption.TextXAlignment = Enum.TextXAlignment.Left
	caption.TextYAlignment = Enum.TextYAlignment.Center
	caption.TextStrokeTransparency = 0.2
	caption.TextStrokeColor3 = Color3.fromRGB(20, 12, 8)
	caption.TextTruncate = Enum.TextTruncate.AtEnd
	caption.Parent = bg

	-- Legacy "Count" sibling kept as an empty no-op so any code that expects it doesn't crash.
	local countLine = Instance.new("TextLabel")
	countLine.Name = "Count"
	countLine.Size = UDim2.fromScale(0, 0)
	countLine.BackgroundTransparency = 1
	countLine.Text = ""
	countLine.Visible = false
	countLine.Parent = bg

	-- Vitals strip: stacked mini-bars (organization / morale / entrenchment),
	-- updated by reconcileOne. Found by name, like UnitName/StateIcon.
	local function miniBar(name, yOff, baseColor)
		local track = Instance.new("Frame")
		track.Name = name .. "Track"
		track.Size = UDim2.new(1, -34, 0, 3)
		track.Position = UDim2.fromOffset(8, yOff)
		track.BackgroundColor3 = Color3.fromRGB(40, 30, 18)
		track.BackgroundTransparency = 0.25
		track.BorderSizePixel = 0
		track.Parent = bg
		local fill = Instance.new("Frame")
		fill.Name = name
		fill.Size = UDim2.fromScale(0, 1)
		fill.BackgroundColor3 = baseColor
		fill.BorderSizePixel = 0
		fill.Parent = track
		return fill
	end
	miniBar("OrgFill", 24, Color3.fromRGB(120, 180, 90))
	miniBar("MoraleFill", 29, Color3.fromRGB(120, 180, 90))
	miniBar("EntFill", 34, Color3.fromRGB(218, 168, 84))

	-- Supply pip (right of the bars): hidden when adequate, amber crowded, red starving.
	local supplyPip = Instance.new("TextLabel")
	supplyPip.Name = "SupplyPip"
	supplyPip.AnchorPoint = Vector2.new(1, 1)
	supplyPip.Position = UDim2.new(1, -6, 1, -2)
	supplyPip.Size = UDim2.fromOffset(18, 14)
	supplyPip.BackgroundTransparency = 1
	supplyPip.Text = ""
	supplyPip.TextColor3 = Color3.fromRGB(220, 176, 80)
	supplyPip.Font = Enum.Font.GothamBold
	supplyPip.TextSize = 12
	supplyPip.TextStrokeTransparency = 0
	supplyPip.TextStrokeColor3 = Color3.fromRGB(20, 12, 8)
	supplyPip.Parent = bg

	return bb, bg, stateIcon, caption
end

local function buildBannerPinModel(armyId, factionColor)
	local model = Instance.new("Model")
	model.Name = "army_" .. tostring(armyId)
	model:SetAttribute("armyId", armyId)

	-- Anchor: invisible PrimaryPart with NO rotation.
	-- All other parts have absolute world rotation baked into their CFrames.
	-- PivotTo(CFrame.new(pos)) translates the whole model without changing any rotation.
	local anchor = Instance.new("Part")
	anchor.Name = "Anchor"
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.Massless = true
	anchor.CFrame = CFrame.new(0, 0, 0)
	anchor.Parent = model
	model.PrimaryPart = anchor

	local function partCommon(p)
		p.Material = Enum.Material.SmoothPlastic
		p.Anchored = true
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = true
		p.Massless = true
		p.CastShadow = false
		p.Locked = true
	end

	-- Base disc (cylinder lying flat). Rotation baked in CFrame.
	local base = Instance.new("Part")
	base.Name = "Base"
	base.Shape = Enum.PartType.Cylinder
	base.Size = BASE_SIZE
	base.Color = factionColor
	base.Transparency = 0
	partCommon(base)
	base.CFrame = CFrame.new(0, BASE_OFFSET_Y, 0) * CFrame.Angles(0, 0, math.pi / 2)
	base.Parent = model

	-- Pole
	local pole = Instance.new("Part")
	pole.Name = "Pole"
	pole.Size = POLE_SIZE
	pole.Color = POLE_COLOR
	pole.Transparency = 0
	partCommon(pole)
	pole.CFrame = CFrame.new(0, POLE_OFFSET_Y, 0)
	pole.Parent = model

	-- Flag
	local flag = Instance.new("Part")
	flag.Name = "Flag"
	flag.Size = FLAG_SIZE
	flag.Color = factionColor
	flag.Transparency = 0
	partCommon(flag)
	flag.CFrame = CFrame.new(FLAG_OFFSET)
	flag.Parent = model

	local bb = buildBannerGui(pole, BB_STUDS_OFFSET, factionColor)
	bb.Parent = pole

	-- Selection highlight
	local hl = Instance.new("Highlight")
	hl.Name = "Selection"
	hl.FillColor = Color3.fromRGB(120, 220, 255)
	hl.OutlineColor = Color3.fromRGB(255, 255, 255)
	hl.FillTransparency = 0.5
	hl.OutlineTransparency = 0
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Adornee = model
	hl.Enabled = false
	hl.Parent = model

	model.Parent = armiesFolder
	return model
end

-- Build a clone of the Musketeer model in ReplicatedStorage.Models.
-- Animation state machine: load Idle/Walk/Shoot/Reload tracks once per army, then switch
-- between them when army state changes. Empty AnimationIds skip the load so unauthored
-- assets don't error.  The user must paste rbxassetid:// URLs into the four Animation
-- objects on `RS.Models.Musketeer` for any of this to be visible.
local function loadAnimationsFor(armyId, model)
	local hum = model:FindFirstChildOfClass("Humanoid")
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	if not animator then return end
	local function loadOne(name)
		local animObj = model:FindFirstChild(name)
		if not animObj or not animObj:IsA("Animation") then return nil end
		if animObj.AnimationId == "" then return nil end
		local ok, track = pcall(function() return animator:LoadAnimation(animObj) end)
		return ok and track or nil
	end
	animTracks[armyId] = {
		Idle   = loadOne("Idle"),
		Walk   = loadOne("Walk"),
		Shoot  = loadOne("Shoot"),
		Reload = loadOne("Reload"),
	}
end

local function disconnectCombatConns(armyId)
	local c = combatAnimConns[armyId]
	if not c then return end
	if c.shoot then c.shoot:Disconnect() end
	if c.reload then c.reload:Disconnect() end
	combatAnimConns[armyId] = nil
end

local function stopCombatCycle(armyId)
	disconnectCombatConns(armyId)
	combatAnimGen[armyId] = (combatAnimGen[armyId] or 0) + 1
end

local function startCombatCycle(armyId)
	local t = animTracks[armyId]
	if not t or not t.Shoot then return end
	disconnectCombatConns(armyId)
	local gen = (combatAnimGen[armyId] or 0) + 1
	combatAnimGen[armyId] = gen
	local conns = {}
	combatAnimConns[armyId] = conns

	local function alive()
		return animState[armyId] == "attacking" and combatAnimGen[armyId] == gen
	end
	local function playShoot()
		if not alive() then return end
		local tracks = animTracks[armyId]
		if tracks and tracks.Shoot then
			tracks.Shoot.Looped = false
			tracks.Shoot:Play(0.15)
		end
	end
	local function playReload()
		if not alive() then return end
		local tracks = animTracks[armyId]
		if not tracks then return end
		if not tracks.Reload then
			task.delay(0.4 + math.random() * 0.4, playShoot)
			return
		end
		tracks.Reload.Looped = false
		tracks.Reload:Play(0.15)
	end

	conns.shoot = t.Shoot.Stopped:Connect(function()
		if not alive() then return end
		task.delay(0.4 + math.random() * 0.4, playReload)
	end)
	if t.Reload then
		conns.reload = t.Reload.Stopped:Connect(function()
			if not alive() then return end
			task.delay(0.6 + math.random() * 0.6, playShoot)
		end)
	end
	playShoot()
end

local function setAnimState(armyId, state)
	local t = animTracks[armyId]
	if not t then return end
	if animState[armyId] == state then return end
	local prev = animState[armyId]
	animState[armyId] = state
	if prev == "attacking" then stopCombatCycle(armyId) end
	if state == "attacking" then
		for _, tr in pairs(t) do
			if tr ~= t.Shoot and tr ~= t.Reload and tr.IsPlaying then tr:Stop(0.2) end
		end
		startCombatCycle(armyId)
		return
	end
	local desired
	if state == "moving" or state == "retreating" then desired = t.Walk
	else desired = t.Idle end
	for _, tr in pairs(t) do
		if tr ~= desired and tr.IsPlaying then tr:Stop(0.2) end
	end
	if desired and not desired.IsPlaying then
		desired.Looped = true
		desired:Play(0.2)
	end
end

-- v2: HumanoidRootPart anchored, limbs un-anchored — animations drive Motor6D transforms.
-- BillboardGui sits above the Head so the army's regiment count + state still reads.
local function buildMusketeerModel(armyId, factionColor)
	local template = getMusketeerTemplate()
	if not template then
		return buildBannerPinModel(armyId, factionColor)
	end

	local model = template:Clone()
	model.Name = "army_" .. tostring(armyId)
	model:SetAttribute("armyId", armyId)
	model:SetAttribute("modelType", "musketeer")

	-- Freeze the Humanoid so it has no AI/physics behavior.
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.PlatformStand = true
		hum.AutoRotate = false
		hum.WalkSpeed = 0
		hum.JumpPower = 0
		hum.HipHeight = 0
		hum.BreakJointsOnDeath = false
		hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
		hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
		hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
	end

	-- Anchor only the HumanoidRootPart so PivotTo translates the rig as a unit while
	-- limb/torso/head BaseParts stay un-anchored. Motor6Ds drive joint transforms during
	-- animation playback only when limbs are un-anchored. Massless + PlatformStand ensures
	-- the un-anchored parts don't fall under gravity or collide with anything.
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = (p.Name == "HumanoidRootPart")
			p.CanCollide = false
			p.CanTouch = false
			p.CanQuery = true
			p.Massless = true
			p.CastShadow = false
			p.Locked = true
			-- HumanoidRootPart is a control hull, not visible geometry: keep it invisible.
			if p.Name == "HumanoidRootPart" then p.Transparency = 1 end
		end
	end

	-- Faction color accent on the Shako (hat).
	local shako = model:FindFirstChild("Shako")
	if shako and shako:IsA("BasePart") then
		shako.Color = factionColor
	end

	-- Scale before measuring feet offset.
	-- Important: ScaleTo replaces the model's *absolute* scale; the template may already have
	-- a non-unit scale (Roblox's GetScale()), so multiply by current scale, not just the ratio.
	if model.ScaleTo and model.GetScale then
		local currentScale = model:GetScale()
		local _, bbSize0 = model:GetBoundingBox()
		if bbSize0.Y > 0 then
			model:ScaleTo(currentScale * (MUSKETEER_TARGET_HEIGHT / bbSize0.Y))
		end
	end

	-- Compute feet-offset (distance from PrimaryPart center down to the model's lowest point).
	-- computePosition uses this to lift the pivot so the feet rest on the province surface.
	local cf, bbSize = model:GetBoundingBox()
	local primaryY = model.PrimaryPart.Position.Y
	local bottomY = cf.Position.Y - bbSize.Y * 0.5
	local feetOffset = primaryY - bottomY
	model:SetAttribute("feetOffsetY", feetOffset)

	-- Find the Head for BillboardGui adornee.
	local head = model:FindFirstChild("Head") or model.PrimaryPart

	local bb = buildBannerGui(head, Vector3.new(0, 18, 0), factionColor)
	bb.Parent = head

	-- Selection highlight on the model
	local hl = Instance.new("Highlight")
	hl.Name = "Selection"
	hl.FillColor = Color3.fromRGB(120, 220, 255)
	hl.OutlineColor = Color3.fromRGB(255, 255, 255)
	hl.FillTransparency = 0.5
	hl.OutlineTransparency = 0
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Adornee = model
	hl.Enabled = false
	hl.Parent = model

	model.Parent = armiesFolder
	loadAnimationsFor(armyId, model)
	setAnimState(armyId, "idle")
	return model
end

-- Dispatch builder: choose model based on dominant unit's modelType.
local function buildModel(armyId, factionColor, dominantUnitId)
	local mt = modelTypeFor(dominantUnitId)
	if mt == "musketeer" then
		return buildMusketeerModel(armyId, factionColor)
	end
	return buildBannerPinModel(armyId, factionColor)
end

local function applyTransparency(model, target)
	if not model then return end
	-- Banner-pin parts
	for _, partName in ipairs({"Base", "Pole", "Flag"}) do
		local part = model:FindFirstChild(partName)
		if part then
			TweenService:Create(part, TweenInfo.new(0.35, Enum.EasingStyle.Quad), { Transparency = target }):Play()
		end
	end
	-- Musketeer parts: tween every BasePart descendant (except invisible ones we own like Anchor)
	if model:GetAttribute("modelType") == "musketeer" then
		for _, p in model:GetDescendants() do
			if p:IsA("BasePart") and p.Name ~= "Anchor" and p.Name ~= "HumanoidRootPart" then
				TweenService:Create(p, TweenInfo.new(0.35, Enum.EasingStyle.Quad), { Transparency = target }):Play()
			end
		end
	end
end

local function setCameraMode(mode)
	cameraMode = mode
	for _, model in pairs(armyParts) do
		applyTransparency(model, mode == "command" and 1 or 0)
	end
end

local function ensurePulse(armyId, model, on)
	if on then
		if pulseTweens[armyId] then return end
		local target = model:FindFirstChild("Base") or model:FindFirstChild("Shako")
		if not target then return end
		local tween = TweenService:Create(target,
			TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Transparency = 0.4 })
		tween:Play()
		pulseTweens[armyId] = tween
	else
		local tween = pulseTweens[armyId]
		if tween then
			tween:Cancel()
			pulseTweens[armyId] = nil
			local target = model:FindFirstChild("Base") or model:FindFirstChild("Shako")
			if target then target.Transparency = cameraMode == "command" and 1 or 0 end
		end
	end
end

local function computePosition(army, state)
	local center = provinceCenter(army.provinceId)
	if not center then return nil end
	local x, z, topY = center.x, center.z, center.topY
	local lift = 0

	if state == "moving" or state == "retreating" then
		-- The token holds at its ORIGIN province while the move arrow fills (the
		-- army's provinceId stays the origin until the server relocates it on
		-- completion, which then triggers the arrival hop). No continuous slide.
		lift = state == "retreating" and RETREAT_LIFT or MOVING_LIFT
	elseif state == "attacking" then
		local origin = army.originProvinceId and provinceCenter(army.originProvinceId)
		if origin then
			x = center.x + (origin.x - center.x) * 0.3
			z = center.z + (origin.z - center.z) * 0.3
		end
	end

	-- For musketeer models, lift Y so feet touch the surface (PrimaryPart is HumanoidRootPart, mid-height).
	local model = armyParts[army.id]
	local modelLift = 0
	if model and model:GetAttribute("modelType") == "musketeer" then
		modelLift = model:GetAttribute("feetOffsetY") or (MUSKETEER_TARGET_HEIGHT * 0.5)
	end

	-- (No hover-expand: only the strongest per stack is rendered, always centered.)
	local y = topY + BASE_LIFT + lift + modelLift
	return Vector3.new(x, y, z)
end

local function reconcileOne(armyId)
	local army = ClientStateCache.allArmies()[armyId]
	if not army then
		destroyModelFor(armyId)
		return
	end

	if not ensureFolder() then return end

	-- Stack hiding: skip rendering non-strongest armies in same owner+province (unless moving/in-battle)
	if not isVisibleInStack(armyId, army) then
		destroyModelFor(armyId)  -- ensure no stale model lingers
		return
	end

	local state = deriveState(army)
	-- Cheap pre-check: province must exist for any positioning to make sense.
	if not provinceCenter(army.provinceId) then
		if not recentRetryArmies[armyId] then
			recentRetryArmies[armyId] = true
			task.delay(0.25, function()
				recentRetryArmies[armyId] = nil
				dirtyArmies[armyId] = true
			end)
		end
		return
	end

	local color = getOwnerColor(army.ownerTag)
	local model = armyParts[armyId]
	local last = lastKnownState[armyId] or {}
	local newlyCreated = false

	-- Rebuild model if dominant unit's model type changed (e.g., infantry -> cavalry composition shift)
	local dominantId, _ = dominantUnit(army)
	local desiredModelType = modelTypeFor(dominantId)
	if model and last.modelType ~= nil and last.modelType ~= desiredModelType then
		destroyModelFor(armyId)
		model = nil
	end
	if not model then
		model = buildModel(armyId, color, dominantId)
		armyParts[armyId] = model
		newlyCreated = true
	end

	-- Compute position AFTER the model exists so the modelType-aware modelLift is applied
	-- correctly on the very first reconcile (otherwise musketeer would pivot to ground level
	-- with HRP-centered offset wrong, half-clipping into the tile).
	local pos = computePosition(army, state)
	if not pos then return end

	-- Recolor on owner change or first build
	if newlyCreated or last.ownerTag ~= army.ownerTag then
		local tint = TINT_BY_STATE[state]
		local applied = tint and color:Lerp(tint, 0.4) or color
		-- Banner-pin parts
		local base = model:FindFirstChild("Base")
		local flag = model:FindFirstChild("Flag")
		if base then base.Color = applied end
		if flag then flag.Color = color end
		-- Musketeer parts
		local shako = model:FindFirstChild("Shako")
		if shako then shako.Color = applied end
		-- Banner stroke (works for both model types since Label is parented to Pole or Head)
		local label = (model:FindFirstChild("Pole") and model.Pole:FindFirstChild("Label"))
			or (model:FindFirstChild("Head") and model.Head:FindFirstChild("Label"))
		local stroke = label and label:FindFirstChild("Bg") and label.Bg:FindFirstChild("AccentStroke")
		if stroke then stroke.Color = color end
	end

	-- Banner content: unit type + count, and total stack count if multiple armies
	local count = compositionCount(army)
	local domUnitId = dominantUnit(army)
	local nameText = unitDisplayName(domUnitId)
	-- If this army represents a stack of multiple armies (strongest), append "(+N)" indicator
	local key = tostring(army.provinceId) .. ":" .. tostring(army.ownerTag)
	local stack = stackInfo[key]
	local stackExtra = stack and #stack.armyIds > 1 and (" +" .. (#stack.armyIds - 1)) or ""

	if newlyCreated or last.unitName ~= nameText or last.count ~= count or last.stackExtra ~= stackExtra then
		local label = (model:FindFirstChild("Pole") and model.Pole:FindFirstChild("Label"))
			or (model:FindFirstChild("Head") and model.Head:FindFirstChild("Label"))
		local bg = label and label:FindFirstChild("Bg")
		local caption = bg and bg:FindFirstChild("UnitName")
		if caption then
			caption.Text = string.format("%s · %s (%d%s)", getOwnerName(army.ownerTag), nameText, count, stackExtra)
		end
	end

	-- State icon + tint + pulse + animation
	if newlyCreated or last.state ~= state then
		local label = (model:FindFirstChild("Pole") and model.Pole:FindFirstChild("Label"))
			or (model:FindFirstChild("Head") and model.Head:FindFirstChild("Label"))
		local icon = label and label:FindFirstChild("Bg") and label.Bg:FindFirstChild("StateIcon")
		if icon then icon.Text = STATE_ICON[state] or "" end
		local tint = TINT_BY_STATE[state]
		local applied = tint and color:Lerp(tint, 0.4) or color
		local base = model:FindFirstChild("Base")
		if base then base.Color = applied end
		local shako = model:FindFirstChild("Shako")
		if shako then shako.Color = applied end
		ensurePulse(armyId, model, state == "attacking")
		setAnimState(armyId, state)
	end

	-- On-map vitals strip: org / morale / entrenchment mini-bars + supply pip.
	-- Cheap (a few Size/Color writes); refreshed every reconcile so it tracks deltas.
	do
		local vlabel = (model:FindFirstChild("Pole") and model.Pole:FindFirstChild("Label"))
			or (model:FindFirstChild("Head") and model.Head:FindFirstChild("Label"))
		local vbg = vlabel and vlabel:FindFirstChild("Bg")
		if vbg then
			local orgTrack = vbg:FindFirstChild("OrgFillTrack")
			local moraleTrack = vbg:FindFirstChild("MoraleFillTrack")
			local entTrack = vbg:FindFirstChild("EntFillTrack")
			local orgFill = orgTrack and orgTrack:FindFirstChild("OrgFill")
			local moraleFill = moraleTrack and moraleTrack:FindFirstChild("MoraleFill")
			local entFill = entTrack and entTrack:FindFirstChild("EntFill")
			local supplyPip = vbg:FindFirstChild("SupplyPip")
			local baseOrg = army.baseOrganization or 10
			local orgPct = baseOrg > 0 and math.clamp((army.organization or baseOrg) / baseOrg, 0, 1) or 0
			local moralePct = math.clamp((army.morale or 0) / ARMY_MORALE_MAX, 0, 1)
			local entMax = army.entrenchmentMax or 5
			local entPct = entMax > 0 and math.clamp((army.entrenchment or 0) / entMax, 0, 1) or 0
			if orgFill then orgFill.Size = UDim2.fromScale(orgPct, 1); orgFill.BackgroundColor3 = tierColor(orgPct) end
			if moraleFill then moraleFill.Size = UDim2.fromScale(moralePct, 1); moraleFill.BackgroundColor3 = tierColor(moralePct) end
			if entFill then entFill.Size = UDim2.fromScale(entPct, 1) end
			if supplyPip then
				local s = army.supplyStatus
				if s == "starving" then
					supplyPip.Text = "\u{26A0}"; supplyPip.TextColor3 = Color3.fromRGB(230, 70, 60)
				elseif s == "crowded" then
					supplyPip.Text = "\u{26A0}"; supplyPip.TextColor3 = Color3.fromRGB(230, 180, 80)
				else
					supplyPip.Text = ""
				end
			end
		end
	end

	-- Arrival hop: the army's province changed (move completed, retreat, or a
	-- post-battle advance). Animate a quick cosmetic hop from where the token is
	-- into the new tile instead of snapping. Retreat is an instant server relocate
	-- with no movement record, so we key off the province change itself (cosmetic
	-- only -- no server mechanic is involved). Otherwise pivot instantly (unless a
	-- hop is already in flight, which the render loop is driving).
	local moved = (not newlyCreated) and last.provinceId ~= nil and last.provinceId ~= army.provinceId
	if moved then
		local fromPos = model:GetPivot().Position
		if (fromPos - pos).Magnitude > 1 then
			hopState[armyId] = { from = fromPos, to = pos, t0 = os.clock() }
		else
			model:PivotTo(CFrame.new(pos))
		end
	elseif hopState[armyId] then
		-- a hop is animating; don't fight it with an instant pivot
		hopState[armyId].to = pos
	else
		model:PivotTo(CFrame.new(pos))
	end

	local hl = model:FindFirstChild("Selection")
	if hl then hl.Enabled = (selectedArmyId == armyId) or (selectedArmyIds[armyId] == true) end

	local label = (model:FindFirstChild("Pole") and model.Pole:FindFirstChild("Label"))
		or (model:FindFirstChild("Head") and model.Head:FindFirstChild("Label"))
	if label then label.Enabled = true end

	if newlyCreated then
		local target = cameraMode == "command" and 0.25 or 0
		local canQuery = target < 1
		for _, partName in ipairs({"Base", "Pole", "Flag"}) do
			local p = model:FindFirstChild(partName)
			if p then
				p.Transparency = target
				p.CanQuery = canQuery
			end
		end
		if model:GetAttribute("modelType") == "musketeer" then
			for _, p in model:GetDescendants() do
				if p:IsA("BasePart") and p.Name ~= "Anchor" and p.Name ~= "HumanoidRootPart" then
					p.Transparency = target
					p.CanQuery = canQuery
				end
			end
		end
	end

	lastKnownState[armyId] = {
		state = state,
		provinceId = army.provinceId,
		ownerTag = army.ownerTag,
		count = count,
		unitName = nameText,
		stackExtra = stackExtra,
		originProvinceId = army.originProvinceId,
		fromId = army.movement and army.movement.fromProvinceId,
		toId = army.movement and army.movement.toProvinceId,
		modelType = desiredModelType,
	}
end

local function reconcileAll()
	rebuildStacks()
	for armyId in pairs(ClientStateCache.allArmies()) do
		dirtyArmies[armyId] = true
	end
	for armyId in pairs(armyParts) do
		if not ClientStateCache.allArmies()[armyId] then
			dirtyArmies[armyId] = true
		end
	end
end

-- Clicking a unit selects that unit's stack and CONSUMES the click so the province
-- underneath is not also selected (province/unit selection are separate). Enemy/other
-- units return nil → the click falls through to province selection, so a contested
-- province under an enemy unit stays inspectable.
local function isLocallyOwned(ownerTag)
	local lp = Players.LocalPlayer
	if not ownerTag or not lp then return false end
	local country = ClientStateCache.getCountry(ownerTag)
	return country ~= nil and country.claimedBy == lp.UserId
end

local function selectStackOnProvince(provinceId, additive)
	-- Select every locally-owned army on this province (one rendered banner = one stack).
	local first = true
	for _, army in pairs(ClientStateCache.allArmies()) do
		if army and army.provinceId == provinceId and isLocallyOwned(army.ownerTag) then
			ArmyView.focusArmy(army.id, additive or not first)
			first = false
		end
	end
	return not first
end

local function modelForClickedPart(part)
	-- Army models are direct children of the Armies folder and carry an "armyId" attribute.
	local node = part
	while node and node.Parent do
		if node.Parent == armiesFolder and node:IsA("Model") then return node end
		node = node.Parent
	end
	return nil
end

local function classifyArmyClick(part)
	local model = modelForClickedPart(part)
	local armyId = model and model:GetAttribute("armyId")
	if not armyId then return nil end
	local army = ClientStateCache.allArmies()[armyId]
	if not army or not isLocallyOwned(army.ownerTag) then
		return nil
	end
	local additive = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
	if not additive then ArmyView.deselect() end
	selectStackOnProvince(army.provinceId, additive)
	return "consumed"
end

function ArmyView.focusArmy(armyId, additive)
	if not armyId then return end
	if not additive then
		-- single-select: clear all previous
		for prevId in pairs(selectedArmyIds) do
			local prev = armyParts[prevId]
			if prev then
				local hl = prev:FindFirstChild("Selection")
				if hl then hl.Enabled = false end
			end
		end
		selectedArmyIds = {}
	end
	selectedArmyIds[armyId] = true
	selectedArmyId = armyId  -- track most recent

	local model = armyParts[armyId]
	if model then
		local hl = model:FindFirstChild("Selection")
		if hl then hl.Enabled = true end
	end

	for cb in pairs(onArmySelectedListeners) do
		local ok, err = pcall(cb, armyId, additive)
		if not ok then warn("[ArmyView] onArmySelected listener errored: " .. tostring(err)) end
	end
end

function ArmyView.deselect()
	for armyId in pairs(selectedArmyIds) do
		local model = armyParts[armyId]
		if model then
			local hl = model:FindFirstChild("Selection")
			if hl then hl.Enabled = false end
		end
	end
	selectedArmyIds = {}
	selectedArmyId = nil
	for cb in pairs(onArmySelectedListeners) do
		pcall(cb, nil, false)
	end
end

function ArmyView.onArmySelected(cb)
	if type(cb) ~= "function" then return function() end end
	onArmySelectedListeners[cb] = true
	return function() onArmySelectedListeners[cb] = nil end
end

function ArmyView.getModel(armyId)
	return armyParts[armyId]
end

function ArmyView.getSelectedArmyId()
	return selectedArmyId
end

function ArmyView.getSelectedArmyIds()
	local list = {}
	for id in pairs(selectedArmyIds) do table.insert(list, id) end
	return list
end

function ArmyView.setBundle(bundle)
	bundleRef = bundle
	-- Force re-render of banner text after bundle becomes known
	for armyId in pairs(armyParts) do dirtyArmies[armyId] = true end
end

function ArmyView.setHoverProvince(provinceId)
	if hoverProvinceId == provinceId then return end
	local prev = hoverProvinceId
	hoverProvinceId = provinceId
	-- Mark all armies whose province is the prev OR new hover province as dirty (re-evaluate visibility/position)
	for armyId, army in pairs(ClientStateCache.allArmies()) do
		if army.provinceId == prev or army.provinceId == provinceId then
			dirtyArmies[armyId] = true
		end
	end
end

function ArmyView.init()
	if heartbeatConn then return end -- idempotent

	if not ensureFolder() then
		task.defer(ArmyView.init)
		return
	end
	ProvinceInteraction.addRaycastFolder(armiesFolder, classifyArmyClick)

	if ClientStateCache.onChangePrefix then
		stateSub = ClientStateCache.onChangePrefix("armies", function(_, path)
			local _, _, armyId = path:find("^armies%.([^%.]+)")
			if armyId then dirtyArmies[armyId] = true end
		end)
		battleSub = ClientStateCache.onChangePrefix("battles", function(_, path)
			-- C3: mark only the armies referenced by the changed battle dirty (state / in-battle
			-- visuals) instead of every rendered army. Battle removal clears each army's battleId,
			-- which the "armies" sub above already reconciles.
			local id = path and path:match("^battles%.([^%.]+)")
			if not id then return end
			local battle = ClientStateCache.allBattles()[id]
			if not battle then return end
			if battle.attackerArmyIds then for _, aid in ipairs(battle.attackerArmyIds) do dirtyArmies[aid] = true end end
			if battle.defenderArmyIds then for _, aid in ipairs(battle.defenderArmyIds) do dirtyArmies[aid] = true end end
		end)
		-- C3: removed the "countries" subscription that marked EVERY rendered army dirty on ANY
		-- country change (treasury/PP/faction churn every tick). Army rendering reads only static
		-- country fields (color, display name) -- read fresh on (re)build / owner change -- and the
		-- snapshot sub below covers initial load, so country churn no longer forces a full army
		-- reconcile each replication tick.
	end

	if ClientStateCache.onChange then
		snapshotSub = ClientStateCache.onChange("snapshot", function()
			reconcileAll()
		end)
	end

	if MapModeController and MapModeController.onChange then
		cameraSub = MapModeController.onChange(setCameraMode)
		cameraMode = MapModeController.current and MapModeController.current() or "field"
	end

	heartbeatConn = RunService.Heartbeat:Connect(function()
		if next(dirtyArmies) then
			rebuildStacks()
			for armyId in pairs(dirtyArmies) do
				reconcileOne(armyId)
			end
			table.clear(dirtyArmies)
		end
	end)

	renderConn = RunService.RenderStepped:Connect(function()
		if not next(hopState) then return end
		local now = os.clock()
		for armyId, hop in pairs(hopState) do
			local model = armyParts[armyId]
			if not model or not model.Parent then
				hopState[armyId] = nil
			else
				local a = math.clamp((now - hop.t0) / HOP_TIME, 0, 1)
				local p = hop.from:Lerp(hop.to, a)
				p = Vector3.new(p.X, p.Y + math.sin(a * math.pi) * HOP_ARC, p.Z)
				model:PivotTo(CFrame.new(p))
				if a >= 1 then
					model:PivotTo(CFrame.new(hop.to))
					hopState[armyId] = nil
				end
			end
		end
	end)

	if ClientStateCache.isReady and ClientStateCache.isReady() then
		reconcileAll()
	end
end

function ArmyView.destroy()
	if heartbeatConn then heartbeatConn:Disconnect(); heartbeatConn = nil end
	if renderConn then renderConn:Disconnect(); renderConn = nil end
	if stateSub then stateSub() end
	if battleSub then battleSub() end
	if countriesSub then countriesSub() end
	if snapshotSub then snapshotSub() end
	if cameraSub then cameraSub() end
	for _, model in pairs(armyParts) do
		if model.Parent then model:Destroy() end
	end
	-- Disconnect the per-army combat-animation signal handles before dropping the tables.
	for _, conns in pairs(combatAnimConns) do
		if type(conns) == "table" then
			if conns.shoot then conns.shoot:Disconnect() end
			if conns.reload then conns.reload:Disconnect() end
		end
	end
	armyParts = {}
	lastKnownState = {}
	dirtyArmies = {}
	hopState = {}
	provinceCenterCache = {}
	stackInfo = {}
	pulseTweens = {}
	combatAnimConns = {}
	combatAnimGen = {}
	animTracks = {}
	animState = {}
	selectedArmyId = nil
	selectedArmyIds = {}
end

return ArmyView
