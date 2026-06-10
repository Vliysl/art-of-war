local DiplomacySystem = {}

local ctx
local nextWarSeq = 0
local nextProposalSeq = 0

local function generateWarId(a, b)
	nextWarSeq += 1
	return string.format("war_%s_%s_%d", a, b, nextWarSeq)
end

local function generateProposalId(a, b)
	nextProposalSeq += 1
	return string.format("peace_%s_%s_%d", a, b, nextProposalSeq)
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
	if not tagA or not tagB or tagA == tagB then return nil end
	for _, war in ctx.WorldState.allWars() do
		if war.status == "active" then
			if (war.attackerTag == tagA and war.defenderTag == tagB)
				or (war.attackerTag == tagB and war.defenderTag == tagA) then
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
	if not country or not country.truces then return nil end
	local ends = country.truces[otherTag]
	if not ends then return nil end
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

local function declareWar(attackerTag, defenderTag)
	if not attackerTag or not defenderTag then return false, "missing_tag" end
	if attackerTag == defenderTag then return false, "self_war" end
	if not ctx.WorldState.getCountry(attackerTag) then return false, "unknown_attacker" end
	if not ctx.WorldState.getCountry(defenderTag) then return false, "unknown_defender" end
	if findActiveWar(attackerTag, defenderTag) then return false, "already_at_war" end
	local atkCountry = ctx.WorldState.getCountry(attackerTag)
	if readTruce(atkCountry, defenderTag) then return false, "truce_active" end

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
		declaredMonthIndex = (function() local gd = ctx.TickScheduler.getGameDate and ctx.TickScheduler.getGameDate(); return gd and (gd.year * 12 + (gd.month - 1)) or nil end)(),
	}
	ctx.WorldState.setWar(id, war)
	ctx.EventBus.publish(ctx.Channels.WarDeclared, {
		warId = id,
		attackerTag = attackerTag,
		defenderTag = defenderTag,
		declaredAt = war.declaredAt,
	})
	return true, id
end

local function cancelOutstandingProposalsBetween(fromTag, toTag)
	for _, proposal in ctx.WorldState.allPeaceProposals() do
		if proposal.status == "pending"
			and proposal.fromTag == fromTag
			and proposal.toTag == toTag then
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
			if (controller == war.attackerTag and owner == war.defenderTag)
				or (controller == war.defenderTag and owner == war.attackerTag) then
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

local function applyTermsAnnexOccupied(war, winnerTag, loserTag)
	-- Provinces where winnerTag controls but loserTag owns -> ownership flips to winnerTag
	for id, province in ctx.WorldState.allProvinces() do
		if province.controllerTag == winnerTag and province.ownerTag == loserTag then
			local oldOwner = province.ownerTag
			province.ownerTag = winnerTag
			ctx.WorldState.setProvince(id, province)
			ctx.EventBus.publish(ctx.Channels.ProvinceOwnershipChanged, {
				provinceId = id,
				oldOwner = oldOwner,
				newOwner = winnerTag,
			})
		end
	end
end

local function endActiveBattlesBetween(tagA, tagB)
	if not ctx.BattleManager then return end
	local toEnd = {}
	for id, battle in ctx.WorldState.allBattles() do
		-- End if any attacker is tagA and any defender is tagB, or vice versa
		local relevant = false
		for _, armyId in battle.attackerArmyIds do
			local army = ctx.WorldState.getArmy(armyId)
			if army and (army.ownerTag == tagA or army.ownerTag == tagB) then
				relevant = true; break
			end
		end
		if relevant then
			table.insert(toEnd, id)
		end
	end
	for _, id in toEnd do
		local b = ctx.WorldState.getBattle(id)
		if b then ctx.BattleManager.endBattle(b, nil, "draw_war_ended") end
	end
end

local function cancelStaleAttackMoves(tagA, tagB)
	if not ctx.MovementSystem then return end
	for armyId, army in ctx.WorldState.allArmies() do
		if army.movement then
			local target = ctx.WorldState.getProvince(army.movement.toProvinceId)
			if target then
				local toController = target.controllerTag
				if (army.ownerTag == tagA and toController == tagB)
					or (army.ownerTag == tagB and toController == tagA) then
					ctx.MovementSystem.cancelMovement(armyId, "war_ended")
				end
			end
		end
	end
end

local function endWar(warId, terms)
	local war = ctx.WorldState.getWar(warId)
	if not war or war.status ~= "active" then return false, "war_not_active" end

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
	end

	-- 3) Cancel in-flight attack moves
	cancelStaleAttackMoves(war.attackerTag, war.defenderTag)

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

local function isClaimedTag(tag)
	return ctx.PlayerAuthority ~= nil and ctx.PlayerAuthority.playerFor ~= nil and ctx.PlayerAuthority.playerFor(tag) ~= nil
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
	if not war or war.status ~= "active" then return end
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
	if not war or war.status ~= "active" then return end
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
		if not ids then return false end
		for _, aid in ipairs(ids) do
			local a = ctx.WorldState.getArmy(aid)
			if a and a.domain == "naval" then return true end
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
	if not payload then return end
	local winnerTag, loserTag = payload.winnerTag, payload.loserTag
	if not winnerTag or not loserTag then return end -- draw / war-end teardown
	local war = (payload.warId and ctx.WorldState.getWar(payload.warId)) or findActiveWar(winnerTag, loserTag)
	if not war or war.status ~= "active" then return end
	local C = ctx.WorldConstants
	local delta = battlePayloadIsNaval(payload) and (C.WarScoreNavalWin or 8) or (C.WarScoreBattleWin or 5)
	applyBattleScore(war, winnerTag, loserTag, delta)
end

-- Phase 6: naval battles share the war-score model. NavalBattleResolved carries
-- attackerTag/defenderTag (fleet owners) + winner in {attacker,defender,mutual}.
local function onNavalBattleResolved(payload)
	if not payload then return end
	local winner = payload.winner
	if winner ~= "attacker" and winner ~= "defender" then return end -- skip mutual/unknown
	local aTag, dTag = payload.attackerTag, payload.defenderTag
	if not aTag or not dTag then return end
	local war = findActiveWar(aTag, dTag)
	if not war or war.status ~= "active" then return end
	local winnerTag = (winner == "attacker") and aTag or dTag
	local loserTag  = (winner == "attacker") and dTag or aTag
	applyBattleScore(war, winnerTag, loserTag, ctx.WorldConstants.WarScoreNavalWin or 8)
end

local function onProvinceOccupied(payload)
	if not payload then return end
	local newController, ownerTag = payload.newController, payload.ownerTag
	-- Skip peace-deal reversions (province returned to owner); only score hostile takes.
	if not newController or not ownerTag or newController == ownerTag then return end
	local war = findActiveWar(newController, ownerTag)
	if not war or war.status ~= "active" then return end
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
	local recipientExhaustion = (toTag == war.attackerTag) and (war.attackerExhaustion or 0) or (war.defenderExhaustion or 0)
	local willingness = -recipientScore + recipientExhaustion * (C.PeaceAIExhaustionWeight or 0.5)
	local cost
	if terms.type == "annex_occupied" then
		local n = occupiedProvinceCount(fromTag, toTag)
		cost = (C.PeaceAnnexBaseCost or 20) + n * (C.PeaceAnnexPerProvinceCost or 10)
	else
		cost = C.PeaceWhitePeaceCost or 0
	end
	return (willingness - cost) >= (C.PeaceAIAcceptMargin or 0)
end

-- Monthly: both sides gain base exhaustion; mandatory white peace after a long stalemate.
local lastDiplomacyMonth = nil
local function accrueMonthlyAndResolve(currentMonthIndex, months)
	local C = ctx.WorldConstants
	local base = (C.WarExhaustionMonthlyBase or 0.05) * months
	local stalemateMonths = (C.WarStalemateYears or 5) * 12
	local ids = {}
	for id, war in ctx.WorldState.allWars() do
		if war.status == "active" then table.insert(ids, id) end
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

local function proposePeace(fromTag, toTag, terms)
	if not fromTag or not toTag then return false, nil, "missing_tag" end
	local war = findActiveWar(fromTag, toTag)
	if not war then return false, nil, "no_war" end
	terms = terms or { type = "white_peace" }
	if terms.type ~= "white_peace" and terms.type ~= "annex_occupied" then
		return false, nil, "bad_terms"
	end
	-- Stamp proposer for annex resolution
	terms.proposerTag = fromTag

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

	if not isClaimedTag(toTag) then
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
			endWar(war.id, terms)
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
	if not proposal then return false, "no_proposal" end
	if proposal.status ~= "pending" then return false, "not_pending" end
	if proposal.toTag ~= byTag then return false, "not_recipient" end
	proposal.status = "accepted"
	ctx.WorldState.setPeaceProposal(proposalId, proposal)
	endWar(proposal.warId, proposal.terms)
	return true
end

local function rejectPeace(proposalId, byTag)
	local proposal = ctx.WorldState.getPeaceProposal(proposalId)
	if not proposal then return false, "no_proposal" end
	if proposal.status ~= "pending" then return false, "not_pending" end
	if proposal.toTag ~= byTag then return false, "not_recipient" end
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
	if not proposal then return false, "no_proposal" end
	if proposal.status ~= "pending" then return false, "not_pending" end
	if proposal.fromTag ~= byTag then return false, "not_proposer" end
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

local function tickProposals()
	local n = now()
	for id, proposal in ctx.WorldState.allPeaceProposals() do
		if proposal.status == "pending" and proposal.expiresAt and n >= proposal.expiresAt then
			proposal.status = "expired"
			ctx.WorldState.setPeaceProposal(id, proposal)
			ctx.EventBus.publish(ctx.Channels.PeaceProposalExpired, {
				proposalId = id,
				warId = proposal.warId,
			})
		end
	end
end

function DiplomacySystem.register(context)
	ctx = context
	local api = {
		declareWar = declareWar,
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
	}
	context.DiplomacySystem = api
	for k, v in pairs(api) do DiplomacySystem[k] = v end

	-- Phase 5b: accrue war score from canonical battle + occupation channels.
	if context.EventBus and context.EventBus.subscribe then
		context.EventBus.subscribe(context.Channels.BattleResolved, onBattleResolved)
		context.EventBus.subscribe(context.Channels.ProvinceOccupied, onProvinceOccupied)
		if context.Channels.NavalBattleResolved then
			context.EventBus.subscribe(context.Channels.NavalBattleResolved, onNavalBattleResolved)
		end
	end

	context.TickScheduler.register({
		id = "DiplomacySystem",
		priority = 28,
		updateIntervalSeconds = context.WorldConstants.DiplomacyTickInterval or 6,
		update = function(sysCtx)
			tickProposals()
			local gd = (sysCtx and sysCtx.gameDate) or (context.TickScheduler.getGameDate and context.TickScheduler.getGameDate())
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
