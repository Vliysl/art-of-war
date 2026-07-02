-- World-space capital stars: one ReplicatedStorage.Models.StarMarker clone per nation,
-- centred on its capital tile. Outline = darker tint of the nation's color; Inner = white,
-- or a lighter tint of the CONTROLLER's color while the capital is occupied. An annexed
-- nation's country record disappears from the cache, which removes its marker. The
-- template's Y level and scale are authored ("already aligned") -- placement only moves XZ.
local CapitalMarkerView = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local ClientStateCache = require(aow:WaitForChild("Modules"):WaitForChild("ClientStateCache"))
local ProvincePositions = require(aow:WaitForChild("Modules"):WaitForChild("ProvincePositions"))
local Countries = require(aow:WaitForChild("Data"):WaitForChild("Countries"))

local FALLBACK = Color3.fromRGB(150, 150, 150)
local INNER_WHITE = Color3.new(1, 1, 1)
local OUTLINE_DARKEN = 0.55 -- lerp toward black for the outline
local INNER_LIGHTEN = 0.55 -- lerp toward white for the occupier tint

local markers = {} -- tag -> { model, inner, outline, sig }
local folder
local template = nil
local started = false
local dirty = false

local function realTag(t)
	return t ~= nil and t ~= "" and t ~= "NONE" and t or nil
end

local function getTemplate()
	if template ~= nil then
		return template or nil
	end
	local models = ReplicatedStorage:FindFirstChild("Models")
	local m = models and models:FindFirstChild("StarMarker")
	template = m or false
	return m
end

local function ownerColor(tag)
	local c = ClientStateCache.getCountry and ClientStateCache.getCountry(tag)
	if c and c.color then
		return Color3.fromRGB(c.color[1] or 150, c.color[2] or 150, c.color[3] or 150)
	end
	local s = tag and Countries[tag]
	if s and s.color then
		return Color3.fromRGB(s.color[1] or 150, s.color[2] or 150, s.color[3] or 150)
	end
	return FALLBACK
end

local function ensureFolder()
	if folder and folder.Parent then
		return folder
	end
	local map = workspace:FindFirstChild("ArtOfWarMap")
	if not map then
		return nil
	end
	folder = map:FindFirstChild("CapitalMarkers")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "CapitalMarkers"
		folder.Parent = map
	end
	return folder
end

local function buildMarker(tag, tmpl)
	local model = tmpl:Clone()
	model.Name = "capital_" .. tostring(tag)
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = false
			p.CanTouch = false
			p.CanQuery = false
			p.CastShadow = false
			p.Locked = true
		end
	end
	model.Parent = folder
	return {
		model = model,
		inner = model:FindFirstChild("Inner", true),
		outline = model:FindFirstChild("Outline", true),
		sig = nil,
	}
end

local function reconcile()
	local tmpl = getTemplate()
	if not tmpl or not ensureFolder() then
		return
	end
	local seen = {}
	for tag, country in pairs(ClientStateCache.allCountries() or {}) do
		local capId = country.capitalProvinceId
		local part = capId and ProvincePositions.partOf(capId)
		if part then
			seen[tag] = true
			local m = markers[tag]
			if not m or not m.model.Parent then
				m = buildMarker(tag, tmpl)
				markers[tag] = m
			end
			-- Centre on the capital tile's XZ; keep the template's authored Y + rotation.
			local pivot = m.model:GetPivot()
			local target = Vector3.new(part.Position.X, pivot.Position.Y, part.Position.Z)
			if (pivot.Position - target).Magnitude > 0.05 then
				m.model:PivotTo(CFrame.new(target) * pivot.Rotation)
			end
			local prov = ClientStateCache.getProvince(capId)
			local occTag = prov and realTag(prov.controllerTag)
			if occTag == tag then
				occTag = nil
			end
			-- Signature folds everything the colors derive from, so per-tick province deltas
			-- that don't move the capital's controller skip the recolor writes.
			local oc = ownerColor(tag)
			local sig = tostring(occTag) .. "|" .. oc:ToHex() .. "|" .. tostring(capId)
			if m.sig ~= sig then
				m.sig = sig
				if m.outline then
					m.outline.Color = oc:Lerp(Color3.new(0, 0, 0), OUTLINE_DARKEN)
				end
				if m.inner then
					m.inner.Color = occTag and ownerColor(occTag):Lerp(INNER_WHITE, INNER_LIGHTEN) or INNER_WHITE
				end
			end
		end
	end
	for tag, m in pairs(markers) do
		if not seen[tag] then
			m.model:Destroy()
			markers[tag] = nil
		end
	end
end

function CapitalMarkerView.init()
	if started then
		return
	end
	started = true
	local function schedule()
		if dirty then
			return
		end
		dirty = true
		task.defer(function()
			dirty = false
			reconcile()
		end)
	end
	ClientStateCache.onChangePrefix("countries", schedule)
	ClientStateCache.onChangePrefix("provinces", schedule)
	ClientStateCache.onChange("snapshot", schedule)
	-- The map and the place-side template can land after boot; retry until both exist.
	task.spawn(function()
		local deadline = os.clock() + 30
		repeat
			if getTemplate() and ensureFolder() then
				schedule()
				return
			end
			task.wait(1)
		until os.clock() > deadline
	end)
	schedule()
end

function CapitalMarkerView.destroy()
	for tag, m in pairs(markers) do
		m.model:Destroy()
		markers[tag] = nil
	end
	if folder then
		folder:Destroy()
		folder = nil
	end
end

return CapitalMarkerView
