-- EventCard — the full political-event window. RoN-style: opened from the "!" alert
-- chip, it is a NON-BLOCKING (no scrim) floating window the player can DRAG around by
-- its title bar. Closing it (X) minimizes back to the alert chip (onMinimize); picking
-- an option resolves it (onChoose). ctx.data = {
--   title, body, options = { {id, label, tooltip} }, onChoose(optionId), onMinimize() }.

local UserInputService = game:GetService("UserInputService")

local Components = script.Parent.Parent.Components
local Modal = require(Components.Modal)
local Button = require(Components.Button)
local Tooltip = require(Components.Tooltip)
local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors

local EventCard = {}

function EventCard.create(ctx)
	local data = ctx.data or {}
	local options = data.options or {}
	local optionCount = #options

	-- closeReason distinguishes WHY Modal.close ran: a player choice or external teardown
	-- must NOT trigger the minimize-to-chip callback; only the X button (reason=nil) should.
	local closeReason = nil

	local modal = Modal.create({
		parent = ctx.parent or ctx.modalLayer,
		name = "EventCard",
		title = data.title or "A Decision",
		width = 440,
		height = 180 + optionCount * 46,
		floating = true,                       -- no scrim — map/HUD stay interactive
		dismissable = false,                   -- never closes from an outside click
		anchorPoint = Vector2.new(0.5, 0.5),   -- centered; the player can drag it anywhere
		position = UDim2.fromScale(0.5, 0.5),
		footer = false,
		onClose = function()
			if closeReason == "choose" or closeReason == "external" then
				return
			end
			if data.onMinimize then
				data.onMinimize()
			end
		end,
	})

	-- ── Drag the window by its title bar (pattern borrowed from MovableWindow) ──
	local panel = modal.panel
	local header = modal.header
	if header and panel then
		header.Active = true
		header.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1
				and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			local dragStart = input.Position
			local startPos = panel.Position
			local moveConn, endConn
			endConn = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					if moveConn then moveConn:Disconnect() end
					if endConn then endConn:Disconnect() end
				end
			end)
			moveConn = UserInputService.InputChanged:Connect(function(other)
				if other.UserInputType ~= Enum.UserInputType.MouseMovement
					and other.UserInputType ~= Enum.UserInputType.Touch then
					return
				end
				local delta = other.Position - dragStart
				panel.Position = UDim2.new(
					startPos.X.Scale, startPos.X.Offset + delta.X,
					startPos.Y.Scale, startPos.Y.Offset + delta.Y
				)
			end)
		end)
	end

	-- ── Content: body text + one button per option ──
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 10)
	layout.Parent = modal.content

	local body = Instance.new("TextLabel")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Size = UDim2.new(1, 0, 0, 0)
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.TextWrapped = true
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.Font = Enum.Font.Gotham
	body.TextSize = 15
	body.TextColor3 = Colors.TextPrimary
	body.Text = data.body or ""
	body.LayoutOrder = 0
	body.Parent = modal.content

	local resolved = false
	local function choose(optionId)
		if resolved then
			return
		end
		resolved = true
		closeReason = "choose"
		if data.onChoose then
			data.onChoose(optionId)
		end
		modal.close()
	end

	for i, opt in ipairs(options) do
		local btn = Button.create({
			parent = modal.content,
			variant = i == 1 and "primary" or "secondary",
			text = opt.label or opt.id,
			fill = true,
			layoutOrder = i,
			onClick = function()
				choose(opt.id)
			end,
		})
		if opt.tooltip and opt.tooltip ~= "" then
			Tooltip.attach(btn, function()
				return Tooltip.create({ title = opt.label, body = opt.tooltip, width = 250 })
			end, ctx.tooltipLayer)
		end
	end

	return {
		root = modal.root,
		destroy = function()
			closeReason = "external"
			modal.close()
		end,
	}
end

return EventCard
