-- FormablesScreen — the reachable "Nation" goal screen (formerly the cut Missions screen). Lists the
-- formable identities the player can work toward, with per-goal territory progress and a one-tap Form when
-- eligible. Reachable on desktop via hotkey 6 (Hud SCREEN_MODULES.Formables) and on touch via the crest ->
-- Realm -> "Nation" tab (RealmScreen mounts FormablesScreen.mount). The Releasable Nations section (spawn a
-- breakaway from your releasable cores) is appended by the release workstream.
--
-- Progress and eligibility come from FormablesClient.progress / FormableRules, the SAME threshold logic the
-- server's FormableSystem.canForm uses, so the bar and the button never disagree. Forming keeps the player's
-- own tag and adopts the formable's identity (name/colour/crest) — it is not a new country.

local ScreenKit = require(script.Parent.ScreenKit)
local Components = script.Parent.Parent.Components
local Button = require(Components.Button)
local CountryBadge = require(Components.CountryBadge)
local DesignSystem = require(script.Parent.Parent.Parent.DesignSystem)
local Colors = DesignSystem.Colors
local Typography = DesignSystem.Typography
local aow = script.Parent.Parent.Parent -- ArtOfWar
local FormablesClient = require(aow.Modules.FormablesClient)
local WorldConstants = require(aow.Shared.WorldConstants)
local WorldEventLog = require(aow.Modules.WorldEventLog)
local FormableRules = require(aow.Shared.FormableRules)

local FormablesScreen = {}

-- Difficulty bands by how many provinces the goal needs (P4: many early wins, a few mid, rare trophies).
local function tierOf(need)
	if need <= 15 then
		return 1, "Early Goals"
	elseif need <= 40 then
		return 2, "Major Goals"
	end
	return 3, "Grand Ambitions"
end

-- One formable goal row: crest + name, a progress bar, a "held / need" (or reason) line, and a Form button
-- when the threshold is met. Built from primitives (not StatRow) so the progress bar and crest fit cleanly.
local function formableRow(parent, entry, ctx, order)
	local def = entry.def
	-- A formable with a description gets a taller row so the flavor line has its own space above the bar.
	local hasDesc = type(def.description) == "string" and def.description ~= ""
	local barY, statusY = (hasDesc and 40 or 30), (hasDesc and 48 or 38)
	local row = Instance.new("Frame")
	row.Name = "Formable_" .. entry.tag
	row.Size = UDim2.new(1, 0, 0, hasDesc and 64 or 54)
	row.BackgroundColor3 = Colors.SurfaceSunken or Colors.SurfaceBase
	row.BorderSizePixel = 0
	row.LayoutOrder = order
	row.Parent = parent
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 5)
	pad.PaddingRight = UDim.new(0, 5)
	pad.Parent = row

	CountryBadge.create({
		parent = row,
		code = entry.tag,
		countryColor = def.color,
		flag = def.flag,
		square = true,
		px = 44,
	}).Position = UDim2.fromScale(0, 0.08)

	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.Position = UDim2.fromOffset(52, hasDesc and 4 or 6)
	name.Size = UDim2.new(1, -52 - 110, 0, 18)
	name.Text = def.displayName or entry.tag
	name.TextColor3 = Colors.TextPrimary
	name.TextXAlignment = Enum.TextXAlignment.Left
	Typography.apply(name, "bodyMd")
	name.Parent = row

	if hasDesc then
		local desc = Instance.new("TextLabel")
		desc.BackgroundTransparency = 1
		desc.Position = UDim2.fromOffset(52, 22)
		desc.Size = UDim2.new(1, -52 - 110, 0, 14)
		desc.Text = def.description
		desc.TextColor3 = Colors.TextTertiary or Colors.TextSecondary
		desc.TextXAlignment = Enum.TextXAlignment.Left
		desc.TextTruncate = Enum.TextTruncate.AtEnd
		Typography.apply(desc, "bodySm")
		desc.Parent = row
	end

	-- Progress bar: fill = held / need, clamped. Green when the threshold is met, accent while in progress.
	local barBg = Instance.new("Frame")
	barBg.Position = UDim2.fromOffset(52, barY)
	barBg.Size = UDim2.new(1, -52 - 110, 0, 6)
	barBg.BackgroundColor3 = Colors.SurfaceBase or Colors.SurfaceElevated
	barBg.BorderSizePixel = 0
	barBg.Parent = row
	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(1, 0)
	barCorner.Parent = barBg
	local frac = (entry.need > 0) and math.clamp(entry.held / entry.need, 0, 1) or 0
	local barFill = Instance.new("Frame")
	barFill.Size = UDim2.fromScale(frac, 1)
	barFill.BackgroundColor3 = entry.ready and Colors.Positive or Colors.Accent
	barFill.BorderSizePixel = 0
	barFill.Parent = barBg
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = barFill

	local status = Instance.new("TextLabel")
	status.BackgroundTransparency = 1
	status.Position = UDim2.fromOffset(52, statusY)
	status.Size = UDim2.new(1, -52 - 110, 0, 14)
	status.Text = entry.reason
	status.TextColor3 = entry.ready and Colors.Positive or Colors.TextSecondary
	status.TextXAlignment = Enum.TextXAlignment.Left
	Typography.apply(status, "bodySm")
	status.Parent = row

	if entry.ready then
		local btn = Button.create({
			parent = row,
			variant = "primary",
			text = "Form",
			width = 96,
			size = "sm",
			onClick = function()
				ctx.fire("FormNation", entry.tag)
			end,
		})
		btn.AnchorPoint = Vector2.new(1, 0.5)
		btn.Position = UDim2.new(1, -4, 0.5, 0)
	end
	return row
end

-- Collect the formables this player can see, with progress. Filters: former-tag whitelist, not-already-a-
-- live-country, one-time formed guard (formedTags), and secret defs (hidden until the land is fully held).
local function collect(ctx)
	local eligible = {}
	local mine = ctx.tag and ctx.cache and ctx.cache.getCountry(ctx.tag)
	for tag, def in pairs(FormablesClient.getAll()) do
		local formerOk = not (type(def.formerTags) == "table" and #def.formerTags > 0)
			or (ctx.tag and table.find(def.formerTags, ctx.tag) ~= nil)
		local exists = ctx.cache and ctx.cache.getCountry(tag)
		-- One-time guard: once you've formed it, drop it (server refuses a re-form; the button would no-op).
		local alreadyFormed = mine and mine.formedTags and mine.formedTags[tag]
		if def.canForm ~= false and formerOk and not exists and not alreadyFormed then
			local held, total, need, ready = FormablesClient.progress(ctx.cache, ctx.tag, def)
			-- Skip skeleton defs whose territory hasn't been authored yet (total == 0): they'd read as broken.
			-- Secret formables surface only once you already hold the full territory; the rest show as goals.
			if total > 0 and (ready or not def.secret) then
				local reason
				if ready then
					reason = "Ready to form"
				else
					reason = string.format("%d / %d provinces held", held, need)
				end
				eligible[#eligible + 1] = {
					tag = tag,
					def = def,
					held = held,
					total = total,
					need = need,
					ready = ready,
				}
				eligible[#eligible].reason = reason
			end
		end
	end
	table.sort(eligible, function(a, b)
		if a.ready ~= b.ready then
			return a.ready -- ready-to-form first
		end
		return (a.def.displayName or a.tag) < (b.def.displayName or b.tag)
	end)
	return eligible
end

-- Render the formables list into `body`, grouped by difficulty tier. Returns the next free layout order so
-- the Releasable Nations section (release workstream) can append below.
function FormablesScreen.renderFormables(body, ctx, startOrder)
	local order = startOrder or 0
	if not WorldConstants.EnableFormables then
		order += 1
		ScreenKit.note(body, "Forming nations is not enabled.", order)
		return order
	end
	local eligible = collect(ctx)
	if #eligible == 0 then
		order += 1
		ScreenKit.section(body, "Formable Nations", order)
		order += 1
		ScreenKit.note(body, "No formable nations available to you yet. Expand your realm toward a goal's territory.", order)
		return order
	end
	-- Group under tier headers (only tiers with entries appear).
	local lastTier = nil
	for _, e in ipairs(eligible) do
		local tier, tierLabel = tierOf(e.need)
		if tier ~= lastTier then
			lastTier = tier
			order += 1
			ScreenKit.section(body, tierLabel, order)
		end
		order += 1
		formableRow(body, e, ctx, order)
	end
	return order
end

-- ── Releasable Nations (spawn a breakaway from your Releasable Cores) ────────────────────────────────────
-- Distinct from forming: releasing creates a REAL new nation on the provinces you hold that list it as a
-- releasable core (server: DiplomacySystem.releaseNation). Eligibility is computed client-side from the
-- replicated province cache in a single pass; the province count is the "what you hand over" preview.

local function collectReleasables(ctx)
	local mine = ctx.tag
	if not (mine and ctx.cache and ctx.cache.allProvinces) then
		return {}
	end
	local provinces = ctx.cache.allProvinces() or {}
	local ownedTags, candidate = {}, {}
	for _, p in pairs(provinces) do
		if p.ownerTag then
			ownedTags[p.ownerTag] = true -- any tag that owns land is "alive" and cannot be released
		end
		if p.ownerTag == mine and type(p.releasableCores) == "table" then
			for _, relTag in ipairs(p.releasableCores) do
				candidate[relTag] = (candidate[relTag] or 0) + 1
			end
		end
	end
	local out = {}
	for relTag, count in pairs(candidate) do
		if relTag ~= mine and relTag ~= "NONE" and not ownedTags[relTag] then
			out[#out + 1] = { tag = relTag, count = count }
		end
	end
	local function nameOf(tag)
		local rec = ctx.cache.getCountry(tag)
		return (rec and rec.displayName) or tag
	end
	table.sort(out, function(a, b)
		return nameOf(a.tag) < nameOf(b.tag)
	end)
	return out
end

local function releasableRow(parent, entry, ctx, order)
	local rec = ctx.cache and ctx.cache.getCountry(entry.tag)
	local row = Instance.new("Frame")
	row.Name = "Releasable_" .. entry.tag
	row.Size = UDim2.new(1, 0, 0, 54)
	row.BackgroundColor3 = Colors.SurfaceSunken or Colors.SurfaceBase
	row.BorderSizePixel = 0
	row.LayoutOrder = order
	row.Parent = parent
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 5)
	pad.PaddingRight = UDim.new(0, 5)
	pad.Parent = row

	CountryBadge.create({
		parent = row,
		code = entry.tag,
		countryColor = rec and rec.color,
		flag = rec and rec.flagAssetId,
		square = true,
		px = 44,
	}).Position = UDim2.fromScale(0, 0.08)

	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.Position = UDim2.fromOffset(52, 8)
	name.Size = UDim2.new(1, -52 - 150, 0, 18)
	name.Text = (rec and rec.displayName) or entry.tag
	name.TextColor3 = Colors.TextPrimary
	name.TextXAlignment = Enum.TextXAlignment.Left
	Typography.apply(name, "bodyMd")
	name.Parent = row

	-- Release "preview": how many of your provinces the breakaway would take.
	local status = Instance.new("TextLabel")
	status.BackgroundTransparency = 1
	status.Position = UDim2.fromOffset(52, 28)
	status.Size = UDim2.new(1, -52 - 150, 0, 16)
	status.Text = string.format("Frees %d province%s you hold", entry.count, entry.count == 1 and "" or "s")
	status.TextColor3 = Colors.TextSecondary
	status.TextXAlignment = Enum.TextXAlignment.Left
	Typography.apply(status, "bodySm")
	status.Parent = row

	local freeBtn = Button.create({
		parent = row,
		variant = "primary",
		text = "Free",
		width = 64,
		size = "sm",
		onClick = function()
			ctx.fire("ReleaseNation", entry.tag, false)
		end,
	})
	freeBtn.AnchorPoint = Vector2.new(1, 0.5)
	freeBtn.Position = UDim2.new(1, -4, 0.5, 0)

	local puppetBtn = Button.create({
		parent = row,
		variant = "secondary",
		text = "Puppet",
		width = 74,
		size = "sm",
		onClick = function()
			ctx.fire("ReleaseNation", entry.tag, true)
		end,
	})
	puppetBtn.AnchorPoint = Vector2.new(1, 0.5)
	puppetBtn.Position = UDim2.new(1, -72, 0.5, 0)
	return row
end

-- Append the Releasable Nations section (only when the player has any) below the formables. Returns the next
-- free layout order.
function FormablesScreen.renderReleasables(body, ctx, startOrder)
	local order = startOrder or 0
	if not WorldConstants.EnableFormables then
		return order
	end
	local list = collectReleasables(ctx)
	if #list == 0 then
		return order -- no section if nothing is releasable -- keep the screen focused on formable goals
	end
	order += 1
	ScreenKit.section(body, "Releasable Nations", order)
	order += 1
	ScreenKit.note(body, "Free a breakaway nation from provinces you hold as its releasable cores.", order)
	for _, e in ipairs(list) do
		order += 1
		releasableRow(body, e, ctx, order)
	end
	return order
end

-- Recent world events (formations / releases) so players who dismissed/missed a banner can catch up. Reads
-- the shared WorldEventLog ring buffer (populated by Hud.showSuperEvent). Only shown when non-empty.
function FormablesScreen.renderWorldEvents(body, ctx, startOrder)
	local order = startOrder or 0
	local list = WorldEventLog.getAll()
	if #list == 0 then
		return order
	end
	order += 1
	ScreenKit.section(body, "World Events", order)
	for _, e in ipairs(list) do
		order += 1
		ScreenKit.stat(body, { icon = "Star", label = e.title or "Event", layoutOrder = order })
		if e.body and e.body ~= "" then
			order += 1
			ScreenKit.note(body, e.body, order)
		end
	end
	return order
end

-- ── All-formables catalog (browse every formable, not just the eligible ones) ────────────────────────────
local function catLine(parent, text, role, color, y)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Position = UDim2.fromOffset(52, y)
	l.Size = UDim2.new(1, -52 - 8, 0, 16)
	l.Text = text
	l.TextColor3 = color
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextTruncate = Enum.TextTruncate.AtEnd
	Typography.apply(l, role)
	l.Parent = parent
	return l
end

local function catalogRow(parent, tag, def, order, records)
	local row = Instance.new("Frame")
	row.Name = "Cat_" .. tag
	row.Size = UDim2.new(1, 0, 0, 58)
	row.BackgroundColor3 = Colors.SurfaceSunken or Colors.SurfaceBase
	row.BorderSizePixel = 0
	row.LayoutOrder = order
	row.Parent = parent
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 5)
	pad.PaddingRight = UDim.new(0, 5)
	pad.Parent = row

	CountryBadge.create({
		parent = row,
		code = tag,
		countryColor = def.color,
		flag = def.flag,
		square = true,
		px = 44,
	}).Position = UDim2.fromScale(0, 0.12)

	catLine(row, def.displayName or tag, "bodyMd", Colors.TextPrimary, 4)
	local sub = (type(def.description) == "string" and def.description ~= "" and def.description)
		or FormableRules.requirementLabel(def)
	catLine(row, sub, "bodySm", Colors.TextSecondary, 22)
	local rec = records[tag]
	local recText = rec
			and string.format("\u{2605} Fastest: %s \u{00B7} %s", FormablesClient.formatDuration(rec.seconds), rec.holder or "?")
		or "Not yet formed"
	catLine(row, recText, "bodySm", rec and Colors.Positive or (Colors.TextTertiary or Colors.TextSecondary), 40)
	return row
end

-- Every formable (with territory), grouped by tier, with its fastest-time record. Read-only browsing.
function FormablesScreen.renderCatalog(body, ctx, startOrder)
	local order = startOrder or 0
	if not WorldConstants.EnableFormables then
		return order
	end
	local records = FormablesClient.getRecords()
	local list = {}
	for tag, def in pairs(FormablesClient.getAll()) do
		if FormableRules.total(def) > 0 then -- skip territory-less skeletons
			list[#list + 1] = { tag = tag, def = def, need = FormableRules.threshold(def) }
		end
	end
	table.sort(list, function(a, b)
		if a.need ~= b.need then
			return a.need < b.need
		end
		return (a.def.displayName or a.tag) < (b.def.displayName or b.tag)
	end)
	if #list == 0 then
		order += 1
		ScreenKit.note(body, "No formables defined yet.", order)
		return order
	end
	local lastTier = nil
	for _, e in ipairs(list) do
		local tier, tierLabel = tierOf(e.need)
		if tier ~= lastTier then
			lastTier = tier
			order += 1
			ScreenKit.section(body, tierLabel, order)
		end
		order += 1
		catalogRow(body, e.tag, e.def, order, records)
	end
	return order
end

-- A two-button "Available | All formables" mode switch pinned to the top of the screen.
local function renderModeToggle(parent, showAll, onSelect)
	local row = Instance.new("Frame")
	row.Name = "ModeToggle"
	row.Size = UDim2.new(1, 0, 0, 30)
	row.BackgroundTransparency = 1
	row.LayoutOrder = -1000
	row.Parent = parent
	local avail = Button.create({
		parent = row,
		variant = showAll and "ghost" or "primary",
		text = "Available",
		width = 106,
		size = "sm",
		onClick = function()
			onSelect(false)
		end,
	})
	avail.Position = UDim2.fromOffset(0, 0)
	local all = Button.create({
		parent = row,
		variant = showAll and "primary" or "ghost",
		text = "All formables",
		width = 130,
		size = "sm",
		onClick = function()
			onSelect(true)
		end,
	})
	all.Position = UDim2.fromOffset(112, 0)
end

-- Build the screen either as a standalone window (container == nil) or embedded in a host pane (RealmScreen
-- "Nation" tab). Mirrors DiplomacyScreen's build(ctx, container). Refreshes as territory replicates in.
local function build(ctx, container)
	local conns = {}
	local handle, body, root, clearBody

	if container then
		local bodyHandle = ScreenKit.body(container)
		body = bodyHandle.body
		clearBody = bodyHandle.clearBody
		root = bodyHandle.clip
	else
		local data = ctx.data or {}
		handle = ScreenKit.open(ctx, {
			name = "FormablesScreen",
			title = "Formables",
			subtitle = (data.name or "Realm") .. "  \u{00B7}  Form a new nation",
		})
		body = handle.body
		clearBody = handle.clearBody
		root = handle.root
	end

	local showAll = false
	local rebuild
	rebuild = function()
		clearBody()
		renderModeToggle(body, showAll, function(v)
			if v ~= showAll then
				showAll = v
				rebuild()
			end
		end)
		local order
		if showAll then
			order = FormablesScreen.renderCatalog(body, ctx, 0)
		else
			order = FormablesScreen.renderFormables(body, ctx, 0)
		end
		order = FormablesScreen.renderReleasables(body, ctx, order)
		FormablesScreen.renderWorldEvents(body, ctx, order)
	end
	rebuild()

	-- Live-refresh as provinces stream in / change hands so progress bars stay honest. Debounced + gated.
	if ctx.cache then
		local refresh = ScreenKit.throttle(rebuild, 0.25)
		if ctx.cache.onChangePrefix then
			table.insert(conns, ctx.cache.onChangePrefix("provinces", refresh))
			table.insert(conns, ctx.cache.onChangePrefix("countries", refresh))
		end
		if ctx.cache.onChange then
			table.insert(conns, ctx.cache.onChange("provincesReady", refresh))
		end
	end
	if FormablesClient.onChanged then
		local c = FormablesClient.onChanged(rebuild)
		if c then
			table.insert(conns, c)
		end
	end

	return {
		root = root,
		destroy = function()
			-- Cache subscriptions return a disconnect FUNCTION; FormablesClient.onChanged returns a CONNECTION.
			for _, d in conns do
				pcall(function()
					if typeof(d) == "RBXScriptConnection" then
						d:Disconnect()
					elseif type(d) == "function" then
						d()
					end
				end)
			end
			if handle then
				handle.destroy()
			elseif root then
				root:Destroy()
			end
		end,
	}
end

function FormablesScreen.create(ctx)
	return build(ctx, nil)
end

-- Embed inside `container` (a RealmScreen tab pane) with no window chrome. Returns { root, destroy }.
function FormablesScreen.mount(container, ctx)
	return build(ctx, container)
end

return FormablesScreen
