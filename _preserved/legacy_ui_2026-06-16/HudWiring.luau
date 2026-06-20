local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local UI = script.Parent
local ArtOfWar = UI.Parent
local Hud = require(UI.Hud)

local HudWiring = {}

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
	return (n > 0 and "+" or "") .. tostring(n)
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
	local ProvinceCodes = modules.ProvinceCodes
	if not ClientStateCache then
		return
	end

	local localPlayer = Players.LocalPlayer
	local Remotes = ArtOfWar:FindFirstChild("Remotes")
	local function fire(name, ...)
		local r = Remotes and Remotes:FindFirstChild(name)
		if r then
			r:FireServer(...)
		end
	end

	local claimedTag = nil
	local nationSelectShown = false

	local function aggregateArmies(tag)
		local count, men = 0, 0
		local list = ClientStateCache.allArmies and ClientStateCache.allArmies() or {}
		for _, a in pairs(list) do
			if a.ownerTag == tag then
				count += 1
				men += (a.strength or a.size or 0)
			end
		end
		return count, men
	end

	local function breakdownList(map)
		local out = {}
		if type(map) ~= "table" then
			return out
		end
		for provider, amount in pairs(map) do
			if type(amount) == "number" and amount ~= 0 then
				out[#out + 1] =
					{ label = prettify(provider) or tostring(provider), value = abbreviate(math.abs(amount)) }
			end
		end
		table.sort(out, function(x, y)
			return x.label < y.label
		end)
		return out
	end

	local function normalizeCountry(tag)
		local c = ClientStateCache.getCountry(tag)
		if not c then
			return nil
		end
		local regiments, men = aggregateArmies(tag)
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
				manpowerDelta = delta(c.manpowerDelta),
				manpowerDeltaNum = c.manpowerDelta or 0,
				pp = tostring(c.politicalPower or 0),
				ppDelta = delta(c.politicalPowerGain),
				ppDeltaNum = c.politicalPowerGain or 0,
				stability = signed(c.stability),
				legitimacy = tostring(math.floor((c.legitimacy or 0) + 0.5)),
			},
			politics = {
				governmentForm = prettify(c.governmentForm),
				ideology = prettify(c.ideology),
				legitimacy = c.legitimacy,
				stability = c.stability,
				powerProjection = c.politicalPower,
			},
			economy = {
				treasury = money(c.treasury),
				net = c.totalIncome and c.totalExpenses and money(c.totalIncome - c.totalExpenses) or nil,
				income = breakdownList(c.incomeBreakdown),
				expense = breakdownList(c.expenseBreakdown),
			},
			military = {
				regiments = regiments,
				manpower = c.manpower,
				maxManpower = c.maxManpower or math.max(c.manpower or 1, 1),
				armies = (function()
					local arr = {}
					local list = ClientStateCache.allArmies and ClientStateCache.allArmies() or {}
					for id, a in pairs(list) do
						if a.ownerTag == tag then
							arr[#arr + 1] =
								{ name = a.name or ("Army #" .. tostring(id)), size = a.strength or a.size or 0 }
						end
					end
					return arr
				end)(),
			},
		}
	end

	local function normalizeProvince(id)
		local p = ClientStateCache.getProvince(id)
		if not p then
			return nil
		end
		local ownerCountry = p.ownerTag and ClientStateCache.getCountry(p.ownerTag)
		return {
			id = id,
			name = p.displayCityName or p.name or ("Province #" .. tostring(id)),
			ownerTag = p.ownerTag,
			ownerName = ownerCountry and ownerCountry.displayName or p.ownerTag,
			ownerColor = ownerCountry and colorOf(ownerCountry.color) or nil,
			terrain = prettify(p.terrain),
			devTotal = (p.baseTax or 0) + (p.baseProduction or 0) + (p.baseManpower or 0),
			devAdm = p.baseTax,
			devDip = p.baseProduction,
			devMil = p.baseManpower,
			tradeGood = prettify(p.tradeGood),
			fortLevel = p.fortLevel or p.infraTier,
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
		local all = ClientStateCache.allCountries() or {}
		for tag, c in pairs(all) do
			if not c.claimedBy then
				local regiments, _ = aggregateArmies(tag)
				nations[#nations + 1] = {
					tag = tag,
					name = c.displayName or tag,
					color = colorOf(c.color),
					government = prettify(c.governmentForm),
					treasury = money(c.treasury),
					manpower = abbreviate(c.manpower),
					provinces = c.provinceCount,
					development = c.totalDevelopment,
					regiments = regiments,
					capital = nil,
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
		onPause = function()
			fire("TimeRequest", { action = "togglePause" })
		end,
		onSpeed = function(speed)
			fire("TimeRequest", { action = "setSpeed", speed = speed })
		end,
		action = function(name, payload)
			HudWiring.action(name, payload, fire, claimedTag)
		end,
	})

	Hud.start({ mapModes = MAP_MODES, parentGui = modules.parentGui })

	local function showNationSelection()
		Hud.openNationSelection({
			nations = buildClaimable(),
			onPlay = function(tag)
				fire("ClaimCountry", tag)
			end,
		})
	end

	local countryDirty = false
	local function scheduleCountryRefresh()
		if countryDirty then
			return
		end
		countryDirty = true
		task.defer(function()
			countryDirty = false
			local newTag = resolveTag()
			if newTag ~= claimedTag then
				claimedTag = newTag
				if claimedTag then
					nationSelectShown = false
					Hud.closeNationSelection()
					local data = normalizeCountry(claimedTag)
					if data then
						Hud.setCountry(data)
					end
				elseif not nationSelectShown then
					nationSelectShown = true
					showNationSelection()
				end
			elseif claimedTag then
				local data = normalizeCountry(claimedTag)
				if data then
					Hud.setCountry(data)
				end
			end
		end)
	end

	ClientStateCache.onChangePrefix("countries", scheduleCountryRefresh)
	ClientStateCache.onChangePrefix("armies", scheduleCountryRefresh)

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
			Hud.setClock(dateStr, packet.speed, packet.paused)
		end)
	end

	if MapModeController then
		MapModeController.onChange(function(mode)
			Hud.setMapMode(mode)
		end)
	end

	if ProvinceInteraction then
		ProvinceInteraction.addSelectListener(function(part)
			if not part then
				Hud.closeProvince()
				return
			end
			local id = part:GetAttribute("province_id")
			if not id and ProvinceCodes and ProvinceCodes.idFromPart then
				id = ProvinceCodes.idFromPart(part)
			end
			if not id then
				return
			end
			local prov = normalizeProvince(id)
			if prov then
				Hud.openProvince(prov)
			end
		end)
	end

	claimedTag = resolveTag()
	if claimedTag then
		local data = normalizeCountry(claimedTag)
		if data then
			Hud.setCountry(data)
		end
	elseif next(ClientStateCache.allCountries() or {}) then
		nationSelectShown = true
		showNationSelection()
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
