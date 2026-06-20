local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Spacing = DesignSystem.Spacing
local ScreenKit = require(script.Parent.ScreenKit)
local Components = script.Parent.Parent.Components
local Button = require(Components.Button)
local CountryBadge = require(Components.CountryBadge)

local DiplomacyScreen = {}

local TABS = {
	{ key = "nations", label = "Nations" },
	{ key = "wars", label = "Wars" },
	{ key = "proposals", label = "Proposals" },
}

local TERMS_LABEL = {
	white_peace = "White Peace",
	annex_occupied = "Demand Lands",
}

local CHIP = {
	WAR = Colors.Negative,
	TRUCE = Colors.Warning,
	PEACE = Colors.TextSecondary,
	YOU = Colors.Accent,
}

local function nameOf(cache, tag)
	local c = cache.getCountry(tag)
	return (c and (c.displayName or c.name)) or tag or "?"
end

local function countryColor(c)
	local col = c and c.color
	if type(col) == "table" and col[1] then
		return Color3.fromRGB(col[1], col[2], col[3])
	end
	return nil
end

local function activeWarWith(cache, mineTag, otherTag)
	for _, war in pairs(cache.allWars()) do
		if
			war.status == "active"
			and (
				(war.attackerTag == mineTag and war.defenderTag == otherTag)
				or (war.defenderTag == mineTag and war.attackerTag == otherTag)
			)
		then
			return war
		end
	end
	return nil
end

local function statusOf(cache, mineTag, otherTag)
	if not mineTag then
		return "PEACE"
	end
	if otherTag == mineTag then
		return "YOU"
	end
	if activeWarWith(cache, mineTag, otherTag) then
		return "WAR"
	end
	local mine = cache.getCountry(mineTag)
	local other = cache.getCountry(otherTag)
	if (mine and mine.truces and mine.truces[otherTag]) or (other and other.truces and other.truces[mineTag]) then
		return "TRUCE"
	end
	return "PEACE"
end

function DiplomacyScreen.create(ctx)
	local cache = ctx.cache
	local mineTag = ctx.tag
	local handle
	local conns = {}
	local dirty = false

	local function chip(parent, label)
		local l = Instance.new("TextLabel")
		l.Name = "Chip"
		l.AnchorPoint = Vector2.new(1, 0.5)
		l.Position = UDim2.new(1, -6, 0.5, 0)
		l.Size = UDim2.fromOffset(58, 18)
		l.BackgroundTransparency = 1
		l.Text = label
		l.TextColor3 = CHIP[label] or Colors.TextSecondary
		l.TextXAlignment = Enum.TextXAlignment.Right
		Typography.apply(l, "label")
		l.Parent = parent
	end

	local function nationRow(parent, tag, status, order)
		local row = Instance.new("Frame")
		row.Name = "Nation"
		row.Size = UDim2.new(1, 0, 0, 44)
		row.BackgroundTransparency = 1
		row.LayoutOrder = order
		row.Parent = parent

		local badge = CountryBadge.create({
			code = tag,
			countryColor = countryColor(cache.getCountry(tag)),
			size = "sm",
			parent = row,
		})
		badge.AnchorPoint = Vector2.new(0, 0.5)
		badge.Position = UDim2.fromScale(0, 0.5)

		local nameLbl = Instance.new("TextLabel")
		nameLbl.Name = "Name"
		nameLbl.Position = UDim2.fromOffset(46, 0)
		nameLbl.Size = UDim2.new(1, -110, 1, 0)
		nameLbl.BackgroundTransparency = 1
		nameLbl.Text = nameOf(cache, tag)
		nameLbl.TextColor3 = Colors.TextPrimary
		nameLbl.TextXAlignment = Enum.TextXAlignment.Left
		nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
		Typography.apply(nameLbl, "bodyLg")
		nameLbl.Parent = row

		chip(row, status)
		return row
	end

	local function declareWar(tag)
		ctx.fire("DeclareWar", tag)
	end
	local function proposePeace(tag, kind)
		ctx.fire("ProposePeace", tag, { type = kind, proposerTag = mineTag })
	end

	local renderers = {
		nations = function(body)
			if not mineTag then
				ScreenKit.note(body, "Claim a country to conduct diplomacy.", 1)
				return
			end
			local entries = {}
			for tag in pairs(cache.allCountries()) do
				entries[#entries + 1] = { tag = tag, name = nameOf(cache, tag) }
			end
			table.sort(entries, function(a, b)
				return a.name < b.name
			end)
			if #entries == 0 then
				ScreenKit.note(body, "Waiting for the world to replicate.", 1)
				return
			end

			local order = 0
			for _, entry in ipairs(entries) do
				order += 1
				local status = statusOf(cache, mineTag, entry.tag)
				nationRow(body, entry.tag, status, order)
				if status == "WAR" then
					local actions = ScreenKit.buttonRow(body, order + 0.1)
					actions.Size = UDim2.new(1, 0, 0, 36)
					Button.create({
						parent = actions,
						variant = "secondary",
						text = "White Peace",
						size = "sm",
						width = 150,
						onClick = function()
							proposePeace(entry.tag, "white_peace")
						end,
					})
					Button.create({
						parent = actions,
						variant = "primary",
						text = "Demand Lands",
						size = "sm",
						width = 150,
						onClick = function()
							proposePeace(entry.tag, "annex_occupied")
						end,
					})
				elseif status == "PEACE" then
					local actions = ScreenKit.buttonRow(body, order + 0.1)
					actions.Size = UDim2.new(1, 0, 0, 36)
					Button.create({
						parent = actions,
						variant = "danger",
						text = "Declare War",
						size = "sm",
						width = 150,
						onClick = function()
							declareWar(entry.tag)
						end,
					})
				elseif status == "TRUCE" then
					ScreenKit.note(body, "Truce in effect. War cannot be declared.", order + 0.1)
				end
				ScreenKit.spacer(body, Spacing.space1, order + 0.2)
			end
		end,
		wars = function(body)
			if not mineTag then
				ScreenKit.note(body, "Claim a country to wage war.", 1)
				return
			end
			local wars = {}
			for _, war in pairs(cache.allWars()) do
				if war.status == "active" and (war.attackerTag == mineTag or war.defenderTag == mineTag) then
					wars[#wars + 1] = war
				end
			end
			table.sort(wars, function(a, b)
				return (a.declaredMonthIndex or 0) < (b.declaredMonthIndex or 0)
			end)
			if #wars == 0 then
				ScreenKit.note(body, "You are at peace with the world.", 1)
				return
			end

			local order = 0
			for _, war in ipairs(wars) do
				local aggressor = war.attackerTag == mineTag
				local opponent = aggressor and war.defenderTag or war.attackerTag
				local score = war.score or 0
				if not aggressor then
					score = -score
				end
				local myExh = aggressor and war.attackerExhaustion or war.defenderExhaustion
				local theirExh = aggressor and war.defenderExhaustion or war.attackerExhaustion
				order += 1
				ScreenKit.section(body, "War with " .. nameOf(cache, opponent), order)
				order += 1
				ScreenKit.stat(body, {
					icon = "War",
					label = "Role",
					value = aggressor and "Aggressor" or "Defender",
					layoutOrder = order,
				})
				order += 1
				ScreenKit.stat(body, {
					icon = "Battle",
					label = "War Score",
					value = string.format("%+d", math.floor(score)),
					valueColor = score >= 0 and "positive" or "negative",
					layoutOrder = order,
				})
				order += 1
				ScreenKit.stat(body, {
					icon = "Unrest",
					label = "Exhaustion",
					value = string.format("you %.1f  \u{00B7}  them %.1f", myExh or 0, theirExh or 0),
					layoutOrder = order,
				})
				order += 1
				local actions = ScreenKit.buttonRow(body, order)
				Button.create({
					parent = actions,
					variant = "secondary",
					text = "White Peace",
					width = 150,
					onClick = function()
						proposePeace(opponent, "white_peace")
					end,
				})
				Button.create({
					parent = actions,
					variant = "primary",
					text = "Demand Lands",
					width = 150,
					onClick = function()
						proposePeace(opponent, "annex_occupied")
					end,
				})
			end
		end,
		proposals = function(body)
			if not mineTag then
				ScreenKit.note(body, "Claim a country to negotiate peace.", 1)
				return
			end
			local incoming, outgoing = {}, {}
			for id, prop in pairs(cache.allPeaceProposals()) do
				if prop.status == "pending" then
					if prop.toTag == mineTag then
						incoming[#incoming + 1] = { id = id, prop = prop }
					elseif prop.fromTag == mineTag then
						outgoing[#outgoing + 1] = { id = id, prop = prop }
					end
				end
			end

			local order = 0
			order += 1
			ScreenKit.section(body, "Incoming", order)
			if #incoming == 0 then
				order += 1
				ScreenKit.note(body, "No offers awaiting your response.", order)
			else
				for _, entry in ipairs(incoming) do
					local terms = entry.prop.terms or {}
					order += 1
					ScreenKit.stat(body, {
						icon = "Diplomacy",
						label = nameOf(cache, entry.prop.fromTag),
						value = TERMS_LABEL[terms.type] or "Peace",
						layoutOrder = order,
					})
					order += 1
					local actions = ScreenKit.buttonRow(body, order)
					Button.create({
						parent = actions,
						variant = "primary",
						text = "Accept",
						width = 130,
						onClick = function()
							ctx.fire("AcceptPeace", entry.id)
						end,
					})
					Button.create({
						parent = actions,
						variant = "danger",
						text = "Reject",
						width = 130,
						onClick = function()
							ctx.fire("RejectPeace", entry.id)
						end,
					})
				end
			end

			order += 1
			ScreenKit.section(body, "Outgoing", order)
			if #outgoing == 0 then
				order += 1
				ScreenKit.note(body, "You have no pending offers.", order)
			else
				for _, entry in ipairs(outgoing) do
					local terms = entry.prop.terms or {}
					order += 1
					ScreenKit.stat(body, {
						icon = "Diplomacy",
						label = nameOf(cache, entry.prop.toTag),
						value = TERMS_LABEL[terms.type] or "Peace",
						layoutOrder = order,
					})
					order += 1
					local actions = ScreenKit.buttonRow(body, order)
					Button.create({
						parent = actions,
						variant = "ghost",
						text = "Cancel",
						width = 130,
						onClick = function()
							ctx.fire("CancelPeaceProposal", entry.id)
						end,
					})
				end
			end
		end,
	}

	local function render(tab)
		handle.clearBody()
		local fn = renderers[tab] or renderers.nations
		fn(handle.body)
	end

	local currentTab = "nations"
	local function scheduleRefresh()
		if dirty then
			return
		end
		dirty = true
		task.defer(function()
			dirty = false
			if handle and handle.root and handle.root.Parent then
				render(currentTab)
			end
		end)
	end

	local mine = mineTag and cache.getCountry(mineTag)
	handle = ScreenKit.open(ctx, {
		name = "DiplomacyScreen",
		title = "Diplomacy",
		subtitle = (mine and (mine.displayName or mineTag)) or "Realm",
		tabs = TABS,
		activeTab = "nations",
		onTab = function(key)
			currentTab = key
			render(key)
		end,
	})
	render("nations")

	table.insert(conns, cache.onChangePrefix("countries", scheduleRefresh))
	table.insert(conns, cache.onChangePrefix("wars", scheduleRefresh))
	table.insert(conns, cache.onChangePrefix("peaceProposals", scheduleRefresh))

	return {
		root = handle.root,
		destroy = function()
			for _, d in conns do
				pcall(d)
			end
			handle.destroy()
		end,
	}
end

return DiplomacyScreen
