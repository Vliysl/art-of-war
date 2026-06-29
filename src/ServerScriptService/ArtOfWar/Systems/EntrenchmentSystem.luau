local EntrenchmentSystem = {}

local ctx

local function onDateAdvanced(payload)
	local days = payload and payload.daysAdvanced or 1
	local gain = (ctx.WorldConstants.CombatEntrenchmentDailyGain or 0.25) * days
	if gain <= 0 then return end
	-- perf: iterate ArmySystem.idleArmies() (the sparse idle subset) instead of every army when the
	-- index is enabled. The index may over-include, so the existing early-skip and the getState()
	-- authority check below are kept verbatim -- results are identical, the loop is just narrower.
	local function processArmy(armyId, army)
		-- cheaply skip armies that are definitely non-idle before the heavier getState()
		-- (which can resolve battles). These conditions each guarantee getState() ~= "idle",
		-- so results stay identical. battleId alone is NOT skipped (may not resolve to a
		-- battle -> falls through).
		if army.movement or army.retreating or (army.state and army.state ~= "idle") then
			return
		end
		local state = ctx.ArmySystem.getState(armyId)
		if state == "idle" then
			ctx.ArmySystem.setEntrenchment(armyId, (army.entrenchment or 0) + gain)
		end
	end
	if ctx.WorldConstants.UseArmyMembershipIndex and ctx.ArmySystem and ctx.ArmySystem.idleArmies then
		for armyId, army in ctx.ArmySystem.idleArmies() do
			processArmy(armyId, army)
		end
	else
		for armyId, army in ctx.WorldState.allArmies() do
			processArmy(armyId, army)
		end
	end
end

function EntrenchmentSystem.register(context)
	ctx = context
	context.EntrenchmentSystem = EntrenchmentSystem
	context.EventBus.subscribe(context.Channels.DateAdvanced, onDateAdvanced)
end

return EntrenchmentSystem
