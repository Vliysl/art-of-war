local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")

local ScreenKit = require(script.Parent.ScreenKit)
local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Responsive = DesignSystem.Responsive
local Components = script.Parent.Parent.Components
local Button = require(Components.Button)
local Slider = require(Components.Slider)
local WorldConstants = require(script.Parent.Parent.Parent.Shared.WorldConstants)
local ClientSignals = require(script.Parent.Parent.Parent.Modules.ClientSignals)

local SettingsScreen = {}

local testCounter = 0

local TABS = {
	{ key = "general", label = "General" },
	{ key = "controls", label = "Controls" },
	{ key = "test", label = "Test Mode" },
}

local MENU_KEYS = {
	{ "Politics", "1" },
	{ "Economy", "2" },
	{ "Military", "3" },
	{ "Diplomacy", "4" },
	{ "Research", "5" },
	{ "Missions", "6" },
	{ "Settings", "7" },
}

local CONTROL_KEYS = {
	{ "Pause / Resume", "Space" },
	{ "Close Panel", "Esc" },
	{ "Settings", "Gear" },
}

local function toggleRow(parent, label, getValue, setValue, order)
	local row = Instance.new("Frame")
	row.Name = label
	row.Size = UDim2.new(1, 0, 0, Responsive.tapHeight(40))
	row.BackgroundTransparency = 1
	row.LayoutOrder = order
	row.Parent = parent

	local text = Instance.new("TextLabel")
	text.Size = UDim2.new(1, -100, 1, 0)
	text.BackgroundTransparency = 1
	text.Text = label
	text.TextColor3 = Colors.TextSecondary
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Center
	Typography.apply(text, "bodyMd")
	text.Parent = row

	local btn
	btn = Button.create({
		parent = row,
		variant = "secondary",
		text = getValue() and "On" or "Off",
		onClick = function()
			local nv = not getValue()
			setValue(nv)
			local lbl = btn:FindFirstChild("Label")
			if lbl then
				lbl.Text = nv and "On" or "Off"
			end
		end,
	})
	btn.AnchorPoint = Vector2.new(1, 0.5)
	btn.Position = UDim2.fromScale(1, 0.5)
end

local function sliderRow(parent, label, getValue, setValue, minV, maxV, order, formatFn)
	local row = Instance.new("Frame")
	row.Name = label
	row.Size = UDim2.new(1, 0, 0, Responsive.tapHeight(54))
	row.BackgroundTransparency = 1
	row.LayoutOrder = order
	row.Parent = parent

	local text = Instance.new("TextLabel")
	text.Size = UDim2.new(1, -76, 0, 20)
	text.BackgroundTransparency = 1
	text.Text = label
	text.TextColor3 = Colors.TextSecondary
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Center
	Typography.apply(text, "bodyMd")
	text.Parent = row

	local valueLabel = Instance.new("TextLabel")
	valueLabel.Name = "Value"
	valueLabel.AnchorPoint = Vector2.new(1, 0)
	valueLabel.Position = UDim2.fromScale(1, 0)
	valueLabel.Size = UDim2.new(0, 72, 0, 20)
	valueLabel.BackgroundTransparency = 1
	valueLabel.TextColor3 = Colors.TextPrimary
	valueLabel.TextXAlignment = Enum.TextXAlignment.Right
	valueLabel.TextYAlignment = Enum.TextYAlignment.Center
	Typography.apply(valueLabel, "bodyMd")
	valueLabel.Parent = row

	local function fmt(v)
		return formatFn and formatFn(v) or tostring(math.floor(v + 0.5))
	end
	valueLabel.Text = fmt(getValue())

	local holder = Instance.new("Frame")
	holder.Name = "SliderHolder"
	holder.AnchorPoint = Vector2.new(0, 1)
	holder.Position = UDim2.fromScale(0, 1)
	holder.Size = UDim2.new(1, 0, 0, 20)
	holder.BackgroundTransparency = 1
	holder.Parent = row

	Slider.create({
		parent = holder,
		min = minV,
		max = maxV,
		value = getValue(),
		onChange = function(v)
			setValue(v)
			valueLabel.Text = fmt(v)
		end,
	})
end

function SettingsScreen.create(ctx)
	local lp = Players.LocalPlayer
	local handle

	local renderers = {
		general = function(body)
			ScreenKit.section(body, "Display & Sound", 1)
			toggleRow(body, "Sound", function()
				return not (lp and lp:GetAttribute("SoundMuted"))
			end, function(on)
				if lp then
					lp:SetAttribute("SoundMuted", not on)
				end
			end, 2)
			toggleRow(body, "Reduce Motion", function()
				return lp and lp:GetAttribute("ReduceMotion") == true
			end, function(on)
				if lp then
					lp:SetAttribute("ReduceMotion", on)
				end
			end, 3)

			ScreenKit.section(body, "Graphics", 10)
			ScreenKit.note(
				body,
				"Lower render distance hides far-off map tiles for better performance on weaker devices.",
				11
			)
			sliderRow(body, "Render Distance", function()
				return (lp and lp:GetAttribute("RenderDistance")) or WorldConstants.RenderDistanceMax
			end, function(v)
				if lp then
					lp:SetAttribute("RenderDistance", v)
				end
			end, WorldConstants.RenderDistanceMin, WorldConstants.RenderDistanceMax, 12, function(v)
				if v >= WorldConstants.RenderDistanceMax then
					return "Max"
				end
				local span = WorldConstants.RenderDistanceMax - WorldConstants.RenderDistanceMin
				local p = span > 0 and math.floor((v - WorldConstants.RenderDistanceMin) / span * 100 + 0.5) or 0
				return p .. "%"
			end)

			ScreenKit.section(body, "Controls", 13)
			toggleRow(body, "Invert Map Drag", function()
				return lp == nil or lp:GetAttribute("InvertDrag") ~= false
			end, function(on)
				if lp then
					lp:SetAttribute("InvertDrag", on)
				end
			end, 14)

			ScreenKit.section(body, "Map Mode", 4)
			ScreenKit.note(body, "Switch between commanding the map and walking your ruler across it.", 5)
			local row = ScreenKit.buttonRow(body, 6)
			Button.create({
				parent = row,
				variant = "secondary",
				text = "Command",
				onClick = function()
					if ctx.fire then
						ctx.fire("SetMapMode", "command")
					end
				end,
			})
			Button.create({
				parent = row,
				variant = "ghost",
				text = "Field",
				onClick = function()
					if ctx.fire then
						ctx.fire("SetMapMode", "field")
					end
				end,
			})

			-- Map Editor access. OFF the Map Editor place: authorized editors (MapEditorAuthorized, stamped
			-- server-side place-independently) get a Teleport button. ON the Map Editor place: authorized editors
			-- (IsAdmin = the effective, place-gated access) get an Open Data Editor button (same as the \ key).
			if lp then
				local onMapPlace = game.PlaceId == WorldConstants.MapEditorPlaceId
				if not onMapPlace and lp:GetAttribute("MapEditorAuthorized") == true then
					ScreenKit.section(body, "Map Editor", 30)
					ScreenKit.note(body, "Enter the dedicated Map Editor place to edit the official world map.", 31)
					local meRow = ScreenKit.buttonRow(body, 32)
					Button.create({
						parent = meRow,
						variant = "primary",
						text = "Teleport to Map Editor",
						onClick = function()
							local ok, err = pcall(function()
								TeleportService:Teleport(WorldConstants.MapEditorPlaceId, lp)
							end)
							if not ok then
								warn("[Settings] Map Editor teleport failed: " .. tostring(err))
							end
						end,
					})
				elseif onMapPlace and lp:GetAttribute("IsAdmin") == true then
					ScreenKit.section(body, "Map Editor", 30)
					ScreenKit.note(body, "Open the Data Editor to edit the world map. (Shortcut: the \\ key.)", 31)
					local meRow = ScreenKit.buttonRow(body, 32)
					Button.create({
						parent = meRow,
						variant = "primary",
						text = "Open Data Editor",
						onClick = function()
							ClientSignals.fire("OpenDataEditor")
						end,
					})
				end
			end
		end,
		controls = function(body)
			ScreenKit.section(body, "Menus", 1)
			for i, entry in ipairs(MENU_KEYS) do
				ScreenKit.stat(body, { label = entry[1], value = entry[2], mono = true, layoutOrder = 1 + i })
			end
			ScreenKit.section(body, "Controls", 20)
			for i, entry in ipairs(CONTROL_KEYS) do
				ScreenKit.stat(body, { label = entry[1], value = entry[2], mono = true, layoutOrder = 20 + i })
			end
			ScreenKit.note(body, "Key rebinding is not yet available.", 40)
		end,
		test = function(body)
			local Hud = require(script.Parent.Parent.Hud)
			ScreenKit.section(body, "Event Notifications", 1)
			ScreenKit.note(
				body,
				"Spawn a sample political event to preview the \"!\" alert and the draggable event window. Client-side preview only \u{2014} it does not affect your nation.",
				2
			)

			local function spawn(title, bodyText, options)
				testCounter += 1
				Hud.showEventAlert({
					eventId = "test_event_" .. testCounter,
					title = title,
					body = bodyText,
					options = options,
					onChoose = function(optionId)
						Hud.notify({ kind = "info", title = "Test event", body = "You chose: " .. tostring(optionId) })
						task.defer(function()
							Hud.hideEventAlert()
						end)
					end,
				})
			end

			local r1 = ScreenKit.buttonRow(body, 3)
			Button.create({
				parent = r1,
				variant = "primary",
				text = "Estate Demand (3 options)",
				onClick = function()
					spawn(
						"A Demand from the Clergy",
						"The clergy grow restless and press the ruler to confirm their ancient privileges. Concede, and they will be loyal but emboldened; refuse, and resentment will simmer.",
						{
							{ id = "grant", label = "Grant their privileges", tooltip = "+Loyalty and +Influence for the estate, \u{2212}Crown Authority." },
							{ id = "refuse", label = "Refuse them", tooltip = "\u{2212}Loyalty and rising Unrest, but you keep (and gain) Authority." },
							{ id = "bribe", label = "Buy them off with gold", tooltip = "Spend from the treasury to keep the peace without conceding power." },
						}
					)
				end,
			})

			local r2 = ScreenKit.buttonRow(body, 4)
			Button.create({
				parent = r2,
				variant = "secondary",
				text = "Enlightenment (2 options)",
				onClick = function()
					spawn(
						"The Spirit of the Age",
						"Fashionable salons buzz with the new philosophy. The ruler may patronise the philosophes and ride the tide of reason \u{2014} at the cost of clerical goodwill.",
						{
							{ id = "embrace", label = "Patronise the philosophes", tooltip = "The philosophes warm to you; the clergy bristle." },
							{ id = "rebuke", label = "Stand with the Church", tooltip = "The clergy approve; the philosophes are disappointed." },
						}
					)
				end,
			})

			local r3 = ScreenKit.buttonRow(body, 5)
			Button.create({
				parent = r3,
				variant = "ghost",
				text = "Clear notification",
				onClick = function()
					Hud.hideEventAlert()
				end,
			})
		end,
	}

	local currentTab = "general"
	local function render(tab)
		currentTab = tab
		handle.clearBody()
		local fn = renderers[tab] or renderers.general
		fn(handle.body)
	end

	handle = ScreenKit.open(ctx, {
		name = "SettingsScreen",
		title = "Settings",
		tabs = TABS,
		activeTab = "general",
		onTab = function(key)
			render(key)
		end,
	})
	render("general")

	-- The Map Editor button appears/disappears with the player's editor access; refresh the general tab live
	-- if it flips (MapEditorAuthorized drives the Teleport button off-place; IsAdmin drives the Open Data
	-- Editor button on the Map Editor place, and lands a few seconds after joining once the config resolves).
	local attrConns = {}
	if lp then
		local function refreshGeneral()
			if currentTab == "general" then
				render("general")
			end
		end
		attrConns[#attrConns + 1] = lp:GetAttributeChangedSignal("MapEditorAuthorized"):Connect(refreshGeneral)
		attrConns[#attrConns + 1] = lp:GetAttributeChangedSignal("IsAdmin"):Connect(refreshGeneral)
	end

	return {
		root = handle.root,
		destroy = function()
			for _, c in ipairs(attrConns) do
				c:Disconnect()
			end
			handle.destroy()
		end,
	}
end

return SettingsScreen
