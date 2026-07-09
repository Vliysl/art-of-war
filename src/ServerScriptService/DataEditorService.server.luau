local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Editor = require(ServerStorage:WaitForChild("Dev"):WaitForChild("DataEditor"))
local EditorAdmins = require(ServerStorage:WaitForChild("Dev"):WaitForChild("EditorAdmins"))
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local RelayConfig = require(ServerStorage:WaitForChild("Dev"):WaitForChild("RelayConfig"))
local DataOverlay = require(ServerStorage:WaitForChild("Services"):WaitForChild("DataOverlay"))

local STAGING_ENABLED = true

local function tryRequire(path)
	local ok, mod = pcall(require, path)
	if ok then
		return mod
	end
	return nil
end

local WorldState =
	tryRequire(game.ServerScriptService:WaitForChild("ArtOfWar"):WaitForChild("Framework"):WaitForChild("WorldState"))
local EventBus = tryRequire(game.ServerScriptService.ArtOfWar.Framework:FindFirstChild("EventBus"))
local Channels = tryRequire(ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Events"):WaitForChild("Channels"))

local function syncProvinceToWorld(id)
	if not WorldState then
		return
	end
	id = tonumber(id) or id
	local rec = Editor.getState().provinces[id]
	if not rec then
		return
	end
	local existing = WorldState.getProvince(id)
	if existing then
		for k, v in pairs(rec) do
			existing[k] = v
		end
		if type(rec.cores) == "table" then
			existing.cores = table.clone(rec.cores)
		end
		if type(rec.defaultCores) == "table" then
			existing.defaultCores = table.clone(rec.defaultCores)
		end
		if type(rec.claims) == "table" then
			existing.claims = table.clone(rec.claims)
		end
		if type(rec.goods) == "table" then
			existing.goods = table.clone(rec.goods)
		end
		WorldState.setProvince(id, existing)
	else
		local clone = table.clone(rec)
		if type(rec.cores) == "table" then
			clone.cores = table.clone(rec.cores)
		end
		if type(rec.defaultCores) == "table" then
			clone.defaultCores = table.clone(rec.defaultCores)
		end
		if type(rec.claims) == "table" then
			clone.claims = table.clone(rec.claims)
		end
		if type(rec.goods) == "table" then
			clone.goods = table.clone(rec.goods)
		end
		WorldState.setProvince(id, clone)
	end
	if EventBus and Channels and Channels.ProvinceOwnershipChanged then
		EventBus.publish(Channels.ProvinceOwnershipChanged, { provinceId = id })
	end
end

local function syncCountryToWorld(tag)
	if not WorldState then
		return
	end
	if type(tag) ~= "string" or tag == "" then
		return
	end
	local rec = Editor.getState().countries[tag]
	if not rec then
		return
	end
	local existing = WorldState.getCountry(tag)
	if existing then
		for k, v in pairs(rec) do
			existing[k] = v
		end
		WorldState.setCountry(tag, existing)
	else
		WorldState.setCountry(tag, table.clone(rec))
	end
end

-- Ownership signature used to detect which provinces a LOAD actually changed (drives the live recolor).
local function provinceOwnerKey(rec)
	if type(rec) ~= "table" then
		return "NONE|NONE"
	end
	return tostring(rec.ownerTag or rec.owner or "NONE")
		.. "|"
		.. tostring(rec.controllerTag or rec.controller or "NONE")
end

-- Live-refresh WorldState + the map after a full-world LOAD (named config / draft). A load only writes
-- the DataStore + rebuilds the editor model, so without this it wouldn't show until the next server
-- boot. Mirrors the post-save sync but scoped to provinces whose owner/controller actually changed
-- (via `beforeProv`, captured before the load) so we don't storm every one of the ~5.7k tiles.
local function refreshLiveWorldAfterLoad(beforeProv)
	if not WorldState then
		return { provinces = 0, countries = 0 }
	end
	local st = Editor.getState()
	local newProv = (st and st.provinces) or {}
	local newCty = (st and st.countries) or {}

	-- Countries first, so each province's stampOne sees the current owner colour/culture/religion.
	local countriesSynced = 0
	for tag in pairs(newCty) do
		pcall(syncCountryToWorld, tag)
		countriesSynced += 1
		if countriesSynced % 200 == 0 then
			task.wait()
		end
	end

	-- Provinces whose owner/controller changed → re-sync (publishes ProvinceOwnershipChanged, which
	-- ProvinceStamper turns into a part re-stamp → the client recolours that tile).
	local changed = 0
	local provincesChanged = false
	for id, rec in pairs(newProv) do
		if beforeProv[id] ~= provinceOwnerKey(rec) then
			pcall(syncProvinceToWorld, id)
			provincesChanged = true
			changed += 1
			if changed % 200 == 0 then
				task.wait()
			end
		end
	end

	-- Provinces the load removed → blank their ownership so the map doesn't keep a stale colour.
	for id, before in pairs(beforeProv) do
		if newProv[id] == nil and before ~= "NONE|NONE" then
			local existing = WorldState.getProvince and WorldState.getProvince(id)
			if existing then
				existing.ownerTag = "NONE"
				existing.controllerTag = "NONE"
				WorldState.setProvince(id, existing)
				if EventBus and Channels and Channels.ProvinceOwnershipChanged then
					EventBus.publish(Channels.ProvinceOwnershipChanged, { provinceId = tonumber(id) or id })
				end
				provincesChanged = true
				changed += 1
			end
		end
	end

	-- Apply tile overrides + rebuild adjacency once, exactly like the save path does.
	local stamperMod = game.ServerScriptService.ArtOfWar.Systems:FindFirstChild("ProvinceStamper")
	if stamperMod then
		local ok, stamper = pcall(require, stamperMod)
		if ok and stamper then
			if stamper.refreshEU4Mappings then
				pcall(stamper.refreshEU4Mappings)
			end
			if stamper.applyTileOwnership then
				pcall(stamper.applyTileOwnership)
			end
		end
	end
	if provincesChanged then
		local adjMod = game.ServerScriptService.ArtOfWar.Systems:FindFirstChild("AdjacencyGraph")
		if adjMod then
			local ok, adj = pcall(require, adjMod)
			if ok and adj and adj.build then
				pcall(adj.build)
			end
		end
	end
	return { provinces = changed, countries = countriesSynced }
end

local function stampTileAttributes(part, ownerTag, partName, map)
	if not part then
		return
	end
	local effectiveTag = "NONE"
	if type(ownerTag) == "string" and ownerTag ~= "" and ownerTag ~= "NONE" then
		local state = Editor.getState()
		if state and state.countries and state.countries[ownerTag] then
			effectiveTag = ownerTag
		end
	end
	part:SetAttribute("owner", effectiveTag)
	part:SetAttribute("controller", effectiveTag)
	if effectiveTag ~= "NONE" then
		local country = Editor.getState().countries[effectiveTag]
		if country then
			if type(country.primaryCulture) == "string" and country.primaryCulture ~= "" then
				part:SetAttribute("culture", country.primaryCulture)
			end
			if type(country.stateReligion) == "string" and country.stateReligion ~= "" then
				part:SetAttribute("religion", country.stateReligion)
			end
		end
	else
		part:SetAttribute("culture", nil)
		part:SetAttribute("religion", nil)
	end
	if part:GetAttribute("province_name") == nil then
		local pretty = (partName or part.Name):gsub("prov_%d+_", ""):gsub("_", " ")
		part:SetAttribute("province_name", pretty)
	end
	if not map then
		return
	end
	for _, wrapName in { "LeftWrap", "RightWrap" } do
		local w = map:FindFirstChild(wrapName)
		local wf = w and w:FindFirstChild("Provinces")
		local wp = wf and wf:FindFirstChild(partName)
		if wp then
			wp:SetAttribute("owner", effectiveTag)
			wp:SetAttribute("controller", effectiveTag)
			if part:GetAttribute("culture") then
				wp:SetAttribute("culture", part:GetAttribute("culture"))
			end
			if part:GetAttribute("religion") then
				wp:SetAttribute("religion", part:GetAttribute("religion"))
			end
		end
	end
end

local api = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Remotes"):WaitForChild("DataEditorAPI")

local function ensureRemote(name, className)
	local remotesFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Remotes")
	local existing = remotesFolder:FindFirstChild(name)
	if existing and existing.ClassName == className then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local r = Instance.new(className)
	r.Name = name
	r.Parent = remotesFolder
	return r
end

local LiveSync = ensureRemote("DataEditorLive", "RemoteEvent")
local Presence = ensureRemote("DataEditorPresence", "RemoteEvent")

local MAX_PAYLOAD_DEPTH = 8
local MAX_STRING_LENGTH = 4096
local MAX_TABLE_ENTRIES = 2000
local CALL_COOLDOWN = 0.2
local WRITE_COOLDOWN = 2.5
local PAINT_COOLDOWN = 0.05
local SNAPSHOT_COOLDOWN = 1.0
-- Country deletion is destructive + potentially abusable, so it's throttled far harder than a normal write:
-- at least DELETE_COOLDOWN between deletions AND at most DELETE_MAX within a rolling DELETE_WINDOW (per editor).
local DELETE_COOLDOWN = 150 -- 2.5 minutes between country deletions
local DELETE_WINDOW = 3600 -- rolling 1-hour window
local DELETE_MAX = 5 -- max country deletions per rolling window

local WRITE_COMMANDS = {
	addCountry = true,
	updateCountry = true,
	removeCountry = true,
	addProvince = true,
	updateProvince = true,
	removeProvince = true,
	addCulture = true,
	updateCulture = true,
	removeCulture = true,
	addReligion = true,
	updateReligion = true,
	removeReligion = true,
	addIdeology = true,
	updateIdeology = true,
	removeIdeology = true,
	addGovernmentType = true,
	updateGovernmentType = true,
	removeGovernmentType = true,
	mapProvinceToPart = true,
	promoteTile = true,
	assignProvinceField = true,
	assignProvinceFieldBatch = true,
	save = true,
	exportToLua = true,
	migrateLegacy = true,
	-- Phase 1B v3->v4 store migration + seed import — all write the DataStore.
	migrateV3toV4 = true,
	rollbackV4 = true,
	importSeed = true,
	undo = true,
	redo = true,
	-- Named Save/Load configs + staging/promote all write to the DataStore, so they belong under the
	-- slower write cooldown, not the 0.2s call cooldown (avoids DataStore rate limits). listConfigs is a
	-- single light read and stays on the default call cooldown.
	saveConfig = true,
	loadConfig = true,
	deleteConfig = true,
	promote = true,
	saveDraft = true,
	discardDraft = true,
}

local PAINT_COMMANDS = {
	assignProvince = true,
	setTileOwner = true,
	assignBatch = true,
	paintTag = true,
	paintTagBatch = true,
}

local SNAPSHOT_COMMANDS = {
	dumpDataStore = true,
	reloadState = true,
	auditMapping = true,
}

local lastCallByPlayer = {}
local saveInProgress = false
local saveOwnerUserId = nil
local presence = {}

local isAuthorized = EditorAdmins.isAllowed

-- Commands that never mutate the dataset (pure reads / diffs / exports). Everything NOT in this set is treated
-- as a write for the place gate below. Allowlist (not denylist) so any newly-added command is write-gated by
-- default -- fail safe. getLogs is served directly in OnServerInvoke and never reaches the gate.
local READ_ONLY_COMMANDS = {
	authCheck = true,
	loadState = true,
	reloadState = true,
	provincesPage = true,
	listConfigs = true,
	listAccess = true,
	getDiff = true,
	computeDiffVsShared = true,
	isStagingEnabled = true,
	exportToLua = true,
	dumpDataStore = true,
	auditMapping = true,
}

-- Legacy per-user staging commands (personal drafts + the 3-way `promote` merge). These are incoherent with the
-- single-server snapshot model, so they are rejected when it's active. The editor client never sends them; this
-- blocks a crafted RemoteFunction call. (They branch on `not STAGING_ENABLED`, which stays false in single-server
-- mode, so they'd otherwise still run the retired merge path.)
local STAGING_ONLY_COMMANDS = {
	saveDraft = true,
	loadDraft = true,
	discardDraft = true,
	pullFromShared = true,
	computeDiffVsShared = true,
	promote = true,
}

-- The editor may open (browse) anywhere an admin is recognised, but it must be READ-ONLY off the Map Editor
-- place: DataOverlay only redirects writes to the ':edit' key set on the editor place or in Studio, so a save
-- on the LIVE game place would mutate the un-suffixed keys the live game reads. Official managers bypass the
-- ── Single-server "blessed server" write gate + crash-safety state (Phases 2 & 5 of the snapshot-save rework) ──
-- In SINGLE_SERVER_EDITOR mode only ONE server (the blessed private server) may write the shared :edit world, so
-- a stray second server can't clobber it with a full snapshot. Studio/Team-Test is always exempt (it IS a single
-- shared server and testing must work). `isBlessed` is the cached hint that drives the read-only UI gate
-- (resolved at boot + refreshed periodically); the authoritative write guard is ensureWriteAuthority, which
-- re-asserts the crown via a DataStore CAS on every real write. `worldDirty` tracks whether the shared world
-- changed since the last snapshot; `maybeSnapshot` (forward-declared, assigned after safeCall) is the single
-- choke point every crash-safety save funnels through.
local AUTOSAVE_INTERVAL = 120
local BLESSED_REFRESH_INTERVAL = 120
local isBlessed = false
local worldDirty = false
local maybeSnapshot

local function singleServerMode()
	return (Editor.isSingleServerMode and Editor.isSingleServerMode()) == true
end

-- open-gate on any place, so this is the backstop that stops a dev from painting/saving into live prod data.
local function isEditorWriteAllowed()
	if RunService:IsStudio() then
		return true
	end
	if not EditorAdmins.isMapEditorPlace() then
		return false
	end
	if not singleServerMode() then
		return true -- legacy per-user model untouched until the flag flips
	end
	-- Single-server mode on the editor place: only the blessed private server may write. A public instance
	-- (PrivateServerId == "") is always read-only so a stray public server can never own the shared world.
	if game.PrivateServerId == "" then
		return false
	end
	return isBlessed
end

-- Re-assert write authority via a DataStore CAS right before an actual write (save / autosave / pushToLive).
-- This is the REAL single-writer guard (cached isBlessed only drives the read-only UI gate): even if the cache
-- is momentarily stale, the CAS makes exactly one server hold the crown, and refreshes its heartbeat.
local function ensureWriteAuthority()
	if RunService:IsStudio() then
		return true
	end
	if not singleServerMode() then
		return true
	end
	if game.PrivateServerId == "" then
		return false
	end
	if not EditorAdmins.isMapEditorPlace() then
		return false -- only the Map Editor place contends for the crown (a live VIP server must never claim it)
	end
	local ok, blessed = pcall(DataOverlay.claimBlessedServer)
	isBlessed = ok and blessed == true
	return isBlessed
end

-- Serialize the whole staging command path. Every staging editorCall runs Editor.setActiveUser, which swaps the
-- module-global country/province tables to the caller's world AND yields on DataStore I/O; save/promote also
-- yield mid-flight. Without a lock, a second editor's command can swap the shared globals while the first is
-- parked, so it resumes against the wrong world and clobbers/promotes bad data. This lock makes commands run
-- one-at-a-time (an admin tool with a handful of concurrent editors -- the small added latency is fine).
local commandLock = false
local function withCommandLock(fn)
	local startedAt = os.clock()
	while commandLock do
		task.wait()
		if os.clock() - startedAt > 20 then
			break -- safety valve: never wedge forever if a holder somehow failed to release
		end
	end
	commandLock = true
	local ok, a, b, c = pcall(fn)
	commandLock = false
	if not ok then
		error(a, 0)
	end
	return a, b, c
end

local function presenceSnapshot()
	local list = {}
	for uid, entry in pairs(presence) do
		table.insert(list, { userId = uid, name = entry.name, kind = entry.kind, key = entry.key })
	end
	return list
end

local function broadcastPresence()
	local snap = presenceSnapshot()
	for _, plr in ipairs(Players:GetPlayers()) do
		if isAuthorized(plr) then
			Presence:FireClient(plr, snap)
		end
	end
end

Players.PlayerRemoving:Connect(function(player)
	lastCallByPlayer[player.UserId] = nil
	if presence[player.UserId] then
		presence[player.UserId] = nil
		broadcastPresence()
	end
	if STAGING_ENABLED and Editor.dropUserState then
		-- Take the command lock so we never nil out the shared active-user state while THIS player's own
		-- save/promote is still parked mid-flight on a DataStore round-trip (would make it write the wrong id).
		task.spawn(function()
			withCommandLock(function()
				Editor.dropUserState(player.UserId)
			end)
		end)
	end
	if singleServerMode() then
		-- Last editor leaving: snapshot the shared in-memory world so a later empty->respawn can't lose unsaved
		-- edits. PlayerRemoving fires while `player` is still in GetPlayers(), so exclude them from the count.
		local othersLeft = 0
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= player and isAuthorized(plr) then
				othersLeft += 1
			end
		end
		if othersLeft == 0 and worldDirty then
			task.spawn(function()
				withCommandLock(function()
					maybeSnapshot("last-editor-left")
				end)
			end)
		end
	end
end)

local function validatePayload(payload)
	local function walk(value, depth)
		if depth > MAX_PAYLOAD_DEPTH then
			return false
		end
		local vtype = type(value)
		if vtype == "string" then
			return #value <= MAX_STRING_LENGTH
		elseif vtype == "number" or vtype == "boolean" or vtype == "nil" then
			return true
		elseif vtype == "table" then
			local count = 0
			for k, v in pairs(value) do
				count += 1
				if count > MAX_TABLE_ENTRIES then
					return false
				end
				local ktype = type(k)
				if ktype ~= "string" and ktype ~= "number" then
					return false
				end
				if ktype == "string" and #k > 256 then
					return false
				end
				if not walk(v, depth + 1) then
					return false
				end
			end
			return true
		end
		return false
	end
	return walk(payload, 1)
end

local function rateLimit(player, command)
	local entry = lastCallByPlayer[player.UserId]
	if not entry then
		entry = { call = 0, write = 0, paint = 0, snapshot = 0 }
		lastCallByPlayer[player.UserId] = entry
	end
	local now = os.clock()
	if PAINT_COMMANDS[command] then
		if now - (entry.paint or 0) < PAINT_COOLDOWN then
			return false, "painting too fast — slow down a bit"
		end
		entry.paint = now
		entry.call = now
		return true
	end
	if command == "removeCountry" then
		-- Deleting a country is destructive; gate it far harder than a normal write. Prune the per-editor
		-- delete log to the rolling window, then require both the spacing and the hourly cap. Nothing is
		-- stamped on rejection, so a blocked delete doesn't consume the editor's other cooldowns.
		if now - entry.call < CALL_COOLDOWN then
			return false, "too many calls — slow down"
		end
		local kept = {}
		for _, t in ipairs(entry.deletes or {}) do
			if now - t < DELETE_WINDOW then
				kept[#kept + 1] = t
			end
		end
		local last = kept[#kept]
		if last and now - last < DELETE_COOLDOWN then
			return false,
				string.format(
					"country deletes are limited to one every 2.5 min — wait %ds",
					math.ceil(DELETE_COOLDOWN - (now - last))
				)
		end
		if #kept >= DELETE_MAX then
			return false, string.format("country delete limit reached (%d per hour) — try again later", DELETE_MAX)
		end
		kept[#kept + 1] = now
		entry.deletes = kept
		entry.call = now
		return true
	end
	if now - entry.call < CALL_COOLDOWN then
		return false, "too many calls — slow down"
	end
	entry.call = now
	if WRITE_COMMANDS[command] then
		if now - entry.write < WRITE_COOLDOWN then
			return false, "writes are rate-limited; wait a moment"
		end
		entry.write = now
	elseif SNAPSHOT_COMMANDS[command] then
		if now - entry.snapshot < SNAPSHOT_COOLDOWN then
			return false, "snapshot cooldown"
		end
		entry.snapshot = now
	end
	return true
end

local function safeCall(fn, ...)
	local ok, result = pcall(fn, ...)
	if not ok then
		return { ok = false, error = tostring(result) }
	end
	return { ok = true, result = result }
end

-- Single-server crash-safety snapshot choke point (Phase 5). The non-manual saves (autosave, last-editor-leaves,
-- shutdown) funnel through here; the manual Save handler clears worldDirty on its own success. Writes only when
-- single-server mode is on, this server holds write authority (blessed CAS), and the world actually changed.
maybeSnapshot = function(reason)
	if not singleServerMode() then
		return false
	end
	if not worldDirty then
		return false
	end
	if not ensureWriteAuthority() then
		return false -- not the blessed server: never write (a stray server must not clobber the shared world)
	end
	local res = safeCall(Editor.snapshotSave)
	local ok = res.ok and res.result ~= nil and res.result.ok == true
	if ok then
		worldDirty = false
		print(string.format("[DataEditorService] crash-safe snapshot (%s): %s", reason, res.result.message or "ok"))
	else
		warn(
			string.format(
				"[DataEditorService] crash-safe snapshot FAILED (%s): %s",
				reason,
				tostring(res.error or (res.result and res.result.message) or "unknown")
			)
		)
	end
	return ok
end

local function readState(kind, key)
	local state = Editor.getState()
	if kind == "country" then
		return state.countries[key]
	end
	if kind == "province" then
		return state.provinces[tonumber(key) or key]
	end
	if kind == "culture" then
		return state.cultures[key]
	end
	if kind == "religion" then
		return state.religions[key]
	end
	if kind == "tile" then
		return state.tileOwners[key]
	end
	if kind == "eu4Map" then
		return state.eu4Map[tonumber(key) or key]
	end
	if kind == "ideology" then
		return state.ideologies[key]
	end
	if kind == "government" then
		return state.governments[key]
	end
end

local function broadcastDelta(originPlayer, kind, key)
	-- Per-edit live sync: suppressed under legacy staging, but ENABLED in single-server mode so co-editors see
	-- each other's edits in real time (the client applies these deltas into its snapshot).
	if STAGING_ENABLED and not (Editor.isSingleServerMode and Editor.isSingleServerMode()) then
		return
	end
	local payload = {
		kind = kind,
		key = key,
		value = readState(kind, key),
		originUserId = originPlayer and originPlayer.UserId or nil,
		originName = originPlayer and (originPlayer.DisplayName or originPlayer.Name) or nil,
	}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= originPlayer and isAuthorized(plr) then
			LiveSync:FireClient(plr, payload)
		end
	end
end

local function broadcastBatch(originPlayer, items)
	-- Per-edit live sync (batch): see broadcastDelta. Suppressed under legacy staging, enabled in single-server.
	if STAGING_ENABLED and not (Editor.isSingleServerMode and Editor.isSingleServerMode()) then
		return
	end
	local payload = {
		batch = true,
		originUserId = originPlayer and originPlayer.UserId or nil,
		originName = originPlayer and (originPlayer.DisplayName or originPlayer.Name) or nil,
		items = {},
	}
	for _, entry in ipairs(items) do
		table.insert(payload.items, { kind = entry.kind, key = entry.key, value = readState(entry.kind, entry.key) })
	end
	if #payload.items == 0 then
		return
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= originPlayer and isAuthorized(plr) then
			LiveSync:FireClient(plr, payload)
		end
	end
end

Presence.OnServerEvent:Connect(function(player, action, data)
	if not isAuthorized(player) then
		return
	end
	if action == "update" and type(data) == "table" then
		local kind = type(data.kind) == "string" and data.kind or nil
		local key = data.key
		if not kind or key == nil then
			return
		end
		presence[player.UserId] = {
			kind = kind,
			key = key,
			name = player.DisplayName or player.Name,
			ts = os.time(),
		}
		broadcastPresence()
	elseif action == "clear" then
		if presence[player.UserId] then
			presence[player.UserId] = nil
			broadcastPresence()
		end
	elseif action == "request" then
		Presence:FireClient(player, presenceSnapshot())
	end
end)

local function snapshotState()
	local state = Editor.getState()
	local function fromEditorWithGov(tbl)
		local list = {}
		for id, def in pairs(tbl or {}) do
			table.insert(
				list,
				{ id = id, name = def.displayName or id, allowedIdeologies = def.allowedIdeologies or {} }
			)
		end
		table.sort(list, function(a, b)
			return a.name < b.name
		end)
		return list
	end
	local function keys(modName)
		local mod = require(ReplicatedStorage.ArtOfWar.Data:FindFirstChild(modName))
		local list = {}
		for id, def in pairs(mod) do
			table.insert(list, { id = id, name = def.displayName or id })
		end
		table.sort(list, function(a, b)
			return a.name < b.name
		end)
		return list
	end
	local function fromEditor(tbl)
		local list = {}
		for id, def in pairs(tbl or {}) do
			table.insert(list, { id = id, name = def.displayName or id })
		end
		table.sort(list, function(a, b)
			return a.name < b.name
		end)
		return list
	end
	-- Technologies use `name` (not displayName) and carry tab/category/starting/prerequisites, so
	-- they need a dedicated builder (the generic keys() would drop those + mislabel the name).
	local function techList()
		local mod = require(ReplicatedStorage.ArtOfWar.Data:FindFirstChild("Technologies"))
		local list = {}
		for id, def in pairs(mod) do
			table.insert(list, {
				id = id,
				name = def.name or id,
				tab = def.tab,
				category = def.category,
				starting = def.starting == true,
				prerequisites = def.prerequisites or {},
			})
		end
		table.sort(list, function(a, b)
			if a.tab ~= b.tab then
				return tostring(a.tab) < tostring(b.tab)
			end
			if a.category ~= b.category then
				return tostring(a.category) < tostring(b.category)
			end
			return a.name < b.name
		end)
		return list
	end
	local function deriveReligionGroups(tbl)
		local seen, list = {}, {}
		for _, def in pairs(tbl or {}) do
			local g = def and def.group
			if type(g) == "string" and g ~= "" and not seen[g] then
				seen[g] = true
				table.insert(list, { id = g, name = g })
			end
		end
		table.sort(list, function(a, b)
			return a.name < b.name
		end)
		return list
	end
	return {
		collapsed = (Editor.isCollapsed and Editor.isCollapsed()) or false,
		-- Whether THIS server may write (off the editor place, or not the blessed single-server writer -> false),
		-- so the client can surface a read-only banner up-front instead of only on a rejected edit.
		canWriteHere = isEditorWriteAllowed(),
		countries = state.countries,
		-- Provinces are NOT sent inline: the full set (~5.7k records, ~2.7 MB) does not survive a single
		-- RemoteFunction return -- a sparse id-keyed table that large silently loses its high ids in transit,
		-- so every province past the low contiguous id run vanished client-side. The client streams them in
		-- dense pages via the `provincesPage` command instead (see EditorClientV2.loadProvincesPaged).
		provinces = {},
		eu4Map = state.eu4Map,
		tileOwners = state.tileOwners,
		cultures = state.cultures,
		religions = state.religions,
		ideologies = state.ideologies,
		governmentTypes = state.governments,
		registries = {
			governments = fromEditorWithGov(state.governments),
			ideologies = fromEditor(state.ideologies),
			cultures = fromEditor(state.cultures),
			religions = fromEditor(state.religions),
			religionGroups = deriveReligionGroups(state.religions),
			tradeGoods = keys("TradeGoods"),
			terrains = keys("Terrains"),
			climates = keys("Climates"),
			areas = keys("Areas"),
			regions = keys("Regions"),
			superRegions = keys("SuperRegions"),
			cultureGroups = keys("CultureGroups"),
			technologies = techList(),
		},
	}
end

-- ─────────────────────────── editor action log ───────────────────────────
-- A filterable audit trail of editor WRITE-actions (who / when / what), shown in the Logs tab. Entries
-- buffer in memory (coalescing rapid same-owner paints into one row) and flush to a shared DataStore key
-- so the log is visible across editor servers and survives restarts. Reads are never logged.
local LOG_KEY = "editor:log@v1"
local LOG_CAP = 600
local LOG_FLUSH_INTERVAL = 20
local PAINT_COALESCE_WINDOW = 8 -- seconds: merge a user's consecutive same-owner paints into one row

-- command -> action category. ONLY these commands are logged; anything else is a read/no-op.
local LOG_ACTIONS = {
	assignProvince = "Paint",
	assignBatch = "Paint",
	paintTag = "Paint",
	paintTagBatch = "Paint",
	assignProvinceField = "Province",
	assignProvinceFieldBatch = "Province",
	addProvince = "Province",
	updateProvince = "Province",
	removeProvince = "Province",
	promoteTile = "Province",
	mapProvinceToPart = "Province",
	addCountry = "Country",
	updateCountry = "Country",
	removeCountry = "Country",
	addCulture = "Culture/Religion",
	updateCulture = "Culture/Religion",
	removeCulture = "Culture/Religion",
	addReligion = "Culture/Religion",
	updateReligion = "Culture/Religion",
	removeReligion = "Culture/Religion",
	addIdeology = "Ideology/Gov",
	updateIdeology = "Ideology/Gov",
	removeIdeology = "Ideology/Gov",
	addGovernmentType = "Ideology/Gov",
	updateGovernmentType = "Ideology/Gov",
	removeGovernmentType = "Ideology/Gov",
	save = "Save",
	saveConfig = "Save config",
	loadConfig = "Load config",
	deleteConfig = "Delete config",
	pushToLive = "Push to Live",
	migrateLegacy = "Migrate",
	migrateV3toV4 = "Migrate",
	rollbackV4 = "Migrate",
	importSeed = "Import",
}
-- Actions that should flush to storage immediately (rare + important; everything else waits for the timer).
local FLUSH_NOW_ACTIONS = { save = true, saveConfig = true, loadConfig = true, deleteConfig = true, pushToLive = true }

-- Distinct action categories (sorted) for the Logs-tab filter dropdown.
local LOG_ACTION_LIST = (function()
	local seen, list = {}, {}
	for _, a in pairs(LOG_ACTIONS) do
		if not seen[a] then
			seen[a] = true
			list[#list + 1] = a
		end
	end
	table.sort(list)
	return list
end)()

local logStore = DataStoreService:GetDataStore(RelayConfig.DATASTORE_NAME, RelayConfig.DATASTORE_SCOPE)
local pendingLog = {} -- entries created on THIS server, not yet flushed

local function logDecode(raw)
	if type(raw) == "string" then
		local ok, dec = pcall(HttpService.JSONDecode, HttpService, raw)
		if ok and type(dec) == "table" then
			return dec
		end
		return {}
	end
	return type(raw) == "table" and raw or {}
end

-- Short human summary + (for paints) a coalesce key so a user's consecutive same-owner paints merge.
local function describeAction(command, payload)
	payload = type(payload) == "table" and payload or {}
	if command == "assignProvince" then
		return string.format("painted #%s -> %s", tostring(payload.id), tostring(payload.ownerTag)),
			"paint:" .. tostring(payload.ownerTag)
	elseif command == "assignBatch" then
		local n = (type(payload.items) == "table" and #payload.items) or 0
		return string.format("painted %d tiles -> %s", n, tostring(payload.ownerTag)), nil
	elseif command == "addCountry" then
		return "added country " .. tostring(payload.tag), nil
	elseif command == "updateCountry" then
		return "edited country " .. tostring(payload.tag), nil
	elseif command == "removeCountry" then
		return "removed country " .. tostring(payload.tag), nil
	elseif command == "saveConfig" then
		return "saved map '" .. tostring(payload.name) .. "'", nil
	elseif command == "loadConfig" then
		return "loaded map '" .. tostring(payload.name) .. "'", nil
	elseif command == "deleteConfig" then
		return "deleted map '" .. tostring(payload.name) .. "'", nil
	elseif command == "pushToLive" then
		return "published the editor map to the live game", nil
	end
	local tgt = payload.id or payload.tag or payload.key or payload.name
	return command .. (tgt ~= nil and (" " .. tostring(tgt)) or ""), nil
end

local function appendLog(player, command, payload)
	local action = LOG_ACTIONS[command]
	if not action then
		return
	end
	local summary, coalesceKey = describeAction(command, payload)
	local now = os.time()
	if coalesceKey then
		local last = pendingLog[#pendingLog]
		if
			last
			and last.uid == player.UserId
			and last.ck == coalesceKey
			and (now - (last.t or 0)) <= PAINT_COALESCE_WINDOW
		then
			last.n = (last.n or 1) + 1
			last.t = now
			last.msg = string.format("painted %d tiles -> %s", last.n, string.sub(coalesceKey, 7))
			return
		end
	end
	pendingLog[#pendingLog + 1] = {
		t = now,
		uid = player.UserId,
		u = player.DisplayName or player.Name,
		a = action,
		msg = summary,
		n = coalesceKey and 1 or nil,
		ck = coalesceKey,
	}
	while #pendingLog > LOG_CAP do
		table.remove(pendingLog, 1)
	end
end

local function flushLogs()
	if #pendingLog == 0 then
		return
	end
	local batch = pendingLog
	pendingLog = {}
	local ok = pcall(function()
		logStore:UpdateAsync(LOG_KEY, function(raw)
			local stored = logDecode(raw)
			for _, e in ipairs(batch) do
				stored[#stored + 1] = e
			end
			while #stored > LOG_CAP do
				table.remove(stored, 1)
			end
			return HttpService:JSONEncode(stored)
		end)
	end)
	if not ok then
		-- restore the batch (front) so we retry on the next flush without losing entries
		for i = #batch, 1, -1 do
			table.insert(pendingLog, 1, batch[i])
		end
	end
end

-- Newest-first list of up to `limit` entries: the shared stored log plus this server's un-flushed batch.
local function readLogs(limit)
	limit = limit or 300
	local stored = {}
	local ok, raw = pcall(function()
		return logStore:GetAsync(LOG_KEY)
	end)
	if ok then
		stored = logDecode(raw)
	end
	for _, e in ipairs(pendingLog) do
		stored[#stored + 1] = e
	end
	local out = {}
	for i = #stored, math.max(1, #stored - limit + 1), -1 do
		out[#out + 1] = stored[i]
	end
	return out
end

local function handleEditorCommand(player, command, payload)
	if type(command) ~= "string" then
		return { ok = false, error = "invalid command" }
	end
	if not isAuthorized(player) then
		return { ok = false, error = "not authorized — only admins may use the data editor" }
	end
	-- authCheck is a trivial authorized-only probe the client uses to gate its window. Handle it BEFORE the
	-- rate limiter: the window-open sequence fires authCheck immediately followed by loadState, and if
	-- authCheck stamped the call cooldown, loadState would be rejected with "too many calls".
	if command == "authCheck" then
		return {
			ok = true,
			result = {
				allowed = isAuthorized(player), -- always true here (gated above), but don't hardcode the invariant
				canManage = EditorAdmins.canManage(player),
				role = EditorAdmins.classify(player),
				canWriteHere = isEditorWriteAllowed(), -- client can surface a read-only banner off the editor place
			},
		}
	end
	if payload ~= nil and not validatePayload(payload) then
		return { ok = false, error = "payload rejected" }
	end
	-- Read-only off the Map Editor place (Studio exempt) so the editor can never write into live prod data.
	if not READ_ONLY_COMMANDS[command] and not isEditorWriteAllowed() then
		-- Distinguish the two read-only causes so the message tells the user how to fix it: on the editor place but
		-- not the blessed single-server writer vs. off the editor place entirely.
		local msg
		if singleServerMode() and EditorAdmins.isMapEditorPlace() and not RunService:IsStudio() then
			msg = "Read-only: this isn't the editing server. Reopen the editor from the blessed private-server link."
		else
			msg = "the data editor is read-only outside the Map Editor place — open it there to make changes"
		end
		return { ok = false, error = msg }
	end
	local allowed, rateErr = rateLimit(player, command)
	if not allowed then
		return { ok = false, error = rateErr }
	end

	if STAGING_ENABLED then
		pcall(Editor.setActiveUser, player.UserId)
	end

	-- Legacy staging commands must never run in single-server mode (they'd invoke the retired draft/promote
	-- 3-way merge). The client never sends them; this blocks a crafted call.
	if singleServerMode() and STAGING_ONLY_COMMANDS[command] then
		return { ok = false, error = "that action is unavailable in single-server editing mode" }
	end

	if command == "loadState" then
		return safeCall(snapshotState)
	elseif command == "reloadState" then
		-- Single-server: only the blessed WRITER's in-memory world can hold unsaved shared edits, so it must NOT
		-- re-read DataStore on reload (that would clobber them) -- it just re-sends its current snapshot. A read-only
		-- (non-blessed / public) server has no unsaved edits, so it SHOULD re-read to pick up the writer's saves.
		if not (singleServerMode() and isEditorWriteAllowed()) then
			Editor.load()
		end
		return safeCall(snapshotState)
	elseif command == "provincesPage" then
		-- Streams provinces to the client in dense pages (snapshotState omits them; see the note there).
		-- Each page is dense PARALLEL arrays {ids, records} -- no sparse id-keyed table, so nothing is lost
		-- in transit. Read-only + bounded, so it rides the ordinary CALL_COOLDOWN (client spaces its pages).
		return safeCall(function()
			local state = Editor.getState()
			local prov = state.provinces or {}
			local ids = {}
			for id in pairs(prov) do
				ids[#ids + 1] = id
			end
			table.sort(ids, function(a, b)
				return (tonumber(a) or 0) < (tonumber(b) or 0)
			end)
			local total = #ids
			local offset = math.max(0, math.floor(tonumber(payload and payload.offset) or 0))
			local limit = math.clamp(math.floor(tonumber(payload and payload.limit) or 800), 1, 1200)
			local last = math.min(offset + limit, total)
			local pageIds, pageRecs = {}, {}
			for i = offset + 1, last do
				local id = ids[i]
				pageIds[#pageIds + 1] = id
				pageRecs[#pageRecs + 1] = prov[id]
			end
			return { ids = pageIds, records = pageRecs, total = total, nextOffset = (last < total) and last or nil }
		end)
	elseif command == "addCountry" then
		local opts = payload.opts or {}
		local promotedId
		if type(opts.promoteCapitalFromTile) == "string" and opts.promoteCapitalFromTile ~= "" then
			local tile = opts.promoteCapitalFromTile
			opts.promoteCapitalFromTile = nil
			local promote = safeCall(Editor.promoteTile, {
				partName = tile,
				culture = opts.primaryCulture,
				religion = opts.stateReligion,
			})
			if not promote.ok then
				return promote
			end
			opts.capitalProvinceId = promote.result.id
			promotedId = promote.result.id
		end
		local result = safeCall(Editor.addCountry, payload.tag, opts)
		if result.ok then
			syncCountryToWorld(payload.tag)
			broadcastDelta(player, "country", payload.tag)
			if promotedId then
				pcall(Editor.assignProvince, promotedId, payload.tag)
				syncProvinceToWorld(promotedId)
				broadcastDelta(player, "province", promotedId)
			end
		end
		return result
	elseif command == "updateCountry" then
		local opts = payload.opts or {}
		-- Route per-country starting techs through the validating setter (rejects unknown ids)
		-- rather than the generic field loop in updateCountry.
		local startingTechs = opts.startingTechs
		if startingTechs ~= nil then
			opts.startingTechs = nil
			local techResult = safeCall(Editor.setCountryStartingTechs, payload.tag, startingTechs)
			if not techResult.ok then
				return techResult
			end
		end
		local promotedId
		if type(opts.promoteCapitalFromTile) == "string" and opts.promoteCapitalFromTile ~= "" then
			local tile = opts.promoteCapitalFromTile
			opts.promoteCapitalFromTile = nil
			local promote = safeCall(Editor.promoteTile, {
				partName = tile,
				culture = opts.primaryCulture,
				religion = opts.stateReligion,
			})
			if not promote.ok then
				return promote
			end
			opts.capitalProvinceId = promote.result.id
			promotedId = promote.result.id
		end
		local result = safeCall(Editor.updateCountry, payload.tag, opts)
		if result.ok then
			syncCountryToWorld(payload.tag)
			-- Grant newly-set starting techs into the LIVE WorldState country.techs (seedAll ran
			-- once at boot and will not re-run). WorldState only -- never the editor record.
			if startingTechs ~= nil and WorldState then
				local Technologies = require(ReplicatedStorage.ArtOfWar.Data:FindFirstChild("Technologies"))
				local wc = WorldState.getCountry(payload.tag)
				if wc then
					wc.techs = wc.techs or {}
					for id, on in pairs(startingTechs) do
						local def = on and Technologies[id]
						if def then
							wc.techs[id] = true
							for _, g in ipairs(def.gates or {}) do
								wc.techs[g] = true
							end
						end
					end
					WorldState.setCountry(payload.tag, wc)
				end
			end
			broadcastDelta(player, "country", payload.tag)
			if promotedId then
				pcall(Editor.assignProvince, promotedId, payload.tag)
				syncProvinceToWorld(promotedId)
				broadcastDelta(player, "province", promotedId)
			end
		end
		return result
	elseif command == "removeCountry" then
		local tag = payload.tag
		local affectedProvinces, affectedTiles = {}, {}
		local pre = Editor.getState()
		if pre.countries[tag] then
			for id, p in pairs(pre.provinces) do
				if p.ownerTag == tag or p.controllerTag == tag then
					table.insert(affectedProvinces, id)
				end
			end
			for partName, owner in pairs(pre.tileOwners) do
				if owner == tag then
					table.insert(affectedTiles, partName)
				end
			end
		end
		local result = safeCall(Editor.removeCountry, tag)
		if result.ok then
			if WorldState and WorldState.deleteCountry then
				-- stripMembership=true: editor delete removes the country from existence, so purge it from live
				-- cores/defaultCores/claims too (combat annexation, the other caller, keeps those).
				pcall(WorldState.deleteCountry, tag, nil, true)
			end
			local items = { { kind = "country", key = tag } }
			for _, id in ipairs(affectedProvinces) do
				syncProvinceToWorld(id)
				table.insert(items, { kind = "province", key = id })
			end
			local map = workspace:FindFirstChild("ArtOfWarMap")
			local main = map and map:FindFirstChild("Provinces")
			if main then
				for _, partName in ipairs(affectedTiles) do
					local part = main:FindFirstChild(partName)
					if part then
						stampTileAttributes(part, "NONE", partName, map)
					end
					table.insert(items, { kind = "tile", key = partName })
				end
			end
			broadcastBatch(player, items)
		end
		return result
	elseif command == "addCulture" then
		local result = safeCall(Editor.addCulture, payload.id, payload.opts or {})
		if result.ok then
			broadcastDelta(player, "culture", payload.id)
		end
		return result
	elseif command == "updateCulture" then
		local result = safeCall(Editor.updateCulture, payload.id, payload.opts or {})
		if result.ok then
			broadcastDelta(player, "culture", payload.id)
		end
		return result
	elseif command == "removeCulture" then
		local result = safeCall(Editor.removeCulture, payload.id)
		if result.ok then
			broadcastDelta(player, "culture", payload.id)
		end
		return result
	elseif command == "addReligion" then
		local result = safeCall(Editor.addReligion, payload.id, payload.opts or {})
		if result.ok then
			broadcastDelta(player, "religion", payload.id)
		end
		return result
	elseif command == "updateReligion" then
		local result = safeCall(Editor.updateReligion, payload.id, payload.opts or {})
		if result.ok then
			broadcastDelta(player, "religion", payload.id)
		end
		return result
	elseif command == "removeReligion" then
		local result = safeCall(Editor.removeReligion, payload.id)
		if result.ok then
			broadcastDelta(player, "religion", payload.id)
		end
		return result
	elseif command == "addIdeology" then
		local result = safeCall(Editor.addIdeology, payload.id, payload.opts or {})
		if result.ok then
			broadcastDelta(player, "ideology", payload.id)
		end
		return result
	elseif command == "updateIdeology" then
		local result = safeCall(Editor.updateIdeology, payload.id, payload.opts or {})
		if result.ok then
			broadcastDelta(player, "ideology", payload.id)
		end
		return result
	elseif command == "removeIdeology" then
		local result = safeCall(Editor.removeIdeology, payload.id)
		if result.ok then
			broadcastDelta(player, "ideology", payload.id)
		end
		return result
	elseif command == "addGovernmentType" then
		local result = safeCall(Editor.addGovernmentType, payload.id, payload.opts or {})
		if result.ok then
			broadcastDelta(player, "government", payload.id)
		end
		return result
	elseif command == "updateGovernmentType" then
		local result = safeCall(Editor.updateGovernmentType, payload.id, payload.opts or {})
		if result.ok then
			broadcastDelta(player, "government", payload.id)
		end
		return result
	elseif command == "removeGovernmentType" then
		local result = safeCall(Editor.removeGovernmentType, payload.id)
		if result.ok then
			broadcastDelta(player, "government", payload.id)
		end
		return result
	elseif command == "addProvince" then
		local result = safeCall(Editor.addProvince, payload.id, payload.opts or {})
		if result.ok then
			syncProvinceToWorld(payload.id)
			broadcastDelta(player, "province", payload.id)
		end
		return result
	elseif command == "updateProvince" then
		local result = safeCall(Editor.updateProvince, payload.id, payload.opts or {})
		if result.ok then
			syncProvinceToWorld(payload.id)
			broadcastDelta(player, "province", payload.id)
		end
		return result
	elseif command == "removeProvince" then
		local id = tonumber(payload.id) or payload.id
		local pre = Editor.getState()
		local eu4Pid = pre.eu4Map[id]
		local result = safeCall(Editor.removeProvince, id)
		if result.ok then
			if WorldState and WorldState.deleteProvince then
				pcall(WorldState.deleteProvince, id)
			end
			if eu4Pid then
				local map = workspace:FindFirstChild("ArtOfWarMap")
				local main = map and map:FindFirstChild("Provinces")
				if main then
					for _, part in ipairs(main:GetChildren()) do
						if part:IsA("BasePart") and tonumber(part.Name:match("prov_(%d+)")) == eu4Pid then
							stampTileAttributes(part, "NONE", part.Name, map)
							break
						end
					end
				end
			end
			broadcastDelta(player, "province", id)
		end
		return result
	elseif command == "assignProvince" then
		local result = safeCall(Editor.assignProvince, payload.id, payload.ownerTag)
		if result.ok then
			syncProvinceToWorld(payload.id)
			broadcastDelta(player, "province", payload.id)
		end
		return result
	elseif command == "paintTag" then
		-- Add/remove one country tag on a province's cores / defaultCores / claims array.
		local result = safeCall(Editor.paintProvinceTag, payload.id, payload.target, payload.tag, payload.mode)
		if result.ok then
			syncProvinceToWorld(payload.id)
			broadcastDelta(player, "province", payload.id)
		end
		return result
	elseif command == "paintTagBatch" then
		local items = type(payload) == "table" and payload.items
		local target = type(payload) == "table" and payload.target or nil
		local tag = type(payload) == "table" and payload.tag or nil
		local mode = (type(payload) == "table" and payload.mode) or "add"
		if type(items) ~= "table" then
			return { ok = false, error = "items must be a table" }
		end
		if type(target) ~= "string" or type(tag) ~= "string" or tag == "" then
			return { ok = false, error = "target and tag required" }
		end
		if #items > 500 then
			return { ok = false, error = string.format("batch too large: %d items (max 500) — split it up", #items) }
		end
		return safeCall(function()
			local processed, errors, deltas = 0, {}, {}
			Editor.beginBatch(string.format("paintTagBatch %s %s -> %s", mode, target, tag))
			for i, item in ipairs(items) do
				if type(item) == "table" and item.id ~= nil then
					local ok, err = pcall(Editor.paintProvinceTag, item.id, target, tag, mode)
					if ok then
						processed += 1
						syncProvinceToWorld(item.id)
						table.insert(deltas, { kind = "province", key = item.id })
					else
						table.insert(errors, { id = item.id, error = tostring(err) })
					end
				end
				if i % 100 == 0 then
					task.wait() -- a max 500-item bulk apply fires ~69 SetAttribute/item; yield so it can't stall a frame
				end
			end
			Editor.endBatch()
			broadcastBatch(player, deltas)
			return { processed = processed, errors = errors, total = #items }
		end)
	elseif command == "assignProvinceField" then
		local result = safeCall(Editor.assignProvinceField, payload.id, payload.field, payload.value)
		if result.ok then
			syncProvinceToWorld(payload.id)
			broadcastDelta(player, "province", payload.id)
		end
		return result
	elseif command == "assignProvinceFieldBatch" then
		local items = type(payload) == "table" and payload.items
		local field = type(payload) == "table" and payload.field
		local value = type(payload) == "table" and payload.value
		if type(items) ~= "table" then
			return { ok = false, error = "items must be a table of province ids" }
		end
		if type(field) ~= "string" or (field ~= "culture" and field ~= "religion") then
			return { ok = false, error = "field must be 'culture' or 'religion'" }
		end
		if #items > 500 then
			return { ok = false, error = string.format("batch too large: %d items (max 500) — split it up", #items) }
		end
		return safeCall(function()
			local processed, errors, deltas = 0, {}, {}
			Editor.beginBatch(string.format("assignProvinceFieldBatch %s", field))
			for _, id in ipairs(items) do
				local ok, err = pcall(Editor.assignProvinceField, id, field, value)
				if ok then
					processed = processed + 1
					syncProvinceToWorld(id)
					table.insert(deltas, { kind = "province", key = id })
				else
					table.insert(errors, { id = id, error = tostring(err) })
				end
			end
			Editor.endBatch()
			broadcastBatch(player, deltas)
			return { processed = processed, errors = errors, total = #items }
		end)
	elseif command == "mapProvinceToPart" then
		local result = safeCall(Editor.mapProvinceToPart, payload.id, payload.btPartId)
		if result.ok then
			broadcastDelta(player, "eu4Map", payload.id)
		end
		return result
	elseif command == "promoteTile" then
		local result = safeCall(Editor.promoteTile, payload or {})
		if result.ok and type(result.result) == "table" and result.result.id then
			syncProvinceToWorld(result.result.id)
			broadcastDelta(player, "province", result.result.id)
			if payload and type(payload) == "table" and type(payload.partName) == "string" then
				broadcastDelta(player, "tile", payload.partName)
			end
		end
		return result
	elseif command == "setTileOwner" then
		local result = safeCall(Editor.setTileOwner, payload.partName, payload.ownerTag)
		if result.ok then
			local map = workspace:FindFirstChild("ArtOfWarMap")
			local main = map and map:FindFirstChild("Provinces")
			local part = main and main:FindFirstChild(payload.partName)
			if part then
				local effective = (payload.ownerTag == nil or payload.ownerTag == "") and "NONE" or payload.ownerTag
				stampTileAttributes(part, effective, payload.partName, map)
			end
			broadcastDelta(player, "tile", payload.partName)
		end
		return result
	elseif command == "assignBatch" then
		local items = type(payload) == "table" and payload.items
		local ownerTag = type(payload) == "table" and payload.ownerTag or nil
		if type(items) ~= "table" then
			return { ok = false, error = "items must be a table" }
		end
		if type(ownerTag) ~= "string" or ownerTag == "" then
			return { ok = false, error = "ownerTag required" }
		end
		if #items > 500 then
			return { ok = false, error = string.format("batch too large: %d items (max 500) — split it up", #items) }
		end
		return safeCall(function()
			local map = workspace:FindFirstChild("ArtOfWarMap")
			local processed, errors, deltas = 0, {}, {}
			Editor.beginBatch(string.format("assignBatch -> %s", ownerTag))
			for i, item in ipairs(items) do
				if type(item) == "table" then
					if item.kind == "seed" and item.id ~= nil then
						local ok, err = pcall(Editor.assignProvince, item.id, ownerTag)
						if ok then
							processed += 1
							syncProvinceToWorld(item.id)
							table.insert(deltas, { kind = "province", key = item.id })
						else
							table.insert(errors, { id = item.id, error = tostring(err) })
						end
					elseif item.kind == "tile" and type(item.partName) == "string" then
						local ok, err = pcall(Editor.setTileOwner, item.partName, ownerTag)
						if ok then
							processed += 1
							if map then
								local main = map:FindFirstChild("Provinces")
								local part = main and main:FindFirstChild(item.partName)
								stampTileAttributes(part, ownerTag, item.partName, map)
							end
							table.insert(deltas, { kind = "tile", key = item.partName })
						else
							table.insert(errors, { partName = item.partName, error = tostring(err) })
						end
					end
				end
				if i % 100 == 0 then
					task.wait() -- yield so a max 500-item bulk apply can't monopolize a server frame
				end
			end
			Editor.endBatch()
			broadcastBatch(player, deltas)
			return { processed = processed, errors = errors, total = #items }
		end)
	elseif command == "save" then
		if Editor.isSingleServerMode and Editor.isSingleServerMode() then
			-- Single-server model: Save is a full snapshot of the one shared world to the :edit aggregates
			-- (no draft, no diff, no per-record merge). Full per-edit live sync is a later phase; for now we
			-- nudge other editors to re-sync on this save boundary (their client's reloadState re-fetches the
			-- shared world) and refresh stamping/adjacency for any tiles promoted during the snapshot.
			-- Blessed-server guard: only the one designated server may overwrite the shared :edit world.
			if not ensureWriteAuthority() then
				return {
					ok = false,
					mode = "datastore",
					message = "Read-only: this isn't the editing server. Reopen from the blessed private-server link.",
					error = "another server holds the editing session",
				}
			end
			local saveResult = safeCall(Editor.snapshotSave)
			local snapOk = saveResult.ok and saveResult.result ~= nil and saveResult.result.ok == true
			if snapOk then
				worldDirty = false
				local stamperMod = game.ServerScriptService.ArtOfWar.Systems:FindFirstChild("ProvinceStamper")
				if stamperMod then
					local stamperOk, stamper = pcall(require, stamperMod)
					if stamperOk and stamper then
						if stamper.refreshEU4Mappings then
							pcall(stamper.refreshEU4Mappings)
						end
						if stamper.applyTileOwnership then
							pcall(stamper.applyTileOwnership)
						end
					end
				end
				local adjMod = game.ServerScriptService.ArtOfWar.Systems:FindFirstChild("AdjacencyGraph")
				if adjMod then
					local adjOk, adj = pcall(require, adjMod)
					if adjOk and adj and adj.build then
						pcall(adj.build)
					end
				end
				for _, plr in ipairs(Players:GetPlayers()) do
					if plr ~= player and isAuthorized(plr) then
						LiveSync:FireClient(plr, {
							sharedMoved = true,
							originUserId = player.UserId,
							originName = player.DisplayName or player.Name,
						})
					end
				end
			end
			local res = saveResult.result or {}
			local writes = res.writes or 0
			local failures = res.failures or (snapOk and 0 or 1)
			local msg
			if snapOk then
				msg = string.format("Saved \u{2713} full snapshot (%d aggregates)", writes)
			else
				local errText = (res.errors and res.errors[1] and res.errors[1].error)
					or saveResult.error
					or "snapshot error"
				msg = "Save failed: " .. tostring(errText)
			end
			return {
				ok = snapOk,
				mode = "datastore",
				result = { mode = "datastore", writes = { failures = failures }, message = msg },
				writes = { failures = failures },
				message = msg,
				error = (not snapOk) and msg or nil,
			}
		end
		if STAGING_ENABLED then
			local draftResult = safeCall(Editor.saveDraft)
			local promoteResult = safeCall(Editor.promote, nil)
			if promoteResult.ok then
				for _, plr in ipairs(Players:GetPlayers()) do
					if plr ~= player and isAuthorized(plr) then
						LiveSync:FireClient(plr, {
							sharedMoved = true,
							originUserId = player.UserId,
							originName = player.DisplayName or player.Name,
							promoted = promoteResult.result and promoteResult.result.promoted or {},
						})
					end
				end
				local stamperMod = game.ServerScriptService.ArtOfWar.Systems:FindFirstChild("ProvinceStamper")
				if stamperMod then
					local stamperOk, stamper = pcall(require, stamperMod)
					if stamperOk and stamper then
						if stamper.refreshEU4Mappings then
							pcall(stamper.refreshEU4Mappings)
						end
						if stamper.applyTileOwnership then
							pcall(stamper.applyTileOwnership)
						end
					end
				end
				local promotedList = promoteResult.result and promoteResult.result.promoted or {}
				local synced = 0
				local provincesChanged = false
				for _, d in ipairs(promotedList) do
					if d.kind == "province" then
						pcall(syncProvinceToWorld, d.key)
						provincesChanged = true
					elseif d.kind == "country" then
						pcall(syncCountryToWorld, d.key)
					end
					synced += 1
					if synced % 200 == 0 then
						task.wait()
					end
				end
				-- Provinces were added/changed (e.g. painted tiles promoted to seeds): rebuild the
				-- land adjacency graph so the freshly stamped province_id parts become movement nodes
				-- this session, without waiting for a server restart.
				if provincesChanged then
					local adjMod = game.ServerScriptService.ArtOfWar.Systems:FindFirstChild("AdjacencyGraph")
					if adjMod then
						local adjOk, adj = pcall(require, adjMod)
						if adjOk and adj and adj.build then
							pcall(adj.build)
						end
					end
				end
			end
			local promoted = promoteResult.result and promoteResult.result.promoted or {}
			local flush = promoteResult.result and promoteResult.result.flush or {}
			return {
				ok = promoteResult.ok and (draftResult.ok ~= false),
				mode = "datastore",
				result = {
					mode = "datastore",
					promotedCount = #promoted,
					draftSaved = draftResult.ok ~= false,
					writes = { failures = flush.failures or 0 },
					message = promoteResult.ok and string.format(
						"Saved \u{2713} %d change%s published to the live map",
						#promoted,
						#promoted == 1 and "" or "s"
					) or ("Save failed: " .. tostring(promoteResult.error or "promote error")),
				},
				promotedCount = #promoted,
				draftSaved = draftResult.ok ~= false,
				writes = { failures = flush.failures or 0 },
				message = promoteResult.ok and string.format(
					"Saved \u{2713} %d change%s published to the live map",
					#promoted,
					#promoted == 1 and "" or "s"
				) or ("Save failed: " .. tostring(promoteResult.error or "promote error")),
				error = (not promoteResult.ok) and tostring(promoteResult.error or "promote error") or nil,
			}
		end
		if saveInProgress then
			local owner = saveOwnerUserId
			local label = owner and ("user " .. tostring(owner)) or "another mapper"
			return { ok = false, error = "save in progress (" .. label .. ") — wait a moment and try again" }
		end
		saveInProgress = true
		saveOwnerUserId = player.UserId
		local ok, result = pcall(safeCall, Editor.save)
		saveInProgress = false
		saveOwnerUserId = nil
		if not ok then
			return { ok = false, error = "save crashed: " .. tostring(result) }
		end
		local stamperMod = game.ServerScriptService.ArtOfWar.Systems:FindFirstChild("ProvinceStamper")
		if stamperMod then
			local stamperOk, stamper = pcall(require, stamperMod)
			if stamperOk and stamper then
				if stamper.refreshEU4Mappings then
					pcall(stamper.refreshEU4Mappings)
				end
				if stamper.applyTileOwnership then
					pcall(stamper.applyTileOwnership)
				end
			end
		end
		return result
	elseif command == "exportToLua" then
		return safeCall(Editor.exportToLua)
	elseif command == "dumpDataStore" then
		local force = type(payload) == "table" and payload.forceRefresh == true
		return safeCall(Editor.dumpDataStore, force)
	elseif command == "listConfigs" then
		return safeCall(Editor.listConfigs)
	elseif command == "saveConfig" then
		if type(payload) ~= "table" then
			return { ok = false, error = "payload required" }
		end
		-- Asymmetry is intentional: saveConfig + listConfigs are non-destructive (any authorized user),
		-- but loadConfig/deleteConfig replace or delete the live world and are gated to the owner below.
		return safeCall(Editor.saveConfig, payload.name)
	elseif command == "loadConfig" then
		if type(payload) ~= "table" then
			return { ok = false, error = "payload required" }
		end
		-- Loading a saved map is open to any authorized map editor (historian tier). With the editor/live
		-- split a load only replaces the EDITOR world (":edit"), never the live game, so it is
		-- non-destructive to players. (deleteConfig + Push to Live stay dev/manager-only.)
		-- Snapshot current ownership BEFORE the load swaps the editor state, so the live-refresh below
		-- only touches the tiles that actually change (a load otherwise only applies on the next boot).
		local beforeProv = {}
		do
			local st = Editor.getState()
			for id, rec in pairs((st and st.provinces) or {}) do
				beforeProv[id] = provinceOwnerKey(rec)
			end
		end
		local result = safeCall(Editor.loadConfig, payload.name)
		if result.ok ~= false then
			local refreshed = refreshLiveWorldAfterLoad(beforeProv)
			if type(result.result) == "table" then
				result.result.liveRefresh = refreshed
			end
			-- Co-editors on this server: their editor view + draft baseline are now stale vs the loaded
			-- world. Signal them (clients that listen can reload/re-baseline).
			for _, plr in ipairs(Players:GetPlayers()) do
				if plr ~= player and isAuthorized(plr) then
					LiveSync:FireClient(plr, {
						sharedMoved = true,
						originUserId = player.UserId,
						originName = player.DisplayName or player.Name,
						configLoaded = payload.name,
					})
				end
			end
		end
		return result
	elseif command == "deleteConfig" then
		if type(payload) ~= "table" then
			return { ok = false, error = "payload required" }
		end
		if not EditorAdmins.canManage(player) then
			return { ok = false, error = "only the owner can load/delete map configs" }
		end
		return safeCall(Editor.deleteConfig, payload.name)
	elseif command == "pushToLive" then
		-- Publish the editor's working world (":edit") to the live keys the main game reads. Owner-only,
		-- since it changes the live game. Editing/loading otherwise never touches live. Applies to the main
		-- game on its next server restart. Save (promote) your edits into the editor world first.
		if not EditorAdmins.canManage(player) then
			return { ok = false, error = "only the owner can push the map to the live game" }
		end
		local pushResult = safeCall(Editor.pushToLive)
		if not pushResult.ok then
			return { ok = false, error = "push failed: " .. tostring(pushResult.error) }
		end
		local pr = pushResult.result or {}
		local ok = (pr.ok ~= false) and ((pr.failures or 0) == 0)
		local msg
		if ok then
			msg = string.format(
				"Pushed to Live \u{2713} %d section%s published to the main game (applies on its next restart)",
				pr.writes or 0,
				(pr.writes == 1) and "" or "s"
			)
		else
			local firstErr = (pr.errors and pr.errors[1] and pr.errors[1].error) or "unknown error"
			msg = "Push to Live failed: " .. tostring(firstErr)
		end
		return {
			ok = ok,
			mode = "push",
			result = { mode = "push", writes = { failures = pr.failures or 0 }, message = msg },
			writes = { failures = pr.failures or 0 },
			message = msg,
			error = (not ok) and msg or nil,
		}
	elseif command == "listAccess" then
		-- Current players + each one's tier, plus the config-driven access model (managers/historians are set
		-- in the Creator Hub "data_editor_access" config — no republish). Any authorized user may view.
		return safeCall(function()
			local list = {}
			for _, plr in ipairs(Players:GetPlayers()) do
				list[#list + 1] = {
					userId = plr.UserId,
					name = plr.DisplayName or plr.Name,
					role = EditorAdmins.classify(plr),
					granted = EditorAdmins.isGranted(plr.UserId),
					manager = EditorAdmins.canManage(plr),
				}
			end
			return {
				canManage = EditorAdmins.canManage(player),
				players = list,
				access = EditorAdmins.getAccessInfo(),
			}
		end)
	elseif command == "grantAccess" then
		if type(payload) ~= "table" then
			return { ok = false, error = "payload required" }
		end
		if not EditorAdmins.canManage(player) then
			return { ok = false, error = "only the server owner can grant editor access" }
		end
		local uid = tonumber(payload.userId)
		if not uid then
			return { ok = false, error = "userId required" }
		end
		EditorAdmins.grant(uid)
		return { ok = true, result = { userId = uid } }
	elseif command == "revokeAccess" then
		if type(payload) ~= "table" then
			return { ok = false, error = "payload required" }
		end
		if not EditorAdmins.canManage(player) then
			return { ok = false, error = "only the server owner can revoke editor access" }
		end
		local uid = tonumber(payload.userId)
		if not uid then
			return { ok = false, error = "userId required" }
		end
		EditorAdmins.revoke(uid)
		return { ok = true, result = { userId = uid } }
	elseif command == "migrateLegacy" then
		-- Destructive DataStore-writing migration — manager-only, like its v4 siblings below.
		if not EditorAdmins.canManage(player) then
			return { ok = false, error = "only the owner can run the legacy migration" }
		end
		return safeCall(Editor.migrateLegacy)
	elseif command == "migrateV3toV4" then
		-- Schema-flipping store migration (v3 -> v4). Owner-only, like load/delete config. Never auto.
		if not EditorAdmins.canManage(player) then
			return { ok = false, error = "only the owner can run the v4 store migration" }
		end
		local commit = type(payload) == "table" and payload.commit == true
		return safeCall(Editor.migrateV3toV4, { commit = commit })
	elseif command == "rollbackV4" then
		if not EditorAdmins.canManage(player) then
			return { ok = false, error = "only the owner can roll back the v4 store migration" }
		end
		return safeCall(Editor.rollbackV4)
	elseif command == "importSeed" then
		if not EditorAdmins.canManage(player) then
			return { ok = false, error = "only the owner can import the first-boot seed" }
		end
		local force = type(payload) == "table" and payload.force == true
		return safeCall(Editor.importSeed, { force = force })
	elseif command == "undo" then
		if singleServerMode() then
			-- The undo/redo history is a single shared stack in single-server mode, so an undo pops whatever the
			-- most recent editor did (and a full-snapshot undo would roll the whole shared world back over other
			-- editors' unsaved edits). Disabled until per-user undo lands. See the plan doc.
			return {
				ok = false,
				error = "Undo isn't available in collaborative editing yet (the history is shared — an undo could revert another editor's work).",
			}
		end
		local result = safeCall(function()
			local ok, label = Editor.undo()
			return { ok = ok, label = label, depth = Editor.historyDepth(), redoDepth = Editor.redoDepth() }
		end)
		if result.ok and result.result and result.result.ok then
			local snap = safeCall(snapshotState)
			if snap.ok then
				snap.result.undoLabel = result.result.label
				snap.result.historyDepth = result.result.depth
				snap.result.redoDepth = result.result.redoDepth
				for _, plr in ipairs(Players:GetPlayers()) do
					if plr ~= player and isAuthorized(plr) then
						LiveSync:FireClient(plr, {
							reload = true,
							originUserId = player.UserId,
							originName = player.DisplayName or player.Name,
							reason = "undo",
						})
					end
				end
				return snap
			end
		end
		return result
	elseif command == "redo" then
		if singleServerMode() then
			return {
				ok = false,
				error = "Redo isn't available in collaborative editing yet (the history is shared across editors).",
			}
		end
		local result = safeCall(function()
			local ok, label = Editor.redo()
			return { ok = ok, label = label, depth = Editor.historyDepth(), redoDepth = Editor.redoDepth() }
		end)
		if result.ok and result.result and result.result.ok then
			local snap = safeCall(snapshotState)
			if snap.ok then
				snap.result.redoLabel = result.result.label
				snap.result.historyDepth = result.result.depth
				snap.result.redoDepth = result.result.redoDepth
				for _, plr in ipairs(Players:GetPlayers()) do
					if plr ~= player and isAuthorized(plr) then
						LiveSync:FireClient(plr, {
							reload = true,
							originUserId = player.UserId,
							originName = player.DisplayName or player.Name,
							reason = "redo",
						})
					end
				end
				return snap
			end
		end
		return result
	elseif command == "getDiff" then
		return safeCall(function()
			return { diff = Editor.diffAgainstBaseline(), historyDepth = Editor.historyDepth() }
		end)
	elseif command == "saveDraft" then
		if not STAGING_ENABLED then
			return { ok = false, error = "staging disabled" }
		end
		return safeCall(Editor.saveDraft)
	elseif command == "loadDraft" then
		if not STAGING_ENABLED then
			return { ok = false, error = "staging disabled" }
		end
		local result = safeCall(Editor.loadDraft)
		if result.ok then
			local snap = safeCall(snapshotState)
			if snap.ok then
				snap.result.draftMode = result.result and result.result.mode or "unknown"
				return snap
			end
		end
		return result
	elseif command == "discardDraft" then
		if not STAGING_ENABLED then
			return { ok = false, error = "staging disabled" }
		end
		local result = safeCall(Editor.discardDraft)
		if result.ok then
			local snap = safeCall(snapshotState)
			if snap.ok then
				return snap
			end
		end
		return result
	elseif command == "pullFromShared" then
		if not STAGING_ENABLED then
			return { ok = false, error = "staging disabled" }
		end
		local result = safeCall(Editor.pullFromShared)
		if result.ok then
			return safeCall(snapshotState)
		end
		return result
	elseif command == "computeDiffVsShared" then
		if not STAGING_ENABLED then
			return { ok = false, error = "staging disabled" }
		end
		return safeCall(Editor.computeDiffVsShared)
	elseif command == "promote" then
		if not STAGING_ENABLED then
			return { ok = false, error = "staging disabled" }
		end
		local selections = (type(payload) == "table" and payload.selections) or nil
		local result = safeCall(Editor.promote, selections)
		if result.ok then
			for _, plr in ipairs(Players:GetPlayers()) do
				if plr ~= player and isAuthorized(plr) then
					LiveSync:FireClient(plr, {
						sharedMoved = true,
						originUserId = player.UserId,
						originName = player.DisplayName or player.Name,
						promoted = result.result and result.result.promoted or {},
					})
				end
			end
		end
		return result
	elseif command == "auditMapping" then
		-- Read-only: validates the serial<->part bijection (the gate for the identity collapse).
		return safeCall(Editor.auditMapping)
	elseif command == "isStagingEnabled" then
		return { ok = true, result = { enabled = STAGING_ENABLED } }
	end
	return { ok = false, error = "unknown command: " .. tostring(command) }
end

-- Public entry point: serve read-only getLogs, run the command, then log successful WRITE-actions so the
-- Logs tab shows an audit trail. getLogs is handled here so it never logs itself.
api.OnServerInvoke = function(player, command, payload)
	if command == "getLogs" then
		if not isAuthorized(player) then
			return { ok = false, error = "not authorized" }
		end
		local limit = (type(payload) == "table" and tonumber(payload.limit)) or 300
		return { ok = true, logs = readLogs(limit), actions = LOG_ACTION_LIST }
	end
	-- Serialize the staging command path so concurrent editors' commands can't interleave through the shared
	-- module-global world swaps + DataStore yields (see withCommandLock). Reads go through it too -- they also
	-- run setActiveUser -- but they're fast, so the added latency is negligible.
	local result
	if STAGING_ENABLED then
		result = withCommandLock(function()
			return handleEditorCommand(player, command, payload)
		end)
	else
		result = handleEditorCommand(player, command, payload)
	end
	if LOG_ACTIONS[command] and type(result) == "table" and result.ok ~= false then
		appendLog(player, command, payload)
		if FLUSH_NOW_ACTIONS[command] then
			task.spawn(flushLogs)
		end
	end
	-- Single-server crash-safety: mark the shared world dirty after ANY successful mutating command (not just
	-- the LOG_ACTIONS-logged ones) so autosave / shutdown / last-editor-leaves persist it. Excludes read-only
	-- commands and `save` (which clears the flag on its own success). This is what covers setTileOwner / undo /
	-- redo, which mutate the shared world but are not in LOG_ACTIONS.
	if type(result) == "table" and result.ok ~= false and not READ_ONLY_COMMANDS[command] and command ~= "save" then
		worldDirty = true
	end
	return result
end

-- Periodically persist buffered log entries to the shared DataStore key, and on server shutdown.
task.spawn(function()
	while true do
		task.wait(LOG_FLUSH_INTERVAL)
		flushLogs()
	end
end)

-- Single-server crash-safety (Phase 5): the shared editor world lives only in this server's memory between
-- Saves, so autosave it on a timer (only when it changed) and snapshot on shutdown BEFORE the log flush so
-- world data wins the ~30s BindToClose budget. Both run only in single-server mode via maybeSnapshot's guards.
task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		if singleServerMode() and worldDirty then
			withCommandLock(function()
				maybeSnapshot("autosave")
			end)
		end
	end
end)

game:BindToClose(function()
	if singleServerMode() and worldDirty then
		-- Snapshot FIRST (world data outranks the audit log) and skip the command lock's 20s wait so the log
		-- flush still gets time inside the shared close budget.
		pcall(maybeSnapshot, "shutdown")
	end
	flushLogs()
end)

Editor.load()

-- Single-server blessed-server resolution (Phase 2): claim/refresh this server's write authority. Runs once at
-- boot (synchronously, so the blessed private server is writable immediately) then periodically, so a server can
-- take over a freed/stale crown without a restart and the blessed server keeps its heartbeat fresh.
if singleServerMode() and game.PrivateServerId ~= "" and EditorAdmins.isMapEditorPlace() then
	pcall(ensureWriteAuthority)
	task.spawn(function()
		while true do
			task.wait(BLESSED_REFRESH_INTERVAL)
			pcall(ensureWriteAuthority)
		end
	end)
end

local function countTable(t)
	local n = 0
	for _ in pairs(t) do
		n += 1
	end
	return n
end
local st = Editor.getState()
print(
	string.format(
		"[DataEditorService] ready — %d countries, %d provinces loaded",
		countTable(st.countries),
		countTable(st.provinces)
	)
)

local function adminSummary()
	local parts = { "Studio=always" }
	if game.CreatorType == Enum.CreatorType.User then
		table.insert(parts, string.format("creator-user=%d", game.CreatorId))
	end
	local allowCount = 0
	for _ in pairs(EditorAdmins.userIds) do
		allowCount += 1
	end
	table.insert(parts, string.format("devlist=%d", allowCount))
	local info = EditorAdmins.getAccessInfo()
	table.insert(
		parts,
		string.format(
			"config[%s]=%s (mgr=%d, hist=%d)",
			info.configKey,
			info.configAvailable and (info.configLoaded and "loaded" or "pending") or "unavailable",
			#info.managers,
			#info.historians
		)
	)
	return table.concat(parts, " | ")
end
print(string.format("[DataEditorService] auth policy: %s", adminSummary()))
