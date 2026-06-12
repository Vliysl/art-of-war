local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local uiFolder = aow:WaitForChild("UI")
local modulesFolder = aow:WaitForChild("Modules")

local UIRoot = require(uiFolder:WaitForChild("UIRoot"))
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local TopBar = require(uiFolder:WaitForChild("TopBar"))
local CountryPanel = require(uiFolder:WaitForChild("CountryPanel"))
local ProvinceTooltip = require(uiFolder:WaitForChild("ProvinceTooltip"))
local ProvinceDetailPanel = require(uiFolder:WaitForChild("ProvinceDetailPanel"))
local ProvinceCodes = require(ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Modules"):WaitForChild("ProvinceCodes"))
local ArmyPanel = require(uiFolder:WaitForChild("ArmyPanel"))
local ClaimScreen = require(uiFolder:WaitForChild("ClaimScreen"))
local BottomBar = require(uiFolder:WaitForChild("BottomBar"))
local UIKeybindings = require(uiFolder:WaitForChild("UIKeybindings"))
local NotificationFeed = require(uiFolder:WaitForChild("NotificationFeed"))
local CountryHeader = require(uiFolder:WaitForChild("CountryHeader"))
local DiplomacyWindow = require(uiFolder:WaitForChild("DiplomacyWindow"))
local EconomyWindow = require(uiFolder:WaitForChild("EconomyWindow"))
local ResearchWindow = require(uiFolder:WaitForChild("ResearchWindow"))
local SettingsMenu = require(uiFolder:WaitForChild("SettingsMenu"))
local KeybindsWindow = require(uiFolder:WaitForChild("KeybindsWindow"))
local Minimap = require(uiFolder:WaitForChild("Minimap"))
local MapModesBar = require(uiFolder:WaitForChild("MapModesBar"))
local FleetPanel = require(uiFolder:WaitForChild("FleetPanel"))

local tabsFolder = uiFolder:WaitForChild("Tabs")
local OverviewTab = require(tabsFolder:WaitForChild("OverviewTab"))
-- (Factions/Leaders/Policies/Laws/Doctrines tabs are required and mounted by DiplomacyWindow.)

local ClientStateCache = require(modulesFolder:WaitForChild("ClientStateCache"))
local ArmyView = require(aow.Modules:WaitForChild("ArmyView"))
local PathPreview = require(aow.Modules:WaitForChild("PathPreview"))
local MapModeController = require(modulesFolder:WaitForChild("MapModeController"))
local ProvinceInteraction = require(modulesFolder:WaitForChild("ProvinceInteraction"))
local WaterBodies = require(modulesFolder:WaitForChild("WaterBodies"))
local MapRenderer = require(modulesFolder:WaitForChild("MapRenderer"))
local UISound = require(uiFolder:WaitForChild("UISound"))
local ShortcutsOverlay = require(uiFolder:WaitForChild("ShortcutsOverlay"))

local UIController = {}

local localPlayer = Players.LocalPlayer
local remotes = {}
local countries = {}
local bundle = {}
local claimedTag = nil
local autoFieldRequested = false
local lastAutoShownTag = nil
local tabs = {}
local topBar, countryPanel, provinceTooltip, provinceDetailPanel, armyPanel, claimScreen, bottomBar, notifFeed, diplomacyWindow, economyWindow, researchWindow, settingsMenu, keybindsWindow, minimap, mapModesBar, shortcutsOverlay, fleetPanel, countryHeader
local selectedProvinceId = nil
local pendingCommand = nil
local lastWaterName = nil

local dirty = { countries = false, armies = false, provinces = false, fleets = false, claim = false }
local dirtyProvinceIds = {}   -- province ids changed since last refresh (targeted recolor)
local dirtyConn = nil

local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" }

local function invokeRemote(name, ...)
	local remote = remotes[name]
	if not remote then
		warn("[UI] invokeRemote: missing remote '" .. tostring(name) .. "'")
		return
	end
	if remote:IsA("RemoteEvent") then
		remote:FireServer(...)
	elseif remote:IsA("RemoteFunction") then
		return remote:InvokeServer(...)
	end
end

local function collectClaims()
	local list = {}
	for tag, country in ClientStateCache.allCountries() do
		if country.claimedBy then
			table.insert(list, tag)
		end
	end
	return list
end

local function buildBundleFromData()
	local dataFolder = aow:FindFirstChild("Data")
	if not dataFolder then return end

	local function loadMod(name)
		local module = dataFolder:FindFirstChild(name)
		if not module then return nil end
		local ok, result = pcall(require, module)
		if ok then return result end
		return nil
	end

	bundle.governmentTypes = loadMod("GovernmentTypes")
	bundle.ideologies = loadMod("Ideologies")
	bundle.policies = loadMod("Policies")
	bundle.doctrines = loadMod("Doctrines")
	bundle.doctrineSlots = loadMod("DoctrineSlots")
	bundle.factions = loadMod("Factions")
	bundle.leaderSlots = loadMod("LeaderSlots")
	bundle.leaderTraits = loadMod("LeaderTraits")
	bundle.unitTypes = loadMod("UnitTypes")
	bundle.shipTypes = loadMod("ShipTypes")
	bundle.terrains = loadMod("Terrains")
	bundle.climates = loadMod("Climates")
	bundle.cultures = loadMod("Cultures")
	bundle.religions = loadMod("Religions")
	bundle.tradeGoods = loadMod("TradeGoods")
	bundle.buildingTypes = loadMod("BuildingTypes")
	bundle.manufactories = loadMod("Manufactories")
	bundle.economyPolicies = loadMod("EconomyPolicies")
	bundle.countries = loadMod("Countries")

	countries = bundle.countries or {}
end

-- Header widgets rebuild their crest/badges on setCountry; skip the call when
-- nothing they display has changed (stats below still update every pass).
local lastHeaderSig = nil

local function refreshTopBar()
	if not topBar then return end
	if claimedTag then
		local country = ClientStateCache.getCountry(claimedTag) or countries[claimedTag]
		if country then
			local govName = nil
			local ideologyName = nil
			if bundle.governmentTypes and country.governmentForm then
				local g = bundle.governmentTypes[country.governmentForm]
				govName = g and g.displayName or tostring(country.governmentForm):gsub("_", " ")
			end
			if bundle.ideologies and country.ideology then
				local i = bundle.ideologies[country.ideology]
				ideologyName = i and i.displayName or tostring(country.ideology):gsub("_", " ")
			end
			local c = country.color
			local headerSig = table.concat({
				tostring(claimedTag), tostring(country.displayName),
				tostring(govName), tostring(ideologyName), tostring(country.flagAssetId),
				type(c) == "table" and ((c[1] or 0) .. "," .. (c[2] or 0) .. "," .. (c[3] or 0)) or "nocolor",
			}, "|")
			if headerSig ~= lastHeaderSig then
				lastHeaderSig = headerSig
				topBar.setCountry(claimedTag, country.displayName, country.color, govName, ideologyName, country.flagAssetId)
				if countryHeader and countryHeader.setCountry then
					countryHeader.setCountry(claimedTag, country.displayName, country.color, govName, ideologyName, country.flagAssetId)
				end
			end
			topBar.setStat("treasury", country.treasury, country.lastIncome)
			topBar.setStat("manpower", country.manpower, country.manpowerDelta)
			topBar.setStat("pp", country.politicalPower, country.politicalPowerGain)
			topBar.setStat("stability", country.stability)
			topBar.setStat("legitimacy", country.legitimacy)
			topBar.setStatColor("stability", UIStyle.stateColor(country.stability or 0))
			if countryHeader and countryHeader.setOpenState and countryPanel and countryPanel.isOpen then
				countryHeader.setOpenState(countryPanel.isOpen())
			end
		end
	else
		if lastHeaderSig ~= "unclaimed" then
			lastHeaderSig = "unclaimed"
			topBar.setCountry(nil, "Unclaimed", nil)
			if countryHeader and countryHeader.setCountry then countryHeader.setCountry(nil) end
		end
	end

	if countryPanel then
		if claimedTag then
			local country = ClientStateCache.getCountry(claimedTag) or countries[claimedTag]
			if country then
				local govName = nil
				local ideologyName = nil
				if bundle.governmentTypes and country.governmentForm then
					local g = bundle.governmentTypes[country.governmentForm]
					govName = g and g.displayName or tostring(country.governmentForm):gsub("_", " ")
				end
				if bundle.ideologies and country.ideology then
					local i = bundle.ideologies[country.ideology]
					ideologyName = i and i.displayName or tostring(country.ideology):gsub("_", " ")
				end
				if countryPanel.setCountry then
					countryPanel.setCountry(claimedTag, country.displayName, country.color, govName, ideologyName)
				end
			end
			if lastAutoShownTag ~= claimedTag then
				lastAutoShownTag = claimedTag
				if countryPanel.showWithAnim then
					countryPanel.showWithAnim()
				else
					countryPanel.root.Visible = true
				end
			end
			if bottomBar then bottomBar.setVisible(true) end
			if minimap then minimap.setVisible(true) end
		else
			lastAutoShownTag = nil
			if countryPanel.hideAll then
				countryPanel.hideAll()
			else
				countryPanel.root.Visible = false
			end
			if bottomBar then bottomBar.setVisible(false) end
			if minimap then minimap.setVisible(false) end
		end
	end
end

-- Tab updates destroy-and-rebuild their whole page, so hidden hosts skip the
-- rebuild and mark themselves stale; ensure*Fresh re-runs the update on reveal.
-- (The five politics tabs gate themselves inside DiplomacyWindow the same way.)
local lastTabCountry = nil
local overviewStale = false
local economyStale = false

local function refreshTabs()
	if not claimedTag then return end
	local country = ClientStateCache.getCountry(claimedTag) or countries[claimedTag]
	if not country then return end
	lastTabCountry = country
	for name, tab in tabs do
		if tab and tab.update then
			if name == "Overview" and countryPanel and countryPanel.isOpen and not countryPanel.isOpen() then
				overviewStale = true
			else
				local ok, err = pcall(tab.update, country, bundle)
				if not ok then warn("[UIController] tab update errored: " .. tostring(err)) end
				if name == "Overview" then overviewStale = false end
			end
		end
	end
	if economyWindow and economyWindow.update then
		if economyWindow.isOpen and economyWindow.isOpen() then
			local ok, err = pcall(economyWindow.update, country)
			if not ok then warn("[UIController] economyWindow update errored: " .. tostring(err)) end
			economyStale = false
		else
			economyStale = true
		end
	end
end

local function ensureOverviewFresh()
	if not overviewStale or not lastTabCountry then return end
	if not (countryPanel and countryPanel.isOpen and countryPanel.isOpen()) then return end
	if tabs.Overview and tabs.Overview.update then
		overviewStale = false
		local ok, err = pcall(tabs.Overview.update, lastTabCountry, bundle)
		if not ok then warn("[UIController] overview refresh errored: " .. tostring(err)) end
	end
end

local function ensureEconomyFresh()
	if not economyStale or not lastTabCountry then return end
	if not (economyWindow and economyWindow.isOpen and economyWindow.isOpen()) then return end
	if economyWindow.update then
		economyStale = false
		local ok, err = pcall(economyWindow.update, lastTabCountry)
		if not ok then warn("[UIController] economy refresh errored: " .. tostring(err)) end
	end
end

local function refresh()
	refreshTopBar()
	refreshTabs()
end

-- Open the diplomacy window via `openFn`, first closing the other movable windows
-- (mirrors toggleWindow's one-window-at-a-time rule), then sync bottom-bar state.
local function focusDiplomacyWindow(openFn)
	if not diplomacyWindow then return end
	local others = { economy = economyWindow, research = researchWindow }
	for id, w in pairs(others) do
		if w and w.isOpen() then
			w.toggle()
			if bottomBar and bottomBar.setActiveWindow then
				bottomBar.setActiveWindow(id, false)
			end
		end
	end
	openFn()
	if bottomBar and bottomBar.setActiveWindow then
		bottomBar.setActiveWindow("diplomacy", diplomacyWindow.isOpen())
	end
end

local function recordForPart(part)
	if not part then return nil end
	local id = part:GetAttribute("province_id")
	if id then
		local province = ClientStateCache.getProvince(id)
		if province then return province, id, part end
	end
	local owner = part:GetAttribute("owner")
	if not owner or owner == "" or owner == "NONE" then return nil end
	local ownerCountry = ClientStateCache.getCountry(owner)
	local rawName = part:GetAttribute("province_name") or part.Name
	local prettyName = tostring(rawName):gsub("^prov_%d+_", ""):gsub("_", " ")
	local code = part:GetAttribute("province_code") or ProvinceCodes.fromPartName(part.Name)
	return {
		id              = nil,
		code            = code,
		name            = prettyName,
		displayCityName = prettyName,
		ownerTag        = owner,
		controllerTag   = part:GetAttribute("controller") or owner,
		terrain         = part:GetAttribute("terrain")    or "unknown",
		climate         = part:GetAttribute("climate")    or "unknown",
		culture         = part:GetAttribute("culture")    or (ownerCountry and ownerCountry.primaryCulture) or "unknown",
		religion        = part:GetAttribute("religion")   or (ownerCountry and ownerCountry.stateReligion) or "unknown",
		tradeGood       = part:GetAttribute("trade_good") or "unknown",
		baseTax         = part:GetAttribute("base_tax")        or 0,
		baseProduction  = part:GetAttribute("base_production") or 0,
		baseManpower    = part:GetAttribute("base_manpower")   or 0,
		devTier         = part:GetAttribute("dev_tier")        or 0,
		infraTier       = part:GetAttribute("infra_tier")      or 0,
		fortTier        = part:GetAttribute("fort_tier")       or 0,
		isCity          = part:GetAttribute("is_city")         or false,
		centerOfTrade   = part:GetAttribute("center_of_trade") or 0,
		areaId          = part:GetAttribute("area"),
		regionId        = part:GetAttribute("region"),
		superRegionId   = part:GetAttribute("super_region"),
		cores           = { owner },
		recruitQueue    = {},
		buildQueue      = {},
		buildings       = {},
		goods           = {},
		population      = part:GetAttribute("population") or 0,
		unrest          = 0,
		autonomy        = 0,
	}, nil, part
end

local function buildSiblingList(focusedPart)
	if not ProvinceInteraction or not ProvinceInteraction.getMultiSelection then return nil end
	local parts = ProvinceInteraction.getMultiSelection()
	if not parts or #parts < 2 then return nil end
	local siblings = {}
	for _, p in ipairs(parts) do
		local rec = recordForPart(p)
		if rec then
			table.insert(siblings, { record = rec, part = p, focused = (p == focusedPart) })
		end
	end
	if #siblings < 2 then return nil end
	return siblings
end

local function onSelectProvince(part)
	if not part then
		selectedProvinceId = nil
		if provinceDetailPanel then provinceDetailPanel.hide() end
		-- Also clear any army selection
		if ArmyView and ArmyView.deselect then ArmyView.deselect() end
		return
	end

	if part:GetAttribute("is_sea") == true then
		if provinceDetailPanel then provinceDetailPanel.hide() end
		selectedProvinceId = nil
		if ArmyView and ArmyView.deselect then ArmyView.deselect() end
		return
	end

	local id = part:GetAttribute("province_id")

	if id then
		selectedProvinceId = id

		if pendingCommand and pendingCommand.kind == "attack" then
			invokeRemote("AttackProvince", pendingCommand.armyId, id)
			pendingCommand = nil
			return
		end
		if pendingCommand and pendingCommand.kind == "fleetMove" then
			invokeRemote("MoveFleet", pendingCommand.fleetId, id)
			pendingCommand = nil
			return
		end
		if pendingCommand and pendingCommand.kind == "fleetAttack" then
			local fleets = ClientStateCache.allFleets and ClientStateCache.allFleets() or {}
			for fid, fleet in pairs(fleets) do
				if fleet.provinceId == id and fleet.ownerTag ~= claimedTag then
					invokeRemote("AttackFleet", pendingCommand.fleetId, fid)
					pendingCommand = nil
					return
				end
			end
			pendingCommand = nil
		end
		if pendingCommand and pendingCommand.kind == "fleetMission" then
			local pc = pendingCommand
			if pc.targetKind == "province" then
				invokeRemote("SetFleetMission", pc.fleetId, pc.missionType, id, "")
				pendingCommand = nil
				return
			elseif pc.targetKind == "friendlyFleet" or pc.targetKind == "enemyFleet" then
				local fleets = ClientStateCache.allFleets and ClientStateCache.allFleets() or {}
				local wantFriendly = pc.targetKind == "friendlyFleet"
				for fid, fleet in pairs(fleets) do
					if fleet.provinceId == id and fid ~= pc.fleetId then
						local isFriendly = fleet.ownerTag == claimedTag
						if (wantFriendly and isFriendly) or (not wantFriendly and not isFriendly) then
							invokeRemote("SetFleetMission", pc.fleetId, pc.missionType, 0, fid)
							pendingCommand = nil
							return
						end
					end
				end
				pendingCommand = nil
			end
		end
	end

	-- A real province (not a pending move/attack command) was selected -> clear any unit
	-- selection so province and unit selections stay separate.
	if id and ArmyView and ArmyView.deselect then ArmyView.deselect() end

	local record = recordForPart(part)
	if not record then
		selectedProvinceId = nil
		if provinceDetailPanel then provinceDetailPanel.hide() end
		return
	end
	if not id then selectedProvinceId = nil end
	if provinceDetailPanel then
		provinceDetailPanel.show(record, ClientStateCache.getCountry(claimedTag or ""), bundle, buildSiblingList(part))
	end
end

local hoverKind = "none"
local hoverKey = nil

local function onHoverProvince(part)
	if not provinceTooltip then return end
	if not part then
		if hoverKind == "province" then
			provinceTooltip.hide()
			hoverKind = "none"
			hoverKey = nil
		end
		return
	end
	local id = part:GetAttribute("province_id")
	if part:GetAttribute("is_sea") == true then
		local seaName = part:GetAttribute("province_name") or part.Name:gsub("prov_%d+_", ""):gsub("_", " ")
		local key = "sea_" .. tostring(id or part.Name)
		if hoverKind ~= "water" or hoverKey ~= key then
			hoverKind = "water"
			hoverKey = key
			lastWaterName = seaName
			provinceTooltip.showWater(seaName, "sea")
		end
		return
	end
	local province = id and ClientStateCache.getProvince(id)
	if not province then
		local owner = part:GetAttribute("owner")
		if not owner then
			if hoverKind == "province" then
				provinceTooltip.hide()
				hoverKind = "none"
				hoverKey = nil
			end
			return
		end
		local rawFallbackName = part:GetAttribute("province_name") or part.Name
		local prettyFallbackName = tostring(rawFallbackName):gsub("^prov_%d+_", ""):gsub("_", " ")
		local fallback = {
			id = nil,
			code = part:GetAttribute("province_code") or ProvinceCodes.fromPartName(part.Name),
			name = prettyFallbackName,
			displayCityName = prettyFallbackName,
			ownerTag = owner,
			controllerTag = owner,
			terrain = part:GetAttribute("terrain") or "unknown",
			climate = part:GetAttribute("climate") or "unknown",
			culture = part:GetAttribute("culture") or "unknown",
			religion = part:GetAttribute("religion") or "unknown",
			tradeGood = part:GetAttribute("trade_good") or "unknown",
			baseTax = part:GetAttribute("base_tax") or 0,
			baseProduction = part:GetAttribute("base_production") or 0,
			baseManpower = part:GetAttribute("base_manpower") or 0,
			isCity = part:GetAttribute("is_city") or false,
		}
		local key = "v_" .. part.Name
		if hoverKind ~= "province" or hoverKey ~= key then
			hoverKind = "province"
			hoverKey = key
			lastWaterName = nil
			provinceTooltip.show(fallback)
		end
		return
	end
	if hoverKind ~= "province" or hoverKey ~= id then
		hoverKind = "province"
		hoverKey = id
		lastWaterName = nil
		local stampedOwner = part:GetAttribute("owner")
		if stampedOwner and stampedOwner ~= "" and stampedOwner ~= province.ownerTag then
			local merged = table.clone(province)
			merged.ownerTag = stampedOwner ~= "NONE" and stampedOwner or merged.ownerTag
			provinceTooltip.show(merged)
		else
			provinceTooltip.show(province)
		end
	end
end

local function onHoverWater(wx, wz)
	if not provinceTooltip then return end
	if wx == nil or wz == nil then
		if hoverKind == "water" then
			provinceTooltip.hide()
			hoverKind = "none"
			hoverKey = nil
			lastWaterName = nil
		end
		return
	end
	local name, bodyType = WaterBodies.getWaterBodyAt(wx, wz)
	if not name then
		if hoverKind == "water" then
			provinceTooltip.hide()
			hoverKind = "none"
			hoverKey = nil
			lastWaterName = nil
		end
		return
	end
	if hoverKind ~= "water" or hoverKey ~= name then
		hoverKind = "water"
		hoverKey = name
		lastWaterName = name
		provinceTooltip.showWater(name, bodyType)
	end
end

local function ownedArmyAt(provinceId)
	if not claimedTag or not provinceId then return nil end
	for _, army in ClientStateCache.allArmies() do
		if army.ownerTag == claimedTag and army.provinceId == provinceId then
			return army
		end
	end
	return nil
end

local function refreshArmyPanel()
	if not armyPanel then return end
	-- Prefer ArmyView's multi-selection list. Fall back to province-based single-select.
	local list = {}
	if ArmyView and ArmyView.getSelectedArmyIds then
		local ids = ArmyView.getSelectedArmyIds()
		for _, armyId in ipairs(ids) do
			local army = ClientStateCache.getArmy and ClientStateCache.getArmy(armyId)
			if army and army.ownerTag == claimedTag then
				table.insert(list, army)
			end
		end
	end
	if #list == 0 then
		armyPanel.hide()
		return
	end
	local provinceName = nil
	if #list == 1 then
		local prov = ClientStateCache.getProvince(list[1].provinceId)
		provinceName = prov and (prov.displayCityName or prov.name) or tostring(list[1].provinceId)
	end
	local country = claimedTag and (ClientStateCache.getCountry(claimedTag) or countries[claimedTag]) or nil
	armyPanel.show(list, bundle, provinceName, country)
end

local function ownedFleetAt(provinceId)
	if not claimedTag or not provinceId then return nil end
	local fleets = ClientStateCache.allFleets and ClientStateCache.allFleets() or {}
	for _, fleet in pairs(fleets) do
		if fleet.ownerTag == claimedTag and fleet.provinceId == provinceId then
			return fleet
		end
	end
	return nil
end

local function refreshFleetPanel()
	if not fleetPanel or not selectedProvinceId then
		if fleetPanel then fleetPanel.hide() end
		return
	end
	local fleet = ownedFleetAt(selectedProvinceId)
	if not fleet then fleetPanel.hide() return end
	local province = ClientStateCache.getProvince(fleet.provinceId)
	local provinceName = province and (province.displayCityName or province.name) or tostring(fleet.provinceId)
	fleetPanel.show(fleet, bundle and bundle.shipTypes, provinceName)
end

local function refreshProvinceDetail()
	if not provinceDetailPanel or not selectedProvinceId then return end
	if not provinceDetailPanel.root or not provinceDetailPanel.root.Visible then return end
	local province = ClientStateCache.getProvince(selectedProvinceId)
	if not province then return end
	local country = claimedTag and (ClientStateCache.getCountry(claimedTag) or countries[claimedTag]) or nil
	provinceDetailPanel.update(province, country, bundle)
end

local function syncClaim()
	for tag, country in ClientStateCache.allCountries() do
		if country.claimedBy == localPlayer.UserId then
			claimedTag = tag
			return
		end
	end
end

local function onClaimTag(tag)
	invokeRemote("ClaimCountry", tag)
end

local uiStarted = false

function UIController.start()
	if uiStarted then return end
	uiStarted = true
	remotes.ClaimCountry = aow:WaitForChild("Remotes"):WaitForChild("ClaimCountry", 10)
	remotes.EnactPolicy = aow.Remotes:WaitForChild("EnactPolicy", 10)
	remotes.RepealPolicy = aow.Remotes:WaitForChild("RepealPolicy", 10)
	remotes.CancelLaw = aow.Remotes:WaitForChild("CancelLaw", 10)
	remotes.AppointLeader = aow.Remotes:WaitForChild("AppointLeader", 10)
	remotes.DismissLeader = aow.Remotes:WaitForChild("DismissLeader", 10)
	remotes.SetDoctrine = aow.Remotes:WaitForChild("SetDoctrine", 10)
	remotes.RecruitUnit = aow.Remotes:WaitForChild("RecruitUnit", 10)
	remotes.MoveArmyPath = aow.Remotes:WaitForChild("MoveArmyPath", 10)
	remotes.MoveArmy = aow.Remotes:WaitForChild("MoveArmy", 10)
	remotes.AttackProvince = aow.Remotes:WaitForChild("AttackProvince", 10)
	remotes.DisbandArmy = aow.Remotes:WaitForChild("DisbandArmy", 10)
	remotes.MergeArmies = aow.Remotes:WaitForChild("MergeArmies", 10)
	remotes.DeclareWar = aow.Remotes:WaitForChild("DeclareWar", 10)
	remotes.ProposePeace = aow.Remotes:WaitForChild("ProposePeace", 10)
	remotes.AcceptPeace = aow.Remotes:WaitForChild("AcceptPeace", 10)
	remotes.RejectPeace = aow.Remotes:WaitForChild("RejectPeace", 10)
	remotes.CancelPeaceProposal = aow.Remotes:WaitForChild("CancelPeaceProposal", 10)
	remotes.CancelRecruit = aow.Remotes:WaitForChild("CancelRecruit", 10)
	remotes.RecruitShip = aow.Remotes:WaitForChild("RecruitShip", 10)
	remotes.MoveFleet = aow.Remotes:WaitForChild("MoveFleet", 10)
	remotes.AttackFleet = aow.Remotes:WaitForChild("AttackFleet", 10)
	remotes.DisbandFleet = aow.Remotes:WaitForChild("DisbandFleet", 10)
	remotes.SetFleetMission = aow.Remotes:WaitForChild("SetFleetMission", 10)
	remotes.ClearFleetMission = aow.Remotes:WaitForChild("ClearFleetMission", 10)
	remotes.ReassignOfficer = aow.Remotes:WaitForChild("ReassignOfficer", 10)
	remotes.BuildBuilding = aow.Remotes:WaitForChild("BuildBuilding", 10)
	remotes.CancelBuilding = aow.Remotes:WaitForChild("CancelBuilding", 10)

	buildBundleFromData()

	local commandLayer = UIRoot.layer("CommandMode", UIStyle.Z.Panel)

	local clusterLayer = Instance.new("Frame")
	clusterLayer.Name = "HudClusterBR"
	clusterLayer.AnchorPoint = Vector2.new(1, 1)
	clusterLayer.Position = UDim2.fromScale(1, 1)
	clusterLayer.Size = UDim2.fromScale(0.6, 0.85)
	clusterLayer.BackgroundTransparency = 1
	clusterLayer.Active = false
	clusterLayer.ClipsDescendants = false
	clusterLayer.ZIndex = UIStyle.Z.Panel
	clusterLayer.Parent = commandLayer
	UIRoot.registerScaled(clusterLayer)

	topBar = TopBar.create(commandLayer)

	countryPanel = CountryPanel.create(commandLayer)

	tabs.Overview = OverviewTab.mount(countryPanel.getPage("Overview"))
	-- The Diplomacy window is the consolidated country-profile window: it owns the
	-- country list + profile view AND hosts the politics pages
	-- (Factions/Leaders/Policies/Laws/Doctrines) on its embedded government screen.
	diplomacyWindow = DiplomacyWindow.create({
		getMyTag         = function() return claimedTag end,
		onDeclareWar     = function(targetTag)        invokeRemote("DeclareWar", targetTag) end,
		onProposePeace   = function(targetTag, terms) invokeRemote("ProposePeace", targetTag, terms) end,
		onAcceptPeace    = function(proposalId)        invokeRemote("AcceptPeace", proposalId) end,
		onRejectPeace    = function(proposalId)        invokeRemote("RejectPeace", proposalId) end,
		onCancelProposal = function(proposalId)        invokeRemote("CancelPeaceProposal", proposalId) end,
		fireDismiss      = function(slot)         invokeRemote("DismissLeader", slot) end,
		fireAppoint      = function(slot, idx)    invokeRemote("AppointLeader", slot, idx) end,
		fireEnact        = function(policyId)     invokeRemote("EnactPolicy", policyId) end,
		fireRepeal       = function(policyId)     invokeRemote("RepealPolicy", policyId) end,
		fireCancel       = function()             invokeRemote("CancelLaw") end,
		fireSetDoctrine  = function(doctrineId)   invokeRemote("SetDoctrine", doctrineId) end,
	})
	tabs.Factions  = diplomacyWindow.tabImpls.Factions
	tabs.Leaders   = diplomacyWindow.tabImpls.Leaders
	tabs.Policies  = diplomacyWindow.tabImpls.Policies
	tabs.Laws      = diplomacyWindow.tabImpls.Laws
	tabs.Doctrines = diplomacyWindow.tabImpls.Doctrines

	-- Legacy callers that did countryPanel.setActive("Policies") etc. now land on the
	-- consolidated window's government screen.
	local CountryPanelMod = require(uiFolder:WaitForChild("CountryPanel"))
	if CountryPanelMod.setPoliticsRedirect then
		CountryPanelMod.setPoliticsRedirect(function(tabName)
			focusDiplomacyWindow(function()
				diplomacyWindow.openPoliticsTab(tabName)
			end)
		end)
	end

	provinceTooltip = ProvinceTooltip.create(commandLayer)
	provinceDetailPanel = ProvinceDetailPanel.create(commandLayer, function()
		selectedProvinceId = nil
	end, {
		onRecruitUnit = function(provinceId, unitTypeId, count)
			invokeRemote("RecruitUnit", provinceId, unitTypeId, count)
		end,
		onCancelRecruit = function(ticketId)
			if ticketId then invokeRemote("CancelRecruit", ticketId) end
		end,
		onRecruitShip = function(provinceId, shipTypeId, count)
			invokeRemote("RecruitShip", provinceId, shipTypeId, count)
		end,
		onBuildBuilding = function(provinceId, buildingId)
			invokeRemote("BuildBuilding", provinceId, buildingId)
		end,
		onCancelBuilding = function(ticketId)
			invokeRemote("CancelBuilding", ticketId)
		end,
		onViewCountry = function(tag)
			if not tag or not diplomacyWindow then return end
			focusDiplomacyWindow(function()
				diplomacyWindow.openCountry(tag)
			end)
		end,
	})
	armyPanel = ArmyPanel.create(clusterLayer, {
		onClear = function()
			if ArmyView and ArmyView.deselect then ArmyView.deselect() end
		end,
		onDisband = function(armyId)
			if armyId then invokeRemote("DisbandArmy", armyId) end
		end,
		onMerge = function(primaryId, otherIds)
			if primaryId and otherIds and #otherIds > 0 then
				invokeRemote("MergeArmies", primaryId, otherIds)
			end
		end,
		onOfficerReassign = function(armyId, traitIds)
			if armyId and type(traitIds) == "table" and #traitIds > 0 then
				invokeRemote("ReassignOfficer", armyId, traitIds)
			end
		end,
	})
	fleetPanel = FleetPanel.create(clusterLayer, {
		onMoveMode = function(fleetId)
			if fleetId then pendingCommand = { kind = "fleetMove", fleetId = fleetId } end
		end,
		onAttackMode = function(fleetId)
			if fleetId then pendingCommand = { kind = "fleetAttack", fleetId = fleetId } end
		end,
		onDisband = function(fleetId)
			if fleetId then invokeRemote("DisbandFleet", fleetId) end
		end,
		onMissionAssign = function(fleetId, missionType, targetProvinceId)
			if fleetId and missionType then
				invokeRemote("SetFleetMission", fleetId, missionType, targetProvinceId or 0, "")
			end
		end,
		onMissionPick = function(fleetId, missionType, targetKind)
			if fleetId and missionType and targetKind then
				pendingCommand = {
					kind = "fleetMission",
					fleetId = fleetId,
					missionType = missionType,
					targetKind = targetKind,
				}
			end
		end,
		onMissionClear = function(fleetId)
			if fleetId then invokeRemote("ClearFleetMission", fleetId) end
		end,
	})

	-- Wire ArmyView click → select that army's province (so existing armyPanel/refresh flow takes over)
	-- Pass bundle to ArmyView so it can render unit type names in banners
	if ArmyView and ArmyView.setBundle then
		ArmyView.setBundle(bundle)
	end
	if ArmyView and ArmyView.onArmySelected then
		ArmyView.onArmySelected(function(armyId, additive)
			if not armyId then
				-- deselect: hide panel
				if armyPanel then armyPanel.hide() end
				return
			end
			local army = ClientStateCache.getArmy and ClientStateCache.getArmy(armyId)
			if not army or army.ownerTag ~= claimedTag then return end
			-- A unit was selected -> this is a UNIT selection, not a province one. Clear the
			-- province selection so the province/fleet panels close (selections are separate).
			selectedProvinceId = nil
			if provinceDetailPanel then provinceDetailPanel.hide() end
			if fleetPanel then fleetPanel.hide() end
			refreshArmyPanel()
		end)
	end
	-- Right-click on a province while armies are selected -> issue path-based move
	if ProvinceInteraction and ProvinceInteraction.onRightClick then
		ProvinceInteraction.onRightClick(function(provincePart)
			if not ArmyView or not ArmyView.getSelectedArmyIds then return end
			local selectedIds = ArmyView.getSelectedArmyIds()
			if #selectedIds == 0 then return end
			local provinceId = provincePart and provincePart:GetAttribute("province_id")
			if not provinceId then return end
			for _, armyId in ipairs(selectedIds) do
				invokeRemote("MoveArmyPath", armyId, provinceId)
			end
			if PathPreview and PathPreview.clear then PathPreview.clear() end
		end)
	end
	-- Arm right-click move only while a unit is selected (otherwise MB2 is left to the field camera).
	if ProvinceInteraction and ProvinceInteraction.setRightClickPredicate then
		ProvinceInteraction.setRightClickPredicate(function()
			if not (ArmyView and ArmyView.getSelectedArmyIds) then return false end
			return #ArmyView.getSelectedArmyIds() > 0
		end)
	end
	-- Hover over a province while armies selected: draw path preview line
	if PathPreview and PathPreview.init then PathPreview.init() end
	if ProvinceInteraction and ProvinceInteraction.addHoverListener then
		local lastHoverPid = nil
		ProvinceInteraction.addHoverListener(function(provincePart)
			local pid = provincePart and provincePart:GetAttribute("province_id")
			if pid == lastHoverPid then return end
			lastHoverPid = pid
			-- Always notify ArmyView for stack-expand-on-hover
			if ArmyView and ArmyView.setHoverProvince then
				ArmyView.setHoverProvince(pid)
			end
			if not pid then PathPreview.clear(); return end
			if not ArmyView or not ArmyView.getSelectedArmyIds then return end
			local selectedIds = ArmyView.getSelectedArmyIds()
			if #selectedIds == 0 then PathPreview.clear(); return end
			local firstArmy = ClientStateCache.getArmy(selectedIds[1])
			if not firstArmy then PathPreview.clear(); return end
			PathPreview.show(firstArmy.provinceId, pid, ClientStateCache, claimedTag)
		end)
	end
	claimScreen = ClaimScreen.create(commandLayer, onClaimTag)
	countryHeader = CountryHeader.create(commandLayer, function()
		if countryPanel and countryPanel.toggle then
			countryPanel.toggle()
			ensureOverviewFresh()
			if countryHeader and countryHeader.setOpenState then
				countryHeader.setOpenState(countryPanel.isOpen())
			end
		end
	end)
	bottomBar = BottomBar.create(commandLayer)
	-- BottomBar panel-button click → toggle the matching MovableWindow
	local function toggleWindow(id)
		local windows = {
			economy = economyWindow,
			research = researchWindow,
			diplomacy = diplomacyWindow,
		}
		local w = windows[id]
		if not w then return end
		if not w.isOpen() then
			for otherId, otherW in pairs(windows) do
				if otherId ~= id and otherW and otherW.isOpen() then
					otherW.toggle()
					if bottomBar and bottomBar.setActiveWindow then
						bottomBar.setActiveWindow(otherId, false)
					end
				end
			end
		end
		w.toggle()
		if id == "economy" then ensureEconomyFresh() end
		if bottomBar and bottomBar.setActiveWindow then
			bottomBar.setActiveWindow(id, w.isOpen())
		end
	end
	bottomBar.onPanelButtonClicked(toggleWindow)
	local toastLayer = UIRoot.layer("Toast", UIStyle.Z.Toast)
	notifFeed = NotificationFeed.create(toastLayer)
	local modalLayer = UIRoot.layer("Modal", UIStyle.Z.Modal)
	economyWindow = EconomyWindow.create({ getBundle = function() return bundle end })
	researchWindow = ResearchWindow.create()
	keybindsWindow = KeybindsWindow.create()
	settingsMenu = SettingsMenu.create(modalLayer, {
		onSetKeybinds = function() keybindsWindow.toggle() end,
	})
	-- Wire the TopBar menu button (currently Visible=false from Round 2)
	if topBar and topBar.getMenuButton then
		local menuBtn = topBar.getMenuButton()
		if menuBtn then
			menuBtn.Visible = true
			menuBtn.MouseButton1Click:Connect(function() settingsMenu.toggle() end)
		end
	end
	shortcutsOverlay = ShortcutsOverlay.create(modalLayer)
	minimap = Minimap.create(clusterLayer)
	task.defer(UISound.preload)

	local _colorCache = nil
	local function rebuildColorCache()
		local colors = {}
		if ClientStateCache and ClientStateCache.allCountries then
			for tag, c in ClientStateCache.allCountries() do
				if type(c) == "table" and c.color then
					colors[tag] = Color3.fromRGB(c.color[1] or 128, c.color[2] or 128, c.color[3] or 128)
				end
			end
		end
		for tag, c in countries do
			if not colors[tag] and c.color then
				colors[tag] = Color3.fromRGB(c.color[1] or 128, c.color[2] or 128, c.color[3] or 128)
			end
		end
		_colorCache = colors
		return colors
	end
	local function currentCountryColors()
		return _colorCache or rebuildColorCache()
	end

	local function applyMapMode(mode)
		local colors = currentCountryColors()
		MapRenderer.setMode(mode, { countryColors = colors })
	end

	mapModesBar = MapModesBar.create(clusterLayer, applyMapMode)
	if minimap and minimap.bindModesToggle and mapModesBar and mapModesBar.toggleVisible then
		minimap.bindModesToggle(function()
			mapModesBar.toggleVisible()
			if minimap.setModesIndicator then
				minimap.setModesIndicator(mapModesBar.isVisible())
			end
		end)
		if minimap.setModesIndicator and mapModesBar.isVisible then
			minimap.setModesIndicator(mapModesBar.isVisible())
		end
	end
	if minimap and minimap.root and mapModesBar and mapModesBar.root then
		local MAP_MODES_GAP = 2
		mapModesBar.root.AnchorPoint = Vector2.new(1, 1)
		RunService.Heartbeat:Connect(function()
			if not (mapModesBar and mapModesBar.root and minimap and minimap.root) then return end
			if not mapModesBar.root.Visible then return end
			local h = minimap.root.AbsoluteSize.Y / UIRoot.uiScale()
			if h <= 0 then return end
			mapModesBar.root.Position = UDim2.new(1, -12, 1,
				-(UIStyle.Size.BottomBarH + 12 + h + MAP_MODES_GAP))
		end)
	end
	task.defer(function() applyMapMode("political") end)

	claimScreen.populate(countries, collectClaims())

	ProvinceInteraction.onSelect(onSelectProvince)
	ProvinceInteraction.onHover(onHoverProvince)
	ProvinceInteraction.onWater(onHoverWater)
	if ProvinceInteraction.addMultiSelectListener then
		ProvinceInteraction.addMultiSelectListener(function()
			local current = ProvinceInteraction.getSelected and ProvinceInteraction.getSelected()
			if current then onSelectProvince(current) end
		end)
	end
	if provinceDetailPanel and provinceDetailPanel.onSiblingClick then
		provinceDetailPanel.onSiblingClick(function(part)
			if part and ProvinceInteraction.focusPart then
				ProvinceInteraction.focusPart(part)
			end
		end)
	end

	UIRoot.setVisible(true)
	MapModeController.onChange(function(mode)
		if mode ~= "command" and provinceTooltip then provinceTooltip.hide() end
		if mapModesBar and mapModesBar.setVisible then mapModesBar.setVisible(mode == "command") end
	end)

	UIKeybindings.registerAction({
		id = "toggleViewMode",
		label = "Toggle View Mode",
		defaultKey = Enum.KeyCode.M,
		contextId = "global",
		fn = function()
			if MapModeController and MapModeController.toggle then
				MapModeController.toggle()
			end
		end,
	})

	ClientStateCache.onChangePrefix("countries", function()
		dirty.countries = true
		dirty.claim = true
	end)
	ClientStateCache.onChangePrefix("armies", function()
		dirty.armies = true
	end)
	ClientStateCache.onChangePrefix("fleets", function()
		dirty.fleets = true
	end)
	ClientStateCache.onChangePrefix("provinces", function(_, path)
		dirty.provinces = true
		local idStr = path and path:match("^provinces%.([^%.]+)")
		if idStr then dirtyProvinceIds[idStr] = true end
	end)
	ClientStateCache.onChange("snapshot", function()
		dirty.countries = true
		dirty.armies = true
		dirty.provinces = true
		dirty.claim = true
	end)

	-- Keyboard shortcuts
	UIKeybindings.start()
	local TAB_KEYS = {
		[Enum.KeyCode.F1] = { name = "Overview",  id = "tabOverview"  },
		[Enum.KeyCode.F2] = { name = "Factions",  id = "tabFactions"  },
		[Enum.KeyCode.F3] = { name = "Leaders",   id = "tabLeaders"   },
		[Enum.KeyCode.F4] = { name = "Policies",  id = "tabPolicies"  },
		[Enum.KeyCode.F5] = { name = "Laws",      id = "tabLaws"      },
		[Enum.KeyCode.F6] = { name = "Doctrines", id = "tabDoctrines" },
	}
	for key, def in TAB_KEYS do
		UIKeybindings.registerAction({
			id = def.id,
			label = "Tab: " .. def.name,
			defaultKey = key,
			contextId = "tabs",
			fn = function()
				if not claimedTag or not countryPanel then return false end
				if not countryPanel.isOpen() then countryPanel.openPanel() end
				countryPanel.setActive(def.name)
				ensureOverviewFresh()
			end,
		})
	end
	UIKeybindings.registerAction({
		id = "escBack", label = "Close / Back",
		defaultKey = Enum.KeyCode.Escape, contextId = "global",
		fn = function()
			-- 1) Settings popover
			if settingsMenu and settingsMenu.isVisible() then
				settingsMenu.setVisible(false)
				return
			end
			-- 2) Topmost movable window
			local MW = require(uiFolder:WaitForChild("MovableWindow"))
			local top = MW.topmostOpen and MW.topmostOpen()
			if top and top.close then
				top.close()
				if bottomBar and bottomBar.setActiveWindow then
					bottomBar.setActiveWindow("economy",   economyWindow and economyWindow.isOpen())
					bottomBar.setActiveWindow("research",  researchWindow and researchWindow.isOpen())
					bottomBar.setActiveWindow("diplomacy", diplomacyWindow and diplomacyWindow.isOpen())
				end
				return
			end
			-- 3) Province detail
			if provinceDetailPanel and provinceDetailPanel.root and provinceDetailPanel.root.Visible then
				provinceDetailPanel.hide()
				return
			end
			-- 4) Army panel
			if armyPanel and armyPanel.root and armyPanel.root.Visible then
				armyPanel.hide()
				selectedProvinceId = nil
				return
			end
			-- 5) Country panel
			if countryPanel and countryPanel.isOpen and countryPanel.isOpen() then
				countryPanel.closePanel()
				if countryHeader and countryHeader.setOpenState then countryHeader.setOpenState(false) end
				return
			end
		end,
	})
	UIKeybindings.registerAction({
		id = "toggleDiplomacy", label = "Toggle Diplomacy",
		defaultKey = Enum.KeyCode.V, contextId = "global",
		fn = function()
			if not claimedTag or not diplomacyWindow then return end
			toggleWindow("diplomacy")
		end,
	})
	UIKeybindings.registerAction({
		id = "togglePolitics", label = "Your Country (Government)",
		defaultKey = Enum.KeyCode.G, contextId = "global",
		fn = function()
			if not claimedTag or not diplomacyWindow then return end
			-- Already looking at your own profile -> close; otherwise jump to it.
			if diplomacyWindow.isShowingOwn() then
				toggleWindow("diplomacy")
			else
				focusDiplomacyWindow(function()
					diplomacyWindow.openOwnProfile()
				end)
			end
		end,
	})
	UIKeybindings.registerAction({
		id = "toggleEconomy", label = "Toggle Economy",
		defaultKey = Enum.KeyCode.E, contextId = "global",
		fn = function()
			if not claimedTag or not economyWindow then return end
			toggleWindow("economy")
		end,
	})
	UIKeybindings.registerAction({
		id = "toggleResearch", label = "Toggle Research",
		defaultKey = Enum.KeyCode.Y, contextId = "global",
		fn = function()
			if not claimedTag or not researchWindow then return end
			toggleWindow("research")
		end,
	})
	UIKeybindings.registerAction({
		id = "toggleSettings", label = "Toggle Settings",
		defaultKey = Enum.KeyCode.F10, contextId = "global",
		fn = function()
			if settingsMenu then settingsMenu.toggle() end
		end,
	})
	UIKeybindings.registerAction({
		id = "closeTopmostWindow",
		label = "Close Topmost Window",
		defaultKey = Enum.KeyCode.X,
		contextId = "global",
		fn = function()
			local MW = require(uiFolder:WaitForChild("MovableWindow"))
			local top = MW.topmostOpen and MW.topmostOpen()
			if top and top.close then
				top.close()
				if bottomBar and bottomBar.setActiveWindow then
					bottomBar.setActiveWindow("economy",   economyWindow and economyWindow.isOpen())
					bottomBar.setActiveWindow("research",  researchWindow and researchWindow.isOpen())
					bottomBar.setActiveWindow("diplomacy", diplomacyWindow and diplomacyWindow.isOpen())
				end
			end
		end,
	})
	UIKeybindings.registerAction({
		id = "gotoPolicies", label = "Open Policies",
		defaultKey = Enum.KeyCode.O, contextId = "tabs",
		fn = function()
			if claimedTag and countryPanel then
				if not countryPanel.isOpen() then countryPanel.openPanel() end
				countryPanel.setActive("Policies")
				ensureOverviewFresh()
			end
		end,
	})
	UIKeybindings.registerAction({
		id = "gotoLaws", label = "Open Laws",
		defaultKey = Enum.KeyCode.L, contextId = "tabs",
		fn = function()
			if claimedTag and countryPanel then
				if not countryPanel.isOpen() then countryPanel.openPanel() end
				countryPanel.setActive("Laws")
			end
		end,
	})

	local timeSync = aow.Remotes:WaitForChild("TimeSync", 10)
	local timeRequest = aow.Remotes:WaitForChild("TimeRequest", 10)

	local function applyTime(packet)
		if not topBar or not topBar.setTime then return end
		if type(packet) ~= "table" then return end
		topBar.setTime(packet.year, packet.month, packet.day, packet.speed, packet.paused)
		if topBar.setPaused then
			topBar.setPaused(packet.paused == true)
		end
	end

	if timeSync then
		timeSync.OnClientEvent:Connect(applyTime)
	end

	-- Admin gate: only admins may change time speed / pause.
	-- Status comes from Players.LocalPlayer:GetAttribute("IsAdmin"), set server-side.
	-- Apply persisted Sound / Reduce-motion settings from LocalPlayer attributes (B5)
	local function applySettingsFromAttributes()
		local muted = localPlayer:GetAttribute("SoundMuted")
		if UISound.setMuted then UISound.setMuted(muted == true) end
		local reduce = localPlayer:GetAttribute("ReduceMotion")
		UIStyle.ReduceMotion = reduce == true
	end
	applySettingsFromAttributes()
	localPlayer:GetAttributeChangedSignal("SoundMuted"):Connect(applySettingsFromAttributes)
	localPlayer:GetAttributeChangedSignal("ReduceMotion"):Connect(applySettingsFromAttributes)

	local function syncAdmin()
		local flag = localPlayer:GetAttribute("IsAdmin") == true
		if topBar and topBar.setAdmin then topBar.setAdmin(flag) end
	end
	syncAdmin()
	localPlayer:GetAttributeChangedSignal("IsAdmin"):Connect(syncAdmin)

	local function isAdmin()
		return topBar and topBar.isAdmin and topBar.isAdmin() or false
	end

	if topBar and topBar.getPauseButton then
		local pauseBtn = topBar.getPauseButton()
		if pauseBtn then
			pauseBtn.MouseButton1Click:Connect(function()
				if not claimedTag or not timeRequest then return end
				if not isAdmin() then
					if notifFeed and notifFeed.push then
						notifFeed.push({ kind = "warn", title = "Admin only", body = "Only admins can pause time." })
					end
					return
				end
				timeRequest:FireServer({ action = "togglePause" })
			end)
		end
	end

	local SPEED_KEYS = {
		[Enum.KeyCode.One]   = 1,
		[Enum.KeyCode.Two]   = 2,
		[Enum.KeyCode.Three] = 4,
		[Enum.KeyCode.Four]  = 8,
		[Enum.KeyCode.Five]  = 16,
	}
	for key, speed in pairs(SPEED_KEYS) do
		UIKeybindings.registerAction({
			id = "setSpeed" .. tostring(speed),
			label = string.format("Set Speed %d\u{00D7}", speed),
			defaultKey = key,
			contextId = "time",
			fn = function()
				if not claimedTag or not timeRequest then return end
				if not isAdmin() then
					if notifFeed and notifFeed.push then
						notifFeed.push({ kind = "warn", title = "Admin only", body = "Only administrators may change game speed.", ttl = 4 })
					end
					return
				end
				timeRequest:FireServer({ action = "setSpeed", speed = speed })
			end,
		})
	end
	UIKeybindings.registerAction({
		id = "togglePause", label = "Pause / Resume Time",
		defaultKey = Enum.KeyCode.P, contextId = "time",
		fn = function()
			if not claimedTag or not timeRequest then return false end
			if not isAdmin() then
				if notifFeed and notifFeed.push then
					notifFeed.push({ kind = "warn", title = "Admin only", body = "Only administrators may pause / resume.", ttl = 4 })
				end
				return
			end
			timeRequest:FireServer({ action = "togglePause" })
		end,
	})

	UIKeybindings.registerAction({
		id = "toggleShortcuts", label = "Show Keyboard Shortcuts",
		defaultKey = Enum.KeyCode.F12, contextId = "help",
		fn = function()
			if shortcutsOverlay and shortcutsOverlay.toggle then
				shortcutsOverlay.toggle()
			end
		end,
	})

	dirty.countries = true
	dirty.claim = true

	local _lastClaimSig = nil

	-- Drag-select: hold left-mouse and drag to pick all your armies whose province is in the rect.
	-- We treat as drag only if the cursor moves more than 6px between down and up.
	do
		local UIS = game:GetService("UserInputService")
		local Players = game:GetService("Players")
		local localPlayerScope = Players.LocalPlayer
		local pgui = localPlayerScope and localPlayerScope:FindFirstChildOfClass("PlayerGui")
		local dragGui = nil
		local dragFrame = nil

		local function ensureDragGui()
			if dragGui and dragGui.Parent then return end
			if not pgui then return end
			dragGui = Instance.new("ScreenGui")
			dragGui.Name = "AoWDragSelect"
			dragGui.IgnoreGuiInset = true
			dragGui.ResetOnSpawn = false
			dragGui.DisplayOrder = 80
			dragGui.Parent = pgui
			dragFrame = Instance.new("Frame")
			dragFrame.Size = UDim2.fromOffset(0, 0)
			dragFrame.Position = UDim2.fromOffset(0, 0)
			dragFrame.BackgroundColor3 = Color3.fromRGB(120, 220, 255)
			dragFrame.BackgroundTransparency = 0.7
			dragFrame.BorderSizePixel = 0
			dragFrame.Visible = false
			dragFrame.Parent = dragGui
			local stroke = Instance.new("UIStroke")
			stroke.Color = Color3.fromRGB(180, 235, 255)
			stroke.Thickness = 1.5
			stroke.Transparency = 0.1
			stroke.Parent = dragFrame
		end

		local dragStart = nil  -- Vector2 mouse pos on down
		local dragMoved = false
		local DRAG_THRESHOLD = 6  -- px

		local function isMouseOverUI()
			-- Re-use ProvinceInteraction's gating where possible. Fallback: check player gui at point.
			if not pgui then return false end
			local mp = UIS:GetMouseLocation()
			local objects = pgui:GetGuiObjectsAtPosition(mp.X, mp.Y - 36)  -- adjust for inset
			for _, obj in ipairs(objects) do
				local cur = obj
				while cur and cur:IsA("GuiObject") do
					if cur:GetAttribute("AoWInputSink") == true then return true end
					if cur:GetAttribute("AoWInputSink") == false then break end
					cur = cur.Parent
				end
			end
			return false
		end

		local function projectToScreen(worldPos)
			local cam = workspace.CurrentCamera
			if not cam then return nil end
			local screenPos, onScreen = cam:WorldToScreenPoint(worldPos)
			if not onScreen then return nil end
			return Vector2.new(screenPos.X, screenPos.Y)
		end

		local function performDrag(rectMin, rectMax, additive)
			if not claimedTag or not ArmyView then return end
			local map = workspace:FindFirstChild("ArtOfWarMap")
			local provinces = map and map:FindFirstChild("Provinces")
			if not provinces then return end
			-- Collect province IDs whose centers project inside the rect
			local hits = {}
			for _, part in ipairs(provinces:GetChildren()) do
				if part:IsA("BasePart") then
					local pid = part:GetAttribute("province_id")
					if pid then
						local sp = projectToScreen(part.Position)
						if sp and sp.X >= rectMin.X and sp.X <= rectMax.X
							and sp.Y >= rectMin.Y and sp.Y <= rectMax.Y then
							hits[pid] = true
						end
					end
				end
			end
			-- Find owned armies on those provinces
			if not additive then ArmyView.deselect() end
			local first = true
			for _, army in pairs(ClientStateCache.allArmies()) do
				if army.ownerTag == claimedTag and hits[army.provinceId] then
					ArmyView.focusArmy(army.id, additive or not first)
					first = false
				end
			end
		end

		UIS.InputBegan:Connect(function(input, processed)
			if processed then return end
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
			if isMouseOverUI() then return end
			dragStart = UIS:GetMouseLocation()
			dragMoved = false
			ensureDragGui()
			if dragFrame then dragFrame.Visible = false end
		end)

		UIS.InputChanged:Connect(function(input)
			if not dragStart then return end
			if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
			local current = UIS:GetMouseLocation()
			local dx = current.X - dragStart.X
			local dy = current.Y - dragStart.Y
			if math.abs(dx) > DRAG_THRESHOLD or math.abs(dy) > DRAG_THRESHOLD then
				dragMoved = true
				if dragFrame then
					local minX = math.min(dragStart.X, current.X)
					local minY = math.min(dragStart.Y, current.Y)
					local w = math.abs(dx)
					local h = math.abs(dy)
					dragFrame.Position = UDim2.fromOffset(minX, minY)
					dragFrame.Size = UDim2.fromOffset(w, h)
					dragFrame.Visible = true
				end
			end
		end)

		UIS.InputEnded:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
			if not dragStart then return end
			local moved = dragMoved
			local additive = UIS:IsKeyDown(Enum.KeyCode.LeftShift) or UIS:IsKeyDown(Enum.KeyCode.RightShift)
			dragStart = nil
			dragMoved = false
			if dragFrame then dragFrame.Visible = false end
			if not moved then return end
			if dragFrame then
				local pos = dragFrame.Position
				local size = dragFrame.Size
				local minX = pos.X.Offset
				local minY = pos.Y.Offset
				local maxX = minX + size.X.Offset
				local maxY = minY + size.Y.Offset
				if maxX > minX and maxY > minY then
					performDrag(Vector2.new(minX, minY), Vector2.new(maxX, maxY), additive)
				end
			end
		end)
	end

	dirtyConn = RunService.Heartbeat:Connect(function()
		if dirty.claim then
			dirty.claim = false
			local hadClaim = claimedTag ~= nil
			syncClaim()
			if not claimedTag then
				local claims = collectClaims()
				table.sort(claims)
				local sig = table.concat(claims, ",")
				if sig ~= _lastClaimSig then
					_lastClaimSig = sig
					claimScreen.populate(countries, claims)
				end
				claimScreen.setVisible(true)
			else
				_lastClaimSig = nil
				claimScreen.setVisible(false)
				if not hadClaim and not autoFieldRequested and MapModeController and MapModeController.requestMode then
					autoFieldRequested = true
					MapModeController.requestMode("field")
				end
			end
		end
		if dirty.countries then
			dirty.countries = false
			refresh()
			refreshProvinceDetail()
			_colorCache = nil   -- invalidate cache; color set may have changed
			-- C1 (perf): country churn (treasury/PP/faction) never changes map colors, which are
			-- static (country.color/tag). The full ~17k-part recolor that ran here every
			-- replication tick was the dominant client hitch. Province ownership/occupation
			-- changes still recolor via the dirty.provinces branch below.
		end
		-- Decoupled per-collection refresh (perf): a change in one collection no longer refreshes
		-- all three selection panels. Combined with the server-side army change-guards, this stops
		-- ArmyPanel / FleetPanel / ProvinceDetail from rebuilding every tick when an unrelated
		-- army's morale/entrenchment ticks. Each panel reads only its own collection.
		if dirty.armies then
			dirty.armies = false
			refreshArmyPanel()
		end
		if dirty.fleets then
			dirty.fleets = false
			refreshFleetPanel()
		end
		if dirty.provinces then
			dirty.provinces = false
			refreshProvinceDetail()
			-- Recolor exactly the provinces that changed. Driven by the replicated province
			-- delta (the same path that updates armies / combat overlays / the province panel),
			-- so it reliably fires on occupation and ownership changes -- the per-part
			-- AttributeChanged watcher alone did not recolor on replicated attribute changes.
			if next(dirtyProvinceIds) then
				for id in pairs(dirtyProvinceIds) do MapRenderer.recolorProvince(id) end
				table.clear(dirtyProvinceIds)
			end
		end
	end)
end

function UIController.notify(data)
	if notifFeed and notifFeed.push then return notifFeed.push(data) end
end

function UIController.destroy()
	if dirtyConn then dirtyConn:Disconnect() dirtyConn = nil end
end

return UIController
