-- EditorClientV2 -- the rebuilt Data Editor on the DesignSystem (Phase 5). Opens with the backslash (\)
-- key, running alongside the legacy EditorClient (backtick) during the rebuild.
--
-- A themed window on the (unchanged) DataEditorService command protocol. Tabs: Countries (create/edit
-- definition fields), Provinces (virtualized list, owner + cores/claims chip editors), Identity
-- (cultures/religions/ideologies/governments create/edit/delete), Formables (author custom formable /
-- releasable definitions). Shows only authoritative DEFINITION fields (no derived/runtime noise like
-- manpower). Remaining: the owner suite (Phase 6 -- province painting, named Save/Load map configs).
-- Toggle with the backslash (\) key.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")

local DesignSystem = require(aow:WaitForChild("DesignSystem"))
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Components = aow:WaitForChild("UI"):WaitForChild("Components")
local Button = require(Components:WaitForChild("Button"))
local VirtualList = require(Components:WaitForChild("VirtualList"))

local api = aow:WaitForChild("Remotes"):WaitForChild("DataEditorAPI")
local remotesFolder = aow:WaitForChild("Remotes")
local FormablesClient = require(aow:WaitForChild("Modules"):WaitForChild("FormablesClient"))
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Fire a Bootstrap RemoteEvent (custom formables use SetFormable/RemoveFormable, not the editor API).
local function fireRemote(name, ...)
	local r = remotesFolder:FindFirstChild(name)
	if r then
		r:FireServer(...)
	end
end

-- ─────────────────────────── protocol client (same commands as DataEditorService) ───────────────────────────
local function editorCall(command, payload)
	local ok, response = pcall(function()
		return api:InvokeServer(command, payload)
	end)
	if not ok then
		return nil, tostring(response)
	end
	if type(response) == "table" and response.ok == false then
		return nil, response.error or "error"
	end
	if type(response) == "table" and response.result ~= nil then
		return response.result
	end
	return true
end

local state = { snapshot = nil, tab = "countries", selected = nil, loaded = false }
local formablesConn -- live-refresh subscription for the Formables tab (disconnected on tab change)

-- ─────────────────────────── small styled builders ───────────────────────────
local function frame(props)
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundColor3 = props.color or Colors.SurfaceElevated
	f.BackgroundTransparency = props.transparent and 1 or 0
	f.Size = props.size or UDim2.fromScale(1, 1)
	f.Position = props.position or UDim2.new()
	if props.anchor then f.AnchorPoint = props.anchor end
	f.Parent = props.parent
	return f
end

local function label(parent, text, role, color)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextColor3 = color or Colors.TextPrimary
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Center
	l.Size = UDim2.fromScale(1, 1)
	Typography.apply(l, role or "bodyMd")
	l.Parent = parent
	return l
end

local function textbox(parent, placeholder)
	local tb = Instance.new("TextBox")
	tb.BackgroundColor3 = Colors.SurfaceSunken or Colors.SurfaceBase
	tb.BorderSizePixel = 0
	tb.ClearTextOnFocus = false
	tb.Text = ""
	tb.PlaceholderText = placeholder or ""
	tb.TextColor3 = Colors.TextPrimary
	tb.TextXAlignment = Enum.TextXAlignment.Left
	tb.Size = UDim2.fromScale(1, 1)
	Typography.apply(tb, "bodyMd")
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = tb
	local stroke = Instance.new("UIStroke")
	stroke.Color = Colors.BorderStrong
	stroke.Thickness = 1
	stroke.Parent = tb
	tb.Parent = parent
	return tb
end

-- ─────────────────────────── window shell ───────────────────────────
local gui = Instance.new("ScreenGui")
gui.Name = "AoWDataEditorV2"
gui.ResetOnSpawn = false
gui.DisplayOrder = 1500000
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local root = frame({ parent = gui, color = Colors.SurfaceBase, size = UDim2.fromOffset(940, 640) })
root.Name = "Window"
root.AnchorPoint = Vector2.new(0.5, 0.5)
root.Position = UDim2.fromScale(0.5, 0.5)
do
	local s = Instance.new("UIStroke")
	s.Color = Colors.BorderStrong
	s.Thickness = 1
	s.Parent = root
end

-- header
local header = frame({ parent = root, color = Colors.SurfaceElevated, size = UDim2.new(1, 0, 0, 40) })
header.Name = "Header"
do
	local title = label(header, "Data Editor", "displayLg")
	title.Position = UDim2.fromOffset(14, 0)
	title.Size = UDim2.new(0, 240, 1, 0)
end
local status = label(header, "", "bodySm", Colors.TextSecondary)
status.Position = UDim2.fromOffset(270, 0)
status.Size = UDim2.new(1, -300, 1, 0)
local function setStatus(text, color)
	status.Text = text or ""
	status.TextColor3 = color or Colors.TextSecondary
end

local closeBtn = Button.create({
	parent = header,
	variant = "ghost",
	text = "Close (\\)",
	width = 92,
	onClick = function()
		gui.Enabled = false
	end,
})
closeBtn.AnchorPoint = Vector2.new(1, 0.5)
closeBtn.Position = UDim2.new(1, -10, 0.5, 0)

-- tab row
local TABS = {
	{ key = "countries", label = "Countries" },
	{ key = "provinces", label = "Provinces" },
	{ key = "identity", label = "Identity" },
	{ key = "formables", label = "Formables" },
	{ key = "saves", label = "Saves" },
}
local tabRow = frame({ parent = root, transparent = true, size = UDim2.new(1, 0, 0, 34), position = UDim2.fromOffset(0, 40) })
local tabButtons = {}

-- body (leaves room for the global action footer at the bottom)
local body = frame({ parent = root, transparent = true, size = UDim2.new(1, -20, 1, -124), position = UDim2.fromOffset(10, 78) })
body.Name = "Body"

local render -- fwd
local applySnapshot -- fwd (set snapshot + status + re-render; used by loadState / reload / undo / redo)

local function selectTab(key)
	state.tab = key
	state.selected = nil
	state.paintOwner = nil -- disarm map painting when leaving the Provinces tab
	for k, b in pairs(tabButtons) do
		local labelChild = b:FindFirstChildWhichIsA("TextLabel")
		b.BackgroundColor3 = (k == key) and Colors.SurfaceOverlay or Colors.SurfaceElevated
		if labelChild then labelChild.TextColor3 = (k == key) and Colors.Accent or Colors.TextSecondary end
	end
	render()
end

do
	local x = 10
	for _, def in ipairs(TABS) do
		local b = Instance.new("TextButton")
		b.AutoButtonColor = false
		b.BackgroundColor3 = Colors.SurfaceElevated
		b.BorderSizePixel = 0
		b.Size = UDim2.fromOffset(120, 26)
		b.Position = UDim2.fromOffset(x, 4)
		b.Text = ""
		b.Parent = tabRow
		local lbl = label(b, def.label, "label", Colors.TextSecondary)
		lbl.TextXAlignment = Enum.TextXAlignment.Center
		b.MouseButton1Click:Connect(function() selectTab(def.key) end)
		tabButtons[def.key] = b
		x += 128
	end
end

-- ─────────────────────────── global action footer (Save / Reload / Undo / Redo) ───────────────────────────
-- The everyday editor operations. Save persists to the DataStore (publishes to the live map); Reload pulls
-- a fresh server snapshot; Undo/Redo return an updated snapshot the server rebuilds from its history.
local footer = frame({ parent = root, transparent = true, size = UDim2.new(1, -20, 0, 30), position = UDim2.new(0, 10, 1, -38) })
do
	local x = 0
	local saveBtn = Button.create({
		parent = footer,
		variant = "primary",
		text = "Save to DataStore",
		width = 156,
		onClick = function()
			setStatus("Saving…", Colors.TextSecondary)
			local res, err = editorCall("save")
			if res then
				setStatus((type(res) == "table" and res.message) or "Saved", Colors.Positive)
			else
				setStatus("Save failed: " .. tostring(err), Colors.Negative)
			end
		end,
	})
	saveBtn.Position = UDim2.fromOffset(x, 0)
	x += 164

	local reloadBtn = Button.create({
		parent = footer,
		variant = "ghost",
		text = "Reload",
		width = 90,
		onClick = function()
			local snap, err = editorCall("reloadState")
			if snap and type(snap) == "table" and snap.countries then
				state.selected = nil
				applySnapshot(snap)
				setStatus("Reloaded from server", Colors.Positive)
			else
				setStatus("Reload failed: " .. tostring(err), Colors.Negative)
			end
		end,
	})
	reloadBtn.Position = UDim2.fromOffset(x, 0)
	x += 98

	local undoBtn = Button.create({
		parent = footer,
		variant = "ghost",
		text = "Undo",
		width = 80,
		onClick = function()
			local snap, err = editorCall("undo")
			if snap and type(snap) == "table" and snap.countries then
				applySnapshot(snap)
				setStatus("Undo: " .. tostring(snap.undoLabel or "✓"), Colors.Positive)
			else
				setStatus("Nothing to undo" .. (err and (" (" .. err .. ")") or ""), Colors.TextSecondary)
			end
		end,
	})
	undoBtn.Position = UDim2.fromOffset(x, 0)
	x += 88

	local redoBtn = Button.create({
		parent = footer,
		variant = "ghost",
		text = "Redo",
		width = 80,
		onClick = function()
			local snap, err = editorCall("redo")
			if snap and type(snap) == "table" and snap.countries then
				applySnapshot(snap)
				setStatus("Redo: " .. tostring(snap.redoLabel or "✓"), Colors.Positive)
			else
				setStatus("Nothing to redo" .. (err and (" (" .. err .. ")") or ""), Colors.TextSecondary)
			end
		end,
	})
	redoBtn.Position = UDim2.fromOffset(x, 0)
	x += 88
end

-- sorted array of a dict's keys (as strings), for dropdown option lists.
local function sortedKeys(dict)
	local out = {}
	for k in pairs(dict or {}) do
		out[#out + 1] = k
	end
	table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
	return out
end

-- Lightweight dropdown (no shared component exists). cfg: { parent, size, position, options[], value, onChange? }.
-- The popup + a full-screen click-catcher live on the root ScreenGui so they overlay and close on outside click.
local openPopup
local function dropdown(cfg)
	local btn = Instance.new("TextButton")
	btn.AutoButtonColor = false
	btn.BackgroundColor3 = Colors.SurfaceSunken or Colors.SurfaceBase
	btn.BorderSizePixel = 0
	btn.Size = cfg.size
	btn.Position = cfg.position
	btn.Text = ""
	btn.Parent = cfg.parent
	local s = Instance.new("UIStroke")
	s.Color = Colors.BorderStrong
	s.Thickness = 1
	s.Parent = btn
	local lbl = label(btn, cfg.value or "—", "bodyMd")
	lbl.Position = UDim2.fromOffset(8, 0)
	lbl.Size = UDim2.new(1, -16, 1, 0)
	local current = cfg.value

	local function closePopup()
		if openPopup then
			openPopup:Destroy() -- its Destroying handler removes the catcher too
			openPopup = nil
		end
	end

	btn.MouseButton1Click:Connect(function()
		closePopup()
		local catcher = Instance.new("TextButton")
		catcher.BackgroundTransparency = 1
		catcher.AutoButtonColor = false
		catcher.Text = ""
		catcher.Size = UDim2.fromScale(1, 1)
		catcher.ZIndex = 60
		catcher.Parent = gui
		catcher.MouseButton1Click:Connect(closePopup)

		local n = #cfg.options
		local popup = Instance.new("ScrollingFrame")
		popup.BackgroundColor3 = Colors.SurfaceElevated
		popup.BorderSizePixel = 0
		popup.ScrollBarThickness = 4
		popup.ZIndex = 61
		popup.CanvasSize = UDim2.fromOffset(0, n * 24)
		local abs, sz = btn.AbsolutePosition, btn.AbsoluteSize
		popup.Size = UDim2.fromOffset(sz.X, math.min(math.max(n, 1), 8) * 24)
		popup.Position = UDim2.fromOffset(abs.X, abs.Y + sz.Y)
		popup.Parent = gui
		local ps = Instance.new("UIStroke")
		ps.Color = Colors.BorderStrong
		ps.Thickness = 1
		ps.Parent = popup
		popup.Destroying:Connect(function()
			if catcher then catcher:Destroy() end
		end)

		for i, opt in ipairs(cfg.options) do
			local ob = Instance.new("TextButton")
			ob.AutoButtonColor = true
			ob.BackgroundColor3 = Colors.SurfaceElevated
			ob.BorderSizePixel = 0
			ob.ZIndex = 62
			ob.Size = UDim2.new(1, 0, 0, 24)
			ob.Position = UDim2.fromOffset(0, (i - 1) * 24)
			ob.Text = ""
			local ol = label(ob, opt, "bodySm")
			ol.Position = UDim2.fromOffset(8, 0)
			ol.Size = UDim2.new(1, -12, 1, 0)
			ol.ZIndex = 63
			ob.MouseButton1Click:Connect(function()
				current = opt
				lbl.Text = opt
				closePopup()
				if cfg.onChange then cfg.onChange(opt) end
			end)
			ob.Parent = popup
		end
		openPopup = popup
	end)

	return { instance = btn, get = function() return current end }
end

-- Editable set of tags shown as removable chips + a "+ add" dropdown of the remaining options.
-- Returns { get } -> sorted array of the current tags. Used for province cores/claims editing.
local function tagListEditor(parent, currentList, allTags)
	local container = frame({ parent = parent, transparent = true, size = UDim2.fromScale(1, 0) })
	container.AutomaticSize = Enum.AutomaticSize.Y
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Wraps = true
	layout.Padding = UDim.new(0, 4)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = container

	local set = {}
	for _, t in ipairs(currentList or {}) do
		set[t] = true
	end

	local rebuild
	local function chip(tag)
		local c = frame({ parent = container, color = Colors.SurfaceOverlay, size = UDim2.fromOffset(0, 22) })
		c.AutomaticSize = Enum.AutomaticSize.X
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 6)
		pad.PaddingRight = UDim.new(0, 2)
		pad.Parent = c
		local h = Instance.new("UIListLayout")
		h.FillDirection = Enum.FillDirection.Horizontal
		h.VerticalAlignment = Enum.VerticalAlignment.Center
		h.Padding = UDim.new(0, 2)
		h.Parent = c
		local tl = Instance.new("TextLabel")
		tl.BackgroundTransparency = 1
		tl.Text = tag
		tl.TextColor3 = Colors.TextPrimary
		tl.AutomaticSize = Enum.AutomaticSize.X
		tl.Size = UDim2.fromOffset(0, 22)
		Typography.apply(tl, "bodySm")
		tl.Parent = c
		local x = Instance.new("TextButton")
		x.BackgroundTransparency = 1
		x.Text = "\u{00D7}"
		x.TextColor3 = Colors.TextSecondary
		x.Size = UDim2.fromOffset(16, 22)
		Typography.apply(x, "bodyMd")
		x.Parent = c
		x.MouseButton1Click:Connect(function()
			set[tag] = nil
			rebuild()
		end)
	end

	rebuild = function()
		for _, ch in container:GetChildren() do
			if ch:IsA("GuiObject") then ch:Destroy() end
		end
		local tags = {}
		for t in pairs(set) do tags[#tags + 1] = t end
		table.sort(tags)
		for _, t in ipairs(tags) do chip(t) end
		local avail = {}
		for _, t in ipairs(allTags) do
			if not set[t] then avail[#avail + 1] = t end
		end
		if #avail > 0 then
			dropdown({
				parent = container,
				size = UDim2.fromOffset(72, 22),
				position = UDim2.new(),
				options = avail,
				value = "+ add",
				onChange = function(t)
					set[t] = true
					rebuild()
				end,
			})
		end
	end
	rebuild()

	return {
		get = function()
			local out = {}
			for t in pairs(set) do out[#out + 1] = t end
			table.sort(out)
			return out
		end,
	}
end

-- ─────────────────────────── reusable list column (search + VirtualList) ───────────────────────────
-- cfg: { parent, getKeys(query) -> array, labelFor(key) -> string, onSelect(key), rowHeight? }
local function listColumn(cfg)
	local col = frame({ parent = cfg.parent, transparent = true, size = UDim2.new(0, 300, 1, 0) })
	local search = textbox(col, "Search…")
	search.Size = UDim2.new(1, 0, 0, 28)
	local holder = frame({ parent = col, color = Colors.SurfaceBase, size = UDim2.new(1, 0, 1, -34), position = UDim2.fromOffset(0, 34) })
	do
		local s = Instance.new("UIStroke")
		s.Color = Colors.BorderSubtle
		s.Thickness = 1
		s.Parent = holder
	end

	local keys = {}
	local vlist
	vlist = VirtualList.create({
		parent = holder,
		rowHeight = cfg.rowHeight or 26,
		getCount = function() return #keys end,
		createRow = function()
			local row = Instance.new("TextButton")
			row.AutoButtonColor = false
			row.BackgroundColor3 = Colors.SurfaceElevated
			row.BackgroundTransparency = 0.35
			row.BorderSizePixel = 0
			row.Text = ""
			local rl = label(row, "", "bodySm")
			rl.Position = UDim2.fromOffset(8, 0)
			rl.Size = UDim2.new(1, -12, 1, 0)
			row.MouseButton1Click:Connect(function()
				local key = row:GetAttribute("key")
				if key ~= nil then cfg.onSelect(key) end
			end)
			return row
		end,
		bindRow = function(row, i)
			local key = keys[i]
			row:SetAttribute("key", key)
			local rl = row:FindFirstChildWhichIsA("TextLabel")
			if rl then rl.Text = cfg.labelFor(key) end
		end,
	})

	local function rebuild()
		keys = cfg.getKeys(search.Text)
		vlist.refresh()
	end
	search:GetPropertyChangedSignal("Text"):Connect(rebuild)
	rebuild()
	return col
end

-- ─────────────────────────── Countries tab ───────────────────────────
local function sortedMatching(dict, query, keyToText)
	query = string.lower(query or "")
	local out = {}
	for k, v in pairs(dict or {}) do
		if query == "" or string.find(string.lower(keyToText(k, v)), query, 1, true) then
			out[#out + 1] = k
		end
	end
	table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
	return out
end

local function clearDetail(detail)
	for _, ch in detail:GetChildren() do
		if not ch:IsA("UIStroke") then
			ch:Destroy()
		end
	end
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)
	pad.PaddingTop = UDim.new(0, 12)
	pad.Parent = detail
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = detail
end

local function makeDetailPane(columns)
	local detail = frame({ parent = columns, color = Colors.SurfaceBase, size = UDim2.new(1, -312, 1, 0), position = UDim2.fromOffset(312, 0) })
	local s = Instance.new("UIStroke")
	s.Color = Colors.BorderSubtle
	s.Thickness = 1
	s.Parent = detail
	return detail
end

local function readonlyRow(detail, name, value)
	local r = frame({ parent = detail, transparent = true, size = UDim2.new(1, 0, 0, 22) })
	label(r, name, "bodySm", Colors.TextSecondary).Size = UDim2.new(0, 90, 1, 0)
	local v = label(r, tostring(value or "—"), "bodySm")
	v.Position = UDim2.fromOffset(96, 0)
	v.Size = UDim2.new(1, -96, 1, 0)
end

local function renderCountries()
	local snap = state.snapshot
	local columns = frame({ parent = body, transparent = true })
	-- Detail pane is built once; only its contents refresh on selection, so the list column's search box
	-- and scroll position persist across clicks.
	local detail = makeDetailPane(columns)

	local function showDetail(tag)
		clearDetail(detail)
		local c = tag and snap.countries[tag] or nil
		local isNew = (tag == nil)

		local newBtn = Button.create({
			parent = detail,
			variant = "ghost",
			text = "+ New Country",
			width = 140,
			onClick = function()
				state.selected = nil
				showDetail(nil)
			end,
		})
		newBtn.LayoutOrder = -1

		if not isNew and not c then
			label(detail, "Select a country", "bodyMd", Colors.TextSecondary)
			return
		end
		label(detail, isNew and "New Country" or tostring(tag), "displayLg").Size = UDim2.new(1, 0, 0, 26)

		local function field(name, value, placeholder)
			local r = frame({ parent = detail, transparent = true, size = UDim2.new(1, 0, 0, 28) })
			label(r, name, "bodySm", Colors.TextSecondary).Size = UDim2.new(0, 90, 1, 0)
			local tb = textbox(r, placeholder or "")
			tb.Size = UDim2.new(1, -96, 1, 0)
			tb.Position = UDim2.fromOffset(96, 0)
			tb.Text = value or ""
			return tb
		end

		local tagBox = isNew and field("Tag", "", "e.g. FRA") or nil
		local nameBox = field("Name", c and c.displayName or "", "display name")

		local colorRow = frame({ parent = detail, transparent = true, size = UDim2.new(1, 0, 0, 28) })
		label(colorRow, "Colour", "bodySm", Colors.TextSecondary).Size = UDim2.new(0, 90, 1, 0)
		local col3 = (c and c.color) or { 150, 150, 150 }
		local boxes = {}
		for i = 1, 3 do
			local b = textbox(colorRow, tostring(col3[i] or 0))
			b.Size = UDim2.new(0, 52, 1, 0)
			b.Position = UDim2.fromOffset(96 + (i - 1) * 58, 0)
			b.Text = tostring(col3[i] or 0)
			boxes[i] = b
		end
		local swatch = frame({ parent = colorRow, size = UDim2.fromOffset(24, 24), position = UDim2.fromOffset(96 + 3 * 58 + 6, 2) })
		local function refreshSwatch()
			swatch.BackgroundColor3 = Color3.fromRGB(
				tonumber(boxes[1].Text) or 0, tonumber(boxes[2].Text) or 0, tonumber(boxes[3].Text) or 0
			)
		end
		refreshSwatch()
		for _, b in ipairs(boxes) do b:GetPropertyChangedSignal("Text"):Connect(refreshSwatch) end

		-- Capital: editable province id when creating (must be an existing province); read-only otherwise.
		-- Compose the nation's territory afterward by setting province owners in the Provinces tab.
		local capBox = isNew and field("Capital prov ID", "", "province id") or nil
		if not isNew then
			readonlyRow(detail, "Capital", c.capitalProvinceId)
		end

		-- editable definition fields via dropdowns (options from the snapshot); derived/runtime fields
		-- (manpower, treasury, ...) are intentionally omitted -- they're recomputed, not definition data.
		local function ddRow(name, options, value)
			local r = frame({ parent = detail, transparent = true, size = UDim2.new(1, 0, 0, 26) })
			label(r, name, "bodySm", Colors.TextSecondary).Size = UDim2.new(0, 90, 1, 0)
			return dropdown({ parent = r, size = UDim2.new(1, -96, 1, 0), position = UDim2.fromOffset(96, 0), options = options, value = value })
		end
		local cultureDD = ddRow("Culture", sortedKeys(snap.cultures), c and c.primaryCulture)
		local religionDD = ddRow("Religion", sortedKeys(snap.religions), c and c.stateReligion)
		local govDD = ddRow("Government", sortedKeys(snap.governmentTypes), c and c.governmentForm)
		local ideoDD = ddRow("Ideology", sortedKeys(snap.ideologies), c and c.ideology)

		local saveBtn = Button.create({
			parent = detail,
			variant = "primary",
			text = isNew and "Create" or "Save",
			width = 120,
			onClick = function()
				local newColor = { tonumber(boxes[1].Text) or 0, tonumber(boxes[2].Text) or 0, tonumber(boxes[3].Text) or 0 }
				local opts = {
					displayName = nameBox.Text,
					color = newColor,
					primaryCulture = cultureDD.get(),
					stateReligion = religionDD.get(),
					governmentForm = govDD.get(),
					ideology = ideoDD.get(),
				}
				if isNew then
					local newTag = (tagBox.Text or ""):gsub("%s", "")
					if #newTag < 2 then
						setStatus("Tag needs 2+ characters", Colors.Negative)
						return
					end
					opts.capitalProvinceId = tonumber(capBox.Text)
					local res, err = editorCall("addCountry", { tag = newTag, opts = opts })
					if res then
						opts.tag = newTag
						snap.countries[newTag] = opts
						state.selected = newTag
						setStatus("Created " .. newTag, Colors.Positive)
						showDetail(newTag)
					else
						setStatus("Create failed: " .. tostring(err), Colors.Negative)
					end
				else
					local res, err = editorCall("updateCountry", { tag = tag, opts = opts })
					if res then
						c.displayName = opts.displayName
						c.color = opts.color
						c.primaryCulture = opts.primaryCulture
						c.stateReligion = opts.stateReligion
						c.governmentForm = opts.governmentForm
						c.ideology = opts.ideology
						setStatus("Saved " .. tostring(tag), Colors.Positive)
					else
						setStatus("Save failed: " .. tostring(err), Colors.Negative)
					end
				end
			end,
		})
		saveBtn.LayoutOrder = 99
	end

	listColumn({
		parent = columns,
		getKeys = function(q)
			return sortedMatching(snap.countries, q, function(tag, c)
				return tostring(tag) .. " " .. (c.displayName or "")
			end)
		end,
		labelFor = function(tag)
			local c = snap.countries[tag]
			return string.format("%s  —  %s", tostring(tag), (c and c.displayName) or "?")
		end,
		onSelect = function(tag)
			state.selected = tag
			showDetail(tag)
		end,
	})

	showDetail(state.selected)
end

-- ─────────────────────────── Provinces tab (virtualized; owner + cores/claims editor + map painting) ───────────────────────────
local function renderProvinces()
	local snap = state.snapshot

	-- Paint control row: pick an owner, then click land tiles on the map to assign it (Phase 6 painting).
	-- The click hook lives at module scope (below) and reads state.paintOwner.
	local paintRow = frame({ parent = body, transparent = true, size = UDim2.new(1, 0, 0, 30) })
	label(paintRow, "Paint owner:", "bodySm", Colors.TextSecondary).Size = UDim2.new(0, 90, 1, 0)
	local paintHint = label(
		paintRow,
		state.paintOwner and ("Painting → " .. state.paintOwner .. "  (click land tiles)")
			or "Pick an owner, then click land tiles on the map",
		"bodySm",
		state.paintOwner and Colors.Positive or Colors.TextSecondary
	)
	paintHint.Position = UDim2.fromOffset(360, 0)
	paintHint.Size = UDim2.new(1, -360, 1, 0)
	dropdown({
		parent = paintRow,
		size = UDim2.fromOffset(150, 26),
		position = UDim2.fromOffset(96, 2),
		options = sortedKeys(snap.countries),
		value = state.paintOwner or "— pick —",
		onChange = function(tag)
			state.paintOwner = tag
			paintHint.Text = "Painting → " .. tag .. "  (click land tiles)"
			paintHint.TextColor3 = Colors.Positive
		end,
	})
	local stopBtn = Button.create({
		parent = paintRow,
		variant = "ghost",
		text = "Stop paint",
		width = 100,
		onClick = function()
			state.paintOwner = nil
			paintHint.Text = "Paint off"
			paintHint.TextColor3 = Colors.TextSecondary
		end,
	})
	stopBtn.Position = UDim2.fromOffset(256, 2)

	local columns = frame({ parent = body, transparent = true, size = UDim2.new(1, 0, 1, -36), position = UDim2.fromOffset(0, 36) })
	local detail = makeDetailPane(columns)

	local function showDetail(id)
		clearDetail(detail)
		local p = id and snap.provinces[id]
		if not p then
			label(detail, "Select a province", "bodyMd", Colors.TextSecondary)
			return
		end
		label(detail, string.format("#%s  %s", tostring(id), p.name or "?"), "displayLg").Size = UDim2.new(1, 0, 0, 26)

		local countryTags = sortedKeys(snap.countries)

		-- Owner (editable; controller follows owner on an ownership edit).
		local ownerRow = frame({ parent = detail, transparent = true, size = UDim2.new(1, 0, 0, 26) })
		label(ownerRow, "Owner", "bodySm", Colors.TextSecondary).Size = UDim2.new(0, 90, 1, 0)
		local ownerDD = dropdown({ parent = ownerRow, size = UDim2.new(1, -96, 1, 0), position = UDim2.fromOffset(96, 0), options = countryTags, value = p.ownerTag })

		readonlyRow(detail, "Controller", p.controllerTag)
		readonlyRow(detail, "Culture", p.culture)
		readonlyRow(detail, "Religion", p.religion)

		-- Cores / claims -- the v4 data, edited as chip lists (single source of truth: the province).
		label(detail, "Cores", "bodySm", Colors.TextSecondary).Size = UDim2.new(1, 0, 0, 18)
		local coresEd = tagListEditor(detail, p.cores, countryTags)
		label(detail, "Claims", "bodySm", Colors.TextSecondary).Size = UDim2.new(1, 0, 0, 18)
		local claimsEd = tagListEditor(detail, p.claims, countryTags)

		local saveBtn = Button.create({
			parent = detail,
			variant = "primary",
			text = "Save",
			width = 120,
			onClick = function()
				local opts = { cores = coresEd.get(), claims = claimsEd.get() }
				local newOwner = ownerDD.get()
				if newOwner and newOwner ~= p.ownerTag then
					opts.ownerTag = newOwner
					opts.controllerTag = newOwner
				end
				local res, err = editorCall("updateProvince", { id = id, opts = opts })
				if res then
					p.cores = opts.cores
					p.claims = opts.claims
					if opts.ownerTag then
						p.ownerTag = opts.ownerTag
						p.controllerTag = opts.controllerTag
					end
					setStatus("Saved province #" .. tostring(id), Colors.Positive)
				else
					setStatus("Save failed: " .. tostring(err), Colors.Negative)
				end
			end,
		})
		saveBtn.LayoutOrder = 99
	end

	listColumn({
		parent = columns,
		getKeys = function(q)
			return sortedMatching(snap.provinces, q, function(id, p)
				return tostring(id) .. " " .. (p.name or "")
			end)
		end,
		labelFor = function(id)
			local p = snap.provinces[id]
			return string.format("#%s  %s", tostring(id), (p and p.name) or "?")
		end,
		onSelect = function(id)
			state.selected = id
			showDetail(id)
		end,
	})

	showDetail(state.selected)
end

-- Formables authoring (Phase 6): create/edit custom formable/releasable definitions. Saves fire the
-- admin-gated SetFormable remote -> FormableStore (persist + replicate); the list live-refreshes when the
-- replicated set changes. Lists the merged static+custom set; editing any tag writes a custom override.
local function renderFormables()
	local columns = frame({ parent = body, transparent = true })
	local detail = makeDetailPane(columns)
	local YESNO = { "Yes", "No" }

	local function showDetail(tag)
		clearDetail(detail)
		local def = tag and FormablesClient.getAll()[tag] or nil

		local newBtn = Button.create({
			parent = detail,
			variant = "ghost",
			text = "+ New Formable",
			width = 150,
			onClick = function()
				state.selected = nil
				showDetail(nil)
			end,
		})
		newBtn.LayoutOrder = -1

		label(detail, tag and ("Edit " .. tag) or "New Formable", "displayLg").Size = UDim2.new(1, 0, 0, 26)

		local function field(name, value)
			local r = frame({ parent = detail, transparent = true, size = UDim2.new(1, 0, 0, 26) })
			label(r, name, "bodySm", Colors.TextSecondary).Size = UDim2.new(0, 120, 1, 0)
			local tb = textbox(r, "")
			tb.Size = UDim2.new(1, -126, 1, 0)
			tb.Position = UDim2.fromOffset(126, 0)
			tb.Text = value or ""
			return tb
		end
		local function ddYesNo(name, isYes)
			local r = frame({ parent = detail, transparent = true, size = UDim2.new(1, 0, 0, 26) })
			label(r, name, "bodySm", Colors.TextSecondary).Size = UDim2.new(0, 120, 1, 0)
			return dropdown({ parent = r, size = UDim2.new(0, 90, 1, 0), position = UDim2.fromOffset(126, 0), options = YESNO, value = isYes and "Yes" or "No" })
		end

		local tagBox = field("Tag", tag or "")
		local nameBox = field("Display name", def and def.displayName or "")
		local col3 = (def and def.color) or { 150, 150, 150 }
		local reqBox = field("Required province IDs", def and def.requiredProvinceIds and table.concat(def.requiredProvinceIds, ", ") or "")
		local colorBox = field("Colour (r,g,b)", string.format("%d, %d, %d", col3[1] or 0, col3[2] or 0, col3[3] or 0))
		local flagBox = field("Flag (rbxassetid)", (def and def.flag) or "")
		local bonusBox = field("Form bonus: stability", def and def.formBonuses and tostring(def.formBonuses.stability or "") or "")
		local canFormDD = ddYesNo("Can form", def == nil or def.canForm ~= false)
		local canReleaseDD = ddYesNo("Can release", def == nil or def.canRelease ~= false)

		local saveBtn = Button.create({
			parent = detail,
			variant = "primary",
			text = "Save",
			width = 120,
			onClick = function()
				local newTag = (tagBox.Text or ""):gsub("%s", "")
				if newTag == "" then
					setStatus("A tag is required", Colors.Negative)
					return
				end
				local ids = {}
				for s in string.gmatch(reqBox.Text or "", "%d+") do
					ids[#ids + 1] = tonumber(s)
				end
				local rgb = {}
				for s in string.gmatch(colorBox.Text or "", "%d+") do
					rgb[#rgb + 1] = tonumber(s)
				end
				local newDef = {
					displayName = nameBox.Text,
					color = { rgb[1] or 150, rgb[2] or 150, rgb[3] or 150 },
					requiredProvinceIds = ids,
					canForm = canFormDD.get() == "Yes",
					canRelease = canReleaseDD.get() == "Yes",
				}
				if flagBox.Text ~= "" then
					newDef.flag = flagBox.Text
				end
				local stab = tonumber(bonusBox.Text)
				if stab then
					newDef.formBonuses = { stability = stab }
				end
				fireRemote("SetFormable", newTag, newDef)
				state.selected = newTag
				setStatus("Saved formable " .. newTag .. " (replicating\u{2026})", Colors.Positive)
			end,
		})
		saveBtn.LayoutOrder = 98

		if tag then
			local delBtn = Button.create({
				parent = detail,
				variant = "danger",
				text = "Delete custom",
				width = 130,
				onClick = function()
					fireRemote("RemoveFormable", tag)
					state.selected = nil
					setStatus("Removed custom formable " .. tag, Colors.Positive)
				end,
			})
			delBtn.LayoutOrder = 99
		end
	end

	listColumn({
		parent = columns,
		getKeys = function(q)
			local defs = FormablesClient.getAll()
			q = string.lower(q or "")
			local out = {}
			for tag, d in pairs(defs) do
				if q == "" or string.find(string.lower(tag .. " " .. (d.displayName or "")), q, 1, true) then
					out[#out + 1] = tag
				end
			end
			table.sort(out)
			return out
		end,
		labelFor = function(tag)
			local d = FormablesClient.getAll()[tag]
			return string.format("%s  \u{2014}  %s", tag, (d and d.displayName) or "?")
		end,
		onSelect = function(tag)
			state.selected = tag
			showDetail(tag)
		end,
	})

	-- Live-refresh when the replicated custom set changes (after a Save/Delete round-trips the server).
	formablesConn = FormablesClient.onChanged(function()
		render()
	end)

	showDetail(state.selected)
end

-- ─────────────────────────── Identity tab (cultures / religions / ideologies / governments) ───────────────────────────
-- One tab with a kind selector; each kind maps to its snapshot dict + add/update/remove commands.
-- Editing is displayName + create/delete (universal & safe); other scalar fields show read-only. Modifier
-- maps stay seed-file authored for now.
local REGISTRIES = {
	{ kind = "cultures", label = "Cultures", singular = "Culture", key = "cultures", add = "addCulture", update = "updateCulture", remove = "removeCulture" },
	{ kind = "religions", label = "Religions", singular = "Religion", key = "religions", add = "addReligion", update = "updateReligion", remove = "removeReligion" },
	{ kind = "ideologies", label = "Ideologies", singular = "Ideology", key = "ideologies", add = "addIdeology", update = "updateIdeology", remove = "removeIdeology" },
	{ kind = "governments", label = "Governments", singular = "Government", key = "governmentTypes", add = "addGovernmentType", update = "updateGovernmentType", remove = "removeGovernmentType" },
}

local function currentRegistry()
	local kind = state.registryKind or "cultures"
	for _, r in ipairs(REGISTRIES) do
		if r.kind == kind then return r end
	end
	return REGISTRIES[1]
end

local function renderIdentity()
	local snap = state.snapshot
	local reg = currentRegistry()

	-- kind selector row (primary = active, ghost = inactive)
	local kindRow = frame({ parent = body, transparent = true, size = UDim2.new(1, 0, 0, 30) })
	local x = 0
	for _, r in ipairs(REGISTRIES) do
		local b = Button.create({
			parent = kindRow,
			variant = (r.kind == reg.kind) and "primary" or "ghost",
			text = r.label,
			width = 116,
			onClick = function()
				state.registryKind = r.kind
				state.selected = nil
				render()
			end,
		})
		b.Position = UDim2.fromOffset(x, 0)
		x += 122
	end

	local columns = frame({ parent = body, transparent = true, size = UDim2.new(1, 0, 1, -36), position = UDim2.fromOffset(0, 36) })
	local detail = makeDetailPane(columns)
	local store = snap[reg.key] or {}

	local function showDetail(id)
		clearDetail(detail)
		local rec = id and store[id] or nil
		local isNew = (id == nil)

		local newBtn = Button.create({
			parent = detail,
			variant = "ghost",
			text = "+ New " .. reg.singular,
			width = 160,
			onClick = function()
				state.selected = nil
				showDetail(nil)
			end,
		})
		newBtn.LayoutOrder = -1

		if not isNew and not rec then
			label(detail, "Select an entry", "bodyMd", Colors.TextSecondary)
			return
		end
		label(detail, isNew and ("New " .. reg.singular) or tostring(id), "displayLg").Size = UDim2.new(1, 0, 0, 26)

		local function field(name, value, placeholder)
			local r = frame({ parent = detail, transparent = true, size = UDim2.new(1, 0, 0, 28) })
			label(r, name, "bodySm", Colors.TextSecondary).Size = UDim2.new(0, 90, 1, 0)
			local tb = textbox(r, placeholder or "")
			tb.Size = UDim2.new(1, -96, 1, 0)
			tb.Position = UDim2.fromOffset(96, 0)
			tb.Text = value or ""
			return tb
		end

		local idBox = isNew and field("ID", "", "e.g. french") or nil
		local nameBox = field("Display name", rec and rec.displayName or "", "display name")

		-- Any other scalar fields shown read-only (modifier maps are seed-file authored for now).
		if rec then
			for _, k in ipairs(sortedKeys(rec)) do
				local v = rec[k]
				if k ~= "id" and k ~= "displayName"
					and (type(v) == "string" or type(v) == "number" or type(v) == "boolean") then
					readonlyRow(detail, k, v)
				end
			end
		end

		local saveBtn = Button.create({
			parent = detail,
			variant = "primary",
			text = isNew and "Create" or "Save",
			width = 120,
			onClick = function()
				local opts = { displayName = nameBox.Text }
				if isNew then
					local newId = (idBox.Text or ""):gsub("%s", "")
					if newId == "" then
						setStatus("ID required", Colors.Negative)
						return
					end
					local res, err = editorCall(reg.add, { id = newId, opts = opts })
					if res then
						store[newId] = { id = newId, displayName = opts.displayName }
						state.selected = newId
						setStatus("Created " .. newId, Colors.Positive)
						showDetail(newId)
					else
						setStatus("Create failed: " .. tostring(err), Colors.Negative)
					end
				else
					local res, err = editorCall(reg.update, { id = id, opts = opts })
					if res then
						rec.displayName = opts.displayName
						setStatus("Saved " .. tostring(id), Colors.Positive)
					else
						setStatus("Save failed: " .. tostring(err), Colors.Negative)
					end
				end
			end,
		})
		saveBtn.LayoutOrder = 98

		if not isNew then
			local delBtn = Button.create({
				parent = detail,
				variant = "danger",
				text = "Delete",
				width = 110,
				onClick = function()
					local res, err = editorCall(reg.remove, { id = id })
					if res then
						store[id] = nil
						state.selected = nil
						setStatus("Removed " .. tostring(id), Colors.Positive)
						showDetail(nil)
					else
						setStatus("Delete failed: " .. tostring(err), Colors.Negative)
					end
				end,
			})
			delBtn.LayoutOrder = 99
		end
	end

	listColumn({
		parent = columns,
		getKeys = function(q)
			return sortedMatching(store, q, function(id, r)
				return tostring(id) .. " " .. (r.displayName or "")
			end)
		end,
		labelFor = function(id)
			local r = store[id]
			return string.format("%s  \u{2014}  %s", tostring(id), (r and r.displayName) or "?")
		end,
		onSelect = function(id)
			state.selected = id
			showDetail(id)
		end,
	})

	showDetail(state.selected)
end

-- ─────────────────────────── Saves tab (named Save/Load map configs, Phase 6) ───────────────────────────
-- Save the full map+nations under a name, list them, load (replaces the live world in storage; applies on
-- restart/rejoin, with the current world auto-backed up), or delete. Backed by DataStore save:* keys.
local function renderSaves()
	local columns = frame({ parent = body, transparent = true })
	local detail = makeDetailPane(columns)

	-- Fetch the config index once per render (re-rendering after save/delete refreshes it).
	local configs = {}
	local res = editorCall("listConfigs")
	if type(res) == "table" and type(res.configs) == "table" then
		for _, cfg in ipairs(res.configs) do
			if cfg.name then configs[cfg.name] = cfg end
		end
	end

	local function showDetail(name)
		clearDetail(detail)

		-- Save the current world under a new name (always shown at top).
		local saveRow = frame({ parent = detail, transparent = true, size = UDim2.new(1, 0, 0, 30) })
		saveRow.LayoutOrder = -3
		local nameBox = textbox(saveRow, "new save name")
		nameBox.Size = UDim2.new(1, -136, 1, 0)
		local saveNewBtn = Button.create({
			parent = saveRow,
			variant = "primary",
			text = "Save current",
			width = 128,
			onClick = function()
				local nm = (nameBox.Text or ""):match("^%s*(.-)%s*$") or ""
				if nm == "" then
					setStatus("Enter a save name", Colors.Negative)
					return
				end
				setStatus("Saving config…", Colors.TextSecondary)
				local r, err = editorCall("saveConfig", { name = nm })
				if r then
					setStatus("Saved config '" .. nm .. "'", Colors.Positive)
					state.selected = nm
					render()
				else
					setStatus("Save failed: " .. tostring(err), Colors.Negative)
				end
			end,
		})
		saveNewBtn.Position = UDim2.new(1, -128, 0, 0)

		local hint = label(detail, "Named snapshots of the full map + nations, stored in the DataStore.", "bodySm", Colors.TextSecondary)
		hint.LayoutOrder = -2
		hint.Size = UDim2.new(1, 0, 0, 18)

		local meta = name and configs[name] or nil
		if not meta then
			label(detail, "Select a saved config on the left, or save the current world above.", "bodyMd", Colors.TextSecondary)
			return
		end

		label(detail, name, "displayLg").Size = UDim2.new(1, 0, 0, 26)
		readonlyRow(detail, "Saved", meta.savedAt or "?")
		readonlyRow(detail, "Countries", meta.countries)
		readonlyRow(detail, "Provinces", meta.provinces)

		-- Load: two-click confirm (replaces the live world in storage; applies on restart/rejoin).
		local armed = false
		local loadBtn
		loadBtn = Button.create({
			parent = detail,
			variant = "danger",
			text = "Load (replaces live map)",
			width = 220,
			onClick = function()
				if not armed then
					armed = true
					loadBtn.Text = "Click again to confirm load"
					setStatus("Load replaces the live map (current world is auto-backed up). Click again to confirm.", Colors.Negative)
					return
				end
				setStatus("Loading config '" .. name .. "'…", Colors.TextSecondary)
				local r, err = editorCall("loadConfig", { name = name })
				if r then
					local snap = editorCall("reloadState")
					if snap and type(snap) == "table" and snap.countries then
						applySnapshot(snap)
					else
						render()
					end
					setStatus((type(r) == "table" and r.message) or ("Loaded '" .. name .. "'"), Colors.Positive)
				else
					setStatus("Load failed: " .. tostring(err), Colors.Negative)
				end
			end,
		})
		loadBtn.LayoutOrder = 90

		local delBtn = Button.create({
			parent = detail,
			variant = "ghost",
			text = "Delete",
			width = 100,
			onClick = function()
				local r, err = editorCall("deleteConfig", { name = name })
				if r then
					setStatus("Deleted config '" .. name .. "'", Colors.Positive)
					state.selected = nil
					render()
				else
					setStatus("Delete failed: " .. tostring(err), Colors.Negative)
				end
			end,
		})
		delBtn.LayoutOrder = 91
	end

	listColumn({
		parent = columns,
		getKeys = function(q)
			q = string.lower(q or "")
			local out = {}
			for nm in pairs(configs) do
				if q == "" or string.find(string.lower(nm), q, 1, true) then
					out[#out + 1] = nm
				end
			end
			table.sort(out)
			return out
		end,
		labelFor = function(nm)
			local m = configs[nm]
			return (m and m.savedAt) and string.format("%s  (%s)", nm, m.savedAt) or nm
		end,
		onSelect = function(nm)
			state.selected = nm
			showDetail(nm)
		end,
	})

	showDetail(state.selected)
end

render = function()
	if formablesConn then
		formablesConn:Disconnect()
		formablesConn = nil
	end
	for _, child in body:GetChildren() do
		if child:IsA("GuiObject") then child:Destroy() end
	end
	if not state.snapshot then
		label(body, "Loading… (or not authorized)", "bodyMd", Colors.TextSecondary)
		return
	end
	if state.tab == "countries" then
		renderCountries()
	elseif state.tab == "provinces" then
		renderProvinces()
	elseif state.tab == "identity" then
		renderIdentity()
	elseif state.tab == "formables" then
		renderFormables()
	elseif state.tab == "saves" then
		renderSaves()
	end
end

applySnapshot = function(snap)
	state.snapshot = snap
	local cn, pn = 0, 0
	for _ in pairs(snap.countries or {}) do cn += 1 end
	for _ in pairs(snap.provinces or {}) do pn += 1 end
	setStatus(string.format("%d countries  •  %d provinces", cn, pn))
	render()
end

local function ensureLoaded()
	if state.loaded then return end
	local snap, err = editorCall("loadState")
	if not snap then
		setStatus("Load failed: " .. tostring(err), Colors.Negative)
		return
	end
	state.loaded = true
	applySnapshot(snap)
end

-- ─────────────────────────── map-click painting (Phase 6) ───────────────────────────
-- A single global select listener. It only acts while the editor is open, on the Provinces tab, with an
-- armed paint owner -- otherwise it no-ops so normal gameplay selection is untouched. Assigns via
-- updateProvince (owner+controller), which the server syncs live to the map.
do
	local modules = aow:FindFirstChild("Modules")
	local piMod = modules and modules:FindFirstChild("ProvinceInteraction")
	if piMod then
		local ok, PI = pcall(require, piMod)
		if ok and PI and PI.addSelectListener then
			PI.addSelectListener(function(part)
				if not gui.Enabled or state.tab ~= "provinces" or not state.paintOwner or not part then
					return
				end
				local parent = part.Parent
				if parent and parent.Name == "Sea" then
					setStatus("Sea tiles can't be assigned", Colors.Negative)
					return
				end
				local pid = part:GetAttribute("province_id")
				local snap = state.snapshot
				if not (pid and snap and snap.provinces and snap.provinces[pid]) then
					setStatus("That tile isn't a seeded province yet", Colors.TextSecondary)
					return
				end
				local owner = state.paintOwner
				local res, err = editorCall("updateProvince", { id = pid, opts = { ownerTag = owner, controllerTag = owner } })
				if res then
					local p = snap.provinces[pid]
					p.ownerTag = owner
					p.controllerTag = owner
					setStatus(string.format("Painted #%s → %s", tostring(pid), owner), Colors.Positive)
				else
					setStatus("Paint failed: " .. tostring(err), Colors.Negative)
				end
			end)
		end
	end
end

selectTab("countries")

UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode == Enum.KeyCode.BackSlash then
		gui.Enabled = not gui.Enabled
		if gui.Enabled then
			ensureLoaded()
			render()
		end
	end
end)
