-- Pure shared rules for formable / releasable territory requirements, so the server (FormableSystem.canForm)
-- and the client (FormablesClient, the Formables screen, the Data Editor difficulty hint) all compute
-- eligibility and progress identically. No side effects, no service access -- safe to require anywhere.
--
-- A requirement is a threshold over `def.requiredProvinceIds`:
--   * `def.minProvinces`    -> hold at least N of them (clamped to the list size), or
--   * `def.percentRequired` -> hold at least that percentage of them (rounded up, min 1), or
--   * neither set           -> hold ALL of them (legacy / exact-list behaviour).

local FormableRules = {}

-- Total provinces named by the definition (0 for a malformed/empty def).
function FormableRules.total(def)
	return (def and def.requiredProvinceIds and #def.requiredProvinceIds) or 0
end

-- How many of the required provinces must be held to qualify. Never exceeds the list size.
function FormableRules.threshold(def)
	local total = FormableRules.total(def)
	if total == 0 then
		return 0
	end
	if type(def.minProvinces) == "number" and def.minProvinces > 0 then
		return math.min(math.floor(def.minProvinces), total)
	end
	if type(def.percentRequired) == "number" and def.percentRequired > 0 then
		local n = math.ceil(total * math.min(def.percentRequired, 100) / 100)
		return math.clamp(n, 1, total)
	end
	return total -- exact-all (legacy)
end

-- Is a given held-count sufficient to form/release this def? (a def with no provinces is never ready)
function FormableRules.ready(heldCount, def)
	local total = FormableRules.total(def)
	return total > 0 and heldCount >= FormableRules.threshold(def)
end

-- Short human-readable requirement label for editor/UI hints, e.g. "12 provinces", "8 of 20", "60% of 20".
function FormableRules.requirementLabel(def)
	local total = FormableRules.total(def)
	if total == 0 then
		return "no provinces set"
	end
	if type(def.minProvinces) == "number" and def.minProvinces > 0 then
		return string.format("%d of %d", math.min(math.floor(def.minProvinces), total), total)
	end
	if type(def.percentRequired) == "number" and def.percentRequired > 0 then
		return string.format("%d%% of %d", math.min(def.percentRequired, 100), total)
	end
	return string.format("%d provinces", total)
end

return FormableRules
