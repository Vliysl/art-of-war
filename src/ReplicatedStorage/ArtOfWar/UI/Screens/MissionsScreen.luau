local ScreenKit = require(script.Parent.ScreenKit)
local Components = script.Parent.Parent.Components
local Button = require(Components.Button)
local aow = script.Parent.Parent.Parent -- ArtOfWar
local FormablesClient = require(aow.Modules.FormablesClient)
local WorldConstants = require(aow.Shared.WorldConstants)

local MissionsScreen = {}

-- Does `tag` own every province in `ids`? (client-side eligibility from the replicated cache)
local function ownsAll(cache, tag, ids)
	if not cache or not tag or not ids or #ids == 0 then
		return false
	end
	for _, id in ipairs(ids) do
		local p = cache.getProvince(id)
		if not p or p.ownerTag ~= tag then
			return false
		end
	end
	return true
end

function MissionsScreen.create(ctx)
	local data = ctx.data or {}
	local groups = (data.missions and data.missions.groups) or {}
	local handle

	-- Formable nations (Phase 4) live under Missions: hold a formable's full territory, then form it.
	local function renderFormables(body, startOrder)
		if not WorldConstants.EnableFormables then
			return startOrder
		end
		local eligible = {}
		for tag, def in pairs(FormablesClient.getAll()) do
			-- former-tag whitelist: if the def names formerTags, only those countries may form it (empty = any)
			local formerOk = not (type(def.formerTags) == "table" and #def.formerTags > 0)
				or (ctx.tag and table.find(def.formerTags, ctx.tag) ~= nil)
			if def.canForm ~= false
				and formerOk
				and not (ctx.cache and ctx.cache.getCountry(tag))
				and ownsAll(ctx.cache, ctx.tag, def.requiredProvinceIds) then
				eligible[#eligible + 1] = { tag = tag, def = def }
			end
		end
		table.sort(eligible, function(a, b)
			return (a.def.displayName or a.tag) < (b.def.displayName or b.tag)
		end)

		local order = startOrder
		order += 1
		ScreenKit.section(body, "Formable Nations", order)
		if #eligible == 0 then
			order += 1
			ScreenKit.note(body, "No nations can be formed yet \u{2014} hold a formable's full territory to unlock it.", order)
			return order
		end
		for _, e in ipairs(eligible) do
			order += 1
			local row = ScreenKit.stat(body, { icon = "Star", label = e.def.displayName or e.tag, layoutOrder = order })
			local btn = Button.create({
				parent = row,
				variant = "primary",
				text = "Form",
				width = 96,
				size = "sm",
				onClick = function()
					ctx.fire("FormNation", e.tag)
				end,
			})
			btn.AnchorPoint = Vector2.new(1, 0.5)
			btn.Position = UDim2.fromScale(1, 0.5)
		end
		return order
	end

	local function renderBody(body)
		local order = 0
		if #groups == 0 then
			ScreenKit.note(body, "No active mission trees. Objectives will appear here as your realm grows.", 1)
			order = 1
		else
			for _, group in ipairs(groups) do
				order += 1
				ScreenKit.section(body, group.name or "Missions", order)
				for _, mission in ipairs(group.missions or {}) do
					order += 1
					local done = mission.done == true
					ScreenKit.stat(body, {
						parent = body,
						icon = done and "Check" or "Bookmark",
						iconColor = done and "positive" or "secondary",
						label = mission.name or "Mission",
						value = done and "Complete" or (mission.progress and mission.progress .. "%") or "",
						valueColor = done and "positive" or nil,
						layoutOrder = order,
					})
					if mission.desc then
						order += 1
						ScreenKit.note(body, mission.desc, order)
					end
				end
			end
		end
		renderFormables(body, order + 100)
	end

	handle = ScreenKit.open(ctx, {
		name = "MissionsScreen",
		title = "Missions",
		subtitle = (data.name or "Realm") .. "  \u{00B7}  Objectives",
	})
	renderBody(handle.body)
	return handle
end

return MissionsScreen
