local ReplicatedStorage = game:GetService("ReplicatedStorage")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))
local UISound = require(uiFolder:WaitForChild("UISound"))

local ClaimScreen = {}

local function titleCase(text)
	if not text then return "-" end
	return (text:gsub("_", " ")):gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b:lower() end)
end

local function countryMatches(country, tag, query)
	if not query or query == "" then return true end
	local q = query:lower()
	local name = (country.displayName or tag or ""):lower()
	if name:find(q, 1, true) then return true end
	if tag:lower():find(q, 1, true) then return true end
	if (country.ideology or ""):lower():find(q, 1, true) then return true end
	if (country.governmentForm or ""):lower():find(q, 1, true) then return true end
	return false
end

function ClaimScreen.create(parent, onClaim)
	-- Full-screen dim at 75%
	local overlay = UIBuilder.dim(parent, 0.75, {
		Name = "ClaimScreen",
		ZIndex = UIStyle.Z.Modal,
	})
	overlay.Active = true

	local panel = UIBuilder.bracketedPanel(overlay, {
		Size = UDim2.new(1, -40, 1, -40),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = UIStyle.Z.Modal + 1,
		BackgroundColor3 = UIStyle.Color.Panel,
	}, 18, 8)
	local panelSize = Instance.new("UISizeConstraint")
	panelSize.MaxSize = Vector2.new(960, 620)
	panelSize.MinSize = Vector2.new(480, 360)
	panelSize.Parent = panel
	for _, c in panel:GetChildren() do
		if c:IsA("UIStroke") then c.Color = UIStyle.Color.Gold c.Thickness = 1 end
	end

	local header = Instance.new("Frame")
	header.Size = UDim2.new(1, 0, 0, 96)
	header.BackgroundTransparency = 1
	header.ZIndex = UIStyle.Z.Modal + 2
	header.Parent = panel

	UIBuilder.generalLabel(header, "Choose your realm", {
		Size = UDim2.new(1, -40, 0, 14),
		Position = UDim2.fromOffset(28, 16),
		TextSize = 11,
		color = UIStyle.Color.LedgerSection,
	})

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Size = UDim2.new(1, -40, 0, 38)
	titleLabel.Position = UDim2.fromOffset(28, 32)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = "Select a Nation"
	titleLabel.TextColor3 = UIStyle.Color.Text
	titleLabel.FontFace = UIStyle.FontFace.CinzelBold
	titleLabel.TextSize = 28
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.ZIndex = UIStyle.Z.Modal + 3
	titleLabel.Parent = header

	local subtitleLabel = Instance.new("TextLabel")
	subtitleLabel.Size = UDim2.new(1, -40, 0, 16)
	subtitleLabel.Position = UDim2.fromOffset(28, 70)
	subtitleLabel.BackgroundTransparency = 1
	subtitleLabel.Text = "Every nation begins in 1750 with its own character. Choose yours."
	subtitleLabel.TextColor3 = UIStyle.Color.TextMuted
	subtitleLabel.FontFace = UIStyle.FontFace.InterItalic
	subtitleLabel.TextSize = 12
	subtitleLabel.TextXAlignment = Enum.TextXAlignment.Left
	subtitleLabel.ZIndex = UIStyle.Z.Modal + 3
	subtitleLabel.Parent = header

	local body = Instance.new("Frame")
	body.Size = UDim2.new(1, -32, 1, -110)
	body.Position = UDim2.fromOffset(16, 100)
	body.BackgroundTransparency = 1
	body.ZIndex = UIStyle.Z.Modal + 2
	body.Parent = panel

	-- LEFT: search + filter + list
	local leftCol = Instance.new("Frame")
	leftCol.Size = UDim2.new(0.42, -6, 1, 0)
	leftCol.Position = UDim2.fromOffset(0, 0)
	leftCol.BackgroundTransparency = 1
	leftCol.Parent = body

	local searchBox = Instance.new("TextBox")
	searchBox.Size = UDim2.new(1, 0, 0, 30)
	searchBox.Position = UDim2.fromOffset(0, 0)
	searchBox.BackgroundColor3 = UIStyle.Color.Bg
	searchBox.BorderSizePixel = 0
	searchBox.Text = ""
	searchBox.PlaceholderText = "  Search nations..."
	searchBox.PlaceholderColor3 = UIStyle.Color.TextMuted
	searchBox.TextColor3 = UIStyle.Color.Text
	searchBox.Font = UIStyle.Font.Regular
	searchBox.TextSize = 13
	searchBox.TextXAlignment = Enum.TextXAlignment.Left
	searchBox.ClearTextOnFocus = false
	searchBox.ZIndex = UIStyle.Z.Modal + 3
	searchBox.Parent = leftCol
	UIBuilder.corner(searchBox, 2)
	UIBuilder.stroke(searchBox, 1, UIStyle.Color.Border)
	UIBuilder.padding(searchBox, 0, 10, 0, 10)

	local listScroll, listLayout = UIBuilder.scrollingList(leftCol, {
		Size = UDim2.new(1, 0, 1, -40),
		Position = UDim2.fromOffset(0, 38),
	})
	listLayout.Padding = UDim.new(0, 4)

	-- RIGHT: preview
	local rightCol = Instance.new("Frame")
	rightCol.Size = UDim2.new(0.58, -6, 1, 0)
	rightCol.Position = UDim2.new(0.42, 6, 0, 0)
	rightCol.BackgroundColor3 = UIStyle.Color.PanelAlt
	rightCol.BorderSizePixel = 0
	rightCol.ZIndex = UIStyle.Z.Modal + 2
	rightCol.Parent = body
	UIBuilder.corner(rightCol, 3)
	UIBuilder.stroke(rightCol, 1, UIStyle.Color.Border)

	local previewCrestHolder = Instance.new("Frame")
	previewCrestHolder.Size = UDim2.fromOffset(80, 80)
	previewCrestHolder.Position = UDim2.fromOffset(20, 20)
	previewCrestHolder.BackgroundTransparency = 1
	previewCrestHolder.ZIndex = UIStyle.Z.Modal + 3
	previewCrestHolder.Parent = rightCol

	local previewCrest = UIBuilder.crest(previewCrestHolder, UIStyle.Color.PanelAlt, "---", { size = 80 })

	local previewName = Instance.new("TextLabel")
	previewName.Size = UDim2.new(1, -120, 0, 26)
	previewName.Position = UDim2.fromOffset(112, 22)
	previewName.BackgroundTransparency = 1
	previewName.Text = ""
	previewName.TextColor3 = UIStyle.Color.Text
	previewName.FontFace = UIStyle.FontFace.CinzelBold
	previewName.TextSize = 20
	previewName.TextXAlignment = Enum.TextXAlignment.Left
	previewName.TextYAlignment = Enum.TextYAlignment.Center
	previewName.ZIndex = UIStyle.Z.Modal + 3
	previewName.Parent = rightCol

	local previewBadgeRow = Instance.new("Frame")
	previewBadgeRow.Size = UDim2.new(1, -120, 0, 20)
	previewBadgeRow.Position = UDim2.fromOffset(112, 52)
	previewBadgeRow.BackgroundTransparency = 1
	previewBadgeRow.ZIndex = UIStyle.Z.Modal + 3
	previewBadgeRow.Parent = rightCol
	local previewBadgeLayout = Instance.new("UIListLayout")
	previewBadgeLayout.FillDirection = Enum.FillDirection.Horizontal
	previewBadgeLayout.Padding = UDim.new(0, 4)
	previewBadgeLayout.Parent = previewBadgeRow

	local previewFlavor = Instance.new("TextLabel")
	previewFlavor.Size = UDim2.new(1, -40, 0, 48)
	previewFlavor.Position = UDim2.fromOffset(20, 112)
	previewFlavor.BackgroundTransparency = 1
	previewFlavor.Text = ""
	previewFlavor.TextColor3 = UIStyle.Color.TooltipTertiary
	previewFlavor.FontFace = UIStyle.FontFace.InterItalic
	previewFlavor.TextSize = 12
	previewFlavor.TextXAlignment = Enum.TextXAlignment.Left
	previewFlavor.TextYAlignment = Enum.TextYAlignment.Top
	previewFlavor.TextWrapped = true
	previewFlavor.ZIndex = UIStyle.Z.Modal + 3
	previewFlavor.Parent = rightCol

	-- Stats grid (placeholder; shows what we have)
	local statsHolder = Instance.new("Frame")
	statsHolder.Size = UDim2.new(1, -40, 0, 180)
	statsHolder.Position = UDim2.fromOffset(20, 170)
	statsHolder.BackgroundTransparency = 1
	statsHolder.ZIndex = UIStyle.Z.Modal + 3
	statsHolder.Parent = rightCol

	local statsLayout = Instance.new("UIListLayout")
	statsLayout.FillDirection = Enum.FillDirection.Vertical
	statsLayout.Padding = UDim.new(0, 6)
	statsLayout.Parent = statsHolder

	local cta = UIBuilder.secondaryButton(rightCol, {
		Size = UDim2.new(1, -40, 0, 44),
		Position = UDim2.new(0.5, 0, 1, -20),
		AnchorPoint = Vector2.new(0.5, 1),
		Text = "Select a Realm",
		TextSize = 15,
		ZIndex = UIStyle.Z.Modal + 3,
	})
	cta.button:SetAttribute("AoWNoClickSound", true)
	cta.setEnabled(false)

	local allCountries = {}
	local claimedSet = {}
	local selectedTag = nil
	local selectedOrdered = {}

	local function refreshCta()
		if not selectedTag then
			cta.setText("Select a Realm")
			cta.setEnabled(false)
			return
		end
		if claimedSet[selectedTag] then
			cta.setText("Already Claimed")
			cta.setEnabled(false)
			return
		end
		local c = allCountries[selectedTag]
		cta.setText("Play as " .. (c and c.displayName or selectedTag))
		cta.setEnabled(true)
	end

	cta.clicked(function()
		if selectedTag and onClaim then
			if UISound and UISound.claim then UISound.claim() end
			onClaim(selectedTag)
		end
	end)

	local function renderPreview(tag)
		local c = tag and allCountries[tag]
		if previewCrest then previewCrest:Destroy() end
		if not c then
			previewCrest = UIBuilder.crest(previewCrestHolder, UIStyle.Color.PanelAlt, "---", { size = 80 })
			previewName.Text = "Select a realm"
			previewFlavor.Text = "Pick a nation from the list."
			for _, child in previewBadgeRow:GetChildren() do
				if child:IsA("Frame") then child:Destroy() end
			end
			for _, child in statsHolder:GetChildren() do
				if child:IsA("Frame") then child:Destroy() end
			end
			refreshCta()
			return
		end

		local color = c.color and Color3.fromRGB(c.color[1], c.color[2], c.color[3]) or UIStyle.Color.PanelAlt
		previewCrest = UIBuilder.crest(previewCrestHolder, color, tag, { size = 80 })
		previewName.Text = c.displayName or tag
		previewFlavor.Text = c.flavor or string.format("The realm of %s stands ready at the dawn of %s.", c.displayName or tag, "1750")

		for _, child in previewBadgeRow:GetChildren() do
			if child:IsA("Frame") then child:Destroy() end
		end
		if c.governmentForm then
			UIBuilder.badge(previewBadgeRow, titleCase(c.governmentForm), "muted", { LayoutOrder = 1 })
		end
		if c.ideology then
			UIBuilder.badge(previewBadgeRow, titleCase(c.ideology), "info", { LayoutOrder = 2 })
		end

		for _, child in statsHolder:GetChildren() do
			if child:IsA("Frame") then child:Destroy() end
		end

		local function addStatRow(label, value, tone)
			UIBuilder.ledgerRow(statsHolder, {
				label = label,
				value = tostring(value or "-"),
				valueColor = tone or UIStyle.Color.LedgerValue,
			})
		end

		addStatRow("Starting Treasury",  c.treasury or "-",      UIStyle.Color.LedgerValue)
		addStatRow("Manpower Pool",      c.manpower or "-",      UIStyle.Color.LedgerPositive)
		addStatRow("Political Power",    c.politicalPower or "-",UIStyle.Color.LedgerPositive)
		addStatRow("Stability",
			c.stability ~= nil and string.format("%+d", c.stability) or "-",
			c.stability and UIBuilder.ledgerNumberColor(c.stability) or UIStyle.Color.LedgerValue)
		addStatRow("Legitimacy",
			c.legitimacy ~= nil and string.format("%d", math.floor(c.legitimacy + 0.5)) or "-",
			UIStyle.Color.LedgerPositive)
		addStatRow("Starting Provinces", c.provinceCount or c.startingProvinceCount or "-", UIStyle.Color.LedgerPositive)

		refreshCta()
	end

	local function selectTag(tag)
		selectedTag = tag
		renderPreview(tag)
		for _, child in listScroll:GetChildren() do
			if child:IsA("TextButton") then
				local isActive = child:GetAttribute("tag") == tag
				child.BackgroundColor3 = isActive and UIStyle.Color.PanelAlt or UIStyle.Color.Panel
				child.BackgroundTransparency = isActive and 0 or 0.4
				for _, c in child:GetChildren() do
					if c:IsA("Frame") and c.Size == UDim2.new(0, 2, 1, -10) then
						c.Visible = isActive
					end
				end
			end
		end
	end

	local function buildList(query)
		for _, child in listScroll:GetChildren() do
			if child:IsA("TextButton") then child:Destroy() end
		end
		local ordered = {}
		for tag, c in allCountries do
			if countryMatches(c, tag, query) then
				table.insert(ordered, { tag = tag, c = c })
			end
		end
		table.sort(ordered, function(a, b) return (a.c.displayName or a.tag) < (b.c.displayName or b.tag) end)
		selectedOrdered = ordered

		for i, entry in ordered do
			local c = entry.c
			local isClaimed = claimedSet[entry.tag]
			local row = Instance.new("TextButton")
			row.Size = UDim2.new(1, -4, 0, 64)
			row.BackgroundColor3 = UIStyle.Color.Panel
			row.BackgroundTransparency = 0.4
			row.BorderSizePixel = 0
			row.AutoButtonColor = false
			row.Text = ""
			row.LayoutOrder = i
			row.ZIndex = UIStyle.Z.Modal + 3
			row:SetAttribute("AoWNoClickSound", true)
			row.Parent = listScroll
			row:SetAttribute("tag", entry.tag)
			UIBuilder.corner(row, 2)

			local accent = Instance.new("Frame")
			accent.Size = UDim2.new(0, 2, 1, -10)
			accent.Position = UDim2.fromOffset(0, 5)
			accent.BackgroundColor3 = UIStyle.Color.Gold
			accent.BorderSizePixel = 0
			accent.Visible = false
			accent.ZIndex = UIStyle.Z.Modal + 4
			accent.Parent = row
			row:SetAttribute("__accent", true)

			local color = c.color and Color3.fromRGB(c.color[1], c.color[2], c.color[3]) or UIStyle.Color.BorderStrong
			UIBuilder.tagChip(row, entry.tag, color, {
				size = 40,
				Position = UDim2.fromOffset(16, 12),
			})

			local nameLbl = Instance.new("TextLabel")
			nameLbl.Size = UDim2.new(1, -80, 0, 22)
			nameLbl.Position = UDim2.fromOffset(68, 10)
			nameLbl.BackgroundTransparency = 1
			nameLbl.Text = c.displayName or entry.tag
			nameLbl.TextColor3 = UIStyle.Color.Text
			nameLbl.FontFace = UIStyle.FontFace.Cinzel
			nameLbl.TextSize = 16
			nameLbl.TextXAlignment = Enum.TextXAlignment.Left
			nameLbl.TextYAlignment = Enum.TextYAlignment.Center
			nameLbl.ZIndex = UIStyle.Z.Modal + 4
			nameLbl.Parent = row

			local subText = string.format("%s  \u{00B7}  %s", titleCase(c.governmentForm or ""), titleCase(c.ideology or ""))
			local subLbl = Instance.new("TextLabel")
			subLbl.Size = UDim2.new(1, -80, 0, 14)
			subLbl.Position = UDim2.fromOffset(68, 36)
			subLbl.BackgroundTransparency = 1
			subLbl.Text = subText
			subLbl.TextColor3 = UIStyle.Color.TextMuted
			subLbl.FontFace = UIStyle.FontFace.InterItalic
			subLbl.TextSize = 11
			subLbl.TextXAlignment = Enum.TextXAlignment.Left
			subLbl.TextYAlignment = Enum.TextYAlignment.Center
			subLbl.ZIndex = UIStyle.Z.Modal + 4
			subLbl.Parent = row

			if isClaimed then
				row.Active = false
				row.AutoButtonColor = false
				local claimedLbl = Instance.new("TextLabel")
				claimedLbl.Size = UDim2.fromOffset(72, 14)
				claimedLbl.Position = UDim2.new(1, -12, 0, 12)
				claimedLbl.AnchorPoint = Vector2.new(1, 0)
				claimedLbl.BackgroundTransparency = 1
				claimedLbl.Text = "CLAIMED"
				claimedLbl.TextColor3 = UIStyle.Color.Bad
				claimedLbl.FontFace = UIStyle.FontFace.CinzelBold
				claimedLbl.TextSize = 10
				claimedLbl.TextXAlignment = Enum.TextXAlignment.Right
				claimedLbl.TextYAlignment = Enum.TextYAlignment.Center
				claimedLbl.ZIndex = UIStyle.Z.Modal + 4
				claimedLbl.Parent = row
				row.BackgroundTransparency = 0.7
			else
				row.MouseEnter:Connect(function()
					if entry.tag ~= selectedTag then
						row.BackgroundColor3 = UIStyle.Color.PanelAlt
						row.BackgroundTransparency = 0.15
					end
				end)
				row.MouseLeave:Connect(function()
					if entry.tag ~= selectedTag then
						row.BackgroundColor3 = UIStyle.Color.Panel
						row.BackgroundTransparency = 0.4
					end
				end)
				row.MouseButton1Click:Connect(function() selectTag(entry.tag) end)
			end
		end

		-- default select
		if not selectedTag or not allCountries[selectedTag] or claimedSet[selectedTag] then
			for _, entry in ordered do
				if not claimedSet[entry.tag] then
					selectTag(entry.tag)
					break
				end
			end
		else
			selectTag(selectedTag)
		end
	end

	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		buildList(searchBox.Text)
	end)

	local function populate(countries, claims)
		allCountries = countries or {}
		claimedSet = {}
		if claims then
			for _, tag in claims do claimedSet[tag] = true end
		end
		buildList(searchBox.Text)
	end

	local function setVisible(flag)
		overlay.Visible = flag and true or false
	end

	return {
		root = overlay,
		populate = populate,
		setVisible = setVisible,
	}
end

return ClaimScreen
