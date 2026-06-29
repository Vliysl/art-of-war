local EntrenchmentSystem = {}

local ctx

local function onDateAdvanced(payload)
	local days = payload and payload.daysAdvanced or 1
	local gain = (ctx.WorldConstants.CombatEntrenchmentDailyGain or 0.25) * days
	if gain <= 0 then return end
	for armyId, army in ctx.WorldState.allArmies() do
		-- perf: cheaply skip armies that are definitely non-idle before the
		-- heavier getState() (which can resolve battles). These conditions each
		-- guarantee getState() ~= "idle", so results stay identical. battleId
		-- alone is NOT skipped (may not resolve to a battle -> falls through).
		if army.movement or army.retreating or (army.state and army.state ~= "idle") then
			continue
		end
		local state = ctx.ArmySystem.getState(armyId)
		if state == "idle" then
			ctx.ArmySystem.setEntrenchment(armyId, (army.entrenchment or 0) + gain)
		end
	end
end

function EntrenchmentSystem.register(context)
	ctx = context
	context.EntrenchmentSystem = EntrenchmentSystem
	context.EventBus.subscribe(context.Channels.DateAdvanced, onDateAdvanced)
end

return EntrenchmentSystem
