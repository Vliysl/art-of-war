local ScreenKit = require(script.Parent.ScreenKit)
local Components = script.Parent.Parent.Components
local Button = require(Components.Button)
local CountryBadge = require(Components.CountryBadge)
local Modal = require(Components.Modal)

local ProvinceOverview = {}

local function val(v)
	if v == nil or v == "" then
		return "\u{2014}"
	end
	return tostring(v)
end

function ProvinceOverview.create(ctx)
	local prov = ctx.data or {}
	local handle
	local registries = ctx.registries

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

	-- Province-scoped recruitment: gives a player with no armies a way to raise their first one
	-- (server validates ownership/cost via RecruitUnit).
	local function openRecruit()
		local types = registries and registries.UnitTypes
		if not types or not prov.id then
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
			subtitle = prov.name or ("Province #" .. tostring(prov.id)),
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
			local r = ScreenKit.stat(list, {
				icon = "Army",
				label = item.def.displayName or titleCase(item.id),
				value = string.format("%s gold", tostring(item.def.recruitCost)),
				mono = true,
				layoutOrder = i,
			})
			local add = Button.create({
				parent = r,
				variant = "secondary",
				text = "Add",
				onClick = function()
					ctx.fire("RecruitUnit", prov.id, item.id, 1)
				end,
			})
			add.AnchorPoint = Vector2.new(1, 0.5)
			add.Position = UDim2.fromScale(1, 0.5)
		end
	end

	handle = ScreenKit.open(ctx, {
		name = "ProvinceOverview",
		shell = "panel_medium_shell",
		title = prov.name or "Province",
		subtitle = (prov.ownerName and (prov.ownerName .. "  \u{00B7}  ") or "") .. ("#" .. tostring(prov.id or "?")),
		anchorPoint = Vector2.new(1, 0),
		position = UDim2.new(1, -16, 0, 16),
		size = UDim2.new(0, 360, 1, -132),
	})
	local body = handle.body

	local badge = CountryBadge.create({
		code = prov.ownerTag or "\u{2014}",
		countryColor = prov.ownerColor,
		size = "md",
		layoutOrder = 1,
		parent = body,
	})
	badge.LayoutOrder = 1

	ScreenKit.section(body, "Land", 2)
	ScreenKit.stat(body, { icon = "MapTerrain", label = "Terrain", value = val(prov.terrain), layoutOrder = 3 })
	ScreenKit.stat(
		body,
		{ icon = "Building", label = "Development", value = val(prov.devTotal), mono = true, layoutOrder = 4 }
	)
	ScreenKit.stat(body, {
		label = "Tax / Prod / Mp",
		value = string.format("%s / %s / %s", val(prov.devAdm), val(prov.devDip), val(prov.devMil)),
		mono = true,
		layoutOrder = 5,
	})
	ScreenKit.stat(body, { icon = "Goods", label = "Trade Good", value = val(prov.tradeGood), layoutOrder = 6 })
	ScreenKit.stat(body, { icon = "Fort", label = "Fort Level", value = val(prov.fortLevel or 0), layoutOrder = 7 })

	ScreenKit.section(body, "Society", 8)
	ScreenKit.stat(body, { icon = "MapCulture", label = "Culture", value = val(prov.culture), layoutOrder = 9 })
	ScreenKit.stat(body, { icon = "MapReligion", label = "Religion", value = val(prov.religion), layoutOrder = 10 })
	ScreenKit.stat(body, {
		icon = "Unrest",
		label = "Unrest",
		value = val(prov.unrest or 0),
		valueColor = (prov.unrest and prov.unrest > 0) and "negative" or nil,
		progress = { value = prov.unrest or 0, max = 10, color = "red" },
		layoutOrder = 11,
	})
	ScreenKit.stat(body, {
		icon = "Lock",
		label = "Autonomy",
		value = (prov.autonomy and prov.autonomy .. "%") or "\u{2014}",
		progress = { value = prov.autonomy or 0, max = 100, color = "amber" },
		layoutOrder = 12,
	})

	ScreenKit.section(body, "Output", 13)
	ScreenKit.stat(
		body,
		{ icon = "Treasury", label = "Tax Income", value = val(prov.tax), valueColor = "positive", layoutOrder = 14 }
	)
	ScreenKit.stat(body, {
		icon = "Factory",
		label = "Production",
		value = val(prov.production),
		valueColor = "positive",
		layoutOrder = 15,
	})
	ScreenKit.stat(body, { icon = "Manpower", label = "Manpower", value = val(prov.manpower), layoutOrder = 16 })

	if prov.isOwn then
		local row = ScreenKit.buttonRow(body, 40)
		Button.create({
			parent = row,
			variant = "primary",
			text = "Recruit",
			onClick = openRecruit,
		})
		ScreenKit.note(body, "Construct buildings from the Economy screen (hotkey 2).", 41)
	end

	return handle
end

return ProvinceOverview
