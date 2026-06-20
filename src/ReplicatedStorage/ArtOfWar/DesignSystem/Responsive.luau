local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local Responsive = {}

local REF_HEIGHT = 1080
local MIN_SCALE = 0.7
local MAX_SCALE = 1.5

Responsive.tapTargetMin = 44

function Responsive.isTouch()
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

local function viewport()
	local cam = workspace.CurrentCamera
	return cam and cam.ViewportSize or Vector2.new(1280, 720)
end

function Responsive.computeScale()
	local h = viewport().Y
	if h < 200 then
		h = REF_HEIGHT
	end
	local base = math.clamp(h / REF_HEIGHT, MIN_SCALE, MAX_SCALE)
	if Responsive.isTouch() then
		base = base * 1.15
	end
	return base
end

function Responsive.attach(root)
	local scale = Instance.new("UIScale")
	scale.Name = "ResponsiveScale"
	scale.Scale = Responsive.computeScale()
	scale.Parent = root

	local function update()
		scale.Scale = Responsive.computeScale()
	end

	local function bind(cam)
		if cam then
			cam:GetPropertyChangedSignal("ViewportSize"):Connect(update)
		end
	end
	bind(workspace.CurrentCamera)
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		bind(workspace.CurrentCamera)
		update()
	end)
	UserInputService:GetPropertyChangedSignal("TouchEnabled"):Connect(update)

	return scale
end

function Responsive.guiInset()
	local topLeft, bottomRight = GuiService:GetGuiInset()
	return topLeft, bottomRight
end

function Responsive.tapHeight(base)
	if Responsive.isTouch() then
		return math.max(base, Responsive.tapTargetMin)
	end
	return base
end

return Responsive
