local MapStyling = {}

local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")

local LABEL_FONT = Font.fromEnum(Enum.Font.Garamond)
local LABEL_FONT_ENUM = Enum.Font.Garamond
local LABEL_TEXT_COLOR = Color3.fromRGB(244, 232, 206)
local LABEL_STROKE_COLOR = Color3.fromRGB(28, 18, 8)
local LABEL_SHADOW_COLOR = Color3.fromRGB(8, 4, 0)
local LABEL_SHADOW_ALPHA = 0.45
local LABEL_SHADOW_OFFSET_SCALE = 0.04
local LABEL_PLANE_Y = 8

local LINK_DIST = 420
local MAX_TEXT_HEIGHT_PX = 360
local FADE_RANGE_PX = 16
local LETTER_ASPECT = 0.48
local LENGTH_INSET = 0.82
local WIDTH_INSET = 0.52
local PIXELS_PER_STUD = 4
local SLAB_THICKNESS = 0.05
local LETTER_PADDING_SCALE = 0.04
local LABEL_MIN_STUD_HEIGHT = 36
local LABEL_MAX_STUD_HEIGHT = 1200
local LABEL_MIN_DYNAMIC_CAP = 400
local LABEL_SIZE_PER_SQRT_PROV = 64
local MAX_LETTER_SLOT_STUDS = 380
local LETTER_MAX_STRETCH = 1.35
local ROBLOX_PART_SIZE_LIMIT = 2048

local MIN_PROV_SIZE_FLOOR = 200
local MERGE_DIST_LARGE = 1500
local MERGE_DIST_MEDIUM = 2200
local MERGE_DIST_SMALL = 3000
local MERGE_DIST_TINY = 4200
local MIN_PROVINCES_LARGE = 30
local MIN_PROVINCES_MEDIUM = 10
local MIN_PROVINCES_SMALL = 2

local FORCE_LABEL_PROVINCES = 6
local SECONDARY_TEXT_ALPHA = 0.22
local SECONDARY_STROKE_ALPHA = 0.45

local ROTATE_ASPECT_THRESHOLD = 2.2
local MAX_LABEL_ROT_DEG = 26
local CURVE_MAX_DEFLECTION_RATIO = 0.45
local CURVE_LETTER_ROT_CAP_DEG = 35
local CURVE_MIN_BLOB_COUNT = 6

local MIN_PX_DEFAULT = 16
local MIN_PX_MID = 22
local MIN_PX_SMALL = 28
local MIN_PX_MICRO = 38

local OVERLAP_BIAS_PX = 26

local labelUpdateConn = nil
local labelsEnabled = true

local cachedMap = nil
local cachedNames = nil
local rebuildDirty = false
local lastBuildAt = 0
local REBUILD_DEBOUNCE_SECONDS = 1.2
local MIN_COUNTRY_PROVINCES_TOTAL = 1

local function findBlobs(provinces)
	local n = #provinces
	if n == 0 then return {} end

	local cellSize = LINK_DIST * 0.5
	local cells = {}
	for i, p in ipairs(provinces) do
		if p:IsA("BasePart") then
			local gx = math.floor(p.Position.X / cellSize)
			local gz = math.floor(p.Position.Z / cellSize)
			local key = gx .. ":" .. gz
			if not cells[key] then cells[key] = {} end
			table.insert(cells[key], i)
		end
	end

	local d2 = LINK_DIST * LINK_DIST
	local cellRange = math.ceil(LINK_DIST / cellSize)
	local visited = {}
	local blobs = {}

	for startIdx = 1, n do
		if not visited[startIdx] then
			local stack = { startIdx }
			local parts = {}
			local sumX, sumZ = 0, 0

			while #stack > 0 do
				local idx = table.remove(stack)
				if not visited[idx] then
					visited[idx] = true
					local p = provinces[idx]
					table.insert(parts, p)
					sumX += p.Position.X
					sumZ += p.Position.Z

					local gx = math.floor(p.Position.X / cellSize)
					local gz = math.floor(p.Position.Z / cellSize)
					for dgx = -cellRange, cellRange do
						for dgz = -cellRange, cellRange do
							local bucket = cells[(gx + dgx) .. ":" .. (gz + dgz)]
							if bucket then
								for _, j in ipairs(bucket) do
									if not visited[j] then
										local q = provinces[j]
										local dx = q.Position.X - p.Position.X
										local dz = q.Position.Z - p.Position.Z
										if (dx * dx + dz * dz) <= d2 then
											table.insert(stack, j)
										end
									end
								end
							end
						end
					end
				end
			end

			local count = #parts
			if count > 0 then
				table.insert(blobs, {
					parts = parts,
					count = count,
					cx = sumX / count,
					cz = sumZ / count,
				})
			end
		end
	end

	table.sort(blobs, function(a, b) return a.count > b.count end)
	return blobs
end

local function principalAxis(blob)
	local n = #blob
	if n == 0 then return nil end
	local cx, cz = 0, 0
	for _, p in ipairs(blob) do
		cx += p.Position.X
		cz += p.Position.Z
	end
	cx /= n
	cz /= n

	if n == 1 then
		local p = blob[1]
		local sx = math.max(p.Size.X, MIN_PROV_SIZE_FLOOR)
		local sz = math.max(p.Size.Z, MIN_PROV_SIZE_FLOOR)
		return cx, cz, 0, sx, sz
	end

	local Sxx, Szz, Sxz = 0, 0, 0
	for _, p in ipairs(blob) do
		local dx = p.Position.X - cx
		local dz = p.Position.Z - cz
		Sxx += dx * dx
		Szz += dz * dz
		Sxz += dx * dz
	end
	Sxx /= n
	Szz /= n
	Sxz /= n

	local trace = Sxx + Szz
	local diff = Sxx - Szz
	local discr = math.sqrt(math.max(diff * diff + 4 * Sxz * Sxz, 0))
	local lambdaMax = (trace + discr) / 2

	local vx, vz
	if math.abs(Sxz) > 1e-6 then
		vx = Sxz
		vz = lambdaMax - Sxx
	elseif Sxx >= Szz then
		vx, vz = 1, 0
	else
		vx, vz = 0, 1
	end
	local lenV = math.sqrt(vx * vx + vz * vz)
	if lenV < 1e-6 then
		vx, vz, lenV = 1, 0, 1
	end
	vx, vz = vx / lenV, vz / lenV

	local px, pz = -vz, vx
	local minP, maxP, minQ, maxQ = math.huge, -math.huge, math.huge, -math.huge
	for _, p in ipairs(blob) do
		local dx = p.Position.X - cx
		local dz = p.Position.Z - cz
		local proj = dx * vx + dz * vz
		local perp = dx * px + dz * pz
		if proj < minP then minP = proj end
		if proj > maxP then maxP = proj end
		if perp < minQ then minQ = perp end
		if perp > maxQ then maxQ = perp end
	end

	local pad = 140
	local length = math.max((maxP - minP) + pad, MIN_PROV_SIZE_FLOOR)
	local width = math.max((maxQ - minQ) + pad, MIN_PROV_SIZE_FLOOR * 0.4)
	local angle = math.atan2(vz, vx)
	return cx, cz, angle, length, width
end

local function fitCurveCoefficients(blob, vx, vz, px, pz, cx, cz)
	local n = #blob
	if n < 4 then return 0, 0 end
	local s_xx, s_xxx, s_xxxx, s_xy, s_xxy = 0, 0, 0, 0, 0
	for _, p in ipairs(blob) do
		local dx = p.Position.X - cx
		local dz = p.Position.Z - cz
		local x = dx * vx + dz * vz
		local y = dx * px + dz * pz
		local x2 = x * x
		s_xx = s_xx + x2
		s_xxx = s_xxx + x2 * x
		s_xxxx = s_xxxx + x2 * x2
		s_xy = s_xy + x * y
		s_xxy = s_xxy + x2 * y
	end
	local det = s_xx * s_xxxx - s_xxx * s_xxx
	if math.abs(det) < 1e-6 then return 0, 0 end
	local b = (s_xxxx * s_xy - s_xxx * s_xxy) / det
	local c = (s_xx * s_xxy - s_xxx * s_xy) / det
	return b, c
end

local letterWidthCache = {}

local function measureLetters(text, fontSize)
	local widths = {}
	local total = 0
	for i = 1, #text do
		local glyph = text:sub(i, i)
		local cacheKey = glyph .. "@" .. fontSize
		local w = letterWidthCache[cacheKey]
		if not w then
			local ok, size = pcall(function()
				return TextService:GetTextSize(glyph, fontSize, LABEL_FONT_ENUM, Vector2.new(10000, 10000))
			end)
			w = (ok and size and size.X > 0) and size.X or fontSize * 0.55
			if glyph == " " then w = fontSize * 0.4 end
			letterWidthCache[cacheKey] = w
		end
		widths[i] = w
		total = total + w
	end
	return widths, total
end

local function shouldLabelBlob(blob, accepted, isFirst)
	if isFirst then return true end
	if blob.count >= FORCE_LABEL_PROVINCES then return true end
	local mergeDist
	if blob.count >= MIN_PROVINCES_LARGE then
		mergeDist = MERGE_DIST_LARGE
	elseif blob.count >= MIN_PROVINCES_MEDIUM then
		mergeDist = MERGE_DIST_MEDIUM
	elseif blob.count >= MIN_PROVINCES_SMALL then
		mergeDist = MERGE_DIST_SMALL
	elseif blob.count >= 1 then
		mergeDist = MERGE_DIST_TINY
	else
		return false
	end
	local mergeSq = mergeDist * mergeDist
	for _, prev in ipairs(accepted) do
		local dx = blob.cx - prev.cx
		local dz = blob.cz - prev.cz
		if (dx * dx + dz * dz) < mergeSq then
			return false
		end
	end
	return true
end

local function minPxFor(blobCount, studHeight)
	if blobCount <= 2 then return MIN_PX_MICRO end
	if blobCount <= 8 then return MIN_PX_SMALL end
	if blobCount <= 25 or studHeight < 80 then return MIN_PX_MID end
	return MIN_PX_DEFAULT
end

local function makeLetterFrame(parent, glyph, fontSize, rotation, xPx, yPx, widthPx, heightPx)
	local frame = Instance.new("Frame")
	frame.Name = "Letter"
	frame.BackgroundTransparency = 1
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromOffset(xPx, yPx)
	frame.Size = UDim2.fromOffset(widthPx, heightPx)
	frame.Rotation = rotation
	frame.Parent = parent

	local shadowOffset = math.max(1, math.floor(fontSize * LABEL_SHADOW_OFFSET_SCALE + 0.5))

	local shadow = Instance.new("TextLabel")
	shadow.Name = "Shadow"
	shadow.BackgroundTransparency = 1
	shadow.Size = UDim2.fromScale(1, 1)
	shadow.Position = UDim2.fromOffset(shadowOffset, shadowOffset)
	shadow.Text = glyph
	shadow.TextColor3 = LABEL_SHADOW_COLOR
	shadow.TextTransparency = LABEL_SHADOW_ALPHA
	shadow.FontFace = LABEL_FONT
	shadow.TextSize = fontSize
	shadow.TextXAlignment = Enum.TextXAlignment.Center
	shadow.TextYAlignment = Enum.TextYAlignment.Center
	shadow.ZIndex = 1
	shadow.Parent = frame

	local main = Instance.new("TextLabel")
	main.Name = "Main"
	main.BackgroundTransparency = 1
	main.Size = UDim2.fromScale(1, 1)
	main.Position = UDim2.fromOffset(0, 0)
	main.Text = glyph
	main.TextColor3 = LABEL_TEXT_COLOR
	main.FontFace = LABEL_FONT
	main.TextSize = fontSize
	main.TextXAlignment = Enum.TextXAlignment.Center
	main.TextYAlignment = Enum.TextYAlignment.Center
	main.ZIndex = 2
	main.Parent = frame

	return frame
end

local function buildArcLengthTable(b, c, xMin, xMax, samples)
	local cumLen, cumX = {}, {}
	cumLen[0], cumX[0] = 0, xMin
	local step = (xMax - xMin) / samples
	local total = 0
	for i = 1, samples do
		local x0 = xMin + (i - 1) * step
		local x1 = xMin + i * step
		local d0 = b + 2 * c * x0
		local d1 = b + 2 * c * x1
		local dy = (d0 + d1) * 0.5 * step
		total = total + math.sqrt(step * step + dy * dy)
		cumLen[i] = total
		cumX[i] = x1
	end
	return cumLen, cumX, total
end

local function xAtArcLength(cumLen, cumX, target, samples)
	if target <= 0 then return cumX[0] end
	if target >= cumLen[samples] then return cumX[samples] end
	local lo, hi = 1, samples
	while lo < hi do
		local mid = math.floor((lo + hi) * 0.5)
		if cumLen[mid] < target then lo = mid + 1 else hi = mid end
	end
	local prev = lo - 1
	local span = cumLen[lo] - cumLen[prev]
	if span <= 0 then return cumX[lo] end
	local frac = (target - cumLen[prev]) / span
	return cumX[prev] + (cumX[lo] - cumX[prev]) * frac
end

local function createLetterSlab(parent, name, glyph, worldX, worldZ, rotRad, slabWidth, slabHeight, fontSize)
	local slab = Instance.new("Part")
	slab.Name = name
	slab.Anchored = true
	slab.CanCollide = false
	slab.CanQuery = false
	slab.CanTouch = false
	slab.CastShadow = false
	slab.Transparency = 1
	slab.Size = Vector3.new(slabHeight, SLAB_THICKNESS, slabWidth)
	slab.CFrame = CFrame.new(worldX, LABEL_PLANE_Y, worldZ) * CFrame.Angles(0, math.pi * 0.5 - rotRad, 0)
	slab.Parent = parent

	local sg = Instance.new("SurfaceGui")
	sg.Name = "Letter"
	sg.Adornee = slab
	sg.Face = Enum.NormalId.Top
	sg.LightInfluence = 0
	sg.AlwaysOnTop = false
	sg.ClipsDescendants = false
	sg.PixelsPerStud = PIXELS_PER_STUD
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.ZOffset = 0
	sg.Parent = slab

	local canvasW = slabWidth * PIXELS_PER_STUD
	local canvasH = slabHeight * PIXELS_PER_STUD
	makeLetterFrame(sg, glyph, fontSize, 0, canvasW * 0.5, canvasH * 0.5, canvasW, canvasH)
end

local function buildLabel(parent, tag, displayName, blob, suffix, isPrimary)
	local cx, cz, angle, length, width = principalAxis(blob.parts)
	if not cx then return end

	local upperName = string.upper(displayName)
	local charCount = math.max(#upperName, 1)
	local heightFromLength = length * LENGTH_INSET / (charCount * LETTER_ASPECT)
	local heightFromWidth = width * WIDTH_INSET
	local studHeight = math.min(heightFromLength, heightFromWidth)
	local dynamicCap = math.clamp(math.sqrt(blob.count) * LABEL_SIZE_PER_SQRT_PROV, LABEL_MIN_DYNAMIC_CAP, LABEL_MAX_STUD_HEIGHT)
	studHeight = math.clamp(studHeight, LABEL_MIN_STUD_HEIGHT, math.min(dynamicCap, ROBLOX_PART_SIZE_LIMIT))

	local provisionalCanvasH = studHeight * PIXELS_PER_STUD
	local provisionalFontSize = math.floor(provisionalCanvasH * 0.78)
	local letterWidths, totalLetterWidth = measureLetters(upperName, provisionalFontSize)
	if totalLetterWidth <= 0 then totalLetterWidth = 1 end
	local naturalStudWidth = totalLetterWidth / PIXELS_PER_STUD
	local studWidth = math.min(
		length * LENGTH_INSET,
		naturalStudWidth * LETTER_MAX_STRETCH,
		charCount * MAX_LETTER_SLOT_STUDS
	)
	studWidth = math.max(studWidth, naturalStudWidth)

	local aspect = length / math.max(width, 1)
	local degAngle = math.deg(angle)
	if degAngle > 90 then
		degAngle = degAngle - 180
	elseif degAngle < -90 then
		degAngle = degAngle + 180
	end
	if aspect < ROTATE_ASPECT_THRESHOLD then
		degAngle = 0
	else
		degAngle = math.clamp(degAngle, -MAX_LABEL_ROT_DEG, MAX_LABEL_ROT_DEG)
	end
	local radAngle = math.rad(degAngle)

	local anchorName = suffix and (tag .. "_" .. suffix) or tag

	local anchor = Instance.new("Part")
	anchor.Name = anchorName
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, SLAB_THICKNESS, 1)
	anchor.CFrame = CFrame.new(cx, LABEL_PLANE_Y, cz)
	anchor:SetAttribute("tag", tag)
	anchor:SetAttribute("studWidth", studWidth)
	anchor:SetAttribute("studHeight", studHeight)
	anchor:SetAttribute("priority", blob.count)
	anchor:SetAttribute("minPx", minPxFor(blob.count, studHeight))
	anchor:SetAttribute("secondary", not isPrimary)
	anchor.Parent = parent

	local vx, vz = -math.cos(radAngle), -math.sin(radAngle)
	local px, pz = math.sin(radAngle), -math.cos(radAngle)

	if charCount == 1 then
		local slabWidth = math.min(math.max(studHeight * 1.0, 32), ROBLOX_PART_SIZE_LIMIT)
		createLetterSlab(anchor, "L1", upperName, cx, cz, radAngle, slabWidth, studHeight, provisionalFontSize)
		return
	end

	local b, c = 0, 0
	if blob.count >= CURVE_MIN_BLOB_COUNT then
		b, c = fitCurveCoefficients(blob.parts, vx, vz, px, pz, cx, cz)
	end

	local xRange = studWidth * 0.5
	local xMin, xMax = -xRange, xRange

	local function deflection(x) return b * x + c * x * x end
	local maxDef = math.max(math.abs(deflection(xMin)), math.abs(deflection(xMax)))
	if math.abs(c) > 1e-6 then
		local apexX = -b / (2 * c)
		if apexX >= xMin and apexX <= xMax then
			maxDef = math.max(maxDef, math.abs(deflection(apexX)))
		end
	end
	local studCap = studHeight * CURVE_MAX_DEFLECTION_RATIO
	if maxDef > studCap and maxDef > 0 then
		local k = studCap / maxDef
		b, c = b * k, c * k
	end

	local samples = 60
	local cumLen, cumX, totalArc = buildArcLengthTable(b, c, xMin, xMax, samples)
	if totalArc <= 0 then totalArc = xMax - xMin end

	local cursorArc = 0
	for i = 1, charCount do
		local letterArc = (letterWidths[i] / totalLetterWidth) * totalArc
		local centerArc = cursorArc + letterArc * 0.5
		cursorArc = cursorArc + letterArc

		local x = xAtArcLength(cumLen, cumX, centerArc, samples)
		local y = deflection(x)
		local tangent = b + 2 * c * x
		local localRotRad = math.atan(tangent)
		local clampedLocalRot = math.rad(math.clamp(math.deg(localRotRad), -CURVE_LETTER_ROT_CAP_DEG, CURVE_LETTER_ROT_CAP_DEG))

		local worldX = cx + x * vx + y * px
		local worldZ = cz + x * vz + y * pz

		local slotStuds = (letterWidths[i] / totalLetterWidth) * studWidth
		local slabWidth = math.min(math.max(slotStuds, 32), ROBLOX_PART_SIZE_LIMIT)
		local slabHeight = math.min(studHeight, ROBLOX_PART_SIZE_LIMIT)

		createLetterSlab(anchor, "L" .. i, upperName:sub(i, i), worldX, worldZ, radAngle + clampedLocalRot, slabWidth, slabHeight, provisionalFontSize)
	end
end

local function markDirty()
	rebuildDirty = true
end

local function subscribeProvinceChanges(provFolder)
	for _, p in provFolder:GetChildren() do
		if p:IsA("BasePart") and not p:GetAttribute("AoWLabelWatcher") then
			p:SetAttribute("AoWLabelWatcher", true)
			p:GetAttributeChangedSignal("owner"):Connect(markDirty)
		end
	end
end

local LABELS_DISABLED = true

function MapStyling.buildCountryLabels(map, countryNames)
	cachedMap = map
	if countryNames then cachedNames = countryNames end
	if LABELS_DISABLED then
		local existing = map:FindFirstChild("CountryLabels")
		if existing then existing:Destroy() end
		return
	end
	local namesTable = countryNames or cachedNames or {}

	local existing = map:FindFirstChild("CountryLabels")
	if existing then existing:Destroy() end
	local labels = Instance.new("Folder")
	labels.Name = "CountryLabels"
	labels.Parent = map

	local provFolder = map:FindFirstChild("Provinces")
	if not provFolder then return end

	local countryProvs = {}
	for _, p in provFolder:GetChildren() do
		if p:IsA("BasePart") then
			local owner = p:GetAttribute("owner")
			if owner and owner ~= "NONE" and owner ~= "" then
				if not countryProvs[owner] then countryProvs[owner] = {} end
				table.insert(countryProvs[owner], p)
			end
		end
	end

	for tag, provs in countryProvs do
		if #provs < MIN_COUNTRY_PROVINCES_TOTAL then continue end
		local displayName = namesTable[tag]
		if type(displayName) ~= "string" or displayName == "" then continue end

		local blobs = findBlobs(provs)
		if #blobs == 0 then continue end

		local accepted = {}
		for i, blob in ipairs(blobs) do
			if shouldLabelBlob(blob, accepted, i == 1) then
				table.insert(accepted, blob)
				local suffix = (#accepted > 1) and tostring(#accepted) or nil
				buildLabel(labels, tag, displayName, blob, suffix, #accepted == 1)
			end
		end
	end

	subscribeProvinceChanges(provFolder)
	rebuildDirty = false
	lastBuildAt = os.clock()
end

local function forEachLetterSurfaceGui(anchor, fn)
	for _, letter in anchor:GetChildren() do
		if letter:IsA("BasePart") then
			local sg = letter:FindFirstChildOfClass("SurfaceGui")
			if sg then fn(sg) end
		end
	end
end

function MapStyling.setEnabled(flag)
	local desired = flag and true or false
	if desired == labelsEnabled then return end
	labelsEnabled = desired
	if labelsEnabled then return end
	local map = workspace:FindFirstChild("ArtOfWarMap")
	if not map then return end
	local labelsFolder = map:FindFirstChild("CountryLabels")
	if not labelsFolder then return end
	for _, anchor in labelsFolder:GetChildren() do
		if anchor:IsA("BasePart") then
			forEachLetterSurfaceGui(anchor, function(sg) sg.Enabled = false end)
		end
	end
end

local function rectsOverlap(a, b)
	if a.right < b.left or b.right < a.left then return false end
	if a.bottom < b.top or b.bottom < a.top then return false end
	return true
end

-- M1: memoize each letter SurfaceGui's TextLabels so the per-frame declutter pass does not
-- call GetDescendants on every letter of every visible label while the camera pans. Weak keys
-- mean entries are dropped automatically when labels are rebuilt.
local letterTextCache = setmetatable({}, { __mode = "k" })
local function labelTextsOf(sg)
	local cached = letterTextCache[sg]
	if cached then return cached end
	local shadow, main = nil, {}
	for _, descendant in ipairs(sg:GetDescendants()) do
		if descendant:IsA("TextLabel") then
			if descendant.Name == "Shadow" then shadow = descendant
			else main[#main + 1] = descendant end
		end
	end
	cached = { shadow = shadow, main = main }
	letterTextCache[sg] = cached
	return cached
end

function MapStyling.startLabelManager(getZoom)
	if labelUpdateConn then labelUpdateConn:Disconnect() end
	if LABELS_DISABLED then
		local map = workspace:FindFirstChild("ArtOfWarMap")
		if map then
			local existing = map:FindFirstChild("CountryLabels")
			if existing then existing:Destroy() end
		end
		return
	end
	local lastSig = ""
	local frameCounter = 0

	labelUpdateConn = RunService.Heartbeat:Connect(function()
		frameCounter += 1
		if frameCounter % 4 ~= 0 then return end

		local map = workspace:FindFirstChild("ArtOfWarMap")
		if not map then return end

		if rebuildDirty and cachedMap and (os.clock() - lastBuildAt) >= REBUILD_DEBOUNCE_SECONDS then
			MapStyling.buildCountryLabels(cachedMap, cachedNames)
			lastSig = ""
		end

		local labelsFolder = map:FindFirstChild("CountryLabels")
		if not labelsFolder then return end

		if not labelsEnabled then
			for _, anchor in labelsFolder:GetChildren() do
				if anchor:IsA("BasePart") then
					forEachLetterSurfaceGui(anchor, function(sg)
						if sg.Enabled then sg.Enabled = false end
					end)
				end
			end
			return
		end

		local cam = workspace.CurrentCamera
		if not cam then return end

		local zoom = (type(getZoom) == "function" and getZoom()) or 5000
		local vp = cam.ViewportSize
		if vp.Y < 1 then return end

		local camPos = cam.CFrame.Position
		local sig = string.format("%d:%dx%d:%d:%d:%d",
			math.floor(zoom / 8),
			math.floor(vp.X), math.floor(vp.Y),
			math.floor(cam.FieldOfView * 10),
			math.floor(camPos.X / 24),
			math.floor(camPos.Z / 24))
		if sig == lastSig then return end
		lastSig = sig

		local fovRad = math.rad(cam.FieldOfView)
		local visibleStuds = 2 * zoom * math.tan(fovRad * 0.5)
		local pixelsPerStud = vp.Y / math.max(visibleStuds, 1)

		local candidates = {}

		for _, anchor in labelsFolder:GetChildren() do
			if not anchor:IsA("BasePart") then continue end
			local hasLetters = false
			for _, child in anchor:GetChildren() do
				if child:IsA("BasePart") then hasLetters = true; break end
			end
			if not hasLetters then continue end

			local studWidth = anchor:GetAttribute("studWidth") or 400
			local studHeight = anchor:GetAttribute("studHeight") or 80
			local pxWidth = studWidth * pixelsPerStud
			local pxHeight = studHeight * pixelsPerStud
			local minPx = anchor:GetAttribute("minPx") or MIN_PX_DEFAULT

			if pxHeight < minPx or pxHeight > MAX_TEXT_HEIGHT_PX then
				forEachLetterSurfaceGui(anchor, function(sg) sg.Enabled = false end)
				continue
			end

			local screen, onScreen = cam:WorldToViewportPoint(anchor.Position)
			if not onScreen or screen.Z <= 0 then
				forEachLetterSurfaceGui(anchor, function(sg) sg.Enabled = false end)
				continue
			end

			local rectW = math.clamp(pxWidth, 24, 9000)
			local rectH = math.clamp(pxHeight, 10, 1400)
			local marginX = rectW * 0.5 - OVERLAP_BIAS_PX
			local marginY = rectH * 0.5 - OVERLAP_BIAS_PX

			table.insert(candidates, {
				anchor = anchor,
				pxWidth = rectW,
				pxHeight = rectH,
				minPx = minPx,
				priority = anchor:GetAttribute("priority") or 1,
				left = screen.X - marginX,
				right = screen.X + marginX,
				top = screen.Y - marginY,
				bottom = screen.Y + marginY,
			})
		end

		table.sort(candidates, function(a, b)
			if a.priority == b.priority then return a.pxHeight > b.pxHeight end
			return a.priority > b.priority
		end)

		local shown = {}
		for _, c in ipairs(candidates) do
			local hide = false
			for _, s in ipairs(shown) do
				if rectsOverlap(c, s) then
					hide = true
					break
				end
			end
			if hide then
				forEachLetterSurfaceGui(c.anchor, function(sg) sg.Enabled = false end)
			else
				local fadeIn = (c.pxHeight - c.minPx) / FADE_RANGE_PX
				local fadeOut = (MAX_TEXT_HEIGHT_PX - c.pxHeight) / FADE_RANGE_PX
				local fade = math.clamp(math.min(fadeIn, fadeOut, 1), 0, 1)
				local mainAlpha = 1 - fade
				local shadowAlpha = math.max(LABEL_SHADOW_ALPHA, 1 - fade)
				if c.anchor:GetAttribute("secondary") then
					mainAlpha = math.clamp(mainAlpha + SECONDARY_TEXT_ALPHA, 0, 1)
					shadowAlpha = math.clamp(shadowAlpha + SECONDARY_TEXT_ALPHA, 0, 1)
				end
				forEachLetterSurfaceGui(c.anchor, function(sg)
					sg.Enabled = true
					local texts = labelTextsOf(sg)
					if texts.shadow then texts.shadow.TextTransparency = shadowAlpha end
					for _, t in ipairs(texts.main) do t.TextTransparency = mainAlpha end
				end)
				table.insert(shown, c)
			end
		end
	end)
end

function MapStyling.stopLabelManager()
	if labelUpdateConn then
		labelUpdateConn:Disconnect()
		labelUpdateConn = nil
	end
end

return MapStyling
