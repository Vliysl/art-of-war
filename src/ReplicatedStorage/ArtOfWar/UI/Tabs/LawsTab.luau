local ReplicatedStorage = game:GetService("ReplicatedStorage")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))

local LawsTab = {}

function LawsTab.mount(page, fireCancel)
	local list, _ = UIBuilder.scrollingList(page, { Size = UDim2.fromScale(1, 1) })

	return {
		update = function(country, bundle)
			for _, child in list:GetChildren() do
				if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
					child:Destroy()
				end
			end
			if not country then return end

			local pass = country.lawPass
			if not pass then
				UIBuilder.label(list, "No law in progress.", UIStyle.Type.Body, UIStyle.Color.InkMuted, {
					Size = UDim2.new(1, 0, 0, 24),
				})
				UIBuilder.label(list, "Enact a policy from the Policies tab to start the law process.", UIStyle.Type.Small, UIStyle.Color.InkMuted, {
					Size = UDim2.new(1, 0, 0, 32),
					TextWrapped = true,
				})
			else
				local def = bundle and bundle.policies and bundle.policies[pass.policyId]
				local card = Instance.new("Frame")
				card.Size = UDim2.new(1, -4, 0, 112)
				card.BackgroundColor3 = UIStyle.Color.Parchment
				card.BorderSizePixel = 0
				card.ZIndex = UIStyle.Z.Content
				card.Parent = list
				UIBuilder.corner(card, 2)
				UIBuilder.stroke(card, 1, UIStyle.Color.Gold)

				UIBuilder.tooltip(card, function()
					local rows = { { header = def and def.displayName or pass.policyId } }
					if def and def.description then table.insert(rows, { body = def.description }) end
					table.insert(rows, { label = "Phase", value = string.format("%d / 3", pass.phase or 1) })
					table.insert(rows, { label = "PP invested", value = tostring(pass.ppSpent or 0) })
					table.insert(rows, { label = "Setbacks", value = tostring(pass.setbacksTotal or 0) })
					table.insert(rows, { body = "Laws pass in three phases. Each phase burns PP and can suffer setbacks." })
					return rows
				end)

				UIBuilder.label(card, def and def.displayName or pass.policyId, UIStyle.Type.SectionHeader, UIStyle.Color.Ink, {
					Size = UDim2.new(1, -16, 0, 24),
					Position = UDim2.fromOffset(8, 6),
					TextSize = 18,
				})

				local phaseText = string.format("Phase %d of 3  |  Setbacks: %d", pass.phase or 1, pass.setbacksTotal or 0)
				UIBuilder.label(card, phaseText, UIStyle.Type.Body, UIStyle.Color.InkMuted, {
					Size = UDim2.new(1, -16, 0, 18),
					Position = UDim2.fromOffset(8, 32),
				})

				local barBg = Instance.new("Frame")
				barBg.Size = UDim2.new(1, -16, 0, 10)
				barBg.Position = UDim2.fromOffset(8, 54)
				barBg.BackgroundColor3 = UIStyle.Color.WoodFrame
				barBg.BorderSizePixel = 0
				barBg.ZIndex = UIStyle.Z.Content
				barBg.Parent = card
				UIBuilder.corner(barBg, 2)

				local fill = Instance.new("Frame")
				fill.Size = UDim2.fromScale(math.clamp((pass.phase or 1) / 3, 0, 1), 1)
				fill.BackgroundColor3 = UIStyle.Color.Gold
				fill.BorderSizePixel = 0
				fill.ZIndex = UIStyle.Z.Content + 1
				fill.Parent = barBg
				UIBuilder.corner(fill, 2)

				UIBuilder.label(card, string.format("PP invested: %d", pass.ppSpent or 0), UIStyle.Type.Small, UIStyle.Color.InkMuted, {
					Size = UDim2.new(1, -16, 0, 16),
					Position = UDim2.fromOffset(8, 70),
				})

				local cancel = UIBuilder.button(card, {
					Size = UDim2.fromOffset(120, 26),
					Position = UDim2.new(1, -8, 1, -8),
					AnchorPoint = Vector2.new(1, 1),
					Text = "Cancel Law",
				})
				cancel.MouseButton1Click:Connect(function()
					if fireCancel then fireCancel() end
				end)
			end

			local cooldowns = country.lawCooldowns or {}
			local cdList = {}
			for policyId, day in cooldowns do
				table.insert(cdList, { id = policyId, day = day })
			end
			if #cdList > 0 then
				UIBuilder.label(list, "Cooldowns", UIStyle.Type.SectionHeader, UIStyle.Color.InkMuted, {
					Size = UDim2.new(1, 0, 0, 20),
					TextSize = 14,
				})
				for _, cd in cdList do
					local def = bundle and bundle.policies and bundle.policies[cd.id]
					UIBuilder.label(list, string.format("%s — until day %d", def and def.displayName or cd.id, cd.day), UIStyle.Type.Small, UIStyle.Color.InkMuted, {
						Size = UDim2.new(1, 0, 0, 16),
					})
				end
			end
		end,
	}
end

return LawsTab
