local ArmySystem = {}

local ctx
local nextArmySeq = 0
local armiesByOwner = {}
local armiesByProvince = {}
local officerRollCount = 0

-- perf: membership indices so hot per-tick systems iterate the sparse subset they care about
-- instead of scanning allArmies() every tick. movingArmies = armies with a pending .movement;
-- idleArmies = armies in state "idle" with no movement/retreat. Design rule: these may OVER-include
-- (a stale member is harmless -- consumers re-apply their own filters) but must never UNDER-include,
-- so we refresh on every relevant mutation/event and self-heal on a low-priority backstop tick.
local movingArmies = {}
local idleArmies = {}

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
	-- perf: drop from the membership indices too (army record is going away)
	movingArmies[army.id] = nil
	idleArmies[army.id] = nil
end

-- perf: re-derive an army's membership in movingArmies/idleArmies from its CURRENT record.
-- Resolving via getArmy keeps the indices honest no matter which mutation path ran. If the
-- record is gone, clear both. Over-inclusion is acceptable; under-inclusion is not, so this
-- is called from every create/relocate/setState path AND from the relevant event channels.
local function refreshArmyMembership(armyId)
	if not armyId then return end
	local army = ctx.WorldState.getArmy(armyId)
	if not army then
		movingArmies[armyId] = nil
		idleArmies[armyId] = nil
		return
	end
	movingArmies[armyId] = (army.movement ~= nil) or nil
	idleArmies[armyId] = (army.state == "idle" and not army.movement and not army.retreating) or nil
end

-- perf: self-healing backstop -- rebuild both indices from scratch by scanning allArmies().
-- Registered on a low-priority ~15s scheduler entry so any missed-event staleness is bounded.
local function rebuildMembership()
	table.clear(movingArmies)
	table.clear(idleArmies)
	for armyId, army in ctx.WorldState.allArmies() do
		if army.movement ~= nil then movingArmies[armyId] = true end
		if army.state == "idle" and not army.movement and not army.retreating then
			idleArmies[armyId] = true
		end
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
	refreshArmyMembership(armyId) -- perf: keep idle/moving indices current on every state change
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
		-- High-water mark per unit type that manpower-fed reinforcement rebuilds toward after battle
		-- losses. Grown by addRegiments/recruit, lowered by intentional removal, untouched by casualties.
		reinforceTarget = composition and table.clone(composition) or {},
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
	refreshArmyMembership(id) -- perf: a newly created army starts "idle" -> joins idleArmies
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
	-- Growing the army (recruitment) raises its reinforce target; reinforcement itself never routes
	-- through here, so this only ever ratchets up.
	army.reinforceTarget = army.reinforceTarget or {}
	army.reinforceTarget[unitTypeId] = math.max(army.reinforceTarget[unitTypeId] or 0, army.composition[unitTypeId])
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
	-- Intentional removal (disband/withdraw) lowers the reinforce target so it isn't refilled later.
	if army.reinforceTarget then
		army.reinforceTarget[unitTypeId] = (remaining > 0)
				and math.min(army.reinforceTarget[unitTypeId] or 0, remaining)
			or nil
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
	primary.reinforceTarget = primary.reinforceTarget or table.clone(primary.composition)
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
		-- Carry the merged army's reinforce target into the primary (so the combined army rebuilds to
		-- the combined size). Fall back to its composition for armies created before this field existed.
		for unitTypeId, count in pairs(other.reinforceTarget or other.composition or {}) do
			primary.reinforceTarget[unitTypeId] = (primary.reinforceTarget[unitTypeId] or 0) + count
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
	-- The detached regiments take their reinforce target with them (createArmy seeded the new army's
	-- target = take), so subtract them from the source -- it shouldn't refill regiments it gave away.
	if source.reinforceTarget then
		for unitTypeId, n in pairs(take) do
			local rt = (source.reinforceTarget[unitTypeId] or 0) - n
			source.reinforceTarget[unitTypeId] = (rt > 0) and rt or nil
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
	local reinforcePerTick = ctx.WorldConstants.ReinforceRegimentsPerTick or 0.5
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

			-- Manpower-fed reinforcement: a settled army (not moving/retreating; battle already excluded
			-- above) standing in a province it controls rebuilds battle losses toward its reinforceTarget,
			-- paying the owner's manpower per restored regiment. The fractional progress accumulator is an
			-- internal field (mutated in place, no replication); we only setArmy when composition changes.
			if not army.movement and not army.retreating and army.reinforceEnabled ~= false then
				army.composition = army.composition or {}
				if not army.reinforceTarget then
					army.reinforceTarget = table.clone(army.composition) -- lazy-init for pre-existing armies
				end
				local deficit = 0
				for u, target in pairs(army.reinforceTarget) do
					local d = target - (army.composition[u] or 0)
					if d > 0 then deficit += d end
				end
				local owner = army.ownerTag
				local prov = (deficit > 0 and owner) and ctx.WorldState.getProvince(army.provinceId) or nil
				if prov and prov.controllerTag == owner then
					army.reinforceProgress = (army.reinforceProgress or 0) + reinforcePerTick
					local budget = math.min(math.floor(army.reinforceProgress), deficit)
					if budget > 0 then
						local country = ctx.WorldState.getCountry(owner)
						local units = ctx.Bundle and ctx.Bundle.unitTypes
						if country and units then
							local restored = 0
							while restored < budget do
								local bestU, bestD = nil, 0
								for u, target in pairs(army.reinforceTarget) do
									local d = target - (army.composition[u] or 0)
									if d > bestD then bestU, bestD = u, d end
								end
								if not bestU then break end
								local cost = (units[bestU] and units[bestU].recruitManpower) or 0
								if cost > 0 and (country.manpower or 0) < cost then break end
								army.composition[bestU] = (army.composition[bestU] or 0) + 1
								country.manpower = (country.manpower or 0) - cost
								restored += 1
							end
							if restored > 0 then
								army.reinforceProgress -= restored
								refreshBaseOrganization(army)
								ctx.WorldState.setCountry(owner, country)
								changed = true
							end
						end
					end
				elseif army.reinforceProgress then
					army.reinforceProgress = nil -- in-memory reset (no deficit / not supplied); no replication
				end
			end

			if changed then ctx.WorldState.setArmy(armyId, army) end
		end
	end
end

-- perf: shared iterator factory for the membership accessors. Snapshots the member ids first
-- (so consumers may mutate during iteration), then resolves each id to its LIVE record via
-- getArmy, skipping ids whose record has vanished. Yields (armyId, armyRecord).
local function membershipIterator(set)
	local ids = {}
	for armyId in set do
		ids[#ids + 1] = armyId
	end
	local i = 0
	return function()
		while true do
			i += 1
			local armyId = ids[i]
			if armyId == nil then return nil end
			local army = ctx.WorldState.getArmy(armyId)
			if army then return armyId, army end
		end
	end
end

-- perf: consumers iterate `for armyId, army in ArmySystem.movingArmies() do ... end`.
local function movingArmiesIter()
	return membershipIterator(movingArmies)
end

local function idleArmiesIter()
	return membershipIterator(idleArmies)
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
		-- perf: membership accessors -- each returns an iterator yielding (armyId, armyRecord)
		movingArmies = movingArmiesIter,
		idleArmies = idleArmiesIter,
	}
	context.ArmySystem = api
	for k, v in pairs(api) do ArmySystem[k] = v end

	context.TickScheduler.register({
		id = "ArmyRegen",
		priority = 37,
		updateIntervalSeconds = context.WorldConstants.CombatTickInterval or 3,
		update = regenTick,
	})

	-- perf: maintain movingArmies/idleArmies off the existing mutation event channels. createArmy
	-- and setState already refresh inline (above); these cover the paths that mutate army.movement /
	-- army.retreating / army.battleId directly (MovementSystem, BattleManager). Battle channels carry
	-- ARRAYS of ids (attackerArmyIds/defenderArmyIds), not a single armyId -- refresh each. No new
	-- channels are added and the Channels/EventBus modules are untouched.
	local Channels = context.Channels
	local function refreshFromPayload(payload)
		if payload and payload.armyId then refreshArmyMembership(payload.armyId) end
	end
	context.EventBus.subscribe(Channels.ArmyCreated, refreshFromPayload)        -- payload.armyId
	context.EventBus.subscribe(Channels.ArmyMoveStarted, refreshFromPayload)    -- payload.armyId
	context.EventBus.subscribe(Channels.ArmyMoveCompleted, refreshFromPayload)  -- payload.armyId
	context.EventBus.subscribe(Channels.ArmyMoveCancelled, refreshFromPayload)  -- payload.armyId
	context.EventBus.subscribe(Channels.ArmyStateChanged, refreshFromPayload)   -- payload.armyId
	context.EventBus.subscribe(Channels.ArmyDisbanded, function(payload)
		-- payload.armyId; record is already gone -> refresh clears both sets
		if payload and payload.armyId then refreshArmyMembership(payload.armyId) end
	end)
	local function refreshArmyIdList(list)
		if type(list) ~= "table" then return end
		for _, armyId in ipairs(list) do
			refreshArmyMembership(armyId)
		end
	end
	local function refreshBattlePayload(payload)
		-- BattleStarted/BattleResolved carry attackerArmyIds + defenderArmyIds (arrays), no scalar armyId
		if not payload then return end
		refreshArmyIdList(payload.attackerArmyIds)
		refreshArmyIdList(payload.defenderArmyIds)
	end
	context.EventBus.subscribe(Channels.BattleStarted, refreshBattlePayload)
	context.EventBus.subscribe(Channels.BattleResolved, refreshBattlePayload)

	-- perf: self-healing backstop -- rebuild both indices from a full scan every ~15s so any
	-- missed-event staleness is bounded. Low priority (runs after the systems that consume them).
	context.TickScheduler.register({
		id = "ArmyMembershipRebuild",
		priority = 200,
		updateIntervalSeconds = 15,
		update = rebuildMembership,
	})
end

return ArmySystem
