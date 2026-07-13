local Players = game:GetService("Players")

local PlayerAuthority = {}

local ctx
local claimsByUser = {}
local claimsByTag = {}

local function currentSimTime()
	return (ctx and ctx.TickScheduler and ctx.TickScheduler.getSimTime() or 0)
end

local function tagFor(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return nil end
	local claim = claimsByUser[player.UserId]
	return claim and claim.tag or nil
end

local function playerFor(tag)
	local claim = claimsByTag[tag]
	if not claim then return nil end
	return Players:GetPlayerByUserId(claim.userId)
end

local function writeClaimField(tag, userId)
	local country = ctx.WorldState.getCountry(tag)
	if not country then return end
	country.claimedBy = userId
	-- Stamp when this player took the nation, so FormationRecordStore can measure "time to form" for the
	-- fastest-time leaderboard. Only set on a real claim (userId present), not on release/unclaim.
	if userId then
		country.claimedAt = os.time()
	end
	ctx.WorldState.setCountry(tag, country)
end

local function claim(player, tag)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return false end
	if type(tag) ~= "string" or tag == "" then return false end
	if not ctx.WorldState.getCountry(tag) then return false end
	if claimsByTag[tag] and claimsByTag[tag].userId ~= player.UserId then return false end

	local existing = claimsByUser[player.UserId]
	if existing then
		if existing.tag == tag then return true end
		claimsByTag[existing.tag] = nil
		writeClaimField(existing.tag, nil)
		ctx.EventBus.publish(ctx.Channels.CountryReleased, {
			userId = player.UserId, tag = existing.tag, name = player.Name,
		})
	end

	local record = { userId = player.UserId, tag = tag, since = currentSimTime() }
	claimsByUser[player.UserId] = record
	claimsByTag[tag] = record
	writeClaimField(tag, player.UserId)
	-- Client-readable claim: CombatView's viewer-relative battle colors (playerTide) and any
	-- other local read of "my tag" key off this attribute -- it was read but never written.
	player:SetAttribute("CountryTag", tag)
	ctx.EventBus.publish(ctx.Channels.CountryClaimed, {
		userId = player.UserId, tag = tag, name = player.Name,
	})
	return true
end

local function release(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return false end
	local record = claimsByUser[player.UserId]
	if not record then return false end
	claimsByUser[player.UserId] = nil
	claimsByTag[record.tag] = nil
	writeClaimField(record.tag, nil)
	player:SetAttribute("CountryTag", nil)
	ctx.EventBus.publish(ctx.Channels.CountryReleased, {
		userId = player.UserId, tag = record.tag, name = player.Name,
	})
	return true
end

local function releaseByUserId(userId)
	local record = claimsByUser[userId]
	if not record then return false end
	claimsByUser[userId] = nil
	claimsByTag[record.tag] = nil
	writeClaimField(record.tag, nil)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		player:SetAttribute("CountryTag", nil)
	end
	ctx.EventBus.publish(ctx.Channels.CountryReleased, {
		userId = userId, tag = record.tag,
	})
	return true
end

local function availableTags()
	local available = {}
	for tag in ctx.WorldState.allCountries() do
		if not claimsByTag[tag] then
			table.insert(available, tag)
		end
	end
	table.sort(available)
	return available
end

local function allClaims()
	local snapshot = {}
	for userId, record in claimsByUser do
		table.insert(snapshot, { userId = userId, tag = record.tag, since = record.since })
	end
	return snapshot
end

-- S3: the set of countries that must be simulated per-tick (economy / political power /
-- factions). Players only ever view their OWN country's economy; there is no AI that acts on
-- the others, so unclaimed-and-not-at-war countries are frozen at their current state (their
-- ClaimScreen "starting stats" stay the initial values, which is correct). Active-war
-- participants are included defensively.
local function relevantSet()
	local set = {}
	for tag in claimsByTag do set[tag] = true end
	if ctx and ctx.WorldState and ctx.WorldState.allWars then
		for _, war in ctx.WorldState.allWars() do
			if war.status == "active" then
				if war.attackerTag then set[war.attackerTag] = true end
				if war.defenderTag then set[war.defenderTag] = true end
			end
		end
	end
	return set
end

function PlayerAuthority.register(context)
	ctx = context
	ctx.PlayerAuthority = {
		claim = claim,
		release = release,
		tagFor = tagFor,
		playerFor = playerFor,
		availableTags = availableTags,
		allClaims = allClaims,
		relevantSet = relevantSet,
	}
	Players.PlayerRemoving:Connect(function(player)
		releaseByUserId(player.UserId)
	end)
end

return PlayerAuthority
