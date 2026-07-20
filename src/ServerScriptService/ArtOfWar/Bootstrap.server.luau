local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")

pcall(function()
	StarterPlayer.EnableMouseLockOption = false
end)

local ArtOfWarServer = script.Parent
local Framework = ArtOfWarServer:WaitForChild("Framework")
local Systems = ArtOfWarServer:WaitForChild("Systems")

local WorldConstants = require(ReplicatedStorage.ArtOfWar.Shared.WorldConstants)
-- Server-only WorldConstants (AI decision thresholds, political/law/combat tuning,
-- OfficerRngSeed) live in a ServerScriptService module so they never replicate to clients.
-- Merge them into the shared table here -- before any Framework/System require reads them --
-- by mutating the require-cached instance, so ctx.WorldConstants and every later require see
-- the full set at runtime.
for key, value in require(ArtOfWarServer.WorldConstantsServer) do
	WorldConstants[key] = value
end
local Channels = require(ArtOfWarServer.Events.Channels)

local EventBus = require(Framework.EventBus)
local TickScheduler = require(Framework.TickScheduler)
local WorldState = require(Framework.WorldState)
local DataLoader = require(Framework.DataLoader)
local UIBridge = require(Framework.UIBridge)
local InputValidator = require(Framework.InputValidator)
local ModifierStack = require(Framework.ModifierStack)
local EditorAdmins = require(ServerStorage:WaitForChild("Dev"):WaitForChild("EditorAdmins"))

UIBridge.init()

UIBridge.registerCommand("ready", function(player)
	EventBus.publish(Channels.PlayerReady, { userId = player.UserId, name = player.Name })
end)

local context = {
	EventBus = EventBus,
	TickScheduler = TickScheduler,
	WorldState = WorldState,
	DataLoader = DataLoader,
	UIBridge = UIBridge,
	InputValidator = InputValidator,
	Channels = Channels,
	WorldConstants = WorldConstants,
}

-- Give WorldState the event framework so its ownership chokepoint (setProvinceOwnership) can publish
-- the canonical ProvinceOwnershipChanged / ProvinceOccupied events.
WorldState.bindEvents(EventBus, Channels)

ModifierStack.register(context)

local bundle = DataLoader.loadBundle()
context.Bundle = bundle

-- File-authoritative boot (UseBakedWorldData): when the world came from the ServerData/World
-- baked modules, every DataStore-overlay touchpoint below is skipped — there is no overlay to
-- persist ghost-heals into, migrate, or retry after throttling. healBundle (below) still runs
-- and re-derives the same fixes in-memory on every boot, so nothing needs persisting.
local bakedMode = false
do
	-- FindFirstChild (not WaitForChild): in a Studio session that predates the module a wait
	-- would hang the boot; a nil just means "not baked" and the DataStore path proceeds.
	local okBaked, BakedWorld = pcall(require, Framework:FindFirstChild("BakedWorld"))
	bakedMode = (okBaked and BakedWorld and BakedWorld.wasApplied()) == true
end

local heals = DataLoader.healBundle(bundle)
if #heals > 0 then
	warn(string.format("[ArtOfWar] auto-healed %d bundle issue(s) before validation:", #heals))
	for i, msg in ipairs(heals) do
		if i <= 30 then
			warn("  · " .. msg)
		end
	end
	if #heals > 30 then
		warn(string.format("  · …and %d more", #heals - 30))
	end
end

if not bakedMode then
	local overlayMod = ServerStorage:FindFirstChild("Services")
	overlayMod = overlayMod and overlayMod:FindFirstChild("DataOverlay")
	if overlayMod then
		local ok, overlay = pcall(require, overlayMod)
		if ok and overlay and overlay.snapshot and overlay.setProvince then
			local snapOk, snap = pcall(overlay.snapshot)
			local overlayProvinces = (snapOk and snap and snap.provinces) or {}
			local countries = bundle.countries or {}
			local function tagIsGhost(tag)
				if tag == nil or tag == "" or tag == "NONE" then
					return false
				end
				return countries[tag] == nil
			end
			local function coresDiverged(overlayCores, healedCores)
				if type(overlayCores) ~= "table" then
					return false
				end
				local healedSet = {}
				if type(healedCores) == "table" then
					for _, t in ipairs(healedCores) do
						healedSet[t] = true
					end
				end
				for _, t in ipairs(overlayCores) do
					if not healedSet[t] then
						return true
					end
				end
				return false
			end
			local persisted, samples = 0, {}
			for pid, prov in pairs(bundle.provinces or {}) do
				if type(prov) == "table" then
					local overlayRec = overlayProvinces[pid] or overlayProvinces[tostring(pid)]
					if type(overlayRec) == "table" then
						local oGhost = tagIsGhost(overlayRec.ownerTag)
						local cGhost = tagIsGhost(overlayRec.controllerTag)
						local staleCores = coresDiverged(overlayRec.cores, prov.cores)
						if oGhost or cGhost or staleCores then
							local patched = table.clone(overlayRec)
							patched.ownerTag = prov.ownerTag or "NONE"
							patched.controllerTag = prov.controllerTag or patched.ownerTag
							if staleCores then
								local cleaned = {}
								if type(prov.cores) == "table" then
									for _, t in ipairs(prov.cores) do
										table.insert(cleaned, t)
									end
								end
								patched.cores = cleaned
							end
							overlay.setProvince(pid, patched)
							persisted = persisted + 1
							if #samples < 5 then
								local note = string.format(
									"pid=%s owner %s→%s ctrl %s→%s",
									tostring(pid),
									tostring(overlayRec.ownerTag),
									tostring(patched.ownerTag),
									tostring(overlayRec.controllerTag),
									tostring(patched.controllerTag)
								)
								if staleCores then
									note = note
										.. string.format(
											" cores %d→%d",
											type(overlayRec.cores) == "table" and #overlayRec.cores or 0,
											#patched.cores
										)
								end
								table.insert(samples, note)
							end
						end
					end
				end
			end
			if persisted > 0 then
				print(string.format("[ArtOfWar] persisting %d ghost heal(s) to DataOverlay", persisted))
				for _, s in ipairs(samples) do
					print("  · " .. s)
				end
				if overlay.flush then
					local flushOk, flushResult = pcall(overlay.flush)
					if not flushOk then
						warn(
							string.format("[ArtOfWar] overlay flush after ghost-heal failed: %s", tostring(flushResult))
						)
					elseif type(flushResult) == "table" and (flushResult.failures or 0) > 0 then
						warn(string.format("[ArtOfWar] ghost-heal flush reported %d failure(s)", flushResult.failures))
					end
				end
			end
		end
	end
end

local validateOk, report = pcall(DataLoader.validateBundle, bundle)
if not validateOk then
	warn("[ArtOfWar] validateBundle errored, continuing: " .. tostring(report))
	report = { ok = true, errors = {}, warnings = {} }
end
if not report.ok then
	warn(
		string.format(
			"[ArtOfWar] bundle validation surfaced %d non-fatal error(s); boot continues so the map and physics still load:",
			#report.errors
		)
	)
	for _, err in report.errors do
		warn("  · " .. err)
	end
end
for _, note in report.warnings do
	warn("[ArtOfWar] data warning: " .. note)
end

local registryOrder = { "ProvinceRegistry", "CountryRegistry" }
local loadedSystems = {}

for _, name in registryOrder do
	local moduleScript = Systems:FindFirstChild(name)
	if moduleScript then
		local ok, system = pcall(require, moduleScript)
		if not ok then
			error(string.format("[ArtOfWar] failed to require '%s': %s", name, tostring(system)))
		end
		if type(system) == "table" and type(system.register) == "function" then
			system.register(context)
			loadedSystems[name] = system
		end
	end
end

if loadedSystems.ProvinceRegistry and type(loadedSystems.ProvinceRegistry.hydrate) == "function" then
	loadedSystems.ProvinceRegistry.hydrate(bundle.provinces)
end
if loadedSystems.CountryRegistry and type(loadedSystems.CountryRegistry.hydrate) == "function" then
	loadedSystems.CountryRegistry.hydrate(bundle.countries)
end

for _, child in Systems:GetChildren() do
	if child:IsA("ModuleScript") and not loadedSystems[child.Name] then
		local ok, system = pcall(require, child)
		if not ok then
			warn(string.format("[Bootstrap] failed to require system '%s': %s", child.Name, tostring(system)))
		elseif type(system) == "table" and type(system.register) == "function" then
			local success, err = pcall(system.register, context)
			if not success then
				warn(string.format("[Bootstrap] system '%s' register errored: %s", child.Name, tostring(err)))
			else
				loadedSystems[child.Name] = system
			end
		end
	end
end

if loadedSystems.ProvinceStamper and type(loadedSystems.ProvinceStamper.stamp) == "function" then
	local ok, stamped = pcall(loadedSystems.ProvinceStamper.stamp)
	if ok then
		print(string.format("[ArtOfWar] stamped %d provinces onto map parts", stamped or 0))
	else
		warn("[ArtOfWar] ProvinceStamper.stamp errored: " .. tostring(stamped))
	end
end

-- Reconcile owned-but-unregistered land tiles into real provinces before the adjacency graph is
-- built, so painted territory that was never promoted to a seed still becomes a movement/economy/
-- building-eligible province this session. Runs after stamping (owner attributes are settled) and
-- before AdjacencyGraph.build (which then enrols the freshly stamped province_id parts and, in baked
-- mode, geometry-links any registered province the baked adjacency table does not cover).
if context.ProvinceReconciler and type(context.ProvinceReconciler.reconcile) == "function" then
	local reconcileOk, reconcileReport = pcall(context.ProvinceReconciler.reconcile)
	if reconcileOk and type(reconcileReport) == "table" then
		if reconcileReport.found > 0 or reconcileReport.registered > 0 then
			print(
				string.format(
					"[ArtOfWar] province reconciler: %d owned-but-unregistered tile(s) found, %d registered (%d unlinkable, %d already mapped, %d ghost owner)",
					reconcileReport.found,
					reconcileReport.registered,
					reconcileReport.unlinkable,
					reconcileReport.alreadyMapped,
					reconcileReport.ghostOwner
				)
			)
		end
	elseif not reconcileOk then
		warn("[ArtOfWar] ProvinceReconciler.reconcile errored: " .. tostring(reconcileReport))
	end
end

if not bakedMode then
	local overlayModule = ServerStorage:FindFirstChild("Services")
	overlayModule = overlayModule and overlayModule:FindFirstChild("DataOverlay")
	if overlayModule then
		local ok, overlay = pcall(require, overlayModule)
		if ok and overlay then
			if overlay.onMigrated then
				overlay.onMigrated(function()
					local stamper = context.ProvinceStamper
					if stamper then
						if stamper.refreshEU4Mappings then
							pcall(stamper.refreshEU4Mappings)
						end
						if stamper.stamp then
							pcall(stamper.stamp)
						elseif stamper.applyTileOwnership then
							pcall(stamper.applyTileOwnership)
						end
					end
					if context.StateReplicator and context.StateReplicator.broadcast then
						pcall(context.StateReplicator.broadcast)
					end
				end)
			end
			if overlay.autoMigrate then
				overlay.autoMigrate()
			end
		end
	end
end

task.spawn(function()
	if bakedMode then
		return -- baked boot: file loads can't throttle, so there are no late reads to recover
	end
	local overlayMod = ServerStorage:FindFirstChild("Services")
	overlayMod = overlayMod and overlayMod:FindFirstChild("DataOverlay")
	local ov = overlayMod and select(2, pcall(require, overlayMod))
	for _ = 1, 10 do
		task.wait(6)
		local stamper = loadedSystems.ProvinceStamper
		if not stamper or type(stamper.refreshEU4Mappings) ~= "function" then
			break
		end
		if type(ov) == "table" and type(ov.retryNow) == "function" then
			pcall(ov.retryNow)
		end

		-- Re-hydrate late-arriving province RECORDS into WorldState. If KIND_PROVINCES throttled at
		-- boot, those records never entered the registry — refreshEU4Mappings + stamp alone would
		-- leave getProvince(id) nil (stamp finds no record, so the province stays invisible to
		-- movement/economy/buildings). Enrol any overlay province not yet in WorldState via the
		-- incremental registry path (guarded by getProvince==nil so we never double-index).
		local hydratedLate = 0
		local registry = context.ProvinceRegistry
		if
			type(ov) == "table"
			and type(ov.snapshot) == "function"
			and registry
			and type(registry.registerProvince) == "function"
		then
			local okSnap, snap = pcall(ov.snapshot, false)
			if okSnap and type(snap) == "table" and type(snap.provinces) == "table" then
				for id, rec in pairs(snap.provinces) do
					local nid = tonumber(id) or id
					if type(rec) == "table" and context.WorldState.getProvince(nid) == nil then
						if registry.registerProvince(nid, rec) then
							hydratedLate += 1
						end
					end
				end
			end
		end

		local recovered = 0
		pcall(function()
			recovered = stamper.refreshEU4Mappings() or 0
		end)
		if recovered > 0 or hydratedLate > 0 then
			-- Keep healing across the whole window: mappings/records can trickle in over several
			-- throttled reads. Delta-stamp (only parts not yet stamped) rather than re-stamping all
			-- ~2,800 provinces on every retry.
			if type(stamper.stampMissing) == "function" then
				pcall(stamper.stampMissing)
			elseif type(stamper.stamp) == "function" then
				pcall(stamper.stamp)
			end
			print(
				string.format(
					"[ArtOfWar] map self-healed: recovered %d province tile mappings, %d late province records after a throttled boot and re-stamped",
					recovered,
					hydratedLate
				)
			)
		end
	end
end)

if context.AdjacencyGraph and context.AdjacencyGraph.build then
	context.AdjacencyGraph.build()
end

if context.SeaAdjacencyGraph and context.SeaAdjacencyGraph.build then
	context.SeaAdjacencyGraph.build()
end

if context.SeaZoneGraph and context.SeaZoneGraph.build then
	context.SeaZoneGraph.build()
end

local remotesFolder = ReplicatedStorage.ArtOfWar:FindFirstChild("Remotes")
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = "Remotes"
	remotesFolder.Parent = ReplicatedStorage.ArtOfWar
end

local function ensureEvent(name)
	local existing = remotesFolder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = remotesFolder
	return remote
end

local function ensureFunction(name)
	local existing = remotesFolder:FindFirstChild(name)
	if existing and existing:IsA("RemoteFunction") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local remote = Instance.new("RemoteFunction")
	remote.Name = name
	remote.Parent = remotesFolder
	return remote
end

InputValidator.register("ClaimCountry", {
	schema = { { name = "tag", type = "countryTag" } },
	rate = { count = 3, window = 10 },
})
InputValidator.register("ReleaseCountry", {
	schema = {},
	rate = { count = 3, window = 10 },
})
InputValidator.register("SetEconomyPolicy", {
	schema = { { name = "policyId", type = "policyId" } },
	rate = { count = 4, window = 10 },
})
InputValidator.register("SetConsumerGoods", {
	schema = { { name = "priorities", type = "shallowTable" } },
	rate = { count = 4, window = 10 },
})
InputValidator.register("ProposeTrade", {
	schema = {
		{ name = "toTag", type = "countryTag" },
		{ name = "offer", type = "tradeOffer" },
		{ name = "request", type = "tradeOffer" },
	},
	rate = { count = 6, window = 10 },
})
InputValidator.register("AcceptTrade", {
	schema = { { name = "tradeId", type = "integer" } },
	rate = { count = 12, window = 10 },
})
InputValidator.register("CancelTrade", {
	schema = { { name = "tradeId", type = "integer" } },
	rate = { count = 12, window = 10 },
})
InputValidator.addValidator("boolean", function(v)
	return type(v) == "boolean"
end)
InputValidator.addValidator("pactType", function(v)
	return v == "nap" or v == "guarantee" or v == "alliance"
end)
InputValidator.addValidator("tradeLines", function(v)
	if type(v) ~= "table" then
		return false
	end
	local n = 0
	for _, line in ipairs(v) do
		n += 1
		if n > 16 then
			return false
		end
		if type(line) ~= "table" then
			return false
		end
		if type(line.goodId) ~= "string" or line.goodId == "" then
			return false
		end
		if type(line.amount) ~= "number" or line.amount ~= line.amount or line.amount <= 0 then
			return false
		end
	end
	return n > 0
end)
InputValidator.register("PlaceTradeOrder", {
	schema = {
		{ name = "counterpartyTag", type = "countryTag" },
		{ name = "direction", type = "string" },
		{ name = "lines", type = "tradeLines" },
		{ name = "multiplier", type = "positiveNumber" },
		{ name = "recurring", type = "boolean" },
	},
	rate = { count = 6, window = 10 },
})
InputValidator.register("AcceptTradeOrder", {
	schema = { { name = "orderId", type = "integer" } },
	rate = { count = 12, window = 10 },
})
InputValidator.register("RejectTradeOrder", {
	schema = { { name = "orderId", type = "integer" } },
	rate = { count = 12, window = 10 },
})
InputValidator.register("CancelTradeOrder", {
	schema = { { name = "orderId", type = "integer" } },
	rate = { count = 12, window = 10 },
})
InputValidator.register("RequestFullState", {
	rate = { count = 2, window = 30 },
})
InputValidator.register("RequestOwnershipDigest", {
	rate = { count = 6, window = 30 },
})
InputValidator.register("RequestPreviewPath", {
	schema = {
		{ name = "fromProvinceId", type = "integer" },
		{ name = "toProvinceId", type = "integer" },
	},
	rate = { count = 30, window = 5 },
})
InputValidator.register("SetIdeology", {
	schema = { { name = "ideologyId", type = "policyId" } },
	rate = { count = 2, window = 15 },
})
InputValidator.register("SetGovernmentType", {
	schema = {
		{ name = "targetGov", type = "policyId" },
		{ name = "targetIdeology", type = "policyId" },
	},
	rate = { count = 1, window = 30 },
})
InputValidator.register("CancelTransition", {
	rate = { count = 2, window = 30 },
})
InputValidator.register("EnactPolicy", {
	schema = { { name = "policyId", type = "policyId" } },
	rate = { count = 3, window = 15 },
})
InputValidator.register("SetResearch", {
	schema = { { name = "slot", type = "integer" }, { name = "techId", type = "policyId" } },
	rate = { count = 4, window = 10 },
})
InputValidator.register("ClearResearch", {
	schema = { { name = "slot", type = "integer" } },
	rate = { count = 4, window = 10 },
})
InputValidator.register("RepealPolicy", {
	schema = { { name = "policyId", type = "policyId" } },
	rate = { count = 3, window = 15 },
})
InputValidator.register("CancelLaw", {
	rate = { count = 2, window = 30 },
})
-- Politics overhaul ("Authority & the Estates")
InputValidator.register("GrantPrivilege", {
	schema = { { name = "privilegeId", type = "policyId" } },
	rate = { count = 6, window = 15 },
})
InputValidator.register("RevokePrivilege", {
	schema = { { name = "privilegeId", type = "policyId" } },
	rate = { count = 6, window = 15 },
})
InputValidator.register("SeizePower", {
	schema = { { name = "estateId", type = "policyId" } },
	rate = { count = 4, window = 15 },
})
InputValidator.register("ResolveEvent", {
	schema = {
		{ name = "eventId", type = "policyId" },
		{ name = "optionId", type = "policyId" },
	},
	rate = { count = 6, window = 10 },
})
InputValidator.register("AppointLeader", {
	schema = {
		{ name = "slot", type = "policyId" },
		{ name = "candidateIndex", type = "integer" },
	},
	rate = { count = 4, window = 15 },
})
InputValidator.register("DismissLeader", {
	schema = { { name = "slot", type = "policyId" } },
	rate = { count = 3, window = 15 },
})
InputValidator.register("SetMapMode", {
	schema = { { name = "mode", type = "policyId" } },
	rate = { count = 4, window = 10 },
})
InputValidator.register("RecruitUnit", {
	schema = {
		{ name = "provinceId", type = "integer" },
		{ name = "unitTypeId", type = "policyId" },
		{ name = "count", type = "integer" },
	},
	rate = { count = 6, window = 10 },
})
InputValidator.register("MoveArmy", {
	schema = {
		{ name = "armyId", type = "string" },
		{ name = "toProvinceId", type = "integer" },
	},
	rate = { count = 12, window = 10 },
})
InputValidator.register("MoveArmyPath", {
	schema = {
		{ name = "armyId", type = "string" },
		{ name = "finalProvinceId", type = "integer" },
	},
	rate = { count = 12, window = 10 },
})
-- C6 batched remotes: per-remote rate limits make client-side loops over a multi-selection
-- impossible (orders silently drop), so multi-province/multi-army actions arrive as ONE call
-- with a bounded id list (shallowTable caps at 256 entries; handlers re-cap at 25).
InputValidator.register("MoveArmyPathMulti", {
	schema = {
		{ name = "armyIds", type = "shallowTable" },
		{ name = "finalProvinceId", type = "integer" },
	},
	rate = { count = 12, window = 10 },
})
InputValidator.register("RecruitUnitMulti", {
	schema = {
		{ name = "provinceIds", type = "shallowTable" },
		{ name = "unitTypeId", type = "policyId" },
		{ name = "count", type = "integer" },
	},
	rate = { count = 3, window = 10 },
})
InputValidator.register("ConstructBuildingMulti", {
	schema = {
		{ name = "provinceIds", type = "shallowTable" },
		{ name = "buildingId", type = "policyId" },
	},
	rate = { count = 3, window = 10 },
})
InputValidator.register("AttackProvince", {
	schema = {
		{ name = "armyId", type = "string" },
		{ name = "targetProvinceId", type = "integer" },
	},
	rate = { count = 6, window = 10 },
})
InputValidator.register("DisbandArmy", {
	schema = { { name = "armyId", type = "string" } },
	rate = { count = 6, window = 15 },
})
InputValidator.register("MergeArmies", {
	schema = {
		{ name = "primaryId", type = "string" },
		{ name = "otherIds", type = "shallowTable" },
	},
	rate = { count = 4, window = 15 },
})
InputValidator.register("SplitArmy", {
	schema = {
		{ name = "armyId", type = "string" },
		{ name = "composition", type = "shallowTable" },
	},
	rate = { count = 6, window = 15 },
})
-- Combat depth B: army groups.
InputValidator.register("FormArmyGroup", {
	schema = {
		{ name = "name", type = "string" },
		{ name = "armyIds", type = "shallowTable" },
	},
	rate = { count = 6, window = 15 },
})
InputValidator.register("RenameArmyGroup", {
	schema = {
		{ name = "groupId", type = "string" },
		{ name = "name", type = "string" },
	},
	rate = { count = 4, window = 15 },
})
InputValidator.register("DisbandArmyGroup", {
	schema = { { name = "groupId", type = "string" } },
	rate = { count = 6, window = 15 },
})
InputValidator.register("AddArmyToGroup", {
	schema = {
		{ name = "groupId", type = "string" },
		{ name = "armyIds", type = "shallowTable" },
	},
	rate = { count = 6, window = 15 },
})
-- Combat depth C: generals.
InputValidator.register("BuyGeneral", { schema = {}, rate = { count = 3, window = 30 } })
InputValidator.register("AssignGeneral", {
	schema = {
		{ name = "groupId", type = "string" },
		{ name = "generalId", type = "string" },
	},
	rate = { count = 6, window = 15 },
})
InputValidator.register("UnassignGeneral", {
	schema = { { name = "groupId", type = "string" } },
	rate = { count = 6, window = 15 },
})
-- Combat depth D: cover-border order.
InputValidator.register("SetBorderCover", {
	schema = {
		{ name = "groupId", type = "string" },
		{ name = "targetTag", type = "countryTag" },
	},
	rate = { count = 6, window = 15 },
})
InputValidator.register("ClearBorderCover", {
	schema = { { name = "groupId", type = "string" } },
	rate = { count = 6, window = 15 },
})
InputValidator.register("Reinforce", {
	schema = {
		{ name = "armyId", type = "string" },
		{ name = "provinceId", type = "integer" },
	},
	rate = { count = 6, window = 10 },
})
InputValidator.register("SetDoctrine", {
	schema = { { name = "doctrineId", type = "policyId" } },
	rate = { count = 3, window = 15 },
})
InputValidator.register("RecruitShip", {
	schema = {
		{ name = "provinceId", type = "integer" },
		{ name = "shipTypeId", type = "policyId" },
		{ name = "count", type = "integer" },
	},
	rate = { count = 6, window = 10 },
})
InputValidator.register("MoveFleet", {
	schema = {
		{ name = "fleetId", type = "string" },
		{ name = "toProvinceId", type = "integer" },
	},
	rate = { count = 12, window = 10 },
})
InputValidator.register("AttackFleet", {
	schema = {
		{ name = "fleetId", type = "string" },
		{ name = "targetFleetId", type = "string" },
	},
	rate = { count = 6, window = 10 },
})
InputValidator.register("DisbandFleet", {
	schema = { { name = "fleetId", type = "string" } },
	rate = { count = 6, window = 15 },
})
InputValidator.register("SetFleetMission", {
	schema = {
		{ name = "fleetId", type = "string" },
		{ name = "missionType", type = "string" },
		{ name = "targetProvinceId", type = "integer" },
		{ name = "targetFleetId", type = "optionalString" },
	},
	rate = { count = 6, window = 10 },
})
InputValidator.register("ClearFleetMission", {
	schema = { { name = "fleetId", type = "string" } },
	rate = { count = 6, window = 10 },
})
InputValidator.register("ReassignOfficer", {
	schema = {
		{ name = "armyId", type = "string" },
		{ name = "traitIds", type = "shallowTable" },
	},
	rate = { count = 4, window = 30 },
})
InputValidator.register("BuildBuilding", {
	schema = {
		{ name = "provinceId", type = "integer" },
		{ name = "buildingId", type = "policyId" },
	},
	rate = { count = 6, window = 10 },
})
InputValidator.register("CancelBuilding", {
	schema = { { name = "ticketId", type = "string" } },
	rate = { count = 6, window = 15 },
})
InputValidator.register("BuildDistrict", {
	schema = {
		{ name = "provinceId", type = "integer" },
		{ name = "slotIndex", type = "integer" },
		{ name = "districtType", type = "string" },
	},
	rate = { count = 8, window = 10 },
})
InputValidator.register("UpgradeDistrict", {
	schema = {
		{ name = "provinceId", type = "integer" },
		{ name = "slotIndex", type = "integer" },
	},
	rate = { count = 8, window = 10 },
})
InputValidator.register("UpgradeDistrictAll", {
	schema = { { name = "districtType", type = "string" } },
	rate = { count = 4, window = 10 },
})
InputValidator.register("RazeDistrict", {
	schema = {
		{ name = "provinceId", type = "integer" },
		{ name = "slotIndex", type = "integer" },
	},
	rate = { count = 8, window = 10 },
})
InputValidator.register("CancelMove", {
	schema = { { name = "armyId", type = "string" } },
	rate = { count = 20, window = 10 },
})
InputValidator.register("SetAutoCapture", {
	schema = {
		{ name = "armyId", type = "string" },
		{ name = "enabled", type = "boolean" },
	},
	rate = { count = 20, window = 10 },
})

InputValidator.register("SetMerge", {
	schema = {
		{ name = "armyId", type = "string" },
		{ name = "enabled", type = "boolean" },
	},
	rate = { count = 20, window = 10 },
})

InputValidator.register("SetReinforce", {
	schema = {
		{ name = "armyId", type = "string" },
		{ name = "enabled", type = "boolean" },
	},
	rate = { count = 20, window = 10 },
})

InputValidator.register("DeclareWar", {
	schema = { { name = "targetTag", type = "countryTag" } },
	rate = { count = 2, window = 30 },
})
InputValidator.register("ProposePeace", {
	schema = {
		{ name = "targetTag", type = "countryTag" },
		{ name = "terms", type = "peaceTerms" },
	},
	rate = { count = 4, window = 30 },
})
InputValidator.register("AcceptPeace", {
	schema = { { name = "proposalId", type = "string" } },
	rate = { count = 4, window = 15 },
})
InputValidator.register("RejectPeace", {
	schema = { { name = "proposalId", type = "string" } },
	rate = { count = 6, window = 15 },
})
InputValidator.register("CancelPeaceProposal", {
	schema = { { name = "proposalId", type = "string" } },
	rate = { count = 4, window = 15 },
})
InputValidator.register("ImproveRelations", {
	schema = { { name = "targetTag", type = "countryTag" } },
	rate = { count = 6, window = 30 },
})
InputValidator.register("ProposePact", {
	schema = {
		{ name = "toTag", type = "countryTag" },
		{ name = "pactType", type = "pactType" },
	},
	rate = { count = 6, window = 30 },
})
InputValidator.register("AcceptPact", {
	schema = { { name = "pactId", type = "string" } },
	rate = { count = 12, window = 10 },
})
InputValidator.register("RejectPact", {
	schema = { { name = "pactId", type = "string" } },
	rate = { count = 6, window = 15 },
})
InputValidator.register("CancelPact", {
	schema = { { name = "pactId", type = "string" } },
	rate = { count = 4, window = 15 },
})
InputValidator.register("BreakPact", {
	schema = {
		{ name = "otherTag", type = "countryTag" },
		{ name = "pactType", type = "pactType" },
	},
	rate = { count = 4, window = 30 },
})
InputValidator.register("ReleaseSubject", {
	schema = { { name = "subjectTag", type = "countryTag" } },
	rate = { count = 4, window = 30 },
})
InputValidator.register("AnnexSubject", {
	schema = { { name = "subjectTag", type = "countryTag" } },
	rate = { count = 4, window = 30 },
})
InputValidator.register("FormNation", {
	schema = { { name = "formableTag", type = "string" } },
	rate = { count = 4, window = 15 },
})
InputValidator.register("ReleaseNation", {
	schema = { { name = "formableTag", type = "string" }, { name = "asPuppet", type = "any" } },
	rate = { count = 4, window = 30 },
})
-- Owner-authored custom formables (Phase 6). Admin-gated in the handler (EditorAdmins, required above);
-- def is validated server-side by FormableStore.
InputValidator.register("SetFormable", {
	schema = { { name = "tag", type = "string" }, { name = "def", type = "any" } },
	rate = { count = 20, window = 30 },
})
InputValidator.register("RemoveFormable", {
	schema = { { name = "tag", type = "string" } },
	rate = { count = 20, window = 30 },
})
InputValidator.register("SaveClientSettings", {
	schema = { { name = "settings", type = "shallowTable" } },
	rate = { count = 20, window = 10 },
})

local function bindEvent(name, handler)
	local remote = ensureEvent(name)
	remote.OnServerEvent:Connect(function(player, ...)
		if not InputValidator.accept(player, name, ...) then
			return
		end
		local ok, err = pcall(handler, player, ...)
		if not ok then
			warn(string.format("[ArtOfWar] remote '%s' handler errored: %s", name, tostring(err)))
		end
	end)
	return remote
end

local function bindFunction(name, handler)
	local remote = ensureFunction(name)
	remote.OnServerInvoke = function(player, ...)
		if not InputValidator.accept(player, name, ...) then
			return nil
		end
		local ok, result = pcall(handler, player, ...)
		if not ok then
			warn(string.format("[ArtOfWar] remote '%s' handler errored: %s", name, tostring(result)))
			return nil
		end
		return result
	end
	return remote
end

local function authority()
	return context.PlayerAuthority
end

bindEvent("ClaimCountry", function(player, tag)
	local auth = authority()
	if not auth then
		return
	end
	local ok = auth.claim(player, tag)
	if ok and context.StateReplicator and context.StateReplicator.broadcast then
		context.StateReplicator.broadcast()
	end
end)

bindEvent("ReleaseCountry", function(player)
	local auth = authority()
	if not auth then
		return
	end
	auth.release(player)
	if context.StateReplicator and context.StateReplicator.broadcast then
		context.StateReplicator.broadcast()
	end
end)

bindEvent("SaveClientSettings", function(player, settings)
	if context.SettingsStore then
		context.SettingsStore.save(player, settings)
	end
end)

-- ── Custom Country Colors (gamepass cosmetic) ─────────────────────────────────────────────────────────
-- Owners of the "Custom Country Colors" gamepass can recolour their nation. The colour lives on the country
-- record (customColor = {r,g,b}) so it replicates server-wide exactly like the base colour (StateReplicator
-- copies every non-dropped field). A 60s per-player cooldown throttles changes. Reset stores `false` rather
-- than nil so the cleared state actually replicates in a delta (a removed key would linger on clients).
local MarketplaceService = game:GetService("MarketplaceService")
local CUSTOM_COLORS_GAMEPASS = 1907046397
local COLOR_CHANGE_COOLDOWN = 60 -- seconds between colour changes, per player
local ownsColorsCache = {} -- [userId] = bool (gamepass ownership; refreshed on purchase)
local colorChangeAt = {} -- [userId] = os.clock() of the last successful change

local COLOR_OWNERSHIP_TTL = 45 -- seconds to trust a cached NON-owner result before re-verifying
local function ownsCustomColors(player)
	local uid = player.UserId
	-- Trust a cached TRUE forever (ownership is permanent once bought). Trust a cached FALSE only for a short
	-- TTL, then re-verify -- this bounds MarketplaceService calls from a spoofing client to ~1 per TTL while
	-- still honouring a just-completed purchase promptly (also flipped true by PromptGamePassPurchaseFinished).
	local cached = ownsColorsCache[uid]
	if type(cached) == "table" then
		if cached.value == true then
			return true
		end
		if (os.clock() - cached.at) < COLOR_OWNERSHIP_TTL then
			return false
		end
	end
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(uid, CUSTOM_COLORS_GAMEPASS)
	end)
	owns = (ok and owns) or false
	ownsColorsCache[uid] = { value = owns, at = os.clock() }
	return owns
end

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
	if gamePassId == CUSTOM_COLORS_GAMEPASS and wasPurchased then
		ownsColorsCache[player.UserId] = { value = true, at = os.clock() }
	end
end)
game:GetService("Players").PlayerRemoving:Connect(function(player)
	ownsColorsCache[player.UserId] = nil
	colorChangeAt[player.UserId] = nil
end)

local function colorToast(tag, kind, body)
	if context.NotificationBroadcaster then
		context.NotificationBroadcaster.push({
			kind = kind,
			title = "Country Color",
			body = body,
			audience = "self",
			tag = tag,
			eventType = "country.color",
			ttl = 6,
		})
	end
end

InputValidator.addValidator("colorByte", function(v)
	return type(v) == "number" and v >= 0 and v <= 255 and v == math.floor(v)
end)
InputValidator.register("SetCustomCountryColor", {
	schema = {
		{ name = "r", type = "colorByte" },
		{ name = "g", type = "colorByte" },
		{ name = "b", type = "colorByte" },
	},
	rate = { count = 5, window = 10 },
})
InputValidator.register("ResetCustomCountryColor", {
	schema = {},
	rate = { count = 5, window = 10 },
})

bindEvent("SetCustomCountryColor", function(player, r, g, b)
	local auth = authority()
	if not auth then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	if not ownsCustomColors(player) then
		colorToast(tag, "warn", "Requires the \u{201C}Custom Country Colors\u{201D} gamepass.")
		return
	end
	local now = os.clock()
	local last = colorChangeAt[player.UserId]
	if last and (now - last) < COLOR_CHANGE_COOLDOWN then
		colorToast(
			tag,
			"warn",
			string.format("You can change your color again in %ds.", math.ceil(COLOR_CHANGE_COOLDOWN - (now - last)))
		)
		return
	end
	local country = context.WorldState.getCountry(tag)
	if not country then
		return
	end
	country.customColor = {
		math.clamp(math.floor(r), 0, 255),
		math.clamp(math.floor(g), 0, 255),
		math.clamp(math.floor(b), 0, 255),
	}
	context.WorldState.setCountry(tag, country)
	colorChangeAt[player.UserId] = now
	colorToast(tag, "good", "Your country color has been updated.")
end)

bindEvent("ResetCustomCountryColor", function(player)
	local auth = authority()
	if not auth then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	local country = context.WorldState.getCountry(tag)
	if not country or country.customColor == nil then
		return
	end
	country.customColor = false -- sentinel: replicates the cleared state (nil would linger in the delta)
	context.WorldState.setCountry(tag, country)
end)

bindEvent("SetEconomyPolicy", function(player, policyId)
	local auth = authority()
	local system = loadedSystems.EconomySystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.setEconomyPolicy(tag, policyId)
end)

bindEvent("SetConsumerGoods", function(player, priorities)
	local auth = authority()
	local system = loadedSystems.EconomySystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.setConsumerGoods(tag, priorities)
end)

bindEvent("ProposeTrade", function(player, toTag, offer, request)
	if not WorldConstants.EnableTrade then
		return
	end
	local auth = authority()
	local system = loadedSystems.TradeSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.propose(tag, toTag, offer, request)
end)

bindEvent("AcceptTrade", function(player, tradeId)
	if not WorldConstants.EnableTrade then
		return
	end
	local auth = authority()
	local system = loadedSystems.TradeSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.accept(tradeId, tag)
end)

bindEvent("CancelTrade", function(player, tradeId)
	if not WorldConstants.EnableTrade then
		return
	end
	local auth = authority()
	local system = loadedSystems.TradeSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.cancel(tradeId, tag)
end)

bindEvent("PlaceTradeOrder", function(player, counterpartyTag, direction, lines, multiplier, recurring)
	if not WorldConstants.EnableTrade then
		return
	end
	local auth = authority()
	local system = loadedSystems.TradeOrderSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.place(tag, counterpartyTag, direction, lines, multiplier, recurring)
end)

bindEvent("AcceptTradeOrder", function(player, orderId)
	if not WorldConstants.EnableTrade then
		return
	end
	local auth = authority()
	local system = loadedSystems.TradeOrderSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.accept(orderId, tag)
end)

bindEvent("RejectTradeOrder", function(player, orderId)
	if not WorldConstants.EnableTrade then
		return
	end
	local auth = authority()
	local system = loadedSystems.TradeOrderSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.reject(orderId, tag)
end)

bindEvent("CancelTradeOrder", function(player, orderId)
	if not WorldConstants.EnableTrade then
		return
	end
	local auth = authority()
	local system = loadedSystems.TradeOrderSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.cancel(orderId, tag)
end)

bindEvent("SetIdeology", function(player, ideologyId)
	if not WorldConstants.EnablePolitics then
		return
	end
	local auth = authority()
	local system = loadedSystems.IdeologySystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.setIdeology(tag, ideologyId, "voluntary")
end)

bindEvent("SetGovernmentType", function(player, targetGov, targetIdeology)
	if not WorldConstants.EnablePolitics then
		return
	end
	local auth = authority()
	if not auth or not context.GovernmentTransitions then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	context.GovernmentTransitions.begin(tag, targetGov, {
		trigger = "voluntary",
		targetIdeology = targetIdeology,
	})
end)

bindEvent("CancelTransition", function(player)
	if not WorldConstants.EnablePolitics then
		return
	end
	local auth = authority()
	if not auth or not context.GovernmentTransitions then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	context.GovernmentTransitions.cancel(tag)
end)

bindEvent("EnactPolicy", function(player, policyId)
	if not WorldConstants.EnablePolitics then
		return
	end
	local auth = authority()
	if not auth then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	-- Phase 4: the 3-phase LawSystem is retired — policies enact instantly, with estate reactions
	-- firing via the CountryPolicyEnacted subscription.
	local polSys = loadedSystems.PolicySystem
	if polSys then
		polSys.enact(tag, policyId, "voluntary")
	end
end)

bindEvent("RepealPolicy", function(player, policyId)
	if not WorldConstants.EnablePolitics then
		return
	end
	local auth = authority()
	local system = loadedSystems.PolicySystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.repeal(tag, policyId, "voluntary")
end)

-- Politics overhaul ("Authority & the Estates")
bindEvent("GrantPrivilege", function(player, privilegeId)
	if not WorldConstants.EnablePolitics then
		return
	end
	local auth = authority()
	if not auth or not context.EstateSystem then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	context.EstateSystem.grantPrivilege(tag, privilegeId)
end)

bindEvent("RevokePrivilege", function(player, privilegeId)
	if not WorldConstants.EnablePolitics then
		return
	end
	local auth = authority()
	if not auth or not context.EstateSystem then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	context.EstateSystem.revokePrivilege(tag, privilegeId)
end)

bindEvent("SeizePower", function(player, estateId)
	if not WorldConstants.EnablePolitics then
		return
	end
	local auth = authority()
	if not auth or not context.EstateSystem then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	context.EstateSystem.seizePower(tag, estateId)
end)

bindEvent("ResolveEvent", function(player, eventId, optionId)
	local auth = authority()
	if not auth or not context.EventSystem then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	context.EventSystem.resolveEvent(tag, eventId, optionId, false)
end)

bindEvent("SetResearch", function(player, slot, techId)
	if not WorldConstants.EnableTechTree then
		return
	end
	local auth = authority()
	local system = loadedSystems.ResearchSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.startResearch(tag, slot, techId)
end)

bindEvent("ClearResearch", function(player, slot)
	if not WorldConstants.EnableTechTree then
		return
	end
	local auth = authority()
	local system = loadedSystems.ResearchSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.clearSlot(tag, slot)
end)

bindEvent("CancelLaw", function(player)
	if not WorldConstants.EnablePolitics then
		return
	end
	local auth = authority()
	local system = loadedSystems.LawSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.cancelLaw(tag, "voluntary")
end)

bindEvent("AppointLeader", function(player, slot, candidateIndex)
	if not WorldConstants.EnablePolitics then
		return
	end
	local auth = authority()
	local system = loadedSystems.LeaderSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.appoint(tag, slot, candidateIndex)
end)

bindEvent("DismissLeader", function(player, slot)
	if not WorldConstants.EnablePolitics then
		return
	end
	local auth = authority()
	local system = loadedSystems.LeaderSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.dismiss(tag, slot)
end)

bindEvent("SetMapMode", function(player, mode)
	local system = loadedSystems.MapModeSystem
	if not system then
		return
	end
	system.setMode(player, mode)
end)

-- Human-readable body for a failed recruit/build/release. RecruitSystem returns snake_case tokens
-- (insufficient_treasury, district_required:Military, ...); NavalSystem returns space-separated phrases
-- ("no shipyard here"). Toasting this instead of dropping the click fixes the "Recruit does nothing" trap
-- flagged in the pre-playtest ArmyPanel/FleetPanel audit.
local RECRUIT_REASON_TEXT = {
	insufficient_treasury = "Not enough gold.",
	insufficient_manpower = "Not enough manpower.",
	insufficient_levies = "Not enough levy manpower.",
	province_ineligible = "That province can't recruit this unit.",
	production_lines_full = "That province's build queue is full.",
	unit_locked = "That unit isn't available yet.",
	unknown_unit = "That unit isn't available.",
	bad_count = "Choose a valid amount.",
	-- DiplomacySystem.releaseNation tokens. Without these the generic de-underscoring fallback would render
	-- "no_releasable_cores" as the bare "No releasable cores.", which explains nothing to a player.
	no_releasable_cores = "You hold no provinces that would free this nation.",
	already_exists = "That nation already exists on the map.",
	invalid = "That nation can't be released.",
	unavailable = "Releasing isn't available right now.",
	disabled = "Releasing nations is disabled.",
}
local function recruitFailBody(reason)
	if type(reason) ~= "string" or reason == "" then
		return "You can't recruit there right now."
	end
	local mapped = RECRUIT_REASON_TEXT[reason]
	if mapped then
		return mapped
	end
	local district = reason:match("^district_required:(.+)$")
	if district then
		return string.format("Requires a %s district in that province.", district)
	end
	-- NavalSystem phrases are already human ("no shipyard here"); army tokens fall back to a de-underscored form.
	local text = reason:gsub("_", " ")
	return text:sub(1, 1):upper() .. text:sub(2) .. "."
end
local function toastRecruitFail(tag, title, reason)
	if context.NotificationBroadcaster then
		context.NotificationBroadcaster.push({
			kind = "warn",
			title = title,
			body = recruitFailBody(reason),
			audience = "self",
			tag = tag,
			eventType = "recruit.fail",
			ttl = 5,
		})
	end
end

bindEvent("RecruitUnit", function(player, provinceId, unitTypeId, count)
	local auth = authority()
	local system = loadedSystems.RecruitSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	local ok, reason = system.enqueue(tag, provinceId, unitTypeId, count)
	if not ok then
		toastRecruitFail(tag, "Can't recruit", reason)
	end
end)

-- C6: apply a batched action per province, count successes, and toast the partial result
-- ("Queued in 4/7 provinces"). Validation stays entirely per-province inside enqueue, so
-- partial application (owner decision) is automatic -- it deducts until broke/ineligible.
local MULTI_PROVINCE_CAP = 200

local function applyMulti(tag, provinceIds, applyFn, title, verb)
	local applied, total, firstReason = 0, 0, nil
	for _, pid in ipairs(provinceIds) do
		if total >= MULTI_PROVINCE_CAP then
			break
		end
		if type(pid) == "number" then
			total += 1
			local ok, reason = applyFn(pid)
			if ok then
				applied += 1
			elseif not firstReason and reason then
				firstReason = reason
			end
		end
	end
	if total > 0 and context.NotificationBroadcaster then
		local suffix = (applied < total and firstReason) and string.format(" (%s)", tostring(firstReason)) or ""
		context.NotificationBroadcaster.push({
			kind = applied > 0 and "good" or "warn",
			title = title,
			body = string.format("%s in %d/%d provinces%s.", verb, applied, total, suffix),
			audience = "self",
			tag = tag,
			eventType = "multi.apply",
			ttl = 6,
		})
	end
end

bindEvent("RecruitUnitMulti", function(player, provinceIds, unitTypeId, count)
	local auth = authority()
	local system = loadedSystems.RecruitSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	if type(provinceIds) ~= "table" then
		return
	end
	applyMulti(tag, provinceIds, function(pid)
		return system.enqueue(tag, pid, unitTypeId, count)
	end, "Recruitment Queued", "Recruitment queued")
end)

bindEvent("ConstructBuildingMulti", function(player, provinceIds, buildingId)
	local auth = authority()
	local system = loadedSystems.BuildingSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	if type(provinceIds) ~= "table" then
		return
	end
	applyMulti(tag, provinceIds, function(pid)
		return system.enqueue(tag, pid, buildingId)
	end, "Construction Queued", "Construction queued")
end)

-- Helper: surface a server-side movement rejection as a notification toast.
local function notifyMoveRejected(tag, reason)
	if not tag then
		return
	end
	local nb = context.NotificationBroadcaster
	if not nb or not nb.push then
		return
	end
	local title, body
	if reason == "not_at_war" then
		title = "No path to enemy territory"
		body = "You must declare war before crossing the border."
	elseif reason == "in_battle" then
		title = "Army is engaged"
		body = "Cannot reorder a force currently in battle."
	elseif reason == "no_path" then
		title = "No accessible path"
		body = "There is no friendly route to that destination."
	elseif reason == "no_speed" then
		title = "Army cannot move"
		body = "This force has no movement speed."
	else
		return
	end
	nb.push({
		kind = "warn",
		title = title,
		body = body,
		audience = "self",
		tag = tag,
		ttl = 4,
	})
end

bindEvent("MoveArmy", function(player, armyId, toProvinceId)
	local auth = authority()
	local system = loadedSystems.MovementSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	local army = context.WorldState.getArmy(armyId)
	if not army or army.ownerTag ~= tag then
		return
	end
	local ok, reason = system.beginMove(armyId, toProvinceId)
	if not ok and reason then
		notifyMoveRejected(tag, reason)
	end
end)

bindEvent("MoveArmyPath", function(player, armyId, finalProvinceId)
	local auth = authority()
	local system = loadedSystems.MovementSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	local army = context.WorldState.getArmy(armyId)
	if not army or army.ownerTag ~= tag then
		return
	end
	local ok, reason = system.beginMovePath(armyId, finalProvinceId)
	if not ok and reason then
		notifyMoveRejected(tag, reason)
	end
end)

-- C6: one remote for a whole stack selection (MoveArmyPath's 12/10s rate would drop orders
-- past 12 armies). Ownership validated per army; one rejection toast at most.
bindEvent("MoveArmyPathMulti", function(player, armyIds, finalProvinceId)
	local auth = authority()
	local system = loadedSystems.MovementSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	if type(armyIds) ~= "table" then
		return
	end
	local n, firstReason = 0, nil
	for _, armyId in ipairs(armyIds) do
		n += 1
		if n > 25 then
			break
		end
		local army = context.WorldState.getArmy(armyId)
		if army and army.ownerTag == tag then
			local ok, reason = system.beginMovePath(armyId, finalProvinceId)
			if not ok and reason and not firstReason then
				firstReason = reason
			end
		end
	end
	if firstReason then
		notifyMoveRejected(tag, firstReason)
	end
end)

-- Server-authoritative move PREVIEW: returns the exact route the player's army would take, so the
-- client renders the real path instead of recomputing its own (which could diverge from movement).
bindFunction("RequestPreviewPath", function(player, fromProvinceId, toProvinceId)
	local auth = authority()
	local system = loadedSystems.MovementSystem
	if not auth or not system or not system.computePreviewPath then
		return nil
	end
	local tag = auth.tagFor(player)
	if not tag then
		return nil
	end
	return system.computePreviewPath(fromProvinceId, toProvinceId, tag)
end)

bindEvent("CancelMove", function(player, armyId)
	local auth = authority()
	local system = loadedSystems.MovementSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	local army = context.WorldState.getArmy(armyId)
	if not army or army.ownerTag ~= tag then
		return
	end
	system.cancelMovement(armyId, "player_cancelled")
end)

bindEvent("SetAutoCapture", function(player, armyId, enabled)
	local auth = authority()
	local system = loadedSystems.AutoCaptureSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	local army = context.WorldState.getArmy(armyId)
	if not army or army.ownerTag ~= tag then
		return
	end
	system.setAutoCapture(armyId, enabled)
end)

bindEvent("SetMerge", function(player, armyId, enabled)
	local auth = authority()
	local system = loadedSystems.ArmySystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	local army = context.WorldState.getArmy(armyId)
	if not army or army.ownerTag ~= tag then
		return
	end
	system.setMerge(armyId, enabled)
end)

-- Per-army toggle for the manpower-fed reinforcement pass (ArmySystem.regenTick honours
-- army.reinforceEnabled ~= false). Mirrors SetAutoCapture.
bindEvent("SetReinforce", function(player, armyId, enabled)
	local auth = authority()
	if not auth then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	local army = context.WorldState.getArmy(armyId)
	if not army or army.ownerTag ~= tag then
		return
	end
	army.reinforceEnabled = enabled and true or false
	context.WorldState.setArmy(armyId, army)
end)

bindEvent("AttackProvince", function(player, armyId, targetProvinceId)
	local auth = authority()
	local system = loadedSystems.CombatSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	local army = context.WorldState.getArmy(armyId)
	if not army or army.ownerTag ~= tag then
		return
	end
	system.attackProvince(armyId, targetProvinceId)
end)

bindEvent("DisbandArmy", function(player, armyId)
	local auth = authority()
	local armySys = loadedSystems.ArmySystem
	if not auth or not armySys then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	local army = context.WorldState.getArmy(armyId)
	if not army or army.ownerTag ~= tag then
		return
	end
	local country = context.WorldState.getCountry(tag)
	if country and army.composition then
		local refund = context.WorldConstants.ArmyDisbandManpowerRefund or 0.5
		local bundle = context.Bundle
		for unitTypeId, quantity in army.composition do
			local unit = bundle and bundle.unitTypes and bundle.unitTypes[unitTypeId]
			if unit then
				country.manpower = (country.manpower or 0) + unit.recruitManpower * quantity * refund
			end
		end
		context.WorldState.setCountry(tag, country)
	end
	armySys.destroyArmy(armyId, "disbanded")
end)

bindEvent("MergeArmies", function(player, primaryId, otherIds)
	local auth = authority()
	local armySys = loadedSystems.ArmySystem
	if not auth or not armySys or not armySys.mergeArmies then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	-- Verify primary belongs to player
	local primary = context.WorldState.getArmy(primaryId)
	if not primary or primary.ownerTag ~= tag then
		return
	end
	-- Filter otherIds to player-owned strings only (defensive)
	local cleaned = {}
	for _, id in ipairs(otherIds or {}) do
		if type(id) == "string" and id ~= primaryId then
			local other = context.WorldState.getArmy(id)
			if other and other.ownerTag == tag then
				table.insert(cleaned, id)
			end
		end
	end
	if #cleaned == 0 then
		return
	end
	armySys.mergeArmies(primaryId, cleaned)
end)

bindEvent("SplitArmy", function(player, armyId, composition)
	local auth = authority()
	local armySys = loadedSystems.ArmySystem
	if not auth or not armySys or not armySys.splitArmy then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	local army = context.WorldState.getArmy(armyId)
	if not army or army.ownerTag ~= tag then
		return
	end
	-- Defensive: only string keys -> positive integer counts.
	local cleaned = {}
	if type(composition) == "table" then
		for unitTypeId, count in pairs(composition) do
			if type(unitTypeId) == "string" and type(count) == "number" and count >= 1 then
				cleaned[unitTypeId] = math.floor(count)
			end
		end
	end
	if next(cleaned) == nil then
		return
	end
	armySys.splitArmy(armyId, cleaned)
end)

local TextService = game:GetService("TextService")
-- Run a player-supplied name through Roblox text filtering before it is stored and replicated to every
-- client (UGC-text compliance; also strips RichText injection). Returns a broadcast-safe string, or nil
-- when the input is empty or filtering fails -- callers fall back to a safe default / keep the old name.
local function filterBroadcastName(player, text)
	if type(text) ~= "string" or text == "" then
		return nil
	end
	local ok, result = pcall(function()
		return TextService:FilterStringAsync(text, player.UserId)
	end)
	if not ok or not result then
		return nil
	end
	local ok2, filtered = pcall(function()
		return result:GetNonChatStringForBroadcastAsync()
	end)
	if not ok2 or type(filtered) ~= "string" then
		return nil
	end
	return filtered
end

bindEvent("FormArmyGroup", function(player, name, armyIds)
	local auth = authority()
	local ags = loadedSystems.ArmyGroupSystem
	if not auth or not ags or not ags.createGroup then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	if type(armyIds) ~= "table" then
		return
	end
	local cleaned = {}
	for _, id in ipairs(armyIds) do
		if type(id) == "string" then
			local army = context.WorldState.getArmy(id)
			if army and army.ownerTag == tag then
				table.insert(cleaned, id)
			end
		end
	end
	if #cleaned == 0 then
		return
	end
	ags.createGroup(tag, filterBroadcastName(player, name), cleaned)
end)

local function ownedGroup(tag, groupId)
	local g = context.WorldState.getArmyGroup(groupId)
	if g and g.ownerTag == tag then
		return g
	end
	return nil
end

bindEvent("RenameArmyGroup", function(player, groupId, name)
	local auth = authority()
	local ags = loadedSystems.ArmyGroupSystem
	if not auth or not ags or not ags.renameGroup then
		return
	end
	local tag = auth.tagFor(player)
	if not tag or not ownedGroup(tag, groupId) then
		return
	end
	ags.renameGroup(groupId, filterBroadcastName(player, name))
end)

bindEvent("DisbandArmyGroup", function(player, groupId)
	local auth = authority()
	local ags = loadedSystems.ArmyGroupSystem
	if not auth or not ags or not ags.disbandGroup then
		return
	end
	local tag = auth.tagFor(player)
	if not tag or not ownedGroup(tag, groupId) then
		return
	end
	ags.disbandGroup(groupId, "player")
end)

-- Group cards: add/reassign owned armies into a group. addMember already detaches an army from its
-- prior group, so this doubles as the "move between groups" path.
bindEvent("AddArmyToGroup", function(player, groupId, armyIds)
	local auth = authority()
	local ags = loadedSystems.ArmyGroupSystem
	if not auth or not ags or not ags.addMember then
		return
	end
	local tag = auth.tagFor(player)
	if not tag or not ownedGroup(tag, groupId) then
		return
	end
	if type(armyIds) ~= "table" then
		return
	end
	for _, id in ipairs(armyIds) do
		if type(id) == "string" then
			local army = context.WorldState.getArmy(id)
			if army and army.ownerTag == tag then
				ags.addMember(groupId, id)
			end
		end
	end
end)

bindEvent("BuyGeneral", function(player)
	local auth = authority()
	local gs = loadedSystems.GeneralSystem
	if not auth or not gs or not gs.buyGeneral then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	gs.buyGeneral(tag)
end)

bindEvent("AssignGeneral", function(player, groupId, generalId)
	local auth = authority()
	local gs = loadedSystems.GeneralSystem
	if not auth or not gs or not gs.assignGeneral then
		return
	end
	local tag = auth.tagFor(player)
	if not tag or not ownedGroup(tag, groupId) then
		return
	end
	gs.assignGeneral(tag, groupId, generalId)
end)

bindEvent("UnassignGeneral", function(player, groupId)
	local auth = authority()
	local gs = loadedSystems.GeneralSystem
	if not auth or not gs or not gs.unassignGeneral then
		return
	end
	local tag = auth.tagFor(player)
	if not tag or not ownedGroup(tag, groupId) then
		return
	end
	gs.unassignGeneral(tag, groupId)
end)

bindEvent("SetBorderCover", function(player, groupId, targetTag)
	local auth = authority()
	local bcs = loadedSystems.BorderCoverSystem
	if not auth or not bcs or not bcs.setBorderCover then
		return
	end
	local tag = auth.tagFor(player)
	if not tag or not ownedGroup(tag, groupId) then
		return
	end
	bcs.setBorderCover(groupId, targetTag)
end)

bindEvent("ClearBorderCover", function(player, groupId)
	local auth = authority()
	local bcs = loadedSystems.BorderCoverSystem
	if not auth or not bcs or not bcs.clearBorderCover then
		return
	end
	local tag = auth.tagFor(player)
	if not tag or not ownedGroup(tag, groupId) then
		return
	end
	bcs.clearBorderCover(groupId)
end)

bindEvent("Reinforce", function(player, armyId, provinceId)
	local auth = authority()
	local bm = loadedSystems.BattleManager
	if not auth or not bm or not bm.reinforce then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	local army = context.WorldState.getArmy(armyId)
	if not army or army.ownerTag ~= tag then
		return
	end
	bm.reinforce(armyId, provinceId)
end)

bindEvent("SetDoctrine", function(player, doctrineId)
	local auth = authority()
	local system = loadedSystems.DoctrineSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.setDoctrine(tag, doctrineId)
end)

bindEvent("RecruitShip", function(player, provinceId, shipTypeId, count)
	local auth = authority()
	local system = loadedSystems.NavalSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	local ok, reason = system.queueRecruit(tag, provinceId, shipTypeId, count)
	if not ok then
		toastRecruitFail(tag, "Can't build ships", reason)
	end
end)

bindEvent("MoveFleet", function(player, fleetId, toProvinceId)
	local auth = authority()
	local system = loadedSystems.NavalSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	local fleet = context.WorldState.getFleet(fleetId)
	if not fleet or fleet.ownerTag ~= tag then
		return
	end
	system.moveFleet(tag, fleetId, toProvinceId)
end)

bindEvent("AttackFleet", function(player, fleetId, targetFleetId)
	local auth = authority()
	local system = loadedSystems.NavalSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	local fleet = context.WorldState.getFleet(fleetId)
	if not fleet or fleet.ownerTag ~= tag then
		return
	end
	system.attackFleet(tag, fleetId, targetFleetId)
end)

bindEvent("DisbandFleet", function(player, fleetId)
	local auth = authority()
	local system = loadedSystems.NavalSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.disbandFleet(tag, fleetId)
end)

bindEvent("SetFleetMission", function(player, fleetId, missionType, targetProvinceId, targetFleetId)
	local auth = authority()
	local system = loadedSystems.NavalSystem
	if not auth or not system or not system.assignMission then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	local fleet = context.WorldState.getFleet(fleetId)
	if not fleet or fleet.ownerTag ~= tag then
		return
	end
	local target = (type(targetProvinceId) == "number" and targetProvinceId > 0) and targetProvinceId or nil
	local fleetRef = (type(targetFleetId) == "string" and targetFleetId ~= "") and targetFleetId or nil
	if fleetRef then
		local targetFleet = context.WorldState.getFleet(fleetRef)
		if not targetFleet then
			return
		end
		system.assignMission(fleetId, missionType, target, {
			targetFleetId = fleetRef,
			pairedFleetId = fleetRef,
		})
	else
		system.assignMission(fleetId, missionType, target)
	end
end)

bindEvent("ClearFleetMission", function(player, fleetId)
	local auth = authority()
	local system = loadedSystems.NavalSystem
	if not auth or not system or not system.clearMission then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	local fleet = context.WorldState.getFleet(fleetId)
	if not fleet or fleet.ownerTag ~= tag then
		return
	end
	system.clearMission(fleetId)
end)

local OFFICER_REASSIGN_COST = 25

bindEvent("ReassignOfficer", function(player, armyId, traitIds)
	local auth = authority()
	local armySys = loadedSystems.ArmySystem
	if not auth or not armySys or not armySys.reassignOfficer then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	local army = context.WorldState.getArmy(armyId)
	if not army or army.ownerTag ~= tag then
		return
	end
	if type(traitIds) ~= "table" then
		return
	end
	local cleaned = {}
	for _, tid in pairs(traitIds) do
		if type(tid) == "string" and tid ~= "" then
			table.insert(cleaned, tid)
		end
	end
	if #cleaned == 0 then
		return
	end
	local pp = context.PoliticalPower
	if pp and pp.spend then
		local paid = pp.spend(tag, OFFICER_REASSIGN_COST, "officer_reassign")
		if not paid then
			return
		end
	end
	armySys.reassignOfficer(armyId, cleaned)
end)

bindEvent("BuildBuilding", function(player, provinceId, buildingId)
	local auth = authority()
	local system = loadedSystems.BuildingSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.enqueue(tag, provinceId, buildingId)
end)

bindEvent("CancelBuilding", function(player, ticketId)
	local auth = authority()
	local system = loadedSystems.BuildingSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.cancel(tag, ticketId)
end)

bindEvent("BuildDistrict", function(player, provinceId, slotIndex, districtType)
	local auth = authority()
	local system = loadedSystems.DistrictSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.buildDistrict(tag, provinceId, slotIndex, districtType)
end)

bindEvent("UpgradeDistrict", function(player, provinceId, slotIndex)
	local auth = authority()
	local system = loadedSystems.DistrictSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.upgradeDistrict(tag, provinceId, slotIndex)
end)

bindEvent("UpgradeDistrictAll", function(player, districtType)
	local auth = authority()
	local system = loadedSystems.DistrictSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.upgradeDistrictAll(tag, districtType)
end)
bindEvent("RazeDistrict", function(player, provinceId, slotIndex)
	local auth = authority()
	local system = loadedSystems.DistrictSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.razeDistrict(tag, provinceId, slotIndex)
end)
bindEvent("DeclareWar", function(player, targetTag)
	local auth = authority()
	local system = loadedSystems.DiplomacySystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.declareWar(tag, targetTag)
end)

bindEvent("ProposePeace", function(player, targetTag, terms)
	local auth = authority()
	local system = loadedSystems.DiplomacySystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.proposePeace(tag, targetTag, terms)
end)

bindEvent("AcceptPeace", function(player, proposalId)
	local auth = authority()
	local system = loadedSystems.DiplomacySystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.acceptPeace(proposalId, tag)
end)

bindEvent("RejectPeace", function(player, proposalId)
	local auth = authority()
	local system = loadedSystems.DiplomacySystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.rejectPeace(proposalId, tag)
end)

bindEvent("CancelPeaceProposal", function(player, proposalId)
	local auth = authority()
	local system = loadedSystems.DiplomacySystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.cancelPeaceProposal(proposalId, tag)
end)

bindEvent("ImproveRelations", function(player, targetTag)
	local auth = authority()
	local system = loadedSystems.DiplomacySystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.improveRelations(tag, targetTag)
end)

bindEvent("ProposePact", function(player, toTag, pactType)
	local auth = authority()
	local system = loadedSystems.DiplomacySystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.proposePact(tag, toTag, pactType)
end)

bindEvent("AcceptPact", function(player, pactId)
	local auth = authority()
	local system = loadedSystems.DiplomacySystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.acceptPact(pactId, tag)
end)

bindEvent("RejectPact", function(player, pactId)
	local auth = authority()
	local system = loadedSystems.DiplomacySystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.rejectPact(pactId, tag)
end)

bindEvent("CancelPact", function(player, pactId)
	local auth = authority()
	local system = loadedSystems.DiplomacySystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.cancelPact(pactId, tag)
end)

bindEvent("BreakPact", function(player, otherTag, pactType)
	local auth = authority()
	local system = loadedSystems.DiplomacySystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.breakPact(tag, otherTag, pactType)
end)

bindEvent("ReleaseSubject", function(player, subjectTag)
	local auth = authority()
	local system = loadedSystems.DiplomacySystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.releaseSubject(tag, subjectTag)
end)

bindEvent("AnnexSubject", function(player, subjectTag)
	local auth = authority()
	local system = loadedSystems.DiplomacySystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.annexSubject(tag, subjectTag)
end)

bindEvent("FormNation", function(player, formableTag)
	local auth = authority()
	local system = context.FormableSystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	system.formNation(tag, formableTag)
end)

bindEvent("ReleaseNation", function(player, formableTag, asPuppet)
	local auth = authority()
	local system = loadedSystems.DiplomacySystem
	if not auth or not system then
		return
	end
	local tag = auth.tagFor(player)
	if not tag then
		return
	end
	-- releaseNation's rejection reason was being discarded, so a refused release looked identical to a
	-- successful one from the client's side: nothing happened, with no explanation. Toast it like recruiting.
	local ok, reason = system.releaseNation(tag, formableTag, asPuppet == true)
	if not ok then
		toastRecruitFail(tag, "Can't release", reason)
	end
end)

bindEvent("SetFormable", function(player, tag, def)
	if not EditorAdmins.isAllowed(player) then
		return
	end
	if context.FormableStore then
		context.FormableStore.set(tag, def)
	end
end)

bindEvent("RemoveFormable", function(player, tag)
	if not EditorAdmins.isAllowed(player) then
		return
	end
	if context.FormableStore then
		context.FormableStore.remove(tag)
	end
end)

local mapModeSync = ensureEvent("MapModeSync")
if loadedSystems.MapModeSystem and context.MapModeSystem then
	context.MapModeSystem.setSync(mapModeSync)
	for _, existing in game:GetService("Players"):GetPlayers() do
		context.MapModeSystem.handleJoin(existing)
	end
end

local stateSync = ensureEvent("StateSync")
local ownPoliticsSync = ensureEvent("OwnPolitics")
local ownArmiesSync = ensureEvent("OwnArmies")
local ownResearchSync = ensureEvent("OwnResearch")
if loadedSystems.StateReplicator and context.StateReplicator then
	context.StateReplicator.setStateSync(stateSync)
	context.StateReplicator.setOwnPoliticsSync(ownPoliticsSync)
	context.StateReplicator.setOwnArmiesSync(ownArmiesSync)
	context.StateReplicator.setOwnResearchSync(ownResearchSync)
end

local notificationChannel = ensureEvent("NotificationChannel")
if loadedSystems.NotificationBroadcaster and context.NotificationBroadcaster then
	context.NotificationBroadcaster.setRemote(notificationChannel)
end

-- (removed) BattlePhaseChannel relay: BattlePhaseChanged had ZERO client subscribers, so the
-- per-battle FireAllClients on every phase flip was pure wasted replication. The client bubble reads
-- phaseCycle/phaseIndex off the normal replicated battle record.

local timeSync = ensureEvent("TimeSync")
local timeRequest = ensureEvent("TimeRequest")
if loadedSystems.TimeController and context.TimeController then
	context.TimeController.setSync(timeSync)
	timeRequest.OnServerEvent:Connect(function(player, payload)
		context.TimeController.handleRequest(player, payload)
	end)
	task.defer(context.TimeController.broadcast)
end

bindFunction("RequestFullState", function(player)
	if not context.StateReplicator then
		return nil
	end
	local snapshot = context.StateReplicator.buildSnapshot()
	-- The snapshot omits provinces (the full ~5.7k set is a ~2.6 MB sparse table that truncates in remote
	-- transit). Stream them to THIS client in chunks after returning the small collections.
	if player and context.StateReplicator.pushProvincesTo then
		task.spawn(function()
			context.StateReplicator.pushProvincesTo(player)
		end)
	end
	-- Armies are omitted from the snapshot too (chunked, string-keyed, ~1.5 KB/record) -- stream them to this client.
	if player and context.StateReplicator.pushArmiesTo then
		task.spawn(function()
			context.StateReplicator.pushArmiesTo(player)
		end)
	end
	-- Fleets + armyGroups are also chunked (same truncation class); stream them too.
	if player and context.StateReplicator.pushFleetsTo then
		task.spawn(function()
			context.StateReplicator.pushFleetsTo(player)
		end)
	end
	if player and context.StateReplicator.pushArmyGroupsTo then
		task.spawn(function()
			context.StateReplicator.pushArmyGroupsTo(player)
		end)
	end
	-- Deliver this player their own country's politics (leaders/factions), stripped from the shared snapshot.
	-- No-op until they have claimed; the claim then dirties the country and broadcast() keeps it current.
	if player and context.StateReplicator.pushOwnPoliticsTo then
		context.StateReplicator.pushOwnPoliticsTo(player)
	end
	if player and context.StateReplicator.pushOwnArmiesTo then
		context.StateReplicator.pushOwnArmiesTo(player)
	end
	-- Deliver this player their own country's tech state (levels + research slots), stripped from the shared snapshot.
	if player and context.StateReplicator.pushOwnResearchTo then
		context.StateReplicator.pushOwnResearchTo(player)
	end
	return snapshot
end)

-- Client self-heal reconcile (OwnershipReconcile): compact owner/controller digest so a client can repair
-- any province whose replicated record drifted from the server (see ClientStateCache.reconcileProvinces).
bindFunction("RequestOwnershipDigest", function()
	if not context.WorldState or not context.WorldState.getOwnershipDigest then
		return nil
	end
	return context.WorldState.getOwnershipDigest()
end)

local isAdminPlayer = EditorAdmins.isAllowed

context.isAdminPlayer = isAdminPlayer

-- The Data Editor client (EditorClientV2) is no longer shipped in StarterGui -- that replicated its
-- full ~120 KB source to every player. The template lives in ServerStorage and is cloned into an
-- authorized editor's PlayerGui only while their IsAdmin attribute is true; non-admins never receive
-- the code. FindFirstChild (not WaitForChild) so a missing template degrades to "no editor" rather
-- than hanging Bootstrap.
local editorClientTemplate
do
	local dev = ServerStorage:FindFirstChild("Dev")
	local adminGui = dev and dev:FindFirstChild("AdminGui")
	editorClientTemplate = adminGui and adminGui:FindFirstChild("EditorClientV2")
end
local ADMIN_EDITOR_HOST = "AoWDataEditorHost"

-- Clone the editor into (or remove it from) a player's PlayerGui to match their effective access.
-- Idempotent: safe to call repeatedly (join, config change, live grant/revoke).
local function syncAdminEditorGui(player, allowed)
	task.spawn(function()
		if not player.Parent then
			return
		end
		local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 15)
		if not playerGui or not player.Parent then
			return
		end
		local host = playerGui:FindFirstChild(ADMIN_EDITOR_HOST)
		if allowed and editorClientTemplate then
			if not host then
				host = Instance.new("ScreenGui")
				host.Name = ADMIN_EDITOR_HOST
				host.ResetOnSpawn = false -- survive respawns; the editor builds its own gui too
				host.Enabled = false -- just a container for the LocalScript
				editorClientTemplate:Clone().Parent = host
				host.Parent = playerGui
			end
		else
			if host then
				host:Destroy()
			end
			-- The editor builds a sibling ScreenGui ("AoWDataEditorV2"); clean it up on revoke too.
			local editorGui = playerGui:FindFirstChild("AoWDataEditorV2")
			if editorGui then
				editorGui:Destroy()
			end
		end
	end)
end

local function applyAdminAttribute(player)
	local allowed = isAdminPlayer(player)
	player:SetAttribute("IsAdmin", allowed)
	-- Place-independent editor authorization — drives the Settings "Teleport to Map Editor" button. Distinct
	-- from IsAdmin, which is the EFFECTIVE editor access in THIS place (config tiers only unlock on the Map
	-- Editor place). A historian therefore has MapEditorAuthorized=true but IsAdmin=false in the main game.
	local anywhere = EditorAdmins.isEditorAuthorizedAnywhere and EditorAdmins.isEditorAuthorizedAnywhere(player)
		or false
	player:SetAttribute("MapEditorAuthorized", anywhere)
	syncAdminEditorGui(player, allowed)
end

local Players = game:GetService("Players")

-- Config-driven access loads async and can change live, so re-stamp IsAdmin/MapEditorAuthorized for everyone
-- whenever the access lists change. Register this BEFORE the initial stamp below, so a config load that
-- resolves mid-boot (firing accessChanged) always re-stamps players already present — otherwise a config-only
-- mapper stamped before the snapshot landed would keep stale (false) attributes until the 5-min backstop.
if EditorAdmins.onAccessChanged then
	EditorAdmins.onAccessChanged(function()
		for _, p in Players:GetPlayers() do
			applyAdminAttribute(p)
		end
	end)
end

Players.PlayerAdded:Connect(applyAdminAttribute)
for _, p in Players:GetPlayers() do
	task.spawn(applyAdminAttribute, p)
end

-- Map Editor place is restricted: only authorized editors may remain. Because config access loads async,
-- wait for the config to resolve (or a grace window) before kicking, and never kick an always-on manager.
if game.PlaceId == WorldConstants.MapEditorPlaceId then
	local function gateMapEditor(player)
		local deadline = tick() + 60
		while player.Parent do
			if EditorAdmins.isEditorAuthorizedAnywhere(player) then
				return -- authorized (official manager immediately, or config resolved in their favor)
			end
			local info = EditorAdmins.getAccessInfo and EditorAdmins.getAccessInfo() or {}
			if info.configLoaded or info.configAvailable == false or tick() > deadline then
				break -- config has had its chance; decide now
			end
			-- Actively drive the async config load so a legit historian isn't kicked while the module's own
			-- slow retry cadence (5 tries, then a 5-min backstop) is still pending.
			if EditorAdmins.reload then
				pcall(EditorAdmins.reload)
			end
			task.wait(1)
		end
		if player.Parent and not EditorAdmins.isEditorAuthorizedAnywhere(player) then
			player:Kick("The Map Editor is restricted to authorized editors.")
		end
	end
	Players.PlayerAdded:Connect(function(p)
		task.spawn(gateMapEditor, p)
	end)
	for _, p in Players:GetPlayers() do
		task.spawn(gateMapEditor, p)
	end
end

Players.PlayerRemoving:Connect(function(player)
	InputValidator.releaseWindows(player.UserId)
end)

print(
	string.format(
		"[ArtOfWar] loaded %d provinces, %d countries, %d areas, %d regions",
		DataLoader.countEntries(bundle.provinces),
		DataLoader.countEntries(bundle.countries),
		DataLoader.countEntries(bundle.areas),
		DataLoader.countEntries(bundle.regions)
	)
)

print(
	string.format(
		"[ArtOfWar] economy online: %d goods, %d manufactories, %d policies, %d remotes, tick=%.1fs",
		DataLoader.countEntries(bundle.tradeGoods),
		DataLoader.countEntries(bundle.manufactories),
		DataLoader.countEntries(bundle.economyPolicies),
		#remotesFolder:GetChildren(),
		WorldConstants.SecondsPerEconomyUpdate
	)
)

print(
	string.format(
		"[ArtOfWar] politics online: %d ideologies, %d government types, %d policies, %d leader slots, %d traits, %d factions, PP cap=%d",
		DataLoader.countEntries(bundle.ideologies),
		DataLoader.countEntries(bundle.governmentTypes),
		DataLoader.countEntries(bundle.policies),
		DataLoader.countEntries(bundle.leaderSlots),
		DataLoader.countEntries(bundle.leaderTraits),
		DataLoader.countEntries(bundle.factions),
		WorldConstants.PoliticalPowerCap
	)
)

print(
	string.format(
		"[ArtOfWar] combat online: %d unit types, %d doctrines, combat cap=%dx, adjacency=%d studs",
		DataLoader.countEntries(bundle.unitTypes),
		DataLoader.countEntries(bundle.doctrines),
		WorldConstants.MultiplierCapCombatStat,
		WorldConstants.AdjacencyThreshold
	)
)

local audit = DataLoader.auditUsage(bundle)
print(
	string.format(
		"[ArtOfWar] registry headroom: %d cultures, %d religions, %d goods, %d terrains, %d climates, %d superregions reserved for future content",
		#audit.unusedCultures,
		#audit.unusedReligions,
		#audit.unusedTradeGoods,
		#audit.unusedTerrains,
		#audit.unusedClimates,
		#audit.unusedSuperRegions
	)
)

TickScheduler.start()
