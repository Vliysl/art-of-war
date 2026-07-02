-- BorderCoverSystem (Combat depth D): the "Cover Border vs Nation" order. A group with a
-- borderCoverTargetTag spreads its member armies to hold every province the owner controls that
-- borders the target nation, splitting armies to cover more tiles than it has and re-covering when a
-- tile is lost or a member dies. Defensive front-fill only (it garrisons the owner's OWN controlled
-- tiles, so pathing is always legal, at war or peace). Modeled on AutoCaptureSystem: decides moves,
-- delegates to MovementSystem, never resolves combat. Flag: EnableBorderCover.
local BorderCoverSystem = {}

local ctx

local function realTag(t)
	return t ~= nil and t ~= "" and t ~= "NONE" and t or nil
end

-- Provinces the owner controls that border the target nation (land only; sea nodes are negative
-- ids and never front tiles). Generalizes AISystem.collectBorders to a specific target.
local function coverProvincesFor(ownerTag, targetTag)
	local out = {}
	local registry = ctx.ProvinceRegistry
	local adj = ctx.AdjacencyGraph
	if not (registry and registry.byController and adj and adj.getNeighbors) then return out end
	for _, pid in ipairs(registry.byController(ownerTag)) do
		if type(pid) == "number" and pid > 0 then
			for _, n in ipairs(adj.getNeighbors(pid)) do
				if type(n) == "number" and n > 0 then
					local np = ctx.WorldState.getProvince(n)
					if np and np.controllerTag == targetTag then
						out[#out + 1] = pid
						break
					end
				end
			end
		end
	end
	return out
end

-- Half of an army's composition (for auto-split): take floor(count/2) of each unit type. splitArmy
-- refuses a split that would empty the source, so callers only split armies with >= 2 regiments.
local function halfComposition(army)
	local half = {}
	for unitId, count in pairs(army.composition or {}) do
		local n = math.floor((count or 0) / 2)
		if n > 0 then half[unitId] = n end
	end
	return half
end

local function coverGroup(group, now)
	local coverSet = coverProvincesFor(group.ownerTag, group.borderCoverTargetTag)
	local coverLookup = {}
	for _, pid in ipairs(coverSet) do coverLookup[pid] = true end

	-- Live, non-battling members. A member standing on / moving to a cover tile counts as covering it;
	-- an idle member off a cover tile is assignable.
	local covered = {}
	local idle = {}
	local biggest, biggestReg = nil, 0
	for _, armyId in ipairs(group.memberArmyIds) do
		local army = ctx.WorldState.getArmy(armyId)
		if army and not army.battleId then
			if army.movement then
				local dest = army.movement.toProvinceId
				if coverLookup[dest] then covered[dest] = true end
			else
				if coverLookup[army.provinceId] then
					covered[army.provinceId] = true
				else
					idle[#idle + 1] = armyId
				end
				local reg = ctx.ArmySystem.totalRegimentCount and ctx.ArmySystem.totalRegimentCount(army.composition) or 0
				if reg > biggestReg then biggest, biggestReg = armyId, reg end
			end
		end
	end

	local uncovered = {}
	for _, pid in ipairs(coverSet) do
		if not covered[pid] then uncovered[#uncovered + 1] = pid end
	end
	if #uncovered == 0 then return end

	local adj = ctx.AdjacencyGraph
	local idleSet = {}
	for _, id in ipairs(idle) do idleSet[id] = true end

	-- Assign the nearest idle member to each uncovered tile.
	for _, pid in ipairs(uncovered) do
		if next(idleSet) == nil then break end
		local best, bestDist = nil, math.huge
		for id in pairs(idleSet) do
			local a = ctx.WorldState.getArmy(id)
			local d = a and adj.distance and adj.distance(a.provinceId, pid) or math.huge
			if d < bestDist then best, bestDist = id, d end
		end
		if best then
			ctx.MovementSystem.beginMovePath(best, pid)
			idleSet[best] = nil
			covered[pid] = true
		end
	end

	-- Still short of tokens: split the biggest idle member (>= 2 regiments) to cover more tiles.
	local minReg = ctx.WorldConstants.BorderCoverMinRegiments or 1
	local maxSplits = ctx.WorldConstants.BorderCoverMaxSplitsPerRun or 4
	local splits = 0
	for _, pid in ipairs(uncovered) do
		if covered[pid] then continue end
		if splits >= maxSplits then break end
		if not biggest or biggestReg < math.max(2, minReg * 2) then break end
		local src = ctx.WorldState.getArmy(biggest)
		if not src or src.movement or src.battleId then break end
		local ok, newId = ctx.ArmySystem.splitArmy(biggest, halfComposition(src))
		if not ok or type(newId) ~= "string" then break end
		ctx.ArmyGroupSystem.addMember(group.id, newId)
		ctx.MovementSystem.beginMovePath(newId, pid)
		covered[pid] = true
		splits += 1
		-- Recompute the biggest remaining idle member for the next split.
		biggest, biggestReg = nil, 0
		for _, armyId in ipairs(group.memberArmyIds) do
			local a = ctx.WorldState.getArmy(armyId)
			if a and not a.movement and not a.battleId then
				local reg = ctx.ArmySystem.totalRegimentCount(a.composition) or 0
				if reg > biggestReg then biggest, biggestReg = armyId, reg end
			end
		end
	end
end

local function tick()
	if not (ctx.MovementSystem and ctx.MovementSystem.beginMovePath) then return end
	local now = ctx.TickScheduler.getSimTime()
	local cooldown = ctx.WorldConstants.BorderCoverCooldownSec or 6
	local groups = {}
	for _, group in ctx.WorldState.allArmyGroups() do
		if group.borderCoverTargetTag then groups[#groups + 1] = group end
	end
	for _, group in ipairs(groups) do
		if not group.borderCoverLastRunAt or (now - group.borderCoverLastRunAt) >= cooldown then
			coverGroup(group, now)
			local fresh = ctx.WorldState.getArmyGroup(group.id)
			if fresh then
				fresh.borderCoverLastRunAt = now
				ctx.WorldState.setArmyGroup(group.id, fresh)
			end
		end
	end
end

local function setBorderCover(groupId, targetTag)
	if not ctx.WorldConstants.EnableBorderCover then return false end
	local group = ctx.WorldState.getArmyGroup(groupId)
	if not group or not realTag(targetTag) then return false end
	group.borderCoverTargetTag = targetTag
	group.borderCoverLastRunAt = nil
	-- Mutually exclusive with per-army auto-capture: a holding army shouldn't also wander off.
	if ctx.AutoCaptureSystem and ctx.AutoCaptureSystem.setAutoCapture then
		for _, armyId in ipairs(group.memberArmyIds) do
			ctx.AutoCaptureSystem.setAutoCapture(armyId, false)
		end
	end
	ctx.WorldState.setArmyGroup(groupId, group)
	return true
end

local function clearBorderCover(groupId)
	local group = ctx.WorldState.getArmyGroup(groupId)
	if not group then return false end
	group.borderCoverTargetTag = nil
	group.borderCoverLastRunAt = nil
	ctx.WorldState.setArmyGroup(groupId, group)
	return true
end

-- A cover tile changed hands or a member died -> let the next tick recompute immediately.
local function nudgeRecompute()
	for gid, group in ctx.WorldState.allArmyGroups() do
		if group.borderCoverTargetTag and group.borderCoverLastRunAt then
			group.borderCoverLastRunAt = nil
			ctx.WorldState.setArmyGroup(gid, group)
		end
	end
end

function BorderCoverSystem.register(context)
	ctx = context
	local api = {
		setBorderCover = setBorderCover,
		clearBorderCover = clearBorderCover,
		coverProvincesFor = coverProvincesFor,
	}
	context.BorderCoverSystem = api
	for k, v in pairs(api) do BorderCoverSystem[k] = v end

	if not context.WorldConstants.EnableBorderCover then return end

	context.EventBus.subscribe(context.Channels.ProvinceOwnershipChanged, nudgeRecompute)
	context.EventBus.subscribe(context.Channels.ArmyDisbanded, nudgeRecompute)
	context.TickScheduler.register({
		id = "BorderCoverSystem",
		priority = 37,
		updateIntervalSeconds = context.WorldConstants.CombatTickInterval or 3,
		update = tick,
	})
end

return BorderCoverSystem
