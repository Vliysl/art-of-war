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

local state = { snapshot = nil, tab = "countries", selected = nil, loaded = false, dirty = false }
local formablesConn -- live-refresh subscription for the Formables tab (disconnected on tab change)

-- Dirty tracking + a lowercased search cache. The dirty flag flips whenever an in-memory edit succeeds
-- (edits live only in the snapshot until "Save to DataStore"); the header shows an "Unsaved changes" marker
-- and Close/Reload confirm before discarding. markDirty()/clearDirty() are wired to the footer marker below.
local setDirty -- fwd (defined once the header marker exists)
local function markDirty()
	state.dirty = true
	if setDirty then setDirty() end
end
local function clearDirty()
	state.dirty = false
	if setDirty then setDirty() end
end

-- Search cache: precompute one lowercased "id + display name" string per country/province ONCE when a
-- snapshot loads, so the per-keystroke filter is a plain table lookup instead of re-lowercasing all ~5713
-- entries every time. Keyed by the dict's own keys (tag / province id). Rebuilt on every applySnapshot.
local searchCache = { countries = {}, provinces = {} }
local function buildSearchCache(snap)
	local cc = {}
	for tag, c in pairs(snap.countries or {}) do
		cc[tag] = string.lower(tostring(tag) .. " " .. (c.displayName or ""))
	end
	local pc = {}
	for id, p in pairs(snap.provinces or {}) do
		pc[id] = string.lower(tostring(id) .. " " .. (p.name or ""))
	end
	searchCache = { countries = cc, provinces = pc }
end

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

-- Unsaved-changes marker (hidden until an edit flips the dirty flag; sits just left of the Close button).
local dirtyMarker = label(header, "● Unsaved changes", "bodySm", Colors.Warning or Colors.Negative)
dirtyMarker.AnchorPoint = Vector2.new(1, 0.5)
dirtyMarker.Position = UDim2.new(1, -112, 0.5, 0)
dirtyMarker.Size = UDim2.fromOffset(150, 40)
dirtyMarker.TextXAlignment = Enum.TextXAlignment.Right
dirtyMarker.Visible = false
setDirty = function()
	dirtyMarker.Visible = state.dirty
end

-- Close: confirms (two-click) when there are unsaved changes so an in-memory edit isn't discarded silently.
local closeArmed = false
local closeBtn
closeBtn = Button.create({
	parent = header,
	variant = "ghost",
	text = "Close (\\)",
	width = 92,
	onClick = function()
		if state.dirty and not closeArmed then
			closeArmed = true
			closeBtn.Text = "Discard?"
			setStatus("Unsaved changes — click again to close without saving", Colors.Negative)
			return
		end
		closeArmed = false
		closeBtn.Text = "Close (\\)"
		gui.Enabled = false
	end,
})
closeBtn.AnchorPoint = Vector2.new(1, 0.5)
closeBtn.Position = UDim2.new(1, -10, 0.5, 0)

-- ─────────────────────────── draggable window (drag the header like a title bar) ───────────────────────────
-- Translate root.Position by the pointer delta. Drags that begin on a button (Close, tabs live under the
-- header row, not on it) are ignored so clicks still register. Works for mouse (MouseButton1) and touch.
do
	local dragging = false
	local dragStart, startPos
	local function beginDrag(input)
		-- Ignore drags that start over the Close button so its click still works.
		if closeBtn and closeBtn.Visible then
			local bp, bs = closeBtn.AbsolutePosition, closeBtn.AbsoluteSize
			local px, py = input.Position.X, input.Position.Y
			if px >= bp.X and px <= bp.X + bs.X and py >= bp.Y and py <= bp.Y + bs.Y then
				return
			end
		end
		dragging = true
		dragStart = input.Position
		startPos = root.Position
	end
	header.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			beginDrag(input)
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			local delta = input.Position - dragStart
			root.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y
			)
		end
	end)
end

-- tab row
local TABS = {
	{ key = "countries", label = "Countries" },
	{ key = "provinces", label = "Provinces" },
	{ key = "identity", label = "Identity" },
	{ key = "formables", label = "Formables" },
	{ key = "saves", label = "Saves" },
	{ key = "access", label = "Access" },
}
local tabRow = frame({ parent = root, transparent = true, size = UDim2.new(1, 0, 0, 34), position = UDim2.fromOffset(0, 40) })
local tabButtons = {}

-- body (leaves room for the global action footer at the bottom)
local body = frame({ parent = root, transparent = true, size = UDim2.new(1, -20, 1, -124), position = UDim2.fromOffset(10, 78) })
body.Name = "Body"

local render -- fwd
local applySnapshot -- fwd (set snapshot + status + re-render; used by loadState / reload / undo / redo)
local paintInteraction -- ProvinceInteraction ref (map-click select/paint + bulk assign), set at module scope below
local bulkApplyBtn, bulkCountLabel -- Provinces-tab bulk-assign controls, kept live by the multi-select listener

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
-- Undo/Redo depth labels: the undo/redo command responses carry historyDepth/redoDepth so the buttons can
-- read "Undo (3)". applyDepths() (defined once both buttons exist) is called from applySnapshot too.
local applyDepths
local undoBtn, redoBtn
-- Reload: confirms (two-click) when there are unsaved in-memory changes so they aren't discarded silently.
local reloadArmed = false
local reloadBtn
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
				clearDirty()
				closeArmed = false
				closeBtn.Text = "Close (\\)"
				reloadArmed = false
				if reloadBtn then reloadBtn.Text = "Reload" end
				setStatus((type(res) == "table" and res.message) or "Saved", Colors.Positive)
			else
				setStatus("Save failed: " .. tostring(err), Colors.Negative)
			end
		end,
	})
	saveBtn.Position = UDim2.fromOffset(x, 0)
	x += 164

	reloadBtn = Button.create({
		parent = footer,
		variant = "ghost",
		text = "Reload",
		width = 90,
		onClick = function()
			if state.dirty and not reloadArmed then
				reloadArmed = true
				reloadBtn.Text = "Discard & reload?"
				setStatus("Unsaved changes — click Reload again to discard them", Colors.Negative)
				return
			end
			reloadArmed = false
			reloadBtn.Text = "Reload"
			local snap, err = editorCall("reloadState")
			if snap and type(snap) == "table" and snap.countries then
				state.selected = nil
				clearDirty()
				applySnapshot(snap)
				setStatus("Reloaded from server", Colors.Positive)
			else
				setStatus("Reload failed: " .. tostring(err), Colors.Negative)
			end
		end,
	})
	reloadBtn.Position = UDim2.fromOffset(x, 0)
	x += 98

	undoBtn = Button.create({
		parent = footer,
		variant = "ghost",
		text = "Undo",
		width = 90,
		onClick = function()
			local snap, err = editorCall("undo")
			if snap and type(snap) == "table" and snap.countries then
				markDirty()
				applySnapshot(snap)
				setStatus("Undo: " .. tostring(snap.undoLabel or "✓"), Colors.Positive)
			else
				setStatus("Nothing to undo" .. (err and (" (" .. err .. ")") or ""), Colors.TextSecondary)
			end
		end,
	})
	undoBtn.Position = UDim2.fromOffset(x, 0)
	x += 98

	redoBtn = Button.create({
		parent = footer,
		variant = "ghost",
		text = "Redo",
		width = 90,
		onClick = function()
			local snap, err = editorCall("redo")
			if snap and type(snap) == "table" and snap.countries then
				markDirty()
				applySnapshot(snap)
				setStatus("Redo: " .. tostring(snap.redoLabel or "✓"), Colors.Positive)
			else
				setStatus("Nothing to redo" .. (err and (" (" .. err .. ")") or ""), Colors.TextSecondary)
			end
		end,
	})
	redoBtn.Position = UDim2.fromOffset(x, 0)
	x += 98

	-- Reflect the history depths (and last labels) on the buttons; safe to call with a nil snapshot.
	applyDepths = function(snap)
		local ud = snap and snap.historyDepth
		local rd = snap and snap.redoDepth
		local ul = snap and snap.undoLabel
		local rl = snap and snap.redoLabel
		local ubtn = undoBtn:FindFirstChildWhichIsA("TextLabel")
		local rbtn = redoBtn:FindFirstChildWhichIsA("TextLabel")
		if ubtn then
			ubtn.Text = ud and (ul and string.format("Undo %s (%d)", tostring(ul), ud) or ("Undo (" .. ud .. ")")) or "Undo"
		end
		if rbtn then
			rbtn.Text = rd and (rl and string.format("Redo %s (%d)", tostring(rl), rd) or ("Redo (" .. rd .. ")")) or "Redo"
		end
	end
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
	-- Debounce (~0.15s): a fast typist otherwise re-filters the whole dict on every character. Each keystroke
	-- bumps a token; only the last scheduled pass (whose token still matches) actually rebuilds.
	local debounceToken = 0
	search:GetPropertyChangedSignal("Text"):Connect(function()
		debounceToken += 1
		local myToken = debounceToken
		task.delay(0.15, function()
			if myToken == debounceToken and search.Parent then
				rebuild()
			end
		end)
	end)
	rebuild()
	return col, rebuild
end

-- ─────────────────────────── Countries tab ───────────────────────────
-- Filter + sort a dict's keys by a query. Pass `cache` (id -> precomputed lowercased search string) to skip
-- re-lowercasing every entry per keystroke; otherwise falls back to keyToText (used by the smaller dicts).
local function sortedMatching(dict, query, keyToText, cache, filterFn, sortFn)
	query = string.lower(query or "")
	local out = {}
	for k, v in pairs(dict or {}) do
		if filterFn == nil or filterFn(k, v) then
			local text = cache and cache[k] or string.lower(keyToText(k, v))
			if query == "" or string.find(text, query, 1, true) then
				out[#out + 1] = k
			end
		end
	end
	table.sort(out, sortFn or function(a, b) return tostring(a) < tostring(b) end)
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

-- Faceted culture/religion filter for Countries (combined with the text search). state.countryCultureFilter
-- / state.countryReligionFilter hold the sentinel or a chosen key; countryFilter() -> filterFn or nil.
local ALL_FILTER = "\u{2014} all \u{2014}"
local countryFilter -- fwd (returns a per-render filterFn built from the two dropdowns' state)

local function renderCountries()
	local snap = state.snapshot
	local listCol -- fwd (culture/religion dropdowns re-filter this column's list)

	countryFilter = function()
		local cul = state.countryCultureFilter
		local rel = state.countryReligionFilter
		local hasCul = cul and cul ~= ALL_FILTER
		local hasRel = rel and rel ~= ALL_FILTER
		if not hasCul and not hasRel then return nil end
		return function(_, c)
			if hasCul and c.primaryCulture ~= cul then return false end
			if hasRel and c.stateReligion ~= rel then return false end
			return true
		end
	end

	-- Filter row: culture + religion dropdowns above the list/detail columns.
	local filterRow = frame({ parent = body, transparent = true, size = UDim2.fromOffset(300, 28) })
	label(filterRow, "Culture:", "bodySm", Colors.TextSecondary).Size = UDim2.new(0, 54, 1, 0)
	do
		local culOptions = { ALL_FILTER }
		for _, k in ipairs(sortedKeys(snap.cultures)) do culOptions[#culOptions + 1] = k end
		dropdown({
			parent = filterRow,
			size = UDim2.fromOffset(190, 28),
			position = UDim2.fromOffset(54, 0),
			options = culOptions,
			value = state.countryCultureFilter or ALL_FILTER,
			onChange = function(sel)
				state.countryCultureFilter = sel
				if listCol then listCol() end
			end,
		})
	end
	local filterRow2 = frame({ parent = body, transparent = true, size = UDim2.fromOffset(300, 28), position = UDim2.fromOffset(0, 30) })
	label(filterRow2, "Religion:", "bodySm", Colors.TextSecondary).Size = UDim2.new(0, 54, 1, 0)
	do
		local relOptions = { ALL_FILTER }
		for _, k in ipairs(sortedKeys(snap.religions)) do relOptions[#relOptions + 1] = k end
		dropdown({
			parent = filterRow2,
			size = UDim2.fromOffset(190, 28),
			position = UDim2.fromOffset(54, 0),
			options = relOptions,
			value = state.countryReligionFilter or ALL_FILTER,
			onChange = function(sel)
				state.countryReligionFilter = sel
				if listCol then listCol() end
			end,
		})
	end

	local columns = frame({ parent = body, transparent = true, size = UDim2.new(1, 0, 1, -62), position = UDim2.fromOffset(0, 62) })
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

		-- Inline validation error text (hidden until a validate() failure), shown just above the Save button.
		local errLabel = label(detail, "", "bodySm", Colors.Negative)
		errLabel.LayoutOrder = 98
		errLabel.TextWrapped = true
		errLabel.Size = UDim2.new(1, 0, 0, 20)
		errLabel.Visible = false
		local function showError(msg)
			errLabel.Text = msg
			errLabel.Visible = true
			setStatus(msg, Colors.Negative)
		end

		-- Validate the form: tag length >=2 (create only), RGB channels present & 0-255, and (create only) the
		-- capital province id must exist in the snapshot. Returns newColor on success, or nil + shows the error.
		local function validate()
			local rgb = {}
			for i = 1, 3 do
				local n = tonumber(boxes[i].Text)
				if not n or n < 0 or n > 255 or n ~= math.floor(n) then
					showError("Colour channels must be whole numbers 0-255")
					return nil
				end
				rgb[i] = n
			end
			if isNew then
				local newTag = (tagBox.Text or ""):gsub("%s", "")
				if #newTag < 2 then
					showError("Tag needs 2+ characters")
					return nil
				end
				local capText = (capBox.Text or ""):gsub("%s", "")
				local capId = tonumber(capText)
				if capText ~= "" and (not capId or not snap.provinces[capId]) then
					showError("Capital prov ID must be an existing province")
					return nil
				end
			end
			errLabel.Visible = false
			return rgb
		end

		local saveBtn = Button.create({
			parent = detail,
			variant = "primary",
			text = isNew and "Create" or "Save",
			width = 120,
			onClick = function()
				local newColor = validate()
				if not newColor then return end
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
					opts.capitalProvinceId = tonumber(capBox.Text)
					local res, err = editorCall("addCountry", { tag = newTag, opts = opts })
					if res then
						opts.tag = newTag
						snap.countries[newTag] = opts
						searchCache.countries[newTag] = string.lower(newTag .. " " .. (opts.displayName or ""))
						state.selected = newTag
						markDirty()
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
						searchCache.countries[tag] = string.lower(tostring(tag) .. " " .. (opts.displayName or ""))
						markDirty()
						setStatus("Saved " .. tostring(tag), Colors.Positive)
					else
						setStatus("Save failed: " .. tostring(err), Colors.Negative)
					end
				end
			end,
		})
		saveBtn.LayoutOrder = 99
	end

	local _, rebuildList = listColumn({
		parent = columns,
		getKeys = function(q)
			return sortedMatching(snap.countries, q, function(tag, c)
				return tostring(tag) .. " " .. (c.displayName or "")
			end, searchCache.countries, countryFilter and countryFilter())
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
	listCol = rebuildList

	showDetail(state.selected)
end

-- ─────────────────────────── Provinces tab (virtualized; owner + cores/claims editor + map painting) ───────────────────────────
-- Faceted owner-filter sentinels (combined with the text search): "All" = no filter, "— none —" = unowned.
local ALL_OWNERS = "\u{2014} all \u{2014}"
local NO_OWNER = "\u{2014} none (unowned) \u{2014}"

local function renderProvinces()
	local snap = state.snapshot
	local listCol -- fwd (owner filter dropdown re-filters this column's list)

	-- Paint control row: pick an owner, then click land tiles on the map to assign it (Phase 6 painting).
	-- The click hook lives at module scope (below) and reads state.paintOwner.
	local paintRow = frame({ parent = body, transparent = true, size = UDim2.new(1, 0, 0, 30) })
	label(paintRow, "Paint owner:", "bodySm", Colors.TextSecondary).Size = UDim2.new(0, 90, 1, 0)
	local paintHint = label(
		paintRow,
		state.paintOwner and ("Painting → " .. state.paintOwner) or "",
		"bodySm",
		state.paintOwner and Colors.Positive or Colors.TextSecondary
	)
	paintHint.TextTruncate = Enum.TextTruncate.AtEnd -- never let a long status overflow the window edge
	paintHint.Position = UDim2.fromOffset(600, 0)
	paintHint.Size = UDim2.new(1, -600, 1, 0)
	dropdown({
		parent = paintRow,
		size = UDim2.fromOffset(150, 26),
		position = UDim2.fromOffset(96, 2),
		options = sortedKeys(snap.countries),
		value = state.paintOwner or "— pick —",
		onChange = function(tag)
			state.paintOwner = tag
			paintHint.Text = "Painting → " .. tag
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
			paintHint.Text = ""
			paintHint.TextColor3 = Colors.TextSecondary
		end,
	})
	stopBtn.Position = UDim2.fromOffset(256, 2)

	-- Bulk assign: shift-select tiles on the map, then assign them all to the paint owner at once
	-- (assignBatch). bulkApplyBtn/bulkCountLabel are module refs the multi-select listener keeps live.
	bulkApplyBtn = Button.create({
		parent = paintRow,
		variant = "primary",
		text = "Assign selected",
		width = 140,
		onClick = function()
			local owner = state.paintOwner
			if not owner then
				setStatus("Pick a paint owner first", Colors.Negative)
				return
			end
			if not (paintInteraction and paintInteraction.getMultiSelection) then
				return
			end
			local items = {}
			for _, part in ipairs(paintInteraction.getMultiSelection()) do
				local pid = part:GetAttribute("province_id")
				local isSea = part.Parent and part.Parent.Name == "Sea"
				if pid and not isSea and snap.provinces[pid] then
					items[#items + 1] = { kind = "seed", id = pid }
				end
			end
			if #items == 0 then
				setStatus("No seeded land tiles selected (shift-click tiles on the map)", Colors.Negative)
				return
			end
			if #items > 500 then
				setStatus(string.format("Too many (%d); max 500 — select fewer", #items), Colors.Negative)
				return
			end
			local res, err = editorCall("assignBatch", { ownerTag = owner, items = items })
			if res then
				for _, it in ipairs(items) do
					local p = snap.provinces[it.id]
					if p then
						p.ownerTag = owner
						p.controllerTag = owner
					end
				end
				setStatus(string.format("Assigned %d tiles → %s", #items, owner), Colors.Positive)
				markDirty()
				if paintInteraction.clearMultiSelection then
					paintInteraction.clearMultiSelection()
				end
				state.multiSelCount = 0
				if bulkCountLabel then bulkCountLabel.Text = "" end
				bulkApplyBtn.Visible = false
			else
				setStatus("Bulk assign failed: " .. tostring(err), Colors.Negative)
			end
		end,
	})
	bulkApplyBtn.Position = UDim2.fromOffset(364, 2)
	bulkApplyBtn.Visible = (state.multiSelCount or 0) > 0

	bulkCountLabel = label(
		paintRow,
		(state.multiSelCount or 0) > 0 and (state.multiSelCount .. " selected") or "",
		"bodySm",
		Colors.Accent
	)
	bulkCountLabel.Position = UDim2.fromOffset(512, 0)
	bulkCountLabel.Size = UDim2.new(0, 84, 1, 0)

	-- Faceted owner filter (combined with the list's text search). Options: All / none(unowned) / each country.
	local filterRow = frame({ parent = body, transparent = true, size = UDim2.fromOffset(300, 28), position = UDim2.fromOffset(0, 36) })
	label(filterRow, "Owner:", "bodySm", Colors.TextSecondary).Size = UDim2.new(0, 48, 1, 0)
	do
		local ownerOptions = { ALL_OWNERS, NO_OWNER }
		for _, t in ipairs(sortedKeys(snap.countries)) do ownerOptions[#ownerOptions + 1] = t end
		dropdown({
			parent = filterRow,
			size = UDim2.new(1, -52, 1, 0),
			position = UDim2.fromOffset(52, 0),
			options = ownerOptions,
			value = state.provOwnerFilter or ALL_OWNERS,
			onChange = function(sel)
				state.provOwnerFilter = sel
				if listCol then listCol() end -- re-run the list's getKeys with the new filter
			end,
		})
	end

	-- Sort toggle: Numeric (by #id, so #1..#2..#10 not #1..#10..#100) or Alphabetical (by name).
	local sortLbl = label(body, "Sort:", "bodySm", Colors.TextSecondary)
	sortLbl.Position = UDim2.fromOffset(316, 36)
	sortLbl.Size = UDim2.fromOffset(38, 28)
	dropdown({
		parent = body,
		size = UDim2.fromOffset(150, 26),
		position = UDim2.fromOffset(356, 37),
		options = { "Numeric", "Alphabetical" },
		value = ((state.provSort or "numeric") == "alpha") and "Alphabetical" or "Numeric",
		onChange = function(sel)
			state.provSort = (sel == "Alphabetical") and "alpha" or "numeric"
			if listCol then listCol() end
		end,
	})

	local columns = frame({ parent = body, transparent = true, size = UDim2.new(1, 0, 1, -68), position = UDim2.fromOffset(0, 68) })
	local detail = makeDetailPane(columns)

	local function showDetail(id)
		clearDetail(detail)
		local p = id and snap.provinces[id]
		if not p then
			local ph = label(detail, "Select a province from the list — or click a tile on the map (shift-click to multi-select).", "bodyMd", Colors.TextSecondary)
			ph.TextWrapped = true
			ph.Size = UDim2.new(1, 0, 0, 48)
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

		-- Cores / default cores / claims -- edited as chip lists (single source of truth: the province).
		-- Default cores = homeland cores shown GOLD-outlined in the province panel; other cores show plain.
		label(detail, "Cores", "bodySm", Colors.TextSecondary).Size = UDim2.new(1, 0, 0, 18)
		local coresEd = tagListEditor(detail, p.cores, countryTags)
		label(detail, "Default cores (gold)", "bodySm", Colors.TextSecondary).Size = UDim2.new(1, 0, 0, 18)
		local defaultCoresEd = tagListEditor(detail, p.defaultCores, countryTags)
		label(detail, "Claims", "bodySm", Colors.TextSecondary).Size = UDim2.new(1, 0, 0, 18)
		local claimsEd = tagListEditor(detail, p.claims, countryTags)

		local saveBtn = Button.create({
			parent = detail,
			variant = "primary",
			text = "Save",
			width = 120,
			onClick = function()
				local opts = { cores = coresEd.get(), defaultCores = defaultCoresEd.get(), claims = claimsEd.get() }
				local newOwner = ownerDD.get()
				if newOwner and newOwner ~= p.ownerTag then
					opts.ownerTag = newOwner
					opts.controllerTag = newOwner
				end
				local res, err = editorCall("updateProvince", { id = id, opts = opts })
				if res then
					p.cores = opts.cores
					p.defaultCores = opts.defaultCores
					p.claims = opts.claims
					if opts.ownerTag then
						p.ownerTag = opts.ownerTag
						p.controllerTag = opts.controllerTag
					end
					markDirty()
					setStatus("Saved province #" .. tostring(id), Colors.Positive)
				else
					setStatus("Save failed: " .. tostring(err), Colors.Negative)
				end
			end,
		})
		saveBtn.LayoutOrder = 99
	end

	local _, rebuildList = listColumn({
		parent = columns,
		getKeys = function(q)
			local ownerSel = state.provOwnerFilter
			local filterFn = nil
			if ownerSel and ownerSel ~= ALL_OWNERS then
				local want = (ownerSel == NO_OWNER) and nil or ownerSel
				filterFn = function(_, p) return (p.ownerTag or nil) == want end
			end
			local sortFn
			if (state.provSort or "numeric") == "alpha" then
				sortFn = function(a, b)
					return ((snap.provinces[a] and snap.provinces[a].name) or "") < ((snap.provinces[b] and snap.provinces[b].name) or "")
				end
			else
				sortFn = function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end
			end
			return sortedMatching(snap.provinces, q, function(id, p)
				return tostring(id) .. " " .. (p.name or "")
			end, searchCache.provinces, filterFn, sortFn)
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
	listCol = rebuildList

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
		-- A tall, wrapping text field for long values (e.g. a big province-id list) so the text WRAPS inside
		-- the box instead of overflowing the window; it scrolls to the cursor while editing.
		local function bigField(name, value, h)
			h = h or 92
			local r = frame({ parent = detail, transparent = true, size = UDim2.new(1, 0, 0, h) })
			label(r, name, "bodySm", Colors.TextSecondary).Size = UDim2.fromOffset(120, 26)
			local tb = textbox(r, "")
			tb.Size = UDim2.new(1, -126, 1, 0)
			tb.Position = UDim2.fromOffset(126, 0)
			tb.Text = value or ""
			tb.MultiLine = true
			tb.TextWrapped = true
			tb.ClipsDescendants = true
			tb.TextXAlignment = Enum.TextXAlignment.Left
			tb.TextYAlignment = Enum.TextYAlignment.Top
			return tb
		end
		local function ddYesNo(name, isYes)
			local r = frame({ parent = detail, transparent = true, size = UDim2.new(1, 0, 0, 26) })
			label(r, name, "bodySm", Colors.TextSecondary).Size = UDim2.new(0, 120, 1, 0)
			return dropdown({ parent = r, size = UDim2.new(0, 90, 1, 0), position = UDim2.fromOffset(126, 0), options = YESNO, value = isYes and "Yes" or "No" })
		end

		-- The forming nation KEEPS its own tag (HoI4-style); a formable is just an identity (name/colour/
		-- flag) it ADOPTS on formation — so there's no "formable tag" to enter. The internal id is derived
		-- from the name on create (kept as-is when editing). "Formed by (tags)" is the comma-separated
		-- whitelist of countries that may form it (e.g. POR, SPA for Iberia); empty = any holder.
		local nameBox = field("Display name", def and def.displayName or "")
		local formerBox = field("Formed by (tags)", def and def.formerTags and table.concat(def.formerTags, ", ") or "")
		local col3 = (def and def.color) or { 150, 150, 150 }
		local reqBox = bigField("Required province IDs", def and def.requiredProvinceIds and table.concat(def.requiredProvinceIds, ", ") or "", 60)
		-- Map-select flow: shift-select tiles on the map, then add them here instead of typing ids.
		do
			local reqTools = frame({ parent = detail, transparent = true, size = UDim2.new(1, 0, 0, 28) })
			local addSel = Button.create({
				parent = reqTools,
				variant = "primary",
				text = "Add map selection",
				width = 170,
				size = "sm",
				onClick = function()
					if not (paintInteraction and paintInteraction.getMultiSelection) then
						setStatus("Map selection unavailable", Colors.Negative)
						return
					end
					local set = {}
					for s in string.gmatch(reqBox.Text or "", "%d+") do set[tonumber(s)] = true end
					local added = 0
					for _, part in ipairs(paintInteraction.getMultiSelection()) do
						local pid = part:GetAttribute("province_id")
						local isSea = part.Parent and part.Parent.Name == "Sea"
						if pid and not isSea and not set[pid] then
							set[pid] = true
							added += 1
						end
					end
					local ids = {}
					for id in pairs(set) do ids[#ids + 1] = id end
					table.sort(ids, function(a, b) return a < b end)
					reqBox.Text = table.concat(ids, ", ")
					setStatus(string.format("Added %d tiles (%d total)", added, #ids), added > 0 and Colors.Positive or Colors.TextSecondary)
				end,
			})
			addSel.Position = UDim2.fromOffset(126, 0)
			local clearBtn = Button.create({
				parent = reqTools,
				variant = "ghost",
				text = "Clear",
				width = 76,
				size = "sm",
				onClick = function()
					reqBox.Text = ""
					setStatus("Cleared required provinces", Colors.TextSecondary)
				end,
			})
			clearBtn.Position = UDim2.fromOffset(304, 0)
			local hint = label(reqTools, "shift-select map tiles \u{2192} Add", "bodySm", Colors.TextSecondary)
			hint.Position = UDim2.fromOffset(390, 0)
			hint.Size = UDim2.new(1, -390, 1, 0)
			hint.TextTruncate = Enum.TextTruncate.AtEnd
		end
		local colorBox = field("Colour (r,g,b)", string.format("%d, %d, %d", col3[1] or 0, col3[2] or 0, col3[3] or 0))
		local flagBox = field("Flag (rbxassetid)", (def and def.flag) or "")
		local bonusBox = field("Form bonus: stability", def and def.formBonuses and tostring(def.formBonuses.stability or "") or "")
		local canFormDD = ddYesNo("Can form", def == nil or def.canForm ~= false)
		local canReleaseDD = ddYesNo("Can release", def == nil or def.canRelease ~= false)
		-- Secret: hide from the Missions tab until a nation already holds the full territory (otherwise
		-- eligible formers see it as a goal with progress). Default No (visible as a goal).
		local secretDD = ddYesNo("Secret formable", def ~= nil and def.secret == true)

		local saveBtn = Button.create({
			parent = detail,
			variant = "primary",
			text = "Save",
			width = 120,
			onClick = function()
				local displayName = (nameBox.Text or ""):match("^%s*(.-)%s*$") or ""
				if displayName == "" then
					setStatus("A display name is required", Colors.Negative)
					return
				end
				-- Keep the existing id when editing; otherwise derive a tag-like id from the name
				-- (the forming nation keeps its own tag — this id is only the definition key).
				local newTag = (tag ~= nil and tag ~= "") and tag
					or (displayName:upper():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
				if newTag == "" then
					setStatus("Could not derive an id from the name", Colors.Negative)
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
				-- Parse the comma/space-separated former tags (uppercased), e.g. "POR, SPA" -> {"POR","SPA"}.
				local formers = {}
				for s in string.gmatch((formerBox.Text or ""):upper(), "[%w_]+") do
					formers[#formers + 1] = s
				end
				local newDef = {
					displayName = displayName,
					color = { rgb[1] or 150, rgb[2] or 150, rgb[3] or 150 },
					requiredProvinceIds = ids,
					formerTags = (#formers > 0) and formers or nil,
					canForm = canFormDD.get() == "Yes",
					canRelease = canReleaseDD.get() == "Yes",
					secret = (secretDD.get() == "Yes") or nil,
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
				markDirty()
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
					markDirty()
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
						markDirty()
						setStatus("Created " .. newId, Colors.Positive)
						showDetail(newId)
					else
						setStatus("Create failed: " .. tostring(err), Colors.Negative)
					end
				else
					local res, err = editorCall(reg.update, { id = id, opts = opts })
					if res then
						rec.displayName = opts.displayName
						markDirty()
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
						markDirty()
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

-- ─────────────────────────── Access tab (config-driven, Configs & Experiments) ───────────────────────────
-- Access is set in the Creator Hub config "data_editor_access" (a JSON object { managers, historians }) and
-- changes go live WITHOUT a place republish. This tab explains that model and lists online players + their
-- tier. The legacy in-game session Grant/Revoke buttons only appear when the RoN owner suite is enabled.
local function renderAccess()
	local res = editorCall("listAccess")
	local canManage = type(res) == "table" and res.canManage == true
	local players = (type(res) == "table" and res.players) or {}
	local access = (type(res) == "table" and res.access) or {}
	local suiteOn = access.ownerSuiteEnabled == true

	local configState = access.configAvailable == false and "unavailable on this build"
		or (access.configLoaded and "loaded" or "pending…")
	local note = label(
		body,
		string.format(
			'Access is set in the Creator Hub config "%s" (Configs & Experiments) — no republish needed.\n'
				.. 'Edit its JSON  { "managers": [...], "historians": [...] }  and Publish; live in ~5 min.\n'
				.. "historians = mappers (edit map + formables + save).  managers = full access incl. admin actions.\n"
				.. "Config: %s   |   managers: %d   |   historians: %d",
			access.configKey or "data_editor_access",
			configState,
			#(access.managers or {}),
			#(access.historians or {})
		),
		"bodySm",
		Colors.TextSecondary
	)
	note.Position = UDim2.fromOffset(4, 2)
	note.Size = UDim2.new(1, -8, 0, 76)
	note.TextWrapped = true
	note.TextYAlignment = Enum.TextYAlignment.Top

	local headerH = 84
	local scroll = Instance.new("ScrollingFrame")
	scroll.BackgroundColor3 = Colors.SurfaceBase
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.Position = UDim2.fromOffset(0, headerH)
	scroll.Size = UDim2.new(1, 0, 1, -headerH)
	scroll.CanvasSize = UDim2.fromOffset(0, #players * 38 + 16) -- rows are 34px + 4px layout padding
	scroll.Parent = body
	do
		local s = Instance.new("UIStroke")
		s.Color = Colors.BorderSubtle
		s.Thickness = 1
		s.Parent = scroll
	end
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = scroll

	if #players == 0 then
		label(scroll, "No players online.", "bodySm", Colors.TextSecondary).Size = UDim2.new(1, 0, 0, 24)
		return
	end

	for i, p in ipairs(players) do
		local row = frame({ parent = scroll, color = Colors.SurfaceElevated, size = UDim2.new(1, 0, 0, 34) })
		row.LayoutOrder = i
		local nameLbl = label(row, string.format("%s  (%d)", p.name or "?", p.userId), "bodyMd")
		nameLbl.Position = UDim2.fromOffset(10, 0)
		nameLbl.Size = UDim2.new(1, -260, 1, 0)

		local role = p.role or (p.manager and "manager" or (p.granted and "granted" or "none"))
		local statusText = ({
			manager = "Manager",
			historian = "Historian",
			granted = "Granted (session)",
			none = "No access",
		})[role] or "No access"
		local statusColor = (role == "manager" and Colors.Accent)
			or ((role == "historian" or role == "granted") and Colors.Positive)
			or Colors.TextSecondary
		local statusLbl = label(row, statusText, "bodySm", statusColor)
		statusLbl.Position = UDim2.new(1, -240, 0, 0)
		statusLbl.Size = UDim2.fromOffset(120, 34)
		statusLbl.TextXAlignment = Enum.TextXAlignment.Right

		-- Session Grant/Revoke is legacy and only takes effect while the RoN owner suite is on. When it's off,
		-- the config (managers/historians) is the only path — buttons are hidden to avoid a no-op.
		if suiteOn and canManage and (role == "none" or role == "granted") then
			local btn = Button.create({
				parent = row,
				variant = p.granted and "danger" or "primary",
				text = p.granted and "Revoke" or "Grant",
				width = 100,
				onClick = function()
					local cmd = p.granted and "revokeAccess" or "grantAccess"
					local r, err = editorCall(cmd, { userId = p.userId })
					if r then
						setStatus((p.granted and "Revoked " or "Granted ") .. (p.name or tostring(p.userId)), Colors.Positive)
						render()
					else
						setStatus("Failed: " .. tostring(err), Colors.Negative)
					end
				end,
			})
			btn.AnchorPoint = Vector2.new(1, 0.5)
			btn.Position = UDim2.new(1, -10, 0.5, 0)
		end
	end
end

render = function()
	if formablesConn then
		formablesConn:Disconnect()
		formablesConn = nil
	end
	-- Close any open dropdown popup: it (and its full-screen click-catcher) parent to the root gui, outside
	-- body, so the body-only clear below would leave a stale invisible click-blocker on a re-render.
	if openPopup then openPopup:Destroy() end -- its Destroying handler removes the catcher too
	openPopup = nil
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
	elseif state.tab == "access" then
		renderAccess()
	end
end

applySnapshot = function(snap)
	state.snapshot = snap
	buildSearchCache(snap)
	if applyDepths then applyDepths(snap) end
	local cn, pn = 0, 0
	for _ in pairs(snap.countries or {}) do cn += 1 end
	for _ in pairs(snap.provinces or {}) do pn += 1 end
	local extra = state.dirty and "  •  unsaved" or ""
	setStatus(string.format("%d countries  •  %d provinces%s", cn, pn, extra))
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
		if ok and PI then
			paintInteraction = PI
			if PI.addSelectListener then
				PI.addSelectListener(function(part)
					if not gui.Enabled or state.tab ~= "provinces" or not part then
						return
					end
					local snap = state.snapshot
					local pid = part:GetAttribute("province_id")
					local seeded = pid and snap and snap.provinces and snap.provinces[pid] ~= nil
					if state.paintOwner then
						-- PAINT: assign the armed owner to the clicked land tile.
						if part.Parent and part.Parent.Name == "Sea" then
							setStatus("Sea tiles can't be assigned", Colors.Negative)
							return
						end
						if not seeded then
							setStatus("That tile isn't a seeded province yet", Colors.TextSecondary)
							return
						end
						local owner = state.paintOwner
						-- assignProvince (paint cooldown 0.05s) sets owner+controller without the 2.5s write throttle.
						local res, err = editorCall("assignProvince", { id = pid, ownerTag = owner })
						if res then
							local p = snap.provinces[pid]
							p.ownerTag = owner
							p.controllerTag = owner
							markDirty()
							setStatus(string.format("Painted #%s → %s", tostring(pid), owner), Colors.Positive)
						else
							setStatus("Paint failed: " .. tostring(err), Colors.Negative)
						end
					elseif seeded then
						-- SELECT: jump the Provinces tab to the clicked province + open its detail.
						state.selected = pid
						render()
						setStatus("Selected #" .. tostring(pid), Colors.Accent)
					end
				end)
			end
			if PI.addMultiSelectListener then
				-- Keep the bulk-assign controls live as the map multi-selection (shift-click) changes.
				PI.addMultiSelectListener(function(selection)
					state.multiSelCount = selection and #selection or 0
					if bulkCountLabel and bulkCountLabel.Parent then
						bulkCountLabel.Text = state.multiSelCount > 0 and (state.multiSelCount .. " selected") or ""
					end
					if bulkApplyBtn and bulkApplyBtn.Parent then
						bulkApplyBtn.Visible = state.multiSelCount > 0
					end
				end)
			end
		end
	end
end

selectTab("countries")

UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode == Enum.KeyCode.BackSlash then
		-- Gate the window on server authorization: regular players get nothing (the editor never opens).
		-- Cache ONLY the positive result. Config-driven editors (Historians) are authorized asynchronously —
		-- their access config loads a few seconds after server boot — so a \ press during that window returns
		-- "not authorized"; caching that would lock them out for the whole session. Re-probe (throttled) while
		-- unauthorized and latch once authorized. The server also rejects every command (defence-in-depth).
		if not state.authorized then
			local now = tick()
			if not state.lastAuthProbe or (now - state.lastAuthProbe) >= 1.5 then
				state.lastAuthProbe = now
				state.authorized = editorCall("authCheck") ~= nil
			end
		end
		if not state.authorized then
			return
		end
		gui.Enabled = not gui.Enabled
		if gui.Enabled then
			ensureLoaded()
			render()
		end
	end
end)
