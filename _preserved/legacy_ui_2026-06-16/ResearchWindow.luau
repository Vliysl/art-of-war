local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))
local UIRoot = require(uiFolder:WaitForChild("UIRoot"))
local MovableWindow = require(uiFolder:WaitForChild("MovableWindow"))

local ResearchWindow = {}

local TAB_DEFS = {
	{ key = "Economic",   label = "Economic",   subtitle = "Markets, taxation, and workshops will collect here." },
	{ key = "Military",   label = "Military",   subtitle = "Doctrines, formations, and equipment reforms will collect here." },
	{ key = "Political",  label = "Political",  subtitle = "Administrative reforms and statecraft advances will collect here." },
	{ key = "Industrial", label = "Industrial", subtitle = "Manufacturing and infrastructure advances will collect here." },
}

local TAB_STRIP_H = 32

function ResearchWindow.create()
	local win = MovableWindow.create({ id = "research", title = "Research", size = UDim2.fromOffset(600, 500) })

	local tabStrip = Instance.new("Frame")
	tabStrip.Size = UDim2.new(1, 0, 0, TAB_STRIP_H)
	tabStrip.BackgroundColor3 = UIStyle.Color.Bg
	tabStrip.BorderSizePixel = 0
	tabStrip.Parent = win.body
	-- Buttons live inside tabRow (which owns the layout); underline is a sibling so the layout never touches it.
	local tabRow = Instance.new("Frame")
	tabRow.Size = UDim2.fromScale(1, 1)
	tabRow.BackgroundTransparency = 1
	tabRow.Parent = tabStrip

	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.Parent = tabRow

	local underline = Instance.new("Frame")
	underline.Size = UDim2.fromOffset(0, 2)
	underline.Position = UDim2.new(0, 0, 1, -2)
	underline.BackgroundColor3 = UIStyle.Color.Gold
	underline.BorderSizePixel = 0
	underline.Parent = tabStrip

	local content = Instance.new("Frame")
	content.Size = UDim2.new(1, 0, 1, -TAB_STRIP_H)
	content.Position = UDim2.fromOffset(0, TAB_STRIP_H)
	content.BackgroundTransparency = 1
	content.ClipsDescendants = true
	content.Parent = win.body

	local tabs = {}
	local active = nil
	local function setActive(key)
		for k, data in tabs do
			local isActive = k == key
			data.page.Visible = isActive
			data.label.TextColor3 = isActive and UIStyle.Color.Gold or UIStyle.Color.TextMuted
			if isActive then
				local s = UIRoot.uiScale()
				local px = (data.button.AbsolutePosition.X - tabRow.AbsolutePosition.X) / s
				local sx = data.button.AbsoluteSize.X / s
				if not UIStyle.ReduceMotion then
					TweenService:Create(underline, UIStyle.tween(UIStyle.Motion.Fast), {
						Position = UDim2.new(0, px, 1, -2),
						Size = UDim2.fromOffset(sx, 2),
					}):Play()
				else
					underline.Position = UDim2.new(0, px, 1, -2)
					underline.Size = UDim2.fromOffset(sx, 2)
				end
			end
		end
		active = key
	end

	for i, def in ipairs(TAB_DEFS) do
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1 / #TAB_DEFS, 0, 1, 0)
		btn.BackgroundTransparency = 1
		btn.AutoButtonColor = false
		btn.Text = ""
		btn.LayoutOrder = i
		btn.Parent = tabRow
		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.BackgroundTransparency = 1
		lbl.Text = def.label
		lbl.TextColor3 = UIStyle.Color.TextMuted
		lbl.FontFace = UIStyle.FontFace.Cinzel
		lbl.TextSize = 12
		lbl.TextXAlignment = Enum.TextXAlignment.Center
		lbl.TextYAlignment = Enum.TextYAlignment.Center
		lbl.Parent = btn
		local page = Instance.new("Frame")
		page.Size = UDim2.fromScale(1, 1)
		page.BackgroundTransparency = 1
		page.Visible = false
		page.Parent = content
		UIBuilder.emptyState(page, {
			icon = "Research",
			title = def.label .. " Research",
			subtitle = def.subtitle,
		})
		tabs[def.key] = { button = btn, label = lbl, page = page }
		btn.MouseButton1Click:Connect(function() setActive(def.key) end)
	end
	task.defer(function() setActive("Economic") end)

	return {
		open = win.open, close = win.close, toggle = win.toggle, isOpen = win.isOpen,
		bringToFront = win.bringToFront,
		setActiveTab = setActive,
	}
end

return ResearchWindow
