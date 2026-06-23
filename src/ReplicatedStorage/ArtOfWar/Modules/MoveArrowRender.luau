-- MoveArrowRender: shared geometry for the on-ground movement arrows (Conquer-the-World style).
-- Builds flat "plank" segments laid over the map and a chevron arrowhead, all from anchored parts
-- (no meshes). Used by PathPreview (static dark preview arrow) and MoveArrowView (active arrow with
-- a yellow fill that grows as the move completes). Pure geometry: callers parent + colour the parts.
local MoveArrowRender = {}

local DEFAULT_WIDTH = 7
local DEFAULT_THICK = 0.4
local DEFAULT_LIFT = 2
local HEAD_LEN = 11
local HEAD_HALF_ANGLE = 32 -- degrees each chevron arm opens back from the travel direction

local function configPart(p, color, transparency, material)
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Massless = true
	p.Material = material or Enum.Material.SmoothPlastic
	p.Color = color or Color3.fromRGB(38, 38, 44)
	p.Transparency = transparency or 0
end

-- A flat ground plank spanning a->b (both world positions, already lifted by the caller). Returns
-- the Part, or nil for a degenerate (near-zero) span.
function MoveArrowRender.plank(a, b, opts)
	opts = opts or {}
	local dist = (b - a).Magnitude
	if dist < 0.05 then
		return nil
	end
	local p = Instance.new("Part")
	configPart(p, opts.color, opts.transparency, opts.material)
	p.Size = Vector3.new(opts.width or DEFAULT_WIDTH, opts.thickness or DEFAULT_THICK, dist)
	p.CFrame = CFrame.lookAt((a + b) * 0.5, b)
	return p
end

local function rotateY(v, deg)
	local r = math.rad(deg)
	local c, s = math.cos(r), math.sin(r)
	return Vector3.new(v.X * c - v.Z * s, v.Y, v.X * s + v.Z * c)
end

-- Chevron arrowhead at `tip`, arms opening back along (tip - from). Returns a list of parts.
function MoveArrowRender.arrowhead(tip, from, opts)
	opts = opts or {}
	local dir = tip - from
	if dir.Magnitude < 0.05 then
		return {}
	end
	local back = -dir.Unit
	local len = opts.headLength or HEAD_LEN
	local ang = opts.headAngle or HEAD_HALF_ANGLE
	local armOpts = {
		color = opts.color,
		transparency = opts.transparency,
		material = opts.material,
		width = opts.headWidth or opts.width or DEFAULT_WIDTH,
		thickness = opts.thickness or DEFAULT_THICK,
	}
	local parts = {}
	local left = MoveArrowRender.plank(tip, tip + rotateY(back, ang) * len, armOpts)
	local right = MoveArrowRender.plank(tip, tip + rotateY(back, -ang) * len, armOpts)
	if left then parts[#parts + 1] = left end
	if right then parts[#parts + 1] = right end
	return parts
end

-- Full dark arrow along an ordered list of world points: one plank per leg + an arrowhead at the
-- end. Returns a flat list of (unparented) parts for the caller to parent/track.
function MoveArrowRender.buildArrow(points, opts)
	opts = opts or {}
	local parts = {}
	if #points < 2 then
		return parts
	end
	for i = 1, #points - 1 do
		local seg = MoveArrowRender.plank(points[i], points[i + 1], opts)
		if seg then parts[#parts + 1] = seg end
	end
	for _, h in ipairs(MoveArrowRender.arrowhead(points[#points], points[#points - 1], opts)) do
		parts[#parts + 1] = h
	end
	return parts
end

MoveArrowRender.DEFAULT_LIFT = DEFAULT_LIFT
MoveArrowRender.DEFAULT_WIDTH = DEFAULT_WIDTH
MoveArrowRender.DEFAULT_THICK = DEFAULT_THICK

return MoveArrowRender
