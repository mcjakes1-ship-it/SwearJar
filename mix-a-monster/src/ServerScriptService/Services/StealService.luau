--!strict
--[[
	StealService.luau — the Placed → Carried → (Banked | Dropped) state
	machine, the Bonk Bat, and every rule that decides who owns what.
	GDD §8.4 in full, plus §8.4.6 (rage-quit) and §8.7 (steal stats/badges).

	OWNERSHIP MOVES AT BANK, NEVER AT PICKUP (GDD §8.4.3). Between
	`DenService.takeFromPedestal` and `DenService.bank`, the Mixling belongs to
	NO profile: this service is the only thing holding it. That is deliberate —
	the owner stops earning from it the moment it leaves the pedestal, and the
	thief earns nothing until it is on their own. Every exit from that window
	(bank, drop timeout, bonk, death, disconnect on either side) is handled
	here, because a Mixling that leaks out of it exists nowhere and is gone.

	THE PROMPT FIRING IS NOT PERMISSION. `ProximityPrompt` hold timing runs on
	the thief's client, so a triggered prompt proves only that a client said
	so. Every gate — owner, lock, shield, bound, already-carrying, repeat-victim
	cooldown — is re-checked when the trigger arrives, and the server keeps its
	own clock on the hold: a trigger that arrives before the rarity's hold time
	has actually elapsed (measured from `PromptButtonHoldBegan`, minus one RTT
	of slack) is refused. That check, not `HoldDuration`, is what makes an
	instant-steal exploit fail.

	INTERRUPTION IS SERVER-SIDE TOO. The hold is sampled against the position
	it started from; drift past Constants.STEAL_INTERRUPT_DISTANCE, or a bonk,
	invalidates it. Roblox has no server API to abort a hold in progress, so
	the visible prompt is cancelled by bouncing its `Enabled` flag; that is
	cosmetic, and the authoritative answer is always the invalidated record.

	CARRIERS SHOW THE MODEL, NOT TEXT (GDD §10). The real assembled Mixling is
	welded over the thief's head, massless and non-colliding, so everyone in
	Blendburg can see what is being run down the street. The red "THIEF" tag is
	the opposite: it lives in the OWNER's PlayerGui, adorned to the thief's
	head, so only the person being robbed sees it.

	RAGDOLL IS PlatformStand, NOT Motor6D SURGERY. Breaking and rebuilding
	joints is the prettier ragdoll, but it has to know whether the rig is R6 or
	R15, it fights the Humanoid state machine, and a failure halfway through
	leaves a player permanently in pieces. `PlatformStand` plus an impulse
	drops the player, removes their control for exactly
	Constants.BONK_RAGDOLL_SECONDS, and cannot corrupt a character; the cost is
	that the ragdoll looks stiff. For a 2-second stun that is the right trade.

	ONE LOOP FOR EVERYTHING TIMED (GDD §11.4). Hold interruption, the victim's
	compass refresh and the drop return timer all ride a single heartbeat, so
	nothing here leaks a thread when a player disconnects mid-carry.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Config = ReplicatedStorage:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Config:WaitForChild("Constants"))
local Rarity = require(Config:WaitForChild("Rarity"))
local Assembler = require(Shared:WaitForChild("MixlingAssembler"))
local Net = require(Shared:WaitForChild("Net"))
local Types = require(Shared:WaitForChild("Types"))
local Util = require(Shared:WaitForChild("Util"))

-- Server-only (GDD §11.3). A carried Secret must show its real name over the
-- thief's head; that name never leaves the server except to a client that can
-- already see the model.
local SecretRecipes = require(ServerStorage:WaitForChild("SecretRecipes"))

type Profile = Types.Profile
type Mixling = Types.Mixling
type MixlingView = Types.MixlingView
type AlertKind = "Started" | "Tracking" | "Stolen" | "Recovered" | "Dropped" | "Intruder"

-- What a sibling service (PlayerService refuses teleports with it, DECISIONS
-- D9) is allowed to know about a carry. Always a copy: the live record is
-- this file's alone.
export type CarriedInfo = {
	mixling: Mixling,
	view: MixlingView,
	ownerUserId: number,
	ownerName: string,
	startedAt: number,
}

type Hold = {
	prompt: ProximityPrompt,
	kind: string, -- "Steal" | "Drop"
	owner: Player?, -- steal: the victim
	index: number?, -- steal: which pedestal
	dropId: string?, -- drop: key into `dropped`
	origin: Vector3,
	beganAt: number,
	duration: number,
	valid: boolean,
	endedAt: number?,
}

type Carry = {
	mixling: Mixling,
	view: MixlingView,
	owner: Player, -- the ORIGINAL owner, until a bank says otherwise
	ownerUserId: number,
	ownerName: string,
	model: Model,
	root: BasePart,
	humanoid: Humanoid, -- the one captured at pickup, never "the player's now"
	walkSpeed: number,
	jumpPower: number,
	jumpHeight: number,
	tag: BillboardGui?,
	startedAt: number,
	nextAlertAt: number,
	touches: { RBXScriptConnection },
}

type Dropped = {
	mixling: Mixling,
	view: MixlingView,
	owner: Player,
	ownerUserId: number,
	ownerName: string,
	model: Model,
	root: BasePart,
	prompt: ProximityPrompt,
	expiresAt: number,
}

local StealService = {}
StealService.Name = "StealService"

StealService.onBanked = Util.signal()

-- ── Local tunables ───────────────────────────────────────────────────────
-- Presentation, geometry and cadence. None of these is a balance value — GDD
-- §17 owns everything the player feels, and all of that is in Constants. The
-- two exceptions are called out in their comments.

local NOTIFY_KIND = "Steal"
local CARRY_FOLDER = "CarriedMixlings" -- one workspace folder owns every loose Mixling
local BAT_NAME = "Bonk Bat"
local BAT_GRIP = Vector3.new(0, -1.1, 0)
local BAT_HANDLE_SIZE = Vector3.new(0.4, 2.6, 0.4)
local BAT_HEAD_SIZE = Vector3.new(0.9, 1.3, 0.9)
local BAT_COLOR = Color3.fromRGB(168, 124, 76)
local BAT_HEAD_COLOR = Color3.fromRGB(226, 96, 96)

local CARRY_HEIGHT = 3.4 -- studs from the Head to the Mixling's root
local DROP_LIFT = 2 -- studs above the carrier a dropped Mixling falls from
local TICK = 0.1 -- the one heartbeat: holds, compass, drop timers
local ALERT_INTERVAL = 1 -- how often the victim's compass gets a fresh position
-- Network slack on the server's own hold clock. It is a security threshold, so
-- it lives in Constants rather than here.
local HOLD_GRACE = Constants.STEAL_HOLD_GRACE
local HOLD_KEEP = 0.5 -- a finished hold record outlives its release this long
local PROMPT_BOUNCE = 0.15 -- how long a cancelled prompt is disabled for
local PICKUP_DISTANCE = 10 -- prompt reach on a dropped Mixling
-- Vertical share of the bonk impulse; the strength is Constants.BONK_KNOCKBACK.
-- A pure-horizontal shove just scrapes people along the ground and reads as a
-- network hiccup rather than a hit. Both dials live in Constants.
local KNOCKBACK_LIFT = Constants.BONK_KNOCKBACK_LIFT
local ALARM_SECONDS = 4
local ALARM_RANGE = 110
local TAG_RANGE = 300 -- how far the owner can read their own THIEF tag

local THIEF_COLOR = Color3.fromRGB(255, 72, 72)
local ALARM_ASSET = { "Sounds", "Den", "Alarm" } -- optional, like every other asset (§6)

-- ── State ────────────────────────────────────────────────────────────────

local data: any = nil
local den: any = nil
local economy: any = nil
local announcements: any = nil
local monetization: any = nil
local analytics: any = nil

local carrying: { [Player]: Carry } = {}
local dropped: { [string]: Dropped } = {} -- mixling.id -> loose in the world
local dropByPrompt: { [ProximityPrompt]: string } = {}
local holds: { [Player]: Hold } = {}
local lastBonkAt: { [Player]: number } = {}
local ragdollUntil: { [Player]: number } = {}
-- thiefUserId .. ":" .. victimUserId -> os.clock() the cooldown lifts.
-- GDD §8.4.7: banking from someone buys them 45 seconds of peace from you.
local repeatVictim: { [string]: number } = {}

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
	Net.fire(player, "Notify", NOTIFY_KIND, text)
end

local function specOf(mixling: Mixling): Assembler.BuildSpec
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

local function viewOf(mixling: Mixling): MixlingView
	local spec = specOf(mixling)
	return {
		id = mixling.id,
		critter = mixling.critter,
		stuff = mixling.stuff,
		rarity = mixling.rarity,
		secretId = mixling.secretId,
		secretName = spec.secretName,
		bound = mixling.bound,
		displayName = Assembler.displayName(spec),
		goopPerSec = Rarity.goopPerSec(mixling.rarity),
	}
end

local function carryFolder(): Folder
	local existing = Workspace:FindFirstChild(CARRY_FOLDER)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = CARRY_FOLDER
	created.Parent = Workspace
	return created
end

local function headOf(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local head = character:FindFirstChild("Head")
	return if head and head:IsA("BasePart") then head else nil
end

local function isAlive(player: Player): boolean
	local humanoid = Util.humanoid(player)
	return humanoid ~= nil and humanoid.Health > 0
end

local function victimKey(thief: Player, victimUserId: number): string
	return thief.UserId .. ":" .. victimUserId
end

--[[
	The alert the owner's HUD draws (GDD §8.4.2): a banner and a compass arrow
	pointing at the thief. `position` is refreshed on the heartbeat while the
	carry lasts, and those refreshes go out as kind "Tracking" rather than a
	repeated "Started" — a client that read them as new events would toast the
	victim once a second for the whole chase.
]]
local function alertOwner(owner: Player?, kind: AlertKind, view: MixlingView, thief: Player?, position: Vector3?)
	if not owner or not owner.Parent then
		return
	end
	local alert: Types.TheftAlert = {
		kind = kind,
		mixlingName = view.displayName,
		rarity = view.rarity,
		thiefName = if thief then thief.DisplayName else nil,
		thiefUserId = if thief then thief.UserId else nil,
	}
	Net.fire(owner, "TheftAlert", alert, position)
end

local function pushCarryState(player: Player, view: MixlingView?)
	if not player.Parent then
		return
	end
	Net.fire(player, "CarryState", view)
end

-- Optional asset, exactly like every sound in the game (ARCHITECTURE §6): with
-- no Assets/Sounds/Den/Alarm the theft is silent rather than broken.
local function alarmTemplate(): Sound?
	local node: Instance? = ReplicatedStorage:FindFirstChild("Assets")
	for _, step in ALARM_ASSET do
		if not node then
			return nil
		end
		node = node:FindFirstChild(step)
	end
	return if node and node:IsA("Sound") then node else nil
end

local function playAlarm(owner: Player, index: number)
	if not den then
		return
	end
	local pedestal = den.getPedestal(owner, index)
	if not pedestal or not pedestal:IsA("BasePart") then
		return
	end
	local template = alarmTemplate()
	if not template then
		return
	end

	local sound = template:Clone()
	sound.Name = "TheftAlarm"
	sound.RollOffMaxDistance = ALARM_RANGE
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.Parent = pedestal
	sound:Play()
	task.delay(ALARM_SECONDS, function()
		sound:Destroy()
	end)
end

-- ── The THIEF tag (owner's eyes only) ────────────────────────────────────
-- A world BillboardGui would tell the whole server who is carrying. Parented
-- to the owner's PlayerGui and adorned to the thief's head, it renders in the
-- world for exactly one player (GDD §8.4.2).

local function showThiefTag(owner: Player, thief: Player): BillboardGui?
	local head = headOf(thief)
	local playerGui = owner:FindFirstChildOfClass("PlayerGui")
	if not head or not playerGui then
		return nil
	end

	local board = Instance.new("BillboardGui")
	board.Name = "ThiefTag"
	board.Adornee = head
	board.AlwaysOnTop = true
	board.ResetOnSpawn = false -- the owner respawning must not blind them
	board.MaxDistance = TAG_RANGE
	board.Size = UDim2.fromScale(5, 1.4)
	board.StudsOffsetWorldSpace = Vector3.new(0, 2.2, 0)

	local text = Instance.new("TextLabel")
	text.Name = "Label"
	text.BackgroundTransparency = 1
	text.Size = UDim2.fromScale(1, 1)
	text.Font = Enum.Font.GothamBold
	text.Text = "THIEF"
	text.TextColor3 = THIEF_COLOR
	text.TextScaled = true
	text.TextStrokeTransparency = 0.35
	text.Parent = board

	board.Parent = playerGui
	return board
end

-- ── The Bonk Bat ─────────────────────────────────────────────────────────
-- Built in code so the repo needs no Studio Tool asset. Everyone gets one on
-- spawn; carriers do not (GDD §8.4.2), which is enforced by destroying it on
-- pickup and rebuilding it on release — a Tool parked in a folder is one more
-- thing to leak when a player disconnects mid-carry.

local function buildBat(): Tool
	local tool = Instance.new("Tool")
	tool.Name = BAT_NAME
	tool.ToolTip = "Bonk a thief. Hitting a carrier drops what they stole."
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool.GripPos = BAT_GRIP

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = BAT_HANDLE_SIZE
	handle.Color = BAT_COLOR
	handle.Material = Enum.Material.Wood
	handle.CanCollide = false
	handle.TopSurface = Enum.SurfaceType.Smooth
	handle.BottomSurface = Enum.SurfaceType.Smooth
	handle.Parent = tool

	local head = Instance.new("Part")
	head.Name = "Bonker"
	head.Size = BAT_HEAD_SIZE
	head.Color = BAT_HEAD_COLOR
	head.Material = Enum.Material.SmoothPlastic
	head.CanCollide = false
	head.Massless = true
	head.CFrame = handle.CFrame * CFrame.new(0, BAT_HANDLE_SIZE.Y * 0.5 + BAT_HEAD_SIZE.Y * 0.4, 0)
	head.Parent = tool

	-- A Weld with an explicit C0, not a WeldConstraint: a WeldConstraint
	-- captures its offset when it first becomes active, and a Tool sitting in
	-- a Backpack is not active yet.
	local weld = Instance.new("Weld")
	weld.Name = "BonkerWeld"
	weld.Part0 = handle
	weld.Part1 = head
	weld.C0 = CFrame.new(0, BAT_HANDLE_SIZE.Y * 0.5 + BAT_HEAD_SIZE.Y * 0.4, 0)
	weld.Parent = handle

	return tool
end

local function removeBat(player: Player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		local stowed = backpack:FindFirstChild(BAT_NAME)
		if stowed then
			stowed:Destroy()
		end
	end
	local character = player.Character
	if character then
		local held = character:FindFirstChild(BAT_NAME)
		if held then
			held:Destroy()
		end
	end
end

local function giveBat(player: Player)
	task.spawn(function()
		if carrying[player] then
			return
		end
		local backpack = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 10)
		if not backpack or not backpack:IsA("Backpack") or not player.Parent then
			return
		end
		if carrying[player] or backpack:FindFirstChild(BAT_NAME) then
			return
		end
		local character = player.Character
		if character and character:FindFirstChild(BAT_NAME) then
			return
		end
		buildBat().Parent = backpack
	end)
end

-- ── Carry effects on the character ───────────────────────────────────────

--[[
	Humanoids obey either JumpPower or JumpHeight depending on
	Workspace.CharacterUseJumpPower, so both are clamped from the one constant:
	the height a launch speed of Constants.CARRY_MAX_JUMP_POWER reaches is
	v² / 2g. Without this a carrier could set JumpHeight and hop over every
	defender in Blendburg.
]]
local function jumpHeightCap(): number
	local gravity = Workspace.Gravity
	if gravity <= 0 then
		return Constants.CARRY_MAX_JUMP_POWER
	end
	return (Constants.CARRY_MAX_JUMP_POWER ^ 2) / (2 * gravity)
end

local function applyCarryPenalty(carry: Carry)
	local humanoid = carry.humanoid
	if not humanoid.Parent then
		return
	end
	humanoid.WalkSpeed = carry.walkSpeed * Constants.CARRY_WALKSPEED_MULT
	humanoid.JumpPower = math.min(carry.jumpPower, Constants.CARRY_MAX_JUMP_POWER)
	humanoid.JumpHeight = math.min(carry.jumpHeight, jumpHeightCap())
end

--[[
	Every exit from Carried comes through here, including death and
	disconnect. Restoring the humanoid we captured (rather than "the player's
	humanoid now") is what stops the classic bug: a respawn mid-carry would
	otherwise write 0.85x onto a brand-new character and leave it there.
]]
local function restoreCharacter(carry: Carry)
	local humanoid = carry.humanoid
	if not humanoid.Parent then
		return -- the character it belonged to is already gone
	end
	humanoid.WalkSpeed = carry.walkSpeed
	humanoid.JumpPower = carry.jumpPower
	humanoid.JumpHeight = carry.jumpHeight
end

-- ── Hold tracking ────────────────────────────────────────────────────────

-- Roblox exposes no way to abort a hold from the server, so the prompt is
-- bounced off and back to whatever DenService left on it. This is feedback
-- only: the authoritative refusal is the invalidated hold record, and every
-- gate is re-checked at the trigger regardless of what Enabled says.
local function cancelPrompt(prompt: ProximityPrompt)
	if not prompt.Parent then
		return
	end
	local was = prompt.Enabled
	prompt.Enabled = false
	task.delay(PROMPT_BOUNCE, function()
		if prompt.Parent then
			prompt.Enabled = was
		end
	end)
end

local function invalidateHold(player: Player, reason: string?)
	local hold = holds[player]
	if not hold or not hold.valid then
		return
	end
	hold.valid = false
	cancelPrompt(hold.prompt)
	if reason then
		notify(player, reason)
	end
end

-- The server's own clock on the hold. A trigger that arrives before the hold
-- could physically have completed is an exploit, not a fast player.
local function holdCompleted(hold: Hold): boolean
	return os.clock() - hold.beganAt >= hold.duration - HOLD_GRACE
end

-- ── Eligibility (GDD §8.4.1) ─────────────────────────────────────────────

--[[
	Every reason a steal can be refused, in one place, evaluated twice: once
	when the hold starts so the thief is told immediately, and once when the
	trigger arrives because that is the only check that counts.
]]
local function canStart(thief: Player, owner: Player, index: number): (boolean, string?)
	if thief == owner then
		return false, "That one is already yours."
	end
	if carrying[thief] then
		return false, "You can only carry one Mixling at a time."
	end
	if not isAlive(thief) then
		return false, nil
	end
	if ragdollUntil[thief] then
		return false, nil
	end
	if not den then
		return false, nil
	end
	if den.isShielded(owner) then
		return false, owner.DisplayName .. " is still a new player."
	end
	if not den.canEnter(thief, owner.UserId) then
		return false, "That Den is locked."
	end

	local until_ = repeatVictim[victimKey(thief, owner.UserId)]
	if until_ and os.clock() < until_ then
		return false, ("Wait %s before robbing %s again."):format(Util.clock(until_ - os.clock()), owner.DisplayName)
	end

	local profile = profileOf(owner)
	if not profile then
		return false, nil
	end
	local mixlingId = profile.placed[tostring(index)]
	if not mixlingId then
		return false, "That pedestal is empty."
	end
	local mixling = Util.find(profile.mixlings, function(entry: Mixling): boolean
		return entry.id == mixlingId
	end)
	if not mixling then
		return false, "That pedestal is empty."
	end
	if mixling.bound then
		return false, "Bound Mixlings can never be stolen."
	end

	return true, nil
end

-- ── Dropped Mixlings (GDD §8.4.5) ────────────────────────────────────────

local function destroyDrop(entry: Dropped)
	dropped[entry.mixling.id] = nil
	dropByPrompt[entry.prompt] = nil
	entry.model:Destroy()
end

local function landInWorld(mixling: Mixling, view: MixlingView, owner: Player, ownerName: string, model: Model, root: BasePart)
	root.Anchored = false
	root.CanCollide = true
	root.CanQuery = true
	root.CanTouch = true
	root.Massless = false

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "DropPrompt"
	prompt.ObjectText = view.displayName
	prompt.ActionText = "TAKE"
	prompt.HoldDuration = Constants.DROP_PICKUP_HOLD
	prompt.MaxActivationDistance = PICKUP_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Parent = root

	local entry: Dropped = {
		mixling = mixling,
		view = view,
		owner = owner,
		ownerUserId = owner.UserId,
		ownerName = ownerName,
		model = model,
		root = root,
		prompt = prompt,
		expiresAt = os.clock() + Constants.DROP_RETURN_SECONDS,
	}
	dropped[mixling.id] = entry
	dropByPrompt[prompt] = mixling.id
	model.Parent = carryFolder()
	return entry
end

-- The 8-second timeout: back to the pedestal it came from, or to the owner's
-- collection when that pedestal has since been filled (DenService decides).
local function returnDrop(entry: Dropped)
	destroyDrop(entry)
	if den and entry.owner.Parent then
		den.returnToOwner(entry.owner, entry.mixling)
		alertOwner(entry.owner, "Recovered", entry.view, nil, nil)
		notify(entry.owner, entry.view.displayName .. " found its way home.")
		return
	end
	-- The owner left while it lay on the ground: their profile is gone with
	-- them, and DataService already wrote the copy this service handed back
	-- through onReleasing. Nothing to do but let it go.
	warn(("[StealService] %s was dropped with no owner in the server; discarding the world copy"):format(entry.view.displayName))
end

-- ── Carry (GDD §8.4.2) ───────────────────────────────────────────────────

-- Assigned in the Bank section below. The pedestal watcher a carry installs
-- has to reach the bank, and the bank has to unwind the carry, so one of the
-- two is declared ahead of the other.
local bankCarried: (thief: Player) -> ()

local function attachToHead(player: Player, model: Model, root: BasePart): boolean
	local head = headOf(player)
	if not head then
		return false
	end

	root.Anchored = false
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false -- never let the trophy trip its own bank pedestal
	root.Massless = true

	local weld = Instance.new("Weld")
	weld.Name = "CarryWeld"
	weld.Part0 = head
	weld.Part1 = root
	weld.C0 = CFrame.new(0, CARRY_HEIGHT, 0)
	weld.Parent = root

	model:PivotTo(head.CFrame * CFrame.new(0, CARRY_HEIGHT, 0))
	model.Parent = carryFolder()
	return true
end

local function bankPedestalTouched(thief: Player, index: number)
	local carry = carrying[thief]
	if not carry or not den then
		return
	end
	local profile = profileOf(thief)
	if not profile then
		return
	end
	if profile.placed[tostring(index)] ~= nil then
		return -- occupied; the thief has to find an empty one
	end
	if index > den.totalSlots(thief) then
		return -- a locked slot is not a pedestal yet
	end
	bankCarried(thief)
end

-- Bank detection is a Touched on the thief's OWN pedestals, connected for the
-- duration of the carry only. Polling every carrier against fifteen pedestals
-- on the heartbeat would cost more and still miss a fast run-through.
local function watchOwnPedestals(thief: Player, carry: Carry)
	if not den then
		return
	end
	local myDen = den.getDen(thief)
	if not myDen then
		return -- no Den in this server means nowhere to bank; the carry stands
	end
	for index = 1, Constants.WORLD.PEDESTAL_COUNT do
		local pedestal = myDen.pedestals[index]
		if pedestal then
			local connection = pedestal.Touched:Connect(function(hit: BasePart)
				local character = thief.Character
				if not character or not hit:IsDescendantOf(character) then
					return
				end
				bankPedestalTouched(thief, index)
			end)
			table.insert(carry.touches, connection)
		end
	end
end

-- A Mixling that fails to attach must never evaporate: every early exit here
-- hands it straight back to the owner it was just taken from.
local function abortCarry(owner: Player, mixling: Mixling, model: Model?)
	if model then
		model:Destroy()
	end
	if den then
		den.returnToOwner(owner, mixling)
	end
end

local function beginCarry(thief: Player, owner: Player, mixling: Mixling, view: MixlingView)
	local humanoid = Util.humanoid(thief)
	if not humanoid then
		abortCarry(owner, mixling, nil)
		return
	end

	local model = Assembler.build(specOf(mixling))
	local root = model.PrimaryPart
	if not root then
		-- Unreachable in practice (the Assembler guarantees a root), but a
		-- Mixling with nowhere to weld would vanish.
		abortCarry(owner, mixling, model)
		return
	end

	local carry: Carry = {
		mixling = mixling,
		view = view,
		owner = owner,
		ownerUserId = owner.UserId,
		ownerName = owner.DisplayName,
		model = model,
		root = root,
		humanoid = humanoid,
		walkSpeed = humanoid.WalkSpeed,
		jumpPower = humanoid.JumpPower,
		jumpHeight = humanoid.JumpHeight,
		tag = nil,
		startedAt = os.clock(),
		nextAlertAt = os.clock() + ALERT_INTERVAL,
		touches = {},
	}

	if not attachToHead(thief, model, root) then
		abortCarry(owner, mixling, model)
		return
	end

	carrying[thief] = carry
	applyCarryPenalty(carry)
	removeBat(thief) -- a carrier cannot bonk (GDD §8.4.2)
	carry.tag = showThiefTag(owner, thief)
	watchOwnPedestals(thief, carry)

	pushCarryState(thief, view)
	notify(thief, ("Run! Touch an empty pedestal in your own Den to keep %s."):format(view.displayName))

	local root0 = Util.rootPart(thief)
	alertOwner(owner, "Started", view, thief, if root0 then root0.Position else nil)
	notify(owner, ("%s is stealing your %s!"):format(thief.DisplayName, view.displayName))

	if analytics then
		-- `victimRate` is what the Den still earns with this Mixling gone: GDD
		-- §15 wants theft measured in income, not incidents, and that number
		-- only exists in EconomyService.
		analytics.event("StealStarted", {
			player = thief,
			victim = owner.UserId,
			rarity = mixling.rarity,
			victimRate = if economy then economy.getGoopPerSec(owner) else 0,
			value = Rarity.goopPerSec(mixling.rarity),
		})
	end
end

--[[
	Detaches, restores and clears — the single exit from Carried. The model is
	handed back to the caller still alive and parented to the carry folder, so
	each caller can decide whether it lands in the world (drop), is consumed
	(bank) or is destroyed (rage-quit).
]]
local function endCarry(thief: Player): Carry?
	local carry = carrying[thief]
	if not carry then
		return nil
	end
	carrying[thief] = nil

	for _, connection in carry.touches do
		connection:Disconnect()
	end
	table.clear(carry.touches)

	local weld = carry.root:FindFirstChild("CarryWeld")
	if weld then
		weld:Destroy()
	end

	local tag = carry.tag
	if tag then
		tag:Destroy()
		carry.tag = nil
	end

	restoreCharacter(carry)
	giveBat(thief)
	pushCarryState(thief, nil)
	return carry
end

-- ── Bank (GDD §8.4.3) ────────────────────────────────────────────────────

--[[
	The only place ownership changes hands. Everything downstream — stats,
	badge, funnel step, the repeat-victim cooldown, the banner — hangs off this
	one transition, so there is exactly one way for a Mixling to change owner.
]]
function bankCarried(thief: Player)
	local carry = carrying[thief]
	if not carry or not den then
		return
	end

	local finished = endCarry(thief)
	if not finished then
		return
	end
	finished.model:Destroy() -- DenService builds the pedestal display itself

	local index = den.bank(thief, finished.mixling)
	local view = finished.view

	-- Recovering your own dropped Mixling runs the same path (anyone may pick
	-- a dropped one up, GDD §8.4.5) but it is not a steal: no stat, no banner,
	-- and certainly no "you were robbed" alert to yourself.
	if finished.ownerUserId == thief.UserId then
		notify(thief, ("%s is home safe."):format(view.displayName))
		alertOwner(thief, "Recovered", view, nil, nil)
		return
	end

	local profile = profileOf(thief)
	if profile then
		profile.stats.stealsBanked += 1
		-- GDD §8.4: a steal is scored at a minute of the victim's production.
		-- 60 is the seconds-in-a-minute conversion, not a balance value.
		profile.stats.goopStolen += Rarity.goopPerSec(finished.mixling.rarity) * 60
		if data then
			data.push(thief, { stats = profile.stats })
		end
	end

	repeatVictim[victimKey(thief, finished.ownerUserId)] = os.clock() + Constants.STEAL_REPEAT_VICTIM_COOLDOWN

	StealService.onBanked:fire(thief, finished.ownerUserId, finished.mixling)

	if index then
		notify(thief, ("%s is yours — pedestal %d."):format(view.displayName, index))
	else
		notify(thief, ("%s is yours, but your Den is full. Place it from the Den panel."):format(view.displayName))
	end

	alertOwner(finished.owner, "Stolen", view, thief, nil)
	notify(finished.owner, ("%s got away with your %s."):format(thief.DisplayName, view.displayName))

	-- GDD §8.8: big steals are server news, the same bar the roll banners use.
	if announcements and finished.mixling.rarity >= Constants.RARITY_EPIC then
		local line: Types.Announcement = {
			scope = "Server",
			kind = "Steal",
			text = ("%s stole %s from %s!"):format(thief.DisplayName, view.displayName, finished.ownerName),
			rarity = finished.mixling.rarity,
			playerName = thief.DisplayName,
			shake = finished.mixling.rarity >= Constants.RARITY_LEGENDARY,
			fanfare = false,
		}
		announcements.server(line)
	end

	if monetization then
		monetization.awardBadge(thief, "FirstSteal")
	end
	if analytics then
		analytics.funnel(thief, "FirstSteal")
		analytics.event("StealBanked", {
			player = thief,
			victim = finished.ownerUserId,
			rarity = finished.mixling.rarity,
			value = Rarity.goopPerSec(finished.mixling.rarity) * 60,
		})
	end
end

-- ── Drop (GDD §8.4.4, §8.4.5) ────────────────────────────────────────────

function StealService.dropCarried(player: Player, reason: string)
	local carry = endCarry(player)
	if not carry then
		return
	end

	local root = Util.rootPart(player)
	if not root or not carry.owner.Parent then
		-- No body to drop from (a disconnect that beat us to the character),
		-- or an owner already on their way out. Hand it back unconditionally:
		-- a Mixling in this window belongs to no profile, so anything less
		-- than a write deletes it. If the owner's profile has already been
		-- released, DenService warns and it is genuinely gone — which is why
		-- the rage-quit path runs on onReleasing and not on PlayerRemoving.
		carry.model:Destroy()
		if den then
			den.returnToOwner(carry.owner, carry.mixling)
		end
		alertOwner(carry.owner, "Recovered", carry.view, nil, nil)
		return
	end

	carry.model:PivotTo(CFrame.new(root.Position + Vector3.new(0, DROP_LIFT, 0)))
	landInWorld(carry.mixling, carry.view, carry.owner, carry.ownerName, carry.model, carry.root)

	-- `reason` is a telemetry label, not a line of dialogue; the player can see
	-- perfectly well what just happened to them.
	notify(player, ("You lost %s!"):format(carry.view.displayName))
	alertOwner(carry.owner, "Dropped", carry.view, player, root.Position)
	notify(carry.owner, ("%s was dropped! It comes home in %d seconds if nobody grabs it."):format(
		carry.view.displayName,
		Constants.DROP_RETURN_SECONDS
	))

	if analytics then
		analytics.event("StealDropped", { player = player, reason = reason, rarity = carry.mixling.rarity })
	end
end

-- The dropped model is thrown away and the carried one rebuilt rather than
-- reused: the two states want opposite physics and a different prompt, and a
-- fresh build cannot inherit half of the old one.
local function takeDrop(taker: Player, entry: Dropped)
	destroyDrop(entry)
	beginCarry(taker, entry.owner, entry.mixling, entry.view)
end

-- ── Bonk (GDD §8.4.4) ────────────────────────────────────────────────────

--[[
	PlatformStand plus an impulse. See the file header for why this is not
	Motor6D surgery: it is rig-agnostic and cannot leave a character broken.
	Recovery is guarded by a token so a second bonk during the first stun
	extends it instead of ending it early.
]]
local function ragdoll(player: Player, humanoid: Humanoid, root: BasePart, impulse: Vector3)
	local until_ = os.clock() + Constants.BONK_RAGDOLL_SECONDS
	ragdollUntil[player] = until_
	humanoid.PlatformStand = true
	root.AssemblyLinearVelocity = impulse

	task.delay(Constants.BONK_RAGDOLL_SECONDS, function()
		local current = ragdollUntil[player]
		if current ~= nil and current > until_ then
			return -- re-bonked; the later timer owns the recovery
		end
		ragdollUntil[player] = nil
		if humanoid.Parent and humanoid.Health > 0 then
			humanoid.PlatformStand = false
		end
	end)
end

local function bonkImpulse(from: Vector3, to: Vector3): Vector3
	local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	local direction = if flat.Magnitude > 0 then flat.Unit else Vector3.new(0, 0, 1)
	return (direction + Vector3.new(0, KNOCKBACK_LIFT, 0)).Unit * Constants.BONK_KNOCKBACK
end

-- DECISIONS D12: the client says "I swung" and nothing else, so the server
-- picks the target. Nearest wins outright — no preference for carriers, or a
-- defender in a crowd could reach past the person in front of them.
local function nearestTarget(swinger: Player, from: Vector3): (Player?, BasePart?)
	local best: Player? = nil
	local bestRoot: BasePart? = nil
	local bestDistance = Constants.BONK_RANGE

	for _, other in Players:GetPlayers() do
		if other ~= swinger then
			local root = Util.rootPart(other)
			local humanoid = Util.humanoid(other)
			if root and humanoid and humanoid.Health > 0 then
				local distance = (root.Position - from).Magnitude
				if distance <= bestDistance then
					bestDistance = distance
					best = other
					bestRoot = root
				end
			end
		end
	end
	return best, bestRoot
end

local function onBonk(swinger: Player)
	local last = lastBonkAt[swinger]
	if last and os.clock() - last < Constants.BONK_COOLDOWN then
		return
	end
	if carrying[swinger] or ragdollUntil[swinger] then
		return -- both hands full, or face down in the street
	end

	local character = swinger.Character
	if not character or not character:FindFirstChild(BAT_NAME) then
		return -- the bat has to be equipped; "I swung" with nothing is nothing
	end
	local from = Util.rootPart(swinger)
	if not from or not isAlive(swinger) then
		return
	end

	lastBonkAt[swinger] = os.clock()

	local target, targetRoot = nearestTarget(swinger, from.Position)
	if not target or not targetRoot then
		return
	end
	local targetHumanoid = Util.humanoid(target)
	if not targetHumanoid then
		return
	end

	local impulse = bonkImpulse(from.Position, targetRoot.Position)

	-- GDD §8.4.1: a bonk interrupts a pickup in progress. This is the reason
	-- it comes before the carrier test — the most valuable bonk in the game is
	-- the one that lands on someone two seconds into holding your pedestal,
	-- and they are not carrying anything yet.
	invalidateHold(target, "Bonked!")

	local carry = carrying[target]
	if not carry then
		targetRoot.AssemblyLinearVelocity = impulse -- knockback only (GDD §8.4.4)
		return
	end

	ragdoll(target, targetHumanoid, targetRoot, impulse)
	StealService.dropCarried(target, "Bonked")

	local profile = profileOf(swinger)
	if profile then
		profile.stats.stealsFoiled += 1
		if data then
			data.push(swinger, { stats = profile.stats })
		end
	end
	notify(swinger, ("BONK! You made %s drop %s."):format(target.DisplayName, carry.view.displayName))

	if monetization then
		monetization.awardBadge(swinger, "FirstBonk")
	end
	if analytics then
		analytics.event("Bonk", { player = swinger, target = target.UserId, rarity = carry.mixling.rarity })
	end
end

-- ── Prompt wiring ────────────────────────────────────────────────────────

-- The prompt only reports where a hold started; the record it opens is what
-- the trigger is judged against.
local function onHoldBegan(prompt: ProximityPrompt, player: Player)
	local root = Util.rootPart(player)
	if not root then
		return
	end

	local dropId = dropByPrompt[prompt]
	if dropId then
		if carrying[player] then
			notify(player, "You are already carrying something.")
			cancelPrompt(prompt)
			return
		end
		holds[player] = {
			prompt = prompt,
			kind = "Drop",
			owner = nil,
			index = nil,
			dropId = dropId,
			origin = root.Position,
			beganAt = os.clock(),
			duration = prompt.HoldDuration,
			valid = true,
			endedAt = nil,
		}
		return
	end

	if prompt.Name ~= "StealPrompt" or not den then
		return
	end

	-- DenService parents the steal prompt inside the display model on the
	-- pedestal, so the Den answers "whose?" and the display list answers
	-- "which pedestal?".
	local owner = den.ownerOfDen(prompt)
	if not owner then
		return
	end
	local ownerDen = den.getDen(owner)
	if not ownerDen then
		return
	end

	local index: number? = nil
	for slot, model in ownerDen.displays do
		if prompt:IsDescendantOf(model) then
			index = slot
			break
		end
	end
	if not index then
		return
	end

	local ok, reason = canStart(player, owner, index)
	if not ok then
		if reason then
			notify(player, reason)
		end
		cancelPrompt(prompt)
		return
	end

	holds[player] = {
		prompt = prompt,
		kind = "Steal",
		owner = owner,
		index = index,
		dropId = nil,
		origin = root.Position,
		-- The prompt's own HoldDuration is DenService's copy of the rarity
		-- hold time (GDD §11.3), so the server's clock and the client's bar
		-- can never disagree about how long this was supposed to take.
		beganAt = os.clock(),
		duration = prompt.HoldDuration,
		valid = true,
		endedAt = nil,
	}
end

--[[
	A hold ends both when the player lets go early and when it completes, and
	the completion order against Triggered is not guaranteed. So the record is
	marked rather than deleted and the heartbeat sweeps it a moment later; the
	elapsed-time check is what actually decides whether it counted.
]]
local function onHoldEnded(prompt: ProximityPrompt, player: Player)
	local hold = holds[player]
	if not hold or hold.prompt ~= prompt then
		return
	end
	hold.endedAt = os.clock()
end

local function onPedestalPrompt(thief: Player, owner: Player, index: number)
	local hold = holds[thief]
	if not hold or hold.kind ~= "Steal" or hold.owner ~= owner or hold.index ~= index then
		return -- a trigger with no hold behind it never happened
	end
	holds[thief] = nil
	if not hold.valid then
		return
	end
	if not holdCompleted(hold) then
		warn(("[StealService] %s triggered a steal %.2fs into a %.2fs hold; refused"):format(
			thief.Name,
			os.clock() - hold.beganAt,
			hold.duration
		))
		return
	end

	-- Everything is asked again here, because this is the check that matters.
	local ok, reason = canStart(thief, owner, index)
	if not ok then
		if reason then
			notify(thief, reason)
		end
		return
	end
	if not den then
		return
	end

	local mixling = den.takeFromPedestal(owner, index)
	if not mixling then
		return -- someone else took it in the same frame
	end

	local view = viewOf(mixling)
	beginCarry(thief, owner, mixling, view)
	playAlarm(owner, index)
end

local function onDropPrompt(prompt: ProximityPrompt, taker: Player)
	local hold = holds[taker]
	holds[taker] = nil

	local dropId = dropByPrompt[prompt]
	if not dropId then
		return
	end
	local entry = dropped[dropId]
	if not entry then
		return
	end
	if not hold or hold.kind ~= "Drop" or hold.dropId ~= dropId or not hold.valid or not holdCompleted(hold) then
		return
	end
	if carrying[taker] or not isAlive(taker) then
		return
	end

	takeDrop(taker, entry)
end

-- ── The heartbeat ────────────────────────────────────────────────────────

local function tickHolds(clock: number)
	for player, hold in holds do
		if not player.Parent then
			holds[player] = nil
		elseif hold.endedAt ~= nil and clock - hold.endedAt > HOLD_KEEP then
			holds[player] = nil
		elseif clock - hold.beganAt > hold.duration + HOLD_KEEP + HOLD_GRACE then
			holds[player] = nil
		elseif hold.valid and hold.kind == "Steal" then
			local root = Util.rootPart(player)
			if not root then
				hold.valid = false
			elseif (root.Position - hold.origin).Magnitude > Constants.STEAL_INTERRUPT_DISTANCE then
				invalidateHold(player, "You moved — hold still to steal.")
			end
		end
	end
end

local function tickCarries(clock: number)
	for player, carry in carrying do
		if not player.Parent then
			continue -- PlayerRemoving owns this one; never race it
		end
		local root = Util.rootPart(player)
		if not root or not isAlive(player) then
			StealService.dropCarried(player, "Down")
		elseif clock >= carry.nextAlertAt then
			carry.nextAlertAt = clock + ALERT_INTERVAL
			alertOwner(carry.owner, "Tracking", carry.view, player, root.Position)
		end
	end
end

local function tickDrops(clock: number)
	for _, entry in dropped do
		if clock >= entry.expiresAt then
			returnDrop(entry)
		end
	end
end

local function tick()
	local clock = os.clock()
	tickHolds(clock)
	tickCarries(clock)
	tickDrops(clock)

	for key, until_ in repeatVictim do
		if clock > until_ then
			repeatVictim[key] = nil
		end
	end
end

-- ── Session lifecycle ────────────────────────────────────────────────────

local function onCharacterAdded(player: Player, character: Model)
	ragdollUntil[player] = nil
	-- A carry can never survive a respawn. Death already dropped it; anything
	-- still here is a leak, and dropping it is how it stops being one.
	if carrying[player] then
		StealService.dropCarried(player, "Respawned")
	end
	giveBat(player)

	task.spawn(function()
		local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
		if not humanoid or not humanoid:IsA("Humanoid") then
			return
		end
		humanoid.Died:Connect(function()
			ragdollUntil[player] = nil
			StealService.dropCarried(player, "Down")
		end)
	end)
end

--[[
	GDD §8.4.6, the rage-quit rule. If the ORIGINAL owner leaves while their
	Mixling is Carried or Dropped it goes back into their profile and the world
	copy is destroyed. This runs on DataService.onReleasing — the last
	synchronous moment before the profile is written — so `returnToOwner` still
	has a live profile to write into. Nothing in here may yield.
]]
local function onOwnerReleasing(owner: Player)
	for thief, carry in carrying do
		if carry.owner == owner then
			local finished = endCarry(thief)
			if finished then
				finished.model:Destroy()
				if den then
					den.returnToOwner(owner, finished.mixling)
				end
				notify(thief, ("%s left. %s went home with them."):format(owner.DisplayName, finished.view.displayName))
			end
		end
	end

	for _, entry in dropped do
		if entry.owner == owner then
			destroyDrop(entry)
			if den then
				den.returnToOwner(owner, entry.mixling)
			end
		end
	end
end

-- The other half of §8.4.6: a thief who quits mid-carry drops what they were
-- carrying where they stood, so the chase resolves in the world instead of
-- deleting a Mixling.
local function onPlayerRemoving(player: Player)
	if carrying[player] then
		StealService.dropCarried(player, "Disconnected")
	end

	holds[player] = nil
	lastBonkAt[player] = nil
	ragdollUntil[player] = nil

	-- Their cooldowns as a thief go with them; the ones where they were the
	-- victim expire on the heartbeat like any other.
	local prefix = player.UserId .. ":"
	for key in repeatVictim do
		if key:sub(1, #prefix) == prefix then
			repeatVictim[key] = nil
		end
	end
end

-- ── Public API ───────────────────────────────────────────────────────────

function StealService.isCarrying(player: Player): boolean
	return carrying[player] ~= nil
end

function StealService.getCarried(player: Player): CarriedInfo?
	local carry = carrying[player]
	if not carry then
		return nil
	end
	return {
		mixling = carry.mixling,
		view = carry.view,
		ownerUserId = carry.ownerUserId,
		ownerName = carry.ownerName,
		startedAt = carry.startedAt,
	}
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

function StealService.init(services: { [string]: any })
	data = services.DataService
	den = services.DenService
	economy = services.EconomyService
	announcements = services.AnnouncementService
	monetization = services.MonetizationService
	analytics = services.AnalyticsService
end

function StealService.start()
	if not den then
		warn("[StealService] DenService is missing; nothing can be stolen.")
		return
	end

	den.onPedestalPrompt:connect(onPedestalPrompt)

	if data then
		data.onReleasing:connect(function(player: Player)
			onOwnerReleasing(player)
		end)
	end

	ProximityPromptService.PromptButtonHoldBegan:Connect(onHoldBegan)
	ProximityPromptService.PromptButtonHoldEnded:Connect(onHoldEnded)
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
		if dropByPrompt[prompt] then
			onDropPrompt(prompt, player)
		end
	end)

	-- Neither of these carries an argument, by design (DECISIONS D12): "I
	-- swung" and "I let go" are the whole message, so there is nothing for a
	-- client to lie about and nothing to validate. Anything an exploiter
	-- appends is ignored by the signature.
	Net.onServerEvent("RequestBonk", function(player: Player)
		onBonk(player)
	end)

	Net.onServerEvent("RequestDropCarried", function(player: Player)
		if not carrying[player] then
			return
		end
		StealService.dropCarried(player, "Dropped")
	end)

	local function watch(player: Player)
		player.CharacterAdded:Connect(function(character: Model)
			onCharacterAdded(player, character)
		end)
		-- Death is not the only way to lose a character (a scripted respawn or
		-- a teleport does it too), and this fires while the old body is still
		-- there — so the Mixling lands where the carrier was standing rather
		-- than at whatever spawn the next character appears on.
		player.CharacterRemoving:Connect(function()
			if carrying[player] then
				StealService.dropCarried(player, "Down")
			end
		end)
		local character = player.Character
		if character then
			onCharacterAdded(player, character)
		end
	end

	for _, player in Players:GetPlayers() do
		watch(player)
	end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	task.spawn(function()
		while true do
			task.wait(TICK)
			local ok, err = pcall(function(): any
				tick()
				return nil
			end)
			if not ok then
				-- This loop owns the drop timer and the hold interrupt. A dead
				-- one strands Mixlings on the ground forever, so it has to
				-- survive a bad frame.
				warn("[StealService] heartbeat failed: " .. tostring(err))
			end
		end
	end)
end

return StealService
