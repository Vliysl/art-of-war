local ReplicatedStorage = game:GetService("ReplicatedStorage")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))

local FactionsTab = {}

local function tierColor(tier)
	if tier == "powerful" then return UIStyle.Color.StateGood end
	if tier == "marginalized" then return UIStyle.Color.StateBad end
	return UIStyle.Color.StateNeutral
end

function FactionsTab.mount(page)
	local list, _ = UIBuilder.scrollingList(page, { Size = UDim2.fromScale(1, 1) })

	return {
		update = function(country, bundle)
			for _, child in list:GetChildren() do
				if child:IsA("Frame") then child:Destroy() end
			end
			if not country or not country.factions or not bundle or not bundle.factions then
				UIBuilder.label(list, "No faction data.", UIStyle.Type.Body, UIStyle.Color.InkMuted, {
					Size = UDim2.new(1, 0, 0, 24),
				})
				return
			end

			local ordered = {}
			for id, record in country.factions do
				table.insert(ordered, { id = id, record = record, def = bundle.factions[id] })
			end
			table.sort(ordered, function(a, b) return (a.record.clout or 0) > (b.record.clout or 0) end)

			for i, entry in ordered do
				local card = Instance.new("Frame")
				card.Size = UDim2.new(1, -4, 0, 44)
				card.BackgroundColor3 = UIStyle.Color.ParchmentDark
				card.BackgroundTransparency = 0
				card.BorderSizePixel = 0
				card.LayoutOrder = i
				card.ZIndex = UIStyle.Z.Content
				card.Parent = list
				UIBuilder.corner(card, 2)
				UIBuilder.stroke(card, 1, UIStyle.Color.WoodFrameLight)

				UIBuilder.tooltip(card, function()
					local rows = { { header = entry.def and entry.def.displayName or entry.id } }
					if entry.def and entry.def.description then table.insert(rows, { body = entry.def.description }) end
					table.insert(rows, { label = "Tier", value = entry.record.tier or "influential" })
					table.insert(rows, { label = "Clout", value = string.format("%.0f%%", (entry.record.clout or 0) * 100) })
					if entry.def and entry.def.policyReactions then
						local favored, opposed = {}, {}
						for policyId, weight in entry.def.policyReactions do
							if weight > 0 then
								table.insert(favored, policyId)
							elseif weight < 0 then
								table.insert(opposed, policyId)
							end
						end
						if #favored > 0 then
							table.insert(rows, { label = "Favored", value = table.concat(favored, ", ") })
						end
						if #opposed > 0 then
							table.insert(rows, { label = "Opposed", value = table.concat(opposed, ", ") })
						end
					end
					return rows
				end)

				local name = UIBuilder.label(card, entry.def and entry.def.displayName or entry.id, UIStyle.Type.StatValue, UIStyle.Color.Ink, {
					Size = UDim2.new(0.6, -8, 0, 18),
					Position = UDim2.fromOffset(8, 4),
					TextSize = 14,
				})

				local tierLabel = UIBuilder.label(card, (entry.record.tier or "influential"):upper(), UIStyle.Type.Small, tierColor(entry.record.tier), {
					Size = UDim2.new(0.4, -8, 0, 18),
					Position = UDim2.new(1, -8, 0, 4),
					AnchorPoint = Vector2.new(1, 0),
					TextXAlignment = Enum.TextXAlignment.Right,
				})

				local barBg = Instance.new("Frame")
				barBg.Size = UDim2.new(1, -16, 0, 8)
				barBg.Position = UDim2.fromOffset(8, 26)
				barBg.BackgroundColor3 = UIStyle.Color.WoodFrame
				barBg.BorderSizePixel = 0
				barBg.ZIndex = UIStyle.Z.Content
				barBg.Parent = card
				UIBuilder.corner(barBg, 2)

				local fill = Instance.new("Frame")
				fill.Size = UDim2.fromScale(math.clamp(entry.record.clout or 0, 0, 1), 1)
				fill.BackgroundColor3 = UIStyle.Color.Gold
				fill.BorderSizePixel = 0
				fill.ZIndex = UIStyle.Z.Content + 1
				fill.Parent = barBg
				UIBuilder.corner(fill, 2)

				local pct = UIBuilder.label(card, string.format("%.0f%%", (entry.record.clout or 0) * 100), UIStyle.Type.Small, UIStyle.Color.InkMuted, {
					Size = UDim2.fromOffset(40, 16),
					Position = UDim2.new(1, -8, 0, 22),
					AnchorPoint = Vector2.new(1, 0),
					TextXAlignment = Enum.TextXAlignment.Right,
				})
			end
		end,
	}
end

return FactionsTab
