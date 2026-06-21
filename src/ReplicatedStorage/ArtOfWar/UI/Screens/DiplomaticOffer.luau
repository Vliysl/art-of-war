-- DiplomaticOffer: the accept/decline modal a player sees when another nation directs a pending pact
-- at them. Handles non-aggression pacts, alliance proposals, and call-to-arms (an ally/guarantor being
-- summoned to a war). Guarantees are unilateral + instant so they never produce a pending offer.
-- Opened by HudWiring when a Pending pacts record targets the local player. Mirrors TradeOffer.

local ScreenKit = require(script.Parent.ScreenKit)
local Components = script.Parent.Parent.Components
local Modal = require(Components.Modal)
local Button = require(Components.Button)
local SectionDivider = require(Components.SectionDivider)

local DiplomaticOffer = {}

local PACT_LABEL = {
	nap = "Non-Aggression Pact",
	guarantee = "Guarantee of Independence",
	alliance = "Alliance",
	call_to_arms = "Call to Arms",
}

function DiplomaticOffer.create(ctx)
	local pact = ctx.data or {}
	local pactType = pact.type or "nap"

	local function nationName(tag)
		local country = ctx.cache and ctx.cache.getCountry(tag)
		return (country and country.displayName) or tag or "?"
	end

	local label = PACT_LABEL[pactType] or "Diplomatic Pact"
	local subtitle
	if pactType == "call_to_arms" then
		subtitle = string.format("%s calls you to arms!", nationName(pact.fromTag))
	else
		subtitle = string.format(
			"%s proposes a%s %s",
			nationName(pact.fromTag),
			label:match("^[AEIOU]") and "n" or "",
			label:lower()
		)
	end

	local modal = Modal.create({
		parent = ctx.parent,
		title = label,
		subtitle = subtitle,
		width = 460,
		height = 380,
		footer = true,
		dismissable = false,
		onClose = ctx.onClose,
	})

	local body = Instance.new("ScrollingFrame")
	body.Size = UDim2.fromScale(1, 1)
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.ScrollBarThickness = 4
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.CanvasSize = UDim2.new()
	body.Parent = modal.content
	local pad = Instance.new("UIPadding")
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = body
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = body

	SectionDivider.create({ parent = body, label = "Terms", layoutOrder = 1 })
	if pactType == "nap" then
		local years = math.max(1, math.floor((pact.durationDays or 3650) / 365 + 0.5))
		ScreenKit.stat(body, {
			icon = "Core",
			label = "Duration",
			value = string.format("%d years", years),
			mono = true,
			layoutOrder = 2,
		})
		ScreenKit.note(
			body,
			"Neither side may declare war on the other while the pact holds. Breaking it early angers both peoples.",
			3
		)
	elseif pactType == "alliance" then
		ScreenKit.note(
			body,
			"A mutual-defence alliance. If either of you is attacked, the other is called to arms. Breaking it is a grave betrayal.",
			2
		)
	elseif pactType == "call_to_arms" then
		ScreenKit.stat(body, { icon = "Core", label = "Enemy", value = nationName(pact.aggressorTag), layoutOrder = 2 })
		local why = (pact.obligation == "guarantee") and "You guaranteed their independence." or "They are your ally."
		ScreenKit.note(
			body,
			string.format(
				"%s is at war with %s. %s Join the war, or refuse and break the bond.",
				nationName(pact.fromTag),
				nationName(pact.aggressorTag),
				why
			),
			3
		)
	else
		ScreenKit.note(body, "Review the proposed pact.", 2)
	end

	local function finish(remote)
		if pact.id then
			ctx.fire(remote, pact.id)
		end
		modal.close()
	end

	Button.create({
		parent = modal.footer,
		variant = "danger",
		text = pactType == "call_to_arms" and "Refuse" or "Decline",
		layoutOrder = 1,
		onClick = function()
			finish("RejectPact")
		end,
	})
	Button.create({
		parent = modal.footer,
		variant = "success",
		text = pactType == "call_to_arms" and "Join War" or "Accept",
		layoutOrder = 2,
		onClick = function()
			finish("AcceptPact")
		end,
	})

	return modal
end

return DiplomaticOffer
