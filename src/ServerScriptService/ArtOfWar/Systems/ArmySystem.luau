local ArmySystem = {}

local ctx
local nextArmySeq = 0
local armiesByOwner = {}
local armiesByProvince = {}
local officerRollCount = 0

local function generateArmyId(tag)
	nextArmySeq += 1
	return string.format("army_%s_%d", tag, nextArmySeq)
end

local function indexArmy(army)
	local ownerBucket = armiesByOwner[army.ownerTag] or {}
	ownerBucket[army.id] = true
	armiesByOwner[army.ownerTag] = ownerBucket

	local provinceBucket = armiesByProvince[army.provinceId] or {}
	provinceBucket[army.id] = true
	armiesByProvince[army.provinceId] = provinceBucket
end

local function deindexArmy(army)
	local ownerBucket = armiesByOwner[army.ownerTag]
	if ownerBucket then
		ownerBucket[army.id] = nil
		if next(ownerBucket) == nil then armiesByOwner[army.ownerTag] = nil end
	end
	local provinceBucket = armiesByProvince[army.provinceId]
	if provinceBucket then
		provinceBucket[army.id] = nil
		if next(provinceBucket) == nil then armiesByProvince[army.provinceId] = nil end
	end
end

local function compositionStrength(composition)
	if not composition then return 0 end
	local total = 0
	for _, count in composition do
		total += count
	end
	return total * (ctx.WorldConstants.ArmyRegimentStrength or 1000)
end

local function compositionSpeed(composition)
	if not composition then return 1 end
	local bundle = ctx.Bundle
	local units = bundle and bundle.unitTypes
	if not units then return 1 end
	local slowest = math.huge
	local hasAny = false
	for unitId, count in composition do
		if count > 0 then
			local unit = units[unitId]
			if unit and unit.speed then
				slowest = math.min(slowest, unit.speed)
				hasAny = true
			end
		end
	end
	return hasAny and slowest or 1
end

local function totalRegimentCount(composition)
	if not composition then return 0 end
	local total = 0
	for _, count in composition do total += count end
	return total
end

local function compositionOrganization(composition)
	if not composition then return ctx.WorldConstants.ArmyOrganizationMax or 10 end
	local bundle = ctx.Bundle
	local units = bundle and bundle.unitTypes
	local maxOrg = ctx.WorldConstants.ArmyOrganizationMax or 10
	if not units then return maxOrg end
	local weighted, total = 0, 0
	for unitId, count in composition do
		if count > 0 then
			local unit = units[unitId]
			local org = unit and unit.organization or maxOrg
			weighted += org * count
			total += count
		end
	end
	if total <= 0 then return maxOrg end
	return weighted / total
end

local function refreshBaseOrganization(army)
	if not army then return end
	local base = compositionOrganization(army.composition)
	army.baseOrganization = base
	if (army.organization or -1) < 0 or army.organization > base then
		army.organization = base
	end
end

local function entrenchmentMaxFor(tag)
	local base = ctx.WorldConstants.CombatEntrenchmentMax or 5
	if ctx.ModifierStack and ctx.ModifierStack.resolveAdditive then
		local extra = ctx.ModifierStack.resolveAdditive(tag, "army_entrenchment_max") or 0
		base += extra
	end
	return math.max(0, base)
end

local function setEntrenchment(armyId, value)
	local army = ctx.WorldState.getArmy(armyId)
	if not army then return end
	local cap = entrenchmentMaxFor(army.ownerTag)
	local newVal = math.clamp(value or 0, 0, cap)
	-- Change-guard: skip the write (and the resulting full-record replication) when the
	-- value is unchanged. Without this, EntrenchmentSystem re-dirties every idle army every
	-- tick forever -- even at the cap -- flooding StateReplicator with no-op deltas.
	if army.entrenchment == newVal then return end
	army.entrenchment = newVal
	ctx.WorldState.setArmy(armyId, army)
end

local function getState(armyId)
	local army = ctx.WorldState.getArmy(armyId)
	if not army then return nil end
	if army.state then return army.state end
	if army.battleId then
		local b = ctx.WorldState.getBattle(army.battleId)
		if b then
			if b.attackerArmyIds then
				for _, id in b.attackerArmyIds do
					if id == army.id then return "attacking" end
				end
			end
			if b.defenderArmyIds then
				for _, id in b.defenderArmyIds do
					if id == army.id then return "defending" end
				end
			end
		end
	end
	if army.retreating then return "retreating" end
	if army.movement then return "moving" end
	return "idle"
end

local function setState(armyId, state)
	local army = ctx.WorldState.getArmy(armyId)
	if not army then return end
	if army.state == state then return end
	local previous = army.state
	army.state = state
	ctx.WorldState.setArmy(armyId, army)
	ctx.EventBus.publish(ctx.Channels.ArmyStateChanged, {
		armyId = armyId,
		tag = army.ownerTag,
		previous = previous,
		state = state,
	})
end

local function setOriginProvinceId(armyId, provinceId)
	local army = ctx.WorldState.getArmy(armyId)
	if not army then return end
	army.originProvinceId = provinceId
	ctx.WorldState.setArmy(armyId, army)
end

local function rollOfficer(country, domain)
	local bundle = ctx.Bundle
	if not bundle then return nil end
	local namesMod = bundle.officerNames
	local traitsMod = bundle.officerTraits
	if not namesMod or not traitsMod then return nil end
	local culture = country and country.primaryCulture or nil
	local name = namesMod.roll and namesMod.roll(culture)
	if not name then return nil end
	local pool = traitsMod.byDomain and traitsMod.byDomain(domain or "ground") or {}
	local traits = {}
	if #pool > 0 then
		officerRollCount += 1
		local rng = Random.new((ctx.WorldConstants.OfficerRngSeed or 13337) + officerRollCount)
		local count = rng:NextInteger(1, math.min(2, #pool))
		local picked = {}
		for _ = 1, count do
			local attempts = 0
			repeat
				local pick = pool[rng:NextInteger(1, #pool)]
				if pick and not picked[pick.id] then
					picked[pick.id] = true
					table.insert(traits, pick.id)
					break
				end
				attempts += 1
			until attempts >= 6
		end
	end
	return {
		name = name,
		culture = culture or "generic",
		traits = traits,
		assignedAt = ctx.TickScheduler.getSimTime(),
		experience = 0,
		level = 0,
		skillAttack = 2,
		skillDefense = 2,
		skillManeuver = 2,
	}
end

-- HQ/Formations (spec 6.5 military model, Phase 4): one HQ per country per domain,
-- sited at the capital. New formations auto-assign to it (army.hqId). Multi-HQ-per-region
-- and the military-menu UI belong to the broader overhaul (deferred); this is the cohesive
-- data layer + auto-assign the combat model expects.
local function ensureHQ(tag, domain)
	domain = domain or "ground"
	local country = ctx.WorldState.getCountry(tag)
	if not country then return nil end
	country.headquarters = country.headquarters or {}
	local hq = country.headquarters[domain]
	if not hq then
		hq = {
			id = string.format("hq_%s_%s", tag, domain),
			tag = tag,
			domain = domain,
			provinceId = country.capitalProvinceId,
			name = string.format("%s %s Command", tag, domain == "naval" and "Naval" or "Army"),
			createdAt = (ctx.TickScheduler and ctx.TickScheduler.getSimTime and ctx.TickScheduler.getSimTime()) or 0,
		}
		country.headquarters[domain] = hq
		ctx.WorldState.setCountry(tag, country)
	end
	return hq.id
end

local function createArmy(tag, provinceId, composition, opts)
	if not tag or not provinceId then return nil end
	local country = ctx.WorldState.getCountry(tag)
	if not country then return nil end
	local id = generateArmyId(tag)
	local domain = (opts and opts.domain) or "ground"
	local record = {
		id = id,
		ownerTag = tag,
		provinceId = provinceId,
		composition = composition and table.clone(composition) or {},
		morale = ctx.WorldConstants.ArmyMoraleMax or 100,
		createdAt = ctx.TickScheduler.getSimTime(),
		entrenchment = 0,
		entrenchmentMax = entrenchmentMaxFor(tag),  -- replicated so the ArmyPanel bar shows the real cap
		state = "idle",
		originProvinceId = provinceId,
		domain = domain,
		officer = rollOfficer(country, domain),
		hqId = ensureHQ(tag, domain),
	}
	refreshBaseOrganization(record)
	ctx.WorldState.setArmy(id, record)
	indexArmy(record)
	ctx.EventBus.publish(ctx.Channels.ArmyCreated, {
		armyId = id, tag = tag, provinceId = provinceId, domain = domain,
	})
	return record
end

local function destroyArmy(armyId, reason)
	local army = ctx.WorldState.getArmy(armyId)
	if not army then return false end
	deindexArmy(army)
	ctx.WorldState.setArmy(armyId, nil)
	ctx.EventBus.publish(ctx.Channels.ArmyDisbanded, {
		armyId = armyId, tag = army.ownerTag, provinceId = army.provinceId,
		reason = reason or "destroyed",
	})
	return true
end

local function relocateArmy(armyId, newProvinceId)
	local army = ctx.WorldState.getArmy(armyId)
	if not army then return false end
	if army.provinceId == newProvinceId then return true end
	deindexArmy(army)
	army.provinceId = newProvinceId
	indexArmy(army)
	ctx.WorldState.setArmy(armyId, army)
	return true
end

local function addRegiments(armyId, unitTypeId, count)
	local army = ctx.WorldState.getArmy(armyId)
	if not army then return false end
	army.composition = army.composition or {}
	army.composition[unitTypeId] = (army.composition[unitTypeId] or 0) + count
	refreshBaseOrganization(army)
	ctx.WorldState.setArmy(armyId, army)
	return true
end

local function removeRegiments(armyId, unitTypeId, count)
	local army = ctx.WorldState.getArmy(armyId)
	if not army or not army.composition then return false end
	local current = army.composition[unitTypeId] or 0
	local removed = math.min(current, count)
	local remaining = current - removed
	if remaining > 0 then
		army.composition[unitTypeId] = remaining
	else
		army.composition[unitTypeId] = nil
	end
	refreshBaseOrganization(army)
	ctx.WorldState.setArmy(armyId, army)
	return removed
end

-- Defensive: never auto-destroy armies that hit zero strength here.
-- BattleManager.endBattle decides retreat-or-destroy at the right moment.
local function applyCasualties(armyId, ratio)
	local army = ctx.WorldState.getArmy(armyId)
	if not army or not army.composition then return false end
	ratio = math.clamp(ratio, 0, 1)
	local totalRegiments = 0
	for _, count in army.composition do totalRegiments += count end
	if totalRegiments <= 0 then return 0 end
	local pending = (army.casualtyDebt or 0) + totalRegiments * ratio
	local toRemove = math.floor(pending)
	army.casualtyDebt = pending - toRemove
	if toRemove <= 0 then
		ctx.WorldState.setArmy(armyId, army)
		return 0
	end
	local total = 0
	while toRemove > 0 do
		local biggestId, biggestCount = nil, 0
		for unitId, count in army.composition do
			if count > biggestCount then biggestId, biggestCount = unitId, count end
		end
		if not biggestId then break end
		local take = math.min(toRemove, biggestCount)
		local remaining = biggestCount - take
		if remaining > 0 then
			army.composition[biggestId] = remaining
		else
			army.composition[biggestId] = nil
		end
		total += take
		toRemove -= take
	end
	refreshBaseOrganization(army)
	ctx.WorldState.setArmy(armyId, army)
	return total
end

local function armiesInProvince(provinceId)
	local bucket = armiesByProvince[provinceId]
	if not bucket then return {} end
	local list = {}
	for armyId in bucket do
		local army = ctx.WorldState.getArmy(armyId)
		if army then table.insert(list, army) end
	end
	return list
end

local function armiesOfOwner(tag)
	local bucket = armiesByOwner[tag]
	if not bucket then return {} end
	local list = {}
	for armyId in bucket do
		local army = ctx.WorldState.getArmy(armyId)
		if army then table.insert(list, army) end
	end
	return list
end

local function findFriendlyArmyAt(tag, provinceId)
	local bucket = armiesByProvince[provinceId]
	if not bucket then return nil end
	for armyId in bucket do
		local army = ctx.WorldState.getArmy(armyId)
		if army and army.ownerTag == tag and not army.movement and not army.battleId then
			return army
		end
	end
	return nil
end

local function findEnemyArmyAt(tag, provinceId)
	local bucket = armiesByProvince[provinceId]
	if not bucket then return nil end
	for armyId in bucket do
		local army = ctx.WorldState.getArmy(armyId)
		if army and army.ownerTag ~= tag then
			return army
		end
	end
	return nil
end

-- Post-battle morale modifier (spec G.1.7): victor +bonus / loser -penalty for N months.
-- Stored as army.battleMoraleMod = { pct, expireMonthIndex }; expiry tracked by in-game month.
local function activeMoralePct(army)
	local mod = army and army.battleMoraleMod
	if type(mod) ~= "table" then return 0 end
	local getDate = ctx.TickScheduler and ctx.TickScheduler.getGameDate
	if getDate then
		local gd = getDate()
		if gd and mod.expireMonthIndex then
			local cur = gd.year * 12 + (gd.month - 1)
			if cur >= mod.expireMonthIndex then return 0 end
		end
	end
	return mod.pct or 0
end

local function effectiveMoraleMax(army)
	local base = ctx.WorldConstants.ArmyMoraleMax or 100
	return base * (1 + activeMoralePct(army))
end

local function adjustMorale(armyId, delta)
	local army = ctx.WorldState.getArmy(armyId)
	if not army then return end
	local mMin = ctx.WorldConstants.ArmyMoraleMin or 0
	local mMax = effectiveMoraleMax(army)
	army.morale = math.clamp((army.morale or mMax) + delta, mMin, mMax)
	ctx.WorldState.setArmy(armyId, army)
end

local function adjustOrganization(armyId, delta)
	local army = ctx.WorldState.getArmy(armyId)
	if not army then return end
	local oMin = ctx.WorldConstants.ArmyOrganizationMin or 0
	local base = army.baseOrganization or compositionOrganization(army.composition)
	army.baseOrganization = base
	army.organization = math.clamp((army.organization or base) + delta, oMin, base)
	ctx.WorldState.setArmy(armyId, army)
end

-- Merge `otherIds` armies INTO `primaryId` (a single existing army).
-- All armies must share the same ownerTag and provinceId, must not be in battle or in motion.
-- Composition is summed; morale is weighted-averaged by regiment count; organization takes the
-- minimum across the merged set; baseOrganization is recomputed.
-- Returns true on success; false, reason on failure.
local function mergeArmies(primaryId, otherIds)
	local primary = ctx.WorldState.getArmy(primaryId)
	if not primary then return false, "unknown_primary" end
	if primary.battleId then return false, "in_battle" end
	if primary.movement then return false, "in_motion" end

	local provinceId = primary.provinceId
	local ownerTag = primary.ownerTag

	local valid = {}
	for _, id in ipairs(otherIds or {}) do
		if id ~= primaryId then
			local other = ctx.WorldState.getArmy(id)
			if other then
				if other.ownerTag ~= ownerTag then return false, "ownership_mismatch" end
				if other.provinceId ~= provinceId then return false, "province_mismatch" end
				if other.battleId then return false, "other_in_battle" end
				if other.movement then return false, "other_in_motion" end
				table.insert(valid, other)
			end
		end
	end
	if #valid == 0 then return false, "no_valid_others" end

	primary.composition = primary.composition or {}
	local totalRegiments = totalRegimentCount(primary.composition)
	local moraleMax = ctx.WorldConstants.ArmyMoraleMax or 100
	local moraleSum = (primary.morale or moraleMax) * totalRegiments
	local minOrg = primary.organization or (primary.baseOrganization or 0)

	for _, other in ipairs(valid) do
		local weight = totalRegimentCount(other.composition or {})
		moraleSum = moraleSum + (other.morale or moraleMax) * weight
		totalRegiments = totalRegiments + weight
		for unitTypeId, count in pairs(other.composition or {}) do
			primary.composition[unitTypeId] = (primary.composition[unitTypeId] or 0) + count
		end
		local oOrg = other.organization or other.baseOrganization or 0
		if oOrg < minOrg then minOrg = oOrg end
	end

	if totalRegiments > 0 then
		primary.morale = moraleSum / totalRegiments
	end
	refreshBaseOrganization(primary)
	primary.organization = math.min(minOrg, primary.baseOrganization or minOrg)
	ctx.WorldState.setArmy(primaryId, primary)

	for _, other in ipairs(valid) do
		destroyArmy(other.id, "merged")
	end

	ctx.EventBus.publish(ctx.Channels.ArmyStateChanged, {
		armyId = primaryId,
		tag = ownerTag,
		state = primary.state or "idle",
		merged = true,
	})

	return true
end

-- Split: detach a sub-composition into a NEW army at the same province (inverse of
-- mergeArmies). The new army inherits the source's morale; its organization is
-- inherited too but capped at its own baseOrganization (which its composition sets),
-- because organization may never exceed baseOrganization -- exactly how mergeArmies
-- treats org. The source keeps the remainder. Invariants mirror merge: source not in
-- battle/motion, each requested count <= available, and the source keeps >=1 regiment.
-- Returns true, newArmyId on success; false, reason on failure.
local function splitArmy(sourceId, splitComposition)
	local source = ctx.WorldState.getArmy(sourceId)
	if not source then return false, "unknown_army" end
	if source.battleId then return false, "in_battle" end
	if source.movement then return false, "in_motion" end
	if type(splitComposition) ~= "table" then return false, "bad_composition" end
	source.composition = source.composition or {}

	-- Validate + clamp the requested split against what the source actually has.
	local take = {}
	local takeTotal = 0
	for unitTypeId, count in pairs(splitComposition) do
		if type(unitTypeId) == "string" and type(count) == "number" then
			local avail = source.composition[unitTypeId] or 0
			local n = math.min(math.floor(count), avail)
			if n > 0 then
				take[unitTypeId] = n
				takeTotal += n
			end
		end
	end
	if takeTotal <= 0 then return false, "empty_split" end
	if takeTotal >= totalRegimentCount(source.composition) then return false, "would_empty_source" end

	-- New detached army at the same province: inherit morale; inherit org but clamp to
	-- the new army's own baseOrganization (org <= baseOrg invariant).
	local newArmy = createArmy(source.ownerTag, source.provinceId, take, { domain = source.domain })
	if not newArmy then return false, "create_failed" end
	newArmy.morale = source.morale or newArmy.morale
	newArmy.organization = math.min(source.organization or newArmy.organization or 0, newArmy.baseOrganization or newArmy.organization or 0)
	ctx.WorldState.setArmy(newArmy.id, newArmy)

	-- Subtract the detached regiments from the source.
	for unitTypeId, n in pairs(take) do
		local remaining = (source.composition[unitTypeId] or 0) - n
		if remaining > 0 then
			source.composition[unitTypeId] = remaining
		else
			source.composition[unitTypeId] = nil
		end
	end
	refreshBaseOrganization(source)
	source.organization = math.min(source.organization or source.baseOrganization or 0, source.baseOrganization or 0)
	ctx.WorldState.setArmy(sourceId, source)

	ctx.EventBus.publish(ctx.Channels.ArmyStateChanged, {
		armyId = sourceId, tag = source.ownerTag, state = source.state or "idle", split = true,
	})
	return true, newArmy.id
end

local function reassignOfficer(armyId, traitIds)
	local army = ctx.WorldState.getArmy(armyId)
	if not army then return false, "no_army" end
	local bundle = ctx.Bundle
	local traitsMod = bundle and bundle.officerTraits
	if not traitsMod then return false, "no_trait_data" end
	local domain = army.domain or (army.officer and army.officer.domain) or "ground"
	local pool = traitsMod.byDomain and traitsMod.byDomain(domain) or {}
	local valid = {}
	for _, def in ipairs(pool) do
		if def and def.id then valid[def.id] = true end
	end
	if type(traitIds) ~= "table" then return false, "invalid_traits" end
	local maxTraits = traitsMod.MAX_TRAITS or 5
	local cleaned = {}
	local seen = {}
	for _, tid in ipairs(traitIds) do
		if type(tid) == "string" and valid[tid] and not seen[tid] then
			seen[tid] = true
			table.insert(cleaned, tid)
			if #cleaned >= maxTraits then break end
		end
	end
	if #cleaned == 0 then return false, "no_valid_traits" end
	if type(army.officer) ~= "table" then
		local ownerCountry = ctx.WorldState.getCountry(army.ownerTag)
		local officerCulture = (ownerCountry and ownerCountry.primaryCulture) or "generic"
		army.officer = {
			name = (bundle.officerNames and bundle.officerNames.roll
				and bundle.officerNames.roll(officerCulture)) or "Officer",
			culture = officerCulture,
			traits = cleaned,
			assignedAt = ctx.TickScheduler.getSimTime(),
			experience = 0,
			level = 0,
		}
	else
		army.officer.traits = cleaned
		army.officer.assignedAt = ctx.TickScheduler.getSimTime()
	end
	ctx.WorldState.setArmy(armyId, army)
	if ctx.Channels and ctx.Channels.ArmyOfficerLeveled then
		ctx.EventBus.publish(ctx.Channels.ArmyOfficerLeveled, {
			armyId = armyId,
			tag = army.ownerTag,
			level = army.officer.level or 0,
			newTraitId = nil,
			officerName = army.officer.name,
			reassigned = true,
		})
	end
	return true
end

local function regenTick()
	local moraleRegen = ctx.WorldConstants.ArmyMoraleRegenPerTick or 3
	local orgRegen = ctx.WorldConstants.ArmyOrganizationRegenPerTick or 0.5
	local mMin = ctx.WorldConstants.ArmyMoraleMin or 0
	local oMin = ctx.WorldConstants.ArmyOrganizationMin or 0
	local orgMaxDefault = ctx.WorldConstants.ArmyOrganizationMax or 10
	-- Single read-modify-write per army, change-guarded. Previously this called
	-- adjustMorale + adjustOrganization, each re-fetching the army and issuing its own
	-- setArmy (up to 3 dirties + 2 redundant getArmy per regenerating army). Now the army
	-- in hand is mutated directly and written once, only when something actually changed.
	for armyId, army in ctx.WorldState.allArmies() do
		if not army.battleId then
			local changed = false

			if army.battleMoraleMod and activeMoralePct(army) == 0 then
				army.battleMoraleMod = nil
				changed = true
			end

			local moraleMax = effectiveMoraleMax(army)
			local curMorale = army.morale or moraleMax
			if curMorale < moraleMax then
				local nv = math.clamp(curMorale + moraleRegen, mMin, moraleMax)
				if nv ~= army.morale then army.morale = nv; changed = true end
			end

			local base = army.baseOrganization or compositionOrganization(army.composition) or orgMaxDefault
			army.baseOrganization = base
			local curOrg = army.organization or base
			if curOrg < base then
				local nv = math.clamp(curOrg + orgRegen, oMin, base)
				if nv ~= army.organization then army.organization = nv; changed = true end
			end

			if changed then ctx.WorldState.setArmy(armyId, army) end
		end
	end
end

function ArmySystem.register(context)
	ctx = context
	local api = {
		createArmy = createArmy,
		destroyArmy = destroyArmy,
		relocateArmy = relocateArmy,
		addRegiments = addRegiments,
		removeRegiments = removeRegiments,
		applyCasualties = applyCasualties,
		armiesInProvince = armiesInProvince,
		armiesOfOwner = armiesOfOwner,
		findFriendlyArmyAt = findFriendlyArmyAt,
		findEnemyArmyAt = findEnemyArmyAt,
		adjustMorale = adjustMorale,
		adjustOrganization = adjustOrganization,
		compositionStrength = compositionStrength,
		compositionSpeed = compositionSpeed,
		compositionOrganization = compositionOrganization,
		totalRegimentCount = totalRegimentCount,
		setEntrenchment = setEntrenchment,
		getState = getState,
		setState = setState,
		setOriginProvinceId = setOriginProvinceId,
		mergeArmies = mergeArmies,
		splitArmy = splitArmy,
		reassignOfficer = reassignOfficer,
		regenTick = regenTick,
		effectiveMoraleMax = effectiveMoraleMax,
		activeMoralePct = activeMoralePct,
	}
	context.ArmySystem = api
	for k, v in pairs(api) do ArmySystem[k] = v end

	context.TickScheduler.register({
		id = "ArmyRegen",
		priority = 37,
		updateIntervalSeconds = context.WorldConstants.CombatTickInterval or 3,
		update = regenTick,
	})
end

return ArmySystem
