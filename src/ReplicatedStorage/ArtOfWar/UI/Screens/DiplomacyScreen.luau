-- DiplomacyScreen: an HOI4/RoN-style list -> country-profile -> contextual-actions flow.
-- The alphabetical, searchable nation list drills into a rich per-country profile (flag + controller
-- avatar + relation pill + opinion meter + nation info + only-valid actions). War state and pending
-- peace/pact offers are folded into the profile. Major actions confirm via a modal. A deep-link entry
-- point (ctx.data.focusTag) opens straight to a profile -- e.g. the province-panel crest.

local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local ScreenKit = require(script.Parent.ScreenKit)
local Components = script.Parent.Parent.Components
local Button = require(Components.Button)
local Modal = require(Components.Modal)
local CountryBadge = require(Components.CountryBadge)
local SimClock = require(script.Parent.Parent.Parent.Modules.SimClock)

local DiplomacyScreen = {}

local TERMS_LABEL = {
	white_peace = "White Peace",
	annex_occupied = "Demand Lands",
	vassalize = "Vassalize",
}

-- Primary relation -> { label, color }. Priority resolved in relationStatus().
local RELATION = {
	YOU = { label = "You", color = Colors.Accent },
	WAR = { label = "At War", color = Colors.Negative },
	SUBJECT = { label = "Your Subject", color = Colors.Accent },
	OVERLORD = { label = "Your Overlord", color = Colors.Warning },
	ALLY = { label = "Allied", color = Colors.Positive },
	GUARANTEE = { label = "Guaranteed", color = Colors.Positive },
	NAP = { label = "Non-Aggression", color = Colors.Warning },
	TRUCE = { label = "Truce", color = Colors.Warning },
	NEUTRAL = { label = "Neutral", color = Colors.TextSecondary },
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

local function prettify(id)
	if type(id) ~= "string" or id == "" then
		return "—"
	end
	local out = {}
	for word in id:gmatch("[^_%s]+") do
		out[#out + 1] = word:sub(1, 1):upper() .. word:sub(2)
	end
	return table.concat(out, " ")
end

-- Is a stored pact expiry still in the future? A nil expiresAt means there is NO such pact -> inactive.
-- If the sim clock has not synced yet (SimClock.now() nil) but an expiry exists, treat the pact as active.
local function stillActive(expiresAt)
	if not expiresAt then
		return false
	end
	local nowT = SimClock.now()
	return (not nowT) or expiresAt > nowT
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

-- The single most salient relation between mineTag and otherTag, for the list chip + profile pill.
local function relationStatus(cache, mineTag, otherTag)
	if not mineTag or otherTag == mineTag then
		return "YOU"
	end
	if activeWarWith(cache, mineTag, otherTag) then
		return "WAR"
	end
	local mine = cache.getCountry(mineTag)
	local other = cache.getCountry(otherTag)
	if mine then
		if mine.subjects and mine.subjects[otherTag] then
			return "SUBJECT"
		end
		if mine.subjectOf == otherTag then
			return "OVERLORD"
		end
		if mine.allies and mine.allies[otherTag] then
			return "ALLY"
		end
		if (mine.guarantees and mine.guarantees[otherTag]) or (mine.guaranteedBy and mine.guaranteedBy[otherTag]) then
			return "GUARANTEE"
		end
		if mine.naps and stillActive(mine.naps[otherTag]) then
			return "NAP"
		end
		if mine.truces and stillActive(mine.truces[otherTag]) then
			return "TRUCE"
		end
	end
	if other and other.truces and stillActive(other.truces[mineTag]) then
		return "TRUCE"
	end
	return "NEUTRAL"
end

-- A procedural, debounced search box (no shell texture -> no load race). initialText preserves the query
-- across re-renders.
local function makeSearchBox(parent, placeholder, initialText, onChanged)
	local box = Instance.new("TextBox")
	box.Name = "Search"
	box.Size = UDim2.new(1, 0, 0, 34)
	box.BackgroundColor3 = Colors.SurfaceSunken
	box.BorderSizePixel = 0
	box.Text = initialText or ""
	box.PlaceholderText = placeholder
	box.PlaceholderColor3 = Colors.TextTertiary
	box.TextColor3 = Colors.TextPrimary
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.ClearTextOnFocus = false
	box.LayoutOrder = 0
	Typography.apply(box, "bodyMd")
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = box
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = box
	local stroke = Instance.new("UIStroke")
	stroke.Color = Colors.BorderSubtle
	stroke.Parent = box
	box.Parent = parent
	local debounce
	box:GetPropertyChangedSignal("Text"):Connect(function()
		local text = box.Text
		if debounce then
			task.cancel(debounce)
		end
		debounce = task.delay(0.1, function()
			debounce = nil
			onChanged(text)
		end)
	end)
	return box
end

function DiplomacyScreen.create(ctx)
	local cache = ctx.cache
	local mineTag = ctx.tag
	local handle
	local conns = {}
	local dirty = false

	-- View state. focusTag deep-links straight to a profile (e.g. the province-panel crest).
	local mode = "list"
	local currentTag = nil
	local listQuery = ""
	local focusTag = ctx.data and ctx.data.focusTag
	if focusTag and focusTag ~= mineTag then
		-- Deep-link straight to the profile. renderProfile's guard handles a not-yet-synced or annexed tag,
		-- and the "ex:" signature term re-renders once the country record arrives.
		mode = "profile"
		currentTag = focusTag
	end

	local render, showList, showProfile

	-- ---- remote fire helpers -------------------------------------------------
	local function declareWar(tag)
		ctx.fire("DeclareWar", tag)
	end
	local function proposePeace(tag, kind)
		ctx.fire("ProposePeace", tag, { type = kind, proposerTag = mineTag })
	end
	local function improveRelations(tag)
		ctx.fire("ImproveRelations", tag)
	end
	local function proposePact(tag, kind)
		ctx.fire("ProposePact", tag, kind)
	end
	local function breakPact(tag, kind)
		ctx.fire("BreakPact", tag, kind)
	end
	local function releaseSubject(tag)
		ctx.fire("ReleaseSubject", tag)
	end
	local function annexSubject(tag)
		ctx.fire("AnnexSubject", tag)
	end

	-- ---- relation reads (bound to cache/mineTag) -----------------------------
	local function opinionOf(other)
		local me = mineTag and cache.getCountry(mineTag)
		return (me and me.opinion and me.opinion[other]) or 0
	end
	local function napActive(other)
		local me = mineTag and cache.getCountry(mineTag)
		return me ~= nil and me.naps ~= nil and stillActive(me.naps[other])
	end
	local function truceActive(other)
		local me = mineTag and cache.getCountry(mineTag)
		local other2 = cache.getCountry(other)
		return (me and me.truces and stillActive(me.truces[other]))
			or (other2 and other2.truces and stillActive(other2.truces[mineTag]))
			or false
	end
	local function isAllied(other)
		local me = mineTag and cache.getCountry(mineTag)
		return (me and me.allies and me.allies[other]) == true
	end
	local function iGuarantee(other)
		local me = mineTag and cache.getCountry(mineTag)
		return (me and me.guarantees and me.guarantees[other]) == true
	end

	-- ---- a Cancel/Confirm modal for major actions ----------------------------
	local function confirm(opts)
		local modal = Modal.create({
			parent = ctx.modalLayer,
			title = opts.title,
			subtitle = opts.subtitle,
			width = 420,
			height = 220,
			footer = true,
			dismissable = true,
			onClose = function() end,
		})
		local msg = Instance.new("TextLabel")
		msg.Size = UDim2.new(1, -24, 1, -12)
		msg.Position = UDim2.fromOffset(12, 6)
		msg.BackgroundTransparency = 1
		msg.Text = opts.body or ""
		msg.TextWrapped = true
		msg.TextColor3 = Colors.TextSecondary
		msg.TextXAlignment = Enum.TextXAlignment.Left
		msg.TextYAlignment = Enum.TextYAlignment.Top
		Typography.apply(msg, "bodyMd")
		msg.Parent = modal.content
		Button.create({
			parent = modal.footer,
			variant = "ghost",
			text = "Cancel",
			layoutOrder = 1,
			onClick = function()
				modal.close()
			end,
		})
		Button.create({
			parent = modal.footer,
			variant = opts.variant or "danger",
			text = opts.confirmText or "Confirm",
			layoutOrder = 2,
			onClick = function()
				opts.onConfirm()
				modal.close()
			end,
		})
	end

	-- ---- a centered -200..+200 opinion meter (ProgressBar is left-origin only) ----
	local function opinionMeter(parent, value, order)
		local container = Instance.new("Frame")
		container.Name = "OpinionMeter"
		container.Size = UDim2.new(1, 0, 0, 30)
		container.BackgroundTransparency = 1
		container.LayoutOrder = order
		container.Parent = parent

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 0, 16)
		label.BackgroundTransparency = 1
		label.Text = string.format("Opinion  %s%d", value > 0 and "+" or "", value)
		label.TextColor3 = value > 0 and Colors.Positive or (value < 0 and Colors.Negative or Colors.TextSecondary)
		label.TextXAlignment = Enum.TextXAlignment.Left
		Typography.apply(label, "label")
		label.Parent = container

		local track = Instance.new("Frame")
		track.Size = UDim2.new(1, 0, 0, 8)
		track.Position = UDim2.fromOffset(0, 20)
		track.BackgroundColor3 = Colors.SurfaceSunken
		track.BorderSizePixel = 0
		track.Parent = container
		local tcorner = Instance.new("UICorner")
		tcorner.CornerRadius = UDim.new(1, 0)
		tcorner.Parent = track

		local center = Instance.new("Frame")
		center.AnchorPoint = Vector2.new(0.5, 0)
		center.Position = UDim2.fromScale(0.5, 0)
		center.Size = UDim2.new(0, 1, 1, 0)
		center.BackgroundColor3 = Colors.BorderStrong
		center.BorderSizePixel = 0
		center.ZIndex = 2
		center.Parent = track

		local frac = math.clamp(value / 200, -1, 1)
		local fill = Instance.new("Frame")
		fill.AnchorPoint = Vector2.new(frac >= 0 and 0 or 1, 0)
		fill.Position = UDim2.fromScale(0.5, 0)
		fill.Size = UDim2.fromScale(0.5 * math.abs(frac), 1)
		fill.BackgroundColor3 = value >= 0 and Colors.Positive or Colors.Negative
		fill.BorderSizePixel = 0
		fill.Parent = track
		local fcorner = Instance.new("UICorner")
		fcorner.CornerRadius = UDim.new(1, 0)
		fcorner.Parent = fill
	end

	-- ---- province + army counts (not precomputed; iterate once per profile render) ----
	local function countryStats(tag)
		local provinces = 0
		for _, p in pairs(cache.allProvinces()) do
			if p.ownerTag == tag then
				provinces += 1
			end
		end
		local regiments = 0
		for _, a in pairs(cache.allArmies()) do
			if a.ownerTag == tag then
				for _, count in pairs(a.composition or {}) do
					regiments += count
				end
			end
		end
		return provinces, regiments
	end

	-- ---- list mode -----------------------------------------------------------
	local function listRow(parent, tag, order)
		local rel = relationStatus(cache, mineTag, tag)
		local row = Instance.new("TextButton")
		row.Name = "Nation"
		row.Size = UDim2.new(1, 0, 0, 56)
		row.BackgroundColor3 = Colors.SurfaceElevated
		row.BackgroundTransparency = 1
		row.BorderSizePixel = 0
		row.AutoButtonColor = false
		row.Text = ""
		row.LayoutOrder = order
		row.Parent = parent
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = row
		row.MouseEnter:Connect(function()
			row.BackgroundTransparency = 0.88
		end)
		row.MouseLeave:Connect(function()
			row.BackgroundTransparency = 1
		end)
		row.Activated:Connect(function()
			showProfile(tag)
		end)

		local badge = CountryBadge.create({
			code = tag,
			countryColor = countryColor(cache.getCountry(tag)),
			size = "sm",
			parent = row,
		})
		badge.AnchorPoint = Vector2.new(0, 0.5)
		badge.Position = UDim2.new(0, 8, 0.5, 0)

		local nameLbl = Instance.new("TextLabel")
		nameLbl.Position = UDim2.fromOffset(60, 0)
		nameLbl.Size = UDim2.new(1, -200, 1, 0)
		nameLbl.BackgroundTransparency = 1
		nameLbl.Text = nameOf(cache, tag)
		nameLbl.TextColor3 = Colors.TextPrimary
		nameLbl.TextXAlignment = Enum.TextXAlignment.Left
		nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
		Typography.apply(nameLbl, "bodyLg")
		nameLbl.Parent = row

		local chipLbl = Instance.new("TextLabel")
		chipLbl.AnchorPoint = Vector2.new(1, 0.5)
		chipLbl.Position = UDim2.new(1, -10, 0.5, 0)
		chipLbl.Size = UDim2.fromOffset(120, 18)
		chipLbl.BackgroundTransparency = 1
		chipLbl.Text = RELATION[rel].label
		chipLbl.TextColor3 = RELATION[rel].color
		chipLbl.TextXAlignment = Enum.TextXAlignment.Right
		Typography.apply(chipLbl, "label")
		chipLbl.Parent = row

		local op = opinionOf(tag)
		local opLbl = Instance.new("TextLabel")
		opLbl.AnchorPoint = Vector2.new(1, 0.5)
		opLbl.Position = UDim2.new(1, -138, 0.5, 0)
		opLbl.Size = UDim2.fromOffset(48, 18)
		opLbl.BackgroundTransparency = 1
		opLbl.Text = (op > 0 and "+" or "") .. tostring(op)
		opLbl.TextColor3 = op > 0 and Colors.Positive or (op < 0 and Colors.Negative or Colors.TextSecondary)
		opLbl.TextXAlignment = Enum.TextXAlignment.Right
		Typography.apply(opLbl, "mono")
		opLbl.Parent = row
	end

	local function renderList(body)
		if not mineTag then
			ScreenKit.note(body, "Claim a country to conduct diplomacy.", 1)
			return
		end

		local listContainer = Instance.new("Frame")
		listContainer.Name = "List"
		listContainer.Size = UDim2.fromScale(1, 0)
		listContainer.AutomaticSize = Enum.AutomaticSize.Y
		listContainer.BackgroundTransparency = 1
		listContainer.LayoutOrder = 1
		local listLayout = Instance.new("UIListLayout")
		listLayout.SortOrder = Enum.SortOrder.LayoutOrder
		listLayout.Padding = UDim.new(0, 4)
		listLayout.Parent = listContainer

		local function rebuild()
			for _, ch in listContainer:GetChildren() do
				if ch:IsA("GuiObject") then
					ch:Destroy()
				end
			end
			local q = listQuery:lower()
			local entries = {}
			for tag in pairs(cache.allCountries()) do
				if tag ~= mineTag then
					local nm = nameOf(cache, tag)
					if q == "" or nm:lower():find(q, 1, true) or tag:lower():find(q, 1, true) then
						entries[#entries + 1] = { tag = tag, name = nm }
					end
				end
			end
			table.sort(entries, function(a, b)
				return a.name < b.name
			end)
			if #entries == 0 then
				ScreenKit.note(listContainer, "No nations match your search.", 1)
				return
			end
			local order = 0
			for _, e in ipairs(entries) do
				order += 1
				listRow(listContainer, e.tag, order)
			end
		end

		makeSearchBox(body, "Search nations…", listQuery, function(text)
			listQuery = text
			rebuild()
		end)
		listContainer.Parent = body
		rebuild()
	end

	-- ---- profile mode --------------------------------------------------------
	local function renderProfile(body)
		local tag = currentTag
		local n = 0
		local function ord()
			n += 1
			return n
		end

		local back = ScreenKit.buttonRow(body, ord())
		Button.create({
			parent = back,
			variant = "ghost",
			text = "‹ Back",
			size = "sm",
			onClick = showList,
		})

		local country = tag and cache.getCountry(tag)
		if not country then
			ScreenKit.note(body, "This nation no longer exists.", ord())
			return
		end
		local rel = relationStatus(cache, mineTag, tag)
		local col = countryColor(country)

		-- Header: flag/crest + name + relation pill + controller avatar.
		local header = Instance.new("Frame")
		header.Name = "Header"
		header.Size = UDim2.new(1, 0, 0, 76)
		header.BackgroundTransparency = 1
		header.LayoutOrder = ord()
		header.Parent = body

		-- Crest sits in a slim gold-framed square (the crest itself supplies the colour/decal).
		local flag = Instance.new("Frame")
		flag.Size = UDim2.fromOffset(48, 48)
		flag.AnchorPoint = Vector2.new(0, 0.5)
		flag.Position = UDim2.fromScale(0, 0.5)
		flag.BackgroundTransparency = 1
		flag.BorderSizePixel = 0
		flag.Parent = header
		local fcorner = Instance.new("UICorner")
		fcorner.CornerRadius = UDim.new(0, 6)
		fcorner.Parent = flag
		local fstroke = Instance.new("UIStroke")
		fstroke.Color = Colors.BorderStrong
		fstroke.Parent = flag
		local crest = CountryBadge.create({ code = tag, countryColor = col, size = "md", parent = flag })
		crest.AnchorPoint = Vector2.new(0.5, 0.5)
		crest.Position = UDim2.fromScale(0.5, 0.5)

		local nameLbl = Instance.new("TextLabel")
		nameLbl.Position = UDim2.fromOffset(60, 12)
		nameLbl.Size = UDim2.new(1, -180, 0, 28)
		nameLbl.BackgroundTransparency = 1
		nameLbl.Text = nameOf(cache, tag)
		nameLbl.TextColor3 = Colors.TextPrimary
		nameLbl.TextXAlignment = Enum.TextXAlignment.Left
		nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
		Typography.apply(nameLbl, "displayMd")
		nameLbl.Parent = header

		local pill = Instance.new("TextLabel")
		pill.Position = UDim2.fromOffset(60, 42)
		pill.Size = UDim2.new(1, -180, 0, 18)
		pill.BackgroundTransparency = 1
		pill.Text = RELATION[rel].label
		pill.TextColor3 = RELATION[rel].color
		pill.TextXAlignment = Enum.TextXAlignment.Left
		Typography.apply(pill, "label")
		pill.Parent = header

		if country.claimedBy then
			local avatar = Instance.new("ImageLabel")
			avatar.AnchorPoint = Vector2.new(1, 0.5)
			avatar.Position = UDim2.new(1, -4, 0.5, 0)
			avatar.Size = UDim2.fromOffset(52, 52)
			avatar.BackgroundColor3 = Colors.SurfaceSunken
			avatar.Image = "rbxthumb://type=AvatarHeadShot&id=" .. tostring(country.claimedBy) .. "&w=150&h=150"
			avatar.Parent = header
			local acorner = Instance.new("UICorner")
			acorner.CornerRadius = UDim.new(1, 0)
			acorner.Parent = avatar
		else
			local ai = Instance.new("TextLabel")
			ai.AnchorPoint = Vector2.new(1, 0.5)
			ai.Position = UDim2.new(1, -4, 0.5, 0)
			ai.Size = UDim2.fromOffset(52, 24)
			ai.BackgroundTransparency = 1
			ai.Text = "AI"
			ai.TextColor3 = Colors.TextTertiary
			ai.TextXAlignment = Enum.TextXAlignment.Right
			Typography.apply(ai, "caption")
			ai.Parent = header
		end

		opinionMeter(body, opinionOf(tag), ord())

		-- Nation info.
		ScreenKit.section(body, "Nation", ord())
		ScreenKit.stat(body, {
			icon = "Core",
			label = "Government",
			value = prettify(country.governmentForm),
			layoutOrder = ord(),
		})
		ScreenKit.stat(body, {
			label = "Ideology",
			value = prettify(country.ideology),
			layoutOrder = ord(),
		})
		local provinces, regiments = countryStats(tag)
		ScreenKit.stat(
			body,
			{ icon = "Prestige", label = "Provinces", value = tostring(provinces), mono = true, layoutOrder = ord() }
		)
		ScreenKit.stat(
			body,
			{ icon = "War", label = "Regiments", value = tostring(regiments), mono = true, layoutOrder = ord() }
		)
		if country.treasury ~= nil then
			ScreenKit.stat(body, {
				icon = "Treasury",
				label = "Treasury",
				value = tostring(math.floor(country.treasury or 0)),
				mono = true,
				layoutOrder = ord(),
			})
		end
		if country.manpower ~= nil then
			ScreenKit.stat(body, {
				icon = "Manpower",
				label = "Manpower",
				value = tostring(math.floor(country.manpower or 0)),
				mono = true,
				layoutOrder = ord(),
			})
		end

		-- Relations detail.
		ScreenKit.section(body, "Relations", ord())
		local war = activeWarWith(cache, mineTag, tag)
		if war then
			local iAmAttacker = war.attackerTag == mineTag
			local myScore = iAmAttacker and (war.score or 0) or -(war.score or 0)
			ScreenKit.stat(body, {
				icon = "War",
				label = "War score",
				value = string.format("%s%d", myScore > 0 and "+" or "", math.floor(myScore)),
				valueColor = myScore > 0 and "positive" or (myScore < 0 and "negative" or nil),
				mono = true,
				layoutOrder = ord(),
			})
			ScreenKit.stat(body, {
				label = "War exhaustion",
				value = string.format(
					"you %d%%  ·  them %d%%",
					math.floor((iAmAttacker and war.attackerExhaustion or war.defenderExhaustion) or 0),
					math.floor((iAmAttacker and war.defenderExhaustion or war.attackerExhaustion) or 0)
				),
				layoutOrder = ord(),
			})
		end
		if napActive(tag) then
			ScreenKit.note(body, "Non-aggression pact in force.", ord())
		end
		if truceActive(tag) then
			ScreenKit.note(body, "Truce in effect — war cannot be declared.", ord())
		end
		if isAllied(tag) then
			ScreenKit.note(body, "Allied — you defend each other's wars.", ord())
		end
		if iGuarantee(tag) then
			ScreenKit.note(body, "You guarantee their independence.", ord())
		end
		local me = mineTag and cache.getCountry(mineTag)
		if me and me.guaranteedBy and me.guaranteedBy[tag] then
			ScreenKit.note(body, "They guarantee your independence.", ord())
		end
		if rel == "SUBJECT" then
			ScreenKit.note(body, "Your subject — they fight your wars and cannot act alone.", ord())
		elseif rel == "OVERLORD" then
			ScreenKit.note(body, "Your overlord — they control your foreign policy.", ord())
		end

		-- Pending offers between you (folded in, per design).
		local pendingShown = false
		local function ensurePending()
			if not pendingShown then
				ScreenKit.section(body, "Pending", ord())
				pendingShown = true
			end
		end
		local function offerButtons(incoming, acceptRemote, rejectRemote, cancelRemote, id)
			local prow = ScreenKit.buttonRow(body, ord())
			if incoming then
				Button.create({
					parent = prow,
					variant = "success",
					text = "Accept",
					size = "sm",
					onClick = function()
						ctx.fire(acceptRemote, id)
					end,
				})
				Button.create({
					parent = prow,
					variant = "danger",
					text = "Reject",
					size = "sm",
					onClick = function()
						ctx.fire(rejectRemote, id)
					end,
				})
			else
				Button.create({
					parent = prow,
					variant = "ghost",
					text = "Cancel",
					size = "sm",
					onClick = function()
						ctx.fire(cancelRemote, id)
					end,
				})
			end
		end
		for id, p in pairs(cache.allPeaceProposals()) do
			if
				p.status == "pending"
				and ((p.fromTag == mineTag and p.toTag == tag) or (p.fromTag == tag and p.toTag == mineTag))
			then
				ensurePending()
				local incoming = p.toTag == mineTag
				ScreenKit.note(
					body,
					(incoming and "Incoming" or "Outgoing")
						.. " peace offer · "
						.. (TERMS_LABEL[(p.terms or {}).type] or "Peace"),
					ord()
				)
				offerButtons(incoming, "AcceptPeace", "RejectPeace", "CancelPeaceProposal", id)
			end
		end
		for id, p in pairs(cache.allPacts()) do
			if
				p.status == "pending"
				and ((p.fromTag == mineTag and p.toTag == tag) or (p.fromTag == tag and p.toTag == mineTag))
			then
				ensurePending()
				local incoming = p.toTag == mineTag
				local label = (p.type == "call_to_arms") and "Call to arms"
					or ((p.type == "alliance") and "Alliance offer" or "Non-aggression pact")
				ScreenKit.note(body, (incoming and "Incoming · " or "Outgoing · ") .. label, ord())
				offerButtons(incoming, "AcceptPact", "RejectPact", "CancelPact", id)
			end
		end

		-- Contextual actions.
		ScreenKit.section(body, "Actions", ord())
		local act = ScreenKit.buttonRow(body, ord())
		local function major(variant, text, title, bodyText, confirmText, onYes)
			Button.create({
				parent = act,
				variant = variant,
				text = text,
				size = "sm",
				onClick = function()
					confirm({
						title = title,
						subtitle = nameOf(cache, tag),
						body = bodyText,
						confirmText = confirmText,
						variant = variant,
						onConfirm = onYes,
					})
				end,
			})
		end
		local function minor(variant, text, onClick)
			Button.create({ parent = act, variant = variant, text = text, size = "sm", onClick = onClick })
		end

		local meSubject = me and me.subjectOf ~= nil
		if rel == "WAR" then
			major(
				"secondary",
				"White Peace",
				"Propose White Peace",
				"End the war with no exchange of land?",
				"Propose",
				function()
					proposePeace(tag, "white_peace")
				end
			)
			major(
				"primary",
				"Demand Lands",
				"Demand Lands",
				"Demand the provinces you occupy as the price of peace?",
				"Demand",
				function()
					proposePeace(tag, "annex_occupied")
				end
			)
			major("primary", "Vassalize", "Vassalize", "Force them to become your subject?", "Vassalize", function()
				proposePeace(tag, "vassalize")
			end)
		elseif rel == "OVERLORD" then
			minor("secondary", "Improve · 25 PP", function()
				improveRelations(tag)
			end)
		elseif rel == "SUBJECT" then
			minor("secondary", "Release", function()
				releaseSubject(tag)
			end)
			major(
				"danger",
				"Annex",
				"Annex Subject",
				"Absorb this subject — its provinces become yours and the nation ceases to exist?",
				"Annex",
				function()
					annexSubject(tag)
				end
			)
		else
			local allied = isAllied(tag)
			local napOn = napActive(tag)
			local truceOn = truceActive(tag)
			-- A nation that is someone else's subject can't form pacts (server rejects "subject_involved").
			local targetIsSubject = country.subjectOf ~= nil
			if not meSubject then
				if allied then
					major(
						"danger",
						"Break Alliance",
						"Break Alliance",
						"Breaking an alliance is a grave betrayal — opinion plummets.",
						"Break",
						function()
							breakPact(tag, "alliance")
						end
					)
				elseif napOn then
					major(
						"danger",
						"Break NAP",
						"Break Non-Aggression Pact",
						"Breaking the pact angers both peoples.",
						"Break",
						function()
							breakPact(tag, "nap")
						end
					)
				elseif not truceOn then
					major(
						"danger",
						"Declare War",
						"Declare War",
						"Declare war on " .. nameOf(cache, tag) .. "?",
						"Declare War",
						function()
							declareWar(tag)
						end
					)
				end
				if not allied and not targetIsSubject then
					minor("secondary", "Propose Alliance", function()
						proposePact(tag, "alliance")
					end)
				end
				if not allied and not napOn and not targetIsSubject then
					minor("secondary", "Propose NAP", function()
						proposePact(tag, "nap")
					end)
				end
				if iGuarantee(tag) then
					major(
						"ghost",
						"Revoke Guarantee",
						"Revoke Guarantee",
						"Withdraw your protection of " .. nameOf(cache, tag) .. "?",
						"Revoke",
						function()
							breakPact(tag, "guarantee")
						end
					)
				elseif not targetIsSubject then
					minor("ghost", "Guarantee", function()
						proposePact(tag, "guarantee")
					end)
				end
			end
			minor("secondary", "Improve · 25 PP", function()
				improveRelations(tag)
			end)
		end
	end

	-- ---- dispatch + navigation ----------------------------------------------
	render = function()
		if not (handle and handle.body) then
			return
		end
		handle.clearBody()
		if mode == "profile" and currentTag then
			renderProfile(handle.body)
		else
			renderList(handle.body)
		end
	end
	showList = function()
		mode = "list"
		currentTag = nil
		render()
	end
	showProfile = function(tag)
		mode = "profile"
		currentTag = tag
		render()
	end

	-- Mode-aware signature: re-render the current view only when its meaningful state changes (economy
	-- ticks mutate treasury/manpower but those are excluded, so an open profile/list does not thrash).
	local function contentSignature()
		local parts = {}
		if mode == "profile" and currentTag then
			local t = currentTag
			parts[#parts + 1] = "rel:" .. relationStatus(cache, mineTag, t)
			parts[#parts + 1] = "op:" .. tostring(opinionOf(t))
			local tc = cache.getCountry(t)
			parts[#parts + 1] = "ex:" .. (tc and "1" or "0")
			-- Field PRESENCE (not value, to avoid per-tick thrash) so the info rows appear once populated.
			parts[#parts + 1] = "fld:"
				.. ((tc and tc.treasury ~= nil) and "1" or "0")
				.. ((tc and tc.manpower ~= nil) and "1" or "0")
			local w = activeWarWith(cache, mineTag, t)
			if w then
				parts[#parts + 1] = string.format(
					"w:%d/%d/%d",
					math.floor(w.score or 0),
					math.floor(w.attackerExhaustion or 0),
					math.floor(w.defenderExhaustion or 0)
				)
			end
			for id, p in pairs(cache.allPeaceProposals()) do
				if
					p.status == "pending"
					and ((p.fromTag == mineTag and p.toTag == t) or (p.fromTag == t and p.toTag == mineTag))
				then
					parts[#parts + 1] = "pp:" .. tostring(id) .. ":" .. tostring((p.terms or {}).type)
				end
			end
			for id, p in pairs(cache.allPacts()) do
				if
					p.status == "pending"
					and ((p.fromTag == mineTag and p.toTag == t) or (p.fromTag == t and p.toTag == mineTag))
				then
					parts[#parts + 1] = "pa:" .. tostring(id) .. ":" .. tostring(p.type)
				end
			end
		else
			for tag in pairs(cache.allCountries()) do
				if tag ~= mineTag then
					parts[#parts + 1] = tag
						.. ":"
						.. relationStatus(cache, mineTag, tag)
						.. ":"
						.. tostring(opinionOf(tag))
				end
			end
		end
		table.sort(parts)
		return table.concat(parts, "|")
	end

	local lastSig = nil
	local function scheduleRefresh()
		if dirty then
			return
		end
		dirty = true
		task.defer(function()
			dirty = false
			if not (handle and handle.root and handle.root.Parent) then
				return
			end
			local sig = contentSignature()
			if sig == lastSig then
				return
			end
			lastSig = sig
			render()
		end)
	end

	local mine = mineTag and cache.getCountry(mineTag)
	handle = ScreenKit.open(ctx, {
		name = "DiplomacyScreen",
		title = "Diplomacy",
		subtitle = (mine and (mine.displayName or mineTag)) or "Realm",
	})
	render()
	lastSig = contentSignature()

	table.insert(conns, cache.onChangePrefix("countries", scheduleRefresh))
	table.insert(conns, cache.onChangePrefix("wars", scheduleRefresh))
	table.insert(conns, cache.onChangePrefix("peaceProposals", scheduleRefresh))
	table.insert(conns, cache.onChangePrefix("pacts", scheduleRefresh))

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
