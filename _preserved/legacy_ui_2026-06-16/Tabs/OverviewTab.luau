local ReplicatedStorage = game:GetService("ReplicatedStorage")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))

local OverviewTab = {}

local function titleCase(text)
	if not text then return "" end
	return (text:gsub("_", " ")):gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b:lower() end)
end

local function addStatRow(parent, _iconKey, label, orderIndex)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 20)
	row.BackgroundTransparency = 1
	row.LayoutOrder = orderIndex
	row.Parent = parent

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(0.55, 0, 1, 0)
	lbl.Position = UDim2.fromOffset(0, 0)
	lbl.BackgroundTransparency = 1
	lbl.Text = label or ""
	lbl.TextColor3 = UIStyle.Color.LedgerLabel
	lbl.FontFace = UIStyle.FontFace.Inter
	lbl.TextSize = 13
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextYAlignment = Enum.TextYAlignment.Center
	lbl.ZIndex = (parent.ZIndex or 1) + 1
	lbl.Parent = row

	local valueLbl = Instance.new("TextLabel")
	valueLbl.Size = UDim2.new(0.45, 0, 1, 0)
	valueLbl.Position = UDim2.new(1, 0, 0, 0)
	valueLbl.AnchorPoint = Vector2.new(1, 0)
	valueLbl.BackgroundTransparency = 1
	valueLbl.Text = "-"
	valueLbl.TextColor3 = UIStyle.Color.LedgerValue
	valueLbl.FontFace = UIStyle.FontFace.Cinzel
	valueLbl.TextSize = 13
	valueLbl.TextXAlignment = Enum.TextXAlignment.Right
	valueLbl.TextYAlignment = Enum.TextYAlignment.Center
	valueLbl.ZIndex = (parent.ZIndex or 1) + 1
	valueLbl.Parent = row

	return { row = row, label = lbl, value = valueLbl }
end

function OverviewTab.mount(page)
	local scroll, layout = UIBuilder.scrollingList(page, { Size = UDim2.fromScale(1, 1) })
	layout.Padding = UDim.new(0, 8)

	-- Top: Stability + Legitimacy progress bars
	local headerSec = Instance.new("Frame")
	headerSec.Size = UDim2.new(1, -4, 0, 92)
	headerSec.BackgroundColor3 = UIStyle.Color.PanelAlt
	headerSec.BorderSizePixel = 0
	headerSec.LayoutOrder = 1
	headerSec.ZIndex = UIStyle.Z.Content
	headerSec.Parent = scroll
	UIBuilder.corner(headerSec, 2)
	UIBuilder.stroke(headerSec, 1, UIStyle.Color.Border)
	UIBuilder.padding(headerSec, 12)

	local stabilityBar = UIBuilder.progressBar(headerSec, {
		label = "Stability",
		value = 0, max = 6,
		color = UIStyle.Color.Good,
		height = 10,
		size = UDim2.new(1, 0, 0, 30),
	})
	stabilityBar.root.Position = UDim2.fromOffset(0, 0)

	local legitimacyBar = UIBuilder.progressBar(headerSec, {
		label = "Legitimacy",
		value = 0, max = 100,
		color = UIStyle.Color.Gold,
		height = 10,
		size = UDim2.new(1, 0, 0, 30),
	})
	legitimacyBar.root.Position = UDim2.fromOffset(0, 38)

	-- ECONOMY section
	local econ = UIBuilder.collapsibleSection(scroll, "Economy")
	econ.container.LayoutOrder = 2

	local econBodyPad = Instance.new("Frame")
	econBodyPad.Size = UDim2.new(1, 0, 0, 0)
	econBodyPad.AutomaticSize = Enum.AutomaticSize.Y
	econBodyPad.BackgroundTransparency = 1
	econBodyPad.Parent = econ.body
	UIBuilder.padding(econBodyPad, 8, 10, 8, 10)

	local econLayout = Instance.new("UIListLayout")
	econLayout.FillDirection = Enum.FillDirection.Vertical
	econLayout.Padding = UDim.new(0, 2)
	econLayout.SortOrder = Enum.SortOrder.LayoutOrder
	econLayout.Parent = econBodyPad

	local rows = {}
	rows.treasury = addStatRow(econBodyPad, "Treasury", "Treasury", 1)
	rows.income   = addStatRow(econBodyPad, "Trade",    "Last Income", 2)
	rows.manpower = addStatRow(econBodyPad, "Manpower", "Manpower", 3)
	rows.pp       = addStatRow(econBodyPad, "PowerProj","Political Power", 4)

	-- GOVERNMENT section
	local gov = UIBuilder.collapsibleSection(scroll, "Government")
	gov.container.LayoutOrder = 3

	local govBodyPad = Instance.new("Frame")
	govBodyPad.Size = UDim2.new(1, 0, 0, 0)
	govBodyPad.AutomaticSize = Enum.AutomaticSize.Y
	govBodyPad.BackgroundTransparency = 1
	govBodyPad.Parent = gov.body
	UIBuilder.padding(govBodyPad, 8, 10, 8, 10)

	local govLayout = Instance.new("UIListLayout")
	govLayout.FillDirection = Enum.FillDirection.Vertical
	govLayout.Padding = UDim.new(0, 2)
	govLayout.SortOrder = Enum.SortOrder.LayoutOrder
	govLayout.Parent = govBodyPad

	rows.government     = addStatRow(govBodyPad, "TabLeaders",  "Government", 1)
	rows.ideology       = addStatRow(govBodyPad, "TabFactions", "Ideology", 2)
	rows.doctrine       = addStatRow(govBodyPad, "Army",        "Doctrine", 3)
	-- Doctrine names can be long ("Asymmetrical Infantry Doctrine") -- wrap to 2 lines
	rows.doctrine.value.TextWrapped = true
	rows.doctrine.value.AutomaticSize = Enum.AutomaticSize.Y
	rows.doctrine.value.TextYAlignment = Enum.TextYAlignment.Top
	rows.doctrine.row.AutomaticSize = Enum.AutomaticSize.Y
	rows.capital        = addStatRow(govBodyPad, "Province",    "Capital", 4)
	rows.activePolicies = addStatRow(govBodyPad, "TabPolicies", "Active Policies", 5)

	return {
		update = function(country, bundle)
			if not country then return end

			-- Bars (stability range -3..+3 -> scaled 0..6)
			stabilityBar.setValue((country.stability or 0) + 3, 6)
			stabilityBar.setColor(UIStyle.stateColor(country.stability or 0))
			legitimacyBar.setValue(country.legitimacy or 0, 100)

			-- Economy
			rows.treasury.value.Text = string.format("%d", math.floor((country.treasury or 0) + 0.5))
			rows.treasury.value.TextColor3 = UIStyle.Color.LedgerValue
			local income = country.lastIncome or 0
			rows.income.value.Text = string.format("%+.1f", income)
			rows.income.value.TextColor3 = UIBuilder.ledgerNumberColor(income)
			rows.manpower.value.Text = string.format("%d", math.floor((country.manpower or 0) + 0.5))
			rows.manpower.value.TextColor3 = UIStyle.Color.LedgerPositive
			rows.pp.value.Text = string.format("%d", math.floor((country.politicalPower or 0) + 0.5))
			rows.pp.value.TextColor3 = UIStyle.Color.LedgerPositive

			-- Government
			local g = bundle and bundle.governmentTypes and bundle.governmentTypes[country.governmentForm]
			rows.government.value.Text = g and g.displayName or titleCase(country.governmentForm)

			local ideology = bundle and bundle.ideologies and bundle.ideologies[country.ideology]
			rows.ideology.value.Text = ideology and ideology.displayName or titleCase(country.ideology)

			local doctrine = bundle and bundle.doctrines and bundle.doctrines[country.doctrine]
			rows.doctrine.value.Text = doctrine and doctrine.displayName or (country.doctrine and titleCase(country.doctrine)) or "None"

			rows.capital.value.Text = tostring(country.capitalProvinceId or "-")

			local policyCount = 0
			if country.activePolicies then
				for _ in country.activePolicies do policyCount += 1 end
			end
			rows.activePolicies.value.Text = tostring(policyCount)
		end,
	}
end

return OverviewTab
