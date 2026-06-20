local Players = game:GetService("Players")

local UIRoot = {}

local screenGui
local layers = {}
local windowGuis = {}     -- id -> ScreenGui
local nextWindowZ = 60    -- baseline UIStyle.Z.Window

local DEFAULT_Z = {
	Chrome    = 10,
	Content   = 20,
	Transient = 50,
	Window    = 60,
	Modal     = 100,
	Toast     = 150,
}

local LAYER_ALIASES = {
	CommandMode = "Content",
}

local function ensureGui()
	if screenGui and screenGui.Parent then return screenGui end
	local player = Players.LocalPlayer
	local pg = player:WaitForChild("PlayerGui")
	local existing = pg:FindFirstChild("ArtOfWarUI")
	if existing then existing:Destroy() end
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ArtOfWarUI"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 10
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Enabled = false
	screenGui.Parent = pg

	-- Auto-attach UI click sound to every GuiButton descendant
	local ok, UISound = pcall(require, script.Parent:WaitForChild("UISound"))
	if ok and UISound and UISound.attachAll then
		UISound.attachAll(screenGui)
	end

	return screenGui
end

local function ensureLayer(name, zIndex)
	local resolved = LAYER_ALIASES[name] or name
	if layers[resolved] then return layers[resolved] end
	local root = ensureGui()
	local z = zIndex or DEFAULT_Z[resolved] or 1
	local layer = Instance.new("Frame")
	layer.Name = resolved
	layer.BackgroundTransparency = 1
	layer.Size = UDim2.fromScale(1, 1)
	layer.ZIndex = z
	layer.Parent = root
	layers[resolved] = layer
	return layer
end

function UIRoot.gui()
	return ensureGui()
end

function UIRoot.layer(name, zIndex)
	return ensureLayer(name, zIndex)
end

local tooltipGui
function UIRoot.tooltipLayer()
	if tooltipGui and tooltipGui.Parent then return tooltipGui end
	local player = Players.LocalPlayer
	local pg = player:WaitForChild("PlayerGui")
	local existing = pg:FindFirstChild("AoW_Tooltip")
	if existing then existing:Destroy() end
	tooltipGui = Instance.new("ScreenGui")
	tooltipGui.Name = "AoW_Tooltip"
	tooltipGui.ResetOnSpawn = false
	tooltipGui.IgnoreGuiInset = true
	tooltipGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	tooltipGui.DisplayOrder = 10000
	tooltipGui.Parent = pg
	return tooltipGui
end

local scaleInstances = setmetatable({}, { __mode = "k" })
local currentScale = 1
local scaleListening = false

local function computeScale()
	local cam = workspace.CurrentCamera
	local h = (cam and cam.ViewportSize.Y) or 1080
	if h < 200 then h = 1080 end
	return math.clamp(h / 1080, 0.75, 1.4)
end

local function applyScale()
	currentScale = computeScale()
	for inst in pairs(scaleInstances) do
		if inst.Parent then
			inst.Scale = currentScale
		else
			scaleInstances[inst] = nil
		end
	end
end

local function ensureScaleListening()
	if scaleListening then return end
	scaleListening = true
	currentScale = computeScale()
	local function bind(cam)
		if cam then
			cam:GetPropertyChangedSignal("ViewportSize"):Connect(applyScale)
		end
	end
	bind(workspace.CurrentCamera)
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		bind(workspace.CurrentCamera)
		applyScale()
	end)
end

function UIRoot.uiScale()
	ensureScaleListening()
	return currentScale
end

function UIRoot.registerScaled(obj)
	if not obj then return end
	ensureScaleListening()
	local scale = Instance.new("UIScale")
	scale.Scale = currentScale
	scale.Parent = obj
	scaleInstances[scale] = true
	return scale
end

function UIRoot.setVisible(flag)
	local gui = ensureGui()
	gui.Enabled = flag and true or false
end

function UIRoot.isVisible()
	return screenGui and screenGui.Enabled or false
end

-- Each MovableWindow gets its own ScreenGui so DisplayOrder is the only z-knob.
-- This avoids fighting with the tier system inside the main ArtOfWarUI ScreenGui.
function UIRoot.createWindowGui(id)
	if windowGuis[id] and windowGuis[id].Parent then
		return windowGuis[id]
	end
	local player = Players.LocalPlayer
	local pg = player:WaitForChild("PlayerGui")
	local sg = Instance.new("ScreenGui")
	sg.Name = "AoW_Window_" .. tostring(id)
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	nextWindowZ = nextWindowZ + 1
	sg.DisplayOrder = nextWindowZ
	sg.Enabled = false
	sg.Parent = pg
	windowGuis[id] = sg

	local ok, UISound = pcall(require, script.Parent:WaitForChild("UISound"))
	if ok and UISound and UISound.attachAll then
		UISound.attachAll(sg)
	end

	return sg
end

-- Bump a window-GUI to the top of the window stack.
function UIRoot.bumpWindowGui(sg)
	if not sg then return end
	nextWindowZ = nextWindowZ + 1
	sg.DisplayOrder = nextWindowZ
end

function UIRoot.getWindowGui(id)
	return windowGuis[id]
end

function UIRoot.destroy()
	if screenGui then screenGui:Destroy() end
	for _, sg in windowGuis do
		if sg then sg:Destroy() end
	end
	screenGui = nil
	layers = {}
	windowGuis = {}
	nextWindowZ = 60
end

return UIRoot
