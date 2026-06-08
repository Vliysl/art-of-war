local EntrenchmentSystem = {}

local ctx

local function onDateAdvanced(payload)
	local days = payload and payload.daysAdvanced or 1
	local gain = (ctx.WorldConstants.CombatEntrenchmentDailyGain or 0.25) * days
	if gain <= 0 then return end
	for armyId, army in ctx.WorldState.allArmies() do
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
