local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Spacing = DesignSystem.Spacing
local Shells = DesignSystem.Shells

local ProvinceTooltip = {}

local WIDTH = 248

local function line(parent, role, color, order)
	local l = Instance.new("TextLabel")
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.Size = UDim2.new(1, 0, 0, 0)
	l.BackgroundTransparency = 1
	l.Text = ""
	l.TextColor3 = color
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.TextWrapped = true
	l.LayoutOrder = order
	Typography.apply(l, role)
	l.Parent = parent
	return l
end

function ProvinceTooltip.create(parent)
	local root = Shells.create("tooltip_shell", {
		Name = "ProvinceTooltip",
		Size = UDim2.fromOffset(WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = false,
		ZIndex = 80,
	})
	root:SetAttribute("AoWInputSink", false)

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Spacing.space3)
	pad.PaddingBottom = UDim.new(0, Spacing.space3)
	pad.PaddingLeft = UDim.new(0, Spacing.space4)
	pad.PaddingRight = UDim.new(0, Spacing.space4)
	pad.Parent = root

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = root

	local nameRow = line(root, "title", Colors.TextPrimary, 1)
	local ownerRow = line(root, "bodySm", Colors.TextSecondary, 2)
	local terrainRow = line(root, "caption", Colors.TextTertiary, 3)
	local societyRow = line(root, "caption", Colors.TextTertiary, 4)
	local devRow = line(root, "caption", Colors.TextSecondary, 5)

	if parent then
		root.Parent = parent
	end

	local OFFSET = 18
	local MARGIN = 8

	-- The Tooltips layer carries a Responsive UIScale, which multiplies child offsets about
	-- the layer origin. GetMouseLocation is in true-top-left pixels (matching the layer, which
	-- ignores the GUI inset), so position is computed in screen pixels then divided by the
	-- scale to land the tooltip exactly at the cursor at any resolution / UI scale.
	local function effectiveScale()
		local sg = root.Parent
		local s = sg and sg:FindFirstChildWhichIsA("UIScale")
		return (s and s.Scale) or 1
	end

	local followConn = nil
	local function follow()
		local cam = workspace.CurrentCamera
		local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
		local scale = effectiveScale()
		local size = root.AbsoluteSize
		local w = size.X > 0 and size.X or WIDTH * scale
		local h = size.Y > 0 and size.Y or 120 * scale
		local mp = UserInputService:GetMouseLocation()
		local x = mp.X + OFFSET
		local y = mp.Y + OFFSET
		if x + w > vp.X - MARGIN then
			x = mp.X - OFFSET - w
		end
		if y + h > vp.Y - MARGIN then
			y = mp.Y - OFFSET - h
		end
		x = math.clamp(x, MARGIN, math.max(MARGIN, vp.X - w - MARGIN))
		y = math.clamp(y, MARGIN, math.max(MARGIN, vp.Y - h - MARGIN))
		root.Position = UDim2.fromOffset(x / scale, y / scale)
	end
	local function ensureFollow()
		follow()
		if not followConn then
			followConn = RunService.RenderStepped:Connect(follow)
		end
	end
	local function stopFollow()
		if followConn then
			followConn:Disconnect()
			followConn = nil
		end
	end

	local function setLand(visible)
		ownerRow.Visible = visible
		terrainRow.Visible = visible
		societyRow.Visible = visible
		devRow.Visible = visible
	end

	local function showProvince(info)
		setLand(true)
		nameRow.Text = info.name or "Province"
		ownerRow.Text = info.owner or ""
		ownerRow.Visible = (info.owner or "") ~= ""
		terrainRow.Text = info.terrain or ""
		terrainRow.Visible = (info.terrain or "") ~= ""
		societyRow.Text = info.society or ""
		societyRow.Visible = (info.society or "") ~= ""
		devRow.Text = info.dev or ""
		devRow.Visible = (info.dev or "") ~= ""
		root.Visible = true
		ensureFollow()
	end

	local function showWater(name)
		setLand(false)
		nameRow.Text = name or "Open Water"
		root.Visible = true
		ensureFollow()
	end

	local function hide()
		root.Visible = false
		stopFollow()
	end

	return {
		root = root,
		showProvince = showProvince,
		showWater = showWater,
		hide = hide,
		destroy = function()
			stopFollow()
			root:Destroy()
		end,
	}
end

return ProvinceTooltip
