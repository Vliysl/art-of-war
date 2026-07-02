local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local UI = script.Parent
local ArtOfWar = UI.Parent
local Hud = require(UI.Hud)
local Registries = require(UI.Registries)
local ProvinceTooltip = require(UI.Components.ProvinceTooltip)
local Platform = require(ArtOfWar.Modules.Platform)
local Button = require(UI.Components.Button)

local HudWiring = {}

local nationSelectActive = false
local nationSelectApi = nil

local BOOT_DEBUG = false
local function nslog(...)
	if BOOT_DEBUG then
		print("[AoW NationSelect]", ...)
	end
end

function HudWiring.setNationSelectActive(v)
	nationSelectActive = v == true
end

function HudWiring.setNationSelectApi(api)
	nationSelectApi = api
end

local MONTHS = {
	"January",
	"February",
	"March",
	"April",
	"May",
	"June",
	"July",
	"August",
	"September",
	"October",
	"November",
	"December",
}
local MAP_MODES = {
	{ key = "political", icon = "MapPolitical", label = "Political" },
	{ key = "terrain", icon = "MapTerrain", label = "Terrain" },
	{ key = "culture", icon = "MapCulture", label = "Culture" },
	{ key = "religion", icon = "MapReligion", label = "Religion" },
	{ key = "trade", icon = "MapTrade", label = "Trade Goods" },
}

local function prettify(id)
	if type(id) ~= "string" or id == "" then
		return nil
	end
	local out = {}
	for word in id:gmatch("[^_%s]+") do
		out[#out + 1] = word:sub(1, 1):upper() .. word:sub(2)
	end
	return table.concat(out, " ")
end

local function abbreviate(n)
	if type(n) ~= "number" then
		return nil
	end
	local sign = n < 0 and "-" or ""
	local a = math.abs(n)
	if a >= 1e9 then
		return string.format("%s%.2fB", sign, a / 1e9)
	elseif a >= 1e6 then
		return string.format("%s%.2fM", sign, a / 1e6)
	elseif a >= 1e3 then
		return string.format("%s%.1fK", sign, a / 1e3)
	end
	return string.format("%s%d", sign, math.floor(a + 0.5))
end

local function money(n)
	local a = abbreviate(n)
	return a and ("\u{00A3}" .. a) or "\u{2014}"
end

local function delta(n)
	if type(n) ~= "number" or n == 0 then
		return nil
	end
	return (n > 0 and "+" or "") .. abbreviate(n)
end

local function signed(n)
	if type(n) ~= "number" then
		return "\u{2014}"
	end
	local mag = math.floor(math.abs(n) + 0.5)
	if mag == 0 then
		return "0"
	end
	return (n < 0 and "-" or "+") .. tostring(mag)
end

local function colorOf(arr)
	if type(arr) == "table" and arr[1] then
		return Color3.fromRGB(arr[1], arr[2], arr[3])
	end
	return nil
end

function HudWiring.start(modules)
	modules = modules or {}
	local ClientStateCache = modules.ClientStateCache
	local MapModeController = modules.MapModeController
	local ProvinceInteraction = modules.ProvinceInteraction
	if not ClientStateCache then
		return
	end

	local localPlayer = Players.LocalPlayer
	local Remotes = ArtOfWar:FindFirstChild("Remotes")
	local function fire(name, ...)
		local r = Remotes and Remotes:FindFirstChild(name)
		if r then
			r:FireServer(...)
		else
			warn("[AoW HudWiring] missing remote '" .. tostring(name) .. "'")
		end
	end

	local claimedTag = nil
	local nationSelectShown = false
	-- When set, the next map province click resolves this command (attack/move) instead of
	-- opening the province panel. Set via ctx.requestTarget from army/fleet panels.
	local pendingCommand = nil

	local function requestTarget(spec)
		pendingCommand = spec
		Hud.notify({
			kind = "info",
			title = "Select a target",
			body = (spec and spec.hint) or "Click a province on the map.",
			ttl = 5,
		})
	end

	local function aggregateArmies(tag)
		local regiments = 0
		for _, a in pairs(ClientStateCache.allArmies() or {}) do
			if a.ownerTag == tag then
				for _, n in pairs(a.composition or {}) do
					regiments += n
				end
			end
		end
		return regiments, regiments * 1000
	end

	local function provinceTotals()
		local totals = {}
		for _, p in pairs(ClientStateCache.allProvinces() or {}) do
			local owner = p.ownerTag
			if owner then
				local t = totals[owner]
				if not t then
					t = { count = 0, dev = 0 }
					totals[owner] = t
				end
				t.count += 1
				t.dev += (p.devTier or 0)
			end
		end
		return totals
	end

	local function normalizeCountry(tag)
		local c = ClientStateCache.getCountry(tag)
		if not c then
			return nil
		end
		return {
			code = tag,
			name = c.displayName or tag,
			color = colorOf(c.color),
			government = prettify(c.governmentForm),
			culture = prettify(c.primaryCulture),
			resources = {
				treasury = money(c.treasury),
				treasuryDelta = delta(c.lastIncome),
				treasuryDeltaNum = c.lastIncome or 0,
				manpower = abbreviate(c.manpower) or "\u{2014}",
				pp = abbreviate(c.politicalPower or 0) or "0",
				stability = signed(c.stability),
				legitimacy = tostring(math.floor((c.legitimacy or 0) + 0.5)),
			},
		}
	end

	local function tagOrNil(t)
		if t == nil or t == "" or t == "NONE" then
			return nil
		end
		return t
	end

	local function recordFromPart(part, id)
		local owner = tagOrNil(part:GetAttribute("owner"))
		local rawName = part:GetAttribute("province_name") or part.Name
		local name = tostring(rawName):gsub("^prov_%d+_", ""):gsub("_", " ")
		return {
			id = id,
			name = name,
			displayCityName = name,
			ownerTag = owner,
			controllerTag = tagOrNil(part:GetAttribute("controller")) or owner,
			terrain = part:GetAttribute("terrain"),
			climate = part:GetAttribute("climate"),
			culture = part:GetAttribute("culture"),
			religion = part:GetAttribute("religion"),
			tradeGood = part:GetAttribute("trade_good"),
			baseTax = part:GetAttribute("base_tax"),
			baseProduction = part:GetAttribute("base_production"),
			baseManpower = part:GetAttribute("base_manpower"),
			devTier = part:GetAttribute("dev_tier"),
			infraTier = part:GetAttribute("infra_tier"),
			fortTier = part:GetAttribute("fort_tier"),
			population = part:GetAttribute("population"),
			isCity = part:GetAttribute("is_city"),
			unrest = part:GetAttribute("unrest"),
			autonomy = part:GetAttribute("autonomy"),
		}
	end

	-- Resolve a hovered/clicked province PART to a record without depending solely on the
	-- province_id attribute (only ~45% of land parts carry it). Order: live cache record by
	-- id -> build from the part's own stamped attributes (covers cache-miss and parts that
	-- were ownership-painted but never id-mapped) -> nil for genuinely empty/sea land. The
	-- returned id is numeric (or nil); callers that need a server target no-op when it is nil.
	local function provinceFromPart(part)
		if not part then
			return nil
		end
		if part:GetAttribute("is_sea") == true then
			return nil
		end
		local id = part:GetAttribute("province_id")
		if id then
			local cached = ClientStateCache.getProvince(id)
			if cached then
				return cached, id
			end
			return recordFromPart(part, id), id
		end
		if not tagOrNil(part:GetAttribute("owner")) then
			return nil
		end
		return recordFromPart(part, nil), nil
	end

	local function normalizeProvince(p, id)
		if not p then
			return nil
		end
		id = id or p.id
		local ownerCountry = p.ownerTag and ClientStateCache.getCountry(p.ownerTag)
		return {
			id = id,
			name = p.displayCityName or p.name or (id and ("Province #" .. tostring(id))) or "Province",
			ownerTag = p.ownerTag,
			ownerName = ownerCountry and ownerCountry.displayName or p.ownerTag,
			ownerColor = ownerCountry and colorOf(ownerCountry.color) or nil,
			terrain = prettify(p.terrain),
			devTotal = (p.baseTax or 0) + (p.baseProduction or 0) + (p.baseManpower or 0),
			devAdm = p.baseTax,
			devDip = p.baseProduction,
			devMil = p.baseManpower,
			tradeGood = prettify(p.tradeGood),
			fortLevel = p.fortLevel or p.fortTier or p.infraTier,
			culture = prettify(p.culture),
			religion = prettify(p.religion),
			unrest = p.unrest or 0,
			autonomy = p.autonomy or 0,
			tax = abbreviate(p.baseTax),
			production = abbreviate(p.baseProduction),
			manpower = abbreviate(p.baseManpower),
			isOwn = p.ownerTag == claimedTag,
		}
	end

	local function buildClaimable()
		local nations = {}
		local totals = provinceTotals()
		for tag, c in pairs(ClientStateCache.allCountries() or {}) do
			if not c.claimedBy then
				local t = totals[tag]
				nations[#nations + 1] = {
					tag = tag,
					name = c.displayName or tag,
					color = colorOf(c.color),
					government = prettify(c.governmentForm),
					treasury = money(c.treasury),
					manpower = abbreviate(c.manpower),
					provinces = t and t.count or 0,
					development = t and t.dev or 0,
					regiments = (aggregateArmies(tag)),
				}
			end
		end
		table.sort(nations, function(a, b)
			return (a.name or "") < (b.name or "")
		end)
		return nations
	end

	local function resolveTag()
		for tag, c in pairs(ClientStateCache.allCountries() or {}) do
			if c.claimedBy == localPlayer.UserId then
				return tag
			end
		end
		return nil
	end

	Hud.bind({
		onMapMode = function(mode)
			if MapModeController then
				MapModeController.requestMode(mode)
			end
		end,
		action = function(name, payload)
			HudWiring.action(name, payload, fire, claimedTag)
		end,
		onTimeControl = function(req)
			if localPlayer:GetAttribute("IsAdmin") ~= true then
				Hud.notify({
					kind = "warning",
					title = "Admin only",
					body = "Only administrators can control game speed.",
					ttl = 4,
				})
				return
			end
			fire("TimeRequest", req)
		end,
	})

	Hud.start({ mapModes = MAP_MODES, parentGui = modules.parentGui })

	Hud.setContext({
		tag = claimedTag,
		cache = ClientStateCache,
		fire = fire,
		registries = Registries,
		openArmyPanel = Hud.openArmyPanel,
		openFleetPanel = Hud.openFleetPanel,
		openCountryProfile = Hud.openCountryProfile,
		requestTarget = requestTarget,
		cancelTarget = function()
			pendingCommand = nil
		end,
	})

	local function countryCount()
		local n = 0
		for _ in pairs(ClientStateCache.allCountries() or {}) do
			n += 1
		end
		return n
	end

	local function showNationSelection()
		nslog("showNationSelection() called; countries=" .. countryCount())
		if MapModeController then
			MapModeController.requestMode("political")
		end
		local handle = Hud.openNationSelection({
			nations = buildClaimable(),
			onPlay = function(tag)
				fire("ClaimCountry", tag)
			end,
		})
		-- Arm the map-routing flag and hide the HUD AFTER the screen mounts: Hud.openNationSelection
		-- closes any stale screen first, and that destroy() resets nationSelectActive + re-enables the
		-- HUD layer -- doing this last makes the final state independent of that ordering.
		nationSelectActive = true
		local hudLayer = Hud.getLayer("Hud")
		if hudLayer then
			hudLayer.Enabled = false
		end
		local root = handle and handle.root
		nslog(
			"nation selection mounted: handle="
				.. tostring(handle ~= nil)
				.. " rootParent="
				.. tostring(root and root.Parent and root.Parent.Name)
		)
	end

	-- State-based: reconciles the UI to whatever the CURRENT claimed/unclaimed state is, rather
	-- than only reacting to a claimed<->unclaimed transition. This is what makes the screen open
	-- for a freshly-loaded unclaimed player once country data lands (newTag stays nil, so the old
	-- transition gate never fired).
	-- Display-equality guard: updating the CountryBar only matters when a value it actually shows
	-- changed. The server re-sends the country record on every economy/army tick, so without this the
	-- bar would update every frame even when nothing visible moved.
	local RESOURCE_KEYS =
		{ "treasury", "treasuryDelta", "treasuryDeltaNum", "manpower", "pp", "stability", "legitimacy" }
	local lastCountryData = nil
	local function sameCountryData(a, b)
		if a == nil or b == nil then
			return a == b
		end
		if a.code ~= b.code or a.name ~= b.name then
			return false
		end
		if a.government ~= b.government or a.culture ~= b.culture or a.color ~= b.color then
			return false
		end
		local ra, rb = a.resources or {}, b.resources or {}
		for _, k in ipairs(RESOURCE_KEYS) do
			if ra[k] ~= rb[k] then
				return false
			end
		end
		return true
	end

	local countryDirty = false
	local function scheduleCountryRefresh()
		if countryDirty then
			return
		end
		countryDirty = true
		task.defer(function()
			countryDirty = false
			claimedTag = resolveTag()
			Hud.setContext({ tag = claimedTag })
			if claimedTag then
				if nationSelectShown or nationSelectActive then
					nslog("claimed as " .. tostring(claimedTag) .. " -> closing selection, restoring HUD")
					nationSelectShown = false
					nationSelectActive = false
					nationSelectApi = nil
					Hud.closeNationSelection()
				end
				local restoreHud = Hud.getLayer("Hud")
				if restoreHud and not restoreHud.Enabled then
					restoreHud.Enabled = true
				end
				local data = normalizeCountry(claimedTag)
				if data and not sameCountryData(data, lastCountryData) then
					lastCountryData = data
					Hud.setCountry(data)
				end
			elseif not nationSelectShown and countryCount() > 0 then
				nationSelectShown = true
				showNationSelection()
			end
		end)
	end

	ClientStateCache.onChangePrefix("countries", scheduleCountryRefresh)
	ClientStateCache.onChangePrefix("armies", scheduleCountryRefresh)
	ClientStateCache.onChange("snapshot", scheduleCountryRefresh)

	-- Pop the PeaceTreaty modal once when an incoming proposal addressed to the player arrives. The
	-- modal + AcceptPeace/RejectPeace remotes already exist; only this trigger was missing.
	local function describeTerms(terms)
		local kind = type(terms) == "table" and terms.type or nil
		if kind == "white_peace" then
			return { { icon = "Core", label = "Terms", value = "White peace (status quo)" } }
		elseif kind == "annex_occupied" then
			return { { icon = "Core", label = "Terms", value = "Cede occupied territory" } }
		end
		return { { icon = "Core", label = "Terms", value = kind and prettify(kind) or "Negotiated peace" } }
	end
	local seenProposals = {}
	ClientStateCache.onChangePrefix("peaceProposals", function()
		for id, p in pairs(ClientStateCache.allPeaceProposals() or {}) do
			p.id = p.id or id
			local mine = p.toTag == claimedTag and p.status == "pending"
			if mine and not seenProposals[p.id] then
				seenProposals[p.id] = true
				local fromC = ClientStateCache.getCountry(p.fromTag)
				Hud.openPeaceTreaty({
					warName = "Peace offer from " .. ((fromC and fromC.displayName) or p.fromTag or "?"),
					demands = describeTerms(p.terms),
					costs = {},
					onAccept = function()
						fire("AcceptPeace", p.id)
					end,
					onRefuse = function()
						fire("RejectPeace", p.id)
					end,
				})
			elseif not mine then
				-- Allow re-opening if the same id is later re-proposed to us.
				seenProposals[p.id] = nil
			end
		end
	end)

	-- Pop the TradeOffer modal once when a pending trade order is directed at the player (the
	-- counterparty who must accept). Mirrors the peace-proposal hook above.
	local seenOrders = {}
	ClientStateCache.onChangePrefix("tradeOrders", function()
		for id, o in pairs(ClientStateCache.allTradeOrders() or {}) do
			o.id = o.id or id
			local mine = o.counterpartyTag == claimedTag and o.state == "Pending"
			if mine and not seenOrders[o.id] then
				seenOrders[o.id] = true
				Hud.openTradeOffer(o)
			elseif not mine then
				seenOrders[o.id] = nil
			end
		end
	end)

	-- Pop the DiplomaticOffer modal once when a pending NAP offer is directed at the player.
	-- Mirrors the trade-order hook above (active NAPs live on the country record, not here).
	local seenPacts = {}
	ClientStateCache.onChangePrefix("pacts", function()
		for id, p in pairs(ClientStateCache.allPacts() or {}) do
			p.id = p.id or id
			local mine = p.toTag == claimedTag and p.status == "pending"
			if mine and not seenPacts[p.id] then
				seenPacts[p.id] = true
				Hud.openDiplomaticOffer(p)
			elseif not mine then
				seenPacts[p.id] = nil
			end
		end
	end)

	-- Pop the political event card when the claimed country has an activeEvent (and close it
	-- when the event is resolved/auto-resolved server-side). Mirrors the peace/trade/pact hooks.
	local activeEventKey = nil
	ClientStateCache.onChangePrefix("countries", function()
		if not claimedTag then
			return
		end
		local c = ClientStateCache.getCountry(claimedTag)
		local ev = c and c.activeEvent
		if ev and ev.eventId then
			local key = tostring(ev.eventId) .. "@" .. tostring(ev.firedDay)
			if key ~= activeEventKey then
				activeEventKey = key
				local capturedId = ev.eventId
				Hud.showEventAlert({
					eventId = capturedId,
					title = ev.title,
					body = ev.body,
					options = ev.options,
					onChoose = function(optionId)
						fire("ResolveEvent", capturedId, optionId)
					end,
				})
			end
		elseif activeEventKey ~= nil then
			-- Only tear down an alert THIS watcher opened (a server-driven event that has now
			-- resolved). Client-side test alerts (Settings -> Test Mode) set no server activeEvent,
			-- so without this guard the next countries delta would hide them after a single tick.
			activeEventKey = nil
			Hud.hideEventAlert()
		end
	end)

	local timeSync = Remotes and Remotes:FindFirstChild("TimeSync")
	if timeSync then
		timeSync.OnClientEvent:Connect(function(packet)
			if type(packet) ~= "table" then
				return
			end
			local dateStr = nil
			if packet.year and packet.month then
				dateStr = string.format("%d %s %d", packet.day or 1, MONTHS[packet.month] or "", packet.year)
			end
			Hud.setTime({ date = dateStr, speed = packet.speed, paused = packet.paused })
		end)
	end

	if MapModeController then
		MapModeController.onChange(function(mode)
			Hud.setMapMode(mode)
		end)
	end

	local ArmyView = modules.ArmyView
	local PathPreview = modules.PathPreview
	-- Start PathPreview's reconcile backstop (the stuck-arrow fix). The live boot path never called
	-- init() before -- only the dead UIController did -- which left the orphan-lane sweep inert.
	if PathPreview and PathPreview.init then PathPreview.init() end
	local WaterBodies = modules.WaterBodies
	local tooltip = ProvinceTooltip.create(Hud.getLayer("Tooltips"))

	local function selectedArmies()
		if ArmyView and ArmyView.getSelectedArmyIds then
			return ArmyView.getSelectedArmyIds()
		end
		return nil
	end

	local function tooltipInfo(prov)
		local owner = "Unclaimed"
		if prov.ownerTag then
			local oc = ClientStateCache.getCountry(prov.ownerTag)
			owner = (oc and oc.displayName) or prov.ownerTag
			if prov.controllerTag and prov.controllerTag ~= prov.ownerTag then
				local cc = ClientStateCache.getCountry(prov.controllerTag)
				owner = owner .. " (occupied by " .. ((cc and cc.displayName) or prov.controllerTag) .. ")"
			end
		end
		local terrain = prettify(prov.terrain)
		local climate = prettify(prov.climate)
		local culture = prettify(prov.culture)
		local religion = prettify(prov.religion)
		local dev = string.format("Dev %d  \u{00B7}  Infra %d", prov.devTier or 0, prov.infraTier or 0)
		if prov.population then
			dev = dev .. "  \u{00B7}  Pop " .. tostring(prov.population)
		end
		return {
			name = prov.displayCityName or prov.name or ("Province #" .. tostring(prov.id or "?")),
			owner = owner,
			terrain = (terrain and climate) and (terrain .. "  \u{00B7}  " .. climate) or terrain,
			society = (culture and religion) and (culture .. "  \u{00B7}  " .. religion) or culture or religion,
			dev = dev,
		}
	end

	local function updatePathPreview(part)
		if not (PathPreview and PathPreview.showMany) then
			return
		end
		local sel = selectedArmies()
		if not sel or #sel == 0 then
			-- Nothing selected -> nothing to preview. (Deselect/move-issued also clear explicitly elsewhere.)
			if PathPreview.clear then PathPreview.clear() end
			return
		end
		-- Resolve the destination via the SAME robust resolver the click/move path uses (the raw
		-- province_id attribute is only stamped on ~45% of land parts). A nil id means a transient
		-- hover-nil / sea tile / unmapped wilderness -> KEEP the last valid preview (do not blank it
		-- while sweeping the cursor across tiles). "What you can preview" thus equals "what you can move to".
		local _, toId = provinceFromPart(part)
		if not toId then return end
		-- One preview per distinct ORIGIN province (armies stacked on the same tile share a route),
		-- so multi-select shows every selected unit's path, not just the first.
		local seen, requests = {}, {}
		for _, armyId in ipairs(sel) do
			local army = ClientStateCache.getArmy(armyId)
			local fromId = army and army.provinceId
			if fromId and not seen[fromId] then
				seen[fromId] = true
				requests[#requests + 1] = { id = fromId, from = fromId }
			end
		end
		if #requests > 0 then
			pcall(PathPreview.showMany, requests, toId)
		end
	end

	if ProvinceInteraction then
		-- Dedupe the water tooltip: ProvinceInteraction fires onWater every 30Hz tick over ocean, so without
		-- this showWater would re-run (and flicker) constantly. Reset whenever the hover state changes (land or
		-- off-map) so re-entering a water body re-shows it.
		local lastWaterName = nil
		ProvinceInteraction.addSelectListener(function(part)
			if nationSelectActive then
				if part then
					local rec = provinceFromPart(part)
					if nationSelectApi then
						nationSelectApi.setCandidateFromMap(rec and rec.ownerTag)
					end
					ProvinceInteraction.clearSelectionSilent()
				end
				return
			end
			if pendingCommand then
				local cmd = pendingCommand
				pendingCommand = nil
				local id = nil
				if part then
					local _, pid = provinceFromPart(part)
					id = pid
				end
				if id then
					if cmd.kind == "attackProvince" and cmd.armyId then
						fire("AttackProvince", cmd.armyId, id)
					elseif cmd.kind == "reinforce" and cmd.armyId then
						fire("Reinforce", cmd.armyId, id)
					elseif cmd.kind == "moveFleet" and cmd.fleetId then
						fire("MoveFleet", cmd.fleetId, id)
					elseif cmd.kind == "attackFleet" and cmd.fleetId then
						local target = nil
						for fid, fleet in pairs(ClientStateCache.allFleets() or {}) do
							if fleet.provinceId == id and fleet.ownerTag ~= claimedTag then
								target = fid
								break
							end
						end
						if target then
							fire("AttackFleet", cmd.fleetId, target)
						else
							Hud.notify({
								kind = "warning",
								title = "No target",
								body = "No enemy fleet in that province.",
								ttl = 4,
							})
						end
					end
				end
				ProvinceInteraction.clearSelectionSilent()
				return
			end
			-- A plain (non-command) map click drops any selected army stack, so clicking a province
			-- or empty tile deselects troops (parallels the X-key deselect). Clicking your OWN army is
			-- consumed by ArmyView's classifier and never reaches this listener, so this cannot clobber
			-- a fresh selection. Alt-inspect (new input scheme) keeps the stack alive -- inspecting
			-- the tile under your own token is its whole purpose.
			local altKeep = ProvinceInteraction.isAltInspecting and ProvinceInteraction.isAltInspecting()
			if ArmyView and ArmyView.deselect and not altKeep then
				local sel = selectedArmies()
				if sel and #sel > 0 then
					ArmyView.deselect()
					if PathPreview and PathPreview.clear then
						PathPreview.clear()
					end
				end
			end
			if not part then
				Hud.closeContext()
				return
			end
			local rec, id = provinceFromPart(part)
			if rec then
				Hud.openProvince(normalizeProvince(rec, id))
			else
				Hud.closeContext()
			end
		end)

		ProvinceInteraction.addHoverListener(function(part)
			-- Hover state changed (this fires only on a province/nil transition), so we're no longer over a
			-- stable water body -> clear the dedupe key so returning to water re-shows the water tooltip.
			lastWaterName = nil
			if nationSelectActive then
				tooltip.hide()
				if nationSelectApi then
					local rec = part and provinceFromPart(part)
					nationSelectApi.hoverCountry(rec and rec.ownerTag)
				end
				return
			end
			local rec = part and provinceFromPart(part)
			if rec then
				tooltip.showProvince(tooltipInfo(rec))
			else
				tooltip.hide()
			end
			updatePathPreview(part)
		end)

		if ProvinceInteraction.onWater then
			ProvinceInteraction.onWater(function(wx, wz)
				if nationSelectActive then
					tooltip.hide()
					lastWaterName = nil
					if nationSelectApi then
						nationSelectApi.hoverCountry(nil)
					end
					return
				end
				if wx and wz then
					local name = (WaterBodies and WaterBodies.getWaterBodyAt and WaterBodies.getWaterBodyAt(wx, wz))
						or "Open Water"
					-- onWater fires every 30Hz tick over ocean; only (re)show when the water body actually changes.
					if name ~= lastWaterName then
						lastWaterName = name
						tooltip.showWater(name)
					end
				else
					tooltip.hide()
					lastWaterName = nil
				end
			end)
		end

		if ArmyView and ProvinceInteraction.onRightClick then
			if ProvinceInteraction.setRightClickPredicate then
				ProvinceInteraction.setRightClickPredicate(function()
					local sel = selectedArmies()
					return sel ~= nil and #sel > 0
				end)
			end
			-- New input scheme: a pending requestTarget command (fleet attack/reinforce picker)
			-- must consume the next click through the select pipeline, not the LMB-move branch.
			if ProvinceInteraction.setCommandPredicate then
				ProvinceInteraction.setCommandPredicate(function()
					return pendingCommand ~= nil
				end)
			end
			ProvinceInteraction.onRightClick(function(part)
				local sel = selectedArmies()
				if not sel or #sel == 0 then
					return
				end
				local _, id = provinceFromPart(part)
				if not id then
					return
				end
				for _, armyId in ipairs(sel) do
					fire("MoveArmyPath", armyId, id)
				end
				-- Issuing the move drops the selection (HOI4-style): clear the preview, deselect the
				-- stack, and close the army panel. The in-progress move arrow is driven by replicated
				-- state (MoveArrowView), not selection, so it stays visible after deselect.
				if PathPreview and PathPreview.clear then
					PathPreview.clear()
				end
				if ArmyView and ArmyView.deselect then
					ArmyView.deselect()
				end
				Hud.closeContext()
			end)
		end

		-- Drag-box select: select every owned army stack inside the rectangle. Shift adds to the
		-- current selection. An empty (non-additive) box clears the selection and closes the panel.
		if ArmyView and ArmyView.selectArmiesInScreenRect and ProvinceInteraction.onDragSelect then
			ProvinceInteraction.onDragSelect(function(rectMin, rectMax, additive)
				local n = ArmyView.selectArmiesInScreenRect(rectMin, rectMax, additive)
				if (not n or n == 0) and not additive then
					Hud.closeContext()
					if PathPreview and PathPreview.clear then
						PathPreview.clear()
					end
				end
			end)
		end
	end

	if ArmyView and ArmyView.onArmySelected then
		local pendingOpen = false
		ArmyView.onArmySelected(function(armyId)
			if not armyId then
				return
			end
			-- A drag-select fires onArmySelected once per army; coalesce them into a single open on the
			-- next step so the panel sees the FULL selection (which drives single-vs-aggregate view).
			if pendingOpen then
				return
			end
			pendingOpen = true
			task.defer(function()
				pendingOpen = false
				local primary = armyId
				if not ClientStateCache.getArmy(primary) then
					return
				end
				local sel = {}
				for _, id in ipairs(selectedArmies() or {}) do
					sel[#sel + 1] = id
				end
				if #sel == 0 then
					sel = { primary }
				end
				local army = ClientStateCache.getArmy(primary)
				local provinceId = army and army.provinceId
				local ids = {}
				for id, a in pairs(ClientStateCache.allArmies() or {}) do
					if a.ownerTag == claimedTag and a.provinceId == provinceId then
						table.insert(ids, id)
					end
				end
				if #ids == 0 then
					ids = { primary }
				end
				Hud.openArmyPanel({ armyId = primary, armyIds = ids, provinceId = provinceId, selectedIds = sel })
			end)
		end)
	end

	-- Deselect the army stack, or (if none) the selected province. Shared by the X key and, on touch,
	-- an on-screen button (no keyboard on touch). clearSelection() fires the select listener with nil,
	-- whose handler closes the context panel (parallels the empty-map click/tap).
	local function doDeselect()
		local sel = selectedArmies()
		if sel and #sel > 0 then
			if ArmyView and ArmyView.deselect then
				ArmyView.deselect()
			end
			Hud.closeContext()
			if PathPreview and PathPreview.clear then
				PathPreview.clear()
			end
			return
		end
		if ProvinceInteraction and ProvinceInteraction.getSelected and ProvinceInteraction.getSelected() then
			ProvinceInteraction.clearSelection()
		end
	end

	-- X deselects (X is otherwise unbound in the live HUD). gameProcessed guards typing in TextBoxes.
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.X then
			doDeselect()
		end
	end)

	-- Touch has no keyboard: an always-available on-screen Deselect button mirrors the X key. (A no-op
	-- when nothing is selected; needed because with units selected a tap on land issues a move, so there
	-- is otherwise no way to deselect without tapping empty water.)
	if Platform.isTouch then
		local hudLayer = Hud.getLayer("Hud")
		if hudLayer then
			local deselectBtn = Button.create({
				parent = hudLayer,
				variant = "secondary",
				text = "Deselect",
				onClick = doDeselect,
			})
			deselectBtn.Name = "TouchDeselect"
			deselectBtn.AnchorPoint = Vector2.new(0, 0)
			deselectBtn.Position = UDim2.fromOffset(68, 16) -- top-left, just right of the settings gear
			deselectBtn:SetAttribute("AoWInputSink", true)
			-- Only meaningful in command mode -- field mode (walking the ruler) has no map selection.
			local function syncDeselectVisible()
				deselectBtn.Visible = (MapModeController == nil) or (MapModeController.current() == "command")
			end
			syncDeselectVisible()
			if MapModeController and MapModeController.onChange then
				MapModeController.onChange(syncDeselectVisible)
			end
		end
	end

	claimedTag = resolveTag()
	Hud.setContext({ tag = claimedTag })
	nslog("boot: claimedTag=" .. tostring(claimedTag) .. " countries=" .. countryCount())
	if claimedTag then
		local data = normalizeCountry(claimedTag)
		if data then
			Hud.setCountry(data)
		end
	else
		scheduleCountryRefresh()
		task.spawn(function()
			local deadline = os.clock() + 30
			while not nationSelectShown and not claimedTag and os.clock() < deadline do
				task.wait(0.25)
				if countryCount() > 0 then
					scheduleCountryRefresh()
				end
			end
			if not nationSelectShown and not claimedTag then
				warn("[AoW NationSelect] selection screen did not open within 30s -- no country data received")
			end
		end)
	end

	return Hud
end

function HudWiring.action(name, payload, fire, claimedTag)
	payload = payload or {}
	if name == "acceptPeace" and payload.proposalId then
		fire("AcceptPeace", payload.proposalId)
	elseif name == "rejectPeace" and payload.proposalId then
		fire("RejectPeace", payload.proposalId)
	elseif name == "releaseNation" then
		fire("ReleaseCountry")
	end
end

return HudWiring
