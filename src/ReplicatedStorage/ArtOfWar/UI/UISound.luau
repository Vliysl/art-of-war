local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local UISound = {}

-- Hover SFX only makes sense with a cursor; never play it on touch devices.
local IS_TOUCH = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

local ASSETS = {
	click   = "rbxassetid://15051647685",
	whoosh  = "rbxassetid://135595810064855",
	hover   = "rbxassetid://107511012621133",
	notify  = "rbxasset://sounds/electronicpingshort.wav",
	alert   = "rbxassetid://4590657391",
	claim   = "rbxassetid://130735746419880",
	phase   = "rbxasset://sounds/bass.wav",
	delete  = "rbxassetid://10066926605",
	economy  = "rbxassetid://99927446005550",  -- Economy window open/close
	military = "rbxassetid://140203539654892", -- Military window open/close
}

local PITCH = {
	click  = 1.0,
	whoosh = 1.0,
	hover  = 1.0,
	notify = 1.0,
	alert  = 1.0,
	claim  = 1.0,
	phase  = 0.85,
	delete = 1.0,
	economy  = 1.0,
	military = 1.0,
}

local VOLUMES = {
	click  = 0.4,
	whoosh = 0.5,
	hover  = 0.2,
	notify = 0.45,
	alert  = 0.55,
	claim  = 0.7,
	phase  = 0.35,
	delete = 0.5,
	economy  = 0.5,
	military = 0.5,
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
function UISound.delete() UISound.play("delete") end

function UISound.attachButton(button)
	if not button or not button:IsA("GuiButton") then return end
	if button:GetAttribute("AoWClickAttached") then return end
	button:SetAttribute("AoWClickAttached", true)
	-- Defer so callers can set AoWNoClickSound / AoWClickSound / AoWHoverSound on the button right
	-- after creation (ClaimScreen's CTA fires its own claim sound; Button.create tags danger buttons
	-- with AoWClickSound="delete" and prominent variants with AoWHoverSound="hover").
	task.defer(function()
		if not button or not button.Parent then return end
		if not button:GetAttribute("AoWNoClickSound") then
			button.MouseButton1Down:Connect(function()
				UISound.play(button:GetAttribute("AoWClickSound") or "click")
			end)
		end
		-- Hover is OPT-IN (only buttons tagged AoWHoverSound play it) so it stays on "major" buttons,
		-- and never on touch devices.
		local hoverKind = button:GetAttribute("AoWHoverSound")
		if hoverKind and not IS_TOUCH then
			button.MouseEnter:Connect(function()
				if button.Active == false then return end
				UISound.play(hoverKind)
			end)
		end
	end)
end

-- Auto-attach click sound to every GuiButton descendant of a ScreenGui.
-- Idempotent: SetAttribute("AoWClickAttached") guards against double-binding.
function UISound.attachAll(screenGui)
	if not screenGui then return end
	if screenGui:GetAttribute("AoWSoundAttachedAll") then return end
	screenGui:SetAttribute("AoWSoundAttachedAll", true)
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

-- Only one event sting may play at a time (see playAssetId).
local _eventStingActive = nil

-- One-shot event sting from an ARBITRARY asset id (e.g. a formable's authored formation audio). Non-looping,
-- 2D (parented to SoundService so everyone hears it equally), destroyed when it ends. Guards, per research:
--   * blank / non-string id -> no-op (a formable with no audio is silent, not an error),
--   * respects the player's "Event / Formation Audio" mute (LocalPlayer attribute MuteEventAudio, set by
--     the Settings toggle -- same pattern as HideOtherCustomColors),
--   * ONE sting at a time: a second concurrent formation is dropped rather than stacked into noise.
-- `volume` defaults to a moderate 0.6. Returns the Sound (or nil if it didn't play).
function UISound.playAssetId(id, volume)
	if type(id) ~= "string" or id == "" then
		return nil
	end
	local lp = Players.LocalPlayer
	if lp and lp:GetAttribute("MuteEventAudio") then
		return nil
	end
	if _eventStingActive then
		return nil
	end
	local snd = Instance.new("Sound")
	snd.Name = "AoWEventSting"
	snd.SoundId = id
	snd.Volume = volume or 0.6
	snd.Looped = false
	snd.PlayOnRemove = false
	snd.Parent = SoundService
	_eventStingActive = snd
	local function clear()
		if _eventStingActive == snd then
			_eventStingActive = nil
		end
		if snd then
			snd:Destroy()
		end
	end
	snd.Ended:Connect(clear)
	snd:Play()
	-- Backstop: a bad/never-loading id would otherwise pin the single-sting slot forever.
	task.delay(12, clear)
	return snd
end

-- Boot entry: hook EVERY ScreenGui under PlayerGui (current + future), so default click/hover
-- sounds reach all UI regardless of which ScreenGui a button lives in -- the live HUD builds its
-- own ScreenGuis (Hud.makeLayer) outside UIRoot, which UIRoot.attachAll never saw. Also preloads.
function UISound.start()
	local player = Players.LocalPlayer
	if not player then return end
	-- The Settings "Sound" toggle writes the SoundMuted attribute; honor it live (SFX vs Music split).
	UISound.setMuted(player:GetAttribute("SoundMuted") == true)
	player:GetAttributeChangedSignal("SoundMuted"):Connect(function()
		UISound.setMuted(player:GetAttribute("SoundMuted") == true)
	end)
	local pg = player:WaitForChild("PlayerGui")
	local function hook(inst)
		if inst:IsA("ScreenGui") then UISound.attachAll(inst) end
	end
	for _, c in ipairs(pg:GetChildren()) do hook(c) end
	pg.ChildAdded:Connect(hook)
	UISound.preload()
end

return UISound
