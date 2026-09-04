--!strict
--[[
	TutorialController.luau — the scripted first sixty seconds.
	GDD §5 (the whole table, beat for beat), §3 and §10 (mobile-first: every
	beat below works with touch alone), §8.2 (the Goop/sec the placement beat
	celebrates).

	OWNS the opening camera pan, the glowing floor path, the world-anchored
	bubbles, the placement confetti, and the funnel beats the server measures
	("mixed", "placed", "bought").

	THE TUTORIAL NEVER BLOCKS MOVEMENT (GDD §5's closing rule; ARCHITECTURE
	§7.6). That single line is why this file is shaped the way it is, and
	every one of these is a consequence of it:

	  * No WalkSpeed, no anchoring, no ContextActionService binding, no modal
	    and no Humanoid touched anywhere in this file. Nothing here can hold a
	    player still, so nothing here has to remember to let them go.
	  * No beat waits on a tap. Each one ends when the SERVER says the thing
	    happened — a MixResult landed, `placed` stopped being empty, the
	    inventory grew — so a player who ignores every bubble and works it out
	    alone finishes the tutorial anyway, in whatever order they like.
	  * A bubble dismisses itself the moment the player walks away from what
	    it points at, and returns if they turn back. Walking away IS the skip
	    button, which is exactly what the GDD asks for and needs no button.
	  * Paths are drawn from wherever the player actually is and redrawn when
	    they leave the line, so the sequence resumes from their position and
	    never from the one the script assumed.
	  * The camera is taken exactly ONCE, for the opening pan, and handed back
	    on the first input of any kind. After that this file never touches it
	    again — a tutorial that steals the camera twice is a tutorial the
	    player is fighting.

	THE CLOCK IN GDD §5 IS A TARGET, NOT A GATE. The only timers here are the
	length of the pan and the 3 s beat before the first bubble; both run
	whatever the player does. Nothing waits FOR the player: arrival is a
	distance check against the same reach the Mixer pads and the shop shelves
	use, and completion is a ProfileSync.

	NOTHING HERE DECIDES ANYTHING (ARCHITECTURE §7.1). The starter pair comes
	from Constants.STARTER and is only PRE-FILLED into the Mixer's slots — the
	ingredients themselves were granted by PlayerService and the rigged
	Uncommon is MixerService's, rolled server-side. This file spends no Goop,
	names no price and predicts no tier; it draws arrows at things.

	A RETURNING PLAYER BUILDS NOTHING. Every instance below is created inside
	`begin()`, which runs only after the first full ProfileSync says
	`tutorialDone` is false. Someone on their fiftieth session pays no parts,
	no BillboardGui and no Heartbeat connection for a minute they finished
	months ago.

	WHY "bought" IS THE ONE BEAT WATCHED FROM HERE. PlayerService can seed
	"mixed" and "placed" from the profile it already holds (rolls, and a
	non-empty `placed`), but a purchase leaves no such mark — the ingredient
	it bought is spent by the next mix. So the client reports it, from the one
	thing a purchase does that nothing else does: an ingredient count in the
	synced inventory going UP. Mixing only ever takes ingredients away, and
	the starter grant lands in the baseline sync before this file is watching.

	THE FUNNEL LINE. This screen's brief asks for a "done" step alongside the
	three; PlayerService's TutorialStep handler accepts only "mixed", "placed"
	and "bought" and flips `tutorialDone` itself once it holds all three. So
	"done" is fired for the funnel and the completion stays the server's.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Config = ReplicatedStorage:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Config:WaitForChild("Constants"))
local Rarity = require(Config:WaitForChild("Rarity"))
local Net = require(Shared:WaitForChild("Net"))
local UiKit = require(Shared:WaitForChild("UiKit"))
local Util = require(Shared:WaitForChild("Util"))

local ClientState = require(script.Parent.Parent:WaitForChild("ClientState"))

local TutorialController = {}
TutorialController.Name = "TutorialController"

local LocalPlayer = Players.LocalPlayer

-- ── Local tunables ───────────────────────────────────────────────────────
--[[
	Constants owns every number the player earns or waits for (GDD §17), and
	the three this file needs — the starter pair, the 50-Goop goal and the
	pedestal count — are read from there rather than restated. What is left
	here is staging: how long a camera move takes, how far apart two glowing
	tiles sit, how wide a bubble is. None of it changes what the player gets.
]]

local PROFILE_WAIT = 30 -- matches Net's own remote wait; past it, no tutorial
local WORLD_WAIT = 20 -- Blendburg replicates as one burst; this is the ceiling

-- The opening pan. Short by design: it is over before the 3 s bubble beat,
-- and any input ends it sooner (GDD §5).
local PAN_SECONDS = 2.6
local PAN_HEIGHT = 13 -- studs above the thing being looked at
local PAN_BACK = 24 -- opens behind the pedestals, near where the player stands
local PAN_MIXER_BACK = 48 -- and lands off the Mixer's Den-facing side

--[[
	Arrival. The same 12 studs MixerUIController and ShopController give their
	ProximityPrompts, so "close enough for the tutorial" and "close enough to
	press the button" are the same place; a bubble that fires at a different
	radius than the prompt it describes is a bubble that lies.
]]
local ARRIVE_DISTANCE = 12

-- The glowing path.
local PATH_FOLDER = "TutorialPath"
local NODE_SPACING = 7 -- studs between tiles
local NODE_MIN, NODE_MAX = 4, 32
local NODE_DIAMETER = 3.2
local NODE_THICKNESS = 0.25
local NODE_LIFT = 0.35 -- above whatever the ray hit, so it never z-fights the floor
local RAY_UP = 60 -- start height for the ground probe
local RAY_DOWN = 220 -- and how far down it looks before giving up
local PATH_FADE = 0.45 -- seconds to fade a path in or out
local PULSE_SPEED = 1.5 -- crests per second, travelling toward the destination
local PULSE_GAP = 0.085 -- phase offset per tile: the wave's wavelength
local NODE_BRIGHT, NODE_DIM = 0.05, 0.72 -- transparency at the crest and behind it
local REPATH_DISTANCE = 18 -- redraw once the player has left the drawn line
local REPATH_INTERVAL = 0.5

-- The bubble.
local BUBBLE_DELAY = 3 -- GDD §5: the first prompt at 3 s
local BUBBLE_SIZE = Vector2.new(300, 96)
local BUBBLE_REFERENCE = 26 -- studs at which the bubble draws at 1x
local BUBBLE_MAX_SCALE = 4.5
local BUBBLE_HEIGHT = 7 -- studs above the thing it points at
local BUBBLE_DISTANCE = 700 -- readable from a Den on the far side of the plaza
local BUBBLE_TITLE_CEILING = 30
local BUBBLE_HINT_CEILING = 20
--[[
	How much further from the destination the player has to get before the
	bubble takes the hint and leaves. Generous, because walking around the
	Mixer or a shop stall adds studs without meaning anything; a player who
	crosses this much ground is going somewhere else.
]]
local WANDER_MARGIN = 26

local CONFETTI_COUNT = 90
local CONFETTI_SECONDS = 2.5
local CONFETTI_LIFT = 3.5 -- studs above the pedestal the Mixling landed on

local TICK_INTERVAL = 0.15 -- how often the beat is re-read; the pulse runs every frame

-- World lookups. WorldService builds Workspace/Blendburg and tags the pads
-- and the shop triggers; DenService names the pedestals inside it.
local WORLD_ROOT = "Blendburg"
local DENS_FOLDER = "Dens"
local DEN_PREFIX = "Den"
local PEDESTAL_HOME = "Pedestals"
local PEDESTAL_RING = "Ring"
local MIXER_FOLDER = "Mixer"
local MIXER_PAD_TAG = "MixerPad"
local CRITTER_SHOP_TAG = "Shop_Critter"
local CRITTER_SHOP_FOLDER = "CritterPen"

-- GDD §5's three lines, in the order the player meets them.
local MIX_TITLE = "Take these to the Mixer!"
local MIX_HINT = "Both ingredients are already in your bag."
local PLACE_TITLE = "Put it on a pedestal in your Den."
local PLACE_HINT = "A placed Mixling earns Goop every second."
local BUY_TITLE = ("Earn %s Goop → buy a new ingredient."):format(Util.abbreviate(Constants.TUTORIAL_GOAL_GOOP))
local BUY_HINT = "The shelves are at the Critter Pen."
local PLACED_TOAST = "That pedestal pays you now — watch your Goop/sec."

-- ── State ────────────────────────────────────────────────────────────────

local mixer: any = nil
local hud: any = nil
local sound: any = nil
local alerts: any = nil

local running = false
local finished = false
local panned = false -- the camera is taken once, ever
local openedMixer = false
local celebrated = false
local shopLit = false

local reported: { [string]: boolean } = {}
local inventorySeen: { [string]: number }? = nil
local denSlot: number? = nil

local connections: { RBXScriptConnection } = {}
local stateConnections: { Util.Connection } = {}

local startedAt = 0
local sinceTick = 0

type Beat = {
	title: string,
	hint: string,
	adornee: BasePart?,
	point: Vector3?,
}

local guide = {
	beat = "",
	dismissed = false,
	closest = math.huge,
	farthest = 0,
}

local pathFolder: Folder? = nil
local nodes: { BasePart } = {}
local pathOrigin = Vector3.zero
local pathTarget = Vector3.zero
local pathFade = 0
local pathWanted = false
local repathAt = 0

local bubbleGui: BillboardGui? = nil
local bubbleFrame: Frame? = nil
local bubbleTitle: TextLabel? = nil
local bubbleHint: TextLabel? = nil
local bubbleScale = 0

-- ── Small helpers ────────────────────────────────────────────────────────

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function flatUnit(vector: Vector3, fallback: Vector3): Vector3
	local level = flat(vector)
	if level.Magnitude < 1e-3 then
		return fallback
	end
	return level.Unit
end

--[[
	UiKit.label documents a `MaxTextSize` prop, but applyCommon assigns every
	prop it does not recognise straight onto the instance and MaxTextSize is
	not a member of TextLabel — passing it throws. The kit already attaches a
	UITextSizeConstraint, so the ceiling is set on that afterwards. Every
	screen in the game carries this same three-line workaround.
]]
local function textCeiling(gui: GuiObject, ceiling: number)
	local constraint = gui:FindFirstChildOfClass("UITextSizeConstraint")
	if constraint then
		constraint.MaxTextSize = ceiling
	end
end

local function cue(name: string)
	if sound and type(sound.play) == "function" then
		sound.play(name)
	end
end

--[[
	One intent per beat, once each. Firing twice would cost the player a slot
	in Net's TutorialStep window for nothing; the server treats a repeat as a
	no-op anyway, which is what makes reporting a beat that was already true
	on a rejoin safe.
]]
local function report(step: string)
	if reported[step] then
		return
	end
	reported[step] = true
	Net.event("TutorialStep"):FireServer(step)
end

-- ── Finding Blendburg ────────────────────────────────────────────────────
-- Every lookup below returns nil rather than warning when the town has not
-- replicated yet. A missing landmark means one quiet frame without a bubble,
-- never a broken tutorial: the beat machine simply tries again next tick.

local function worldRoot(): Instance?
	return Workspace:FindFirstChild(WORLD_ROOT)
end

local function centreOf(container: Instance?): Vector3?
	if not container then
		return nil
	end
	local total = Vector3.zero
	local count = 0
	for _, descendant in container:GetDescendants() do
		if descendant:IsA("BasePart") then
			total += descendant.Position
			count += 1
		end
	end
	if count == 0 then
		return nil
	end
	return total / count
end

local function mixerFolder(): Instance?
	local root = worldRoot()
	if not root then
		return nil
	end
	return root:FindFirstChild(MIXER_FOLDER)
end

--[[
	The tallest part of the machine, so the bubble floats over the Mixer
	rather than inside it. Pads are skipped: they are on the floor, and one of
	them is the destination the path already points at.
]]
local function mixerBody(): BasePart?
	local folder = mixerFolder()
	if not folder then
		return nil
	end
	local best: BasePart? = nil
	for _, descendant in folder:GetDescendants() do
		if descendant:IsA("BasePart") and not CollectionService:HasTag(descendant, MIXER_PAD_TAG) then
			if not best or descendant.Position.Y > best.Position.Y then
				best = descendant
			end
		end
	end
	return best
end

-- The pad nearest the player: on a full server the ten pads are the reason
-- nobody queues, and the tutorial should send its player to the free-est one
-- it can reason about without asking the server anything.
local function nearestPad(from: Vector3): BasePart?
	local best: BasePart? = nil
	local bestDistance = math.huge
	for _, tagged in CollectionService:GetTagged(MIXER_PAD_TAG) do
		if tagged:IsA("BasePart") then
			local distance = (flat(tagged.Position) - flat(from)).Magnitude
			if distance < bestDistance then
				best = tagged
				bestDistance = distance
			end
		end
	end
	return best
end

local function denFolder(): Instance?
	local slot = denSlot
	local root = worldRoot()
	if not slot or not root then
		return nil
	end
	local dens = root:FindFirstChild(DENS_FOLDER)
	if not dens then
		return nil
	end
	return dens:FindFirstChild(DEN_PREFIX .. tostring(slot))
end

local function pedestalPart(index: number): BasePart?
	local den = denFolder()
	if not den then
		return nil
	end
	local home = den:FindFirstChild(PEDESTAL_HOME)
	if not home then
		return nil
	end
	local ring = home:FindFirstChild(PEDESTAL_RING)
	if not ring then
		return nil
	end
	local part = ring:FindFirstChild(("Pedestal%02d"):format(index))
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

--[[
	The first pedestal the player owns and has not filled. Mirrors the synced
	`placed` map and `denSlots` — both server truth — and decides nothing: the
	server re-runs its own check on RequestPlace and refuses in its own words.
]]
local function freePedestal(): BasePart?
	local view = ClientState.get()
	local slots = view.denSlots
	if type(slots) ~= "number" or slots ~= slots then
		slots = Constants.DEN_SLOTS_START
	end
	local ceiling = math.min(slots, Constants.WORLD.PEDESTAL_COUNT)
	for index = 1, ceiling do
		if view.placed[tostring(index)] == nil then
			local part = pedestalPart(index)
			if part then
				return part
			end
		end
	end
	return nil
end

local function critterPen(): BasePart?
	for _, tagged in CollectionService:GetTagged(CRITTER_SHOP_TAG) do
		if tagged:IsA("BasePart") then
			return tagged
		end
	end
	-- No trigger yet: the stall's own fascia is a fine thing to point at.
	local root = worldRoot()
	local stall = if root then root:FindFirstChild(CRITTER_SHOP_FOLDER) else nil
	if not stall then
		return nil
	end
	for _, descendant in stall:GetDescendants() do
		if descendant:IsA("BasePart") then
			return descendant
		end
	end
	return nil
end

-- ── The glowing path (GDD §5, the 3 s and 18 s beats) ────────────────────

local function clearPath()
	local folder = pathFolder
	pathFolder = nil
	table.clear(nodes)
	if folder then
		folder:Destroy()
	end
end

--[[
	A line of small emissive discs laid on the floor between the player and
	the destination. Parts rather than a Beam: a Beam is one flat ribbon that
	sinks into the plaza and disappears at a glancing phone camera angle,
	while discs sit ON the ground the player is walking over and read from any
	angle. They are decoration in the strictest sense — no collision, no
	query, no touch, no shadow — so they can never trip, block or catch
	anybody. GDD §5's rule is about movement, and geometry that a player can
	walk into is geometry that blocks movement.
]]
local function buildPath(from: Vector3, to: Vector3)
	clearPath()

	local line = flat(to - from)
	local span = line.Magnitude
	if span <= ARRIVE_DISTANCE then
		return -- they are already there; an arrow to your own feet is noise
	end

	local folder = Instance.new("Folder")
	folder.Name = PATH_FOLDER

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	local ignore: { Instance } = { folder }
	local character = LocalPlayer.Character
	if character then
		table.insert(ignore, character)
	end
	params.FilterDescendantsInstances = ignore

	local count = math.clamp(math.floor(span / NODE_SPACING), NODE_MIN, NODE_MAX)
	for index = 1, count do
		local alpha = index / (count + 1)
		local point = from + line * alpha
		-- Blendburg is one flat island, but the plaza lip, the Den floors and
		-- the shop decks all sit at their own heights; a probe is cheaper than
		-- assuming, and a tile floating a stud over a step reads as a bug.
		local hit = Workspace:Raycast(point + Vector3.new(0, RAY_UP, 0), Vector3.new(0, -RAY_DOWN, 0), params)
		local height = if hit then hit.Position.Y else math.min(from.Y, to.Y)

		local node = Instance.new("Part")
		node.Name = "Step"
		node.Shape = Enum.PartType.Cylinder
		-- A Roblox cylinder runs along its own X axis, so a disc laid flat is
		-- a quarter turn about Z — the same idiom WorldService paints the
		-- plaza with.
		node.Size = Vector3.new(NODE_THICKNESS, NODE_DIAMETER, NODE_DIAMETER)
		node.CFrame = CFrame.new(point.X, height + NODE_LIFT, point.Z) * CFrame.Angles(0, 0, math.pi * 0.5)
		node.Color = UiKit.PALETTE.goop
		node.Material = Enum.Material.Neon
		node.Anchored = true
		node.CanCollide = false
		node.CanQuery = false
		node.CanTouch = false
		node.CastShadow = false
		node.Transparency = 1 -- the fade below brings it in
		node.Parent = folder

		table.insert(nodes, node)
	end

	folder.Parent = Workspace
	pathFolder = folder
	pathOrigin = from
	pathTarget = to
end

--[[
	Fade and pulse. The crest travels from the first tile to the last, which
	is the whole point: direction has to be unambiguous without reading a word
	of English, because plenty of the audience cannot yet (GDD §3).
]]
local function animatePath(now: number, delta: number)
	local step = delta / PATH_FADE
	if pathWanted then
		pathFade = math.min(1, pathFade + step)
	else
		pathFade = math.max(0, pathFade - step)
		if pathFade <= 0 then
			clearPath()
			return
		end
	end

	for index, node in nodes do
		local phase = (now * PULSE_SPEED - index * PULSE_GAP) % 1
		local crest = 1 - phase
		local lit = NODE_DIM + (NODE_BRIGHT - NODE_DIM) * crest
		node.Transparency = 1 - pathFade * (1 - lit)
	end
end

-- ── The bubble ───────────────────────────────────────────────────────────

--[[
	Not a ScreenGui: GDD §5 wants the prompt ON the thing it is talking about,
	and UiKit has no BillboardGui primitive. Everything inside it is still
	built from the kit, so a tutorial bubble reads like the rest of the game.

	AlwaysOnTop, because the first bubble is seen from inside a Den and points
	at a machine on the far side of a wall. A prompt you have to walk around
	to read is a prompt that has already failed.
]]
local function ensureBubble()
	if bubbleGui then
		return
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "TutorialBubble"
	gui.Size = UDim2.fromOffset(BUBBLE_SIZE.X, BUBBLE_SIZE.Y)
	gui.StudsOffsetWorldSpace = Vector3.new(0, BUBBLE_HEIGHT, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = BUBBLE_DISTANCE
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

	local frame = UiKit.frame({
		BackgroundColor3 = UiKit.PALETTE.ink,
		BackgroundTransparency = 0.08,
		Corner = 16,
		Stroke = UiKit.PALETTE.accent,
		Padding = 10,
		Parent = gui,
	})

	local title = UiKit.label({
		Text = "",
		Size = UDim2.fromScale(1, 0.6),
		TextStrokeTransparency = 0.4,
		TextStrokeColor3 = UiKit.PALETTE.ink,
		Parent = frame,
	})
	textCeiling(title, BUBBLE_TITLE_CEILING)

	local hint = UiKit.label({
		Text = "",
		Font = UiKit.FONT_BODY,
		TextColor3 = UiKit.PALETTE.muted,
		Size = UDim2.fromScale(1, 0.4),
		Position = UDim2.fromScale(0, 0.6),
		TextStrokeTransparency = 0.55,
		TextStrokeColor3 = UiKit.PALETTE.ink,
		Parent = frame,
	})
	textCeiling(hint, BUBBLE_HINT_CEILING)

	bubbleGui = gui
	bubbleFrame = frame
	bubbleTitle = title
	bubbleHint = hint
end

local function showBubble(beat: Beat)
	ensureBubble()
	local gui, frame, title, hint = bubbleGui, bubbleFrame, bubbleTitle, bubbleHint
	if not gui or not frame or not title or not hint then
		return
	end
	local adornee = beat.adornee
	if not adornee then
		gui.Enabled = false
		return
	end

	title.Text = beat.title
	hint.Text = beat.hint
	gui.Adornee = adornee
	if not gui.Enabled then
		gui.Enabled = true
		UiKit.pop(frame, 0.16)
	end
end

local function hideBubble()
	local gui = bubbleGui
	if gui then
		gui.Enabled = false
	end
end

--[[
	A BillboardGui sized in offset shrinks with distance like everything else
	in the world, and the first bubble is read from ~150 studs away on a
	phone. So the size is compensated back up, clamped so that standing next
	to the Mixer does not paste a billboard over the plaza (GDD §10: readable
	at arm's length, never covering the world).
]]
local function animateBubble()
	local gui = bubbleGui
	if not gui or not gui.Enabled then
		return
	end
	local adornee = gui.Adornee
	local camera = Workspace.CurrentCamera
	if not camera or not adornee or not adornee:IsA("BasePart") then
		return
	end

	local distance = (adornee.Position - camera.CFrame.Position).Magnitude
	local scale = math.clamp(distance / BUBBLE_REFERENCE, 1, BUBBLE_MAX_SCALE)
	if math.abs(scale - bubbleScale) < 0.02 then
		return
	end
	bubbleScale = scale
	gui.Size = UDim2.fromOffset(BUBBLE_SIZE.X * scale, BUBBLE_SIZE.Y * scale)
end

local function hideGuide()
	hideBubble()
	pathWanted = false
end

-- ── The placement celebration (GDD §5, the 25 s beat) ────────────────────

--[[
	Confetti in the Mixling's own rarity colour, which for the scripted first
	roll is Constants.STARTER.riggedRarity's — read through Rarity.color like
	every other tier colour in the game, never from a literal.
]]
local function confetti(at: BasePart, colour: Color3)
	local attachment = Instance.new("Attachment")
	attachment.Name = "TutorialConfetti"
	attachment.Parent = at
	-- WorldPosition, not Position: a pedestal is a laid-down cylinder, so its
	-- local Y is not the world's up.
	attachment.WorldPosition = at.Position + Vector3.new(0, CONFETTI_LIFT, 0)

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(colour, UiKit.PALETTE.text)
	emitter.Size = NumberSequence.new(0.55, 0.12)
	emitter.Transparency = NumberSequence.new(0.05, 1)
	emitter.Lifetime = NumberRange.new(1.1, CONFETTI_SECONDS)
	emitter.Speed = NumberRange.new(14, 26)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-220, 220)
	emitter.Acceleration = Vector3.new(0, -34, 0)
	emitter.LightEmission = 0.35
	emitter.Rate = 0 -- a burst, not a fountain
	emitter.Enabled = false
	emitter.Parent = attachment
	emitter:Emit(CONFETTI_COUNT)

	task.delay(CONFETTI_SECONDS + 0.5, function()
		attachment:Destroy()
	end)
end

local function celebratePlacement()
	if celebrated then
		return
	end
	celebrated = true

	local view = ClientState.get()
	for key, id in view.placed do
		local index = tonumber(key)
		if index then
			local part = pedestalPart(index)
			local mixling = ClientState.mixlingById(id)
			local tier = if mixling then mixling.rarity else Constants.RARITY_COMMON
			if part then
				confetti(part, Rarity.color(tier))
			end
			break
		end
	end

	cue("Confetti")
	if alerts and type(alerts.toast) == "function" then
		-- No figure in the text: the Goop/sec the HUD is about to show is the
		-- server's, and it may not have synced yet. The counter says the
		-- number; this only points at it.
		alerts.toast(PLACED_TOAST, "Success")
	end
end

-- ── The one camera pan (GDD §5, the 0 s beat) ────────────────────────────

--[[
	From the empty pedestals to the Mixer, once, and interruptible by any
	input at all. Movement is never taken: a Scriptable camera still walks,
	and the first touch of the thumbstick hands the camera straight back.

	If anything else already owns the camera the pan is abandoned rather than
	fought over, and `panned` is set before the first early return so a failed
	pan can never become a second attempt.
]]
local function panCamera()
	if panned then
		return
	end
	panned = true

	local camera = Workspace.CurrentCamera
	if not camera or camera.CameraType == Enum.CameraType.Scriptable then
		return
	end

	local root = Util.rootPart(LocalPlayer)
	local pedestals = centreOf(denFolder()) or (if root then root.Position else nil)
	local machine = centreOf(mixerFolder())
	if not pedestals or not machine then
		return -- nothing to pan between; the bubble beat does the job alone
	end

	local outward = flatUnit(machine - pedestals, Vector3.new(0, 0, -1))
	local lift = Vector3.new(0, PAN_HEIGHT, 0)
	local from = CFrame.lookAt(pedestals + outward * PAN_BACK + lift, pedestals)
	local to = CFrame.lookAt(machine - outward * PAN_MIXER_BACK + lift, machine)

	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = from
	local tween = UiKit.tween(camera, { CFrame = to }, PAN_SECONDS, Enum.EasingStyle.Sine)

	local released = false
	local watchers: { RBXScriptConnection } = {}
	local function release()
		if released then
			return
		end
		released = true
		for _, watcher in watchers do
			watcher:Disconnect()
		end
		table.clear(watchers)
		tween:Cancel()
		local humanoid = Util.humanoid(LocalPlayer)
		if humanoid then
			camera.CameraSubject = humanoid
		end
		camera.CameraType = Enum.CameraType.Custom
	end

	-- MouseMovement is excluded and nothing else is: a key, a tap, a stick,
	-- a scroll or a click all mean "I would like my camera back".
	table.insert(
		watchers,
		UserInputService.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType ~= Enum.UserInputType.MouseMovement then
				release()
			end
		end)
	)
	table.insert(
		watchers,
		UserInputService.InputChanged:Connect(function(input: InputObject)
			if input.UserInputType ~= Enum.UserInputType.MouseMovement then
				release()
			end
		end)
	)
	table.insert(watchers, tween.Completed:Connect(release))

	-- Belt and braces: a tween that never reports Completed (a respawn, a
	-- cancelled render step) must not strand the player in a fixed shot.
	task.delay(PAN_SECONDS + 0.5, release)
end

-- ── The script (GDD §5) ──────────────────────────────────────────────────

--[[
	Which beat the player is on is derived from server truth every tick, not
	tracked as a step counter here. A player who mixes before the bubble
	appears, or places from the reveal card without ever walking home, moves
	the sequence on exactly the same way — the tutorial follows them.
]]
local function currentBeat(): string
	local view = ClientState.get()
	if view.tutorialDone or reported.bought then
		return "done"
	end

	local stats = view.stats
	local rolls = if type(stats) == "table" then tonumber(stats.rolls) or 0 else 0
	if rolls <= 0 then
		return "mix"
	end
	if next(view.placed) == nil then
		return "place"
	end
	return "buy"
end

local function beatFor(name: string, here: Vector3): Beat?
	if name == "mix" then
		local pad = nearestPad(here)
		return {
			title = MIX_TITLE,
			hint = MIX_HINT,
			adornee = mixerBody() or pad,
			point = if pad then pad.Position else nil,
		}
	end
	if name == "place" then
		local pedestal = freePedestal()
		return {
			title = PLACE_TITLE,
			hint = PLACE_HINT,
			adornee = pedestal,
			point = if pedestal then pedestal.Position else nil,
		}
	end
	if name == "buy" then
		local shelves = critterPen()
		return {
			title = BUY_TITLE,
			hint = BUY_HINT,
			adornee = shelves,
			point = if shelves then shelves.Position else nil,
		}
	end
	return nil
end

--[[
	GDD §5, 10 s: the Mixer opens with both slots pre-filled and one button.
	Opened ONCE. A panel that reappears every time the player wanders back
	into range is a panel they cannot walk away from, which is the one thing
	this file may never build; if they close it, the pads' own prompts are
	right under their feet.
]]
local function openMixer()
	if openedMixer or not mixer then
		return
	end
	openedMixer = true
	if type(mixer.prefill) == "function" then
		mixer.prefill(Constants.STARTER.critter, Constants.STARTER.stuff)
	end
	if type(mixer.open) == "function" then
		mixer.open()
		cue("Click")
	end
end

local function isRevealing(): boolean
	return mixer ~= nil and type(mixer.isRevealing) == "function" and mixer.isRevealing() == true
end

local function lightShopButton(on: boolean)
	if shopLit == on or not hud or type(hud.setButtonHighlight) ~= "function" then
		return
	end
	shopLit = on
	hud.setButtonHighlight("Shop", on)
end

local function finish()
	if finished then
		return
	end
	finished = true
	running = false

	lightShopButton(false)
	hideGuide()
	clearPath()

	local gui = bubbleGui
	bubbleGui = nil
	bubbleFrame = nil
	bubbleTitle = nil
	bubbleHint = nil
	if gui then
		gui:Destroy()
	end

	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	for _, connection in stateConnections do
		connection.disconnect(connection)
	end
	table.clear(stateConnections)
end

-- The last beat. "done" is the funnel's closing line; `tutorialDone` itself
-- is PlayerService's to set once it holds all three of the beats above.
local function completeTutorial()
	report("bought")
	report("done")
	finish()
end

-- ── The beat machine ─────────────────────────────────────────────────────

local function tick(now: number)
	if finished then
		return
	end

	local view = ClientState.get()
	if view.tutorialDone then
		finish()
		return
	end

	local beat = currentBeat()
	if beat == "done" then
		finish()
		return
	end

	lightShopButton(beat == "buy" and view.goop >= Constants.TUTORIAL_GOAL_GOOP)

	-- The roll is never interrupted (GDD §2, pillar 1). Nothing new is drawn
	-- over the reveal; the next beat is waiting when the card is dismissed.
	if isRevealing() then
		hideGuide()
		return
	end

	local root = Util.rootPart(LocalPlayer)
	if not root then
		hideGuide()
		return
	end

	local plan = beatFor(beat, root.Position)
	if not plan or not plan.point then
		hideGuide() -- Blendburg, or this player's Den, has not arrived yet
		return
	end
	local point = plan.point :: Vector3
	local here = root.Position
	local distance = (flat(point) - flat(here)).Magnitude

	if beat ~= guide.beat then
		guide.beat = beat
		guide.dismissed = false
		guide.closest = distance
		guide.farthest = distance
		clearPath() -- the old line pointed somewhere else
		pathFade = 0
	end

	--[[
		Walking away is the skip button (GDD §5). Distance is measured against
		the closest the player has been since the bubble appeared, so pacing
		around the Mixer costs nothing and setting off across town costs the
		bubble. Turning back brings it straight home again — no timer, no
		nagging, and nothing the player has to dismiss by hand.
	]]
	if guide.dismissed then
		guide.farthest = math.max(guide.farthest, distance)
		if distance < guide.farthest - WANDER_MARGIN then
			guide.dismissed = false
			guide.closest = distance
			guide.farthest = distance
		end
	else
		guide.closest = math.min(guide.closest, distance)
		if distance > guide.closest + WANDER_MARGIN then
			guide.dismissed = true
			guide.farthest = distance
		end
	end

	-- GDD §5 puts the first prompt at 3 s; the pan owns the seconds before it.
	local due = now - startedAt >= BUBBLE_DELAY or beat ~= "mix"
	if guide.dismissed or not due then
		hideGuide()
	else
		showBubble(plan)
		pathWanted = distance > ARRIVE_DISTANCE
	end

	if pathWanted then
		local stale = (flat(point) - flat(pathTarget)).Magnitude > ARRIVE_DISTANCE
		local strayed = (flat(here) - flat(pathOrigin)).Magnitude > REPATH_DISTANCE
		if not pathFolder or (now >= repathAt and (stale or strayed)) then
			buildPath(here, point)
			repathAt = now + REPATH_INTERVAL
		end
	end

	if beat == "mix" and distance <= ARRIVE_DISTANCE then
		openMixer()
	end
end

-- ── Watching the server ──────────────────────────────────────────────────

local function noteDenRows(rows: any)
	if type(rows) ~= "table" then
		return
	end
	for _, entry in rows :: { any } do
		if type(entry) == "table" and entry.userId == LocalPlayer.UserId then
			local slot = tonumber(entry.slotIndex)
			if slot then
				denSlot = slot
			end
			return
		end
	end
end

--[[
	An ingredient count that went UP. Mixing only ever spends ingredients and
	theft never touches the inventory, so a rise is a purchase — the one beat
	the server cannot reconstruct from the profile it already holds. The first
	sync seen is the baseline, never a purchase: it carries the starter pair
	PlayerService grants before the full view goes out.
]]
local function watchInventory(inventory: { [string]: number })
	local previous = inventorySeen
	inventorySeen = table.clone(inventory)
	if not previous then
		return
	end
	for name, count in inventory do
		if count > (previous[name] or 0) then
			cue("Purchase")
			completeTutorial()
			return
		end
	end
end

-- Both of these are also true for a player who rejoins mid-tutorial, which
-- is why they are read from the view rather than only from the live events:
-- the beats they already reached are reported once and the sequence picks up
-- at the one they have not.
local function watchProgress()
	local view = ClientState.get()

	local stats = view.stats
	local rolls = if type(stats) == "table" then tonumber(stats.rolls) or 0 else 0
	if rolls > 0 then
		report("mixed")
	end

	if next(view.placed) ~= nil then
		report("placed")
		celebratePlacement()
	end
end

local function connectWatchers()
	table.insert(
		connections,
		Net.event("MixResult").OnClientEvent:Connect(function()
			-- The server's own word that a mix happened, a full ProfileSync
			-- ahead of the stats delta that confirms it.
			report("mixed")
		end)
	)

	table.insert(
		connections,
		Net.event("DenSync").OnClientEvent:Connect(function(rows: any)
			noteDenRows(rows)
		end)
	)

	table.insert(
		stateConnections,
		ClientState.changed:connect(function(keys: any)
			if finished or type(keys) ~= "table" then
				return
			end
			local view = ClientState.get()
			for _, key in keys :: { string } do
				if key == "inventory" then
					watchInventory(view.inventory)
				elseif key == "placed" or key == "stats" then
					watchProgress()
				elseif key == "tutorialDone" and view.tutorialDone then
					finish()
				end
			end
		end)
	)

	-- One pull so the Den slot is known before the first broadcast; the
	-- placement beat needs a pedestal to point at.
	task.spawn(function()
		local ok, rows = pcall(function()
			return Net.func("Query"):InvokeServer("DenList")
		end)
		if ok then
			noteDenRows(rows)
		end
	end)
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

--[[
	Nothing is built before the first full ProfileSync, because that sync is
	what says whether this file should exist at all. ClientState.start() runs
	before any controller, so it may already be in when this runs.
]]
local function waitForProfile(): boolean
	if ClientState.isReady() then
		return true
	end

	local thread = coroutine.running()
	local woken = false
	local function wake()
		if woken then
			return
		end
		woken = true
		task.spawn(thread)
	end

	ClientState.ready:once(wake)
	task.delay(PROFILE_WAIT, wake)
	coroutine.yield()

	return ClientState.isReady()
end

local function begin()
	running = true
	startedAt = os.clock()

	local view = ClientState.get()
	inventorySeen = table.clone(view.inventory)
	-- A Mixling already on a pedestal was placed in an earlier session; the
	-- beat is reported, but the confetti belongs to the moment it lands.
	celebrated = next(view.placed) ~= nil

	connectWatchers()
	watchProgress()

	table.insert(
		connections,
		RunService.Heartbeat:Connect(function(delta: number)
			if finished then
				return
			end
			local now = os.clock()
			animatePath(now, delta)
			animateBubble()

			sinceTick += delta
			if sinceTick < TICK_INTERVAL then
				return
			end
			sinceTick = 0
			tick(now)
		end)
	)

	task.spawn(function()
		-- The pan opens on the pedestals, so it waits for the character and
		-- for the town; both are in long before the profile in practice.
		if not LocalPlayer.Character then
			LocalPlayer.CharacterAdded:Wait()
		end
		Workspace:WaitForChild(WORLD_ROOT, WORLD_WAIT)
		if not finished and running then
			panCamera()
		end
	end)
end

function TutorialController.init(controllers: { [string]: any })
	mixer = controllers.MixerUIController
	hud = controllers.HudController
	sound = controllers.SoundController
	alerts = controllers.AlertController
end

function TutorialController.start()
	task.spawn(function()
		if not waitForProfile() then
			return -- no profile, no idea whether this player is new; draw nothing
		end
		if ClientState.get().tutorialDone then
			-- GDD §5 is for new Mixers. A returning player pays nothing for
			-- it: no beams, no bubble, no Heartbeat, no camera.
			return
		end
		begin()
	end)
end

return TutorialController
