local ScreenKit = require(script.Parent.ScreenKit)
local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Spacing = DesignSystem.Spacing
local Icons = DesignSystem.Icons
local Shells = DesignSystem.Shells
local Components = script.Parent.Parent.Components
local Tooltip = require(Components.Tooltip)

local ResearchScreen = {}

local TABS = {
	{ key = "army", label = "Army" },
	{ key = "naval", label = "Naval" },
	{ key = "industrial", label = "Industrial" },
	{ key = "technological", label = "Technological" },
}

local function prettify(id)
	if type(id) ~= "string" or id == "" then
		return ""
	end
	local out = {}
	for word in id:gmatch("[^_%s]+") do
		out[#out + 1] = word:sub(1, 1):upper() .. word:sub(2)
	end
	return table.concat(out, " ")
end

function ResearchScreen.create(ctx)
	local registry = (ctx.registries and ctx.registries.Technologies) or {}
	local conns = {}
	local handle

	local byTabCat = {}
	local catOrder = {}
	for _, def in registry do
		local tab = def.tab or "industrial"
		local cat = def.category or "general"
		byTabCat[tab] = byTabCat[tab] or {}
		byTabCat[tab][cat] = byTabCat[tab][cat] or {}
		table.insert(byTabCat[tab][cat], def)
	end
	for tab, cats in byTabCat do
		catOrder[tab] = {}
		for cat, list in cats do
			table.sort(list, function(a, b)
				if a.year == b.year then
					return a.name < b.name
				end
				return a.year < b.year
			end)
			local minYear = list[1] and list[1].year or 9999
			table.insert(catOrder[tab], { cat = cat, minYear = minYear })
		end
		table.sort(catOrder[tab], function(a, b)
			return a.minYear < b.minYear
		end)
	end

	local function country()
		return ctx.tag and ctx.cache.getCountry(ctx.tag) or nil
	end
	local function completed(c, id)
		return c and c.techs and c.techs[id] == true
	end
	local function prereqsMet(c, def)
		for _, p in ipairs(def.prerequisites or {}) do
			if not completed(c, p) then
				return false
			end
		end
		return true
	end
	local function progressOf(c, id)
		return (c and c.research and c.research.progress and c.research.progress[id]) or 0
	end

	local function techRow(body, def, c, order)
		local isDone = completed(c, def.id)
		local active = c and c.research and c.research.active
		local isActive = active == def.id
		local met = prereqsMet(c, def)
		local statusText, statusColor, nameColor
		if isDone then
			statusText, statusColor, nameColor = "Researched", Colors.Positive, Colors.TextSecondary
		elseif isActive then
			local prog = progressOf(c, def.id)
			statusText = string.format("%d%%", math.clamp(math.floor(prog / math.max(def.cost, 1) * 100), 0, 99))
			statusColor, nameColor = Colors.Accent, Colors.Accent
		elseif met then
			statusText, statusColor, nameColor = def.cost .. " RP", Colors.TextSecondary, Colors.TextPrimary
		else
			statusText, statusColor, nameColor = "Locked", Colors.TextTertiary, Colors.TextDisabled
		end

		local row = Instance.new("TextButton")
		row.Name = def.id
		row.Size = UDim2.new(1, 0, 0, isActive and 42 or 32)
		row.BackgroundTransparency = 1
		row.AutoButtonColor = false
		row.Text = ""
		row.LayoutOrder = order
		row.Parent = body

		local icon = Icons.create(isDone and "Check" or "Research", 15, statusColor)
		icon.AnchorPoint = Vector2.new(0, 0)
		icon.Position = UDim2.fromOffset(0, 8)
		icon.Parent = row

		local name = Instance.new("TextLabel")
		name.Position = UDim2.fromOffset(24, 0)
		name.Size = UDim2.new(1, -120, 0, 30)
		name.BackgroundTransparency = 1
		name.Text = string.format("%s  [%d]", def.name, def.year)
		name.TextColor3 = nameColor
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextYAlignment = Enum.TextYAlignment.Top
		name.TextTruncate = Enum.TextTruncate.AtEnd
		Typography.apply(name, "label")
		name.Parent = row

		local status = Instance.new("TextLabel")
		status.AnchorPoint = Vector2.new(1, 0)
		status.Position = UDim2.fromOffset(0, 0)
		status.Position = UDim2.new(1, 0, 0, 0)
		status.Size = UDim2.new(0, 96, 0, 30)
		status.BackgroundTransparency = 1
		status.Text = statusText
		status.TextColor3 = statusColor
		status.TextXAlignment = Enum.TextXAlignment.Right
		status.TextYAlignment = Enum.TextYAlignment.Top
		Typography.apply(status, "caption")
		status.Parent = row

		if isActive then
			local prog = progressOf(c, def.id)
			local track = Shells.create("progress_track_long", { Name = "Bar", Size = UDim2.new(1, 0, 0, 4) })
			track.AnchorPoint = Vector2.new(0, 1)
			track.Position = UDim2.new(0, 0, 1, -2)
			track.Parent = row
			local clip = Instance.new("Frame")
			clip.BackgroundTransparency = 1
			clip.ClipsDescendants = true
			local pct = math.clamp(prog / math.max(def.cost, 1), 0, 1)
			clip.Size = UDim2.new(pct, 0, 1, 0)
			clip.Parent = track
			local fill =
				Shells.create("progress_fill_amber_long", { Size = UDim2.new(pct > 0 and 1 / pct or 1, 0, 1, 0) })
			fill.Parent = clip
		end

		if not isDone and met and not isActive then
			row.MouseEnter:Connect(function()
				name.TextColor3 = Colors.AccentHover
			end)
			row.MouseLeave:Connect(function()
				name.TextColor3 = Colors.TextPrimary
			end)
			row.MouseButton1Click:Connect(function()
				if ctx.fire then
					ctx.fire("SetResearch", def.id)
				end
			end)
		end

		Tooltip.attach(row, function()
			local rows =
				{ { label = "Cost", value = def.cost .. " RP" }, { label = "Year", value = tostring(def.year) } }
			if def.prerequisites and #def.prerequisites > 0 then
				local names = {}
				for _, p in ipairs(def.prerequisites) do
					names[#names + 1] = registry[p] and registry[p].name or prettify(p)
				end
				rows[#rows + 1] = { label = "Requires", value = table.concat(names, ", ") }
			end
			local body2 = def.description or ""
			if def.effects and def.effects.summary and def.effects.summary ~= "" then
				body2 = body2 .. "\n\nEffects: " .. def.effects.summary
			end
			return Tooltip.create({ title = def.name, body = body2, rows = rows, width = 300 })
		end)
	end

	local function render(tabKey)
		handle.clearBody()
		local body = handle.body
		local c = country()

		local active = c and c.research and c.research.active
		if active and registry[active] then
			local def = registry[active]
			ScreenKit.stat(body, {
				parent = body,
				icon = "Research",
				label = "Researching: " .. def.name,
				value = string.format("%d / %d RP", math.floor(progressOf(c, active)), def.cost),
				valueColor = "accent",
				progress = { value = progressOf(c, active), max = def.cost, color = "amber" },
				layoutOrder = 1,
			})
		else
			ScreenKit.note(
				body,
				c and "No active research — select a technology below to begin."
					or "Claim a nation to direct its research.",
				1
			)
		end

		local order = 9
		for _, entry in ipairs(catOrder[tabKey] or {}) do
			order += 1
			ScreenKit.section(body, prettify(entry.cat), order)
			for _, def in ipairs(byTabCat[tabKey][entry.cat]) do
				order += 1
				techRow(body, def, c, order)
			end
		end
	end

	local activeTab = "army"
	local lastSig = nil
	local dirty = false

	-- The visible state is tech statuses (researched/locked/available) + the active research's progress.
	-- It does NOT depend on treasury/manpower, so exclude those (they mutate every economy tick). The
	-- active tech's progress IS displayed exactly ("X / Y RP"), so track exact floor(prog): this rebuilds
	-- only per game-day WHILE a tech is researching (never when idle, which is the screenshotted case).
	local function contentSignature(tabKey)
		local c = country()
		local parts = { tabKey }
		if not c then
			parts[#parts + 1] = "noclaim"
			return table.concat(parts, "|")
		end
		local active = c.research and c.research.active
		parts[#parts + 1] = "a:" .. tostring(active)
		if active and registry[active] then
			parts[#parts + 1] = "p:" .. math.floor(progressOf(c, active))
		end
		local done = {}
		if c.techs then
			for id, v in pairs(c.techs) do
				if v == true then
					done[#done + 1] = id
				end
			end
			table.sort(done)
		end
		parts[#parts + 1] = "t:" .. table.concat(done, ",")
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
		name = "ResearchScreen",
		title = "Research",
		subtitle = "Technology",
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

return ResearchScreen
