local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Animations = DesignSystem.Animations
local Shells = DesignSystem.Shells

local ProgressBar = {}

local TRACK = { long = "progress_track_long", medium = "progress_track_medium", short = "progress_track_short" }
local FILL = {
	green = "progress_fill_green_long",
	amber = "progress_fill_amber_long",
	red = "progress_fill_red_long",
	grey = "progress_fill_grey_long",
}

local function pctOf(value, minV, maxV)
	local span = maxV - minV
	if span == 0 then
		return 0
	end
	return math.clamp((value - minV) / span, 0, 1)
end

function ProgressBar.create(config)
	config = config or {}
	local minV = config.min or 0
	local maxV = config.max or 100
	local height = config.height or 10
	local pct = pctOf(config.value or 0, minV, maxV)

	if config.flat then
		local bg = Instance.new("Frame")
		bg.Name = "ProgressBar"
		bg.Size = config.size or UDim2.new(1, 0, 0, height)
		bg.BackgroundColor3 = Colors.SurfaceSunken
		bg.BorderSizePixel = 0
		bg.LayoutOrder = config.layoutOrder or 0
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, math.floor(height / 2))
		c.Parent = bg
		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.Size = UDim2.new(pct, 0, 1, 0)
		fill.BackgroundColor3 = typeof(config.color) == "Color3" and config.color or Colors.Positive
		fill.BorderSizePixel = 0
		fill.Parent = bg
		local fc = Instance.new("UICorner")
		fc.CornerRadius = UDim.new(0, math.floor(height / 2))
		fc.Parent = fill
		local function setFlat(v, col)
			local p = pctOf(v, minV, maxV)
			Animations.tween(fill, Animations.Slow, { Size = UDim2.new(p, 0, 1, 0) })
			if typeof(col) == "Color3" then
				fill.BackgroundColor3 = col
			end
		end
		if config.parent then
			bg.Parent = config.parent
		end
		return bg, setFlat
	end

	local track = Shells.create(TRACK[config.length or "long"], {
		Name = "ProgressBar",
		Size = config.size or UDim2.new(1, 0, 0, height),
		LayoutOrder = config.layoutOrder or 0,
	})

	local clip = Instance.new("Frame")
	clip.Name = "Clip"
	clip.BackgroundTransparency = 1
	clip.ClipsDescendants = true
	clip.Size = UDim2.new(pct, 0, 1, 0)
	clip.Parent = track

	local fillName = FILL[config.color] or FILL.green
	local fill = Shells.create(fillName, {
		Name = "Fill",
		Size = UDim2.new(pct > 0 and 1 / pct or 1, 0, 1, 0),
	})
	fill.Parent = clip

	local function setValue(newValue, newColor)
		local p = pctOf(newValue, minV, maxV)
		Animations.tween(clip, Animations.Slow, { Size = UDim2.new(p, 0, 1, 0) })
		fill.Size = UDim2.new(p > 0 and 1 / p or 1, 0, 1, 0)
		if newColor and FILL[newColor] and Shells.Data[FILL[newColor]] then
			fill.Image = Shells.Data[FILL[newColor]].Id
		end
	end

	if config.parent then
		track.Parent = config.parent
	end
	return track, setValue
end

return ProgressBar
