local DiplomacySystem = {}

local ctx
local nextWarSeq = 0
local nextProposalSeq = 0
local nextPactSeq = 0

-- Forward declarations: the player-consent gate inside endWar() calls offerPeaceToHuman, which calls
-- proposePeace / isClaimedTag -- all defined further down. Declared here so endWar can reference them;
-- they are ASSIGNED at their definition sites below (note `function isClaimedTag` / `function
-- proposePeace`, NOT `local function`, so they fill these upvalues).
local isClaimedTag
local proposePeace
local annexCountry -- full-annex helper (transfer all + delete); defined below, called by endWar's annex_all

local function generateWarId(a, b)
	nextWarSeq += 1
	return string.format("war_%s_%s_%d", a, b, nextWarSeq)
end

local function generateProposalId(a, b)
	nextProposalSeq += 1
	return string.format("peace_%s_%s_%d", a, b, nextProposalSeq)
end

local function generatePactId(a, b)
	nextPactSeq += 1
	return string.format("pact_%s_%s_%d", a, b, nextPactSeq)
end

local function now()
	return ctx.TickScheduler.getSimTime()
end

local function dayToSeconds(days)
	-- 1 game day == roughly DaysPerEarlyTick / SecondsPerSimTick. Treat as advisory.
	-- Simpler: use a fixed seconds-per-day scale tied to YearsPerRealSecond.
	local yearsPerSec = ctx.WorldConstants.YearsPerRealSecond or 0.05
	local secondsPerDay = 1 / (yearsPerSec * 365)
	return days * secondsPerDay
end

local function findActiveWar(tagA, tagB)
	if not tagA or not tagB or tagA == tagB then
		return nil
	end
	for _, war in ctx.WorldState.allWars() do
		if war.status == "active" then
			if
				(war.attackerTag == tagA and war.defenderTag == tagB)
				or (war.attackerTag == tagB and war.defenderTag == tagA)
			then
				return war
			end
		end
	end
	return nil
end

local function areAtWar(tagA, tagB)
	return findActiveWar(tagA, tagB) ~= nil
end

local function readTruce(country, otherTag)
	if not country or not country.truces then
		return nil
	end
	local ends = country.truces[otherTag]
	if not ends then
		return nil
	end
	if ends < now() then
		country.truces[otherTag] = nil
		ctx.WorldState.setCountry(country.tag, country)
		return nil
	end
	return ends
end

local function setTruce(tagA, tagB, durationSeconds)
	local ends = now() + durationSeconds
	local a = ctx.WorldState.getCountry(tagA)
	if a then
		a.truces = a.truces or {}
		a.truces[tagB] = ends
		ctx.WorldState.setCountry(tagA, a)
	end
	local b = ctx.WorldState.getCountry(tagB)
	if b then
		b.truces = b.truces or {}
		b.truces[tagA] = ends
		ctx.WorldState.setCountry(tagB, b)
	end
end

-- =====================================================================
-- OPINION (relations). Per-direction value stored on the country record
-- (country.opinion[otherTag]). Like truces it auto-replicates because the
-- whole country record is re-sent. Raised by Improve Relations, lowered by
-- war, decayed monthly toward a baseline from historical friends/rivals.
-- =====================================================================
local function containsTag(list, tag)
	if type(list) ~= "table" then
		return false
	end
	if list[tag] ~= nil then
		return true
	end
	for _, v in ipairs(list) do
		if v == tag then
			return true
		end
	end
	return false
end

local function opinionBaseline(country, otherTag)
	local C = ctx.WorldConstants
	if country then
		if containsTag(country.historicalFriends, otherTag) then
			return C.OpinionFriendBase or 50
		end
		if containsTag(country.historicalRivals, otherTag) then
			return C.OpinionRivalBase or -50
		end
	end
	return 0
end

local function getOpinion(tagA, tagB)
	local a = ctx.WorldState.getCountry(tagA)
	if a and a.opinion and a.opinion[tagB] ~= nil then
		return a.opinion[tagB]
	end
	return opinionBaseline(a, tagB)
end

local function addOpinion(tagA, tagB, delta)
	if not delta or delta == 0 then
		return
	end
	local a = ctx.WorldState.getCountry(tagA)
	if not a then
		return
	end
	local C = ctx.WorldConstants
	a.opinion = a.opinion or {}
	local cur = a.opinion[tagB]
	if cur == nil then
		cur = opinionBaseline(a, tagB)
	end
	a.opinion[tagB] = math.clamp(cur + delta, C.OpinionMin or -200, C.OpinionMax or 200)
	ctx.WorldState.setCountry(tagA, a)
end

local function improveRelations(fromTag, toTag)
	if not fromTag or not toTag or fromTag == toTag then
		return false, "bad_target"
	end
	if not ctx.WorldState.getCountry(fromTag) or not ctx.WorldState.getCountry(toTag) then
		return false, "unknown_country"
	end
	local C = ctx.WorldConstants
	local from = ctx.WorldState.getCountry(fromTag)
	local cooldownUntil = from.opinionCooldown and from.opinionCooldown[toTag]
	if cooldownUntil and cooldownUntil > now() then
		return false, "on_cooldown"
	end
	local cost = C.OpinionImproveCost or 25
	if
		not (
			ctx.PoliticalPower
			and ctx.PoliticalPower.spend
			and ctx.PoliticalPower.spend(fromTag, cost, "improve_relations")
		)
	then
		return false, "insufficient_pp"
	end
	-- Re-fetch: the PP spend mutated + persisted the country, so stamp the cooldown on the fresh copy.
	from = ctx.WorldState.getCountry(fromTag)
	from.opinionCooldown = from.opinionCooldown or {}
	from.opinionCooldown[toTag] = now() + dayToSeconds(C.OpinionImproveCooldownDays or 30)
	ctx.WorldState.setCountry(fromTag, from)
	local step = C.OpinionImproveStep or 25
	addOpinion(fromTag, toTag, step)
	addOpinion(toTag, fromTag, step)
	ctx.EventBus.publish(ctx.Channels.OpinionChanged, {
		fromTag = fromTag,
		toTag = toTag,
		opinion = getOpinion(fromTag, toTag),
		reason = "improve_relations",
	})
	return true
end

local function decayOpinionMonthly(months)
	local C = ctx.WorldConstants
	local step = (C.OpinionDecayPerMonth or 3) * months
	if step <= 0 then
		return
	end
	for tag, country in ctx.WorldState.allCountries() do
		if country.opinion then
			local changed = false
			for otherTag, value in country.opinion do
				local base = opinionBaseline(country, otherTag)
				if value > base then
					local nv = math.max(base, value - step)
					country.opinion[otherTag] = (nv == base) and nil or nv
					changed = true
				elseif value < base then
					local nv = math.min(base, value + step)
					country.opinion[otherTag] = (nv == base) and nil or nv
					changed = true
				end
			end
			if changed then
				ctx.WorldState.setCountry(tag, country)
			end
		end
	end
end

-- =====================================================================
-- NON-AGGRESSION PACTS (active state). Bilateral country.naps[other]=expiresAt,
-- mirroring truces (auto-replicates; lazy-expired on read). The pending OFFER
-- lives in the replicated `pacts` collection (handled further down).
-- =====================================================================
local function readNap(country, otherTag)
	if not country or not country.naps then
		return nil
	end
	local ends = country.naps[otherTag]
	if not ends then
		return nil
	end
	if ends < now() then
		country.naps[otherTag] = nil
		ctx.WorldState.setCountry(country.tag, country)
		return nil
	end
	return ends
end

local function setNap(tagA, tagB, durationSeconds)
	local ends = now() + durationSeconds
	local a = ctx.WorldState.getCountry(tagA)
	if a then
		a.naps = a.naps or {}
		a.naps[tagB] = ends
		ctx.WorldState.setCountry(tagA, a)
	end
	local b = ctx.WorldState.getCountry(tagB)
	if b then
		b.naps = b.naps or {}
		b.naps[tagA] = ends
		ctx.WorldState.setCountry(tagB, b)
	end
end

local function clearNap(tagA, tagB)
	local a = ctx.WorldState.getCountry(tagA)
	if a and a.naps and a.naps[tagB] then
		a.naps[tagB] = nil
		ctx.WorldState.setCountry(tagA, a)
	end
	local b = ctx.WorldState.getCountry(tagB)
	if b and b.naps and b.naps[tagA] then
		b.naps[tagA] = nil
		ctx.WorldState.setCountry(tagB, b)
	end
end

local function hasNap(tagA, tagB)
	local a = ctx.WorldState.getCountry(tagA)
	return readNap(a, tagB) ~= nil
end

-- =====================================================================
-- ALLIANCES (active state). Bilateral country.allies[other]=true (boolean, no
-- expiry; auto-replicates). Defined here so declareWar can gate on it; the
-- offer/accept lifecycle + call-to-arms live further down.
-- =====================================================================
local function areAllied(tagA, tagB)
	local a = ctx.WorldState.getCountry(tagA)
	return a ~= nil and a.allies ~= nil and a.allies[tagB] == true
end

local function setAlliance(tagA, tagB)
	local a = ctx.WorldState.getCountry(tagA)
	if a then
		a.allies = a.allies or {}
		a.allies[tagB] = true
		ctx.WorldState.setCountry(tagA, a)
	end
	local b = ctx.WorldState.getCountry(tagB)
	if b then
		b.allies = b.allies or {}
		b.allies[tagA] = true
		ctx.WorldState.setCountry(tagB, b)
	end
end

local function clearAlliance(tagA, tagB)
	local a = ctx.WorldState.getCountry(tagA)
	if a and a.allies and a.allies[tagB] then
		a.allies[tagB] = nil
		ctx.WorldState.setCountry(tagA, a)
	end
	local b = ctx.WorldState.getCountry(tagB)
	if b and b.allies and b.allies[tagA] then
		b.allies[tagA] = nil
		ctx.WorldState.setCountry(tagB, b)
	end
end

-- =====================================================================
-- SUBJECTS / VASSALS (active state). A subject has ONE overlord
-- (country.subjectOf=overlordTag); the overlord lists country.subjects[sub]=true.
-- Both auto-replicate. Defined here so declareWar/proposePeace can use them.
-- =====================================================================
local function overlordOf(tag)
	local c = ctx.WorldState.getCountry(tag)
	return c and c.subjectOf or nil
end

local function isSubject(tag)
	return overlordOf(tag) ~= nil
end

local function setSubject(overlordTag, subjectTag)
	if overlordTag == subjectTag then
		return
	end
	local s = ctx.WorldState.getCountry(subjectTag)
	if s then
		-- Transfer of subjugation: drop the previous overlord's claim before reassigning so a subject
		-- always has exactly one overlord (no dangling entry in the old overlord's subjects set).
		local prev = s.subjectOf
		if prev and prev ~= overlordTag then
			local po = ctx.WorldState.getCountry(prev)
			if po and po.subjects then
				po.subjects[subjectTag] = nil
				ctx.WorldState.setCountry(prev, po)
			end
		end
		s.subjectOf = overlordTag
		ctx.WorldState.setCountry(subjectTag, s)
	end
	local o = ctx.WorldState.getCountry(overlordTag)
	if o then
		o.subjects = o.subjects or {}
		o.subjects[subjectTag] = true
		ctx.WorldState.setCountry(overlordTag, o)
	end
end

local function clearSubject(overlordTag, subjectTag)
	local s = ctx.WorldState.getCountry(subjectTag)
	if s and s.subjectOf == overlordTag then
		s.subjectOf = nil
		ctx.WorldState.setCountry(subjectTag, s)
	end
	local o = ctx.WorldState.getCountry(overlordTag)
	if o and o.subjects then
		o.subjects[subjectTag] = nil
		ctx.WorldState.setCountry(overlordTag, o)
	end
end

local function declareWar(attackerTag, defenderTag)
	if not attackerTag or not defenderTag then
		return false, "missing_tag"
	end
	if attackerTag == defenderTag then
		return false, "self_war"
	end
	if not ctx.WorldState.getCountry(attackerTag) then
		return false, "unknown_attacker"
	end
	if not ctx.WorldState.getCountry(defenderTag) then
		return false, "unknown_defender"
	end
	if findActiveWar(attackerTag, defenderTag) then
		return false, "already_at_war"
	end
	local atkCountry = ctx.WorldState.getCountry(attackerTag)
	if readTruce(atkCountry, defenderTag) then
		return false, "truce_active"
	end
	if readNap(atkCountry, defenderTag) then
		return false, "nap_active"
	end
	if areAllied(attackerTag, defenderTag) then
		return false, "allied"
	end
	if isSubject(attackerTag) then
		return false, "is_subject"
	end

	local id = generateWarId(attackerTag, defenderTag)
	local war = {
		id = id,
		attackerTag = attackerTag,
		defenderTag = defenderTag,
		declaredAt = now(),
		status = "active",
		-- Phase 5b: war score (ATTACKER POV, -WarScoreMax..+WarScoreMax) + exhaustion.
		score = 0,
		attackerExhaustion = 0,
		defenderExhaustion = 0,
		-- Phase 3: a direct war is the root of its own conflict; co-belligerents share this id.
		conflictId = id,
		callReason = "direct",
		declaredMonthIndex = (function()
			local gd = ctx.TickScheduler.getGameDate and ctx.TickScheduler.getGameDate()
			return gd and (gd.year * 12 + (gd.month - 1)) or nil
		end)(),
	}
	ctx.WorldState.setWar(id, war)
	ctx.EventBus.publish(ctx.Channels.WarDeclared, {
		warId = id,
		attackerTag = attackerTag,
		defenderTag = defenderTag,
		declaredAt = war.declaredAt,
		conflictId = id,
		callReason = "direct",
	})
	local warPenalty = ctx.WorldConstants.OpinionWarPenalty or 50
	addOpinion(attackerTag, defenderTag, -warPenalty)
	addOpinion(defenderTag, attackerTag, -warPenalty)
	return true, id
end

local function cancelOutstandingProposalsBetween(fromTag, toTag)
	for _, proposal in ctx.WorldState.allPeaceProposals() do
		if proposal.status == "pending" and proposal.fromTag == fromTag and proposal.toTag == toTag then
			proposal.status = "cancelled"
			ctx.WorldState.setPeaceProposal(proposal.id, proposal)
		end
	end
end

local function expireOutstandingProposalsForWar(warId)
	for _, proposal in ctx.WorldState.allPeaceProposals() do
		if proposal.status == "pending" and proposal.warId == warId then
			proposal.status = "expired"
			ctx.WorldState.setPeaceProposal(proposal.id, proposal)
		end
	end
end

local function applyTermsWhitePeace(war)
	-- Revert all controllerTags between belligerents to ownerTags
	for id, province in ctx.WorldState.allProvinces() do
		if province.controllerTag ~= province.ownerTag then
			local controller = province.controllerTag
			local owner = province.ownerTag
			if
				(controller == war.attackerTag and owner == war.defenderTag)
				or (controller == war.defenderTag and owner == war.attackerTag)
			then
				if ctx.WorldConstants.RecordOwnershipChokepoint then
					ctx.WorldState.setProvinceOwnership(id, { controller = owner, reason = "white_peace" })
				else
					local oldController = controller
					province.controllerTag = owner
					ctx.WorldState.setProvince(id, province)
					ctx.EventBus.publish(ctx.Channels.ProvinceOccupied, {
						provinceId = id,
						newController = owner,
						oldController = oldController,
						ownerTag = owner,
					})
				end
			end
		end
	end
end

local function applyTermsAnnexOccupied(war, winnerTag, loserTag)
	-- Provinces where winnerTag controls but loserTag owns -> ownership flips to winnerTag.
	-- Iterate the winner's CONTROLLED provinces (O(controlled)) rather than scanning the whole world.
	local ids = {}
	if ctx.ProvinceRegistry and ctx.ProvinceRegistry.byController then
		for _, id in ipairs(ctx.ProvinceRegistry.byController(winnerTag)) do
			ids[#ids + 1] = id
		end
	else
		for id, province in ctx.WorldState.allProvinces() do
			if province.controllerTag == winnerTag and province.ownerTag == loserTag then
				ids[#ids + 1] = id
			end
		end
	end
	for _, id in ipairs(ids) do
		local province = ctx.WorldState.getProvince(id)
		if province and province.controllerTag == winnerTag and province.ownerTag == loserTag then
			if ctx.WorldConstants.RecordOwnershipChokepoint then
				ctx.WorldState.setProvinceOwnership(id, { owner = winnerTag, reason = "annex_occupied" })
			else
				province.ownerTag = winnerTag
				ctx.WorldState.setProvince(id, province)
				ctx.EventBus.publish(ctx.Channels.ProvinceOwnershipChanged, {
					provinceId = id,
					oldOwner = loserTag,
					newOwner = winnerTag,
				})
			end
		end
	end
end

local function endActiveBattlesBetween(tagA, tagB)
	if not ctx.BattleManager then
		return
	end
	local toEnd = {}
	for id, battle in ctx.WorldState.allBattles() do
		-- End if any attacker is tagA and any defender is tagB, or vice versa
		local relevant = false
		for _, armyId in battle.attackerArmyIds do
			local army = ctx.WorldState.getArmy(armyId)
			if army and (army.ownerTag == tagA or army.ownerTag == tagB) then
				relevant = true
				break
			end
		end
		if relevant then
			table.insert(toEnd, id)
		end
	end
	for _, id in toEnd do
		local b = ctx.WorldState.getBattle(id)
		if b then
			ctx.BattleManager.endBattle(b, nil, "draw_war_ended")
		end
	end
end

local function cancelStaleAttackMoves(tagA, tagB)
	if not ctx.MovementSystem then
		return
	end
	for armyId, army in ctx.WorldState.allArmies() do
		if army.movement then
			local target = ctx.WorldState.getProvince(army.movement.toProvinceId)
			if target then
				local toController = target.controllerTag
				if
					(army.ownerTag == tagA and toController == tagB)
					or (army.ownerTag == tagB and toController == tagA)
				then
					ctx.MovementSystem.cancelMovement(armyId, "war_ended")
				end
			end
		end
	end
end

-- Nearest province the owner currently CONTROLS, reachable from `fromId` over the land graph.
-- Plain BFS (no traversability gate): peace just concluded, so we only need a home anchor to
-- route toward -- beginMovePath re-applies the real traversability/war gating leg by leg.
local function nearestControlledProvince(ownerTag, fromId)
	local adj = ctx.AdjacencyGraph
	if not adj or not adj.getNeighbors then
		return nil
	end
	local visited = { [fromId] = true }
	local frontier = { fromId }
	while #frontier > 0 do
		local nextFrontier = {}
		for _, cur in ipairs(frontier) do
			for _, n in ipairs(adj.getNeighbors(cur)) do
				if not visited[n] then
					visited[n] = true
					local p = ctx.WorldState.getProvince(n)
					if p and p.controllerTag == ownerTag then
						return n
					end
					table.insert(nextFrontier, n)
				end
			end
		end
		frontier = nextFrontier
	end
	return nil
end

-- On peace, send each belligerent's armies that are standing on territory they do not control
-- back to their nearest controlled province. Idle/disengaged armies only (battles were already
-- ended above); if no home is reachable the army is left in place rather than stranded-disbanded.
local function returnTrespassers(tagA, tagB)
	if not ctx.MovementSystem or not ctx.MovementSystem.beginMovePath then
		return
	end
	for armyId, army in ctx.WorldState.allArmies() do
		if not army.battleId and not army.movement and (army.ownerTag == tagA or army.ownerTag == tagB) then
			local prov = ctx.WorldState.getProvince(army.provinceId)
			local controller = prov and prov.controllerTag
			if controller and controller ~= army.ownerTag and controller ~= "" and controller ~= "NONE" then
				local home = nearestControlledProvince(army.ownerTag, army.provinceId)
				if home then
					ctx.MovementSystem.beginMovePath(armyId, home)
				end
			end
		end
	end
end

-- A war with a human belligerent is NEVER concluded automatically -- the player must approve any peace
-- via the modal. These helpers + the endWar gate enforce that; AI-vs-AI peace is unaffected.
local function warHasHuman(war)
	-- humanBelligerent persists across a player disconnect. isClaimedTag only sees CONNECTED players,
	-- so without this flag a player who disconnects mid-war could be auto-peaced/annexed while away
	-- (the sim keeps resolving the war). The flag is stamped by stampHumanWars (each Diplomacy tick,
	-- while a belligerent is connected) and is never cleared.
	return war ~= nil
		and (war.humanBelligerent == true or isClaimedTag(war.attackerTag) or isClaimedTag(war.defenderTag))
end

-- Persist "this war involves a human" onto any active war that currently has a connected belligerent,
-- so the consent gate survives that player disconnecting. Bounded scan (active wars only); runs on the
-- Diplomacy tick. AI-vs-AI wars never get the flag, so they still auto-resolve.
local function stampHumanWars()
	for id, war in ctx.WorldState.allWars() do
		if war.status == "active" then
			-- Per-side sticky human flags (never cleared) so proposePeace can tell a DISCONNECTED human
			-- belligerent (whose nation must not be peaced/annexed behind their back -- B5) apart from a
			-- genuine AI. attackerHuman/defenderHuman persist across that side disconnecting, exactly like
			-- humanBelligerent does for the war as a whole.
			local dirty = false
			if not war.attackerHuman and isClaimedTag(war.attackerTag) then
				war.attackerHuman = true
				dirty = true
			end
			if not war.defenderHuman and isClaimedTag(war.defenderTag) then
				war.defenderHuman = true
				dirty = true
			end
			if not war.humanBelligerent and (war.attackerHuman or war.defenderHuman) then
				war.humanBelligerent = true
				dirty = true
			end
			if dirty then
				ctx.WorldState.setWar(id, war)
			end
		end
	end
end

-- True if `tag` is (or ever was) the human belligerent on its side of `war`. attackerHuman/defenderHuman are
-- stamped by stampHumanWars while that side is connected and never cleared, so this stays true after the
-- player disconnects -- letting the peace pipeline protect an offline human from having peace/annexation
-- concluded on their behalf (B5), where the connection-only isClaimedTag would treat them as AI.
local function isPersistentHumanSide(war, tag)
	if not war then
		return false
	end
	if tag == war.attackerTag then
		return war.attackerHuman == true or isClaimedTag(tag)
	elseif tag == war.defenderTag then
		return war.defenderHuman == true or isClaimedTag(tag)
	end
	return false
end

local function hasPendingProposalForWar(warId, toTag)
	for _, p in ctx.WorldState.allPeaceProposals() do
		if p and p.status == "pending" and p.warId == warId and p.toTag == toTag then
			return true
		end
	end
	return false
end

-- Convert an auto-peace that touches a human into a pending proposal they must accept/reject. The AI
-- offers its winning terms if it is the dictating winner, otherwise a white peace. If the HUMAN is the
-- one dictating terms (they are winning) we do NOT auto-conclude -- they keep control and end the war
-- through the normal flow. PvP (both human) is never auto-resolved.
local function offerPeaceToHuman(war, terms)
	local aHuman = isClaimedTag(war.attackerTag)
	local dHuman = isClaimedTag(war.defenderTag)
	if aHuman and dHuman then
		return
	end
	-- Flagged human-involved (warHasHuman) but NEITHER side is currently connected: the human is offline.
	-- HOLD the war (do not conclude, do not offer) -- proposePeace to an offline tag is treated as AI and
	-- would auto-accept, concluding the war behind the disconnected player's back. The war waits for them.
	if not aHuman and not dHuman then
		return
	end
	local human = aHuman and war.attackerTag or war.defenderTag
	local ai = aHuman and war.defenderTag or war.attackerTag
	local termType = terms and terms.type or "white_peace"
	local winner = terms and terms.proposerTag
	if (termType == "annex_occupied" or termType == "vassalize") and winner == human then
		return
	end
	if hasPendingProposalForWar(war.id, human) then
		return
	end
	-- Cooldown so a repeatedly-tripped forced peace (winning battle after battle at max war score) does
	-- not re-pop the modal on every event after the player rejects an offer.
	local cd = ctx.WorldConstants.PeaceProposalLifetimeSeconds or 60
	if war.autoPeaceOfferAt and (now() - war.autoPeaceOfferAt) < cd then
		return
	end
	war.autoPeaceOfferAt = now()
	ctx.WorldState.setWar(war.id, war)
	local offerTerms
	if (termType == "annex_occupied" or termType == "vassalize") and winner == ai then
		offerTerms = { type = termType }
	else
		offerTerms = { type = "white_peace" }
	end
	proposePeace(ai, human, offerTerms)
end

-- ============ Phase 3: war-score peace conference ============
-- A "conference" peace carries a list of demands; the proposer (winner) spends war score to enact them.
-- Costs are computed ONCE at proposal time (computeConferenceCost stamps demand.computedCost + totalCost)
-- and only RE-VALIDATED against the live score at apply -- never recomputed. Cores cost more; claims less.
local function provinceHasTag(list, tag)
	return list ~= nil and table.find(list, tag) ~= nil
end

-- The winner's war score in THEIR favour (war.score is attacker-POV).
local function scoreInFavour(war, winnerTag)
	local s = war.score or 0
	return (winnerTag == war.attackerTag) and s or -s
end

local function conferenceDemandCost(demand, winnerTag, loserTag)
	local C = ctx.WorldConstants
	local t = demand.type
	if t == "annex_all" then
		local n = (ctx.ProvinceRegistry and #ctx.ProvinceRegistry.byOwner(loserTag)) or 0
		return (C.PeaceAnnexBaseCost or 20) + n * (C.PeaceAnnexPerProvinceCost or 10)
	elseif t == "vassalize" then
		return C.PeaceVassalizeCost or 90
	elseif t == "take_province" then
		local p = ctx.WorldState.getProvince(demand.provinceId)
		if not p or p.ownerTag ~= loserTag then
			return math.huge
		end -- not the loser's -> not takeable
		local cost = C.PeaceTakeProvinceCost or 12
		-- Cores/claims only modify cost once the cores phase is enabled (mirrors hasClaimOn's gate), so the
		-- surcharge/discount stay inert -- and match the client preview -- while EnableCores is off.
		if C.EnableCores then
			if provinceHasTag(p.cores, loserTag) then
				cost *= (C.PeaceCoreMultiplier or 1.5)
			end
			if provinceHasTag(p.claims, winnerTag) then
				cost *= (C.PeaceClaimCostDiscount or 0.7)
			end
		end
		return cost
	end
	return math.huge -- unknown demand type
end

-- Stamp each demand's cost + the total onto the terms (called at proposal time). Returns the total.
local function computeConferenceCost(terms, winnerTag, loserTag)
	local total = 0
	for _, d in ipairs(terms.demands or {}) do
		local c = conferenceDemandCost(d, winnerTag, loserTag)
		d.computedCost = c
		total += c
	end
	terms.totalCost = total
	return total
end

-- Take a single province in a conference (owner + controller -> winner).
local function takeConferenceProvince(winnerTag, loserTag, provinceId)
	local p = ctx.WorldState.getProvince(provinceId)
	if not p or p.ownerTag ~= loserTag then
		warn(
			string.format(
				"[Diplomacy] takeConferenceProvince skipped: province %s no longer owned by %s",
				tostring(provinceId),
				tostring(loserTag)
			)
		)
		return
	end
	if ctx.WorldConstants.RecordOwnershipChokepoint then
		-- Only take the controller if the loser still occupies it (else an enemy occupier keeps it).
		local controller = (p.controllerTag == loserTag) and winnerTag or nil
		ctx.WorldState.setProvinceOwnership(
			provinceId,
			{ owner = winnerTag, controller = controller, reason = "conference" }
		)
	else
		p.ownerTag = winnerTag
		if p.controllerTag == loserTag then
			p.controllerTag = winnerTag
		end
		ctx.WorldState.setProvince(provinceId, p)
		ctx.EventBus.publish(ctx.Channels.ProvinceOwnershipChanged, {
			provinceId = provinceId,
			oldOwner = loserTag,
			newOwner = winnerTag,
		})
	end
end

-- Apply a conference's demands, re-validating the STORED total vs the live score (no recompute).
-- annexCountry/isClaimedTag are forward-declared upvalues; setSubject/applyTermsAnnexOccupied are above.
local function applyConference(war, winnerTag, loserTag, terms, warId)
	if (terms.totalCost or 0) > scoreInFavour(war, winnerTag) + 1e-6 then
		return false
	end
	for _, d in ipairs(terms.demands or {}) do
		-- Re-derive each demand's cost against the LIVE state (province may have changed hands, the loser
		-- may have shrunk) and skip any that are now impossible/unaffordable, rather than applying blindly
		-- off the stale stamped cost. Unknown/ineligible demands return math.huge from conferenceDemandCost.
		local liveCost = conferenceDemandCost(d, winnerTag, loserTag)
		if liveCost == math.huge then
			warn(
				string.format(
					"[Diplomacy] applyConference skipped demand '%s' (live cost is impossible)",
					tostring(d.type)
				)
			)
		elseif d.type == "annex_all" then
			if ctx.WorldConstants.EnableFullAnnex and not isPersistentHumanSide(war, loserTag) then
				annexCountry(winnerTag, loserTag, warId)
			else
				applyTermsAnnexOccupied(war, winnerTag, loserTag)
			end
		elseif d.type == "vassalize" then
			setSubject(winnerTag, loserTag)
		elseif d.type == "take_province" then
			takeConferenceProvince(winnerTag, loserTag, d.provinceId)
		end
	end
	-- Zombie cleanup: an AI loser reduced to 0 provinces (and not already deleted) is removed.
	if
		ctx.WorldConstants.EnableFullAnnex
		and not isPersistentHumanSide(war, loserTag)
		and ctx.WorldState.getCountry(loserTag)
		and ctx.ProvinceRegistry
		and #ctx.ProvinceRegistry.byOwner(loserTag) == 0
	then
		annexCountry(winnerTag, loserTag, warId)
	end
	return true
end

local function endWar(warId, terms, opts)
	local war = ctx.WorldState.getWar(warId)
	if not war or war.status ~= "active" then
		return false, "war_not_active"
	end

	-- Player-consent gate (see helpers above): unless this is an explicit player decision
	-- (opts.consented -- set by acceptPeace, or by the AI accepting the player's OWN offer), a war with
	-- a human belligerent is converted into a pending peace proposal instead of being concluded here, so
	-- the AI can never force or accept peace on the player's behalf.
	if not (opts and opts.consented) and warHasHuman(war) then
		offerPeaceToHuman(war, terms)
		return false, "requires_player_consent"
	end

	-- 1) End active battles between belligerents (suppresses controller flips)
	endActiveBattlesBetween(war.attackerTag, war.defenderTag)

	-- 2) Apply terms
	local termType = terms and terms.type or "white_peace"
	if termType == "white_peace" then
		applyTermsWhitePeace(war)
	elseif termType == "annex_occupied" then
		-- The proposer (terms.proposerTag) is the winner of the annex
		local winner = terms.proposerTag or war.attackerTag
		local loser = (winner == war.attackerTag) and war.defenderTag or war.attackerTag
		applyTermsAnnexOccupied(war, winner, loser)
		-- Zombie cleanup: an AI loser reduced to 0 owned provinces is deleted outright, so it can't
		-- linger owning un-occupied land (the old bug). Humans are never auto-deleted.
		if
			ctx.WorldConstants.EnableFullAnnex
			and not isPersistentHumanSide(war, loser)
			and ctx.ProvinceRegistry
			and #ctx.ProvinceRegistry.byOwner(loser) == 0
		then
			annexCountry(winner, loser, warId)
		end
	elseif termType == "annex_all" then
		-- Full annexation: take ALL the loser's provinces + delete it. Gated by EnableFullAnnex; a human
		-- loser is never deleted (fall back to taking only occupied land).
		local winner = terms.proposerTag or war.attackerTag
		local loser = (winner == war.attackerTag) and war.defenderTag or war.attackerTag
		if ctx.WorldConstants.EnableFullAnnex and not isPersistentHumanSide(war, loser) then
			annexCountry(winner, loser, warId)
		else
			applyTermsAnnexOccupied(war, winner, loser)
		end
	elseif termType == "conference" then
		-- Phase 3: spend war score on a basket of demands (take provinces / annex_all / vassalize).
		local winner = terms.proposerTag or war.attackerTag
		local loser = (winner == war.attackerTag) and war.defenderTag or war.attackerTag
		if ctx.WorldConstants.EnablePeaceConference then
			applyConference(war, winner, loser, terms, warId)
		end
	elseif termType == "vassalize" then
		-- The proposer (winner) makes the loser its subject.
		local winner = terms.proposerTag or war.attackerTag
		local loser = (winner == war.attackerTag) and war.defenderTag or war.attackerTag
		setSubject(winner, loser)
	end

	-- 3) Cancel in-flight attack moves
	cancelStaleAttackMoves(war.attackerTag, war.defenderTag)

	-- 3b) March trespassing armies home (control was finalized by the terms above, so this
	-- sees the post-peace map). Runs after the cancel so freshly-idled armies are picked up.
	returnTrespassers(war.attackerTag, war.defenderTag)

	-- 4) Mark war ended
	war.status = "ended"
	war.endedAt = now()
	war.peaceTermsApplied = terms
	ctx.WorldState.setWar(warId, war)

	-- 5) Set truce on both sides
	local truceSeconds = dayToSeconds(ctx.WorldConstants.TrucePeriodDays or 1825)
	setTruce(war.attackerTag, war.defenderTag, truceSeconds)

	-- 6) Expire any remaining proposals for this war
	expireOutstandingProposalsForWar(warId)

	-- 7) Publish PeaceConcluded
	ctx.EventBus.publish(ctx.Channels.PeaceConcluded, {
		warId = warId,
		attackerTag = war.attackerTag,
		defenderTag = war.defenderTag,
		peaceTerms = terms,
		endedAt = war.endedAt,
	})

	return true
end

function isClaimedTag(tag) -- fills the forward-declared upvalue (do NOT add `local`)
	return ctx.PlayerAuthority ~= nil
		and ctx.PlayerAuthority.playerFor ~= nil
		and ctx.PlayerAuthority.playerFor(tag) ~= nil
end

local function occupiedProvinceCount(occupierTag, ownerTag)
	local count = 0
	for _, province in ctx.WorldState.allProvinces() do
		if province.controllerTag == occupierTag and province.ownerTag == ownerTag then
			count += 1
		end
	end
	return count
end

-- =====================================================================
-- Phase 5b: WAR SCORE / EXHAUSTION / PEACE THRESHOLDS (spec B.9 / G.4-G.5).
-- war.score is ATTACKER POV. Accrued from BattleResolved + ProvinceOccupied
-- (canonical BattleManager channel). Legacy NavalBattleResolved is intentionally
-- NOT scored here to avoid double-counting until Phase 6 removes the legacy naval
-- combat engine; unified naval battles already publish BattleResolved.
-- =====================================================================
local function clampScore(s)
	local mx = ctx.WorldConstants.WarScoreMax or 100
	return math.clamp(s, -mx, mx)
end

local function clampExhaustion(e)
	return math.clamp(e, 0, ctx.WorldConstants.WarExhaustionMax or 100)
end

-- Decisive-victory auto-end at +/-WarScoreForcedPeace (winner dictates terms).
local function forcePeace(war, winnerTag)
	if not war or war.status ~= "active" then
		return
	end
	local loserTag = (winnerTag == war.attackerTag) and war.defenderTag or war.attackerTag
	local terms
	if occupiedProvinceCount(winnerTag, loserTag) > 0 then
		terms = { type = "annex_occupied", proposerTag = winnerTag, forced = true }
	else
		terms = { type = "white_peace", forced = true }
	end
	endWar(war.id, terms)
end

local function checkForcedPeace(war)
	if not war or war.status ~= "active" then
		return
	end
	local threshold = ctx.WorldConstants.WarScoreForcedPeace or 100
	local s = war.score or 0
	if s >= threshold then
		forcePeace(war, war.attackerTag)
	elseif s <= -threshold then
		forcePeace(war, war.defenderTag)
	end
end

-- Detect a naval battle from a resolved-battle payload (any surviving naval formation).
local function battlePayloadIsNaval(payload)
	local function anyNaval(ids)
		if not ids then
			return false
		end
		for _, aid in ipairs(ids) do
			local a = ctx.WorldState.getArmy(aid)
			if a and a.domain == "naval" then
				return true
			end
		end
		return false
	end
	return anyNaval(payload.attackerArmyIds) or anyNaval(payload.defenderArmyIds)
end

-- Shared by land (onBattleResolved) and naval (onNavalBattleResolved) war-score accrual.
local function applyBattleScore(war, winnerTag, loserTag, delta)
	local C = ctx.WorldConstants
	if winnerTag == war.attackerTag then
		war.score = clampScore((war.score or 0) + delta)
	elseif winnerTag == war.defenderTag then
		war.score = clampScore((war.score or 0) - delta)
	end
	local exLoss = C.WarExhaustionPerBattleLost or 0.5
	if loserTag == war.attackerTag then
		war.attackerExhaustion = clampExhaustion((war.attackerExhaustion or 0) + exLoss)
	elseif loserTag == war.defenderTag then
		war.defenderExhaustion = clampExhaustion((war.defenderExhaustion or 0) + exLoss)
	end
	ctx.WorldState.setWar(war.id, war)
	checkForcedPeace(war)
end

local function onBattleResolved(payload)
	if not payload then
		return
	end
	local winnerTag, loserTag = payload.winnerTag, payload.loserTag
	if not winnerTag or not loserTag then
		return
	end -- draw / war-end teardown
	local war = (payload.warId and ctx.WorldState.getWar(payload.warId)) or findActiveWar(winnerTag, loserTag)
	if not war or war.status ~= "active" then
		return
	end
	local C = ctx.WorldConstants
	local delta = battlePayloadIsNaval(payload) and (C.WarScoreNavalWin or 8) or (C.WarScoreBattleWin or 5)
	applyBattleScore(war, winnerTag, loserTag, delta)
end

-- Phase 6: naval battles share the war-score model. NavalBattleResolved carries
-- attackerTag/defenderTag (fleet owners) + winner in {attacker,defender,mutual}.
local function onNavalBattleResolved(payload)
	if not payload then
		return
	end
	local winner = payload.winner
	if winner ~= "attacker" and winner ~= "defender" then
		return
	end -- skip mutual/unknown
	local aTag, dTag = payload.attackerTag, payload.defenderTag
	if not aTag or not dTag then
		return
	end
	local war = findActiveWar(aTag, dTag)
	if not war or war.status ~= "active" then
		return
	end
	local winnerTag = (winner == "attacker") and aTag or dTag
	local loserTag = (winner == "attacker") and dTag or aTag
	applyBattleScore(war, winnerTag, loserTag, ctx.WorldConstants.WarScoreNavalWin or 8)
end

local function onProvinceOccupied(payload)
	if not payload then
		return
	end
	local newController, ownerTag = payload.newController, payload.ownerTag
	-- Skip peace-deal reversions (province returned to owner); only score hostile takes.
	if not newController or not ownerTag or newController == ownerTag then
		return
	end
	local war = findActiveWar(newController, ownerTag)
	if not war or war.status ~= "active" then
		return
	end
	local C = ctx.WorldConstants
	local delta = C.WarScoreOccupyProvince or 8
	if newController == war.attackerTag and ownerTag == war.defenderTag then
		war.score = clampScore((war.score or 0) + delta)
	elseif newController == war.defenderTag and ownerTag == war.attackerTag then
		war.score = clampScore((war.score or 0) - delta)
	else
		return -- occupation not between this war's belligerent pair
	end
	local exLoss = C.WarExhaustionPerProvinceLost or 1.0
	if ownerTag == war.attackerTag then
		war.attackerExhaustion = clampExhaustion((war.attackerExhaustion or 0) + exLoss)
	elseif ownerTag == war.defenderTag then
		war.defenderExhaustion = clampExhaustion((war.defenderExhaustion or 0) + exLoss)
	end
	ctx.WorldState.setWar(war.id, war)
	checkForcedPeace(war)
end

-- AI peace acceptance: willingness (losing position + exhaustion) vs term war-score cost.
local function aiWouldAccept(war, fromTag, toTag, terms)
	local C = ctx.WorldConstants
	local attackerPOV = war.score or 0
	local recipientScore = (toTag == war.attackerTag) and attackerPOV or -attackerPOV
	local recipientExhaustion = (toTag == war.attackerTag) and (war.attackerExhaustion or 0)
		or (war.defenderExhaustion or 0)
	local willingness = -recipientScore + recipientExhaustion * (C.PeaceAIExhaustionWeight or 0.5)
	local cost
	if terms.type == "annex_occupied" then
		local n = occupiedProvinceCount(fromTag, toTag)
		cost = (C.PeaceAnnexBaseCost or 20) + n * (C.PeaceAnnexPerProvinceCost or 10)
	elseif terms.type == "annex_all" then
		local n = (ctx.ProvinceRegistry and #ctx.ProvinceRegistry.byOwner(toTag)) or 0
		cost = (C.PeaceAnnexBaseCost or 20) + n * (C.PeaceAnnexPerProvinceCost or 10)
	elseif terms.type == "vassalize" then
		cost = C.PeaceVassalizeCost or 90
	elseif terms.type == "conference" then
		cost = terms.totalCost or 0
	else
		cost = C.PeaceWhitePeaceCost or 0
	end
	return (willingness - cost) >= (C.PeaceAIAcceptMargin or 0)
end

-- Monthly: both sides gain base exhaustion; mandatory white peace after a long stalemate.
local lastDiplomacyMonth = nil
local function accrueMonthlyAndResolve(currentMonthIndex, months)
	local C = ctx.WorldConstants
	decayOpinionMonthly(months)
	local base = (C.WarExhaustionMonthlyBase or 0.05) * months
	local stalemateMonths = (C.WarStalemateYears or 5) * 12
	local ids = {}
	for id, war in ctx.WorldState.allWars() do
		if war.status == "active" then
			table.insert(ids, id)
		end
	end
	for _, id in ipairs(ids) do
		local war = ctx.WorldState.getWar(id)
		if war and war.status == "active" then
			war.attackerExhaustion = clampExhaustion((war.attackerExhaustion or 0) + base)
			war.defenderExhaustion = clampExhaustion((war.defenderExhaustion or 0) + base)
			ctx.WorldState.setWar(id, war)
			if war.declaredMonthIndex and (currentMonthIndex - war.declaredMonthIndex) >= stalemateMonths then
				endWar(id, { type = "white_peace", forced = true, reason = "stalemate" })
			else
				checkForcedPeace(war)
			end
		end
	end
end

-- A nation that can no longer resist -- no armies left AND it controls none of its own territory --
-- has been knocked out, so it must accept whatever the victor offers (human or AI alike). Occupation
-- flips controllerTag, NOT ownerTag, so a nation whose entire homeland is occupied still "owns" that
-- land but controls none of it: that counts as capitulated too (the France-occupies-Lorraine gap --
-- the old check only looked at ownership, so an occupied-but-un-annexed nation could still refuse).
local function isFullyCapitulated(tag)
	-- Any surviving army anywhere means it can still fight.
	if ctx.ArmySystem and ctx.ArmySystem.armiesOfOwner then
		if #ctx.ArmySystem.armiesOfOwner(tag) > 0 then
			return false
		end
	else
		for _, army in ctx.WorldState.allArmies() do
			if army.ownerTag == tag then
				return false
			end
		end
	end
	-- Holds (controls) any province it owns -> still has a homeland base to resist from. controllerTag
	-- nil defaults to the owner, so guard for that.
	if ctx.ProvinceRegistry and ctx.ProvinceRegistry.byOwner then
		for _, id in ipairs(ctx.ProvinceRegistry.byOwner(tag)) do
			local prov = ctx.WorldState.getProvince(id)
			if prov and (prov.controllerTag or prov.ownerTag) == tag then
				return false
			end
		end
	else
		for _, prov in ctx.WorldState.allProvinces() do
			if prov.ownerTag == tag and (prov.controllerTag or prov.ownerTag) == tag then
				return false
			end
		end
	end
	return true
end

function proposePeace(fromTag, toTag, terms) -- fills the forward-declared upvalue (do NOT add local)
	if not fromTag or not toTag then
		return false, nil, "missing_tag"
	end
	local war = findActiveWar(fromTag, toTag)
	if not war then
		return false, nil, "no_war"
	end
	terms = terms or { type = "white_peace" }
	if
		terms.type ~= "white_peace"
		and terms.type ~= "annex_occupied"
		and terms.type ~= "vassalize"
		and terms.type ~= "annex_all"
		and terms.type ~= "conference"
	then
		return false, nil, "bad_terms"
	end
	-- Stamp proposer for annex resolution
	terms.proposerTag = fromTag

	-- Phase 3 conference: compute + stamp demand costs now; reject if the proposer can't afford them or
	-- the feature is disabled. (Costs are re-validated, not recomputed, at apply.)
	if terms.type == "conference" then
		if not ctx.WorldConstants.EnablePeaceConference then
			return false, nil, "bad_terms"
		end
		local cost = computeConferenceCost(terms, fromTag, toTag)
		if cost > scoreInFavour(war, fromTag) + 1e-6 then
			return false, nil, "insufficient_war_score"
		end
	end

	cancelOutstandingProposalsBetween(fromTag, toTag)

	local id = generateProposalId(fromTag, toTag)
	local lifetime = ctx.WorldConstants.PeaceProposalLifetimeSeconds or 60
	local proposal = {
		id = id,
		warId = war.id,
		fromTag = fromTag,
		toTag = toTag,
		terms = terms,
		proposedAt = now(),
		expiresAt = now() + lifetime,
		status = "pending",
	}
	ctx.WorldState.setPeaceProposal(id, proposal)
	ctx.EventBus.publish(ctx.Channels.PeaceProposed, {
		proposalId = id,
		warId = war.id,
		fromTag = fromTag,
		toTag = toTag,
		terms = terms,
		expiresAt = proposal.expiresAt,
	})

	-- B5: never auto-conclude a proposal to a persistent human who is currently disconnected -- hold it
	-- pending (exactly like a connected human) so their nation can't be peaced or annexed behind their back.
	local recipientOfflineHuman = isPersistentHumanSide(war, toTag) and not isClaimedTag(toTag)

	-- B8: the full-capitulation override only applies to a proposer that actually did the beating -- holds
	-- positive war score in this war, or occupies at least one of the target's provinces -- so a third party
	-- can't declare war on an already-ground-down nation and instantly annex it ("capitulation sniping").
	local proposerEarnedCapitulation = scoreInFavour(war, fromTag) > 0 or occupiedProvinceCount(fromTag, toTag) > 0

	-- Full capitulation overrides the usual accept/reject path (AI willingness OR a human's
	-- modal): a nation with nothing left surrenders on any terms the victor proposes.
	if isFullyCapitulated(toTag) and proposerEarnedCapitulation and not recipientOfflineHuman then
		proposal.status = "accepted"
		ctx.WorldState.setPeaceProposal(id, proposal)
		endWar(war.id, terms, { consented = true })
		return true, id
	end

	if not isClaimedTag(toTag) and not recipientOfflineHuman then
		if terms.type == "annex_occupied" and occupiedProvinceCount(fromTag, toTag) <= 0 then
			proposal.status = "rejected"
			ctx.WorldState.setPeaceProposal(id, proposal)
			ctx.EventBus.publish(ctx.Channels.PeaceProposalRejected, {
				proposalId = id,
				warId = war.id,
				fromTag = fromTag,
				toTag = toTag,
				reason = "nothing_to_annex",
			})
			return false, id, "nothing_to_annex"
		end
		-- Phase 5b: AI accepts only if war score + exhaustion justify the terms' cost.
		if aiWouldAccept(war, fromTag, toTag, terms) then
			proposal.status = "accepted"
			ctx.WorldState.setPeaceProposal(id, proposal)
			-- The recipient is an AI (this branch only runs when not isClaimedTag(toTag)); the offer was
			-- made BY fromTag (a player proposing, or AI-vs-AI), so concluding here is consensual.
			endWar(war.id, terms, { consented = true })
		else
			proposal.status = "rejected"
			ctx.WorldState.setPeaceProposal(id, proposal)
			ctx.EventBus.publish(ctx.Channels.PeaceProposalRejected, {
				proposalId = id,
				warId = war.id,
				fromTag = fromTag,
				toTag = toTag,
				reason = "unfavorable_terms",
			})
			return false, id, "unfavorable_terms"
		end
	end

	return true, id
end

local function acceptPeace(proposalId, byTag)
	local proposal = ctx.WorldState.getPeaceProposal(proposalId)
	if not proposal then
		return false, "no_proposal"
	end
	if proposal.status ~= "pending" then
		return false, "not_pending"
	end
	if proposal.toTag ~= byTag then
		return false, "not_recipient"
	end
	proposal.status = "accepted"
	ctx.WorldState.setPeaceProposal(proposalId, proposal)
	endWar(proposal.warId, proposal.terms, { consented = true }) -- explicit player decision (AcceptPeace)
	return true
end

local function rejectPeace(proposalId, byTag)
	local proposal = ctx.WorldState.getPeaceProposal(proposalId)
	if not proposal then
		return false, "no_proposal"
	end
	if proposal.status ~= "pending" then
		return false, "not_pending"
	end
	if proposal.toTag ~= byTag then
		return false, "not_recipient"
	end
	proposal.status = "rejected"
	ctx.WorldState.setPeaceProposal(proposalId, proposal)
	ctx.EventBus.publish(ctx.Channels.PeaceProposalRejected, {
		proposalId = proposalId,
		warId = proposal.warId,
		byTag = byTag,
	})
	return true
end

local function cancelPeaceProposal(proposalId, byTag)
	local proposal = ctx.WorldState.getPeaceProposal(proposalId)
	if not proposal then
		return false, "no_proposal"
	end
	if proposal.status ~= "pending" then
		return false, "not_pending"
	end
	if proposal.fromTag ~= byTag then
		return false, "not_proposer"
	end
	proposal.status = "cancelled"
	ctx.WorldState.setPeaceProposal(proposalId, proposal)
	ctx.EventBus.publish(ctx.Channels.PeaceProposalCancelled, {
		proposalId = proposalId,
		warId = proposal.warId,
		byTag = byTag,
	})
	return true
end

local function getActiveWarsFor(tag)
	local out = {}
	for _, war in ctx.WorldState.allWars() do
		if war.status == "active" and (war.attackerTag == tag or war.defenderTag == tag) then
			table.insert(out, war)
		end
	end
	return out
end

local function getOutgoingProposals(tag)
	local out = {}
	for _, proposal in ctx.WorldState.allPeaceProposals() do
		if proposal.status == "pending" and proposal.fromTag == tag then
			table.insert(out, proposal)
		end
	end
	return out
end

local function getIncomingProposals(tag)
	local out = {}
	for _, proposal in ctx.WorldState.allPeaceProposals() do
		if proposal.status == "pending" and proposal.toTag == tag then
			table.insert(out, proposal)
		end
	end
	return out
end

local DIPLO_TERMINAL_TTL_SECONDS = 60

local function tickProposals()
	local n = now()
	for id, proposal in ctx.WorldState.allPeaceProposals() do
		if proposal.status == "pending" then
			if proposal.expiresAt and n >= proposal.expiresAt then
				proposal.status = "expired"
				proposal.terminalAt = n
				ctx.WorldState.setPeaceProposal(id, proposal)
				ctx.EventBus.publish(ctx.Channels.PeaceProposalExpired, {
					proposalId = id,
					warId = proposal.warId,
				})
			end
		elseif proposal.terminalAt == nil then
			-- Resolved elsewhere (accepted / rejected / cancelled) with no stamp: mark it now.
			proposal.terminalAt = n
			ctx.WorldState.setPeaceProposal(id, proposal)
		elseif n - proposal.terminalAt >= DIPLO_TERMINAL_TTL_SECONDS then
			-- Terminal long enough for clients to render the outcome: drop from the store + replicated
			-- collection so resolved offers can't accumulate (the diplomacy ticks and findActiveWar
			-- scan these collections every cycle).
			ctx.WorldState.setPeaceProposal(id, nil)
		end
	end
end

-- =====================================================================
-- PACTS (Phase 2). NAP = bilateral offer->accept; the pending offer lives in
-- the replicated `pacts` collection until resolved (status-flipped, mirroring
-- peaceProposals), then the active NAP is written to country.naps via setNap.
-- Guarantee independence = unilateral + instant (no pact record): stored as
-- guarantor.guarantees[protected] / protected.guaranteedBy[guarantor].
-- =====================================================================
local function cancelOutstandingPactsBetween(fromTag, toTag, pactType)
	for _, pact in ctx.WorldState.allPacts() do
		if pact.status == "pending" and pact.type == pactType and pact.fromTag == fromTag and pact.toTag == toTag then
			pact.status = "cancelled"
			ctx.WorldState.setPact(pact.id, pact)
		end
	end
end

local function isGuaranteeing(guarantorTag, protectedTag)
	local g = ctx.WorldState.getCountry(guarantorTag)
	return g ~= nil and g.guarantees ~= nil and g.guarantees[protectedTag] == true
end

-- AI signs a NAP when its opinion of the proposer clears the threshold.
local function aiWouldAcceptNap(fromTag, toTag)
	local threshold = ctx.WorldConstants.NapAcceptThreshold or 0
	return getOpinion(toTag, fromTag) >= threshold
end

local function activateNap(pact)
	local C = ctx.WorldConstants
	setNap(pact.fromTag, pact.toTag, dayToSeconds(C.NapDurationDays or 3650))
	local bonus = C.NapAcceptOpinionBonus or 15
	addOpinion(pact.fromTag, pact.toTag, bonus)
	addOpinion(pact.toTag, pact.fromTag, bonus)
	ctx.EventBus.publish(ctx.Channels.PactAccepted, {
		pactId = pact.id,
		pactType = "nap",
		fromTag = pact.fromTag,
		toTag = pact.toTag,
	})
end

local function proposeNap(fromTag, toTag)
	if hasNap(fromTag, toTag) then
		return false, nil, "already_nap"
	end
	cancelOutstandingPactsBetween(fromTag, toTag, "nap")
	local C = ctx.WorldConstants
	local id = generatePactId(fromTag, toTag)
	local pact = {
		id = id,
		type = "nap",
		fromTag = fromTag,
		toTag = toTag,
		status = "pending",
		proposedAt = now(),
		expiresAt = now() + (C.PactOfferLifetimeSeconds or 600),
		durationDays = C.NapDurationDays or 3650,
	}
	ctx.WorldState.setPact(id, pact)
	ctx.EventBus.publish(ctx.Channels.PactProposed, {
		pactId = id,
		pactType = "nap",
		fromTag = fromTag,
		toTag = toTag,
		expiresAt = pact.expiresAt,
	})
	if not isClaimedTag(toTag) then
		if aiWouldAcceptNap(fromTag, toTag) then
			pact.status = "accepted"
			ctx.WorldState.setPact(id, pact)
			activateNap(pact)
		else
			pact.status = "rejected"
			ctx.WorldState.setPact(id, pact)
			ctx.EventBus.publish(ctx.Channels.PactRejected, {
				pactId = id,
				pactType = "nap",
				fromTag = fromTag,
				toTag = toTag,
				reason = "unfavorable",
			})
			return false, id, "ai_rejected"
		end
	end
	return true, id
end

local function guaranteeIndependence(guarantorTag, protectedTag)
	if isGuaranteeing(guarantorTag, protectedTag) then
		return false, "already_guaranteed"
	end
	local g = ctx.WorldState.getCountry(guarantorTag)
	local p = ctx.WorldState.getCountry(protectedTag)
	if not g or not p then
		return false, "unknown_country"
	end
	local C = ctx.WorldConstants
	-- B37: guarantees were free + instant, so guarantee->revoke->re-guarantee spam was a cheap opinion lever.
	-- Charge political power and gate re-guaranteeing the same target behind a cooldown (mirrors improveRelations).
	local cooldownUntil = g.guaranteeCooldown and g.guaranteeCooldown[protectedTag]
	if cooldownUntil and cooldownUntil > now() then
		return false, "on_cooldown"
	end
	local cost = C.GuaranteeCost or 40
	if
		not (
			ctx.PoliticalPower
			and ctx.PoliticalPower.spend
			and ctx.PoliticalPower.spend(guarantorTag, cost, "guarantee")
		)
	then
		return false, "insufficient_pp"
	end
	-- Re-fetch: the PP spend mutated + persisted the guarantor country.
	g = ctx.WorldState.getCountry(guarantorTag)
	g.guarantees = g.guarantees or {}
	g.guarantees[protectedTag] = true
	g.guaranteeCooldown = g.guaranteeCooldown or {}
	g.guaranteeCooldown[protectedTag] = now() + dayToSeconds(C.GuaranteeCooldownDays or 30)
	ctx.WorldState.setCountry(guarantorTag, g)
	p.guaranteedBy = p.guaranteedBy or {}
	p.guaranteedBy[guarantorTag] = true
	ctx.WorldState.setCountry(protectedTag, p)
	local bonus = C.GuaranteeOpinionBonus or 15
	addOpinion(guarantorTag, protectedTag, bonus)
	addOpinion(protectedTag, guarantorTag, bonus)
	ctx.EventBus.publish(ctx.Channels.GuaranteeIssued, {
		guarantorTag = guarantorTag,
		protectedTag = protectedTag,
	})
	return true
end

local function revokeGuarantee(guarantorTag, protectedTag)
	if not isGuaranteeing(guarantorTag, protectedTag) then
		return false, "not_guaranteeing"
	end
	local g = ctx.WorldState.getCountry(guarantorTag)
	if g and g.guarantees then
		g.guarantees[protectedTag] = nil
		ctx.WorldState.setCountry(guarantorTag, g)
	end
	local p = ctx.WorldState.getCountry(protectedTag)
	if p and p.guaranteedBy then
		p.guaranteedBy[guarantorTag] = nil
		ctx.WorldState.setCountry(protectedTag, p)
	end
	addOpinion(protectedTag, guarantorTag, -(ctx.WorldConstants.GuaranteeRevokeOpinionPenalty or 15))
	ctx.EventBus.publish(ctx.Channels.GuaranteeRevoked, {
		guarantorTag = guarantorTag,
		protectedTag = protectedTag,
	})
	return true
end

local function activateAlliance(pact)
	setAlliance(pact.fromTag, pact.toTag)
	local bonus = ctx.WorldConstants.AllianceOpinionBonus or 25
	addOpinion(pact.fromTag, pact.toTag, bonus)
	addOpinion(pact.toTag, pact.fromTag, bonus)
	ctx.EventBus.publish(ctx.Channels.PactAccepted, {
		pactId = pact.id,
		pactType = "alliance",
		fromTag = pact.fromTag,
		toTag = pact.toTag,
	})
end

local function proposeAlliance(fromTag, toTag)
	if areAllied(fromTag, toTag) then
		return false, nil, "already_allied"
	end
	cancelOutstandingPactsBetween(fromTag, toTag, "alliance")
	local C = ctx.WorldConstants
	local id = generatePactId(fromTag, toTag)
	local pact = {
		id = id,
		type = "alliance",
		fromTag = fromTag,
		toTag = toTag,
		status = "pending",
		proposedAt = now(),
		expiresAt = now() + (C.PactOfferLifetimeSeconds or 600),
	}
	ctx.WorldState.setPact(id, pact)
	ctx.EventBus.publish(ctx.Channels.PactProposed, {
		pactId = id,
		pactType = "alliance",
		fromTag = fromTag,
		toTag = toTag,
		expiresAt = pact.expiresAt,
	})
	if not isClaimedTag(toTag) then
		if getOpinion(toTag, fromTag) >= (C.AllianceAcceptThreshold or 50) then
			pact.status = "accepted"
			ctx.WorldState.setPact(id, pact)
			activateAlliance(pact)
		else
			pact.status = "rejected"
			ctx.WorldState.setPact(id, pact)
			ctx.EventBus.publish(ctx.Channels.PactRejected, {
				pactId = id,
				pactType = "alliance",
				fromTag = fromTag,
				toTag = toTag,
				reason = "unfavorable",
			})
			return false, id, "ai_rejected"
		end
	end
	return true, id
end

local function breakAlliance(fromTag, otherTag)
	if not areAllied(fromTag, otherTag) then
		return false, "not_allied"
	end
	clearAlliance(fromTag, otherTag)
	local penalty = ctx.WorldConstants.AllianceBreakPenalty or 60
	addOpinion(fromTag, otherTag, -penalty)
	addOpinion(otherTag, fromTag, -penalty)
	ctx.EventBus.publish(ctx.Channels.PactBroken, {
		pactType = "alliance",
		fromTag = fromTag,
		toTag = otherTag,
	})
	return true
end

local function releaseSubject(overlordTag, subjectTag)
	if overlordOf(subjectTag) ~= overlordTag then
		return false, "not_your_subject"
	end
	clearSubject(overlordTag, subjectTag)
	addOpinion(subjectTag, overlordTag, ctx.WorldConstants.ReleaseSubjectOpinionBonus or 30)
	ctx.EventBus.publish(ctx.Channels.SubjectReleased, {
		overlordTag = overlordTag,
		subjectTag = subjectTag,
	})
	return true
end

-- Province ids owned by `holderTag` on which `releaseTag` is a releasable core (the land a release hands over).
local function releasableProvinceIds(holderTag, releaseTag)
	local ids = {}
	if not (ctx.ProvinceRegistry and ctx.ProvinceRegistry.byOwner) then
		return ids
	end
	for _, id in ipairs(ctx.ProvinceRegistry.byOwner(holderTag)) do
		local p = ctx.WorldState.getProvince(id)
		if p and p.releasableCores and table.find(p.releasableCores, releaseTag) then
			ids[#ids + 1] = id
		end
	end
	return ids
end

-- Phase 4 (UPD 1: cores-driven): voluntarily release a breakaway nation from your RELEASABLE CORES, either
-- independent or as a puppet. `releaseTag` is a country tag (authored via the Data Editor's Releasable Cores
-- paint, or stamped on annexed provinces). Revives the nation's dormant identity (NationFactory), transfers
-- every province you own that lists it as a releasable core, cores them to it, and sets an anti-exploit truce.
local function releaseNation(holderTag, releaseTag, asPuppet)
	if not ctx.WorldConstants.EnableFormables then
		return false, "disabled"
	end
	if not ctx.NationFactory then
		return false, "unavailable"
	end
	if not releaseTag or releaseTag == holderTag or releaseTag == "NONE" then
		return false, "invalid"
	end
	-- A nation that already owns land is alive and cannot be released (a dormant, landless record is fine to revive).
	if ctx.ProvinceRegistry and ctx.ProvinceRegistry.byOwner and #ctx.ProvinceRegistry.byOwner(releaseTag) > 0 then
		return false, "already_exists"
	end
	local ids = releasableProvinceIds(holderTag, releaseTag)
	if #ids == 0 then
		return false, "no_releasable_cores"
	end
	-- Identity source: a dormant country record first (authored releasables), then an annex-stored formable
	-- def, then the capital province's culture/religion. Forming keeps identity; releasing revives it.
	local rec = ctx.WorldState.getCountry(releaseTag)
	local def = (ctx.FormableSystem and ctx.FormableSystem.getDefinition)
			and ctx.FormableSystem.getDefinition(releaseTag)
		or nil
	local holder = ctx.WorldState.getCountry(holderTag)
	local capProv = ctx.WorldState.getProvince(ids[1])
	ctx.NationFactory.create(releaseTag, {
		displayName = (rec and rec.displayName) or (def and def.displayName) or releaseTag,
		color = (rec and rec.color) or (def and def.color),
		flag = (rec and rec.flagAssetId) or (def and def.flag),
		capitalProvinceId = ids[1],
		primaryCulture = (rec and rec.primaryCulture) or (capProv and capProv.culture),
		stateReligion = (rec and rec.stateReligion) or (capProv and capProv.religion),
		governmentForm = (rec and rec.governmentForm) or (holder and holder.governmentForm),
		ideology = (rec and rec.ideology) or (holder and holder.ideology),
	})
	for _, id in ipairs(ids) do
		local p = ctx.WorldState.getProvince(id)
		if p and p.ownerTag == holderTag then
			-- Add the released nation's core on the record first so it rides the same dirty mark as the flip.
			p.cores = p.cores or {}
			if not table.find(p.cores, releaseTag) then
				table.insert(p.cores, releaseTag)
			end
			-- Only hand over the controller if the holder still occupies it; an enemy-occupied core stays
			-- occupied (mirrors annexCountry) rather than being silently freed to the new nation.
			if ctx.WorldConstants.RecordOwnershipChokepoint then
				local controller = (p.controllerTag == holderTag) and releaseTag or nil
				ctx.WorldState.setProvinceOwnership(
					id,
					{ owner = releaseTag, controller = controller, reason = "formable" }
				)
			else
				p.ownerTag = releaseTag
				if p.controllerTag == holderTag then
					p.controllerTag = releaseTag
				end
				ctx.WorldState.setProvince(id, p)
				ctx.EventBus.publish(ctx.Channels.ProvinceOwnershipChanged, {
					provinceId = id,
					oldOwner = holderTag,
					newOwner = releaseTag,
				})
			end
		end
	end
	if asPuppet then
		setSubject(holderTag, releaseTag)
	end
	-- Anti-exploit truce: release -> immediate re-annex would otherwise be free expansion laundering.
	local truceSeconds = dayToSeconds(ctx.WorldConstants.ReleaseTruceDays or ctx.WorldConstants.TrucePeriodDays or 1825)
	setTruce(holderTag, releaseTag, truceSeconds)
	ctx.EventBus.publish(ctx.Channels.SubjectReleased, {
		overlordTag = holderTag,
		subjectTag = releaseTag,
	})
	return true
end

-- Full annexation (shared): end the loser's OTHER active wars (skip exceptWarId -- the war currently
-- being concluded, if any), transfer ALL its owned provinces to the winner (owner + controller), then
-- delete the now-empty nation. O(owned) via ProvinceRegistry.byOwner. CapitalSystem / EconomySystem /
-- ProvinceStamper / StateReplicator all react to ProvinceOwnershipChanged automatically. Callers gate
-- the consent / human checks. `function` (not `local function`) fills the forward-declared upvalue.
function annexCountry(winnerTag, loserTag, exceptWarId)
	local loserCountry = ctx.WorldState.getCountry(loserTag)
	local loserName = (loserCountry and loserCountry.displayName) or loserTag
	local winnerCountry = ctx.WorldState.getCountry(winnerTag)
	local winnerName = (winnerCountry and winnerCountry.displayName) or winnerTag
	for _, war in getActiveWarsFor(loserTag) do
		if war.id ~= exceptWarId then
			-- The other belligerent in this side-war is losing an enemy to a third-party annexation, not
			-- negotiating a peace. If they are a connected human, tell them explicitly -- the plain
			-- PeaceConcluded toast (white_peace) would misrepresent why the war ended.
			local otherTag = (war.attackerTag == loserTag) and war.defenderTag or war.attackerTag
			if otherTag ~= winnerTag and isClaimedTag(otherTag) and ctx.NotificationBroadcaster then
				ctx.NotificationBroadcaster.push({
					kind = "info",
					title = "War Ended",
					body = string.format(
						"%s has been annexed by %s; our war with them is over.",
						loserName,
						winnerName
					),
					audience = "self",
					tag = otherTag,
					eventType = "war.enemy.annexed",
					ttl = 10,
				})
			end
			endWar(war.id, { type = "white_peace", forced = true, reason = "annexed" }, { consented = true })
		end
	end
	-- Snapshot the id list (byOwner returns the live bucket, which we mutate as we reassign owners).
	local ids = {}
	if ctx.ProvinceRegistry and ctx.ProvinceRegistry.byOwner then
		for _, id in ipairs(ctx.ProvinceRegistry.byOwner(loserTag)) do
			ids[#ids + 1] = id
		end
	else
		for id, province in ctx.WorldState.allProvinces() do
			if province.ownerTag == loserTag then
				ids[#ids + 1] = id
			end
		end
	end
	for _, id in ipairs(ids) do
		local province = ctx.WorldState.getProvince(id)
		if province and province.ownerTag == loserTag then
			if ctx.WorldConstants.RecordOwnershipChokepoint then
				local controller = (province.controllerTag == loserTag) and winnerTag or nil
				ctx.WorldState.setProvinceOwnership(
					id,
					{ owner = winnerTag, controller = controller, reason = "annex" }
				)
			else
				province.ownerTag = winnerTag
				if province.controllerTag == loserTag then
					province.controllerTag = winnerTag
				end
				ctx.WorldState.setProvince(id, province)
				ctx.EventBus.publish(ctx.Channels.ProvinceOwnershipChanged, {
					provinceId = id,
					oldOwner = loserTag,
					newOwner = winnerTag,
				})
			end
		end
	end
	-- Releasable conquered nation (v1, in-memory/session-scoped): register the just-deleted loser as a
	-- release-only formable definition so a later rebellion (civil war) in the conqueror can restore it.
	-- Homeland = the provinces we just transferred (capital first if present). NOT persisted via
	-- FormableStore to avoid replicating hundreds of dormant defs; gated by EnableFormables.
	if
		ctx.WorldConstants.EnableFormables
		and ctx.FormableSystem
		and ctx.FormableSystem.addDefinition
		and loserCountry
		and #ids > 0
	then
		local homeland = {}
		local capital = loserCountry.capitalProvinceId
		if capital ~= nil and table.find(ids, capital) then
			homeland[#homeland + 1] = capital
		end
		for _, id in ipairs(ids) do
			if id ~= capital then
				homeland[#homeland + 1] = id
			end
		end
		if #homeland > 0 then
			ctx.FormableSystem.addDefinition(loserTag, {
				displayName = loserName,
				color = loserCountry.color,
				flag = loserCountry.flagAssetId,
				requiredProvinceIds = homeland,
				canForm = false,
				canRelease = true,
				annexedBy = winnerTag,
			})
		end
		-- Cores-driven release (UPD 1): stamp the loser's tag into the releasableCores of the provinces we
		-- took, so a future holder can free it as a breakaway. The def above survives as an identity source
		-- once the loser's country record is deleted.
		for _, id in ipairs(ids) do
			local rp = ctx.WorldState.getProvince(id)
			if rp then
				rp.releasableCores = rp.releasableCores or {}
				if not table.find(rp.releasableCores, loserTag) then
					table.insert(rp.releasableCores, loserTag)
					ctx.WorldState.setProvince(id, rp)
				end
			end
		end
	end
	-- Disband the annexed nation's military. Without this its armies/fleets orphan under a dead
	-- ownerTag once the country record is deleted. Battles self-heal via BattleManager's
	-- ArmyDisbanded scrub; naval battles prune themselves when a fleet record vanishes.
	if ctx.WorldConstants.EnableAnnexArmyDisband then
		if ctx.ArmySystem and ctx.ArmySystem.armiesOfOwner then
			for _, army in ipairs(ctx.ArmySystem.armiesOfOwner(loserTag)) do
				ctx.ArmySystem.destroyArmy(army.id, "country_annexed")
			end
		end
		if ctx.NavalSystem and ctx.NavalSystem.disbandAllFor then
			ctx.NavalSystem.disbandAllFor(loserTag)
		end
	end
	-- Pass the winner so the deleteCountry integrity guard reassigns any province the byOwner-driven loop
	-- above missed (index desync) to the conqueror instead of stranding it owning a now-deleted tag.
	ctx.WorldState.deleteCountry(loserTag, winnerTag)
end

-- Absorb a subject: clear the subject link, then full-annex it (AI subjects only).
local function annexSubject(overlordTag, subjectTag)
	if overlordOf(subjectTag) ~= overlordTag then
		return false, "not_your_subject"
	end
	-- A human-controlled nation can never be annexed away (that would end their wars + delete their
	-- country with no consent). Overlord annexation is an AI-subject-only mechanic. Check PERSISTENT
	-- humanity (claimStartedBy survives a disconnect/release) so an overlord can't vassalize a human, wait
	-- for them to log off, and delete their nation behind their back (B5) -- this is the only path that can
	-- fully delete a formerly-human nation, and it is not gated by EnableFullAnnex.
	local subject = ctx.WorldState.getCountry(subjectTag)
	if isClaimedTag(subjectTag) or (subject and subject.claimStartedBy ~= nil) then
		return false, "cannot_annex_player"
	end
	clearSubject(overlordTag, subjectTag)
	annexCountry(overlordTag, subjectTag)
	ctx.EventBus.publish(ctx.Channels.SubjectAnnexed, {
		overlordTag = overlordTag,
		subjectTag = subjectTag,
	})
	return true
end

-- Call-to-arms: a co-belligerent joins as a NEW linked 1v1 war vs the aggressor. Combat is gated
-- pairwise by areAtWar, so the new front lights up with zero combat-stack changes. A NAP with the
-- aggressor shields a nation from the call. Co-belligerent wars carry callReason ~= "direct" so the
-- WarDeclared handler does NOT recurse them into further calls.
local function joinWarAgainst(joinerTag, aggressorTag, conflictId, reason)
	if not joinerTag or not aggressorTag or joinerTag == aggressorTag then
		return false
	end
	if not ctx.WorldState.getCountry(joinerTag) or not ctx.WorldState.getCountry(aggressorTag) then
		return false
	end
	if findActiveWar(joinerTag, aggressorTag) then
		return false
	end
	local joinerCountry = ctx.WorldState.getCountry(joinerTag)
	if readNap(joinerCountry, aggressorTag) then
		return false
	end
	local id = generateWarId(aggressorTag, joinerTag)
	local war = {
		id = id,
		attackerTag = aggressorTag,
		defenderTag = joinerTag,
		declaredAt = now(),
		status = "active",
		score = 0,
		attackerExhaustion = 0,
		defenderExhaustion = 0,
		conflictId = conflictId,
		callReason = reason or "ally",
		declaredMonthIndex = (function()
			local gd = ctx.TickScheduler.getGameDate and ctx.TickScheduler.getGameDate()
			return gd and (gd.year * 12 + (gd.month - 1)) or nil
		end)(),
	}
	ctx.WorldState.setWar(id, war)
	ctx.EventBus.publish(ctx.Channels.WarDeclared, {
		warId = id,
		attackerTag = aggressorTag,
		defenderTag = joinerTag,
		declaredAt = war.declaredAt,
		conflictId = conflictId,
		callReason = war.callReason,
	})
	local penalty = ctx.WorldConstants.OpinionWarPenalty or 50
	addOpinion(aggressorTag, joinerTag, -penalty)
	addOpinion(joinerTag, aggressorTag, -penalty)
	return true, id
end

-- Public entry for the ProposePact remote: routes by pact type.
local function proposePact(fromTag, toTag, pactType)
	if not fromTag or not toTag or fromTag == toTag then
		return false, nil, "bad_target"
	end
	if not ctx.WorldState.getCountry(fromTag) or not ctx.WorldState.getCountry(toTag) then
		return false, nil, "unknown_country"
	end
	if areAtWar(fromTag, toTag) then
		return false, nil, "at_war"
	end
	-- Subjects have no independent foreign policy; nobody pacts with a subject either.
	if isSubject(fromTag) or isSubject(toTag) then
		return false, nil, "subject_involved"
	end
	if pactType == "guarantee" then
		local ok, reason = guaranteeIndependence(fromTag, toTag)
		return ok, nil, reason
	elseif pactType == "nap" then
		return proposeNap(fromTag, toTag)
	elseif pactType == "alliance" then
		return proposeAlliance(fromTag, toTag)
	end
	return false, nil, "bad_pact_type"
end

local function acceptPact(pactId, byTag)
	local pact = ctx.WorldState.getPact(pactId)
	if not pact then
		return false, "no_pact"
	end
	if pact.status ~= "pending" then
		return false, "not_pending"
	end
	if pact.toTag ~= byTag then
		return false, "not_recipient"
	end
	if (pact.type == "nap" or pact.type == "alliance") and areAtWar(pact.fromTag, pact.toTag) then
		pact.status = "cancelled"
		ctx.WorldState.setPact(pactId, pact)
		ctx.EventBus.publish(ctx.Channels.PactCancelled, {
			pactId = pactId,
			pactType = pact.type,
			fromTag = pact.fromTag,
			toTag = pact.toTag,
			byTag = byTag,
			reason = "at_war",
		})
		return false, "at_war"
	end
	pact.status = "accepted"
	ctx.WorldState.setPact(pactId, pact)
	if pact.type == "nap" then
		activateNap(pact)
	elseif pact.type == "alliance" then
		if not areAllied(pact.fromTag, pact.toTag) then
			activateAlliance(pact)
		end
	elseif pact.type == "call_to_arms" then
		joinWarAgainst(pact.toTag, pact.aggressorTag, pact.conflictId, "call_to_arms")
	end
	return true
end

local function rejectPact(pactId, byTag)
	local pact = ctx.WorldState.getPact(pactId)
	if not pact then
		return false, "no_pact"
	end
	if pact.status ~= "pending" then
		return false, "not_pending"
	end
	if pact.toTag ~= byTag then
		return false, "not_recipient"
	end
	pact.status = "rejected"
	ctx.WorldState.setPact(pactId, pact)
	if pact.type == "call_to_arms" then
		-- Refusing a called-for war is a betrayal: opinion penalty + dissolve the underlying tie.
		local penalty = ctx.WorldConstants.CallToArmsDeclinePenalty or 75
		addOpinion(pact.toTag, pact.fromTag, -penalty)
		addOpinion(pact.fromTag, pact.toTag, -penalty)
		if pact.obligation == "ally" then
			clearAlliance(pact.fromTag, pact.toTag)
		elseif pact.obligation == "guarantee" then
			-- The guarantor (toTag) failed to honor its guarantee of the caller (fromTag): void it.
			local g = ctx.WorldState.getCountry(pact.toTag)
			if g and g.guarantees then
				g.guarantees[pact.fromTag] = nil
				ctx.WorldState.setCountry(pact.toTag, g)
			end
			local p = ctx.WorldState.getCountry(pact.fromTag)
			if p and p.guaranteedBy then
				p.guaranteedBy[pact.toTag] = nil
				ctx.WorldState.setCountry(pact.fromTag, p)
			end
		end
	end
	ctx.EventBus.publish(ctx.Channels.PactRejected, {
		pactId = pactId,
		pactType = pact.type,
		fromTag = pact.fromTag,
		toTag = pact.toTag,
		byTag = byTag,
	})
	return true
end

local function cancelPact(pactId, byTag)
	local pact = ctx.WorldState.getPact(pactId)
	if not pact then
		return false, "no_pact"
	end
	if pact.status ~= "pending" then
		return false, "not_pending"
	end
	if pact.fromTag ~= byTag then
		return false, "not_proposer"
	end
	pact.status = "cancelled"
	ctx.WorldState.setPact(pactId, pact)
	ctx.EventBus.publish(ctx.Channels.PactCancelled, {
		pactId = pactId,
		pactType = pact.type,
		fromTag = pact.fromTag,
		toTag = pact.toTag,
		byTag = byTag,
	})
	return true
end

local function breakNap(fromTag, otherTag)
	if not hasNap(fromTag, otherTag) then
		return false, "no_nap"
	end
	clearNap(fromTag, otherTag)
	local penalty = ctx.WorldConstants.NapBreakOpinionPenalty or 40
	addOpinion(fromTag, otherTag, -penalty)
	addOpinion(otherTag, fromTag, -penalty)
	ctx.EventBus.publish(ctx.Channels.PactBroken, {
		pactType = "nap",
		fromTag = fromTag,
		toTag = otherTag,
	})
	return true
end

-- Public entry for the BreakPact remote: NAP -> betrayal break; guarantee -> revoke.
local function breakPact(fromTag, otherTag, pactType)
	if pactType == "guarantee" then
		return revokeGuarantee(fromTag, otherTag)
	elseif pactType == "nap" then
		return breakNap(fromTag, otherTag)
	elseif pactType == "alliance" then
		return breakAlliance(fromTag, otherTag)
	end
	return false, "bad_pact_type"
end

local function getOutgoingPacts(tag)
	local out = {}
	for _, pact in ctx.WorldState.allPacts() do
		if pact.status == "pending" and pact.fromTag == tag then
			table.insert(out, pact)
		end
	end
	return out
end

local function getIncomingPacts(tag)
	local out = {}
	for _, pact in ctx.WorldState.allPacts() do
		if pact.status == "pending" and pact.toTag == tag then
			table.insert(out, pact)
		end
	end
	return out
end

local function tickPacts()
	local n = now()
	for id, pact in ctx.WorldState.allPacts() do
		if pact.status == "pending" then
			if pact.expiresAt and n >= pact.expiresAt then
				pact.status = "expired"
				pact.terminalAt = n
				ctx.WorldState.setPact(id, pact)
				ctx.EventBus.publish(ctx.Channels.PactExpired, {
					pactId = id,
					pactType = pact.type,
					fromTag = pact.fromTag,
					toTag = pact.toTag,
				})
			end
		elseif pact.terminalAt == nil then
			pact.terminalAt = n
			ctx.WorldState.setPact(id, pact)
		elseif n - pact.terminalAt >= DIPLO_TERMINAL_TTL_SECONDS then
			ctx.WorldState.setPact(id, nil)
		end
	end
end

-- Call-to-arms dispatch: an AI ally/guarantor honors the call immediately; a player gets a pending
-- call_to_arms pact (which pops the DiplomaticOffer modal via the existing pacts hook).
local function proposeCallToArms(callerTag, helperTag, conflictId, aggressorTag, obligation)
	if not helperTag or helperTag == aggressorTag or helperTag == callerTag then
		return
	end
	if findActiveWar(helperTag, aggressorTag) then
		return
	end
	local helperCountry = ctx.WorldState.getCountry(helperTag)
	if not helperCountry then
		return
	end
	if readNap(helperCountry, aggressorTag) then
		return
	end
	if not isClaimedTag(helperTag) then
		joinWarAgainst(helperTag, aggressorTag, conflictId, obligation)
		return
	end
	local id = generatePactId(callerTag, helperTag)
	local pact = {
		id = id,
		type = "call_to_arms",
		fromTag = callerTag,
		toTag = helperTag,
		status = "pending",
		proposedAt = now(),
		expiresAt = now() + (ctx.WorldConstants.PactOfferLifetimeSeconds or 600),
		conflictId = conflictId,
		aggressorTag = aggressorTag,
		obligation = obligation,
	}
	ctx.WorldState.setPact(id, pact)
	ctx.EventBus.publish(ctx.Channels.PactProposed, {
		pactId = id,
		pactType = "call_to_arms",
		fromTag = callerTag,
		toTag = helperTag,
		aggressorTag = aggressorTag,
		expiresAt = pact.expiresAt,
	})
end

-- When a DIRECT war is declared, call the defender's allies + guarantors against the aggressor.
-- Co-belligerent wars carry callReason ~= "direct", so the guard prevents a cascade.
local function onWarDeclared(payload)
	if not payload then
		return
	end
	if payload.callReason and payload.callReason ~= "direct" then
		return
	end
	local attackerTag = payload.attackerTag
	local defenderTag = payload.defenderTag
	if not attackerTag or not defenderTag then
		return
	end
	local conflictId = payload.conflictId or payload.warId
	local defender = ctx.WorldState.getCountry(defenderTag)
	if not defender then
		return
	end
	local called = {}
	local function callHelper(helperTag, obligation)
		if not helperTag or helperTag == defenderTag or helperTag == attackerTag then
			return
		end
		if called[helperTag] then
			return
		end
		called[helperTag] = true
		proposeCallToArms(defenderTag, helperTag, conflictId, attackerTag, obligation)
	end
	if defender.allies then
		for ally in pairs(defender.allies) do
			callHelper(ally, "ally")
		end
	end
	if defender.guaranteedBy then
		for guarantor in pairs(defender.guaranteedBy) do
			callHelper(guarantor, "guarantee")
		end
	end
	-- Subjects are FORCED into their overlord's war (no offer, no decline). The defender's subjects
	-- + overlord defend against the attacker; the attacker's subjects support the offensive.
	if defender.subjects then
		for sub in pairs(defender.subjects) do
			if sub ~= attackerTag then
				joinWarAgainst(sub, attackerTag, conflictId, "subject")
			end
		end
	end
	if defender.subjectOf and defender.subjectOf ~= attackerTag then
		joinWarAgainst(defender.subjectOf, attackerTag, conflictId, "subject")
	end
	local attacker = ctx.WorldState.getCountry(attackerTag)
	if attacker and attacker.subjects then
		for sub in pairs(attacker.subjects) do
			if sub ~= defenderTag then
				-- The attacker's subjects support the offensive: the subject is the aggressor vs the
				-- defender (joinWarAgainst frames arg2 as attacker, arg1 as defender of the new front).
				joinWarAgainst(defenderTag, sub, conflictId, "subject")
			end
		end
	end
end

-- Phase 2: does `tag` hold a claim on this province? Claims live on the province (single source of
-- truth) -- a direct membership read. Feeds the peace-conference cost math + CB checks (Phase 3).
-- Returns false while EnableCores is off, so claim discounts/CBs stay inert until the phase is enabled.
local function hasClaimOn(tag, provinceId)
	if not ctx.WorldConstants.EnableCores then
		return false
	end
	local p = ctx.WorldState.getProvince(provinceId)
	return p ~= nil and p.claims ~= nil and table.find(p.claims, tag) ~= nil
end

function DiplomacySystem.register(context)
	ctx = context
	local api = {
		declareWar = declareWar,
		hasClaimOn = hasClaimOn,
		proposePeace = proposePeace,
		acceptPeace = acceptPeace,
		rejectPeace = rejectPeace,
		cancelPeaceProposal = cancelPeaceProposal,
		areAtWar = areAtWar,
		findActiveWar = findActiveWar,
		getActiveWarsFor = getActiveWarsFor,
		getOutgoingProposals = getOutgoingProposals,
		getIncomingProposals = getIncomingProposals,
		endWar = endWar,
		getOpinion = getOpinion,
		improveRelations = improveRelations,
		proposePact = proposePact,
		acceptPact = acceptPact,
		rejectPact = rejectPact,
		cancelPact = cancelPact,
		breakPact = breakPact,
		guaranteeIndependence = guaranteeIndependence,
		revokeGuarantee = revokeGuarantee,
		hasNap = hasNap,
		isGuaranteeing = isGuaranteeing,
		areAllied = areAllied,
		joinWarAgainst = joinWarAgainst,
		isSubject = isSubject,
		overlordOf = overlordOf,
		releaseSubject = releaseSubject,
		releaseNation = releaseNation,
		annexSubject = annexSubject,
		getOutgoingPacts = getOutgoingPacts,
		getIncomingPacts = getIncomingPacts,
	}
	context.DiplomacySystem = api
	for k, v in pairs(api) do
		DiplomacySystem[k] = v
	end

	-- Phase 5b: accrue war score from canonical battle + occupation channels.
	if context.EventBus and context.EventBus.subscribe then
		context.EventBus.subscribe(context.Channels.BattleResolved, onBattleResolved)
		context.EventBus.subscribe(context.Channels.ProvinceOccupied, onProvinceOccupied)
		if context.Channels.NavalBattleResolved then
			context.EventBus.subscribe(context.Channels.NavalBattleResolved, onNavalBattleResolved)
		end
		-- Phase 3: call the defender's allies + guarantors into linked co-belligerent wars.
		context.EventBus.subscribe(context.Channels.WarDeclared, onWarDeclared)
	end

	context.TickScheduler.register({
		id = "DiplomacySystem",
		priority = 28,
		updateIntervalSeconds = context.WorldConstants.DiplomacyTickInterval or 6,
		update = function(sysCtx)
			tickProposals()
			tickPacts()
			stampHumanWars()
			local gd = (sysCtx and sysCtx.gameDate)
				or (context.TickScheduler.getGameDate and context.TickScheduler.getGameDate())
			if gd then
				local mi = gd.year * 12 + (gd.month - 1)
				if lastDiplomacyMonth == nil then
					lastDiplomacyMonth = mi
				elseif mi ~= lastDiplomacyMonth then
					local months = mi - lastDiplomacyMonth
					lastDiplomacyMonth = mi
					accrueMonthlyAndResolve(mi, months)
				end
			end
		end,
	})
end

return DiplomacySystem
