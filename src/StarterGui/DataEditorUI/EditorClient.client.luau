local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local screen = script.Parent

local api = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("Remotes"):WaitForChild("DataEditorAPI")

-- Phase 5: the rebuilt DesignSystem editor (EditorClientV2) runs alongside this legacy one during the
-- rebuild -- legacy editor on the backtick key, the new one on backslash (\).

local ProvinceInteraction
do
	local aow = ReplicatedStorage:FindFirstChild("ArtOfWar")
	local modules = aow and aow:FindFirstChild("Modules")
	local piModule = modules and modules:FindFirstChild("ProvinceInteraction")
	if piModule then
		local ok, mod = pcall(require, piModule)
		if ok then
			ProvinceInteraction = mod
		end
	end
end

-- Province display label: "[id] Name". The id is the canonical province id — the map part
-- number (prov_<N>) after the identity collapse. The old cosmetic 5-letter code was removed.
local function provinceLabel(idOrItem, record)
	local name = (type(record) == "table" and (record.name or record.displayCityName)) or ""
	return string.format("[%s] %s", tostring(idOrItem), name)
end

local PALETTE = {
	bgDim = Color3.fromRGB(18, 20, 24),
	bgPanel = Color3.fromRGB(28, 30, 36),
	bgPanelAlt = Color3.fromRGB(40, 43, 52),
	bgInput = Color3.fromRGB(22, 24, 30),
	border = Color3.fromRGB(62, 66, 78),
	borderHot = Color3.fromRGB(200, 160, 80),
	text = Color3.fromRGB(228, 230, 235),
	textBright = Color3.fromRGB(245, 247, 250),
	textMuted = Color3.fromRGB(150, 152, 162),
	accent = Color3.fromRGB(200, 160, 80),
	accentHot = Color3.fromRGB(235, 195, 110),
	good = Color3.fromRGB(90, 160, 95),
	bad = Color3.fromRGB(200, 80, 70),
	warn = Color3.fromRGB(220, 160, 70),
}

local function px(x)
	return UDim2.fromOffset(x, 0)
end

local function newInstance(className, props, parent)
	local inst = Instance.new(className)
	for k, v in pairs(props or {}) do
		inst[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function addCorner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 4)
	c.Parent = parent
	return c
end

local function addStroke(parent, color, thickness)
	local s = Instance.new("UIStroke")
	s.Color = color or PALETTE.border
	s.Thickness = thickness or 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function addPadding(parent, n)
	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, n)
	p.PaddingRight = UDim.new(0, n)
	p.PaddingTop = UDim.new(0, n)
	p.PaddingBottom = UDim.new(0, n)
	p.Parent = parent
	return p
end

local WINDOW_MIN_W, WINDOW_MIN_H = 720, 500
local TOOLBAR_H = 104

local root = newInstance("Frame", {
	Name = "Root",
	Size = UDim2.fromOffset(960, 600),
	Position = UDim2.fromScale(0.5, 0.5),
	AnchorPoint = Vector2.new(0.5, 0.5),
	BackgroundColor3 = PALETTE.bgDim,
	BorderSizePixel = 0,
	Active = true,
	Visible = false,
	ClipsDescendants = false,
}, screen)
addCorner(root, 6)
addStroke(root, PALETTE.accent, 2)
root:SetAttribute("AoWInputSink", true)

local sizeConstraint = Instance.new("UISizeConstraint")
sizeConstraint.MinSize = Vector2.new(WINDOW_MIN_W, WINDOW_MIN_H)
sizeConstraint.Parent = root

local titleBar = newInstance("Frame", {
	Size = UDim2.new(1, 0, 0, 34),
	BackgroundColor3 = PALETTE.bgPanelAlt,
	BorderSizePixel = 0,
}, root)
addCorner(titleBar, 6)

local title = newInstance("TextLabel", {
	Size = UDim2.new(1, -120, 1, 0),
	Position = UDim2.fromOffset(14, 0),
	BackgroundTransparency = 1,
	Text = "Art of War — Data Editor",
	TextColor3 = PALETTE.accent,
	Font = Enum.Font.GothamBold,
	TextSize = 15,
	TextXAlignment = Enum.TextXAlignment.Left,
}, titleBar)

titleBar.ClipsDescendants = true

local closeBtn = newInstance("TextButton", {
	Size = UDim2.fromOffset(26, 22),
	Position = UDim2.new(1, -8, 0.5, 0),
	AnchorPoint = Vector2.new(1, 0.5),
	BackgroundColor3 = PALETTE.bad,
	BorderSizePixel = 0,
	Text = "×",
	TextColor3 = PALETTE.text,
	Font = Enum.Font.GothamBold,
	TextSize = 16,
	AutoButtonColor = true,
}, titleBar)
addCorner(closeBtn, 3)

local minimizeBtn = newInstance("TextButton", {
	Size = UDim2.fromOffset(26, 22),
	Position = UDim2.new(1, -40, 0.5, 0),
	AnchorPoint = Vector2.new(1, 0.5),
	BackgroundColor3 = PALETTE.bgPanelAlt,
	BorderSizePixel = 0,
	Text = "–",
	TextColor3 = PALETTE.accent,
	Font = Enum.Font.GothamBold,
	TextSize = 18,
	AutoButtonColor = true,
}, titleBar)
addCorner(minimizeBtn, 3)
addStroke(minimizeBtn, PALETTE.border, 1)

local tabBar = newInstance("Frame", {
	Size = UDim2.new(1, 0, 0, 32),
	Position = UDim2.fromOffset(0, 34),
	BackgroundColor3 = PALETTE.bgPanel,
	BorderSizePixel = 0,
}, root)

local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0, 0)
tabLayout.Parent = tabBar

local content = newInstance("Frame", {
	Size = UDim2.new(1, 0, 1, -(66 + TOOLBAR_H)),
	Position = UDim2.fromOffset(0, 66),
	BackgroundTransparency = 1,
	ClipsDescendants = true,
}, root)

local toolbar = newInstance("Frame", {
	Size = UDim2.new(1, 0, 0, TOOLBAR_H),
	Position = UDim2.new(0, 0, 1, 0),
	AnchorPoint = Vector2.new(0, 1),
	BackgroundColor3 = PALETTE.bgPanelAlt,
	BorderSizePixel = 0,
	Parent = root,
})

local toolbarDivider = newInstance("Frame", {
	Size = UDim2.new(1, 0, 0, 1),
	Position = UDim2.fromOffset(0, 0),
	BackgroundColor3 = PALETTE.border,
	BorderSizePixel = 0,
	Parent = toolbar,
})
toolbarDivider.BackgroundTransparency = 0.4

local statusHolder = newInstance("Frame", {
	Size = UDim2.new(1, -28, 0, 16),
	Position = UDim2.fromOffset(14, 8),
	BackgroundTransparency = 1,
	ClipsDescendants = true,
	Parent = toolbar,
})

local statusLabel = newInstance("TextLabel", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Text = "",
	TextColor3 = PALETTE.textMuted,
	Font = Enum.Font.Gotham,
	TextSize = 12,
	RichText = false,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Center,
	TextTruncate = Enum.TextTruncate.AtEnd,
}, statusHolder)

local primaryLeft, primaryRight, secondaryLeft, secondaryRight
do
	local function makeToolbarRow(yOffset, rightInset)
		return newInstance("Frame", {
			Size = UDim2.new(1, -(14 + rightInset), 0, 28),
			Position = UDim2.fromOffset(14, yOffset),
			BackgroundTransparency = 1,
			Parent = toolbar,
		})
	end
	local function makeButtonGroup(row, side)
		local group = newInstance("Frame", {
			Size = UDim2.new(0, 0, 1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(side, 0.5),
			Position = UDim2.new(side, 0, 0.5, 0),
			Parent = row,
		})
		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.Padding = UDim.new(0, 8)
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = group
		return group
	end
	local primaryRow = makeToolbarRow(32, 14)
	local secondaryRow = makeToolbarRow(68, 26)
	primaryLeft = makeButtonGroup(primaryRow, 0)
	primaryRight = makeButtonGroup(primaryRow, 1)
	secondaryLeft = makeButtonGroup(secondaryRow, 0)
	secondaryRight = makeButtonGroup(secondaryRow, 1)
end

local function viewportSize()
	local cam = workspace.CurrentCamera
	return cam and cam.ViewportSize or Vector2.new(1280, 720)
end

local function clampToViewport()
	local vp = viewportSize()
	local size = root.AbsoluteSize
	local anchor = root.AnchorPoint
	local topLeftX = root.Position.X.Offset + vp.X * root.Position.X.Scale - size.X * anchor.X
	local topLeftY = root.Position.Y.Offset + vp.Y * root.Position.Y.Scale - size.Y * anchor.Y
	topLeftX = math.clamp(topLeftX, 0, math.max(0, vp.X - size.X))
	topLeftY = math.clamp(topLeftY, 0, math.max(0, vp.Y - size.Y))
	root.AnchorPoint = Vector2.new(0, 0)
	root.Position = UDim2.fromOffset(topLeftX, topLeftY)
end

local dragHandle = newInstance("TextButton", {
	Size = UDim2.new(1, -40, 1, 0),
	Position = UDim2.fromOffset(0, 0),
	BackgroundTransparency = 1,
	Text = "",
	AutoButtonColor = false,
	ZIndex = 0,
	Parent = titleBar,
})

do
	local dragging = false
	local startMouse = Vector2.zero
	local startPos = Vector2.zero

	dragHandle.MouseButton1Down:Connect(function()
		clampToViewport()
		dragging = true
		local mp = UserInputService:GetMouseLocation()
		startMouse = Vector2.new(mp.X, mp.Y)
		startPos = Vector2.new(root.Position.X.Offset, root.Position.Y.Offset)
	end)

	UserInputService.InputChanged:Connect(function(input)
		if not dragging then
			return
		end
		if
			input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		local mp = UserInputService:GetMouseLocation()
		local delta = Vector2.new(mp.X, mp.Y) - startMouse
		local vp = viewportSize()
		local size = root.AbsoluteSize
		local x = math.clamp(startPos.X + delta.X, 0, math.max(0, vp.X - size.X))
		local y = math.clamp(startPos.Y + delta.Y, 0, math.max(0, vp.Y - size.Y))
		root.Position = UDim2.fromOffset(x, y)
	end)

	UserInputService.InputEnded:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = false
		end
	end)
end

local resizeGrip = newInstance("TextButton", {
	Size = UDim2.fromOffset(20, 20),
	Position = UDim2.new(1, -2, 1, -2),
	AnchorPoint = Vector2.new(1, 1),
	BackgroundTransparency = 1,
	Text = "⋰",
	TextColor3 = PALETTE.accent,
	TextTransparency = 0.3,
	Font = Enum.Font.GothamBold,
	TextSize = 16,
	AutoButtonColor = false,
	ZIndex = 5,
	Parent = root,
})

do
	local resizing = false
	local startMouse = Vector2.zero
	local startSize = Vector2.zero

	resizeGrip.MouseButton1Down:Connect(function()
		clampToViewport()
		resizing = true
		local mp = UserInputService:GetMouseLocation()
		startMouse = Vector2.new(mp.X, mp.Y)
		startSize = root.AbsoluteSize
	end)

	resizeGrip.MouseEnter:Connect(function()
		resizeGrip.TextTransparency = 0
	end)
	resizeGrip.MouseLeave:Connect(function()
		resizeGrip.TextTransparency = 0.3
	end)

	UserInputService.InputChanged:Connect(function(input)
		if not resizing then
			return
		end
		if
			input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		local mp = UserInputService:GetMouseLocation()
		local delta = Vector2.new(mp.X, mp.Y) - startMouse
		local vp = viewportSize()
		local posX = root.Position.X.Offset
		local posY = root.Position.Y.Offset
		local maxW = math.max(WINDOW_MIN_W, vp.X - posX)
		local maxH = math.max(WINDOW_MIN_H, vp.Y - posY)
		local w = math.clamp(startSize.X + delta.X, WINDOW_MIN_W, maxW)
		local h = math.clamp(startSize.Y + delta.Y, WINDOW_MIN_H, maxH)
		root.Size = UDim2.fromOffset(w, h)
	end)

	UserInputService.InputEnded:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			resizing = false
		end
	end)
end

local function makeButton(parent, text, bg)
	local btn = newInstance("TextButton", {
		BackgroundColor3 = bg or PALETTE.bgPanelAlt,
		BorderSizePixel = 0,
		Text = text,
		TextColor3 = PALETTE.text,
		Font = Enum.Font.GothamSemibold,
		TextSize = 13,
		AutoButtonColor = false,
		Active = true,
	}, parent)
	addCorner(btn, 3)
	addStroke(btn, PALETTE.border, 1)
	btn.MouseEnter:Connect(function()
		btn.BackgroundColor3 = (bg or PALETTE.bgPanelAlt):Lerp(PALETTE.accent, 0.3)
	end)
	btn.MouseLeave:Connect(function()
		btn.BackgroundColor3 = bg or PALETTE.bgPanelAlt
	end)
	return btn
end

local function showConfirm(opts)
	opts = opts or {}
	local accent = opts.accent or PALETTE.accent
	local overlay = newInstance("TextButton", {
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromScale(0, 0),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		ZIndex = 200,
	}, root)
	overlay:SetAttribute("AoWInputSink", true)

	local dialog = newInstance("Frame", {
		Size = UDim2.fromOffset(400, 180),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = PALETTE.bgPanel,
		BorderSizePixel = 0,
		ZIndex = 201,
	}, overlay)
	addCorner(dialog, 5)
	addStroke(dialog, accent, 2)

	newInstance("TextLabel", {
		Size = UDim2.new(1, -24, 0, 24),
		Position = UDim2.fromOffset(12, 12),
		BackgroundTransparency = 1,
		Text = opts.title or "Confirm",
		TextColor3 = accent,
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 202,
	}, dialog)

	newInstance("TextLabel", {
		Size = UDim2.new(1, -24, 0, 84),
		Position = UDim2.fromOffset(12, 42),
		BackgroundTransparency = 1,
		Text = opts.message or "",
		TextColor3 = PALETTE.text,
		Font = Enum.Font.Gotham,
		TextSize = 13,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		ZIndex = 202,
	}, dialog)

	local cancelBtn = makeButton(dialog, opts.cancelText or "No", PALETTE.bgInput)
	cancelBtn.Size = UDim2.fromOffset(110, 32)
	cancelBtn.Position = UDim2.new(1, -130, 1, -44)
	cancelBtn.ZIndex = 203

	local confirmBtn = makeButton(dialog, opts.confirmText or "Yes", accent)
	confirmBtn.Size = UDim2.fromOffset(110, 32)
	confirmBtn.Position = UDim2.new(1, -250, 1, -44)
	confirmBtn.ZIndex = 203

	local closed = false
	local function close(result)
		if closed then
			return
		end
		closed = true
		overlay:Destroy()
		if result and opts.onConfirm then
			opts.onConfirm()
		elseif not result and opts.onCancel then
			opts.onCancel()
		end
	end
	cancelBtn.MouseButton1Click:Connect(function()
		close(false)
	end)
	confirmBtn.MouseButton1Click:Connect(function()
		close(true)
	end)
	overlay.MouseButton1Click:Connect(function()
		close(false)
	end)
end

local attachTooltip
do
	local TextService = game:GetService("TextService")
	local tooltip = newInstance("TextLabel", {
		Name = "Tooltip",
		BackgroundColor3 = PALETTE.bgDim,
		BackgroundTransparency = 0.04,
		Text = "",
		TextColor3 = PALETTE.text,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		Visible = false,
		ZIndex = 2000,
		AnchorPoint = Vector2.new(0.5, 1),
		BorderSizePixel = 0,
	}, root)
	addCorner(tooltip, 4)
	addStroke(tooltip, PALETTE.border, 1)
	local tooltipToken = 0
	function attachTooltip(btn, text)
		if not btn then
			return
		end
		btn.MouseEnter:Connect(function()
			tooltipToken += 1
			local myToken = tooltipToken
			task.delay(0.35, function()
				if tooltipToken ~= myToken or not btn.Parent then
					return
				end
				local measured = TextService:GetTextSize(text, 12, Enum.Font.Gotham, Vector2.new(420, 100))
				local w = math.ceil(measured.X) + 16
				local h = math.ceil(measured.Y) + 8
				tooltip.Text = text
				tooltip.Size = UDim2.fromOffset(w, h)
				local centerX = btn.AbsolutePosition.X + btn.AbsoluteSize.X / 2 - root.AbsolutePosition.X
				local relX = math.clamp(centerX, w / 2 + 4, math.max(w / 2 + 4, root.AbsoluteSize.X - w / 2 - 4))
				local aboveTop = btn.AbsolutePosition.Y - root.AbsolutePosition.Y - 6
				if aboveTop - h < 4 then
					tooltip.AnchorPoint = Vector2.new(0.5, 0)
					tooltip.Position = UDim2.fromOffset(
						relX,
						(btn.AbsolutePosition.Y + btn.AbsoluteSize.Y) - root.AbsolutePosition.Y + 6
					)
				else
					tooltip.AnchorPoint = Vector2.new(0.5, 1)
					tooltip.Position = UDim2.fromOffset(relX, aboveTop)
				end
				tooltip.Visible = true
			end)
		end)
		btn.MouseLeave:Connect(function()
			tooltipToken += 1
			tooltip.Visible = false
		end)
	end
end

local newBtn = makeButton(primaryLeft, "➕  New", PALETTE.accent)
newBtn.Size = UDim2.fromOffset(96, 28)
newBtn.LayoutOrder = 1

local deleteBtn = makeButton(primaryLeft, "🗑  Delete", PALETTE.bad)
deleteBtn.Size = UDim2.fromOffset(100, 28)
deleteBtn.LayoutOrder = 2

local saveBtn = makeButton(primaryRight, "💾  Save", PALETTE.good)
saveBtn.Size = UDim2.fromOffset(110, 28)
saveBtn.LayoutOrder = 4

local undoBtn = makeButton(secondaryLeft, "↶  Undo", PALETTE.bgInput)
undoBtn.Size = UDim2.fromOffset(90, 28)
undoBtn.LayoutOrder = 1

local redoBtn = makeButton(secondaryLeft, "↷  Redo", PALETTE.bgInput)
redoBtn.Size = UDim2.fromOffset(90, 28)
redoBtn.LayoutOrder = 2

local reloadBtn = makeButton(secondaryRight, "⟳  Reload", PALETTE.bgInput)
reloadBtn.Size = UDim2.fromOffset(100, 28)
reloadBtn.LayoutOrder = 1

local exportBtn = makeButton(secondaryRight, "⇪  Export to Lua", PALETTE.bgInput)
exportBtn.Size = UDim2.fromOffset(140, 28)
exportBtn.LayoutOrder = 2

attachTooltip(newBtn, "Create a new record in this tab")
attachTooltip(deleteBtn, "Delete the selected record")
attachTooltip(saveBtn, "Save your draft and publish all changes to the live map")
attachTooltip(undoBtn, "Undo the last change  ·  Ctrl+Z")
attachTooltip(redoBtn, "Redo the last undone change  ·  Ctrl+Y")
attachTooltip(reloadBtn, "Reload everything fresh from the saved data")
attachTooltip(exportBtn, "Write your changes out to the Lua source modules")

local state = {
	snapshot = nil,
	currentTab = "countries",
	selectedCountryTag = nil,
	selectedProvinceId = nil,
	pendingProvinces = {},
	armedTag = nil,
	overwriteArmedFor = nil,
	dirty = false,
}

local refresh
local paintRefresh
local pendingProvincesAPI

local WRITE_COMMANDS_LOCAL = {
	addCountry = true,
	updateCountry = true,
	removeCountry = true,
	addProvince = true,
	updateProvince = true,
	removeProvince = true,
	addCulture = true,
	updateCulture = true,
	removeCulture = true,
	addReligion = true,
	updateReligion = true,
	removeReligion = true,
	addIdeology = true,
	updateIdeology = true,
	removeIdeology = true,
	addGovernmentType = true,
	updateGovernmentType = true,
	removeGovernmentType = true,
	assignProvince = true,
	mapProvinceToPart = true,
	setTileOwner = true,
	assignBatch = true,
	assignProvinceField = true,
	assignProvinceFieldBatch = true,
	undo = true,
	redo = true,
}

local TITLE_BASE = "Art of War — Data Editor"
local function markDirty(flag)
	state.dirty = flag and true or false
	title.Text = state.dirty and (TITLE_BASE .. "  *") or TITLE_BASE
end

local function sanitizeStatus(msg)
	if msg == nil then
		return ""
	end
	local s = tostring(msg)
	s = s:gsub("<[^>]->", " ")
	s = s:gsub("%s+", " ")
	s = s:match("^%s*(.-)%s*$") or s
	if #s > 160 then
		s = s:sub(1, 157) .. "…"
	end
	return s
end

local logBuffer = {}
local logSink = nil
local LOG_MAX = 400

local function pushLog(msg, color)
	local entry = { ts = os.date("%H:%M:%S"), msg = sanitizeStatus(msg), color = color or PALETTE.textMuted }
	table.insert(logBuffer, entry)
	while #logBuffer > LOG_MAX do
		table.remove(logBuffer, 1)
	end
	if logSink then
		logSink(entry)
	end
end

local function setStatus(msg, color)
	statusLabel.Text = sanitizeStatus(msg)
	statusLabel.TextColor3 = color or PALETTE.textMuted
	if msg ~= nil and msg ~= "" then
		pushLog(msg, color)
	end
end

local PAINT_REFRESH_DELAY = 0.35
local OVERWRITE_CONFIRM_WINDOW = 5

local paintRefreshGen = 0
local paintBurst = { count = 0, tag = nil }
local pendingOverwrite = nil

local function resetPaintBurst()
	paintBurst.count = 0
	paintBurst.tag = nil
end

local function bumpPaintBurst(tag)
	if paintBurst.tag ~= tag then
		paintBurst.tag = tag
		paintBurst.count = 1
	else
		paintBurst.count = paintBurst.count + 1
	end
	setStatus(
		string.format("Painted %d tile%s for %s", paintBurst.count, paintBurst.count == 1 and "" or "s", tostring(tag)),
		PALETTE.good
	)
end

paintRefresh = function()
	paintRefreshGen += 1
	local gen = paintRefreshGen
	task.delay(PAINT_REFRESH_DELAY, function()
		if gen ~= paintRefreshGen then
			return
		end
		if pendingProvincesAPI and pendingProvincesAPI.refresh then
			pendingProvincesAPI.refresh()
		end
		resetPaintBurst()
	end)
end

local function ownerOf(partName)
	local map = workspace:FindFirstChild("ArtOfWarMap")
	local provinces = map and map:FindFirstChild("Provinces")
	local part = provinces and provinces:FindFirstChild(partName)
	if not part then
		return nil
	end
	local owner = part:GetAttribute("owner")
	if type(owner) ~= "string" or owner == "" or owner == "NONE" then
		return nil
	end
	return owner
end

local function shouldConfirmOverwrite(currentOwner, newTag)
	if not currentOwner or currentOwner == newTag then
		return false
	end
	if state.overwriteArmedFor == newTag then
		return false
	end
	return true
end

local function armOverwrite(tag)
	state.overwriteArmedFor = tag
end

local function disarmOverwrite()
	state.overwriteArmedFor = nil
	pendingOverwrite = nil
end

local CALL_OK = setmetatable({}, {
	__tostring = function()
		return "<CALL_OK>"
	end,
})

local function call(command, payload)
	local ok, response = pcall(function()
		return api:InvokeServer(command, payload)
	end)
	if not ok then
		setStatus("remote error: " .. tostring(response), PALETTE.bad)
		return nil
	end
	if type(response) == "table" and response.ok == false then
		setStatus(response.error or "error", PALETTE.bad)
		return nil
	end
	if WRITE_COMMANDS_LOCAL[command] then
		markDirty(true)
	elseif command == "save" then
		markDirty(false)
	end
	if response and response.result ~= nil then
		return response.result
	end
	return CALL_OK
end

local tabs = {}
local function setTab(key)
	state.currentTab = key
	for k, def in pairs(tabs) do
		def.button.BackgroundColor3 = k == key and PALETTE.bgDim or PALETTE.bgPanel
		def.button.TextColor3 = k == key and PALETTE.accent or PALETTE.textMuted
		def.body.Visible = k == key
	end
end

local function makeTab(key, label)
	local btn = newInstance("TextButton", {
		Size = UDim2.fromOffset(0, 32),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = PALETTE.bgPanel,
		BorderSizePixel = 0,
		Text = label,
		TextColor3 = PALETTE.textMuted,
		Font = Enum.Font.GothamSemibold,
		TextSize = 13,
		AutoButtonColor = false,
	}, tabBar)

	local btnPad = Instance.new("UIPadding")
	btnPad.PaddingLeft = UDim.new(0, 14)
	btnPad.PaddingRight = UDim.new(0, 14)
	btnPad.Parent = btn

	local body = newInstance("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
	}, content)

	tabs[key] = { button = btn, body = body }
	btn.MouseButton1Click:Connect(function()
		setTab(key)
	end)
	return body
end

local countriesBody = makeTab("countries", "Countries")
local provincesBody = makeTab("provinces", "Provinces")
local mappingBody = makeTab("mapping", "Mapping")
local dataStoreBody = makeTab("datastore", "DataStore")
local culturesBody = makeTab("cultures", "Cultures")
local religionsBody = makeTab("religions", "Religions")
local ideologiesBody = makeTab("ideologies", "Ideologies")
local governmentsBody = makeTab("governments", "Governments")
local logsBody = makeTab("logs", "Logs")

local function makeColumn(parent, widthOffset, xOffset)
	return newInstance("Frame", {
		Size = UDim2.new(0, widthOffset, 1, 0),
		Position = UDim2.fromOffset(xOffset, 0),
		BackgroundColor3 = PALETTE.bgPanel,
		BorderSizePixel = 0,
	}, parent)
end

local function makeListColumn(parent)
	local col = makeColumn(parent, 260, 0)
	local search = newInstance("TextBox", {
		Size = UDim2.new(1, -20, 0, 28),
		Position = UDim2.fromOffset(10, 10),
		BackgroundColor3 = PALETTE.bgInput,
		BorderSizePixel = 0,
		PlaceholderText = "Search…",
		PlaceholderColor3 = PALETTE.textMuted,
		Text = "",
		TextColor3 = PALETTE.text,
		Font = Enum.Font.Gotham,
		TextSize = 13,
		ClearTextOnFocus = false,
	}, col)
	addCorner(search, 3)
	addStroke(search, PALETTE.border, 1)
	addPadding(search, 8)

	local scroll = newInstance("ScrollingFrame", {
		Size = UDim2.new(1, -20, 1, -58),
		Position = UDim2.fromOffset(10, 48),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = PALETTE.accent,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, col)

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 2)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	return col, scroll, search
end

local function makeFormScroll(parent)
	local col = newInstance("Frame", {
		Size = UDim2.new(1, -260, 1, 0),
		Position = UDim2.fromOffset(260, 0),
		BackgroundColor3 = PALETTE.bgDim,
		BorderSizePixel = 0,
	}, parent)

	local scroll = newInstance("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = PALETTE.accent,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, col)
	addPadding(scroll, 16)

	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 10)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = scroll

	return col, scroll
end

local function makeRow(parent, labelText, order)
	local row = newInstance("Frame", {
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundTransparency = 1,
		LayoutOrder = order or 1,
	}, parent)
	local label = newInstance("TextLabel", {
		Size = UDim2.fromOffset(160, 28),
		BackgroundTransparency = 1,
		Text = labelText,
		TextColor3 = PALETTE.textMuted,
		Font = Enum.Font.GothamSemibold,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, row)
	return row, label
end

local function makeTextBox(row, placeholder, value)
	local box = newInstance("TextBox", {
		Size = UDim2.new(1, -170, 1, 0),
		Position = UDim2.fromOffset(160, 0),
		BackgroundColor3 = PALETTE.bgInput,
		BorderSizePixel = 0,
		PlaceholderText = placeholder or "",
		PlaceholderColor3 = PALETTE.textMuted,
		Text = value or "",
		TextColor3 = PALETTE.text,
		Font = Enum.Font.Gotham,
		TextSize = 13,
		ClearTextOnFocus = false,
	}, row)
	addCorner(box, 3)
	addStroke(box, PALETTE.border, 1)
	addPadding(box, 6)
	return box
end

local openCombo = nil

local function normalizeOption(opt)
	if type(opt) == "table" then
		return tostring(opt.id), tostring(opt.name or opt.id)
	end
	return tostring(opt), tostring(opt)
end

local function makeCombo(row, options, value, opts)
	opts = opts or {}
	local allowFreeform = opts.allowFreeform
	local onChange = opts.onChange

	local holder
	if opts.parent then
		holder = opts.parent
	else
		holder = newInstance("Frame", {
			Size = UDim2.new(1, -170, 1, 0),
			Position = UDim2.fromOffset(160, 0),
			BackgroundTransparency = 1,
		}, row)
	end

	local box = newInstance("TextBox", {
		Size = UDim2.new(1, -26, 1, 0),
		BackgroundColor3 = PALETTE.bgInput,
		BorderSizePixel = 0,
		PlaceholderText = opts.placeholder or "type to search…",
		PlaceholderColor3 = PALETTE.textMuted,
		Text = "",
		TextColor3 = PALETTE.text,
		Font = Enum.Font.Gotham,
		TextSize = 13,
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, holder)
	addCorner(box, 3)
	addStroke(box, PALETTE.border, 1)
	addPadding(box, 6)

	local chevron = newInstance("TextButton", {
		Size = UDim2.fromOffset(22, 1),
		Position = UDim2.new(1, -22, 0, 0),
		BackgroundColor3 = PALETTE.bgInput,
		BorderSizePixel = 0,
		Text = "▾",
		TextColor3 = PALETTE.textMuted,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		AutoButtonColor = false,
	}, holder)
	chevron.Size = UDim2.new(0, 22, 1, 0)
	addCorner(chevron, 3)
	addStroke(chevron, PALETTE.border, 1)

	local list = newInstance("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		Position = UDim2.new(0, 0, 1, 2),
		BackgroundColor3 = PALETTE.bgPanel,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 50,
	}, holder)
	addCorner(list, 3)
	addStroke(list, PALETTE.accent, 1)

	local scroll = newInstance("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ZIndex = 51,
	}, list)
	local layout = Instance.new("UIListLayout")
	layout.Parent = scroll

	local rowHeight = 22
	local maxRows = 8

	local selectedId = value
	local selectedName = nil
	local programmaticSet = false

	local labelMap = {}
	for _, opt in ipairs(options) do
		local oid, oname = normalizeOption(opt)
		labelMap[oid] = oname
	end

	local function labelFor(id)
		return labelMap[tostring(id)] or tostring(id)
	end

	local function displayText(id)
		if id == nil or id == "" then
			return ""
		end
		local name = labelFor(id)
		if name ~= tostring(id) then
			if opts.hideIdSuffix then
				return name
			end
			return name .. "  (" .. tostring(id) .. ")"
		end
		return tostring(id)
	end

	local function setBoxText(s)
		programmaticSet = true
		box.Text = s
	end

	if selectedId ~= nil and selectedId ~= "" then
		selectedName = labelFor(selectedId)
		setBoxText(displayText(selectedId))
	end

	local function closeList()
		list.Visible = false
		if openCombo == list then
			openCombo = nil
		end
	end

	local rowEntries
	local poolSize
	local buttonPool
	local truncatedHint

	local function ensureData()
		if rowEntries then
			return
		end
		rowEntries = {}
		for _, opt in ipairs(options) do
			local id, name = normalizeOption(opt)
			rowEntries[#rowEntries + 1] = { id = id, name = name }
		end
		poolSize = math.min(opts.maxButtons or #rowEntries, #rowEntries)
	end

	local function ensurePool()
		if buttonPool then
			return
		end
		ensureData()
		buttonPool = {}
		for i = 1, poolSize do
			local btn = newInstance("TextButton", {
				Size = UDim2.new(1, -4, 0, rowHeight),
				BackgroundColor3 = PALETTE.bgPanel,
				BorderSizePixel = 0,
				Text = "",
				TextColor3 = PALETTE.text,
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left,
				AutoButtonColor = false,
				ZIndex = 52,
				Visible = false,
				LayoutOrder = i,
			}, scroll)
			btn:SetAttribute("optionId", "")
			btn:SetAttribute("optionName", "")
			btn.MouseEnter:Connect(function()
				btn.BackgroundColor3 = PALETTE.bgPanelAlt
			end)
			btn.MouseLeave:Connect(function()
				btn.BackgroundColor3 = PALETTE.bgPanel
			end)
			btn.MouseButton1Click:Connect(function()
				local id = btn:GetAttribute("optionId")
				if not id or id == "" then
					return
				end
				selectedId = id
				selectedName = btn:GetAttribute("optionName")
				setBoxText(displayText(id))
				closeList()
				if onChange then
					onChange(id)
				end
			end)
			buttonPool[i] = btn
		end
		if poolSize < #rowEntries then
			truncatedHint = newInstance("TextLabel", {
				Size = UDim2.new(1, -4, 0, 18),
				BackgroundTransparency = 1,
				Text = "",
				TextColor3 = PALETTE.textMuted,
				Font = Enum.Font.Gotham,
				TextSize = 10,
				TextXAlignment = Enum.TextXAlignment.Center,
				ZIndex = 52,
				LayoutOrder = poolSize + 1,
			}, scroll)
		end
	end

	local function bindButton(idx, entry)
		local btn = buttonPool and buttonPool[idx]
		if not btn then
			return
		end
		if entry then
			local label = "  " .. entry.name
			if not opts.hideIdSuffix then
				label = label .. "  (" .. entry.id .. ")"
			end
			btn.Text = label
			btn:SetAttribute("optionId", entry.id)
			btn:SetAttribute("optionName", entry.name)
			btn.Visible = true
		else
			btn.Visible = false
			btn:SetAttribute("optionId", "")
			btn:SetAttribute("optionName", "")
		end
	end

	local function applyFilter(query)
		ensurePool()
		query = (query or ""):lower()
		local matchedTotal = 0
		local boundCount = 0
		for _, entry in ipairs(rowEntries) do
			local match = query == ""
				or entry.id:lower():find(query, 1, true) ~= nil
				or entry.name:lower():find(query, 1, true) ~= nil
			if match then
				matchedTotal += 1
				if boundCount < poolSize then
					boundCount += 1
					bindButton(boundCount, entry)
				end
			end
		end
		for i = boundCount + 1, poolSize do
			bindButton(i, nil)
		end
		local listRows = math.min(maxRows, math.max(1, boundCount))
		local extraHeight = 0
		if truncatedHint then
			if matchedTotal > poolSize then
				truncatedHint.Text = string.format("…%d more — refine your search", matchedTotal - poolSize)
				truncatedHint.Visible = true
				extraHeight = 18
			else
				truncatedHint.Visible = false
			end
		end
		list.Size = UDim2.new(1, 0, 0, listRows * rowHeight + 4 + extraHeight)
	end

	local function bestMatch(query)
		if not query or query == "" then
			return nil
		end
		ensureData()
		local lower = query:lower()
		for _, entry in ipairs(rowEntries) do
			if entry.id:lower() == lower then
				return entry.id
			end
		end
		for _, entry in ipairs(rowEntries) do
			if entry.name:lower() == lower then
				return entry.id
			end
		end
		for _, entry in ipairs(rowEntries) do
			if entry.id:lower():find(lower, 1, true) or entry.name:lower():find(lower, 1, true) then
				return entry.id
			end
		end
		return nil
	end

	local function openList()
		if openCombo and openCombo ~= list then
			openCombo.Visible = false
		end
		openCombo = list
		applyFilter("")
		list.Visible = true
	end

	chevron.MouseButton1Click:Connect(function()
		if list.Visible then
			closeList()
		else
			openList()
		end
	end)

	box.Focused:Connect(openList)
	box:GetPropertyChangedSignal("Text"):Connect(function()
		if programmaticSet then
			programmaticSet = false
			applyFilter(box.Text)
			return
		end
		if not list.Visible then
			openList()
		end
		applyFilter(box.Text)
	end)
	box.FocusLost:Connect(function(enter)
		task.delay(0.12, function()
			if list.Visible then
				closeList()
			end
		end)
		task.defer(function()
			if enter and allowFreeform then
				selectedId = box.Text ~= "" and box.Text or nil
				if onChange then
					onChange(selectedId)
				end
			elseif enter then
				local raw = box.Text or ""
				local typed = raw:match("^%s*(.-)%s*$") or ""
				typed = typed:gsub("%s*%([^%)]*%)$", "")
				if typed == "" then
					if selectedId ~= nil then
						selectedId = nil
						selectedName = nil
						if onChange then
							onChange(nil)
						end
					end
				else
					local match = bestMatch(typed)
					if match and match ~= selectedId then
						selectedId = match
						selectedName = labelFor(match)
						if onChange then
							onChange(match)
						end
					end
				end
			end
			setBoxText(displayText(selectedId))
		end)
	end)

	list.Visible = false

	return {
		getValue = function()
			if allowFreeform and (not selectedId or selectedId == "") then
				local txt = box.Text
				return txt ~= "" and txt or nil
			end
			return selectedId
		end,
		setValue = function(val)
			selectedId = val
			selectedName = val and labelFor(val) or nil
			setBoxText(displayText(val))
		end,
	}
end

local function makeDropdown(row, options, value, onChange)
	return makeCombo(row, options, value, { onChange = onChange })
end

local function makeSection(parent, titleText, order)
	local section = newInstance("Frame", {
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
		LayoutOrder = order or 1,
	}, parent)
	newInstance("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = titleText,
		TextColor3 = PALETTE.accent,
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, section)
	local divider = newInstance("Frame", {
		Size = UDim2.new(1, 0, 0, 1),
		Position = UDim2.new(0, 0, 1, -1),
		BackgroundColor3 = PALETTE.border,
		BorderSizePixel = 0,
	}, section)
	return section
end

local function makeResourceList(parent, options, initialMap, layoutOrder)
	local container = newInstance("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder or 1,
	}, parent)

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = container

	local entries = {}
	local nextOrder = 0
	local emptyHint
	local addBtn

	local function refreshEmptyHint()
		if not emptyHint then
			return
		end
		emptyHint.Visible = #entries == 0
	end

	local function makeRow(goodId, qty)
		nextOrder += 1
		local row = newInstance("Frame", {
			Size = UDim2.new(1, 0, 0, 30),
			BackgroundColor3 = PALETTE.bgPanelAlt,
			BorderSizePixel = 0,
			LayoutOrder = nextOrder,
		}, container)
		addCorner(row, 3)
		addStroke(row, PALETTE.border, 1)

		local rowPad = Instance.new("UIPadding")
		rowPad.PaddingLeft = UDim.new(0, 6)
		rowPad.PaddingRight = UDim.new(0, 6)
		rowPad.Parent = row

		local comboHolder = newInstance("Frame", {
			Size = UDim2.new(1, -126, 0, 22),
			Position = UDim2.fromOffset(0, 4),
			BackgroundTransparency = 1,
		}, row)
		local combo = makeCombo(nil, options, goodId, { parent = comboHolder, placeholder = "resource…" })

		local qtyBox = newInstance("TextBox", {
			Size = UDim2.fromOffset(86, 22),
			Position = UDim2.new(1, -118, 0, 4),
			BackgroundColor3 = PALETTE.bgInput,
			BorderSizePixel = 0,
			PlaceholderText = "qty",
			PlaceholderColor3 = PALETTE.textMuted,
			Text = tostring(tonumber(qty) or 1),
			TextColor3 = PALETTE.text,
			Font = Enum.Font.Code,
			TextSize = 13,
			ClearTextOnFocus = false,
			TextXAlignment = Enum.TextXAlignment.Center,
		}, row)
		addCorner(qtyBox, 3)
		addStroke(qtyBox, PALETTE.border, 1)
		addPadding(qtyBox, 4)

		local rmBtn = makeButton(row, "×", PALETTE.bad)
		rmBtn.Size = UDim2.fromOffset(26, 22)
		rmBtn.Position = UDim2.new(1, -26, 0, 4)
		rmBtn.TextSize = 16

		local entry = { combo = combo, qtyBox = qtyBox, frame = row }
		table.insert(entries, entry)
		refreshEmptyHint()

		rmBtn.MouseButton1Click:Connect(function()
			for i, e in ipairs(entries) do
				if e == entry then
					table.remove(entries, i)
					break
				end
			end
			row:Destroy()
			refreshEmptyHint()
		end)

		return entry
	end

	emptyHint = newInstance("TextLabel", {
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		Text = "  (no resources — click + Add Resource below)",
		TextColor3 = PALETTE.textMuted,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 0,
	}, container)

	if type(initialMap) == "table" then
		local sortedKeys = {}
		for k in pairs(initialMap) do
			table.insert(sortedKeys, k)
		end
		table.sort(sortedKeys)
		for _, k in ipairs(sortedKeys) do
			makeRow(k, initialMap[k])
		end
	end
	refreshEmptyHint()

	addBtn = makeButton(container, "+ Add Resource", PALETTE.bgInput)
	addBtn.Size = UDim2.new(1, 0, 0, 26)
	addBtn.LayoutOrder = 999999
	addBtn.MouseButton1Click:Connect(function()
		local taken = {}
		for _, e in ipairs(entries) do
			local v = e.combo.getValue()
			if v then
				taken[v] = true
			end
		end
		local firstFree = nil
		for _, opt in ipairs(options) do
			local id = type(opt) == "table" and opt.id or opt
			if not taken[id] then
				firstFree = id
				break
			end
		end
		makeRow(firstFree, 1)
	end)

	return {
		getValue = function()
			local out = {}
			for _, e in ipairs(entries) do
				local id = e.combo.getValue()
				local q = tonumber(e.qtyBox.Text) or 0
				if id and id ~= "" and q > 0 then
					out[id] = q
				end
			end
			return out
		end,
	}
end

local countryListCol, countryScroll, countrySearch = makeListColumn(countriesBody)
local countryFormCol, countryForm = makeFormScroll(countriesBody)
local countryFields = {}
local countryListItems = {}

local function clearFrame(frame)
	for _, c in frame:GetChildren() do
		if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then
			c:Destroy()
		end
	end
end

local function prettyTileName(partName)
	return (partName:gsub("^prov_", ""):gsub("_", " "))
end

local function collectAllMapTiles()
	local list = {}
	local map = workspace:FindFirstChild("ArtOfWarMap")
	local folder = map and map:FindFirstChild("Provinces")
	if not folder then
		return list
	end
	for _, part in folder:GetChildren() do
		if part:IsA("BasePart") then
			local pretty = prettyTileName(part.Name)
			local partId = tonumber(part.Name:match("prov_(%d+)"))
			list[part.Name] = {
				partName = part.Name,
				display = partId and ("[" .. partId .. "] " .. pretty) or pretty,
				partId = partId,
				seedId = part:GetAttribute("province_id"),
			}
		end
	end
	return list
end

local function collectOwnedEntries(tag)
	local list = {}
	if not state.snapshot or not tag then
		return list
	end
	for id, prov in pairs(state.snapshot.provinces) do
		if prov.ownerTag == tag then
			table.insert(list, {
				kind = "seed",
				id = tonumber(id) or id,
				display = provinceLabel(id, prov),
				sortKey = tostring(prov.name or id),
			})
		end
	end
	if state.snapshot.tileOwners then
		for partName, ownerTag in pairs(state.snapshot.tileOwners) do
			if ownerTag == tag then
				table.insert(list, {
					kind = "tile",
					partName = partName,
					display = prettyTileName(partName),
					sortKey = prettyTileName(partName),
				})
			end
		end
	end
	table.sort(list, function(a, b)
		return a.sortKey < b.sortKey
	end)
	return list
end

pendingProvincesAPI = nil

local function buildProvincesSection(parent, ctx, order)
	local tag = ctx.tag
	local isPending = ctx.pending == true

	makeSection(parent, "PROVINCES", order)

	local armRow = newInstance("Frame", {
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
		LayoutOrder = (order or 1) + 1,
	}, parent)

	local armBtn = makeButton(armRow, "", PALETTE.bgInput)
	armBtn.Size = UDim2.new(1, 0, 1, 0)
	armBtn.TextXAlignment = Enum.TextXAlignment.Center
	armBtn.TextSize = 12
	armBtn.Font = Enum.Font.GothamSemibold

	local armStroke = armBtn:FindFirstChildOfClass("UIStroke")

	attachTooltip(
		armBtn,
		isPending and "Click tiles on the map to queue them for this new country"
			or "Click tiles on the map to assign them to this country"
	)

	local function isArmed()
		return state.armedTag == tag
	end

	local function refreshArmBtn()
		if isArmed() then
			armBtn.Text = "■  STOP click-to-assign  —  map clicks ARMED"
			armBtn.BackgroundColor3 = PALETTE.accent
			armBtn.TextColor3 = PALETTE.bgDim
			if armStroke then
				armStroke.Color = PALETTE.accentHot
			end
		else
			armBtn.Text = isPending and "▶  Arm map-click to queue tiles"
				or ("▶  Arm map-click to assign tiles to " .. tostring(tag))
			armBtn.BackgroundColor3 = PALETTE.bgInput
			armBtn.TextColor3 = PALETTE.text
			if armStroke then
				armStroke.Color = PALETTE.border
			end
		end
	end
	refreshArmBtn()

	local function applyArmedHighlight()
		if not ProvinceInteraction or not ProvinceInteraction.setSelectColor then
			return
		end
		local snap = state.snapshot
		local country = snap and snap.countries and snap.countries[tag]
		local rgb = country and country.color
		if type(rgb) ~= "table" then
			return
		end
		local r = (tonumber(rgb[1]) or 128) / 255
		local g = (tonumber(rgb[2]) or 128) / 255
		local b = (tonumber(rgb[3]) or 128) / 255
		local fill = Color3.new(r, g, b)
		local outline = Color3.new(math.min(r + 0.2, 1), math.min(g + 0.2, 1), math.min(b + 0.2, 1))
		ProvinceInteraction.setSelectColor(fill, outline)
	end

	local function clearArmedHighlight()
		if ProvinceInteraction and ProvinceInteraction.resetSelectColor then
			ProvinceInteraction.resetSelectColor()
		end
	end

	armBtn.MouseButton1Click:Connect(function()
		if isArmed() then
			state.armedTag = nil
			refreshArmBtn()
			clearArmedHighlight()
			disarmOverwrite()
			setStatus("Click-to-assign disarmed — map clicks ignored", PALETTE.textMuted)
		else
			state.armedTag = tag
			refreshArmBtn()
			applyArmedHighlight()
			setStatus("Click-to-assign armed for " .. tostring(tag) .. " — click tiles on the map", PALETTE.accent)
		end
	end)

	local listHolder = newInstance("Frame", {
		Size = UDim2.new(1, 0, 0, 168),
		BackgroundColor3 = PALETTE.bgPanel,
		BorderSizePixel = 0,
		LayoutOrder = (order or 1) + 2,
	}, parent)
	addCorner(listHolder, 3)
	addStroke(listHolder, PALETTE.border, 1)

	local scroll = newInstance("ScrollingFrame", {
		Size = UDim2.new(1, -8, 1, -8),
		Position = UDim2.fromOffset(4, 4),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = PALETTE.accent,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, listHolder)

	local scrollLayout = Instance.new("UIListLayout")
	scrollLayout.Padding = UDim.new(0, 2)
	scrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
	scrollLayout.Parent = scroll

	local hintLabel = newInstance("TextLabel", {
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundTransparency = 1,
		Text = "Arm map-click above, then tap any tile to assign it.",
		TextColor3 = PALETTE.textMuted,
		Font = Enum.Font.Gotham,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = (order or 1) + 4,
	}, parent)

	local function renderList()
		for _, c in scroll:GetChildren() do
			if not c:IsA("UIListLayout") then
				c:Destroy()
			end
		end

		local entries
		if isPending then
			entries = {}
			for _, item in ipairs(state.pendingProvinces) do
				if type(item) == "table" then
					if not item.display or item.display == "" then
						if item.kind == "seed" and item.id then
							local prov = state.snapshot.provinces[item.id]
							item.display = prov and provinceLabel(item.id, prov) or ("Province " .. tostring(item.id))
						elseif item.kind == "tile" and item.partName then
							item.display = prettyTileName(item.partName)
						else
							item.display = "?"
						end
					end
					table.insert(entries, item)
				else
					local prov = state.snapshot.provinces[item]
					if prov then
						table.insert(entries, {
							kind = "seed",
							id = item,
							display = provinceLabel(item, prov),
						})
					end
				end
			end
		else
			entries = collectOwnedEntries(tag)
		end

		if #entries == 0 then
			newInstance("TextLabel", {
				Size = UDim2.new(1, -8, 0, 28),
				BackgroundTransparency = 1,
				Text = isPending and "  (no provinces queued — add below or click on the map)"
					or "  (no provinces owned)",
				TextColor3 = PALETTE.textMuted,
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left,
				LayoutOrder = 1,
			}, scroll)
			return
		end

		for idx, entry in ipairs(entries) do
			local rowFrame = newInstance("Frame", {
				Size = UDim2.new(1, -8, 0, 26),
				BackgroundColor3 = PALETTE.bgPanelAlt,
				BorderSizePixel = 0,
				LayoutOrder = idx,
			}, scroll)
			addCorner(rowFrame, 2)

			newInstance("TextLabel", {
				Size = UDim2.new(1, -72, 1, 0),
				Position = UDim2.fromOffset(8, 0),
				BackgroundTransparency = 1,
				Text = entry.display,
				TextColor3 = entry.kind == "seed" and PALETTE.text or PALETTE.textMuted,
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left,
			}, rowFrame)

			local removeBtn = makeButton(rowFrame, "Remove", PALETTE.bgInput)
			removeBtn.Size = UDim2.fromOffset(64, 20)
			removeBtn.Position = UDim2.new(1, -4, 0.5, 0)
			removeBtn.AnchorPoint = Vector2.new(1, 0.5)
			removeBtn.TextSize = 11
			removeBtn.MouseButton1Click:Connect(function()
				if isPending then
					for i, queued in ipairs(state.pendingProvinces) do
						local match = type(queued) == "table"
								and ((queued.kind == entry.kind) and (queued.kind == "seed" and queued.id == entry.id or queued.kind == "tile" and queued.partName == entry.partName))
							or queued == entry.id
						if match then
							table.remove(state.pendingProvinces, i)
							break
						end
					end
					setStatus("Removed from queue: " .. entry.display, PALETTE.warn)
					renderList()
				elseif entry.kind == "seed" then
					if call("assignProvince", { id = entry.id, ownerTag = "NONE" }) ~= nil then
						setStatus(string.format("Province %s released from %s", tostring(entry.id), tag), PALETTE.warn)
						refresh()
					end
				else
					if call("setTileOwner", { partName = entry.partName, ownerTag = "NONE" }) ~= nil then
						setStatus(string.format("Tile %s released from %s", entry.display, tag), PALETTE.warn)
						refresh()
					end
				end
			end)
		end
	end

	local controls = newInstance("Frame", {
		Size = UDim2.new(1, 0, 0, 36),
		BackgroundTransparency = 1,
		LayoutOrder = (order or 1) + 3,
	}, parent)

	local pickerOptions = {}
	local seededEu4Ids = {}
	if state.snapshot.eu4Map then
		for _, eu4Pid in pairs(state.snapshot.eu4Map) do
			seededEu4Ids[tostring(eu4Pid)] = true
		end
	end
	local tileOwners = state.snapshot.tileOwners or {}

	for id, prov in pairs(state.snapshot.provinces) do
		local isOwned = prov.ownerTag == tag
		if not isOwned then
			local ownerLabel = (prov.ownerTag == nil or prov.ownerTag == "NONE") and "unowned" or prov.ownerTag
			table.insert(pickerOptions, {
				id = "seed:" .. tostring(id),
				name = string.format("%s (%s)", provinceLabel(id, prov), ownerLabel),
				sortKey = tostring(prov.name or id):lower(),
			})
		end
	end

	local allTiles = collectAllMapTiles()
	for partName, info in pairs(allTiles) do
		local eu4PidStr = partName:match("prov_(%d+)")
		local isSeededPart = eu4PidStr and seededEu4Ids[tostring(tonumber(eu4PidStr))]
		if not isSeededPart then
			local owner = tileOwners[partName]
			if owner ~= tag then
				local ownerLabel = (owner == nil or owner == "" or owner == "NONE") and "unowned" or owner
				table.insert(pickerOptions, {
					id = "tile:" .. partName,
					name = string.format("%s (%s)", info.display, ownerLabel),
					sortKey = info.display:lower(),
				})
			end
		end
	end
	table.sort(pickerOptions, function(a, b)
		return a.sortKey < b.sortKey
	end)

	local picker = makeCombo(controls, pickerOptions, nil, { placeholder = "search any tile…", maxButtons = 200 })

	local assignBtn = makeButton(controls, isPending and "Queue for new country" or ("Assign to " .. tag), PALETTE.good)
	assignBtn.Size = UDim2.fromOffset(170, 28)
	assignBtn.Position = UDim2.new(1, 0, 0, 0)
	assignBtn.AnchorPoint = Vector2.new(1, 0)

	local pickerHolder = controls:FindFirstChildOfClass("Frame")
	if pickerHolder then
		pickerHolder.Size = UDim2.new(1, -180, 1, 0)
		pickerHolder.Position = UDim2.fromOffset(0, 0)
	end

	local function tryAddSeed(pid)
		pid = tonumber(pid) or pid
		local province = state.snapshot.provinces[pid]
		if not province then
			setStatus("unknown seed province " .. tostring(pid), PALETTE.warn)
			return
		end
		if isPending then
			for _, existing in ipairs(state.pendingProvinces) do
				if type(existing) == "table" and existing.kind == "seed" and existing.id == pid then
					setStatus("already queued", PALETTE.warn)
					return
				end
				if existing == pid then
					setStatus("already queued", PALETTE.warn)
					return
				end
			end
			table.insert(state.pendingProvinces, {
				kind = "seed",
				id = pid,
				display = provinceLabel(pid, province),
			})
			setStatus(string.format("Province %s queued for new country", tostring(pid)), PALETTE.good)
			renderList()
			return
		end
		local currentOwner = province.ownerTag
		if currentOwner == "NONE" or currentOwner == "" then
			currentOwner = nil
		end
		if shouldConfirmOverwrite(currentOwner, tag) then
			local now = os.clock()
			local key = "seed:" .. tostring(pid)
			if
				pendingOverwrite
				and pendingOverwrite.key == key
				and now - pendingOverwrite.at < OVERWRITE_CONFIRM_WINDOW
			then
				pendingOverwrite = nil
				armOverwrite(tag)
			else
				pendingOverwrite = { key = key, at = now }
				setStatus(
					string.format(
						"Province %s belongs to %s — click again within %ds to take it for %s",
						tostring(pid),
						tostring(currentOwner),
						OVERWRITE_CONFIRM_WINDOW,
						tag
					),
					PALETTE.warn
				)
				return
			end
		end
		if call("assignProvince", { id = pid, ownerTag = tag }) ~= nil then
			if state.snapshot and state.snapshot.provinces and state.snapshot.provinces[pid] then
				state.snapshot.provinces[pid].ownerTag = tag
			end
			bumpPaintBurst(tag)
			paintRefresh()
		end
	end

	local function tryAddTile(partName)
		if type(partName) ~= "string" or partName == "" then
			setStatus("invalid tile reference", PALETTE.warn)
			return
		end
		if isPending then
			for _, existing in ipairs(state.pendingProvinces) do
				if type(existing) == "table" and existing.kind == "tile" and existing.partName == partName then
					setStatus("already queued", PALETTE.warn)
					return
				end
			end
			table.insert(state.pendingProvinces, {
				kind = "tile",
				partName = partName,
				display = prettyTileName(partName),
			})
			setStatus(string.format("Tile %s queued for new country", prettyTileName(partName)), PALETTE.good)
			renderList()
			return
		end
		local currentOwner = ownerOf(partName)
		if shouldConfirmOverwrite(currentOwner, tag) then
			local now = os.clock()
			local key = "tile:" .. partName
			if
				pendingOverwrite
				and pendingOverwrite.key == key
				and now - pendingOverwrite.at < OVERWRITE_CONFIRM_WINDOW
			then
				pendingOverwrite = nil
				armOverwrite(tag)
			else
				pendingOverwrite = { key = key, at = now }
				setStatus(
					string.format(
						"%s belongs to %s — click again within %ds to take it for %s",
						prettyTileName(partName),
						tostring(currentOwner),
						OVERWRITE_CONFIRM_WINDOW,
						tag
					),
					PALETTE.warn
				)
				return
			end
		end
		if call("setTileOwner", { partName = partName, ownerTag = tag }) ~= nil then
			if state.snapshot then
				state.snapshot.tileOwners = state.snapshot.tileOwners or {}
				state.snapshot.tileOwners[partName] = tag
			end
			bumpPaintBurst(tag)
			paintRefresh()
		end
	end

	local function tryAddFromMap(part)
		if not part then
			return
		end
		local seedPid = part:GetAttribute("province_id")
		if seedPid then
			tryAddSeed(seedPid)
		else
			tryAddTile(part.Name)
		end
	end

	local function tryRemoveFromMap(part)
		if not part then
			return
		end
		local seedPid = part:GetAttribute("province_id")
		if isPending then
			local removed = false
			for i, item in ipairs(state.pendingProvinces) do
				if type(item) == "table" then
					local match = (seedPid and item.kind == "seed" and item.id == seedPid)
						or (item.kind == "tile" and item.partName == part.Name)
					if match then
						table.remove(state.pendingProvinces, i)
						removed = true
						break
					end
				end
			end
			if removed then
				setStatus("Unqueued from new country", PALETTE.warn)
				renderList()
			end
			return
		end
		if seedPid then
			if call("assignProvince", { id = seedPid, ownerTag = "NONE" }) ~= nil then
				if state.snapshot and state.snapshot.provinces and state.snapshot.provinces[seedPid] then
					state.snapshot.provinces[seedPid].ownerTag = "NONE"
				end
				setStatus(string.format("Released province %s", tostring(seedPid)), PALETTE.warn)
				paintRefresh()
			end
		else
			if call("setTileOwner", { partName = part.Name, ownerTag = "NONE" }) ~= nil then
				if state.snapshot and state.snapshot.tileOwners then
					state.snapshot.tileOwners[part.Name] = nil
				end
				setStatus(string.format("Released tile %s", prettyTileName(part.Name)), PALETTE.warn)
				paintRefresh()
			end
		end
	end

	local function bulkAssign(parts)
		if not parts or #parts == 0 then
			return
		end
		local items = {}
		for _, part in ipairs(parts) do
			if part:IsA("BasePart") then
				local seedPid = part:GetAttribute("province_id")
				if seedPid then
					table.insert(items, { kind = "seed", id = seedPid })
				else
					table.insert(items, { kind = "tile", partName = part.Name })
				end
			end
		end
		if #items == 0 then
			return
		end
		if isPending then
			local added = 0
			for _, it in ipairs(items) do
				local exists = false
				for _, existing in ipairs(state.pendingProvinces) do
					if type(existing) == "table" and existing.kind == it.kind then
						if
							(it.kind == "seed" and existing.id == it.id)
							or (it.kind == "tile" and existing.partName == it.partName)
						then
							exists = true
							break
						end
					end
				end
				if not exists then
					if it.kind == "seed" then
						local prov = state.snapshot.provinces[it.id]
						table.insert(state.pendingProvinces, {
							kind = "seed",
							id = it.id,
							display = prov and provinceLabel(it.id, prov) or ("Province " .. tostring(it.id)),
						})
					else
						table.insert(state.pendingProvinces, {
							kind = "tile",
							partName = it.partName,
							display = prettyTileName(it.partName),
						})
					end
					added += 1
				end
			end
			setStatus(string.format("Queued %d for new country", added), PALETTE.good)
			renderList()
			if ProvinceInteraction and ProvinceInteraction.clearMultiSelection then
				ProvinceInteraction.clearMultiSelection()
			end
			return
		end
		local result = call("assignBatch", { ownerTag = tag, items = items })
		if type(result) == "table" then
			local n = result.processed or 0
			setStatus(string.format("Bulk assigned %d to %s", n, tag), PALETTE.good)
			paintRefresh()
			if ProvinceInteraction and ProvinceInteraction.clearMultiSelection then
				ProvinceInteraction.clearMultiSelection()
			end
		end
	end

	local multiAssignRow = newInstance("Frame", {
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
		LayoutOrder = (order or 1) + 5,
	}, parent)

	local multiAssignBtn = makeButton(multiAssignRow, "", PALETTE.good)
	multiAssignBtn.Size = UDim2.new(1, 0, 1, 0)
	multiAssignBtn.TextSize = 12
	multiAssignBtn.Visible = false
	multiAssignBtn.MouseButton1Click:Connect(function()
		if not ProvinceInteraction or not ProvinceInteraction.getMultiSelection then
			return
		end
		local sel = ProvinceInteraction.getMultiSelection()
		if #sel < 2 then
			return
		end
		showConfirm({
			title = "Bulk assign?",
			message = string.format(
				"Assign %d shift-selected tiles to %s?",
				#sel,
				isPending and "the new country" or tag
			),
			confirmText = "Assign all",
			cancelText = "Cancel",
			accent = PALETTE.good,
			onConfirm = function()
				bulkAssign(sel)
			end,
		})
	end)

	local unsubMulti
	if ProvinceInteraction and ProvinceInteraction.addMultiSelectListener then
		unsubMulti = ProvinceInteraction.addMultiSelectListener(function(selection)
			local n = selection and #selection or 0
			if n >= 2 then
				multiAssignBtn.Text =
					string.format("Assign %d shift-selected to %s", n, isPending and "new country" or tag)
				multiAssignBtn.Visible = true
			else
				multiAssignBtn.Visible = false
			end
		end)
	end

	assignBtn.MouseButton1Click:Connect(function()
		local value = picker.getValue()
		if not value or value == "" then
			setStatus("pick a tile first", PALETTE.warn)
			return
		end
		local kind, ref = value:match("^(%a+):(.+)$")
		if kind == "seed" then
			tryAddSeed(ref)
		elseif kind == "tile" then
			tryAddTile(ref)
		else
			setStatus("unknown picker value", PALETTE.warn)
		end
	end)

	renderList()

	pendingProvincesAPI = {
		addFromMap = tryAddFromMap,
		removeFromMap = tryRemoveFromMap,
		bulkAssign = bulkAssign,
		addSeed = tryAddSeed,
		addTile = tryAddTile,
		refresh = renderList,
		isArmed = isArmed,
		active = true,
		cleanup = function()
			if unsubMulti then
				unsubMulti()
			end
		end,
	}
end

local TECH_GROUPS = {
	{ id = "western", name = "Western" },
	{ id = "eastern", name = "Eastern" },
	{ id = "muslim", name = "Muslim" },
	{ id = "ottoman", name = "Ottoman" },
	{ id = "indian", name = "Indian" },
	{ id = "chinese", name = "Chinese" },
	{ id = "nomadic", name = "Nomadic" },
	{ id = "sub_saharan", name = "Sub-Saharan" },
	{ id = "north_american", name = "North American" },
	{ id = "mesoamerican", name = "Mesoamerican" },
	{ id = "south_american", name = "South American" },
	{ id = "andean", name = "Andean" },
	{ id = "polynesian", name = "Polynesian" },
	{ id = "aboriginal", name = "Aboriginal" },
	{ id = "high_american", name = "High American" },
}

local function rebuildCountryForm()
	clearFrame(countryForm)
	countryFields = {}
	if pendingProvincesAPI and pendingProvincesAPI.cleanup then
		pendingProvincesAPI.cleanup()
	end
	pendingProvincesAPI = nil
	local s = state.snapshot
	if not s then
		return
	end

	local country = state.selectedCountryTag and s.countries[state.selectedCountryTag] or nil
	local isNew = country == nil

	local headerOrder = 0
	makeSection(countryForm, isNew and "NEW COUNTRY" or ("EDIT  " .. state.selectedCountryTag), headerOrder)

	local function addField(order, label, mk)
		local row = makeRow(countryForm, label, order)
		local field = mk(row)
		return field
	end

	if isNew then
		state.pendingProvinces = state.pendingProvinces or {}
	else
		state.pendingProvinces = {}
	end

	buildProvincesSection(countryForm, {
		tag = isNew and "<NEW>" or state.selectedCountryTag,
		pending = isNew,
	}, 1)

	makeSection(countryForm, "IDENTIFIERS", 10)
	countryFields.tag = addField(11, "Tag (3-char)", function(row)
		local box = makeTextBox(row, "PRU", country and country.tag or "")
		box.TextEditable = isNew
		return box
	end)
	countryFields.displayName = addField(12, "Display Name", function(row)
		return makeTextBox(row, "Prussia", country and country.displayName or "")
	end)
	local capitalOptions = {}
	local seenCapitalTile = {}
	local seededEU4 = {}
	if s.eu4Map then
		for _, eu4 in pairs(s.eu4Map) do
			seededEU4[tostring(eu4)] = true
		end
	end
	for pid, p in pairs(s.provinces) do
		table.insert(capitalOptions, {
			id = "P:" .. tostring(pid),
			name = string.format("[%s] %s", tostring(pid), tostring(p.name or "")),
			sortKey = string.format("1_%05d", tonumber(pid) or 0),
		})
	end
	local function pushTileOption(partName, label)
		if not partName or partName == "" or seenCapitalTile[partName] then
			return
		end
		seenCapitalTile[partName] = true
		local pretty = (partName:gsub("^prov_%d+_", "")):gsub("_", " ")
		table.insert(capitalOptions, {
			id = "T:" .. partName,
			name = string.format("%s · %s", pretty, label),
			sortKey = string.format("2_%s", pretty:lower()),
		})
	end
	if isNew then
		for _, item in ipairs(state.pendingProvinces or {}) do
			if type(item) == "table" and item.kind == "tile" and item.partName then
				pushTileOption(item.partName, "queued (auto-seed)")
			end
		end
	end
	if s.tileOwners then
		for partName in pairs(s.tileOwners) do
			pushTileOption(partName, "painted (auto-seed)")
		end
	end
	local mapRoot = workspace:FindFirstChild("ArtOfWarMap")
	local mapProv = mapRoot and mapRoot:FindFirstChild("Provinces")
	if mapProv then
		for _, part in pairs(mapProv:GetChildren()) do
			if part:IsA("BasePart") then
				local eu4Pid = part.Name:match("prov_(%d+)")
				if not eu4Pid or not seededEU4[eu4Pid] then
					pushTileOption(part.Name, "unseeded tile (auto-seed)")
				end
			end
		end
	end
	table.sort(capitalOptions, function(a, b)
		return a.sortKey < b.sortKey
	end)
	countryFields.capitalProvinceId = addField(13, "Capital Province", function(row)
		local existing
		if country and country.capitalProvinceId ~= nil then
			existing = "P:" .. tostring(country.capitalProvinceId)
		end
		return makeCombo(row, capitalOptions, existing, {
			placeholder = "search name or id…",
			hideIdSuffix = true,
			maxButtons = 200,
		})
	end)
	countryFields.color = addField(14, "Color (R,G,B)", function(row)
		local c = country and country.color or { 128, 128, 128 }
		return makeTextBox(row, "40, 40, 40", string.format("%d, %d, %d", c[1] or 128, c[2] or 128, c[3] or 128))
	end)
	countryFields.flagAssetId = addField(15, "Flag Image (rbxassetid)", function(row)
		return makeTextBox(row, "rbxassetid://123456789", country and tostring(country.flagAssetId or "") or "")
	end)

	makeSection(countryForm, "IDENTITY", 20)
	countryFields.primaryCulture = addField(21, "Primary Culture", function(row)
		return makeCombo(row, s.registries.cultures, country and country.primaryCulture)
	end)
	countryFields.acceptedCultures = addField(22, "Accepted (comma-sep)", function(row)
		return makeTextBox(row, "occitan, breton", country and table.concat(country.acceptedCultures or {}, ", ") or "")
	end)
	countryFields.stateReligion = addField(23, "State Religion", function(row)
		return makeCombo(row, s.registries.religions, country and country.stateReligion)
	end)

	makeSection(countryForm, "GOVERNMENT", 30)
	countryFields.governmentForm = addField(31, "Government", function(row)
		return makeCombo(row, s.registries.governments, country and country.governmentForm)
	end)
	countryFields.ideology = addField(32, "Ideology", function(row)
		return makeCombo(row, s.registries.ideologies, country and country.ideology)
	end)
	countryFields.technologyGroup = addField(33, "Tech Group", function(row)
		return makeCombo(row, TECH_GROUPS, country and country.technologyGroup or "western", { allowFreeform = true })
	end)

	makeSection(countryForm, "STATS", 40)
	countryFields.stability = addField(41, "Stability (-3..+3)", function(row)
		return makeTextBox(row, "1", country and tostring(country.stability) or "0")
	end)
	countryFields.legitimacy = addField(42, "Legitimacy (0..100)", function(row)
		return makeTextBox(row, "80", country and tostring(country.legitimacy) or "70")
	end)
	countryFields.treasury = addField(43, "Treasury", function(row)
		return makeTextBox(row, "500", country and tostring(country.treasury) or "100")
	end)
	countryFields.manpower = addField(44, "Manpower", function(row)
		return makeTextBox(row, "120000", country and tostring(country.manpower) or "10000")
	end)
	countryFields.politicalPower = addField(45, "Political Power", function(row)
		return makeTextBox(row, "120", country and tostring(country.politicalPower) or "80")
	end)

	makeSection(countryForm, "DIPLOMACY", 50)
	countryFields.historicalRivals = addField(51, "Rivals (comma-sep tags)", function(row)
		return makeTextBox(row, "GBR, HAB", country and table.concat(country.historicalRivals or {}, ", ") or "")
	end)
	countryFields.historicalFriends = addField(52, "Friends (comma-sep tags)", function(row)
		return makeTextBox(row, "SPA", country and table.concat(country.historicalFriends or {}, ", ") or "")
	end)

	makeSection(countryForm, "STARTING TECHNOLOGIES", 60)
	do
		local techList = (s.registries and s.registries.technologies) or {}
		local owned = (country and type(country.startingTechs) == "table") and country.startingTechs or {}
		local selected = {}
		newInstance("TextLabel", {
			Size = UDim2.new(1, 0, 0, 15),
			BackgroundTransparency = 1,
			Text = "Granted at game start, on top of the global default set. Gold = granted.",
			TextColor3 = PALETTE.textMuted,
			Font = Enum.Font.Gotham,
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = 61,
		}, countryForm)
		local listScroll = newInstance("ScrollingFrame", {
			Size = UDim2.new(1, 0, 0, 200),
			BackgroundColor3 = PALETTE.bgInput,
			BorderSizePixel = 0,
			ScrollBarThickness = 5,
			ScrollBarImageColor3 = PALETTE.border,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			LayoutOrder = 62,
		}, countryForm)
		addCorner(listScroll, 6)
		local listLayout = Instance.new("UIListLayout")
		listLayout.Padding = UDim.new(0, 2)
		listLayout.SortOrder = Enum.SortOrder.LayoutOrder
		listLayout.Parent = listScroll
		local listPad = Instance.new("UIPadding")
		listPad.PaddingTop = UDim.new(0, 4)
		listPad.PaddingBottom = UDim.new(0, 4)
		listPad.PaddingLeft = UDim.new(0, 6)
		listPad.PaddingRight = UDim.new(0, 6)
		listPad.Parent = listScroll
		local rowOrder, currentTab = 0, nil
		for _, def in ipairs(techList) do
			if def.tab ~= currentTab then
				currentTab = def.tab
				rowOrder += 1
				newInstance("TextLabel", {
					Size = UDim2.new(1, 0, 0, 18),
					BackgroundTransparency = 1,
					Text = string.upper(tostring(def.tab or "other")),
					TextColor3 = PALETTE.accent,
					Font = Enum.Font.GothamBold,
					TextSize = 11,
					TextXAlignment = Enum.TextXAlignment.Left,
					LayoutOrder = rowOrder,
				}, listScroll)
			end
			rowOrder += 1
			local isGlobal = def.starting == true
			local check = (not isGlobal) and owned[def.id] == true
			if check then
				selected[def.id] = true
			end
			local row = newInstance("Frame", {
				Size = UDim2.new(1, 0, 0, 22),
				BackgroundTransparency = 1,
				LayoutOrder = rowOrder,
			}, listScroll)
			local toggle = newInstance("TextButton", {
				Size = UDim2.fromOffset(18, 18),
				Position = UDim2.fromOffset(0, 2),
				BackgroundColor3 = (isGlobal or check) and PALETTE.accent or PALETTE.bgPanel,
				AutoButtonColor = false,
				Text = "",
			}, row)
			addCorner(toggle, 4)
			addStroke(toggle, PALETTE.border, 1)
			newInstance("TextLabel", {
				Position = UDim2.fromOffset(26, 0),
				Size = UDim2.new(1, -26, 1, 0),
				BackgroundTransparency = 1,
				Text = tostring(def.name or def.id) .. (isGlobal and "   (default)" or ""),
				TextColor3 = isGlobal and PALETTE.textMuted or PALETTE.text,
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
			}, row)
			if not isGlobal then
				toggle.MouseButton1Click:Connect(function()
					if selected[def.id] then
						selected[def.id] = nil
						toggle.BackgroundColor3 = PALETTE.bgPanel
					else
						selected[def.id] = true
						toggle.BackgroundColor3 = PALETTE.accent
					end
				end)
			end
		end
		countryFields.startingTechs = {
			getValue = function()
				local out = {}
				for id in pairs(selected) do
					out[id] = true
				end
				return out
			end,
		}
	end

	local applyBtn = makeButton(countryForm, isNew and "Create Country" or "Apply Changes", PALETTE.accent)
	applyBtn.Size = UDim2.fromOffset(200, 32)
	applyBtn.LayoutOrder = 99
	applyBtn.MouseButton1Click:Connect(function()
		local function parseList(t)
			local out = {}
			for s in (t or ""):gmatch("[^,%s]+") do
				table.insert(out, s)
			end
			return out
		end
		local function parseColor(t)
			local parts = {}
			for n in (t or ""):gmatch("%d+") do
				table.insert(parts, tonumber(n))
			end
			return { parts[1] or 128, parts[2] or 128, parts[3] or 128 }
		end
		local flagText = countryFields.flagAssetId.Text
		local capitalRaw = countryFields.capitalProvinceId.getValue()
		local capitalId, capitalTilePart
		if type(capitalRaw) == "string" then
			if capitalRaw:sub(1, 2) == "P:" then
				capitalId = tonumber(capitalRaw:sub(3))
			elseif capitalRaw:sub(1, 2) == "T:" then
				capitalTilePart = capitalRaw:sub(3)
			else
				capitalId = tonumber(capitalRaw)
			end
		end
		local opts = {
			displayName = countryFields.displayName.Text,
			capitalProvinceId = capitalId,
			color = parseColor(countryFields.color.Text),
			flagAssetId = (flagText ~= nil and flagText ~= "") and flagText or nil,
			primaryCulture = countryFields.primaryCulture.getValue(),
			acceptedCultures = parseList(countryFields.acceptedCultures.Text),
			stateReligion = countryFields.stateReligion.getValue(),
			governmentForm = countryFields.governmentForm.getValue(),
			ideology = countryFields.ideology.getValue(),
			technologyGroup = countryFields.technologyGroup.getValue() or "western",
			stability = tonumber(countryFields.stability.Text) or 0,
			legitimacy = tonumber(countryFields.legitimacy.Text) or 70,
			treasury = tonumber(countryFields.treasury.Text) or 100,
			manpower = tonumber(countryFields.manpower.Text) or 10000,
			politicalPower = tonumber(countryFields.politicalPower.Text) or 80,
			historicalRivals = parseList(countryFields.historicalRivals.Text),
			historicalFriends = parseList(countryFields.historicalFriends.Text),
			startingTechs = (countryFields.startingTechs and countryFields.startingTechs.getValue()) or {},
		}
		local tag = countryFields.tag.Text:upper():gsub("%s", "")
		if isNew and (#tag < 2 or #tag > 4 or not tag:match("^[A-Z]+$")) then
			setStatus("Tag must be 2–4 uppercase letters", PALETTE.bad)
			return
		end
		local function isBlank(v)
			return v == nil or v == ""
		end
		local missing = {}
		if isBlank(opts.displayName) then
			table.insert(missing, "Display Name")
		end
		if isBlank(opts.primaryCulture) then
			table.insert(missing, "Primary Culture")
		end
		if isBlank(opts.stateReligion) then
			table.insert(missing, "State Religion")
		end
		if isBlank(opts.governmentForm) then
			table.insert(missing, "Government")
		end
		if isBlank(opts.ideology) then
			table.insert(missing, "Ideology")
		end
		if not capitalId and not capitalTilePart then
			table.insert(missing, "Capital Province")
		end
		if #missing > 0 then
			setStatus("Missing required: " .. table.concat(missing, ", "), PALETTE.bad)
			return
		end
		if capitalId and state.snapshot and not state.snapshot.provinces[capitalId] then
			setStatus(
				"Capital Province " .. tostring(capitalId) .. " does not exist — pick from the list",
				PALETTE.bad
			)
			return
		end
		if capitalTilePart then
			opts.promoteCapitalFromTile = capitalTilePart
		end
		if isNew then
			if call("addCountry", { tag = tag, opts = opts }) ~= nil then
				local queued = state.pendingProvinces or {}
				local items = {}
				for _, item in ipairs(queued) do
					if type(item) == "table" then
						if item.kind == "seed" and item.id then
							table.insert(items, { kind = "seed", id = item.id })
						elseif item.kind == "tile" and item.partName then
							table.insert(items, { kind = "tile", partName = item.partName })
						end
					else
						table.insert(items, { kind = "seed", id = item })
					end
				end
				local flushed = 0
				if #items > 0 then
					local result = call("assignBatch", { ownerTag = tag, items = items })
					if type(result) == "table" then
						flushed = result.processed or 0
					end
				end
				state.pendingProvinces = {}
				setStatus(string.format("Created %s (+%d entries)", tag, flushed), PALETTE.good)
				state.selectedCountryTag = tag
				refresh()
			end
		else
			if call("updateCountry", { tag = state.selectedCountryTag, opts = opts }) ~= nil then
				setStatus("Updated " .. state.selectedCountryTag, PALETTE.good)
				refresh()
			end
		end
	end)
end

local function selectCountry(tag)
	state.selectedCountryTag = tag
	state.selectedProvinceId = nil
	for t, item in pairs(countryListItems) do
		item.BackgroundColor3 = t == tag and PALETTE.bgPanelAlt or PALETTE.bgPanel
	end
	rebuildCountryForm()
end

local function rebuildCountryList(filter)
	clearFrame(countryScroll)
	countryListItems = {}
	if not state.snapshot then
		return
	end
	local tags = {}
	for t in pairs(state.snapshot.countries) do
		table.insert(tags, t)
	end
	table.sort(tags)
	filter = filter and filter:lower() or ""
	local order = 0
	for _, tag in ipairs(tags) do
		local c = state.snapshot.countries[tag]
		local dispName = c.displayName or tag
		if filter == "" or tag:lower():find(filter, 1, true) or dispName:lower():find(filter, 1, true) then
			order += 1
			local item = newInstance("TextButton", {
				Size = UDim2.new(1, -4, 0, 34),
				BackgroundColor3 = tag == state.selectedCountryTag and PALETTE.bgPanelAlt or PALETTE.bgPanel,
				BorderSizePixel = 0,
				Text = "",
				AutoButtonColor = false,
				LayoutOrder = order,
			}, countryScroll)
			addCorner(item, 2)
			addStroke(item, PALETTE.border, 1)

			if c.flagAssetId and c.flagAssetId ~= "" then
				local flag = newInstance("ImageLabel", {
					Size = UDim2.fromOffset(22, 14),
					Position = UDim2.fromOffset(6, 10),
					BackgroundColor3 = PALETTE.bgInput,
					BorderSizePixel = 0,
					Image = c.flagAssetId,
					ScaleType = Enum.ScaleType.Fit,
				}, item)
				addCorner(flag, 2)
				addStroke(flag, PALETTE.border, 1)
			else
				local colorChip = newInstance("Frame", {
					Size = UDim2.fromOffset(14, 14),
					Position = UDim2.fromOffset(8, 10),
					BackgroundColor3 = Color3.fromRGB(
						(c.color or {})[1] or 128,
						(c.color or {})[2] or 128,
						(c.color or {})[3] or 128
					),
					BorderSizePixel = 0,
				}, item)
				addCorner(colorChip, 2)
			end

			newInstance("TextLabel", {
				Size = UDim2.new(1, -34, 0, 16),
				Position = UDim2.fromOffset(30, 3),
				BackgroundTransparency = 1,
				Text = dispName,
				TextColor3 = PALETTE.text,
				Font = Enum.Font.GothamSemibold,
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left,
			}, item)

			local capLabel
			local capId = c.capitalProvinceId
			if capId then
				local snap = state.snapshot
				local capRec = snap and snap.provinces and snap.provinces[capId]
				if capRec and type(capRec.name) == "string" and capRec.name ~= "" then
					capLabel = capRec.name .. " (" .. tostring(capId) .. ")"
				else
					capLabel = "P:" .. tostring(capId)
				end
			else
				capLabel = "no capital"
			end

			newInstance("TextLabel", {
				Size = UDim2.new(1, -34, 0, 14),
				Position = UDim2.fromOffset(30, 17),
				BackgroundTransparency = 1,
				Text = tag .. "  •  " .. capLabel,
				TextColor3 = PALETTE.textMuted,
				Font = Enum.Font.Gotham,
				TextSize = 10,
				TextXAlignment = Enum.TextXAlignment.Left,
			}, item)

			item.MouseButton1Click:Connect(function()
				selectCountry(tag)
			end)
			countryListItems[tag] = item
		end
	end
end

countrySearch:GetPropertyChangedSignal("Text"):Connect(function()
	rebuildCountryList(countrySearch.Text)
end)

local provinceListCol, provinceScroll, provinceSearch = makeListColumn(provincesBody)
local provinceFormCol, provinceForm = makeFormScroll(provincesBody)
local provinceFields = {}
local provinceListItems = {}

local function rebuildProvinceForm()
	clearFrame(provinceForm)
	provinceFields = {}
	local s = state.snapshot
	if not s then
		return
	end

	local prov = state.selectedProvinceId and s.provinces[state.selectedProvinceId] or nil
	local isNew = prov == nil

	local headerLabel
	if isNew then
		headerLabel = "NEW PROVINCE"
	else
		headerLabel =
			string.format("EDIT PROVINCE [%s] %s", tostring(state.selectedProvinceId), tostring(prov.name or ""))
	end
	makeSection(provinceForm, headerLabel, 1)

	local function addField(order, label, mk)
		local row = makeRow(provinceForm, label, order)
		return mk(row)
	end

	provinceFields.id = addField(2, "ID", function(row)
		local box = makeTextBox(
			row,
			s.collapsed and "(set by Map Part)" or "42",
			prov and tostring(state.selectedProvinceId) or ""
		)
		-- v3: a province's id IS its map part number, so it's derived from the Map Part picker, not typed.
		box.TextEditable = isNew and not s.collapsed
		return box
	end)
	provinceFields.name = addField(3, "Name", function(row)
		return makeTextBox(row, "Paris", prov and prov.name or "")
	end)
	provinceFields.displayCityName = addField(4, "Display City", function(row)
		return makeTextBox(row, "Paris", prov and prov.displayCityName or "")
	end)

	makeSection(provinceForm, "GEOGRAPHY", 5)
	provinceFields.areaId = addField(6, "Area", function(row)
		return makeDropdown(row, s.registries.areas, prov and prov.areaId)
	end)
	provinceFields.regionId = addField(7, "Region", function(row)
		return makeDropdown(row, s.registries.regions, prov and prov.regionId)
	end)
	provinceFields.superRegionId = addField(8, "Super-Region", function(row)
		return makeDropdown(row, s.registries.superRegions, prov and prov.superRegionId)
	end)
	provinceFields.terrain = addField(9, "Terrain", function(row)
		return makeDropdown(row, s.registries.terrains, prov and prov.terrain)
	end)
	provinceFields.climate = addField(10, "Climate", function(row)
		return makeDropdown(row, s.registries.climates, prov and prov.climate)
	end)

	makeSection(provinceForm, "IDENTITY", 11)
	provinceFields.culture = addField(12, "Culture", function(row)
		return makeDropdown(row, s.registries.cultures, prov and prov.culture)
	end)
	provinceFields.religion = addField(13, "Religion", function(row)
		return makeDropdown(row, s.registries.religions, prov and prov.religion)
	end)
	makeSection(provinceForm, "RESOURCES", 14)
	local initialResources = nil
	if prov then
		if type(prov.goods) == "table" and next(prov.goods) ~= nil then
			initialResources = prov.goods
		elseif type(prov.tradeGood) == "string" and prov.tradeGood ~= "" and prov.tradeGood ~= "none" then
			initialResources = { [prov.tradeGood] = prov.baseProduction or 1 }
		end
	end
	provinceFields.resources = makeResourceList(provinceForm, s.registries.tradeGoods, initialResources, 14)

	makeSection(provinceForm, "OWNERSHIP", 15)
	local countryList = {}
	table.insert(countryList, { id = "NONE", name = "(unowned)" })
	for tag, c in pairs(s.countries) do
		table.insert(countryList, { id = tag, name = c.displayName or tag })
	end
	table.sort(countryList, function(a, b)
		return a.name < b.name
	end)
	provinceFields.ownerTag = addField(16, "Owner", function(row)
		return makeDropdown(row, countryList, prov and prov.ownerTag or "NONE")
	end)

	makeSection(provinceForm, "DEVELOPMENT", 17)
	provinceFields.baseTax = addField(18, "Base Tax", function(row)
		return makeTextBox(row, "6", prov and tostring(prov.baseTax) or "1")
	end)
	provinceFields.baseProduction = addField(19, "Base Production", function(row)
		return makeTextBox(row, "7", prov and tostring(prov.baseProduction) or "1")
	end)
	provinceFields.baseManpower = addField(20, "Base Manpower", function(row)
		return makeTextBox(row, "3", prov and tostring(prov.baseManpower) or "1")
	end)
	provinceFields.devTier = addField(21, "Dev Tier (1-5)", function(row)
		return makeTextBox(row, "3", prov and tostring(prov.devTier) or "1")
	end)
	provinceFields.infraTier = addField(22, "Infra Tier (1-5)", function(row)
		return makeTextBox(row, "3", prov and tostring(prov.infraTier) or "1")
	end)
	provinceFields.fortTier = addField(23, "Fort Tier (0-5)", function(row)
		return makeTextBox(row, "2", prov and tostring(prov.fortTier) or "1")
	end)
	provinceFields.population = addField(24, "Population", function(row)
		return makeTextBox(row, "100000", prov and tostring(prov.population) or "10000")
	end)

	makeSection(provinceForm, "NAVAL", 25)
	local boolList = { { id = "false", name = "No" }, { id = "true", name = "Yes" } }
	provinceFields.coastal = addField(26, "Coastal", function(row)
		return makeDropdown(row, boolList, prov and prov.coastal == true and "true" or "false")
	end)
	provinceFields.hasShipyard = addField(27, "Has Shipyard", function(row)
		return makeDropdown(row, boolList, prov and prov.hasShipyard == true and "true" or "false")
	end)

	makeSection(provinceForm, "MAP PART", 28)
	-- Pick the map tile by its Studio name (search "prov_0001_Stockholm") instead of typing a raw
	-- part-id number. The combo's value IS the part number (prov_<N>), which the server's
	-- mapProvinceToPart writes into eu4Map. After the identity collapse, the part number == the id.
	local partOptions = {}
	for _, info in pairs(collectAllMapTiles()) do
		if info.partId then
			table.insert(partOptions, { id = info.partId, name = info.display, sortKey = (info.display or ""):lower() })
		end
	end
	table.sort(partOptions, function(a, b)
		return a.sortKey < b.sortKey
	end)
	provinceFields.btPartId = addField(29, "Map Part (Studio name)", function(row)
		-- v3: a province's part IS its id, so the current part is just the id itself.
		local existing = s.collapsed and state.selectedProvinceId or s.eu4Map[state.selectedProvinceId]
		return makeCombo(row, partOptions, existing, {
			placeholder = "search tile by name or number…",
			maxButtons = 200,
			onChange = function(partId)
				-- v3: keep the (read-only) ID field in sync — picking the part picks the id.
				if s.collapsed and isNew and provinceFields.id then
					provinceFields.id.Text = tostring(partId or "")
				end
			end,
		})
	end)

	local applyBtn = makeButton(provinceForm, isNew and "Create Province" or "Apply Changes", PALETTE.accent)
	applyBtn.Size = UDim2.fromOffset(200, 32)
	applyBtn.LayoutOrder = 99
	applyBtn.MouseButton1Click:Connect(function()
		local opts = {
			name = provinceFields.name.Text,
			displayCityName = provinceFields.displayCityName.Text,
			areaId = provinceFields.areaId.getValue(),
			regionId = provinceFields.regionId.getValue(),
			superRegionId = provinceFields.superRegionId.getValue(),
			terrain = provinceFields.terrain.getValue(),
			climate = provinceFields.climate.getValue(),
			culture = provinceFields.culture.getValue(),
			religion = provinceFields.religion.getValue(),
			goods = provinceFields.resources.getValue(),
			ownerTag = provinceFields.ownerTag.getValue(),
			baseTax = tonumber(provinceFields.baseTax.Text) or 1,
			baseProduction = tonumber(provinceFields.baseProduction.Text) or 1,
			baseManpower = tonumber(provinceFields.baseManpower.Text) or 1,
			devTier = tonumber(provinceFields.devTier.Text) or 1,
			infraTier = tonumber(provinceFields.infraTier.Text) or 1,
			fortTier = tonumber(provinceFields.fortTier.Text) or 1,
			population = tonumber(provinceFields.population.Text) or 10000,
			coastal = provinceFields.coastal.getValue() == "true",
			hasShipyard = provinceFields.hasShipyard.getValue() == "true",
		}
		local id = tonumber(provinceFields.id.Text) or 0
		-- v3: the province id IS its map part number — derive it from the Map Part picker so a new
		-- province can never be created with an id that doesn't match its part.
		if isNew and s.collapsed then
			local part = tonumber(provinceFields.btPartId.getValue())
			if not part then
				setStatus("Pick a Map Part — its number becomes the province id", PALETTE.bad)
				return
			end
			id = part
		end
		if isNew and id < 1 then
			setStatus("Province ID must be a positive integer", PALETTE.bad)
			return
		end
		if isNew and state.snapshot and state.snapshot.provinces[id] then
			setStatus("Province " .. id .. " already exists", PALETTE.bad)
			return
		end
		local function pBlank(v)
			return v == nil or v == ""
		end
		local pMissing = {}
		if pBlank(opts.name) then
			table.insert(pMissing, "Name")
		end
		if pBlank(opts.areaId) then
			table.insert(pMissing, "Area")
		end
		if pBlank(opts.regionId) then
			table.insert(pMissing, "Region")
		end
		if pBlank(opts.superRegionId) then
			table.insert(pMissing, "Super-Region")
		end
		if pBlank(opts.terrain) then
			table.insert(pMissing, "Terrain")
		end
		if pBlank(opts.climate) then
			table.insert(pMissing, "Climate")
		end
		if pBlank(opts.culture) then
			table.insert(pMissing, "Culture")
		end
		if pBlank(opts.religion) then
			table.insert(pMissing, "Religion")
		end
		if #pMissing > 0 then
			setStatus("Missing required: " .. table.concat(pMissing, ", "), PALETTE.bad)
			return
		end
		if isNew then
			if call("addProvince", { id = id, opts = opts }) ~= nil then
				setStatus("Created province " .. id, PALETTE.good)
				state.selectedProvinceId = id
				local bt = tonumber(provinceFields.btPartId.getValue())
				if bt then
					call("mapProvinceToPart", { id = id, btPartId = bt })
				end
				refresh()
			end
		else
			if call("updateProvince", { id = state.selectedProvinceId, opts = opts }) ~= nil then
				setStatus("Updated province " .. state.selectedProvinceId, PALETTE.good)
				local bt = tonumber(provinceFields.btPartId.getValue())
				if bt then
					call("mapProvinceToPart", { id = state.selectedProvinceId, btPartId = bt })
				end
				refresh()
			end
		end
	end)
end

local function selectProvince(id)
	state.selectedProvinceId = id
	state.selectedCountryTag = nil
	for pid, item in pairs(provinceListItems) do
		item.BackgroundColor3 = pid == id and PALETTE.bgPanelAlt or PALETTE.bgPanel
	end
	rebuildProvinceForm()
end

local function rebuildProvinceList(filter)
	clearFrame(provinceScroll)
	provinceListItems = {}
	if not state.snapshot then
		return
	end
	local ids = {}
	for id in pairs(state.snapshot.provinces) do
		table.insert(ids, id)
	end
	table.sort(ids)
	filter = filter and filter:lower() or ""
	local order = 0
	for _, id in ipairs(ids) do
		local p = state.snapshot.provinces[id]
		local provName = tostring(p.name or "")
		local cityName = tostring(p.displayCityName or "")
		if
			filter == ""
			or tostring(id):find(filter, 1, true)
			or provName:lower():find(filter, 1, true)
			or cityName:lower():find(filter, 1, true)
		then
			order += 1
			local item = newInstance("TextButton", {
				Size = UDim2.new(1, -4, 0, 32),
				BackgroundColor3 = id == state.selectedProvinceId and PALETTE.bgPanelAlt or PALETTE.bgPanel,
				BorderSizePixel = 0,
				Text = "",
				AutoButtonColor = false,
				LayoutOrder = order,
			}, provinceScroll)
			addCorner(item, 2)
			addStroke(item, PALETTE.border, 1)

			local primary = (cityName ~= "" and cityName) or provName
			local secondary = (cityName ~= "" and cityName ~= provName and provName ~= "") and (" — " .. provName)
				or ""
			newInstance("TextLabel", {
				Size = UDim2.new(1, -16, 0, 14),
				Position = UDim2.fromOffset(8, 2),
				BackgroundTransparency = 1,
				Text = string.format("[%s]  %s%s", tostring(id), primary, secondary),
				TextColor3 = PALETTE.text,
				Font = Enum.Font.GothamSemibold,
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left,
			}, item)

			newInstance("TextLabel", {
				Size = UDim2.new(1, -16, 0, 14),
				Position = UDim2.fromOffset(8, 16),
				BackgroundTransparency = 1,
				Text = string.format("owner %s  •  %s", tostring(p.ownerTag), tostring(p.culture)),
				TextColor3 = PALETTE.textMuted,
				Font = Enum.Font.Gotham,
				TextSize = 10,
				TextXAlignment = Enum.TextXAlignment.Left,
			}, item)

			item.MouseButton1Click:Connect(function()
				selectProvince(id)
			end)
			provinceListItems[id] = item
		end
	end

	if state.snapshot.tileOwners then
		local seededEU4 = {}
		for _, eu4Pid in pairs(state.snapshot.eu4Map or {}) do
			seededEU4[eu4Pid] = true
		end
		local painted = {}
		for partName, ownerTag in pairs(state.snapshot.tileOwners) do
			if type(ownerTag) == "string" and ownerTag ~= "" and ownerTag ~= "NONE" then
				local eu4Pid = tonumber(partName:match("prov_(%d+)"))
				if not eu4Pid or not seededEU4[eu4Pid] then
					table.insert(painted, { partName = partName, ownerTag = ownerTag })
				end
			end
		end
		table.sort(painted, function(a, b)
			return a.partName < b.partName
		end)
		for _, t in ipairs(painted) do
			local pretty = (t.partName:gsub("^prov_%d+_", "")):gsub("_", " ")
			local partNum = t.partName:match("prov_(%d+)") or "?"
			if filter == "" or pretty:lower():find(filter, 1, true) or tostring(partNum):find(filter, 1, true) then
				order += 1
				local item = newInstance("TextButton", {
					Size = UDim2.new(1, -4, 0, 32),
					BackgroundColor3 = PALETTE.bgPanel,
					BorderSizePixel = 0,
					Text = "",
					AutoButtonColor = false,
					LayoutOrder = order,
				}, provinceScroll)
				addCorner(item, 2)
				addStroke(item, PALETTE.warn, 1)

				newInstance("TextLabel", {
					Size = UDim2.new(1, -16, 0, 14),
					Position = UDim2.fromOffset(8, 2),
					BackgroundTransparency = 1,
					Text = string.format("[%s]  %s", partNum, pretty),
					TextColor3 = PALETTE.text,
					Font = Enum.Font.GothamSemibold,
					TextSize = 12,
					TextXAlignment = Enum.TextXAlignment.Left,
				}, item)

				newInstance("TextLabel", {
					Size = UDim2.new(1, -16, 0, 14),
					Position = UDim2.fromOffset(8, 16),
					BackgroundTransparency = 1,
					Text = string.format("painted • %s • promotes on save", tostring(t.ownerTag)),
					TextColor3 = PALETTE.warn,
					Font = Enum.Font.Gotham,
					TextSize = 10,
					TextXAlignment = Enum.TextXAlignment.Left,
				}, item)

				local localTile = t
				item.MouseButton1Click:Connect(function()
					setStatus(
						string.format(
							"Tile %s (%s) — promotes to a seed on next Save, then editable here",
							pretty,
							localTile.ownerTag
						),
						PALETTE.warn
					)
				end)
			end
		end
	end
end

provinceSearch:GetPropertyChangedSignal("Text"):Connect(function()
	rebuildProvinceList(provinceSearch.Text)
end)

local mappingScroll = newInstance("ScrollingFrame", {
	Size = UDim2.new(1, -20, 1, -20),
	Position = UDim2.fromOffset(10, 10),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 4,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, mappingBody)
addPadding(mappingScroll, 8)

local mappingLayout = Instance.new("UIListLayout")
mappingLayout.Padding = UDim.new(0, 4)
mappingLayout.Parent = mappingScroll

local function rebuildMappingView()
	clearFrame(mappingScroll)
	if not state.snapshot then
		return
	end
	local s = state.snapshot
	local info = newInstance("TextLabel", {
		Size = UDim2.new(1, 0, 0, 48),
		BackgroundTransparency = 1,
		Text = "Each seed province maps to a map tile (prov_<N>). The stamper uses that part to place the province on the map. Edit a province under the Provinces tab and pick its Map Part by Studio name.",
		TextColor3 = PALETTE.textMuted,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		LayoutOrder = 1,
	}, mappingScroll)

	-- Collapse-readiness banner. The identity collapse (serial id -> part id) requires eu4Map to be
	-- a clean bijection: duplicate part targets AND unmapped provinces both block it. Computed
	-- client-side from the snapshot (the authoritative gate is server-side Editor.auditMapping).
	do
		local targetCount = {}
		for _, pid in pairs(s.eu4Map or {}) do
			targetCount[pid] = (targetCount[pid] or 0) + 1
		end
		local dupes = 0
		for _, n in pairs(targetCount) do
			if n > 1 then
				dupes += 1
			end
		end
		local unmapped = 0
		for id in pairs(s.provinces or {}) do
			if (s.eu4Map or {})[id] == nil then
				unmapped += 1
			end
		end
		local ready = dupes == 0 and unmapped == 0
		newInstance("TextLabel", {
			Size = UDim2.new(1, 0, 0, 22),
			BackgroundTransparency = 1,
			Text = ready and "\u{2713} Mapping is a clean bijection — ready to collapse." or string.format(
				"\u{26A0} %d duplicate part target(s), %d unmapped province(s) — resolve before collapsing.",
				dupes,
				unmapped
			),
			TextColor3 = ready and PALETTE.good or PALETTE.warn,
			Font = Enum.Font.GothamBold,
			TextSize = 12,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = 2,
		}, mappingScroll)
	end

	local ids = {}
	for id in pairs(s.provinces) do
		table.insert(ids, id)
	end
	table.sort(ids)
	local order = 10
	for _, id in ipairs(ids) do
		order += 1
		local p = s.provinces[id]
		local btId = s.eu4Map[id]
		local item = newInstance("Frame", {
			Size = UDim2.new(1, 0, 0, 24),
			BackgroundColor3 = btId and PALETTE.bgPanel or PALETTE.bgPanelAlt,
			BorderSizePixel = 0,
			LayoutOrder = order,
		}, mappingScroll)
		addCorner(item, 2)
		addStroke(item, btId and PALETTE.border or PALETTE.warn, 1)

		newInstance("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = string.format("  [%3d]  %-22s  →  BT part  %s", id, p.name or "", tostring(btId or "(unmapped)")),
			TextColor3 = btId and PALETTE.text or PALETTE.warn,
			Font = Enum.Font.Code,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, item)
	end

	if s.tileOwners then
		local seededEU4 = {}
		for _, eu4 in pairs(s.eu4Map or {}) do
			seededEU4[eu4] = true
		end
		local painted = {}
		for partName, ownerTag in pairs(s.tileOwners) do
			if type(ownerTag) == "string" and ownerTag ~= "" and ownerTag ~= "NONE" then
				local eu4Pid = tonumber(partName:match("prov_(%d+)"))
				if not eu4Pid or not seededEU4[eu4Pid] then
					table.insert(painted, { partName = partName, eu4Pid = eu4Pid, ownerTag = ownerTag })
				end
			end
		end
		table.sort(painted, function(a, b)
			return (a.eu4Pid or 0) < (b.eu4Pid or 0)
		end)
		for _, t in ipairs(painted) do
			order += 1
			local pretty = (t.partName:gsub("^prov_%d+_", "")):gsub("_", " ")
			local item = newInstance("Frame", {
				Size = UDim2.new(1, 0, 0, 24),
				BackgroundColor3 = PALETTE.bgPanelAlt,
				BorderSizePixel = 0,
				LayoutOrder = order,
			}, mappingScroll)
			addCorner(item, 2)
			addStroke(item, PALETTE.warn, 1)

			newInstance("TextLabel", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Text = string.format(
					"  [tile]  %-22s  →  BT part  %s   • painted (%s) — promotes on save",
					pretty,
					tostring(t.eu4Pid or "?"),
					t.ownerTag
				),
				TextColor3 = PALETTE.warn,
				Font = Enum.Font.Code,
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left,
			}, item)
		end
	end
end

local dataStoreHeader = newInstance("TextLabel", {
	Size = UDim2.new(1, -20, 0, 22),
	Position = UDim2.fromOffset(10, 10),
	BackgroundTransparency = 1,
	Text = "Load the DataStore to inspect what's persisted in this universe.",
	TextColor3 = PALETTE.textMuted,
	Font = Enum.Font.GothamSemibold,
	TextSize = 12,
	TextXAlignment = Enum.TextXAlignment.Left,
}, dataStoreBody)

local dataStoreControls = newInstance("Frame", {
	Size = UDim2.new(1, -20, 0, 30),
	Position = UDim2.fromOffset(10, 38),
	BackgroundTransparency = 1,
}, dataStoreBody)

local dsLoadBtn = makeButton(dataStoreControls, "⟳  Load DataStore", PALETTE.good)
dsLoadBtn.Size = UDim2.fromOffset(170, 28)
dsLoadBtn.Position = UDim2.fromOffset(0, 0)

local dsForceBtn = makeButton(dataStoreControls, "↺  Force Refresh", PALETTE.bgInput)
dsForceBtn.Size = UDim2.fromOffset(150, 28)
dsForceBtn.Position = UDim2.fromOffset(180, 0)

local dsMigrateBtn = makeButton(dataStoreControls, "⇠  Migrate Legacy", PALETTE.bgInput)
dsMigrateBtn.Size = UDim2.fromOffset(160, 28)
dsMigrateBtn.Position = UDim2.fromOffset(340, 0)

local dsSearch = newInstance("TextBox", {
	Size = UDim2.new(1, -520, 1, 0),
	Position = UDim2.fromOffset(510, 0),
	BackgroundColor3 = PALETTE.bgInput,
	BorderSizePixel = 0,
	PlaceholderText = "filter keys (e.g. tile:prov_123, country:FRA)",
	PlaceholderColor3 = PALETTE.textMuted,
	Text = "",
	TextColor3 = PALETTE.text,
	Font = Enum.Font.Gotham,
	TextSize = 13,
	ClearTextOnFocus = false,
	TextXAlignment = Enum.TextXAlignment.Left,
}, dataStoreControls)
addCorner(dsSearch, 3)
addStroke(dsSearch, PALETTE.border, 1)
addPadding(dsSearch, 8)

local dsSummaryLabel = newInstance("TextLabel", {
	Size = UDim2.new(1, -20, 0, 20),
	Position = UDim2.fromOffset(10, 74),
	BackgroundTransparency = 1,
	Text = "",
	TextColor3 = PALETTE.accent,
	Font = Enum.Font.Code,
	TextSize = 12,
	TextXAlignment = Enum.TextXAlignment.Left,
}, dataStoreBody)

local dsScroll = newInstance("ScrollingFrame", {
	Size = UDim2.new(1, -20, 1, -108),
	Position = UDim2.fromOffset(10, 98),
	BackgroundColor3 = PALETTE.bgPanel,
	BorderSizePixel = 0,
	ScrollBarThickness = 6,
	ScrollBarImageColor3 = PALETTE.accent,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, dataStoreBody)
addCorner(dsScroll, 3)
addStroke(dsScroll, PALETTE.border, 1)

local dsLayout = Instance.new("UIListLayout")
dsLayout.Padding = UDim.new(0, 2)
dsLayout.SortOrder = Enum.SortOrder.LayoutOrder
dsLayout.Parent = dsScroll

local dsPadding = Instance.new("UIPadding")
dsPadding.PaddingTop = UDim.new(0, 6)
dsPadding.PaddingBottom = UDim.new(0, 6)
dsPadding.PaddingLeft = UDim.new(0, 6)
dsPadding.PaddingRight = UDim.new(0, 6)
dsPadding.Parent = dsScroll

local dataStoreSnapshot = nil

local function describeValue(kind, value)
	if type(value) ~= "table" then
		return tostring(value)
	end
	if kind == "country" then
		return string.format(
			"displayName=%q cap=%s",
			tostring(value.displayName or ""),
			tostring(value.capitalProvinceId or "?")
		)
	elseif kind == "province" then
		return string.format(
			"name=%q owner=%s culture=%s",
			tostring(value.name or ""),
			tostring(value.ownerTag or "?"),
			tostring(value.culture or "?")
		)
	elseif kind == "tile" then
		return "owner=" .. tostring(value)
	elseif kind == "eu4map" then
		return "→ BT part " .. tostring(value)
	end
	return "(table)"
end

local function pushEntry(list, kind, key, value, tombstoned)
	table.insert(list, {
		kind = kind,
		key = tostring(key),
		display = string.format("%s:%s", kind, tostring(key)),
		tombstoned = tombstoned == true,
		detail = tombstoned and "<deleted>" or describeValue(kind, value),
	})
end

local function renderDataStoreList(filter)
	clearFrame(dsScroll)
	if not dataStoreSnapshot then
		newInstance("TextLabel", {
			Size = UDim2.new(1, -12, 0, 28),
			BackgroundTransparency = 1,
			Text = "  (not loaded — click Load DataStore)",
			TextColor3 = PALETTE.textMuted,
			Font = Enum.Font.Gotham,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = 1,
		}, dsScroll)
		return
	end

	local list = {}
	for tag, record in pairs(dataStoreSnapshot.countries or {}) do
		pushEntry(list, "country", tag, record, false)
	end
	for tag in pairs((dataStoreSnapshot.tombstones or {}).country or {}) do
		pushEntry(list, "country", tag, nil, true)
	end
	for id, record in pairs(dataStoreSnapshot.provinces or {}) do
		pushEntry(list, "province", id, record, false)
	end
	for id in pairs((dataStoreSnapshot.tombstones or {}).province or {}) do
		pushEntry(list, "province", id, nil, true)
	end
	for id, v in pairs(dataStoreSnapshot.eu4Map or {}) do
		pushEntry(list, "eu4map", id, v, false)
	end
	for id in pairs((dataStoreSnapshot.tombstones or {}).eu4map or {}) do
		pushEntry(list, "eu4map", id, nil, true)
	end
	for name, owner in pairs(dataStoreSnapshot.tiles or {}) do
		pushEntry(list, "tile", name, owner, false)
	end
	for name in pairs((dataStoreSnapshot.tombstones or {}).tile or {}) do
		pushEntry(list, "tile", name, nil, true)
	end

	table.sort(list, function(a, b)
		if a.kind == b.kind then
			return a.key < b.key
		end
		return a.kind < b.kind
	end)

	local term = (filter or ""):lower()
	local shown = 0
	for idx, entry in ipairs(list) do
		if
			term == ""
			or entry.display:lower():find(term, 1, true)
			or (entry.detail or ""):lower():find(term, 1, true)
		then
			shown += 1
			local row = newInstance("Frame", {
				Size = UDim2.new(1, -12, 0, 22),
				BackgroundColor3 = entry.tombstoned and PALETTE.bgInput or PALETTE.bgPanelAlt,
				BorderSizePixel = 0,
				LayoutOrder = idx,
			}, dsScroll)
			addCorner(row, 2)

			newInstance("TextLabel", {
				Size = UDim2.new(0, 220, 1, 0),
				Position = UDim2.fromOffset(8, 0),
				BackgroundTransparency = 1,
				Text = entry.display,
				TextColor3 = entry.tombstoned and PALETTE.textMuted or PALETTE.accent,
				Font = Enum.Font.Code,
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left,
			}, row)

			newInstance("TextLabel", {
				Size = UDim2.new(1, -236, 1, 0),
				Position = UDim2.fromOffset(228, 0),
				BackgroundTransparency = 1,
				Text = entry.detail or "",
				TextColor3 = entry.tombstoned and PALETTE.bad or PALETTE.text,
				Font = Enum.Font.Code,
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
			}, row)
		end
	end

	if shown == 0 then
		newInstance("TextLabel", {
			Size = UDim2.new(1, -12, 0, 28),
			BackgroundTransparency = 1,
			Text = "  (no entries match filter)",
			TextColor3 = PALETTE.textMuted,
			Font = Enum.Font.Gotham,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = 99999,
		}, dsScroll)
	end
end

local function countTable(t)
	local n = 0
	for _ in pairs(t or {}) do
		n += 1
	end
	return n
end

local function loadDataStore(forceRefresh)
	setStatus(forceRefresh and "Refetching DataStore…" or "Loading DataStore…", PALETTE.accent)
	local snap = call("dumpDataStore", { forceRefresh = forceRefresh })
	if not snap then
		return
	end
	if type(snap) == "table" and snap.mode == "error" then
		setStatus("DataStore load failed: " .. tostring(snap.error), PALETTE.bad)
		return
	end
	dataStoreSnapshot = snap
	local tombs = snap.tombstones or {}
	dsSummaryLabel.Text = string.format(
		"universe=%s  place=%d  scope=%s  |  %dC  %dP  %dM  %dT  (tomb: %dC %dP %dM %dT)",
		tostring(snap.universe or "?"),
		tonumber(snap.placeId) or 0,
		tostring(snap.scope or "?"),
		countTable(snap.countries),
		countTable(snap.provinces),
		countTable(snap.eu4Map),
		countTable(snap.tiles),
		countTable(tombs.country),
		countTable(tombs.province),
		countTable(tombs.eu4map),
		countTable(tombs.tile)
	)
	renderDataStoreList(dsSearch.Text)
	setStatus(forceRefresh and "DataStore refreshed from backend" or "DataStore loaded", PALETTE.good)
end

dsLoadBtn.MouseButton1Click:Connect(function()
	loadDataStore(false)
end)
dsForceBtn.MouseButton1Click:Connect(function()
	loadDataStore(true)
end)
dsMigrateBtn.MouseButton1Click:Connect(function()
	setStatus("Scanning legacy keys…", PALETTE.accent)
	local result = call("migrateLegacy")
	if not result then
		return
	end
	if type(result) == "table" and result.mode == "error" then
		setStatus("Migrate failed: " .. tostring(result.error), PALETTE.bad)
		return
	end
	setStatus(result.message or "Legacy migration complete", PALETTE.good)
	loadDataStore(true)
end)
dsSearch:GetPropertyChangedSignal("Text"):Connect(function()
	renderDataStoreList(dsSearch.Text)
end)

renderDataStoreList("")

local logsHeader = newInstance("Frame", {
	Size = UDim2.new(1, -20, 0, 30),
	Position = UDim2.fromOffset(10, 10),
	BackgroundTransparency = 1,
}, logsBody)

newInstance("TextLabel", {
	Size = UDim2.new(1, -120, 1, 0),
	BackgroundTransparency = 1,
	Text = "Editor activity log — most recent at the bottom.",
	TextColor3 = PALETTE.textMuted,
	Font = Enum.Font.Gotham,
	TextSize = 12,
	TextXAlignment = Enum.TextXAlignment.Left,
}, logsHeader)

local logsClearBtn = makeButton(logsHeader, "Clear", PALETTE.bgInput)
logsClearBtn.Size = UDim2.fromOffset(80, 24)
logsClearBtn.Position = UDim2.new(1, 0, 0.5, 0)
logsClearBtn.AnchorPoint = Vector2.new(1, 0.5)
logsClearBtn.TextSize = 11

local logsScroll = newInstance("ScrollingFrame", {
	Size = UDim2.new(1, -20, 1, -50),
	Position = UDim2.fromOffset(10, 46),
	BackgroundColor3 = PALETTE.bgPanel,
	BorderSizePixel = 0,
	ScrollBarThickness = 6,
	ScrollBarImageColor3 = PALETTE.accent,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, logsBody)
addCorner(logsScroll, 3)
addStroke(logsScroll, PALETTE.border, 1)

local logsLayout = Instance.new("UIListLayout")
logsLayout.Padding = UDim.new(0, 0)
logsLayout.SortOrder = Enum.SortOrder.LayoutOrder
logsLayout.Parent = logsScroll

local logsPadding = Instance.new("UIPadding")
logsPadding.PaddingTop = UDim.new(0, 4)
logsPadding.PaddingBottom = UDim.new(0, 4)
logsPadding.PaddingLeft = UDim.new(0, 6)
logsPadding.PaddingRight = UDim.new(0, 6)
logsPadding.Parent = logsScroll

local logRowOrder = 0

local function renderLogEntry(entry)
	logRowOrder += 1
	local row = newInstance("TextLabel", {
		Size = UDim2.new(1, 0, 0, 16),
		BackgroundTransparency = 1,
		Text = string.format("[%s] %s", entry.ts, entry.msg),
		TextColor3 = entry.color or PALETTE.text,
		Font = Enum.Font.Code,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		LayoutOrder = logRowOrder,
	}, logsScroll)
	logsScroll.CanvasPosition = Vector2.new(0, math.huge)
	return row
end

for _, entry in ipairs(logBuffer) do
	renderLogEntry(entry)
end
logSink = renderLogEntry

logsClearBtn.MouseButton1Click:Connect(function()
	for _, c in logsScroll:GetChildren() do
		if c:IsA("TextLabel") then
			c:Destroy()
		end
	end
	table.clear(logBuffer)
	logRowOrder = 0
end)

local identityTabRebuilders = {}

local function safeRun(label, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		warn(string.format("[Editor] %s failed: %s", label, tostring(err)))
	end
end

local function rebuildAllTabs()
	safeRun("rebuildCountryList", rebuildCountryList, countrySearch.Text)
	safeRun("rebuildCountryForm", rebuildCountryForm)
	safeRun("rebuildProvinceList", rebuildProvinceList, provinceSearch.Text)
	safeRun("rebuildProvinceForm", rebuildProvinceForm)
	safeRun("rebuildMappingView", rebuildMappingView)
	for index, rebuild in ipairs(identityTabRebuilders) do
		safeRun("identityTabRebuilders[" .. index .. "]", rebuild)
	end
end

refresh = function()
	local snap = call("loadState")
	if not snap then
		return
	end
	state.snapshot = snap
	rebuildAllTabs()
	local cn, pn = 0, 0
	for _ in pairs(snap.countries) do
		cn += 1
	end
	for _ in pairs(snap.provinces) do
		pn += 1
	end
	setStatus(string.format("%d countries  •  %d provinces", cn, pn), PALETTE.textMuted)
end

local pendingReloadAt = 0
local function forceReload()
	if state.dirty then
		local now = os.clock()
		if now - pendingReloadAt > 5 then
			pendingReloadAt = now
			setStatus("Unsaved changes — click Reload again within 5s to discard", PALETTE.warn)
			return
		end
	end
	pendingReloadAt = 0
	local snap = call("reloadState")
	if not snap then
		return
	end
	state.snapshot = snap
	rebuildAllTabs()
	markDirty(false)
	setStatus("Reloaded from live data modules", PALETTE.accent)
end

local function formatDiffSegment(label, d)
	if not d or (d.added == 0 and d.modified == 0 and d.removed == 0) then
		return nil
	end
	local parts = {}
	if d.added > 0 then
		table.insert(parts, "+" .. d.added)
	end
	if d.modified > 0 then
		table.insert(parts, "*" .. d.modified)
	end
	if d.removed > 0 then
		table.insert(parts, "-" .. d.removed)
	end
	return label .. " " .. table.concat(parts, "/")
end

local function performSave()
	setStatus("Saving to DataStore…", PALETTE.accent)
	local result = call("save")
	if result == nil then
		return
	end
	if type(result) == "table" and result.mode == "datastore" then
		local failures = result.writes and result.writes.failures or 0
		local verify = result.verify
		local tone = PALETTE.good
		if failures > 0 or (verify and verify.total > 0 and verify.verified < verify.total) then
			tone = PALETTE.warn
		end
		setStatus(result.message or "Saved ✓", tone)
	elseif type(result) == "table" and result.mode == "error" then
		setStatus("Save failed: " .. tostring(result.error), PALETTE.bad)
	else
		setStatus("Saved ✓", PALETTE.good)
	end
end

saveBtn.MouseButton1Click:Connect(function()
	local diffResult = call("getDiff")
	if diffResult == nil then
		return
	end
	local diff = type(diffResult) == "table" and diffResult.diff or nil
	if not diff or diff.totalChanges == 0 then
		setStatus("No changes to save", PALETTE.textMuted)
		return
	end
	local segments = {}
	for _, kind in ipairs({
		"countries",
		"provinces",
		"eu4Map",
		"tileOwners",
		"cultures",
		"religions",
		"ideologies",
		"governments",
	}) do
		local seg = formatDiffSegment(kind, diff[kind])
		if seg then
			table.insert(segments, seg)
		end
	end
	local summary = #segments > 0 and table.concat(segments, "  ·  ") or "no changes"
	showConfirm({
		title = "Save changes?",
		message = "About to save: " .. summary .. " — writes to the shared DataStore.",
		confirmText = "Save",
		cancelText = "Cancel",
		accent = PALETTE.good,
		onConfirm = performSave,
	})
end)

exportBtn.MouseButton1Click:Connect(function()
	setStatus("Exporting to Lua source…", PALETTE.accent)
	local result = call("exportToLua")
	if result == nil then
		return
	end
	if type(result) == "table" then
		if result.mode == "source" then
			setStatus("Exported to .lua source ✓ — reopen the place to persist", PALETTE.good)
		elseif result.mode == "export" then
			setStatus("Exported to ServerStorage.DataEditorOutput — copy strings manually", PALETTE.warn)
		else
			setStatus("Exported", PALETTE.good)
		end
	end
end)

reloadBtn.MouseButton1Click:Connect(forceReload)

local function applyHistorySnap(snap, verb, fallbackMsg)
	if type(snap) ~= "table" then
		return false
	end
	state.snapshot = snap
	rebuildAllTabs()
	local label = snap.undoLabel or snap.redoLabel
	local depth = snap.historyDepth or 0
	if label then
		setStatus(string.format("%s: %s  (history %d)", verb, label, depth), PALETTE.warn)
	else
		setStatus(fallbackMsg, PALETTE.warn)
	end
	return true
end

local function performUndo()
	local snap = call("undo")
	if snap == nil then
		return
	end
	applyHistorySnap(snap, "Undid", "Undone")
end

local function performRedo()
	local snap = call("redo")
	if snap == nil then
		return
	end
	applyHistorySnap(snap, "Redid", "Redone")
end

undoBtn.MouseButton1Click:Connect(performUndo)
redoBtn.MouseButton1Click:Connect(performRedo)

newBtn.MouseButton1Click:Connect(function()
	if state.currentTab == "countries" then
		state.selectedCountryTag = nil
		rebuildCountryForm()
		setStatus("Blank country form — fill in and click Create", PALETTE.accent)
	elseif state.currentTab == "provinces" then
		state.selectedProvinceId = nil
		rebuildProvinceForm()
		setStatus("Blank province form — fill in and click Create", PALETTE.accent)
	end
end)

deleteBtn.MouseButton1Click:Connect(function()
	if state.currentTab == "countries" then
		if not state.selectedCountryTag then
			setStatus("Select a country first", PALETTE.warn)
			return
		end
		local tag = state.selectedCountryTag
		local country = state.snapshot and state.snapshot.countries and state.snapshot.countries[tag]
		local displayName = country and country.displayName or tag
		showConfirm({
			title = "Delete country?",
			message = string.format(
				"Delete %s (%s)? All provinces owned by %s will be released to NONE. This is reversible until you Save.",
				displayName,
				tag,
				tag
			),
			confirmText = "Delete",
			cancelText = "Cancel",
			accent = PALETTE.bad,
			onConfirm = function()
				if call("removeCountry", { tag = tag }) ~= nil then
					setStatus("Deleted " .. tag, PALETTE.warn)
					state.selectedCountryTag = nil
					refresh()
				end
			end,
		})
	elseif state.currentTab == "provinces" then
		if not state.selectedProvinceId then
			setStatus("Select a province first", PALETTE.warn)
			return
		end
		local id = state.selectedProvinceId
		local prov = state.snapshot and state.snapshot.provinces and state.snapshot.provinces[id]
		local provLabel = prov and string.format("[%s] %s", tostring(id), prov.name or "?") or tostring(id)
		showConfirm({
			title = "Delete province?",
			message = string.format("Delete province %d (%s)? This is reversible until you Save.", id, provLabel),
			confirmText = "Delete",
			cancelText = "Cancel",
			accent = PALETTE.bad,
			onConfirm = function()
				if call("removeProvince", { id = id }) ~= nil then
					setStatus("Deleted province " .. id, PALETTE.warn)
					state.selectedProvinceId = nil
					refresh()
				end
			end,
		})
	else
		setStatus("Nothing to delete on this tab", PALETTE.warn)
	end
end)

local MINIMIZED_HEIGHT = 34
local MINIMIZE_TWEEN_TIME = 0.22
local minimized = false
local restoreSize = UDim2.fromOffset(960, 600)
local minimizeTween = nil

local function clampPositionForSize(targetW, targetH)
	local vp = viewportSize()
	local size = root.AbsoluteSize
	local anchor = root.AnchorPoint
	local curTopLeftX = root.Position.X.Offset + vp.X * root.Position.X.Scale - size.X * anchor.X
	local curTopLeftY = root.Position.Y.Offset + vp.Y * root.Position.Y.Scale - size.Y * anchor.Y
	local maxX = math.max(0, vp.X - targetW)
	local maxY = math.max(0, vp.Y - targetH)
	root.AnchorPoint = Vector2.new(0, 0)
	root.Position = UDim2.fromOffset(math.clamp(curTopLeftX, 0, maxX), math.clamp(curTopLeftY, 0, maxY))
end

local function cancelMinimizeTween()
	if minimizeTween then
		minimizeTween:Cancel()
		minimizeTween = nil
	end
end

local function setMinimized(flag)
	flag = flag and true or false
	if minimized == flag then
		return
	end
	minimized = flag
	cancelMinimizeTween()

	if flag then
		restoreSize = root.Size
		local currentWidth = root.AbsoluteSize.X
		sizeConstraint.MinSize = Vector2.new(WINDOW_MIN_W, MINIMIZED_HEIGHT)
		tabBar.Visible = false
		content.Visible = false
		toolbar.Visible = false
		resizeGrip.Visible = false
		minimizeBtn.Text = "+"
		minimizeTween = TweenService:Create(
			root,
			TweenInfo.new(MINIMIZE_TWEEN_TIME, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
			{ Size = UDim2.fromOffset(currentWidth, MINIMIZED_HEIGHT) }
		)
		minimizeTween:Play()
	else
		sizeConstraint.MinSize = Vector2.new(WINDOW_MIN_W, WINDOW_MIN_H)
		local targetW = restoreSize.X.Offset
		local targetH = restoreSize.Y.Offset
		if targetW < WINDOW_MIN_W then
			targetW = WINDOW_MIN_W
		end
		if targetH < WINDOW_MIN_H then
			targetH = WINDOW_MIN_H
		end
		clampPositionForSize(targetW, targetH)
		minimizeBtn.Text = "–"
		tabBar.Visible = true
		content.Visible = true
		toolbar.Visible = true
		resizeGrip.Visible = true
		minimizeTween = TweenService:Create(
			root,
			TweenInfo.new(MINIMIZE_TWEEN_TIME, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
			{ Size = UDim2.fromOffset(targetW, targetH) }
		)
		minimizeTween:Play()
	end
end

minimizeBtn.MouseButton1Click:Connect(function()
	setMinimized(not minimized)
end)

local function showRoot()
	root.Visible = true
	if minimized then
		setMinimized(false)
	else
		clampToViewport()
	end
	if not state.snapshot then
		refresh()
	end
end

local function hideRoot()
	root.Visible = false
end
closeBtn.MouseButton1Click:Connect(hideRoot)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.Backquote then
		if root.Visible then
			hideRoot()
		else
			showRoot()
		end
		return
	end
	if not root.Visible or minimized then
		return
	end
	local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
	if not ctrl then
		return
	end
	if input.KeyCode == Enum.KeyCode.Z then
		performUndo()
	elseif input.KeyCode == Enum.KeyCode.U or input.KeyCode == Enum.KeyCode.Y then
		performRedo()
	end
end)

do
	local aow = ReplicatedStorage:FindFirstChild("ArtOfWar")
	local modules = aow and aow:FindFirstChild("Modules")
	local piModule = modules and modules:FindFirstChild("ProvinceInteraction")
	if piModule then
		local ProvinceInteraction = require(piModule)
		ProvinceInteraction.addSelectListener(function(part)
			if not root.Visible or minimized then
				return
			end
			if not part then
				return
			end
			if state.currentTab == "provinces" then
				local parent = part.Parent
				if parent and parent.Name == "Sea" then
					return
				end
				local seedId = part:GetAttribute("province_id")
				if seedId and state.snapshot and state.snapshot.provinces and state.snapshot.provinces[seedId] then
					selectProvince(seedId)
					local item = provinceListItems[seedId]
					if item and provinceScroll then
						provinceScroll.CanvasPosition = Vector2.new(
							0,
							math.max(0, item.AbsolutePosition.Y - provinceScroll.AbsolutePosition.Y - 40)
						)
					end
					setStatus(
						string.format("Selected province %s", tostring(part:GetAttribute("province_name") or seedId)),
						PALETTE.accent
					)
				else
					setStatus(
						"That tile isn't seeded as a province yet — paint it under Countries first, then Save to promote",
						PALETTE.warn
					)
				end
				return
			end
			if state.currentTab ~= "countries" then
				return
			end
			local parent = part.Parent
			if parent and parent.Name == "Sea" then
				if ProvinceInteraction.clearSelection then
					ProvinceInteraction.clearSelection()
				end
				setStatus("Sea tiles cannot be assigned to a country", PALETTE.warn)
				return
			end
			if not pendingProvincesAPI or not pendingProvincesAPI.active then
				setStatus("Pick a country on the left first, then click a tile", PALETTE.warn)
				return
			end
			if pendingProvincesAPI.isArmed and not pendingProvincesAPI.isArmed() then
				return
			end
			local shiftHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
				or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
			if shiftHeld and pendingProvincesAPI.removeFromMap then
				pendingProvincesAPI.removeFromMap(part)
			elseif pendingProvincesAPI.addFromMap then
				pendingProvincesAPI.addFromMap(part)
			end
		end)
	end
end

local function buildIdentityTab(body, kind, opts)
	opts = opts or {}
	local groupField = opts.groupField or "groupId"
	local registryName = opts.registryName or "cultureGroups"
	local titleSingular = opts.titleSingular or "Culture"
	local placeholderId = opts.placeholderId or "occitan"
	local placeholderName = opts.placeholderName or "Occitan"
	local addCmd = opts.addCmd or "addCulture"
	local updateCmd = opts.updateCmd or "updateCulture"
	local removeCmd = opts.removeCmd or "removeCulture"

	local listCol, listScroll, listSearch = makeListColumn(body)
	local formCol, formScroll = makeFormScroll(body)
	local fields = {}
	local listItems = {}
	local selectedId = nil

	local rebuildList
	local rebuildForm

	local function refresh()
		local snap = call("loadState")
		if not snap then
			return
		end
		state.snapshot = snap
		rebuildList(listSearch.Text)
		rebuildForm()
	end

	local function getRecords()
		if not state.snapshot then
			return {}
		end
		if kind == "culture" then
			return state.snapshot.cultures or {}
		end
		if kind == "religion" then
			return state.snapshot.religions or {}
		end
		if kind == "ideology" then
			return state.snapshot.ideologies or {}
		end
		if kind == "government" then
			return state.snapshot.governmentTypes or {}
		end
		return {}
	end

	rebuildForm = function()
		clearFrame(formScroll)
		fields = {}
		local records = getRecords()
		local rec = selectedId and records[selectedId] or nil
		local isNew = rec == nil

		makeSection(
			formScroll,
			isNew and ("NEW " .. string.upper(titleSingular))
				or ("EDIT " .. string.upper(titleSingular) .. "  " .. tostring(selectedId or "")),
			1
		)

		local function addField(order, label, mk)
			local row = makeRow(formScroll, label, order)
			return mk(row)
		end

		fields.id = addField(2, "ID", function(row)
			local box = makeTextBox(row, placeholderId, rec and rec.id or selectedId or "")
			box.TextEditable = isNew
			return box
		end)
		fields.displayName = addField(3, "Display Name", function(row)
			return makeTextBox(row, placeholderName, rec and rec.displayName or "")
		end)
		if not opts.noGroup and groupField then
			fields.group = addField(4, opts.groupLabel or "Group", function(row)
				local opt = (state.snapshot and state.snapshot.registries and state.snapshot.registries[registryName])
					or {}
				return makeCombo(
					row,
					opt,
					rec and rec[groupField] or nil,
					{ allowFreeform = true, placeholder = "type or pick a group…" }
				)
			end)
		end

		local extraGetters = {}
		if type(opts.extraFields) == "function" then
			local ok, result = pcall(opts.extraFields, formScroll, rec, isNew, addField)
			if ok and type(result) == "table" then
				extraGetters = result
			elseif not ok then
				warn("[Editor] extraFields callback errored: " .. tostring(result))
			end
		end

		local applyBtn =
			makeButton(formScroll, isNew and ("Create " .. titleSingular) or "Apply Changes", PALETTE.accent)
		applyBtn.Size = UDim2.fromOffset(200, 32)
		applyBtn.LayoutOrder = 99
		applyBtn.MouseButton1Click:Connect(function()
			local id = fields.id.Text:lower():gsub("%s", "_"):gsub("[^%w_]", "")
			if id == "" then
				setStatus("ID required (lowercase, letters/numbers/underscore)", PALETTE.bad)
				return
			end
			local displayName = fields.displayName.Text
			if displayName == "" then
				setStatus("Display Name required", PALETTE.bad)
				return
			end
			local optsPayload = { displayName = displayName }
			if fields.group then
				optsPayload[groupField] = fields.group.getValue()
			end
			for k, getter in pairs(extraGetters) do
				local ok, val = pcall(getter)
				if ok then
					optsPayload[k] = val
				end
			end
			if isNew then
				local existingRecords = getRecords()
				if existingRecords[id] then
					setStatus(titleSingular .. " " .. id .. " already exists", PALETTE.bad)
					return
				end
				if call(addCmd, { id = id, opts = optsPayload }) ~= nil then
					setStatus("Created " .. titleSingular:lower() .. " " .. id, PALETTE.good)
					selectedId = id
					refresh()
				end
			else
				if call(updateCmd, { id = selectedId, opts = optsPayload }) ~= nil then
					setStatus("Updated " .. titleSingular:lower() .. " " .. selectedId, PALETTE.good)
					refresh()
				end
			end
		end)

		if not isNew and opts.bulkField then
			local bulkField = opts.bulkField
			makeSection(formScroll, "BULK ASSIGN TO PROVINCES", 110)

			local hint = newInstance("TextLabel", {
				Size = UDim2.new(1, 0, 0, 32),
				BackgroundTransparency = 1,
				Text = string.format(
					"Paste province IDs separated by commas, spaces, or newlines. The selected %s will be applied to each province.",
					bulkField
				),
				TextColor3 = PALETTE.textMuted,
				Font = Enum.Font.Gotham,
				TextSize = 11,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				TextWrapped = true,
				LayoutOrder = 111,
			}, formScroll)

			local boxFrame = newInstance("Frame", {
				Size = UDim2.new(1, 0, 0, 96),
				BackgroundColor3 = PALETTE.bgInput,
				BorderSizePixel = 0,
				LayoutOrder = 112,
			}, formScroll)
			addCorner(boxFrame, 3)
			addStroke(boxFrame, PALETTE.border, 1)

			local bulkBox = newInstance("TextBox", {
				Size = UDim2.new(1, -12, 1, -8),
				Position = UDim2.fromOffset(6, 4),
				BackgroundTransparency = 1,
				PlaceholderText = "5, 6, 7  ·  or one ID per line",
				PlaceholderColor3 = PALETTE.textMuted,
				Text = "",
				TextColor3 = PALETTE.text,
				Font = Enum.Font.Code,
				TextSize = 13,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				TextWrapped = true,
				MultiLine = true,
				ClearTextOnFocus = false,
			}, boxFrame)

			local function parseIds(text)
				local seen, ids = {}, {}
				for chunk in tostring(text or ""):gmatch("%-?%d+") do
					local n = tonumber(chunk)
					if n and not seen[n] then
						seen[n] = true
						table.insert(ids, n)
					end
				end
				return ids
			end

			local function refreshCount()
				local ids = parseIds(bulkBox.Text)
				return ids
			end

			local applyBulkBtn = makeButton(formScroll, "Apply " .. titleSingular .. " to provinces", PALETTE.good)
			applyBulkBtn.Size = UDim2.fromOffset(260, 32)
			applyBulkBtn.LayoutOrder = 113
			applyBulkBtn.MouseButton1Click:Connect(function()
				local ids = refreshCount()
				if #ids == 0 then
					setStatus("No province IDs found in input", PALETTE.bad)
					return
				end
				if #ids > 500 then
					setStatus(string.format("Too many IDs: %d (max 500) — split it up", #ids), PALETTE.bad)
					return
				end
				local result = call("assignProvinceFieldBatch", { items = ids, field = bulkField, value = selectedId })
				if not result then
					return
				end
				if type(result) == "table" and result.processed then
					local errCount = result.errors and #result.errors or 0
					if errCount > 0 then
						setStatus(
							string.format(
								"Applied %s to %d provinces (%d failed)",
								bulkField,
								result.processed,
								errCount
							),
							PALETTE.warn
						)
					else
						setStatus(
							string.format("Applied %s '%s' to %d provinces", bulkField, selectedId, result.processed),
							PALETTE.good
						)
						bulkBox.Text = ""
					end
					refresh()
				end
			end)
		end

		if not isNew then
			local deleteBtn = makeButton(formScroll, "Delete " .. titleSingular, PALETTE.bad)
			deleteBtn.Size = UDim2.fromOffset(200, 28)
			deleteBtn.LayoutOrder = 200
			deleteBtn.MouseButton1Click:Connect(function()
				local id = selectedId
				showConfirm({
					title = "Delete " .. titleSingular:lower() .. "?",
					message = string.format(
						"Delete %s '%s' (%s)? Provinces/countries referencing it will need to be reassigned.",
						titleSingular:lower(),
						tostring(rec.displayName or id),
						id
					),
					confirmText = "Delete",
					cancelText = "Cancel",
					accent = PALETTE.bad,
					onConfirm = function()
						if call(removeCmd, { id = id }) ~= nil then
							setStatus("Deleted " .. titleSingular:lower() .. " " .. id, PALETTE.warn)
							selectedId = nil
							refresh()
						end
					end,
				})
			end)
		end
	end

	local function selectRow(id)
		selectedId = id
		for rid, item in pairs(listItems) do
			item.BackgroundColor3 = rid == id and PALETTE.bgPanelAlt or PALETTE.bgPanel
		end
		rebuildForm()
	end

	rebuildList = function(filter)
		clearFrame(listScroll)
		listItems = {}
		local records = getRecords()
		local ids = {}
		for id in pairs(records) do
			table.insert(ids, id)
		end
		table.sort(ids)
		filter = filter and filter:lower() or ""
		local order = 0
		for _, id in ipairs(ids) do
			local r = records[id]
			local name = r.displayName or id
			if filter == "" or id:lower():find(filter, 1, true) or name:lower():find(filter, 1, true) then
				order += 1
				local item = newInstance("TextButton", {
					Size = UDim2.new(1, -4, 0, 32),
					BackgroundColor3 = id == selectedId and PALETTE.bgPanelAlt or PALETTE.bgPanel,
					BorderSizePixel = 0,
					Text = "",
					AutoButtonColor = false,
					LayoutOrder = order,
				}, listScroll)
				addCorner(item, 2)
				addStroke(item, PALETTE.border, 1)
				newInstance("TextLabel", {
					Size = UDim2.new(1, -16, 0, 16),
					Position = UDim2.fromOffset(8, 2),
					BackgroundTransparency = 1,
					Text = name,
					TextColor3 = PALETTE.text,
					Font = Enum.Font.GothamSemibold,
					TextSize = 12,
					TextXAlignment = Enum.TextXAlignment.Left,
				}, item)
				newInstance("TextLabel", {
					Size = UDim2.new(1, -16, 0, 12),
					Position = UDim2.fromOffset(8, 18),
					BackgroundTransparency = 1,
					Text = string.format(
						"%s  •  %s",
						id,
						tostring((groupField and r[groupField]) or (opts.subtitleFn and opts.subtitleFn(r)) or "—")
					),
					TextColor3 = PALETTE.textMuted,
					Font = Enum.Font.Gotham,
					TextSize = 10,
					TextXAlignment = Enum.TextXAlignment.Left,
				}, item)
				item.MouseButton1Click:Connect(function()
					selectRow(id)
				end)
				listItems[id] = item
			end
		end
	end

	listSearch:GetPropertyChangedSignal("Text"):Connect(function()
		rebuildList(listSearch.Text)
	end)

	return {
		rebuild = function()
			rebuildList(listSearch.Text)
			rebuildForm()
		end,
		newRecord = function()
			selectedId = nil
			rebuildForm()
			setStatus("Blank " .. titleSingular:lower() .. " form — fill in and click Create", PALETTE.accent)
		end,
		hasSelection = function()
			return selectedId ~= nil
		end,
	}
end

local culturesTab = buildIdentityTab(culturesBody, "culture", {
	groupField = "groupId",
	registryName = "cultureGroups",
	titleSingular = "Culture",
	placeholderId = "occitan",
	placeholderName = "Occitan",
	groupLabel = "Group",
	addCmd = "addCulture",
	updateCmd = "updateCulture",
	removeCmd = "removeCulture",
	bulkField = "culture",
})

local religionsTab = buildIdentityTab(religionsBody, "religion", {
	groupField = "group",
	registryName = "religionGroups",
	titleSingular = "Religion",
	placeholderId = "lutheran",
	placeholderName = "Lutheran",
	groupLabel = "Group",
	addCmd = "addReligion",
	updateCmd = "updateReligion",
	removeCmd = "removeReligion",
	bulkField = "religion",
})

local function modifiersToText(modifiers)
	if type(modifiers) ~= "table" then
		return ""
	end
	local lines = {}
	local keys = {}
	for k in pairs(modifiers) do
		table.insert(keys, k)
	end
	table.sort(keys)
	for _, k in ipairs(keys) do
		local v = modifiers[k]
		if type(v) == "number" then
			table.insert(lines, string.format("%s = %s", k, tostring(v)))
		end
	end
	return table.concat(lines, string.char(10))
end

local function parseModifiers(text)
	local out = {}
	for line in tostring(text or ""):gmatch("[^" .. string.char(10) .. "]+") do
		local key, value = line:match("^%s*([%w_]+)%s*=%s*(%-?[%d%.]+)%s*$")
		if key and value then
			local n = tonumber(value)
			if n then
				out[key] = n
			end
		end
	end
	return out
end

local function arrayToText(arr)
	if type(arr) ~= "table" then
		return ""
	end
	return table.concat(arr, ", ")
end

local function parseIdsArray(text)
	local out, seen = {}, {}
	for token in tostring(text or ""):gmatch("[%w_]+") do
		if not seen[token] then
			seen[token] = true
			table.insert(out, token)
		end
	end
	return out
end

local ideologiesTab = buildIdentityTab(ideologiesBody, "ideology", {
	groupField = nil,
	registryName = nil,
	titleSingular = "Ideology",
	placeholderId = "socialism",
	placeholderName = "Socialism",
	addCmd = "addIdeology",
	updateCmd = "updateIdeology",
	removeCmd = "removeIdeology",
	noGroup = true,
	subtitleFn = function(rec)
		local n = 0
		if type(rec.modifiers) == "table" then
			for _ in pairs(rec.modifiers) do
				n = n + 1
			end
		end
		return n .. " modifier" .. (n == 1 and "" or "s")
	end,
	extraFields = function(formScroll, rec, isNew, addField)
		local modifiersBox
		addField(20, "Modifiers", function(row)
			row.Size = UDim2.new(1, 0, 0, 110)
			local frame = newInstance("Frame", {
				Size = UDim2.new(1, -160, 1, -8),
				Position = UDim2.fromOffset(154, 4),
				BackgroundColor3 = PALETTE.bgInput,
				BorderSizePixel = 0,
			}, row)
			addCorner(frame, 3)
			addStroke(frame, PALETTE.border, 1)
			modifiersBox = newInstance("TextBox", {
				Size = UDim2.new(1, -12, 1, -8),
				Position = UDim2.fromOffset(6, 4),
				BackgroundTransparency = 1,
				PlaceholderText = "base_stability = 0.05  (one per line)",
				PlaceholderColor3 = PALETTE.textMuted,
				Text = modifiersToText(rec and rec.modifiers),
				TextColor3 = PALETTE.text,
				Font = Enum.Font.Code,
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				TextWrapped = true,
				MultiLine = true,
				ClearTextOnFocus = false,
			}, frame)
			return frame
		end)
		return {
			modifiers = function()
				return parseModifiers(modifiersBox.Text)
			end,
		}
	end,
})

local governmentsTab = buildIdentityTab(governmentsBody, "government", {
	groupField = nil,
	registryName = nil,
	titleSingular = "Government",
	placeholderId = "constitutional_republic",
	placeholderName = "Constitutional Republic",
	addCmd = "addGovernmentType",
	updateCmd = "updateGovernmentType",
	removeCmd = "removeGovernmentType",
	noGroup = true,
	subtitleFn = function(rec)
		local n = type(rec.allowedIdeologies) == "table" and #rec.allowedIdeologies or 0
		return n .. " ideolog" .. (n == 1 and "y" or "ies")
	end,
	extraFields = function(formScroll, rec, isNew, addField)
		local allowedBox, modifiersBox, ppStartBox, ppPerTickBox
		addField(15, "Allowed Ideologies", function(row)
			local box =
				makeTextBox(row, "absolutism, conservatism, liberalism", arrayToText(rec and rec.allowedIdeologies))
			allowedBox = box
			return box
		end)
		addField(16, "PP Start Bonus", function(row)
			local box = makeTextBox(row, "0", tostring((rec and rec.ppStartBonus) or 0))
			ppStartBox = box
			return box
		end)
		addField(17, "PP Per Tick", function(row)
			local box = makeTextBox(row, "1.0", tostring((rec and rec.ppPerTick) or 1.0))
			ppPerTickBox = box
			return box
		end)
		addField(20, "Modifiers", function(row)
			row.Size = UDim2.new(1, 0, 0, 110)
			local frame = newInstance("Frame", {
				Size = UDim2.new(1, -160, 1, -8),
				Position = UDim2.fromOffset(154, 4),
				BackgroundColor3 = PALETTE.bgInput,
				BorderSizePixel = 0,
			}, row)
			addCorner(frame, 3)
			addStroke(frame, PALETTE.border, 1)
			modifiersBox = newInstance("TextBox", {
				Size = UDim2.new(1, -12, 1, -8),
				Position = UDim2.fromOffset(6, 4),
				BackgroundTransparency = 1,
				PlaceholderText = "base_stability = 0.05  (one per line)",
				PlaceholderColor3 = PALETTE.textMuted,
				Text = modifiersToText(rec and rec.modifiers),
				TextColor3 = PALETTE.text,
				Font = Enum.Font.Code,
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				TextWrapped = true,
				MultiLine = true,
				ClearTextOnFocus = false,
			}, frame)
			return frame
		end)
		return {
			allowedIdeologies = function()
				return parseIdsArray(allowedBox.Text)
			end,
			ppStartBonus = function()
				return tonumber(ppStartBox.Text) or 0
			end,
			ppPerTick = function()
				return tonumber(ppPerTickBox.Text) or 1.0
			end,
			modifiers = function()
				return parseModifiers(modifiersBox.Text)
			end,
		}
	end,
})

table.insert(identityTabRebuilders, culturesTab.rebuild)
table.insert(identityTabRebuilders, religionsTab.rebuild)
table.insert(identityTabRebuilders, ideologiesTab.rebuild)
table.insert(identityTabRebuilders, governmentsTab.rebuild)

local liveSync
local softRefresh

do
	local remotesFolder = ReplicatedStorage:FindFirstChild("ArtOfWar")
		and ReplicatedStorage.ArtOfWar:FindFirstChild("Remotes")
	liveSync = remotesFolder and remotesFolder:FindFirstChild("DataEditorLive")
	local presenceRemote = remotesFolder and remotesFolder:FindFirstChild("DataEditorPresence")

	state.presence = {}

	local function readBefore(item)
		if not state.snapshot or type(item) ~= "table" then
			return nil
		end
		local kind, key = item.kind, item.key
		if kind == "country" then
			return state.snapshot.countries[key]
		end
		if kind == "province" then
			return state.snapshot.provinces[tonumber(key) or key]
		end
		if kind == "culture" then
			return state.snapshot.cultures[key]
		end
		if kind == "religion" then
			return state.snapshot.religions[key]
		end
		return nil
	end

	local function diffFields(before, after)
		local list = {}
		if type(before) ~= "table" or type(after) ~= "table" then
			return list
		end
		local seen = {}
		for k, v in pairs(after) do
			seen[k] = true
			local prev = before[k]
			if type(v) ~= "table" and type(prev) ~= "table" and prev ~= v then
				table.insert(list, k)
			end
		end
		for k in pairs(before) do
			if not seen[k] then
				table.insert(list, k)
			end
		end
		table.sort(list)
		return list
	end

	local function applyDelta(item)
		if not state.snapshot or type(item) ~= "table" then
			return
		end
		local kind, key, value = item.kind, item.key, item.value
		if kind == "country" then
			state.snapshot.countries[key] = value
		elseif kind == "province" then
			state.snapshot.provinces[tonumber(key) or key] = value
		elseif kind == "culture" then
			state.snapshot.cultures[key] = value
		elseif kind == "religion" then
			state.snapshot.religions[key] = value
		elseif kind == "ideology" then
			state.snapshot.ideologies = state.snapshot.ideologies or {}
			state.snapshot.ideologies[key] = value
		elseif kind == "government" then
			state.snapshot.governmentTypes = state.snapshot.governmentTypes or {}
			state.snapshot.governmentTypes[key] = value
		elseif kind == "tile" then
			if state.snapshot.tileOwners then
				state.snapshot.tileOwners[key] = value
			end
		elseif kind == "eu4Map" then
			if state.snapshot.eu4Map then
				state.snapshot.eu4Map[tonumber(key) or key] = value
			end
		end
	end

	local function presenceForRecord(kind, key)
		local out = {}
		local skey = tostring(key)
		for _, entry in ipairs(state.presence or {}) do
			if entry.userId ~= player.UserId and entry.kind == kind and tostring(entry.key) == skey then
				table.insert(out, entry.name)
			end
		end
		return out
	end

	local function ensurePresenceBadge(row)
		local existing = row:FindFirstChild("__PresenceBadge__")
		if existing then
			return existing
		end

		local badge = Instance.new("Frame")
		badge.Name = "__PresenceBadge__"
		badge.AutomaticSize = Enum.AutomaticSize.X
		badge.Size = UDim2.new(0, 0, 0, 16)
		badge.AnchorPoint = Vector2.new(1, 0.5)
		badge.Position = UDim2.new(1, -8, 0.5, 0)
		badge.BackgroundColor3 = PALETTE.bgPanelAlt
		badge.BorderSizePixel = 0
		badge.ZIndex = (row.ZIndex or 1) + 5
		badge.Parent = row

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 3)
		corner.Parent = badge

		local stroke = Instance.new("UIStroke")
		stroke.Color = PALETTE.borderHot
		stroke.Thickness = 1
		stroke.Transparency = 0.35
		stroke.Parent = badge

		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 6)
		pad.PaddingRight = UDim.new(0, 6)
		pad.Parent = badge

		local lbl = Instance.new("TextLabel")
		lbl.Name = "Label"
		lbl.Size = UDim2.new(1, 0, 1, 0)
		lbl.AutomaticSize = Enum.AutomaticSize.X
		lbl.BackgroundTransparency = 1
		lbl.Font = Enum.Font.GothamSemibold
		lbl.TextColor3 = PALETTE.borderHot
		lbl.TextSize = 10
		lbl.TextXAlignment = Enum.TextXAlignment.Center
		lbl.TextYAlignment = Enum.TextYAlignment.Center
		lbl.ZIndex = badge.ZIndex + 1
		lbl.Parent = badge

		return badge
	end

	local function decorateRows(items, kind)
		if not items then
			return
		end
		for key, row in pairs(items) do
			if typeof(row) == "Instance" and row.Parent then
				local names = presenceForRecord(kind, key)
				local badge = row:FindFirstChild("__PresenceBadge__")
				if #names > 0 then
					badge = badge or ensurePresenceBadge(row)
					local lbl = badge:FindFirstChild("Label")
					if lbl then
						local first = names[1]
						lbl.Text = "● " .. first .. (#names > 1 and (" +" .. (#names - 1)) or "")
					end
					badge.Visible = true
				elseif badge then
					badge.Visible = false
				end
			end
		end
	end

	local function decoratePresence()
		decorateRows(countryListItems, "country")
		decorateRows(provinceListItems, "province")
	end

	softRefresh = function()
		if not state.snapshot then
			return
		end
		local tab = state.currentTab
		if tab == "countries" then
			rebuildCountryList(countrySearch.Text)
		elseif tab == "provinces" then
			rebuildProvinceList(provinceSearch.Text)
		elseif tab == "cultures" or tab == "religions" then
			for _, fn in ipairs(identityTabRebuilders) do
				pcall(fn)
			end
		end
		decoratePresence()
	end

	local function touchesSelected(item)
		if not item then
			return false
		end
		if item.kind == "country" and state.selectedCountryTag == item.key then
			return true
		end
		if item.kind == "province" then
			local pid = tonumber(item.key) or item.key
			if state.selectedProvinceId == pid or tostring(state.selectedProvinceId) == tostring(pid) then
				return true
			end
		end
		return false
	end

	if liveSync then
		liveSync.OnClientEvent:Connect(function(payload)
			if type(payload) ~= "table" then
				return
			end
			if payload.reload then
				local snap = call("loadState")
				if snap then
					state.snapshot = snap
					softRefresh()
				end
				setStatus(
					string.format(
						"Reloaded — %s did %s",
						tostring(payload.originName or "another mapper"),
						tostring(payload.reason or "an undo")
					),
					PALETTE.warn
				)
				return
			end
			local items = payload.items or { payload }
			local hitSelected = false
			local diffs = {}
			for _, item in ipairs(items) do
				diffs[item] = diffFields(readBefore(item), item.value)
				applyDelta(item)
				if touchesSelected(item) then
					hitSelected = true
				end
			end
			softRefresh()
			local origin = payload.originName or "another mapper"
			if hitSelected and state.dirty then
				local first = items[1]
				local fields = diffs[first]
				local fieldStr = ""
				if fields and #fields > 0 then
					local preview = table.concat(fields, ", ", 1, math.min(3, #fields))
					if #fields > 3 then
						preview = preview .. ", +" .. (#fields - 3)
					end
					fieldStr = "  ·  fields: " .. preview
				end
				setStatus(
					string.format(
						"⚠ %s edited %s %s%s — your draft is preserved",
						origin,
						tostring(first.kind),
						tostring(first.key),
						fieldStr
					),
					PALETTE.warn
				)
			else
				local first = items[1]
				if first then
					local fields = diffs[first]
					local fieldStr = ""
					if fields and #fields > 0 then
						local preview = table.concat(fields, ", ", 1, math.min(3, #fields))
						if #fields > 3 then
							preview = preview .. ", +" .. (#fields - 3)
						end
						fieldStr = " (" .. preview .. ")"
					end
					setStatus(
						string.format(
							"Live · %s updated %s %s%s",
							origin,
							tostring(first.kind),
							tostring(first.key),
							fieldStr
						),
						PALETTE.accent
					)
				end
			end
		end)
	end

	if presenceRemote then
		presenceRemote.OnClientEvent:Connect(function(snapshot)
			state.presence = type(snapshot) == "table" and snapshot or {}
			decoratePresence()
		end)

		local lastSent
		local function sendPresence(kind, key)
			local sig = key ~= nil and (kind .. ":" .. tostring(key)) or nil
			if sig == lastSent then
				return
			end
			lastSent = sig
			if key == nil then
				presenceRemote:FireServer("clear")
			else
				presenceRemote:FireServer("update", { kind = kind, key = key })
			end
		end

		local RunService = game:GetService("RunService")
		local presenceTick = 0
		RunService.Heartbeat:Connect(function(dt)
			presenceTick = presenceTick + dt
			if presenceTick < 0.5 then
				return
			end
			presenceTick = 0
			if state.currentTab == "countries" and state.selectedCountryTag then
				sendPresence("country", state.selectedCountryTag)
			elseif state.currentTab == "provinces" and state.selectedProvinceId then
				sendPresence("province", state.selectedProvinceId)
			else
				sendPresence(nil, nil)
			end
		end)

		task.defer(function()
			presenceRemote:FireServer("request")
		end)
	end
end

setTab("countries")

do
	local stagingResp = call("isStagingEnabled")
	local stagingEnabled = type(stagingResp) == "table" and stagingResp.enabled == true
	if not stagingEnabled then
		return
	end

	local stagingOk, stagingErr = pcall(function()
		local chip = Instance.new("Frame")
		chip.Name = "DraftModeChip"
		chip.Size = UDim2.fromOffset(118, 20)
		chip.Position = UDim2.new(1, -72, 0.5, 0)
		chip.AnchorPoint = Vector2.new(1, 0.5)
		chip.BackgroundColor3 = PALETTE.accent
		chip.BackgroundTransparency = 0.15
		chip.BorderSizePixel = 0
		chip.Parent = titleBar

		local chipCorner = Instance.new("UICorner")
		chipCorner.CornerRadius = UDim.new(0, 4)
		chipCorner.Parent = chip

		local chipLabel = Instance.new("TextLabel")
		chipLabel.Size = UDim2.fromScale(1, 1)
		chipLabel.BackgroundTransparency = 1
		chipLabel.Text = "DRAFT MODE"
		chipLabel.TextColor3 = PALETTE.textBright
		chipLabel.Font = Enum.Font.GothamBold
		chipLabel.TextSize = 11
		chipLabel.TextXAlignment = Enum.TextXAlignment.Center
		chipLabel.Parent = chip

		local promoteBtn = makeButton(primaryRight, "↑  Promote", PALETTE.accent)
		promoteBtn.Size = UDim2.fromOffset(106, 28)
		promoteBtn.LayoutOrder = 3

		local pullBtn = makeButton(primaryRight, "⇣  Pull", PALETTE.bgInput)
		pullBtn.Size = UDim2.fromOffset(84, 28)
		pullBtn.LayoutOrder = 2

		local discardBtn = makeButton(primaryRight, "✕  Discard", PALETTE.bad)
		discardBtn.Size = UDim2.fromOffset(106, 28)
		discardBtn.LayoutOrder = 1

		attachTooltip(promoteBtn, "Pick which of your changes to publish to the live map")
		attachTooltip(pullBtn, "Refresh your draft from live — discards unsaved local edits")
		attachTooltip(discardBtn, "Delete your whole draft and reload the live state")

		local function valuePreview(value)
			if value == nil then
				return "<none>"
			end
			if type(value) == "string" then
				return value
			end
			if type(value) == "number" then
				return tostring(value)
			end
			if type(value) == "boolean" then
				return tostring(value)
			end
			if type(value) == "table" then
				local ok, json = pcall(game:GetService("HttpService").JSONEncode, game:GetService("HttpService"), value)
				if ok then
					if #json > 60 then
						return json:sub(1, 57) .. "..."
					end
					return json
				end
				return "<table>"
			end
			return tostring(value)
		end

		local function openPromoteModal(diffs)
			if #diffs == 0 then
				setStatus("No changes to promote — your draft matches shared.", PALETTE.warn)
				return
			end

			local modal = Instance.new("Frame")
			modal.Name = "PromoteModal"
			modal.AnchorPoint = Vector2.new(0.5, 0.5)
			modal.Position = UDim2.fromScale(0.5, 0.5)
			modal.Size = UDim2.fromOffset(720, 540)
			modal.BackgroundColor3 = PALETTE.bgPanel
			modal.BorderSizePixel = 0
			modal.ZIndex = 1000
			modal.Parent = root

			local overlay = Instance.new("Frame")
			overlay.Size = UDim2.fromScale(1, 1)
			overlay.BackgroundColor3 = Color3.new(0, 0, 0)
			overlay.BackgroundTransparency = 0.55
			overlay.BorderSizePixel = 0
			overlay.ZIndex = 999
			overlay.Parent = root

			local title = Instance.new("TextLabel")
			title.Text = string.format("Promote to Live  ·  %d change(s) detected", #diffs)
			title.Size = UDim2.new(1, -24, 0, 32)
			title.Position = UDim2.fromOffset(12, 8)
			title.BackgroundTransparency = 1
			title.TextColor3 = PALETTE.textBright
			title.Font = Enum.Font.GothamBold
			title.TextSize = 16
			title.TextXAlignment = Enum.TextXAlignment.Left
			title.ZIndex = 1001
			title.Parent = modal

			local scroll = Instance.new("ScrollingFrame")
			scroll.Position = UDim2.fromOffset(12, 52)
			scroll.Size = UDim2.new(1, -24, 1, -120)
			scroll.BackgroundColor3 = PALETTE.bgInput
			scroll.BorderSizePixel = 0
			scroll.ScrollBarThickness = 8
			scroll.CanvasSize = UDim2.fromOffset(0, 0)
			scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
			scroll.ZIndex = 1001
			scroll.Parent = modal

			local layout = Instance.new("UIListLayout")
			layout.Padding = UDim.new(0, 4)
			layout.SortOrder = Enum.SortOrder.LayoutOrder
			layout.Parent = scroll

			local checks = {}
			for i, d in ipairs(diffs) do
				local row = Instance.new("Frame")
				row.Size = UDim2.new(1, -8, 0, 44)
				row.BackgroundColor3 = PALETTE.bgPanel
				row.BorderSizePixel = 0
				row.LayoutOrder = i
				row.ZIndex = 1002
				row.Parent = scroll

				local isDelete = d.action == "delete"
				local onColor = isDelete and PALETTE.bad or PALETTE.accent

				local check = Instance.new("TextButton")
				check.Size = UDim2.fromOffset(22, 22)
				check.Position = UDim2.fromOffset(8, 11)
				check.BackgroundColor3 = isDelete and PALETTE.bgInput or onColor
				check.Text = isDelete and "" or "✓"
				check.TextColor3 = Color3.new(1, 1, 1)
				check.Font = Enum.Font.GothamBold
				check.TextSize = 16
				check.BorderSizePixel = 0
				check.ZIndex = 1003
				check.Parent = row
				checks[i] = { selected = not isDelete, button = check, diff = d }

				check.MouseButton1Click:Connect(function()
					checks[i].selected = not checks[i].selected
					check.BackgroundColor3 = checks[i].selected and onColor or PALETTE.bgInput
					check.Text = checks[i].selected and "✓" or ""
				end)

				local label = Instance.new("TextLabel")
				label.Size = UDim2.new(1, -40, 0, 18)
				label.Position = UDim2.fromOffset(38, 4)
				label.BackgroundTransparency = 1
				label.TextColor3 = isDelete and PALETTE.bad or PALETTE.textBright
				label.Font = Enum.Font.GothamSemibold
				label.TextSize = 13
				label.TextXAlignment = Enum.TextXAlignment.Left
				label.Text = string.format("[%s]  %s/%s", d.action:upper(), d.kind, tostring(d.key))
				label.ZIndex = 1003
				label.Parent = row

				local detail = Instance.new("TextLabel")
				detail.Size = UDim2.new(1, -40, 0, 18)
				detail.Position = UDim2.fromOffset(38, 22)
				detail.BackgroundTransparency = 1
				detail.TextColor3 = PALETTE.text
				detail.Font = Enum.Font.Code
				detail.TextSize = 11
				detail.TextXAlignment = Enum.TextXAlignment.Left
				if d.action == "add" then
					detail.Text = "shared: <none>  →  yours: " .. valuePreview(d.draftValue)
				elseif d.action == "delete" then
					detail.Text = "shared: " .. valuePreview(d.sharedValue) .. "  →  yours: <delete>"
				else
					detail.Text = "shared: "
						.. valuePreview(d.sharedValue)
						.. "  →  yours: "
						.. valuePreview(d.draftValue)
				end
				detail.ZIndex = 1003
				detail.Parent = row
			end

			local function close()
				overlay:Destroy()
				modal:Destroy()
			end

			local cancelBtn = makeButton(modal, "Cancel", PALETTE.bgInput)
			cancelBtn.Size = UDim2.fromOffset(120, 36)
			cancelBtn.Position = UDim2.new(1, -260, 1, -52)
			cancelBtn.AnchorPoint = Vector2.new(0, 0)
			cancelBtn.ZIndex = 1003
			cancelBtn.MouseButton1Click:Connect(close)
			overlay.MouseButton1Click:Connect(close)

			local confirmBtn = makeButton(modal, "Promote selected", PALETTE.good)
			confirmBtn.Size = UDim2.fromOffset(140, 36)
			confirmBtn.Position = UDim2.new(1, -130, 1, -52)
			confirmBtn.AnchorPoint = Vector2.new(0, 0)
			confirmBtn.ZIndex = 1003
			confirmBtn.MouseButton1Click:Connect(function()
				local selections = {}
				for _, c in ipairs(checks) do
					if c.selected then
						table.insert(selections, { kind = c.diff.kind, key = c.diff.key })
					end
				end
				close()
				if #selections == 0 then
					setStatus("No fields selected — nothing promoted.", PALETTE.warn)
					return
				end
				local result = call("promote", { selections = selections })
				if result then
					setStatus(string.format("Promoted %d change(s) to live.", #(result.promoted or {})), PALETTE.good)
				end
			end)
		end

		promoteBtn.MouseButton1Click:Connect(function()
			local diffResult = call("computeDiffVsShared")
			if type(diffResult) ~= "table" or not diffResult.ok then
				setStatus("Could not compute diff vs shared.", PALETTE.bad)
				return
			end
			openPromoteModal(diffResult.diffs or {})
		end)

		pullBtn.MouseButton1Click:Connect(function()
			showConfirm({
				title = "Pull from Live?",
				message = "Discards your unsaved local edits and reloads your draft from the current shared state. Continue?",
				confirmText = "Pull",
				cancelText = "Cancel",
				accent = PALETTE.accent,
				onConfirm = function()
					local snap = call("pullFromShared")
					if snap then
						state.snapshot = snap
						state.dirty = false
						markDirty(false)
						softRefresh()
						setStatus("Pulled from live — draft refreshed.", PALETTE.good)
					end
				end,
			})
		end)

		discardBtn.MouseButton1Click:Connect(function()
			showConfirm({
				title = "Discard your draft?",
				message = "Permanently deletes your draft from the DataStore and reloads the shared state. Other users are not affected. Continue?",
				confirmText = "Discard Draft",
				cancelText = "Cancel",
				accent = PALETTE.bad,
				onConfirm = function()
					local snap = call("discardDraft")
					if snap then
						state.snapshot = snap
						state.dirty = false
						markDirty(false)
						softRefresh()
						setStatus("Draft discarded.", PALETTE.warn)
					end
				end,
			})
		end)

		if liveSync then
			liveSync.OnClientEvent:Connect(function(payload)
				if type(payload) ~= "table" then
					return
				end
				if payload.sharedMoved then
					local promotedCount = type(payload.promoted) == "table" and #payload.promoted or 0
					setStatus(
						string.format(
							"%s promoted %d change(s) to live. Click Pull to refresh your draft.",
							tostring(payload.originName or "another mapper"),
							promotedCount
						),
						PALETTE.warn
					)
				end
			end)
		end
	end)
	if not stagingOk then
		warn("[DataEditor] staging UI failed to build: " .. tostring(stagingErr))
		setStatus("Draft tools failed to load — see console. Editing still works.", PALETTE.bad)
	end
end
