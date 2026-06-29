local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Shells = DesignSystem.Shells
local Icons = DesignSystem.Icons

local TopBar = {}

-- Engine rate multipliers, shown to the player as rate/4 -> 0.25x, 0.5x, 1x, 2x, 4x. The default rate
-- is 4 ("1x"), so the game runs at the old "4x" pace by default. These stay the REAL rates (sim balance
-- and per-tier system tick rates are unchanged); only the displayed label is divided by 4 (see setTime).
local SPEEDS = { 1, 2, 4, 8, 16 }

function TopBar.create(config)
	config = config or {}
	local z = config.zIndex or 5

	local root = Shells.create("date_speed_shell", {
		Name = "TopBar",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = config.position or UDim2.new(0.5, 0, 0, 12),
		Size = config.size or UDim2.fromOffset(248, 46),
		ZIndex = z,
	})
	root:SetAttribute("AoWInputSink", true)

	local date = Instance.new("TextLabel")
	date.Name = "Date"
	date.AnchorPoint = Vector2.new(0.5, 0.5)
	date.Position = UDim2.fromScale(0.5, 0.5)
	date.Size = UDim2.new(1, -96, 1, 0)
	date.BackgroundTransparency = 1
	date.Text = config.date or ""
	date.TextColor3 = Colors.TextPrimary
	date.TextXAlignment = Enum.TextXAlignment.Center
	date.TextYAlignment = Enum.TextYAlignment.Center
	date.TextTruncate = Enum.TextTruncate.AtEnd
	date.ZIndex = z + 1
	Typography.apply(date, "displayMd")
	date.Parent = root

	-- Pause / resume (left). Time control is admin-gated server-side; HudWiring notifies non-admins.
	local pauseBtn = Instance.new("ImageButton")
	pauseBtn.Name = "Pause"
	pauseBtn.AnchorPoint = Vector2.new(0, 0.5)
	pauseBtn.Position = UDim2.new(0, 12, 0.5, 0)
	pauseBtn.Size = UDim2.fromOffset(26, 26)
	pauseBtn.BackgroundTransparency = 1
	pauseBtn.AutoButtonColor = false
	pauseBtn.Image = ""
	pauseBtn.ZIndex = z + 1
	pauseBtn.Parent = root
	local pauseIcon = Icons.create("Pause", 18, Colors.TextSecondary)
	pauseIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	pauseIcon.Position = UDim2.fromScale(0.5, 0.5)
	pauseIcon.ZIndex = z + 2
	pauseIcon.Parent = pauseBtn

	-- Speed cycle (right): clicking steps through 0.25x -> 0.5x -> 1x -> 2x -> 4x (engine rates 1->2->4->8->16->1).
	local speedBtn = Instance.new("TextButton")
	speedBtn.Name = "Speed"
	speedBtn.AnchorPoint = Vector2.new(1, 0.5)
	speedBtn.Position = UDim2.new(1, -12, 0.5, 0)
	speedBtn.Size = UDim2.fromOffset(42, 26)
	speedBtn.BackgroundTransparency = 1
	speedBtn.AutoButtonColor = false
	speedBtn.Text = "1\u{00D7}"
	speedBtn.TextColor3 = Colors.TextSecondary
	speedBtn.ZIndex = z + 1
	Typography.apply(speedBtn, "value")
	speedBtn.Parent = root

	local speed = 4 -- default engine rate (displayed as "1x"); matches TimeController DEFAULT_SPEED
	local paused = false

	local function cycleSpeed()
		for i, s in ipairs(SPEEDS) do
			if s == speed then
				return SPEEDS[i % #SPEEDS + 1]
			end
		end
		return SPEEDS[1]
	end

	local function refreshSpeedColor()
		speedBtn.TextColor3 = paused and Colors.Warning or Colors.TextSecondary
	end

	pauseBtn.MouseEnter:Connect(function()
		pauseIcon.ImageColor3 = Colors.TextPrimary
	end)
	pauseBtn.MouseLeave:Connect(function()
		pauseIcon.ImageColor3 = Colors.TextSecondary
	end)
	speedBtn.MouseEnter:Connect(function()
		speedBtn.TextColor3 = Colors.TextPrimary
	end)
	speedBtn.MouseLeave:Connect(refreshSpeedColor)

	pauseBtn.MouseButton1Click:Connect(function()
		if config.onTogglePause then
			config.onTogglePause()
		end
	end)
	speedBtn.MouseButton1Click:Connect(function()
		if config.onSetSpeed then
			config.onSetSpeed(cycleSpeed())
		end
	end)

	if config.parent then
		root.Parent = config.parent
	end

	return {
		root = root,
		setDate = function(d)
			if d then
				date.Text = d
			end
		end,
		setTime = function(packet)
			if type(packet) ~= "table" then
				return
			end
			if packet.date then
				date.Text = packet.date
			end
			if type(packet.speed) == "number" then
				speed = packet.speed
				speedBtn.Text = tostring(packet.speed / 4) .. "\u{00D7}" -- engine rate -> player label (rate / 4)
			end
			if packet.paused ~= nil then
				paused = packet.paused == true
				pauseIcon.Image = Icons.Ids[paused and "Play" or "Pause"] or ""
				refreshSpeedColor()
			end
		end,
	}
end

return TopBar
