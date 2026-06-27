-- MoveArrowRender: shared geometry for the on-ground movement arrows (HOI4 / Conquer-the-World style).
-- Builds flat ribbon segments laid over the map and a solid triangular arrowhead, all from anchored
-- parts (no meshes). Used by PathPreview (static preview arrow) and MoveArrowView (active arrow with a
-- yellow fill that grows as the move completes). Pure geometry: callers parent + colour the parts.
--
-- The preview arrow (buildArrow) is a SMOOTHED PENTAGON BANNER: the raw province-centroid polyline is
-- corner-cut (Chaikin) and resampled to an even spacing, then drawn as a two-layer ribbon (dark
-- outline + colour on top) with overlapping segments so the joints read as one continuous flowing
-- arrow instead of a blocky zigzag. The body is a uniform width and ends in a single matching-width
-- point (flat back at the origin, thick body, one clean point at the target = a 5-sided banner).
local MoveArrowRender = {}

local DEFAULT_WIDTH = 7
local DEFAULT_THICK = 0.4
local DEFAULT_LIFT = 2
local HEAD_LEN = 11
local HEAD_HALF_ANGLE = 32 -- degrees each chevron arm opens back from the travel direction

-- buildArrow tuning
local SMOOTH_ITERS = 2     -- Chaikin corner-cut passes (more = rounder bends)
local RIBBON_SPACING = 14  -- studs between ribbon planks along the smoothed curve
local RIBBON_MAX_SEG = 60  -- hard cap on ribbon planks (long paths just space out further)
local RIBBON_BORDER = 1.4  -- half-width of the dark outline that peeks out past the colour
local BUILD_HEAD_LEN = 15 -- arrowhead length for buildArrow (shorter = stubbier, less awkward at bends)
local BUILD_HEAD_WIDTH_MULT = 1.0 -- banner: point base width == body width (uniform 5-sided banner)
local OUTLINE_DARKEN = 0.62       -- how far the auto outline colour is lerped toward black
local LOWER = Vector3.new(0, 0.06, 0) -- world-Y drop for the outline layer (sits just under the top)

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
-- (Legacy two-plank head; kept for callers that want the lightweight look.)
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

local function darken(color, amount)
	return color:Lerp(Color3.new(0, 0, 0), amount)
end

-- A filled, tapered triangular arrowhead at `tip`, pointing away from `from`. Scan-filled from a
-- stack of cross strips (wide at the base, narrowing to the tip) so it reads as a solid HOI4-style
-- head rather than a thin "V". Draws a darker outline strip under each slice when an outline colour
-- is available. Returns a list of (unparented) parts.
function MoveArrowRender.solidArrowhead(tip, from, opts)
	opts = opts or {}
	local f = tip - from
	if f.Magnitude < 1e-3 then
		return {}
	end
	f = f.Unit
	-- Flatten the travel direction so the base sits level and the perpendicular is stable.
	local fh = Vector3.new(f.X, 0, f.Z)
	fh = (fh.Magnitude < 1e-4) and f or fh.Unit
	local side = Vector3.new(-fh.Z, 0, fh.X) -- horizontal unit perpendicular

	local L = opts.headLength or HEAD_LEN
	local width = opts.width or DEFAULT_WIDTH
	local halfBase = (opts.headWidth or width * BUILD_HEAD_WIDTH_MULT) * 0.5
	local thick = opts.thickness or DEFAULT_THICK
	local material = opts.material
	local color = opts.color
	local transparency = opts.transparency
	local border = opts.border or RIBBON_BORDER
	local outlineColor = opts.outlineColor or (color and darken(color, OUTLINE_DARKEN))
	local outlineTransparency = opts.outlineTransparency
		or (transparency and math.min(0.85, transparency + 0.18))
	local slices = opts.headSlices or 12

	local base = tip - fh * L
	local parts = {}
	for i = 0, slices - 1 do
		local tc = (i + 0.5) / slices
		-- Evaluate the taper at the slice's BACK edge so the first (base) slice is the full base width
		-- and butts flush against the shaft instead of starting a half-slice in (which pinched the join).
		local tcw = i / slices
		local center = base:Lerp(tip, tc)
		local w = math.max(halfBase * 2 * (1 - tcw), 0.6)
		local sliceLen = L / slices + 0.25 -- slight overlap along travel so slices read as one mass
		local a = center - side * (w * 0.5)
		local b = center + side * (w * 0.5)
		local span = (b - a).Magnitude
		if outlineColor then
			local o = Instance.new("Part")
			configPart(o, outlineColor, outlineTransparency, material)
			o.Size = Vector3.new(sliceLen + border, thick, span + border * 1.5)
			o.CFrame = CFrame.lookAt((a + b) * 0.5 - LOWER, b - LOWER)
			parts[#parts + 1] = o
		end
		local p = Instance.new("Part")
		configPart(p, color, transparency, material)
		p.Size = Vector3.new(sliceLen, thick, span)
		p.CFrame = CFrame.lookAt((a + b) * 0.5, b)
		parts[#parts + 1] = p
	end
	return parts
end

-- Chaikin corner-cutting: replaces each interior corner with two points 1/4 and 3/4 along its legs,
-- rounding the polyline while pinning the first and last points. Cheap smoothing, no overshoot.
local function chaikin(points, iters)
	local pts = points
	for _ = 1, iters do
		if #pts < 3 then
			break
		end
		local out = { pts[1] }
		for i = 1, #pts - 1 do
			local p, q = pts[i], pts[i + 1]
			out[#out + 1] = p:Lerp(q, 0.25)
			out[#out + 1] = p:Lerp(q, 0.75)
		end
		out[#out + 1] = pts[#pts]
		pts = out
	end
	return pts
end

-- Resample an ordered polyline to an even arc-length spacing (always keeping the true endpoint),
-- raising the spacing if needed so the count never exceeds maxSeg.
local function resample(points, step, maxSeg)
	if #points < 2 then
		return points
	end
	local total = 0
	for i = 1, #points - 1 do
		total += (points[i + 1] - points[i]).Magnitude
	end
	if total < 1e-3 then
		return { points[1] }
	end
	step = math.max(step, total / maxSeg)
	local out = { points[1] }
	local target = step
	local travelled = 0
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local segLen = (b - a).Magnitude
		if segLen > 1e-5 then
			while travelled + segLen >= target do
				out[#out + 1] = a:Lerp(b, (target - travelled) / segLen)
				target += step
			end
			travelled += segLen
		end
	end
	if (out[#out] - points[#points]).Magnitude > 1e-3 then
		out[#out + 1] = points[#points]
	end
	return out
end

-- Full smoothed arrow along an ordered list of world points: a two-layer flowing ribbon (dark
-- outline + colour) of uniform width ending in a single matching-width point — a pentagon banner.
-- Returns a flat list of (unparented) parts for the caller to parent/track. Only used by PathPreview
-- (the active arrow uses plank+solidArrowhead).
function MoveArrowRender.buildArrow(points, opts)
	opts = opts or {}
	local parts = {}
	if #points < 2 then
		return parts
	end

	local color = opts.color or Color3.fromRGB(120, 220, 255)
	local thick = opts.thickness or DEFAULT_THICK
	local width = opts.width or DEFAULT_WIDTH
	local material = opts.material
	local transparency = opts.transparency or 0.08
	local border = opts.border or RIBBON_BORDER
	local outlineColor = opts.outlineColor or darken(color, OUTLINE_DARKEN)
	local outlineTransparency = opts.outlineTransparency or math.min(0.85, transparency + 0.18)
	local headLen = opts.headLength or BUILD_HEAD_LEN
	local overlap = width * 1.0 -- lengthen each plank so neighbours overlap and hide the joints

	-- Smooth + evenly resample the route so the arrow flows instead of zig-zagging through centroids.
	local pts = resample(chaikin(points, opts.smoothIters or SMOOTH_ITERS),
		opts.spacing or RIBBON_SPACING, opts.maxSegments or RIBBON_MAX_SEG)
	if #pts < 2 then
		pts = points
	end

	-- Head direction + the arrowhead base (ribbonEnd). The shaft is trimmed to END exactly at ribbonEnd
	-- so the solid head sits cleanly past it -- even when the head is longer than one resample step
	-- (otherwise the last full-size plank runs under the head base and the head clips into it).
	local tip = pts[#pts]
	local headDir = tip - pts[#pts - 1]
	headDir = (headDir.Magnitude < 1e-3) and (points[#points] - points[1]) or headDir
	headDir = headDir.Unit
	local totalLen = 0
	for i = 1, #pts - 1 do
		totalLen += (pts[i + 1] - pts[i]).Magnitude
	end
	local hLen = math.min(headLen, totalLen * 0.6) -- never let the head exceed the whole arrow
	local ribbonEnd = tip - headDir * hLen

	local function ribbonSeg(a, b, topT, outT, isLast)
		local d = (b - a).Magnitude
		if d < 0.02 then
			return
		end
		local dir = (b - a).Unit
		-- Centre each plank over its own span, overhanging BOTH joints equally so neighbours overlap
		-- symmetrically around each corner -- the bend then reads as one continuous ribbon. (Extending
		-- only the back end pinned the plank at `b` and left the outside of every corner notched, which
		-- looked choppy.) EXCEPTION: the final shaft segment (isLast) must end exactly at the arrowhead
		-- base, so it overhangs backward only and never pokes into the narrowing head.
		local a2, b2
		if isLast then
			a2 = a - dir * overlap
			b2 = b
		else
			a2 = a - dir * (overlap * 0.5)
			b2 = b + dir * (overlap * 0.5)
		end
		local len = (b2 - a2).Magnitude
		local mid = (a2 + b2) * 0.5
		local o = Instance.new("Part")
		configPart(o, outlineColor, outT, material)
		o.Size = Vector3.new(width + border * 2, thick, len)
		o.CFrame = CFrame.lookAt(mid - LOWER, b2 - LOWER)
		parts[#parts + 1] = o
		local p = Instance.new("Part")
		configPart(p, color, topT, material)
		p.Size = Vector3.new(width, thick, len)
		p.CFrame = CFrame.lookAt(mid, b2)
		parts[#parts + 1] = p
	end

	-- Trim the shaft to end EXACTLY at the arrowhead base: drop the trailing resampled points that fall
	-- inside the head, then finish the shaft on ribbonEnd itself. The final plank is thus shortened to
	-- make room for the head instead of the head clipping into a full-size plank.
	local shaftPts = {}
	for i = 1, #pts do
		shaftPts[i] = pts[i]
	end
	while #shaftPts > 1 and (shaftPts[#shaftPts] - ribbonEnd):Dot(headDir) > 0 do
		shaftPts[#shaftPts] = nil
	end
	if (shaftPts[#shaftPts] - ribbonEnd).Magnitude > 0.5 then
		shaftPts[#shaftPts + 1] = ribbonEnd
	end

	local segs = {}
	for i = 1, #shaftPts - 1 do
		segs[#segs + 1] = { shaftPts[i], shaftPts[i + 1] }
	end

	-- Draw the uniform-width banner body. Optional gentle fade-in over the first few segments.
	for idx, seg in ipairs(segs) do
		local topT, outT = transparency, outlineTransparency
		if opts.fadeIn then
			local fade = math.clamp((idx - 1) / 3, 0, 1)
			topT = math.min(transparency + (0.4 - transparency) * (1 - fade), 0.4)
			outT = math.min(outlineTransparency + (0.55 - outlineTransparency) * (1 - fade), 0.55)
		end
		ribbonSeg(seg[1], seg[2], topT, outT, idx == #segs)
	end

	for _, h in ipairs(MoveArrowRender.solidArrowhead(tip, ribbonEnd, {
		color = color,
		transparency = transparency,
		material = material,
		width = width,
		headLength = hLen,
		headWidth = opts.headWidth,
		thickness = thick,
		border = border,
		outlineColor = outlineColor,
		outlineTransparency = outlineTransparency,
	})) do
		parts[#parts + 1] = h
	end

	return parts
end

MoveArrowRender.DEFAULT_LIFT = DEFAULT_LIFT
MoveArrowRender.DEFAULT_WIDTH = DEFAULT_WIDTH
MoveArrowRender.DEFAULT_THICK = DEFAULT_THICK

return MoveArrowRender
