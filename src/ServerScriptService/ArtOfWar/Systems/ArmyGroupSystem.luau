-- ArmyGroupSystem (Combat depth B): persistent, named army groups. A group is a first-class
-- replicated record (armyGroups collection) that survives deselection; each member army carries a
-- groupId back-ref. Groups are the unit a general is assigned to (C) and the target of the border-
-- cover order (D). Membership self-heals against army death/merge/annex via ArmyDisbanded, and a
-- low-priority backstop tick rebuilds the index. Flag: EnableArmyGroups (off => api exposed but no
-- groups are ever created, since the remotes early-return).
local ArmyGroupSystem = {}

local ctx
local nextGroupSeq = 0
local groupsByOwner = {}   -- tag -> { [groupId] = true }
local groupOfArmy = {}     -- armyId -> groupId (server index; army.groupId is the replicated truth)

local MAX_MEMBERS = 50

local function generateGroupId(tag)
	nextGroupSeq += 1
	return string.format("grp_%s_%d", tostring(tag), nextGroupSeq)
end

local function indexGroup(record)
	local bucket = groupsByOwner[record.ownerTag] or {}
	bucket[record.id] = true
	groupsByOwner[record.ownerTag] = bucket
	for _, armyId in ipairs(record.memberArmyIds) do
		groupOfArmy[armyId] = record.id
	end
end

local function setArmyGroupId(armyId, groupId)
	local army = ctx.WorldState.getArmy(armyId)
	if army and army.groupId ~= groupId then
		army.groupId = groupId
		ctx.WorldState.setArmy(armyId, army)
	end
end

local function groupOf(armyId)
	local gid = groupOfArmy[armyId]
	return gid and ctx.WorldState.getArmyGroup(gid) or nil
end

local function groupsOfOwner(tag)
	local out = {}
	local bucket = groupsByOwner[tag]
	if not bucket then return out end
	for gid in pairs(bucket) do
		local g = ctx.WorldState.getArmyGroup(gid)
		if g then out[#out + 1] = g end
	end
	return out
end

-- Forward declaration: removeMember and disbandGroup are mutually recursive (removing the last
-- member disbands the group).
local disbandGroup

local function removeMember(groupId, armyId)
	local record = ctx.WorldState.getArmyGroup(groupId)
	if not record then return false end
	local found = false
	for i = #record.memberArmyIds, 1, -1 do
		if record.memberArmyIds[i] == armyId then
			table.remove(record.memberArmyIds, i)
			found = true
		end
	end
	if not found then return false end
	if groupOfArmy[armyId] == groupId then groupOfArmy[armyId] = nil end
	setArmyGroupId(armyId, nil)
	if #record.memberArmyIds == 0 then
		disbandGroup(groupId, "empty")
	else
		ctx.WorldState.setArmyGroup(groupId, record)
		ctx.EventBus.publish(ctx.Channels.ArmyGroupChanged, { groupId = groupId, ownerTag = record.ownerTag })
	end
	return true
end

function disbandGroup(groupId, reason)
	local record = ctx.WorldState.getArmyGroup(groupId)
	if not record then return false end
	for _, armyId in ipairs(record.memberArmyIds) do
		if groupOfArmy[armyId] == groupId then groupOfArmy[armyId] = nil end
		setArmyGroupId(armyId, nil)
	end
	local bucket = groupsByOwner[record.ownerTag]
	if bucket then
		bucket[groupId] = nil
		if next(bucket) == nil then groupsByOwner[record.ownerTag] = nil end
	end
	ctx.WorldState.setArmyGroup(groupId, nil)
	ctx.EventBus.publish(ctx.Channels.ArmyGroupDisbanded, {
		groupId = groupId, ownerTag = record.ownerTag, commanderId = record.commanderId, reason = reason,
	})
	return true
end

local function addMember(groupId, armyId)
	local record = ctx.WorldState.getArmyGroup(groupId)
	if not record then return false end
	if #record.memberArmyIds >= MAX_MEMBERS then return false end
	local army = ctx.WorldState.getArmy(armyId)
	if not army or army.ownerTag ~= record.ownerTag then return false end
	-- One group per army: pull it out of any prior group first.
	local prior = groupOfArmy[armyId]
	if prior and prior ~= groupId then removeMember(prior, armyId) end
	if groupOfArmy[armyId] == groupId then return true end
	table.insert(record.memberArmyIds, armyId)
	groupOfArmy[armyId] = groupId
	setArmyGroupId(armyId, groupId)
	ctx.WorldState.setArmyGroup(groupId, record)
	ctx.EventBus.publish(ctx.Channels.ArmyGroupChanged, { groupId = groupId, ownerTag = record.ownerTag })
	return true
end

local function createGroup(tag, name, armyIds)
	if not ctx.WorldConstants.EnableArmyGroups then return nil end
	if type(tag) ~= "string" or type(armyIds) ~= "table" then return nil end
	local members = {}
	local seen = {}
	for _, armyId in ipairs(armyIds) do
		if type(armyId) == "string" and not seen[armyId] and #members < MAX_MEMBERS then
			local army = ctx.WorldState.getArmy(armyId)
			if army and army.ownerTag == tag then
				seen[armyId] = true
				members[#members + 1] = armyId
			end
		end
	end
	if #members == 0 then return nil end
	-- Pull each member out of any prior group before enrolling it here.
	for _, armyId in ipairs(members) do
		local prior = groupOfArmy[armyId]
		if prior then removeMember(prior, armyId) end
	end
	local id = generateGroupId(tag)
	local cleanName = (type(name) == "string" and name ~= "") and string.sub(name, 1, 64) or "Army Group"
	local record = {
		id = id,
		ownerTag = tag,
		name = cleanName,
		memberArmyIds = members,
		commanderId = nil,
		borderCoverTargetTag = nil,
		borderCoverLastRunAt = nil,
		createdAt = ctx.TickScheduler.getSimTime(),
	}
	indexGroup(record)
	for _, armyId in ipairs(members) do
		setArmyGroupId(armyId, id)
	end
	ctx.WorldState.setArmyGroup(id, record)
	ctx.EventBus.publish(ctx.Channels.ArmyGroupFormed, { groupId = id, ownerTag = tag })
	return id
end

local function renameGroup(groupId, name)
	local record = ctx.WorldState.getArmyGroup(groupId)
	if not record then return false end
	record.name = (type(name) == "string" and name ~= "") and string.sub(name, 1, 64) or record.name
	ctx.WorldState.setArmyGroup(groupId, record)
	ctx.EventBus.publish(ctx.Channels.ArmyGroupChanged, { groupId = groupId, ownerTag = record.ownerTag })
	return true
end

-- Army left the world (death / merge / annex). Scrub it from its group; empty groups disband.
local function onArmyDisbanded(payload)
	local armyId = payload and payload.armyId
	if not armyId then return end
	local gid = groupOfArmy[armyId]
	if gid then removeMember(gid, armyId) end
end

-- Backstop: rebuild the index from the replicated groups + prune members whose army is gone.
local function rebuildIndex()
	table.clear(groupsByOwner)
	table.clear(groupOfArmy)
	for gid, record in ctx.WorldState.allArmyGroups() do
		local kept = {}
		for _, armyId in ipairs(record.memberArmyIds) do
			if ctx.WorldState.getArmy(armyId) then
				kept[#kept + 1] = armyId
				groupOfArmy[armyId] = gid
			end
		end
		if #kept == 0 then
			ctx.WorldState.setArmyGroup(gid, nil)
		else
			if #kept ~= #record.memberArmyIds then
				record.memberArmyIds = kept
				ctx.WorldState.setArmyGroup(gid, record)
			end
			local bucket = groupsByOwner[record.ownerTag] or {}
			bucket[gid] = true
			groupsByOwner[record.ownerTag] = bucket
		end
	end
end

function ArmyGroupSystem.register(context)
	ctx = context
	local api = {
		createGroup = createGroup,
		renameGroup = renameGroup,
		disbandGroup = disbandGroup,
		addMember = addMember,
		removeMember = removeMember,
		groupOf = groupOf,
		groupsOfOwner = groupsOfOwner,
	}
	context.ArmyGroupSystem = api
	for k, v in pairs(api) do ArmyGroupSystem[k] = v end

	if not context.WorldConstants.EnableArmyGroups then return end

	context.EventBus.subscribe(context.Channels.ArmyDisbanded, onArmyDisbanded)
	context.TickScheduler.register({
		id = "ArmyGroupRebuild",
		priority = 200,
		updateIntervalSeconds = 15,
		update = rebuildIndex,
	})
end

return ArmyGroupSystem
