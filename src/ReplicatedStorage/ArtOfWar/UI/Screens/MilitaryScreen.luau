local ScreenKit = require(script.Parent.ScreenKit)

local MilitaryScreen = {}

local TABS = {
	{ key = "army", label = "Army" },
	{ key = "navy", label = "Navy" },
}

local function val(v)
	if v == nil or v == "" then
		return "\u{2014}"
	end
	return tostring(v)
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
	}

	local activeTab = "army"

	local function render(tab)
		handle.clearBody()
		local fn = renderers[tab] or renderers.army
		fn(handle.body)
	end

	local scheduleRefresh = ScreenKit.throttle(function()
		if handle and handle.root and handle.root.Parent then
			render(activeTab)
		end
	end)

	handle = ScreenKit.open(ctx, {
		name = "MilitaryScreen",
		title = "Military",
		subtitle = #ownArmies() .. " regiments",
		tabs = TABS,
		activeTab = activeTab,
		onTab = function(key)
			activeTab = key
			render(key)
		end,
	})
	render(activeTab)

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
