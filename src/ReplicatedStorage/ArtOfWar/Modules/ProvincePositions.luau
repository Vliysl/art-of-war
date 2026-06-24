-- ProvincePositions: client-side province id -> map part / world position, resolved by the STABLE
-- part NAME (prov_<id>_...), NOT the runtime `province_id` attribute.
--
-- Why: the `province_id` attribute is the OLD serial id for the first ~6s after a world loads (the
-- place file persists it until the server re-stamps it to the part id at boot). Resolving positions
-- by that attribute — and caching the result, as ArmyView/MoveArrowView/PathPreview each used to —
-- poisons every position read in that window, permanently (caches are write-once). Part NAMES never
-- change and, post identity-collapse, the number IS the province id, so a name-keyed index is correct
-- from the first frame and forever. Shared by ArmyView, MoveArrowView, and PathPreview.
local ProvincePositions = {}

local byNumber = nil -- [id:number] = BasePart, keyed by the prov_<N> name number

local function provincesFolder()
	local map = workspace:FindFirstChild("ArtOfWarMap")
	return map and map:FindFirstChild("Provinces")
end

local function build()
	byNumber = {}
	local folder = provincesFolder()
	if not folder then
		byNumber = nil
		return
	end
	for _, part in folder:GetChildren() do
		if part:IsA("BasePart") then
			local n = tonumber(part.Name:match("^prov_(%d+)"))
			if n then byNumber[n] = part end
		end
	end
end

-- The map part whose name encodes this province id, or nil. Builds the index on first use and
-- rebuilds it on a miss / stale (re-parented) hit so runtime-promoted provinces resolve too.
function ProvincePositions.partOf(id)
	if id == nil then return nil end
	if not byNumber then build() end
	if not byNumber then return nil end
	local part = byNumber[id]
	if part and part.Parent then return part end
	build()
	return byNumber and byNumber[id] or nil
end

-- Top-centre world position of the province's part (optionally lifted), or nil.
function ProvincePositions.centerOf(id, lift)
	local part = ProvincePositions.partOf(id)
	if not part then return nil end
	return Vector3.new(
		part.Position.X,
		part.Position.Y + part.Size.Y * 0.5 + (lift or 0),
		part.Position.Z
	)
end

-- Call fn(id, part) for every resolvable province. Builds the index if needed.
function ProvincePositions.forEach(fn)
	if not byNumber then build() end
	if not byNumber then return end
	for id, part in pairs(byNumber) do
		if part.Parent then fn(id, part) end
	end
end

-- Drop the cached index; it rebuilds lazily on the next lookup.
function ProvincePositions.refresh()
	byNumber = nil
end

return ProvincePositions
