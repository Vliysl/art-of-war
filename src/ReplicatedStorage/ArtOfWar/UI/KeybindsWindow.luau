local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))
local MovableWindow = require(uiFolder:WaitForChild("MovableWindow"))
local UIKeybindings = require(uiFolder:WaitForChild("UIKeybindings"))
local Platform = require(ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Modules"):WaitForChild("Platform"))

local KeybindsWindow = {}

local MODIFIER_KEYS = {
	[Enum.KeyCode.LeftShift] = true, [Enum.KeyCode.RightShift] = true,
	[Enum.KeyCode.LeftControl] = true, [Enum.KeyCode.RightControl] = true,
	[Enum.KeyCode.LeftAlt] = true, [Enum.KeyCode.RightAlt] = true,
	[Enum.KeyCode.LeftMeta] = true, [Enum.KeyCode.RightMeta] = true,
	[Enum.KeyCode.Tab] = true,
	[Enum.KeyCode.Unknown] = true,
}

local function keyCodeName(k)
	if not k or k == Enum.KeyCode.Unknown then return "—" end
	return k.Name
end

function KeybindsWindow.create()
	local win = MovableWindow.create({ id = "keybinds", title = "Keybinds", size = UDim2.fromOffset(520, 560) })

	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.new(1, 0, 1, -44)
	scroll.Position = UDim2.fromOffset(0, 0)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollBarThickness = 6
	scroll.ScrollBarImageColor3 = UIStyle.Color.Gold
	scroll.ScrollBarImageTransparency = 0.3
	scroll.Parent = win.body
	UIBuilder.padding(scroll, 8)

	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Vertical
	listLayout.Padding = UDim.new(0, 4)
	listLayout.Parent = scroll
	if Platform.isTouch then
		local banner = Instance.new("Frame")
		banner.Size = UDim2.new(1, -16, 0, 56)
		banner.BackgroundColor3 = UIStyle.Color.PanelAlt
		banner.BorderSizePixel = 0
		banner.LayoutOrder = -1
		banner.Parent = scroll
		UIBuilder.corner(banner, 3)
		UIBuilder.stroke(banner, 1, UIStyle.Color.Warn)
		UIBuilder.label(banner, "Keybinds are desktop-only.", UIStyle.Type.SectionHeader, UIStyle.Color.Warn, {
			Size = UDim2.new(1, -16, 0, 22),
			Position = UDim2.fromOffset(8, 6),
			TextSize = 13,
		})
		UIBuilder.label(banner, "On touch devices, use the on-screen buttons (TopBar pause, BottomBar windows, in-panel actions). Bindings shown below are read-only references.",
			UIStyle.Type.Small, UIStyle.Color.TextMuted, {
				Size = UDim2.new(1, -16, 0, 28),
				Position = UDim2.fromOffset(8, 26),
				TextSize = 11,
				TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Top,
			})
	end

	-- Footer with Reset All / Done
	local footer = Instance.new("Frame")
	footer.Size = UDim2.new(1, 0, 0, 44)
	footer.Position = UDim2.new(0, 0, 1, 0)
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.BackgroundColor3 = UIStyle.Color.Bg
	footer.BorderSizePixel = 0
	footer.Parent = win.body

	local footTrim = Instance.new("Frame")
	footTrim.Size = UDim2.new(1, 0, 0, 1)
	footTrim.Position = UDim2.fromOffset(0, 0)
	footTrim.BackgroundColor3 = UIStyle.Color.Gold
	footTrim.BackgroundTransparency = 0.5
	footTrim.BorderSizePixel = 0
	footTrim.Parent = footer

	local resetAllBtn = UIBuilder.button(footer, {
		Size = UDim2.fromOffset(120, 28),
		Position = UDim2.new(0, 12, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		Text = "Reset all",
	}, false)

	local doneBtn = UIBuilder.button(footer, {
		Size = UDim2.fromOffset(80, 28),
		Position = UDim2.new(1, -12, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		Text = "Done",
	}, true)

	doneBtn.MouseButton1Click:Connect(function() win.close() end)

	-- Row factory
	local rows = {}    -- id -> {row, keyBox, warnLbl}
	local activeRebind = nil

	local function flashConflict(otherId)
		local other = rows[otherId]
		if other then
			local origColor = other.keyBox.BackgroundColor3
			other.keyBox.BackgroundColor3 = UIStyle.Color.Bad
			task.delay(0.6, function()
				if other.keyBox then other.keyBox.BackgroundColor3 = origColor end
			end)
		end
	end

	local function repaintRow(id)
		local data = rows[id]
		if not data then return end
		local list = UIKeybindings.getBindings()
		for _, b in list do
			if b.id == id then
				data.keyBox.Text = keyCodeName(b.currentKey)
				data.keyBox.TextColor3 = (b.currentKey == b.defaultKey)
					and UIStyle.Color.TextMuted or UIStyle.Color.Text
				-- Update conflict warning
				local conflicts = UIKeybindings.findConflicts(id, b.currentKey)
				if #conflicts > 0 then
					local names = {}
					for _, otherId in conflicts do
						for _, ob in list do
							if ob.id == otherId then table.insert(names, ob.label) break end
						end
					end
					data.warnLbl.Text = "Conflicts with: " .. table.concat(names, ", ")
					data.warnLbl.Visible = true
				else
					data.warnLbl.Visible = false
				end
				return
			end
		end
	end

	local function repaintAll()
		for id, _ in rows do repaintRow(id) end
	end

	local function startRebind(id)
		if activeRebind then return end
		activeRebind = id
		local data = rows[id]
		data.keyBox.Text = "Press a key…"
		data.keyBox.BackgroundColor3 = UIStyle.Color.Gold
		data.keyBox.TextColor3 = UIStyle.Color.Bg

		local conn
		conn = UserInputService.InputBegan:Connect(function(input, processed)
			if processed then return end
			if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
			local kc = input.KeyCode
			if MODIFIER_KEYS[kc] then return end
			conn:Disconnect()
			activeRebind = nil
			if kc == Enum.KeyCode.Escape then
				-- Cancel rebind
				repaintRow(id)
				return
			end
			local conflicts = UIKeybindings.findConflicts(id, kc)
			UIKeybindings.setBinding(id, kc)
			repaintAll()  -- both this row and any conflicting row need repaint
			for _, otherId in conflicts do flashConflict(otherId) end
		end)
	end

	local function buildList()
		for id, data in rows do
			if data.row then data.row:Destroy() end
		end
		rows = {}

		local bindings = UIKeybindings.getBindings()
		for i, b in ipairs(bindings) do
			local row = Instance.new("Frame")
			row.Size = UDim2.new(1, -8, 0, 36)
			row.BackgroundColor3 = (i % 2 == 0) and UIStyle.Color.Panel or UIStyle.Color.PanelAlt
			row.BorderSizePixel = 0
			row.LayoutOrder = i
			row.Parent = scroll
			UIBuilder.corner(row, 2)
			UIBuilder.padding(row, 6, 8, 6, 8)

			UIBuilder.label(row, b.label, UIStyle.Type.Body, UIStyle.Color.Text, {
				Size = UDim2.new(1, -200, 0, 18),
				Position = UDim2.fromOffset(0, 0),
				TextSize = 13,
			})

			local warnLbl = UIBuilder.label(row, "", UIStyle.Type.Small, UIStyle.Color.Bad, {
				Size = UDim2.new(1, -200, 0, 12),
				Position = UDim2.fromOffset(0, 18),
				TextSize = 10,
				Visible = false,
			})

			local keyBox = Instance.new("TextButton")
			keyBox.Size = UDim2.fromOffset(120, 24)
			keyBox.Position = UDim2.new(1, -36, 0.5, 0)
			keyBox.AnchorPoint = Vector2.new(1, 0.5)
			keyBox.BackgroundColor3 = UIStyle.Color.Bg
			keyBox.BorderSizePixel = 0
			keyBox.AutoButtonColor = false
			keyBox.Text = keyCodeName(b.currentKey)
			keyBox.TextColor3 = UIStyle.Color.Text
			keyBox.Font = UIStyle.Font.Mono
			keyBox.TextSize = 12
			keyBox.Parent = row
			UIBuilder.corner(keyBox, 3)
			UIBuilder.stroke(keyBox, 1, UIStyle.Color.Border)
			keyBox.MouseButton1Click:Connect(function() startRebind(b.id) end)

			local resetBtn = Instance.new("TextButton")
			resetBtn.Size = UDim2.fromOffset(24, 24)
			resetBtn.Position = UDim2.new(1, -4, 0.5, 0)
			resetBtn.AnchorPoint = Vector2.new(1, 0.5)
			resetBtn.BackgroundColor3 = UIStyle.Color.PanelAlt
			resetBtn.BorderSizePixel = 0
			resetBtn.AutoButtonColor = false
			resetBtn.Text = "\u{21BA}"
			resetBtn.TextColor3 = UIStyle.Color.TextMuted
			resetBtn.Font = UIStyle.Font.Bold
			resetBtn.TextSize = 14
			resetBtn.Parent = row
			UIBuilder.corner(resetBtn, 3)
			UIBuilder.stroke(resetBtn, 1, UIStyle.Color.Border)
			resetBtn.MouseButton1Click:Connect(function()
				UIKeybindings.resetBinding(b.id)
				repaintAll()
			end)

			rows[b.id] = { row = row, keyBox = keyBox, warnLbl = warnLbl }
			repaintRow(b.id)
		end
	end

	resetAllBtn.MouseButton1Click:Connect(function()
		UIKeybindings.resetAll()
		repaintAll()
	end)

	-- Subscribe to external rebind events
	UIKeybindings.subscribeChanged(function() repaintAll() end)

	-- Build on first open and rebuild whenever opened (so newly registered actions show up)
	local origOpen = win.open
	local function open()
		buildList()
		origOpen()
	end

	return {
		root = win.root,
		open = open,
		close = win.close,
		toggle = function() if win.isOpen() then win.close() else open() end end,
		isOpen = win.isOpen,
		bringToFront = win.bringToFront,
	}
end

return KeybindsWindow
