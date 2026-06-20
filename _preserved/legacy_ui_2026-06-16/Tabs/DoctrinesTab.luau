local ReplicatedStorage = game:GetService("ReplicatedStorage")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))

local DoctrinesTab = {}

local TIER_LABEL = { [1] = "I — Base", [2] = "II — Standard", [3] = "III — Advanced" }

local function prettyDomain(domain)
	return (domain:gsub("_", " ")):gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b:lower() end)
end

local function formatModifier(domain, value)
	local pretty = prettyDomain(domain)
	if domain == "army_organization" then
		local sign = value > 0 and "+" or ""
		return string.format("%s: %s%.1f", pretty, sign, value)
	end
	local sign = value > 0 and "+" or ""
	return string.format("%s: %s%.0f%%", pretty, sign, value * 100)
end

local function slotsSortedByOrder(slotsTable)
	local list = {}
	for id, def in slotsTable do table.insert(list, { id = id, def = def }) end
	table.sort(list, function(a, b)
		if a.def.tier ~= b.def.tier then return (a.def.tier or 0) < (b.def.tier or 0) end
		return (a.def.order or 0) < (b.def.order or 0)
	end)
	return list
end

local function doctrinesForSlot(doctrines, slotId)
	local list = {}
	for id, def in doctrines do
		if def.slot == slotId then table.insert(list, { id = id, def = def }) end
	end
	table.sort(list, function(a, b) return (a.def.displayName or a.id) < (b.def.displayName or b.id) end)
	return list
end

function DoctrinesTab.mount(page, fireSetDoctrine)
	local list, _ = UIBuilder.scrollingList(page, { Size = UDim2.fromScale(1, 1) })

	return {
		update = function(country, bundle)
			for _, child in list:GetChildren() do
				if child:IsA("Frame") then child:Destroy() end
			end
			if not country or not bundle or not bundle.doctrines or not bundle.doctrineSlots then return end

			local active = country.doctrines or {}
			local orderCounter = 0
			for _, slotEntry in slotsSortedByOrder(bundle.doctrineSlots) do
				local slotId = slotEntry.id
				local slotDef = slotEntry.def
				orderCounter += 1

				local slotHeader = Instance.new("Frame")
				slotHeader.Size = UDim2.new(1, -4, 0, 28)
				slotHeader.BackgroundColor3 = UIStyle.Color.Bg
				slotHeader.BorderSizePixel = 0
				slotHeader.LayoutOrder = orderCounter
				slotHeader.ZIndex = UIStyle.Z.Content
				slotHeader.Parent = list
				UIBuilder.corner(slotHeader, 2)

				local tierLabel = TIER_LABEL[slotDef.tier] or ""
				UIBuilder.label(slotHeader, string.format("%s  ·  Tier %s", slotDef.displayName or slotId, tierLabel),
					UIStyle.Type.SectionHeader, UIStyle.Color.Gold, {
						Size = UDim2.new(1, -120, 1, 0),
						Position = UDim2.fromOffset(10, 0),
						TextSize = 12,
					})

				if slotDef.unlockedByDefault == false then
					UIBuilder.label(slotHeader, "LOCKED", UIStyle.Type.Small, UIStyle.Color.TextDim, {
						Size = UDim2.fromOffset(100, 20),
						Position = UDim2.new(1, -10, 0.5, 0),
						AnchorPoint = Vector2.new(1, 0.5),
						TextXAlignment = Enum.TextXAlignment.Right,
					})
				end

				local slotOptions = doctrinesForSlot(bundle.doctrines, slotId)
				for _, entry in slotOptions do
					orderCounter += 1
					local isActive = active[slotId] == entry.id
					local card = Instance.new("Frame")
					card.Size = UDim2.new(1, -4, 0, 112)
					card.BackgroundColor3 = isActive and UIStyle.Color.Panel or UIStyle.Color.PanelAlt
					card.BackgroundTransparency = isActive and 0.05 or 0.35
					card.BorderSizePixel = 0
					card.ClipsDescendants = true
					card.LayoutOrder = orderCounter
					card.ZIndex = UIStyle.Z.Content
					card.Parent = list
					UIBuilder.corner(card, 3)
					UIBuilder.stroke(card, isActive and 2 or 1, isActive and UIStyle.Color.Gold or UIStyle.Color.Border)

					UIBuilder.label(card, entry.def.displayName or entry.id, UIStyle.Type.SectionHeader, UIStyle.Color.Text, {
						Size = UDim2.new(1, -140, 0, 22),
						Position = UDim2.fromOffset(10, 8),
						TextSize = 15,
					})

					if entry.def.description then
						UIBuilder.label(card, entry.def.description, UIStyle.Type.Small, UIStyle.Color.TextMuted, {
							Size = UDim2.new(1, -18, 0, 28),
							Position = UDim2.fromOffset(10, 32),
							TextWrapped = true,
						})
					end

					local parts = {}
					if entry.def.modifiers then
						for domain, value in entry.def.modifiers do
							if value ~= 0 then table.insert(parts, formatModifier(domain, value)) end
						end
					end
					table.sort(parts)
					UIBuilder.label(card, table.concat(parts, "  \u{2022}  "), UIStyle.Type.Small, UIStyle.Color.Text, {
						Size = UDim2.new(1, -18, 0, 30),
						Position = UDim2.fromOffset(10, 62),
						TextWrapped = true,
					})

					UIBuilder.tooltip(card, function()
						local rows = { { header = entry.def.displayName or entry.id } }
						if entry.def.description then table.insert(rows, { body = entry.def.description }) end
						for _, p in parts do table.insert(rows, { body = p }) end
						table.insert(rows, { label = "Slot", value = slotDef.displayName or slotId })
						table.insert(rows, { label = "Tier", value = tostring(slotDef.tier or "?") })
						if isActive then
							table.insert(rows, { body = "Currently active for this slot." })
						else
							table.insert(rows, { body = "Adopt to replace the current " .. (slotDef.displayName or slotId) .. "." })
						end
						return rows
					end)

					if isActive then
						UIBuilder.label(card, "ACTIVE", UIStyle.Type.Small, UIStyle.Color.Good, {
							Size = UDim2.fromOffset(110, 24),
							Position = UDim2.new(1, -10, 0, 10),
							AnchorPoint = Vector2.new(1, 0),
							TextXAlignment = Enum.TextXAlignment.Right,
							Font = UIStyle.Font.Bold,
						})
					else
						local btn = UIBuilder.button(card, {
							Size = UDim2.fromOffset(110, 26),
							Position = UDim2.new(1, -10, 0, 8),
							AnchorPoint = Vector2.new(1, 0),
							Text = "Adopt",
						}, true)
						btn.MouseButton1Click:Connect(function()
							if fireSetDoctrine then fireSetDoctrine(entry.id) end
						end)
					end
				end
			end
		end,
	}
end

return DoctrinesTab
