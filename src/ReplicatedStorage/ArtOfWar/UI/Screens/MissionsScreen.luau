local ScreenKit = require(script.Parent.ScreenKit)

local MissionsScreen = {}

function MissionsScreen.create(ctx)
	local data = ctx.data or {}
	local groups = (data.missions and data.missions.groups) or {}
	local handle

	local function renderBody(body)
		if #groups == 0 then
			ScreenKit.note(body, "No active mission trees. Objectives will appear here as your realm grows.", 1)
			return
		end
		local order = 0
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

	handle = ScreenKit.open(ctx, {
		name = "MissionsScreen",
		title = "Missions",
		subtitle = (data.name or "Realm") .. "  \u{00B7}  Objectives",
	})
	renderBody(handle.body)
	return handle
end

return MissionsScreen
