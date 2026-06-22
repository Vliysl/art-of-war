local ScreenKit = require(script.Parent.ScreenKit)
local Components = script.Parent.Parent.Components
local Button = require(Components.Button)
local Modal = require(Components.Modal)
local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors

local PoliticsScreen = {}

local TABS = {
	{ key = "overview", label = "Overview" },
	{ key = "government", label = "Government" },
	{ key = "estates", label = "Estates" },
	{ key = "leaders", label = "Leaders" },
	{ key = "policies", label = "Policies" },
	{ key = "laws", label = "Laws" },
	{ key = "doctrines", label = "Doctrines" },
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
		overview = function(body, c)
			ScreenKit.section(body, "Authority", 1)
			ScreenKit.stat(body, {
				icon = "Legitimacy",
				label = "Legitimacy",
				value = round(c and c.legitimacy) .. "%",
				progress = { value = c and c.legitimacy or 0, max = 100, color = "green" },
				layoutOrder = 2,
			})
			ScreenKit.stat(body, {
				icon = "Stability",
				label = "Stability",
				value = signed(c and c.stability),
				valueColor = (c and c.stability ~= nil) and (c.stability < 0 and "negative" or "positive") or nil,
				layoutOrder = 3,
			})
			ScreenKit.stat(body, {
				icon = "PowerProj",
				label = "Political Power",
				value = val(c and c.politicalPower),
				mono = true,
				layoutOrder = 4,
			})
			if c and c.prestige ~= nil then
				ScreenKit.stat(body, {
					icon = "Prestige",
					label = "Prestige",
					value = signed(c.prestige),
					valueColor = c.prestige < 0 and "negative" or "positive",
					layoutOrder = 5,
				})
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
			ScreenKit.section(body, "Factions", 1)
			local factions = c and c.factions
			local ordered = {}
			if type(factions) == "table" then
				for key, record in factions do
					local id = record.id or key
					ordered[#ordered + 1] = { id = id, record = record }
				end
			end
			if #ordered == 0 then
				ScreenKit.note(body, "No active factions in the realm.", 2)
				return
			end
			table.sort(ordered, function(a, b)
				return (a.record.clout or 0) > (b.record.clout or 0)
			end)
			for i, entry in ordered do
				local def = registries.Factions and registries.Factions[entry.id]
				local clout = entry.record.clout or 0
				local tier = entry.record.tier or "influential"
				ScreenKit.stat(body, {
					label = def and def.displayName or entry.id,
					value = tier:upper(),
					valueColor = tierColor(tier),
					progress = { value = clout * 100, max = 100, color = "amber" },
					layoutOrder = 1 + i,
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
		policies = function(body, c)
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
			local order = 0
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
	handle = ScreenKit.open(ctx, {
		name = "PoliticsScreen",
		title = "Government",
		subtitle = ((c0 and c0.displayName) or ctx.tag or "Realm") .. "  \u{00B7}  " .. val(govName(c0)),
		size = UDim2.new(0, 512, 1, -132),
		tabs = TABS,
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
