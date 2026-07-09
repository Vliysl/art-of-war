-- Slider: a draggable value control (mouse + touch). No reusable slider existed; modeled on ProgressBar's
-- flat track + fill, with a draggable handle. Drag listeners are connected only while dragging (and torn
-- down on release) so instances don't leak global UserInputService connections.
--
-- Slider.create(config) -> (Frame root, function setValue)
--   config: { parent?, min?, max?, value?, step?, size?, height?, layoutOrder?, onChange?(value) }

local UserInputService = game:GetService("UserInputService")

local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors

local Slider = {}

local HANDLE = DesignSystem.Responsive.isTouch() and 28 or 18 -- D2: larger grab handle on touch
local TRACK_H = 5

function Slider.create(config)
	config = config or {}
	local minV = config.min or 0
	local maxV = config.max or 100
	local value = math.clamp(config.value or minV, minV, maxV)
	local onChange = config.onChange

	local function pct(v)
		local span = maxV - minV
		if span <= 0 then
			return 0
		end
		return math.clamp((v - minV) / span, 0, 1)
	end

	local root = Instance.new("Frame")
	root.Name = "Slider"
	root.Size = config.size or UDim2.new(1, 0, 0, config.height or HANDLE)
	root.BackgroundTransparency = 1
	root.LayoutOrder = config.layoutOrder or 0

	-- Track is inset by half a handle on each side so the handle centre maps cleanly across [0,1].
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.new(0, HANDLE / 2, 0.5, 0)
	track.Size = UDim2.new(1, -HANDLE, 0, TRACK_H)
	track.BackgroundColor3 = Colors.SurfaceSunken
	track.BorderSizePixel = 0
	track.Parent = root
	local tc = Instance.new("UICorner")
	tc.CornerRadius = UDim.new(0, math.floor(TRACK_H / 2))
	tc.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(pct(value), 0, 1, 0)
	fill.BackgroundColor3 = Colors.Accent
	fill.BorderSizePixel = 0
	fill.Parent = track
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(0, math.floor(TRACK_H / 2))
	fc.Parent = fill

	local handle = Instance.new("Frame")
	handle.Name = "Handle"
	handle.AnchorPoint = Vector2.new(0.5, 0.5)
	handle.Position = UDim2.new(pct(value), 0, 0.5, 0)
	handle.Size = UDim2.fromOffset(HANDLE, HANDLE)
	handle.BackgroundColor3 = Colors.TextPrimary
	handle.BorderSizePixel = 0
	handle.ZIndex = 3
	handle.Parent = track
	local hc = Instance.new("UICorner")
	hc.CornerRadius = UDim.new(1, 0)
	hc.Parent = handle

	local function applyVisual()
		local p = pct(value)
		fill.Size = UDim2.new(p, 0, 1, 0)
		handle.Position = UDim2.new(p, 0, 0.5, 0)
	end

	local function setValueFromX(absX)
		local trackPos = track.AbsolutePosition.X
		local trackW = track.AbsoluteSize.X
		if trackW <= 0 then
			return
		end
		local p = math.clamp((absX - trackPos) / trackW, 0, 1)
		local v = minV + p * (maxV - minV)
		if config.step and config.step > 0 then
			v = minV + math.floor((v - minV) / config.step + 0.5) * config.step
			v = math.clamp(v, minV, maxV)
		end
		if v ~= value then
			value = v
			applyVisual()
			if onChange then
				onChange(v)
			end
		end
	end

	local dragging = false
	local dragConns = {}
	local function endDrag()
		dragging = false
		for _, c in dragConns do
			c:Disconnect()
		end
		table.clear(dragConns)
	end
	local function beginDrag(input)
		if dragging then
			return
		end
		dragging = true
		setValueFromX(input.Position.X)
		dragConns[#dragConns + 1] = UserInputService.InputChanged:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch then
				setValueFromX(i.Position.X)
			end
		end)
		dragConns[#dragConns + 1] = UserInputService.InputEnded:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
				endDrag()
			end
		end)
	end

	local function onInputBegan(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			beginDrag(input)
		end
	end
	handle.InputBegan:Connect(onInputBegan)
	track.InputBegan:Connect(onInputBegan)

	if config.parent then
		root.Parent = config.parent
	end

	local function setValue(v)
		value = math.clamp(v, minV, maxV)
		applyVisual()
	end

	return root, setValue
end

return Slider
