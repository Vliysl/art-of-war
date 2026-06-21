local ScreenKit = require(script.Parent.ScreenKit)
local Components = script.Parent.Parent.Components
local Button = require(Components.Button)
local Modal = require(Components.Modal)

local EconomyScreen = {}

local TABS = {
	{ key = "budget", label = "Budget" },
	{ key = "production", label = "Production" },
	{ key = "trade", label = "Trade" },
	{ key = "buildings", label = "Buildings" },
}

local POLICY_ORDER = { "agrarian", "mercantilism", "laissez_faire", "state_enterprise", "war_economy" }

local CATEGORY_LABELS = {
	economic = "Economic",
	military = "Military",
	cultural = "Cultural",
	industry = "Industry",
}

local function prettify(id)
	if type(id) ~= "string" or id == "" then
		return nil
	end
	local out = {}
	for word in id:gmatch("[^_%s]+") do
		out[#out + 1] = word:sub(1, 1):upper() .. word:sub(2)
	end
	return table.concat(out, " ")
end

local function abbreviate(n)
	if type(n) ~= "number" then
		return nil
	end
	local sign = n < 0 and "-" or ""
	local a = math.abs(n)
	if a >= 1e9 then
		return string.format("%s%.2fB", sign, a / 1e9)
	elseif a >= 1e6 then
		return string.format("%s%.2fM", sign, a / 1e6)
	elseif a >= 1e3 then
		return string.format("%s%.1fK", sign, a / 1e3)
	end
	return string.format("%s%d", sign, math.floor(a + 0.5))
end

local function money(n)
	local a = abbreviate(n)
	return a and ("\u{00A3}" .. a) or "\u{2014}"
end

local function perDay(n)
	if type(n) ~= "number" or n == 0 then
		return nil
	end
	return string.format("%s%.1f/day", n > 0 and "+" or "", n)
end

local function goodName(registries, id)
	local goods = registries and registries.TradeGoods
	local def = goods and goods[id]
	return (def and def.displayName) or prettify(id) or tostring(id)
end

local function provinceName(prov)
	return prov.displayCityName or prov.name or ("Province #" .. tostring(prov.id))
end

function EconomyScreen.create(ctx)
	local conns = {}
	local openModals = {}
	local dirty = false
	local handle
	local registries = ctx.registries

	local function country()
		return ctx.tag and ctx.cache.getCountry(ctx.tag) or nil
	end

	local function renderBudget(body, c)
		local income = c.totalIncome or 0
		local expenses = c.totalExpenses or 0
		ScreenKit.section(body, "Treasury", 1)
		ScreenKit.stat(body, {
			icon = "Treasury",
			label = "Balance",
			value = money(c.treasury),
			valueColor = "positive",
			layoutOrder = 2,
		})
		ScreenKit.stat(body, {
			icon = "Trade",
			label = "Monthly Net",
			value = money(income - expenses),
			valueColor = (income - expenses) < 0 and "negative" or "positive",
			layoutOrder = 3,
		})

		ScreenKit.section(body, "Income", 10)
		local incomeBreakdown = c.incomeBreakdown or {}
		local hasIncome = false
		local order = 11
		for provider, amount in incomeBreakdown do
			if type(amount) == "number" and amount ~= 0 then
				hasIncome = true
				ScreenKit.stat(body, {
					label = prettify(provider) or tostring(provider),
					value = money(amount),
					valueColor = "positive",
					layoutOrder = order,
				})
				order += 1
			end
		end
		if not hasIncome then
			ScreenKit.note(body, "No recorded income sources.", 11)
		end

		ScreenKit.section(body, "Expenses", 30)
		local expenseBreakdown = c.expenseBreakdown or {}
		local hasExpense = false
		order = 31
		for provider, amount in expenseBreakdown do
			if type(amount) == "number" and amount ~= 0 then
				hasExpense = true
				ScreenKit.stat(body, {
					label = prettify(provider) or tostring(provider),
					value = money(-math.abs(amount)),
					valueColor = "negative",
					layoutOrder = order,
				})
				order += 1
			end
		end
		if not hasExpense then
			ScreenKit.note(body, "No recorded expenses.", 31)
		end

		ScreenKit.section(body, "Policy", 50)
		local policies = registries and registries.EconomyPolicies or {}
		local current = policies[c.economyPolicy]
		ScreenKit.stat(body, {
			icon = "Economy",
			label = "Current",
			value = (current and current.displayName) or prettify(c.economyPolicy) or "\u{2014}",
			layoutOrder = 51,
		})
		local order2 = 52
		for _, id in ipairs(POLICY_ORDER) do
			local def = policies[id]
			if def then
				local active = id == c.economyPolicy
				local row = ScreenKit.buttonRow(body, order2)
				Button.create({
					parent = row,
					variant = active and "primary" or "secondary",
					text = def.displayName,
					disabled = active,
					onClick = function()
						ctx.fire("SetEconomyPolicy", id)
					end,
				})
				order2 += 1
			end
		end
	end

	local function renderProduction(body, c)
		local production = c.dailyProduction or {}
		local consumption = c.dailyConsumption or {}
		local stockpiles = c.stockpiles or {}
		local seen, entries = {}, {}
		local function consider(id)
			if seen[id] then
				return
			end
			seen[id] = true
			entries[#entries + 1] = {
				id = id,
				prod = production[id] or 0,
				cons = consumption[id] or 0,
				stock = stockpiles[id] or 0,
			}
		end
		for id in production do
			consider(id)
		end
		for id in consumption do
			consider(id)
		end
		for id in stockpiles do
			consider(id)
		end

		if #entries == 0 then
			ScreenKit.note(body, "No resource activity yet. Develop a province or wait for the first day.", 1)
			return
		end

		table.sort(entries, function(a, b)
			if a.prod ~= b.prod then
				return a.prod > b.prod
			end
			return tostring(a.id) < tostring(b.id)
		end)

		ScreenKit.section(body, "Stockpiles", 1)
		for i, e in ipairs(entries) do
			local net = e.prod - e.cons
			ScreenKit.stat(body, {
				icon = "Goods",
				label = goodName(registries, e.id),
				value = abbreviate(e.stock) or "0",
				delta = perDay(net),
				deltaNum = net,
				layoutOrder = 1 + i,
			})
		end
	end

	local function renderTrade(body)
		local mine = ctx.tag
		local incoming, outgoing = {}, {}
		for id, route in ctx.cache.allTrades() do
			route.id = route.id or id
			if route.toTag == mine then
				incoming[#incoming + 1] = route
			elseif route.fromTag == mine then
				outgoing[#outgoing + 1] = route
			end
		end
		table.sort(incoming, function(a, b)
			return (a.id or 0) < (b.id or 0)
		end)
		table.sort(outgoing, function(a, b)
			return (a.id or 0) < (b.id or 0)
		end)

		if #incoming == 0 and #outgoing == 0 then
			ScreenKit.note(body, "No trade routes. Propose a deal from another nation's panel.", 1)
			return
		end

		local function offerText(offer)
			if type(offer) ~= "table" then
				return "\u{2014}"
			end
			return string.format("%s \u{00D7} %s", abbreviate(offer.amount) or "0", goodName(registries, offer.goodId))
		end

		if #incoming > 0 then
			ScreenKit.section(body, "Incoming", 1)
			local order = 2
			for _, route in ipairs(incoming) do
				local fromC = ctx.cache.getCountry(route.fromTag)
				ScreenKit.stat(body, {
					icon = "Trade",
					label = (fromC and fromC.displayName) or route.fromTag or "\u{2014}",
					value = route.state or "\u{2014}",
					layoutOrder = order,
				})
				ScreenKit.stat(body, { label = "They offer", value = offerText(route.offer), layoutOrder = order + 1 })
				ScreenKit.stat(
					body,
					{ label = "They request", value = offerText(route.request), layoutOrder = order + 2 }
				)
				if route.state == "Proposed" then
					local row = ScreenKit.buttonRow(body, order + 3)
					Button.create({
						parent = row,
						variant = "primary",
						text = "Accept",
						onClick = function()
							ctx.fire("AcceptTrade", route.id)
						end,
					})
					Button.create({
						parent = row,
						variant = "ghost",
						text = "Reject",
						onClick = function()
							ctx.fire("CancelTrade", route.id)
						end,
					})
				end
				order += 5
			end
		end

		if #outgoing > 0 then
			ScreenKit.section(body, "Outgoing", 30)
			local order = 31
			for _, route in ipairs(outgoing) do
				local toC = ctx.cache.getCountry(route.toTag)
				ScreenKit.stat(body, {
					icon = "Trade",
					label = (toC and toC.displayName) or route.toTag or "\u{2014}",
					value = route.state or "\u{2014}",
					layoutOrder = order,
				})
				ScreenKit.stat(body, { label = "You offer", value = offerText(route.offer), layoutOrder = order + 1 })
				ScreenKit.stat(
					body,
					{ label = "You request", value = offerText(route.request), layoutOrder = order + 2 }
				)
				local row = ScreenKit.buttonRow(body, order + 3)
				Button.create({
					parent = row,
					variant = "ghost",
					text = "Cancel",
					onClick = function()
						ctx.fire("CancelTrade", route.id)
					end,
				})
				order += 5
			end
		end
	end

	local function buildableProvinces(buildingId, def)
		local out = {}
		for id, prov in ctx.cache.allProvinces() do
			prov.id = prov.id or id
			if prov.ownerTag == ctx.tag and prov.controllerTag == ctx.tag then
				local buildings = prov.buildings or {}
				local has = false
				local prereqOk = true
				for _, b in ipairs(buildings) do
					if b == buildingId then
						has = true
					end
				end
				if def.requires then
					for _, req in ipairs(def.requires) do
						local found = false
						for _, b in ipairs(buildings) do
							if b == req then
								found = true
								break
							end
						end
						if not found then
							prereqOk = false
							break
						end
					end
				end
				local infraOk = (prov.infraTier or 0) >= (def.infraRequirement or 0)
				local coastalOk = (not def.requiresCoastal) or prov.coastal == true
				if infraOk and coastalOk and prereqOk and (def.repeatable or not has) then
					out[#out + 1] = prov
				end
			end
		end
		table.sort(out, function(a, b)
			return provinceName(a) < provinceName(b)
		end)
		return out
	end

	local function openBuildModal(buildingId, def)
		local list = buildableProvinces(buildingId, def)
		local modal = Modal.create({
			parent = ctx.modalLayer or ctx.parent,
			title = "Build " .. (def.displayName or prettify(buildingId) or buildingId),
			subtitle = string.format("Cost %s \u{00B7} %d days", money(def.cost or 0), def.buildDays or 0),
			width = 420,
			height = 460,
		})
		table.insert(openModals, modal)
		local content = modal.content
		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Vertical
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 6)
		layout.Parent = content

		if #list == 0 then
			ScreenKit.note(content, "No eligible provinces. Check infrastructure, coast, or prerequisites.", 1)
			return
		end
		for i, prov in ipairs(list) do
			local row = ScreenKit.buttonRow(content, i)
			Button.create({
				parent = row,
				variant = "secondary",
				text = provinceName(prov),
				onClick = function()
					ctx.fire("BuildBuilding", prov.id, buildingId)
					modal.close()
				end,
			})
		end
	end

	local function renderBuildings(body, c)
		ScreenKit.section(body, "Construction", 1)
		local types = registries and registries.BuildingTypes or {}
		local queue = c.buildQueue or {}
		if #queue == 0 then
			ScreenKit.note(body, "Nothing under construction.", 2)
		else
			local order = 2
			for _, item in ipairs(queue) do
				local def = types[item.buildingId]
				local prov = item.provinceId and ctx.cache.getProvince(item.provinceId)
				local pct = 0
				if item.startedAt and item.completesAt and item.completesAt > item.startedAt then
					pct = math.clamp((os.clock() - item.startedAt) / (item.completesAt - item.startedAt), 0, 1)
				end
				ScreenKit.stat(body, {
					icon = "Building",
					label = (def and def.displayName) or prettify(item.buildingId) or item.buildingId,
					value = prov and provinceName(prov) or "\u{2014}",
					progress = { value = pct * 100, max = 100, color = "amber" },
					layoutOrder = order,
				})
				local row = ScreenKit.buttonRow(body, order + 1)
				Button.create({
					parent = row,
					variant = "ghost",
					text = "Cancel",
					onClick = function()
						ctx.fire("CancelBuilding", item.id)
					end,
				})
				order += 2
			end
		end

		local groups = {}
		for id, def in types do
			local cat = def.category or "other"
			groups[cat] = groups[cat] or {}
			table.insert(groups[cat], { id = id, def = def })
		end
		local cats = {}
		for cat in groups do
			cats[#cats + 1] = cat
		end
		table.sort(cats)

		local order = 30
		for _, cat in ipairs(cats) do
			ScreenKit.section(body, CATEGORY_LABELS[cat] or prettify(cat) or cat, order)
			order += 1
			local items = groups[cat]
			table.sort(items, function(a, b)
				return (a.def.displayName or a.id) < (b.def.displayName or b.id)
			end)
			for _, entry in ipairs(items) do
				local def = entry.def
				ScreenKit.stat(body, {
					icon = "Building",
					label = def.displayName or prettify(entry.id) or entry.id,
					value = string.format("%s \u{00B7} %dd", money(def.cost or 0), def.buildDays or 0),
					mono = true,
					layoutOrder = order,
				})
				local row = ScreenKit.buttonRow(body, order + 1)
				Button.create({
					parent = row,
					variant = "secondary",
					text = "Build",
					onClick = function()
						openBuildModal(entry.id, def)
					end,
				})
				order += 2
			end
		end
	end

	local renderers = {
		budget = renderBudget,
		production = renderProduction,
		buildings = renderBuildings,
	}

	local function render(tab)
		handle.clearBody()
		local c = country()
		if not c then
			ScreenKit.note(handle.body, "No realm claimed.", 1)
			return
		end
		if tab == "trade" then
			renderTrade(handle.body)
			return
		end
		local fn = renderers[tab] or renderBudget
		fn(handle.body, c)
	end

	local activeTab = "budget"
	local function scheduleRefresh()
		if dirty then
			return
		end
		dirty = true
		task.defer(function()
			dirty = false
			if handle and handle.root and handle.root.Parent then
				render(activeTab)
			end
		end)
	end

	local c = country()
	handle = ScreenKit.open(ctx, {
		name = "EconomyScreen",
		title = "Economy",
		subtitle = (c and c.displayName or ctx.tag or "Realm") .. "  \u{00B7}  Treasury " .. money(c and c.treasury),
		tabs = TABS,
		activeTab = activeTab,
		onTab = function(key)
			activeTab = key
			render(key)
		end,
	})

	table.insert(conns, ctx.cache.onChangePrefix("countries", scheduleRefresh))
	table.insert(conns, ctx.cache.onChangePrefix("tradeRoutes", scheduleRefresh))
	table.insert(conns, ctx.cache.onChangePrefix("provinces", scheduleRefresh))

	render(activeTab)

	return {
		root = handle.root,
		destroy = function()
			for _, d in conns do
				pcall(d)
			end
			for _, m in openModals do
				if m and m.root and m.root.Parent then
					m.close()
				end
			end
			if handle then
				handle.destroy()
			end
		end,
	}
end

return EconomyScreen
