-- Phase C1: a small radial (command-wheel) menu shown at a touch point. Options appear in a ring around the
-- press point (zero travel), a full-screen catcher dismisses it, and a center label shows "Cancel". Self-contained
-- and reusable: RadialMenu.show(screenPos, options) where options = { { text = "Halt", onSelect = fn }, ... }.
-- Returns a hide() function. Only one wheel is shown at a time.
local Players = game:GetService("Players")

local RadialMenu = {}

local RADIUS = 96
local BTN = 60
local FILL = Color3.fromRGB(28, 34, 46)
local FILL_HI = Color3.fromRGB(60, 120, 170)
local STROKE = Color3.fromRGB(180, 235, 255)

local activeGui = nil

local function hide()
	if activeGui then
		activeGui:Destroy()
		activeGui = nil
	end
end
RadialMenu.hide = hide

function RadialMenu.show(screenPos, options)
	hide()
	local player = Players.LocalPlayer
	local pg = player and player:FindFirstChildOfClass("PlayerGui")
	if not pg or type(options) ~= "table" or #options == 0 then
		return function() end
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "AoWRadialMenu"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 60
	gui.Parent = pg
	activeGui = gui

	-- Full-screen catcher: a tap outside the ring dismisses.
	local catcher = Instance.new("TextButton")
	catcher.Size = UDim2.fromScale(1, 1)
	catcher.BackgroundColor3 = Color3.new(0, 0, 0)
	catcher.BackgroundTransparency = 0.55
	catcher.Text = ""
	catcher.AutoButtonColor = false
	catcher.ZIndex = 1
	catcher:SetAttribute("AoWInputSink", true)
	catcher.Parent = gui
	catcher.Activated:Connect(hide)

	-- Center "Cancel" hint.
	local center = Instance.new("TextLabel")
	center.Size = UDim2.fromOffset(64, 64)
	center.AnchorPoint = Vector2.new(0.5, 0.5)
	center.Position = UDim2.fromOffset(screenPos.X, screenPos.Y)
	center.BackgroundColor3 = FILL
	center.BackgroundTransparency = 0.2
	center.TextColor3 = STROKE
	center.Font = Enum.Font.GothamBold
	center.TextSize = 12
	center.Text = "Cancel"
	center.ZIndex = 2
	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(1, 0)
	cc.Parent = center
	center.Parent = gui

	local n = #options
	for i, opt in ipairs(options) do
		local angle = (i - 1) / n * math.pi * 2 - math.pi / 2 -- first item at top
		local bx = screenPos.X + math.cos(angle) * RADIUS
		local by = screenPos.Y + math.sin(angle) * RADIUS
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.fromOffset(BTN, BTN)
		btn.AnchorPoint = Vector2.new(0.5, 0.5)
		btn.Position = UDim2.fromOffset(bx, by)
		btn.BackgroundColor3 = FILL
		btn.BackgroundTransparency = 0.05
		btn.TextColor3 = Color3.new(1, 1, 1)
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = 13
		btn.TextWrapped = true
		btn.Text = tostring(opt.text or "?")
		btn.AutoButtonColor = true
		btn.ZIndex = 2
		btn:SetAttribute("AoWInputSink", true)
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = btn
		local stroke = Instance.new("UIStroke")
		stroke.Color = STROKE
		stroke.Thickness = 1.5
		stroke.Transparency = 0.3
		stroke.Parent = btn
		btn.Parent = gui
		local onSelect = opt.onSelect
		btn.Activated:Connect(function()
			hide()
			if type(onSelect) == "function" then
				local ok, err = pcall(onSelect)
				if not ok then
					warn("[RadialMenu] option '" .. tostring(opt.text) .. "' errored: " .. tostring(err))
				end
			end
		end)
	end

	return hide
end

return RadialMenu
