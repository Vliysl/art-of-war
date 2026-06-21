local ScreenKit = require(script.Parent.ScreenKit)
local Components = script.Parent.Parent.Components
local Button = require(Components.Button)
local CountryBadge = require(Components.CountryBadge)
local Modal = require(Components.Modal)

local ArmyPanel = {}

local REGIMENT_STRENGTH = 1000
local MORALE_MAX = 100

local function val(v)
	if v == nil or v == "" then
		return "\u{2014}"
	end
	return tostring(v)
end

local function commafy(n)
	n = math.floor(tonumber(n) or 0)
	local out = tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
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

local function moraleColor(pct)
	if pct > 0.6 then
		return "green"
	elseif pct > 0.3 then
		return "amber"
	end
	return "red"
end

local function dominantInfo(army, registries)
	local domId, domCount, total = nil, -1, 0
	local entries = {}
	for unitId, count in pairs((army and army.composition) or {}) do
		if count > 0 then
			table.insert(entries, { id = unitId, count = count })
			total += count
			if count > domCount then
				domCount = count
				domId = unitId
			end
		end
	end
	table.sort(entries, function(a, b)
		return a.count > b.count
	end)
	return {
		entries = entries,
		total = total,
		domName = domId and unitName(registries, domId) or "Force",
	}
end

local function stateLabel(army)
	if not army then
		return "\u{2014}"
	end
	if army.movement and army.movement.toProvinceId then
		return string.format("Marching \u{2192} %s", tostring(army.movement.toProvinceId))
	end
	local map = {
		idle = "Idle",
		moving = "Moving",
		attacking = "Attacking",
		defending = "Defending",
		retreating = "Retreating",
	}
	return map[army.state] or titleCase(army.state) or "Idle"
end

local function traitText(registries, officer)
	local traits = officer and officer.traits
	if type(traits) ~= "table" or #traits == 0 then
		return "No traits"
	end
	local defs = registries and registries.OfficerTraits
	local names = {}
	for _, tid in ipairs(traits) do
		local def = defs and defs[tid]
		table.insert(names, (def and def.displayName) or titleCase(tid))
	end
	return table.concat(names, ", ")
end

function ArmyPanel.create(ctx)
	local data = ctx.data or {}
	local registries = ctx.registries
	local conns = {}
	local handle

	local activeArmyId = data.armyId
	local provinceId = data.provinceId

	local function armyIds()
		if type(data.armyIds) == "table" and #data.armyIds > 0 then
			return data.armyIds
		end
		return { activeArmyId }
	end

	local function getArmy(id)
		return id and ctx.cache.getArmy(id) or nil
	end

	local function otherIds(primary)
		local out = {}
		for _, id in ipairs(armyIds()) do
			if id ~= primary then
				table.insert(out, id)
			end
		end
		return out
	end

	local function openRecruit()
		local types = registries and registries.UnitTypes
		if not types or not provinceId then
			return
		end
		local pool = {}
		for id, def in pairs(types) do
			if def.recruitCost ~= nil then
				table.insert(pool, { id = id, def = def })
			end
		end
		table.sort(pool, function(a, b)
			return (a.def.displayName or a.id) < (b.def.displayName or b.id)
		end)

		local modal = Modal.create({
			parent = ctx.modalLayer,
			title = "Recruit Regiment",
			subtitle = "Province #" .. tostring(provinceId),
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

		for i, item in ipairs(pool) do
			local row = ScreenKit.stat(list, {
				icon = "Army",
				label = item.def.displayName or titleCase(item.id),
				value = string.format("%s gold", commafy(item.def.recruitCost)),
				mono = true,
				layoutOrder = i,
			})
			local add = Button.create({
				parent = row,
				variant = "secondary",
				text = "Add",
				width = 72,
				size = "sm",
				onClick = function()
					ctx.fire("RecruitUnit", provinceId, item.id, 1)
				end,
			})
			add.AnchorPoint = Vector2.new(1, 0.5)
			add.Position = UDim2.fromScale(1, 0.5)
		end
	end

	local function render()
		handle.clearBody()
		local body = handle.body
		local army = getArmy(activeArmyId)
		if not army then
			ScreenKit.note(body, "This army no longer exists.", 1)
			return
		end

		local ownerCountry = army.ownerTag and ctx.cache.getCountry(army.ownerTag)
		CountryBadge.create({
			code = army.ownerTag or "\u{2014}",
			countryColor = ownerCountry and ownerCountry.color,
			size = "md",
			layoutOrder = 1,
			parent = body,
		})

		ScreenKit.section(body, "Vitals", 2)
		local moralePct = math.clamp((army.morale or 0) / MORALE_MAX, 0, 1)
		ScreenKit.stat(body, {
			icon = "Shield",
			label = "Morale",
			value = string.format("%d / %d", math.floor(army.morale or 0), MORALE_MAX),
			progress = { value = army.morale or 0, max = MORALE_MAX, color = moraleColor(moralePct) },
			layoutOrder = 3,
		})
		local baseOrg = army.baseOrganization or 0
		ScreenKit.stat(body, {
			icon = "War",
			label = "Organization",
			value = string.format("%d / %d", math.floor(army.organization or 0), math.floor(baseOrg)),
			progress = { value = army.organization or 0, max = math.max(baseOrg, 1), color = "amber" },
			layoutOrder = 4,
		})
		local entMax = army.entrenchmentMax or 0
		ScreenKit.stat(body, {
			icon = "Fort",
			label = "Entrenchment",
			value = string.format("%d / %d", math.floor(army.entrenchment or 0), math.floor(entMax)),
			progress = { value = army.entrenchment or 0, max = math.max(entMax, 1), color = "amber" },
			layoutOrder = 5,
		})

		local info = dominantInfo(army, registries)
		ScreenKit.section(body, "Strength", 6)
		ScreenKit.stat(body, {
			icon = "Army",
			label = "Regiments",
			value = string.format("%d  \u{00B7}  %s men", info.total, commafy(info.total * REGIMENT_STRENGTH)),
			mono = true,
			layoutOrder = 7,
		})
		local country = ctx.cache.getCountry(ctx.tag)
		ScreenKit.stat(body, {
			icon = "Manpower",
			label = "Manpower",
			value = country and commafy(country.manpower or country.levyManpower or 0) or "\u{2014}",
			mono = true,
			layoutOrder = 8,
		})

		local officer = army.officer
		if type(officer) == "table" then
			ScreenKit.section(body, "Officer", 9)
			ScreenKit.stat(body, {
				icon = "Star",
				label = val(officer.name),
				value = string.format("Lvl %d", officer.level or 0),
				layoutOrder = 10,
			})
			ScreenKit.note(body, traitText(registries, officer), 11)
			ScreenKit.stat(body, {
				label = "Experience",
				value = commafy(officer.experience or 0),
				mono = true,
				layoutOrder = 12,
			})
		end

		ScreenKit.section(body, "Composition", 20)
		if #info.entries > 0 then
			for i, e in ipairs(info.entries) do
				ScreenKit.stat(body, {
					icon = "Army",
					label = unitName(registries, e.id),
					value = tostring(e.count),
					mono = true,
					layoutOrder = 20 + i,
				})
			end
		else
			ScreenKit.note(body, "No regiments in this army.", 21)
		end

		local actions = Instance.new("Frame")
		actions.Name = "Actions"
		actions.Size = UDim2.new(1, 0, 0, 0)
		actions.AutomaticSize = Enum.AutomaticSize.Y
		actions.BackgroundTransparency = 1
		actions.LayoutOrder = 40
		actions.Parent = body
		local grid = Instance.new("UIGridLayout")
		grid.CellSize = UDim2.fromOffset(96, 36)
		grid.CellPadding = UDim2.fromOffset(8, 8)
		grid.SortOrder = Enum.SortOrder.LayoutOrder
		grid.HorizontalAlignment = Enum.HorizontalAlignment.Left
		grid.Parent = actions

		local actionOrder = 0
		local function addAction(text, variant, onClick)
			actionOrder += 1
			local b = Button.create({ parent = actions, variant = variant, text = text, width = 96, onClick = onClick })
			b.LayoutOrder = actionOrder
			return b
		end

		addAction("Attack", "danger", function()
			if ctx.requestTarget then
				ctx.requestTarget({
					kind = "attackProvince",
					armyId = activeArmyId,
					hint = "Click an enemy province to attack.",
				})
			end
		end)
		addAction("Reinforce", "secondary", function()
			if ctx.requestTarget then
				ctx.requestTarget({
					kind = "reinforce",
					armyId = activeArmyId,
					hint = "Click the battle province to reinforce.",
				})
			end
		end)
		if army.movement then
			addAction("Cancel Move", "ghost", function()
				ctx.fire("CancelMove", activeArmyId)
			end)
		end
		addAction("Recruit", "secondary", openRecruit)
		if info.total >= 2 then
			addAction("Split", "ghost", function()
				local cur = getArmy(activeArmyId)
				if not cur then
					return
				end
				local comp = {}
				local peeled = 0
				local bestId, bestCount = nil, 0
				for unitId, count in pairs(cur.composition or {}) do
					if count > 0 then
						local half = math.floor(count / 2)
						if half > 0 then
							comp[unitId] = half
							peeled += half
						end
						if count > bestCount then
							bestCount = count
							bestId = unitId
						end
					end
				end
				if peeled == 0 and bestId then
					comp[bestId] = 1
					peeled = 1
				end
				if peeled > 0 then
					ctx.fire("SplitArmy", activeArmyId, comp)
				end
			end)
		end
		if #armyIds() >= 2 then
			addAction("Merge", "ghost", function()
				local others = otherIds(activeArmyId)
				if #others > 0 then
					ctx.fire("MergeArmies", activeArmyId, others)
				end
			end)
		end
		addAction("Disband", "danger", function()
			ctx.fire("DisbandArmy", activeArmyId)
		end)
	end

	local function tabsFor()
		local ids = armyIds()
		if #ids < 2 then
			return nil
		end
		local defs = {}
		for _, id in ipairs(ids) do
			local info = dominantInfo(getArmy(id), registries)
			table.insert(defs, { key = id, label = info.domName })
		end
		return defs
	end

	local army = getArmy(activeArmyId)
	local ownerCountry = army and army.ownerTag and ctx.cache.getCountry(army.ownerTag)
	local ownerName = (ownerCountry and ownerCountry.displayName) or (army and army.ownerTag) or "\u{2014}"
	local info = dominantInfo(army, registries)

	handle = ScreenKit.open(ctx, {
		name = "ArmyPanel",
		shell = "panel_medium_shell",
		title = string.format("%s \u{00D7}%d", info.domName, info.total),
		subtitle = string.format("%s  \u{00B7}  %s", stateLabel(army), ownerName),
		anchorPoint = Vector2.new(1, 0),
		position = UDim2.new(1, -16, 0, 16),
		size = UDim2.new(0, 360, 1, -132),
		tabs = tabsFor(),
		activeTab = activeArmyId,
		onTab = function(key)
			activeArmyId = key
			render()
		end,
	})
	render()

	local scheduleRefresh = ScreenKit.throttle(function()
		if handle and handle.root and handle.root.Parent then
			render()
		end
	end)
	table.insert(conns, ctx.cache.onChangePrefix("armies", scheduleRefresh))
	table.insert(conns, ctx.cache.onChangePrefix("countries", scheduleRefresh))

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

return ArmyPanel
