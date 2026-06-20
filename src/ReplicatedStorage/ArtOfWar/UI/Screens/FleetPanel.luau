local ScreenKit = require(script.Parent.ScreenKit)
local Components = script.Parent.Parent.Components
local Button = require(Components.Button)
local Modal = require(Components.Modal)
local Tooltip = require(Components.Tooltip)
local CountryBadge = require(Components.CountryBadge)

local FleetPanel = {}

local MISSION_ORDER = { "patrol", "raid", "blockade", "transport", "escort", "intercept" }
local SHIP_ORDER = { "shipOfTheLine", "frigate", "galleon", "transport" }

local function val(v)
	if v == nil or v == "" then
		return "\u{2014}"
	end
	return tostring(v)
end

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

local function colorOf(arr)
	if type(arr) == "table" and arr[1] then
		return Color3.fromRGB(arr[1], arr[2], arr[3])
	end
	return nil
end

local function moraleColor(pct)
	if pct > 0.6 then
		return "green"
	elseif pct > 0.3 then
		return "amber"
	end
	return "red"
end

local function shipCounts(fleet)
	local counts, hull = {}, {}
	for _, ship in ipairs(fleet.ships or {}) do
		counts[ship.typeId] = (counts[ship.typeId] or 0) + 1
		hull[ship.typeId] = (hull[ship.typeId] or 0) + (ship.hullFraction or 1)
	end
	return counts, hull
end

local function dominantType(counts, shipTypes)
	local bestId, bestCount = nil, 0
	for id, count in pairs(counts) do
		if count > bestCount then
			bestId, bestCount = id, count
		end
	end
	if not bestId then
		return "Fleet"
	end
	local spec = shipTypes and shipTypes[bestId]
	return (spec and spec.displayName) or prettify(bestId) or "Fleet"
end

function FleetPanel.create(ctx)
	local data = ctx.data or {}
	local fleetIds = data.fleetIds or { data.fleetId }
	local activeId = data.fleetId or fleetIds[1]
	local shipTypes = ctx.registries and ctx.registries.ShipTypes
	local navalMissions = ctx.registries and ctx.registries.NavalMissions
	local conns = {}
	local handle
	local dirty = false

	local function missionDefs()
		local out = {}
		local types = navalMissions and navalMissions.types
		for _, id in ipairs(MISSION_ORDER) do
			local def = types and types[id]
			if def then
				out[#out + 1] = def
			end
		end
		return out
	end

	local function statusLine(fleet, country)
		local ownerName = (country and country.displayName) or fleet.ownerTag or "\u{2014}"
		if fleet.status == "moving" then
			return string.format("Sailing \u{2192} %s  \u{00B7}  %s", val(fleet.destination), ownerName)
		elseif fleet.status == "battle" then
			return string.format("In Battle  \u{00B7}  %s", ownerName)
		elseif fleet.status == "destroyed" then
			return string.format("Destroyed  \u{00B7}  %s", ownerName)
		end
		return string.format("Docked  \u{00B7}  %s", ownerName)
	end

	local function openMissionModal(fleet)
		local modal = Modal.create({
			parent = ctx.modalLayer,
			title = "Naval Missions",
			subtitle = "Assign a standing order to this fleet",
			width = 460,
			height = 460,
			dismissable = true,
		})
		local list = Instance.new("ScrollingFrame")
		list.Size = UDim2.fromScale(1, 1)
		list.BackgroundTransparency = 1
		list.BorderSizePixel = 0
		list.ScrollBarThickness = 4
		list.AutomaticCanvasSize = Enum.AutomaticSize.Y
		list.CanvasSize = UDim2.new()
		list.ZIndex = modal.content.ZIndex
		list.Parent = modal.content
		local layout = Instance.new("UIListLayout")
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 6)
		layout.Parent = list

		local clearRow = ScreenKit.buttonRow(list, 0)
		Button.create({
			parent = clearRow,
			variant = "ghost",
			text = "Clear Mission",
			width = 180,
			onClick = function()
				ctx.fire("ClearFleetMission", fleet.id)
				modal.close()
			end,
		})

		for i, def in ipairs(missionDefs()) do
			local row = ScreenKit.stat(list, {
				icon = "Navy",
				label = def.displayName or def.id,
				value = "",
				layoutOrder = i,
			})
			Tooltip.attach(row, function()
				return Tooltip.create({ title = def.displayName or def.id, body = def.description })
			end)
			local assign = Button.create({
				parent = row,
				variant = "secondary",
				text = "Assign",
				width = 96,
				size = "sm",
				onClick = function()
					local province = def.requiresAdjacentTarget and (data.provinceId or 0) or 0
					ctx.fire("SetFleetMission", fleet.id, def.id, province, nil)
					modal.close()
				end,
			})
			assign.AnchorPoint = Vector2.new(1, 0.5)
			assign.Position = UDim2.fromScale(1, 0.5)
			assign.ZIndex = row.ZIndex + 5
		end

		local notes = missionDefs()
		for _, def in ipairs(notes) do
			if def.requiresTargetFleet or def.requiresPaired then
				ScreenKit.note(
					list,
					"Some missions need a target fleet \u{2014} pick the target on the map after assigning.",
					90
				)
				break
			end
		end
	end

	local function openBuildModal(fleet)
		local country = ctx.tag and ctx.cache.getCountry(ctx.tag)
		local provinceId = data.provinceId or fleet.provinceId
		local modal = Modal.create({
			parent = ctx.modalLayer,
			title = "Build Ships",
			subtitle = "Treasury " .. val(country and country.treasury),
			width = 460,
			height = 440,
			dismissable = true,
		})
		local list = Instance.new("ScrollingFrame")
		list.Size = UDim2.fromScale(1, 1)
		list.BackgroundTransparency = 1
		list.BorderSizePixel = 0
		list.ScrollBarThickness = 4
		list.AutomaticCanvasSize = Enum.AutomaticSize.Y
		list.CanvasSize = UDim2.new()
		list.ZIndex = modal.content.ZIndex
		list.Parent = modal.content
		local layout = Instance.new("UIListLayout")
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 6)
		layout.Parent = list

		local order = 0
		local function addShip(id, spec)
			order += 1
			local row = ScreenKit.stat(list, {
				icon = "Ship",
				label = spec.displayName or prettify(id),
				value = string.format("%s gold  \u{00B7}  %s sailors", val(spec.hullCost), val(spec.sailorCost)),
				mono = true,
				layoutOrder = order,
				height = 44,
			})
			if spec.description then
				Tooltip.attach(row, function()
					return Tooltip.create({ title = spec.displayName or id, body = spec.description })
				end)
			end
			local build = Button.create({
				parent = row,
				variant = "secondary",
				text = "Build",
				width = 90,
				size = "sm",
				onClick = function()
					ctx.fire("RecruitShip", provinceId, id, 1)
					modal.close()
				end,
			})
			build.AnchorPoint = Vector2.new(1, 0.5)
			build.Position = UDim2.fromScale(1, 0.5)
			build.ZIndex = row.ZIndex + 5
		end

		local seen = {}
		for _, id in ipairs(SHIP_ORDER) do
			local spec = shipTypes and shipTypes[id]
			if spec then
				seen[id] = true
				addShip(id, spec)
			end
		end
		if shipTypes then
			for id, spec in pairs(shipTypes) do
				if not seen[id] then
					addShip(id, spec)
				end
			end
		end
	end

	local function render()
		handle.clearBody()
		local body = handle.body
		local fleet = ctx.cache.getFleet(activeId)
		if not fleet then
			ScreenKit.note(body, "This fleet no longer exists.", 1)
			return
		end
		local country = fleet.ownerTag and ctx.cache.getCountry(fleet.ownerTag)
		local counts, hull = shipCounts(fleet)
		local isOwn = fleet.ownerTag == ctx.tag

		local badge = CountryBadge.create({
			code = fleet.ownerTag or "\u{2014}",
			countryColor = country and colorOf(country.color),
			size = "md",
			layoutOrder = 1,
			parent = body,
		})
		badge.LayoutOrder = 1

		ScreenKit.section(body, "Vitals", 2)
		local moralePct = math.clamp((fleet.morale or 0) / 100, 0, 1)
		ScreenKit.stat(body, {
			icon = "Navy",
			label = "Morale",
			value = string.format("%d / 100", math.floor((fleet.morale or 0) + 0.5)),
			progress = { value = fleet.morale or 0, max = 100, color = moraleColor(moralePct) },
			layoutOrder = 3,
		})
		ScreenKit.stat(body, {
			icon = "Shield",
			label = "Organization",
			value = string.format("%s / %s", val(fleet.organization), val(fleet.baseOrganization)),
			progress = {
				value = fleet.organization or 0,
				max = math.max(fleet.baseOrganization or 1, fleet.organization or 1),
				color = "amber",
			},
			layoutOrder = 4,
		})

		ScreenKit.section(body, "Composition", 5)
		local order = 6
		local function addType(id)
			local count = counts[id]
			if not count or count <= 0 then
				return
			end
			local spec = shipTypes and shipTypes[id]
			local avg = math.floor((hull[id] / count) * 100 + 0.5)
			ScreenKit.stat(body, {
				icon = "Ship",
				label = (spec and spec.displayName) or prettify(id),
				value = string.format("\u{00D7}%d  \u{00B7}  %d%%", count, avg),
				mono = true,
				layoutOrder = order,
			})
			order += 1
		end
		local seen = {}
		for _, id in ipairs(SHIP_ORDER) do
			seen[id] = true
			addType(id)
		end
		for id in pairs(counts) do
			if not seen[id] then
				addType(id)
			end
		end
		if order == 6 then
			ScreenKit.note(body, "This fleet has no ships.", order)
		end

		ScreenKit.section(body, "Mission", 30)
		local mission = fleet.mission
		if type(mission) == "table" and type(mission.type) == "string" then
			local def = navalMissions and navalMissions.types and navalMissions.types[mission.type]
			local target = mission.targetProvinceId and ("\u{2192} prov " .. tostring(mission.targetProvinceId)) or ""
			ScreenKit.stat(body, {
				icon = "War",
				label = (def and def.displayName) or prettify(mission.type),
				value = target,
				valueColor = "positive",
				layoutOrder = 31,
			})
		else
			ScreenKit.note(body, "No active mission.", 31)
		end

		if isOwn then
			local row = ScreenKit.buttonRow(body, 40)
			Button.create({
				parent = row,
				variant = "secondary",
				text = "Mission",
				width = 110,
				onClick = function()
					openMissionModal(fleet)
				end,
			})
			Button.create({
				parent = row,
				variant = "secondary",
				text = "Build Ships",
				width = 130,
				onClick = function()
					openBuildModal(fleet)
				end,
			})
			local row2 = ScreenKit.buttonRow(body, 41)
			Button.create({
				parent = row2,
				variant = "danger",
				text = "Disband",
				width = 120,
				onClick = function()
					ctx.fire("DisbandFleet", fleet.id)
					if ctx.onClose then
						ctx.onClose()
					end
				end,
			})
			ScreenKit.note(body, "Sail and engage orders are issued from the map.", 42)
		end
	end

	local function scheduleRefresh()
		if dirty then
			return
		end
		dirty = true
		task.defer(function()
			dirty = false
			if handle and handle.root and handle.root.Parent then
				render()
			end
		end)
	end

	local fleet = ctx.cache.getFleet(activeId)
	local country = fleet and fleet.ownerTag and ctx.cache.getCountry(fleet.ownerTag)
	local title = fleet and (dominantType(shipCounts(fleet), shipTypes) .. "  \u{00D7}" .. #(fleet.ships or {}))
		or "Fleet"

	local opts = {
		name = "FleetPanel",
		shell = "panel_medium_shell",
		title = title,
		subtitle = fleet and statusLine(fleet, country) or "\u{2014}",
		anchorPoint = Vector2.new(1, 0),
		position = UDim2.new(1, -16, 0, 16),
		size = UDim2.new(0, 360, 1, -132),
	}
	if #fleetIds >= 2 then
		local tabs = {}
		for i, id in ipairs(fleetIds) do
			local f = ctx.cache.getFleet(id)
			tabs[#tabs + 1] = {
				key = id,
				label = f and (dominantType(shipCounts(f), shipTypes)) or ("Fleet " .. tostring(i)),
			}
		end
		opts.tabs = tabs
		opts.activeTab = activeId
		opts.onTab = function(key)
			activeId = key
			render()
		end
	end

	handle = ScreenKit.open(ctx, opts)
	render()
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

return FleetPanel
