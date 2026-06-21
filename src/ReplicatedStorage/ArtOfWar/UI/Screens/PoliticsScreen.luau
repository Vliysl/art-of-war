local ScreenKit = require(script.Parent.ScreenKit)
local Components = script.Parent.Parent.Components
local Button = require(Components.Button)
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

			ScreenKit.section(body, "Available Transitions", 4)
			local gov = registries.GovernmentTypes and c and registries.GovernmentTypes[c.governmentForm]
			local transitions = gov and gov.transitions
			if transitions and next(transitions) then
				local ordered = {}
				for id, def in transitions do
					local target = registries.GovernmentTypes and registries.GovernmentTypes[id]
					ordered[#ordered + 1] = {
						label = target and target.displayName or id,
						cost = def.ppCost or 0,
					}
				end
				table.sort(ordered, function(a, b)
					return a.label < b.label
				end)
				for i, entry in ordered do
					ScreenKit.stat(body, {
						label = entry.label,
						value = entry.cost .. " PP",
						mono = true,
						layoutOrder = 4 + i,
					})
				end
			else
				ScreenKit.note(body, "No government transitions are available.", 5)
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

	local scheduleRefresh = ScreenKit.throttle(function()
		if handle and handle.root and handle.root.Parent then
			render(currentTab)
		end
	end)

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
		end,
	})

	if ctx.cache then
		table.insert(conns, ctx.cache.onChangePrefix("countries", scheduleRefresh))
	end

	render("overview")

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
