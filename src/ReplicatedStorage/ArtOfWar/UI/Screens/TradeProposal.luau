-- TradeProposal: the deal builder. Buy OR sell a basket of resources to/from a chosen nation for
-- gold (price = basePrice x multiplier), as a one-time or recurring (every 5 days) order. Fires
-- PlaceTradeOrder; the server prompts the counterparty (TradeOffer modal) if it is a player, or
-- auto-accepts if it is unclaimed/AI.

local ScreenKit = require(script.Parent.ScreenKit)
local Components = script.Parent.Parent.Components
local Button = require(Components.Button)
local Modal = require(Components.Modal)
local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Icons = DesignSystem.Icons

local TradeProposal = {}

local MULT_MIN = 0.5
local MULT_MAX = 2.0
local MULT_STEP = 0.05
local MAX_PICKER_ROWS = 60

local function prettify(id)
	if type(id) ~= "string" or id == "" then
		return tostring(id)
	end
	local out = {}
	for word in id:gmatch("[^_%s]+") do
		out[#out + 1] = word:sub(1, 1):upper() .. word:sub(2)
	end
	return table.concat(out, " ")
end

local function money(n)
	n = tonumber(n) or 0
	return string.format("\u{00A3}%g", math.floor(n * 100 + 0.5) / 100)
end

-- Procedural search box (Frame + UICorner + UIStroke + TextBox), debounced 0.1s. No 9-slice shell, so
-- it is correct on frame 0 (see the procedural-button rationale).
local function makeSearchBox(parent, placeholder, onChanged)
	local frame = Instance.new("Frame")
	frame.Name = "Search"
	frame.Size = UDim2.new(1, 0, 0, 36)
	frame.BackgroundColor3 = Colors.SurfaceElevated
	frame.BorderSizePixel = 0
	frame.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = Colors.BorderStrong
	stroke.Thickness = 1
	stroke.Parent = frame
	local icon = Icons.create("Search", 16, Colors.TextSecondary)
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.new(0, 10, 0.5, 0)
	icon.Parent = frame
	local box = Instance.new("TextBox")
	box.Name = "Input"
	box.Position = UDim2.fromOffset(34, 0)
	box.Size = UDim2.new(1, -44, 1, 0)
	box.BackgroundTransparency = 1
	box.Text = ""
	box.PlaceholderText = placeholder
	box.PlaceholderColor3 = Colors.TextSecondary
	box.TextColor3 = Colors.TextPrimary
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.ClearTextOnFocus = false
	box.ClipsDescendants = true
	Typography.apply(box, "bodyMd")
	box.Parent = frame
	local debounce
	box:GetPropertyChangedSignal("Text"):Connect(function()
		local text = box.Text
		if debounce then
			task.cancel(debounce)
		end
		debounce = task.delay(0.1, function()
			debounce = nil
			onChanged(text)
		end)
	end)
	return frame
end

-- A searchable list sub-modal (rendered above the form). `items` = { key, label, searchText, icon }.
local function openSearchPicker(ctx, title, items, onPick)
	local modal = Modal.create({
		parent = ctx.modalLayer or ctx.parent,
		title = title,
		width = 440,
		height = 500,
		zIndex = 60,
	})
	local content = modal.content

	local list = Instance.new("ScrollingFrame")
	list.Position = UDim2.fromOffset(0, 46)
	list.Size = UDim2.new(1, 0, 1, -46)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 4
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.Parent = content
	local listPad = Instance.new("UIPadding")
	listPad.PaddingRight = UDim.new(0, 8)
	listPad.Parent = list
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = list

	local function rebuild(query)
		query = (query or ""):lower()
		for _, child in list:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local shown = 0
		for _, item in ipairs(items) do
			if query == "" or item.searchText:find(query, 1, true) then
				shown += 1
				local row = ScreenKit.stat(list, { icon = item.icon, label = item.label, layoutOrder = shown })
				local btn = Button.create({
					parent = row,
					variant = "secondary",
					text = "Select",
					width = 84,
					size = "sm",
					onClick = function()
						onPick(item)
						modal.close()
					end,
				})
				btn.AnchorPoint = Vector2.new(1, 0.5)
				btn.Position = UDim2.fromScale(1, 0.5)
				if shown >= MAX_PICKER_ROWS then
					break
				end
			end
		end
		if shown == 0 then
			ScreenKit.note(list, "No matches.", 1)
		end
	end

	local search = makeSearchBox(content, "Search\u{2026}", rebuild)
	search.Position = UDim2.fromOffset(0, 0)
	rebuild("")
end

function TradeProposal.create(ctx)
	local registries = ctx.registries or {}
	local goods = registries.TradeGoods or {}

	local state = {
		partnerTag = nil,
		partnerName = nil,
		direction = "buy",
		lines = {},
		multiplier = 1.0,
		recurring = false,
	}

	local function basePrice(goodId)
		local def = goods[goodId]
		return (def and def.basePrice) or 0
	end
	local function goodName(goodId)
		local def = goods[goodId]
		return (def and def.displayName) or prettify(goodId)
	end
	local function total()
		local sum = 0
		for _, line in ipairs(state.lines) do
			sum += line.amount * basePrice(line.goodId)
		end
		return sum * state.multiplier
	end
	local function hasLine(goodId)
		for _, line in ipairs(state.lines) do
			if line.goodId == goodId then
				return true
			end
		end
		return false
	end

	local function countryItems()
		local items = {}
		for tag, country in pairs(ctx.cache.allCountries() or {}) do
			if tag ~= ctx.tag then
				items[#items + 1] = {
					key = tag,
					label = country.displayName or tag,
					searchText = ((country.displayName or "") .. " " .. tag):lower(),
					icon = "Diplomacy",
				}
			end
		end
		table.sort(items, function(a, b)
			return a.label < b.label
		end)
		return items
	end
	local function goodItems()
		local items = {}
		for id, def in pairs(goods) do
			if type(def) == "table" and def.id then
				items[#items + 1] = {
					key = id,
					label = string.format(
						"%s  \u{00B7}  %s",
						def.displayName or prettify(id),
						money(def.basePrice or 0)
					),
					searchText = ((def.displayName or id) .. " " .. (def.category or "")):lower(),
					icon = "Goods",
				}
			end
		end
		table.sort(items, function(a, b)
			return a.label < b.label
		end)
		return items
	end

	local modal = Modal.create({
		parent = ctx.modalLayer or ctx.parent,
		title = "Trade",
		subtitle = "Buy or sell resources for gold",
		width = 480,
		height = 560,
		footer = true,
	})

	local body = Instance.new("ScrollingFrame")
	body.Size = UDim2.fromScale(1, 1)
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.ScrollBarThickness = 4
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.CanvasSize = UDim2.new()
	body.Parent = modal.content
	local bodyPad = Instance.new("UIPadding")
	bodyPad.PaddingRight = UDim.new(0, 8)
	bodyPad.Parent = body
	local bodyLayout = Instance.new("UIListLayout")
	bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bodyLayout.Padding = UDim.new(0, 6)
	bodyLayout.Parent = body

	local sendBtn
	local renderBody

	local function dirButton(parent, key, text)
		Button.create({
			parent = parent,
			variant = state.direction == key and "primary" or "secondary",
			text = text,
			onClick = function()
				state.direction = key
				renderBody()
			end,
		})
	end

	local function modeButton(parent, recurring, text)
		Button.create({
			parent = parent,
			variant = state.recurring == recurring and "primary" or "secondary",
			text = text,
			onClick = function()
				state.recurring = recurring
				renderBody()
			end,
		})
	end

	function renderBody()
		for _, child in body:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end

		ScreenKit.section(body, "Trade Partner", 1)
		local partnerRow = ScreenKit.stat(body, {
			icon = "Diplomacy",
			label = "Nation: " .. (state.partnerName or "(choose)"),
			layoutOrder = 2,
		})
		local chooseBtn = Button.create({
			parent = partnerRow,
			variant = "secondary",
			text = "Choose",
			width = 96,
			size = "sm",
			onClick = function()
				openSearchPicker(ctx, "Select Nation", countryItems(), function(item)
					state.partnerTag = item.key
					state.partnerName = item.label
					renderBody()
				end)
			end,
		})
		chooseBtn.AnchorPoint = Vector2.new(1, 0.5)
		chooseBtn.Position = UDim2.fromScale(1, 0.5)

		ScreenKit.section(body, "Direction", 10)
		local dirRow = ScreenKit.buttonRow(body, 11)
		dirButton(dirRow, "buy", "Buy")
		dirButton(dirRow, "sell", "Sell")
		ScreenKit.note(
			body,
			state.direction == "buy" and "You pay gold and receive the resources."
				or "You give the resources and receive gold.",
			12
		)

		ScreenKit.section(body, "Resources", 20)
		if #state.lines == 0 then
			ScreenKit.note(body, "No resources yet \u{2014} add one below.", 21)
		end
		for i, line in ipairs(state.lines) do
			local base = 22 + i * 4
			ScreenKit.stat(body, {
				icon = "Goods",
				label = goodName(line.goodId),
				value = string.format(
					"\u{00D7}%d  \u{00B7}  %s",
					line.amount,
					money(line.amount * basePrice(line.goodId) * state.multiplier)
				),
				mono = true,
				layoutOrder = base,
			})
			local row = ScreenKit.buttonRow(body, base + 1)
			Button.create({
				parent = row,
				variant = "ghost",
				text = "\u{2212}",
				width = 44,
				size = "sm",
				onClick = function()
					line.amount = math.max(1, line.amount - 1)
					renderBody()
				end,
			})
			Button.create({
				parent = row,
				variant = "ghost",
				text = "+",
				width = 44,
				size = "sm",
				onClick = function()
					line.amount += 1
					renderBody()
				end,
			})
			Button.create({
				parent = row,
				variant = "danger",
				text = "Remove",
				width = 84,
				size = "sm",
				onClick = function()
					table.remove(state.lines, i)
					renderBody()
				end,
			})
		end
		local addRow = ScreenKit.buttonRow(body, 45)
		Button.create({
			parent = addRow,
			variant = "secondary",
			text = "Add Resource",
			onClick = function()
				openSearchPicker(ctx, "Add Resource", goodItems(), function(item)
					if not hasLine(item.key) then
						table.insert(state.lines, { goodId = item.key, amount = 1 })
					end
					renderBody()
				end)
			end,
		})

		ScreenKit.section(body, "Price Multiplier", 50)
		ScreenKit.stat(body, {
			icon = "Trade",
			label = "Multiplier",
			value = string.format("\u{00D7}%.2f", state.multiplier),
			mono = true,
			layoutOrder = 51,
		})
		local multRow = ScreenKit.buttonRow(body, 52)
		Button.create({
			parent = multRow,
			variant = "ghost",
			text = "\u{2212}",
			width = 60,
			size = "sm",
			onClick = function()
				state.multiplier = math.max(MULT_MIN, math.floor((state.multiplier - MULT_STEP) * 100 + 0.5) / 100)
				renderBody()
			end,
		})
		Button.create({
			parent = multRow,
			variant = "ghost",
			text = "+",
			width = 60,
			size = "sm",
			onClick = function()
				state.multiplier = math.min(MULT_MAX, math.floor((state.multiplier + MULT_STEP) * 100 + 0.5) / 100)
				renderBody()
			end,
		})

		ScreenKit.section(body, "Mode", 60)
		local modeRow = ScreenKit.buttonRow(body, 61)
		modeButton(modeRow, false, "One-time")
		modeButton(modeRow, true, "Recurring (5 days)")

		ScreenKit.section(body, "Summary", 70)
		ScreenKit.stat(body, {
			icon = "Treasury",
			label = state.direction == "buy" and "You pay" or "You receive",
			value = money(total()),
			valueColor = state.direction == "buy" and "negative" or "positive",
			mono = true,
			layoutOrder = 71,
		})

		if sendBtn then
			sendBtn.Active = state.partnerTag ~= nil and #state.lines > 0
		end
	end

	Button.create({
		parent = modal.footer,
		variant = "ghost",
		text = "Cancel",
		layoutOrder = 1,
		onClick = function()
			modal.close()
		end,
	})
	sendBtn = Button.create({
		parent = modal.footer,
		variant = "primary",
		text = "Send Offer",
		layoutOrder = 2,
		disabled = true,
		onClick = function()
			if not (state.partnerTag and #state.lines > 0) then
				return
			end
			local lines = {}
			for _, line in ipairs(state.lines) do
				lines[#lines + 1] = { goodId = line.goodId, amount = line.amount }
			end
			ctx.fire("PlaceTradeOrder", state.partnerTag, state.direction, lines, state.multiplier, state.recurring)
			modal.close()
		end,
	})

	renderBody()
	return modal
end

return TradeProposal
