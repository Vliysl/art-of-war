-- RecruitGate: the CLIENT-side mirror of RecruitSystem's Military-district recruit rule, so the recruit UIs
-- grey out exactly what the server would reject (RecruitSystem is the authoritative copy on the server).
--
-- Rule (economy rework, GateRecruitOnMilitary): a province may raise ONLY levy units (militia/irregular) unless
-- it has a built Military district. Professional (non-levy) units, and anything that explicitly requires a
-- Military district, are locked until one exists. When the flag is off, nothing is gated.
local WorldConstants = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("WorldConstants"))

local RecruitGate = {}

-- A province "has" a Military district when any slot holds a built (level >= 1) Military entry. Mirrors
-- RecruitSystem.provinceHasMilitaryDistrict; province.districts is on the replicated province record.
function RecruitGate.provinceHasMilitaryDistrict(province)
	local districts = province and province.districts
	if type(districts) ~= "table" then
		return false
	end
	for _, d in pairs(districts) do
		if type(d) == "table" and d.type == "Military" and (d.level or 0) >= 1 then
			return true
		end
	end
	return false
end

-- Does this unit require a Military district to recruit? Only when the gate flag is on. Mirrors the server's
-- `unit.requiresDistrict == "Military" or unit.class ~= "levy"`.
function RecruitGate.unitNeedsMilitaryDistrict(def)
	if not (def and WorldConstants.GateRecruitOnMilitary) then
		return false
	end
	return def.requiresDistrict == "Military" or def.class ~= "levy"
end

-- Convenience: is recruiting this unit in this province currently blocked by the Military-district gate?
function RecruitGate.isMilitaryLocked(def, province)
	return RecruitGate.unitNeedsMilitaryDistrict(def) and not RecruitGate.provinceHasMilitaryDistrict(province)
end

-- Order a recruit pool of { id, def } items: levy units (militia/irregular) FIRST — they're always
-- recruitable regardless of districts — then everything else, each group alphabetical by display name.
function RecruitGate.sortPool(pool)
	table.sort(pool, function(a, b)
		local aLevy = a.def.class == "levy"
		local bLevy = b.def.class == "levy"
		if aLevy ~= bLevy then
			return aLevy
		end
		return (a.def.displayName or a.id) < (b.def.displayName or b.id)
	end)
end

return RecruitGate
