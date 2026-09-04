--!strict
--[[
	BonkController.luau — the input half of the Bonk Bat.
	GDD §8.4.4 (the bonk), §8.4.2 (a carrier may not bonk), §3 and §10
	(mobile-first; touch controls are mandatory), §11.3 ("the client only
	reports 'I swung'").

	IT SENDS ONE ARGUMENT-FREE INTENT AND NOTHING ELSE. `RequestBonk` carries
	no target, no position and no timestamp (DECISIONS D12): a target chosen
	here — even one the server distance-checks — still lets an exploiter pick
	which of several people in range gets hit. The server picks the nearest
	valid target, applies Constants.BONK_RANGE and Constants.BONK_COOLDOWN, and
	decides whether anything happened. Nothing in this file knows who was hit.

	THE SWING IS THE PLAYER'S, THE HIT IS THE SERVER'S. The wind-up and the
	Bonk cue play the moment the player swings, before any reply. Feedback on
	an unconfirmed action is only an exploit when it grants something, and this
	grants nothing — no damage, no drop, no Goop — while a bat that waits a
	round trip before moving feels broken on a phone. It is drawn on the
	swinger's own screen alone: this file replicates nothing, and Net.luau is
	the complete remote surface, so there is no wire for a swing that others
	could see. An authored swing animation played server-side is what would
	give the rest of Blendburg that, and it is an asset, not a client change.

	THE BAT IS THE SERVER'S TOO. StealService builds the Tool named "Bonk Bat",
	hands one out on every spawn, destroys it while its owner is carrying a
	stolen Mixling and rebuilds it when the carry ends. So this file never
	creates one, never keeps one and never assumes one: it watches the Backpack
	and the character, adopts whatever bat is there at the moment, and shows
	nothing when there is none. That is also why the carrier rule needs no
	enforcement here — a carrier has no bat to swing.

	MOBILE (GDD §3). Tapping the screen activates a Tool that is ALREADY
	equipped, so a phone player with the bat in their Backpack has no way to
	swing at all; the BONK button is that way, and it equips first when it has
	to. It sits bottom-LEFT because the HUD's button cluster and Roblox's jump
	button both own the bottom-right, and it is lifted clear of the movement
	thumbstick that owns the bottom-left corner itself — left edge, above the
	stick, reachable without covering either.

	THE COOLDOWN DRAWN HERE IS A COURTESY. Constants.BONK_COOLDOWN greys the
	button and runs the sweep so nobody spends the window tapping a remote the
	server is going to drop. StealService keeps the cooldown that counts.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = ReplicatedStorage:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Config:WaitForChild("Constants"))
local Net = require(Shared:WaitForChild("Net"))
local UiKit = require(Shared:WaitForChild("UiKit"))
local Util = require(Shared:WaitForChild("Util"))

local BonkController = {}
BonkController.Name = "BonkController"

local LocalPlayer = Players.LocalPlayer

-- ── Local tunables ───────────────────────────────────────────────────────
-- Geometry, animation timing and two contracts with other files. Constants
-- owns everything the player earns or waits for (GDD §17) — the one number
-- here that the player feels is Constants.BONK_COOLDOWN, and it is read from
-- there, not restated.

local BAT_NAME = "Bonk Bat" -- StealService's Tool name; the seam between the two files
-- The engine's own grip weld, made on equip and named the same on R6 and R15.
-- Posing it is rig-agnostic and cannot leave a character broken, which is the
-- same reason StealService ragdolls with PlatformStand instead of joints.
local GRIP_WELD = "RightGrip"

--[[
	Above the HUD (10) and its panel stage (8): defending is never buried under
	a menu that happens to be open, for the reason AlertController's alarms sit
	at 100. Below the Mixer's reveal (90) just as deliberately — the roll is
	never interrupted (GDD §2, pillar 1), not even by this.
]]
local DISPLAY_ORDER = 12

local MARGIN = 12
--[[
	How far the button is lifted off the bottom edge. Roblox's movement
	thumbstick owns the bottom-left corner on a touch device and a button drawn
	on top of it is a button that blocks movement, so this clears the stick
	rather than sharing with it. Clamped against the viewport in layout() so a
	640x360 window keeps the button on screen instead of pushing it into the
	HUD's top band.
]]
local THUMBSTICK_CLEAR = 150
local LIFT_MAX = 0.42

-- Comfortably past UiKit's 44px minimum: this is a panic button pressed with
-- a thumb while running, not a menu row.
local BUTTON_SIZE = Vector2.new(124, 78)
local BUTTON_SIZE_SMALL = Vector2.new(96, 62)
local TEXT_CEILING = 22

local SWEEP_TRANSPARENCY = 0.45
local FULL = UDim2.fromScale(1, 1)
local EMPTY = UDim2.fromScale(0, 1)

--[[
	The pose the bat is snapped into, and how long it takes to swing back down
	out of it. Back easing on the return overshoots the resting grip, so the
	swing has a follow-through instead of stopping dead at neutral.
]]
local SWING_WINDUP = CFrame.Angles(math.rad(-70), 0, math.rad(30))
local SWING_TIME = 0.22

--[[
	The beat between equipping the bat for a player who tapped BONK with it
	stowed and telling the server they swung. The server refuses a swing from a
	character with no bat in it, and an equip made on this client is not there
	until it replicates. It is one beat, not a guarantee: on a bad connection
	the server drops that first swing, and the second tap — bat already in
	hand — lands. It is added to the local cooldown so this client's window can
	only ever be the more generous of the two.
]]
local EQUIP_SETTLE = 0.1

-- Viewport and touch state are polled rather than watched: the camera can be
-- replaced under us and each replacement would leak a listener (HudController
-- makes the same call for the same reason).
local POLL_INTERVAL = 0.5

-- ── State ────────────────────────────────────────────────────────────────

local sound: any = nil

local gui: ScreenGui? = nil
local button: TextButton? = nil
local sweep: Frame? = nil
local sweepTween: Tween? = nil

local bat: Tool? = nil
local batActivated: RBXScriptConnection? = nil
local backpackWatch: { RBXScriptConnection } = {}
local characterWatch: { RBXScriptConnection } = {}

-- Told by the server over CarryState. UI only — see the header: the missing
-- bat is what actually stops a carrier from swinging.
local carrying = false

local readyAt = 0
local lastViewport = Vector2.zero
local lastTouch = false

local swingWeld: Weld? = nil
local swingBase: CFrame? = nil

-- The button taps into the swing and the swing repaints the button, so one of
-- the two has to be named before it is written. This is the one.
local swing: (settle: number) -> ()

-- ── Small helpers ────────────────────────────────────────────────────────

local function viewportSize(): Vector2
	local camera = Workspace.CurrentCamera
	return if camera then camera.ViewportSize else Vector2.new(1280, 720)
end

local function textCeiling(target: GuiObject, ceiling: number)
	local constraint = target:FindFirstChildOfClass("UITextSizeConstraint")
	if constraint then
		constraint.MaxTextSize = ceiling
	end
end

-- The bat wherever it currently is. Equipped first: that is the copy the
-- server tests a swing against.
local function currentBat(): Tool?
	local character = LocalPlayer.Character
	if character then
		local held = character:FindFirstChild(BAT_NAME)
		if held and held:IsA("Tool") then
			return held
		end
	end
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	if backpack then
		local stowed = backpack:FindFirstChild(BAT_NAME)
		if stowed and stowed:IsA("Tool") then
			return stowed
		end
	end
	return nil
end

local function canSwing(): boolean
	if not bat then
		return false -- no bat: respawning, or carrying (GDD §8.4.2)
	end
	return os.clock() >= readyAt
end

-- ── The touch button ─────────────────────────────────────────────────────

local function layout(target: TextButton)
	local viewport = viewportSize()
	local size = if UiKit.isSmallScreen() then BUTTON_SIZE_SMALL else BUTTON_SIZE
	local lift = math.min(THUMBSTICK_CLEAR, viewport.Y * LIFT_MAX)
	target.Size = UDim2.fromOffset(size.X, size.Y)
	target.Position = UDim2.new(0, MARGIN, 1, -lift)
end

--[[
	The cooldown wipe, and the only thing that draws the disabled state.

	It is painted from `readyAt` rather than stepped, so it is correct from any
	starting point: a repaint mid-cooldown resumes the wipe with the time that
	is actually left instead of restarting it. The button's own colour is left
	alone deliberately — UiKit.button tweens that back to the colour it was
	built with on every press, and a grey written over the top of it would be
	undone by the next tap.
]]
local function paintSweep()
	local frame = sweep
	if not frame then
		return
	end

	local running = sweepTween
	if running then
		running:Cancel()
		sweepTween = nil
	end

	if carrying then
		frame.Size = FULL
		return
	end

	local remaining = readyAt - os.clock()
	if remaining <= 0 then
		frame.Size = EMPTY
		return
	end

	frame.Size = UDim2.fromScale(math.min(1, remaining / Constants.BONK_COOLDOWN), 1)
	sweepTween = UiKit.tween(frame, { Size = EMPTY }, remaining, Enum.EasingStyle.Linear)
end

--[[
	A tap equips the bat when it is stowed and swings either way, because a
	phone player cannot activate a Tool that is not in their hand and would
	otherwise have to find it in the Backpack tray first.
]]
local function onTap()
	local tool = bat
	if not tool or not canSwing() then
		return
	end
	local character = LocalPlayer.Character
	if not character then
		return
	end
	if tool.Parent == character then
		swing(0)
		return
	end

	local humanoid = Util.humanoid(LocalPlayer)
	if not humanoid then
		return
	end
	humanoid:EquipTool(tool)
	swing(EQUIP_SETTLE)
end

local function ensureButton(): TextButton
	local existing = button
	if existing then
		return existing
	end

	local screen = UiKit.screen("MixBonk", DISPLAY_ORDER)
	local created = UiKit.button({
		Text = "BONK",
		BackgroundColor3 = UiKit.PALETTE.danger,
		TextColor3 = UiKit.PALETTE.text,
		TextWrapped = true,
		AnchorPoint = Vector2.new(0, 1),
		Corner = 16,
		Stroke = UiKit.PALETTE.warn,
		ClipsDescendants = true, -- keeps the sweep inside the rounded corners
		Parent = screen,
	}, onTap)
	textCeiling(created, TEXT_CEILING)

	-- An inert Frame, so it dims the button without swallowing the tap that
	-- lands on it.
	local overlay = UiKit.frame({
		BackgroundColor3 = UiKit.PALETTE.ink,
		BackgroundTransparency = SWEEP_TRANSPARENCY,
		Size = EMPTY,
		Parent = created,
	})

	gui = screen
	button = created
	sweep = overlay
	layout(created)
	return created
end

--[[
	The whole visible state of this controller, from one place: shown on a
	touch device that has a bat, hidden otherwise. Nothing is built on a
	desktop client at all — the first call that would show the button is the
	one that creates it.
]]
local function refresh()
	if not (UiKit.isTouch() and bat) then
		local screen = gui
		if screen then
			screen.Enabled = false
		end
		return
	end

	local target = ensureButton()
	local screen = gui
	if screen then
		screen.Enabled = true
	end

	layout(target)
	-- GDD §8.4.2, told by CarryState. The bat is normally gone by now and the
	-- button with it; this covers the moment before that removal replicates.
	target.Text = if carrying then "HANDS FULL" else "BONK"
	paintSweep()
end

-- ── The swing ────────────────────────────────────────────────────────────

--[[
	Poses the engine's grip weld and lets it fall back to rest. C0 is the base
	of the joint and animations write Transform, so this composes with whatever
	the character is already playing instead of fighting it, and the pose is
	restored exactly rather than guessed at.
]]
local function playSwing()
	local character = LocalPlayer.Character
	if not character then
		return
	end
	local found = character:FindFirstChild(GRIP_WELD, true)
	if not found or not found:IsA("Weld") then
		return -- nothing in hand yet; the sound still sells the swing
	end

	local weld = found
	if swingWeld ~= weld then
		swingWeld = weld
		swingBase = weld.C0
	end
	local base = swingBase
	if not base then
		return
	end

	weld.C0 = base * SWING_WINDUP
	UiKit.tween(weld, { C0 = base }, SWING_TIME, Enum.EasingStyle.Back)
end

local function strike()
	playSwing()
	if sound then
		sound.play("Bonk")
	end
	-- No target, no position, no timestamp (DECISIONS D12).
	Net.event("RequestBonk"):FireServer()
end

--[[
	`settle` is the delay the equip needs before the server can see the bat;
	it is zero for a swing made with the bat already in hand. The cooldown
	starts at the tap either way, so the button answers the finger rather than
	the network.
]]
function swing(settle: number)
	if not canSwing() then
		return
	end

	readyAt = os.clock() + Constants.BONK_COOLDOWN + settle
	refresh()
	task.delay(Constants.BONK_COOLDOWN + settle, refresh)

	if settle <= 0 then
		strike()
		return
	end
	task.delay(settle, strike)
end

-- ── Finding the bat ──────────────────────────────────────────────────────

local function onActivated()
	swing(0) -- Activated only fires equipped, so there is nothing to settle
end

--[[
	Adopts whatever bat exists now. The Tool keeps its identity as it moves
	between the Backpack and the character, so equipping does not churn the
	connection; a destroyed-and-rebuilt bat (every carry, every respawn) is a
	different instance and gets a fresh one.
]]
local function syncBat()
	local found = currentBat()
	if found ~= bat then
		local existing = batActivated
		if existing then
			existing:Disconnect()
		end
		batActivated = nil
		bat = found
		if found then
			batActivated = found.Activated:Connect(onActivated)
		end
	end
	refresh()
end

local function stopWatching(list: { RBXScriptConnection })
	for _, connection in list do
		connection:Disconnect()
	end
	table.clear(list)
end

-- Both containers are replaced over a session — the Backpack on every respawn,
-- the character with it — so each keeps its own bucket and the bucket is
-- emptied when its container is.
local function watch(container: Instance, list: { RBXScriptConnection })
	stopWatching(list)
	table.insert(list, container.ChildAdded:Connect(syncBat))
	table.insert(list, container.ChildRemoved:Connect(syncBat))
	syncBat()
end

local function onCharacter(character: Model)
	-- The grip weld died with the old character, and the resting pose captured
	-- from it means nothing to the new one.
	swingWeld = nil
	swingBase = nil
	watch(character, characterWatch)
end

local function poll()
	local size = viewportSize()
	local touch = UiKit.isTouch()
	if size == lastViewport and touch == lastTouch then
		return
	end
	lastViewport = size
	lastTouch = touch
	refresh()
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

function BonkController.init(controllers: { [string]: any })
	sound = controllers.SoundController
end

function BonkController.start()
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	if backpack then
		watch(backpack, backpackWatch)
	end
	LocalPlayer.ChildAdded:Connect(function(child: Instance)
		if child:IsA("Backpack") then
			watch(child, backpackWatch)
		end
	end)

	local character = LocalPlayer.Character
	if character then
		onCharacter(character)
	end
	LocalPlayer.CharacterAdded:Connect(onCharacter)
	LocalPlayer.CharacterRemoving:Connect(function()
		stopWatching(characterWatch)
		swingWeld = nil
		swingBase = nil
		syncBat()
	end)

	--[[
		The server's word on whether this player is carrying (GDD §8.4.2). It
		arrives on both edges of a carry, and the payload is a MixlingView or
		nil; nothing here reads the view, only whether there is one.
	]]
	Net.event("CarryState").OnClientEvent:Connect(function(view: any)
		carrying = type(view) == "table"
		refresh()
	end)

	lastTouch = UiKit.isTouch()
	lastViewport = viewportSize()
	syncBat()

	task.spawn(function()
		while true do
			task.wait(POLL_INTERVAL)
			poll()
		end
	end)
end

return BonkController
