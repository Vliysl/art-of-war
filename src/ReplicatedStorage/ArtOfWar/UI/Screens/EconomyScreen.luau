local ScreenKit = require(script.Parent.ScreenKit)
local Components = script.Parent.Parent.Components
local Button = require(Components.Button)
local Modal = require(Components.Modal)
local SimClock = require(script.Parent.Parent.Parent.Modules.SimClock)
local DistrictTypes = require(script.Parent.Parent.Parent.Data.DistrictTypes)
local WorldConstants = require(script.Parent.Parent.Parent.Shared.WorldConstants)

-- Economy rework: hide district-absorbed + manufactory buildings from the legacy catalog when the district
-- system is on (they are managed as districts in the province grid).
local DISTRICT_ABSORBED = {
	marketplace = true,
	workshop = true,
	granary = true,
	tax_office = true,
	barracks = true,
	stables = true,
	trading_port = true,
}

local EconomyScreen = {}

-- Trade was CUT ahead of the public playtest (undercooked); the Trade tab, its renderer, and the tradeOrders
-- subscription below are removed. TradeOrderSystem still runs server-side but has no client entry point now.
local TABS = {
	{ key = "budget", label = "Budget" },
	{ key = "production", label = "Production" },
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
	local handle
	local registries = ctx.registries

	local function country()
		return ctx.tag and ctx.cache.getCountry(ctx.tag) or nil
	end

	local function renderBudget(body, c)
		local income = c.totalIncome or 0
		local expenses = c.totalExpenses or 0
		-- Under MonthlyEconomy the income/expense providers hold DAILY rates but the treasury only commits
		-- monthly (rate x DaysPerMonth). Show every budget flow as per-month gold so the numbers match what
		-- actually gets banked each month (this is why "Exports" now reads per-month, not per-day).
		local perMonth = (WorldConstants.MonthlyEconomy and (WorldConstants.DaysPerMonth or 30)) or 1
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
			value = money((income - expenses) * perMonth),
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
					value = money(amount * perMonth),
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
					value = money(-math.abs(amount) * perMonth),
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
		local readyConn
		local modal = Modal.create({
			parent = ctx.modalLayer or ctx.parent,
			title = "Build " .. (def.displayName or prettify(buildingId) or buildingId),
			subtitle = string.format("Cost %s \u{00B7} %d days", money(def.cost or 0), def.buildDays or 0),
			width = 420,
			height = 460,
			onClose = function()
				if readyConn then
					pcall(readyConn)
					readyConn = nil
				end
			end,
		})
		table.insert(openModals, modal)
		local content = modal.content
		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Vertical
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 6)
		layout.Parent = content

		-- Provinces stream in chunked/late after join, so a modal opened during streaming can miss the player's own
		-- high-id tiles. Rebuild the eligible-province rows in place (keeping the layout) once the set streams in.
		local function populate()
			for _, child in ipairs(content:GetChildren()) do
				if not child:IsA("UIListLayout") then
					child:Destroy()
				end
			end
			local list = buildableProvinces(buildingId, def)
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

		populate()
		readyConn = ctx.cache.onChange("provincesReady", populate)
	end

	-- Country-wide district totals + "Upgrade All" macros (economy rework), from the replicated
	-- country.districtStats aggregate (computed server-side in DistrictSystem).
	local function renderDistrictTotals(body, c, order)
		local stats = c.districtStats or {}
		local byType = stats.byType or {}
		local levelSum = stats.levelSumByType or {}
		local tax = stats.monthlyTaxByType or {}
		local upgradable = stats.upgradableByType or {}
		ScreenKit.section(body, "Districts", order)
		local o, any = order + 1, false
		for _, dtype in DistrictTypes.order do
			local count = byType[dtype] or 0
			if count > 0 then
				any = true
				local def = DistrictTypes.types[dtype]
				local avg = (levelSum[dtype] or 0) / count
				ScreenKit.stat(body, {
					icon = (def and def.icon) or "Building",
					label = (def and def.displayName) or dtype,
					value = string.format("%d \u{00B7} avg L%.1f \u{00B7} +%.1f/mo", count, avg, tax[dtype] or 0),
					layoutOrder = o,
				})
				o += 1
				local n = upgradable[dtype] or 0
				if n > 0 then
					local row = ScreenKit.buttonRow(body, o)
					Button.create({
						parent = row,
						variant = "secondary",
						text = string.format("Upgrade All (%d)", n),
						onClick = function()
							ctx.fire("UpgradeDistrictAll", dtype)
						end,
					})
					o += 1
				end
			end
		end
		if not any then
			ScreenKit.note(body, "No districts yet \u{2014} build them in your provinces.", order + 1)
		end
	end

	local function renderBuildings(body, c)
		local districtsOn = WorldConstants.DistrictsPlayable
		if districtsOn then
			renderDistrictTotals(body, c, 1)
		end
		ScreenKit.section(body, "Construction", 100)
		local types = registries and registries.BuildingTypes or {}
		local queue = c.buildQueue or {}
		if #queue == 0 then
			ScreenKit.note(body, "Nothing under construction.", 101)
		else
			local order = 101
			for _, item in ipairs(queue) do
				local def = types[item.buildingId]
				local prov = item.provinceId and ctx.cache.getProvince(item.provinceId)
				local pct = 0
				if item.startedAt and item.completesAt and item.completesAt > item.startedAt then
					local now = SimClock.now() or item.startedAt
					pct = math.clamp((now - item.startedAt) / (item.completesAt - item.startedAt), 0, 1)
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
			if not (districtsOn and (DISTRICT_ABSORBED[id] or def.manufactoryId ~= nil)) then
				local cat = def.category or "other"
				groups[cat] = groups[cat] or {}
				table.insert(groups[cat], { id = id, def = def })
			end
		end
		local cats = {}
		for cat in groups do
			cats[#cats + 1] = cat
		end
		table.sort(cats)

		local order = 200
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
		local fn = renderers[tab] or renderBudget
		fn(handle.body, c)
	end

	local activeTab = "budget"
	local lastSig = nil
	local dirty = false

	-- Signature gating: rebuild the body only when something the CURRENT tab visibly renders changes.
	-- The budget tab shows mostly live economic numbers (treasury, income/expense breakdowns, net), so
	-- those are COARSENED into integer buckets and the body steps in visible increments instead of
	-- rebuilding every micro-tick:
	--   treasury        -> floor(treasury / 100)        (£100 steps)
	--   net (inc-exp)   -> floor(net / 10)              (£10 steps)
	--   income lines    -> provider + floor(amount/10)  (sorted; £10 steps)
	--   expense lines   -> provider + floor(amount/10)  (sorted; £10 steps)
	--   economyPolicy   -> exact (drives Current + active button state)
	-- Production tab: per-good stockpile (floor(stock/10)) + net prod-cons (floor(net/10)), sorted by id.
	-- Buildings tab: sorted build-queue ids + completion-progress bucket (5% steps); the catalog is
	--   static (registry) so it is omitted. The buildable-province lists live only inside the modal,
	--   not in the body, so they do not feed the body signature.
	-- Manpower is NOT displayed on any Economy tab, so it is deliberately excluded.
	local function contentSignature(tabKey)
		local c = country()
		local parts = { tabKey }
		if not c then
			parts[#parts + 1] = "noclaim"
			return table.concat(parts, "|")
		end
		if tabKey == "budget" then
			-- Tokens use the SAME formatter (money()) the body displays, so the signature changes exactly
			-- when a shown figure changes (a coarser bucket would freeze the Balance / a breakdown line).
			local income = c.totalIncome or 0
			local expenses = c.totalExpenses or 0
			-- Mirror renderBudget's per-month scaling so the signature changes when a DISPLAYED figure does.
			local perMonth = (WorldConstants.MonthlyEconomy and (WorldConstants.DaysPerMonth or 30)) or 1
			parts[#parts + 1] = "tr:" .. money(c.treasury)
			parts[#parts + 1] = "net:" .. money((income - expenses) * perMonth)
			parts[#parts + 1] = "pol:" .. tostring(c.economyPolicy)
			local inc = {}
			for provider, amount in c.incomeBreakdown or {} do
				if type(amount) == "number" and amount ~= 0 then
					inc[#inc + 1] = tostring(provider) .. "=" .. money(amount * perMonth)
				end
			end
			table.sort(inc)
			parts[#parts + 1] = "inc:" .. table.concat(inc, ",")
			local exp = {}
			for provider, amount in c.expenseBreakdown or {} do
				if type(amount) == "number" and amount ~= 0 then
					exp[#exp + 1] = tostring(provider) .. "=" .. money(-math.abs(amount) * perMonth)
				end
			end
			table.sort(exp)
			parts[#parts + 1] = "exp:" .. table.concat(exp, ",")
		elseif tabKey == "production" then
			-- Mirror renderProduction EXACTLY: same entry set + sort (prod desc, then id) + the displayed
			-- strings (abbreviate(stock), perDay(net)). NOT re-sorted, so a row REORDER also changes the
			-- signature (lexicographic sorting would have hidden a prod-driven order swap).
			local production = c.dailyProduction or {}
			local consumption = c.dailyConsumption or {}
			local stockpiles = c.stockpiles or {}
			local seen, entries = {}, {}
			local function consider(id)
				if seen[id] then
					return
				end
				seen[id] = true
				entries[#entries + 1] =
					{ id = id, prod = production[id] or 0, cons = consumption[id] or 0, stock = stockpiles[id] or 0 }
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
			table.sort(entries, function(a, b)
				if a.prod ~= b.prod then
					return a.prod > b.prod
				end
				return tostring(a.id) < tostring(b.id)
			end)
			local rows = {}
			for _, e in ipairs(entries) do
				local net = e.prod - e.cons
				rows[#rows + 1] = string.format(
					"%s=%s/%s",
					tostring(e.id),
					tostring(abbreviate(e.stock) or "0"),
					tostring(perDay(net) or "")
				)
			end
			parts[#parts + 1] = "prod:" .. table.concat(rows, ",")
		elseif tabKey == "buildings" then
			local now = SimClock.now()
			local queue = {}
			for _, item in ipairs(c.buildQueue or {}) do
				local pct = 0
				if item.startedAt and item.completesAt and item.completesAt > item.startedAt then
					local t = now or item.startedAt
					pct = math.clamp((t - item.startedAt) / (item.completesAt - item.startedAt), 0, 1)
				end
				queue[#queue + 1] =
					string.format("%s:%s:%d", tostring(item.id), tostring(item.provinceId), math.floor(pct * 100 / 5))
			end
			table.sort(queue)
			parts[#parts + 1] = "build:" .. table.concat(queue, ",")
			-- District totals: count / level-sum / upgradable per type, so build+upgrade refresh the section.
			local ds = {}
			local dstats = c.districtStats or {}
			for _, dtype in DistrictTypes.order do
				ds[#ds + 1] = string.format(
					"%s:%d:%d:%d",
					dtype,
					(dstats.byType and dstats.byType[dtype]) or 0,
					(dstats.levelSumByType and dstats.levelSumByType[dtype]) or 0,
					(dstats.upgradableByType and dstats.upgradableByType[dtype]) or 0
				)
			end
			parts[#parts + 1] = "ds:" .. table.concat(ds, ",")
		end
		return table.concat(parts, "|")
	end

	-- Deferred, signature-gated refresh: an open Economy screen rebuilds its body only when the active
	-- tab's coarsened signature changes, so idle/micro-tick economy churn no longer rebuilds every tick.
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
			lastSig = contentSignature(key)
		end,
	})

	table.insert(conns, ctx.cache.onChangePrefix("countries", scheduleRefresh))
	table.insert(conns, ctx.cache.onChangePrefix("provinces", scheduleRefresh))

	render(activeTab)
	lastSig = contentSignature(activeTab)

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
