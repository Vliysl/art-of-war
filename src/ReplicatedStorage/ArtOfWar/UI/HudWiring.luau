local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local UI = script.Parent
local ArtOfWar = UI.Parent
local Hud = require(UI.Hud)
local Registries = require(UI.Registries)
local ProvinceTooltip = require(UI.Components.ProvinceTooltip)
local Platform = require(ArtOfWar.Modules.Platform)
local CameraController = require(ArtOfWar.Modules.CameraController)
local Button = require(UI.Components.Button)
local RadialMenu = require(UI.RadialMenu)
local PeaceInfo = require(UI.PeaceInfo)
local WorldConstants = require(ArtOfWar.Shared.WorldConstants)
local SeaNodes = require(ArtOfWar.Shared.SeaNodes)
local Technologies = require(ArtOfWar.Data.Technologies)
local CountryColor = require(ArtOfWar.Modules.CountryColor)

-- Sea targeting (C9): a hovered water point snaps to the nearest baked sea node within this
-- many studs (mirrors ProvinceInteraction's click-side SEA_TARGET_MAX_DIST).
local SEA_HOVER_MAX_DIST = 60

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

	-- (aggregateArmies + provinceTotals removed with buildClaimable: an every-army and an every-province scan
	-- that existed solely to build the nation-selection payload nothing ever read.)

	-- Active tech + progress %, for the Research button tooltip (e.g. "Field Howitzers  62%").
	local function researchLabel(c)
		local rec = c.research
		local techId = rec and rec.active
		if not techId then
			return "No active research"
		end
		local def = Technologies[techId]
		local name = (def and def.name) or techId
		local cost = (def and def.cost) or 0
		local prog = (rec.progress and rec.progress[techId]) or 0
		if cost <= 0 then
			return name .. "  100%"
		end
		local pct = math.clamp(math.floor(prog / cost * 100 + 0.5), 0, 100)
		return string.format("%s  %d%%", name, pct)
	end

	local function normalizeCountry(tag)
		local c = ClientStateCache.getCountry(tag)
		if not c then
			return nil
		end
		return {
			code = tag,
			name = c.displayName or tag,
			color = CountryColor.resolve(tag),
			-- Carried purely so sameCountryData below can see a crest swap. Forming a formable keeps the tag and
			-- changes displayName/color/flagAssetId independently, so without these an editor-authored formable
			-- that sets only a flag would be judged "same country", Hud.setCountry would never be called, and
			-- the bar would keep the old crest -- the same trap CountryBar's own update() used to fall into.
			flag = CountryColor.resolveFlag(tag),
			formed = CountryColor.isFormed(tag),
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
				prestige = tostring(math.floor((c.prestige or 0) + 0.5)),
				manpowerCap = c.manpowerCap and abbreviate(c.manpowerCap) or nil,
				research = researchLabel(c),
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
			ownerColor = p.ownerTag and CountryColor.resolve(p.ownerTag) or nil,
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

	-- The single province whose ProvinceOverview context panel is open, tracked so the panel can be
	-- rebuilt live when that province changes owner (annex/peace). Without this the header keeps the
	-- open-time owner snapshot -- which greys out once that country is deleted (the annex "still shows
	-- MCS" bug). Cleared implicitly: a new single province replaces it, the multi-select panel nils it,
	-- and Hud.getContextName() guards against ever firing over a different panel.
	local openProvinceId = nil
	local openProvinceOwner = nil
	local function showProvincePanel(rec, id)
		openProvinceId = id
		openProvinceOwner = rec and rec.ownerTag
		Hud.openProvince(normalizeProvince(rec, id))
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
		-- A screen left open (e.g. Settings, where Switch Country lives) renders on its own
		-- layer and would float over the selection UI -- close it before mounting.
		if Hud.closeScreen then
			Hud.closeScreen()
		end
		-- NationSelection builds its own view models straight from ClientStateCache; the only thing it ever
		-- reads off ctx.data is onPlay. This used to also pass `nations = buildClaimable()` -- a full province
		-- scan plus a per-country army aggregation, computed on the boot path and then discarded unread.
		local handle = Hud.openNationSelection({
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
	-- Keys the CountryBar shows: treasury (+income delta) + manpower on the big buttons, and PP / stability /
	-- legitimacy / prestige as the right-side stat readouts. A shown value missing here would render once but
	-- never live-update (sameCountryData would treat ticks changing only it as "no change").
	local RESOURCE_KEYS =
		{ "treasury", "treasuryDelta", "treasuryDeltaNum", "manpower", "manpowerCap", "research", "pp", "stability", "legitimacy", "prestige" }
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
		if a.flag ~= b.flag or a.formed ~= b.formed then
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

	-- Peace proposals: (1) pop the offer modal once for an incoming proposal addressed to the player,
	-- now with war standing + a clear per-term breakdown; (2) notify on our OWN proposals'
	-- transitions so proposing peace isn't a silent void (sent / accepted / rejected / expired).
	local function countryName(tag)
		local c = tag and ClientStateCache.getCountry(tag)
		return (c and c.displayName) or tag or "?"
	end
	-- Friendly label for a pact record's `type`, used in the outgoing-pact result toasts below.
	local PACT_LABELS = { alliance = "Alliance", nap = "Non-Aggression Pact", call_to_arms = "Call to Arms", guarantee = "Guarantee" }
	local function pactLabel(t)
		return PACT_LABELS[t] or "Pact"
	end
	local seenProposals = {}
	local myProposalStatus = {}
	local myPactStatus = {}
	local seenWarStatus = {}
	local peaceTrackedTag = nil
	-- On a country switch, clear per-nation tracking so pending offers re-pop and notifications re-arm
	-- for the new nation (and the old nation's ids don't wrongly suppress them).
	local function syncPeaceTag()
		if claimedTag ~= peaceTrackedTag then
			seenProposals = {}
			myProposalStatus = {}
			myPactStatus = {}
			seenWarStatus = {}
			peaceTrackedTag = claimedTag
		end
	end
	ClientStateCache.onChangePrefix("peaceProposals", function()
		syncPeaceTag()
		for id, p in pairs(ClientStateCache.allPeaceProposals() or {}) do
			p.id = p.id or id
			if p.toTag == claimedTag then
				if p.status == "pending" then
					if not seenProposals[p.id] then
						seenProposals[p.id] = true
						Hud.openPeaceTreaty({
							warName = "Peace offer from " .. countryName(p.fromTag),
							warStanding = PeaceInfo.warStanding(ClientStateCache, p.warId, claimedTag),
							terms = PeaceInfo.describeTerms(ClientStateCache, p.terms, p.fromTag, p.toTag, claimedTag),
							onAccept = function()
								fire("AcceptPeace", p.id)
							end,
							onRefuse = function()
								fire("RejectPeace", p.id)
							end,
						})
					end
				else
					-- Responded/expired -> allow a future re-proposal (new id) to pop again.
					seenProposals[p.id] = nil
				end
			end
			if p.fromTag == claimedTag then
				local prev = myProposalStatus[p.id]
				if prev ~= p.status then
					myProposalStatus[p.id] = p.status
					local who = countryName(p.toTag)
					if p.status == "pending" and prev == nil then
						Hud.notify({
							kind = "info",
							title = "Peace offer sent",
							body = "Awaiting " .. who .. "'s response.",
							ttl = 5,
						})
					elseif p.status == "accepted" then
						Hud.notify({
							kind = "success",
							title = "Peace accepted",
							body = who .. " accepted your terms \u{2014} the war ends.",
							ttl = 6,
						})
					elseif p.status == "rejected" then
						Hud.notify({
							kind = "warning",
							title = "Peace rejected",
							body = who .. " rejected your peace offer.",
							ttl = 6,
						})
					elseif p.status == "expired" then
						Hud.notify({
							kind = "warning",
							title = "Peace offer expired",
							body = who .. " did not respond in time.",
							ttl = 6,
						})
					end
				end
			end
		end
	end)

	-- War closure: notify when a war the player is in ends (seed silently on first sight so joining
	-- mid-game with old ended wars doesn't spam).
	ClientStateCache.onChangePrefix("wars", function()
		syncPeaceTag()
		for id, w in pairs(ClientStateCache.allWars() or {}) do
			if w.attackerTag == claimedTag or w.defenderTag == claimedTag then
				local prev = seenWarStatus[id]
				if prev == nil then
					seenWarStatus[id] = w.status
				elseif prev ~= w.status then
					seenWarStatus[id] = w.status
					if w.status == "ended" then
						local other = (w.attackerTag == claimedTag) and w.defenderTag or w.attackerTag
						Hud.notify({
							kind = "info",
							title = "War concluded",
							body = "Your war with " .. countryName(other) .. " has ended.",
							ttl = 6,
						})
					end
				end
			end
		end
	end)

	-- Trade was cut for the public playtest: no player or AI creates trade orders, so the incoming-TradeOffer
	-- modal hook is removed -- a stray/exploit PlaceTradeOrder can no longer pop an unanswerable accept/reject
	-- modal at a player with no Trade UI. (Re-add this subscription alongside Hud.openTradeOffer when a trade
	-- entry point returns.)

	-- (1) Pop the DiplomaticOffer modal once when a pending pact offer (alliance / NAP / call-to-arms) is
	-- directed at the player; (2) toast the PROPOSER when their outgoing pact is accepted / rejected / expired.
	-- Pact proposals were fire-and-forget, so a below-opinion-threshold alliance/NAP that the AI instantly
	-- rejects gave zero feedback and read as a broken button. Mirrors the peace-proposal hook above.
	local seenPacts = {}
	ClientStateCache.onChangePrefix("pacts", function()
		syncPeaceTag()
		for id, p in pairs(ClientStateCache.allPacts() or {}) do
			p.id = p.id or id
			-- Incoming offer -> modal (once).
			if p.toTag == claimedTag and p.status == "pending" then
				if not seenPacts[p.id] then
					seenPacts[p.id] = true
					Hud.openDiplomaticOffer(p)
				end
			else
				seenPacts[p.id] = nil
			end
			-- Outgoing proposal -> result toast on any status transition (incl. first sight already-rejected).
			if p.fromTag == claimedTag then
				local prev = myPactStatus[p.id]
				if prev ~= p.status then
					myPactStatus[p.id] = p.status
					local who = countryName(p.toTag)
					local what = pactLabel(p.type)
					if p.status == "pending" and prev == nil then
						Hud.notify({ kind = "info", title = what .. " proposed", body = "Awaiting " .. who .. "'s response.", ttl = 5 })
					elseif p.status == "accepted" then
						Hud.notify({ kind = "success", title = what .. " accepted", body = who .. " accepted your " .. what .. ".", ttl = 6 })
					elseif p.status == "rejected" then
						Hud.notify({ kind = "warning", title = what .. " rejected", body = who .. " rejected your " .. what .. ".", ttl = 6 })
					elseif p.status == "expired" then
						Hud.notify({ kind = "warning", title = what .. " expired", body = who .. " did not respond in time.", ttl = 6 })
					end
				end
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
	if PathPreview and PathPreview.init then
		PathPreview.init()
	end
	local WaterBodies = modules.WaterBodies
	local tooltip = ProvinceTooltip.create(Hud.getLayer("Tooltips"))

	local groupStripMod = nil -- set below when the army-group strip inits; drives the touch Hide/Show Groups button
	-- Army-group card strip (bottom-center HUD). Owns all group commands; needs fire/requestTarget/cache
	-- and a live tag getter (claimedTag is reassigned on claim/switch, so pass a closure, not the value).
	if WorldConstants.EnableArmyGroups and WorldConstants.EnableGroupCards then
		local okStrip, ArmyGroupStrip = pcall(require, UI:WaitForChild("ArmyGroupStrip"))
		if okStrip and ArmyGroupStrip and ArmyGroupStrip.init then
			groupStripMod = ArmyGroupStrip
			pcall(ArmyGroupStrip.init, {
				parent = Hud.getLayer("Hud"),
				cache = ClientStateCache,
				armyView = ArmyView,
				fire = fire,
				requestTarget = requestTarget,
				getTag = function()
					return claimedTag
				end,
				registries = Registries,
			})
		end
	end

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

	-- Drive the preview lanes to a raw destination id (province, or a negative sea node id --
	-- C9 water hovers resolve to sea nodes with no part to pass through provinceFromPart).
	-- A nil toId means a transient hover-nil / unmapped wilderness -> KEEP the last valid
	-- preview (do not blank it while sweeping the cursor across tiles).
	local function updatePathPreviewToId(toId)
		if not (PathPreview and PathPreview.showMany) then
			return
		end
		local sel = selectedArmies()
		if not sel or #sel == 0 then
			-- Nothing selected -> nothing to preview. (Deselect/move-issued also clear explicitly elsewhere.)
			if PathPreview.clear then
				PathPreview.clear()
			end
			return
		end
		if not toId then
			return
		end
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

	local function updatePathPreview(part)
		-- Resolve the destination via the SAME robust resolver the click/move path uses (the raw
		-- province_id attribute is only stamped on ~45% of land parts). "What you can preview"
		-- thus equals "what you can move to".
		local _, toId = provinceFromPart(part)
		updatePathPreviewToId(toId)
	end

	if ProvinceInteraction then
		-- Dedupe the water tooltip: ProvinceInteraction fires onWater every 30Hz tick over ocean, so without
		-- this showWater would re-run (and flicker) constantly. Reset whenever the hover state changes (land or
		-- off-map) so re-entering a water body re-shows it. lastSeaHoverId is the same dedupe for the sea-node
		-- path preview (C9): re-fire only when the resolved node CHANGES, not per 30Hz tick.
		local lastWaterName = nil
		local lastSeaHoverId = nil
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
				local clickedRec = nil
				if part then
					local prec, pid = provinceFromPart(part)
					id = pid
					clickedRec = prec
				end
				if id then
					if cmd.kind == "attackProvince" and cmd.armyId then
						fire("AttackProvince", cmd.armyId, id)
					elseif cmd.kind == "coverBorder" and cmd.groupId then
						-- Combat depth D: resolve the clicked tile's owner and cover the group's border
						-- against that nation. Mirrors attackProvince; no-ops on an unowned/empty tile.
						-- Prefer the live cache record, falling back to the resolver's part-built record
						-- (id-mapped-but-uncached tiles carry their owner attribute on the part).
						local prov = ClientStateCache.getProvince(id) or clickedRec
						local target = prov and prov.ownerTag
						if target and target ~= "" and target ~= "NONE" then
							fire("SetBorderCover", cmd.groupId, target)
						end
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
				showProvincePanel(rec, id)
			else
				Hud.closeContext()
			end
		end)

		-- Multi-province selection (C6): the aggregate ProvinceOverview is driven live from the
		-- multi-select listener -- every toggle re-fires openProvince so the panel tracks the
		-- selection; emptying it closes the panel.
		if WorldConstants.EnableMultiProvinceActions and ProvinceInteraction.addMultiSelectListener then
			ProvinceInteraction.addMultiSelectListener(function(parts)
				if nationSelectActive then
					return
				end
				if not parts or #parts == 0 then
					Hud.closeContext()
					return
				end
				local ids, ownedIds = {}, {}
				for _, part in ipairs(parts) do
					local rec, id = provinceFromPart(part)
					if rec and id ~= nil then
						ids[#ids + 1] = id
						if rec.ownerTag == claimedTag then
							ownedIds[#ownedIds + 1] = id
						end
					end
				end
				if #ids == 0 then
					return
				end
				openProvinceId = nil -- the aggregate panel is not a single tracked province
				Hud.openProvince({ multi = true, ids = ids, ownedIds = ownedIds, isOwn = #ownedIds > 0 })
			end)
		end

		-- Rebuild the open province panel when ITS province changes owner (annex / peace / rebellion), so
		-- the header crest + subtitle + owns-gated Build/Recruit tabs reflect the NEW owner instead of the
		-- stale open-time snapshot. Gated to the single-province ProvinceOverview (getContextName) and to an
		-- actual OWNER change, so it never fires over another panel nor churns on unrelated province ticks.
		if ClientStateCache.onChangePrefix then
			ClientStateCache.onChangePrefix("provinces", function(_, path)
				if openProvinceId == nil then
					return
				end
				local idStr = typeof(path) == "string" and path:match("^provinces%.([^%.]+)")
				if not idStr or idStr ~= tostring(openProvinceId) then
					return
				end
				if Hud.getContextName and Hud.getContextName() ~= "ProvinceOverview" then
					return
				end
				local fresh = ClientStateCache.getProvince(openProvinceId)
					or ClientStateCache.getProvince(tonumber(openProvinceId))
				if not fresh or fresh.ownerTag == openProvinceOwner then
					return
				end
				showProvincePanel(fresh, openProvinceId)
			end)
		end

		ProvinceInteraction.addHoverListener(function(part)
			-- Hover state changed (this fires only on a province/nil transition), so we're no longer over a
			-- stable water body -> clear the dedupe keys so returning to water re-shows the water tooltip
			-- and re-fires the sea-node preview.
			lastWaterName = nil
			lastSeaHoverId = nil
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
					lastSeaHoverId = nil
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
					-- Sea hover preview (C9): with armies selected, hovering water previews the route to
					-- the nearest baked sea node (negative id -- the server pathfinder + ProvincePositions
					-- both speak it directly). Deduped on the resolved node so the preview re-fires only
					-- when it CHANGES; leaving node range keeps the last preview, matching the land rule.
					-- With no armies selected this is inert and water behaves exactly as today.
					if WorldConstants.EnableSeaTransport then
						local sel = selectedArmies()
						if sel and #sel > 0 then
							local seaNodeId = SeaNodes.nearestNode(wx, wz, SEA_HOVER_MAX_DIST)
							if seaNodeId and seaNodeId ~= lastSeaHoverId then
								lastSeaHoverId = seaNodeId
								updatePathPreviewToId(seaNodeId)
							end
						else
							lastSeaHoverId = nil
						end
					end
				else
					tooltip.hide()
					lastWaterName = nil
					lastSeaHoverId = nil
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
				-- Move target: a province PART, or (C9) a { seaNodeId } table for water clicks --
				-- sea tiles have no clickable part, so ProvinceInteraction resolves them to the
				-- nearest baked node. The negative id rides the same move remotes unchanged.
				local id
				if type(part) == "table" and part.seaNodeId then
					id = part.seaNodeId
				else
					local _, pid = provinceFromPart(part)
					id = pid
				end
				if not id then
					return
				end
				-- Multi-army orders batch into one remote: MoveArmyPath is rate-limited 12/10s,
				-- so a large stack selection firing per army would silently drop orders.
				if #sel > 1 and WorldConstants.EnableMultiProvinceActions then
					fire("MoveArmyPathMulti", sel, id)
				else
					for _, armyId in ipairs(sel) do
						fire("MoveArmyPath", armyId, id)
					end
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

	-- C1: long-press on the map with an army selected opens a radial order menu at the finger (touch). Flag-gated.
	if WorldConstants.EnableRadialOrders and ProvinceInteraction.onLongPress then
		ProvinceInteraction.onLongPress(function(screenPos)
			local sel = selectedArmies()
			if not sel or #sel == 0 then
				return false
			end
			-- Aggregate current state across the selection (mirrors ArmyPanel): all reinforcing? all auto-capturing?
			local reAllOn, capAllOn = true, true
			for _, id in ipairs(sel) do
				local a = ClientStateCache.getArmy(id)
				if a then
					if a.reinforceEnabled == false then
						reAllOn = false
					end
					if not a.autoCapture then
						capAllOn = false
					end
				end
			end
			RadialMenu.show(screenPos, {
				{
					text = "Halt",
					onSelect = function()
						for _, id in ipairs(sel) do
							fire("CancelMove", id)
						end
					end,
				},
				{
					text = reAllOn and "Reinforce Off" or "Reinforce On",
					onSelect = function()
						for _, id in ipairs(sel) do
							fire("SetReinforce", id, not reAllOn)
						end
					end,
				},
				{
					text = capAllOn and "Auto-Cap Off" or "Auto-Cap On",
					onSelect = function()
						for _, id in ipairs(sel) do
							fire("SetAutoCapture", id, not capAllOn)
						end
					end,
				},
				{ text = "Deselect", onSelect = doDeselect },
			})
			return true
		end)
	end

	-- Ctrl+M toggles all UI for clean screenshots: every enabled 2D ScreenGui plus the world-space
	-- overlays (army banners, capture/battle bars, capital markers). Snapshot-based -- re-showing only
	-- re-enables what we hid, never Guis that were already off.
	local uiHidden = false
	local hiddenGuis = {}
	local function toggleUiVisibility()
		if uiHidden then
			for _, gui in ipairs(hiddenGuis) do
				if gui.Parent then
					gui.Enabled = true
				end
			end
			table.clear(hiddenGuis)
			uiHidden = false
			return
		end
		table.clear(hiddenGuis)
		local playerGui = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if playerGui then
			for _, gui in ipairs(playerGui:GetChildren()) do
				if gui:IsA("ScreenGui") and gui.Enabled then
					gui.Enabled = false
					hiddenGuis[#hiddenGuis + 1] = gui
				end
			end
		end
		for _, inst in ipairs(workspace:GetDescendants()) do
			if (inst:IsA("BillboardGui") or inst:IsA("SurfaceGui")) and inst.Enabled then
				inst.Enabled = false
				hiddenGuis[#hiddenGuis + 1] = inst
			end
		end
		uiHidden = true
	end

	-- X deselects (X is otherwise unbound in the live HUD). gameProcessed guards typing in TextBoxes.
	-- Ctrl+M is checked first so the screenshot toggle stays global even while a TextBox has focus.
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if
			input.KeyCode == Enum.KeyCode.M
			and (
				UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
				or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
			)
		then
			toggleUiVisibility()
			return
		end
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.X then
			doDeselect()
		end
		if input.KeyCode == Enum.KeyCode.G and ArmyView and ArmyView.selectOwnedArmiesOnScreen then
			ArmyView.selectOwnedArmiesOnScreen() -- B2: select all my armies on screen (Conquerors G)
		end
	end)

	-- Touch on-screen controls (left-edge column): Deselect, Select Army (B2), Box Select toggle + its
	-- Units/Provinces target sub-toggle (A3). Touch has no keyboard/modifiers, so these mirror X / G / Alt.
	if Platform.isTouch then
		local hudLayer = Hud.getLayer("Hud")
		if hudLayer then
			local COL_X, COL_BOTTOM, ROW_GAP = 16, 124, 56
			local function place(btn, row)
				-- Bottom-anchored, growing UP above the country bar: clears the settings gear (top-left) and never
				-- overlaps the country bar on short landscape phones; ROW_GAP=56 leaves ~12px between 44px buttons.
				btn.AnchorPoint = Vector2.new(0, 1)
				btn.Position = UDim2.new(0, COL_X, 1, -(COL_BOTTOM + row * ROW_GAP))
				btn:SetAttribute("AoWInputSink", true)
			end
			local deselectBtn = Button.create({ parent = hudLayer, variant = "secondary", text = "Deselect", onClick = doDeselect })
			deselectBtn.Name = "TouchDeselect"
			place(deselectBtn, 0)
			-- B2: one-tap select-all-my-armies-on-screen (no drag).
			local nearbyBtn = Button.create({
				parent = hudLayer,
				variant = "secondary",
				text = "Select Army",
				onClick = function()
					if ArmyView and ArmyView.selectOwnedArmiesOnScreen then
						ArmyView.selectOwnedArmiesOnScreen()
					end
				end,
			})
			nearbyBtn.Name = "TouchSelectNearby"
			place(nearbyBtn, 1)
			-- Box-select (marquee) toggle + its Units/Provinces target sub-toggle.
			local multiBtn, targetBtn = nil, nil
			local function setMultiBtnText(on)
				local lbl = multiBtn and multiBtn:FindFirstChild("Label")
				if lbl then
					lbl.Text = on and "Box Select: On" or "Box Select: Off"
				end
			end
			local function setTargetBtnText()
				local lbl = targetBtn and targetBtn:FindFirstChild("Label")
				if lbl and ProvinceInteraction.getDragSelectTarget then
					lbl.Text = ProvinceInteraction.getDragSelectTarget() == "provinces" and "Box: Provinces" or "Box: Units"
				end
			end
			if WorldConstants.EnableMultiProvinceActions and ProvinceInteraction.setMultiSelectMode then
				multiBtn = Button.create({
					parent = hudLayer,
					variant = "secondary",
					text = "Box Select: Off",
					onClick = function()
						local on = not ProvinceInteraction.getMultiSelectMode()
						ProvinceInteraction.setMultiSelectMode(on)
						setMultiBtnText(on)
						if targetBtn then
							targetBtn.Visible = on
						end
					end,
				})
				multiBtn.Name = "TouchMultiSelect"
				place(multiBtn, 2)
				targetBtn = Button.create({
					parent = hudLayer,
					variant = "secondary",
					text = "Box: Units",
					onClick = function()
						if not ProvinceInteraction.getDragSelectTarget then
							return
						end
						local nextT = ProvinceInteraction.getDragSelectTarget() == "provinces" and "units" or "provinces"
						ProvinceInteraction.setDragSelectTarget(nextT)
						setTargetBtnText()
					end,
				})
				targetBtn.Name = "TouchDragTarget"
				place(targetBtn, 3)
				targetBtn.Visible = false -- only meaningful while box-select is on
				setTargetBtnText()
			end
			-- Hide/show the army-group card strip (it can occlude the map on small screens).
			if groupStripMod and groupStripMod.setHidden then
				local groupsBtn
				groupsBtn = Button.create({
					parent = hudLayer,
					variant = "secondary",
					text = "Hide Groups",
					onClick = function()
						local hide = not (groupStripMod.isHidden and groupStripMod.isHidden())
						groupStripMod.setHidden(hide)
						local lbl = groupsBtn:FindFirstChild("Label")
						if lbl then
							lbl.Text = hide and "Show Groups" or "Hide Groups"
						end
					end,
				})
				groupsBtn.Name = "TouchGroupsToggle"
				place(groupsBtn, 4)
			end
			-- Only meaningful in command mode -- field mode (walking the ruler) has no map selection.
			local function syncDeselectVisible()
				local visible = (MapModeController == nil) or (MapModeController.current() == "command")
				deselectBtn.Visible = visible
				nearbyBtn.Visible = visible
				if multiBtn then
					multiBtn.Visible = visible
					if not visible then
						if ProvinceInteraction.getMultiSelectMode and ProvinceInteraction.getMultiSelectMode() then
							ProvinceInteraction.setMultiSelectMode(false)
							setMultiBtnText(false)
						end
						if targetBtn then
							targetBtn.Visible = false
						end
					end
				end
			end
			syncDeselectVisible()
			if MapModeController and MapModeController.onChange then
				MapModeController.onChange(syncDeselectVisible)
			end
			-- D5: on-screen zoom +/- (pinch is otherwise the only zoom on touch).
			if CameraController and CameraController.setZoom and CameraController.getZoom then
				local function zoomBtn(sym, factor, y)
					local b = Button.create({
						parent = hudLayer,
						variant = "secondary",
						text = sym,
						onClick = function()
							CameraController.setZoom(CameraController.getZoom() * factor)
						end,
					})
					b.Name = "TouchZoom" .. sym
					b.AnchorPoint = Vector2.new(1, 1)
					b.Position = UDim2.new(1, -16, 1, -y)
					b:SetAttribute("AoWInputSink", true)
				end
				zoomBtn("+", 0.8, 180) -- bottom-right, above the "-" and clear of the top-right toasts
				zoomBtn("-", 1.25, 124)
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
