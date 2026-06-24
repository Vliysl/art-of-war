local ProvinceStamper = {}

local ctx
local partLookup = {}
local leftWrapLookup = {}
local rightWrapLookup = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SOURCE_EU4_MAP = require(ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Data"):WaitForChild("EU4IDMap"))

local EU4_ID_MAP = {}
for k, v in pairs(SOURCE_EU4_MAP) do EU4_ID_MAP[k] = v end
do
	local services = game:GetService("ServerStorage"):FindFirstChild("Services")
	local overlayMod = services and services:FindFirstChild("DataOverlay")
	if overlayMod then
		local ok, overlay = pcall(require, overlayMod)
		if ok and overlay and overlay.getEU4MapOverrides then
			local overrides = overlay.getEU4MapOverrides()
			for k, v in pairs(overrides or {}) do
				EU4_ID_MAP[tonumber(k) or k] = v
			end
		end
	end
end

-- Identity-collapse mode. When the DataOverlay schema is v3, province ids ARE map part ids, so the
-- eu4Map bridge is bypassed: the part is found directly by the province id. Refreshed from the
-- overlay at stamp time (and at register) since the overlay loads its schema flag at boot.
local COLLAPSED = false
local function refreshMode()
	local services = game:GetService("ServerStorage"):FindFirstChild("Services")
	local overlayMod = services and services:FindFirstChild("DataOverlay")
	if overlayMod then
		local ok, overlay = pcall(require, overlayMod)
		if ok and overlay and overlay.isCollapsed then
			local okC, collapsed = pcall(overlay.isCollapsed)
			if okC then COLLAPSED = collapsed == true end
		end
	end
end

-- Resolve a province id to its physical part id. v3: the id IS the part id. v2: bridge via eu4Map.
local function resolvePartId(provinceId)
	if COLLAPSED then return provinceId end
	return EU4_ID_MAP[provinceId]
end

local YIELD_EVERY = 500

local function tunePart(part)
	if part.CanTouch then part.CanTouch = false end
	if part.CastShadow then part.CastShadow = false end
end

local function indexById(folder)
	local n = 0
	for _, part in folder:GetChildren() do
		if part:IsA("BasePart") then
			tunePart(part)
			local pid = tonumber(part.Name:match("prov_(%d+)"))
			if pid then partLookup[pid] = part end
			n += 1
			if n % YIELD_EVERY == 0 then task.wait() end
		end
	end
end

local function indexByName(folder, target)
	local n = 0
	for _, part in folder:GetChildren() do
		if part:IsA("BasePart") then
			tunePart(part)
			target[part.Name] = part
			n += 1
			if n % YIELD_EVERY == 0 then task.wait() end
		end
	end
end

local function buildLookups()
	table.clear(partLookup)
	table.clear(leftWrapLookup)
	table.clear(rightWrapLookup)
	local map = workspace:FindFirstChild("ArtOfWarMap")
	if not map then return end
	local main = map:FindFirstChild("Provinces")
	if main then indexById(main) end
	local lw = map:FindFirstChild("LeftWrap")
	if lw then
		local f = lw:FindFirstChild("Provinces")
		if f then indexByName(f, leftWrapLookup) end
	end
	local rw = map:FindFirstChild("RightWrap")
	if rw then
		local f = rw:FindFirstChild("Provinces")
		if f then indexByName(f, rightWrapLookup) end
	end
end

local function applyTileMaterials()
	local map = workspace:FindFirstChild("ArtOfWarMap")
	if map and map:GetAttribute("tileMaterialsApplied") then return end
	local n = 0
	for _, part in pairs(partLookup) do
		if part:IsA("BasePart") and part.Material ~= Enum.Material.Concrete then
			part.Material = Enum.Material.Concrete
		end
		n += 1
		if n % YIELD_EVERY == 0 then task.wait() end
	end
	for _, part in pairs(leftWrapLookup) do
		if part:IsA("BasePart") and part.Material ~= Enum.Material.Snow then
			part.Material = Enum.Material.Snow
		end
		n += 1
		if n % YIELD_EVERY == 0 then task.wait() end
	end
	for _, part in pairs(rightWrapLookup) do
		if part:IsA("BasePart") and part.Material ~= Enum.Material.Snow then
			part.Material = Enum.Material.Snow
		end
		n += 1
		if n % YIELD_EVERY == 0 then task.wait() end
	end
	if map then map:SetAttribute("tileMaterialsApplied", true) end
end

local function writeAttrs(part, record)
	part:SetAttribute("province_id", record.id)
	part:SetAttribute("province_name", record.displayCityName or record.name)
	part:SetAttribute("owner", record.ownerTag)
	part:SetAttribute("controller", record.controllerTag)
	part:SetAttribute("terrain", record.terrain)
	part:SetAttribute("climate", record.climate)
	part:SetAttribute("culture", record.culture)
	part:SetAttribute("religion", record.religion)
	part:SetAttribute("trade_good", record.tradeGood)
	part:SetAttribute("base_tax", record.baseTax)
	part:SetAttribute("base_production", record.baseProduction)
	part:SetAttribute("base_manpower", record.baseManpower)
	part:SetAttribute("population", record.population)
	part:SetAttribute("dev_tier", record.devTier)
	part:SetAttribute("infra_tier", record.infraTier)
	part:SetAttribute("fort_tier", record.fortTier)
	part:SetAttribute("is_city", record.isCity)
	part:SetAttribute("center_of_trade", record.centerOfTrade)
	part:SetAttribute("area", record.areaId)
	part:SetAttribute("region", record.regionId)
	part:SetAttribute("super_region", record.superRegionId)
	part:SetAttribute("unrest", record.unrest)
	part:SetAttribute("coastal", record.coastal == true)
	part:SetAttribute("has_shipyard", record.hasShipyard == true)
end

local function stampTriple(mainPart, record)
	writeAttrs(mainPart, record)
	local lw = leftWrapLookup[mainPart.Name]
	if lw then writeAttrs(lw, record) end
	local rw = rightWrapLookup[mainPart.Name]
	if rw then writeAttrs(rw, record) end
end

local function stampOne(provinceId)
	local record = ctx.WorldState.getProvince(provinceId)
	if not record then return false end
	local eu4Pid = resolvePartId(provinceId)
	if not eu4Pid then return false end
	local part = partLookup[eu4Pid]
	if not part then return false end
	stampTriple(part, record)
	return true
end

local function stampUnowned()
	local map = workspace:FindFirstChild("ArtOfWarMap")
	if not map then return end

	local mainOwnerByName = {}

	local main = map:FindFirstChild("Provinces")
	if main then
		local n = 0
		for _, part in main:GetChildren() do
			if part:IsA("BasePart") then
				local owner = part:GetAttribute("owner")
				if not owner then
					part:SetAttribute("owner", "NONE")
					part:SetAttribute("province_name", part.Name:gsub("prov_%d+_", ""):gsub("_", " "))
					owner = "NONE"
				end
				if part:GetAttribute("coastal") == nil then
					part:SetAttribute("coastal", false)
				end
				if part:GetAttribute("has_shipyard") == nil then
					part:SetAttribute("has_shipyard", false)
				end
				mainOwnerByName[part.Name] = owner
				n += 1
				if n % YIELD_EVERY == 0 then task.wait() end
			end
		end
	end

	local function propagateWrap(folder)
		local n = 0
		for _, part in folder:GetChildren() do
			if part:IsA("BasePart") then
				if not part:GetAttribute("owner") then
					local owner = mainOwnerByName[part.Name] or "NONE"
					part:SetAttribute("owner", owner)
					part:SetAttribute("province_name", part.Name:gsub("prov_%d+_", ""):gsub("_", " "))
				end
				if part:GetAttribute("coastal") == nil then
					part:SetAttribute("coastal", false)
				end
				if part:GetAttribute("has_shipyard") == nil then
					part:SetAttribute("has_shipyard", false)
				end
				n += 1
				if n % YIELD_EVERY == 0 then task.wait() end
			end
		end
	end

	local lw = map:FindFirstChild("LeftWrap")
	if lw and lw:FindFirstChild("Provinces") then propagateWrap(lw.Provinces) end
	local rw = map:FindFirstChild("RightWrap")
	if rw and rw:FindFirstChild("Provinces") then propagateWrap(rw.Provinces) end
end

local function applyTileOwnershipOverlay()
	local services = game:GetService("ServerStorage"):FindFirstChild("Services")
	local overlayMod = services and services:FindFirstChild("DataOverlay")
	if not overlayMod then return 0 end
	local ok, overlay = pcall(require, overlayMod)
	if not ok or not overlay or not overlay.getTileOverrides then return 0 end
	local overrides = overlay.getTileOverrides()
	local applied = 0
	local map = workspace:FindFirstChild("ArtOfWarMap")
	if not map then return 0 end
	local main = map:FindFirstChild("Provinces")
	if not main then return 0 end

	local countryCache = {}
	local function lookup(tag)
		local hit = countryCache[tag]
		if hit ~= nil then return hit end
		local country = ctx and ctx.WorldState and ctx.WorldState.getCountry and ctx.WorldState.getCountry(tag)
		countryCache[tag] = country or false
		return country
	end

	local function stampCountryAttrs(part, tag)
		if not part then return end
		local country = lookup(tag)
		if not country then
			part:SetAttribute("owner", "NONE")
			part:SetAttribute("controller", "NONE")
			return
		end
		part:SetAttribute("owner", tag)
		part:SetAttribute("controller", tag)
		if type(country.primaryCulture) == "string" and country.primaryCulture ~= "" then
			part:SetAttribute("culture", country.primaryCulture)
		end
		if type(country.stateReligion) == "string" and country.stateReligion ~= "" then
			part:SetAttribute("religion", country.stateReligion)
		end
	end

	local n = 0
	for _, part in main:GetChildren() do
		if part:IsA("BasePart") then
			local tag = overrides[part.Name]
			if tag then
				stampCountryAttrs(part, tag)
				stampCountryAttrs(leftWrapLookup[part.Name], tag)
				stampCountryAttrs(rightWrapLookup[part.Name], tag)
				applied += 1
			end
			n += 1
			if n % YIELD_EVERY == 0 then task.wait() end
		end
	end
	return applied
end

function ProvinceStamper.applyTileOwnership()
	return applyTileOwnershipOverlay()
end

function ProvinceStamper.setTileOwner(partName, ownerTag)
	if type(partName) ~= "string" or partName == "" then return false end
	local map = workspace:FindFirstChild("ArtOfWarMap")
	if not map then return false end
	local main = map:FindFirstChild("Provinces")
	if not main then return false end
	local part = main:FindFirstChild(partName)
	if not part or not part:IsA("BasePart") then return false end
	local effective = (ownerTag == nil or ownerTag == "") and "NONE" or ownerTag
	part:SetAttribute("owner", effective)
	local lw = leftWrapLookup[partName]
	if lw then lw:SetAttribute("owner", effective) end
	local rw = rightWrapLookup[partName]
	if rw then rw:SetAttribute("owner", effective) end
	return true
end

function ProvinceStamper.stamp()
	refreshMode()
	buildLookups()
	applyTileMaterials()
	local provinces = ctx.WorldState.allProvinces()
	local stamped, unmatched, processed = 0, 0, 0
	for seedId, record in provinces do
		processed += 1
		local eu4Pid = resolvePartId(seedId)
		if eu4Pid then
			local part = partLookup[eu4Pid]
			if part then
				stampTriple(part, record)
				stamped += 1
			else
				unmatched += 1
			end
		else
			unmatched += 1
		end
		if processed % YIELD_EVERY == 0 then task.wait() end
	end
	stampUnowned()
	applyTileOwnershipOverlay()
	if unmatched > 0 then
		warn(string.format("[ProvinceStamper] %d seed provinces had no matching map part", unmatched))
	end
	local map = workspace:FindFirstChild("ArtOfWarMap")
	if map then map:SetAttribute("provincesStamped", true) end
	return stamped
end

-- Delta stamp: only stamp provinces whose part has not been stamped yet (province_id attribute
-- absent). Used by the boot self-heal loop so recovering late records/mappings doesn't re-stamp
-- all ~2,800 provinces on every retry. Assumes lookups are already built (stamp() ran at boot).
function ProvinceStamper.stampMissing()
	refreshMode()
	if next(partLookup) == nil then buildLookups() end
	local stamped, processed = 0, 0
	for seedId, record in ctx.WorldState.allProvinces() do
		processed += 1
		local eu4Pid = resolvePartId(seedId)
		local part = eu4Pid and partLookup[eu4Pid]
		if part and part:GetAttribute("province_id") == nil then
			stampTriple(part, record)
			stamped += 1
		end
		if processed % YIELD_EVERY == 0 then task.wait() end
	end
	return stamped
end

-- Set of EU4 part ids that are currently mapped to some province. Lets the boot
-- reconciler tell a genuinely un-promoted tile apart from one that already has (or is
-- about to get) a real seed, so it never creates a duplicate mapping for the same part.
function ProvinceStamper.mappedPartIds()
	local set = {}
	if COLLAPSED then
		-- v3: every registered province's id IS a mapped part id.
		for provinceId in ctx.WorldState.allProvinces() do
			set[provinceId] = true
		end
	else
		for _, eu4Pid in pairs(EU4_ID_MAP) do
			set[eu4Pid] = true
		end
	end
	return set
end

-- Link a freshly-registered province to its physical part and stamp it. The province
-- record must already exist in WorldState; the part is found through the name index that
-- stamp() built (partLookup is keyed by the prov_<id> token, present for every part).
function ProvinceStamper.registerProvincePart(provinceId, eu4Pid)
	EU4_ID_MAP[provinceId] = eu4Pid
	return stampOne(provinceId)
end

function ProvinceStamper.refreshEU4Mappings()
	local services = game:GetService("ServerStorage"):FindFirstChild("Services")
	local overlayMod = services and services:FindFirstChild("DataOverlay")
	if not overlayMod then return 0 end
	local ok, overlay = pcall(require, overlayMod)
	if not ok or not overlay or not overlay.getEU4MapOverrides then return 0 end
	local overrides = overlay.getEU4MapOverrides()
	local added = 0
	for k, v in pairs(overrides or {}) do
		local key = tonumber(k) or k
		if EU4_ID_MAP[key] ~= v then
			EU4_ID_MAP[key] = v
			added += 1
		end
	end
	return added
end

function ProvinceStamper.register(context)
	ctx = context
	refreshMode()
	ProvinceStamper.api = {
		stampOne = stampOne,
		stamp = ProvinceStamper.stamp,
		stampMissing = ProvinceStamper.stampMissing,
		isCollapsed = function() return COLLAPSED end,
		setTileOwner = ProvinceStamper.setTileOwner,
		applyTileOwnership = ProvinceStamper.applyTileOwnership,
		refreshEU4Mappings = ProvinceStamper.refreshEU4Mappings,
		mappedPartIds = ProvinceStamper.mappedPartIds,
		registerProvincePart = ProvinceStamper.registerProvincePart,
	}
	ctx.ProvinceStamper = ProvinceStamper.api

	ctx.EventBus.subscribe(ctx.Channels.ProvinceOwnershipChanged, function(payload)
		if not payload then return end
		if payload.provinceId ~= nil then stampOne(payload.provinceId) end
		if payload.newCapitalId and payload.newCapitalId ~= payload.provinceId then
			stampOne(payload.newCapitalId)
		end
	end)

	ctx.EventBus.subscribe(ctx.Channels.ProvinceOccupied, function(payload)
		if payload and payload.provinceId then stampOne(payload.provinceId) end
	end)
end

return ProvinceStamper
