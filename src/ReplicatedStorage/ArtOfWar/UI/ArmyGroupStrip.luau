-- Bottom-center army-group card strip (HOI4 / "Conquer the World" style). One sharp card per owned
-- army group + a trailing "+" card. Tapping a card quick-selects the group's armies and opens a
-- floating command popover (Assign General / Cover Border / Rename / Disband / ...). This is a
-- persistent Hud-layer widget wired from HudWiring.start (see init(deps)) -- NOT an openContext screen.
-- Gated by WorldConstants.EnableGroupCards; when off, the old ArmyPanel group bar renders instead.
local UI = script.Parent
local ArtOfWar = UI.Parent
local DesignSystem = require(ArtOfWar.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Icons = DesignSystem.Icons
local Responsive = DesignSystem.Responsive
local Button = require(UI.Components.Button)
local Modal = require(UI.Components.Modal)
local ScreenKit = require(UI.Screens.ScreenKit)
local WorldConstants = require(ArtOfWar.Shared.WorldConstants)
local LeaderTraits = require(ArtOfWar.Data.LeaderTraits)

local ArmyGroupStrip = {}

local CARD_W = 104
local STRIP_H = 128
-- The strip's bottom edge sits above the country bar (bottom-left, top edge 104px up) so they never
-- overlap at any viewport width; cards flow centered and scroll horizontally only on overflow.
local COUNTRYBAR_BAND = 104
local STRIP_BOTTOM = 16 + COUNTRYBAR_BAND + 12
local PLUS_ORDER = 1000000

-- Module-scope singleton state (one strip per client, wired once from HudWiring).
local deps
local root, scroller, layout
local cardsById = {}
local plusCard
local selectedGroupId
local popover -- { handle, groupId }
local picker -- { handle }
local unsubs = {}
local reconcileQueued = false

local function titleCase(s)
	s = tostring(s or "")
	return (s:gsub("(%a)([%w]*)", function(a, b)
		return a:upper() .. b:lower()
	end):gsub("_", " "))
end

local function generalName(g)
	if type(g) ~= "table" then
		return "\u{2014}"
	end
	local nm = string.format("%s %s", g.firstName or "", g.lastName or "")
	nm = (nm:gsub("^%s+", ""):gsub("%s+$", ""))
	return nm ~= "" and nm or "\u{2014}"
end

local function generalTraitNames(g)
	local names = {}
	if type(g) == "table" and type(g.traits) == "table" then
		for _, tid in ipairs(g.traits) do
			local def = LeaderTraits[tid]
			names[#names + 1] = (def and def.displayName) or titleCase(tid)
		end
	end
	return names
end

local function regimentsTotal(army)
	local n = 0
	for _, c in pairs((army and army.composition) or {}) do
		n += c
	end
	return n
end

local function setButtonText(btn, text)
	local lbl = btn and btn:FindFirstChild("Label")
	if lbl then
		lbl.Text = text
	end
end

local function getTag()
	return deps and deps.getTag and deps.getTag() or nil
end

local function commanderOf(group)
	if not (WorldConstants.EnableGenerals and group and group.commanderId) then
		return nil
	end
	local country = deps.cache.getCountry(group.ownerTag)
	local roster = country and country.generalRoster
	return roster and roster[group.commanderId] or nil
end

-- Owned army groups sorted by name.
local function ownGroupsSorted()
	local tag = getTag()
	local out = {}
	if not tag then
		return out
	end
	for _, g in pairs(deps.cache.allArmyGroups() or {}) do
		if g.ownerTag == tag then
			out[#out + 1] = g
		end
	end
	table.sort(out, function(x, y)
		return tostring(x.name) < tostring(y.name)
	end)
	return out
end

-- The player's currently-selected armies that they own.
local function ownedSelection()
	local tag = getTag()
	local out = {}
	local ids = deps.armyView.getSelectedArmyIds and deps.armyView.getSelectedArmyIds() or nil
	for _, id in ipairs(ids or {}) do
		local a = deps.cache.getArmy(id)
		if a and a.ownerTag == tag then
			out[#out + 1] = id
		end
	end
	return out
end

-- The group id shared by the WHOLE selection, or nil if ungrouped / spanning groups (mirrors the old
-- ArmyPanel.currentGroupId) -- only a single-group selection highlights its card.
local function selectionGroupId()
	local ids = deps.armyView.getSelectedArmyIds and deps.armyView.getSelectedArmyIds() or nil
	if not ids or #ids == 0 then
		return nil
	end
	local gid
	for _, id in ipairs(ids) do
		local a = deps.cache.getArmy(id)
		local g = a and a.groupId
		if not g then
			return nil
		end
		if gid == nil then
			gid = g
		elseif g ~= gid then
			return nil
		end
	end
	return gid
end

local function closePicker()
	if picker and picker.handle then
		picker.handle.close()
	end
	picker = nil
end

local function closePopover()
	if popover and popover.handle then
		popover.handle.close()
	end
	popover = nil
end

-- A single-field name-entry modal (Form Group / Rename), centered. onConfirm gets the trimmed text.
local function openNameEntry(cfg)
	closePicker()
	local modal = Modal.create({
		parent = deps.parent,
		floating = true,
		anchorPoint = Vector2.new(0.5, 0.5),
		position = UDim2.fromScale(0.5, 0.5),
		name = "GroupNameEntry",
		title = cfg.title or "Name",
		subtitle = cfg.subtitle,
		width = 320,
		height = 160,
		footer = true,
		onClose = function()
			picker = nil
		end,
	})
	picker = { handle = modal }
	modal.panel:SetAttribute("AoWInputSink", true)
	local box = Instance.new("TextBox")
	box.Size = UDim2.new(1, 0, 0, 36)
	box.BackgroundColor3 = Colors.SurfaceSunken
	box.BorderSizePixel = 0
	box.Text = cfg.default or ""
	box.PlaceholderText = cfg.placeholder or "Enter a name"
	box.TextColor3 = Colors.TextPrimary
	box.PlaceholderColor3 = Colors.TextTertiary
	box.ClearTextOnFocus = false
	box.TextXAlignment = Enum.TextXAlignment.Left
	Typography.apply(box, "bodyMd")
	local bp = Instance.new("UIPadding")
	bp.PaddingLeft = UDim.new(0, 8)
	bp.PaddingRight = UDim.new(0, 8)
	bp.Parent = box
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(0, 6)
	bc.Parent = box
	box.Parent = modal.content
	local function confirm()
		local text = (box.Text or ""):gsub("^%s+", ""):gsub("%s+$", "")
		if text == "" then
			text = cfg.default or "Army Group"
		end
		cfg.onConfirm(text)
		modal.close()
	end
	box.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			confirm()
		end
	end)
	Button.create({
		parent = modal.footer,
		variant = "primary",
		text = cfg.confirmText or "Confirm",
		layoutOrder = 1,
		onClick = confirm,
	})
end

-- Pick an unassigned (or already-this-group) roster general to command `groupId`.
local function openGeneralPicker(groupId)
	if not groupId then
		return
	end
	closePicker()
	local country = deps.cache.getCountry(getTag())
	local roster = country and country.generalRoster
	local pool = {}
	if type(roster) == "table" then
		for _, g in pairs(roster) do
			if type(g) == "table" and (g.assignedGroupId == nil or g.assignedGroupId == groupId) then
				pool[#pool + 1] = g
			end
		end
	end
	table.sort(pool, function(a, b)
		return generalName(a) < generalName(b)
	end)

	local modal = Modal.create({
		parent = deps.parent,
		floating = true,
		anchorPoint = Vector2.new(0.5, 0.5),
		position = UDim2.fromScale(0.5, 0.5),
		name = "GroupGeneralPicker",
		title = "Assign General",
		subtitle = "Available generals",
		width = 360,
		height = 420,
		onClose = function()
			picker = nil
		end,
	})
	picker = { handle = modal }
	modal.panel:SetAttribute("AoWInputSink", true)
	local list = Instance.new("ScrollingFrame")
	list.Size = UDim2.fromScale(1, 1)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 4
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.Parent = modal.content
	local ll = Instance.new("UIListLayout")
	ll.SortOrder = Enum.SortOrder.LayoutOrder
	ll.Padding = UDim.new(0, 6)
	ll.Parent = list

	if #pool == 0 then
		ScreenKit.note(list, "No generals \u{2014} buy one from the Military screen.", 0)
	else
		for i, g in ipairs(pool) do
			local row = ScreenKit.stat(list, {
				icon = "Star",
				label = string.format("%s  \u{00B7}  Lvl %d", generalName(g), g.level or 0),
				layoutOrder = i * 2,
			})
			local assign = Button.create({
				parent = row,
				variant = "secondary",
				text = "Assign",
				width = 84,
				size = "sm",
				onClick = function()
					deps.fire("AssignGeneral", groupId, g.id)
					modal.close()
				end,
			})
			assign.AnchorPoint = Vector2.new(1, 0.5)
			assign.Position = UDim2.fromScale(1, 0.5)
			local names = generalTraitNames(g)
			if #names > 0 then
				ScreenKit.note(list, table.concat(names, "  \u{00B7}  "), i * 2 + 1)
			end
		end
	end
end

-- Quick-select: replace the map selection with this group's members (HudWiring coalesces the focus
-- calls into one ArmyPanel open), then surface the command popover.
local function quickSelect(groupId)
	local g = deps.cache.getArmyGroup(groupId)
	if not g then
		return
	end
	deps.armyView.deselect()
	for _, id in ipairs(g.memberArmyIds or {}) do
		if deps.cache.getArmy(id) then
			deps.armyView.focusArmy(id, true)
		end
	end
end

local function actionButton(parent, order, text, variant, onClick)
	local btn = Button.create({
		parent = parent,
		variant = variant,
		text = text,
		fill = true,
		size = Responsive.isTouch() and "md" or "sm",
		layoutOrder = order,
		onClick = onClick,
	})
	return btn
end

-- A single command popover, centered just above the strip, reflecting the tapped group. Re-tapping the
-- same card toggles it shut; tapping another card swaps it. Parented to the Hud layer (not the scroller)
-- so it escapes the strip's clipping.
local function openPopover(groupId)
	if popover and popover.groupId == groupId then
		closePopover()
		return
	end
	closePopover()
	closePicker()
	local g = deps.cache.getArmyGroup(groupId)
	if not g then
		return
	end

	local actions = {}
	if WorldConstants.EnableGenerals then
		actions[#actions + 1] = { text = "Assign General", variant = "secondary", run = function()
			closePopover()
			openGeneralPicker(groupId)
		end }
		if g.commanderId then
			actions[#actions + 1] = { text = "Unassign General", variant = "ghost", run = function()
				deps.fire("UnassignGeneral", groupId)
				closePopover()
			end }
		end
	end
	if WorldConstants.EnableBorderCover then
		actions[#actions + 1] = { text = "Cover Border", variant = "secondary", run = function()
			closePopover()
			deps.requestTarget({
				kind = "coverBorder",
				groupId = groupId,
				hint = "Click the nation to cover the border against.",
			})
		end }
		if g.borderCoverTargetTag then
			actions[#actions + 1] = { text = "Clear Cover", variant = "ghost", run = function()
				deps.fire("ClearBorderCover", groupId)
				closePopover()
			end }
		end
	end
	actions[#actions + 1] = { text = "Rename", variant = "secondary", run = function()
		local current = g.name or "Army Group"
		closePopover()
		openNameEntry({
			title = "Rename Group",
			subtitle = current,
			default = current,
			confirmText = "Rename",
			onConfirm = function(name)
				deps.fire("RenameArmyGroup", groupId, name)
			end,
		})
	end }
	actions[#actions + 1] = { text = "Disband", variant = "danger", disband = true }

	local btnH = Responsive.isTouch() and 44 or 34
	local height = 56 + 12 + #actions * (btnH + 6) + 12
	local modal = Modal.create({
		parent = deps.parent,
		floating = true,
		keepOpenOver = root,
		anchorPoint = Vector2.new(0.5, 1),
		position = UDim2.new(0.5, 0, 1, -(STRIP_BOTTOM + STRIP_H + 8)),
		name = "GroupCommand",
		title = g.name or "Army Group",
		subtitle = string.format("%d armies", #(g.memberArmyIds or {})),
		width = 240,
		height = height,
		onClose = function()
			popover = nil
		end,
	})
	popover = { handle = modal, groupId = groupId }
	modal.panel:SetAttribute("AoWInputSink", true)
	local col = Instance.new("UIListLayout")
	col.SortOrder = Enum.SortOrder.LayoutOrder
	col.Padding = UDim.new(0, 6)
	col.Parent = modal.content

	for i, a in ipairs(actions) do
		if a.disband then
			local armed = false
			local btn
			btn = actionButton(modal.content, i, "Disband", "danger", function()
				if not armed then
					armed = true
					setButtonText(btn, "Confirm Disband?")
					task.delay(3, function()
						if armed and btn and btn.Parent then
							armed = false
							setButtonText(btn, "Disband")
						end
					end)
				else
					deps.fire("DisbandArmyGroup", groupId)
					closePopover()
				end
			end)
		else
			actionButton(modal.content, i, a.text, a.variant, a.run)
		end
	end
end

-- Build one group card. Returns a handle with in-place update / selected / add-mode / destroy.
local function createCard(groupId)
	local card = Instance.new("TextButton")
	card.Name = "GroupCard_" .. groupId
	card.AutoButtonColor = false
	card.Text = ""
	card.Size = UDim2.fromOffset(CARD_W, STRIP_H)
	card.BackgroundColor3 = Colors.SurfaceElevated
	card.BorderSizePixel = 0
	card.ZIndex = 1
	card:SetAttribute("AoWInputSink", true)
	card.Parent = scroller
	local stroke = Instance.new("UIStroke")
	stroke.Color = Colors.BorderStrong
	stroke.Thickness = 1
	stroke.Parent = card
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.Parent = card

	-- Portrait layout: a nation-tinted army icon on top, then the group name and unit count stacked and
	-- centered. (No crest -- every card is the player's own nation, so it would be redundant.)
	local ownerTag = getTag()
	local ownerCountry = ownerTag and deps.cache.getCountry(ownerTag) or nil
	local ownerColor = (ownerCountry and type(ownerCountry.color) == "table")
			and Color3.fromRGB(ownerCountry.color[1] or 200, ownerCountry.color[2] or 200, ownerCountry.color[3] or 200)
		or Colors.TextSecondary

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Size = UDim2.fromScale(1, 1)
	content.ZIndex = 2
	content.Parent = card
	local vlist = Instance.new("UIListLayout")
	vlist.FillDirection = Enum.FillDirection.Vertical
	vlist.HorizontalAlignment = Enum.HorizontalAlignment.Center
	vlist.VerticalAlignment = Enum.VerticalAlignment.Center
	vlist.SortOrder = Enum.SortOrder.LayoutOrder
	vlist.Padding = UDim.new(0, 4)
	vlist.Parent = content

	local topIcon = Icons.create("Army", 40, ownerColor)
	topIcon.LayoutOrder = 1
	topIcon.ZIndex = 2
	topIcon.Parent = content

	local nameLabel = Instance.new("TextLabel")
	nameLabel.BackgroundTransparency = 1
	nameLabel.Size = UDim2.new(1, 0, 0, 30)
	nameLabel.TextXAlignment = Enum.TextXAlignment.Center
	nameLabel.TextYAlignment = Enum.TextYAlignment.Center
	nameLabel.TextWrapped = true
	nameLabel.TextColor3 = Colors.TextPrimary
	nameLabel.LayoutOrder = 2
	nameLabel.ZIndex = 2
	Typography.apply(nameLabel, "label")
	nameLabel.Parent = content

	local countLabel = Instance.new("TextLabel")
	countLabel.BackgroundTransparency = 1
	countLabel.Size = UDim2.new(1, 0, 0, 28)
	countLabel.TextXAlignment = Enum.TextXAlignment.Center
	countLabel.TextYAlignment = Enum.TextYAlignment.Top
	countLabel.TextWrapped = true
	countLabel.TextColor3 = Colors.TextSecondary
	countLabel.LayoutOrder = 3
	countLabel.ZIndex = 2
	Typography.apply(countLabel, "caption")
	countLabel.Parent = content

	local star = Icons.create("Star", 14, Colors.Accent)
	star.AnchorPoint = Vector2.new(0, 1)
	star.Position = UDim2.fromScale(0, 1)
	star.ZIndex = 3
	star.Visible = false
	star.Parent = card

	local shield = Icons.create("Shield", 14, Colors.Warning)
	shield.AnchorPoint = Vector2.new(1, 1)
	shield.Position = UDim2.fromScale(1, 1)
	shield.ZIndex = 3
	shield.Visible = false
	shield.Parent = card

	local addBtn = Instance.new("TextButton")
	addBtn.Name = "AddSelection"
	addBtn.AutoButtonColor = false
	addBtn.Text = ""
	addBtn.AnchorPoint = Vector2.new(1, 0)
	addBtn.Position = UDim2.fromScale(1, 0)
	addBtn.Size = UDim2.fromOffset(22, 22)
	addBtn.BackgroundColor3 = Colors.Accent
	addBtn.BorderSizePixel = 0
	addBtn.ZIndex = 5
	addBtn.Visible = false
	addBtn:SetAttribute("AoWInputSink", true)
	addBtn.Parent = card
	local plusIcon = Icons.create("Plus", 16, Colors.SurfaceBase)
	plusIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	plusIcon.Position = UDim2.fromScale(0.5, 0.5)
	plusIcon.ZIndex = 6
	plusIcon.Parent = addBtn

	card.MouseButton1Click:Connect(function()
		quickSelect(groupId)
		openPopover(groupId)
	end)
	addBtn.MouseButton1Click:Connect(function()
		if not deps.cache.getArmyGroup(groupId) then
			return
		end
		local sel = ownedSelection()
		local ids = {}
		for _, id in ipairs(sel) do
			local a = deps.cache.getArmy(id)
			if a and a.groupId ~= groupId then
				ids[#ids + 1] = id
			end
		end
		if #ids > 0 then
			deps.fire("AddArmyToGroup", groupId, ids)
		end
	end)

	local function update(group)
		nameLabel.Text = group.name or "Army Group"
		local rgts = 0
		for _, id in ipairs(group.memberArmyIds or {}) do
			rgts += regimentsTotal(deps.cache.getArmy(id))
		end
		countLabel.Text = string.format("%d armies \u{00B7} %d rgts", #(group.memberArmyIds or {}), rgts)
		star.Visible = commanderOf(group) ~= nil
		shield.Visible = WorldConstants.EnableBorderCover and group.borderCoverTargetTag ~= nil
	end

	local function setSelected(on)
		stroke.Color = on and Colors.BorderActive or Colors.BorderStrong
		stroke.Thickness = on and 2 or 1
		card.BackgroundColor3 = on and Colors.SurfaceOverlay or Colors.SurfaceElevated
	end

	local function setAddMode(show)
		addBtn.Visible = show
	end

	local function destroy()
		card:Destroy()
	end

	return { root = card, update = update, setSelected = setSelected, setAddMode = setAddMode, destroy = destroy }
end

local function ensurePlusCard()
	if plusCard then
		return
	end
	local card = Instance.new("TextButton")
	card.Name = "NewGroupCard"
	card.AutoButtonColor = false
	card.Text = ""
	card.Size = UDim2.fromOffset(CARD_W, STRIP_H)
	card.BackgroundColor3 = Colors.SurfaceElevated
	card.BorderSizePixel = 0
	card.LayoutOrder = PLUS_ORDER
	card:SetAttribute("AoWInputSink", true)
	card.Parent = scroller
	local stroke = Instance.new("UIStroke")
	stroke.Color = Colors.BorderSubtle
	stroke.Thickness = 1
	stroke.Parent = card
	local icon = Icons.create("Plus", 24, Colors.Accent)
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.new(0.5, 0, 0.5, -8)
	icon.Parent = card
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.AnchorPoint = Vector2.new(0.5, 1)
	lbl.Position = UDim2.new(0.5, 0, 1, -8)
	lbl.Size = UDim2.new(1, -16, 0, 16)
	lbl.Text = "New Group"
	lbl.TextColor3 = Colors.TextSecondary
	lbl.TextXAlignment = Enum.TextXAlignment.Center
	Typography.apply(lbl, "caption")
	lbl.Parent = card
	card.MouseButton1Click:Connect(function()
		if card.Active == false then
			return
		end
		local sel = ownedSelection()
		if #sel == 0 then
			return
		end
		openNameEntry({
			title = "Form Army Group",
			subtitle = "Name the new group",
			default = "Army Group",
			confirmText = "Create",
			onConfirm = function(name)
				deps.fire("FormArmyGroup", name, sel)
			end,
		})
	end)
	plusCard = { root = card, icon = icon }
end

local function setPlusEnabled(on)
	if not plusCard then
		return
	end
	plusCard.root.Active = on
	plusCard.icon.ImageColor3 = on and Colors.Accent or Colors.TextDisabled
end

-- Highlight the selected group's card, toggle per-card add affordances, enable the "+" card, and hide
-- the whole strip when there is nothing to show (no groups + no owned selection).
local function refreshSelectionState()
	if not root then
		return
	end
	selectedGroupId = selectionGroupId()
	local sel = ownedSelection()
	local hasSel = #sel > 0
	for gid, card in pairs(cardsById) do
		card.setSelected(gid == selectedGroupId)
		local addable = false
		if hasSel then
			for _, id in ipairs(sel) do
				local a = deps.cache.getArmy(id)
				if a and a.groupId ~= gid then
					addable = true
					break
				end
			end
		end
		card.setAddMode(addable)
	end
	setPlusEnabled(hasSel)
	local anyGroups = next(cardsById) ~= nil
	root.Visible = (getTag() ~= nil) and (anyGroups or hasSel)
end

local function reconcile()
	reconcileQueued = false
	if not root then
		return
	end
	local groups = ownGroupsSorted()
	local seen = {}
	for i, g in ipairs(groups) do
		seen[g.id] = true
		local card = cardsById[g.id]
		if not card then
			card = createCard(g.id)
			cardsById[g.id] = card
		end
		card.root.LayoutOrder = i
		card.update(g)
	end
	for gid, card in pairs(cardsById) do
		if not seen[gid] then
			card.destroy()
			cardsById[gid] = nil
		end
	end
	if popover and not seen[popover.groupId] then
		closePopover()
	end
	refreshSelectionState()
end

local function scheduleReconcile()
	if reconcileQueued then
		return
	end
	reconcileQueued = true
	task.defer(reconcile)
end

function ArmyGroupStrip.init(d)
	if root then
		return { destroy = ArmyGroupStrip.destroy }
	end
	deps = d
	if not (deps and deps.parent and deps.cache and deps.armyView and deps.fire and deps.requestTarget and deps.getTag) then
		return nil
	end

	root = Instance.new("Frame")
	root.Name = "ArmyGroupStrip"
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.Position = UDim2.new(0.5, 0, 1, -STRIP_BOTTOM)
	root.Size = UDim2.new(0.8, 0, 0, STRIP_H)
	root.BackgroundTransparency = 1
	root.ZIndex = 40
	root.Visible = false
	root.Parent = deps.parent

	scroller = Instance.new("ScrollingFrame")
	scroller.Name = "Cards"
	scroller.Size = UDim2.fromScale(1, 1)
	scroller.BackgroundTransparency = 1
	scroller.BorderSizePixel = 0
	scroller.ClipsDescendants = true
	scroller.ScrollingDirection = Enum.ScrollingDirection.X
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.None
	scroller.CanvasSize = UDim2.new()
	scroller.ScrollBarThickness = 4
	scroller.ScrollBarImageColor3 = Colors.BorderStrong
	scroller.ZIndex = 40
	scroller:SetAttribute("AoWInputSink", true)
	scroller.Parent = root

	layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroller

	-- Center the row when it fits; switch to left-aligned horizontal scrolling only on overflow.
	local function relayout()
		if not (scroller and layout) then
			return
		end
		local cw = layout.AbsoluteContentSize.X
		local sw = scroller.AbsoluteSize.X
		if cw <= sw then
			scroller.AutomaticCanvasSize = Enum.AutomaticSize.None
			scroller.CanvasSize = UDim2.new()
			layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		else
			layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
			scroller.AutomaticCanvasSize = Enum.AutomaticSize.X
		end
	end
	unsubs[#unsubs + 1] = layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(relayout)
	unsubs[#unsubs + 1] = scroller:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)

	ensurePlusCard()

	unsubs[#unsubs + 1] = deps.cache.onChangePrefix("armyGroups", scheduleReconcile)
	unsubs[#unsubs + 1] = deps.cache.onChangePrefix("armies", scheduleReconcile)
	unsubs[#unsubs + 1] = deps.cache.onChangePrefix("countries", scheduleReconcile)
	if deps.armyView.onArmySelected then
		unsubs[#unsubs + 1] = deps.armyView.onArmySelected(function()
			refreshSelectionState()
		end)
	end

	reconcile()
	return { destroy = ArmyGroupStrip.destroy }
end

function ArmyGroupStrip.destroy()
	closePopover()
	closePicker()
	for _, u in ipairs(unsubs) do
		if type(u) == "function" then
			pcall(u)
		elseif typeof(u) == "RBXScriptConnection" then
			u:Disconnect()
		end
	end
	unsubs = {}
	for gid, card in pairs(cardsById) do
		card.destroy()
		cardsById[gid] = nil
	end
	plusCard = nil
	if root then
		root:Destroy()
		root = nil
	end
	scroller = nil
	layout = nil
	deps = nil
end

return ArmyGroupStrip
