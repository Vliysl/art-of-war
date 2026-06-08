--!strict
-- Single source of truth for platform / input / viewport state used by the UI.
-- Resolves at first require; updates live as the user changes input or rotates.
--
-- API:
--   Platform.isTouch        -- boolean (true if device has touchscreen)
--   Platform.isMobile       -- boolean (touch + small screen)
--   Platform.isTablet       -- boolean (touch + large screen)
--   Platform.isDesktop      -- boolean (mouse / keyboard primary)
--   Platform.lastInputKind  -- "Touch" | "Mouse" | "Keyboard" | "Gamepad"
--   Platform.viewport()     -- Vector2 of current camera viewport size
--   Platform.tapTargetMin   -- minimum tap-target dimension (px) — 44 on touch, 22 on desktop
--   Platform.scale          -- recommended UI scale multiplier (1.0 desktop, ~1.15 phone, 1.0 tablet)
--   Platform.onChanged(fn)  -- subscribe; fn(reason: "input"|"viewport") fires after debounced changes
--
-- Caller-friendly: Platform.isTouch is a primitive snapshot read at module-load time.
-- For live changes, listen via Platform.onChanged.

local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")

local Platform = {}

local listeners = {}
local function fire(reason)
	for _, fn in ipairs(listeners) do
		task.spawn(function()
			local ok, err = pcall(fn, reason)
			if not ok then warn("[Platform] listener errored: " .. tostring(err)) end
		end)
	end
end

local function classifyInput(inputType)
	if inputType == Enum.UserInputType.Touch then return "Touch" end
	if inputType == Enum.UserInputType.Keyboard then return "Keyboard" end
	if inputType == Enum.UserInputType.Gamepad1
		or inputType == Enum.UserInputType.Gamepad2
		or inputType == Enum.UserInputType.Gamepad3
		or inputType == Enum.UserInputType.Gamepad4 then
		return "Gamepad"
	end
	return "Mouse"
end

Platform.isTouch = UserInputService.TouchEnabled
Platform.hasMouse = UserInputService.MouseEnabled
Platform.hasKeyboard = UserInputService.KeyboardEnabled
Platform.hasGamepad = UserInputService.GamepadEnabled
Platform.lastInputKind = classifyInput(UserInputService:GetLastInputType())

local function recomputeFlags()
	local cam = workspace.CurrentCamera
	local vp = (cam and cam.ViewportSize) or Vector2.new(1280, 720)
	Platform._viewport = vp

	-- Roblox treats anything with TouchEnabled+!MouseEnabled as mobile-ish; tablets often
	-- expose both. Use viewport diagonal as the primary tablet/phone discriminator.
	local diag = math.sqrt(vp.X * vp.X + vp.Y * vp.Y)
	if Platform.isTouch and not Platform.hasMouse and diag < 1100 then
		Platform.isMobile = true
		Platform.isTablet = false
		Platform.isDesktop = false
		Platform.scale = 1.15
		Platform.tapTargetMin = 44
	elseif Platform.isTouch and diag < 1500 then
		-- iPad-class / 2-in-1
		Platform.isMobile = false
		Platform.isTablet = true
		Platform.isDesktop = false
		Platform.scale = 1.05
		Platform.tapTargetMin = 40
	else
		Platform.isMobile = false
		Platform.isTablet = false
		Platform.isDesktop = true
		Platform.scale = 1.0
		Platform.tapTargetMin = 22
	end
end
recomputeFlags()

local SAFE_VP = Vector2.new(1280, 720)

function Platform.viewport()
	local cam = workspace.CurrentCamera
	if cam then
		local vp = cam.ViewportSize
		if vp and vp.X >= 100 and vp.Y >= 100 then
			Platform._viewport = vp
			return vp
		end
	end
	if Platform._viewport and Platform._viewport.X >= 100 and Platform._viewport.Y >= 100 then
		return Platform._viewport
	end
	return SAFE_VP
end

function Platform.onChanged(fn)
	assert(type(fn) == "function", "Platform.onChanged: fn must be function")
	table.insert(listeners, fn)
	return function()
		for i, f in ipairs(listeners) do
			if f == fn then table.remove(listeners, i); break end
		end
	end
end

-- Debounced viewport listener so rotation / resize fires once.
local pending = false
local function scheduleViewportRecompute()
	if pending then return end
	pending = true
	task.delay(0.05, function()
		pending = false
		recomputeFlags()
		fire("viewport")
	end)
end

local cam = workspace.CurrentCamera
if cam then cam:GetPropertyChangedSignal("ViewportSize"):Connect(scheduleViewportRecompute) end
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	cam = workspace.CurrentCamera
	if cam then cam:GetPropertyChangedSignal("ViewportSize"):Connect(scheduleViewportRecompute) end
	scheduleViewportRecompute()
end)

UserInputService.LastInputTypeChanged:Connect(function(inputType)
	Platform.lastInputKind = classifyInput(inputType)
	fire("input")
end)

return Platform
