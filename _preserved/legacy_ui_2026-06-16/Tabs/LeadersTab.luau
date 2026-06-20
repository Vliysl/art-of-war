local ReplicatedStorage = game:GetService("ReplicatedStorage")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))

local LeadersTab = {}

local function traitLine(bundle, traitIds)
	if not traitIds or #traitIds == 0 then return "" end
	local parts = {}
	for _, id in traitIds do
		local trait = bundle and bundle.leaderTraits and bundle.leaderTraits[id]
		table.insert(parts, trait and trait.displayName or id)
	end
	return table.concat(parts, ", ")
end

local function orderedSlots(bundle)
	local list = {}
	if not bundle or not bundle.leaderSlots then return list end
	for id, slot in bundle.leaderSlots do
		table.insert(list, { id = id, def = slot })
	end
	table.sort(list, function(a, b) return (a.def.order or 0) < (b.def.order or 0) end)
	return list
end

function LeadersTab.mount(page, fireDismiss, fireAppoint)
	local list, _ = UIBuilder.scrollingList(page, { Size = UDim2.fromScale(1, 1) })

	return {
		update = function(country, bundle)
			for _, child in list:GetChildren() do
				if child:IsA("Frame") then child:Destroy() end
			end
			if not country or not bundle then return end

			for i, entry in orderedSlots(bundle) do
				if entry.def.unlockedByDefault == false then continue end
				local leader = country.leaders and country.leaders[entry.id]
				local candidates = country.leaderCandidates and country.leaderCandidates[entry.id]

				local card = Instance.new("Frame")
				card.Size = UDim2.new(1, -4, 0, 82)
				card.BackgroundColor3 = UIStyle.Color.ParchmentDark
				card.BackgroundTransparency = 0
				card.BorderSizePixel = 0
				card.LayoutOrder = i
				card.ZIndex = UIStyle.Z.Content
				card.Parent = list
				UIBuilder.corner(card, 2)
				UIBuilder.stroke(card, 1, UIStyle.Color.WoodFrameLight)

				UIBuilder.tooltip(card, function()
					local rows = { { header = entry.def.displayName or entry.id } }
					if entry.def.description then
						table.insert(rows, { body = entry.def.description })
					end
					if leader then
						if leader.title then
							table.insert(rows, { label = "Title", value = leader.title })
						end
						if leader.traits and #leader.traits > 0 then
							table.insert(rows, { label = "Traits", value = traitLine(bundle, leader.traits) })
						end
					else
						table.insert(rows, { body = "Seat is vacant. Appoint from your candidate pool." })
					end
					return rows
				end)

				UIBuilder.label(card, entry.def.displayName or entry.id, UIStyle.Type.SectionHeader, UIStyle.Color.InkMuted, {
					Size = UDim2.new(1, -120, 0, 18),
					Position = UDim2.fromOffset(8, 4),
					TextSize = 13,
				})

				if leader then
					local titleText = leader.title and string.format("%s %s %s", leader.title, leader.firstName or "", leader.lastName or "") or leader.id
					UIBuilder.label(card, titleText, UIStyle.Type.StatValue, UIStyle.Color.Ink, {
						Size = UDim2.new(1, -16, 0, 18),
						Position = UDim2.fromOffset(8, 22),
						TextSize = 14,
					})
					UIBuilder.label(card, traitLine(bundle, leader.traits), UIStyle.Type.Small, UIStyle.Color.InkMuted, {
						Size = UDim2.new(1, -16, 0, 32),
						Position = UDim2.fromOffset(8, 42),
						TextWrapped = true,
					})

					local btn = UIBuilder.button(card, {
						Size = UDim2.fromOffset(96, 22),
						Position = UDim2.new(1, -8, 0, 6),
						AnchorPoint = Vector2.new(1, 0),
						Text = "Dismiss",
					})
					btn.MouseButton1Click:Connect(function()
						if fireDismiss then fireDismiss(entry.id) end
					end)
				else
					UIBuilder.label(card, "Vacant", UIStyle.Type.StatValue, UIStyle.Color.StateBad, {
						Size = UDim2.new(1, -16, 0, 18),
						Position = UDim2.fromOffset(8, 22),
						TextSize = 14,
					})
					local candidateCount = 0
					if candidates then for _ in candidates do candidateCount += 1 end end
					UIBuilder.label(card, candidateCount > 0 and string.format("%d candidates available", candidateCount) or "Awaiting candidates", UIStyle.Type.Small, UIStyle.Color.InkMuted, {
						Size = UDim2.new(1, -16, 0, 18),
						Position = UDim2.fromOffset(8, 42),
					})
					if candidateCount > 0 then
						local btn = UIBuilder.button(card, {
							Size = UDim2.fromOffset(96, 22),
							Position = UDim2.new(1, -8, 0, 6),
							AnchorPoint = Vector2.new(1, 0),
							Text = "Appoint #1",
						}, true)
						btn.MouseButton1Click:Connect(function()
							if fireAppoint then fireAppoint(entry.id, 1) end
						end)
					end
				end
			end
		end,
	}
end

return LeadersTab
