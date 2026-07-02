local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")

local Editor = require(ServerStorage:WaitForChild("Dev"):WaitForChild("DataEditor"))
local EditorAdmins = require(ServerStorage:WaitForChild("Dev"):WaitForChild("EditorAdmins"))

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
		Editor.dropUserState(player.UserId)
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
			return false, string.format("country deletes are limited to one every 2.5 min — wait %ds", math.ceil(DELETE_COOLDOWN - (now - last)))
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
	if STAGING_ENABLED then
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
	if STAGING_ENABLED then
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
		countries = state.countries,
		provinces = state.provinces,
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

api.OnServerInvoke = function(player, command, payload)
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
				allowed = true,
				canManage = EditorAdmins.canManage(player),
				role = EditorAdmins.classify(player),
			},
		}
	end
	if payload ~= nil and not validatePayload(payload) then
		return { ok = false, error = "payload rejected" }
	end
	local allowed, rateErr = rateLimit(player, command)
	if not allowed then
		return { ok = false, error = rateErr }
	end

	if STAGING_ENABLED then
		pcall(Editor.setActiveUser, player.UserId)
	end

	if command == "loadState" then
		return safeCall(snapshotState)
	elseif command == "reloadState" then
		Editor.load()
		return safeCall(snapshotState)
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
				pcall(WorldState.deleteCountry, tag)
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
			for _, item in ipairs(items) do
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
			end
			Editor.endBatch()
			broadcastBatch(player, deltas)
			return { processed = processed, errors = errors, total = #items }
		end)
	elseif command == "save" then
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
		if not EditorAdmins.canManage(player) then
			return { ok = false, error = "only the owner can load/delete map configs" }
		end
		return safeCall(Editor.loadConfig, payload.name)
	elseif command == "deleteConfig" then
		if type(payload) ~= "table" then
			return { ok = false, error = "payload required" }
		end
		if not EditorAdmins.canManage(player) then
			return { ok = false, error = "only the owner can load/delete map configs" }
		end
		return safeCall(Editor.deleteConfig, payload.name)
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
						LiveSync:FireClient(
							plr,
							{
								reload = true,
								originUserId = player.UserId,
								originName = player.DisplayName or player.Name,
								reason = "undo",
							}
						)
					end
				end
				return snap
			end
		end
		return result
	elseif command == "redo" then
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
						LiveSync:FireClient(
							plr,
							{
								reload = true,
								originUserId = player.UserId,
								originName = player.DisplayName or player.Name,
								reason = "redo",
							}
						)
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

Editor.load()
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
