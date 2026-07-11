local NotificationBroadcaster = {}

local ctx
local remote

local function displayName(tag)
	if not tag then return "?" end
	local country = ctx.WorldState.getCountry(tag)
	return (country and country.displayName) or tag
end

local function deliver(player, payload)
	if not remote or not player then return end
	remote:FireClient(player, payload)
end

local function playerForTag(tag)
	if not tag then return nil end
	if ctx.PlayerAuthority and ctx.PlayerAuthority.playerFor then
		return ctx.PlayerAuthority.playerFor(tag)
	end
end

local function broadcast(payload)
	if not remote then return end
	local audience = payload.audience
	if audience == "global" then
		remote:FireAllClients(payload)
	elseif audience == "tags" and type(payload.toTags) == "table" then
		for _, tag in payload.toTags do
			local player = playerForTag(tag)
			if player then deliver(player, payload) end
		end
	else
		local player = playerForTag(payload.tag)
		if player then deliver(player, payload) end
	end
end

local function makePayload(kind, title, body, audience, tag, eventType, extra)
	local payload = {
		kind = kind,
		title = title,
		body = body,
		audience = audience or "self",
		tag = tag,
		eventType = eventType,
		ttl = extra and extra.ttl or nil,
	}
	if extra then
		for k, v in extra do
			if payload[k] == nil then payload[k] = v end
		end
	end
	return payload
end

-- "Army Raised" / "Army Arrived" toasts intentionally removed (too noisy during normal play).
-- The ArmyCreated / ArmyMoveCompleted events still fire for other systems; we just don't toast them.

local function occupiedToastPair(provinceId, newController, oldController)
	broadcast(makePayload("good", "Province Occupied",
		string.format("Province %s taken by %s.", tostring(provinceId), displayName(newController)),
		"self", newController, "province.occupied"))
	if oldController and oldController ~= newController then
		broadcast(makePayload("bad", "Province Lost",
			string.format("Province %s has fallen to %s.", tostring(provinceId), displayName(newController)),
			"self", oldController, "province.lost"))
	end
end

-- Under instant capture an AutoCapture sweep flips a province every few seconds; per-tile
-- toasts become spam for both players. Toast the FIRST flip of a (taker, loser) pair
-- immediately, buffer the rest of the window, then flush one "N more provinces" summary.
local occupiedBuffer = {}

local function flushOccupiedBuffer(key)
	local entry = occupiedBuffer[key]
	occupiedBuffer[key] = nil
	if not entry or entry.count <= 0 then return end
	local takerName = displayName(entry.newController)
	broadcast(makePayload("good", "Provinces Occupied",
		string.format("%d more province%s taken by %s.", entry.count, entry.count == 1 and "" or "s", takerName),
		"self", entry.newController, "province.occupied"))
	if entry.oldController and entry.oldController ~= entry.newController then
		broadcast(makePayload("bad", "Provinces Lost",
			string.format("%d more province%s have fallen to %s.", entry.count, entry.count == 1 and "" or "s", takerName),
			"self", entry.oldController, "province.lost"))
	end
end

local function onProvinceOccupied(data)
	if not ctx.WorldConstants.EnableInstantCapture then
		occupiedToastPair(data.provinceId, data.newController, data.oldController)
		return
	end
	local key = tostring(data.newController) .. "|" .. tostring(data.oldController)
	local entry = occupiedBuffer[key]
	if entry then
		entry.count += 1
		return
	end
	occupiedToastPair(data.provinceId, data.newController, data.oldController)
	occupiedBuffer[key] = {
		newController = data.newController,
		oldController = data.oldController,
		count = 0,
	}
	task.delay(ctx.WorldConstants.OccupiedToastWindowSec or 10, function()
		flushOccupiedBuffer(key)
	end)
end

local function onRecruitCancelled(data)
	if data.reason ~= "occupied" then return end
	broadcast(makePayload("warn", "Recruitment Cancelled",
		string.format("Recruitment in province %s was cancelled — the province is occupied (costs refunded).",
			tostring(data.provinceId or "?")),
		"self", data.tag, "recruit.cancelled.occupied", { ttl = 8 }))
end

-- Combat runs many battles in parallel during a war and each start/resolve fired its own per-side toast, so
-- the feed flooded. Coalesce high-volume combat notifications per (recipient, bucket): the FIRST in a burst
-- toasts immediately; further ones within the window are counted and flushed as one "N more ..." summary.
local combatBuffers = {}
local function coalesceToast(kind, tag, bucket, title, firstBody, moreBody, eventType)
	if not tag then return end
	local key = tostring(tag) .. "|" .. bucket
	local entry = combatBuffers[key]
	if entry then
		entry.count += 1
		return
	end
	broadcast(makePayload(kind, title, firstBody, "self", tag, eventType))
	combatBuffers[key] = { count = 0 }
	task.delay(ctx.WorldConstants.CombatToastWindowSec or 12, function()
		local e = combatBuffers[key]
		combatBuffers[key] = nil
		if e and e.count > 0 then
			broadcast(makePayload(kind, title, moreBody(e.count), "self", tag, eventType))
		end
	end)
end

local function onBattleStarted(data)
	-- Attacker-side "Battle Joined" removed (you launched the attack, so you already know). The defender still
	-- gets a coalesced "Under Attack" so a surprise assault surfaces -- without one toast per engagement.
	coalesceToast("bad", data.defenderTag, "attacked|" .. tostring(data.attackerTag), "Under Attack",
		string.format("%s has engaged our forces in province %s.", displayName(data.attackerTag), tostring(data.provinceId)),
		function(n)
			return string.format("%s is attacking on %d more front%s.", displayName(data.attackerTag), n, n == 1 and "" or "s")
		end,
		"battle.started.defender")
end

local function onBattleResolved(data)
	if data.winnerTag then
		coalesceToast("good", data.winnerTag, "victory|" .. tostring(data.loserTag), "Victory",
			string.format("Our forces prevailed over %s in province %s.", displayName(data.loserTag), tostring(data.provinceId)),
			function(n)
				return string.format("%d more victor%s over %s.", n, n == 1 and "y" or "ies", displayName(data.loserTag))
			end,
			"battle.won")
	end
	if data.loserTag then
		coalesceToast("bad", data.loserTag, "defeat|" .. tostring(data.winnerTag), "Defeat",
			string.format("Our army was beaten by %s in province %s.", displayName(data.winnerTag), tostring(data.provinceId)),
			function(n)
				return string.format("%d more defeat%s by %s.", n, n == 1 and "" or "s", displayName(data.winnerTag))
			end,
			"battle.lost")
	end
end

local function onLawPassed(data)
	broadcast(makePayload("good", "Law Passed",
		string.format("The assembly has passed %s.", tostring(data.policyId or "the motion")),
		"self", data.tag, "law.passed"))
end

local function onLawFailed(data)
	broadcast(makePayload("bad", "Law Rejected",
		string.format("Repeated setbacks have killed the motion for %s.", tostring(data.policyId or "?")),
		"self", data.tag, "law.failed"))
end

local function onPolicyEnacted(data)
	broadcast(makePayload("good", "Policy Enacted",
		string.format("%s is now in force.", tostring(data.policyId)),
		"self", data.tag, "policy.enacted"))
end

local function onPolicyRepealed(data)
	local reason = (data.reason or data.trigger) == "pp_exhausted" and " (political power exhausted)" or ""
	broadcast(makePayload("warn", "Policy Repealed",
		string.format("%s has been repealed%s.", tostring(data.policyId), reason),
		"self", data.tag, "policy.repealed"))
end

local function onLeaderAppointed(data)
	broadcast(makePayload("info", "Leader Appointed",
		string.format("A new %s has taken office.", tostring(data.slot or "minister")),
		"self", data.tag, "leader.appointed"))
end

local function onTransitionStarted(data)
	broadcast(makePayload("warn", "Government Transition",
		string.format("Transition to %s has begun.", tostring(data.to or "a new government")),
		"self", data.tag, "transition.started"))
end

local function onTransitionCompleted(data)
	broadcast(makePayload("good", "Transition Complete",
		string.format("The state has completed its transition to %s.", tostring(data.to or "a new government")),
		"self", data.tag, "transition.completed"))
end

local function onFactionTierChanged(data)
	if data.to == "powerful" then
		broadcast(makePayload("warn", "Faction Rising",
			string.format("%s have grown powerful.", tostring(data.factionId or "A faction")),
			"self", data.tag, "faction.tier.powerful"))
	elseif data.to == "marginalized" then
		broadcast(makePayload("info", "Faction Marginalized",
			string.format("%s have faded into the background.", tostring(data.factionId or "A faction")),
			"self", data.tag, "faction.tier.marginalized"))
	end
end

local function onCountryClaimed(data)
	broadcast(makePayload("good", "Realm Claimed",
		string.format("You now govern %s.", displayName(data.tag)),
		"self", data.tag, "country.claimed"))
end

-- Forming a nation (adopting a formable identity). data = { tag, formableTag }; the country's displayName is
-- already the formable's name by publish time, so displayName(tag) returns the new identity. Green success
-- toast + a rare global announcement (forming is one-time, so it is not spammy).
local function onNationFormed(data)
	if not data or not data.tag then return end
	broadcast(makePayload("success", "Nation Formed",
		string.format("You have forged %s!", displayName(data.tag)),
		"self", data.tag, "nation.formed", { ttl = 12 }))
	broadcast(makePayload("info", "A New Power Rises",
		string.format("The nation of %s has been forged.", displayName(data.tag)),
		"global", nil, "nation.formed.global", { ttl = 8 }))
end

-- Releasing a breakaway nation from your releasable cores. data = { overlordTag, subjectTag }. Notifies the
-- overlord (the releaser); the freed nation is AI today.
local function onSubjectReleased(data)
	if not data or not data.overlordTag then return end
	broadcast(makePayload("success", "Nation Released",
		string.format("%s has risen as a nation.", displayName(data.subjectTag)),
		"self", data.overlordTag, "subject.released", { ttl = 10 }))
end

local function fleetOwnerOf(fleetId)
	if not fleetId then return nil end
	local fleet = ctx.WorldState.getFleet and ctx.WorldState.getFleet(fleetId)
	return fleet and fleet.ownerTag or nil
end

local function onFleetMoveCompleted(data)
	broadcast(makePayload("info", "Fleet Arrived",
		string.format("Your fleet has anchored at province %s.", tostring(data.provinceId or "?")),
		"self", data.ownerTag, "fleet.move.completed"))
end

local function onShipRecruited(data)
	broadcast(makePayload("info", "Ship Commissioned",
		string.format("A new %s has joined the fleet at province %s.",
			tostring(data.typeId or "ship"), tostring(data.provinceId or "?")),
		"self", data.ownerTag, "ship.recruited"))
end

local function onNavalBattleStarted(data)
	local attackerTag = fleetOwnerOf(data.attacker)
	local defenderTag = fleetOwnerOf(data.defender)
	broadcast(makePayload("warn", "Naval Engagement",
		string.format("Our fleet has engaged %s at sea near province %s.",
			displayName(defenderTag), tostring(data.provinceId or "?")),
		"self", attackerTag, "naval.battle.started"))
	broadcast(makePayload("bad", "Fleet Under Attack",
		string.format("%s has engaged our fleet near province %s.",
			displayName(attackerTag), tostring(data.provinceId or "?")),
		"self", defenderTag, "naval.battle.started.defender"))
end

local function onNavalBattleResolved(data)
	local attackerTag = data.attackerTag or fleetOwnerOf(data.attackerId)
	local defenderTag = data.defenderTag or fleetOwnerOf(data.defenderId)
	if data.winner == "attacker" then
		broadcast(makePayload("good", "Naval Victory",
			string.format("Our fleet has driven off %s at sea.", displayName(defenderTag)),
			"self", attackerTag, "naval.battle.won"))
		broadcast(makePayload("bad", "Naval Defeat",
			string.format("Our fleet was beaten at sea by %s.", displayName(attackerTag)),
			"self", defenderTag, "naval.battle.lost"))
	elseif data.winner == "defender" then
		broadcast(makePayload("bad", "Naval Defeat",
			string.format("Our fleet was beaten at sea by %s.", displayName(defenderTag)),
			"self", attackerTag, "naval.battle.lost"))
		broadcast(makePayload("good", "Naval Victory",
			string.format("Our fleet has driven off %s at sea.", displayName(attackerTag)),
			"self", defenderTag, "naval.battle.won"))
	elseif data.winner == "mutual" then
		broadcast(makePayload("bad", "Mutual Destruction",
			string.format("Both fleets sank in the engagement near province %s.", tostring(data.provinceId or "?")),
			"self", attackerTag, "naval.battle.mutual"))
		broadcast(makePayload("bad", "Mutual Destruction",
			string.format("Both fleets sank in the engagement near province %s.", tostring(data.provinceId or "?")),
			"self", defenderTag, "naval.battle.mutual"))
	end
end

local function onWarDeclared(data)
	broadcast(makePayload("bad", "War Declared",
		string.format("%s has declared war upon us.", displayName(data.attackerTag)),
		"self", data.defenderTag, "war.declared.defender", { ttl = 12 }))
	broadcast(makePayload("warn", "War Declared",
		string.format("We have declared war upon %s.", displayName(data.defenderTag)),
		"self", data.attackerTag, "war.declared.attacker", { ttl = 8 }))
end

local function onPeaceProposed(data)
	broadcast(makePayload("info", "Peace Proposed",
		string.format("%s proposes peace (%s).", displayName(data.fromTag), tostring(data.terms and data.terms.type or "?")),
		"self", data.toTag, "peace.proposed", { ttl = 15 }))
end

local function onPeaceConcluded(data)
	-- Annexation force-concludes the loser's side-wars, but that path already sends the affected human a
	-- targeted "War Ended" notice (and the loser is being deleted). Skip the generic white_peace toast here
	-- so those players don't get a second, misleading notification.
	if data.peaceTerms and data.peaceTerms.reason == "annexed" then
		return
	end
	local termType = data.peaceTerms and data.peaceTerms.type or "white_peace"
	broadcast(makePayload("good", "Peace Concluded",
		string.format("Peace with %s has been settled (%s).", displayName(data.defenderTag), termType),
		"self", data.attackerTag, "peace.concluded", { ttl = 10 }))
	broadcast(makePayload("good", "Peace Concluded",
		string.format("Peace with %s has been settled (%s).", displayName(data.attackerTag), termType),
		"self", data.defenderTag, "peace.concluded", { ttl = 10 }))
end

local function onPeaceProposalRejected(data)
	broadcast(makePayload("warn", "Peace Rejected",
		"Our peace proposal has been rejected.",
		"self", nil, "peace.rejected", { ttl = 8 }))
end

local function onPeaceProposalExpired(data)
	-- Quiet event - no toast; UI will reflect from state
end

local function onRulerDied(data)
	if not data or not data.tag then return end
	local r = data.ruler
	local who = r and (((r.title or "Ruler") .. " " .. (r.firstName or "")):gsub("%s+$", "")) or "The ruler"
	broadcast(makePayload("warn", "The Crown Passes", who .. " has died.", "self", data.tag, "ruler.died", { ttl = 10 }))
end

local function onSuccessionResolved(data)
	if not data or not data.tag then return end
	local who = data.rulerName or "A new ruler"
	local body = data.regency and (who .. " ascends under a regency.") or (who .. " now holds power.")
	broadcast(makePayload("info", "Succession", body, "self", data.tag, "succession", { ttl = 10 }))
end


local SUBSCRIPTIONS = {
	WarDeclared             = onWarDeclared,
	PeaceProposed           = onPeaceProposed,
	PeaceConcluded          = onPeaceConcluded,
	PeaceProposalRejected   = onPeaceProposalRejected,
	PeaceProposalExpired    = onPeaceProposalExpired,
	ProvinceOccupied        = onProvinceOccupied,
	RegimentRecruitCancelled = onRecruitCancelled,
	BattleStarted           = onBattleStarted,
	BattleResolved          = onBattleResolved,
	CountryLawPassed        = onLawPassed,
	CountryLawFailed        = onLawFailed,
	CountryPolicyEnacted    = onPolicyEnacted,
	CountryPolicyRepealed   = onPolicyRepealed,
	LeaderAppointed         = onLeaderAppointed,
	CountryTransitionStarted   = onTransitionStarted,
	CountryTransitionCompleted = onTransitionCompleted,
	FactionTierChanged      = onFactionTierChanged,
	CountryClaimed          = onCountryClaimed,
	NationFormed            = onNationFormed,
	SubjectReleased         = onSubjectReleased,
	FleetMoveCompleted      = onFleetMoveCompleted,
	ShipRecruited           = onShipRecruited,
	NavalBattleStarted      = onNavalBattleStarted,
	NavalBattleResolved     = onNavalBattleResolved,
	RulerDied               = onRulerDied,
	SuccessionResolved      = onSuccessionResolved,
}

function NotificationBroadcaster.setRemote(r)
	remote = r
end

function NotificationBroadcaster.push(payload)
	broadcast(payload)
end

function NotificationBroadcaster.register(context)
	ctx = context
	context.NotificationBroadcaster = {
		push = NotificationBroadcaster.push,
		setRemote = NotificationBroadcaster.setRemote,
	}
	for channelKey, handler in SUBSCRIPTIONS do
		local channel = ctx.Channels[channelKey]
		if channel then
			ctx.EventBus.subscribe(channel, function(data)
				if not data then return end
				local ok, err = pcall(handler, data)
				if not ok then
					warn("[NotificationBroadcaster] handler '" .. channelKey .. "' failed: " .. tostring(err))
				end
			end)
		end
	end
end

return NotificationBroadcaster
