local ReplicatedStorage = game:GetService("ReplicatedStorage")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))
local Platform = require(ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Modules"):WaitForChild("Platform"))

local BottomBar = {}

-- Politics merged into the Diplomacy window (country profiles own the
-- government pages now), so it no longer gets its own panel button.
local PANEL_BUTTONS = {
	{ id = "diplomacy", label = "Diplomacy", hint = "V" },
	{ id = "economy",   label = "Economy",   hint = "E" },
	{ id = "research",  label = "Research",  hint = "Y" },
}

function BottomBar.create(parent)
	local bar = Instance.new("Frame")
	bar.Name = "BottomBar"
	bar.Size = UDim2.new(1, 0, 0, UIStyle.Size.BottomBarH)
	bar.Position = UDim2.new(0, 0, 1, 0)
	bar.AnchorPoint = Vector2.new(0, 1)
	bar.BackgroundColor3 = UIStyle.Color.Bg
	bar.BorderSizePixel = 0
	bar.ZIndex = UIStyle.Z.Chrome
	bar.Active = true
	bar:SetAttribute("AoWInputSink", true)
	bar.Parent = parent

	local trim = Instance.new("Frame")
	trim.Size = UDim2.new(1, 0, 0, 1)
	trim.Position = UDim2.fromOffset(0, 0)
	trim.BackgroundColor3 = UIStyle.Color.Gold
	trim.BackgroundTransparency = 0.3
	trim.BorderSizePixel = 0
	trim.ZIndex = UIStyle.Z.Chrome + 1
	trim.Parent = bar

	-- LEFT-aligned panel-button cluster (flush against the left edge)
	local panelBtnsBox = Instance.new("Frame")
	panelBtnsBox.Name = "PanelButtons"
	panelBtnsBox.Size = UDim2.new(0.7, 0, 1, 0)
	panelBtnsBox.Position = UDim2.fromOffset(12, 0)
	panelBtnsBox.BackgroundTransparency = 1
	panelBtnsBox.ZIndex = UIStyle.Z.Chrome + 1
	panelBtnsBox.Parent = bar

	local panelLayout = Instance.new("UIListLayout")
	panelLayout.FillDirection = Enum.FillDirection.Horizontal
	panelLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	panelLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	panelLayout.Padding = UDim.new(0, 8)
	panelLayout.Parent = panelBtnsBox

	local panelButtonRefs = {}
	local onPanelButtonClick = nil

	for i, def in ipairs(PANEL_BUTTONS) do
		local cell = Instance.new("Frame")
		cell.Size = UDim2.fromOffset(150, Platform.isTouch and 40 or 34)
		cell.BackgroundTransparency = 1
		cell.LayoutOrder = i
		cell.Parent = panelBtnsBox

		local cil = UIBuilder.compactIconLabel(cell, {
			Size = UDim2.fromScale(1, 1),
			Text = def.label,
			iconText = Platform.isTouch and "" or def.hint,
			TextSize = 13,
		})
		cil.clicked(function()
			if onPanelButtonClick then onPanelButtonClick(def.id) end
		end)
		panelButtonRefs[def.id] = cil
	end

	-- CENTER: alert chips (kept)
	local centerBox = Instance.new("Frame")
	centerBox.Size = UDim2.fromOffset(360, UIStyle.Size.BottomBarH)
	centerBox.Position = UDim2.fromScale(0.5, 0)
	centerBox.AnchorPoint = Vector2.new(0.5, 0)
	centerBox.BackgroundTransparency = 1
	centerBox.ZIndex = UIStyle.Z.Chrome + 1
	centerBox.Parent = bar

	local centerLayout = Instance.new("UIListLayout")
	centerLayout.FillDirection = Enum.FillDirection.Horizontal
	centerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	centerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	centerLayout.Padding = UDim.new(0, 6)
	centerLayout.Parent = centerBox

	-- RIGHT-side hint strip removed (hints are now inside each button)

	local function pushAlert(text, tone, onClick)
		for _, c in centerBox:GetChildren() do
			if c:IsA("TextButton") and c:GetAttribute("isAlert") then c:Destroy() end
		end
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.fromOffset(140, UIStyle.Size.ChipH)
		btn.BackgroundColor3 = UIStyle.Color.PanelAlt
		btn.BorderSizePixel = 0
		btn.AutoButtonColor = false
		btn.Text = "  " .. tostring(text or "") .. "  "
		btn.TextColor3 = tone or UIStyle.Color.Warn
		btn.Font = UIStyle.Font.Semibold
		btn.TextSize = 11
		btn.ZIndex = UIStyle.Z.Chrome + 2
		btn.Parent = centerBox
		btn:SetAttribute("isAlert", true)
		UIBuilder.corner(btn, UIStyle.Size.CornerPill)
		UIBuilder.stroke(btn, 1, tone or UIStyle.Color.Warn)
		if onClick then
			btn.MouseButton1Click:Connect(onClick)
		end
		return btn
	end

	bar.Visible = false

	return {
		root = bar,
		setVisible = function(flag) bar.Visible = flag and true or false end,
		setCountry = function() end,
		onPanelButtonClicked = function(fn) onPanelButtonClick = fn end,
		setActiveWindow = function(id, isActive)
			local refs = panelButtonRefs[id]
			if refs and refs.setActive then
				refs.setActive(isActive and true or false)
			end
		end,
		setMapMode = function() end,
		getMapMode = function() return nil end,
		onMapModeChanged = function() end,
		pushAlert = pushAlert,
	}
end

return BottomBar
