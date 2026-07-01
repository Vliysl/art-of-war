local ScreenKit = require(script.Parent.ScreenKit)
local Components = script.Parent.Parent.Components
local Button = require(Components.Button)
local Modal = require(Components.Modal)
local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local aow = script.Parent.Parent.Parent -- ArtOfWar
local FormablesClient = require(aow.Modules.FormablesClient)
local WorldConstants = require(aow.Shared.WorldConstants)

local PoliticsScreen = {}

-- Three tabs: Court (ruler + meters + council), Estates, Reforms (government + ideology + policies).
-- Doctrines moved to the Military screen; the 3-phase Laws system was retired.
local TABS = {
	{ key = "overview", label = "Court" },
	{ key = "estates", label = "Estates" },
	{ key = "reforms", label = "Reforms" },
}

local function val(v)
	if v == nil or v == "" then
		return "\u{2014}"
	end
	return tostring(v)
end

local function signed(n)
	if type(n) ~= "number" then
		return "\u{2014}"
	end
	return (n > 0 and "+" or "") .. tostring(n)
end

local function round(n)
	if type(n) ~= "number" then
		return 0
	end
	return math.floor(n + 0.5)
end

local function tierColor(tier)
	if tier == "powerful" then
		return "positive"
	elseif tier == "marginalized" then
		return "negative"
	end
	return Colors.Warning
end

local function count(map)
	local n = 0
	if type(map) == "table" then
		for _ in map do
			n += 1
		end
	end
	return n
end

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

function PoliticsScreen.create(ctx)
	local registries = ctx.registries or {}
	local handle
	local conns = {}
	local currentTab = "overview"

	local function country()
		if ctx.tag and ctx.cache then
			return ctx.cache.getCountry(ctx.tag)
		end
		return nil
	end

	local function govName(c)
		local gov = registries.GovernmentTypes and c and registries.GovernmentTypes[c.governmentForm]
		return gov and gov.displayName or (c and c.governmentForm)
	end

	-- Authority meter label adapts to government archetype (Crown / Republican / Chiefly).
	local function authorityLabel(c)
		local ga = registries.GovernmentArchetypes
		if ga and ga.labelsFor and c then
			local labels = ga.labelsFor(c.governmentForm)
			if labels and labels.authority then return labels.authority end
		end
		return "Crown Authority"
	end

	local function rulerWord(c)
		local ga = registries.GovernmentArchetypes
		local labels = ga and ga.labelsFor and ga.labelsFor(c and c.governmentForm)
		return (labels and labels.leaderWord) or "Ruler"
	end

	-- The ruler card sits at the top of the Court (overview) tab. Negative layoutOrders keep it
	-- above the "Authority" section (order 1) without renumbering the meters.
	local function renderRulerCard(body, c)
		ScreenKit.section(body, rulerWord(c), -20)
		local r = c and c.ruler
		if not r then
			ScreenKit.note(body, "The throne stands vacant.", -19)
			return
		end
		ScreenKit.stat(body, {
			icon = "Star",
			label = (r.title or "Ruler") .. (r.isRegent and "  (Regent)" or ""),
			value = string.format("%s %s", r.firstName or "", r.lastName or ""),
			layoutOrder = -18,
		})
		ScreenKit.stat(body, { label = "Age", value = tostring(r.age or "\u{2014}"), mono = true, layoutOrder = -17 })
		ScreenKit.stat(body, {
			label = "ADM / DIP / MIL",
			value = string.format("%d / %d / %d", r.adm or 0, r.dip or 0, r.mil or 0),
			mono = true,
			layoutOrder = -16,
		})
		local names = {}
		for _, tid in (r.traits or {}) do
			local t = registries.LeaderTraits and registries.LeaderTraits[tid]
			names[#names + 1] = (t and t.displayName) or tid
		end
		if #names > 0 then
			ScreenKit.note(body, table.concat(names, "  \u{00B7}  "), -15)
		end
		if c.heir then
			ScreenKit.stat(body, {
				label = "Heir",
				value = string.format("%s %s (claim %d)", c.heir.firstName or "", c.heir.lastName or "", c.heir.legitimacyClaim or 0),
				layoutOrder = -14,
			})
		else
			local ga = registries.GovernmentArchetypes
			local kind = ga and ga.get and ga.get(c.governmentForm).successionKind
			if kind == "republican_term" then
				ScreenKit.note(body, "The head of state serves a fixed term.", -14)
			elseif kind == "elective" then
				ScreenKit.note(body, "Succession is decided by election.", -14)
			elseif kind == "tribal_strongest" then
				ScreenKit.note(body, "The strongest claimant inherits.", -14)
			end
		end
	end

	local function openIdeologyPicker()
		local c = country()
		local gov = registries.GovernmentTypes and c and registries.GovernmentTypes[c.governmentForm]
		local allowed = (gov and gov.allowedIdeologies) or {}
		local pp = (c and c.politicalPower) or 0
		local modal = Modal.create({
			parent = ctx.modalLayer or ctx.parent,
			title = "Change Ideology",
			subtitle = "Costs 60 PP",
			width = 420,
			height = 460,
		})
		local list = Instance.new("ScrollingFrame")
		list.Size = UDim2.fromScale(1, 1)
		list.BackgroundTransparency = 1
		list.BorderSizePixel = 0
		list.ScrollBarThickness = 4
		list.AutomaticCanvasSize = Enum.AutomaticSize.Y
		list.CanvasSize = UDim2.new()
		list.Parent = modal.content
		local layout = Instance.new("UIListLayout")
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 6)
		layout.Parent = list

		local order = 0
		local any = false
		for _, id in ipairs(allowed) do
			if id ~= (c and c.ideology) then
				any = true
				local def = registries.Ideologies and registries.Ideologies[id]
				order += 1
				local row = ScreenKit.stat(list, {
					icon = "Politics",
					label = (def and def.displayName) or id,
					layoutOrder = order,
				})
				local btn = Button.create({
					parent = row,
					variant = "primary",
					text = "Adopt",
					width = 96,
					size = "sm",
					disabled = pp < 60,
					onClick = function()
						ctx.fire("SetIdeology", id)
						modal.close()
					end,
				})
				btn.AnchorPoint = Vector2.new(1, 0.5)
				btn.Position = UDim2.fromScale(1, 0.5)
				local mods = modifierLine(def and def.modifiers)
				if mods then
					order += 1
					ScreenKit.note(list, mods, order)
				end
			end
		end
		if not any then
			ScreenKit.note(list, "No alternative ideologies are available to your government.", 1)
		end
	end

	local function openTransitionConfirm(targetGovId, def)
		local c = country()
		local govs = registries.GovernmentTypes or {}
		local target = govs[targetGovId]
		local pp = (c and c.politicalPower) or 0
		local cost = def.ppCost or 0
		local allowed = (target and target.allowedIdeologies) or {}
		local chosen = nil
		for _, id in ipairs(allowed) do
			if id == (c and c.ideology) then
				chosen = id
				break
			end
		end
		chosen = chosen or allowed[1]

		local modal = Modal.create({
			parent = ctx.modalLayer or ctx.parent,
			title = "Begin Transition",
			subtitle = (target and target.displayName) or targetGovId,
			width = 440,
			height = 460,
			footer = true,
		})
		local content = modal.content
		local layout = Instance.new("UIListLayout")
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 6)
		layout.Parent = content

		ScreenKit.stat(
			content,
			{ icon = "PowerProj", label = "Cost", value = cost .. " PP", mono = true, layoutOrder = 1 }
		)
		if def.minYears then
			ScreenKit.stat(content, { label = "Minimum duration", value = def.minYears .. " yrs", layoutOrder = 2 })
		end
		local req = def.requires
		if type(req) == "table" then
			if req.ideology then
				ScreenKit.note(content, "Requires current ideology: " .. tostring(req.ideology), 3)
			end
			if req.minLegitimacy then
				ScreenKit.note(content, "Requires legitimacy \u{2265} " .. tostring(req.minLegitimacy), 4)
			end
			if type(req.faction) == "table" then
				for fid, clout in pairs(req.faction) do
					local fname = (
						registries.Factions
						and registries.Factions[fid]
						and registries.Factions[fid].displayName
					) or fid
					ScreenKit.note(content, string.format("Requires %s clout \u{2265} %g%%", fname, clout * 100), 5)
				end
			end
			if req.religion then
				ScreenKit.note(content, "Requires state religion: " .. tostring(req.religion), 6)
			end
			if req.cause then
				ScreenKit.note(content, "Typically occurs only via " .. tostring(req.cause) .. ".", 7)
			end
		end

		ScreenKit.section(content, "Adopt Ideology", 10)
		local ideoBox = Instance.new("Frame")
		ideoBox.Size = UDim2.fromScale(1, 0)
		ideoBox.AutomaticSize = Enum.AutomaticSize.Y
		ideoBox.BackgroundTransparency = 1
		ideoBox.LayoutOrder = 11
		ideoBox.Parent = content
		local ideoLayout = Instance.new("UIListLayout")
		ideoLayout.FillDirection = Enum.FillDirection.Horizontal
		ideoLayout.Wraps = true
		ideoLayout.SortOrder = Enum.SortOrder.LayoutOrder
		ideoLayout.Padding = UDim.new(0, 6)
		ideoLayout.Parent = ideoBox

		local selectedIdeo = chosen
		local function renderIdeo()
			for _, ch in ideoBox:GetChildren() do
				if ch:IsA("GuiObject") then
					ch:Destroy()
				end
			end
			for i, id in ipairs(allowed) do
				local def2 = registries.Ideologies and registries.Ideologies[id]
				Button.create({
					parent = ideoBox,
					variant = id == selectedIdeo and "primary" or "secondary",
					text = (def2 and def2.displayName) or id,
					layoutOrder = i,
					onClick = function()
						selectedIdeo = id
						renderIdeo()
					end,
				})
			end
		end
		renderIdeo()

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
			variant = "primary",
			text = "Begin Transition",
			layoutOrder = 2,
			disabled = pp < cost or selectedIdeo == nil,
			onClick = function()
				if selectedIdeo then
					ctx.fire("SetGovernmentType", targetGovId, selectedIdeo)
				end
				modal.close()
			end,
		})
	end

	local renderers = {
		-- Releasables (Phase 4): release a nation from your cores as independent or puppet. Eligibility is
		-- client-checked against the replicated cache; the server re-validates on ReleaseNation.
		releasables = function(body)
			if not WorldConstants.EnableFormables then
				ScreenKit.note(body, "Releasing nations is not enabled.", 1)
				return
			end
			local myTag = ctx.tag
			local eligible = {}
			for tag, def in pairs(FormablesClient.getAll()) do
				if def.canRelease ~= false
					and def.requiredProvinceIds and #def.requiredProvinceIds > 0
					and not (ctx.cache and ctx.cache.getCountry(tag)) then
					local ownsAll = myTag ~= nil
					for _, id in ipairs(def.requiredProvinceIds) do
						local p = ctx.cache and ctx.cache.getProvince(id)
						if not p or p.ownerTag ~= myTag then
							ownsAll = false
							break
						end
					end
					if ownsAll then
						eligible[#eligible + 1] = { tag = tag, def = def }
					end
				end
			end
			table.sort(eligible, function(a, b)
				return (a.def.displayName or a.tag) < (b.def.displayName or b.tag)
			end)

			ScreenKit.section(body, "Releasable Nations", 1)
			if #eligible == 0 then
				ScreenKit.note(body, "No nations can be released \u{2014} you must hold a releasable's full core territory.", 2)
				return
			end
			local order = 2
			for _, e in ipairs(eligible) do
				order += 1
				local row = ScreenKit.stat(body, { icon = "Politics", label = e.def.displayName or e.tag, layoutOrder = order })
				local puppetBtn = Button.create({
					parent = row,
					variant = "secondary",
					text = "Puppet",
					width = 84,
					size = "sm",
					onClick = function()
						ctx.fire("ReleaseNation", e.tag, true)
					end,
				})
				puppetBtn.AnchorPoint = Vector2.new(1, 0.5)
				puppetBtn.Position = UDim2.new(1, -92, 0.5, 0)
				local freeBtn = Button.create({
					parent = row,
					variant = "primary",
					text = "Release",
					width = 84,
					size = "sm",
					onClick = function()
						ctx.fire("ReleaseNation", e.tag, false)
					end,
				})
				freeBtn.AnchorPoint = Vector2.new(1, 0.5)
				freeBtn.Position = UDim2.fromScale(1, 0.5)
			end
		end,
		overview = function(body, c)
			renderRulerCard(body, c)
			ScreenKit.section(body, "Authority", 1)
			local authCap = (c and c.crownAuthorityCap) or 100
			ScreenKit.stat(body, {
				icon = "PowerProj",
				label = authorityLabel(c),
				value = round(c and c.crownAuthority) .. " / " .. round(authCap),
				progress = { value = c and c.crownAuthority or 0, max = authCap, color = "amber" },
				layoutOrder = 2,
			})
			ScreenKit.stat(body, {
				icon = "Legitimacy",
				label = "Legitimacy",
				value = round(c and c.legitimacy) .. "%",
				progress = { value = c and c.legitimacy or 0, max = 100, color = "green" },
				layoutOrder = 3,
			})
			ScreenKit.stat(body, {
				icon = "Stability",
				label = "Stability",
				value = signed(c and c.stability),
				valueColor = (c and c.stability ~= nil) and (c.stability < 0 and "negative" or "positive") or nil,
				layoutOrder = 4,
			})
			local unrest = (c and c.unrest) or 0
			ScreenKit.stat(body, {
				label = "Unrest",
				value = round(unrest) .. "%",
				valueColor = unrest >= 50 and "negative" or (unrest >= 25 and "warning" or "positive"),
				progress = { value = unrest, max = 100, color = unrest >= 50 and "red" or "amber" },
				layoutOrder = 5,
			})
			ScreenKit.stat(body, {
				icon = "PowerProj",
				label = "Political Power",
				value = val(c and c.politicalPower),
				mono = true,
				layoutOrder = 6,
			})
			if c and c.prestige ~= nil then
				ScreenKit.stat(body, {
					icon = "Prestige",
					label = "Prestige",
					value = signed(c.prestige),
					valueColor = c.prestige < 0 and "negative" or "positive",
					layoutOrder = 7,
				})
			end

			-- Council (ministers) — folded into the Court (was its own Leaders tab)
			local slots = registries.LeaderSlots
			if slots then
				ScreenKit.section(body, "Council", 30)
				local ordered = {}
				for id, def in slots do
					ordered[#ordered + 1] = { id = id, def = def }
				end
				table.sort(ordered, function(a, b)
					return (a.def.order or 0) < (b.def.order or 0)
				end)
				local leaders = (c and c.leaders) or {}
				local candidates = (c and c.leaderCandidates) or {}
				local order = 30
				for _, entry in ordered do
					local leader = leaders[entry.id]
					if entry.def.unlockedByDefault == false and not leader then
						continue
					end
					order += 1
					local row = ScreenKit.stat(body, {
						label = entry.def.displayName or entry.id,
						value = leader and (((leader.firstName or "") .. " " .. (leader.lastName or "")):gsub("%s+$", "")) or "Vacant",
						valueColor = (not leader) and "negative" or nil,
						layoutOrder = order,
					})
					if leader then
						local b = Button.create({ parent = row, variant = "ghost", text = "Dismiss", width = 92, size = "sm", onClick = function() ctx.fire("DismissLeader", entry.id) end })
						b.AnchorPoint = Vector2.new(1, 0.5)
						b.Position = UDim2.fromScale(1, 0.5)
					elseif count(candidates[entry.id]) > 0 then
						local b = Button.create({ parent = row, variant = "secondary", text = "Appoint", width = 92, size = "sm", onClick = function() ctx.fire("AppointLeader", entry.id, 1) end })
						b.AnchorPoint = Vector2.new(1, 0.5)
						b.Position = UDim2.fromScale(1, 0.5)
					end
				end
			end
		end,
		government = function(body, c)
			ScreenKit.section(body, "Form", 1)
			ScreenKit.stat(body, { icon = "Core", label = "Government", value = val(govName(c)), layoutOrder = 2 })
			local ideo = registries.Ideologies and c and registries.Ideologies[c.ideology]
			ScreenKit.stat(body, {
				label = "Ruling Ideology",
				value = val(ideo and ideo.displayName or (c and c.ideology)),
				layoutOrder = 3,
			})
			local pp = (c and c.politicalPower) or 0
			local ideoRow = ScreenKit.buttonRow(body, 4)
			Button.create({
				parent = ideoRow,
				variant = "secondary",
				text = "Change Ideology \u{00B7} 60 PP",
				disabled = pp < 60,
				onClick = openIdeologyPicker,
			})

			local transition = c and c.transition
			if type(transition) == "table" then
				ScreenKit.section(body, "Transition in Progress", 10)
				local govs = registries.GovernmentTypes or {}
				local fromName = (govs[transition.from] and govs[transition.from].displayName) or transition.from
				local toName = (govs[transition.to] and govs[transition.to].displayName) or transition.to
				ScreenKit.stat(body, {
					icon = "Core",
					label = "Changing to",
					value = string.format("%s \u{2192} %s", val(fromName), val(toName)),
					layoutOrder = 11,
				})
				if transition.completesAtDay then
					ScreenKit.stat(body, {
						label = "Completes",
						value = "Day " .. tostring(transition.completesAtDay),
						mono = true,
						layoutOrder = 12,
					})
				end
				ScreenKit.note(body, "Cancelling refunds 50% of the PP spent and costs 5 legitimacy.", 13)
				local cancelRow = ScreenKit.buttonRow(body, 14)
				Button.create({
					parent = cancelRow,
					variant = "danger",
					text = "Cancel Transition",
					onClick = function()
						ctx.fire("CancelTransition")
					end,
				})
				return
			end

			ScreenKit.section(body, "Available Transitions", 20)
			local gov = registries.GovernmentTypes and c and registries.GovernmentTypes[c.governmentForm]
			local transitions = gov and gov.transitions
			if transitions and next(transitions) then
				local ordered = {}
				for id, def in transitions do
					local target = registries.GovernmentTypes and registries.GovernmentTypes[id]
					ordered[#ordered + 1] = {
						id = id,
						def = def,
						label = target and target.displayName or id,
						cost = def.ppCost or 0,
					}
				end
				table.sort(ordered, function(a, b)
					return a.label < b.label
				end)
				local order = 20
				for _, entry in ipairs(ordered) do
					order += 1
					local row = ScreenKit.stat(body, {
						label = string.format("%s  \u{00B7}  %d PP", entry.label, entry.cost),
						layoutOrder = order,
					})
					local btn = Button.create({
						parent = row,
						variant = "secondary",
						text = "Begin",
						width = 84,
						size = "sm",
						disabled = pp < entry.cost,
						onClick = function()
							openTransitionConfirm(entry.id, entry.def)
						end,
					})
					btn.AnchorPoint = Vector2.new(1, 0.5)
					btn.Position = UDim2.fromScale(1, 0.5)
				end
			else
				ScreenKit.note(body, "No government transitions are available.", 21)
			end
		end,
		estates = function(body, c)
			local factions = c and c.factions
			local ordered = {}
			if type(factions) == "table" then
				for key, record in factions do
					local id = record.id or key
					if id ~= "crown" then
						ordered[#ordered + 1] = { id = id, record = record }
					end
				end
			end
			if #ordered == 0 then
				ScreenKit.note(body, "No estates in the realm.", 1)
				return
			end
			table.sort(ordered, function(a, b)
				return (a.record.clout or 0) > (b.record.clout or 0)
			end)

			-- index privileges by estate
			local privByEstate = {}
			for pid, pdef in (registries.Privileges or {}) do
				local list = privByEstate[pdef.estateId]
				if not list then list = {}; privByEstate[pdef.estateId] = list end
				list[#list + 1] = { id = pid, def = pdef }
			end
			local granted = (c and c.estatePrivileges) or {}

			local order = 0
			for _, entry in ordered do
				local def = registries.Factions and registries.Factions[entry.id]
				local rec = entry.record
				local clout = rec.clout or 0
				local loyalty = rec.loyalty or 50
				local tier = rec.tier or "influential"

				order += 1
				ScreenKit.section(body, def and def.displayName or entry.id, order)
				order += 1
				ScreenKit.stat(body, {
					label = "Influence",
					value = tier:upper(),
					valueColor = tierColor(tier),
					progress = { value = clout * 100, max = 100, color = "amber" },
					layoutOrder = order,
				})
				order += 1
				ScreenKit.stat(body, {
					label = "Loyalty",
					value = round(loyalty) .. "%",
					valueColor = loyalty >= 60 and "positive" or (loyalty < 35 and "negative" or nil),
					progress = { value = loyalty, max = 100, color = loyalty < 35 and "red" or "green" },
					layoutOrder = order,
				})

				local privList = privByEstate[entry.id] or {}
				table.sort(privList, function(a, b)
					return (a.def.displayName or a.id) < (b.def.displayName or b.id)
				end)
				for _, p in ipairs(privList) do
					order += 1
					local isGranted = granted[p.id] ~= nil
					local capCost = p.def.authorityCap or 0
					local row = ScreenKit.stat(body, {
						label = p.def.displayName or p.id,
						value = isGranted and "GRANTED" or (capCost ~= 0 and (tostring(capCost) .. " auth") or ""),
						valueColor = isGranted and "positive" or "warning",
						layoutOrder = order,
					})
					local btn = Button.create({
						parent = row,
						variant = isGranted and "danger" or "secondary",
						text = isGranted and "Revoke" or "Grant",
						width = 92,
						size = "sm",
						onClick = function()
							if isGranted then
								ctx.fire("RevokePrivilege", p.id)
							else
								ctx.fire("GrantPrivilege", p.id)
							end
						end,
					})
					btn.AnchorPoint = Vector2.new(1, 0.5)
					btn.Position = UDim2.fromScale(1, 0.5)
				end

				order += 1
				local seizeRow = ScreenKit.buttonRow(body, order)
				Button.create({
					parent = seizeRow,
					variant = "secondary",
					text = "Seize Power",
					size = "sm",
					onClick = function()
						ctx.fire("SeizePower", entry.id)
					end,
				})
			end
		end,
		leaders = function(body, c)
			local slots = registries.LeaderSlots
			if not slots then
				ScreenKit.note(body, "Leader data unavailable.", 1)
				return
			end
			local ordered = {}
			for id, def in slots do
				ordered[#ordered + 1] = { id = id, def = def }
			end
			table.sort(ordered, function(a, b)
				return (a.def.order or 0) < (b.def.order or 0)
			end)
			local leaders = (c and c.leaders) or {}
			local candidates = (c and c.leaderCandidates) or {}
			local order = 0
			for _, entry in ordered do
				local leader = leaders[entry.id]
				if entry.def.unlockedByDefault == false and not leader then
					continue
				end
				order += 1
				ScreenKit.section(body, entry.def.displayName or entry.id, order)
				order += 1
				if leader then
					ScreenKit.stat(body, {
						icon = "Star",
						label = leader.title or "Minister",
						value = string.format("%s %s", leader.firstName or "", leader.lastName or ""),
						layoutOrder = order,
					})
					local traitNames = {}
					if leader.traits then
						for _, tid in leader.traits do
							local trait = registries.LeaderTraits and registries.LeaderTraits[tid]
							traitNames[#traitNames + 1] = trait and trait.displayName or tid
						end
					end
					if #traitNames > 0 then
						order += 1
						ScreenKit.note(body, table.concat(traitNames, ", "), order)
					end
					order += 1
					local row = ScreenKit.buttonRow(body, order)
					Button.create({
						parent = row,
						variant = "ghost",
						text = "Dismiss",
						onClick = function()
							ctx.fire("DismissLeader", entry.id)
						end,
					})
				else
					local pool = count(candidates[entry.id])
					ScreenKit.stat(body, {
						label = "Seat",
						value = "Vacant",
						valueColor = "negative",
						layoutOrder = order,
					})
					order += 1
					ScreenKit.note(
						body,
						pool > 0 and string.format("%d candidate%s available", pool, pool == 1 and "" or "s")
							or "Awaiting candidates.",
						order
					)
					if pool > 0 then
						order += 1
						local row = ScreenKit.buttonRow(body, order)
						Button.create({
							parent = row,
							variant = "secondary",
							text = "Appoint",
							onClick = function()
								ctx.fire("AppointLeader", entry.id, 1)
							end,
						})
					end
				end
			end
		end,
		policies = function(body, c, baseOrder)
			local policies = registries.Policies
			if not policies then
				ScreenKit.note(body, "Policy data unavailable.", 1)
				return
			end
			local active = (c and c.activePolicies) or {}
			local ideology = c and c.ideology
			local ordered = {}
			for id, def in policies do
				local gate = def.ideologyGate
				local eligible = (not gate) or gate == "any" or gate == ideology
				local isActive = active[id] ~= nil
				if eligible or isActive then
					ordered[#ordered + 1] = { id = id, def = def, active = isActive }
				end
			end
			if #ordered == 0 then
				ScreenKit.note(body, "No policies available to your ideology.", 1)
				return
			end
			table.sort(ordered, function(a, b)
				if a.active ~= b.active then
					return a.active
				end
				return (a.def.displayName or a.id) < (b.def.displayName or b.id)
			end)
			local order = baseOrder or 0
			for _, entry in ordered do
				order += 1
				ScreenKit.section(body, entry.def.displayName or entry.id, order)
				order += 1
				ScreenKit.stat(body, {
					label = "Cost",
					value = string.format("%g PP  \u{00B7}  Upkeep %g", entry.def.ppCost or 0, entry.def.ppUpkeep or 0),
					mono = true,
					layoutOrder = order,
				})
				if entry.def.ideologyGate and entry.def.ideologyGate ~= "any" then
					order += 1
					ScreenKit.note(body, "Requires ideology: " .. entry.def.ideologyGate, order)
				end
				order += 1
				local row = ScreenKit.buttonRow(body, order)
				if entry.active then
					Button.create({
						parent = row,
						variant = "ghost",
						text = "Repeal",
						onClick = function()
							ctx.fire("RepealPolicy", entry.id)
						end,
					})
				else
					Button.create({
						parent = row,
						variant = "secondary",
						text = "Enact",
						onClick = function()
							ctx.fire("EnactPolicy", entry.id)
						end,
					})
				end
			end
		end,
		laws = function(body, c)
			ScreenKit.section(body, "Law in Progress", 1)
			local pass = c and c.lawPass
			if pass then
				local def = registries.Policies and registries.Policies[pass.policyId]
				local phase = pass.phase or 1
				ScreenKit.stat(body, {
					icon = "Politics",
					label = def and def.displayName or pass.policyId,
					value = string.format("Phase %d of 3", phase),
					progress = { value = phase, max = 3, color = "amber" },
					layoutOrder = 2,
				})
				ScreenKit.stat(body, { label = "Setbacks", value = val(pass.setbacksTotal or 0), layoutOrder = 3 })
				ScreenKit.stat(body, {
					label = "PP invested",
					value = val(pass.ppSpent or 0),
					mono = true,
					layoutOrder = 4,
				})
				local row = ScreenKit.buttonRow(body, 5)
				Button.create({
					parent = row,
					variant = "danger",
					text = "Cancel Law",
					onClick = function()
						ctx.fire("CancelLaw")
					end,
				})
			else
				ScreenKit.note(body, "No law in progress.", 2)
			end

			local cooldowns = c and c.lawCooldowns
			if cooldowns and next(cooldowns) then
				ScreenKit.section(body, "Cooldowns", 20)
				local ordered = {}
				for id, day in cooldowns do
					local def = registries.Policies and registries.Policies[id]
					ordered[#ordered + 1] = { label = def and def.displayName or id, day = day }
				end
				table.sort(ordered, function(a, b)
					return a.label < b.label
				end)
				for i, entry in ordered do
					ScreenKit.note(
						body,
						string.format("%s (cooldown until day %s)", entry.label, val(entry.day)),
						20 + i
					)
				end
			end
		end,
		doctrines = function(body, c)
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
				ScreenKit.section(
					body,
					string.format("%s  \u{00B7}  Tier %s", slot.def.displayName or slot.id, val(slot.def.tier)),
					order
				)
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

	local function render(tab)
		currentTab = tab
		handle.clearBody()
		local c = country()
		-- Reforms = the old Government tab + the old Policies tab, merged. Policies render with an order
		-- offset so they sit below the government/transition section instead of interleaving with it.
		if tab == "reforms" then
			renderers.government(handle.body, c)
			ScreenKit.section(handle.body, "Edicts & Reforms", 99)
			renderers.policies(handle.body, c, 100)
			return
		end
		local fn = renderers[tab] or renderers.overview
		fn(handle.body, c)
	end

	local lastSig = nil
	local dirty = false

	-- Hash ONLY what the current tab visibly renders and can change. Continuous numbers
	-- (PP/legitimacy/stability/prestige/clout/lawPass progress) are coarsened into integer
	-- buckets so they step instead of rebuilding every economy micro-tick. Sets (policies,
	-- doctrines, factions, cooldowns, leaders, transition) are sorted for stability. Static
	-- registry-derived structure (available transitions, doctrine options, policy gating) is
	-- driven by mutable country fields already in the signature (governmentForm, ideology, PP).
	local function contentSignature(tabKey)
		local c = country()
		local parts = { tabKey }
		if not c then
			parts[#parts + 1] = "noclaim"
			return table.concat(parts, "|")
		end
		-- PP coarsened but kept fine enough to flip the transition/ideology button gates.
		local ppBucket = math.floor((c.politicalPower or 0) / 5)
		if tabKey == "overview" then
			parts[#parts + 1] = "leg:" .. round(c.legitimacy)
			parts[#parts + 1] = "stab:" .. tostring(c.stability)
			parts[#parts + 1] = "pp:" .. tostring(c.politicalPower)
			parts[#parts + 1] = "prest:" .. tostring(c.prestige)
			parts[#parts + 1] = "auth:" .. round(c.crownAuthority or 0) .. "/" .. round(c.crownAuthorityCap or 100)
			parts[#parts + 1] = "unrest:" .. round(c.unrest or 0)
			local r = c.ruler
			parts[#parts + 1] = "ruler:" .. (r and (tostring(r.id) .. "/" .. tostring(r.age) .. "/" .. (r.isRegent and "R" or "")) or "none")
			parts[#parts + 1] = "heir:" .. (c.heir and tostring(c.heir.id) or "none")
			local led = {}
			for id, l in (c.leaders or {}) do led[#led + 1] = tostring(id) .. ":" .. tostring(l.id) end
			for id, pool in (c.leaderCandidates or {}) do led[#led + 1] = "cand:" .. tostring(id) .. "=" .. count(pool) end
			table.sort(led)
			parts[#parts + 1] = "led:" .. table.concat(led, ",")
		elseif tabKey == "reforms" then
			parts[#parts + 1] = "gov:" .. tostring(c.governmentForm)
			parts[#parts + 1] = "ideo:" .. tostring(c.ideology)
			parts[#parts + 1] = "pp:" .. ppBucket
			local tr = c.transition
			parts[#parts + 1] = type(tr) == "table"
					and string.format("tr:%s>%s@%s", tostring(tr.from), tostring(tr.to), tostring(tr.completesAtDay))
				or "tr:none"
			local active = {}
			if type(c.activePolicies) == "table" then
				for id in c.activePolicies do
					active[#active + 1] = tostring(id)
				end
				table.sort(active)
			end
			parts[#parts + 1] = "pol:" .. table.concat(active, ",")
		elseif tabKey == "government" then
			parts[#parts + 1] = "gov:" .. tostring(c.governmentForm)
			parts[#parts + 1] = "ideo:" .. tostring(c.ideology)
			parts[#parts + 1] = "pp:" .. ppBucket
			local tr = c.transition
			if type(tr) == "table" then
				parts[#parts + 1] =
					string.format("tr:%s>%s@%s", tostring(tr.from), tostring(tr.to), tostring(tr.completesAtDay))
			else
				parts[#parts + 1] = "tr:none"
			end
		elseif tabKey == "estates" then
			local f = {}
			if type(c.factions) == "table" then
				for key, record in c.factions do
					f[#f + 1] = string.format(
						"%s=%s/%s",
						tostring(record.id or key),
						tostring(record.tier or "influential"),
						tostring(math.floor((record.clout or 0) * 100))
					)
				end
				table.sort(f)
			end
			parts[#parts + 1] = "fac:" .. table.concat(f, ",")
			local loy = {}
			if type(c.factions) == "table" then
				for key, record in c.factions do
					loy[#loy + 1] = tostring(record.id or key) .. "=" .. tostring(math.floor(record.loyalty or 50))
				end
				table.sort(loy)
			end
			parts[#parts + 1] = "loy:" .. table.concat(loy, ",")
			local pr = {}
			if type(c.estatePrivileges) == "table" then
				for pid in c.estatePrivileges do
					pr[#pr + 1] = tostring(pid)
				end
				table.sort(pr)
			end
			parts[#parts + 1] = "priv:" .. table.concat(pr, ",")
			parts[#parts + 1] = "auth:" .. round(c.crownAuthority or 0)
		elseif tabKey == "leaders" then
			local l = {}
			local leaders = c.leaders or {}
			local candidates = c.leaderCandidates or {}
			for id, leader in leaders do
				local traits = leader.traits and table.concat(leader.traits, "+") or ""
				l[#l + 1] = string.format(
					"%s:%s/%s/%s/%s",
					tostring(id),
					tostring(leader.title),
					tostring(leader.firstName),
					tostring(leader.lastName),
					traits
				)
			end
			for id, pool in candidates do
				l[#l + 1] = string.format("cand:%s=%d", tostring(id), count(pool))
			end
			table.sort(l)
			parts[#parts + 1] = "led:" .. table.concat(l, ",")
		elseif tabKey == "policies" then
			parts[#parts + 1] = "ideo:" .. tostring(c.ideology)
			local active = {}
			if type(c.activePolicies) == "table" then
				for id in c.activePolicies do
					active[#active + 1] = tostring(id)
				end
				table.sort(active)
			end
			parts[#parts + 1] = "pol:" .. table.concat(active, ",")
		elseif tabKey == "laws" then
			local pass = c.lawPass
			if type(pass) == "table" then
				parts[#parts + 1] = string.format(
					"law:%s/%s/%s/%s",
					tostring(pass.policyId),
					tostring(pass.phase or 1),
					tostring(pass.setbacksTotal or 0),
					tostring(pass.ppSpent or 0)
				)
			else
				parts[#parts + 1] = "law:none"
			end
			local cd = {}
			if type(c.lawCooldowns) == "table" then
				for id, day in c.lawCooldowns do
					cd[#cd + 1] = tostring(id) .. "=" .. tostring(day)
				end
				table.sort(cd)
			end
			parts[#parts + 1] = "cd:" .. table.concat(cd, ",")
		elseif tabKey == "doctrines" then
			local d = {}
			if type(c.doctrines) == "table" then
				for slot, opt in c.doctrines do
					d[#d + 1] = tostring(slot) .. "=" .. tostring(opt)
				end
				table.sort(d)
			end
			parts[#parts + 1] = "doc:" .. table.concat(d, ",")
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
			local sig = contentSignature(currentTab)
			if sig == lastSig then
				return
			end
			lastSig = sig
			render(currentTab)
		end)
	end

	local c0 = country()
	local tabs = table.clone(TABS)
	if WorldConstants.EnableFormables then
		table.insert(tabs, { key = "releasables", label = "Releasables" })
	end
	handle = ScreenKit.open(ctx, {
		name = "PoliticsScreen",
		title = "Government",
		subtitle = ((c0 and c0.displayName) or ctx.tag or "Realm") .. "  \u{00B7}  " .. val(govName(c0)),
		size = UDim2.new(0, 512, 1, -132),
		tabs = tabs,
		activeTab = "overview",
		onTab = function(key)
			render(key)
			lastSig = contentSignature(key)
		end,
	})

	if ctx.cache then
		table.insert(conns, ctx.cache.onChangePrefix("countries", scheduleRefresh))
	end

	render("overview")
	lastSig = contentSignature(currentTab)

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

return PoliticsScreen
