--!strict
--[[
	DenService.luau — pedestals, placement, the door lock and the new-player
	shield. GDD §6, §8.3, §8.4.1, §11.3, §11.4.

	THIS FILE ANSWERS "WHERE IS THAT MIXLING?". A Mixling is on a pedestal
	(`profile.placed[tostring(index)]`), loose in its owner's collection
	(`profile.mixlings` and nothing else), or in StealService's hands between
	`takeFromPedestal` and `bank`/`returnToOwner`. Nothing outside this file
	may write `profile.placed`, and every world model that represents a placed
	Mixling is built, owned and destroyed here.

	DENS ARE PER SESSION; MIXLINGS ARE NOT (GDD §6). A den is a slot in the
	ring, 1..Constants.SERVER_SIZE, held only while its owner is in the
	server. So everything this service builds goes under one "DenParts" folder
	inside WorldService's den folder and is destroyed whole when the owner
	leaves — the next player to take that slot starts from clean geometry
	instead of inheriting someone else's pedestals.

	THE LOCKED DOOR IS A REAL WALL, NOT A SUGGESTION. GDD §8.3 wants a door
	that holds, so the barrier is CanCollide *and* teleports a blocked player
	back out on touch: a fast or scripted client that clips the wall is still
	put back on the street. But CanCollide is a property of the part, not of a
	viewer, and the owner may never be locked out of their own Den while their
	friends must be able to walk in. Barriers therefore sit in their own
	collision group, and a player who passes `canEnter` is briefly moved into
	a group that does not collide with it. If collision groups are
	unavailable — the 32-group budget belongs to the whole place — the barrier
	degrades to CanCollide = false and the touch teleport does the whole job,
	which still turns away a walking intruder and can never trap an owner.

	THE FRIEND CHECK IS CACHED BECAUSE IT YIELDS. `IsFriendsWithAsync` is a
	web call; calling it from a Touched handler would stall the physics thread
	and hand an exploiter a free DoS. Friendship is resolved in the background
	once per pair per session and read from the cache afterwards. An unresolved
	pair reads as "not friends", so the failure mode is one bounce, never an
	open door.

	THE SHIELD IS DETECTED FROM profile.firstJoin. DataService stamps
	`firstJoin` the moment it creates a profile, so a profile whose firstJoin
	is newer than this session's join is a first-ever join and nothing else
	(GDD §8.3: never on rejoins). If we never saw the join — this service
	started with players already in the server — the shield is refused rather
	than guessed: missing a shield is a small disappointment, granting one to
	a veteran is an exploit.

	HOLD DURATION IS SERVER SIDE (GDD §11.3). The pedestal prompt is created
	here, its HoldDuration comes from Rarity.holdTime, and `Enabled` is driven
	by the den's lock and the owner's shield. `Enabled` is a coarse gate the
	client can flip locally, so StealService re-validates everything on the
	trigger; this only decides whether the prompt is worth showing.

	ONE LOOP, NOT ONE PER DEN (GDD §11.4). A single heartbeat walks the ≤10
	live dens once a second and does every periodic job — lock expiry, shield
	expiry, prompt gating, slot reconciliation, sign text, the DenSync
	broadcast and the throttled idle sound. No per-den threads, no timers to
	leak when a player leaves mid-lock.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = ReplicatedStorage:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Config:WaitForChild("Constants"))
local Rarity = require(Config:WaitForChild("Rarity"))
local Assembler = require(Shared:WaitForChild("MixlingAssembler"))
local Net = require(Shared:WaitForChild("Net"))
local Types = require(Shared:WaitForChild("Types"))
local Util = require(Shared:WaitForChild("Util"))

-- Server-only (GDD §11.3): a placed Secret must show its real name, and that
-- name lives in ServerStorage. Nothing read here is ever sent to a client
-- that could not already see the model standing on the pedestal.
local SecretRecipes = require(ServerStorage:WaitForChild("SecretRecipes"))

type Profile = Types.Profile
type Mixling = Types.Mixling
type DenPublic = Types.DenPublic

export type Den = {
	player: Player,
	slotIndex: number,
	folder: Folder, -- WorldService's; shared with whatever else it built
	built: Folder, -- fixtures this service made, destroyed as one unit
	ring: Folder, -- pedestals and display models, inside WorldService's "Pedestals"
	anchor: CFrame,
	outward: Vector3, -- unit, horizontal, den centre -> plaza: the door side
	door: CFrame, -- barrier plane; LookVector points out of the Den
	doorSize: Vector3, -- measured from the Den shell, not assumed
	pedestals: { BasePart },
	padlocks: { [number]: BillboardGui },
	displays: { [number]: Model },
	prompts: { [number]: ProximityPrompt },
	shownSlots: number, -- how many pedestals are currently drawn unlocked
	lockEndsAt: number, -- os.time()
	cooldownEndsAt: number, -- os.time(); GDD §8.3 cooldown runs AFTER the lock
	barrier: BasePart?,
	countdown: TextLabel?,
	signGui: BillboardGui?, -- only when we had to build our own sign
	ownerLabel: TextLabel?,
	rateLabel: TextLabel?,
	rateColor: Color3, -- the sign's own colour, restored when the lock lifts
	shieldBoard: BillboardGui?,
	stealAllowed: boolean,
	shieldOn: boolean,
	lastIntruderAt: number,
	nextIdleAt: number,
	lastIdleAt: number,
}

local DenService = {}
DenService.Name = "DenService"

DenService.onPedestalPrompt = Util.signal()

-- ── Local tunables ───────────────────────────────────────────────────────
-- Geometry, cadences and UI reach. None of these is a balance value (GDD
-- §17 covers what the player feels), and Constants deliberately carries no
-- world-geometry section beyond Constants.WORLD, so the sizes below are
-- derived from Constants.WORLD wherever a relationship exists — change
-- DEN_SIZE or PEDESTAL_RING_RADIUS and the door and ring move together.

local PEDESTAL_SIZE = Vector3.new(3, 1.4, 3)
local DISPLAY_HEIGHT = 2.1 -- studs from the pedestal top to the Mixling's pivot
local PROMPT_DISTANCE = 8 -- how close a thief must stand to see the prompt
local RING_ARC = math.rad(280) -- pedestals span 280°, leaving 80° clear for the doorway
-- Only used when a Den shell brings no measurable doorway (see `doorFrame`).
local DOOR_WIDTH_FALLBACK = Constants.WORLD.DEN_SIZE.X * 0.36
local DOOR_HEIGHT_FALLBACK = Constants.WORLD.DEN_SIZE.Y * 0.4
local DOOR_THICKNESS = 1
local BOUNCE_STUDS = 6 -- how far a blocked player is pushed back out
local BOUNCE_COOLDOWN = 1.5 -- seconds between bounces for one intruder
local INTRUDER_NOTICE_COOLDOWN = 20 -- seconds between "someone tried your door" lines
local PASS_SECONDS = 3 -- how long an allowed player may phase through a barrier
local SYNC_INTERVAL = 1 -- the one heartbeat, seconds
local FORCE_SYNC_SECONDS = 15 -- resend DenSync even when nothing changed

local PEDESTAL_COLOR = Color3.fromRGB(96, 88, 132)
local PEDESTAL_LOCKED_COLOR = Color3.fromRGB(52, 48, 68)
local BARRIER_COLOR = Color3.fromRGB(120, 190, 255)
local TEXT_COLOR = Color3.fromRGB(248, 246, 255)
local MUTED_COLOR = Color3.fromRGB(178, 170, 205)
local WARN_COLOR = Color3.fromRGB(255, 186, 62)

local GROUP_BARRIER = "MixDenBarrier"
local GROUP_PASS = "MixDenPass"
local GROUP_DEFAULT = "Default"

-- ── State ────────────────────────────────────────────────────────────────

local data: any = nil
local economy: any = nil
local world: any = nil
local monetization: any = nil
local announcements: any = nil
local analytics: any = nil

local dens: { [Player]: Den } = {}
local slotOwner: { [number]: Player } = {}
local ownerByFolder: { [Instance]: Player } = {}
local shieldUntil: { [Player]: number } = {}
local joinedAt: { [number]: number } = {} -- userId -> os.time() of this session's join
-- Mixling id -> the pedestal it was carried off. Written only by
-- takeFromPedestal and cleared the moment the Mixling lands somewhere, so it
-- holds the handful of Mixlings currently in a thief's hands and nothing else.
local homePedestal: { [string]: number } = {}
local friends: { [number]: { [number]: boolean } } = {} -- symmetric, per pair, per session
local friendPending: { [string]: boolean } = {}
local passUntil: { [Player]: number } = {}
local lastBounceAt: { [Player]: number } = {}

-- Every service module is required before any of them starts, so this stamp
-- precedes the first profile load in the server. It is the join time used for
-- players who were already here when this service started (see beginShield).
local BOOT_AT = os.time()

local rng = Random.new() -- cosmetic only: which pedestal gets the next idle sound
local groupsReady = false
local lastSignature = ""
local lastBroadcastAt = 0

-- ── Small helpers ────────────────────────────────────────────────────────

local function profileOf(player: Player): Profile?
	if not data then
		return nil
	end
	return data.get(player)
end

local function notify(player: Player, text: string)
	if not player.Parent then
		return
	end
	Net.fire(player, "Notify", "Den", text)
end

local function flatUnit(vector: Vector3, fallback: Vector3): Vector3
	local flat = Vector3.new(vector.X, 0, vector.Z)
	if flat.Magnitude < 1e-3 then
		return fallback
	end
	return flat.Unit
end

local function label(parent: Instance, name: string, text: string, color: Color3, position: UDim2, size: UDim2): TextLabel
	local instance = Instance.new("TextLabel")
	instance.Name = name
	instance.BackgroundTransparency = 1
	instance.Size = size
	instance.Position = position
	instance.Font = Enum.Font.FredokaOne
	instance.Text = text
	instance.TextColor3 = color
	instance.TextScaled = true
	instance.TextStrokeTransparency = 0.4
	instance.Parent = parent
	return instance
end

local function billboard(parent: BasePart, name: string, width: number, height: number, offset: number): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = name
	gui.Size = UDim2.fromScale(width, height)
	gui.StudsOffsetWorldSpace = Vector3.new(0, offset, 0)
	gui.MaxDistance = 140
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.Parent = parent
	return gui
end

-- ── Lock, shield and slot state ──────────────────────────────────────────
-- Wall-clock seconds throughout: lockEndsAt and shieldEndsAt are sent to the
-- client, which compares them against its own os.time(). A monotonic clock
-- would be more precise and completely unshareable.

local function lockActive(den: Den): boolean
	return os.time() < den.lockEndsAt
end

local function lockDef(profile: Profile?)
	local level = if profile then profile.lockLevel else 1
	if not Net.isIntInRange(level, 1, #Constants.LOCK) then
		level = 1
	end
	return Constants.LOCK[level]
end

function DenService.isLocked(player: Player): boolean
	local den = dens[player]
	return den ~= nil and lockActive(den)
end

function DenService.isShielded(player: Player): boolean
	local until_ = shieldUntil[player]
	return until_ ~= nil and os.time() < until_
end

--[[
	profile.denSlots plus the pass bonus, capped at the hard ceiling. Never
	trusts either source blindly: a corrupt denSlots or a monetization service
	that hands back nonsense must not produce a Den with 4 billion pedestals.
]]
function DenService.totalSlots(player: Player): number
	local profile = profileOf(player)
	local base = if profile and Net.isFiniteNumber(profile.denSlots) then profile.denSlots else Constants.DEN_SLOTS_START

	local bonus = 0
	if monetization then
		local granted = monetization.getSlotBonus(player)
		if Net.isFiniteNumber(granted) and granted > 0 then
			bonus = granted
		end
	end

	return math.clamp(math.floor(base + bonus), 0, Constants.DEN_SLOTS_HARD_MAX)
end

-- A pedestal may be stolen from only when the door is open and the owner is
-- out of their grace period. Bound Mixlings never get a prompt at all.
local function stealAllowed(den: Den): boolean
	return not lockActive(den) and not DenService.isShielded(den.player)
end

-- ── Friendship cache ─────────────────────────────────────────────────────

local function pairKey(a: number, b: number): string
	if a > b then
		a, b = b, a
	end
	return a .. ":" .. b
end

local function cacheFriendship(a: number, b: number, value: boolean)
	local rowA = friends[a]
	if not rowA then
		rowA = {}
		friends[a] = rowA
	end
	local rowB = friends[b]
	if not rowB then
		rowB = {}
		friends[b] = rowB
	end
	rowA[b] = value
	rowB[a] = value
end

--[[
	Resolves one pair in the background. Runs at most once per pair per
	session: the answer only changes when someone accepts a friend request
	mid-session, and re-asking on every door touch is exactly the yield this
	cache exists to avoid.
]]
local function primeFriendship(a: Player, b: Player)
	if a == b then
		return
	end
	local row = friends[a.UserId]
	if row and row[b.UserId] ~= nil then
		return
	end
	local key = pairKey(a.UserId, b.UserId)
	if friendPending[key] then
		return
	end
	friendPending[key] = true

	task.spawn(function()
		local ok, result = pcall(function()
			return a:IsFriendsWithAsync(b.UserId)
		end)
		friendPending[key] = nil
		if not ok then
			-- A failed lookup stays uncached so the next door touch retries;
			-- until then the pair reads as "not friends" (see the header).
			warn(("[DenService] friend lookup failed for %s/%s: %s"):format(a.Name, b.Name, tostring(result)))
			return
		end
		cacheFriendship(a.UserId, b.UserId, result == true)
	end)
end

local function areFriends(visitor: Player, owner: Player): boolean
	local row = friends[visitor.UserId]
	local known = if row then row[owner.UserId] else nil
	if known == nil then
		primeFriendship(visitor, owner)
		return false
	end
	return known
end

--[[
	The door rule (GDD §8.3): an unlocked Den is open to everyone, and a
	locked one still admits its owner and the owner's Roblox friends. A Den
	whose owner is not in the server does not exist, so there is nothing to
	keep anyone out of.
]]
function DenService.canEnter(visitor: Player, ownerUserId: number): boolean
	if not Net.isFiniteNumber(ownerUserId) then
		return true
	end
	if visitor.UserId == ownerUserId then
		return true
	end

	for player, den in dens do
		if player.UserId == ownerUserId then
			if not lockActive(den) then
				return true
			end
			return areFriends(visitor, player)
		end
	end
	return true
end

-- ── Collision groups ─────────────────────────────────────────────────────

local function setCharacterGroup(player: Player, group: string)
	local character = player.Character
	if not character then
		return
	end
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = group
		end
	end
end

-- Lets someone the door allows walk through a CanCollide barrier. Expires on
-- the heartbeat, so a disconnect or a respawn mid-pass leaves nothing behind.
local function grantPass(player: Player)
	if not groupsReady then
		return
	end
	passUntil[player] = os.clock() + PASS_SECONDS
	setCharacterGroup(player, GROUP_PASS)
end

local function revokePass(player: Player)
	passUntil[player] = nil
	if groupsReady then
		setCharacterGroup(player, GROUP_DEFAULT)
	end
end

local function registerGroups()
	pcall(function()
		PhysicsService:RegisterCollisionGroup(GROUP_BARRIER)
	end)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(GROUP_PASS)
	end)
	-- The pairing call is the real test: it errors unless both groups exist,
	-- which also covers a re-run in Studio where registration itself throws.
	local ok, err = pcall(function()
		PhysicsService:CollisionGroupSetCollidable(GROUP_BARRIER, GROUP_PASS, false)
	end)
	groupsReady = ok
	if not ok then
		warn(("[DenService] collision groups unavailable (%s); locked doors fall back to the touch barrier only.")
			:format(tostring(err)))
	end
end

-- ── Den geometry ─────────────────────────────────────────────────────────

local function pedestalPivot(den: Den, index: number): CFrame
	local count = math.max(1, Constants.WORLD.PEDESTAL_COUNT)
	-- Spread across the back of the Den, centred on the wall opposite the
	-- door, so nothing is ever standing in the doorway.
	local step = if count > 1 then RING_ARC / (count - 1) else 0
	local angle = math.pi + ((index - 1) * step - RING_ARC * 0.5)

	local base = CFrame.lookAt(den.anchor.Position, den.anchor.Position + den.outward)
	local direction = (base * CFrame.Angles(0, angle, 0)).LookVector
	local position = den.anchor.Position + direction * Constants.WORLD.PEDESTAL_RING_RADIUS
	return CFrame.new(position + Vector3.new(0, PEDESTAL_SIZE.Y * 0.5, 0))
end

--[[
	Where the barrier goes, measured rather than assumed: WorldService frames
	each doorway with two "DoorJamb" parts and a "Lintel", and a Studio
	authored Den (ARCHITECTURE §6) has proportions of its own. The fallback
	derives from Constants.WORLD.DEN_SIZE so a Den with no recognisable door
	still gets a wall across its mouth.

	The returned CFrame looks OUT of the Den, which puts the part's Front face
	— and the countdown printed on it — on the street side (GDD §8.3).
]]
local function doorFrame(folder: Folder, anchor: CFrame, outward: Vector3): (CFrame, Vector3)
	local jambs: { BasePart } = {}
	local lintel: BasePart? = nil
	for _, descendant in folder:GetDescendants() do
		if descendant:IsA("BasePart") then
			if descendant.Name == "DoorJamb" then
				table.insert(jambs, descendant)
			elseif descendant.Name == "Lintel" then
				lintel = descendant
			end
		end
	end

	local width = DOOR_WIDTH_FALLBACK
	local height = DOOR_HEIGHT_FALLBACK
	local thickness = DOOR_THICKNESS
	local centre = anchor.Position + outward * (Constants.WORLD.DEN_SIZE.Z * 0.5)

	if #jambs >= 2 then
		local left, right = jambs[1], jambs[2]
		-- Centre to centre minus one jamb is the gap between their inner faces.
		width = math.max(1, (left.Position - right.Position).Magnitude - math.max(left.Size.X, right.Size.X))
		height = left.Size.Y
		thickness = math.max(left.Size.Z, DOOR_THICKNESS)
		centre = (left.Position + right.Position) * 0.5
	end
	if lintel then
		height = math.max(1, (lintel.Position.Y - lintel.Size.Y * 0.5) - anchor.Position.Y)
	end

	local position = Vector3.new(centre.X, anchor.Position.Y + height * 0.5, centre.Z)
	return CFrame.lookAt(position, position + outward), Vector3.new(width, height, thickness)
end

-- ── Pedestals ────────────────────────────────────────────────────────────

-- What slot `index` costs, as a player-facing line. Slots past the
-- purchasable ceiling exist only through the game pass (GDD §8.3).
local function slotPriceText(index: number): string
	local step = index - Constants.DEN_SLOTS_START
	local price = Constants.DEN_SLOT_PRICES[step]
	if price and index <= Constants.DEN_SLOTS_MAX then
		return Util.comma(price) .. " GOOP"
	end
	return "GAME PASS"
end

local function setPedestalLocked(den: Den, index: number, locked: boolean)
	local pedestal = den.pedestals[index]
	if not pedestal then
		return
	end

	pedestal.Color = if locked then PEDESTAL_LOCKED_COLOR else PEDESTAL_COLOR
	pedestal.Material = if locked then Enum.Material.Slate else Enum.Material.SmoothPlastic
	pedestal.Transparency = if locked then 0.35 else 0

	local existing = den.padlocks[index]
	if not locked then
		if existing then
			existing:Destroy()
			den.padlocks[index] = nil
		end
		return
	end

	if existing then
		local price = existing:FindFirstChild("Price")
		if price and price:IsA("TextLabel") then
			price.Text = slotPriceText(index)
		end
		return
	end

	local gui = billboard(pedestal, "SlotLocked", 4.5, 1.8, 1.9)
	label(gui, "Padlock", "LOCKED", MUTED_COLOR, UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.5))
	label(gui, "Price", slotPriceText(index), WARN_COLOR, UDim2.fromScale(0, 0.5), UDim2.fromScale(1, 0.5))
	den.padlocks[index] = gui
end

local function buildPedestals(den: Den)
	for index = 1, Constants.WORLD.PEDESTAL_COUNT do
		local pedestal = Instance.new("Part")
		pedestal.Name = ("Pedestal%02d"):format(index)
		pedestal.Shape = Enum.PartType.Cylinder
		-- A cylinder's flat faces are on X, so the disc has to be laid down.
		pedestal.Size = Vector3.new(PEDESTAL_SIZE.Y, PEDESTAL_SIZE.X, PEDESTAL_SIZE.Z)
		pedestal.CFrame = pedestalPivot(den, index) * CFrame.Angles(0, 0, math.rad(90))
		pedestal.Anchored = true
		pedestal.CanCollide = true
		pedestal.TopSurface = Enum.SurfaceType.Smooth
		pedestal.BottomSurface = Enum.SurfaceType.Smooth
		pedestal.Color = PEDESTAL_COLOR
		pedestal.Parent = den.ring

		local number = Instance.new("IntValue")
		number.Name = "PedestalIndex"
		number.Value = index
		number.Parent = pedestal

		-- GDD §11.4: "use CollectionService tags for pedestals/doors". Without
		-- the tag every client that needs to find a pedestal — the idle-sound
		-- pass, the tutorial's placement bubble — has to walk Workspace and
		-- key on this service's naming convention, which then cannot change.
		CollectionService:AddTag(pedestal, "Pedestal")
		pedestal:SetAttribute("DenSlot", den.slotIndex)
		pedestal:SetAttribute("PedestalIndex", index)

		den.pedestals[index] = pedestal
	end
end

-- Reconciles the drawn pedestals with the slots the player actually owns.
-- Called from the heartbeat, which is how a slot bought through ShopService
-- or a pass bought mid-session lights up without ShopService knowing this
-- service exists.
local function refreshSlots(den: Den, force: boolean?)
	local slots = DenService.totalSlots(den.player)
	if not force and slots == den.shownSlots then
		return
	end
	den.shownSlots = slots
	for index = 1, Constants.WORLD.PEDESTAL_COUNT do
		setPedestalLocked(den, index, index > slots)
	end
end

-- ── Display models ───────────────────────────────────────────────────────

local function buildSpec(mixling: Mixling): Assembler.BuildSpec
	local secret = if mixling.secretId then SecretRecipes.byId(mixling.secretId) else nil
	return {
		critter = mixling.critter,
		stuff = mixling.stuff,
		rarity = mixling.rarity,
		secretId = mixling.secretId,
		secretName = if secret then secret.name else nil,
		withSound = true,
	}
end

local function displayNameOf(mixling: Mixling): string
	return Assembler.displayName(buildSpec(mixling))
end

local function destroyDisplay(den: Den, index: number)
	local model = den.displays[index]
	den.displays[index] = nil
	den.prompts[index] = nil
	if model then
		model:Destroy()
	end
end

local function playMixSound(model: Model)
	local root = model.PrimaryPart
	if not root then
		return
	end
	local folder = root:FindFirstChild("MixSound")
	if not folder then
		return
	end
	for _, child in folder:GetChildren() do
		if child:IsA("Sound") and child.SoundId ~= "" then
			child:Play()
		end
	end
end

local function attachPrompt(den: Den, root: BasePart, index: number, mixling: Mixling)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "StealPrompt"
	prompt.ObjectText = displayNameOf(mixling)
	prompt.ActionText = "STEAL"
	-- GDD §11.3: hold duration is set here, from rarity, and never sent as a
	-- number the client could shrink.
	prompt.HoldDuration = Rarity.holdTime(mixling.rarity)
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Enabled = stealAllowed(den)
	prompt.Parent = root

	prompt.Triggered:Connect(function(thief: Player)
		if thief == den.player then
			return -- you cannot steal from yourself; the Den panel unplaces
		end
		if not stealAllowed(den) then
			return
		end
		if not den.displays[index] then
			return -- the pedestal emptied while the prompt was held
		end
		DenService.onPedestalPrompt:fire(thief, den.player, index)
	end)

	den.prompts[index] = prompt
end

local function buildDisplay(den: Den, index: number, mixling: Mixling)
	destroyDisplay(den, index)

	local pedestal = den.pedestals[index]
	if not pedestal then
		return
	end

	local pivot = CFrame.new(pedestal.Position + Vector3.new(0, PEDESTAL_SIZE.Y * 0.5 + DISPLAY_HEIGHT, 0))
	local model = Assembler.buildDisplay(buildSpec(mixling), pivot)

	local id = Instance.new("StringValue")
	id.Name = "MixlingId"
	id.Value = mixling.id
	id.Parent = model

	local root = model.PrimaryPart
	if root then
		local gui = billboard(root, "MixlingTag", 7, 2.6, 2.6)
		label(gui, "Title", displayNameOf(mixling), Rarity.color(mixling.rarity), UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.55))
		label(
			gui,
			"Rate",
			Util.abbreviate(Rarity.goopPerSec(mixling.rarity)) .. " Goop/sec",
			TEXT_COLOR,
			UDim2.fromScale(0, 0.55),
			UDim2.fromScale(1, 0.45)
		)

		if mixling.bound then
			-- The starter Mixling is Bound: padlock, and no prompt to hold at
			-- all rather than a prompt that always refuses (GDD §5, §8.3).
			local mark = billboard(root, "BoundTag", 6, 1.1, 4.1)
			label(mark, "Padlock", "LOCKED · BOUND", WARN_COLOR, UDim2.fromScale(0, 0), UDim2.fromScale(1, 1))
		else
			attachPrompt(den, root, index, mixling)
		end
	end

	model.Parent = den.ring
	den.displays[index] = model
end

local function refreshPrompts(den: Den)
	local allowed = stealAllowed(den)
	for _, prompt in den.prompts do
		prompt.Enabled = allowed
	end
end

-- ── The sign and the public list ─────────────────────────────────────────

local function rateOf(player: Player): number
	if not economy then
		return 0
	end
	local rate = economy.getGoopPerSec(player)
	return if Net.isFiniteNumber(rate) then rate else 0
end

local function findLabel(scope: Instance, name: string): TextLabel?
	local found = scope:FindFirstChild(name, true)
	return if found and found:IsA("TextLabel") then found else nil
end

--[[
	The board over the door. WorldService builds it and leaves two empty
	labels, `Owner` and `Rate`, precisely so this service only ever writes
	text (WorldService header, GDD §6). When there is no such board — a
	Studio-authored Den that named things differently — we hang our own
	billboard above the doorway rather than let the Den go unadvertised,
	because a public Goop/sec is a core motivator (GDD §10).
]]
local function bindSign(den: Den)
	local part = den.folder:FindFirstChild("Sign", true) or den.folder:FindFirstChild("DenSign", true)
	if part then
		den.ownerLabel = findLabel(part, "Owner")
		den.rateLabel = findLabel(part, "Rate")
	end

	if not den.ownerLabel or not den.rateLabel then
		local post = Instance.new("Part")
		post.Name = "DenSignAnchor"
		post.Size = Vector3.new(1, 1, 1)
		post.CFrame = den.door * CFrame.new(0, den.doorSize.Y * 0.5 + 2.5, 0)
		post.Anchored = true
		post.CanCollide = false
		post.CanQuery = false
		post.CanTouch = false
		post.Transparency = 1
		post.Parent = den.built

		local gui = billboard(post, "DenSign", 12, 3.2, 0)
		gui.MaxDistance = 260
		den.signGui = gui
		den.ownerLabel = label(gui, "Owner", "", TEXT_COLOR, UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.58))
		den.rateLabel = label(gui, "Rate", "", MUTED_COLOR, UDim2.fromScale(0, 0.58), UDim2.fromScale(1, 0.42))
	end

	local rate = den.rateLabel
	if rate then
		den.rateColor = rate.TextColor3 -- whatever the board was built in
	end
end

local function refreshSign(den: Den)
	local owner = den.ownerLabel
	if owner then
		owner.Text = den.player.DisplayName .. "'S DEN"
	end
	local rate = den.rateLabel
	if rate then
		local text = Util.abbreviate(rateOf(den.player)) .. " Goop/sec"
		if lockActive(den) then
			text ..= "  ·  LOCKED"
		elseif DenService.isShielded(den.player) then
			text ..= "  ·  SHIELDED"
		end
		rate.Text = text
		rate.TextColor3 = if lockActive(den) then WARN_COLOR else den.rateColor
	end
end

function DenService.publicList(): { DenPublic }
	local list: { DenPublic } = {}
	for player, den in dens do
		table.insert(list, {
			userId = player.UserId,
			displayName = player.DisplayName,
			goopPerSec = rateOf(player),
			locked = lockActive(den),
			lockEndsAt = den.lockEndsAt,
			slotIndex = den.slotIndex,
		})
	end
	table.sort(list, function(a: DenPublic, b: DenPublic): boolean
		return a.slotIndex < b.slotIndex
	end)
	return list
end

local function signatureOf(list: { DenPublic }): string
	local parts: { string } = {}
	for _, entry in list do
		table.insert(parts, ("%d/%d/%s/%d/%d"):format(
			entry.userId,
			math.floor(entry.goopPerSec * 100),
			tostring(entry.locked),
			entry.lockEndsAt,
			entry.slotIndex
		))
	end
	return table.concat(parts, "|")
end

--[[
	Pushes the public Den list to everyone. Owner, rate and lock state are the
	only things in it, so it is cheap; it still only goes out when one of them
	actually moved, plus a periodic resend so a client that joined mid-frame
	and missed a broadcast repairs itself within FORCE_SYNC_SECONDS.
]]
local function syncPublic(force: boolean?)
	local list = DenService.publicList()
	local signature = signatureOf(list)
	local now = os.clock()
	if not force and signature == lastSignature and now - lastBroadcastAt < FORCE_SYNC_SECONDS then
		return
	end

	lastSignature = signature
	lastBroadcastAt = now
	for _, den in dens do
		refreshSign(den)
	end
	Net.fireAll("DenSync", list)
end

-- ── The door ─────────────────────────────────────────────────────────────

local function removeBarrier(den: Den)
	local barrier = den.barrier
	den.barrier = nil
	den.countdown = nil
	if barrier then
		barrier:Destroy()
	end
end

local function bounce(den: Den, intruder: Player)
	local now = os.clock()
	if now - (lastBounceAt[intruder] or 0) < BOUNCE_COOLDOWN then
		return
	end
	lastBounceAt[intruder] = now

	local character = intruder.Character
	if character then
		character:PivotTo(character:GetPivot() + den.outward * BOUNCE_STUDS)
	end
	local root = Util.rootPart(intruder)
	if root then
		-- Without this the intruder's own momentum walks them straight back
		-- into the wall and the bounce reads as a stutter.
		root.AssemblyLinearVelocity = Vector3.zero
	end

	notify(intruder, ("%s's Den is locked."):format(den.player.DisplayName))

	if announcements and now - den.lastIntruderAt >= INTRUDER_NOTICE_COOLDOWN then
		den.lastIntruderAt = now
		announcements.toPlayer(den.player, {
			scope = "Local",
			kind = "System",
			text = ("%s bounced off your locked door."):format(intruder.DisplayName),
		})
	end
end

local function onBarrierTouched(den: Den, hit: BasePart)
	local character = hit.Parent
	if not character then
		return
	end
	local player = Players:GetPlayerFromCharacter(character)
	if not player then
		return
	end
	if DenService.canEnter(player, den.player.UserId) then
		grantPass(player)
		return
	end
	bounce(den, player)
end

local function buildBarrier(den: Den)
	if den.barrier then
		return
	end

	local barrier = Instance.new("Part")
	barrier.Name = "DoorLock"
	barrier.Size = den.doorSize
	barrier.CFrame = den.door
	barrier.Anchored = true
	-- See the header: solid when a pass group exists to let the owner through,
	-- otherwise a touch-only barrier so the owner is never trapped outside.
	barrier.CanCollide = groupsReady
	barrier.CanTouch = true
	barrier.CanQuery = false
	barrier.Material = Enum.Material.Neon
	barrier.Color = BARRIER_COLOR
	barrier.Transparency = 0.55
	if groupsReady then
		barrier.CollisionGroup = GROUP_BARRIER
	end
	barrier.Parent = den.built

	local face = Instance.new("SurfaceGui")
	face.Name = "LockFace"
	face.Face = Enum.NormalId.Front -- den.door looks outward, so Front is the street side
	face.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	face.PixelsPerStud = 30
	face.LightInfluence = 0
	face.Parent = barrier

	label(face, "Title", "LOCKED", WARN_COLOR, UDim2.fromScale(0, 0.12), UDim2.fromScale(1, 0.38))
	den.countdown = label(face, "Countdown", "0:00", TEXT_COLOR, UDim2.fromScale(0, 0.5), UDim2.fromScale(1, 0.38))

	barrier.Touched:Connect(function(hit: BasePart)
		onBarrierTouched(den, hit)
	end)

	den.barrier = barrier
end

--[[
	Locks the door (GDD §8.3). The cooldown starts when the lock *ends*, not
	when it starts — "locks for lockDuration, then lockCooldown before reuse"
	— so a level 1 door is reusable 150 s after it was pressed, not 90.
]]
function DenService.tryLock(player: Player): (boolean, string?)
	local den = dens[player]
	if not den then
		return false, "Your Den is not ready yet."
	end
	if lockActive(den) then
		return false, ("Your door is already locked (%s left)."):format(Util.clock(den.lockEndsAt - os.time()))
	end

	local now = os.time()
	if now < den.cooldownEndsAt then
		return false, ("The lock is recharging (%s)."):format(Util.clock(den.cooldownEndsAt - now))
	end

	local def = lockDef(profileOf(player))
	den.lockEndsAt = now + def.duration
	den.cooldownEndsAt = den.lockEndsAt + def.cooldown

	buildBarrier(den)
	den.stealAllowed = stealAllowed(den)
	refreshPrompts(den)
	syncPublic(true)

	if analytics then
		analytics.event("DenLock", { player = player, value = def.duration })
	end
	return true, nil
end

-- The Lock Refresh product (GDD §9): clears the cooldown so the door can be
-- shut again immediately. It does not extend a lock that is already running.
function DenService.refreshLock(player: Player)
	local den = dens[player]
	if not den then
		return
	end
	den.cooldownEndsAt = 0
	notify(player, "Lock refreshed — your door is ready again.")
	if analytics then
		analytics.event("DenLockRefresh", { player = player })
	end
end

-- ── The new-player shield ────────────────────────────────────────────────

local function setShieldBoard(den: Den, on: boolean)
	local existing = den.shieldBoard
	if not on then
		den.shieldBoard = nil
		if existing then
			local post = existing.Parent
			existing:Destroy()
			if post then
				post:Destroy() -- the invisible anchor goes with the bubble
			end
		end
		return
	end
	if existing then
		return
	end

	local post = Instance.new("Part")
	post.Name = "ShieldBubble"
	post.Size = Vector3.new(1, 1, 1)
	post.CFrame = CFrame.new(den.anchor.Position + Vector3.new(0, Constants.WORLD.DEN_SIZE.Y * 0.75, 0))
	post.Anchored = true
	post.CanCollide = false
	post.CanQuery = false
	post.CanTouch = false
	post.Transparency = 1
	post.Parent = den.built

	local gui = billboard(post, "ShieldTag", 12, 3, 0)
	gui.MaxDistance = 300
	label(gui, "Title", "NEW MIXER", WARN_COLOR, UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.6))
	label(gui, "Sub", "protected", TEXT_COLOR, UDim2.fromScale(0, 0.6), UDim2.fromScale(1, 0.4))
	den.shieldBoard = gui
end

local function beginShield(player: Player, profile: Profile)
	local joined = joinedAt[player.UserId]
	if not joined then
		return -- we never saw this session start; refuse rather than guess
	end
	if profile.firstJoin <= 0 or profile.firstJoin < joined then
		return -- a profile older than this session is a rejoin (GDD §8.3)
	end
	shieldUntil[player] = profile.firstJoin + Constants.NEW_PLAYER_SHIELD_SECONDS
end

-- ── Placement ────────────────────────────────────────────────────────────

local function findMixling(profile: Profile, mixlingId: string): (Mixling?, number?)
	return Util.find(profile.mixlings, function(entry: Mixling): boolean
		return entry.id == mixlingId
	end)
end

local function slotHolding(profile: Profile, mixlingId: string): string?
	for slot, id in profile.placed do
		if id == mixlingId then
			return slot
		end
	end
	return nil
end

local function pushPlacement(player: Player, profile: Profile, withMixlings: boolean?)
	if not data then
		return
	end
	if withMixlings then
		data.push(player, { placed = profile.placed, mixlings = profile.mixlings })
	else
		data.push(player, { placed = profile.placed })
	end
end

local function afterPlacementChange(player: Player, profile: Profile, withMixlings: boolean?)
	if economy then
		economy.recompute(player)
	end
	pushPlacement(player, profile, withMixlings)
	syncPublic(true)
end

--[[
	The only way a Mixling reaches a pedestal. Every refusal is a sentence the
	client can show as-is; the client is told the outcome and never consulted
	about it (ARCHITECTURE §7.1).
]]
function DenService.place(player: Player, mixlingId: string, index: number): (boolean, string?)
	if not Net.isString(mixlingId) then
		return false, "That Mixling does not exist."
	end
	if not Net.isIntInRange(index, 1, Constants.WORLD.PEDESTAL_COUNT) then
		return false, "That pedestal does not exist."
	end

	local profile = profileOf(player)
	if not profile then
		return false, "Your Mixlings are still loading."
	end
	local den = dens[player]
	if not den then
		return false, "Your Den is not ready yet."
	end

	if index > DenService.totalSlots(player) then
		return false, "That pedestal is locked. Buy the slot first."
	end

	local mixling = findMixling(profile, mixlingId)
	if not mixling then
		return false, "You do not own that Mixling."
	end
	if slotHolding(profile, mixlingId) then
		return false, "That Mixling is already on a pedestal."
	end

	local key = tostring(index)
	if profile.placed[key] then
		return false, "That pedestal is taken."
	end

	profile.placed[key] = mixlingId
	buildDisplay(den, index, mixling)
	-- GDD §7.5: the Mixling speaks when it lands. Restoring a Den at join
	-- deliberately does not, or a returning player walks into fifteen of them.
	local landed = den.displays[index]
	if landed then
		playMixSound(landed)
	end
	afterPlacementChange(player, profile)

	if analytics then
		analytics.funnel(player, "FirstPlace")
		analytics.event("DenPlace", { player = player, value = mixling.rarity, slot = index })
	end
	if monetization then
		monetization.awardBadge(player, "FirstPlacement")
	end
	return true, nil
end

function DenService.unplace(player: Player, mixlingId: string): boolean
	if not Net.isString(mixlingId) then
		return false
	end
	local profile = profileOf(player)
	if not profile then
		return false
	end

	local key = slotHolding(profile, mixlingId)
	if not key then
		return false
	end

	profile.placed[key] = nil
	local den = dens[player]
	local index = tonumber(key)
	if den and index then
		destroyDisplay(den, index)
	end
	afterPlacementChange(player, profile)
	return true
end

--[[
	StealService only. Ownership moves at bank, not at pickup (GDD §8.4.3),
	but the record has to leave the owner's profile the moment it leaves the
	pedestal — otherwise the owner keeps earning from a Mixling that is
	visibly running down the street. StealService holds it until it is banked
	or handed back through `returnToOwner`.
]]
function DenService.takeFromPedestal(owner: Player, index: number): Mixling?
	if not Net.isIntInRange(index, 1, Constants.WORLD.PEDESTAL_COUNT) then
		return nil
	end
	local profile = profileOf(owner)
	if not profile then
		return nil
	end

	local key = tostring(index)
	local mixlingId = profile.placed[key]
	if not mixlingId then
		return nil
	end

	local mixling, at = findMixling(profile, mixlingId)
	if not mixling then
		-- The pedestal outlived its Mixling; clear the ghost entry so the
		-- rate stops counting it and nobody can carry nothing.
		profile.placed[key] = nil
		afterPlacementChange(owner, profile)
		return nil
	end
	if mixling.bound then
		return nil -- Bound Mixlings never leave their Den (GDD §5, §8.3)
	end

	profile.placed[key] = nil
	if at then
		table.remove(profile.mixlings, at)
	end
	homePedestal[mixling.id] = index

	local den = dens[owner]
	if den then
		destroyDisplay(den, index)
	end
	afterPlacementChange(owner, profile, true)
	return mixling
end

--[[
	The thief's half of a completed steal. The Mixling joins their collection
	and takes the lowest empty pedestal it can; a full Den is not a failure —
	the Mixling is still theirs, it just sits unplaced — so the returned index
	is nil and the caller tells the player.
]]
function DenService.bank(thief: Player, mixling: Mixling): number?
	local profile = profileOf(thief)
	if not profile then
		return nil
	end

	if not findMixling(profile, mixling.id) then
		table.insert(profile.mixlings, mixling)
	end

	local den = dens[thief]
	local slots = DenService.totalSlots(thief)
	local index: number? = nil
	for candidate = 1, slots do
		if not profile.placed[tostring(candidate)] then
			index = candidate
			break
		end
	end

	if not index then
		homePedestal[mixling.id] = nil
		afterPlacementChange(thief, profile, true)
		return nil
	end

	profile.placed[tostring(index)] = mixling.id
	homePedestal[mixling.id] = nil
	if den then
		buildDisplay(den, index, mixling)
		local landed = den.displays[index]
		if landed then
			playMixSound(landed)
		end
	end
	afterPlacementChange(thief, profile, true)
	return index
end

--[[
	The drop-timeout and rage-quit path (GDD §8.4.5, §8.4.6): the Mixling goes
	back to the pedestal it was taken from, or stays in the owner's collection
	when that pedestal has since been filled.
]]
function DenService.returnToOwner(owner: Player, mixling: Mixling)
	local profile = profileOf(owner)
	if not profile then
		warn(("[DenService] returnToOwner for %s dropped: profile already released"):format(owner.Name))
		return
	end

	if not findMixling(profile, mixling.id) then
		table.insert(profile.mixlings, mixling)
	end

	local index = homePedestal[mixling.id]
	homePedestal[mixling.id] = nil

	local free = index ~= nil
		and index <= DenService.totalSlots(owner)
		and profile.placed[tostring(index)] == nil
		and slotHolding(profile, mixling.id) == nil

	if free and index then
		profile.placed[tostring(index)] = mixling.id
		local den = dens[owner]
		if den then
			buildDisplay(den, index, mixling)
		end
	end
	afterPlacementChange(owner, profile, true)
end

-- ── Reads ────────────────────────────────────────────────────────────────

function DenService.getDen(player: Player): Den?
	return dens[player]
end

function DenService.getPedestal(player: Player, index: number): BasePart?
	local den = dens[player]
	if not den or not Net.isIntInRange(index, 1, Constants.WORLD.PEDESTAL_COUNT) then
		return nil
	end
	return den.pedestals[index]
end

-- Any instance inside a Den answers "whose Den is this?" — a pedestal, a
-- display model, the barrier, or the folder itself.
function DenService.ownerOfDen(model: Instance): Player?
	local node: Instance? = model
	while node do
		local owner = ownerByFolder[node]
		if owner then
			return owner
		end
		node = node.Parent
	end
	return nil
end

-- ── Assignment ───────────────────────────────────────────────────────────

local function lowestFreeSlot(): number?
	for index = 1, Constants.SERVER_SIZE do
		if not slotOwner[index] then
			return index
		end
	end
	return nil
end

-- Rebuilds the pedestals from the profile. Entries that point at a Mixling
-- the profile no longer holds, or at a slot the player no longer owns (a
-- lapsed pass), are dropped here rather than paying rent forever.
local function restorePlacements(den: Den, profile: Profile)
	local slots = DenService.totalSlots(den.player)
	local stale: { string } = {}

	for key, mixlingId in profile.placed do
		local index = tonumber(key)
		local mixling = findMixling(profile, mixlingId)
		if not index or not mixling or index < 1 or index > slots or index % 1 ~= 0 then
			table.insert(stale, key)
		else
			buildDisplay(den, index, mixling)
		end
	end

	for _, key in stale do
		profile.placed[key] = nil
	end
end

local function assign(player: Player, profile: Profile)
	if dens[player] or not player.Parent then
		return
	end
	if not world then
		warn("[DenService] WorldService is missing; no Den can be built.")
		return
	end

	local slotIndex = lowestFreeSlot()
	if not slotIndex then
		warn(("[DenService] no free Den slot for %s; the ring holds %d and the server allows %d")
			:format(player.Name, Constants.SERVER_SIZE, #Players:GetPlayers()))
		return
	end

	local folder = world.getDenFolder(slotIndex)
	local anchor = world.getDenAnchor(slotIndex)
	if typeof(folder) ~= "Instance" or not folder:IsA("Folder") then
		warn(("[DenService] WorldService gave no folder for Den slot %d"):format(slotIndex))
		return
	end
	if typeof(anchor) ~= "CFrame" then
		warn(("[DenService] WorldService gave no anchor for Den slot %d"):format(slotIndex))
		return
	end

	local anchorCFrame: CFrame = anchor
	local denFolder: Folder = folder

	-- The door faces the plaza. Deriving that from the plaza position rather
	-- than the anchor's rotation means a Den built facing any direction still
	-- gets its barrier and its sign on the side players walk in from.
	local outward = flatUnit(anchorCFrame.LookVector, Vector3.new(0, 0, -1))
	local plaza = world.getPlazaCenter()
	if typeof(plaza) == "Vector3" then
		outward = flatUnit((plaza :: Vector3) - anchorCFrame.Position, outward)
	end

	local built = Instance.new("Folder")
	built.Name = "DenParts"
	built.Parent = denFolder

	-- WorldService hands over an empty "Pedestals" folder per Den for exactly
	-- this; anything it did not build goes in DenParts. Both are ours, and
	-- both are destroyed whole when the slot is released.
	local pedestalHome = denFolder:FindFirstChild("Pedestals")
	local ring = Instance.new("Folder")
	ring.Name = "Ring"
	ring.Parent = if pedestalHome then pedestalHome else built

	local door, doorSize = doorFrame(denFolder, anchorCFrame, outward)

	local den: Den = {
		player = player,
		slotIndex = slotIndex,
		folder = denFolder,
		built = built,
		ring = ring,
		anchor = anchorCFrame,
		outward = outward,
		door = door,
		doorSize = doorSize,
		pedestals = {},
		padlocks = {},
		displays = {},
		prompts = {},
		shownSlots = -1,
		lockEndsAt = 0,
		cooldownEndsAt = 0,
		barrier = nil,
		countdown = nil,
		signGui = nil,
		ownerLabel = nil,
		rateLabel = nil,
		rateColor = MUTED_COLOR,
		shieldBoard = nil,
		stealAllowed = true,
		shieldOn = false,
		lastIntruderAt = 0,
		nextIdleAt = os.clock() + rng:NextNumber(Constants.IDLE_SOUND_INTERVAL[1], Constants.IDLE_SOUND_INTERVAL[2]),
		lastIdleAt = 0,
	}

	dens[player] = den
	slotOwner[slotIndex] = player
	ownerByFolder[denFolder] = player

	-- Stamp the tenant on the folder so a client can find its own Den by
	-- lookup instead of by inferring it from WorldService's naming scheme.
	-- Attributes replicate, so this is readable from a LocalScript.
	denFolder:SetAttribute("OwnerUserId", player.UserId)
	denFolder:SetAttribute("DenSlot", slotIndex)
	CollectionService:AddTag(denFolder, "Den")

	buildPedestals(den)
	bindSign(den)
	refreshSlots(den, true)

	beginShield(player, profile)
	den.shieldOn = DenService.isShielded(player)
	setShieldBoard(den, den.shieldOn)
	den.stealAllowed = stealAllowed(den)

	restorePlacements(den, profile)
	refreshPrompts(den)

	if economy then
		economy.recompute(player)
	end
	if data then
		data.push(player, {
			placed = profile.placed,
			denSlots = profile.denSlots,
			-- The number every pedestal grid should actually draw against: the
			-- pass bonus included, clamped, decided here rather than re-derived
			-- from `passes` by each screen that needs it.
			denSlotsTotal = DenService.totalSlots(player),
			shielded = den.shieldOn,
			shieldEndsAt = shieldUntil[player] or 0,
		})
	end

	for _, other in Players:GetPlayers() do
		primeFriendship(player, other)
	end
	syncPublic(true)
end

local function release(player: Player)
	local den = dens[player]
	dens[player] = nil
	shieldUntil[player] = nil
	passUntil[player] = nil
	lastBounceAt[player] = nil

	local row = friends[player.UserId]
	friends[player.UserId] = nil
	if row then
		for other in row do
			local otherRow = friends[other]
			if otherRow then
				otherRow[player.UserId] = nil
			end
		end
	end
	joinedAt[player.UserId] = nil

	if den then
		slotOwner[den.slotIndex] = nil
		ownerByFolder[den.folder] = nil
		den.folder:SetAttribute("OwnerUserId", nil)

		-- WorldService's sign outlives the tenant, so hand it back blank
		-- rather than leaving a departed player's name over an empty Den.
		local owner = den.ownerLabel
		if owner and not den.signGui then
			owner.Text = "VACANT DEN"
		end
		local rate = den.rateLabel
		if rate and not den.signGui then
			rate.Text = "0 Goop/sec"
			rate.TextColor3 = den.rateColor
		end

		den.ring:Destroy()
		den.built:Destroy()
	end
	syncPublic(true)
end

-- ── The heartbeat ────────────────────────────────────────────────────────

local function idleSound(den: Den, clock: number)
	if clock < den.nextIdleAt then
		return
	end
	den.nextIdleAt = clock + rng:NextNumber(Constants.IDLE_SOUND_INTERVAL[1], Constants.IDLE_SOUND_INTERVAL[2])
	if clock - den.lastIdleAt < Constants.IDLE_SOUND_MIN_GAP_PER_DEN then
		return -- one Den, one voice at a time (GDD §7.5)
	end

	local models: { Model } = {}
	for _, model in den.displays do
		table.insert(models, model)
	end
	local choice = Util.pick(models, rng)
	if not choice then
		return
	end
	den.lastIdleAt = clock
	playMixSound(choice)
end

local function tickDen(den: Den, clock: number)
	if den.barrier and not lockActive(den) then
		removeBarrier(den)
	end

	local countdown = den.countdown
	if countdown then
		countdown.Text = Util.clock(den.lockEndsAt - os.time())
	end

	-- One comparison covers lock expiry, shield expiry and a shield that was
	-- never granted; prompts are only written when the answer changes.
	local allowed = stealAllowed(den)
	if allowed ~= den.stealAllowed then
		den.stealAllowed = allowed
		refreshPrompts(den)
	end

	local shielded = DenService.isShielded(den.player)
	if shielded ~= den.shieldOn then
		den.shieldOn = shielded
		setShieldBoard(den, shielded)
		if data then
			data.push(den.player, { shielded = shielded, shieldEndsAt = shieldUntil[den.player] or 0 })
		end
	end

	refreshSlots(den)
	idleSound(den, clock)
end

local function tick()
	local clock = os.clock()

	for player, expiry in passUntil do
		if clock > expiry then
			revokePass(player)
		end
	end

	for _, den in dens do
		tickDen(den, clock)
	end
	syncPublic(false)
end

-- ── Remotes ──────────────────────────────────────────────────────────────

local function connectRemotes()
	Net.onServerEvent("RequestPlace", function(player: Player, mixlingId: any, pedestalIndex: any)
		if not Net.isString(mixlingId) then
			return
		end
		if not Net.isIntInRange(pedestalIndex, 1, Constants.WORLD.PEDESTAL_COUNT) then
			return
		end
		local ok, reason = DenService.place(player, mixlingId, pedestalIndex)
		if not ok and reason then
			notify(player, reason)
		end
	end)

	Net.onServerEvent("RequestUnplace", function(player: Player, mixlingId: any)
		if not Net.isString(mixlingId) then
			return
		end
		if not DenService.unplace(player, mixlingId) then
			notify(player, "That Mixling is not on a pedestal.")
		end
	end)

	Net.onServerEvent("RequestLock", function(player: Player)
		local ok, reason = DenService.tryLock(player)
		if ok then
			notify(player, "Door locked.")
			return
		end
		notify(player, reason or "Your door cannot be locked right now.")
	end)
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

function DenService.init(services: { [string]: any })
	data = services.DataService
	economy = services.EconomyService
	world = services.WorldService
	monetization = services.MonetizationService
	announcements = services.AnnouncementService
	analytics = services.AnalyticsService
end

function DenService.start()
	if not data then
		warn("[DenService] DataService is missing; no Den can be assigned.")
		return
	end

	registerGroups()
	connectRemotes()

	local function watchCharacter(player: Player)
		player.CharacterAdded:Connect(function()
			-- A fresh character is back in the default collision group, so a
			-- pass granted to the old one must not outlive it.
			passUntil[player] = nil
		end)
	end

	-- The join stamp has to be older than the profile load it will be compared
	-- against, so anyone already here is dated to module load rather than now.
	for _, player in Players:GetPlayers() do
		joinedAt[player.UserId] = BOOT_AT
		watchCharacter(player)
	end
	Players.PlayerAdded:Connect(function(player: Player)
		joinedAt[player.UserId] = os.time()
		watchCharacter(player)
		for _, other in Players:GetPlayers() do
			primeFriendship(player, other)
		end
	end)

	data.onLoaded:connect(function(player: Player, profile: Profile)
		assign(player, profile)
	end)
	data.forEach(function(player: Player, profile: Profile)
		assign(player, profile) -- anyone whose profile loaded before this service started
	end)

	Players.PlayerRemoving:Connect(release)

	task.spawn(function()
		while true do
			task.wait(SYNC_INTERVAL)
			local ok, err = pcall(function(): any
				tick()
				return nil
			end)
			if not ok then
				-- The heartbeat owns lock expiry: a dead loop leaves every
				-- door shut forever, so it has to outlive a bad frame.
				warn("[DenService] heartbeat failed: " .. tostring(err))
			end
		end
	end)
end

return DenService
