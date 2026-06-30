local ReplicatedFirst = game:GetService("ReplicatedFirst")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local rs = game:GetService("ReplicatedStorage")

ReplicatedFirst:RemoveDefaultLoadingScreen()

while not Players.LocalPlayer do
	task.wait()
end
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "AoWLoadingScreen"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 2000000
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local bg = Instance.new("Frame")
bg.Size = UDim2.fromScale(1, 1)
bg.BackgroundColor3 = Color3.fromRGB(15, 13, 11)
bg.BorderSizePixel = 0
bg.Parent = gui

local grad = Instance.new("UIGradient")
grad.Color = ColorSequence.new(Color3.fromRGB(31, 27, 21), Color3.fromRGB(11, 10, 9))
grad.Rotation = 90
grad.Parent = bg

local center = Instance.new("Frame")
center.AnchorPoint = Vector2.new(0.5, 0.5)
center.Position = UDim2.fromScale(0.5, 0.5)
center.Size = UDim2.new(0.86, 0, 0, 260)
center.BackgroundTransparency = 1
center.Parent = bg

local title = Instance.new("TextLabel")
title.AnchorPoint = Vector2.new(0.5, 0)
title.Position = UDim2.fromScale(0.5, 0)
title.Size = UDim2.new(1, 0, 0, 96)
title.BackgroundTransparency = 1
title.Text = "ART OF WAR"
title.TextColor3 = Color3.fromRGB(238, 208, 112)
title.Font = Enum.Font.Bodoni
title.TextScaled = true
title.TextTransparency = 1
title.Parent = center

local titleSize = Instance.new("UITextSizeConstraint")
titleSize.MaxTextSize = 82
titleSize.MinTextSize = 26
titleSize.Parent = title

local divider = Instance.new("Frame")
divider.AnchorPoint = Vector2.new(0.5, 0)
divider.Position = UDim2.new(0.5, 0, 0, 112)
divider.Size = UDim2.fromOffset(300, 2)
divider.BackgroundColor3 = Color3.fromRGB(200, 144, 58)
divider.BackgroundTransparency = 1
divider.BorderSizePixel = 0
divider.Parent = center

local dividerGrad = Instance.new("UIGradient")
dividerGrad.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.5, 0),
	NumberSequenceKeypoint.new(1, 1),
})
dividerGrad.Parent = divider

local subtitle = Instance.new("TextLabel")
subtitle.AnchorPoint = Vector2.new(0.5, 0)
subtitle.Position = UDim2.new(0.5, 0, 0, 128)
subtitle.Size = UDim2.new(1, 0, 0, 34)
subtitle.BackgroundTransparency = 1
subtitle.Text = "1750  \u{2013}  1849"
subtitle.TextColor3 = Color3.fromRGB(178, 154, 110)
subtitle.Font = Enum.Font.Garamond
subtitle.TextSize = 26
subtitle.TextTransparency = 1
subtitle.Parent = center

local status = Instance.new("TextLabel")
status.AnchorPoint = Vector2.new(0.5, 1)
status.Position = UDim2.new(0.5, 0, 1, 0)
status.Size = UDim2.new(1, 0, 0, 28)
status.BackgroundTransparency = 1
status.Text = "Charting the world"
status.TextColor3 = Color3.fromRGB(132, 118, 96)
status.Font = Enum.Font.Garamond
status.TextSize = 20
status.Parent = center

gui.Parent = playerGui

local entrance = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
TweenService:Create(title, entrance, { TextTransparency = 0 }):Play()
TweenService:Create(subtitle, entrance, { TextTransparency = 0 }):Play()
TweenService:Create(divider, entrance, { BackgroundTransparency = 0 }):Play()

local running = true
task.spawn(function()
	local dots = { "", " .", " . .", " . . ." }
	local i = 0
	while running do
		i = i % #dots + 1
		status.Text = "Charting the world" .. dots[i]
		task.wait(0.45)
	end
end)

local skipped = false
local skipWrap = nil -- the Skip button, built lazily (in the real UI button style) only if loading drags on

-- Reveal a Skip button only if loading drags on (quick loads never flash it). It is built in the game's
-- real UI button style via the shared Button component, and wrapped in a CanvasGroup so the whole button
-- (fill + stroke + label) fades in/out uniformly as one surface.
task.spawn(function()
	task.wait(4)
	if not running or skipped then
		return
	end

	local wrap = Instance.new("CanvasGroup")
	wrap.Name = "SkipButton"
	wrap.AnchorPoint = Vector2.new(0.5, 1)
	wrap.Position = UDim2.new(0.5, 0, 1, -36)
	wrap.Size = UDim2.fromOffset(168, 50)
	wrap.BackgroundTransparency = 1
	wrap.GroupTransparency = 1
	wrap.Parent = bg

	local built = false
	local ok, Button = pcall(function()
		local aow = rs:WaitForChild("ArtOfWar", 5)
		local comps = aow and aow:WaitForChild("UI", 5):WaitForChild("Components", 5):WaitForChild("Button", 5)
		return comps and require(comps)
	end)
	if ok and Button then
		local btn = Button.create({
			parent = wrap,
			variant = "secondary",
			text = "Skip",
			width = 150,
			onClick = function()
				skipped = true
			end,
		})
		btn.AnchorPoint = Vector2.new(0.5, 0.5)
		btn.Position = UDim2.fromScale(0.5, 0.5)
		built = true
	end
	if not built then
		-- Fallback (component not replicated yet): a button matching the same dark fill + stroke, sharp corners.
		local fb = Instance.new("TextButton")
		fb.Size = UDim2.fromScale(1, 1)
		fb.BackgroundColor3 = Color3.fromRGB(38, 33, 26)
		fb.AutoButtonColor = false
		fb.Text = "Skip"
		fb.TextColor3 = Color3.fromRGB(232, 220, 198)
		fb.Font = Enum.Font.GothamMedium
		fb.TextSize = 17
		fb.BorderSizePixel = 0
		fb.Parent = wrap
		local st = Instance.new("UIStroke")
		st.Color = Color3.fromRGB(120, 96, 50)
		st.Thickness = 1
		st.Parent = fb
		fb.Activated:Connect(function()
			skipped = true
		end)
	end

	skipWrap = wrap
	if running and not skipped then
		TweenService:Create(wrap, entrance, { GroupTransparency = 0 }):Play()
	end
end)

if not game:IsLoaded() then
	game.Loaded:Wait()
end

local deadline = os.clock() + 75
while os.clock() < deadline do
	if skipped then
		break
	end
	-- Wait for the FULL client boot (HUD built + map painted), not just the map, so UI doesn't pop in
	-- after the cover fades. ClientBoot sets AoWBootComplete at the very end of its boot.
	if player:GetAttribute("AoWBootComplete") then
		break
	end
	task.wait(0.1)
end

running = false

local exit = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
TweenService:Create(bg, exit, { BackgroundTransparency = 1 }):Play()
TweenService:Create(title, exit, { TextTransparency = 1 }):Play()
TweenService:Create(subtitle, exit, { TextTransparency = 1 }):Play()
TweenService:Create(status, exit, { TextTransparency = 1 }):Play()
TweenService:Create(divider, exit, { BackgroundTransparency = 1 }):Play()
if skipWrap then
	TweenService:Create(skipWrap, exit, { GroupTransparency = 1 }):Play()
end

task.wait(0.75)
if gui then
	gui:Destroy()
end
