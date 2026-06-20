local ReplicatedStorage = game:GetService("ReplicatedStorage")

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local uiFolder = aow:WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))
local Platform = require(aow:WaitForChild("Modules"):WaitForChild("Platform"))
local DebugMode = require(aow:WaitForChild("Modules"):WaitForChild("DebugMode"))
local ClientStateCache = require(aow:WaitForChild("Modules"):WaitForChild("ClientStateCache"))
local NavalMissions = require(aow:WaitForChild("Data"):WaitForChild("NavalMissions"))

local FleetPanel = {}

local FLEET_PANEL_H = 168

local function shipBreakdown(fleet)
	local counts = {}
	for _, ship in ipairs(fleet.ships or {}) do
		counts[ship.typeId] = (counts[ship.typeId] or 0) + 1
	end
	return counts
end

local function titleCase(text)
	if not text then return "" end
	return (text:gsub("_", " ")):gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b:lower() end)
end

function FleetPanel.create(parent, callbacks)
	callbacks = callbacks or {}

	local panel = UIBuilder.panel(parent, {
		Name = "FleetPanel",
		Size = UDim2.fromOffset(UIStyle.Size.ArmyPanelW, FLEET_PANEL_H),
		Position = UDim2.new(1, -14, 1, -(FLEET_PANEL_H + 24)),
		AnchorPoint = Vector2.new(1, 1),
		Visible = false,
	})

	UIBuilder.sectionHeader(panel, "Fleet", 0)

	local body = Instance.new("Frame")
	body.Size = UDim2.new(1, -UIStyle.Size.PanelPaddingX * 2, 1, -(UIStyle.Size.SectionHeaderH + UIStyle.Size.PanelPaddingY * 2))
	body.Position = UDim2.fromOffset(UIStyle.Size.PanelPaddingX, UIStyle.Size.SectionHeaderH + UIStyle.Size.PanelPaddingY)
	body.BackgroundTransparency = 1
	body.ZIndex = UIStyle.Z.Content
	body.Parent = panel

	local title = UIBuilder.label(body, "-", UIStyle.Type.StatValue, UIStyle.Color.Ink, {
		Size = UDim2.new(1, 0, 0, 22),
		Position = UDim2.fromOffset(0, 0),
		TextSize = 16,
	})

	local location = UIBuilder.label(body, "-", UIStyle.Type.Body, UIStyle.Color.InkMuted, {
		Size = UDim2.new(1, 0, 0, 18),
		Position = UDim2.fromOffset(0, 24),
	})

	local moraleBarBg = Instance.new("Frame")
	moraleBarBg.Size = UDim2.new(1, 0, 0, 8)
	moraleBarBg.Position = UDim2.fromOffset(0, 46)
	moraleBarBg.BackgroundColor3 = UIStyle.Color.WoodFrame
	moraleBarBg.BorderSizePixel = 0
	moraleBarBg.ZIndex = UIStyle.Z.Content
	moraleBarBg.Parent = body
	UIBuilder.corner(moraleBarBg, 2)

	local moraleFill = Instance.new("Frame")
	moraleFill.Size = UDim2.fromScale(1, 1)
	moraleFill.BackgroundColor3 = UIStyle.Color.Gold
	moraleFill.BorderSizePixel = 0
	moraleFill.ZIndex = UIStyle.Z.Content + 1
	moraleFill.Parent = moraleBarBg
	UIBuilder.corner(moraleFill, 2)

	local composition = Instance.new("Frame")
	composition.Size = UDim2.new(1, 0, 0, 74)
	composition.Position = UDim2.fromOffset(0, 62)
	composition.BackgroundTransparency = 1
	composition.ZIndex = UIStyle.Z.Content
	composition.Parent = body

	local compLayout = Instance.new("UIListLayout")
	compLayout.FillDirection = Enum.FillDirection.Vertical
	compLayout.Padding = UDim.new(0, 2)
	compLayout.SortOrder = Enum.SortOrder.LayoutOrder
	compLayout.Parent = composition

	local actionBar = Instance.new("Frame")
	actionBar.Size = UDim2.new(1, 0, 0, 30)
	actionBar.Position = UDim2.new(0, 0, 1, 0)
	actionBar.AnchorPoint = Vector2.new(0, 1)
	actionBar.BackgroundTransparency = 1
	actionBar.ZIndex = UIStyle.Z.Content
	actionBar.Parent = body

	local actionLayout = Instance.new("UIListLayout")
	actionLayout.FillDirection = Enum.FillDirection.Horizontal
	actionLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	actionLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	actionLayout.Padding = UDim.new(0, 6)
	actionLayout.Parent = actionBar

	local missionBtn = UIBuilder.button(actionBar, {
		Size = UDim2.fromOffset(Platform.isTouch and 96 or 80, Platform.isTouch and 36 or 26),
		Text = "Mission",
		LayoutOrder = 0,
	})
	local moveBtn = UIBuilder.button(actionBar, {
		Size = UDim2.fromOffset(Platform.isTouch and 96 or 80, Platform.isTouch and 36 or 26),
		Text = "Sail",
		LayoutOrder = 1,
	})
	local attackBtn = UIBuilder.button(actionBar, {
		Size = UDim2.fromOffset(Platform.isTouch and 96 or 80, Platform.isTouch and 36 or 26),
		Text = "Engage",
		LayoutOrder = 2,
	}, true)
	local disbandBtn = UIBuilder.button(actionBar, {
		Size = UDim2.fromOffset(Platform.isTouch and 96 or 80, Platform.isTouch and 36 or 26),
		Text = "Disband",
		LayoutOrder = 3,
	})

	local function buildMissionTooltip(missionId)
		local def = NavalMissions.get(missionId)
		if not def then return "" end
		local lines = {}
		table.insert(lines, def.displayName or missionId)
		if type(def.description) == "string" and def.description ~= "" then
			table.insert(lines, def.description)
		end
		local effects = {}
		local treasury = def.treasuryEffectPerTick or 0
		if treasury ~= 0 then
			local sign = treasury > 0 and "+" or ""
			local target = def.treasuryEffectGoesToMission and "you" or (treasury < 0 and "target" or "you")
			table.insert(effects, string.format("%s%.1f treasury/tick → %s", sign, treasury, target))
		end
		local morale = def.moraleDrainPerTick or 0
		if morale > 0 then
			table.insert(effects, string.format("-%.1f morale/tick", morale))
		end
		local infamy = def.infamyPerTick or 0
		if infamy > 0 then
			table.insert(effects, string.format("+%.2f infamy/tick", infamy))
		end
		if #effects > 0 then table.insert(lines, table.concat(effects, "  ·  ")) end
		local reqs = {}
		if (def.minDuration or 0) > 0 then table.insert(reqs, string.format("min %d ticks", def.minDuration)) end
		if def.requiresAdjacentTarget then table.insert(reqs, "must be coastal-adjacent") end
		if def.requiresPaired then table.insert(reqs, "needs friendly fleet target") end
		if def.requiresTargetFleet then table.insert(reqs, "needs hostile fleet target") end
		if #reqs > 0 then table.insert(lines, "Req: " .. table.concat(reqs, ", ")) end
		return table.concat(lines, string.char(10))
	end

	local missionPopup = Instance.new("Frame")
	missionPopup.Name = "MissionPopup"
	missionPopup.Size = UDim2.fromOffset(340, 196)
	missionPopup.Position = UDim2.new(1, -4, 0, 26)
	missionPopup.AnchorPoint = Vector2.new(1, 0)
	missionPopup.BackgroundColor3 = UIStyle.Color.WoodFrame or Color3.fromRGB(34, 28, 20)
	missionPopup.BorderSizePixel = 0
	missionPopup.ZIndex = UIStyle.Z.Content + 8
	missionPopup.Visible = false
	missionPopup.Parent = body
	UIBuilder.corner(missionPopup, 3)
	local popupStroke = Instance.new("UIStroke")
	popupStroke.Color = UIStyle.Color.Border or Color3.fromRGB(142, 84, 24)
	popupStroke.Thickness = 1
	popupStroke.Parent = missionPopup

	local popupPad = Instance.new("UIPadding")
	popupPad.PaddingTop = UDim.new(0, 8)
	popupPad.PaddingBottom = UDim.new(0, 8)
	popupPad.PaddingLeft = UDim.new(0, 10)
	popupPad.PaddingRight = UDim.new(0, 10)
	popupPad.Parent = missionPopup

	local missionStatusLbl = UIBuilder.label(missionPopup, "No mission", UIStyle.Type.Small, UIStyle.Color.InkMuted, {
		Size = UDim2.new(1, 0, 0, 18),
		Position = UDim2.fromOffset(0, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	missionStatusLbl.ZIndex = missionPopup.ZIndex + 1

	local missionGrid = Instance.new("Frame")
	missionGrid.Size = UDim2.new(1, 0, 0, 86)
	missionGrid.Position = UDim2.fromOffset(0, 22)
	missionGrid.BackgroundTransparency = 1
	missionGrid.ZIndex = missionPopup.ZIndex + 1
	missionGrid.Parent = missionPopup

	local missionGridLayout = Instance.new("UIGridLayout")
	missionGridLayout.CellSize = UDim2.fromOffset(100, 26)
	missionGridLayout.CellPadding = UDim2.fromOffset(4, 4)
	missionGridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	missionGridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	missionGridLayout.Parent = missionGrid

	local missionTooltip = Instance.new("TextLabel")
	missionTooltip.Name = "MissionTooltip"
	missionTooltip.Size = UDim2.new(1, 0, 0, 56)
	missionTooltip.Position = UDim2.fromOffset(0, 116)
	missionTooltip.BackgroundColor3 = UIStyle.Color.PanelInk or Color3.fromRGB(20, 16, 10)
	missionTooltip.BackgroundTransparency = 0.35
	missionTooltip.BorderSizePixel = 0
	missionTooltip.Text = "Hover a mission for details."
	missionTooltip.TextColor3 = UIStyle.Color.InkMuted or Color3.fromRGB(180, 160, 120)
	missionTooltip.Font = UIStyle.Font.Regular or Enum.Font.Gotham
	missionTooltip.TextSize = 11
	missionTooltip.TextWrapped = true
	missionTooltip.TextXAlignment = Enum.TextXAlignment.Left
	missionTooltip.TextYAlignment = Enum.TextYAlignment.Top
	missionTooltip.RichText = false
	missionTooltip.ZIndex = missionPopup.ZIndex + 1
	missionTooltip.Parent = missionPopup
	local tooltipCorner = Instance.new("UICorner")
	tooltipCorner.CornerRadius = UDim.new(0, 2)
	tooltipCorner.Parent = missionTooltip
	local tooltipPad = Instance.new("UIPadding")
	tooltipPad.PaddingLeft = UDim.new(0, 6)
	tooltipPad.PaddingRight = UDim.new(0, 6)
	tooltipPad.PaddingTop = UDim.new(0, 4)
	tooltipPad.PaddingBottom = UDim.new(0, 4)
	tooltipPad.Parent = missionTooltip

	local missionBtnSpecs = {
		{ id = "patrol",    text = "Patrol",    target = nil },
		{ id = "raid",      text = "Raid",      target = nil },
		{ id = "blockade",  text = "Blockade",  target = "province" },
		{ id = "transport", text = "Transport", target = "friendlyFleet" },
		{ id = "escort",    text = "Escort",    target = "friendlyFleet" },
		{ id = "intercept", text = "Intercept", target = "enemyFleet" },
	}

	local missionButtons = {}
	for i, spec in ipairs(missionBtnSpecs) do
		local btn = UIBuilder.button(missionGrid, { Text = spec.text, LayoutOrder = i })
		btn.ZIndex = missionPopup.ZIndex + 2
		missionButtons[spec.id] = btn
		btn.MouseEnter:Connect(function()
			missionTooltip.Text = buildMissionTooltip(spec.id)
		end)
		btn.MouseLeave:Connect(function()
			missionTooltip.Text = "Hover a mission for details."
		end)
	end

	local clearMissionBtn = UIBuilder.button(missionPopup, {
		Size = UDim2.fromOffset(100, 26),
		Position = UDim2.new(1, 0, 0, 116 + 56 + 2),
		AnchorPoint = Vector2.new(1, 1),
		Text = "Clear",
	})
	clearMissionBtn.ZIndex = missionPopup.ZIndex + 2
	clearMissionBtn.MouseEnter:Connect(function()
		missionTooltip.Text = "Cancel any active mission and return to free roam."
	end)
	clearMissionBtn.MouseLeave:Connect(function()
		missionTooltip.Text = "Hover a mission for details."
	end)

	local currentFleetId = nil

	missionBtn.MouseButton1Click:Connect(function()
		missionPopup.Visible = not missionPopup.Visible
	end)

	for _, spec in ipairs(missionBtnSpecs) do
		local btn = missionButtons[spec.id]
		if btn then
			btn.MouseButton1Click:Connect(function()
				if not currentFleetId then return end
				if spec.target == nil then
					if callbacks.onMissionAssign then
						callbacks.onMissionAssign(currentFleetId, spec.id, 0)
						missionPopup.Visible = false
					end
				else
					if callbacks.onMissionPick then
						callbacks.onMissionPick(currentFleetId, spec.id, spec.target)
						missionPopup.Visible = false
					end
				end
			end)
		end
	end

	clearMissionBtn.MouseButton1Click:Connect(function()
		if callbacks.onMissionClear and currentFleetId then
			callbacks.onMissionClear(currentFleetId)
			missionPopup.Visible = false
		end
	end)

	moveBtn.MouseButton1Click:Connect(function()
		if callbacks.onMoveMode then callbacks.onMoveMode(currentFleetId) end
	end)
	attackBtn.MouseButton1Click:Connect(function()
		if callbacks.onAttackMode then callbacks.onAttackMode(currentFleetId) end
	end)
	disbandBtn.MouseButton1Click:Connect(function()
		if callbacks.onDisband and currentFleetId then callbacks.onDisband(currentFleetId) end
	end)

	local function show(fleet, shipTypes, provinceName)
		if not fleet then
			panel.Visible = false
			currentFleetId = nil
			return
		end
		currentFleetId = fleet.id
		panel.Visible = true
		local ownerCountry = fleet.ownerTag and ClientStateCache.getCountry(fleet.ownerTag) or nil
		title.Text = string.format("%s Fleet", DebugMode.formatCountry(fleet.ownerTag, ownerCountry))

		if fleet.status == "moving" then
			location.Text = string.format("Sailing: %s \u{2192} %s", provinceName or fleet.provinceId, fleet.destination)
		elseif fleet.status == "battle" then
			location.Text = string.format("Engaged at %s", provinceName or fleet.provinceId)
		else
			location.Text = string.format("Docked at %s", provinceName or fleet.provinceId)
		end

		local moralePct = math.clamp((fleet.morale or 0) / 100, 0, 1)
		moraleFill.Size = UDim2.fromScale(moralePct, 1)
		if moralePct > 0.6 then
			moraleFill.BackgroundColor3 = UIStyle.Color.StateGood
		elseif moralePct > 0.3 then
			moraleFill.BackgroundColor3 = UIStyle.Color.Gold
		else
			moraleFill.BackgroundColor3 = UIStyle.Color.StateBad
		end

		for _, child in composition:GetChildren() do
			if child:IsA("Frame") then child:Destroy() end
		end

		local counts = shipBreakdown(fleet)
		local index = 0
		for shipId, count in pairs(counts) do
			if count > 0 then
				index += 1
				local spec = shipTypes and shipTypes[shipId]
				local row = Instance.new("Frame")
				row.Size = UDim2.new(1, 0, 0, 18)
				row.BackgroundTransparency = 1
				row.LayoutOrder = index
				row.ZIndex = UIStyle.Z.Content
				row.Parent = composition

				UIBuilder.label(row, spec and spec.displayName or titleCase(shipId), UIStyle.Type.Small, UIStyle.Color.Ink, {
					Size = UDim2.new(0.7, 0, 1, 0),
					Position = UDim2.fromOffset(0, 0),
				})
				UIBuilder.label(row, string.format("x%d", count), UIStyle.Type.StatValue, UIStyle.Color.Ink, {
					Size = UDim2.new(0.3, 0, 1, 0),
					Position = UDim2.new(1, 0, 0, 0),
					AnchorPoint = Vector2.new(1, 0),
					TextXAlignment = Enum.TextXAlignment.Right,
					TextSize = 14,
				})
			end
		end

		attackBtn.Active = fleet.status == "docked"
		moveBtn.Active = fleet.status == "docked"

		local mission = fleet.mission
		if type(mission) == "table" and type(mission.type) == "string" then
			local def = NavalMissions.get(mission.type)
			local name = (def and def.displayName) or mission.type
			if mission.targetProvinceId then
				missionStatusLbl.Text = string.format("Active: %s → prov %s", name, tostring(mission.targetProvinceId))
			else
				missionStatusLbl.Text = string.format("Active: %s", name)
			end
			missionStatusLbl.TextColor3 = UIStyle.Color.Gold or UIStyle.Color.Ink
		else
			missionStatusLbl.Text = "No mission"
			missionStatusLbl.TextColor3 = UIStyle.Color.InkMuted or UIStyle.Color.Ink
		end
	end

	local function hide()
		panel.Visible = false
		missionPopup.Visible = false
		currentFleetId = nil
	end

	return {
		root = panel,
		show = show,
		hide = hide,
		getCurrentId = function() return currentFleetId end,
	}
end

return FleetPanel
