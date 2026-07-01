local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataLoader = {}

local function str(v: any): string
	if v == nil then return "nil" end
	return tostring(v)
end

local requiredProvinceFields = {
	"id", "name", "areaId", "regionId", "superRegionId",
	"terrain", "climate", "baseTax", "baseProduction", "baseManpower",
	"culture", "religion", "tradeGood", "ownerTag", "controllerTag",
}

local numericProvinceFields = {
	"baseTax", "baseProduction", "baseManpower",
	"devTier", "infraTier", "fortTier", "population",
	"unrest", "autonomy", "centerOfTrade",
}

local requiredCountryFields = {
	"tag", "displayName", "capitalProvinceId",
	"primaryCulture", "stateReligion", "governmentForm", "ideology",
	"color",
}

local numericCountryFields = {
	"capitalProvinceId", "stability", "legitimacy",
	"treasury", "manpower", "politicalPower",
}

local function keysAsSet(t)
	local set = {}
	for key in t do
		set[key] = true
	end
	return set
end

local function valuesAsSet(t, field)
	local set = {}
	for _, entry in t do
		set[entry[field]] = true
	end
	return set
end

local function ensureSchema(record, fields, label, key, errors)
	for _, fieldName in fields do
		if record[fieldName] == nil then
			table.insert(errors, string.format("%s '%s' missing field '%s'", label, str(key), fieldName))
		end
	end
end

local function ensureNumeric(record, fields, label, key, errors)
	for _, fieldName in fields do
		local value = record[fieldName]
		if value ~= nil and type(value) ~= "number" then
			table.insert(errors, string.format("%s '%s' field '%s' must be number, got %s",
				label, str(key), fieldName, typeof(value)))
		end
	end
end

function DataLoader.loadModule(moduleScript)
	assert(typeof(moduleScript) == "Instance" and moduleScript:IsA("ModuleScript"),
		"DataLoader.loadModule: expected ModuleScript")
	local ok, result = pcall(require, moduleScript)
	if not ok then
		error(string.format("DataLoader: failed to require '%s': %s", moduleScript:GetFullName(), str(result)))
	end
	return result
end

function DataLoader.loadCollection(folder)
	assert(typeof(folder) == "Instance", "DataLoader.loadCollection: expected Instance")
	local collected = {}
	for _, child in folder:GetChildren() do
		if child:IsA("ModuleScript") then
			local data = DataLoader.loadModule(child)
			if type(data) == "table" then
				for key, value in data do
					if collected[key] ~= nil then
						warn(string.format("DataLoader: duplicate key '%s' in '%s'", str(key), child:GetFullName()))
					end
					collected[key] = value
				end
			end
		end
	end
	return collected
end

function DataLoader.loadBundle()
	local dataRoot = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Data")
	local function pull(name)
		return DataLoader.loadModule(dataRoot:WaitForChild(name))
	end
	local bundle = {
		climates = pull("Climates"),
		terrains = pull("Terrains"),
		cultureGroups = pull("CultureGroups"),
		cultures = pull("Cultures"),
		religions = pull("Religions"),
		tradeGoods = pull("TradeGoods"),
		ideologies = pull("Ideologies"),
		superRegions = pull("SuperRegions"),
		regions = pull("Regions"),
		areas = pull("Areas"),
		provinces = pull("Provinces"),
		countries = pull("Countries"),
		manufactories = pull("Manufactories"),
		economyPolicies = pull("EconomyPolicies"),
		governmentTypes = pull("GovernmentTypes"),
		governmentArchetypes = pull("GovernmentArchetypes"),
		policies = pull("Policies"),
		privileges = pull("Privileges"),
		events = pull("Events"),
		leaderSlots = pull("LeaderSlots"),
		leaderTraits = pull("LeaderTraits"),
		leaderTitles = pull("LeaderTitles"),
		leaderNames = pull("LeaderNames"),
		factions = pull("Factions"),
		unitTypes = pull("UnitTypes"),
		doctrines = pull("Doctrines"),
		doctrineSlots = pull("DoctrineSlots"),
		shipTypes = pull("ShipTypes"),
		buildingTypes = pull("BuildingTypes"),
		combatPhases = pull("CombatPhases"),
		officerTraits = pull("OfficerTraits"),
		officerNames = pull("OfficerNames"),
		navalMissions = pull("NavalMissions"),
		technologies = pull("Technologies"),
	}
	local overlayModule = game:GetService("ServerStorage"):FindFirstChild("Services")
	overlayModule = overlayModule and overlayModule:FindFirstChild("DataOverlay")
	if overlayModule then
		local ok, DataOverlay = pcall(require, overlayModule)
		if ok and DataOverlay and DataOverlay.applyTo then
			local applyOk, err = pcall(DataOverlay.applyTo, bundle)
			if not applyOk then
				warn("[DataLoader] DataOverlay.applyTo failed: " .. tostring(err))
			end
		end
	end
	return bundle
end

function DataLoader.validateIndividual(bundle)
	local errors = {}
	for key, record in bundle.provinces do
		if type(record) ~= "table" then
			table.insert(errors, string.format("Province keyed at %s is not a table", str(key)))
		else
			ensureSchema(record, requiredProvinceFields, "Province", key, errors)
			ensureNumeric(record, numericProvinceFields, "Province", key, errors)
			if record.id ~= key then
				table.insert(errors, string.format("Province keyed at %s has id=%s (mismatch)", str(key), str(record.id)))
			end
		end
	end
	for key, record in bundle.countries do
		if type(record) ~= "table" then
			table.insert(errors, string.format("Country keyed at '%s' is not a table", str(key)))
		else
			ensureSchema(record, requiredCountryFields, "Country", key, errors)
			ensureNumeric(record, numericCountryFields, "Country", key, errors)
			if record.tag ~= key then
				table.insert(errors, string.format("Country keyed at '%s' has tag='%s' (mismatch)", str(key), str(record.tag)))
			end
		end
	end
	return errors
end

function DataLoader.validateCrossReferences(bundle)
	local errors = {}
	local warnings = {}

	local provinceIds = keysAsSet(bundle.provinces)
	local countryTags = keysAsSet(bundle.countries)
	local areaIds = keysAsSet(bundle.areas)
	local regionIds = keysAsSet(bundle.regions)
	local superRegionIds = keysAsSet(bundle.superRegions)
	local cultureIds = keysAsSet(bundle.cultures)
	local cultureGroupIds = keysAsSet(bundle.cultureGroups)
	local religionIds = keysAsSet(bundle.religions)
	local tradeGoodIds = keysAsSet(bundle.tradeGoods)
	local terrainIds = keysAsSet(bundle.terrains)
	local climateIds = keysAsSet(bundle.climates)
	local ideologyIds = keysAsSet(bundle.ideologies)

	for cultureId, culture in bundle.cultures do
		if not cultureGroupIds[culture.groupId] then
			table.insert(errors, string.format("Culture '%s' references unknown group '%s'", cultureId, str(culture.groupId)))
		end
	end

	for areaId, area in bundle.areas do
		if not regionIds[area.regionId] then
			table.insert(errors, string.format("Area '%s' references unknown region '%s'", areaId, str(area.regionId)))
		end
	end

	for regionId, region in bundle.regions do
		if not superRegionIds[region.superRegionId] then
			table.insert(errors, string.format("Region '%s' references unknown superRegion '%s'", regionId, str(region.superRegionId)))
		end
	end

	local areaProvinceCount = {}
	for areaId in areaIds do areaProvinceCount[areaId] = 0 end

	for provinceId, province in bundle.provinces do
		if not areaIds[province.areaId] then
			table.insert(errors, string.format("Province %s references unknown area '%s'", str(provinceId), str(province.areaId)))
		else
			areaProvinceCount[province.areaId] += 1
			local area = bundle.areas[province.areaId]
			if area.regionId ~= province.regionId then
				table.insert(errors, string.format("Province %s regionId '%s' disagrees with area '%s' regionId '%s'",
					str(provinceId), str(province.regionId), province.areaId, area.regionId))
			end
		end

		if not regionIds[province.regionId] then
			table.insert(errors, string.format("Province %s references unknown region '%s'", str(provinceId), str(province.regionId)))
		else
			local region = bundle.regions[province.regionId]
			if region.superRegionId ~= province.superRegionId then
				table.insert(errors, string.format("Province %s superRegionId '%s' disagrees with region '%s' superRegionId '%s'",
					str(provinceId), str(province.superRegionId), province.regionId, region.superRegionId))
			end
		end

		if not superRegionIds[province.superRegionId] then
			table.insert(errors, string.format("Province %s references unknown superRegion '%s'", str(provinceId), str(province.superRegionId)))
		end

		if not terrainIds[province.terrain] then
			table.insert(errors, string.format("Province %s references unknown terrain '%s'", str(provinceId), str(province.terrain)))
		end
		if not climateIds[province.climate] then
			table.insert(errors, string.format("Province %s references unknown climate '%s'", str(provinceId), str(province.climate)))
		end
		if not cultureIds[province.culture] then
			table.insert(errors, string.format("Province %s references unknown culture '%s'", str(provinceId), str(province.culture)))
		end
		if not religionIds[province.religion] then
			table.insert(errors, string.format("Province %s references unknown religion '%s'", str(provinceId), str(province.religion)))
		end
		if not tradeGoodIds[province.tradeGood] then
			table.insert(errors, string.format("Province %s references unknown tradeGood '%s'", str(provinceId), str(province.tradeGood)))
		end

		if province.ownerTag ~= "NONE" and not countryTags[province.ownerTag] then
			table.insert(errors, string.format("Province %s owner '%s' is not a registered country", str(provinceId), str(province.ownerTag)))
		end
		if province.controllerTag ~= "NONE" and not countryTags[province.controllerTag] then
			table.insert(errors, string.format("Province %s controller '%s' is not a registered country", str(provinceId), str(province.controllerTag)))
		end
		if type(province.cores) == "table" then
			for _, coreTag in province.cores do
				if not countryTags[coreTag] then
					table.insert(errors, string.format("Province %s core '%s' is not a registered country", str(provinceId), str(coreTag)))
				end
			end
		end
	end

	for areaId, count in areaProvinceCount do
		if count == 0 then
			table.insert(warnings, string.format("Area '%s' has no provinces", areaId))
		end
	end

	if bundle.manufactories then
		for manufactoryId, manufactory in bundle.manufactories do
			if manufactory.output and not tradeGoodIds[manufactory.output] then
				table.insert(errors, string.format("Manufactory '%s' output '%s' is not a registered trade good", manufactoryId, str(manufactory.output)))
			end
			if type(manufactory.inputs) == "table" then
				for inputId, amount in manufactory.inputs do
					if not tradeGoodIds[inputId] then
						table.insert(errors, string.format("Manufactory '%s' input '%s' is not a registered trade good", manufactoryId, str(inputId)))
					end
					if type(amount) ~= "number" or amount <= 0 then
						table.insert(errors, string.format("Manufactory '%s' input '%s' must have positive numeric amount", manufactoryId, str(inputId)))
					end
				end
			end
			if type(manufactory.outputAmount) ~= "number" or manufactory.outputAmount <= 0 then
				table.insert(errors, string.format("Manufactory '%s' outputAmount must be positive number", manufactoryId))
			end
		end
	end

	if bundle.economyPolicies then
		for policyId, policy in bundle.economyPolicies do
			for _, field in { "taxMult", "productionMult", "tradeMult", "unrestMult" } do
				if type(policy[field]) ~= "number" then
					table.insert(errors, string.format("EconomyPolicy '%s' missing numeric '%s'", policyId, field))
				end
			end
		end
	end

	if bundle.factions then
		for factionId, faction in bundle.factions do
			if type(faction.baseClout) ~= "number" or faction.baseClout < 0 or faction.baseClout > 1 then
				table.insert(errors, string.format("Faction '%s' baseClout must be number in [0,1]", factionId))
			end
			if type(faction.ideologyAffinity) ~= "table" then
				table.insert(errors, string.format("Faction '%s' missing ideologyAffinity table", factionId))
			elseif bundle.ideologies then
				for ideologyId, value in faction.ideologyAffinity do
					if not bundle.ideologies[ideologyId] then
						table.insert(errors, string.format("Faction '%s' ideologyAffinity references unknown ideology '%s'", factionId, str(ideologyId)))
					end
					if type(value) ~= "number" then
						table.insert(errors, string.format("Faction '%s' ideologyAffinity[%s] must be number", factionId, str(ideologyId)))
					end
				end
			end
			if faction.governmentAffinity then
				for govId in faction.governmentAffinity do
					if bundle.governmentTypes and not bundle.governmentTypes[govId] then
						table.insert(errors, string.format("Faction '%s' governmentAffinity references unknown government '%s'", factionId, str(govId)))
					end
				end
			end
			if faction.policyReactions then
				for policyId in faction.policyReactions do
					if bundle.policies and not bundle.policies[policyId] then
						table.insert(errors, string.format("Faction '%s' policyReactions references unknown policy '%s'", factionId, str(policyId)))
					end
				end
			end
		end
	end

	if bundle.leaderSlots then
		for slotId, slot in bundle.leaderSlots do
			if type(slot.primaryDomain) ~= "string" then
				table.insert(errors, string.format("LeaderSlot '%s' missing primaryDomain", slotId))
			end
			if type(slot.order) ~= "number" then
				table.insert(errors, string.format("LeaderSlot '%s' missing numeric 'order'", slotId))
			end
		end
	end

	if bundle.leaderTraits and bundle.leaderSlots then
		for traitId, trait in bundle.leaderTraits do
			if type(trait.modifiers) ~= "table" then
				table.insert(errors, string.format("LeaderTrait '%s' missing modifiers table", traitId))
			else
				for domain, value in trait.modifiers do
					if type(value) ~= "number" then
						table.insert(errors, string.format("LeaderTrait '%s' modifier '%s' must be number", traitId, str(domain)))
					end
				end
			end
			if type(trait.weight) ~= "number" or trait.weight <= 0 then
				table.insert(errors, string.format("LeaderTrait '%s' weight must be positive number", traitId))
			end
			if type(trait.preferredSlots) ~= "table" then
				table.insert(errors, string.format("LeaderTrait '%s' preferredSlots must be table", traitId))
			else
				for _, slotId in trait.preferredSlots do
					if not bundle.leaderSlots[slotId] then
						table.insert(errors, string.format("LeaderTrait '%s' references unknown slot '%s'", traitId, str(slotId)))
					end
				end
			end
		end
	end

	if bundle.policies and bundle.ideologies then
		for policyId, policy in bundle.policies do
			local gate = policy.ideologyGate
			if gate and gate ~= "any" and not bundle.ideologies[gate] then
				table.insert(errors, string.format("Policy '%s' ideologyGate '%s' unknown", policyId, str(gate)))
			end
			if type(policy.ppCost) ~= "number" or policy.ppCost <= 0 then
				table.insert(errors, string.format("Policy '%s' ppCost must be positive number", policyId))
			end
			if type(policy.ppUpkeep) ~= "number" or policy.ppUpkeep < 0 then
				table.insert(errors, string.format("Policy '%s' ppUpkeep must be non-negative number", policyId))
			end
			if type(policy.modifiers) ~= "table" then
				table.insert(errors, string.format("Policy '%s' missing modifiers table", policyId))
			else
				for domain, value in policy.modifiers do
					if type(value) ~= "number" then
						table.insert(errors, string.format("Policy '%s' modifier '%s' must be number", policyId, str(domain)))
					end
				end
			end
		end
	end

	if bundle.governmentTypes and bundle.ideologies then
		for govId, gov in bundle.governmentTypes do
			if type(gov.allowedIdeologies) ~= "table" or #gov.allowedIdeologies == 0 then
				table.insert(errors, string.format("GovernmentType '%s' has empty allowedIdeologies", govId))
			else
				for _, ideologyId in gov.allowedIdeologies do
					if not bundle.ideologies[ideologyId] then
						table.insert(errors, string.format("GovernmentType '%s' allows unknown ideology '%s'", govId, str(ideologyId)))
					end
				end
			end
			if type(gov.ppPerTick) ~= "number" then
				table.insert(errors, string.format("GovernmentType '%s' missing numeric 'ppPerTick'", govId))
			end
			if gov.transitions then
				for targetId, rule in gov.transitions do
					if not bundle.governmentTypes[targetId] then
						table.insert(errors, string.format("GovernmentType '%s' transition target '%s' unknown", govId, str(targetId)))
					end
					if type(rule.ppCost) ~= "number" or rule.ppCost <= 0 then
						table.insert(errors, string.format("GovernmentType '%s' transition to '%s' has invalid ppCost", govId, str(targetId)))
					end
				end
			end
		end
	end

	if bundle.unitTypes then
		for unitId, unit in bundle.unitTypes do
			for _, field in { "attack", "defense", "speed", "upkeep", "recruitCost", "recruitManpower", "recruitTicks" } do
				if type(unit[field]) ~= "number" then
					table.insert(errors, string.format("UnitType '%s' missing numeric '%s'", unitId, field))
				end
			end
			if unit.terrainMods then
				for terrainId, value in unit.terrainMods do
					if not terrainIds[terrainId] then
						table.insert(errors, string.format("UnitType '%s' terrainMod references unknown terrain '%s'", unitId, str(terrainId)))
					end
					if type(value) ~= "number" then
						table.insert(errors, string.format("UnitType '%s' terrainMod[%s] must be number", unitId, str(terrainId)))
					end
				end
			end
		end
	end

	if bundle.doctrines then
		for doctrineId, doctrine in bundle.doctrines do
			if type(doctrine.modifiers) ~= "table" then
				table.insert(errors, string.format("Doctrine '%s' missing modifiers table", doctrineId))
			else
				for domain, value in doctrine.modifiers do
					if type(value) ~= "number" then
						table.insert(errors, string.format("Doctrine '%s' modifier '%s' must be number", doctrineId, str(domain)))
					end
				end
			end
			if bundle.doctrineSlots and doctrine.slot and not bundle.doctrineSlots[doctrine.slot] then
				table.insert(errors, string.format("Doctrine '%s' references unknown slot '%s'", doctrineId, str(doctrine.slot)))
			end
		end
	end

	if bundle.doctrineSlots then
		for slotId, slot in bundle.doctrineSlots do
			if type(slot.baseSwitchCost) ~= "number" or slot.baseSwitchCost <= 0 then
				table.insert(errors, string.format("DoctrineSlot '%s' baseSwitchCost must be positive number", slotId))
			end
			if type(slot.tier) ~= "number" then
				table.insert(errors, string.format("DoctrineSlot '%s' tier must be number", slotId))
			end
		end
	end

	for tag, country in bundle.countries do
		if country.economyPolicy and bundle.economyPolicies and not bundle.economyPolicies[country.economyPolicy] then
			table.insert(errors, string.format("Country '%s' economyPolicy '%s' unknown", tag, str(country.economyPolicy)))
		end
		if bundle.governmentTypes then
			local gov = bundle.governmentTypes[country.governmentForm]
			if not gov then
				table.insert(errors, string.format("Country '%s' governmentForm '%s' is not a registered government type", tag, str(country.governmentForm)))
			elseif gov.allowedIdeologies then
				local allowed = false
				for _, allowedId in gov.allowedIdeologies do
					if allowedId == country.ideology then allowed = true break end
				end
				if not allowed then
					table.insert(errors, string.format("Country '%s' ideology '%s' not allowed by government '%s'", tag, str(country.ideology), str(country.governmentForm)))
				end
			end
		end
		if not provinceIds[country.capitalProvinceId] then
			table.insert(errors, string.format("Country '%s' capitalProvinceId %s does not exist",
				tag, str(country.capitalProvinceId)))
		else
			local capital = bundle.provinces[country.capitalProvinceId]
			if capital.ownerTag ~= tag then
				table.insert(errors, string.format("Country '%s' capital %s is owned by '%s'",
					tag, str(country.capitalProvinceId), str(capital.ownerTag)))
			end
			if not capital.isCity then
				table.insert(warnings, string.format("Country '%s' capital %s has isCity=false",
					tag, str(country.capitalProvinceId)))
			end
		end

		if not cultureIds[country.primaryCulture] then
			table.insert(errors, string.format("Country '%s' primaryCulture '%s' unknown", tag, str(country.primaryCulture)))
		end
		if type(country.acceptedCultures) == "table" then
			for _, cultureId in country.acceptedCultures do
				if not cultureIds[cultureId] then
					table.insert(errors, string.format("Country '%s' acceptedCulture '%s' unknown", tag, str(cultureId)))
				end
			end
		end
		if not religionIds[country.stateReligion] then
			table.insert(errors, string.format("Country '%s' stateReligion '%s' unknown", tag, str(country.stateReligion)))
		end
		if not ideologyIds[country.ideology] then
			table.insert(errors, string.format("Country '%s' ideology '%s' unknown", tag, str(country.ideology)))
		end

		local rivalSet = {}
		if type(country.historicalRivals) == "table" then
			for _, rivalTag in country.historicalRivals do
				if not countryTags[rivalTag] then
					table.insert(errors, string.format("Country '%s' historicalRival '%s' unknown", tag, str(rivalTag)))
				elseif rivalTag == tag then
					table.insert(warnings, string.format("Country '%s' lists itself as historicalRival", tag))
				elseif rivalSet[rivalTag] then
					table.insert(warnings, string.format("Country '%s' has duplicate historicalRival '%s'", tag, rivalTag))
				else
					rivalSet[rivalTag] = true
				end
			end
		end
		if type(country.historicalFriends) == "table" then
			local friendSet = {}
			for _, friendTag in country.historicalFriends do
				if not countryTags[friendTag] then
					table.insert(errors, string.format("Country '%s' historicalFriend '%s' unknown", tag, str(friendTag)))
				elseif friendTag == tag then
					table.insert(warnings, string.format("Country '%s' lists itself as historicalFriend", tag))
				elseif friendSet[friendTag] then
					table.insert(warnings, string.format("Country '%s' has duplicate historicalFriend '%s'", tag, friendTag))
				elseif rivalSet[friendTag] then
					table.insert(errors, string.format("Country '%s' lists '%s' as both rival and friend", tag, friendTag))
				else
					friendSet[friendTag] = true
				end
			end
		end
	end

	return {
		ok = #errors == 0,
		errors = errors,
		warnings = warnings,
	}
end

local function firstKey(t)
	if type(t) ~= "table" then return nil end
	local keys = {}
	for k in pairs(t) do table.insert(keys, k) end
	table.sort(keys)
	return keys[1]
end

local function pickKey(t, preferred)
	if type(t) ~= "table" then return nil end
	if preferred and t[preferred] then return preferred end
	return firstKey(t)
end

function DataLoader.healBundle(bundle)
	local heals = {}
	if type(bundle) ~= "table" then return heals end

	local areas = bundle.areas or {}
	local regions = bundle.regions or {}
	local superRegions = bundle.superRegions or {}
	local cultures = bundle.cultures or {}
	local religions = bundle.religions or {}
	local terrains = bundle.terrains or {}
	local climates = bundle.climates or {}
	local tradeGoods = bundle.tradeGoods or {}
	local countries = bundle.countries or {}

	local fallbackArea = firstKey(areas)
	local fallbackRegion = firstKey(regions)
	local fallbackSuperRegion = firstKey(superRegions)
	local fallbackCulture = firstKey(cultures)
	local fallbackReligion = firstKey(religions)
	local fallbackTerrain = pickKey(terrains, "plains")
	local fallbackClimate = pickKey(climates, "temperate")
	local fallbackTradeGood = pickKey(tradeGoods, "grain")

	for id, rec in pairs(bundle.provinces or {}) do
		if type(rec) ~= "table" then
			table.insert(heals, string.format("Province %s dropped: overlay record was not a table", tostring(id)))
			bundle.provinces[id] = nil
		end
	end
	for tag, rec in pairs(bundle.countries or {}) do
		if type(rec) ~= "table" then
			table.insert(heals, string.format("Country '%s' dropped: overlay record was not a table", tostring(tag)))
			bundle.countries[tag] = nil
		end
	end

	for provinceId, province in pairs(bundle.provinces or {}) do
		if type(province) == "table" then
			local pidStr = tostring(provinceId)

			if not areas[province.areaId] then
				if fallbackArea then
					table.insert(heals, string.format("Province %s areaId '%s' invalid → '%s'", pidStr, str(province.areaId), fallbackArea))
					province.areaId = fallbackArea
				end
			end
			local areaRec = province.areaId and areas[province.areaId]
			if areaRec and areaRec.regionId and province.regionId ~= areaRec.regionId then
				table.insert(heals, string.format("Province %s regionId '%s' → '%s' (from area)", pidStr, str(province.regionId), areaRec.regionId))
				province.regionId = areaRec.regionId
			elseif not regions[province.regionId] and fallbackRegion then
				table.insert(heals, string.format("Province %s regionId '%s' invalid → '%s'", pidStr, str(province.regionId), fallbackRegion))
				province.regionId = fallbackRegion
			end
			local regionRec = province.regionId and regions[province.regionId]
			if regionRec and regionRec.superRegionId and province.superRegionId ~= regionRec.superRegionId then
				table.insert(heals, string.format("Province %s superRegionId '%s' → '%s' (from region)", pidStr, str(province.superRegionId), regionRec.superRegionId))
				province.superRegionId = regionRec.superRegionId
			elseif not superRegions[province.superRegionId] and fallbackSuperRegion then
				table.insert(heals, string.format("Province %s superRegionId '%s' invalid → '%s'", pidStr, str(province.superRegionId), fallbackSuperRegion))
				province.superRegionId = fallbackSuperRegion
			end

			if not terrains[province.terrain] and fallbackTerrain then
				table.insert(heals, string.format("Province %s terrain '%s' → '%s'", pidStr, str(province.terrain), fallbackTerrain))
				province.terrain = fallbackTerrain
			end
			if not climates[province.climate] and fallbackClimate then
				table.insert(heals, string.format("Province %s climate '%s' → '%s'", pidStr, str(province.climate), fallbackClimate))
				province.climate = fallbackClimate
			end
			if not tradeGoods[province.tradeGood] and fallbackTradeGood then
				table.insert(heals, string.format("Province %s tradeGood '%s' → '%s'", pidStr, str(province.tradeGood), fallbackTradeGood))
				province.tradeGood = fallbackTradeGood
			end

			if not province.ownerTag or province.ownerTag == "" then
				province.ownerTag = "NONE"
			elseif province.ownerTag ~= "NONE" and not countries[province.ownerTag] then
				table.insert(heals, string.format("Province %s ownerTag '%s' unknown → 'NONE'", pidStr, str(province.ownerTag)))
				province.ownerTag = "NONE"
			end
			local ownerCountry = countries[province.ownerTag]

			if not cultures[province.culture] then
				local fallback = (ownerCountry and cultures[ownerCountry.primaryCulture] and ownerCountry.primaryCulture) or fallbackCulture
				if fallback then
					table.insert(heals, string.format("Province %s culture '%s' → '%s'", pidStr, str(province.culture), fallback))
					province.culture = fallback
				end
			end
			if not religions[province.religion] then
				local fallback = (ownerCountry and religions[ownerCountry.stateReligion] and ownerCountry.stateReligion) or fallbackReligion
				if fallback then
					table.insert(heals, string.format("Province %s religion '%s' → '%s'", pidStr, str(province.religion), fallback))
					province.religion = fallback
				end
			end

			if not province.controllerTag or province.controllerTag == "" or not countries[province.controllerTag] then
				if province.ownerTag and province.ownerTag ~= "NONE" and countries[province.ownerTag] then
					table.insert(heals, string.format("Province %s controllerTag '%s' → '%s' (from owner)", pidStr, str(province.controllerTag), province.ownerTag))
				end
				province.controllerTag = province.ownerTag
			end

			if type(province.cores) ~= "table" then
				province.cores = (province.ownerTag ~= "NONE") and { province.ownerTag } or {}
			else
				local kept = {}
				for _, coreTag in ipairs(province.cores) do
					if countries[coreTag] then table.insert(kept, coreTag) end
				end
				province.cores = kept
			end

			-- Homeland cores (static): default to the seed cores; prune tags for countries that no longer exist.
			if type(province.defaultCores) ~= "table" then
				province.defaultCores = table.clone(province.cores)
			else
				local keptDefault = {}
				for _, coreTag in ipairs(province.defaultCores) do
					if countries[coreTag] then table.insert(keptDefault, coreTag) end
				end
				province.defaultCores = keptDefault
			end
		end
	end

	local ideologies = bundle.ideologies or {}
	local governmentTypes = bundle.governmentTypes or {}
	local economyPolicies = bundle.economyPolicies or {}

	for tag, country in pairs(bundle.countries or {}) do
		if type(country) == "table" then
			if country.governmentForm and not governmentTypes[country.governmentForm] then
				local fallback = firstKey(governmentTypes)
				if fallback then
					table.insert(heals, string.format("Country '%s' governmentForm '%s' unknown → '%s'", tag, str(country.governmentForm), fallback))
					country.governmentForm = fallback
				end
			end
			if country.ideology and not ideologies[country.ideology] then
				local fallback = firstKey(ideologies)
				if fallback then
					table.insert(heals, string.format("Country '%s' ideology '%s' unknown → '%s'", tag, str(country.ideology), fallback))
					country.ideology = fallback
				end
			end
			local gov = country.governmentForm and governmentTypes[country.governmentForm]
			if gov and gov.allowedIdeologies and country.ideology then
				local allowed = false
				for _, id in ipairs(gov.allowedIdeologies) do
					if id == country.ideology then allowed = true break end
				end
				if not allowed then
					local replacement = gov.allowedIdeologies[1]
					if replacement then
						table.insert(heals, string.format("Country '%s' ideology '%s' incompatible with government '%s' → '%s'", tag, str(country.ideology), str(country.governmentForm), str(replacement)))
						country.ideology = replacement
					end
				end
			end
			if country.economyPolicy and not economyPolicies[country.economyPolicy] then
				table.insert(heals, string.format("Country '%s' economyPolicy '%s' unknown → cleared", tag, str(country.economyPolicy)))
				country.economyPolicy = nil
			end
			if country.primaryCulture and not cultures[country.primaryCulture] then
				local fallback = fallbackCulture
				if fallback then
					table.insert(heals, string.format("Country '%s' primaryCulture '%s' unknown → '%s'", tag, str(country.primaryCulture), fallback))
					country.primaryCulture = fallback
				end
			end
			if country.stateReligion and not religions[country.stateReligion] then
				local fallback = fallbackReligion
				if fallback then
					table.insert(heals, string.format("Country '%s' stateReligion '%s' unknown → '%s'", tag, str(country.stateReligion), fallback))
					country.stateReligion = fallback
				end
			end
			if type(country.acceptedCultures) == "table" then
				local kept, dropped = {}, {}
				for _, cultureId in ipairs(country.acceptedCultures) do
					if cultures[cultureId] then
						table.insert(kept, cultureId)
					else
						table.insert(dropped, tostring(cultureId))
					end
				end
				if #dropped > 0 then
					table.insert(heals, string.format("Country '%s' acceptedCultures dropped invalid entries: %s", tag, table.concat(dropped, ", ")))
					country.acceptedCultures = kept
				end
			end

			local capId = country.capitalProvinceId
			local capProvince = capId and bundle.provinces and bundle.provinces[capId]
			if capProvince and capProvince.ownerTag ~= tag then
				table.insert(heals, string.format("Country '%s' capital %s ownership %s → %s", tag, tostring(capId), tostring(capProvince.ownerTag), tag))
				capProvince.ownerTag = tag
				capProvince.controllerTag = tag
				local hasCore = false
				for _, coreTag in ipairs(capProvince.cores or {}) do
					if coreTag == tag then hasCore = true; break end
				end
				if not hasCore then
					capProvince.cores = capProvince.cores or {}
					table.insert(capProvince.cores, tag)
				end
			elseif capId and not capProvince then
				local replacement
				for pid, prov in pairs(bundle.provinces or {}) do
					if type(prov) == "table" and prov.ownerTag == tag then
						replacement = pid
						break
					end
				end
				if replacement then
					table.insert(heals, string.format("Country '%s' capital %s missing → relocated to %s", tag, tostring(capId), tostring(replacement)))
					country.capitalProvinceId = replacement
				else
					table.insert(heals, string.format("Country '%s' has no provinces → dropped entirely", tag))
					bundle.countries[tag] = nil
				end
			end
		end
	end

	return heals
end

function DataLoader.validateBundle(bundle)
	local individualErrors = DataLoader.validateIndividual(bundle)
	local crossReport = DataLoader.validateCrossReferences(bundle)
	local errors = table.clone(individualErrors)
	for _, err in crossReport.errors do
		table.insert(errors, err)
	end
	return {
		ok = #errors == 0,
		errors = errors,
		warnings = crossReport.warnings,
	}
end

function DataLoader.auditUsage(bundle)
	local used = {
		cultures = {}, cultureGroups = {}, religions = {}, tradeGoods = {},
		terrains = {}, climates = {}, areas = {}, regions = {}, superRegions = {},
		ideologies = {}, manufactories = {}, economyPolicies = {}, governmentTypes = {},
		policies = {},
	}
	local function mark(set, value)
		if value ~= nil then
			set[value] = true
		end
	end

	for _, province in bundle.provinces do
		mark(used.cultures, province.culture)
		mark(used.religions, province.religion)
		mark(used.tradeGoods, province.tradeGood)
		mark(used.terrains, province.terrain)
		mark(used.climates, province.climate)
		mark(used.areas, province.areaId)
		mark(used.regions, province.regionId)
		mark(used.superRegions, province.superRegionId)
	end
	for _, country in bundle.countries do
		mark(used.cultures, country.primaryCulture)
		mark(used.religions, country.stateReligion)
		mark(used.ideologies, country.ideology)
		mark(used.governmentTypes, country.governmentForm)
		mark(used.economyPolicies, country.economyPolicy)
		if type(country.acceptedCultures) == "table" then
			for _, cultureId in country.acceptedCultures do
				mark(used.cultures, cultureId)
			end
		end
	end
	if bundle.manufactories then
		for _, manufactory in bundle.manufactories do
			mark(used.tradeGoods, manufactory.output)
			if type(manufactory.inputs) == "table" then
				for inputId in manufactory.inputs do
					mark(used.tradeGoods, inputId)
				end
			end
		end
	end
	for _, culture in bundle.cultures do
		mark(used.cultureGroups, culture.groupId)
	end
	for _, area in bundle.areas do
		mark(used.regions, area.regionId)
	end
	for _, region in bundle.regions do
		mark(used.superRegions, region.superRegionId)
	end

	local function gather(registry, usageSet)
		local unused = {}
		for id in registry do
			if not usageSet[id] then
				table.insert(unused, id)
			end
		end
		table.sort(unused)
		return unused
	end

	return {
		unusedCultureGroups = gather(bundle.cultureGroups, used.cultureGroups),
		unusedCultures = gather(bundle.cultures, used.cultures),
		unusedReligions = gather(bundle.religions, used.religions),
		unusedTradeGoods = gather(bundle.tradeGoods, used.tradeGoods),
		unusedTerrains = gather(bundle.terrains, used.terrains),
		unusedClimates = gather(bundle.climates, used.climates),
		unusedAreas = gather(bundle.areas, used.areas),
		unusedRegions = gather(bundle.regions, used.regions),
		unusedSuperRegions = gather(bundle.superRegions, used.superRegions),
		unusedIdeologies = gather(bundle.ideologies, used.ideologies),
		unusedManufactories = bundle.manufactories and gather(bundle.manufactories, {}) or {},
		unusedEconomyPolicies = bundle.economyPolicies and gather(bundle.economyPolicies, used.economyPolicies) or {},
	}
end

function DataLoader.countEntries(map)
	local count = 0
	for _ in map do
		count += 1
	end
	return count
end

function DataLoader.buildAreaIndex(provinces)
	local byArea, byRegion, bySuperRegion = {}, {}, {}
	for id, record in provinces do
		local bucket = byArea[record.areaId] or {}
		table.insert(bucket, id)
		byArea[record.areaId] = bucket

		bucket = byRegion[record.regionId] or {}
		table.insert(bucket, id)
		byRegion[record.regionId] = bucket

		bucket = bySuperRegion[record.superRegionId] or {}
		table.insert(bucket, id)
		bySuperRegion[record.superRegionId] = bucket
	end
	return { byArea = byArea, byRegion = byRegion, bySuperRegion = bySuperRegion }
end

function DataLoader.buildCountryOwnership(provinces)
	local byOwner = {}
	for id, record in provinces do
		local bucket = byOwner[record.ownerTag] or {}
		table.insert(bucket, id)
		byOwner[record.ownerTag] = bucket
	end
	return byOwner
end

return DataLoader
