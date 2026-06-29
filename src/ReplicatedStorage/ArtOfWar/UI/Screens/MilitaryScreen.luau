local ScreenKit = require(script.Parent.ScreenKit)
local Button = require(script.Parent.Parent.Components.Button)

local MilitaryScreen = {}

local TABS = {
	{ key = "army", label = "Army" },
	{ key = "navy", label = "Navy" },
	{ key = "doctrines", label = "Doctrines" },
}

local function val(v)
	if v == nil or v == "" then
		return "\u{2014}"
	end
	return tostring(v)
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

	local renderers = {
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

	local activeTab = "army"
	local lastSig = nil
	local dirty = false

	local function render(tab)
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
		if tabKey == "navy" then
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

	table.insert(conns, ctx.cache.onChangePrefix("armies", scheduleRefresh))
	table.insert(conns, ctx.cache.onChangePrefix("fleets", scheduleRefresh))
	table.insert(conns, ctx.cache.onChangePrefix("countries", scheduleRefresh))

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
