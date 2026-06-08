local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local uiFolder = ReplicatedStorage:WaitForChild("ArtOfWar"):WaitForChild("UI")
local UIStyle = require(uiFolder:WaitForChild("UIStyle"))
local UIBuilder = require(uiFolder:WaitForChild("UIBuilder"))
local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local Platform = require(aow:WaitForChild("Modules"):WaitForChild("Platform"))
local WorldConstants = require(aow:WaitForChild("Shared"):WaitForChild("WorldConstants"))
local EconomyPreview = require(aow:WaitForChild("Modules"):WaitForChild("EconomyPreview"))
local ClientStateCache = require(aow:WaitForChild("Modules"):WaitForChild("ClientStateCache"))
local DebugMode = require(aow:WaitForChild("Modules"):WaitForChild("DebugMode"))

local ProvinceTooltip = {}

local function titleCase(text)
	if not text or text == "" then return "-" end
	local out = (text:gsub("_", " "))
	out = (out:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b:lower() end))
	return out
end

function ProvinceTooltip.create(parent)
	local panel = UIBuilder.panel(parent, {
		Name = "ProvinceTooltip",
		Size = UDim2.fromOffset(UIStyle.Size.ProvinceTooltipW, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = false,
		ZIndex = UIStyle.Z.Tooltip,
	})
	panel.ZIndex = UIStyle.Z.Tooltip
	panel:SetAttribute("AoWInputSink", false)

	local headerBar = UIBuilder.sectionHeader(panel, "Province", 0)

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.new(1, 0, 0, 0)
	content.AutomaticSize = Enum.AutomaticSize.Y
	content.Position = UDim2.fromOffset(0, UIStyle.Size.SectionHeaderH)
	content.BackgroundTransparency = 1
	content.ZIndex = UIStyle.Z.Tooltip
	content.Parent = panel

	local contentPad = Instance.new("UIPadding")
	contentPad.PaddingLeft = UDim.new(0, UIStyle.Size.PanelPaddingX)
	contentPad.PaddingRight = UDim.new(0, UIStyle.Size.PanelPaddingX)
	contentPad.PaddingTop = UDim.new(0, 8)
	contentPad.PaddingBottom = UDim.new(0, 10)
	contentPad.Parent = content

	local contentLayout = Instance.new("UIListLayout")
	contentLayout.FillDirection = Enum.FillDirection.Vertical
	contentLayout.Padding = UDim.new(0, 3)
	contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
	contentLayout.Parent = content

	local function makeRow(order, typeToken, color, heightHint)
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 0, heightHint or 18)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.BackgroundTransparency = 1
		label.Text = ""
		label.TextColor3 = color or UIStyle.Color.Text
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Center
		label.TextWrapped = true
		label.TextTruncate = Enum.TextTruncate.None
		label.ZIndex = UIStyle.Z.Tooltip
		label.LayoutOrder = order
		UIStyle.applyType(label, typeToken or UIStyle.Type.Body)
		label.Parent = content
		return label
	end

	local nameRow = makeRow(1, nil, UIStyle.Color.TooltipPrimary, 20)
	nameRow.FontFace = UIStyle.FontFace.CinzelBold
	nameRow.TextSize = 14

	local ownerRow   = makeRow(2, nil, UIStyle.Color.TooltipSecondary, 18)
	ownerRow.FontFace = UIStyle.FontFace.Inter
	ownerRow.TextSize = 12

	local terrainRow = makeRow(3, nil, UIStyle.Color.TooltipTertiary, 16)
	terrainRow.FontFace = UIStyle.FontFace.InterItalic
	terrainRow.TextSize = 11

	local cultureRow = makeRow(4, nil, UIStyle.Color.TooltipTertiary, 16)
	cultureRow.FontFace = UIStyle.FontFace.InterItalic
	cultureRow.TextSize = 11

	local devRow = makeRow(5, nil, UIStyle.Color.TooltipSecondary, 16)
	devRow.FontFace = UIStyle.FontFace.Inter
	devRow.TextSize = 11

	local hintRow = makeRow(6, nil, UIStyle.Color.TooltipTertiary, 14)
	hintRow.FontFace = UIStyle.FontFace.InterItalic
	hintRow.TextSize = 11

	local taxRow = makeRow(7, nil, UIStyle.Color.LedgerStable, 14)
	taxRow.FontFace = UIStyle.FontFace.Inter
	taxRow.TextSize = 11

	local goodsRow = makeRow(8, nil, UIStyle.Color.GoldDim, 14)
	goodsRow.FontFace = UIStyle.FontFace.Inter
	goodsRow.TextSize = 11

	local headerLabel = headerBar:FindFirstChildOfClass("TextLabel")

	local function setLandRowsVisible(visible)
		ownerRow.Visible = visible
		terrainRow.Visible = visible
		cultureRow.Visible = visible
		devRow.Visible = visible
		hintRow.Visible = visible
		if taxRow then taxRow.Visible = visible end
		if goodsRow then goodsRow.Visible = visible end
	end

	local function follow()
		local cam = workspace.CurrentCamera
		local vp = cam and cam.ViewportSize or Vector2.new(800, 600)
		local size = panel.AbsoluteSize
		local w = size.X > 0 and size.X or UIStyle.Size.ProvinceTooltipW
		local h = size.Y > 0 and size.Y or 120
		if Platform.isTouch then
			-- Pin top-left under the topbar; stable position the player can read.
			local x = 12
			local y = (UIStyle.Size and UIStyle.Size.TopBarH or 44) + 12
			panel.Position = UDim2.fromOffset(x, y)
			return
		end
		local mp = UserInputService:GetMouseLocation()
		local x = math.min(mp.X + 16, vp.X - w - 8)
		local y = math.min(mp.Y + 18, vp.Y - h - 8)
		panel.Position = UDim2.fromOffset(x, y)
	end

	local followConn = nil
	local function ensureFollow()
		if not followConn then
			followConn = RunService.RenderStepped:Connect(follow)
		end
	end

	local function showProvince(province)
		if headerLabel then headerLabel.Text = "Province" end
		setLandRowsVisible(true)
		taxRow.Visible = true
		goodsRow.Visible = true

		nameRow.Text = province.displayCityName or province.name or ("Province " .. tostring(province.id))
		local ownerCountry = province.ownerTag and ClientStateCache.getCountry(province.ownerTag) or nil
		local ownerText = DebugMode.formatCountry(province.ownerTag, ownerCountry)
		if province.controllerTag and province.controllerTag ~= province.ownerTag then
			local ctrlCountry = ClientStateCache.getCountry(province.controllerTag)
			ownerText = string.format("%s (occupied by %s)", ownerText, DebugMode.formatCountry(province.controllerTag, ctrlCountry))
		end
		ownerRow.Text = ownerText

		terrainRow.Text = string.format("%s  |  %s", titleCase(province.terrain), titleCase(province.climate))
		cultureRow.Text = string.format("%s  \u{2022}  %s", titleCase(province.culture), titleCase(province.religion))
		devRow.Text = string.format("Dev %d  \u{2022}  Infra %d  \u{2022}  Pop %s",
			province.devTier or 0, province.infraTier or 0,
			province.population and tostring(province.population) or "?")
		hintRow.Text = province.isCity and "Urban center" or ""
		hintRow.Visible = hintRow.Text ~= ""

		-- Economic preview lines
		local owner = province.ownerTag and ClientStateCache.getCountry(province.ownerTag) or nil
		local isCapital = owner and owner.capitalProvinceId == province.id
		local tax = owner and EconomyPreview.taxOf(province, owner, WorldConstants, nil, isCapital, 0) or 0
		taxRow.Text = string.format("Tax: %.1f / day%s", tax, isCapital and " (capital)" or "")
		taxRow.TextColor3 = tax > 0 and UIStyle.Color.Good or UIStyle.Color.TextMuted

		local prod = owner and EconomyPreview.productionOf(province, owner, WorldConstants, nil, 0) or {}
		local goodsList = EconomyPreview.formatProductionList(prod, nil, 4)
		if #goodsList > 0 then
			goodsRow.Text = "Goods: " .. table.concat(goodsList, ", ") .. " / day"
			goodsRow.Visible = true
		else
			goodsRow.Text = ""
			goodsRow.Visible = false
		end

		panel.Visible = true
		ensureFollow()
	end

	local function showWater(name, bodyType)
		if headerLabel then headerLabel.Text = bodyType or "Waters" end
		setLandRowsVisible(false)
		nameRow.Text = name or "Open Water"
		panel.Visible = true
		ensureFollow()
	end

	local function hide()
		panel.Visible = false
		if followConn then
			followConn:Disconnect()
			followConn = nil
		end
	end

	return {
		root = panel,
		show = showProvince,
		showWater = showWater,
		hide = hide,
	}
end

return ProvinceTooltip
