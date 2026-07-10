-- Shared modal colour picker: a saturation/value square + hue bar + live swatch + hex box, over a dimmed
-- backdrop. STAYS OPEN until Done or X (clicking the backdrop does nothing). Extracted from the Data Editor
-- so the game Settings screen and the editor share one implementation.
--
--   ColorPicker.open(parentGui, initialRGB, onChange, onDone)
--     parentGui  : GuiObject/ScreenGui to host the modal scrim
--     initialRGB : {r,g,b} 0-255 array (optional; defaults 150,150,150)
--     onChange   : optional, invoked live with {R,G,B} 0-255 ints as the user drags/types
--     onDone     : optional, invoked once with the final {R,G,B} when Done is clicked (before close)
--   Returns a close() function.

local UserInputService = game:GetService("UserInputService")
local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors

local ColorPicker = {}

function ColorPicker.open(parentGui, initialRGB, onChange, onDone)
	local existing = parentGui:FindFirstChild("__ColorPicker")
	if existing then
		existing:Destroy()
	end
	local function round(x)
		return math.floor(x + 0.5)
	end
	local r0 = math.clamp(round(tonumber(initialRGB and initialRGB[1]) or 150), 0, 255)
	local g0 = math.clamp(round(tonumber(initialRGB and initialRGB[2]) or 150), 0, 255)
	local b0 = math.clamp(round(tonumber(initialRGB and initialRGB[3]) or 150), 0, 255)
	local h, s, v = Color3.fromRGB(r0, g0, b0):ToHSV()
	local lastRGB = { r0, g0, b0 }

	-- Dimmed backdrop that blocks the UI behind. A Frame (not a button) -> clicking it does NOTHING; the
	-- picker only closes via the X or Done button below.
	local scrim = Instance.new("Frame")
	scrim.Name = "__ColorPicker"
	scrim.Active = true
	scrim.BackgroundColor3 = Color3.new(0, 0, 0)
	scrim.BackgroundTransparency = 0.5
	scrim.BorderSizePixel = 0
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.ZIndex = 200
	scrim.Parent = parentGui

	local panel = Instance.new("Frame")
	panel.Active = true
	panel.Size = UDim2.fromOffset(262, 262)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.BackgroundColor3 = Colors.SurfaceElevated
	panel.BorderSizePixel = 0
	panel.ZIndex = 201
	panel.Parent = scrim
	do
		local st = Instance.new("UIStroke")
		st.Color = Colors.BorderStrong
		st.Thickness = 1
		st.Parent = panel
		local p = Instance.new("UIPadding")
		p.PaddingTop = UDim.new(0, 10)
		p.PaddingBottom = UDim.new(0, 10)
		p.PaddingLeft = UDim.new(0, 12)
		p.PaddingRight = UDim.new(0, 12)
		p.Parent = panel
	end

	-- Title bar + close (X).
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -26, 0, 20)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamMedium
	title.TextSize = 14
	title.TextColor3 = Colors.TextPrimary
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "Colour picker"
	title.ZIndex = 202
	title.Parent = panel

	local closeX = Instance.new("TextButton")
	closeX.Size = UDim2.fromOffset(22, 22)
	closeX.AnchorPoint = Vector2.new(1, 0)
	closeX.Position = UDim2.new(1, 0, 0, -1)
	closeX.BackgroundColor3 = Colors.SurfaceSunken or Colors.SurfaceBase
	closeX.TextColor3 = Colors.TextSecondary
	closeX.Font = Enum.Font.GothamBold
	closeX.TextSize = 13
	closeX.Text = "X"
	closeX.BorderSizePixel = 0
	closeX.ZIndex = 203
	closeX.Parent = panel

	local TOP = 28
	local SQW, SQH = 168, 150
	local sv = Instance.new("Frame")
	sv.Size = UDim2.fromOffset(SQW, SQH)
	sv.Position = UDim2.fromOffset(0, TOP)
	sv.BorderSizePixel = 0
	sv.Active = true
	sv.ZIndex = 202
	sv.Parent = panel
	local satF = Instance.new("Frame")
	satF.Size = UDim2.fromScale(1, 1)
	satF.BorderSizePixel = 0
	satF.BackgroundColor3 = Color3.new(1, 1, 1)
	satF.ZIndex = 202
	satF.Parent = sv
	do
		local gg = Instance.new("UIGradient")
		gg.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
		gg.Parent = satF
	end
	local valF = Instance.new("Frame")
	valF.Size = UDim2.fromScale(1, 1)
	valF.BorderSizePixel = 0
	valF.BackgroundColor3 = Color3.new(0, 0, 0)
	valF.ZIndex = 202
	valF.Parent = sv
	do
		local gg = Instance.new("UIGradient")
		gg.Rotation = 90
		gg.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) })
		gg.Parent = valF
	end
	local svCur = Instance.new("Frame")
	svCur.Size = UDim2.fromOffset(12, 12)
	svCur.AnchorPoint = Vector2.new(0.5, 0.5)
	svCur.BackgroundColor3 = Color3.new(1, 1, 1)
	svCur.BorderSizePixel = 0
	svCur.ZIndex = 203
	svCur.Parent = sv
	do
		local st = Instance.new("UIStroke")
		st.Color = Color3.new(0, 0, 0)
		st.Thickness = 2
		st.Parent = svCur
	end

	local hue = Instance.new("Frame")
	hue.Size = UDim2.fromOffset(SQW, 16)
	hue.Position = UDim2.fromOffset(0, TOP + SQH + 8)
	hue.BorderSizePixel = 0
	hue.Active = true
	hue.ZIndex = 202
	hue.Parent = panel
	do
		local gg = Instance.new("UIGradient")
		gg.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0.000, Color3.fromHSV(0.000, 1, 1)),
			ColorSequenceKeypoint.new(0.166, Color3.fromHSV(0.166, 1, 1)),
			ColorSequenceKeypoint.new(0.333, Color3.fromHSV(0.333, 1, 1)),
			ColorSequenceKeypoint.new(0.500, Color3.fromHSV(0.500, 1, 1)),
			ColorSequenceKeypoint.new(0.666, Color3.fromHSV(0.666, 1, 1)),
			ColorSequenceKeypoint.new(0.833, Color3.fromHSV(0.833, 1, 1)),
			ColorSequenceKeypoint.new(1.000, Color3.fromHSV(1.000, 1, 1)),
		})
		gg.Parent = hue
	end
	local hueCur = Instance.new("Frame")
	hueCur.Size = UDim2.new(0, 3, 1, 6)
	hueCur.AnchorPoint = Vector2.new(0.5, 0.5)
	hueCur.Position = UDim2.fromScale(h, 0.5)
	hueCur.BackgroundColor3 = Color3.new(1, 1, 1)
	hueCur.BorderSizePixel = 0
	hueCur.ZIndex = 203
	hueCur.Parent = hue
	do
		local st = Instance.new("UIStroke")
		st.Color = Color3.new(0, 0, 0)
		st.Thickness = 1
		st.Parent = hueCur
	end

	local swatch = Instance.new("Frame")
	swatch.Size = UDim2.fromOffset(58, 40)
	swatch.Position = UDim2.fromOffset(SQW + 14, TOP)
	swatch.BorderSizePixel = 0
	swatch.ZIndex = 202
	swatch.Parent = panel
	do
		local st = Instance.new("UIStroke")
		st.Color = Colors.BorderStrong
		st.Thickness = 1
		st.Parent = swatch
	end

	local hexBox = Instance.new("TextBox")
	hexBox.Size = UDim2.fromOffset(58, 24)
	hexBox.Position = UDim2.fromOffset(SQW + 14, TOP + 48)
	hexBox.BackgroundColor3 = Colors.SurfaceSunken or Colors.SurfaceBase
	hexBox.TextColor3 = Colors.TextPrimary
	hexBox.BorderSizePixel = 0
	hexBox.Font = Enum.Font.Code
	hexBox.TextSize = 13
	hexBox.Text = ""
	hexBox.PlaceholderText = "#hex"
	hexBox.ClearTextOnFocus = false
	hexBox.ZIndex = 202
	hexBox.Parent = panel
	do
		local st = Instance.new("UIStroke")
		st.Color = Colors.BorderStrong
		st.Thickness = 1
		st.Parent = hexBox
	end

	local rgbLabel = Instance.new("TextLabel")
	rgbLabel.Size = UDim2.fromOffset(SQW + 60, 20)
	rgbLabel.Position = UDim2.fromOffset(0, TOP + SQH + 30)
	rgbLabel.BackgroundTransparency = 1
	rgbLabel.TextColor3 = Colors.TextSecondary
	rgbLabel.Font = Enum.Font.Gotham
	rgbLabel.TextSize = 13
	rgbLabel.TextXAlignment = Enum.TextXAlignment.Left
	rgbLabel.Text = ""
	rgbLabel.ZIndex = 202
	rgbLabel.Parent = panel

	local done = Instance.new("TextButton")
	done.Size = UDim2.fromOffset(58, 26)
	done.Position = UDim2.fromOffset(SQW + 14, TOP + 82)
	done.BackgroundColor3 = Colors.Accent
	done.TextColor3 = Color3.fromRGB(20, 20, 24) -- dark font for contrast on the yellow Accent
	done.Text = "Done"
	done.Font = Enum.Font.GothamMedium
	done.TextSize = 13
	done.BorderSizePixel = 0
	done.ZIndex = 202
	done.Parent = panel

	local suppressHex = false
	local function apply(report)
		local col = Color3.fromHSV(h, s, v)
		sv.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
		svCur.Position = UDim2.fromScale(s, 1 - v)
		hueCur.Position = UDim2.fromScale(h, 0.5)
		swatch.BackgroundColor3 = col
		local R, G, B = round(col.R * 255), round(col.G * 255), round(col.B * 255)
		lastRGB = { R, G, B }
		if not suppressHex then
			hexBox.Text = string.format("#%02X%02X%02X", R, G, B)
		end
		rgbLabel.Text = string.format("RGB  %d, %d, %d", R, G, B)
		if report and onChange then
			onChange({ R, G, B })
		end
	end

	local uisConns = {} -- global-InputEnded handles cleared on close (fixes off-region pointer-up release)
	local function bindDrag(region, cb)
		local dragging = false
		local function upd(input)
			local ap, asz = region.AbsolutePosition, region.AbsoluteSize
			local rx = math.clamp((input.Position.X - ap.X) / math.max(asz.X, 1), 0, 1)
			local ry = math.clamp((input.Position.Y - ap.Y) / math.max(asz.Y, 1), 0, 1)
			cb(rx, ry)
		end
		region.InputBegan:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				dragging = true
				upd(input)
			end
		end)
		region.InputChanged:Connect(function(input)
			if
				dragging
				and (
					input.UserInputType == Enum.UserInputType.MouseMovement
					or input.UserInputType == Enum.UserInputType.Touch
				)
			then
				upd(input)
			end
		end)
		region.InputEnded:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				dragging = false
			end
		end)
		-- Also clear on a release ANYWHERE: region.InputEnded misses a pointer-up outside the frame, which
		-- otherwise leaves the selector following bare hover until the next click.
		uisConns[#uisConns + 1] = UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end)
	end
	bindDrag(sv, function(rx, ry)
		s = rx
		v = 1 - ry
		apply(true)
	end)
	bindDrag(hue, function(rx)
		h = rx
		apply(true)
	end)

	hexBox.FocusLost:Connect(function()
		local hx = (hexBox.Text or ""):gsub("#", ""):gsub("%s", "")
		if #hx == 6 then
			local R = tonumber(hx:sub(1, 2), 16)
			local G = tonumber(hx:sub(3, 4), 16)
			local B = tonumber(hx:sub(5, 6), 16)
			if R and G and B then
				h, s, v = Color3.fromRGB(R, G, B):ToHSV()
				suppressHex = true
				apply(true)
				suppressHex = false
				return
			end
		end
		apply(false) -- restore a valid hex string on bad input
	end)

	local function close()
		for _, c in ipairs(uisConns) do
			c:Disconnect()
		end
		table.clear(uisConns)
		scrim:Destroy()
	end
	closeX.Activated:Connect(close)
	done.Activated:Connect(function()
		if onDone then
			onDone({ lastRGB[1], lastRGB[2], lastRGB[3] })
		end
		close()
	end)
	apply(false)
	return close
end

return ColorPicker
