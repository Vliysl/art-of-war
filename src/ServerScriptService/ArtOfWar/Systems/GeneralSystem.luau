-- GeneralSystem (Combat depth C): a per-country roster of named generals, bought with political
-- power + gold, assigned to an army group. The general's LeaderTraits + skill boost every member
-- army in combat (folded in BattleManager) and it levels from the group's battles. The roster lives
-- on country.generalRoster (small, per-country, auto-replicates with the country record); the
-- assignment lives on the group (group.commanderId). Reuses LeaderSystem name/trait generation.
-- Flag: EnableGenerals.
local GeneralSystem = {}

local ctx

local function roster(country)
	country.generalRoster = country.generalRoster or {}
	return country.generalRoster
end

-- Roll a general via the shared LeaderSystem primitives, weighted toward military traits by using
-- the "chief_of_army" slot's preferred-trait pool.
local function rollGeneral(country)
	local ls = ctx.LeaderSystem
	if not (ls and ls.generateName and ls.buildTraitPool and ls.pickTrait and ls.allocId) then
		return nil
	end
	local minT = ctx.WorldConstants.LeaderTraitMinimum or 1
	local maxT = ctx.WorldConstants.LeaderTraitMaximum or 3
	local count = ls.rng and ls.rng:NextInteger(minT, maxT) or minT
	local pool, total = ls.buildTraitPool("chief_of_army")
	local traits, used = {}, {}
	for _ = 1, count do
		local id = ls.pickTrait(pool, total, used)
		if id then
			used[id] = true
			traits[#traits + 1] = id
		end
	end
	local first, last = ls.generateName(country)
	return {
		id = "gen_" .. ls.allocId(),
		firstName = first,
		lastName = last,
		title = "General",
		traits = traits,
		portraitId = ls.rng and ls.rng:NextInteger(1, ctx.WorldConstants.LeaderPortraitPoolSize or 1) or 1,
		hiredAt = ctx.TickScheduler.getSimTime(),
		experience = 0,
		level = 0,
		skill = 2,
		assignedGroupId = nil,
	}
end

local function buyGeneral(tag)
	if not ctx.WorldConstants.EnableGenerals then return false, "disabled" end
	local country = ctx.WorldState.getCountry(tag)
	if not country then return false, "unknown_country" end
	local goldCost = ctx.WorldConstants.GeneralBuyGoldCost or 150
	local ppCost = ctx.WorldConstants.GeneralBuyPpCost or 60
	-- Verify BOTH affordable before spending anything; PP is the atomic gate, then deduct gold.
	if (country.treasury or 0) < goldCost then return false, "insufficient_gold" end
	if not (ctx.PoliticalPower and ctx.PoliticalPower.spend and ctx.PoliticalPower.spend(tag, ppCost, "general_hire")) then
		return false, "insufficient_pp"
	end
	country = ctx.WorldState.getCountry(tag)
	country.treasury = (country.treasury or 0) - goldCost
	local general = rollGeneral(country)
	if not general then
		-- Refund PP if generation failed (LeaderSystem unavailable).
		country.treasury = (country.treasury or 0) + goldCost
		ctx.WorldState.setCountry(tag, country)
		if ctx.PoliticalPower.credit then ctx.PoliticalPower.credit(tag, ppCost, "general_hire_refund") end
		return false, "no_generator"
	end
	roster(country)[general.id] = general
	ctx.WorldState.setCountry(tag, country)
	ctx.EventBus.publish(ctx.Channels.GeneralHired, { tag = tag, generalId = general.id })
	return true, general.id
end

local function unassignGeneral(tag, groupId)
	local group = ctx.WorldState.getArmyGroup(groupId)
	if not group or group.ownerTag ~= tag then return false end
	local gid = group.commanderId
	if not gid then return true end
	group.commanderId = nil
	ctx.WorldState.setArmyGroup(groupId, group)
	local country = ctx.WorldState.getCountry(tag)
	if country and country.generalRoster and country.generalRoster[gid] then
		country.generalRoster[gid].assignedGroupId = nil
		ctx.WorldState.setCountry(tag, country)
	end
	ctx.EventBus.publish(ctx.Channels.GeneralUnassigned, { tag = tag, groupId = groupId, generalId = gid })
	return true
end

local function assignGeneral(tag, groupId, generalId)
	if not ctx.WorldConstants.EnableGenerals then return false, "disabled" end
	local group = ctx.WorldState.getArmyGroup(groupId)
	if not group or group.ownerTag ~= tag then return false, "no_group" end
	local country = ctx.WorldState.getCountry(tag)
	local general = country and country.generalRoster and country.generalRoster[generalId]
	if not general then return false, "no_general" end
	-- Free the general's previous group, and free this group's previous commander.
	if general.assignedGroupId and general.assignedGroupId ~= groupId then
		local prev = ctx.WorldState.getArmyGroup(general.assignedGroupId)
		if prev then prev.commanderId = nil; ctx.WorldState.setArmyGroup(prev.id, prev) end
	end
	if group.commanderId and group.commanderId ~= generalId and country.generalRoster[group.commanderId] then
		country.generalRoster[group.commanderId].assignedGroupId = nil
	end
	group.commanderId = generalId
	general.assignedGroupId = groupId
	ctx.WorldState.setArmyGroup(groupId, group)
	ctx.WorldState.setCountry(tag, country)
	ctx.EventBus.publish(ctx.Channels.GeneralAssigned, { tag = tag, groupId = groupId, generalId = generalId })
	return true
end

-- Resolve the general commanding this army (via its group), or nil. Read-only -- BattleManager
-- uses it for the per-formation combat multiplier.
local function getCommanderFor(army)
	if not ctx.WorldConstants.EnableGenerals then return nil end
	if not army or not army.groupId then return nil end
	local group = ctx.WorldState.getArmyGroup(army.groupId)
	if not group or not group.commanderId then return nil end
	local country = ctx.WorldState.getCountry(army.ownerTag)
	return country and country.generalRoster and country.generalRoster[group.commanderId] or nil
end

-- Award battle XP to the general commanding an army (BattleManager calls this, de-duped per
-- commander per round). Levels via the shared officer XP curve; leveling bumps skill.
local function awardGeneralXp(army, xp)
	if not ctx.WorldConstants.EnableGenerals or not army or not army.groupId then return end
	local group = ctx.WorldState.getArmyGroup(army.groupId)
	if not group or not group.commanderId then return end
	local country = ctx.WorldState.getCountry(army.ownerTag)
	local general = country and country.generalRoster and country.generalRoster[group.commanderId]
	if not general then return end
	local prevLevel = general.level or 0
	general.experience = (general.experience or 0) + xp
	local levelFor = ctx.Bundle and ctx.Bundle.officerTraits and ctx.Bundle.officerTraits.levelFor
	local newLevel = levelFor and levelFor(general.experience) or prevLevel
	if newLevel > prevLevel then
		general.level = newLevel
		general.skill = math.clamp(2 + newLevel, 0, 5)
		ctx.EventBus.publish(ctx.Channels.GeneralLeveled, {
			tag = army.ownerTag, generalId = general.id, level = newLevel,
		})
	end
	ctx.WorldState.setCountry(army.ownerTag, country)
end

function GeneralSystem.register(context)
	ctx = context
	local api = {
		buyGeneral = buyGeneral,
		assignGeneral = assignGeneral,
		unassignGeneral = unassignGeneral,
		getCommanderFor = getCommanderFor,
		awardGeneralXp = awardGeneralXp,
	}
	context.GeneralSystem = api
	for k, v in pairs(api) do GeneralSystem[k] = v end

	if not context.WorldConstants.EnableGenerals then return end

	-- A group losing its last army disbands (ArmyGroupSystem); free the general so it returns to
	-- the roster unassigned rather than pointing at a dead group.
	context.EventBus.subscribe(context.Channels.ArmyGroupDisbanded, function(payload)
		if not payload or not payload.commanderId or not payload.ownerTag then return end
		local country = context.WorldState.getCountry(payload.ownerTag)
		if country and country.generalRoster and country.generalRoster[payload.commanderId] then
			country.generalRoster[payload.commanderId].assignedGroupId = nil
			context.WorldState.setCountry(payload.ownerTag, country)
		end
	end)
end

return GeneralSystem
