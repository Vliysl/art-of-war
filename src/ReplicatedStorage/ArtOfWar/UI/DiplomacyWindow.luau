local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))
local UIRoot = require(uiFolder:WaitForChild("UIRoot"))
local MovableWindow = require(uiFolder:WaitForChild("MovableWindow"))

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local ClientStateCache = require(aow:WaitForChild("Modules"):WaitForChild("ClientStateCache"))

local DiplomacyWindow = {}

local TAB_DEFS = {
	{ key = "Relations", label = "Relations" },
	{ key = "Wars",      label = "Wars" },
	{ key = "Treaties",  label = "Treaties" },
	{ key = "Subjects",  label = "Subjects" },
	{ key = "Messages",  label = "Messages" },
}

local TAB_STRIP_H = 32

local getMyTagCallback = nil
local function myTag()
	if getMyTagCallback then
		local ok, tag = pcall(getMyTagCallback)
		if ok then return tag end
	end
	local p = Players.LocalPlayer
	return p and p:GetAttribute("CountryTag") or nil
end

local function clearChildren(parent)
	for _, c in parent:GetChildren() do
		if c:IsA("GuiObject") or c:IsA("UIListLayout") or c:IsA("UIPadding") then
			-- keep layouts; only destroy frames/buttons/labels we've added
			if c:IsA("Frame") or c:IsA("TextButton") or c:IsA("TextLabel") or c:IsA("ScrollingFrame") or c:IsA("TextBox") then
				c:Destroy()
			end
		end
	end
end

local function styleActionButton(btn, tone)
	local color = UIStyle.Color.Gold
	if tone == "good" then color = UIStyle.Color.Good
	elseif tone == "bad" then color = UIStyle.Color.Bad
	elseif tone == "neutral" then color = UIStyle.Color.TextMuted
	elseif tone == "gold" then color = UIStyle.Color.GoldBright
	end
	btn.BackgroundColor3 = UIStyle.Color.PanelAlt
	btn.BackgroundTransparency = 0.05
	btn.TextColor3 = color
	btn.FontFace = UIStyle.FontFace.Cinzel
	btn.AutoButtonColor = false
	UIBuilder.corner(btn, 2)
	local stroke = UIBuilder.stroke(btn, 1, color)
	stroke.Transparency = 0.2
end

local function statusFor(otherTag, mineTag)
	if not mineTag or otherTag == mineTag then return "self" end
	for _, war in pairs(ClientStateCache.allWars()) do
		if war.status == "active"
			and ((war.attackerTag == mineTag and war.defenderTag == otherTag)
				or (war.defenderTag == mineTag and war.attackerTag == otherTag)) then
			return "at_war"
		end
	end
	local mine = ClientStateCache.getCountry(mineTag)
	if mine and mine.truces and mine.truces[otherTag] then
		return "truce"
	end
	return "peace"
end

local relationsSearchText = ""

local function renderRelations(page, callbacks, mineTag)
	local priorScroll = page:FindFirstChildOfClass("ScrollingFrame")
	local priorPosition = priorScroll and priorScroll.CanvasPosition or Vector2.new(0, 0)
	clearChildren(page)
	if not mineTag then
		UIBuilder.emptyState(page, { icon = "Diplomacy", title = "No claim", subtitle = "Claim a country to access diplomacy." })
		return
	end

	local searchBox = Instance.new("TextBox")
	searchBox.Name = "RelationsSearch"
	searchBox.Size = UDim2.new(1, -12, 0, 28)
	searchBox.Position = UDim2.fromOffset(6, 6)
	searchBox.BackgroundColor3 = UIStyle.Color.Bg
	searchBox.BorderSizePixel = 0
	searchBox.Font = UIStyle.Font.Regular
	searchBox.TextSize = 13
	searchBox.TextColor3 = UIStyle.Color.Text
	searchBox.PlaceholderText = "Search nations\u{2026}"
	searchBox.PlaceholderColor3 = UIStyle.Color.TextMuted
	searchBox.Text = relationsSearchText
	searchBox.ClearTextOnFocus = false
	searchBox.TextXAlignment = Enum.TextXAlignment.Left
	searchBox.ClipsDescendants = true
	searchBox.Parent = page
	UIBuilder.corner(searchBox, 3)
	UIBuilder.stroke(searchBox, 1, UIStyle.Color.Border)
	local sPad = Instance.new("UIPadding")
	sPad.PaddingLeft = UDim.new(0, 10)
	sPad.PaddingRight = UDim.new(0, 10)
	sPad.Parent = searchBox

	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.new(1, 0, 1, -40)
	scroll.Position = UDim2.fromOffset(0, 40)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new()
	scroll.Parent = page

	task.defer(function()
		if scroll.Parent then scroll.CanvasPosition = priorPosition end
	end)

	local rowRefs = {}

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = scroll

	local entries = {}
	for tag, country in pairs(ClientStateCache.allCountries()) do
		if tag ~= mineTag then
			table.insert(entries, { tag = tag, name = country.displayName or tag })
		end
	end
	table.sort(entries, function(a, b) return a.name < b.name end)

	local order = 0
	for _, entry in ipairs(entries) do
		order += 1
		local row = Instance.new("Frame")
		row.Name = "row_" .. entry.tag
		row.Size = UDim2.new(1, -8, 0, 36)
		row.BackgroundColor3 = UIStyle.Color.Panel or Color3.fromRGB(30, 36, 45)
		row.BackgroundTransparency = 0.2
		row.BorderSizePixel = 0
		row.LayoutOrder = order
		row.Parent = scroll
		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = UDim.new(0, 4)
		rowCorner.Parent = row
		rowRefs[#rowRefs + 1] = { frame = row, name = string.lower(entry.name), tag = string.lower(entry.tag) }

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Size = UDim2.new(0.45, 0, 1, 0)
		nameLabel.Position = UDim2.new(0, 8, 0, 0)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Text = string.format("%s (%s)", entry.name, entry.tag)
		nameLabel.TextColor3 = UIStyle.Color.Ink or Color3.fromRGB(232, 220, 192)
		nameLabel.Font = UIStyle.Font.Sans or Enum.Font.Gotham
		nameLabel.TextSize = 13
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.Parent = row

		local status = statusFor(entry.tag, mineTag)
		local statusChip = Instance.new("TextLabel")
		statusChip.Size = UDim2.new(0, 70, 0, 20)
		statusChip.Position = UDim2.new(0.45, 4, 0.5, -10)
		statusChip.BackgroundTransparency = 0.3
		statusChip.BorderSizePixel = 0
		statusChip.Text = ({ at_war = "AT WAR", truce = "TRUCE", peace = "PEACE" })[status] or "?"
		statusChip.Font = Enum.Font.GothamBold
		statusChip.TextSize = 10
		statusChip.TextColor3 = Color3.fromRGB(20, 24, 31)
		if status == "at_war" then
			statusChip.BackgroundColor3 = Color3.fromRGB(220, 80, 80)
		elseif status == "truce" then
			statusChip.BackgroundColor3 = Color3.fromRGB(201, 162, 75)
		else
			statusChip.BackgroundColor3 = Color3.fromRGB(140, 200, 140)
		end
		statusChip.Parent = row
		local chipCorner = Instance.new("UICorner")
		chipCorner.CornerRadius = UDim.new(0, 3)
		chipCorner.Parent = statusChip

		-- Action buttons (right-aligned)
		if status == "peace" then
			local btn = Instance.new("TextButton")
			btn.Size = UDim2.new(0, 110, 0, 24)
			btn.Position = UDim2.new(1, -118, 0.5, -12)
			btn.BackgroundColor3 = Color3.fromRGB(180, 60, 60)
			btn.BorderSizePixel = 0
			btn.Text = "Declare War"
			btn.Font = Enum.Font.GothamSemibold
			btn.TextSize = 12
			btn.TextColor3 = Color3.fromRGB(240, 240, 240)
			btn.Parent = row
			styleActionButton(btn, "bad")
			btn.MouseButton1Click:Connect(function()
				if callbacks.onDeclareWar then callbacks.onDeclareWar(entry.tag) end
			end)
		elseif status == "at_war" then
			local btn1 = Instance.new("TextButton")
			btn1.Size = UDim2.new(0, 90, 0, 24)
			btn1.Position = UDim2.new(1, -200, 0.5, -12)
			btn1.BackgroundColor3 = Color3.fromRGB(140, 140, 140)
			btn1.BorderSizePixel = 0
			btn1.Text = "White Peace"
			btn1.Font = Enum.Font.GothamSemibold
			btn1.TextSize = 11
			btn1.TextColor3 = Color3.fromRGB(20, 24, 31)
			btn1.Parent = row
			styleActionButton(btn1, "neutral")
			btn1.MouseButton1Click:Connect(function()
				if callbacks.onProposePeace then callbacks.onProposePeace(entry.tag, { type = "white_peace" }) end
			end)

			local btn2 = Instance.new("TextButton")
			btn2.Size = UDim2.new(0, 100, 0, 24)
			btn2.Position = UDim2.new(1, -108, 0.5, -12)
			btn2.BackgroundColor3 = Color3.fromRGB(201, 162, 75)
			btn2.BorderSizePixel = 0
			btn2.Text = "Annex Occupied"
			btn2.Font = Enum.Font.GothamSemibold
			btn2.TextSize = 10
			btn2.TextColor3 = Color3.fromRGB(20, 24, 31)
			btn2.Parent = row
			styleActionButton(btn2, "gold")
			btn2.MouseButton1Click:Connect(function()
				if callbacks.onProposePeace then callbacks.onProposePeace(entry.tag, { type = "annex_occupied" }) end
			end)
		end
	end

	local function applyFilter()
		local f = string.lower(relationsSearchText)
		for _, r in ipairs(rowRefs) do
			r.frame.Visible = f == "" or r.name:find(f, 1, true) ~= nil or r.tag:find(f, 1, true) ~= nil
		end
	end
	applyFilter()
	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		relationsSearchText = searchBox.Text
		applyFilter()
	end)
end

local function renderTreaties(page, callbacks, mineTag)
	clearChildren(page)
	if not mineTag then
		UIBuilder.emptyState(page, { icon = "Diplomacy", title = "No claim", subtitle = "Claim a country to view treaties." })
		return
	end

	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.fromScale(1, 1)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new()
	scroll.Parent = page

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = scroll

	local order = 0
	local function header(text, tone)
		order += 1
		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.new(1, -8, 0, 20)
		lbl.BackgroundTransparency = 1
		lbl.Text = string.upper(text)
		lbl.TextColor3 = tone or UIStyle.Color.Gold
		lbl.FontFace = UIStyle.FontFace.Cinzel
		lbl.TextSize = 12
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.LayoutOrder = order
		lbl.Parent = scroll
	end
	local function card(title, subtitle, tone)
		order += 1
		local c = Instance.new("Frame")
		c.Size = UDim2.new(1, -8, 0, 44)
		c.BackgroundColor3 = UIStyle.Color.PanelAlt
		c.BorderSizePixel = 0
		c.LayoutOrder = order
		c.Parent = scroll
		UIBuilder.corner(c, 3)
		UIBuilder.stroke(c, 1, tone or UIStyle.Color.Border)
		local t = Instance.new("TextLabel")
		t.Size = UDim2.new(1, -16, 0, 18)
		t.Position = UDim2.fromOffset(8, 5)
		t.BackgroundTransparency = 1
		t.Text = title
		t.TextColor3 = UIStyle.Color.Text
		t.FontFace = UIStyle.FontFace.Cinzel
		t.TextSize = 13
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.TextTruncate = Enum.TextTruncate.AtEnd
		t.Parent = c
		local sub = Instance.new("TextLabel")
		sub.Size = UDim2.new(1, -16, 0, 14)
		sub.Position = UDim2.fromOffset(8, 24)
		sub.BackgroundTransparency = 1
		sub.Text = subtitle
		sub.TextColor3 = UIStyle.Color.TextMuted
		sub.Font = UIStyle.Font.Regular
		sub.TextSize = 11
		sub.TextXAlignment = Enum.TextXAlignment.Left
		sub.TextTruncate = Enum.TextTruncate.AtEnd
		sub.Parent = c
	end
	local function nameOf(tag)
		local rec = ClientStateCache.getCountry(tag)
		return (rec and (rec.displayName or rec.name)) or tag
	end

	local wars = {}
	for _, war in pairs(ClientStateCache.allWars()) do
		if war.status == "active" and (war.attackerTag == mineTag or war.defenderTag == mineTag) then
			wars[#wars + 1] = war
		end
	end
	if #wars > 0 then
		header("States of War", UIStyle.Color.Bad)
		for _, war in ipairs(wars) do
			local opp = war.attackerTag == mineTag and war.defenderTag or war.attackerTag
			local role = war.attackerTag == mineTag and "Aggressor" or "Defender"
			card("War with " .. nameOf(opp), role .. "  \u{00B7}  ongoing", UIStyle.Color.Bad)
		end
	end

	local mine = ClientStateCache.getCountry(mineTag)
	local truces = {}
	if mine and mine.truces then
		for tag in pairs(mine.truces) do truces[#truces + 1] = tag end
	end
	table.sort(truces)
	if #truces > 0 then
		header("Truces", UIStyle.Color.Gold)
		for _, tag in ipairs(truces) do
			card("Truce with " .. nameOf(tag), "Peace guaranteed", UIStyle.Color.Gold)
		end
	end

	if #wars == 0 and #truces == 0 then
		UIBuilder.emptyState(scroll, { icon = "Diplomacy", title = "No standing treaties",
			subtitle = "Wars you join and truces you sign will be recorded here." })
	end
end

local function renderWars(page, callbacks, mineTag)
	clearChildren(page)
	if not mineTag then
		UIBuilder.emptyState(page, { icon = "Diplomacy", title = "No claim", subtitle = "Claim a country to view your wars." })
		return
	end

	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.fromScale(1, 1)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new()
	scroll.Parent = page

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = scroll

	local hasAny = false
	local order = 0
	for warId, war in pairs(ClientStateCache.allWars()) do
		if war.status == "active"
			and (war.attackerTag == mineTag or war.defenderTag == mineTag) then
			hasAny = true
			order += 1
			local opponent = war.attackerTag == mineTag and war.defenderTag or war.attackerTag
			local opponentName = (ClientStateCache.getCountry(opponent) and ClientStateCache.getCountry(opponent).displayName) or opponent

			local row = Instance.new("Frame")
			row.Size = UDim2.new(1, -8, 0, 56)
			row.BackgroundColor3 = Color3.fromRGB(60, 30, 30)
			row.BackgroundTransparency = 0.4
			row.BorderSizePixel = 0
			row.LayoutOrder = order
			row.Parent = scroll
			local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 4); c.Parent = row

			local title = Instance.new("TextLabel")
			title.Size = UDim2.new(1, -16, 0, 18)
			title.Position = UDim2.new(0, 8, 0, 6)
			title.BackgroundTransparency = 1
			title.Text = string.format("War vs %s (%s)", opponentName, opponent)
			title.TextColor3 = Color3.fromRGB(232, 220, 192)
			title.Font = Enum.Font.GothamBold
			title.TextSize = 13
			title.TextXAlignment = Enum.TextXAlignment.Left
			title.Parent = row

			local detail = Instance.new("TextLabel")
			detail.Size = UDim2.new(1, -16, 0, 16)
			detail.Position = UDim2.new(0, 8, 0, 24)
			detail.BackgroundTransparency = 1
			detail.Text = string.format("Declared at %.0fs (war %s)", war.declaredAt or 0, warId)
			detail.TextColor3 = Color3.fromRGB(180, 180, 180)
			detail.Font = Enum.Font.Gotham
			detail.TextSize = 11
			detail.TextXAlignment = Enum.TextXAlignment.Left
			detail.Parent = row

			local btn1 = Instance.new("TextButton")
			btn1.Size = UDim2.new(0, 90, 0, 22)
			btn1.Position = UDim2.new(1, -200, 1, -28)
			btn1.BackgroundColor3 = Color3.fromRGB(140, 140, 140)
			btn1.BorderSizePixel = 0
			btn1.Text = "White Peace"
			btn1.Font = Enum.Font.GothamSemibold
			btn1.TextSize = 11
			btn1.TextColor3 = Color3.fromRGB(20, 24, 31)
			btn1.Parent = row
			styleActionButton(btn1, "neutral")
			btn1.MouseButton1Click:Connect(function()
				if callbacks.onProposePeace then callbacks.onProposePeace(opponent, { type = "white_peace" }) end
			end)

			local btn2 = Instance.new("TextButton")
			btn2.Size = UDim2.new(0, 100, 0, 22)
			btn2.Position = UDim2.new(1, -108, 1, -28)
			btn2.BackgroundColor3 = Color3.fromRGB(201, 162, 75)
			btn2.BorderSizePixel = 0
			btn2.Text = "Annex Occupied"
			btn2.Font = Enum.Font.GothamSemibold
			btn2.TextSize = 10
			btn2.TextColor3 = Color3.fromRGB(20, 24, 31)
			btn2.Parent = row
			styleActionButton(btn2, "gold")
			btn2.MouseButton1Click:Connect(function()
				if callbacks.onProposePeace then callbacks.onProposePeace(opponent, { type = "annex_occupied" }) end
			end)
		end
	end

	if not hasAny then
		UIBuilder.emptyState(scroll, { icon = "Diplomacy", title = "No active wars", subtitle = "Declare war on a neighbor from the Relations tab." })
	end
end

local function renderMessages(page, callbacks, mineTag)
	clearChildren(page)
	if not mineTag then
		UIBuilder.emptyState(page, { icon = "Diplomacy", title = "No claim", subtitle = "Claim a country to view diplomacy messages." })
		return
	end

	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.fromScale(1, 1)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new()
	scroll.Parent = page

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = scroll

	local hasAny = false
	local order = 0
	for proposalId, prop in pairs(ClientStateCache.allPeaceProposals()) do
		if prop.status == "pending" and (prop.toTag == mineTag or prop.fromTag == mineTag) then
			hasAny = true
			order += 1
			local incoming = prop.toTag == mineTag
			local other = incoming and prop.fromTag or prop.toTag
			local otherName = (ClientStateCache.getCountry(other) and ClientStateCache.getCountry(other).displayName) or other

			local row = Instance.new("Frame")
			row.Size = UDim2.new(1, -8, 0, 60)
			row.BackgroundColor3 = incoming and Color3.fromRGB(40, 50, 70) or Color3.fromRGB(50, 50, 60)
			row.BackgroundTransparency = 0.3
			row.BorderSizePixel = 0
			row.LayoutOrder = order
			row.Parent = scroll
			local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 4); c.Parent = row

			local title = Instance.new("TextLabel")
			title.Size = UDim2.new(1, -16, 0, 18)
			title.Position = UDim2.new(0, 8, 0, 6)
			title.BackgroundTransparency = 1
			title.Text = string.format("%s %s peace (%s)",
				otherName,
				incoming and "proposes" or "(outgoing) to",
				prop.terms and prop.terms.type or "?")
			title.TextColor3 = Color3.fromRGB(232, 220, 192)
			title.Font = Enum.Font.GothamBold
			title.TextSize = 13
			title.TextXAlignment = Enum.TextXAlignment.Left
			title.Parent = row

			local detail = Instance.new("TextLabel")
			detail.Size = UDim2.new(1, -16, 0, 16)
			detail.Position = UDim2.new(0, 8, 0, 26)
			detail.BackgroundTransparency = 1
			detail.Text = string.format("Expires at sim time %.1f", prop.expiresAt or 0)
			detail.TextColor3 = Color3.fromRGB(180, 180, 180)
			detail.Font = Enum.Font.Gotham
			detail.TextSize = 11
			detail.TextXAlignment = Enum.TextXAlignment.Left
			detail.Parent = row

			if incoming then
				local btnA = Instance.new("TextButton")
				btnA.Size = UDim2.new(0, 80, 0, 22)
				btnA.Position = UDim2.new(1, -170, 1, -28)
				btnA.BackgroundColor3 = Color3.fromRGB(140, 200, 140)
				btnA.BorderSizePixel = 0
				btnA.Text = "Accept"
				btnA.Font = Enum.Font.GothamBold
				btnA.TextSize = 12
				btnA.TextColor3 = Color3.fromRGB(20, 24, 31)
				btnA.Parent = row
				styleActionButton(btnA, "good")
				btnA.MouseButton1Click:Connect(function()
					if callbacks.onAcceptPeace then callbacks.onAcceptPeace(proposalId) end
				end)

				local btnR = Instance.new("TextButton")
				btnR.Size = UDim2.new(0, 80, 0, 22)
				btnR.Position = UDim2.new(1, -88, 1, -28)
				btnR.BackgroundColor3 = Color3.fromRGB(200, 100, 100)
				btnR.BorderSizePixel = 0
				btnR.Text = "Reject"
				btnR.Font = Enum.Font.GothamBold
				btnR.TextSize = 12
				btnR.TextColor3 = Color3.fromRGB(240, 240, 240)
				btnR.Parent = row
				styleActionButton(btnR, "bad")
				btnR.MouseButton1Click:Connect(function()
					if callbacks.onRejectPeace then callbacks.onRejectPeace(proposalId) end
				end)
			else
				local btnC = Instance.new("TextButton")
				btnC.Size = UDim2.new(0, 80, 0, 22)
				btnC.Position = UDim2.new(1, -88, 1, -28)
				btnC.BackgroundColor3 = Color3.fromRGB(140, 140, 140)
				btnC.BorderSizePixel = 0
				btnC.Text = "Cancel"
				btnC.Font = Enum.Font.GothamSemibold
				btnC.TextSize = 12
				btnC.TextColor3 = Color3.fromRGB(20, 24, 31)
				btnC.Parent = row
				styleActionButton(btnC, "neutral")
				btnC.MouseButton1Click:Connect(function()
					if callbacks.onCancelProposal then callbacks.onCancelProposal(proposalId) end
				end)
			end
		end
	end

	if not hasAny then
		UIBuilder.emptyState(scroll, { icon = "Diplomacy", title = "No peace proposals", subtitle = "Peace offers and outgoing proposals will appear here." })
	end
end

local function renderStub(page, label, subtitle)
	clearChildren(page)
	UIBuilder.emptyState(page, { icon = "Diplomacy", title = label, subtitle = subtitle })
end

function DiplomacyWindow.create(callbacks)
	callbacks = callbacks or {}
	getMyTagCallback = callbacks.getMyTag
	local win = MovableWindow.create({ id = "diplomacy", title = "Diplomacy", size = UDim2.fromOffset(720, 520) })

	local tabStrip = Instance.new("Frame")
	tabStrip.Size = UDim2.new(1, 0, 0, TAB_STRIP_H)
	tabStrip.BackgroundColor3 = UIStyle.Color.Bg or Color3.fromRGB(20, 24, 31)
	tabStrip.BorderSizePixel = 0
	tabStrip.Parent = win.body

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
	underline.BackgroundColor3 = UIStyle.Color.Gold or Color3.fromRGB(201, 162, 75)
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
	local function rerender(key)
		local tab = tabs[key]
		if not tab then return end
		local mineTag = myTag()
		if key == "Relations" then renderRelations(tab.page, callbacks, mineTag)
		elseif key == "Wars" then renderWars(tab.page, callbacks, mineTag)
		elseif key == "Messages" then renderMessages(tab.page, callbacks, mineTag)
		elseif key == "Treaties" then renderTreaties(tab.page, callbacks, mineTag)
		elseif key == "Subjects" then renderStub(tab.page, "Subjects", "Vassals, colonies, and tributaries coming soon.")
		end
	end

	local function setActive(key)
		for k, data in tabs do
			local isActive = k == key
			data.page.Visible = isActive
			data.label.TextColor3 = isActive and (UIStyle.Color.Gold or Color3.fromRGB(201, 162, 75))
				or (UIStyle.Color.TextMuted or Color3.fromRGB(140, 140, 140))
			if isActive then
				local s = UIRoot.uiScale()
				local px = (data.button.AbsolutePosition.X - tabRow.AbsolutePosition.X) / s
				local sx = data.button.AbsoluteSize.X / s
				underline.Position = UDim2.new(0, px, 1, -2)
				underline.Size = UDim2.fromOffset(sx, 2)
			end
		end
		active = key
		rerender(key)
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
		lbl.TextColor3 = UIStyle.Color.TextMuted or Color3.fromRGB(140, 140, 140)
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
	task.defer(function() setActive("Relations") end)

	-- Re-render on state changes (debounced via task.defer to coalesce)
	local refreshPending = false
	local function scheduleRefresh()
		if refreshPending then return end
		refreshPending = true
		task.defer(function()
			refreshPending = false
			if active then rerender(active) end
		end)
	end
	if ClientStateCache.onChangePrefix then
		ClientStateCache.onChangePrefix("wars", scheduleRefresh)
		ClientStateCache.onChangePrefix("peaceProposals", scheduleRefresh)
		ClientStateCache.onChangePrefix("countries", scheduleRefresh)
	end

	return {
		open = win.open, close = win.close, toggle = win.toggle, isOpen = win.isOpen,
		bringToFront = win.bringToFront,
		setActiveTab = setActive,
		refresh = function() if active then rerender(active) end end,
	}
end

return DiplomacyWindow
