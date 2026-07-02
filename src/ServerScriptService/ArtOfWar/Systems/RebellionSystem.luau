-- RebellionSystem (Phase 4): when a country's unrest boils over, a breakaway nation seizes territory.
--
-- This is the module EventSystem (effects.spawnRebellion) and UnrestSystem (RebellionTriggered) already
-- call -- it didn't exist before. v1 model = a direct breakaway SEIZURE (no fought rebel war): if the
-- parent fully holds a releasable's homeland that includes the revolt province, that releasable is FORMED
-- (takes all its core provinces); otherwise a generic REB_ nation takes the single worst-unrest province.
-- Then the parent's unrest is vented and a cooldown set so it can't immediately re-trigger. Gated by
-- WorldConstants.EnableRebellions. (A fought rebel war with rebel armies + AI is a future refinement.)

local RebellionSystem = {}

local ctx
local rebSeq = 0

local function currentDay()
	local d = ctx.TickScheduler.getGameDate()
	return (d.year - 1) * 365 + (d.month - 1) * 30 + d.day
end

-- The parent's highest-unrest owned province (fallback: first owned). Returns id or nil.
local function pickRevoltProvince(parentTag)
	local ids = ctx.ProvinceRegistry and ctx.ProvinceRegistry.byOwner(parentTag)
	if not ids or #ids == 0 then
		return nil
	end
	local bestId, bestUnrest = nil, -1
	for _, id in ipairs(ids) do
		local p = ctx.WorldState.getProvince(id)
		if p and (p.unrest or 0) > bestUnrest then
			bestId, bestUnrest = id, p.unrest or 0
		end
	end
	return bestId or ids[1]
end

-- A releasable definition (not yet existing) whose homeland the parent FULLY holds and which includes
-- `provinceId`, so a rebellion can restore a real historical nation. Returns formableTag or nil.
local function matchingReleasable(parentTag, provinceId)
	if not ctx.FormableSystem then
		return nil
	end
	for tag, def in pairs(ctx.FormableSystem.allDefinitions()) do
		if
			def.canRelease ~= false
			and def.requiredProvinceIds
			and table.find(def.requiredProvinceIds, provinceId)
			and not ctx.WorldState.getCountry(tag)
		then
			local ownsAll = true
			for _, pid in ipairs(def.requiredProvinceIds) do
				local p = ctx.WorldState.getProvince(pid)
				if not p or p.ownerTag ~= parentTag then
					ownsAll = false
					break
				end
			end
			if ownsAll then
				return tag
			end
		end
	end
	return nil
end

local function transferProvince(toTag, fromTag, id)
	local p = ctx.WorldState.getProvince(id)
	if not p or p.ownerTag ~= fromTag then
		return
	end
	-- Add the rebel core on the record first so it rides the same dirty mark as the ownership flip.
	p.cores = p.cores or {}
	if not table.find(p.cores, toTag) then
		table.insert(p.cores, toTag)
	end
	if ctx.WorldConstants.RecordOwnershipChokepoint then
		ctx.WorldState.setProvinceOwnership(id, { owner = toTag, controller = toTag, reason = "rebellion" })
	else
		p.ownerTag = toTag
		p.controllerTag = toTag
		ctx.WorldState.setProvince(id, p)
		ctx.EventBus.publish(ctx.Channels.ProvinceOwnershipChanged, {
			provinceId = id,
			oldOwner = fromTag,
			newOwner = toTag,
		})
	end
end

-- Spawn a rebellion against parentTag. `kind` is a descriptor ("popular"/"noble"/estate id/...).
local function spawn(parentTag, kind, _context)
	if not ctx.WorldConstants.EnableRebellions then
		return false
	end
	if not ctx.NationFactory then
		return false
	end
	if parentTag:sub(1, 4) == "REB_" then
		return false
	end -- rebels don't rebel
	local parent = ctx.WorldState.getCountry(parentTag)
	if not parent then
		return false
	end

	local target = pickRevoltProvince(parentTag)
	if not target then
		return false
	end

	local breakawayTag, provincesToTake, opts
	local rel = matchingReleasable(parentTag, target)
	if rel then
		local def = ctx.FormableSystem.getDefinition(rel)
		local capProv = ctx.WorldState.getProvince(def.requiredProvinceIds[1])
		breakawayTag = rel
		provincesToTake = def.requiredProvinceIds
		opts = {
			displayName = def.displayName,
			color = def.color,
			flag = def.flag,
			capitalProvinceId = def.requiredProvinceIds[1],
			primaryCulture = capProv and capProv.culture,
			stateReligion = capProv and capProv.religion,
			governmentForm = parent.governmentForm,
			ideology = parent.ideology,
		}
	else
		rebSeq += 1
		local capProv = ctx.WorldState.getProvince(target)
		breakawayTag = string.format("REB_%s_%d", parentTag, rebSeq)
		provincesToTake = { target }
		opts = {
			displayName = (kind == "noble" or kind == "nobility") and "Pretenders" or "Rebels",
			color = { 90, 90, 90 },
			capitalProvinceId = target,
			primaryCulture = capProv and capProv.culture,
			stateReligion = capProv and capProv.religion,
			governmentForm = parent.governmentForm,
			ideology = parent.ideology,
		}
	end

	ctx.NationFactory.create(breakawayTag, opts)
	for _, id in ipairs(provincesToTake) do
		transferProvince(breakawayTag, parentTag, id)
	end

	-- Vent the parent's unrest + set a cooldown so it can't immediately re-trigger (UnrestSystem reads
	-- country.rebellionCooldownDay; same day metric).
	parent = ctx.WorldState.getCountry(parentTag)
	if parent then
		parent.unrest = (parent.unrest or 0) * 0.5
		parent.rebellionCooldownDay = currentDay() + (ctx.WorldConstants.RebellionCooldownDays or 365)
		ctx.WorldState.setCountry(parentTag, parent)
	end

	ctx.EventBus.publish(ctx.Channels.RebellionResolved, {
		tag = parentTag,
		breakawayTag = breakawayTag,
		kind = kind,
		provinces = provincesToTake,
	})
	return true
end

function RebellionSystem.register(context)
	ctx = context
	context.RebellionSystem = { spawn = spawn }
	if context.EventBus and context.EventBus.subscribe and context.Channels.RebellionTriggered then
		context.EventBus.subscribe(context.Channels.RebellionTriggered, function(payload)
			if not payload or not payload.tag then
				return
			end
			spawn(payload.tag, payload.estateId and "estate" or "popular", context)
		end)
	end
end

return RebellionSystem
