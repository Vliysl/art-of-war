local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))
local UISound = require(uiFolder:WaitForChild("UISound"))
local Platform = require(ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Modules"):WaitForChild("Platform"))

local NotificationFeed = {}

local KIND_SOUND = {
	info = "notify",
	good = "notify",
	warn = "alert",
	bad  = "alert",
}

local TOAST_W = 300
local DEFAULT_TTL = 6

local KIND_TONE = {
	info = UIStyle.Color.Info,
	good = UIStyle.Color.Good,
	bad  = UIStyle.Color.Bad,
	warn = UIStyle.Color.Warn,
}

function NotificationFeed.create(parent)
	local root = Instance.new("Frame")
	root.Name = "NotificationFeed"
	root.Size = UDim2.new(0, TOAST_W + 20, 1, -(UIStyle.Size.TopBarH + UIStyle.Size.BottomBarH + 16))
	root.Position = UDim2.new(1, -12, 1, -(UIStyle.Size.BottomBarH + 12))
	root.AnchorPoint = Vector2.new(1, 1)
	root.BackgroundTransparency = 1
	root.ZIndex = UIStyle.Z.Toast
	root.Parent = parent

	local stack = Instance.new("UIListLayout")
	stack.FillDirection = Enum.FillDirection.Vertical
	stack.VerticalAlignment = Enum.VerticalAlignment.Bottom
	stack.HorizontalAlignment = Enum.HorizontalAlignment.Right
	stack.Padding = UDim.new(0, 6)
	stack.SortOrder = Enum.SortOrder.LayoutOrder
	stack.Parent = root

	local order = 0

	local function push(data)
		data = data or {}
		order = order + 1
		local tone = KIND_TONE[data.kind or "info"] or UIStyle.Color.Gold
		UISound.play(KIND_SOUND[data.kind or "info"] or "notify")

		local toast = Instance.new("Frame")
		toast.Size = UDim2.fromOffset(TOAST_W, 0)
		toast.AutomaticSize = Enum.AutomaticSize.Y
		toast.BackgroundColor3 = UIStyle.Color.Panel
		toast.BorderSizePixel = 0
		toast.LayoutOrder = order
		toast.ZIndex = UIStyle.Z.Toast
		toast.Parent = root
		UIBuilder.corner(toast, 3)
		UIBuilder.stroke(toast, 1, tone)

		local accent = Instance.new("Frame")
		accent.Size = UDim2.new(0, 3, 1, 0)
		accent.Position = UDim2.fromOffset(0, 0)
		accent.BackgroundColor3 = tone
		accent.BorderSizePixel = 0
		accent.ZIndex = UIStyle.Z.Toast + 1
		accent.Parent = toast

		local body = Instance.new("Frame")
		body.Size = UDim2.new(1, -16, 0, 0)
		body.Position = UDim2.fromOffset(10, 0)
		body.AutomaticSize = Enum.AutomaticSize.Y
		body.BackgroundTransparency = 1
		body.ZIndex = UIStyle.Z.Toast + 1
		body.Parent = toast
		UIBuilder.padding(body, 8, 8, 8, 8)

		local bodyLayout = Instance.new("UIListLayout")
		bodyLayout.FillDirection = Enum.FillDirection.Vertical
		bodyLayout.Padding = UDim.new(0, 2)
		bodyLayout.Parent = body

		if data.title then
			UIBuilder.label(body, data.title, UIStyle.Type.H2, UIStyle.Color.Gold, {
				Size = UDim2.new(1, -18, 0, 18),
				Font = UIStyle.Font.Bold,
				TextSize = 13,
			})
		end
		if data.body then
			local bl = UIBuilder.label(body, data.body, UIStyle.Type.Small, UIStyle.Color.Text, {
				Size = UDim2.new(1, -18, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				TextSize = 12,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
			})
		end

		-- Close btn
		local closeBtn = Instance.new("TextButton")
		closeBtn.Size = UDim2.fromOffset(Platform.isTouch and 28 or 16, Platform.isTouch and 28 or 16)
		closeBtn.Position = UDim2.new(1, Platform.isTouch and -4 or -8, 0, Platform.isTouch and 4 or 6)
		closeBtn.AnchorPoint = Vector2.new(1, 0)
		closeBtn.BackgroundTransparency = 1
		closeBtn.Text = "\u{2715}"
		closeBtn.TextColor3 = UIStyle.Color.TextMuted
		closeBtn.Font = UIStyle.Font.Bold
		closeBtn.TextSize = Platform.isTouch and 16 or 12
		closeBtn.AutoButtonColor = false
		closeBtn.ZIndex = UIStyle.Z.Toast + 2
		closeBtn.Parent = toast

		if not Platform.isTouch then
			closeBtn.MouseEnter:Connect(function() closeBtn.TextColor3 = UIStyle.Color.Gold end)
			closeBtn.MouseLeave:Connect(function() closeBtn.TextColor3 = UIStyle.Color.TextMuted end)
		end

		local dismissed = false
		local function dismiss()
			if dismissed then return end
			dismissed = true
			local tween = TweenService:Create(toast, UIStyle.tween(UIStyle.Motion.Slow), {
				BackgroundTransparency = 1,
			})
			tween.Completed:Connect(function() toast:Destroy() end)
			tween:Play()
		end

		closeBtn.MouseButton1Click:Connect(dismiss)

		-- Optional click handler on the body
		if data.onClick then
			local clickOverlay = Instance.new("TextButton")
			clickOverlay.Size = UDim2.new(1, -20, 1, 0)
			clickOverlay.Position = UDim2.fromOffset(0, 0)
			clickOverlay.BackgroundTransparency = 1
			clickOverlay.Text = ""
			clickOverlay.AutoButtonColor = false
			clickOverlay.ZIndex = UIStyle.Z.Toast + 1
			clickOverlay.Parent = toast
			clickOverlay.MouseButton1Click:Connect(function()
				pcall(data.onClick)
				dismiss()
			end)
		end

		-- Auto-dismiss unless pinnable
		if not data.pinnable then
			task.delay(data.ttl or DEFAULT_TTL, dismiss)
		end

		return { dismiss = dismiss, root = toast }
	end

	return {
		root = root,
		push = push,
	}
end

return NotificationFeed
