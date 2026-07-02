local ArmyView = {}

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local WorldConstants = require(aow:WaitForChild("Shared"):WaitForChild("WorldConstants"))
local ClientStateCache = require(aow.Modules:WaitForChild("ClientStateCache"))
local ProvinceInteraction = require(aow.Modules:WaitForChild("ProvinceInteraction"))
local MapModeController = require(aow.Modules:WaitForChild("MapModeController"))
local CameraController = require(aow.Modules:WaitForChild("CameraController"))
local ProvincePositions = require(aow.Modules:WaitForChild("ProvincePositions"))
local SeaNodes = require(aow:WaitForChild("Shared"):WaitForChild("SeaNodes"))

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

-- Unit IDs that get the placeholder Musketeer model. Cavalry/dragoons get the horse
-- (CavalryModel) when EnableNewUnitModels is on. All other unit types (artillery)
-- use the generic Banner-Pin (disc + pole + flag) until their own models are added.
local INFANTRY_UNIT_IDS = {
	line_infantry = true,
	light_infantry = true,
	militia_forces = true,
	irregular_forces = true,
	professional_infantry = true,
}

local CAVALRY_UNIT_IDS = {
	cavalry = true,
	dragoons = true,
}

local MUSKETEER_TEMPLATE = nil
local MUSKETEER_TARGET_HEIGHT = 1.85  -- world studs, scaled for 2048 map (was 16.8 @ 18665; x0.110)

local CAVALRY_TEMPLATE = nil
local CAVALRY_TARGET_HEIGHT = 1.7  -- world studs; horses read slightly under the 1.85 musketeer

-- Sea transport (C9): any army standing on a sea node renders as a ship, regardless of
-- composition. The Ship asset is ~212 MeshParts and 58.4 studs long, so ALL heavy prep
-- (part properties + ScaleTo + Anchor placement) happens ONCE on a cached template;
-- buildShipModel only clones + recolors sails/flags per army.
local SHIP_TEMPLATE = nil          -- prepped (scaled/anchored/no-collide) template, cloned per army
local SHIP_TARGET_LENGTH = 3       -- world studs bow-to-stern; masts land ~1.7, near the musketeer
local SHIP_LABEL_CLEARANCE = 0.8   -- banner clearance above the mast tops
local SHIP_LABEL_OFFSET_Y = 2.5    -- recomputed from the scaled bounding box at template prep
-- The big hull mesh is named "Cube"; it carries the state tint (attack red etc.) and the
-- selection pulse. Unlike the cavalry Body it is NOT owner-coloured (sails/flags carry that),
-- so tinting lerps from -- and restores to -- the asset's own wood colour, captured at prep.
local SHIP_HULL_COLOR = Color3.fromRGB(105, 80, 56)
-- Sail/flag mesh names in the Ship asset (exact): sails get the owner colour washed toward
-- white (tinted canvas, Fabric material kept -- Color-only writes never touch Material);
-- the small mast-top flags fly the full owner colour.
local SHIP_SAIL_NAMES = {
	["Plane"] = true,
	["Plane.001"] = true,
	["Plane.002"] = true,
	["Plane.003"] = true,
	["Plane.004"] = true,
	["Plane.005"] = true,
}
local SHIP_FLAG_NAMES = {
	["Plane.006"] = true,
	["Plane.007"] = true,
	["Plane.008"] = true,
}

local function getMusketeerTemplate()
	if MUSKETEER_TEMPLATE then return MUSKETEER_TEMPLATE end
	local rs = game:GetService("ReplicatedStorage")
	local models = rs:FindFirstChild("Models")
	local m = models and models:FindFirstChild("Musketeer")
	if m then MUSKETEER_TEMPLATE = m end
	return MUSKETEER_TEMPLATE
end

local function getCavalryTemplate()
	if CAVALRY_TEMPLATE then return CAVALRY_TEMPLATE end
	local rs = game:GetService("ReplicatedStorage")
	local models = rs:FindFirstChild("Models")
	local m = models and models:FindFirstChild("CavalryModel")
	if m then CAVALRY_TEMPLATE = m end
	return CAVALRY_TEMPLATE
end

-- One-time Ship template prep (never per army -- the asset is ~212 MeshParts): clone,
-- anchor/no-collide every part (banner-pin pattern), scale so the ship is SHIP_TARGET_LENGTH
-- studs bow-to-stern, then add the invisible Anchor PrimaryPart at the hull-bottom centre
-- (post-scale, so its 0.1 size stays fixed -- same ordering as the cavalry builder).
local function getShipTemplate()
	if SHIP_TEMPLATE then return SHIP_TEMPLATE end
	local models = ReplicatedStorage:FindFirstChild("Models")
	local src = models and models:FindFirstChild("Ship")
	if not src then return nil end

	local model = src:Clone()
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = false
			p.CanTouch = false
			p.CanQuery = true
			p.Massless = true
			p.CastShadow = false
			p.Locked = true
		end
	end

	-- Scale by measured length (the longest horizontal extent), not a hardcoded 58.4, so a
	-- re-exported asset stays proportionate. ScaleTo replaces the *absolute* scale, hence the
	-- multiply by the current scale (same rationale as the musketeer/cavalry builders).
	if model.ScaleTo and model.GetScale then
		local currentScale = model:GetScale()
		local _, bbSize0 = model:GetBoundingBox()
		local length = math.max(bbSize0.X, bbSize0.Z)
		if length > 0 then
			model:ScaleTo(currentScale * (SHIP_TARGET_LENGTH / length))
		end
	end

	-- Anchor: invisible PrimaryPart with NO rotation at the post-scale bounding-box bottom
	-- centre, so a ground-level pivot floats the hull on the (zero-thickness) sea tile and
	-- PivotTo/lookAt translates/turns the whole ship (banner-pin pattern).
	local cf, bbSize = model:GetBoundingBox()
	local anchor = Instance.new("Part")
	anchor.Name = "Anchor"
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.Massless = true
	anchor.CFrame = CFrame.new(cf.Position.X, cf.Position.Y - bbSize.Y * 0.5, cf.Position.Z)
	anchor.Parent = model
	model.PrimaryPart = anchor

	-- The anchor sits at hull-bottom, so the banner offset must clear the full mast height.
	SHIP_LABEL_OFFSET_Y = bbSize.Y + SHIP_LABEL_CLEARANCE

	-- Wood colour the state tint restores to (see SHIP_HULL_COLOR).
	local hull = model:FindFirstChild("Cube", true)
	if hull and hull:IsA("BasePart") then
		SHIP_HULL_COLOR = hull.Color
	end

	SHIP_TEMPLATE = model
	return SHIP_TEMPLATE
end

local function modelTypeFor(unitTypeId)
	if unitTypeId and INFANTRY_UNIT_IDS[unitTypeId] then return "musketeer" end
	if WorldConstants.EnableNewUnitModels and unitTypeId and CAVALRY_UNIT_IDS[unitTypeId] then return "cavalry" end
	return "banner_pin"
end

-- Army-aware model kind: an army standing on a sea node is a ship (C9 sea transport), which
-- overrides the composition-derived kind; on land the dominant unit decides as before. This is
-- the single decision point for BOTH the reconcile rebuild compare and the initial build.
local function modelTypeForArmy(army, dominantUnitId)
	if WorldConstants.EnableSeaTransport and army and SeaNodes.isSea(army.provinceId) then
		return "ship"
	end
	return modelTypeFor(dominantUnitId)
end


local BASE_LIFT = 0.11  -- scaled for 2048 map (was 1)
-- HOI4-style movement: the token WAITS at its origin while the move arrow fills
-- (server-timed), then glides straight into the new tile on arrival. The glide is a flat
-- slide (no vertical arc) at the terrain-derived height, so the unit never bounces and
-- never creeps upward over repeated moves.
local HOP_TIME = 0.35

-- Reduced sizes — disc fits comfortably inside an ~86-stud province.
-- The Base cylinder is laid flat: Cylinder shape's axis is along its X-axis.
-- We bake CFrame.Angles(0,0,pi/2) into Base's offset so it lies flat.
local BASE_SIZE   = Vector3.new(0.22, 3.07, 3.07)   -- scaled for 2048 map (was 2, 28, 28)
local POLE_SIZE   = Vector3.new(0.088, 3.29, 0.088) -- was 0.8, 30, 0.8
local FLAG_SIZE   = Vector3.new(1.1, 0.66, 0.044)   -- was 10, 6, 0.4

-- Local-space offsets relative to a hidden Anchor part at (0,0,0)
local BASE_OFFSET_Y = BASE_SIZE.X * 0.5         -- = 1
local POLE_OFFSET_Y = BASE_SIZE.X + POLE_SIZE.Y * 0.5  -- = 17
local FLAG_OFFSET   = Vector3.new(0.55, BASE_SIZE.X + POLE_SIZE.Y - 0.44, 0)  -- near top of pole, offset to side (scaled: 5->0.55, -4->-0.44)
local BB_STUDS_OFFSET = Vector3.new(0, BASE_SIZE.X + POLE_SIZE.Y + 0.88, 0)  -- scaled (+8 -> +0.88)

-- Module state
local armyParts = {}
local labelRefs = {} -- [armyId] = { bb = BillboardGui, scale = UIScale } cached so the per-frame size
-- pass avoids FindFirstChild; populated lazily, cleared in destroyModelFor / ArmyView.destroy.
local lastLabelCamCF = nil -- camera CFrame the label-size pass last ran for (skip recompute when still)
local animTracks = {}                -- [armyId] = { Idle, Walk, Shoot, Reload }  AnimationTrack table
local animState = {}                 -- [armyId] = currently-playing state name (cached to avoid restarting tracks)
local combatAnimConns = {}           -- [armyId] = { shoot = conn, reload = conn }  signal handles for the shoot/reload loop
local combatAnimGen = {}             -- [armyId] = generation counter — increments to invalidate pending task.delay callbacks
local lastKnownState = {}
local dirtyArmies = {}
local hopState = {}                 -- [armyId] = { from = Vector3, to = Vector3, t0 = os.clock() } (arrival hop)
local lastFacing = {}               -- [armyId] = Vector3 (unit, horizontal) heading the model faces
local provinceCenterCache = {}
local stackInfo = {}                -- [provinceId..":"..ownerTag] = { armyIds (sorted), strongestId }
local pulseTweens = {}
local selectedArmyId = nil
local selectedArmyIds = {}          -- multi-selection set
local armiesFolder = nil
local mapFolder = nil
local heartbeatConn = nil
local renderConn = nil
local stateSub, battleSub, countriesSub, snapshotSub, provinceSub
local cameraSub
-- perf: coalesce machinery (gated by WorldConstants.UseArmyViewCoalesce).
-- reconcileQueued collapses multiple same-frame snapshots into ONE deferred reconcileAll() pass.
local reconcileQueued = false
-- provinceOccSig[provinceId] = last-seen occupation signature ("byTag|required|progress") so a province
-- delta that doesn't change the only province-record field reconcileOne reads (prov.occupation) can skip
-- the allArmies() scan. nil entry = unknown -> treated as "changed" (iterate) for correctness.
local provinceOccSig = {}
local cameraMode = "field"
local onArmySelectedListeners = {}
local recentRetryArmies = {}
local hoverProvinceId = nil
local bundleRef = nil               -- set by ArmyView.setBundle for unit-type names

local function ensureFolder()
	if armiesFolder and armiesFolder.Parent then return armiesFolder end
	mapFolder = workspace:FindFirstChild("ArtOfWarMap")
	if not mapFolder then return nil end
	armiesFolder = mapFolder:FindFirstChild("Armies")
	if not armiesFolder then
		armiesFolder = Instance.new("Folder")
		armiesFolder.Name = "Armies"
		armiesFolder.Parent = mapFolder
	end
	return armiesFolder
end

local function locateProvincePart(provinceId)
	-- Resolve by the stable part NAME (via ProvincePositions), never the stale province_id attribute,
	-- so a unit token never caches a wrong (e.g. ocean) position during the boot re-stamp window.
	return ProvincePositions.partOf(provinceId)
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

local CountriesData = require(script.Parent.Parent.Data.Countries)
local function getOwnerFlag(ownerTag)
	local cd = CountriesData[ownerTag]
	return (cd and cd.flagAssetId) or ""
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

-- Forget all per-army tracking (anims, labels, selection, tweens) and hand back the model
-- WITHOUT destroying it, so the caller can either drop it (destroyModelFor) or ragdoll it
-- (a death). Returns the detached model or nil.
local function cleanupTracking(armyId)
	if combatAnimConns[armyId] then
		local c = combatAnimConns[armyId]
		if c.shoot then c.shoot:Disconnect() end
		if c.reload then c.reload:Disconnect() end
		combatAnimConns[armyId] = nil
	end
	combatAnimGen[armyId] = (combatAnimGen[armyId] or 0) + 1
	local model = armyParts[armyId]
	armyParts[armyId] = nil
	labelRefs[armyId] = nil
	lastKnownState[armyId] = nil
	hopState[armyId] = nil
	lastFacing[armyId] = nil
	animTracks[armyId] = nil
	animState[armyId] = nil
	if pulseTweens[armyId] then pulseTweens[armyId]:Cancel(); pulseTweens[armyId] = nil end
	if selectedArmyId == armyId then selectedArmyId = nil end
	selectedArmyIds[armyId] = nil
	return model
end

local function destroyModelFor(armyId)
	local model = cleanupTracking(armyId)
	if model and model.Parent then model:Destroy() end
end

-- Death effect: play the classic Roblox "oof", strip the banner/selection, sever the joints so
-- the body tumbles apart under gravity, fade every part, and clean up after DEATH_LIFETIME.
-- Cosmetic only (client-side; no combat state), so math.random is fine here. Concurrency is
-- capped so a mass wipe (an annexation disbanding a whole army list) can't spawn a physics storm.
local DEATH_SOUND_ID = "rbxasset://sounds/uuhhh.mp3" -- the classic Roblox character "oof"
local DEATH_FADE_TIME = 1.8
local DEATH_LIFETIME = 2
local DEATH_MAX_PHYSICS_PARTS = 40
local DEATH_MAX_CONCURRENT = 24
local activeDeaths = 0

local function playDeathFx(model)
	if not model then return end
	if not model.Parent or activeDeaths >= DEATH_MAX_CONCURRENT then
		model:Destroy()
		return
	end
	activeDeaths += 1
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BillboardGui") or d:IsA("SurfaceGui") or d:IsA("Highlight") or d:IsA("Humanoid") then
			d:Destroy()
		end
	end
	local root = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if root then
		local snd = Instance.new("Sound")
		snd.SoundId = DEATH_SOUND_ID
		snd.Volume = 0.6
		snd.RollOffMaxDistance = 140
		snd.Parent = root
		snd:Play()
	end
	pcall(function() model:BreakJoints() end)
	local n = 0
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			n += 1
			if n <= DEATH_MAX_PHYSICS_PARTS then
				p.Anchored = false
				p.CanCollide = false
				p.CanQuery = false
				p.AssemblyLinearVelocity = Vector3.new((math.random() - 0.5) * 8, 4 + math.random() * 4, (math.random() - 0.5) * 8)
				p.AssemblyAngularVelocity = Vector3.new((math.random() - 0.5) * 10, (math.random() - 0.5) * 10, (math.random() - 0.5) * 10)
			end
			TweenService:Create(p, TweenInfo.new(DEATH_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Transparency = 1 }):Play()
		end
	end
	task.delay(DEATH_LIFETIME, function()
		activeDeaths -= 1
		if model then model:Destroy() end
	end)
end

-- Men-per-regiment + the overhead count formatter: full numbers with a SPACE thousands-separator
-- ("1 000", "250 000" -- no comma/dot, region-safe), switching to "M" only at >= 1,000,000.
local REGIMENT_STRENGTH = 1000
local function abbrevMen(n)
	n = math.floor((n or 0) + 0.5)
	if n >= 1e6 then
		local s = (string.format("%.1f", n / 1e6):gsub("%.0$", ""))
		return s .. "M"
	end
	return (tostring(n):reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^%s+", ""))
end

-- Shared overhead palette/fonts: match the in-world city/battle labels (Garamond serif, dark plate,
-- brown hairline, gold accents). FACE_COUNT = the regiment-count font (Merriweather SemiBold).
local OVH_PLATE = Color3.fromRGB(18, 12, 8)
local OVH_HAIRLINE = Color3.fromRGB(60, 40, 22)
local OVH_CREAM = Color3.fromRGB(248, 240, 218)
local FACE_COUNT = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.SemiBold, Enum.FontStyle.Normal)
local FACE_TAG_MONO = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal)
local OVH_BORDER = Color3.fromRGB(58, 47, 31) -- province-panel CountryBadge subtle border
local OVH_TAGWHITE = Color3.fromRGB(245, 241, 232) -- province-panel CountryBadge tag colour
local BANNER_SCALE = 0.6 -- constant on-screen label size (keeps aspect ratio); the size knob (original was 0.85)
-- A Roblox BillboardGui with an Offset Size GROWS on-screen as the camera gets farther (the "too big
-- when zoomed out" quirk). To hold a CONSTANT on-screen size we counter it every frame: scale the label
-- by LABEL_REF_DISTANCE / (camera->army distance). Labels also hide past LABEL_HIDE_ZOOM for a clean
-- zoomed-out map. BANNER_DESIGN_W/H = base px; LABEL_REF_DISTANCE calibrates the constant size.
local BANNER_DESIGN_W = 204
local BANNER_DESIGN_H = 60
local LABEL_REF_DISTANCE = 44 -- scaled for 2048 map (was 400 @ 18665); on-screen banner size knob (smaller = smaller banner)
local LABEL_HIDE_ZOOM = 1208 -- scaled for 2048 map (was 11000); labels hide past this camera distance

-- Overhead banner (Rise-of-Nations style), laid out as two adjacent elements:
--   [ crest panel ]  [ dark count box ]
-- with a thin capture bar directly below the count box. The crest is its OWN panel (not inside the
-- box). "Bg" is a transparent container kept ONLY so reconcileOne's bg:FindFirstChild lookups still
-- resolve; CountLabel/CaptureTrack are direct children of it (siblings of the box)
-- so those lookups are unchanged. reconcileOne fills crest colour/tag, the count and the
-- capture bar by element name. Adornee/offset/parent are caller-supplied.
local function buildBannerGui(adornee, studsOffset, _factionColor)
	local bb = Instance.new("BillboardGui")
	bb.Name = "Label"
	bb.Adornee = adornee
	bb.Size = UDim2.fromOffset(math.floor(BANNER_DESIGN_W * BANNER_SCALE + 0.5), math.floor(BANNER_DESIGN_H * BANNER_SCALE + 0.5))
	bb.StudsOffset = studsOffset
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 0
	bb.Enabled = false

	-- Transparent container (NOT a plate). Name "Bg" preserved for reconcileOne's lookups.
	local bg = Instance.new("Frame")
	bg.Name = "Bg"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundTransparency = 1
	bg.BorderSizePixel = 0
	bg.Parent = bb

	-- Shrink the whole label uniformly (keeps aspect ratio); child offsets stay in the 204×56 design
	-- space and UIScale maps them into the (scaled) BillboardGui canvas.
	local uiScale = Instance.new("UIScale")
	uiScale.Scale = BANNER_SCALE
	uiScale.Parent = bg

	-- ── Crest panel (left, its own panel) ──────────────────────────────────────────────────────
	local crest = Instance.new("Frame")
	crest.Name = "Crest"
	crest.Position = UDim2.fromOffset(2, 2)
	crest.Size = UDim2.fromOffset(44, 44)
	crest.BackgroundColor3 = Color3.fromRGB(60, 60, 60) -- recoloured (vivid) per-owner by reconcileOne
	crest.BorderSizePixel = 0
	crest.ZIndex = 2
	crest.Parent = bg
	local crestCorner = Instance.new("UICorner")
	crestCorner.CornerRadius = UDim.new(0, 4)
	crestCorner.Parent = crest
	-- Subtle dark border, matching the province-panel CountryBadge (static, not gold, not recoloured).
	local crestStroke = Instance.new("UIStroke")
	crestStroke.Name = "AccentStroke"
	crestStroke.Color = OVH_BORDER
	crestStroke.Thickness = 1
	crestStroke.Transparency = 0.5
	crestStroke.Parent = crest
	-- Future coat-of-arms: set CrestImage.Image to an asset id and it covers the colour+tag.
	local crestImg = Instance.new("ImageLabel")
	crestImg.Name = "CrestImage"
	crestImg.Size = UDim2.fromScale(1, 1)
	crestImg.BackgroundTransparency = 1
	crestImg.Image = ""
	crestImg.ScaleType = Enum.ScaleType.Crop
	crestImg.ZIndex = 4
	crestImg.Parent = crest
	local crestImgCorner = Instance.new("UICorner")
	crestImgCorner.CornerRadius = UDim.new(0, 4)
	crestImgCorner.Parent = crestImg
	-- Tag matches the province-panel badge: white RobotoMono, fixed size, centred (NOT TextScaled).
	local crestTag = Instance.new("TextLabel")
	crestTag.Name = "CrestTag"
	crestTag.Size = UDim2.fromScale(1, 1)
	crestTag.BackgroundTransparency = 1
	crestTag.Text = ""
	crestTag.TextColor3 = OVH_TAGWHITE
	crestTag.FontFace = FACE_TAG_MONO
	crestTag.TextSize = 16
	crestTag.TextStrokeTransparency = 0.5
	crestTag.TextStrokeColor3 = Color3.fromRGB(10, 8, 6)
	crestTag.ZIndex = 5
	crestTag.Parent = crest

	-- ── Count box (dark plate, centre) ─────────────────────────────────────────────────────────
	local box = Instance.new("Frame")
	box.Name = "CountBox"
	box.Position = UDim2.fromOffset(54, 2)
	box.Size = UDim2.fromOffset(114, 44)
	box.BackgroundColor3 = OVH_PLATE
	box.BackgroundTransparency = 0.12
	box.BorderSizePixel = 0
	box.ZIndex = 1
	box.Parent = bg
	local boxCorner = Instance.new("UICorner")
	boxCorner.CornerRadius = UDim.new(0, 4)
	boxCorner.Parent = box
	local boxStroke = Instance.new("UIStroke")
	boxStroke.Color = OVH_HAIRLINE
	boxStroke.Thickness = 1
	boxStroke.Transparency = 0.3
	boxStroke.Parent = box
	-- (Decluttered: the gradient sheen + ornamental corner brackets were removed so a screen full of
	-- banners reads cleanly during big battles. The box is now a plain dark plate.)

	-- Occupied/siege marker: a small flag glyph at the box's top-right, shown ALWAYS (even when the
	-- detail bars are hidden) while this army is occupying/sieging its tile. reconcileOne toggles it.
	local occGlyph = Instance.new("TextLabel")
	occGlyph.Name = "OccupyGlyph"
	occGlyph.AnchorPoint = Vector2.new(1, 0)
	occGlyph.Position = UDim2.fromOffset(167, 5)
	occGlyph.Size = UDim2.fromOffset(13, 13)
	occGlyph.BackgroundTransparency = 1
	occGlyph.Text = "\u{2691}"
	occGlyph.TextColor3 = Color3.fromRGB(235, 196, 90)
	occGlyph.TextScaled = true
	occGlyph.TextStrokeTransparency = 0.4
	occGlyph.TextStrokeColor3 = OVH_PLATE
	occGlyph.Visible = false
	occGlyph.ZIndex = box.ZIndex + 5
	occGlyph.Parent = bg

	-- Morale (green) + Organization (yellow) thin bars below the count box (reconcileOne fills them).
	-- Direct children of bg so bg:FindFirstChild resolves MoraleFill/OrgFill.
	local function makeBar(name, y, fillColor)
		local track = Instance.new("Frame")
		track.Name = name .. "Track"
		track.Position = UDim2.fromOffset(54, y)
		track.Size = UDim2.fromOffset(114, 3)
		track.BackgroundColor3 = Color3.fromRGB(40, 30, 18)
		track.BackgroundTransparency = 0.1
		track.BorderSizePixel = 0
		track.Visible = false -- detail bar: revealed only when the unit is selected or in combat
		track.ZIndex = 2
		track.Parent = bg
		local tc = Instance.new("UICorner")
		tc.CornerRadius = UDim.new(0, 2)
		tc.Parent = track
		local fill = Instance.new("Frame")
		fill.Name = name .. "Fill"
		fill.Size = UDim2.fromScale(0, 1)
		fill.BackgroundColor3 = fillColor
		fill.BorderSizePixel = 0
		fill.ZIndex = 3
		fill.Parent = track
		local fc = Instance.new("UICorner")
		fc.CornerRadius = UDim.new(0, 2)
		fc.Parent = fill
	end
	makeBar("Morale", 47, Color3.fromRGB(90, 170, 80))
	makeBar("Org", 51, Color3.fromRGB(220, 180, 70))

	-- CountLabel sits ON the box but is a sibling of it (direct child of Bg) so reconcileOne's
	-- bg:FindFirstChild("CountLabel") still resolves; higher ZIndex keeps it above the plate.
	local count = Instance.new("TextLabel")
	count.Name = "CountLabel"
	count.Position = UDim2.fromOffset(54, 2)
	count.Size = UDim2.fromOffset(114, 44)
	count.BackgroundTransparency = 1
	count.Text = ""
	count.TextColor3 = OVH_CREAM
	count.FontFace = FACE_COUNT
	count.TextSize = 26
	count.TextXAlignment = Enum.TextXAlignment.Center
	count.TextYAlignment = Enum.TextYAlignment.Center
	count.TextStrokeTransparency = 0.25
	count.TextStrokeColor3 = OVH_PLATE
	count.ZIndex = 4
	count.Parent = bg

	-- Capture progress bar directly below the count box (hidden until occupying).
	-- Instant capture has no progress to show -- skip building the bar entirely.
	if not WorldConstants.EnableInstantCapture then
		local capTrack = Instance.new("Frame")
		capTrack.Name = "CaptureTrack"
		capTrack.Position = UDim2.fromOffset(54, 55)
		capTrack.Size = UDim2.fromOffset(114, 3)
		capTrack.BackgroundColor3 = Color3.fromRGB(44, 32, 18)
		capTrack.BackgroundTransparency = 0.1
		capTrack.BorderSizePixel = 0
		capTrack.Visible = false
		capTrack.ZIndex = 2
		capTrack.Parent = bg
		local capCorner = Instance.new("UICorner")
		capCorner.CornerRadius = UDim.new(0, 2)
		capCorner.Parent = capTrack
		local capFill = Instance.new("Frame")
		capFill.Name = "CaptureFill"
		capFill.Size = UDim2.fromScale(0, 1)
		capFill.BackgroundColor3 = Color3.fromRGB(235, 196, 90)
		capFill.BorderSizePixel = 0
		capFill.ZIndex = 3
		capFill.Parent = capTrack
		local capFillCorner = Instance.new("UICorner")
		capFillCorner.CornerRadius = UDim.new(0, 2)
		capFillCorner.Parent = capFill
	end

	return bb
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

	-- Offset scaled with the 40%-larger model so the label keeps clearance above the taller head.
	local bb = buildBannerGui(head, Vector3.new(0, 2.74, 0), factionColor)  -- scaled for 2048 map (was 25)
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

-- Static horse mesh (Body + Tail, no rig): every part is anchored and the whole model moves
-- via PivotTo, exactly like the banner pin. No animTracks entry is ever created, so
-- setAnimState no-ops for this kind.
local function buildCavalryModel(armyId, factionColor)
	local template = getCavalryTemplate()
	if not template then
		return buildBannerPinModel(armyId, factionColor)
	end

	local model = template:Clone()
	model.Name = "army_" .. tostring(armyId)
	model:SetAttribute("armyId", armyId)
	model:SetAttribute("modelType", "cavalry")

	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = false
			p.CanTouch = false
			p.CanQuery = true
			p.Massless = true
			p.CastShadow = false
			p.Locked = true
		end
	end

	-- Faction color on the horse Body; the Tail stays black.
	local body = model:FindFirstChild("Body")
	if body and body:IsA("BasePart") then
		body.Color = factionColor
	end

	-- Scale before placing the anchor (its 0.1 size must stay fixed).
	-- Important: ScaleTo replaces the model's *absolute* scale; the template may already have
	-- a non-unit scale (Roblox's GetScale()), so multiply by current scale, not just the ratio.
	if model.ScaleTo and model.GetScale then
		local currentScale = model:GetScale()
		local _, bbSize0 = model:GetBoundingBox()
		if bbSize0.Y > 0 then
			model:ScaleTo(currentScale * (CAVALRY_TARGET_HEIGHT / bbSize0.Y))
		end
	end

	-- Anchor: invisible PrimaryPart with NO rotation at the post-scale bounding-box bottom
	-- center, so a ground-level pivot lands the hooves on the tile surface (no feetOffsetY
	-- lift needed) and PivotTo/lookAt translates/turns the whole horse (banner-pin pattern).
	local cf, bbSize = model:GetBoundingBox()
	local anchor = Instance.new("Part")
	anchor.Name = "Anchor"
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.Massless = true
	anchor.CFrame = CFrame.new(cf.Position.X, cf.Position.Y - bbSize.Y * 0.5, cf.Position.Z)
	anchor.Parent = model
	model.PrimaryPart = anchor

	-- The anchor sits at ground level, so the offset clears the whole horse -- roughly the
	-- same world height the musketeer label gets above its head.
	local bb = buildBannerGui(anchor, Vector3.new(0, CAVALRY_TARGET_HEIGHT + 2.5, 0), factionColor)
	bb.Parent = anchor

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
	return model
end

-- Ship (C9 sea transport): static mesh cloned from the prepped template -- part properties,
-- scale and the Anchor PrimaryPart are already baked in, so the per-army work is only the
-- sail/flag recolor + banner + highlight. Moves via PivotTo like the banner pin; no
-- animTracks entry is ever created, so setAnimState no-ops for this kind.
local function buildShipModel(armyId, factionColor)
	local template = getShipTemplate()
	if not template then
		return buildBannerPinModel(armyId, factionColor)
	end

	local model = template:Clone()
	model.Name = "army_" .. tostring(armyId)
	model:SetAttribute("armyId", armyId)
	model:SetAttribute("modelType", "ship")

	-- Sails read as tinted canvas (owner colour washed toward white); flags fly the full
	-- owner colour. Color-only writes keep the Fabric material.
	local sailColor = factionColor:Lerp(Color3.new(1, 1, 1), 0.35)
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			if SHIP_SAIL_NAMES[p.Name] then
				p.Color = sailColor
			elseif SHIP_FLAG_NAMES[p.Name] then
				p.Color = factionColor
			end
		end
	end

	-- The anchor sits at hull-bottom, so the offset clears the masts (computed from the scaled
	-- bounding box at template prep, ~2.5 at the 3-stud scale).
	local anchor = model.PrimaryPart
	local bb = buildBannerGui(anchor, Vector3.new(0, SHIP_LABEL_OFFSET_Y, 0), factionColor)
	bb.Parent = anchor

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
	return model
end

-- Unit tokens are pure presentation: never collide with the map, each other, or the player.
-- The builders already set this, but enforce it uniformly here so a stray colliding part in a
-- model template (or a future builder) can't reintroduce physics shoving.
local function ensureNoCollide(model)
	if not model then return end
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			p.CanCollide = false
			p.CanTouch = false
		end
	end
end

-- Zero any residual velocity on un-anchored rig parts (the musketeer limbs). The HumanoidRootPart
-- is anchored so the assembly should already be inert, but this is cheap insurance against a limb
-- retaining motion after a glide and slowly floating the visible mesh off the token.
local function zeroModelVelocity(model)
	if not model then return end
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") and not p.Anchored then
			pcall(function()
				p.AssemblyLinearVelocity = Vector3.zero
				p.AssemblyAngularVelocity = Vector3.zero
			end)
		end
	end
end

-- Dispatch builder: the caller passes the resolved model kind (modelTypeForArmy) so the
-- initial build and the reconcile rebuild-on-kind-change compare can never disagree.
local function buildModel(armyId, factionColor, modelType)
	local model
	if modelType == "musketeer" then
		model = buildMusketeerModel(armyId, factionColor)
	elseif modelType == "cavalry" then
		model = buildCavalryModel(armyId, factionColor)
	elseif modelType == "ship" then
		model = buildShipModel(armyId, factionColor)
	else
		model = buildBannerPinModel(armyId, factionColor)
	end
	ensureNoCollide(model)
	return model
end

-- Per-camera-mode token transparency. Command map shows tokens at a soft 0.25; field mode shows them
-- fully (0). Both are < 1, so CanQuery stays true. Used by BOTH setCameraMode and the creation block so
-- they can never diverge -- the bug was setCameraMode forcing command -> 1 (invisible) on a mode switch
-- while creation used 0.25, so models vanished after a command->field->command round-trip.
local function modeTransparency(mode)
	return mode == "command" and 0.25 or 0
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
	-- Musketeer/cavalry/ship parts: tween every BasePart descendant (except invisible ones we own like Anchor)
	local mt = model:GetAttribute("modelType")
	if mt == "musketeer" or mt == "cavalry" or mt == "ship" then
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
		applyTransparency(model, modeTransparency(mode))
	end
end

local function ensurePulse(armyId, model, on)
	if on then
		if pulseTweens[armyId] then return end
		local target = model:FindFirstChild("Base") or model:FindFirstChild("Shako") or model:FindFirstChild("Body")
				or model:FindFirstChild("Cube", true) -- ship hull (nested in the mesh import, hence recursive)
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
			local target = model:FindFirstChild("Base") or model:FindFirstChild("Shako") or model:FindFirstChild("Body")
				or model:FindFirstChild("Cube", true) -- ship hull (nested in the mesh import, hence recursive)
			if target then target.Transparency = cameraMode == "command" and 1 or 0 end
		end
	end
end

local function computePosition(army, state)
	local center = provinceCenter(army.provinceId)
	if not center then return nil end
	local x, z, topY = center.x, center.z, center.topY

	-- The token holds at its ORIGIN province while the move arrow fills (its provinceId
	-- stays the origin until the server relocates it on completion, which then triggers the
	-- arrival glide). It sits at terrain height the whole time -- no moving/retreat lift, so
	-- there is no vertical snap when a move is ordered and no upward drift over repeated moves.
	if state == "attacking" then
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
	local y = topY + BASE_LIFT + modelLift
	return Vector3.new(x, y, z)
end

-- Heading: a moving/retreating unit faces its destination; an attacking unit faces
-- the contested tile it's pushing into. Horizontal only (no pitch). Returns a unit
-- Vector3 or nil. facingCFrame applies it, falling back to the army's last heading
-- so an idle unit keeps facing where it last marched.
local function facingDirFor(army, state)
	if (state == "moving" or state == "retreating") and army.movement then
		local from = provinceCenter(army.movement.fromProvinceId)
		local to = provinceCenter(army.movement.toProvinceId)
		if from and to then
			local d = Vector3.new(to.x - from.x, 0, to.z - from.z)
			if d.Magnitude > 0.01 then return d.Unit end
		end
	elseif state == "attacking" and army.originProvinceId then
		local from = provinceCenter(army.originProvinceId)
		local here = provinceCenter(army.provinceId)
		if from and here then
			local d = Vector3.new(here.x - from.x, 0, here.z - from.z)
			if d.Magnitude > 0.01 then return d.Unit end
		end
	end
	return nil
end

local function facingCFrame(armyId, pos, dir)
	local f = dir or lastFacing[armyId]
	if f then return CFrame.lookAt(pos, pos + f) end
	return CFrame.new(pos)
end

local function reconcileOne(armyId)
	local army = ClientStateCache.allArmies()[armyId]
	if not army then
		-- The army record is gone (destroyed/annexed/disbanded) -- ragdoll the model with the
		-- oof instead of instantly deleting it. Stack-hide and model-kind-change removals below
		-- keep the plain destroy (the army still exists; only its rendered model is swapped).
		local model = cleanupTracking(armyId)
		if model then playDeathFx(model) end
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

	-- Rebuild model if the army's model kind changed (infantry -> cavalry composition shift,
	-- or an embark/disembark flipping land <-> sea; a sea node always means "ship").
	local dominantId, _ = dominantUnit(army)
	local desiredModelType = modelTypeForArmy(army, dominantId)
	if model and last.modelType ~= nil and last.modelType ~= desiredModelType then
		destroyModelFor(armyId)
		model = nil
	end
	if not model then
		model = buildModel(armyId, color, desiredModelType)
		armyParts[armyId] = model
		newlyCreated = true
	end

	-- Compute position AFTER the model exists so the modelType-aware modelLift is applied
	-- correctly on the very first reconcile (otherwise musketeer would pivot to ground level
	-- with HRP-centered offset wrong, half-clipping into the tile).
	local pos = computePosition(army, state)
	if not pos then return end

	-- perf: the Label BillboardGui and its "Bg" container are built once per model and never
	-- reparented/renamed, so resolve them ONCE here (model is finalized above) and reuse the refs
	-- for the ~5 lookup sites below instead of repeating the FindFirstChild chain each reconcile.
	local label = (model:FindFirstChild("Pole") and model.Pole:FindFirstChild("Label"))
		or (model:FindFirstChild("Head") and model.Head:FindFirstChild("Label"))
		or (model:FindFirstChild("Anchor") and model.Anchor:FindFirstChild("Label"))
	local bg = label and label:FindFirstChild("Bg")

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
		-- Cavalry parts (Tail stays black)
		local horseBody = model:FindFirstChild("Body")
		if horseBody then horseBody.Color = applied end
		-- Ship hull: state-tint over the asset's wood colour, never the owner colour (the
		-- sails/flags carry that, recoloured at build). modelType-gated so only ship models
		-- pay the recursive lookup.
		local hull = model:GetAttribute("modelType") == "ship" and model:FindFirstChild("Cube", true) or nil
		if hull then hull.Color = tint and SHIP_HULL_COLOR:Lerp(tint, 0.4) or SHIP_HULL_COLOR end
		-- Crest (works for all model types since Label is parented to Pole, Head or Anchor): tint the plate
		-- from the owner colour and stamp the 3-letter country tag.
		local crest = bg and bg:FindFirstChild("Crest")
		if crest then
			-- Match the province-panel CountryBadge: HSV-darkened country colour.
			local h, s, v = Color3.toHSV(color)
			crest.BackgroundColor3 = Color3.fromHSV(h, math.min(s, 0.6), math.min(v, 0.35))
			local crestFlag = getOwnerFlag(army.ownerTag)
			local tagLbl = crest:FindFirstChild("CrestTag")
			if tagLbl then
				tagLbl.Text = string.upper(tostring(army.ownerTag or ""))
				-- A decal replaces the 3-letter tag.
				tagLbl.Visible = (crestFlag == "")
			end
			local imgLbl = crest:FindFirstChild("CrestImage")
			if imgLbl then imgLbl.Image = crestFlag end
		end
	end

	-- Banner content: unit type + count, and total stack count if multiple armies
	local count = compositionCount(army)
	local domUnitId = dominantUnit(army)
	local nameText = unitDisplayName(domUnitId)
	-- If this army represents a stack of multiple armies (strongest), append "(+N)" indicator
	local key = tostring(army.provinceId) .. ":" .. tostring(army.ownerTag)
	local stack = stackInfo[key]
	local stackExtra = stack and #stack.armyIds > 1 and (" +" .. (#stack.armyIds - 1)) or ""

	if newlyCreated or last.count ~= count or last.stackExtra ~= stackExtra then
		local countLbl = bg and bg:FindFirstChild("CountLabel")
		if countLbl then
			local menText = abbrevMen(count * REGIMENT_STRENGTH)
			countLbl.Text = (stackExtra ~= "") and (menText .. stackExtra) or menText
		end
	end

	-- State icon + tint + pulse + animation
	if newlyCreated or last.state ~= state then
		local icon = bg and bg:FindFirstChild("StateIcon")
		if icon then icon.Text = STATE_ICON[state] or "" end
		local tint = TINT_BY_STATE[state]
		local applied = tint and color:Lerp(tint, 0.4) or color
		local base = model:FindFirstChild("Base")
		if base then base.Color = applied end
		local shako = model:FindFirstChild("Shako")
		if shako then shako.Color = applied end
		local horseBody = model:FindFirstChild("Body")
		if horseBody then horseBody.Color = applied end
		-- Ship hull: state-tint over the wood colour (restores it when the tint clears).
		local hull = model:GetAttribute("modelType") == "ship" and model:FindFirstChild("Cube", true) or nil
		if hull then hull.Color = tint and SHIP_HULL_COLOR:Lerp(tint, 0.4) or SHIP_HULL_COLOR end
		ensurePulse(armyId, model, state == "attacking")
		setAnimState(armyId, state)
	end

	-- On-map overhead extras: entrenchment as a shovel glyph + level, and the capture progress bar.
	-- Cheap (a few writes); refreshed every reconcile so both track live deltas.
	do
		local vbg = bg
		if vbg then
			-- Declutter: the morale/org/entrenchment/capture detail bars are hidden by default and reveal
			-- ONLY when this unit is selected or in active combat -- so a screen full of banners stays
			-- readable during big battles. The crest + count box (and the occupy glyph) are always shown.
			local inCombat = (army.battleId ~= nil) or state == "attacking" or state == "defending"
			local showDetails = inCombat or (selectedArmyIds[armyId] == true)

			-- Morale (green) + Organization (yellow) bars (detail).
			local moraleTrack = vbg:FindFirstChild("MoraleTrack")
			local moraleFill = moraleTrack and moraleTrack:FindFirstChild("MoraleFill")
			if moraleTrack then moraleTrack.Visible = showDetails end
			if moraleFill then
				moraleFill.Size = UDim2.fromScale(math.clamp((army.morale or 0) / 100, 0, 1), 1)
			end
			local orgTrack = vbg:FindFirstChild("OrgTrack")
			local orgFill = orgTrack and orgTrack:FindFirstChild("OrgFill")
			if orgTrack then orgTrack.Visible = showDetails end
			if orgFill then
				local baseOrg = army.baseOrganization or 10
				orgFill.Size = UDim2.fromScale(math.clamp((army.organization or baseOrg) / baseOrg, 0, 1), 1)
			end

			-- Occupation: a persistent flag glyph whenever this army is the occupier (always visible, so
			-- the signal survives when the detail bars are hidden) + the capture progress bar (detail only).
			-- Instant capture writes no occupation records, so the glyph instead marks Auto Capture
			-- (the "this army keeps taking tiles" signal) and the capture bar is never built.
			local prov = ClientStateCache.getProvince(army.provinceId)
			local occ = prov and prov.occupation
			local occupying = occ ~= nil and occ.byTag == army.ownerTag and (occ.required or 0) > 0
			local occGlyph = vbg:FindFirstChild("OccupyGlyph")
			if occGlyph then
				occGlyph.Visible = WorldConstants.EnableInstantCapture and army.autoCapture == true or occupying
			end
			local capTrack = vbg:FindFirstChild("CaptureTrack")
			local capFill = capTrack and capTrack:FindFirstChild("CaptureFill")
			if capTrack then
				-- Capture progress is ALWAYS shown while this army is occupying (not gated behind selection),
				-- so the player can always see how far along a tile capture is.
				capTrack.Visible = occupying
				if capFill and occupying then
					capFill.Size = UDim2.fromScale(math.clamp((occ.progress or 0) / occ.required, 0, 1), 1)
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
	-- Facing: a moving unit turns to face its destination (so it rotates the moment
	-- it's ordered, while waiting at origin), and keeps that heading once idle.
	local faceDir = facingDirFor(army, state)
	if faceDir then lastFacing[armyId] = faceDir end

	local moved = (not newlyCreated) and last.provinceId ~= nil and last.provinceId ~= army.provinceId
	if moved then
		local fromPos = model:GetPivot().Position
		if (fromPos - pos).Magnitude > 1 then
			hopState[armyId] = { from = fromPos, to = pos, t0 = os.clock() }
		else
			model:PivotTo(facingCFrame(armyId, pos, faceDir))
		end
	elseif hopState[armyId] then
		-- a hop is animating; don't fight it with an instant pivot
		hopState[armyId].to = pos
	else
		model:PivotTo(facingCFrame(armyId, pos, faceDir))
	end

	local hl = model:FindFirstChild("Selection")
	if hl then hl.Enabled = (selectedArmyId == armyId) or (selectedArmyIds[armyId] == true) end

	if label then label.Enabled = true end

	if newlyCreated then
		local target = modeTransparency(cameraMode)
		local canQuery = target < 1
		for _, partName in ipairs({"Base", "Pole", "Flag"}) do
			local p = model:FindFirstChild(partName)
			if p then
				p.Transparency = target
				p.CanQuery = canQuery
			end
		end
		local mtAttr = model:GetAttribute("modelType")
		if mtAttr == "musketeer" or mtAttr == "cavalry" or mtAttr == "ship" then
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
			dirtyArmies[prevId] = true -- re-run reconcile so its banner details hide
		end
		selectedArmyIds = {}
	end
	selectedArmyIds[armyId] = true
	selectedArmyId = armyId  -- track most recent
	dirtyArmies[armyId] = true -- re-run reconcile so its banner details reveal

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
		dirtyArmies[armyId] = true -- re-run reconcile so its banner details hide
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

-- Drag-box select: select every locally-owned army stack whose rendered token projects inside the
-- given viewport-space rectangle. One model is rendered per stack, so we collect the provinces those
-- tokens sit on and select each FULL stack (matching click-to-select). `additive` (Shift) adds to the
-- current selection; otherwise it replaces. Returns the number of armies now selected.
function ArmyView.selectArmiesInScreenRect(rectMin, rectMax, additive)
	local cam = workspace.CurrentCamera
	if not cam then return 0 end
	if not additive then ArmyView.deselect() end
	local allArmies = ClientStateCache.allArmies()
	local provincesHit = {}
	for armyId, model in pairs(armyParts) do
		local army = allArmies[armyId]
		if army and model and model.Parent and isLocallyOwned(army.ownerTag) then
			local sp, onScreen = cam:WorldToViewportPoint(model:GetPivot().Position)
			if onScreen and sp.X >= rectMin.X and sp.X <= rectMax.X and sp.Y >= rectMin.Y and sp.Y <= rectMax.Y then
				provincesHit[army.provinceId] = true
			end
		end
	end
	for provinceId in pairs(provincesHit) do
		selectStackOnProvince(provinceId, true) -- add the whole stack (additive within the box)
	end
	local count = 0
	for _ in pairs(selectedArmyIds) do count += 1 end
	return count
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

		-- Province changes (e.g. siege occupation progress) live on the PROVINCE record, not the
		-- army, so without this the overhead capture bar would go stale. Mark the armies standing on
		-- the changed province dirty so reconcileOne re-reads province.occupation for the bar.
		provinceSub = ClientStateCache.onChangePrefix("provinces", function(value, path)
			local idStr = path and path:match("^provinces%.([^%.]+)")
			local pid = idStr and tonumber(idStr)
			if not pid then return end
			-- perf: reconcileOne reads exactly ONE field off the province record -- prov.occupation
			-- (byTag/required/progress, drive the occupy glyph + capture bar). Province deltas replace the
			-- whole record every tick (pop/economy/etc), but unless occupation changed nothing about the
			-- army visuals changed. Gate the allArmies() scan on an occupation signature: skip when equal.
			if WorldConstants.UseArmyViewCoalesce then
				local prov = (type(value) == "table" and value) or ClientStateCache.getProvince(pid)
				local occ = type(prov) == "table" and prov.occupation or nil
				-- Signature folds the three occupation fields reconcileOne actually consumes. "0" = no occ.
				local sig = occ and (tostring(occ.byTag) .. "|" .. tostring(occ.required) .. "|" .. tostring(occ.progress)) or "0"
				if provinceOccSig[pid] == sig then return end -- occupation unchanged -> army visuals unaffected
				provinceOccSig[pid] = sig
			end
			for armyId, army in pairs(ClientStateCache.allArmies()) do
				if army.provinceId == pid then dirtyArmies[armyId] = true end
			end
		end)
	end

	if ClientStateCache.onChange then
		snapshotSub = ClientStateCache.onChange("snapshot", function()
			if not WorldConstants.UseArmyViewCoalesce then
				reconcileAll() -- legacy: reconcile immediately on every snapshot
				return
			end
			-- perf: collapse all snapshots that arrive within one frame into a SINGLE reconcileAll().
			-- We only schedule the deferred pass when none is already pending; reconcileQueued stays true
			-- until the deferred callback runs, so any further same-frame snapshots are absorbed. The
			-- deferred callback runs later THIS frame (task.defer = resume on the current frame's defer
			-- queue, never delayed across frames), reads the LATEST cache state, and reconciles once --
			-- so the final post-latest-snapshot reconcile is guaranteed to run and is never dropped.
			if reconcileQueued then return end
			reconcileQueued = true
			task.defer(function()
				reconcileQueued = false
				reconcileAll()
			end)
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
		-- Constant on-screen label size: an Offset-Size BillboardGui grows as the camera moves away, so we
		-- counter it by scaling the label INVERSELY with the camera->army distance (no clamp -- a clamp
		-- would let it drift at the zoom extremes); labels hide past LABEL_HIDE_ZOOM. Efficiency: the
		-- BillboardGui/UIScale refs are cached per army (no per-frame FindFirstChild), only the cheap
		-- Enabled flag is written each frame, and the size recompute (GetPivot + Size) runs ONLY when the
		-- camera actually moved (distances don't change otherwise) or a label is newly built.
		do
			local cam = workspace.CurrentCamera
			local zoom = CameraController.getZoom and CameraController.getZoom()
			-- perf: nothing to size/enable when no tokens exist -- skip the whole pass.
			if cam and type(zoom) == "number" and next(armyParts) ~= nil then
				local camCF = cam.CFrame
				local camMoved = camCF ~= lastLabelCamCF
				lastLabelCamCF = camCF
				local camPos = camCF.Position
				local visible = zoom <= LABEL_HIDE_ZOOM
				for armyId, model in pairs(armyParts) do
					local refs = labelRefs[armyId]
					local isNew = refs == nil
					if isNew then
						local label = (model:FindFirstChild("Pole") and model.Pole:FindFirstChild("Label"))
							or (model:FindFirstChild("Head") and model.Head:FindFirstChild("Label"))
							or (model:FindFirstChild("Anchor") and model.Anchor:FindFirstChild("Label"))
						if label then
							local lbg = label:FindFirstChild("Bg")
							refs = { bb = label, scale = lbg and lbg:FindFirstChildOfClass("UIScale") }
							labelRefs[armyId] = refs
						end
					end
					if refs then
						-- perf: only write Enabled when it actually flips (avoids a property write + its
						-- change/replication work every frame). Still runs each frame so it overrides
						-- reconcile's unconditional enable while zoomed out.
						if refs.bb.Enabled ~= visible then refs.bb.Enabled = visible end
						if visible and (camMoved or isNew) then
							local dist = math.max((camPos - model:GetPivot().Position).Magnitude, 1)
							local f = BANNER_SCALE * LABEL_REF_DISTANCE / dist
							if refs.scale then
								refs.scale.Scale = f
							end
							refs.bb.Size = UDim2.fromOffset(
								math.floor(BANNER_DESIGN_W * f + 0.5),
								math.floor(BANNER_DESIGN_H * f + 0.5)
							)
						end
					end
				end
			end
		end

		if not next(hopState) then return end
		local now = os.clock()
		for armyId, hop in pairs(hopState) do
			local model = armyParts[armyId]
			if not model or not model.Parent then
				hopState[armyId] = nil
			else
				local a = math.clamp((now - hop.t0) / HOP_TIME, 0, 1)
				-- Smoothstep ease-in-out for a clean slide; NO vertical arc, so the token glides
				-- straight from tile to tile (following terrain height between from/to) instead of
				-- bouncing. Y is interpolated only between the two terrain-derived endpoints.
				local e = a * a * (3 - 2 * a)
				local p = hop.from:Lerp(hop.to, e)
				-- Face the direction of travel during the glide, and keep that heading.
				local flat = Vector3.new(hop.to.X - hop.from.X, 0, hop.to.Z - hop.from.Z)
				if flat.Magnitude > 0.01 then
					local dir = flat.Unit
					lastFacing[armyId] = dir
					model:PivotTo(CFrame.lookAt(p, p + dir))
				else
					model:PivotTo(facingCFrame(armyId, p, nil))
				end
				if a >= 1 then
					model:PivotTo(facingCFrame(armyId, hop.to, nil))
					zeroModelVelocity(model)
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
	if provinceSub then provinceSub() end
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
	labelRefs = {}
	lastLabelCamCF = nil
	lastKnownState = {}
	dirtyArmies = {}
	hopState = {}
	lastFacing = {}
	provinceCenterCache = {}
	stackInfo = {}
	pulseTweens = {}
	combatAnimConns = {}
	combatAnimGen = {}
	animTracks = {}
	animState = {}
	selectedArmyId = nil
	selectedArmyIds = {}
	-- perf: reset coalesce state so a fresh init() re-arms the deferred reconcile and re-learns
	-- occupation signatures (a stale reconcileQueued=true would otherwise swallow the next snapshot).
	reconcileQueued = false
	provinceOccSig = {}
end

return ArmyView
