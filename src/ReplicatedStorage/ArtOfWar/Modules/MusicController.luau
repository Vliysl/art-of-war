-- MusicController (client)
-- Adaptive background music: crossfades between phase beds (loading / menu / peacetime / war[/losing] /
-- battle[/losing]) chosen from the player's claimed nation + live ClientStateCache, with regional themes
-- resolved by Data/MusicTracks. Layers one-shot stings on key events (ducking the bed under them). Fully
-- event-driven (no per-frame work). Silent and harmless until real track ids are authored in MusicTracks AND
-- WorldConstants.EnableMusic is flipped on. Mirrors CombatView's lifecycle, UISound's Sound/preload
-- mechanics, and RenderDistanceController's attribute-live settings pattern.

local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local aow = ReplicatedStorage:WaitForChild("ArtOfWar")
local modules = aow:WaitForChild("Modules")
local WorldConstants = require(aow:WaitForChild("Shared"):WaitForChild("WorldConstants"))
local MusicTracks = require(aow:WaitForChild("Data"):WaitForChild("MusicTracks"))
local ClientStateCache = require(modules:WaitForChild("ClientStateCache"))

local MusicController = {}

local Phase = MusicTracks.Phase
local Tuning = MusicTracks.Tuning

-- Escalation rank derived from the single ordered list in MusicTracks (no hand-kept duplicate).
local RANK = {}
for i, p in ipairs(MusicTracks.PhaseOrder) do
	RANK[p] = i
end

-- Engine-only tuning (composer-facing fades/holds live in MusicTracks.Tuning).
local DEBOUNCE = 0.35 -- seconds to coalesce a delta burst before resolving
local LOAD_BACKSTOP = 6 -- seconds; a chosen id still at TimeLength 0 is treated as failed and re-resolved
local BOOT_TIMEOUT = 25 -- seconds; if AoWBootComplete never fires, fall through to normal play anyway
local STING_DUCK_SECONDS = 3 -- how long the bed stays ducked under a one-shot sting
local HOLD_ON_BLANK = true -- empty fallback ladder -> keep the current bed rather than cut to silence
-- Intensity thresholds. battle.tide is normalized [-1, 1]; war.score is +/-100 and exhaustion is 0..100.
local TIDE_LOSING = 0.4 -- viewer battle tide at/below -this (on the -1..1 scale) => battle_losing
local WAR_LOSING_SCORE = 15 -- my war score at/below -this => war_losing
local WAR_LOSING_EXHAUSTION = 60 -- my war exhaustion at/above this => war_losing

local lp = nil
local started = false
local bootComplete = false
local focused = true

local soundGroup, soundA, soundB, duckValue
local active = nil -- whichever of soundA/soundB currently holds the playing bed
local currentTrackId = ""
local currentCellKey = nil -- "phase:themeKey" of the resolved cell (so we don't re-randomize a playlist)
local tweens = {} -- [Instance] = in-flight Tween (cancel-before-restart)
local appliedPhase = nil
local appliedTag = nil
local appliedAt = 0
local evalToken = 0
local duckToken = 0
local disabledTracks = {} -- [assetId] = true once a preload failed this session
local stings = {} -- [Sound] = true for in-flight one-shot stings (so destroy can reap them)
local playlistLast = {} -- [cellKey] = last index chosen (avoid immediate repeat)
local preloaded = {} -- [assetId] = true once warmed
local auditionOverride = nil -- { phase, regionKeys } forced by the dev audition API

-- subscription / connection handles (all torn down in destroy)
local warsSub, battlesSub, armiesSub, countriesSub, snapshotSub
local countryTagConn, volConn, muteConn, bootConn, focusConn, unfocusConn

-- Forward declarations for the eval cycle.
local runEval, scheduleEval

local function dbg(...)
	if WorldConstants.MusicDebug then
		print("[Music]", ...)
	end
end

-- ---- audio plumbing -------------------------------------------------------

local function ensureAudio()
	if soundGroup and soundGroup.Parent and soundA and soundB then
		return
	end
	if not soundGroup then
		soundGroup = Instance.new("SoundGroup")
		soundGroup.Name = "AoWMusic"
		soundGroup.Volume = 0
		soundGroup.Parent = SoundService
	end
	if not duckValue then
		-- A tweenable 0.35..1 multiplier for sidechain-style ducking, folded into the master gain.
		duckValue = Instance.new("NumberValue")
		duckValue.Name = "Duck"
		duckValue.Value = 1
		duckValue.Parent = soundGroup
	end
	local function makeSound(name)
		local snd = Instance.new("Sound")
		snd.Name = name
		snd.Looped = true
		snd.PlayOnRemove = false
		snd.Volume = 0
		snd.SoundGroup = soundGroup
		snd.Parent = SoundService
		return snd
	end
	soundA = soundA or makeSound("AoWMusicA")
	soundB = soundB or makeSound("AoWMusicB")
end

local function eachBed(fn)
	if soundA then
		fn(soundA)
	end
	if soundB then
		fn(soundB)
	end
end

local function normalizeVolume(raw)
	if type(raw) ~= "number" then
		return WorldConstants.MusicDefaultVolume or 0.6
	end
	if raw > 1 then
		raw = raw / 100 -- tolerate a 0..100 slider as well as 0..1
	end
	return math.clamp(raw, MusicTracks.VolumeMin, MusicTracks.VolumeMax)
end

-- Master gain = user volume (0 when muted) x duck. Driving the SoundGroup keeps the per-bed crossfade tweens
-- (which move each Sound's own Volume, up to its per-track gain) independent of the user's setting + ducking.
local function applyMasterVolume()
	if not soundGroup then
		return
	end
	local muted = lp and lp:GetAttribute("MusicMuted") == true
	local base = muted and 0 or normalizeVolume(lp and lp:GetAttribute("MusicVolume"))
	soundGroup.Volume = base * (duckValue and duckValue.Value or 1)
end

-- Pause the decoding beds entirely when muted or the window is unfocused (mobile battery / desktop courtesy),
-- vs the volume-0 path which keeps them streaming. Resume cleanly on unmute / refocus.
local function shouldPlay()
	local muted = lp and lp:GetAttribute("MusicMuted") == true
	return not muted and focused
end

local function updatePlayback()
	local play = shouldPlay()
	eachBed(function(snd)
		if play and snd.IsPaused and snd == active then
			snd:Resume() -- only the active bed; a stopped/idle bed is also IsPaused but must stay stopped
		elseif not play and snd.IsPlaying then
			snd:Pause()
		end
	end)
end

-- Tween any instance property (bed Volume or the duck NumberValue), cancel-before-restart, keyed by instance.
local function fadeTo(inst, prop, target, dur, easingDir, onDone)
	local existing = tweens[inst]
	if existing then
		existing:Cancel()
	end
	local info = TweenInfo.new(dur, Enum.EasingStyle.Sine, easingDir or Enum.EasingDirection.Out)
	local tween = TweenService:Create(inst, info, { [prop] = target })
	tweens[inst] = tween
	tween.Completed:Connect(function()
		if tweens[inst] == tween then
			tweens[inst] = nil
		end
		if onDone then
			onDone()
		end
	end)
	tween:Play()
end

-- Sidechain-style duck: dip the master under a sting/super-event, then restore. Overlapping ducks coalesce
-- via duckToken so the last one owns the restore.
local function duck(seconds)
	if not duckValue then
		return
	end
	duckToken += 1
	local myToken = duckToken
	fadeTo(duckValue, "Value", Tuning.DuckFactor or 0.35, Tuning.DuckFade or 0.25)
	task.delay(seconds, function()
		if myToken == duckToken and duckValue then
			fadeTo(duckValue, "Value", 1, Tuning.DuckFade or 0.25)
		end
	end)
end
MusicController.duck = duck

-- Detect a never-loading / bad id: PreloadAsync Failure marks it disabled and re-resolves so the fallback
-- ladder skips it; a TimeLength backstop reaps ids whose callback never fires.
local function watchLoad(assetId, snd)
	task.spawn(function()
		local ok = pcall(function()
			ContentProvider:PreloadAsync({ snd }, function(_, status)
				if status == Enum.AssetFetchStatus.Failure then
					disabledTracks[assetId] = true
					if currentTrackId == assetId then
						scheduleEval(0)
					end
				end
			end)
		end)
		if not ok then
			disabledTracks[assetId] = true
			if currentTrackId == assetId then
				scheduleEval(0)
			end
		end
	end)
	task.delay(LOAD_BACKSTOP, function()
		if
			not disabledTracks[assetId]
			and currentTrackId == assetId
			and snd.SoundId == assetId
			and snd.TimeLength == 0
		then
			disabledTracks[assetId] = true
			scheduleEval(0)
		end
	end)
end

-- Warm likely-next assets so a transition doesn't fade over a cold stream (blank/already-warm ids are skipped).
local function preloadIds(ids)
	local todo = {}
	for _, id in ipairs(ids) do
		if type(id) == "string" and id ~= "" and not preloaded[id] then
			preloaded[id] = true
			todo[#todo + 1] = id
		end
	end
	if #todo > 0 then
		task.spawn(function()
			pcall(function()
				ContentProvider:PreloadAsync(todo)
			end)
		end)
	end
end

local function applyLoopRegion(snd, loop)
	local a = type(loop) == "table" and tonumber(loop[1]) or nil
	local b = type(loop) == "table" and tonumber(loop[2]) or nil
	if a and b then
		snd.LoopRegion = NumberRange.new(math.min(a, b), math.max(a, b))
	else
		snd.LoopRegion = NumberRange.new(0, 0) -- whole sound
	end
end

-- Ping-pong the two beds: fade the incoming up (to its per-track gain) while the outgoing fades down, then
-- stop (not destroy) the outgoing. Equal-power curve (Out on the incoming, In on the outgoing) avoids a
-- mid-crossfade loudness dip. descriptor = { id, gain?, loop? } or nil for silence.
local function crossfadeTo(descriptor, dur)
	ensureAudio()
	local assetId = descriptor and descriptor.id or ""
	if assetId == "" then
		if HOLD_ON_BLANK then
			return -- nothing authored down the whole ladder: keep whatever is playing
		end
		if active then
			local outgoing = active
			fadeTo(outgoing, "Volume", 0, dur, Enum.EasingDirection.In, function()
				if outgoing ~= active then
					outgoing:Stop()
				end
			end)
			active = nil
			currentTrackId = ""
			currentCellKey = nil
		end
		return
	end
	if assetId == currentTrackId and active then
		return -- same bed already playing; never restart a loop on incidental churn
	end
	local incoming = (active == soundA) and soundB or soundA
	local outgoing = active
	incoming.SoundId = assetId
	incoming.Volume = 0
	applyLoopRegion(incoming, descriptor.loop)
	incoming:Play()
	fadeTo(incoming, "Volume", math.clamp(descriptor.gain or 1, 0, 1), dur, Enum.EasingDirection.Out)
	if outgoing then
		fadeTo(outgoing, "Volume", 0, dur, Enum.EasingDirection.In, function()
			if outgoing ~= active then
				outgoing:Stop()
			end
		end)
	end
	active = incoming
	currentTrackId = assetId
	watchLoad(assetId, incoming)
	updatePlayback()
	dbg("bed ->", assetId, "gain", descriptor.gain or 1)
end

-- ---- state resolution (pure-ish; reads cache + attributes) ----------------

local function localTag()
	return lp and lp:GetAttribute("CountryTag")
end

local function isAtWar(myTag)
	for _, war in ClientStateCache.allWars() do
		if war.status == "active" and (war.attackerTag == myTag or war.defenderTag == myTag) then
			return true
		end
	end
	return false
end

-- True if my side's war score / exhaustion says I am losing an active war.
local function warIsLosing(myTag)
	for _, war in ClientStateCache.allWars() do
		if war.status == "active" and (war.attackerTag == myTag or war.defenderTag == myTag) then
			local mine = (war.attackerTag == myTag) and (war.score or 0) or -(war.score or 0)
			local exh = (war.attackerTag == myTag) and (war.attackerExhaustion or 0) or (war.defenderExhaustion or 0)
			if mine <= -WAR_LOSING_SCORE or exh >= WAR_LOSING_EXHAUSTION then
				return true
			end
		end
	end
	return false
end

local function armyIsMine(id, myTag)
	local army = ClientStateCache.getArmy(id)
	return army ~= nil and army.ownerTag == myTag
end

local function sideHasMine(ids, myTag)
	if type(ids) ~= "table" then
		return false
	end
	for _, id in ipairs(ids) do
		if armyIsMine(id, myTag) then
			return true
		end
	end
	return false
end

-- (inBattle, worstTide): whether the player is engaged, and the most-against-them viewer-relative tide.
local function battleStatus(myTag)
	local inBattle, worst = false, math.huge
	for _, battle in ClientStateCache.allBattles() do
		local mine
		if sideHasMine(battle.attackerArmyIds, myTag) then
			mine = battle.tide or 0
		elseif sideHasMine(battle.defenderArmyIds, myTag) then
			mine = -(battle.tide or 0)
		end
		if mine ~= nil then
			inBattle = true
			if mine < worst then
				worst = mine
			end
		end
	end
	return inBattle, worst
end

local function resolveState()
	if auditionOverride then
		return { phase = auditionOverride.phase, regionKeys = auditionOverride.regionKeys, tag = "__audition__" }
	end
	if not bootComplete then
		return { phase = Phase.Loading, regionKeys = { MusicTracks.DefaultRegionKey }, tag = "__loading__" }
	end
	local myTag = localTag()
	if not myTag then
		return { phase = Phase.Menu, regionKeys = { MusicTracks.DefaultRegionKey }, tag = nil }
	end
	local country = ClientStateCache.getCountry(myTag)
	local regionKeys = MusicTracks.regionKeysFor(country, ClientStateCache.getProvince)
	local phase
	local inBattle, worstTide = battleStatus(myTag)
	if inBattle then
		phase = (worstTide <= -TIDE_LOSING) and Phase.BattleLosing or Phase.Battle
	elseif isAtWar(myTag) then
		phase = warIsLosing(myTag) and Phase.WarLosing or Phase.War
	else
		phase = Phase.Peacetime
	end
	return { phase = phase, regionKeys = regionKeys, tag = myTag }
end

local function isDisabled(tid)
	return disabledTracks[tid] == true
end

-- Choose one descriptor from a resolved cell: single -> it; playlist -> random, avoiding an immediate repeat.
local function chooseEntry(cellKey, descriptors)
	local n = #descriptors
	if n <= 1 then
		return descriptors[1]
	end
	local idx = math.random(1, n)
	if idx == playlistLast[cellKey] then
		idx = (idx % n) + 1
	end
	playlistLast[cellKey] = idx
	return descriptors[idx]
end

local function fadeSecondsFor(phase)
	if phase == Phase.Battle or phase == Phase.BattleLosing then
		return Tuning.FadeBattle or 0.8
	end
	return Tuning.FadeDefault or 1.5
end

local function apply(state)
	local phaseChanged = state.phase ~= appliedPhase or state.tag ~= appliedTag
	appliedPhase = state.phase
	appliedTag = state.tag
	if phaseChanged then
		appliedAt = os.clock() -- only a genuine phase/identity change re-arms the de-escalation hold
	end
	dbg("apply", state.phase, "tag", tostring(state.tag), "region", table.concat(state.regionKeys, ">"))

	local cellKey, descriptors = MusicTracks.resolveCell(state.phase, state.regionKeys, isDisabled)
	if not cellKey then
		crossfadeTo(nil, fadeSecondsFor(state.phase))
		return
	end
	-- Warm the likely-next beds once we settle into peacetime, so a peace->battle jump isn't cold.
	if state.phase == Phase.Peacetime then
		preloadIds({
			MusicTracks.pickTrack(Phase.War, state.regionKeys, isDisabled),
			MusicTracks.pickTrack(Phase.Battle, state.regionKeys, isDisabled),
		})
	end
	-- Already on this cell and the playing track is still a valid entry -> keep it (don't re-randomize a loop).
	if cellKey == currentCellKey then
		for _, d in ipairs(descriptors) do
			if d.id == currentTrackId then
				return
			end
		end
	end
	currentCellKey = cellKey
	crossfadeTo(chooseEntry(cellKey, descriptors), fadeSecondsFor(state.phase))
end

-- ---- one-shot stings + anthems --------------------------------------------

local function playOneShot(descriptor, defaultGain)
	if not descriptor then
		return
	end
	ensureAudio()
	local snd = Instance.new("Sound")
	snd.Name = "AoWMusicSting"
	snd.SoundId = descriptor.id
	snd.Looped = false
	snd.PlayOnRemove = false
	snd.Volume = math.clamp(descriptor.gain or defaultGain or 0.9, 0, 1)
	snd.SoundGroup = soundGroup -- governed by MusicVolume / MusicMuted like the bed
	snd.Parent = SoundService
	stings[snd] = true
	local function clear()
		stings[snd] = nil
		if snd then
			snd:Destroy()
		end
	end
	snd.Ended:Connect(clear)
	task.delay(20, clear) -- backstop for a never-loading sting
	snd:Play()
	duck(STING_DUCK_SECONDS)
	dbg("sting ->", descriptor.id)
end

-- Public: fed the NotificationChannel payload from ClientBoot. Maps eventType -> an authored sting; for a
-- "World News" super-event (which plays its own audio) it just ducks the bed to make room.
function MusicController.onEvent(payload)
	if not started or not WorldConstants.EnableMusic or type(payload) ~= "table" then
		return
	end
	if payload.kind == "superevent" then
		duck(4)
		return
	end
	if type(payload.eventType) == "string" then
		playOneShot(MusicTracks.resolveSting(payload.eventType, isDisabled))
	end
end

local function playAnthem(regionKeys)
	playOneShot(MusicTracks.resolveAnthem(regionKeys, isDisabled))
end

-- ---- debounce + asymmetric hysteresis ------------------------------------

function scheduleEval(delay)
	if type(delay) ~= "number" then
		delay = nil -- called as a subscription callback: ignore the (value, path) args
	end
	evalToken += 1
	local myToken = evalToken
	task.delay(delay or DEBOUNCE, function()
		if myToken == evalToken then
			runEval()
		end
	end)
end

function runEval()
	if not started then
		return
	end
	local state = resolveState()
	local identityChanged = state.tag ~= appliedTag
	-- Menu/Loading (context) OR switching to a DIFFERENT nation is a hard switch, not thrash: apply now.
	if state.phase == Phase.Menu or state.phase == Phase.Loading or identityChanged then
		local claimingNation = identityChanged
			and type(state.tag) == "string"
			and state.tag ~= "__loading__"
			and state.tag ~= "__audition__"
			and appliedTag ~= "__loading__"
			and appliedTag ~= "__audition__"
		apply(state)
		if claimingNation then
			playAnthem(state.regionKeys) -- flourish as the player's peacetime bed begins
		end
		return
	end
	if appliedPhase == nil then
		apply(state)
		return
	end
	local dp = RANK[state.phase]
	local ap = RANK[appliedPhase]
	if not dp or not ap then
		apply(state) -- unknown phase (e.g. a typo'd audition input): apply defensively, never compare nil
		return
	end
	if dp > ap then
		apply(state) -- ESCALATE immediately (into a more intense phase)
		return
	end
	if dp < ap then
		-- DE-ESCALATE only after the current phase's minimum hold (stops a 1s battle / declare-spam thrashing).
		local held = os.clock() - appliedAt
		local need = (Tuning.HoldByPhase and Tuning.HoldByPhase[appliedPhase]) or 0
		if held >= need then
			apply(state)
		else
			scheduleEval(need - held) -- re-check exactly when the hold expires
		end
		return
	end
	-- Same phase, same nation: re-apply only if the track we would now pick differs from what is playing --
	-- e.g. the current track failed to load and got disabled, so descend to its fallback. Skip when the pick
	-- is empty and we intend to hold the current bed, so this converges (no re-walk on every delta).
	local pick = MusicTracks.pickTrack(state.phase, state.regionKeys, isDisabled)
	if pick ~= currentTrackId and (pick ~= "" or not HOLD_ON_BLANK) then
		apply(state)
	end
end

-- ---- lifecycle -----------------------------------------------------------

function MusicController.start()
	if started then
		return
	end
	lp = Players.LocalPlayer
	if not lp then
		return
	end
	started = true
	focused = true
	ensureAudio()
	if lp:GetAttribute("MusicVolume") == nil then
		lp:SetAttribute("MusicVolume", WorldConstants.MusicDefaultVolume or 0.6) -- default-on; unset = default volume
	end
	duckValue.Changed:Connect(applyMasterVolume)
	applyMasterVolume()
	preloadIds({
		MusicTracks.pickTrack(Phase.Loading, { MusicTracks.DefaultRegionKey }),
		MusicTracks.pickTrack(Phase.Menu, { MusicTracks.DefaultRegionKey }),
		MusicTracks.pickTrack(Phase.Peacetime, { MusicTracks.DefaultRegionKey }),
	})

	-- Register synchronously (before the boot's deferred RequestFullState) so no early delta is missed.
	warsSub = ClientStateCache.onChangePrefix("wars", scheduleEval)
	battlesSub = ClientStateCache.onChangePrefix("battles", scheduleEval)
	armiesSub = ClientStateCache.onChangePrefix("armies", scheduleEval) -- army ownership resolves battle involvement
	countriesSub = ClientStateCache.onChangePrefix("countries", scheduleEval) -- capital/culture/tech changes re-theme
	snapshotSub = ClientStateCache.onChange("snapshot", scheduleEval) -- cold-start / reconnect full snapshot

	countryTagConn = lp:GetAttributeChangedSignal("CountryTag"):Connect(scheduleEval) -- claim/unclaim/re-claim
	volConn = lp:GetAttributeChangedSignal("MusicVolume"):Connect(applyMasterVolume)
	muteConn = lp:GetAttributeChangedSignal("MusicMuted"):Connect(function()
		applyMasterVolume()
		updatePlayback()
	end)
	focusConn = UserInputService.WindowFocused:Connect(function()
		focused = true
		updatePlayback()
	end)
	unfocusConn = UserInputService.WindowFocusReleased:Connect(function()
		focused = false
		updatePlayback()
	end)

	-- Play a loading bed over the boot cover immediately; the gameplay beds begin once the map is ready.
	scheduleEval(0)
	if lp:GetAttribute("AoWBootComplete") then
		bootComplete = true
	else
		bootConn = lp:GetAttributeChangedSignal("AoWBootComplete"):Connect(function()
			if lp:GetAttribute("AoWBootComplete") then
				bootComplete = true
				if bootConn then
					bootConn:Disconnect()
					bootConn = nil
				end
				scheduleEval(0)
			end
		end)
		task.delay(BOOT_TIMEOUT, function()
			if started and not bootComplete then
				bootComplete = true -- self-heal: never stay stuck on the loading bed if the boot tail died
				scheduleEval(0)
			end
		end)
	end
end

MusicController.init = MusicController.start

-- Dev audition (admin-gated by the caller): force a specific (phase, region) bed, or resume live resolution.
function MusicController.previewPhase(phase, regionKey)
	if not started or not RANK[phase] then
		return -- ignore a typo'd / unknown phase
	end
	auditionOverride = {
		phase = phase,
		regionKeys = { regionKey or MusicTracks.DefaultRegionKey, MusicTracks.DefaultRegionKey },
	}
	scheduleEval(0)
end

function MusicController.clearAudition()
	auditionOverride = nil
	scheduleEval(0)
end

function MusicController.destroy()
	for inst, tween in pairs(tweens) do
		tween:Cancel()
		tweens[inst] = nil
	end
	for _, conn in { countryTagConn, volConn, muteConn, bootConn, focusConn, unfocusConn } do
		conn:Disconnect()
	end
	for _, unsub in { warsSub, battlesSub, armiesSub, countriesSub, snapshotSub } do
		unsub()
	end
	countryTagConn, volConn, muteConn, bootConn, focusConn, unfocusConn = nil, nil, nil, nil, nil, nil
	warsSub, battlesSub, armiesSub, countriesSub, snapshotSub = nil, nil, nil, nil, nil
	for s in pairs(stings) do
		s:Destroy()
	end
	if soundA then
		soundA:Destroy()
	end
	if soundB then
		soundB:Destroy()
	end
	if soundGroup then
		soundGroup:Destroy() -- also destroys the child duck NumberValue
	end
	soundA, soundB, soundGroup, duckValue, active = nil, nil, nil, nil, nil
	currentTrackId, currentCellKey = "", nil
	appliedPhase, appliedTag = nil, nil
	disabledTracks, playlistLast, preloaded, stings = {}, {}, {}, {}
	auditionOverride = nil
	evalToken, duckToken = evalToken + 1, duckToken + 1 -- invalidate any pending scheduled/restore callbacks
	bootComplete = false
	started = false
end

return MusicController
