-- AutoCaptureSystem: opt-in "continuous frontline push" for a single army. When army.autoCapture
-- is set, an idle army automatically marches to and besieges the nearest capturable province
-- (unowned, or controlled by an enemy it is at war with), repeating after each capture until no
-- capturable province is reachable. Movement + combat + siege are delegated to the existing
-- MovementSystem / CombatSystem.onArmyArrival / SiegeSystem pipeline, so this only decides the
-- NEXT target; it never resolves combat itself.
--
-- The flag lives on the army record (replicated), so the ArmyPanel toggle reflects live state.
local AutoCaptureSystem = {}

local ctx

local function isUnowned(tag)
	return tag == nil or tag == "" or tag == "NONE"
end

-- A province is capturable by `owner` if someone else controls it AND it is either unclaimed or
-- held by a country `owner` is at war with.
local function canCapture(owner, prov)
	if not prov then return false end
	local c = prov.controllerTag
	if c == owner then return false end
	if isUnowned(c) then return true end
	local dipl = ctx.DiplomacySystem
	return (dipl and dipl.areAtWar and dipl.areAtWar(owner, c)) == true
end

-- A province is movement-traversable for `owner` (mirrors MovementSystem.provinceTraversable):
-- own, unowned, or an at-war enemy's. We only expand BFS through these so the target we pick is
-- actually reachable by beginMovePath.
local function traversable(owner, prov)
	if not prov then return false end
	local c = prov.controllerTag
	if c == owner or isUnowned(c) then return true end
	local dipl = ctx.DiplomacySystem
	return (dipl and dipl.areAtWar and dipl.areAtWar(owner, c)) == true
end

-- Nearest capturable province reachable through traversable tiles, BFS from fromId. Returns the
-- first capturable province encountered (so the closest one), or nil if none reachable.
local function nearestCapturable(owner, fromId)
	local adj = ctx.AdjacencyGraph
	if not adj or not adj.getNeighbors then return nil end
	local visited = { [fromId] = true }
	local frontier = { fromId }
	while #frontier > 0 do
		local nextFrontier = {}
		for _, cur in ipairs(frontier) do
			for _, n in ipairs(adj.getNeighbors(cur)) do
				if not visited[n] then
					visited[n] = true
					local p = ctx.WorldState.getProvince(n)
					if canCapture(owner, p) then
						return n
					end
					if traversable(owner, p) then
						table.insert(nextFrontier, n)
					end
				end
			end
		end
		frontier = nextFrontier
	end
	return nil
end

local function setAutoCapture(armyId, enabled)
	local army = ctx.WorldState.getArmy(armyId)
	if not army then return false end
	-- Store nil rather than false so a disabled flag doesn't replicate noise.
	army.autoCapture = enabled and true or nil
	ctx.WorldState.setArmy(armyId, army)
	return true
end

local function tick()
	if not (ctx.MovementSystem and ctx.MovementSystem.beginMovePath) then return end
	for armyId, army in ctx.WorldState.allArmies() do
		if army.autoCapture and not army.movement and not army.battleId then
			local owner = army.ownerTag
			local here = ctx.WorldState.getProvince(army.provinceId)
			-- Already standing on a tile we are taking? Let SiegeSystem finish the siege in place.
			if not (here and canCapture(owner, here)) then
				local target = nearestCapturable(owner, army.provinceId)
				if target then
					ctx.MovementSystem.beginMovePath(armyId, target)
				end
			end
		end
	end
end

function AutoCaptureSystem.register(context)
	ctx = context
	local api = { setAutoCapture = setAutoCapture }
	context.AutoCaptureSystem = api
	for k, v in pairs(api) do AutoCaptureSystem[k] = v end

	context.TickScheduler.register({
		id = "AutoCaptureSystem",
		priority = 37, -- between CombatSystem (36) and SiegeSystem (38)
		updateIntervalSeconds = context.WorldConstants.CombatTickInterval or 3,
		update = tick,
	})
end

return AutoCaptureSystem
