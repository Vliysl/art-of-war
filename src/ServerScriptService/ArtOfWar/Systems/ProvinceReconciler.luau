-- ProvinceReconciler
--
-- Boot-time safety net for province REGISTRATION. A land tile painted with an owner in the
-- Data Editor (setTileOwner -> tileOwners overlay) only gets owner/controller/culture/religion
-- attributes stamped onto its map part by ProvinceStamper.applyTileOwnership; it never receives
-- a WorldState record, an EU4 mapping, or a province_id unless it was PROMOTED into a seed. An
-- un-promoted owned tile is therefore invisible to every record-driven system: ownership counts,
-- economy, buildings, and movement (AdjacencyGraph enrols only parts that carry a province_id, so
-- the tile is an impassable hole in the land graph rather than a node).
--
-- reconcile() runs after ProvinceStamper.stamp() and before AdjacencyGraph.build(): at that point
-- every owner attribute is settled, so it scans the live map for parts that are owned but carry no
-- province_id, synthesises a seed record for each (identity from the part's own attributes, geography
-- inherited from the nearest already-registered province, the same defaults promoteTile uses), and
-- registers it through the normal ProvinceRegistry + ProvinceStamper path. AdjacencyGraph.build()
-- then picks up the freshly stamped province_id parts as ordinary nodes.
--
-- It is live-only and idempotent: it writes nothing to the DataStore and re-runs cleanly every boot
-- (a part that already carries a province_id is skipped). It is fully data-driven -- no country or
-- province is referenced by name. Permanent registration still flows through the Data Editor's
-- Save/promote path; this only guarantees the running world is never left with owned-but-unregistered
-- land.

local ProvinceReconciler = {}

local ctx

local function prettyName(partName)
	return (partName:gsub("^prov_%d+_", "")):gsub("_", " ")
end

local function attr(part, name)
	local v = part:GetAttribute(name)
	if v == nil or v == "" then
		return nil
	end
	return v
end

-- Build a seed record for an owned-but-unregistered part. Identity (owner/controller/culture/
-- religion/coastal) comes from the attributes already stamped on the part; regional geography is
-- inherited from the geometrically nearest registered province; everything else uses the same
-- starter defaults as DataEditor.promoteTile so a reconciled province behaves exactly like an
-- admin-promoted one.
local function buildRecord(part, newId, owner, nearest)
	local controller = attr(part, "controller") or owner
	return {
		id = newId,
		name = prettyName(part.Name),
		displayCityName = prettyName(part.Name),
		areaId = (nearest and nearest.areaId) or "",
		regionId = (nearest and nearest.regionId) or "",
		superRegionId = (nearest and nearest.superRegionId) or "",
		terrain = attr(part, "terrain") or (nearest and nearest.terrain) or "plains",
		climate = attr(part, "climate") or (nearest and nearest.climate) or "temperate",
		baseTax = 1,
		baseProduction = 1,
		baseManpower = 1,
		culture = attr(part, "culture") or (nearest and nearest.culture) or "",
		religion = attr(part, "religion") or (nearest and nearest.religion) or "",
		tradeGood = "grain",
		goods = { grain = 1 },
		ownerTag = owner,
		controllerTag = controller,
		cores = { owner },
		defaultCores = { owner },
		isCity = true,
		devTier = 1,
		infraTier = 1,
		fortTier = 1,
		population = 10000,
		centerOfTrade = 0,
		unrest = 0,
		autonomy = 0,
		coastal = part:GetAttribute("coastal") == true,
		hasShipyard = part:GetAttribute("has_shipyard") == true,
	}
end

function ProvinceReconciler.reconcile()
	local result = { found = 0, registered = 0, unlinkable = 0, alreadyMapped = 0, ghostOwner = 0 }

	local map = workspace:FindFirstChild("ArtOfWarMap")
	local folder = map and map:FindFirstChild("Provinces")
	if not folder then
		return result
	end

	local WorldState = ctx.WorldState
	local registry = ctx.ProvinceRegistry
	local stamper = ctx.ProvinceStamper
	if not (WorldState and registry and stamper and registry.registerProvince and stamper.registerProvincePart) then
		return result
	end

	-- Highest province id currently in the world; reconciled provinces take ids above it.
	local maxId = 0
	for id in WorldState.allProvinces() do
		local n = tonumber(id) or 0
		if n > maxId then
			maxId = n
		end
	end

	-- Snapshot of registered provinces (parts carrying a province_id) for nearest-neighbour
	-- geography inheritance, plus the set of part ids that already back some province.
	local registered = {}
	local mappedPartIds = stamper.mappedPartIds and stamper.mappedPartIds() or {}
	for _, part in folder:GetChildren() do
		if part:IsA("BasePart") then
			local pid = part:GetAttribute("province_id")
			if pid ~= nil then
				local record = WorldState.getProvince(pid)
				if record then
					table.insert(registered, { pos = part.Position, record = record })
				end
			end
		end
	end

	local function nearestRecord(pos)
		local best, bestDistSq = nil, math.huge
		for _, entry in ipairs(registered) do
			local delta = entry.pos - pos
			local distSq = delta.X * delta.X + delta.Y * delta.Y + delta.Z * delta.Z
			if distSq < bestDistSq then
				bestDistSq = distSq
				best = entry.record
			end
		end
		return best
	end

	-- Collect the broken parts first so we can register them in a stable id order across boots.
	local broken = {}
	for _, part in folder:GetChildren() do
		if part:IsA("BasePart") and part:GetAttribute("province_id") == nil then
			local owner = attr(part, "owner")
			if owner ~= nil and owner ~= "NONE" then
				result.found += 1
				local eu4Pid = tonumber(part.Name:match("prov_(%d+)"))
				if not eu4Pid then
					result.unlinkable += 1
				elseif mappedPartIds[eu4Pid] then
					-- Some province already claims this part (e.g. a mapping that arrived after a
					-- throttled boot); leave it for the stamper self-heal rather than duplicate it.
					result.alreadyMapped += 1
				elseif not WorldState.getCountry(owner) then
					-- Owner is not a real country (ghost tag): normalise to neutral, do not register.
					part:SetAttribute("owner", "NONE")
					part:SetAttribute("controller", "NONE")
					result.ghostOwner += 1
				else
					table.insert(broken, { part = part, eu4Pid = eu4Pid, owner = owner })
				end
			end
		end
	end

	table.sort(broken, function(a, b)
		return a.eu4Pid < b.eu4Pid
	end)

	-- v3 (collapsed): a tile's part number IS its province id, so register it under that id directly
	-- (no serial allocation, no eu4Map bridge). v2: take the next id above the current max.
	local collapsed = stamper.isCollapsed and stamper.isCollapsed() == true
	for _, entry in ipairs(broken) do
		local newId
		if collapsed then
			newId = entry.eu4Pid
		else
			maxId += 1
			newId = maxId
		end
		local record = buildRecord(entry.part, newId, entry.owner, nearestRecord(entry.part.Position))
		registry.registerProvince(newId, record)
		stamper.registerProvincePart(newId, entry.eu4Pid)
		result.registered += 1
	end

	return result
end

function ProvinceReconciler.register(context)
	ctx = context
	ProvinceReconciler.api = {
		reconcile = ProvinceReconciler.reconcile,
	}
	ctx.ProvinceReconciler = ProvinceReconciler.api
end

return ProvinceReconciler
