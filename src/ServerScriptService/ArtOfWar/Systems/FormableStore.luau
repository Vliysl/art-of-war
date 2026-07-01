-- FormableStore (Phase 6): persistence + replication for OWNER-AUTHORED custom formable/releasable
-- definitions (the static ones live in Data/Formables). Custom defs are:
--   * loaded from DataStore at boot and applied to FormableSystem (so FormNation/ReleaseNation see them),
--   * mirrored to a ReplicatedStorage StringValue (JSON) so the client (Missions/Politics + editor) can
--     list them, and
--   * written back to DataStore + FormableSystem + the StringValue whenever the owner edits one.
-- All DataStore access is pcall-wrapped so a store outage (or Studio without API access) degrades to
-- in-memory + replicated only, never breaking boot.

local FormableStore = {}

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local STORE_NAME = "AoW_Formables"
local STORE_SCOPE = "v4"
local KEY = "all"

local ctx
local custom = {} -- tag -> definition

-- Mirror the custom set to ReplicatedStorage/ArtOfWar/FormablesRuntime (JSON) for clients.
local function replicate()
	local aow = ReplicatedStorage:FindFirstChild("ArtOfWar")
	if not aow then
		return
	end
	local sv = aow:FindFirstChild("FormablesRuntime")
	if not sv then
		sv = Instance.new("StringValue")
		sv.Name = "FormablesRuntime"
		sv.Parent = aow
	end
	local ok, json = pcall(function()
		return HttpService:JSONEncode(custom)
	end)
	sv.Value = ok and json or "{}"
end

local function applyAll()
	if ctx.FormableSystem and ctx.FormableSystem.addDefinition then
		for tag, def in pairs(custom) do
			ctx.FormableSystem.addDefinition(tag, def)
		end
	end
end

local function persist()
	pcall(function()
		DataStoreService:GetDataStore(STORE_NAME, STORE_SCOPE):SetAsync(KEY, custom)
	end)
end

local function load()
	local ok, data = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME, STORE_SCOPE):GetAsync(KEY)
	end)
	if ok and type(data) == "table" then
		custom = data
	end
end

function FormableStore.register(context)
	ctx = context
	load()
	replicate()
	-- Apply after the register loop so FormableSystem is guaranteed registered (order-independent).
	task.defer(applyAll)

	context.FormableStore = {
		set = function(tag, def)
			if type(tag) ~= "string" or tag == "" or type(def) ~= "table" then
				return false, "bad_args"
			end
			custom[tag] = def
			if ctx.FormableSystem and ctx.FormableSystem.addDefinition then
				ctx.FormableSystem.addDefinition(tag, def)
			end
			replicate()
			persist()
			return true
		end,
		remove = function(tag)
			custom[tag] = nil
			if ctx.FormableSystem and ctx.FormableSystem.removeDefinition then
				ctx.FormableSystem.removeDefinition(tag)
			end
			replicate()
			persist()
			return true
		end,
		list = function()
			return custom
		end,
	}
end

return FormableStore
