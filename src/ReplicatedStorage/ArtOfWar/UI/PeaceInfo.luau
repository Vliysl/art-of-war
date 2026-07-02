-- Shared peace-deal describer: turns a PeaceTerms record into human rows and reads the war standing.
-- Used by the incoming-offer popup (HudWiring -> PeaceTreaty) and the DiplomacyScreen pending rows so
-- both explain a deal the same way. Framing is role-aware: the same terms read as "gain" for the
-- proposer and "loss" for the recipient. `cache` is ClientStateCache (passed in, not required).
local PeaceInfo = {}

local function nameOf(cache, tag)
	local c = tag and cache.getCountry and cache.getCountry(tag)
	return (c and (c.displayName or c.name)) or tag or "?"
end

-- War score + exhaustion from myTag's point of view, or nil if the war isn't known to the client.
function PeaceInfo.warStanding(cache, warId, myTag)
	local w = warId and cache.getWar and cache.getWar(warId)
	if not w then
		return nil
	end
	local iAtt = w.attackerTag == myTag
	return {
		score = math.floor((iAtt and (w.score or 0) or -(w.score or 0)) + 0.5),
		me = math.floor((iAtt and w.attackerExhaustion or w.defenderExhaustion) or 0),
		them = math.floor((iAtt and w.defenderExhaustion or w.attackerExhaustion) or 0),
	}
end

-- Rows describing what `terms` mean for myTag. Each row: { icon, label, value, tone } where tone is
-- "loss" (myTag gives up), "gain" (myTag gets), or "neutral".
function PeaceInfo.describeTerms(cache, terms, fromTag, toTag, myTag)
	local kind = type(terms) == "table" and terms.type or nil
	local iAmProposer = myTag == fromTag
	local other = iAmProposer and toTag or fromTag
	local otherName = nameOf(cache, other)
	local rows = {}

	local function directional(gainLabel, gainVal, lossLabel, lossVal, icon)
		if iAmProposer then
			rows[#rows + 1] = { icon = icon, label = gainLabel, value = gainVal, tone = "gain" }
		else
			rows[#rows + 1] = { icon = icon, label = lossLabel, value = lossVal, tone = "loss" }
		end
	end

	if kind == "white_peace" then
		rows[1] = { icon = "Diplomacy", label = "White peace", value = "Status quo \u{2014} occupied land returns", tone = "neutral" }
	elseif kind == "annex_occupied" then
		-- One-directional on the server (applyTermsAnnexOccupied): the PROPOSER/winner annexes the
		-- recipient's provinces it occupies; the recipient cedes them. Occupations of the winner's own
		-- land just revert on peace, so only the viewer's role-relevant side is a real transfer.
		local count = 0
		for _, p in pairs(cache.allProvinces() or {}) do
			if iAmProposer then
				if p.ownerTag == other and p.controllerTag == myTag then
					count += 1
				end
			elseif p.ownerTag == myTag and p.controllerTag == other then
				count += 1
			end
		end
		local plural = count == 1 and "" or "s"
		if iAmProposer then
			rows[1] = { icon = "War", label = "Annex occupied land", value = string.format("%d province%s from %s", count, plural, otherName), tone = "gain" }
		else
			rows[1] = { icon = "War", label = "Cede occupied land", value = string.format("%d province%s to %s", count, plural, otherName), tone = "loss" }
		end
	elseif kind == "vassalize" then
		directional("Vassalize", otherName .. " becomes your subject", "Vassalized", "You become a subject of " .. otherName, "Diplomacy")
	elseif kind == "annex_all" then
		directional("Annex all", "Absorb " .. otherName .. " entirely", "Annexed", "Absorbed entirely by " .. otherName, "War")
	elseif kind == "conference" then
		for _, d in ipairs((type(terms) == "table" and terms.demands) or {}) do
			if d.type == "take_province" then
				local p = d.provinceId and cache.getProvince and cache.getProvince(d.provinceId)
				local nm = (p and (p.displayCityName or p.name)) or ("#" .. tostring(d.provinceId))
				directional("Take province", nm, "Cede province", nm, "War")
			elseif d.type == "annex_all" then
				directional("Annex all", "Absorb " .. otherName, "Annexed", "Absorbed by " .. otherName, "War")
			elseif d.type == "vassalize" then
				directional("Vassalize", otherName .. " becomes your subject", "Vassalized", "Become a subject of " .. otherName, "Diplomacy")
			end
		end
		if #rows == 0 then
			rows[1] = { icon = "Diplomacy", label = "Terms", value = "Negotiated peace", tone = "neutral" }
		end
	else
		rows[1] = { icon = "Diplomacy", label = "Terms", value = kind or "Negotiated peace", tone = "neutral" }
	end
	return rows
end

-- One-line " · "-joined summary of the term values, for compact rows.
function PeaceInfo.summarize(cache, terms, fromTag, toTag, myTag)
	local parts = {}
	for _, r in ipairs(PeaceInfo.describeTerms(cache, terms, fromTag, toTag, myTag)) do
		parts[#parts + 1] = r.value
	end
	return table.concat(parts, "  \u{00B7}  ")
end

return PeaceInfo
