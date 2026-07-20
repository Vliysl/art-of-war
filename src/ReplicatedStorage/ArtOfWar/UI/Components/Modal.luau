local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local Spacing = DesignSystem.Spacing
local Animations = DesignSystem.Animations
local Icons = DesignSystem.Icons
local Shells = DesignSystem.Shells

local Modal = {}

function Modal.create(config)
	config = config or {}
	local z = config.zIndex or 50
	local width = config.width or 540
	local heightPx = config.height or 440

	local floating = config.floating == true

	local panel = Shells.create("panel_modal_shell", {
		Name = "Window",
		AnchorPoint = floating and (config.anchorPoint or Vector2.new(1, 0)) or Vector2.new(0.5, 0.5),
		Position = floating and (config.position or UDim2.fromOffset(-8, 0)) or UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(width, heightPx),
		ZIndex = floating and (z + 5) or (z + 1),
	})

	-- Modal mode: a full-screen scrim dims + blocks input behind a centered panel. Floating mode: NO
	-- scrim -- the panel is the root, anchored to its trigger, and the map/HUD stay interactive; it
	-- dismisses via the close button + an outside-click listener (set up in open()).
	local scrim
	local root = panel
	if floating then
		panel.Name = config.name or "Modal"
	else
		scrim = Instance.new("TextButton")
		scrim.Name = config.name or "Modal"
		scrim.Size = UDim2.fromScale(1, 1)
		scrim.BackgroundColor3 = Colors.SurfaceSunken
		scrim.BackgroundTransparency = 1
		scrim.AutoButtonColor = false
		scrim.Text = ""
		scrim.Modal = true
		scrim.ZIndex = z
		scrim:SetAttribute("AoWInputSink", true)
		panel.Parent = scrim
		root = scrim
	end

	local catcher = Instance.new("TextButton")
	catcher.Name = "Catcher"
	catcher.Size = UDim2.fromScale(1, 1)
	catcher.BackgroundTransparency = 1
	catcher.AutoButtonColor = false
	catcher.Text = ""
	catcher.ZIndex = z + 1
	catcher.Parent = panel

	local header = Shells.create("panel_modal_header_shell", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, 56),
		ZIndex = z + 2,
	})
	header.Parent = panel

	local headPad = Instance.new("UIPadding")
	headPad.PaddingLeft = UDim.new(0, Spacing.space5)
	headPad.PaddingRight = UDim.new(0, Spacing.space5)
	headPad.Parent = header

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, -48, config.subtitle and 0.6 or 1, 0)
	title.Position = UDim2.fromScale(0, config.subtitle and 0.12 or 0)
	title.BackgroundTransparency = 1
	title.Text = config.title or ""
	title.TextColor3 = Colors.TextPrimary
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextYAlignment = Enum.TextYAlignment.Center
	title.ZIndex = z + 3
	Typography.apply(title, "displayLg")
	title.Parent = header

	if config.subtitle then
		local sub = Instance.new("TextLabel")
		sub.Name = "Subtitle"
		sub.AnchorPoint = Vector2.new(0, 1)
		sub.Position = UDim2.new(0, 0, 1, -8)
		sub.Size = UDim2.new(1, -48, 0, 16)
		sub.BackgroundTransparency = 1
		sub.Text = config.subtitle
		sub.TextColor3 = Colors.TextSecondary
		sub.TextXAlignment = Enum.TextXAlignment.Left
		sub.ZIndex = z + 3
		Typography.apply(sub, "bodySm")
		sub.Parent = header
	end

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "Close"
	closeBtn.AnchorPoint = Vector2.new(1, 0.5)
	closeBtn.Position = UDim2.new(1, 0, 0.5, 0)
	closeBtn.Size = UDim2.fromOffset(34, 34)
	closeBtn.BackgroundTransparency = 1
	closeBtn.AutoButtonColor = false
	closeBtn.Text = ""
	closeBtn.ZIndex = z + 3
	closeBtn.Parent = header
	local closeSlot = Shells.create("window_frame_close_slot", { Name = "Slot", ZIndex = z + 3 })
	closeSlot.Parent = closeBtn
	local x = Icons.create("Close", 20, Colors.Accent)
	x.AnchorPoint = Vector2.new(0.5, 0.5)
	x.Position = UDim2.fromScale(0.5, 0.5)
	x.ZIndex = z + 4
	x.Parent = closeBtn

	local footerHeight = config.footer and 64 or 0
	local footer
	if config.footer then
		footer = Shells.create("modal_footer_shell", {
			Name = "Footer",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, footerHeight),
			ZIndex = z + 2,
		})
		footer.Parent = panel
		local fLayout = Instance.new("UIListLayout")
		fLayout.FillDirection = Enum.FillDirection.Horizontal
		fLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
		fLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		fLayout.SortOrder = Enum.SortOrder.LayoutOrder
		fLayout.Padding = UDim.new(0, Spacing.space3)
		fLayout.Parent = footer
		local fPad = Instance.new("UIPadding")
		fPad.PaddingLeft = UDim.new(0, Spacing.space5)
		fPad.PaddingRight = UDim.new(0, Spacing.space5)
		fPad.Parent = footer
	end

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Position = UDim2.fromOffset(0, 56)
	content.Size = UDim2.new(1, 0, 1, -(56 + footerHeight))
	content.BackgroundTransparency = 1
	content.ZIndex = z + 2
	content.Parent = panel
	local cPad = Instance.new("UIPadding")
	cPad.PaddingTop = UDim.new(0, Spacing.space4)
	cPad.PaddingBottom = UDim.new(0, Spacing.space4)
	cPad.PaddingLeft = UDim.new(0, Spacing.space5)
	cPad.PaddingRight = UDim.new(0, Spacing.space5)
	cPad.Parent = content

	local outsideConn
	local function close()
		if config.onClose then
			config.onClose()
		end
		if outsideConn then
			outsideConn:Disconnect()
			outsideConn = nil
		end
		Animations.tween(panel, Animations.Fast, { Size = UDim2.fromOffset(width, heightPx - 16) })
		if scrim then
			Animations.tween(scrim, Animations.Fast, { BackgroundTransparency = 1 })
		end
		task.delay(Animations.Fast.Time, function()
			root:Destroy()
		end)
	end

	closeBtn.MouseButton1Click:Connect(close)
	closeBtn.MouseEnter:Connect(function()
		x.ImageColor3 = Colors.AccentHover
	end)
	closeBtn.MouseLeave:Connect(function()
		x.ImageColor3 = Colors.Accent
	end)
	if scrim and config.dismissable ~= false then
		scrim.MouseButton1Click:Connect(close)
	end

	local function open(parent)
		root.Parent = parent or config.parent
		panel.Size = UDim2.fromOffset(width, heightPx - 16)
		Animations.tween(panel, Animations.ModalIn, { Size = UDim2.fromOffset(width, heightPx) })
		if scrim then
			Animations.tween(scrim, Animations.ModalIn, { BackgroundTransparency = 0.4 })
		elseif config.dismissable ~= false then
			-- Outside-click dismissal for floating mode: close when a press lands outside the panel AND
			-- outside its trigger (config.keepOpenOver, e.g. the army panel), so the map stays clickable
			-- and clicking the panel or its owning panel never self-dismisses.
			local UIS = game:GetService("UserInputService")
			local Players = game:GetService("Players")
			outsideConn = UIS.InputBegan:Connect(function(input, gp)
				if gp then
					return
				end
				if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
					return
				end
				local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
				if not pg then
					return
				end
				local m = UIS:GetMouseLocation()
				local keep = config.keepOpenOver
				for _, h in ipairs(pg:GetGuiObjectsAtPosition(m.X, m.Y)) do
					if h == panel or h:IsDescendantOf(panel) or (keep and (h == keep or h:IsDescendantOf(keep))) then
						return
					end
				end
				close()
			end)
		end
	end

	-- If the panel is destroyed externally (e.g. its owning screen closes), drop the input listener.
	panel.AncestryChanged:Connect(function(_, parent)
		if not parent and outsideConn then
			outsideConn:Disconnect()
			outsideConn = nil
		end
	end)

	if config.parent then
		open(config.parent)
	end

	return {
		root = root,
		panel = panel,
		header = header,
		content = content,
		footer = footer,
		open = open,
		close = close,
	}
end

-- `content` is a plain Frame that neither clips nor scrolls, so a caller that parents a long list straight into
-- it gets rows stacked past the panel and drawn over the map (a UIListLayout never shrinks or clips its
-- children). Callers with a list that can outgrow the panel should parent into this instead: a ScrollingFrame
-- clips by default, and AutomaticCanvasSize grows the canvas to fit. Returns the scroller; parent your
-- UIListLayout and rows to IT, not to modal.content.
function Modal.scrollBody(modal)
	local list = Instance.new("ScrollingFrame")
	list.Name = "ScrollBody"
	list.Size = UDim2.fromScale(1, 1)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 4
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new() -- AutomaticCanvasSize needs a zero base to grow from
	list.ZIndex = modal.content.ZIndex
	list.Parent = modal.content
	return list
end

return Modal
