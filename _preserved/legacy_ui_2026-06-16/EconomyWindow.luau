local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local uiFolder = aow:WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))
local UIRoot = require(uiFolder:WaitForChild("UIRoot"))
local MovableWindow = require(uiFolder:WaitForChild("MovableWindow"))

local EconomyWindow = {}

local TAB_DEFS = {
	{ key = "Overview",   label = "Overview" },
	{ key = "Production", label = "Resource Production" },
	{ key = "Trade",      label = "Trade", subtitle = "Trade routes, tariffs, and embargoes coming soon." },
}

local TAB_STRIP_H = 32

-- Display labels for the income/expense provider IDs the EconomySystem registers.
-- New providers added later auto-show with a humanised label via fallback.
local PROVIDER_LABELS = {
	tax_income = "Tax Income",
	exports = "Exports",
	manufactory_sales = "Manufactory Sales",
	army_upkeep = "Army Upkeep",
	government_spending = "Government Spending",
	imports = "Imports",
	building_maintenance = "Building Maintenance",
	leader_salary = "Leader Salary",
}

local STAT_DEFS = {
	{ key = "treasury",   icon = "Treasury",   label = "Treasury" },
	{ key = "manpower",   icon = "Manpower",   label = "Manpower" },
	{ key = "pp",         icon = "PowerProj",  label = "Political Power" },
	{ key = "stability",  icon = "Stability",  label = "Stability" },
	{ key = "legitimacy", icon = "Legitimacy", label = "Legitimacy" },
}

local function titleCase(text)
	if not text or text == "" then return "" end
	local out = (text:gsub("_", " "))
	out = (out:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b:lower() end))
	return out
end

local function labelFor(id)
	return PROVIDER_LABELS[id] or titleCase(id)
end

local function formatNumber(n)
	n = n or 0
	if math.abs(n) >= 1e6 then return string.format("%.1fM", n / 1e6) end
	if math.abs(n) >= 1e4 then return string.format("%.1fk", n / 1e3) end
	return string.format("%d", math.floor(n + 0.5))
end

local function formatSigned(n)
	if not n or n == 0 then return "0" end
	local sign = n > 0 and "+" or ""
	return sign .. formatNumber(n)
end

local function formatPerDay(n)
	if not n then return "—" end
	if math.abs(n) >= 100 then
		return string.format("%s%d / day", n > 0 and "+" or "", math.floor(n + 0.5))
	end
	return string.format("%s%.1f / day", n > 0 and "+" or "", n)
end

local function makeRealmStat(parent, def, layoutOrder)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 26)
	row.BackgroundColor3 = UIStyle.Color.PanelAlt
	row.BorderSizePixel = 0
	row.LayoutOrder = layoutOrder
	row.Parent = parent
	UIBuilder.corner(row, 2)
	UIBuilder.icon(row, def.icon, 14, { Position = UDim2.fromOffset(8, 6) })
	UIBuilder.label(row, def.label, UIStyle.Type.StatLabel, UIStyle.Color.TextMuted, {
		Size = UDim2.new(0.55, -28, 1, 0), Position = UDim2.fromOffset(28, 0),
		TextYAlignment = Enum.TextYAlignment.Center, TextSize = 11,
	})
	local val = UIBuilder.label(row, "—", UIStyle.Type.StatValue, UIStyle.Color.Text, {
		Size = UDim2.new(0.45, -8, 1, 0),
		Position = UDim2.new(1, -8, 0, 0),
		AnchorPoint = Vector2.new(1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextSize = 13,
	})
	return val
end

local function makeBudgetColumn(parent, title, isExpense, layoutOrder)
	local panel = Instance.new("Frame")
	panel.Size = UDim2.new(0.5, -6, 1, 0)
	panel.BackgroundColor3 = UIStyle.Color.PanelAlt
	panel.BorderSizePixel = 0
	panel.LayoutOrder = layoutOrder
	panel.Parent = parent
	UIBuilder.corner(panel, 2)
	UIBuilder.stroke(panel, 1, UIStyle.Color.Border)

	local heading = UIBuilder.label(panel, title, UIStyle.Type.SectionHeader,
		isExpense and UIStyle.Color.Bad or UIStyle.Color.Good, {
			Size = UDim2.new(1, -16, 0, 22),
			Position = UDim2.fromOffset(8, 6),
			TextSize = 13,
			Font = UIStyle.Font.Bold,
		})

	local body = Instance.new("ScrollingFrame")
	body.Size = UDim2.new(1, -8, 1, -64)
	body.Position = UDim2.fromOffset(4, 30)
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.ScrollBarThickness = 4
	body.CanvasSize = UDim2.new(0, 0, 0, 0)
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 2)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = body
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 4); pad.PaddingRight = UDim.new(0, 4)
	pad.Parent = body

	-- Total row anchored at bottom
	local totalBar = Instance.new("Frame")
	totalBar.Size = UDim2.new(1, 0, 0, 30)
	totalBar.Position = UDim2.new(0, 0, 1, -30)
	totalBar.BackgroundColor3 = UIStyle.Color.Bg
	totalBar.BorderSizePixel = 0
	totalBar.Parent = panel
	UIBuilder.label(totalBar, "Total", UIStyle.Type.StatLabel, UIStyle.Color.TextMuted, {
		Size = UDim2.new(0.5, 0, 1, 0), Position = UDim2.fromOffset(12, 0),
		TextYAlignment = Enum.TextYAlignment.Center, TextSize = 11, Font = UIStyle.Font.Semibold,
	})
	local totalVal = UIBuilder.label(totalBar, "0.0 / day", UIStyle.Type.StatValue,
		isExpense and UIStyle.Color.Bad or UIStyle.Color.Good, {
			Size = UDim2.new(0.5, -12, 1, 0),
			Position = UDim2.new(1, -12, 0, 0),
			AnchorPoint = Vector2.new(1, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextYAlignment = Enum.TextYAlignment.Center,
			TextSize = 14, Font = UIStyle.Font.Bold,
		})

	local function clearBody()
		for _, c in body:GetChildren() do
			if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
		end
	end

	local function setRows(orderedIds, breakdown)
		clearBody()
		local total = 0
		for i, id in ipairs(orderedIds) do
			local amount = breakdown[id] or 0
			total += amount
			local row = Instance.new("Frame")
			row.Size = UDim2.new(1, 0, 0, 22)
			row.BackgroundTransparency = 1
			row.LayoutOrder = i
			row.Parent = body
			UIBuilder.label(row, labelFor(id), UIStyle.Type.StatLabel, UIStyle.Color.Text, {
				Size = UDim2.new(0.6, 0, 1, 0), Position = UDim2.fromOffset(0, 0),
				TextYAlignment = Enum.TextYAlignment.Center, TextSize = 12,
			})
			UIBuilder.label(row, string.format("%.1f", amount), UIStyle.Type.StatValue,
				amount == 0 and UIStyle.Color.TextMuted or
				(isExpense and UIStyle.Color.Bad or UIStyle.Color.Good), {
					Size = UDim2.new(0.4, 0, 1, 0),
					Position = UDim2.new(1, 0, 0, 0),
					AnchorPoint = Vector2.new(1, 0),
					TextXAlignment = Enum.TextXAlignment.Right,
					TextYAlignment = Enum.TextYAlignment.Center,
					TextSize = 12,
				})
		end
		totalVal.Text = string.format("%.1f / day", total)
		return total
	end

	return { setRows = setRows }
end

local function buildOverviewTab(page)
	local body, layout = UIBuilder.scrollingList(page, {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	})
	UIBuilder.padding(body, 12)
	if layout then layout.Padding = UDim.new(0, 8) end

	-- REALM section: 5 stats moved from TopBar
	UIBuilder.label(body, "Realm", UIStyle.Type.SectionHeader, UIStyle.Color.Gold, {
		Size = UDim2.new(1, 0, 0, 20), LayoutOrder = 1, TextSize = 13,
	})
	local realmGrid = Instance.new("Frame")
	realmGrid.Size = UDim2.new(1, 0, 0, 0)
	realmGrid.AutomaticSize = Enum.AutomaticSize.Y
	realmGrid.BackgroundTransparency = 1
	realmGrid.LayoutOrder = 2
	realmGrid.Parent = body
	local realmLayout = Instance.new("UIListLayout")
	realmLayout.FillDirection = Enum.FillDirection.Vertical
	realmLayout.Padding = UDim.new(0, 2)
	realmLayout.SortOrder = Enum.SortOrder.LayoutOrder
	realmLayout.Parent = realmGrid

	local realmRefs = {}
	for i, def in ipairs(STAT_DEFS) do
		realmRefs[def.key] = makeRealmStat(realmGrid, def, i)
	end

	-- BUDGET section header
	UIBuilder.label(body, "Budget", UIStyle.Type.SectionHeader, UIStyle.Color.Gold, {
		Size = UDim2.new(1, 0, 0, 20), LayoutOrder = 3, TextSize = 13,
	})

	-- Two-column container
	local columns = Instance.new("Frame")
	columns.Size = UDim2.new(1, 0, 0, 240)
	columns.BackgroundTransparency = 1
	columns.LayoutOrder = 4
	columns.Parent = body
	local colLayout = Instance.new("UIListLayout")
	colLayout.FillDirection = Enum.FillDirection.Horizontal
	colLayout.Padding = UDim.new(0, 12)
	colLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	colLayout.SortOrder = Enum.SortOrder.LayoutOrder
	colLayout.Parent = columns

	local incomeCol = makeBudgetColumn(columns, "Income", false, 1)
	local expenseCol = makeBudgetColumn(columns, "Expenses", true, 2)

	-- NET TOTAL bar
	local netBar = Instance.new("Frame")
	netBar.Size = UDim2.new(1, 0, 0, 36)
	netBar.BackgroundColor3 = UIStyle.Color.Bg
	netBar.BorderSizePixel = 0
	netBar.LayoutOrder = 5
	netBar.Parent = body
	UIBuilder.corner(netBar, 2)
	UIBuilder.stroke(netBar, 1, UIStyle.Color.BorderStrong)
	UIBuilder.label(netBar, "Net Balance", UIStyle.Type.StatLabel, UIStyle.Color.TextMuted, {
		Size = UDim2.new(0.5, 0, 1, 0), Position = UDim2.fromOffset(12, 0),
		TextYAlignment = Enum.TextYAlignment.Center, TextSize = 12, Font = UIStyle.Font.Semibold,
	})
	local netVal = UIBuilder.label(netBar, "0.0 / day", UIStyle.Type.StatValue, UIStyle.Color.Text, {
		Size = UDim2.new(0.5, -12, 1, 0),
		Position = UDim2.new(1, -12, 0, 0),
		AnchorPoint = Vector2.new(1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextSize = 16, Font = UIStyle.Font.Bold,
	})

	UIBuilder.captionDivider(body, "Ledger", {
		Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 6,
	})

	return {
		update = function(country, providersMaybe)
			-- Realm stats
			realmRefs.treasury.Text = formatNumber(country and country.treasury or 0)
			realmRefs.manpower.Text = (country and country.levyManpower ~= nil) and string.format("Levy %s · Pro %s", formatNumber(country.levyManpower or 0), formatNumber(country.manpower or 0)) or formatNumber(country and country.manpower or 0)
			realmRefs.pp.Text = formatNumber(country and country.politicalPower or 0)
			realmRefs.stability.Text = string.format("%+d", math.floor((country and country.stability or 0) + 0.5))
			realmRefs.stability.TextColor3 = UIStyle.stateColor and UIStyle.stateColor(country and country.stability or 0) or UIStyle.Color.Text
			realmRefs.legitimacy.Text = string.format("%d", math.floor((country and country.legitimacy or 0) + 0.5))

			-- Budget rows. Use the registered provider order if available.
			local providers = providersMaybe or { income = { "tax_income", "exports" },
				expense = { "army_upkeep", "government_spending", "imports" } }
			local incomeBreakdown = (country and country.incomeBreakdown) or {}
			local expenseBreakdown = (country and country.expenseBreakdown) or {}
			local totalIncome = incomeCol.setRows(providers.income, incomeBreakdown)
			local totalExpenses = expenseCol.setRows(providers.expense, expenseBreakdown)

			local net = totalIncome - totalExpenses
			netVal.Text = formatPerDay(net)
			netVal.TextColor3 = UIStyle.stateColor and UIStyle.stateColor(net) or UIStyle.Color.Text
		end,
	}
end

local function buildProductionTab(page, getBundle)
	local container = Instance.new("Frame")
	container.Size = UDim2.fromScale(1, 1)
	container.BackgroundTransparency = 1
	container.Parent = page

	local header = Instance.new("Frame")
	header.Size = UDim2.new(1, -16, 0, 22)
	header.Position = UDim2.fromOffset(8, 8)
	header.BackgroundColor3 = UIStyle.Color.Bg
	header.BorderSizePixel = 0
	header.Parent = container
	UIBuilder.corner(header, 2)
	UIBuilder.label(header, "Resource", UIStyle.Type.StatLabel, UIStyle.Color.TextMuted, {
		Size = UDim2.new(0.4, -8, 1, 0), Position = UDim2.fromOffset(8, 0),
		TextYAlignment = Enum.TextYAlignment.Center, TextSize = 11,
	})
	UIBuilder.label(header, "Daily Production", UIStyle.Type.StatLabel, UIStyle.Color.TextMuted, {
		Size = UDim2.new(0.25, 0, 1, 0), Position = UDim2.new(0.4, 0, 0, 0),
		TextXAlignment = Enum.TextXAlignment.Right, TextYAlignment = Enum.TextYAlignment.Center, TextSize = 11,
	})
	UIBuilder.label(header, "Daily Use", UIStyle.Type.StatLabel, UIStyle.Color.TextMuted, {
		Size = UDim2.new(0.18, 0, 1, 0), Position = UDim2.new(0.65, 0, 0, 0),
		TextXAlignment = Enum.TextXAlignment.Right, TextYAlignment = Enum.TextYAlignment.Center, TextSize = 11,
	})
	UIBuilder.label(header, "Stockpile", UIStyle.Type.StatLabel, UIStyle.Color.TextMuted, {
		Size = UDim2.new(0.17, -8, 1, 0), Position = UDim2.new(0.83, 0, 0, 0),
		TextXAlignment = Enum.TextXAlignment.Right, TextYAlignment = Enum.TextYAlignment.Center, TextSize = 11,
	})

	local listFrame = Instance.new("Frame")
	listFrame.Size = UDim2.new(1, 0, 1, -38)
	listFrame.Position = UDim2.fromOffset(0, 38)
	listFrame.BackgroundTransparency = 1
	listFrame.Parent = container

	local body, layout = UIBuilder.scrollingList(listFrame, { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 })
	UIBuilder.padding(body, 8)
	if layout then layout.Padding = UDim.new(0, 4) end

	local emptyLabel

	local function clearRows()
		for _, child in body:GetChildren() do
			if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then child:Destroy() end
		end
	end

	local function addRow(displayName, daily, consumed, stockpile, layoutOrder)
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 24)
		row.BackgroundColor3 = UIStyle.Color.PanelAlt
		row.BorderSizePixel = 0
		row.LayoutOrder = layoutOrder
		row.Parent = body
		UIBuilder.corner(row, 2)
		UIBuilder.icon(row, "Trade", 12, { Position = UDim2.fromOffset(6, 6) })
		UIBuilder.label(row, displayName, UIStyle.Type.StatValue, UIStyle.Color.Text, {
			Size = UDim2.new(0.4, -28, 1, 0), Position = UDim2.fromOffset(24, 0),
			TextYAlignment = Enum.TextYAlignment.Center, TextSize = 12,
		})
		local netDaily = (daily or 0) - (consumed or 0)
		UIBuilder.label(row, string.format("%+.1f", daily or 0), UIStyle.Type.StatValue,
			(daily or 0) > 0 and UIStyle.Color.Good or UIStyle.Color.TextMuted, {
				Size = UDim2.new(0.25, 0, 1, 0), Position = UDim2.new(0.4, 0, 0, 0),
				TextXAlignment = Enum.TextXAlignment.Right, TextYAlignment = Enum.TextYAlignment.Center, TextSize = 12,
			})
		UIBuilder.label(row, (consumed or 0) > 0 and string.format("-%.1f", consumed) or "—",
			UIStyle.Type.StatValue,
			(consumed or 0) > 0 and UIStyle.Color.Bad or UIStyle.Color.TextMuted, {
				Size = UDim2.new(0.18, 0, 1, 0), Position = UDim2.new(0.65, 0, 0, 0),
				TextXAlignment = Enum.TextXAlignment.Right, TextYAlignment = Enum.TextYAlignment.Center, TextSize = 12,
			})
		UIBuilder.label(row, formatNumber(stockpile or 0), UIStyle.Type.StatValue, UIStyle.Color.Text, {
			Size = UDim2.new(0.17, -8, 1, 0), Position = UDim2.new(0.83, 0, 0, 0),
			TextXAlignment = Enum.TextXAlignment.Right, TextYAlignment = Enum.TextYAlignment.Center, TextSize = 12,
		})
	end

	return {
		update = function(country)
			clearRows()
			if not country then return end
			local stockpiles = country.stockpiles or {}
			local production = country.dailyProduction or {}
			local consumption = country.dailyConsumption or {}
			local bundle = getBundle and getBundle()
			local goods = bundle and bundle.tradeGoods or {}

			local seen, entries = {}, {}
			for goodId, amount in production do
				if amount and amount > 0 then
					seen[goodId] = true
					table.insert(entries, { id = goodId, daily = amount,
						consumed = consumption[goodId] or 0, stockpile = stockpiles[goodId] or 0 })
				end
			end
			for goodId, amount in consumption do
				if not seen[goodId] and amount and amount > 0 then
					seen[goodId] = true
					table.insert(entries, { id = goodId, daily = production[goodId] or 0,
						consumed = amount, stockpile = stockpiles[goodId] or 0 })
				end
			end
			for goodId, amount in stockpiles do
				if not seen[goodId] and amount and amount > 0 then
					table.insert(entries, { id = goodId, daily = 0,
						consumed = consumption[goodId] or 0, stockpile = amount })
				end
			end

			if #entries == 0 then
				if not emptyLabel then
					emptyLabel = UIBuilder.label(body, "No resource activity yet. Develop a province or wait for the first day.",
						UIStyle.Type.Small, UIStyle.Color.TextMuted, {
							Size = UDim2.new(1, -16, 0, 32), TextWrapped = true, LayoutOrder = 1,
						})
				else
					emptyLabel.Parent = body
				end
				return
			end
			if emptyLabel then emptyLabel.Parent = nil end
			table.sort(entries, function(a, b)
				if a.daily ~= b.daily then return a.daily > b.daily end
				return tostring(a.id) < tostring(b.id)
			end)
			for i, e in ipairs(entries) do
				local def = goods[e.id]
				addRow(def and def.displayName or titleCase(e.id), e.daily, e.consumed, e.stockpile, i)
			end
		end,
	}
end

function EconomyWindow.create(opts)
	opts = opts or {}
	local getBundle = opts.getBundle
	local getProviderOrder = opts.getProviderOrder

	local win = MovableWindow.create({ id = "economy", title = "Economy", size = UDim2.fromOffset(600, 540) })

	local tabStrip = Instance.new("Frame")
	tabStrip.Size = UDim2.new(1, 0, 0, TAB_STRIP_H)
	tabStrip.BackgroundColor3 = UIStyle.Color.Bg
	tabStrip.BorderSizePixel = 0
	tabStrip.Parent = win.body
	local tabRow = Instance.new("Frame")
	tabRow.Size = UDim2.fromScale(1, 1)
	tabRow.BackgroundTransparency = 1
	tabRow.Parent = tabStrip
	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.Parent = tabRow

	local underline = Instance.new("Frame")
	underline.Size = UDim2.fromOffset(0, 2)
	underline.Position = UDim2.new(0, 0, 1, -2)
	underline.BackgroundColor3 = UIStyle.Color.Gold
	underline.BorderSizePixel = 0
	underline.Parent = tabStrip

	local content = Instance.new("Frame")
	content.Size = UDim2.new(1, 0, 1, -TAB_STRIP_H)
	content.Position = UDim2.fromOffset(0, TAB_STRIP_H)
	content.BackgroundTransparency = 1
	content.ClipsDescendants = true
	content.Parent = win.body

	local tabs, tabImpls = {}, {}
	local function setActive(key)
		for k, data in tabs do
			local isActive = k == key
			data.page.Visible = isActive
			data.label.TextColor3 = isActive and UIStyle.Color.Gold or UIStyle.Color.TextMuted
			if isActive then
				local s = UIRoot.uiScale()
				local px = (data.button.AbsolutePosition.X - tabRow.AbsolutePosition.X) / s
				local sx = data.button.AbsoluteSize.X / s
				if not UIStyle.ReduceMotion then
					TweenService:Create(underline, UIStyle.tween(UIStyle.Motion.Fast), {
						Position = UDim2.new(0, px, 1, -2),
						Size = UDim2.fromOffset(sx, 2),
					}):Play()
				else
					underline.Position = UDim2.new(0, px, 1, -2)
					underline.Size = UDim2.fromOffset(sx, 2)
				end
			end
		end
	end

	for i, def in ipairs(TAB_DEFS) do
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1 / #TAB_DEFS, 0, 1, 0)
		btn.BackgroundTransparency = 1
		btn.AutoButtonColor = false
		btn.Text = ""
		btn.LayoutOrder = i
		btn.Parent = tabRow
		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.BackgroundTransparency = 1
		lbl.Text = def.label
		lbl.TextColor3 = UIStyle.Color.TextMuted
		lbl.Font = UIStyle.Font.Semibold
		lbl.TextSize = 13
		lbl.TextXAlignment = Enum.TextXAlignment.Center
		lbl.TextYAlignment = Enum.TextYAlignment.Center
		lbl.Parent = btn
		local page = Instance.new("Frame")
		page.Size = UDim2.fromScale(1, 1)
		page.BackgroundTransparency = 1
		page.Visible = false
		page.Parent = content
		if def.key == "Overview" then
			tabImpls[def.key] = buildOverviewTab(page)
		elseif def.key == "Production" then
			tabImpls[def.key] = buildProductionTab(page, getBundle)
		else
			UIBuilder.emptyState(page, { icon = "Trade", title = def.label, subtitle = def.subtitle or "" })
		end
		tabs[def.key] = { button = btn, label = lbl, page = page }
		btn.MouseButton1Click:Connect(function() setActive(def.key) end)
	end
	task.defer(function() setActive("Overview") end)

	local function update(country)
		local providers = nil
		if getProviderOrder then
			local ok, p = pcall(getProviderOrder)
			if ok and type(p) == "table" then providers = p end
		end
		for key, impl in pairs(tabImpls) do
			if impl and impl.update then
				local ok, err = pcall(function()
					if key == "Overview" then impl.update(country, providers)
					else impl.update(country) end
				end)
				if not ok then warn("[EconomyWindow] tab " .. tostring(key) .. " update failed: " .. tostring(err)) end
			end
		end
	end

	return {
		open = win.open, close = win.close, toggle = win.toggle, isOpen = win.isOpen,
		bringToFront = win.bringToFront,
		setActiveTab = setActive,
		update = update,
	}
end

return EconomyWindow
