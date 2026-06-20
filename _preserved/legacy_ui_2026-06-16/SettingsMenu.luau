local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))
local UIRoot = require(uiFolder:WaitForChild("UIRoot"))
local UISound = require(uiFolder:WaitForChild("UISound"))

local SettingsMenu = {}

local POPOVER_W = 240
local POPOVER_H = 180

-- Toggle pill: a tiny labelled switch
local function makeToggle(parent, label, getter, setter)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -16, 0, 32)
	row.BackgroundTransparency = 1
	row.Parent = parent

	UIBuilder.label(row, label, UIStyle.Type.Body, UIStyle.Color.Text, {
		Size = UDim2.new(1, -56, 1, 0),
		Position = UDim2.fromOffset(0, 0),
		TextSize = 13,
	})

	local sw = Instance.new("TextButton")
	sw.Size = UDim2.fromOffset(44, 22)
	sw.Position = UDim2.new(1, 0, 0.5, 0)
	sw.AnchorPoint = Vector2.new(1, 0.5)
	sw.BackgroundColor3 = UIStyle.Color.PanelAlt
	sw.BorderSizePixel = 0
	sw.AutoButtonColor = false
	sw.Text = ""
	sw.Parent = row
	UIBuilder.corner(sw, 11)
	UIBuilder.stroke(sw, 1, UIStyle.Color.Border)

	local knob = Instance.new("Frame")
	knob.Size = UDim2.fromOffset(16, 16)
	knob.Position = UDim2.fromOffset(3, 3)
	knob.BackgroundColor3 = UIStyle.Color.Text
	knob.BorderSizePixel = 0
	knob.Parent = sw
	UIBuilder.corner(knob, 8)

	local function repaint()
		local on = getter()
		sw.BackgroundColor3 = on and UIStyle.Color.Gold or UIStyle.Color.PanelAlt
		knob.Position = on and UDim2.fromOffset(25, 3) or UDim2.fromOffset(3, 3)
		knob.BackgroundColor3 = on and UIStyle.Color.Bg or UIStyle.Color.Text
	end
	repaint()

	sw.MouseButton1Click:Connect(function()
		setter(not getter())
		repaint()
	end)

	return repaint
end

function SettingsMenu.create(parent, opts)
	opts = opts or {}
	local plr = Players.LocalPlayer

	local popover = UIBuilder.panel(parent, {
		Name = "SettingsMenu",
		Size = UDim2.fromOffset(POPOVER_W, POPOVER_H),
		Position = UDim2.new(1, -10, 0, UIStyle.Size.TopBarH + 8),
		AnchorPoint = Vector2.new(1, 0),
		Visible = false,
		ZIndex = UIStyle.Z.Modal,
	})
	popover.Active = true
	UIRoot.registerScaled(popover)

	local header = Instance.new("Frame")
	header.Size = UDim2.new(1, 0, 0, 28)
	header.BackgroundColor3 = UIStyle.Color.Bg
	header.BorderSizePixel = 0
	header.Parent = popover

	UIBuilder.label(header, "Settings", UIStyle.Type.SectionHeader, UIStyle.Color.Gold, {
		Size = UDim2.new(1, -16, 1, 0),
		Position = UDim2.fromOffset(12, 0),
		Font = UIStyle.Font.Bold,
		TextSize = 13,
	})

	local body = Instance.new("Frame")
	body.Size = UDim2.new(1, 0, 1, -28)
	body.Position = UDim2.fromOffset(0, 28)
	body.BackgroundTransparency = 1
	body.Parent = popover
	UIBuilder.padding(body, 8)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 6)
	layout.Parent = body

	-- 1) Sound on/off
	makeToggle(body, "Sound",
		function()
			local muted = plr:GetAttribute("SoundMuted")
			return muted ~= true
		end,
		function(on)
			plr:SetAttribute("SoundMuted", not on)
			if UISound.setMuted then UISound.setMuted(not on) end
		end
	)

	-- 2) Reduce motion on/off
	makeToggle(body, "Reduce motion",
		function() return UIStyle.ReduceMotion == true end,
		function(on)
			UIStyle.ReduceMotion = on and true or false
			plr:SetAttribute("ReduceMotion", on)
		end
	)

	-- 3) Set Keybinds button
	local kbBtn = UIBuilder.button(body, {
		Size = UDim2.new(1, -16, 0, 32),
		Text = "Set Keybinds...",
	}, false)
	kbBtn.MouseButton1Click:Connect(function()
		if opts.onSetKeybinds then opts.onSetKeybinds() end
		popover.Visible = false
	end)

	local function setVisible(flag)
		popover.Visible = flag and true or false
	end

	local function toggle()
		popover.Visible = not popover.Visible
	end

	return {
		root = popover,
		setVisible = setVisible,
		toggle = toggle,
		isVisible = function() return popover.Visible end,
	}
end

return SettingsMenu
