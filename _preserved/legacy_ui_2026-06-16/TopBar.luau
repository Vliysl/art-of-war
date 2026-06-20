local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
local TweenService = game:GetService("TweenService")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local modulesFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Modules")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))
local Platform = require(modulesFolder:WaitForChild("Platform"))
local ClientStateCache = require(modulesFolder:WaitForChild("ClientStateCache"))
local UIRoot = require(uiFolder:WaitForChild("UIRoot"))

local TopBar = {}

local CHROME_LEFT  = 210
local CHROME_RIGHT = 60

local function formatNumber(value)
	if value == nil then return "-" end
	if type(value) ~= "number" then return tostring(value) end
	if math.abs(value) >= 1000000 then
		return string.format("%.1fM", value / 1000000)
	end
	if math.abs(value) >= 10000 then
		return string.format("%.1fk", value / 1000)
	end
	return string.format("%d", math.floor(value + 0.5))
end

local function formatSigned(value)
	local n = math.floor((tonumber(value) or 0) + 0.5)
	if n > 0 then return "+" .. tostring(n) end
	return tostring(n)
end

local function titleCase(text)
	if not text or text == "" then return "" end
	return (tostring(text):gsub("_", " ")):gsub("(%a)([%w']*)", function(a, b)
		return a:upper() .. b:lower()
	end)
end

local MONTHS = { "January", "February", "March", "April", "May", "June",
	"July", "August", "September", "October", "November", "December" }

local function formatDate(year, month, day)
	local monthName = MONTHS[month] or tostring(month)
	return string.format("%d %s %d", day or 1, monthName, year or 1750)
end

local function formatSpeed(speed, paused)
	if paused then return "PAUSED" end
	local s = tonumber(speed) or 1
	return string.format("%s×", (s == math.floor(s)) and tostring(math.floor(s)) or tostring(s))
end

local STAT_DEFS = {
	{ key = "treasury", iconKey = "Treasury", title = "Treasury", kind = "treasury", hasDelta = true, w = 144 },
	{ key = "manpower", iconKey = "Manpower", title = "Manpower", kind = "plain", field = "manpower", w = 122,
		body = "Trained men held in reserve. Recruiting a regiment draws on this pool, which recovers each month from your provinces." },
	{ key = "pp", iconKey = "PowerProj", title = "Political Power", kind = "plain", field = "politicalPower", w = 118,
		body = "Spent to enact policies, pass laws, and appoint leaders. It accrues each month from your government." },
	{ key = "stability", iconKey = "Stability", title = "Stability", kind = "stability", format = formatSigned, w = 98,
		body = "Higher stability raises tax income and lowers unrest. It ranges from -3 to +3." },
}

local function makeRealmPill(parent, def, order)
	local cell = Instance.new("Frame")
	cell.Name = "Stat_" .. def.key
	cell.Size = UDim2.fromOffset(def.w or 120, 32)
	cell.BackgroundColor3 = UIStyle.Color.PanelAlt
	cell.BorderSizePixel = 0
	cell.LayoutOrder = order
	cell.ZIndex = UIStyle.Z.Chrome + 2
	cell.Parent = parent
	UIBuilder.corner(cell, 3)
	local stroke = UIBuilder.stroke(cell, 1, UIStyle.Color.Border)
	stroke.Transparency = 0.2

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, UIStyle.Color.PanelHigh),
		ColorSequenceKeypoint.new(1, UIStyle.Color.PanelAlt),
	})
	gradient.Rotation = 90
	gradient.Parent = cell

	local icon = UIBuilder.icon(cell, def.iconKey, 15, { ImageColor3 = UIStyle.Color.Gold })
	icon.Position = UDim2.new(0, 8, 0.5, 0)
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.ZIndex = cell.ZIndex + 1
	if icon:IsA("TextLabel") then icon.TextColor3 = UIStyle.Color.Gold end

	local valueLbl = Instance.new("TextLabel")
	valueLbl.BackgroundTransparency = 1
	valueLbl.Text = "—"
	valueLbl.TextColor3 = UIStyle.Color.CreamBright
	valueLbl.FontFace = UIStyle.FontFace.CinzelBold
	valueLbl.TextSize = 14
	valueLbl.TextXAlignment = Enum.TextXAlignment.Left
	valueLbl.TextTruncate = Enum.TextTruncate.AtEnd
	valueLbl.ZIndex = cell.ZIndex + 1
	valueLbl.Parent = cell

	local deltaLbl = Instance.new("TextLabel")
	deltaLbl.BackgroundTransparency = 1
	deltaLbl.Text = ""
	deltaLbl.TextColor3 = UIStyle.Color.TextMuted
	deltaLbl.Font = UIStyle.Font.Semibold
	deltaLbl.TextSize = 9
	deltaLbl.TextXAlignment = Enum.TextXAlignment.Left
	deltaLbl.ZIndex = cell.ZIndex + 1
	deltaLbl.Parent = cell

	if def.hasDelta then
		valueLbl.Size = UDim2.new(1, -36, 0, 16)
		valueLbl.Position = UDim2.fromOffset(30, 3)
		valueLbl.TextYAlignment = Enum.TextYAlignment.Bottom
		deltaLbl.Size = UDim2.new(1, -36, 0, 10)
		deltaLbl.Position = UDim2.fromOffset(30, 19)
		deltaLbl.TextYAlignment = Enum.TextYAlignment.Top
	else
		valueLbl.Size = UDim2.new(1, -36, 1, 0)
		valueLbl.Position = UDim2.fromOffset(30, 0)
		valueLbl.TextYAlignment = Enum.TextYAlignment.Center
		deltaLbl.Visible = false
	end

	local pill = {
		root = cell,
		setText = function(t) valueLbl.Text = t or "" end,
		setColor = function(c) valueLbl.TextColor3 = c end,
	}
	return pill, deltaLbl
end

function TopBar.create(parent)
	local inset = GuiService:GetGuiInset()

	local bar = Instance.new("Frame")
	bar.Name = "TopBar"
	bar.Size = UDim2.new(1, 0, 0, UIStyle.Size.TopBarH)
	bar.Position = UDim2.fromOffset(0, 0)
	bar.BackgroundColor3 = UIStyle.Color.Bg
	bar.BorderSizePixel = 0
	bar.ZIndex = UIStyle.Z.Chrome
	bar.Active = true
	bar:SetAttribute("AoWInputSink", true)
	bar.Parent = parent

	local trim = Instance.new("Frame")
	trim.Size = UDim2.new(1, 0, 0, 1)
	trim.Position = UDim2.new(0, 0, 1, 0)
	trim.AnchorPoint = Vector2.new(0, 1)
	trim.BackgroundColor3 = UIStyle.Color.Gold
	trim.BackgroundTransparency = 0.3
	trim.BorderSizePixel = 0
	trim.ZIndex = UIStyle.Z.Chrome + 1
	trim.Parent = bar

	local centerCluster = Instance.new("Frame")
	centerCluster.Name = "CenterCluster"
	centerCluster.Size = UDim2.fromOffset(240, UIStyle.Size.TopBarH)
	centerCluster.Position = UDim2.fromScale(0.5, 0)
	centerCluster.AnchorPoint = Vector2.new(0.5, 0)
	centerCluster.BackgroundTransparency = 1
	centerCluster.ZIndex = UIStyle.Z.Chrome + 1
	centerCluster.Parent = bar

	local dateLabel = UIBuilder.label(centerCluster, "1 January 1750", UIStyle.Type.Body, UIStyle.Color.GoldBright, {
		Size = UDim2.new(1, 0, 0, 22),
		Position = UDim2.fromOffset(0, 4),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		FontFace = UIStyle.FontFace.CinzelBold,
		TextSize = 15,
	})

	local speedLabel = UIBuilder.label(centerCluster, "1×", UIStyle.Type.Small, UIStyle.Color.TextMuted, {
		Size = UDim2.new(1, 0, 0, 12),
		Position = UDim2.fromOffset(0, 26),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		Font = UIStyle.Font.Regular,
		TextSize = 11,
	})

	local pauseBtn = nil
	if Platform.isTouch then
		pauseBtn = Instance.new("TextButton")
		pauseBtn.Size = UDim2.fromOffset(40, 32)
		pauseBtn.Position = UDim2.new(0, -52, 0.5, 0)
		pauseBtn.AnchorPoint = Vector2.new(0, 0.5)
		pauseBtn.BackgroundColor3 = UIStyle.Color.PanelAlt
		pauseBtn.BorderSizePixel = 0
		pauseBtn.AutoButtonColor = false
		pauseBtn.Text = "\u{23F8}"
		pauseBtn.TextColor3 = UIStyle.Color.Gold
		pauseBtn.Font = UIStyle.Font.Bold
		pauseBtn.TextSize = 16
		pauseBtn.ZIndex = UIStyle.Z.Chrome + 2
		pauseBtn.Parent = centerCluster
		UIBuilder.corner(pauseBtn, 4)
		UIBuilder.stroke(pauseBtn, 1, UIStyle.Color.Border)
	end

	local rightCluster = Instance.new("Frame")
	rightCluster.Name = "RightCluster"
	rightCluster.Size = UDim2.fromOffset(740, UIStyle.Size.TopBarH)
	rightCluster.Position = UDim2.new(1, -CHROME_RIGHT, 0, 0)
	rightCluster.AnchorPoint = Vector2.new(1, 0)
	rightCluster.BackgroundTransparency = 1
	rightCluster.ZIndex = UIStyle.Z.Chrome + 1
	rightCluster.Parent = bar

	local menuBtn = UIBuilder.iconButton(rightCluster, "Menu", { size = 30 })
	menuBtn.Position = UDim2.new(1, 0, 0.5, 0)
	menuBtn.AnchorPoint = Vector2.new(1, 0.5)
	menuBtn.Visible = false

	local pillRow = Instance.new("Frame")
	pillRow.Size = UDim2.new(1, -42, 1, 0)
	pillRow.Position = UDim2.fromOffset(0, 0)
	pillRow.BackgroundTransparency = 1
	pillRow.Parent = rightCluster

	local pillLayout = Instance.new("UIListLayout")
	pillLayout.FillDirection = Enum.FillDirection.Horizontal
	pillLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	pillLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	pillLayout.Padding = UDim.new(0, 6)
	pillLayout.Parent = pillRow

	local statRefs = {}
	local currentTag = nil

	local function makeTooltip(def)
		return function()
			local rows = {}
			local country = currentTag and ClientStateCache.getCountry(currentTag) or nil
			if def.kind == "treasury" then
				rows[#rows + 1] = { header = "Treasury" }
				rows[#rows + 1] = { label = "Balance",
					value = formatNumber(country and country.treasury or statRefs.treasury.current),
					tone = UIStyle.Color.GoldBright }
				local income = (country and country.incomeBreakdown) or {}
				local expense = (country and country.expenseBreakdown) or {}
				local incList, expList, incTotal, expTotal = {}, {}, 0, 0
				for id, amt in pairs(income) do
					if amt and amt > 0 then incList[#incList + 1] = { id = id, amt = amt }; incTotal += amt end
				end
				for id, amt in pairs(expense) do
					if amt and amt > 0 then expList[#expList + 1] = { id = id, amt = amt }; expTotal += amt end
				end
				table.sort(incList, function(a, b) return a.amt > b.amt end)
				table.sort(expList, function(a, b) return a.amt > b.amt end)
				if #incList > 0 then
					rows[#rows + 1] = { header = "Income / day" }
					for _, e in ipairs(incList) do
						rows[#rows + 1] = { label = titleCase(e.id), value = string.format("+%.1f", e.amt), tone = UIStyle.Color.Good }
					end
				end
				if #expList > 0 then
					rows[#rows + 1] = { header = "Expenses / day" }
					for _, e in ipairs(expList) do
						rows[#rows + 1] = { label = titleCase(e.id), value = string.format("-%.1f", e.amt), tone = UIStyle.Color.Bad }
					end
				end
				local net = incTotal - expTotal
				rows[#rows + 1] = { label = "Net", value = string.format("%+.1f / day", net), tone = UIStyle.stateColor(net) }
				if country and country.lastIncome then
					rows[#rows + 1] = { body = string.format("Monthly balance %+d ducats.", math.floor(country.lastIncome + 0.5)) }
				end
			elseif def.kind == "stability" then
				rows[#rows + 1] = { header = "Stability & Legitimacy" }
				rows[#rows + 1] = { label = "Stability",
					value = formatSigned(country and country.stability or statRefs.stability.current),
					tone = UIStyle.stateColor(country and country.stability or 0) }
				rows[#rows + 1] = { label = "Legitimacy",
					value = string.format("%d%%", math.floor((country and country.legitimacy or 0) + 0.5)) }
				if def.body then rows[#rows + 1] = { body = def.body } end
			else
				rows[#rows + 1] = { header = def.title }
				local v = (country and def.field and country[def.field]) or statRefs[def.key].current
				rows[#rows + 1] = { label = "Current", value = formatNumber(v) }
				if def.body then rows[#rows + 1] = { body = def.body } end
			end
			return rows
		end
	end

	for i, def in ipairs(STAT_DEFS) do
		local pill, deltaLbl = makeRealmPill(pillRow, def, i)
		statRefs[def.key] = { pill = pill, delta = deltaLbl, def = def, current = 0 }
		UIBuilder.tooltip(pill.root, makeTooltip(def))
	end

	local function setClaimedVisibility(isClaimed)
		pillRow.Visible = isClaimed
	end

	local pausedBadge = nil
	local pulseTween = nil
	local function setPaused(flag)
		if pauseBtn then
			pauseBtn.Text = flag and "\u{25B6}" or "\u{23F8}"
		end
		if flag then
			if not pausedBadge then
				pausedBadge = UIBuilder.badge(centerCluster, "PAUSED", "warn", {
					Position = UDim2.new(0.5, 0, 1, -10),
					AnchorPoint = Vector2.new(0.5, 1),
				})
			end
			if pulseTween then pulseTween:Cancel() end
			pulseTween = TweenService:Create(
				dateLabel,
				TweenInfo.new(UIStyle.Motion.Slow.time, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ TextColor3 = UIStyle.Color.GoldBright }
			)
			pulseTween:Play()
		else
			if pulseTween then pulseTween:Cancel(); pulseTween = nil end
			dateLabel.TextColor3 = UIStyle.Color.Gold
			if pausedBadge then pausedBadge:Destroy(); pausedBadge = nil end
		end
	end

	local adminMode = false
	local function setAdmin(flag)
		adminMode = flag and true or false
	end

	setClaimedVisibility(false)

	UIRoot.registerScaled(rightCluster)
	UIRoot.registerScaled(centerCluster)

	return {
		root = bar,
		dateLabel = dateLabel,
		stats = statRefs,

		setCountry = function(tag, displayName, colorRGB, govLabel, ideologyLabel, flagAssetId)
			currentTag = tag
			setClaimedVisibility(tag ~= nil)
		end,

		setDate = function(text)
			dateLabel.Text = text or ""
		end,

		setTime = function(year, month, day, speed, paused)
			dateLabel.Text = formatDate(year, month, day)
			speedLabel.Text = formatSpeed(speed, paused)
			speedLabel.TextColor3 = paused and UIStyle.Color.Warn or UIStyle.Color.TextMuted
		end,

		setStat = function(key, value, delta)
			local cell = statRefs[key]
			if not cell then return end
			cell.current = value or 0
			local fmt = (cell.def and cell.def.format) or formatNumber
			cell.pill.setText(fmt(value))
			if delta ~= nil and delta ~= 0 then
				local sign = delta > 0 and "+" or ""
				cell.delta.Text = string.format("%s%s/mo", sign, formatNumber(delta))
				cell.delta.TextColor3 = UIStyle.stateColor(delta)
			else
				cell.delta.Text = ""
			end
		end,

		setStatColor = function(key, color)
			local cell = statRefs[key]
			if not cell then return end
			cell.pill.setColor(color)
		end,
		setPaused = setPaused,
		setAdmin = setAdmin,
		isAdmin = function() return adminMode end,

		getMenuButton = function() return menuBtn end,
		getPauseButton = function() return pauseBtn end,
		setClaimedVisibility = setClaimedVisibility,
	}
end

return TopBar