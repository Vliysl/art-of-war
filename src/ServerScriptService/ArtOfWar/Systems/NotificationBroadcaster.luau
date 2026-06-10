local Players = game:GetService("Players")

local NotificationBroadcaster = {}

local ctx
local remote
local pending = {}

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

local function onArmyCreated(data)
	broadcast(makePayload("info", "Army Raised",
		string.format("Regiments assembled in %s.", tostring(data.provinceId or "?")),
		"self", data.tag, "army.created"))
end

local function onArmyMoveCompleted(data)
	-- quiet success; only notify owner
	broadcast(makePayload("info", "Army Arrived",
		string.format("Your force has reached province %s.", tostring(data.provinceId or "?")),
		"self", data.tag, "army.move.completed"))
end

local function onProvinceOccupied(data)
	broadcast(makePayload("good", "Province Occupied",
		string.format("Province %s taken by %s.", tostring(data.provinceId), displayName(data.newController)),
		"self", data.newController, "province.occupied"))
	if data.oldController and data.oldController ~= data.newController then
		broadcast(makePayload("bad", "Province Lost",
			string.format("Province %s has fallen to %s.", tostring(data.provinceId), displayName(data.newController)),
			"self", data.oldController, "province.lost"))
	end
end

local function onBattleStarted(data)
	broadcast(makePayload("warn", "Battle Joined",
		string.format("Forces engaged against %s in province %s.", displayName(data.defenderTag), tostring(data.provinceId)),
		"self", data.attackerTag, "battle.started"))
	broadcast(makePayload("bad", "Under Attack",
		string.format("%s has engaged our army in province %s.", displayName(data.attackerTag), tostring(data.provinceId)),
		"self", data.defenderTag, "battle.started.defender"))
end

local function onBattleResolved(data)
	if data.winnerTag then
		broadcast(makePayload("good", "Victory",
			string.format("Our forces have prevailed over %s in province %s.", displayName(data.loserTag or "?"), tostring(data.provinceId)),
			"self", data.winnerTag, "battle.won"))
	end
	if data.loserTag then
		broadcast(makePayload("bad", "Defeat",
			string.format("Our army was beaten by %s in province %s.", displayName(data.winnerTag or "?"), tostring(data.provinceId)),
			"self", data.loserTag, "battle.lost"))
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


local SUBSCRIPTIONS = {
	WarDeclared             = onWarDeclared,
	PeaceProposed           = onPeaceProposed,
	PeaceConcluded          = onPeaceConcluded,
	PeaceProposalRejected   = onPeaceProposalRejected,
	PeaceProposalExpired    = onPeaceProposalExpired,
	ArmyCreated             = onArmyCreated,
	ArmyMoveCompleted       = onArmyMoveCompleted,
	ProvinceOccupied        = onProvinceOccupied,
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
	FleetMoveCompleted      = onFleetMoveCompleted,
	ShipRecruited           = onShipRecruited,
	NavalBattleStarted      = onNavalBattleStarted,
	NavalBattleResolved     = onNavalBattleResolved,
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
