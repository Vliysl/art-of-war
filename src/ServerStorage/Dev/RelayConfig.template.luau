-- RelayConfig.template.luau -- REFERENCE ONLY, not the live config.
--
-- The real RelayConfig is a gitignored, place-only ModuleScript (it lives in the .rbxl, not in git or
-- default.project.json) because DATASTORE_NAME / DATASTORE_SCOPE select which DataStore the LIVE world reads
-- and writes -- a wrong value would silently misdirect the game to the wrong or empty store. To boot a
-- from-scratch build (a fresh `rojo build`, CI, or a new/clean place), copy this file to Dev/RelayConfig.luau,
-- fill in the real values, and map it into the place as an instance named "RelayConfig".
--
-- This file deliberately keeps the instance name "RelayConfig.template" (NOT "RelayConfig") so it can never be
-- required in place of the real module, and `tools/publish.luau` can never overwrite the live place-only
-- RelayConfig with it. It is intentionally left out of default.project.json (Dev maps its children explicitly),
-- so Rojo never syncs it into Studio.

local RelayConfig = {}

RelayConfig.DATASTORE_NAME = "REPLACE_ME" -- the live world's DataStore name
RelayConfig.DATASTORE_SCOPE = "REPLACE_ME" -- the live world's DataStore scope

-- A human-readable label for logs (e.g. "prod", "experimental").
function RelayConfig.universeLabel()
	return "REPLACE_ME"
end

return RelayConfig
