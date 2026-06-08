local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))
local UIRoot = require(uiFolder:WaitForChild("UIRoot"))
local UISound = require(uiFolder:WaitForChild("UISound"))

local CountryPanel = {}

local PANEL_W = 380
local MAX_PANEL_H = 480
local COUNTRY_HEADER_H = 78
local GAP_TO_HEADER = 6

-- Politics window tab names that legacy callers might pass into setActive(name)
local POLITICS_TABS = {
	Factions = true,
	Leaders = true,
	Policies = true,
	Laws = true,
	Doctrines = true,
}

local _politicsRedirect = nil   -- function(tabName) -- set by UIController via setPoliticsRedirect

function CountryPanel.create(parent)
	local panel = UIBuilder.panel(parent, {
		Name = "CountryPanel",
		Size = UDim2.fromOffset(PANEL_W, 0),  -- starts collapsed
		Position = UDim2.new(0, 12, 1, -(UIStyle.Size.BottomBarH + COUNTRY_HEADER_H + GAP_TO_HEADER + 12)),
		AnchorPoint = Vector2.new(0, 1),
		BackgroundColor3 = UIStyle.Color.Panel,
		ClipsDescendants = true,
	})
	panel.Active = true
	panel.Visible = false
	UIRoot.registerScaled(panel)

	-- Header strip with title (sits at top of panel)
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 28)
	header.BackgroundColor3 = UIStyle.Color.Bg
	header.BorderSizePixel = 0
	header.ZIndex = UIStyle.Z.PanelHeader
	header.Parent = panel

	UIBuilder.label(header, "Realm Overview", UIStyle.Type.SectionHeader, UIStyle.Color.Gold, {
		Size = UDim2.new(1, -16, 1, 0),
		Position = UDim2.fromOffset(12, 0),
		Font = UIStyle.Font.Bold,
		TextSize = 13,
	})

	local headerTrim = Instance.new("Frame")
	headerTrim.Size = UDim2.new(1, 0, 0, 1)
	headerTrim.Position = UDim2.new(0, 0, 1, 0)
	headerTrim.AnchorPoint = Vector2.new(0, 1)
	headerTrim.BackgroundColor3 = UIStyle.Color.Gold
	headerTrim.BackgroundTransparency = 0.5
	headerTrim.BorderSizePixel = 0
	headerTrim.ZIndex = UIStyle.Z.PanelHeader + 1
	headerTrim.Parent = header

	-- Body (single Overview page; OverviewTab mounts here)
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = UDim2.new(1, 0, 1, -28)
	body.Position = UDim2.fromOffset(0, 28)
	body.BackgroundTransparency = 1
	body.ZIndex = UIStyle.Z.Content
	body.Parent = panel
	UIBuilder.padding(body, 10)

	-- ============ Open / close (slide UP from bottom) ============
	local isOpen = false
	local openTween = nil

	local function targetSize()
		return UDim2.fromOffset(PANEL_W, MAX_PANEL_H)
	end

	local function open()
		if isOpen then return end
		isOpen = true
		panel.Visible = true
		if UISound and UISound.whoosh then UISound.whoosh() end
		if UIStyle.ReduceMotion then
			panel.Size = targetSize()
		else
			panel.Size = UDim2.fromOffset(PANEL_W, 0)
			openTween = TweenService:Create(panel, UIStyle.tween(UIStyle.Motion.Fast), {
				Size = targetSize(),
			})
			openTween:Play()
		end
	end

	local function close()
		if not isOpen then return end
		isOpen = false
		if UISound and UISound.whoosh then UISound.whoosh() end
		if UIStyle.ReduceMotion then
			panel.Size = UDim2.fromOffset(PANEL_W, 0)
			panel.Visible = false
		else
			openTween = TweenService:Create(panel, UIStyle.tween(UIStyle.Motion.Fast), {
				Size = UDim2.fromOffset(PANEL_W, 0),
			})
			openTween.Completed:Connect(function()
				if not isOpen then panel.Visible = false end
			end)
			openTween:Play()
		end
	end

	local function toggle()
		if isOpen then close() else open() end
	end

	-- Hide entirely (used when unclaimed)
	local function hideAll()
		isOpen = false
		panel.Size = UDim2.fromOffset(PANEL_W, 0)
		panel.Visible = false
	end

	-- ============ Compatibility shim ============
	-- Old API: setActive(name). For "Overview" -> open the panel.
	-- For Politics-tab names (Factions/Leaders/Policies/Laws/Doctrines) -> open Politics window.
	local function setActive(name)
		if name == "Overview" then
			if not isOpen then open() end
			return
		end
		if POLITICS_TABS[name] and _politicsRedirect then
			_politicsRedirect(name)
		end
	end

	-- UIController calls this after PoliticsWindow is created so the redirect can wire up.
	function CountryPanel.setPoliticsRedirect(fn)
		_politicsRedirect = fn
	end

	return {
		root = panel,
		body = body,                   -- where OverviewTab mounts
		getOverviewBody = function() return body end,
		getPage = function(name)       -- legacy alias: only "Overview" supported
			if name == "Overview" then return body end
			return nil
		end,
		openPanel = open,
		closePanel = close,
		toggle = toggle,
		isOpen = function() return isOpen end,
		hideAll = hideAll,
		setActive = setActive,         -- legacy redirect to Politics window
		showWithAnim = open,           -- legacy alias from earlier rounds
	}
end

return CountryPanel
