local Players = game:GetService("Players")

local ScreenKit = require(script.Parent.ScreenKit)
local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Spacing = DesignSystem.Spacing
local Responsive = DesignSystem.Responsive
local Components = script.Parent.Parent.Components
local Button = require(Components.Button)

local SettingsScreen = {}

local TABS = {
	{ key = "general", label = "General" },
	{ key = "controls", label = "Controls" },
}

local MENU_KEYS = {
	{ "Politics", "1" },
	{ "Economy", "2" },
	{ "Military", "3" },
	{ "Diplomacy", "4" },
	{ "Research", "5" },
	{ "Missions", "6" },
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
		width = 88,
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
	btn.Position = UDim2.new(1, 0, 0.5, 0)
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

			ScreenKit.section(body, "Map Mode", 4)
			ScreenKit.note(body, "Switch between commanding the map and walking your ruler across it.", 5)
			local row = ScreenKit.buttonRow(body, 6)
			Button.create({
				parent = row,
				variant = "secondary",
				text = "Command",
				width = 150,
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
				width = 130,
				onClick = function()
					if ctx.fire then
						ctx.fire("SetMapMode", "field")
					end
				end,
			})
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
	}

	local function render(tab)
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

	return {
		root = handle.root,
		destroy = function()
			handle.destroy()
		end,
	}
end

return SettingsScreen
