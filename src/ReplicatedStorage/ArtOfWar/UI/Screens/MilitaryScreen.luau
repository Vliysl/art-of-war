local RunService = game:GetService("RunService")

local ScreenKit = require(script.Parent.ScreenKit)
local Button = require(script.Parent.Parent.Components.Button)
local Modal = require(script.Parent.Parent.Components.Modal)
local PickerRow = require(script.Parent.Parent.Components.PickerRow)
local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local WorldConstants = require(script.Parent.Parent.Parent.Shared.WorldConstants)
local LeaderTraits = require(script.Parent.Parent.Parent.Data.LeaderTraits)
-- Selecting a group's members on the map is a client-only view op; ArmyView isn't in the screen ctx
-- (which only carries data/fire), so require it directly like ProvinceOverview requires SimClock.
local ArmyView = require(script.Parent.Parent.Parent.Modules.ArmyView)
-- Recruit tab: the client mirror of the server's Military-district rule, and sim-time for queue progress.
local RecruitGate = require(script.Parent.Parent.Parent.Modules.RecruitGate)
local SimClock = require(script.Parent.Parent.Parent.Modules.SimClock)

local MilitaryScreen = {}

local TABS = {
	{ key = "army", label = "Army" },
	{ key = "recruit", label = "Recruit" },
	{ key = "navy", label = "Navy" },
	{ key = "doctrines", label = "Doctrines" },
}

-- How many production lines a province can run at once. Mirrors RecruitSystem's `cap = max(1, devTier)`, which
-- the UI never surfaced -- the click was just rejected with `production_lines_full` and nothing explained why.
local function lineCapOf(province)
	return math.max(1, (province and province.devTier) or 1)
end

-- Counts the SAME queues the server's RecruitSystem.totalLinesAt does: recruit + buildings + ships. Note it
-- deliberately does NOT count districtQueue -- the server doesn't either, so counting it here would show a
-- province as full while the server happily accepts another regiment.
--
-- One unavoidable gap: NavalSystem keeps its build queue in a module-local `buildQueueByProvince` and never
-- publishes it to the country record, so a client cannot see ship lines. This can therefore UNDER-count in a
-- port that is building ships. It's a hint, not a gate -- the server's `production_lines_full` toast is the
-- authority, and the recruit button stays live rather than being disabled on a number we can't fully know.
local function linesUsedAt(country, provinceId)
	local n = 0
	for _, queueName in ipairs({ "recruitQueue", "buildQueue" }) do
		for _, t in ipairs((country and country[queueName]) or {}) do
			if t.provinceId == provinceId then
				n += 1
			end
		end
	end
	return n
end

local function val(v)
	if v == nil or v == "" then
		return "\u{2014}"
	end
	return tostring(v)
end

-- Treasury is a float that accrues fractional income, so a raw tostring renders "799.0999999999999". Floor +
-- thousands separators, as ArmyPanel does for its recruit costs.
local function commafy(n)
	n = math.floor(tonumber(n) or 0)
	local out = tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

-- Tickets are stamped in server SIM-time, so progress must be read off SimClock (speed- and pause-aware)
-- rather than a wall clock, which would race to 100% while the game is paused. Mirrors ProvinceOverview.
local function progressOf(startedAt, completesAt)
	if startedAt and completesAt and completesAt > startedAt then
		local now = SimClock.now() or startedAt
		return math.clamp((now - startedAt) / (completesAt - startedAt), 0, 1)
	end
	return 0
end

-- A production-queue row: name + where + a bar advanced in place, and a cancel. Built from plain frames like
-- ProvinceOverview's actionRow rather than StatRow's progress, because that bar is driven by an inner "Clip"
-- and exposes no live setter -- resizing its "Fill" would stretch the texture instead of the bar. Returns the
-- fill so the caller's Heartbeat ticker can advance it without rebuilding the row.
local function queueRow(parent, cfg)
	local row = Instance.new("Frame")
	row.Name = "QueueRow"
	row.Size = UDim2.new(1, 0, 0, 44)
	row.BackgroundTransparency = 1
	row.LayoutOrder = cfg.order or 0
	row.Parent = parent

	local name = Instance.new("TextLabel")
	name.Position = UDim2.fromOffset(0, 2)
	name.Size = UDim2.new(1, -140, 0, 18)
	name.BackgroundTransparency = 1
	name.Text = cfg.label or ""
	name.TextColor3 = Colors.TextPrimary
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextTruncate = Enum.TextTruncate.AtEnd
	Typography.apply(name, "bodyMd")
	name.Parent = row

	local sub = Instance.new("TextLabel")
	sub.AnchorPoint = Vector2.new(1, 0)
	sub.Position = UDim2.new(1, -40, 0, 2)
	sub.Size = UDim2.fromOffset(96, 18)
	sub.BackgroundTransparency = 1
	sub.Text = cfg.sub or ""
	sub.TextColor3 = Colors.TextSecondary
	sub.TextXAlignment = Enum.TextXAlignment.Right
	sub.TextTruncate = Enum.TextTruncate.AtEnd
	Typography.apply(sub, "bodySm")
	sub.Parent = row

	-- Sharp corners (no UICorner) per house style.
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0, 1)
	track.Position = UDim2.new(0, 0, 1, -6)
	track.Size = UDim2.new(1, -40, 0, 6)
	track.BackgroundColor3 = Colors.SurfaceSunken
	track.BorderSizePixel = 0
	track.Parent = row
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(math.clamp(cfg.live and cfg.live() or 0, 0, 1), 1)
	fill.BackgroundColor3 = Colors.Accent
	fill.BorderSizePixel = 0
	fill.Parent = track

	local cancel = Button.create({
		parent = row,
		variant = "danger",
		text = "\u{00D7}",
		width = 32,
		size = "sm",
		onClick = cfg.onCancel,
	})
	cancel.AnchorPoint = Vector2.new(1, 0.5)
	cancel.Position = UDim2.fromScale(1, 0.5)
	return row, fill
end

-- Compact "domain +X  ·  domain2 +Y" line for a modifiers table (doctrine effects preview).
local function modifierLine(modifiers)
	if type(modifiers) ~= "table" then
		return nil
	end
	local parts = {}
	for k, v in modifiers do
		if type(v) == "number" and v ~= 0 then
			parts[#parts + 1] = string.format("%s %s%g", k, v > 0 and "+" or "", v)
		end
	end
	table.sort(parts)
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, "  \u{2022}  ")
end

local function titleCase(text)
	if not text then
		return ""
	end
	local s = tostring(text):gsub("_", " ")
	s = s:gsub("(%a)([%w']*)", function(a, b)
		return a:upper() .. b:lower()
	end)
	return s
end

local function unitName(registries, id)
	local types = registries and registries.UnitTypes
	local def = types and types[id]
	return (def and def.displayName) or titleCase(id)
end

local function shipName(registries, id)
	local types = registries and registries.ShipTypes
	local def = types and types[id]
	return (def and def.displayName) or titleCase(id)
end

-- Combat depth C: a roster general's "First Last" display name.
local function generalName(g)
	if type(g) ~= "table" then
		return "\u{2014}"
	end
	local nm = string.format("%s %s", g.firstName or "", g.lastName or "")
	nm = (nm:gsub("^%s+", ""):gsub("%s+$", ""))
	return nm ~= "" and nm or "\u{2014}"
end

-- Combat depth C: a general's leader-trait display names (from Data/LeaderTraits), joined for a note.
local function generalTraitLine(g)
	local names = {}
	if type(g) == "table" and type(g.traits) == "table" then
		for _, tid in ipairs(g.traits) do
			local def = LeaderTraits[tid]
			names[#names + 1] = (def and def.displayName) or titleCase(tid)
		end
	end
	if #names == 0 then
		return nil
	end
	return table.concat(names, "  \u{00B7}  ")
end

local function armyStateLabel(army)
	local map = {
		idle = "Idle",
		moving = "Moving",
		attacking = "Attacking",
		defending = "Defending",
		retreating = "Retreating",
	}
	return map[army.state] or titleCase(army.state) or "Idle"
end

local function fleetStatusLabel(fleet)
	local map = {
		idle = "Docked",
		moving = "Sailing",
		battle = "In Battle",
		destroyed = "Destroyed",
	}
	return map[fleet.status] or titleCase(fleet.status) or "Docked"
end

local function armyInfo(army, registries)
	local domId, domCount, total = nil, -1, 0
	for unitId, count in pairs(army.composition or {}) do
		if count > 0 then
			total += count
			if count > domCount then
				domCount = count
				domId = unitId
			end
		end
	end
	return {
		total = total,
		domName = domId and unitName(registries, domId) or "Force",
	}
end

local function fleetInfo(fleet, registries)
	local counts, total = {}, 0
	for _, ship in ipairs(fleet.ships or {}) do
		counts[ship.typeId] = (counts[ship.typeId] or 0) + 1
		total += 1
	end
	local domId, domCount = nil, -1
	for id, count in pairs(counts) do
		if count > domCount then
			domCount = count
			domId = id
		end
	end
	return {
		total = total,
		domName = domId and shipName(registries, domId) or "Fleet",
	}
end

function MilitaryScreen.create(ctx)
	local registries = ctx.registries
	local conns = {}
	local handle
	-- Recruit-tab state. `render`/`activeTab` are forward-declared because the recruit renderer re-renders
	-- itself after the province picker resolves, and the renderers table is built above their definitions --
	-- without these, that call would resolve to a nil global at runtime rather than the local below.
	local render, activeTab
	local selectedProvinceId = nil
	local liveBars = {} -- { fill, live } advanced in place by the Heartbeat ticker, so bars move between rebuilds

	local function ownArmies()
		local out = {}
		for _, a in pairs(ctx.cache.allArmies()) do
			if a.ownerTag == ctx.tag then
				out[#out + 1] = a
			end
		end
		table.sort(out, function(x, y)
			return tostring(x.id) < tostring(y.id)
		end)
		return out
	end

	local function ownFleets()
		local out = {}
		for _, f in pairs(ctx.cache.allFleets()) do
			if f.ownerTag == ctx.tag then
				out[#out + 1] = f
			end
		end
		table.sort(out, function(x, y)
			return tostring(x.id) < tostring(y.id)
		end)
		return out
	end

	-- Combat depth B: the player's army groups (own its own replicated collection), sorted by name.
	local function ownGroups()
		local out = {}
		for _, g in pairs(ctx.cache.allArmyGroups() or {}) do
			if g.ownerTag == ctx.tag then
				out[#out + 1] = g
			end
		end
		table.sort(out, function(x, y)
			return tostring(x.name) < tostring(y.name)
		end)
		return out
	end

	-- Combat depth C: the player's roster generals, sorted by name (nil roster -> empty list).
	local function ownGenerals()
		local out = {}
		local country = ctx.cache.getCountry(ctx.tag)
		local roster = country and country.generalRoster
		if type(roster) == "table" then
			for _, g in pairs(roster) do
				if type(g) == "table" then
					out[#out + 1] = g
				end
			end
		end
		table.sort(out, function(x, y)
			return generalName(x) < generalName(y)
		end)
		return out
	end

	local function unitRow(parent, text, sub, order, onClick)
		local btn = Instance.new("TextButton")
		btn.Name = "UnitRow"
		btn.Size = UDim2.new(1, 0, 0, 36)
		btn.AutoButtonColor = false
		btn.Text = ""
		btn.BackgroundTransparency = 1
		btn.LayoutOrder = order
		ScreenKit.stat(btn, { icon = "Battle", label = text, value = sub, mono = true, layoutOrder = 1 })
		btn.MouseButton1Click:Connect(onClick)
		btn.Parent = parent
		return btn
	end

	-- ── Recruit tab ─────────────────────────────────────────────────────────────────────────────────────
	-- Orders go through the SAME RecruitUnit remote the province panel and army panel already use; this screen
	-- adds the two things HOI4 has and the game did not: one place to see the whole production queue, and the
	-- per-province line cap that silently rejected orders.

	-- Owned AND controlled -- mirrors RecruitSystem.provinceSupportsRecruit (city/infra requirements were lifted).
	local function recruitProvinces()
		local out = {}
		for id, prov in ctx.cache.allProvinces() do
			prov.id = prov.id or id
			if prov.ownerTag == ctx.tag and prov.controllerTag == ctx.tag then
				out[#out + 1] = prov
			end
		end
		table.sort(out, function(a, b)
			return (a.name or "") < (b.name or "")
		end)
		return out
	end

	local function provinceLabel(prov)
		return (prov and (prov.name or ("Province " .. tostring(prov.id)))) or "\u{2014}"
	end

	-- The recruit pool: every unit with a recruitCost, levy first (RecruitGate.sortPool), as ArmyPanel builds it.
	local function recruitPool()
		local types = (registries and registries.UnitTypes) or {}
		local pool = {}
		for id, def in pairs(types) do
			if def.recruitCost ~= nil then
				pool[#pool + 1] = { id = id, def = def }
			end
		end
		RecruitGate.sortPool(pool)
		return pool
	end

	local function openProvincePicker(onPick)
		local list = recruitProvinces()
		local modal = Modal.create({
			parent = ctx.modalLayer or ctx.parent,
			title = "Recruit in",
			subtitle = #list .. " eligible province" .. (#list == 1 and "" or "s"),
			width = 360,
			height = 420,
		})
		-- Scroller: a large nation has hundreds of eligible provinces.
		local content = Modal.scrollBody(modal)
		local layout = Instance.new("UIListLayout")
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 6)
		layout.Parent = content
		if #list == 0 then
			ScreenKit.note(content, "You control no provinces that can raise troops.", 1)
			return
		end
		local country = ctx.cache.getCountry(ctx.tag)
		for i, prov in ipairs(list) do
			local used, cap = linesUsedAt(country, prov.id), lineCapOf(prov)
			local row = ScreenKit.buttonRow(content, i)
			Button.create({
				parent = row,
				variant = "secondary",
				text = string.format("%s   (%d/%d lines)", provinceLabel(prov), used, cap),
				onClick = function()
					onPick(prov.id)
					modal.close()
				end,
			})
		end
	end

	local renderers = {
		recruit = function(body)
			local country = ctx.cache.getCountry(ctx.tag)
			if not country then
				ScreenKit.note(body, "Claim a nation to raise troops.", 1)
				return
			end

			-- Levy and professional units draw from DIFFERENT pools, so both are shown: a full manpower bar
			-- tells you nothing about whether you can raise a militia.
			ScreenKit.section(body, "Pools", 1)
			ScreenKit.stat(body, {
				icon = "Manpower",
				label = "Manpower",
				value = commafy(country.manpower),
				progress = {
					value = country.manpower or 0,
					max = math.max(country.maxManpower or country.manpower or 1, 1),
					color = "green",
				},
				layoutOrder = 2,
			})
			if country.levyManpower ~= nil then
				ScreenKit.stat(body, { icon = "Army", label = "Levy Manpower", value = commafy(country.levyManpower), layoutOrder = 3 })
			end
			ScreenKit.stat(body, { icon = "Economy", label = "Treasury", value = commafy(country.treasury), layoutOrder = 4 })

			-- Province target. Defaults to the capital, else the first eligible province.
			local provinces = recruitProvinces()
			if #provinces == 0 then
				ScreenKit.section(body, "Recruit", 10)
				ScreenKit.note(body, "You control no provinces that can raise troops.", 11)
				return
			end
			local selected = nil
			for _, p in ipairs(provinces) do
				if p.id == selectedProvinceId then
					selected = p
					break
				end
			end
			if not selected then
				-- Selection lost (province taken, or first open): fall back to the capital, else the first.
				for _, p in ipairs(provinces) do
					if p.id == country.capitalProvinceId then
						selected = p
						break
					end
				end
				selected = selected or provinces[1]
				selectedProvinceId = selected.id
			end

			local used, cap = linesUsedAt(country, selected.id), lineCapOf(selected)
			local full = used >= cap
			ScreenKit.section(body, "Recruit", 10)
			local pickRow = ScreenKit.buttonRow(body, 11)
			Button.create({
				parent = pickRow,
				variant = "secondary",
				text = "Province: " .. provinceLabel(selected),
				onClick = function()
					openProvincePicker(function(id)
						selectedProvinceId = id
						render(activeTab)
					end)
				end,
			})
			ScreenKit.stat(body, {
				icon = "Building",
				label = "Production lines",
				value = string.format("%d / %d", used, cap),
				valueColor = full and "warning" or nil,
				progress = { value = used, max = cap, color = full and "amber" or "green" },
				layoutOrder = 12,
			})
			if full then
				ScreenKit.note(body, "This province's lines are full. Finish or cancel something, or pick another province.", 13)
			end

			local hasMilitary = RecruitGate.provinceHasMilitaryDistrict(selected)
			for i, item in ipairs(recruitPool()) do
				local locked = RecruitGate.unitNeedsMilitaryDistrict(item.def) and not hasMilitary
				local pool = item.def.class == "levy" and "levy" or "regular"
				PickerRow.create({
					parent = body,
					order = 20 + i,
					icon = "Army",
					buttonText = "Recruit",
					locked = locked,
					label = item.def.displayName or titleCase(item.id),
					-- The subline names the pool because levy and professional draw from DIFFERENT ones, so
					-- "1000 levy" vs "1000 regular" is the difference between affordable and not.
					sub = locked and "Needs a Military district in this province"
						or string.format(
							"%s gold  \u{00B7}  %s %s  \u{00B7}  %d ticks",
							commafy(item.def.recruitCost),
							commafy(item.def.recruitManpower),
							pool,
							item.def.recruitTicks or 0
						),
					onClick = function()
						ctx.fire("RecruitUnit", selectedProvinceId, item.id, 1)
					end,
				})
			end

			-- Production queue: every regiment in build, across the whole realm. Progress is live (SimClock is
			-- sim-time, so it respects pause and game speed) rather than redrawn per tick.
			ScreenKit.section(body, "Production Queue", 50)
			local queue = country.recruitQueue or {}
			if #queue == 0 then
				ScreenKit.note(body, "Nothing in production.", 51)
				return
			end
			local sorted = table.clone(queue)
			table.sort(sorted, function(a, b)
				return (a.completesAt or math.huge) < (b.completesAt or math.huge)
			end)
			for i, ticket in ipairs(sorted) do
				local prov = ctx.cache.getProvince and ctx.cache.getProvince(ticket.provinceId)
				local label = unitName(registries, ticket.unitTypeId)
				if (ticket.count or 1) > 1 then
					label ..= "  \u{00D7}" .. ticket.count
				end
				local live = function()
					return progressOf(ticket.queuedAt, ticket.completesAt)
				end
				local _, fill = queueRow(body, {
					label = label,
					sub = provinceLabel(prov),
					order = 51 + i,
					live = live,
					onCancel = function()
						ctx.fire("CancelRecruit", ticket.id)
					end,
				})
				liveBars[#liveBars + 1] = { fill = fill, live = live }
			end
		end,

		army = function(body)
			local country = ctx.cache.getCountry(ctx.tag)
			ScreenKit.section(body, "Manpower", 1)
			if country then
				ScreenKit.stat(body, {
					icon = "Manpower",
					label = "Manpower",
					value = val(country.manpower),
					progress = {
						value = country.manpower or 0,
						max = math.max(country.maxManpower or country.manpower or 1, 1),
						color = "green",
					},
					layoutOrder = 2,
				})
				if country.levyManpower ~= nil then
					ScreenKit.stat(body, {
						icon = "Army",
						label = "Levy Manpower",
						value = val(country.levyManpower),
						layoutOrder = 3,
					})
				end
			else
				ScreenKit.note(body, "Claim a nation to command its armies.", 2)
			end

			ScreenKit.section(body, "Armies", 6)
			local armies = ownArmies()
			if #armies > 0 then
				for i, a in ipairs(armies) do
					local info = armyInfo(a, registries)
					unitRow(
						body,
						string.format("%s \u{00D7}%d", info.domName, info.total),
						armyStateLabel(a),
						6 + i,
						function()
							ctx.openArmyPanel({ armyId = a.id, provinceId = a.provinceId })
						end
					)
				end
			else
				ScreenKit.note(body, "No standing armies. Click one of your provinces, then Recruit.", 7)
			end

			-- Combat depth C: Generals roster + buy. Buy is gated on gold + PP (costs read from
			-- WorldConstants, not hardcoded); disabled when either is short.
			if WorldConstants.EnableGenerals and country then
				local goldCost = WorldConstants.GeneralBuyGoldCost or 0
				local ppCost = WorldConstants.GeneralBuyPpCost or 0
				ScreenKit.section(body, "Generals", 100)
				local generals = ownGenerals()
				if #generals > 0 then
					for i, g in ipairs(generals) do
						local group = g.assignedGroupId and ctx.cache.getArmyGroup(g.assignedGroupId)
						local assigned = group and (group.name or "Army Group") or "\u{2014}"
						ScreenKit.stat(body, {
							icon = "Star",
							label = string.format("%s  \u{00B7}  Lvl %d", generalName(g), g.level or 0),
							value = "Assigned: " .. assigned,
							layoutOrder = 100 + i * 2,
						})
						local traitLine = generalTraitLine(g)
						if traitLine then
							ScreenKit.note(body, traitLine, 100 + i * 2 + 1)
						end
					end
				else
					ScreenKit.note(body, "No generals hired.", 149)
				end
				local canBuy = (country.treasury or 0) >= goldCost and (country.politicalPower or 0) >= ppCost
				local buyRow = ScreenKit.buttonRow(body, 150)
				Button.create({
					parent = buyRow,
					variant = "secondary",
					text = string.format("Buy General \u{00B7} %d gold + %d PP", goldCost, ppCost),
					disabled = not canBuy,
					onClick = function()
						ctx.fire("BuyGeneral")
					end,
				})
			end

			-- Combat depth B: Army Groups list. Clicking a row selects the group's members on the map
			-- (ArmyView.focusArmy fires onArmySelected, which HudWiring coalesces into one ArmyPanel open).
			-- Superseded by the bottom-center card strip; shown only as the EnableGroupCards flag-off fallback.
			if WorldConstants.EnableArmyGroups and not WorldConstants.EnableGroupCards then
				ScreenKit.section(body, "Army Groups", 200)
				local groups = ownGroups()
				if #groups > 0 then
					for i, g in ipairs(groups) do
						local roster = country and country.generalRoster
						local commander = g.commanderId and roster and roster[g.commanderId]
						local commanderText = commander and generalName(commander) or "No general"
						local members = g.memberArmyIds or {}
						unitRow(
							body,
							string.format("%s  \u{00B7}  %d armies", g.name or "Army Group", #members),
							commanderText,
							200 + i,
							function()
								ArmyView.deselect()
								for _, memberId in ipairs(members) do
									ArmyView.focusArmy(memberId, true)
								end
							end
						)
					end
				else
					ScreenKit.note(body, "No army groups. Select armies, then Form Group.", 201)
				end
			end
		end,
		navy = function(body)
			local fleets = ownFleets()
			local shipTotal = 0
			for _, f in ipairs(fleets) do
				shipTotal += #(f.ships or {})
			end
			ScreenKit.section(body, "Naval Forces", 1)
			ScreenKit.stat(body, { icon = "Ship", label = "Fleets", value = tostring(#fleets), layoutOrder = 2 })
			ScreenKit.stat(body, { icon = "Anchor", label = "Ships", value = tostring(shipTotal), layoutOrder = 3 })

			ScreenKit.section(body, "Fleets", 5)
			if #fleets > 0 then
				for i, f in ipairs(fleets) do
					local info = fleetInfo(f, registries)
					unitRow(
						body,
						string.format("%s \u{00D7}%d", info.domName, info.total),
						fleetStatusLabel(f),
						5 + i,
						function()
							ctx.openFleetPanel({ fleetId = f.id, provinceId = f.provinceId })
						end
					)
				end
			else
				ScreenKit.note(body, "No fleets at sea.", 6)
			end
		end,
		doctrines = function(body)
			local c = ctx.cache.getCountry(ctx.tag)
			local slots = registries.DoctrineSlots
			local doctrines = registries.Doctrines
			if not slots or not doctrines then
				ScreenKit.note(body, "Doctrine data unavailable.", 1)
				return
			end
			local ordered = {}
			for id, def in slots do
				ordered[#ordered + 1] = { id = id, def = def }
			end
			table.sort(ordered, function(a, b)
				return (a.def.order or 0) < (b.def.order or 0)
			end)
			local active = (c and c.doctrines) or {}
			local order = 0
			for _, slot in ordered do
				order += 1
				ScreenKit.section(body, string.format("%s  \u{00B7}  Tier %s", slot.def.displayName or slot.id, val(slot.def.tier)), order)
				local options = {}
				for id, def in doctrines do
					if def.slot == slot.id then
						options[#options + 1] = { id = id, def = def }
					end
				end
				table.sort(options, function(a, b)
					return (a.def.displayName or a.id) < (b.def.displayName or b.id)
				end)
				if #options == 0 then
					order += 1
					ScreenKit.note(body, "No doctrines for this slot.", order)
				end
				for _, opt in options do
					local isActive = active[slot.id] == opt.id
					order += 1
					ScreenKit.stat(body, {
						icon = "Star",
						label = opt.def.displayName or opt.id,
						value = isActive and "ACTIVE" or "",
						valueColor = isActive and "positive" or nil,
						layoutOrder = order,
					})
					if opt.def.description then
						order += 1
						ScreenKit.note(body, opt.def.description, order)
					end
					local mods = modifierLine(opt.def.modifiers)
					if mods then
						order += 1
						ScreenKit.note(body, mods, order)
					end
					if not isActive then
						order += 1
						local row = ScreenKit.buttonRow(body, order)
						Button.create({
							parent = row,
							variant = "secondary",
							text = "Adopt",
							onClick = function()
								ctx.fire("SetDoctrine", opt.id)
							end,
						})
					end
				end
			end
		end,
	}

	activeTab = "army"
	local lastSig = nil
	local dirty = false

	function render(tab)
		-- The fills tracked here are about to be destroyed by clearBody(); drop them before they dangle.
		table.clear(liveBars)
		handle.clearBody()
		local fn = renderers[tab] or renderers.army
		fn(handle.body)
	end

	-- Hash only what the CURRENT tab visibly renders and can change. The army tab shows the manpower
	-- stat (coarsened to 1000-step buckets so the bar steps instead of rebuilding every economy tick),
	-- levy manpower, and the owned-armies list (dominant unit + total + state). The navy tab shows the
	-- fleet/ship counts and the owned-fleets list (dominant ship + total + status). Raw treasury and
	-- other non-displayed values are deliberately excluded so they don't force rebuilds.
	local function contentSignature(tabKey)
		local country = ctx.cache.getCountry(ctx.tag)
		local parts = { tabKey }
		if tabKey == "recruit" then
			-- Hash the queue by PRESENCE (id/unit/province/count), never by progress: the Heartbeat ticker
			-- advances the bars in place, so including a live fraction here would rebuild the whole tab every
			-- tenth of a second. Pools and the selected province's line count are what gate the buttons.
			if not country then
				parts[#parts + 1] = "noclaim"
			else
				parts[#parts + 1] = "mp:" .. tostring(country.manpower)
				parts[#parts + 1] = "lv:" .. tostring(country.levyManpower)
				parts[#parts + 1] = "tr:" .. tostring(country.treasury)
				parts[#parts + 1] = "sel:" .. tostring(selectedProvinceId)
				parts[#parts + 1] = "ln:" .. tostring(linesUsedAt(country, selectedProvinceId))
				local items = {}
				for _, t in ipairs(country.recruitQueue or {}) do
					items[#items + 1] = string.format(
						"%s~%s~%s~%d",
						tostring(t.id),
						tostring(t.unitTypeId),
						tostring(t.provinceId),
						t.count or 1
					)
				end
				table.sort(items)
				parts[#parts + 1] = "q:" .. table.concat(items, ",")
			end
		elseif tabKey == "navy" then
			local fleets = ownFleets()
			local shipTotal = 0
			local items = {}
			for _, f in ipairs(fleets) do
				local info = fleetInfo(f, registries)
				shipTotal += info.total
				items[#items + 1] =
					string.format("%s~%s~%d~%s", tostring(f.id), info.domName, info.total, tostring(f.status))
			end
			parts[#parts + 1] = "n:" .. #fleets
			parts[#parts + 1] = "s:" .. shipTotal
			parts[#parts + 1] = "f:" .. table.concat(items, ",")
		elseif tabKey == "doctrines" then
			local cc = ctx.cache.getCountry(ctx.tag)
			local d = {}
			if cc and type(cc.doctrines) == "table" then
				for slot, opt in cc.doctrines do
					d[#d + 1] = tostring(slot) .. "=" .. tostring(opt)
				end
				table.sort(d)
			end
			parts[#parts + 1] = "doc:" .. table.concat(d, ",")
		else
			if not country then
				parts[#parts + 1] = "noclaim"
			else
				-- Exact (not bucketed): these are shown as exact numbers and only regen monthly / on
				-- recruit, so the rare rebuild is fine and a bucket would freeze the displayed value.
				parts[#parts + 1] = "mp:" .. tostring(country.manpower)
				parts[#parts + 1] = "mx:" .. tostring(country.maxManpower)
				parts[#parts + 1] = "lv:" .. tostring(country.levyManpower)
			end
			local items = {}
			for _, a in ipairs(ownArmies()) do
				local info = armyInfo(a, registries)
				items[#items + 1] =
					string.format("%s~%s~%d~%s", tostring(a.id), info.domName, info.total, tostring(a.state))
			end
			parts[#parts + 1] = "a:" .. table.concat(items, ",")
			-- Combat depth C: generals list (name / level / assigned-group id) + buy affordability, so the
			-- roster + button state rebuild when a general is hired/assigned or the treasury/PP crosses cost.
			if WorldConstants.EnableGenerals and country then
				local gs = {}
				for _, g in ipairs(ownGenerals()) do
					gs[#gs + 1] = string.format("%s~%d~%s", generalName(g), g.level or 0, tostring(g.assignedGroupId or "0"))
				end
				local canBuy = (country.treasury or 0) >= (WorldConstants.GeneralBuyGoldCost or 0)
					and (country.politicalPower or 0) >= (WorldConstants.GeneralBuyPpCost or 0)
				parts[#parts + 1] = "gen:" .. table.concat(gs, ",")
				parts[#parts + 1] = "buy:" .. tostring(canBuy)
			end
			-- Combat depth B: groups list (name / member count / commander id) so it rebuilds on any change.
			if WorldConstants.EnableArmyGroups then
				local grs = {}
				for _, g in ipairs(ownGroups()) do
					grs[#grs + 1] =
						string.format("%s~%d~%s", tostring(g.name), #(g.memberArmyIds or {}), tostring(g.commanderId or "0"))
				end
				parts[#parts + 1] = "grp:" .. table.concat(grs, ",")
			end
		end
		return table.concat(parts, "|")
	end

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
			local sig = contentSignature(activeTab)
			if sig == lastSig then
				return
			end
			lastSig = sig
			render(activeTab)
		end)
	end

	handle = ScreenKit.open(ctx, {
		name = "MilitaryScreen",
		title = "Military",
		subtitle = #ownArmies() .. " regiments",
		tabs = TABS,
		activeTab = activeTab,
		onTab = function(key)
			activeTab = key
			lastSig = contentSignature(key)
			render(key)
		end,
	})
	render(activeTab)
	lastSig = contentSignature(activeTab)

	-- Advance the production bars in place. The recruit queue only changes on enqueue/complete, so without
	-- this the bars would sit frozen between rebuilds; and rebuilding the tab often enough to animate them
	-- would be far more expensive than moving a Frame's Size. 0.1s matches ProvinceOverview's ticker.
	local liveAccum = 0
	local hbConn = RunService.Heartbeat:Connect(function(dt)
		liveAccum += dt
		if liveAccum < 0.1 then
			return
		end
		liveAccum = 0
		if not (handle and handle.root and handle.root.Parent) then
			return
		end
		for _, b in ipairs(liveBars) do
			if b.fill and b.fill.Parent then
				b.fill.Size = UDim2.fromScale(math.clamp(b.live(), 0, 1), 1)
			end
		end
	end)
	table.insert(conns, function()
		hbConn:Disconnect()
	end)

	table.insert(conns, ctx.cache.onChangePrefix("armies", scheduleRefresh))
	table.insert(conns, ctx.cache.onChangePrefix("fleets", scheduleRefresh))
	table.insert(conns, ctx.cache.onChangePrefix("countries", scheduleRefresh))
	-- The recruit tab reads province districts (the Military gate) and devTier (the line cap).
	table.insert(conns, ctx.cache.onChangePrefix("provinces", scheduleRefresh))
	-- Combat depth B: the Army Groups list lives in the armyGroups collection (only when the in-screen
	-- list is the active surface; the card strip owns its own subscriptions otherwise).
	if WorldConstants.EnableArmyGroups and not WorldConstants.EnableGroupCards then
		table.insert(conns, ctx.cache.onChangePrefix("armyGroups", scheduleRefresh))
	end

	return {
		root = handle.root,
		destroy = function()
			for _, d in conns do
				pcall(d)
			end
			if handle then
				handle.destroy()
			end
		end,
	}
end

return MilitaryScreen
