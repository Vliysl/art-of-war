local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")

local UISound = {}

local ASSETS = {
	click   = "rbxassetid://8816939097",
	whoosh  = "rbxassetid://135595810064855",
	hover   = "rbxasset://sounds/electronicpingshort.wav",
	notify  = "rbxasset://sounds/electronicpingshort.wav",
	alert   = "rbxassetid://4590657391",
	claim   = "rbxassetid://130735746419880",
	phase   = "rbxasset://sounds/bass.wav",
}

local PITCH = {
	click  = 1.0,
	whoosh = 1.0,
	hover  = 1.6,
	notify = 1.0,
	alert  = 1.0,
	claim  = 1.0,
	phase  = 0.85,
}

local VOLUMES = {
	click  = 0.4,
	whoosh = 0.5,
	hover  = 0.12,
	notify = 0.45,
	alert  = 0.55,
	claim  = 0.7,
	phase  = 0.35,
}

local sounds = {}
local disabled = {}
local enabled = true

local function ensureSound(kind)
	if disabled[kind] then return nil end
	local cached = sounds[kind]
	if cached then return cached end
	local id = ASSETS[kind]
	if not id then return nil end
	local snd = Instance.new("Sound")
	snd.Name = "AoWUISound_" .. kind
	snd.SoundId = id
	snd.Volume = VOLUMES[kind] or 0.3
	snd.PlaybackSpeed = PITCH[kind] or 1.0
	snd.PlayOnRemove = false
	snd.Parent = SoundService
	sounds[kind] = snd
	return snd
end

function UISound.setEnabled(flag)
	enabled = flag and true or false
end

function UISound.isEnabled()
	return enabled
end

function UISound.play(kind)
	if not enabled then return end
	local snd = ensureSound(kind)
	if not snd then return end
	local clone = snd:Clone()
	clone.Parent = SoundService
	clone:Play()
	task.delay(3, function()
		if clone then clone:Destroy() end
	end)
end

function UISound.click()  UISound.play("click")  end
function UISound.whoosh() UISound.play("whoosh") end
function UISound.hover()  UISound.play("hover")  end
function UISound.notify() UISound.play("notify") end
function UISound.alert()  UISound.play("alert")  end
function UISound.claim()  UISound.play("claim")  end
function UISound.phase()  UISound.play("phase")  end

function UISound.attachButton(button)
	if not button or not button:IsA("GuiButton") then return end
	if button:GetAttribute("AoWClickAttached") then return end
	button:SetAttribute("AoWClickAttached", true)
	-- Defer so callers can set AoWNoClickSound on the button immediately after creation
	-- (e.g. ClaimScreen's CTA which fires the dedicated claim sound and shouldn't double up).
	task.defer(function()
		if not button or not button.Parent then return end
		if button:GetAttribute("AoWNoClickSound") then return end
		button.MouseButton1Down:Connect(UISound.click)
	end)
end

-- Auto-attach click sound to every GuiButton descendant of a ScreenGui.
-- Idempotent: SetAttribute("AoWClickAttached") guards against double-binding.
function UISound.attachAll(screenGui)
	if not screenGui then return end
	for _, d in ipairs(screenGui:GetDescendants()) do
		if d:IsA("GuiButton") then UISound.attachButton(d) end
	end
	screenGui.DescendantAdded:Connect(function(d)
		if d:IsA("GuiButton") then UISound.attachButton(d) end
	end)
end

function UISound.preload()
	for kind in pairs(ASSETS) do
		local snd = ensureSound(kind)
		if snd then
			task.spawn(function()
				local ok, fetch = pcall(function()
					ContentProvider:PreloadAsync({ snd }, function(_, status)
						if status == Enum.AssetFetchStatus.Failure then
							disabled[kind] = true
							if sounds[kind] then sounds[kind]:Destroy() end
							sounds[kind] = nil
						end
					end)
				end)
				if not ok then
					disabled[kind] = true
				end
			end)
		end
	end
end

local _muted = false

function UISound.setMuted(flag)
	_muted = flag and true or false
	UISound.setEnabled(not _muted)
end

function UISound.isMuted()
	return _muted
end

return UISound
