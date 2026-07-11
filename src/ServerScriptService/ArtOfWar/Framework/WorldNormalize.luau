-- WorldNormalize — pure-Luau world-record normalization shared by BOTH runtimes:
--   · Roblox server: Framework/BakedWorld.luau applies it when loading baked world modules
--   · Lune CLI:      tools/export-world.luau applies it when baking DataStore aggregates to files
-- It exists so the baked-file pipeline can never drift from DataOverlay.applyTo's normalization:
-- the province-default rules below are a mirror of DataOverlay.applyTo (see the pointer comment
-- there). NO game APIs allowed in this file (no game/script/services) — Lune requires it by path.

local WorldNormalize = {}

function WorldNormalize.isTombstone(value)
	return type(value) == "table" and value.__deleted == true
end

-- Field-level merge of an overlay record onto a source record (mirror of DataOverlay.rawMerge):
-- overlay keys win, missing keys fall through to source, non-table overlay replaces wholesale.
function WorldNormalize.rawMerge(source, overlay)
	if type(overlay) ~= "table" then
		return overlay
	end
	local merged = {}
	if type(source) == "table" then
		for k, v in pairs(source) do
			merged[k] = v
		end
	end
	for k, v in pairs(overlay) do
		merged[k] = v
	end
	return merged
end

-- v4 province defaults (mirror of DataOverlay.applyTo): controllerTag follows owner, cores default
-- to the owner, homeland (defaultCores) defaults to cores, claims/releasableCores default empty.
-- Returns the record unchanged (same table) when nothing is missing; otherwise returns a filled clone.
function WorldNormalize.normalizeProvince(rec)
	if type(rec) ~= "table" then
		return rec
	end
	if
		rec.controllerTag ~= nil
		and rec.cores ~= nil
		and rec.claims ~= nil
		and rec.defaultCores ~= nil
		and rec.releasableCores ~= nil
	then
		return rec
	end
	local owner = rec.ownerTag
	local filled = table.clone(rec)
	if filled.controllerTag == nil then
		filled.controllerTag = owner
	end
	if filled.cores == nil then
		filled.cores = (owner and owner ~= "NONE") and { owner } or {}
	end
	if filled.claims == nil then
		filled.claims = {}
	end
	if filled.defaultCores == nil then
		filled.defaultCores = table.clone(filled.cores) -- homeland cores default to seed cores
	end
	if filled.releasableCores == nil then
		filled.releasableCores = {} -- breakaway cores default empty (distinct from homeland)
	end
	return filled
end

return WorldNormalize
