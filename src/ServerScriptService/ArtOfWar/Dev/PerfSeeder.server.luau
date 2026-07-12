-- PerfSeeder: STUDIO-ONLY in-game performance harness for the 50-player perf work.
--
-- Why it exists: the Studio MCP's execute_luau runs in a SANDBOXED context with its own module-require
-- cache, so a require() there returns a fresh, EMPTY WorldState instead of the game's live singleton and
-- cannot drive the real systems. This Script runs in the GAME's own server context, so its requires resolve
-- to the LIVE singletons (populated WorldState, registered ArmySystem/DiplomacySystem) and it can actually
-- seed load. The MCP drives it through a RemoteFunction bridge (client InvokeServer).
--
-- Safety: hard-refuses outside Studio (never creates the bridge in a live server). Only mutates the
-- EPHEMERAL play-session WorldState -- no DataStore write; a fresh Play resets everything. No-op until
-- invoked. This is a dev tool; delete it (or gate behind a flag) once the perf pass is done.

local RunService = game:GetService("RunService")
if not RunService:IsStudio() then
	return
end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Stats = game:GetService("Stats")

local AoW = script.Parent.Parent -- Dev -> ArtOfWar
local WorldState = require(AoW.Framework.WorldState)
local TickScheduler = require(AoW.Framework.TickScheduler)
local ArmySystem = require(AoW.Systems.ArmySystem)
local DiplomacySystem = require(AoW.Systems.DiplomacySystem)

local SEED_UNIT = "irregular_infantry" -- default-unlocked levy; valid in Bundle.unitTypes
local SEED_REGIMENTS = 4

local function round(x)
	return math.floor(x * 100 + 0.5) / 100
end

local function pctl(sorted, p)
	if #sorted == 0 then
		return 0
	end
	local i = math.clamp(math.ceil(p / 100 * #sorted), 1, #sorted)
	return sorted[i]
end

-- Sample server frame time (Heartbeat delta) + engine stats over `dur` seconds. Runs in-context so it
-- reflects the real server frame; the plan's headline metric is server Heartbeat p99 < 16.7ms.
local function sample(dur)
	local s = {}
	local t0 = os.clock()
	while os.clock() - t0 < dur do
		s[#s + 1] = RunService.Heartbeat:Wait() * 1000
	end
	table.sort(s)
	local sum = 0
	for _, v in s do
		sum += v
	end
	local o = {
		frames = #s,
		avgMs = round(sum / math.max(1, #s)),
		p50Ms = round(pctl(s, 50)),
		p95Ms = round(pctl(s, 95)),
		p99Ms = round(pctl(s, 99)),
		maxMs = round(s[#s] or 0),
	}
	pcall(function()
		o.memMb = math.floor(Stats:GetTotalMemoryUsageMb() + 0.5)
	end)
	pcall(function()
		o.dataSendKbps = round(Stats.DataSendKbps)
	end)
	return o
end

local function worldStats()
	local nc, ncl, na, nw, naw = 0, 0, 0, 0, 0
	for _, c in WorldState.allCountries() do
		nc += 1
		if c.claimedBy ~= nil then
			ncl += 1
		end
	end
	for _ in WorldState.allArmies() do
		na += 1
	end
	for _, w in WorldState.allWars() do
		nw += 1
		if w.status == "active" then
			naw += 1
		end
	end
	return { countries = nc, claimed = ncl, armies = na, wars = nw, activeWars = naw }
end

-- owner tag -> list of province ids it both OWNS and CONTROLS (valid recruit/spawn sites).
local function ownedProvinces()
	local m = {}
	for id, p in WorldState.allProvinces() do
		local o = p.ownerTag
		if o and o ~= "" and o ~= "NONE" and p.controllerTag == o then
			local l = m[o]
			if not l then
				l = {}
				m[o] = l
			end
			l[#l + 1] = id
		end
	end
	return m
end

local function ownersList()
	local op = ownedProvinces()
	local owners = {}
	for o in op do
		owners[#owners + 1] = o
	end
	table.sort(owners)
	return owners, op
end

-- Create `per` armies each for up to `maxOwners` land-holding countries (via the real ArmySystem.createArmy,
-- which rolls officers/HQ and dirties them for replication -- true army-hot-path load).
local function seedArmies(per, maxOwners)
	local owners, op = ownersList()
	local created, used = 0, 0
	for _, o in owners do
		if used >= maxOwners then
			break
		end
		local provs = op[o]
		used += 1
		for i = 1, per do
			local pid = provs[((i - 1) % #provs) + 1]
			local ok = pcall(function()
				ArmySystem.createArmy(o, pid, { [SEED_UNIT] = SEED_REGIMENTS })
			end)
			if ok then
				created += 1
			end
		end
	end
	return { armiesCreated = created, ownersUsed = used, ownersAvailable = #owners }
end

-- Declare up to `count` wars between distinct land-holding countries (via the real DiplomacySystem.declareWar,
-- which builds proper war records, makes participants relevant, and fires WarDeclared -> AI + co-belligerents).
local function seedWars(count)
	local owners = ownersList()
	local made, errs = 0, {}
	local i = 1
	while made < count and i + 1 <= #owners do
		local a, b = owners[i], owners[i + 1]
		local ok, res, reason = pcall(DiplomacySystem.declareWar, a, b)
		if ok and res then
			made += 1
		else
			errs[#errs + 1] = ok and tostring(reason) or ("err:" .. tostring(res))
		end
		i += 2
	end
	return { warsMade = made, errs = errs }
end

-- Command dispatcher. Command string form "verb:arg1:arg2".
local function handle(cmd)
	local verb, a1, a2 = string.match(tostring(cmd), "^([^:]+):?([^:]*):?(.*)$")
	verb = verb or cmd
	if verb == "world" then
		return worldStats()
	elseif verb == "sample" then
		return sample(tonumber(a1) or 3)
	elseif verb == "seedArmies" then
		return seedArmies(tonumber(a1) or 5, tonumber(a2) or 50)
	elseif verb == "seedWars" then
		return seedWars(tonumber(a1) or 12)
	elseif verb == "setSpeed" then
		TickScheduler.setSpeed(tonumber(a1) or 16)
		return { speed = TickScheduler.getSpeed() }
	end
	return { error = "unknown command: " .. tostring(cmd) }
end

local bridge = Instance.new("RemoteFunction")
bridge.Name = "PerfBridge"
bridge.OnServerInvoke = function(_player, cmd)
	local ok, res = pcall(handle, cmd)
	if ok then
		return res
	end
	return { error = tostring(res) }
end
bridge.Parent = ReplicatedStorage

print("[PerfSeeder] ready (Studio dev harness) -- invoke ReplicatedStorage.PerfBridge:InvokeServer(cmd)")
