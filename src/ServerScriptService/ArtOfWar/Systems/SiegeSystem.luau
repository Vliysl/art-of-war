-- SiegeSystem (Phase 5): real sieges extracted from CombatSystem.tickOccupations.
-- Siege progress = SiegeBaseSpeed * armySizeFactor * (1 - fortDefenseMod) toward
-- OccupationProgressRequired; forts slow sieges AND bleed besiegers (attrition);
-- relief (besieger leaves/destroyed/contested) resets progress; completion flips
-- province.controllerTag and publishes ProvinceOccupied (DiplomacySystem scores it).
local SiegeSystem = {}

local ctx

local function isUnowned(tag)
	return tag == nil or tag == "" or tag == "NONE"
end

local function fortTierFor(prov)
	return prov and (prov.effectiveFortTier or prov.fortTier or 0) or 0
end

local activeSieges = {}
local sweptStaleOccupations = false

local function tickSiege()
	local C = ctx.WorldConstants
	-- Instant capture replaces siege progress wholesale (CombatSystem.captureIfUndefended).
	-- Keep the system registered so flipping the flag off restores sieges; on the first gated
	-- tick, clear any lingering occupation records so stale capture rings can't replicate.
	if C.EnableInstantCapture then
		if not sweptStaleOccupations then
			sweptStaleOccupations = true
			for pid, prov in ctx.WorldState.allProvinces() do
				if prov.occupation then
					prov.occupation = nil
					ctx.WorldState.setProvince(pid, prov)
				end
			end
			table.clear(activeSieges)
		end
		return
	end
	sweptStaleOccupations = false
	-- Provinces with an active battle (one pass) so the per-army siege check below is O(1) instead of
	-- O(battles) per army -- the old getBattleAt-per-army call made this O(armies x battles).
	local battleProvince = {}
	for _, b in ctx.WorldState.allBattles() do
		if b.provinceId then battleProvince[b.provinceId] = true end
	end
	-- Resolve a single uncontested besieger per province.
	local occupierOf, contested, besiegers = {}, {}, {}
	for _, army in ctx.WorldState.allArmies() do
		local pid = army.provinceId
		local prov = pid and ctx.WorldState.getProvince(pid)
		if prov and army.ownerTag and prov.controllerTag ~= army.ownerTag
			and not army.battleId and not battleProvince[pid] then
			local controller = prov.controllerTag
			local mayOccupy = isUnowned(controller)
			if not mayOccupy and ctx.DiplomacySystem and ctx.DiplomacySystem.areAtWar then
				mayOccupy = ctx.DiplomacySystem.areAtWar(army.ownerTag, controller)
			end
			if mayOccupy and not contested[pid] then
				if occupierOf[pid] == nil then
					occupierOf[pid] = army.ownerTag
					besiegers[pid] = { army.id }
				elseif occupierOf[pid] ~= army.ownerTag then
					occupierOf[pid] = nil
					contested[pid] = true
					besiegers[pid] = nil
				else
					table.insert(besiegers[pid], army.id)
				end
			end
		end
	end

	local required = C.OccupationProgressRequired or 12
	for pid, tag in pairs(occupierOf) do
		local prov = ctx.WorldState.getProvince(pid)
		if prov then
			local fortTier = fortTierFor(prov)
			local fortMod = math.min(C.SiegeFortMaxReduction or 0.85, fortTier * (C.FortSiegeDefensePerTier or 0.15))

			local regiments = 0
			for _, aid in ipairs(besiegers[pid] or {}) do
				local a = ctx.WorldState.getArmy(aid)
				if a and ctx.ArmySystem and ctx.ArmySystem.totalRegimentCount then
					regiments += ctx.ArmySystem.totalRegimentCount(a.composition)
				end
			end
			local sizeFactor = math.clamp(regiments / (C.SiegeArmySizeRef or 8),
				C.SiegeMinSizeFactor or 0.5, C.SiegeMaxSizeFactor or 1.5)

			local speed = (C.SiegeBaseSpeed or 1) * sizeFactor * (1 - fortMod)
			if ctx.ModifierStack and ctx.ModifierStack.resolveAdditive then
				speed += (ctx.ModifierStack.resolveAdditive(tag, "army_occupation_speed") or 0)
			end
			speed = math.max(0, speed)

			local occ = prov.occupation
			if not occ or occ.byTag ~= tag then occ = { byTag = tag, progress = 0 } end
			occ.progress += speed
			-- Replicate the completion threshold so the client can show progress/required as a
			-- world-space capture bar without knowing WorldConstants.OccupationProgressRequired.
			occ.required = required

			-- Besieger attrition: forts bleed the besieging army each round.
			local attr = (C.SiegeAttritionPerRound or 0.01) + fortTier * (C.SiegeAttritionFortScale or 0.004)
			if attr > 0 and ctx.ArmySystem and ctx.ArmySystem.applyCasualties then
				for _, aid in ipairs(besiegers[pid] or {}) do
					ctx.ArmySystem.applyCasualties(aid, attr)
				end
			end

			if occ.progress >= required then
				local oldController = prov.controllerTag
				prov.controllerTag = tag
				prov.occupation = nil
				activeSieges[pid] = nil
				ctx.WorldState.setProvince(pid, prov)
				ctx.EventBus.publish(ctx.Channels.ProvinceOccupied, {
					provinceId = pid,
					newController = tag,
					oldController = oldController,
					ownerTag = prov.ownerTag,
				})
			else
				prov.occupation = occ
				activeSieges[pid] = true
				ctx.WorldState.setProvince(pid, prov)
				if ctx.Channels.SiegeProgressed then
					ctx.EventBus.publish(ctx.Channels.SiegeProgressed, {
						provinceId = pid,
						byTag = tag,
						progress = occ.progress,
						required = required,
					})
				end
			end
		end
	end

	-- Relief / abandonment: occupier no longer present -> reset siege progress.
	for pid in pairs(activeSieges) do
		if not occupierOf[pid] then
			local prov = ctx.WorldState.getProvince(pid)
			if prov and prov.occupation then
				prov.occupation = nil
				ctx.WorldState.setProvince(pid, prov)
				if ctx.Channels.SiegeProgressed then
					ctx.EventBus.publish(ctx.Channels.SiegeProgressed, {
						provinceId = pid,
						progress = 0,
						required = required,
					})
				end
			end
			activeSieges[pid] = nil
		end
	end
end

function SiegeSystem.register(context)
	ctx = context
	local api = { tickSiege = tickSiege }
	context.SiegeSystem = api
	for k, v in pairs(api) do SiegeSystem[k] = v end

	context.TickScheduler.register({
		id = "SiegeSystem",
		priority = 38,
		updateIntervalSeconds = context.WorldConstants.CombatTickInterval or 3,
		update = tickSiege,
	})
end

return SiegeSystem
