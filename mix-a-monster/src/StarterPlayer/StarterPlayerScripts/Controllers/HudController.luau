--!strict
--[[
	HudController.luau — the always-on layer and the panel host.
	GDD §3 (mobile-first), §8.2 (the interpolated Goop number), §8.8 (daily
	reward, codes), §10 (HUD layout, overhead nameplates), §18 (friendly fire).

	THE REGISTRY API. Every other controller reaches the HUD through these and
	never builds a screen of its own:

	    registerPanel(name, frame)    -- hand the host a frame you built
	    openPanel(name) -> boolean    -- shows it, closing whatever was open
	    closePanel(name)
	    closeAll()
	    isAnyPanelOpen() -> boolean
	    setButtonHighlight(name, on)  -- pulse a cluster button (TutorialController)

	The four cluster buttons that are not mine open panels named "Mixer",
	"Den", "Shop" and "Mixdex"; their owners register those names. A tap on a
	button whose panel has not registered yet does nothing, which is the right
	answer during boot and the only safe one afterwards.

	ONE SCREEN IS NOT IN THE STACK. The Mixer's reveal deliberately sits at a
	DisplayOrder above every panel (MixerUIController's header explains why:
	the roll is never interrupted, GDD §2 pillar 1), so it owns its own
	ScreenGui and exposes open()/close() instead of handing over a frame.
	DELEGATES routes openPanel("Mixer") to it, and every openPanel is refused
	outright while isRevealing() is true — nothing this file draws is worth
	covering those three seconds. isAnyPanelOpen() therefore reports on the
	host's own stack, which is the only thing the host can see.

	WHY THE HOST OWNS THE STACK: "at most one panel open" is not a rule eight
	screens can each half-enforce. One table, one open name, one animation, one
	close button in the stage's own top-right corner — which on a landscape
	phone sits about mid-height on the right edge, an easy thumb reach, and
	costs the panel no height the way a close button under it would. Panels
	keep their own layout; the host parents them into its stage and toggles
	Visible. Codes, Settings, Daily and Travel are registered here; the rest
	arrive from their own controllers.

	NOTHING HERE BLOCKS MOVEMENT (GDD §5's rule, applied to every panel). The
	scrim is an inert Frame — not a button — so it never sinks a touch, and the
	stage is inset from the bottom of the screen by TOUCH_CONTROL_CLEAR on
	touch devices, which is where Roblox puts the thumbstick and the jump
	button. No ContextActionService binding, no ModalEnabled, no WalkSpeed:
	a panel is something drawn over the game, never something that stops it.

	THE GOOP NUMBER IS DRAWN EVERY FRAME AND DECIDED NEVER. The server ticks
	once a second (GDD §8.2); RenderStepped paints
	ClientState.interpolatedGoop() between ticks so the number climbs instead
	of stepping. That interpolation is a rendering trick over the last synced
	balance — every figure the player reads still came from a ProfileSync, and
	a tap swaps the abbreviation for the exact synced figure.

	SETTINGS ARE RENDERED FROM THE PROFILE, NEVER FROM THE TAP. A toggle fires
	SetSetting and then waits; the row redraws when the ProfileSync lands. If a
	write is refused the toggle simply never moves, which is the truth.

	NAMEPLATES ARE FED BY DenSync, NOT BY A LOOP. GDD §10 wants name and
	Goop/sec over every player because public flex is the motivator; one
	BillboardGui per player, its text rewritten only when a DenSync arrives.
	Not over the local player: the HUD already shows that number, and a
	nameplate on your own head is a permanent obstruction of your own camera.
	No theft state is drawn here either — the THIEF tag is owner-only and
	belongs to AlertController.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = ReplicatedStorage:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Config:WaitForChild("Constants"))
local Net = require(Shared:WaitForChild("Net"))
local Types = require(Shared:WaitForChild("Types"))
local UiKit = require(Shared:WaitForChild("UiKit"))
local Util = require(Shared:WaitForChild("Util"))

local ClientState = require(script.Parent.Parent:WaitForChild("ClientState"))

local HudController = {}
HudController.Name = "HudController"

local LocalPlayer = Players.LocalPlayer

-- ── Local tunables ───────────────────────────────────────────────────────
-- Geometry, cadences and animation thresholds. Constants owns everything the
-- player earns or waits for (GDD §17); how many pixels a margin is has never
-- been a balance question, and burying these there would hide the numbers
-- that are.

local MARGIN = 10
local GAP = 6

--[[
	Bottom strip kept clear of the panel stage and the button cluster on touch
	devices. Roblox's default controls live there — the movement thumbstick
	bottom-left, the jump button bottom-right — and a panel drawn over them is
	a panel that blocks movement. Clamped against the viewport in layout()
	so a 640x360 window does not spend a third of its height on clearance.
]]
local TOUCH_CONTROL_CLEAR = 128
local TOP_BAND_MAX = 0.42 -- ceiling on the readout's share of a short screen
local BOTTOM_BAND_MAX = 0.34 -- ceiling on the clearance's share of one

local CLUSTER_COLUMNS = 2 -- six buttons, two wide: room for the word "SETTINGS"
local CLUSTER_ROWS = 3
local MIN_BLOCK_SHRINK = 0.55 -- floor on the top readout when the screen is tiny
local CHIP_HEIGHT = 46 -- TRAVEL and DAILY; UiKit's 44px minimum plus a hair
local CLOSE_WIDTH = 88 -- the panel's own close button, in its top-right corner

--[[
	Under this many pixels of height the Mixdex figure folds into the Goop/sec
	line instead of taking a row of its own. Roblox reports points, not pixels,
	on phones, so a landscape handset really is around 390 tall — and every row
	the readout keeps is a row the open panel does not get.
]]
local SHORT_SCREEN = 480

local SCRIM_TRANSPARENCY = 0.45 -- dark enough to separate a panel, light enough to keep Blendburg visible
local EXACT_SECONDS = 3 -- how long a tap holds the Goop figure at full precision
local SLOW_INTERVAL = 0.25 -- repaint cadence for the daily countdown
local PULSE_SPEED = 5 -- radians/sec of the tutorial highlight breath

--[[
	What counts as "income arrived" rather than "the tick ticked". A second of
	accrual must never pop the label or the HUD would twitch once a second, so
	the threshold is a multiple of the player's own rate with a floor for the
	player whose rate is zero and who just redeemed a code.
]]
local JUMP_SECONDS = 4
local JUMP_FLOOR = 25

local PLATE_DISTANCE = 140 -- studs; nameplates past this are not drawn
local PLATE_DISTANCE_LOW_FX = 60 -- what the lowFx setting cuts it to
local PLATE_HEIGHT = 2.8 -- studs above the head

local HUD_ORDER = 10 -- the HUD draws over the panels, never under them
local PANEL_ORDER = 8

-- Cluster button name -> the panel name it opens. The four that are not mine
-- are registered by their own controllers; see the header.
local CLUSTER: { { key: string, label: string } } = {
	{ key = "Mixer", label = "MIXER" },
	{ key = "Den", label = "DEN" },
	{ key = "Shop", label = "SHOP" },
	{ key = "Mixdex", label = "MIXDEX" },
	{ key = "Codes", label = "CODES" },
	{ key = "Settings", label = "SETTINGS" },
}

-- The server owns the destination list (PlayerService); these names must be
-- in it or the teleport is silently refused. It also refuses every one of
-- them while the player is carrying a stolen Mixling (DECISIONS D9) — the
-- client fires and lets the Notify answer.
local DESTINATIONS: { { key: string, label: string } } = {
	{ key = "Mixer", label = "THE MIXER" },
	{ key = "Den", label = "MY DEN" },
	{ key = "CritterPen", label = "CRITTER PEN" },
	{ key = "StuffShack", label = "STUFF SHACK" },
	{ key = "Mixdex", label = "MIXDEX STAND" },
}

--[[
	Panel name -> the controller that owns that screen itself. A delegate is
	opened through its own open(), never parented into the stage, because its
	ScreenGui has a DisplayOrder this host does not control.
]]
local DELEGATES: { [string]: string } = {
	Mixer = "MixerUIController",
}

local SETTING_ROWS: { { key: string, label: string, hint: string } } = {
	-- GDD §18's open question. The default is on; this stores the answer and
	-- the services that act on it read the profile, never the client.
	{ key = "friendlyFire", label = "Let friends steal from me", hint = "Friends can walk into your Den" },
	{ key = "music", label = "Music", hint = "The Blendburg bed" },
	{ key = "sfx", label = "Sound effects", hint = "Rolls, bonks, Mixling voices" },
	{ key = "lowFx", label = "Low effects", hint = "Fewer particles, shorter nameplates" },
}

-- ── State ────────────────────────────────────────────────────────────────

local sound: any = nil
local mixer: any = nil
local delegates: { [string]: any } = {}

local scrim: Frame? = nil
local stage: Frame? = nil
local topBlock: Frame? = nil
local chipRow: Frame? = nil
local goopButton: TextButton? = nil
local rateLabel: TextLabel? = nil
local dexLabel: TextLabel? = nil
local dailyPill: TextButton? = nil
local travelChip: TextButton? = nil
local cluster: Frame? = nil
local clusterGrid: UIGridLayout? = nil
local closeButton: TextButton? = nil

local clusterStrokes: { [string]: UIStroke } = {}
local highlighted: { [string]: boolean } = {}

local panels: { [string]: Frame } = {}
local openName: string? = nil

-- Panels this file owns, populated in start(). Kept apart from `panels` so a
-- redraw never has to ask whether a frame is mine.
local codesUsedLabel: TextLabel? = nil
local settingToggles: { [string]: TextButton } = {}
local dailyCells: { [number]: Frame } = {}
local dailyStreakLabel: TextLabel? = nil
local dailyClaimButton: TextButton? = nil

local plates: { [Player]: { gui: BillboardGui, name: TextLabel, rate: TextLabel } } = {}
local denRates: { [number]: number } = {}
local playerGui: Instance? = nil

local lastViewport = Vector2.zero
local exactUntil = 0
local hoveringGoop = false
local lastGoopText = ""
local lastGoop = 0
local lastSlowAt = 0

-- ── Small helpers ────────────────────────────────────────────────────────

local function viewportSize(): Vector2
	local camera = Workspace.CurrentCamera
	if not camera then
		return Vector2.new(1280, 720)
	end
	return camera.ViewportSize
end

--[[
	Raises the ceiling on the UITextSizeConstraint UiKit already attached, for
	a label whose size is set after construction.

	This helper predates the fix to UiKit.applyCommon: passing `MaxTextSize` in
	the prop table used to throw, because applyCommon assigned every key it did
	not recognise straight onto the Instance. It no longer does — the prop works
	— but reaching for the constraint is still the only way to change a ceiling
	AFTER the object exists, which is what every call site here is doing.
]]
local function textCeiling(gui: GuiObject, ceiling: number)
	local constraint = gui:FindFirstChildOfClass("UITextSizeConstraint")
	if constraint then
		constraint.MaxTextSize = ceiling
	end
end

--[[
	Sizes here are expressed as a fraction of the parent rather than in raw
	pixels, computed from a pixel target by layout(). That keeps one layout
	readable from a 640x360 phone to a desktop, and it is what lets the HUD
	rescale on a viewport change without rebuilding.
]]
local function fraction(pixels: number, total: number): number
	if total <= 0 then
		return 0
	end
	return pixels / total
end

local function lowFx(): boolean
	return ClientState.get().settings.lowFx == true
end

local function pop(gui: GuiObject, strength: number?)
	if lowFx() then
		return
	end
	UiKit.pop(gui, strength)
end

local function click()
	if sound then
		sound.play("Click")
	end
end

-- os.time() stamps on the wire (Net.luau) are compared against os.time().
local function untilText(seconds: number): string
	if seconds <= 0 then
		return "READY"
	end
	if seconds >= 3600 then
		return ("%dh %dm"):format(seconds // 3600, (seconds % 3600) // 60)
	end
	return Util.clock(seconds)
end

local function dailyState(): { [string]: any }?
	local state = ClientState.get().dailyState
	return if type(state) == "table" then state else nil
end

local function keysInclude(keys: { string }, wanted: { [string]: boolean }): boolean
	for _, key in keys do
		if wanted[key] then
			return true
		end
	end
	return false
end

-- ── Layout ───────────────────────────────────────────────────────────────
-- One function owns every number that depends on the screen, so a rotation,
-- a window resize and a phone are the same code path.

local topBandPixels = 140
local bottomBandPixels = 120
local bottomClearPixels = 64
local clusterSize = Vector2.new(238, 180)
local goopFraction = 0.5
local dexFolded = false
local stageSize = UDim2.fromScale(1, 1)

--[[
	The cluster and the CLOSE button share one slot — the same thumb rest —
	and slide past each other through the right edge. A player who opened a
	panel closes it without moving their hand, and there is exactly one close
	gesture in the game no matter whose panel is on screen. The top block does
	not move: the balance stays readable while a panel is up, and TRAVEL and
	DAILY stay live so one tap swaps panels instead of two.
]]
local function applyChrome(instant: boolean)
	local clusterFrame = cluster
	if not clusterFrame then
		return
	end

	local open = openName ~= nil
	local closeBtn = closeButton
	if closeBtn then
		closeBtn.Visible = open
	end

	-- The cluster leaves through the right edge while a panel is up: it is
	-- taller than the strip below the stage, so it would otherwise sit on top
	-- of whatever panel the player just opened.
	local target = UDim2.new(1, if open then clusterSize.X + MARGIN * 2 else -MARGIN, 1, -bottomClearPixels)
	if instant then
		clusterFrame.Position = target
		return
	end
	UiKit.tween(clusterFrame, { Position = target }, 0.18)
end

local function layout()
	local viewport = viewportSize()
	lastViewport = viewport
	local small = UiKit.isSmallScreen()
	local inset = UiKit.topInset()

	local short = viewport.Y < SHORT_SCREEN
	local goopHeight = if small then 44 else 58
	local rateHeight = if small then 20 else 26
	local dexHeight = if short then 0 else (if small then 18 else 22)
	local rows = if short then 2 else 3
	local blockHeight = goopHeight + rateHeight + dexHeight + CHIP_HEIGHT + GAP * rows

	--[[
		TRAVEL and DAILY ride under the readout rather than in the two top
		corners. A corner badge collides with a centred balance the moment the
		screen is a portrait phone, and the balance is the one thing on this
		HUD that must never be squeezed to make room for a shortcut.
	]]
	local chipWidth = if small then 92 else 112
	local pillWidth = if small then 150 else 184
	local blockWidth = math.min(viewport.X - MARGIN * 2, math.max(
		math.min(viewport.X * 0.62, if small then 320 else 420),
		chipWidth + pillWidth + GAP
	))

	local cellWidth = if small then 92 else 116
	local cellHeight = if small then 46 else 56
	clusterSize = Vector2.new(
		CLUSTER_COLUMNS * cellWidth + (CLUSTER_COLUMNS - 1) * GAP,
		CLUSTER_ROWS * cellHeight + (CLUSTER_ROWS - 1) * GAP
	)

	-- The clearance is the strip the panel stage gives back to Roblox's own
	-- touch controls, and the bottom band is that plus a margin. Both bands
	-- are clamped so a 640x360 window is cramped rather than unusable.
	local clearance = math.min(if UiKit.isTouch() then TOUCH_CONTROL_CLEAR else MARGIN, viewport.Y * 0.18)
	topBandPixels = math.floor(math.min(inset + blockHeight + MARGIN, viewport.Y * TOP_BAND_MAX))
	bottomBandPixels = math.floor(math.min(clearance + MARGIN, viewport.Y * BOTTOM_BAND_MAX))
	bottomClearPixels = math.max(MARGIN, bottomBandPixels - MARGIN)

	--[[
		When that clamp bites, the text rows give up height and the chip row
		does not: it is a touch target, and UiKit's 44px minimum is not mine to
		negotiate away. A 640x360 window then keeps a legible balance and a
		usable panel instead of a perfect balance and no panel.
	]]
	local textHeight = goopHeight + rateHeight + dexHeight
	local available = topBandPixels - inset - MARGIN - CHIP_HEIGHT - GAP * rows
	if available < textHeight then
		local shrink = math.max(MIN_BLOCK_SHRINK, available / textHeight)
		goopHeight = math.floor(goopHeight * shrink)
		rateHeight = math.floor(rateHeight * shrink)
		dexHeight = math.floor(dexHeight * shrink)
		blockHeight = goopHeight + rateHeight + dexHeight + CHIP_HEIGHT + GAP * rows
	end
	dexFolded = short

	local block = topBlock
	if block then
		block.Position = UDim2.new(0.5, 0, 0, inset)
		block.Size = UDim2.fromScale(fraction(blockWidth, viewport.X), fraction(blockHeight, viewport.Y))
	end

	goopFraction = fraction(goopHeight, blockHeight)
	local goop = goopButton
	if goop then
		goop.Size = UDim2.fromScale(1, goopFraction)
		textCeiling(goop, goopHeight)
	end
	local rate = rateLabel
	if rate then
		rate.Size = UDim2.fromScale(1, fraction(rateHeight, blockHeight))
		textCeiling(rate, rateHeight)
	end
	local dex = dexLabel
	if dex then
		dex.Visible = not short
		dex.Size = UDim2.fromScale(1, fraction(dexHeight, blockHeight))
		if dexHeight > 0 then
			textCeiling(dex, dexHeight)
		end
	end

	local row = chipRow
	if row then
		row.Size = UDim2.fromScale(1, fraction(CHIP_HEIGHT, blockHeight))
	end
	local chip = travelChip
	if chip then
		chip.Size = UDim2.fromOffset(chipWidth, CHIP_HEIGHT)
	end
	local pill = dailyPill
	if pill then
		pill.Size = UDim2.fromOffset(pillWidth, CHIP_HEIGHT)
	end

	local clusterFrame = cluster
	local grid = clusterGrid
	if clusterFrame and grid then
		clusterFrame.Size = UDim2.fromOffset(clusterSize.X, clusterSize.Y)
		grid.CellSize = UDim2.fromOffset(cellWidth, cellHeight)
	end

	stageSize = UDim2.new(1, -math.max(MARGIN * 2, viewport.X - 900), 1, -(topBandPixels + bottomBandPixels))
	local stageFrame = stage
	if stageFrame then
		stageFrame.Position = UDim2.new(0.5, 0, 0, topBandPixels)
		stageFrame.Size = stageSize
	end

	applyChrome(true)
end

-- ── The panel host ───────────────────────────────────────────────────────

-- Fades rather than snaps, and only stops rendering once it is invisible —
-- checked against openName again on the way out, so a panel opened during the
-- fade does not lose its backdrop.
local function setScrim(visible: boolean)
	local frame = scrim
	if not frame then
		return
	end
	frame.Visible = true
	UiKit.tween(frame, { BackgroundTransparency = if visible then SCRIM_TRANSPARENCY else 1 }, 0.16)
	if visible then
		return
	end
	task.delay(0.16, function()
		if openName == nil and frame.Parent then
			frame.Visible = false
		end
	end)
end

function HudController.isAnyPanelOpen(): boolean
	return openName ~= nil
end

--[[
	Takes ownership of a frame another controller built: parents it into the
	stage and hides it. The frame keeps whatever size it gave itself — a frame
	left at UiKit's default fills the stage, and one that chose its own size is
	centred rather than pinned to a corner it never asked for.
]]
function HudController.registerPanel(name: string, frame: Frame)
	local stageFrame = stage
	if not stageFrame then
		warn(("[Hud] registerPanel(%q) before the host existed"):format(name))
		return
	end
	local existing = panels[name]
	if existing and existing ~= frame then
		existing:Destroy()
	end

	frame.Visible = false
	if frame.Size ~= UDim2.fromScale(1, 1) and frame.Position == UDim2.new() then
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.fromScale(0.5, 0.5)
	end
	frame.Parent = stageFrame
	panels[name] = frame
end

function HudController.closeAll()
	local current = openName
	if not current then
		return
	end
	local frame = panels[current]
	openName = nil
	if frame then
		frame.Visible = false
	end
	setScrim(false)
	applyChrome(false)
end

function HudController.closePanel(name: string)
	if openName ~= name then
		return
	end
	HudController.closeAll()
end

--[[
	One open at a time, enforced here rather than trusted to callers. Returns
	false for a name nobody registered, which is what a cluster button gets
	during boot and what a typo gets forever.
]]
function HudController.openPanel(name: string): boolean
	-- The roll is never interrupted (GDD §2, pillar 1; ARCHITECTURE §7.5).
	if mixer and mixer.isRevealing and mixer.isRevealing() == true then
		return false
	end

	local frame = panels[name]
	if not frame then
		local delegate = delegates[name]
		if not delegate or type(delegate.open) ~= "function" then
			warn(("[Hud] no panel registered for %q"):format(name))
			return false
		end
		HudController.closeAll() -- one screen at a time still holds
		delegate.open()
		return true
	end
	if openName == name then
		return true
	end

	local previous = openName
	if previous then
		local old = panels[previous]
		if old then
			old.Visible = false
		end
	end

	openName = name
	frame.Visible = true
	setScrim(true)
	applyChrome(false)

	local stageFrame = stage
	if stageFrame and not previous then
		stageFrame.Size = stageSize -- a pop reads the current size as its base
		pop(stageFrame, 0.06)
	end
	return true
end

function HudController.setButtonHighlight(name: string, on: boolean)
	local stroke = clusterStrokes[name]
	if not stroke then
		return
	end
	if not on then
		highlighted[name] = nil
		stroke.Transparency = 1
		return
	end
	-- The stroke is the whole effect: a cluster button's size belongs to the
	-- UIGridLayout, so resizing it — by a pop or otherwise — just fights the
	-- layout for a frame and snaps back.
	highlighted[name] = true
	stroke.Transparency = 0
end

-- ── Panels this file owns ────────────────────────────────────────────────
-- Codes and Settings are both a screenful of nothing; a controller each would
-- be two more files that only know how to fire one remote. Daily and Travel
-- are here for the same reason, and because both are HUD affordances first:
-- the badge and the shortcut chip live in the cluster's world, not in a
-- system's.

local function panelShell(title: string): (Frame, ScrollingFrame)
	local frame = UiKit.frame({
		BackgroundColor3 = UiKit.PALETTE.panel,
		Corner = 16,
		Stroke = UiKit.PALETTE.stroke,
	})

	-- Narrower than the panel by exactly the close button's corner, so a long
	-- title can never run underneath it.
	local heading = UiKit.label({
		Text = title,
		TextColor3 = UiKit.PALETTE.accent,
		Size = UDim2.new(1, -(MARGIN * 2 + CLOSE_WIDTH + GAP), 0, 34),
		Position = UDim2.fromOffset(MARGIN, MARGIN),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
	textCeiling(heading, 30)

	local body = UiKit.scroll({
		Position = UDim2.fromOffset(MARGIN, MARGIN + 40),
		Size = UDim2.new(1, -MARGIN * 2, 1, -(MARGIN * 2 + 40)),
		Parent = frame,
	})
	UiKit.list(body, { Padding = UDim.new(0, GAP), HorizontalAlignment = Enum.HorizontalAlignment.Center })

	return frame, body
end

local function buildCodesPanel(): Frame
	local frame, body = panelShell("CODES")

	local blurb = UiKit.label({
		Text = "Codes come from the weekly drop. Type one in and hit REDEEM.",
		TextColor3 = UiKit.PALETTE.muted,
		Font = UiKit.FONT_BODY,
		Size = UDim2.new(1, 0, 0, 34),
		TextWrapped = true,
		LayoutOrder = 1,
		Parent = body,
	})
	textCeiling(blurb, 15)

	-- UiKit has no TextBox primitive (it is not a button, so nothing about the
	-- touch minimum is at stake); it is built here to the same 48px height the
	-- kit's buttons get, and styled from the palette so it matches them.
	local box = Instance.new("TextBox")
	box.Size = UDim2.new(1, 0, 0, 48)
	box.BackgroundColor3 = UiKit.PALETTE.ink
	box.BorderSizePixel = 0
	box.Font = UiKit.FONT
	box.TextColor3 = UiKit.PALETTE.text
	box.PlaceholderText = "ENTER CODE"
	box.PlaceholderColor3 = UiKit.PALETTE.muted
	box.Text = ""
	box.TextScaled = true
	box.ClearTextOnFocus = false
	box.LayoutOrder = 2
	box.Parent = body
	local boxCorner = Instance.new("UICorner")
	boxCorner.CornerRadius = UDim.new(0, 10)
	boxCorner.Parent = box
	local boxCeiling = Instance.new("UITextSizeConstraint")
	boxCeiling.MaxTextSize = 26
	boxCeiling.MinTextSize = 8
	boxCeiling.Parent = box

	--[[
		Fire and forget. CodesService answers every outcome — unknown, already
		spent, paid — with a Notify toast, so reporting anything here would be
		the client inventing a result it does not have.
	]]
	local function redeem()
		local typed = box.Text
		local trimmed = typed:match("^%s*(.-)%s*$")
		if not trimmed or trimmed == "" then
			return
		end
		click()
		Net.event("RedeemCode"):FireServer(trimmed)
		box.Text = ""
	end

	local redeemButton = UiKit.button({
		Text = "REDEEM",
		Size = UDim2.new(1, 0, 0, 52),
		BackgroundColor3 = UiKit.PALETTE.goop,
		Corner = 12,
		LayoutOrder = 3,
		Parent = body,
	}, redeem)
	textCeiling(redeemButton, 26)

	-- A hardware keyboard should not have to reach for the button.
	box.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed then
			redeem()
		end
	end)

	local used = UiKit.label({
		Text = "",
		TextColor3 = UiKit.PALETTE.muted,
		Font = UiKit.FONT_BODY,
		Size = UDim2.new(1, 0, 0, 40),
		TextWrapped = true,
		LayoutOrder = 4,
		Parent = body,
	})
	textCeiling(used, 15)
	codesUsedLabel = used

	return frame
end

local function buildSettingsPanel(): Frame
	local frame, body = panelShell("SETTINGS")

	for index, row in SETTING_ROWS do
		local holder = UiKit.frame({
			BackgroundColor3 = UiKit.PALETTE.panelSoft,
			Size = UDim2.new(1, 0, 0, 58),
			Corner = 12,
			LayoutOrder = index,
			Parent = body,
		})

		local name = UiKit.label({
			Text = row.label,
			Size = UDim2.new(1, -128, 0, 26),
			Position = UDim2.fromOffset(MARGIN, 6),
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = holder,
		})
		textCeiling(name, 20)

		local hint = UiKit.label({
			Text = row.hint,
			TextColor3 = UiKit.PALETTE.muted,
			Font = UiKit.FONT_BODY,
			Size = UDim2.new(1, -128, 0, 20),
			Position = UDim2.fromOffset(MARGIN, 32),
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = holder,
		})
		textCeiling(hint, 14)

		--[[
			The tap sends an intent and nothing else. The toggle's text and
			colour are painted by renderSettings() from the profile, so a
			refused or dropped SetSetting leaves the switch where it was
			instead of lying about the server's state (GDD §11.3).
		]]
		local key = row.key
		local toggle = UiKit.button({
			Text = "",
			Size = UDim2.fromOffset(100, 44),
			Position = UDim2.new(1, -MARGIN, 0.5, 0),
			AnchorPoint = Vector2.new(1, 0.5),
			Corner = 22,
			Parent = holder,
		}, function()
			local settings = ClientState.get().settings
			click()
			Net.event("SetSetting"):FireServer(key, settings[key] ~= true)
		end)
		textCeiling(toggle, 20)
		settingToggles[key] = toggle
	end

	return frame
end

local function buildDailyPanel(): Frame
	local frame, body = panelShell("DAILY REWARD")

	local streak = UiKit.label({
		Text = "",
		TextColor3 = UiKit.PALETTE.muted,
		Font = UiKit.FONT_BODY,
		Size = UDim2.new(1, 0, 0, 24),
		LayoutOrder = 1,
		Parent = body,
	})
	textCeiling(streak, 16)
	dailyStreakLabel = streak

	local track = UiKit.frame({
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 150),
		LayoutOrder = 2,
		Parent = body,
	})
	local grid = UiKit.grid(track, UDim2.fromOffset(84, 68), UDim2.fromOffset(GAP, GAP))
	grid.FillDirectionMaxCells = 4

	-- The track is Constants.DAILY_REWARD verbatim (GDD §8.8); the amount a
	-- claim actually pays arrives on dailyState, VIP multiplier included.
	for day, amount in Constants.DAILY_REWARD do
		local cell = UiKit.frame({
			BackgroundColor3 = UiKit.PALETTE.panelSoft,
			Corner = 10,
			LayoutOrder = day,
			Parent = track,
		})

		local dayLabel = UiKit.label({
			Text = ("DAY %d"):format(day),
			TextColor3 = UiKit.PALETTE.muted,
			Size = UDim2.new(1, 0, 0, 20),
			Position = UDim2.fromOffset(0, 6),
			Parent = cell,
		})
		textCeiling(dayLabel, 14)

		local value = UiKit.label({
			Text = Util.abbreviate(amount),
			TextColor3 = UiKit.PALETTE.goop,
			Size = UDim2.new(1, 0, 0, 32),
			Position = UDim2.fromOffset(0, 28),
			Parent = cell,
		})
		textCeiling(value, 24)

		dailyCells[day] = cell
	end

	--[[
		Always fires. Whether the claim is open is the server's call and it
		answers a too-early tap with a Notify carrying the exact wait, so the
		button styles itself from dailyState.ready and refuses nothing.
	]]
	local claim = UiKit.button({
		Text = "CLAIM",
		Size = UDim2.new(1, 0, 0, 56),
		BackgroundColor3 = UiKit.PALETTE.goop,
		Corner = 12,
		LayoutOrder = 3,
		Parent = body,
	}, function()
		click()
		Net.event("ClaimDaily"):FireServer()
	end)
	textCeiling(claim, 28)
	dailyClaimButton = claim

	return frame
end

local function buildTravelPanel(): Frame
	local frame, body = panelShell("TRAVEL")

	local blurb = UiKit.label({
		Text = "Shortcuts around Blendburg. None of them work while you are carrying someone else's Mixling — run that one home yourself.",
		TextColor3 = UiKit.PALETTE.muted,
		Font = UiKit.FONT_BODY,
		Size = UDim2.new(1, 0, 0, 36),
		TextWrapped = true,
		LayoutOrder = 1,
		Parent = body,
	})
	textCeiling(blurb, 15)

	for index, destination in DESTINATIONS do
		local key = destination.key
		local button = UiKit.button({
			Text = destination.label,
			Size = UDim2.new(1, 0, 0, 52),
			BackgroundColor3 = UiKit.PALETTE.panelSoft,
			TextColor3 = UiKit.PALETTE.text,
			Corner = 12,
			LayoutOrder = index + 1,
			Parent = body,
		}, function()
			click()
			Net.event("RequestTeleport"):FireServer(key)
			-- Closing regardless: if the server refuses, the Notify lands on a
			-- HUD the player can see rather than behind a panel.
			HudController.closeAll()
		end)
		textCeiling(button, 22)
	end

	return frame
end

-- ── Rendering server truth ───────────────────────────────────────────────

local function renderGoop()
	local button = goopButton
	if not button then
		return
	end
	local goop = ClientState.interpolatedGoop()
	local exact = hoveringGoop or os.clock() < exactUntil
	local text = if exact then Util.comma(goop) else Util.abbreviate(goop)
	if text ~= lastGoopText then
		lastGoopText = text
		button.Text = text
	end
end

local function renderRates()
	local view = ClientState.get()
	local total = view.mixdexTotal
	local percent = if total > 0 then math.floor(view.mixdexDiscovered / total * 100) else 0

	-- On a short screen the Mixdex figure has no row of its own, so it rides
	-- on the end of the rate line rather than disappearing (GDD §10 wants it
	-- on the HUD, not in a menu).
	local rate = rateLabel
	if rate then
		local text = ("%s Goop/sec"):format(Util.abbreviate(view.goopPerSec))
		rate.Text = if dexFolded then ("%s  ·  MIXDEX %d%%"):format(text, percent) else text
	end

	local dex = dexLabel
	if dex then
		dex.Text = ("MIXDEX %d%%  ·  %d/%d"):format(percent, view.mixdexDiscovered, total)
	end
end

local function renderDaily()
	local state = dailyState()
	local pill = dailyPill
	local ready = state ~= nil and state.ready == true

	if pill then
		if ready then
			pill.Text = "DAILY READY!"
			pill.BackgroundColor3 = UiKit.PALETTE.goop
			pill.TextColor3 = UiKit.PALETTE.ink
		elseif state then
			pill.Text = ("DAILY  %s"):format(untilText(math.max(0, (state.nextAt or 0) - os.time())))
			pill.BackgroundColor3 = UiKit.PALETTE.panelSoft
			pill.TextColor3 = UiKit.PALETTE.muted
		else
			pill.Text = "DAILY"
			pill.BackgroundColor3 = UiKit.PALETTE.panelSoft
			pill.TextColor3 = UiKit.PALETTE.muted
		end
	end

	local streak = dailyStreakLabel
	if streak then
		if state then
			local text = ("Day %d of %d  ·  streak %d"):format(state.day or 1, state.days or 0, state.streak or 0)
			if (state.multiplier or 1) > 1 then
				text ..= ("  ·  VIP x%s"):format(tostring(Util.round(state.multiplier, 2)))
			end
			streak.Text = text
		else
			streak.Text = "Loading your streak…"
		end
	end

	local day = if state then state.day else 0
	for index, cell in dailyCells do
		if state and index < day then
			cell.BackgroundColor3 = UiKit.PALETTE.ink -- already banked this streak
		elseif state and index == day then
			cell.BackgroundColor3 = if ready then UiKit.PALETTE.accent else UiKit.PALETTE.stroke
		else
			cell.BackgroundColor3 = UiKit.PALETTE.panelSoft
		end
	end

	local claim = dailyClaimButton
	if claim then
		if not state then
			claim.Text = "CLAIM"
			claim.BackgroundColor3 = UiKit.PALETTE.panelSoft
		elseif ready then
			claim.Text = ("CLAIM %s GOOP"):format(Util.abbreviate(state.amount or 0))
			claim.BackgroundColor3 = UiKit.PALETTE.goop
		else
			local remaining = math.max(0, (state.nextAt or 0) - os.time())
			claim.Text = ("NEXT IN %s"):format(untilText(remaining))
			claim.BackgroundColor3 = UiKit.PALETTE.panelSoft
		end
	end
end

local function renderSettings()
	local settings = ClientState.get().settings
	for key, toggle in settingToggles do
		local on = settings[key] == true
		toggle.Text = if on then "ON" else "OFF"
		toggle.BackgroundColor3 = if on then UiKit.PALETTE.ok else UiKit.PALETTE.panel
		toggle.TextColor3 = if on then UiKit.PALETTE.ink else UiKit.PALETTE.muted
	end
end

local function renderCodes()
	local label = codesUsedLabel
	if not label then
		return
	end
	local codes = ClientState.get().codes
	if type(codes) ~= "table" then
		return
	end
	local used: { string } = {}
	for code, redeemed in codes :: { [string]: boolean } do
		if redeemed then
			table.insert(used, code)
		end
	end
	table.sort(used)
	label.Text = if #used == 0
		then "You have not used a code yet."
		else ("Already used: %s"):format(table.concat(used, ", "))
end

--[[
	Income that arrives in a lump — a code, a daily, a sale, a banked steal —
	must feel like it landed. A second of ordinary accrual must not, so the
	threshold is the player's own rate times JUMP_SECONDS.
]]
local function popOnJump()
	local goop = ClientState.get().goop
	local delta = goop - lastGoop
	lastGoop = goop
	if delta < math.max(ClientState.get().goopPerSec * JUMP_SECONDS, JUMP_FLOOR) then
		return
	end
	local button = goopButton
	if not button then
		return
	end
	button.Size = UDim2.fromScale(1, goopFraction)
	pop(button, 0.18)
end

-- ── Overhead nameplates (GDD §10) ────────────────────────────────────────

local function plateDistance(): number
	return if lowFx() then PLATE_DISTANCE_LOW_FX else PLATE_DISTANCE
end

local function refreshPlate(player: Player)
	local plate = plates[player]
	if not plate then
		return
	end
	local rate = denRates[player.UserId]
	plate.name.Text = player.DisplayName
	plate.rate.Text = if rate then ("%s Goop/sec"):format(Util.abbreviate(rate)) else "no Den yet"
	plate.rate.TextColor3 = if rate and rate > 0 then UiKit.PALETTE.goop else UiKit.PALETTE.muted
	plate.gui.MaxDistance = plateDistance()
end

local function attachPlate(player: Player, head: BasePart)
	local existing = plates[player]
	if existing then
		existing.gui.Adornee = head
		refreshPlate(player)
		return
	end

	local parent = playerGui
	if not parent then
		return
	end

	-- Not a ScreenGui: a BillboardGui lives in the world, and UiKit has no
	-- primitive for one. Its two labels are still built from the kit so a
	-- nameplate reads like the rest of the game.
	local gui = Instance.new("BillboardGui")
	gui.Name = ("Nameplate_%d"):format(player.UserId)
	gui.Adornee = head
	gui.Size = UDim2.fromOffset(190, 46)
	gui.StudsOffsetWorldSpace = Vector3.new(0, PLATE_HEIGHT, 0)
	gui.MaxDistance = plateDistance()
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.Parent = parent

	-- World-space text needs its own contrast: Blendburg's sky is bright and
	-- a Den's walls are not, so both lines carry a stroke rather than relying
	-- on whatever happens to be behind the player.
	local name = UiKit.label({
		Text = player.DisplayName,
		Size = UDim2.new(1, 0, 0, 24),
		TextStrokeTransparency = 0.35,
		TextStrokeColor3 = UiKit.PALETTE.ink,
		Parent = gui,
	})
	textCeiling(name, 20)

	local rate = UiKit.label({
		Text = "",
		TextColor3 = UiKit.PALETTE.goop,
		Size = UDim2.new(1, 0, 0, 20),
		Position = UDim2.fromOffset(0, 24),
		TextStrokeTransparency = 0.35,
		TextStrokeColor3 = UiKit.PALETTE.ink,
		Parent = gui,
	})
	textCeiling(rate, 16)

	plates[player] = { gui = gui, name = name, rate = rate }
	refreshPlate(player)
end

local function watchCharacter(player: Player, character: Model)
	task.spawn(function()
		local head = character:WaitForChild("Head", 10)
		if not head or not head:IsA("BasePart") or player.Character ~= character then
			return
		end
		attachPlate(player, head)
	end)
end

local function dropPlate(player: Player)
	local plate = plates[player]
	if not plate then
		return
	end
	plates[player] = nil
	plate.gui:Destroy()
end

local function watchPlayer(player: Player)
	if player == LocalPlayer then
		return -- the HUD already shows this player their own number
	end
	player.CharacterAdded:Connect(function(character: Model)
		watchCharacter(player, character)
	end)
	player.CharacterRemoving:Connect(function()
		dropPlate(player)
	end)
	local character = player.Character
	if character then
		watchCharacter(player, character)
	end
end

-- ── Construction ─────────────────────────────────────────────────────────

local function buildPanelHost()
	local gui = UiKit.screen("MixPanels", PANEL_ORDER)

	-- A Frame, deliberately not a button: an inert scrim cannot sink the touch
	-- that was aimed at the thumbstick underneath it.
	local dim = UiKit.frame({
		BackgroundColor3 = UiKit.PALETTE.ink,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = gui,
	})
	scrim = dim

	local stageFrame = UiKit.frame({
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})
	stage = stageFrame

	--[[
		A child of the stage, not of the panel: it is the host's affordance and
		it must survive whatever a panel does to its own contents. UiKit.screen
		sets ZIndexBehavior.Sibling, so one ZIndex above its sibling panels
		puts it above their whole subtree without any panel cooperating.
	]]
	local close = UiKit.button({
		Text = "CLOSE",
		Size = UDim2.fromOffset(CLOSE_WIDTH, CHIP_HEIGHT),
		Position = UDim2.new(1, -MARGIN, 0, MARGIN),
		AnchorPoint = Vector2.new(1, 0),
		BackgroundColor3 = UiKit.PALETTE.danger,
		TextColor3 = UiKit.PALETTE.text,
		Corner = 12,
		ZIndex = 20,
		Visible = false,
		Parent = stageFrame,
	}, function()
		click()
		HudController.closeAll()
	end)
	textCeiling(close, 22)
	closeButton = close
end

local function buildTopBlock(gui: ScreenGui)
	local block = UiKit.frame({
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = gui,
	})
	UiKit.list(block, { Padding = UDim.new(0, GAP) })
	topBlock = block

	--[[
		The balance is a button so the exact figure is one tap away on a phone
		(GDD §10 wants the abbreviation; §3 forbids needing a mouse for the
		rest). Hover is the desktop bonus, never the only way in.
	]]
	local goop = UiKit.button({
		Text = "0",
		BackgroundTransparency = 1,
		TextColor3 = UiKit.PALETTE.goop,
		Size = UDim2.fromScale(1, 0.5),
		LayoutOrder = 1,
		Parent = block,
	}, function()
		exactUntil = os.clock() + EXACT_SECONDS
		renderGoop()
	end)
	goop.MouseEnter:Connect(function()
		hoveringGoop = true
	end)
	goop.MouseLeave:Connect(function()
		hoveringGoop = false
	end)
	goopButton = goop

	rateLabel = UiKit.label({
		Text = "0 Goop/sec",
		TextColor3 = UiKit.PALETTE.text,
		Size = UDim2.fromScale(1, 0.25),
		LayoutOrder = 2,
		Parent = block,
	})

	dexLabel = UiKit.label({
		Text = "MIXDEX 0%",
		TextColor3 = UiKit.PALETTE.muted,
		Font = UiKit.FONT_BODY,
		Size = UDim2.fromScale(1, 0.25),
		LayoutOrder = 3,
		Parent = block,
	})

	-- Holds TRAVEL and DAILY, centred under the readout; buildChips fills it.
	local row = UiKit.frame({
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0.25),
		LayoutOrder = 4,
		Parent = block,
	})
	UiKit.list(row, {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, GAP),
		VerticalAlignment = Enum.VerticalAlignment.Center,
	})
	chipRow = row
end

local function buildCluster(gui: ScreenGui)
	local frame = UiKit.frame({
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 1),
		Parent = gui,
	})
	local grid = UiKit.grid(frame, UDim2.fromOffset(116, 56), UDim2.fromOffset(GAP, GAP))
	grid.FillDirectionMaxCells = CLUSTER_COLUMNS
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Right
	cluster = frame
	clusterGrid = grid

	for index, entry in CLUSTER do
		local key = entry.key
		local button = UiKit.button({
			Text = entry.label,
			BackgroundColor3 = UiKit.PALETTE.panelSoft,
			TextColor3 = UiKit.PALETTE.text,
			TextWrapped = true,
			Corner = 12,
			Stroke = UiKit.PALETTE.accent,
			LayoutOrder = index,
			Parent = frame,
		}, function()
			click()
			-- A panel whose controller has not registered yet simply does not
			-- open, and a tap during a reveal is swallowed; nothing here
			-- fakes a screen or interrupts one.
			HudController.openPanel(key)
		end)
		textCeiling(button, 18)

		-- UiKit gives every stroked button a UIStroke; borrowing it is what
		-- makes setButtonHighlight one property write instead of a second
		-- instance per button that is invisible 99% of the time.
		local stroke = button:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Transparency = 1
			clusterStrokes[key] = stroke
		end
	end
end

local function buildChips(row: Frame)
	local chip = UiKit.button({
		Text = "TRAVEL",
		BackgroundColor3 = UiKit.PALETTE.panelSoft,
		TextColor3 = UiKit.PALETTE.text,
		Corner = 12,
		LayoutOrder = 1,
		Parent = row,
	}, function()
		click()
		HudController.openPanel("Travel")
	end)
	textCeiling(chip, 18)
	travelChip = chip

	local pill = UiKit.button({
		Text = "DAILY",
		BackgroundColor3 = UiKit.PALETTE.panelSoft,
		TextColor3 = UiKit.PALETTE.muted,
		Corner = 22,
		LayoutOrder = 2,
		Parent = row,
	}, function()
		click()
		HudController.openPanel("Daily")
	end)
	textCeiling(pill, 18)
	dailyPill = pill
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

function HudController.init(controllers: { [string]: any })
	sound = controllers.SoundController
	mixer = controllers.MixerUIController
	for panelName, controllerName in DELEGATES do
		delegates[panelName] = controllers[controllerName]
	end
end

function HudController.start()
	playerGui = LocalPlayer:WaitForChild("PlayerGui")

	buildPanelHost()

	local gui = UiKit.screen("MixHud", HUD_ORDER)
	buildTopBlock(gui)
	buildCluster(gui)

	local row = chipRow
	if row then
		buildChips(row)
	end

	HudController.registerPanel("Codes", buildCodesPanel())
	HudController.registerPanel("Settings", buildSettingsPanel())
	HudController.registerPanel("Daily", buildDailyPanel())
	HudController.registerPanel("Travel", buildTravelPanel())

	layout()
	lastGoop = ClientState.get().goop
	renderRates()
	renderDaily()
	renderSettings()
	renderCodes()

	--[[
		One repaint path for everything the server owns. The Goop tick fires
		this once a second, so only the labels are unconditional; a panel's
		rows are rebuilt from state only when a key they draw actually moved.
	]]
	ClientState.changed:connect(function(keys: any)
		if type(keys) ~= "table" then
			return
		end
		local changed = keys :: { string }
		renderRates()
		popOnJump()
		if keysInclude(changed, { daily = true, dailyState = true }) then
			renderDaily()
		end
		if keysInclude(changed, { settings = true }) then
			renderSettings()
			for player in plates do
				refreshPlate(player)
			end
		end
		if keysInclude(changed, { codes = true }) then
			renderCodes()
		end
	end)

	ClientState.ready:connect(function()
		lastGoop = ClientState.get().goop
		renderRates()
		renderDaily()
		renderSettings()
		renderCodes()
	end)

	-- Nameplates. DenSync is the feed (GDD §10); it arrives on every change
	-- and on DenService's own periodic resend, so nothing here polls.
	Net.event("DenSync").OnClientEvent:Connect(function(dens: any)
		if type(dens) ~= "table" then
			return
		end
		local rates: { [number]: number } = {}
		for _, entry in dens :: { Types.DenPublic } do
			if type(entry) == "table" and type(entry.userId) == "number" then
				rates[entry.userId] = entry.goopPerSec
			end
		end
		denRates = rates
		for player in plates do
			refreshPlate(player)
		end
	end)

	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(dropPlate)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end

	-- One pull so a joining player sees real rates before the first DenSync
	-- rather than "no Den yet" for up to a resend interval.
	task.spawn(function()
		local ok, result = pcall(function()
			return Net.func("Query"):InvokeServer("DenList")
		end)
		if not ok or type(result) ~= "table" then
			return
		end
		for _, entry in result :: { Types.DenPublic } do
			if type(entry) == "table" and type(entry.userId) == "number" then
				denRates[entry.userId] = entry.goopPerSec
			end
		end
		for player in plates do
			refreshPlate(player)
		end
	end)

	--[[
		The only per-frame work in the file: the Goop number (GDD §8.2) and the
		tutorial's highlight breath. The daily countdown and the viewport check
		ride along on a quarter-second throttle rather than owning connections
		of their own — and watching the size beats listening to the camera,
		which can be replaced under us and would leak a listener each time.
	]]
	RunService.RenderStepped:Connect(function()
		renderGoop()

		local now = os.clock()
		if now - lastSlowAt >= SLOW_INTERVAL then
			lastSlowAt = now
			local size = viewportSize()
			if size ~= lastViewport then
				layout() -- also decides whether the Mixdex row is folded
			end
			renderRates()
			renderDaily()
		end

		for key in highlighted do
			local stroke = clusterStrokes[key]
			if stroke then
				stroke.Transparency = 0.15 + 0.45 * (0.5 + 0.5 * math.sin(now * PULSE_SPEED))
			end
		end
	end)
end

return HudController
