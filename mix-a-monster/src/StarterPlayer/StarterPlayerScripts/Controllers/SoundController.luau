--!strict
--[[
	SoundController.luau — every sound the client plays.
	GDD §2 (pillar 5: "sound is identity"), §7.5, §11.4.

	THE REGISTRY API. Everything else in the client asks this file to make a
	noise and never touches a Sound itself:

	    play(name)                     -- a named UI/event cue, see CUES below
	    playMixling(view, position?)   -- a Mixling's own voice + layer
	    playMusic() / stopMusic()      -- the Blendburg bed
	    setEnabled(kind, on)           -- "sfx" | "music", render-side only

	WHY ONE FILE OWNS ALL OF IT: two SoundGroups (SFX and Music) hang off
	SoundService, every sound this game plays is routed into one of them, and
	the settings toggles are then two assignments instead of a hunt through
	eight screens for a stray Sound instance. It also means a screen can never
	leak a looping sound: the only loops that exist are declared in CUES with
	the length that stops them.

	AUDIO HAS NOT LANDED YET. The owner produces all of it (GDD §7.5), so at
	launch every lookup under ReplicatedStorage/Assets/Sounds misses. A miss is
	never an error and never a print — a cue with no asset clones
	Assets/Sounds/UI/Default at that cue's own pitch and volume so the events
	are at least told apart, and with no Default either it is a Sound with no
	SoundId, which is silent and harmless. THE ASSET NAME IS THE CONTRACT: drop
	a Sound named "RollSlam" into Assets/Sounds/UI and RollSlam starts working
	with no code change.

	NOTHING HERE DECIDES ANYTHING. Rarity, position and identity all arrive
	from the server; this file only chooses how loud they are.
]]

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Config = ReplicatedStorage:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Config:WaitForChild("Constants"))
local Rarity = require(Config:WaitForChild("Rarity"))
local Assembler = require(Shared:WaitForChild("MixlingAssembler"))
local Types = require(Shared:WaitForChild("Types"))
local UiKit = require(Shared:WaitForChild("UiKit"))
local Util = require(Shared:WaitForChild("Util"))

local ClientState = require(script.Parent.Parent:WaitForChild("ClientState"))

local SoundController = {}
SoundController.Name = "SoundController"

-- ── Local tunables ───────────────────────────────────────────────────────
-- Mix levels, not balance values. Constants owns everything the player earns
-- or waits for (GDD §17); how loud a click is has never been a balance
-- question, and putting it there would bury the numbers that matter.

local SFX_VOLUME = 0.9
local MUSIC_VOLUME = 0.35
local DUCK_LEVEL = 0.22 -- how far the bed drops under a big reveal
local DUCK_IN = 0.12 -- fast down: the slam must land in a hole, not a fade
local DUCK_OUT = 0.8 -- slow up: the music creeps back while the card is read
local ONE_SHOT_LIFETIME = 8 -- cleanup ceiling; longer than any voice + tail
local IDLE_TICK = 1 -- one pass over the Dens per second, like DenService's
local REVEAL_VOLUME_BASE = 0.45
local REVEAL_VOLUME_STEP = 0.08 -- a rarer reveal is louder as well as lower

-- How long the reveal owns the screen at its longest: the duck lasts exactly
-- that, and so does the spin loop. Both numbers are the Mixer's, so retuning
-- the roll retunes the sound that covers it (GDD §8.1).
local REVEAL_WINDOW = Constants.REVEAL_SECONDS + Constants.REVEAL_SUSPENSE_SECONDS

-- Asset names. Studio layout is fixed by ARCHITECTURE.md §6.
local UI_FOLDER = "UI"
local MUSIC_FOLDER = "Music"
local DEFAULT_CUE = "Default" -- the stand-in cloned when a named cue is absent
local MUSIC_TRACK = "Blendburg"

-- World lookups for the idle pass. WorldService builds Workspace/Blendburg
-- and a "Dens" folder inside it; DenService stamps each display model with a
-- "MixlingId" StringValue, which is how a Mixling on a pedestal is told from
-- the scenery around it.
local PEDESTAL_TAG = "Pedestal"
local WORLD_ROOT = "Blendburg"
local DENS_FOLDER = "Dens"
local MIXLING_MARKER = "MixlingId"
local SOUND_FOLDER = "MixSound" -- built by MixlingAssembler onto the PrimaryPart

local rng = Random.new() -- cosmetic only: which pedestal chirps next

-- ── Asset lookup ─────────────────────────────────────────────────────────

local function soundAsset(category: string, name: string): Sound?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return nil
	end
	local sounds = assets:FindFirstChild("Sounds")
	if not sounds then
		return nil
	end
	local folder = sounds:FindFirstChild(category)
	if not folder then
		return nil
	end
	local found = folder:FindFirstChild(name)
	return if found and found:IsA("Sound") then found else nil
end

-- ── Groups ───────────────────────────────────────────────────────────────
-- Built at require time rather than in start(): a controller earlier in the
-- boot order may fire a cue before this one's start() runs, and a group that
-- does not exist yet would silently route that cue past the settings toggle.

local function group(name: string): SoundGroup
	local created = Instance.new("SoundGroup")
	created.Name = name
	created.Volume = 1
	created.Parent = SoundService
	return created
end

local sfxGroup = group("MixSFX")
local musicGroup = group("MixMusic")

-- 2D playback: a Sound under a Folder has no position, so a UI cue is at the
-- listener's ear wherever the camera happens to be.
local cueHolder = Instance.new("Folder")
cueHolder.Name = "MixCues"
cueHolder.Parent = SoundService

-- ── Settings, volumes and the duck ───────────────────────────────────────

local sfxOn = true
local musicOn = true
local bedWanted = true -- stopMusic() clears this; a settings sync must not undo it
local bed: Sound? = nil
local ducking = false
local duckToken = 0

local function musicTarget(): number
	local base = if musicOn then MUSIC_VOLUME else 0
	return if ducking then base * DUCK_LEVEL else base
end

local function stopBed()
	local current = bed
	bed = nil
	if not current then
		return
	end
	current:Stop()
	current:Destroy()
end

local function startBed()
	if bed then
		return
	end
	local template = soundAsset(MUSIC_FOLDER, MUSIC_TRACK)
	if not template then
		return -- no track has landed; silence is the correct launch state
	end
	local sound = template:Clone()
	sound.Name = MUSIC_TRACK
	sound.Looped = true
	sound.SoundGroup = musicGroup
	sound.Parent = cueHolder
	sound:Play()
	bed = sound
end

--[[
	The whole of the two settings toggles. A muted stream still costs a phone
	bandwidth and battery, so music that is off is stopped rather than merely
	silenced; SFX are one-shots, so a zeroed group is enough for them.
]]
local function applyVolumes()
	sfxGroup.Volume = if sfxOn then SFX_VOLUME else 0
	musicGroup.Volume = musicTarget()
	if musicOn and bedWanted then
		startBed()
	else
		stopBed()
	end
end

--[[
	GDD §2, pillar 1: the roll is the show and nothing may compete with it. A
	Legendary+ reveal drops the bed for the length of the reveal and lets it
	back up underneath the result card.

	The token is what makes overlapping ducks safe: a second reveal landing
	mid-duck takes ownership, and the first one's restore does nothing instead
	of lifting the music into the middle of the second slam.
]]
local function duckMusic()
	duckToken += 1
	local token = duckToken
	ducking = true
	UiKit.tween(musicGroup, { Volume = musicTarget() }, DUCK_IN)

	task.delay(REVEAL_WINDOW, function()
		if token ~= duckToken then
			return
		end
		ducking = false
		UiKit.tween(musicGroup, { Volume = musicTarget() }, DUCK_OUT)
	end)
end

-- The server owns the settings (GDD §11.3); this reads the cache and never
-- writes it. The settings screen sends SetSetting, the profile comes back,
-- and this runs again.
local function applySettings()
	local settings = ClientState.get().settings
	sfxOn = settings.sfx ~= false
	musicOn = settings.music ~= false
	applyVolumes()
end

-- ── Cues ─────────────────────────────────────────────────────────────────
--[[
	Every named sound in the game. `pitch` and `volume` are the stand-in mix
	used when Assets/Sounds/UI/<Name> does not exist yet — an authored asset
	arrives with the owner's own mix and keeps it, because a sound designer's
	levels beat a programmer's guesses.

	`loop` is a length, not a flag: a looping cue that nobody can stop is how
	a spin sound ends up playing under the whole session, so the only loop in
	the game stops itself after the reveal it belongs to.
]]

type Cue = {
	pitch: number,
	volume: number,
	loop: number?, -- seconds before the loop stops itself
	silences: string?, -- cue this one cuts off (the slam kills the spin)
	duck: boolean?,
}

local CUES: { [string]: Cue } = {
	Click = { pitch = 1.00, volume = 0.35 },
	RollSpin = { pitch = 1.00, volume = 0.55, loop = REVEAL_WINDOW },
	RollSlam = { pitch = 0.90, volume = 0.85, silences = "RollSpin" },
	Place = { pitch = 1.00, volume = 0.60 },
	Steal = { pitch = 0.95, volume = 0.70 },
	Bonk = { pitch = 1.10, volume = 0.80 },
	Alarm = { pitch = 1.00, volume = 0.85 },
	Fanfare = { pitch = 1.00, volume = 0.90, duck = true },
	Purchase = { pitch = 1.05, volume = 0.60 },
	Error = { pitch = 0.80, volume = 0.50 },
	Confetti = { pitch = 1.15, volume = 0.60 },
}

-- The reveal cues are pitched from the same Rarity.fx table that pitches a
-- Mixling's voice (GDD §7.3), so a Legendary sounds like a Legendary whether
-- the player is hearing the machine or the monster.
local REVEAL_TIERS: { [string]: number } = {
	RevealCommon = Rarity.COMMON,
	RevealRare = Rarity.RARE,
	RevealEpic = Rarity.EPIC,
	RevealLegendary = Rarity.LEGENDARY,
	RevealMythic = Rarity.MYTHIC,
	RevealSecret = Rarity.SECRET,
}

for name, tier in REVEAL_TIERS do
	CUES[name] = {
		pitch = Rarity.fx(tier).pitch,
		volume = math.min(1, REVEAL_VOLUME_BASE + tier * REVEAL_VOLUME_STEP),
		duck = tier >= Rarity.LEGENDARY,
	}
end

local looping: { [string]: Sound } = {}

local function stopCue(name: string)
	local sound = looping[name]
	if not sound then
		return
	end
	looping[name] = nil
	sound:Stop()
	sound:Destroy()
end

local function newCue(name: string, cue: Cue): Sound
	local authored = soundAsset(UI_FOLDER, name)
	if authored then
		local sound = authored:Clone()
		sound.Name = name
		sound.SoundGroup = sfxGroup
		sound.Parent = cueHolder
		return sound
	end

	-- Placeholder. Distinct pitch and volume per cue so that a single generic
	-- Default asset still produces a click that is not a bonk; with no Default
	-- present this is a Sound with no SoundId — silent, and deliberately so.
	local stand = soundAsset(UI_FOLDER, DEFAULT_CUE)
	local sound = if stand then stand:Clone() else Instance.new("Sound")
	sound.Name = name
	sound.PlaybackSpeed = cue.pitch
	sound.Volume = cue.volume
	sound.SoundGroup = sfxGroup
	sound.Parent = cueHolder
	return sound
end

--[[
	Plays a named cue. An unknown name is a caller's typo and must not take a
	screen down with it, so it returns quietly rather than erroring or
	printing — a per-click warn on a mobile client is its own bug.
]]
function SoundController.play(name: string)
	local cue = CUES[name]
	if not cue then
		return
	end
	if cue.silences then
		stopCue(cue.silences)
	end
	if not sfxOn then
		return -- and no duck either: ducking under a muted reveal is just a hole
	end
	if cue.duck then
		duckMusic()
	end

	local sound = newCue(name, cue)
	local length = cue.loop
	if length then
		stopCue(name) -- one spin at a time, however fast the player taps MIX
		sound.Looped = true
		looping[name] = sound
		task.delay(length, function()
			if looping[name] == sound then
				stopCue(name)
			end
		end)
	else
		Debris:AddItem(sound, math.max(ONE_SHOT_LIFETIME, sound.TimeLength))
	end
	sound:Play()
end

-- ── Mixling voices (GDD §7.5) ────────────────────────────────────────────
--[[
	Mixling sound = voice + layer played together, with rarity applying
	PlaybackSpeed. MixlingAssembler.buildSound is the one implementation of
	that pair — it resolves Voice_<Critter> and Layer_<Stuff>, applies
	Rarity.fx(tier).pitch and adds the Epic+ reverb — so this file builds the
	holder and does the mixing, never the assembly.
]]
local function playPair(critter: string, stuff: string, tier: number, position: Vector3?)
	local holder = Instance.new("Part")
	holder.Name = "MixlingVoice"
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.CastShadow = false
	holder.Transparency = 1
	holder.Size = Vector3.one

	local camera = Workspace.CurrentCamera
	if position then
		holder.CFrame = CFrame.new(position)
		holder.Parent = Workspace
	elseif camera then
		-- No position means UI: sit the holder on the listener so the voice is
		-- at full volume, and hang it off the camera so a result card never
		-- drops a part into the world.
		holder.CFrame = camera.CFrame
		holder.Parent = camera
	else
		holder.Parent = Workspace
	end

	local folder = Assembler.buildSound(holder, critter, stuff, tier)
	local longest = 0
	for _, child in folder:GetChildren() do
		if child:IsA("Sound") then
			child.SoundGroup = sfxGroup
			longest = math.max(longest, child.TimeLength)
			child:Play()
		end
	end
	Debris:AddItem(holder, math.max(ONE_SHOT_LIFETIME, longest))
end

--[[
	`position` places the voice in the world (a placement, a steal, a pedestal
	chirp); omitting it plays it on the camera for the reveal card.

	The duck is deliberately limited to the UI case: a Legendary two Dens away
	chirping on its pedestal has no claim on the music, but the reveal does.
]]
function SoundController.playMixling(view: Types.MixlingView, position: Vector3?)
	if not sfxOn then
		return
	end
	playPair(view.critter, view.stuff, view.rarity, position)
	if not position and view.rarity >= Rarity.LEGENDARY then
		duckMusic()
	end
end

-- ── Music ────────────────────────────────────────────────────────────────

function SoundController.playMusic()
	bedWanted = true
	applyVolumes()
end

function SoundController.stopMusic()
	bedWanted = false
	applyVolumes()
end

-- ── Settings ─────────────────────────────────────────────────────────────
--[[
	Render-side only. This mutes the mixer for immediate feedback when the
	player flips a toggle; the profile write is the settings screen's
	SetSetting, and the ProfileSync that comes back is what re-applies here.
	If the two ever disagree, this one is wrong (GDD §11.3).
]]
function SoundController.setEnabled(kind: string, on: boolean)
	if kind == "sfx" then
		sfxOn = on
	elseif kind == "music" then
		musicOn = on
	else
		return
	end
	applyVolumes()
end

-- ── Idle chirps on pedestals (GDD §7.5) ──────────────────────────────────
--[[
	Every Constants.IDLE_SOUND_INTERVAL seconds a placed Mixling may chirp, at
	most one per Constants.IDLE_SOUND_MIN_GAP_PER_DEN seconds per Den.

	THIS THROTTLE IS A COURTESY, NOT A BOUND. GDD §18 names ten Dens of idle
	sounds as a real cacophony risk and requires the limit server-side, "not
	just client" — DenService runs the same pass and its throttle is the one
	that actually holds, because a client can be edited and this one then
	protects nobody but the player running it. What this pass adds is a chirp
	that obeys THIS player's sfx toggle and skips a Mixling that is already
	speaking, neither of which the server can know.
]]

type DenIdle = { nextAt: number, lastAt: number }

local idleState: { [Instance]: DenIdle } = {}

local function densFolder(): Instance?
	local root = Workspace:FindFirstChild(WORLD_ROOT)
	if not root then
		return nil
	end
	return root:FindFirstChild(DENS_FOLDER)
end

-- The Den a world instance belongs to: the ancestor sitting directly in the
-- "Dens" folder. Grouping by that is what makes the per-Den throttle per-Den.
local function denOf(instance: Instance, dens: Instance): Instance?
	local node: Instance? = instance
	while node and node.Parent ~= dens do
		node = node.Parent
	end
	return node
end

local function mixlingsIn(den: Instance): { Model }
	local out: { Model } = {}
	for _, descendant in den:GetDescendants() do
		if descendant:IsA("Model") and descendant:FindFirstChild(MIXLING_MARKER) then
			table.insert(out, descendant)
		end
	end
	return out
end

--[[
	Every Den that currently has something standing in it, and what.

	GDD §11.4 asks the server to tag pedestals, so the tagged set is consulted
	first and needs no change here when DenService starts tagging. It does not
	today, so what actually runs is the walk below: the "Dens" folder is the
	Den list and the Assembler's MixlingId marker is the pedestal occupancy.
]]
local function occupiedDens(): { [Instance]: { Model } }
	local out: { [Instance]: { Model } } = {}
	local dens = densFolder()
	if not dens then
		return out
	end

	local roots: { Instance } = {}
	for _, tagged in CollectionService:GetTagged(PEDESTAL_TAG) do
		local den = denOf(tagged, dens)
		if den and not out[den] then
			out[den] = {}
			table.insert(roots, den)
		end
	end
	if #roots == 0 then
		roots = dens:GetChildren()
	end

	for _, den in roots do
		local models = mixlingsIn(den)
		if #models > 0 then
			out[den] = models
		else
			out[den] = nil
		end
	end
	return out
end

-- Plays a display model's own replicated voice. Returns false when it had
-- nothing to say, so a silent pick does not spend the Den's throttle window.
local function chirp(model: Model): boolean
	local root = model.PrimaryPart
	if not root then
		return false
	end

	local folder = root:FindFirstChild(SOUND_FOLDER)
	if folder then
		local voices: { Sound } = {}
		for _, child in folder:GetChildren() do
			if child:IsA("Sound") then
				if child.IsPlaying then
					return false -- already speaking; nothing talks over itself
				end
				-- Adopt it: the server made these, and routing them through the
				-- SFX group is what puts them under the player's sfx toggle.
				child.SoundGroup = sfxGroup
				table.insert(voices, child)
			end
		end
		if #voices > 0 then
			for _, voice in voices do
				voice:Play()
			end
			return true
		end
	end

	-- No sound folder (an authored asset, or a model built without one): fall
	-- back to the values the Assembler stamps on every Mixling it builds.
	local critter = model:FindFirstChild("Critter")
	local stuff = model:FindFirstChild("Stuff")
	local tier = model:FindFirstChild("RarityTier")
	if not (critter and critter:IsA("StringValue")) then
		return false
	end
	if not (stuff and stuff:IsA("StringValue")) then
		return false
	end
	if not (tier and tier:IsA("IntValue")) then
		return false
	end
	playPair(critter.Value, stuff.Value, tier.Value, root.Position)
	return true
end

local function idlePass(clock: number)
	if not sfxOn then
		return
	end

	-- Rebuilt every pass rather than kept: a Den is destroyed whole when its
	-- owner leaves, and a table keyed on dead Instances would hold them all
	-- session.
	local fresh: { [Instance]: DenIdle } = {}

	for den, models in occupiedDens() do
		local state: DenIdle = idleState[den]
			or {
				nextAt = clock + rng:NextNumber(Constants.IDLE_SOUND_INTERVAL[1], Constants.IDLE_SOUND_INTERVAL[2]),
				lastAt = 0,
			}
		fresh[den] = state

		if clock >= state.nextAt then
			state.nextAt = clock + rng:NextNumber(Constants.IDLE_SOUND_INTERVAL[1], Constants.IDLE_SOUND_INTERVAL[2])
			if clock - state.lastAt >= Constants.IDLE_SOUND_MIN_GAP_PER_DEN then
				local choice = Util.pick(models, rng)
				if choice and chirp(choice) then
					state.lastAt = clock
				end
			end
		end
	end

	idleState = fresh
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

--[[
	SoundController is the root of the controller graph: everything asks it
	for a noise and it asks nobody for anything, so there is no sibling to
	capture. The method exists to match the boot contract in Client.client.
]]
function SoundController.init(_controllers: { [string]: any }) end

function SoundController.start()
	applySettings()

	ClientState.ready:connect(function()
		applySettings()
	end)

	ClientState.changed:connect(function(keys: any)
		if type(keys) ~= "table" then
			return
		end
		for _, key in keys :: { string } do
			if key == "settings" then
				applySettings()
				return
			end
		end
	end)

	task.spawn(function()
		while true do
			task.wait(IDLE_TICK)
			idlePass(os.clock())
		end
	end)
end

return SoundController
