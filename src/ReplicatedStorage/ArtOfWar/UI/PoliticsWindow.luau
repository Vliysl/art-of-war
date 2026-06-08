local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))
local UIRoot = require(uiFolder:WaitForChild("UIRoot"))
local MovableWindow = require(uiFolder:WaitForChild("MovableWindow"))

local FactionsTab = require(uiFolder.Tabs:WaitForChild("FactionsTab"))
local LeadersTab = require(uiFolder.Tabs:WaitForChild("LeadersTab"))
local PoliciesTab = require(uiFolder.Tabs:WaitForChild("PoliciesTab"))
local LawsTab = require(uiFolder.Tabs:WaitForChild("LawsTab"))
local DoctrinesTab = require(uiFolder.Tabs:WaitForChild("DoctrinesTab"))

local PoliticsWindow = {}

local TAB_DEFS = {
	{ key = "Factions",  label = "Factions"  },
	{ key = "Leaders",   label = "Leaders"   },
	{ key = "Policies",  label = "Policies"  },
	{ key = "Laws",      label = "Laws"      },
	{ key = "Doctrines", label = "Doctrines" },
}

local TAB_STRIP_H = 32

function PoliticsWindow.create(callbacks)
	callbacks = callbacks or {}

	local win = MovableWindow.create({
		id = "politics",
		title = "Politics",
		size = UDim2.fromOffset(600, 500),
	})

	-- Tab strip
	local tabStrip = Instance.new("Frame")
	tabStrip.Name = "TabStrip"
	tabStrip.Size = UDim2.new(1, 0, 0, TAB_STRIP_H)
	tabStrip.BackgroundColor3 = UIStyle.Color.Bg
	tabStrip.BorderSizePixel = 0
	tabStrip.Parent = win.body

	local tabRow = Instance.new("Frame")
	tabRow.Size = UDim2.fromScale(1, 1)
	tabRow.BackgroundTransparency = 1
	tabRow.Parent = tabStrip

	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.Padding = UDim.new(0, 0)
	tabLayout.Parent = tabRow

	local underline = Instance.new("Frame")
	underline.Size = UDim2.fromOffset(0, 2)
	underline.Position = UDim2.new(0, 0, 1, -2)
	underline.BackgroundColor3 = UIStyle.Color.Gold
	underline.BorderSizePixel = 0
	underline.Parent = tabStrip

	-- Content area
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.new(1, 0, 1, -TAB_STRIP_H)
	content.Position = UDim2.fromOffset(0, TAB_STRIP_H)
	content.BackgroundTransparency = 1
	content.ClipsDescendants = true
	content.Parent = win.body
	UIBuilder.padding(content, 10)

	local tabs = {}
	local activeKey = nil

	local function setActive(key)
		for tabKey, data in tabs do
			local active = tabKey == key
			data.page.Visible = active
			data.label.TextColor3 = active and UIStyle.Color.Gold or UIStyle.Color.TextMuted
			if active then
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
		activeKey = key
	end

	for i, def in ipairs(TAB_DEFS) do
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1 / #TAB_DEFS, 0, 1, 0)
		btn.BackgroundTransparency = 1
		btn.BorderSizePixel = 0
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

		tabs[def.key] = { button = btn, label = lbl, page = page }
		btn.MouseButton1Click:Connect(function() setActive(def.key) end)
	end

	-- Mount tab modules into their pages
	local tabImpls = {}
	tabImpls.Factions = FactionsTab.mount(tabs.Factions.page)
	tabImpls.Leaders = LeadersTab.mount(tabs.Leaders.page,
		callbacks.fireDismiss, callbacks.fireAppoint)
	tabImpls.Policies = PoliciesTab.mount(tabs.Policies.page,
		callbacks.fireEnact, callbacks.fireRepeal)
	tabImpls.Laws = LawsTab.mount(tabs.Laws.page,
		callbacks.fireCancel)
	tabImpls.Doctrines = DoctrinesTab.mount(tabs.Doctrines.page,
		callbacks.fireSetDoctrine)

	task.defer(function() setActive("Factions") end)

	return {
		root = win.root,
		body = win.body,
		open = win.open,
		close = win.close,
		toggle = win.toggle,
		isOpen = win.isOpen,
		bringToFront = win.bringToFront,
		setActiveTab = setActive,
		getActiveTab = function() return activeKey end,
		getPage = function(name)
			return tabs[name] and tabs[name].page or nil
		end,
		tabs = tabs,
		tabImpls = tabImpls,
	}
end

return PoliticsWindow
