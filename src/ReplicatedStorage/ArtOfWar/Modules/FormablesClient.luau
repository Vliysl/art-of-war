-- FormablesClient (Phase 6): the client-side view of formable/releasable definitions -- the static
-- Data/Formables seed merged with the owner-authored custom ones replicated by FormableStore (a JSON
-- StringValue at ReplicatedStorage/ArtOfWar/FormablesRuntime). The Missions (formables) and Politics
-- (releasables) screens read through this so custom definitions show up in-game.

local FormablesClient = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local STATIC = require(aow:WaitForChild("Data"):WaitForChild("Formables"))
local FormableRules = require(aow:WaitForChild("Shared"):WaitForChild("FormableRules"))

local function runtimeValue()
	local sv = aow:FindFirstChild("FormablesRuntime")
	if not sv or sv.Value == nil or sv.Value == "" then
		return {}
	end
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(sv.Value)
	end)
	return (ok and type(decoded) == "table") and decoded or {}
end

-- Static seed overlaid with the replicated custom definitions (custom wins on tag collision).
function FormablesClient.getAll()
	local merged = table.clone(STATIC)
	for tag, def in pairs(runtimeValue()) do
		merged[tag] = def
	end
	return merged
end

-- Territory progress for a formable/releasable def, computed from the replicated cache. Returns
-- (held, total, need, ready): how many required provinces `tag` owns, how many exist, how many are needed
-- (min-count / percent / all -- shared with the server via FormableRules), and whether the threshold is met.
function FormablesClient.progress(cache, tag, def)
	local total = FormableRules.total(def)
	if not cache or not tag or total == 0 then
		return 0, total, FormableRules.threshold(def), false
	end
	local held = 0
	for _, id in ipairs(def.requiredProvinceIds) do
		local p = cache.getProvince(id)
		if p and p.ownerTag == tag then
			held += 1
		end
	end
	return held, total, FormableRules.threshold(def), FormableRules.ready(held, def)
end

-- Fire `fn` whenever the replicated custom set changes (formable authored/removed mid-session).
function FormablesClient.onChanged(fn)
	local sv = aow:WaitForChild("FormablesRuntime", 10)
	if sv then
		return sv:GetPropertyChangedSignal("Value"):Connect(fn)
	end
	return nil
end

return FormablesClient
