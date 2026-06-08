local ReplicatedStorage = game:GetService("ReplicatedStorage")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))

local PoliciesTab = {}

local function eligible(country, policy)
	local gate = policy.ideologyGate
	if not gate or gate == "any" then return true end
	return country.ideology == gate
end

function PoliciesTab.mount(page, fireEnact, fireRepeal)
	local list, _ = UIBuilder.scrollingList(page, { Size = UDim2.fromScale(1, 1) })

	return {
		update = function(country, bundle)
			for _, child in list:GetChildren() do
				if child:IsA("Frame") then child:Destroy() end
			end
			if not country or not bundle or not bundle.policies then return end

			local active = country.activePolicies or {}
			local sorted = {}
			for policyId, policy in bundle.policies do
				table.insert(sorted, { id = policyId, def = policy, active = active[policyId] ~= nil })
			end
			table.sort(sorted, function(a, b)
				if a.active ~= b.active then return a.active end
				return (a.def.displayName or a.id) < (b.def.displayName or b.id)
			end)

			local order = 0
			for _, entry in sorted do
				order += 1
				if not eligible(country, entry.def) and not entry.active then continue end

				local card = Instance.new("Frame")
				card.Size = UDim2.new(1, -4, 0, 64)
				card.BackgroundColor3 = entry.active and UIStyle.Color.Parchment or UIStyle.Color.ParchmentDark
				card.BackgroundTransparency = entry.active and 0.1 or 0.35
				card.BorderSizePixel = 0
				card.LayoutOrder = order
				card.ZIndex = UIStyle.Z.Content
				card.Parent = list
				UIBuilder.corner(card, 2)
				UIBuilder.stroke(card, 1, entry.active and UIStyle.Color.Gold or UIStyle.Color.WoodFrameLight)

				UIBuilder.tooltip(card, function()
					local rows = { { header = entry.def.displayName or entry.id } }
					if entry.def.description then
						table.insert(rows, { body = entry.def.description })
					end
					table.insert(rows, { label = "PP cost", value = tostring(entry.def.ppCost or 0) })
					table.insert(rows, { label = "PP upkeep", value = tostring(entry.def.ppUpkeep or 0) })
					if entry.def.ideologyGate and entry.def.ideologyGate ~= "any" then
						table.insert(rows, { label = "Requires ideology", value = entry.def.ideologyGate })
					end
					if entry.def.modifiers then
						for k, v in entry.def.modifiers do
							local sign = (type(v) == "number" and v > 0) and "+" or ""
							table.insert(rows, { label = k, value = sign .. tostring(v) })
						end
					end
					table.insert(rows, { body = entry.active and "Currently enacted. Repeal to free PP upkeep." or "Not enacted. Enact to apply its modifiers." })
					return rows
				end)

				UIBuilder.label(card, entry.def.displayName or entry.id, UIStyle.Type.StatValue, UIStyle.Color.Ink, {
					Size = UDim2.new(1, -110, 0, 20),
					Position = UDim2.fromOffset(8, 4),
					TextSize = 14,
				})

				UIBuilder.label(card, string.format("Cost %d  |  Upkeep %d", entry.def.ppCost or 0, entry.def.ppUpkeep or 0), UIStyle.Type.Small, UIStyle.Color.InkMuted, {
					Size = UDim2.new(1, -110, 0, 16),
					Position = UDim2.fromOffset(8, 24),
				})

				if entry.def.ideologyGate and entry.def.ideologyGate ~= "any" then
					UIBuilder.label(card, string.format("Requires: %s", entry.def.ideologyGate), UIStyle.Type.Small, UIStyle.Color.StateNeutral, {
						Size = UDim2.new(1, -110, 0, 14),
						Position = UDim2.fromOffset(8, 42),
					})
				end

				if entry.active then
					local btn = UIBuilder.button(card, {
						Size = UDim2.fromOffset(96, 26),
						Position = UDim2.new(1, -8, 0, 6),
						AnchorPoint = Vector2.new(1, 0),
						Text = "Repeal",
					})
					btn.MouseButton1Click:Connect(function()
						if fireRepeal then fireRepeal(entry.id) end
					end)
				else
					local btn = UIBuilder.button(card, {
						Size = UDim2.fromOffset(96, 26),
						Position = UDim2.new(1, -8, 0, 6),
						AnchorPoint = Vector2.new(1, 0),
						Text = "Enact",
					}, true)
					btn.MouseButton1Click:Connect(function()
						if fireEnact then fireEnact(entry.id) end
					end)
				end
			end
		end,
	}
end

return PoliciesTab
