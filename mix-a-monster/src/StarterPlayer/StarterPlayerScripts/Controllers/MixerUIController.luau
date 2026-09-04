--!strict
--[[
	MixerUIController.luau — the Mixer screen and the reveal.
	GDD §2 (pillar 1), §5 (10 s–18 s of the scripted first minute), §7.3,
	§8.1, §10.

	OWNS the three seconds the whole game is built around: the two-slot Mixer
	panel, the inventory pickers behind each slot, the RequestMix intent, and
	the spin → suspense → slam → card sequence that follows it.

	REGISTRY API — HudController and TutorialController call these, never the
	remotes:

	    open()                      -- show the panel (HUD button, or a pad)
	    close()                     -- hide it; REFUSED while a reveal runs
	    isRevealing() -> boolean    -- true from MIX until the card is dismissed
	    prefill(critter, stuff)     -- GDD §5: the tutorial opens both slots full

	THE REVEAL IS NEVER INTERRUPTED (GDD §2, pillar 1; ARCHITECTURE §7.5).
	`isRevealing()` stays true through the spin, the suspense beat, the slam
	AND the result card, because the card is the payoff, not an epilogue.
	While it is true `close()` does nothing, and HudController must not open
	another panel over this one — the reveal ScreenGui deliberately sits at a
	DisplayOrder above every panel and below AlertController's alarms, which
	is the one layer allowed through (a Mythic banner over your own Mythic is
	part of the moment, an alarm you cannot see is a bug).

	NOTHING HERE DECIDES ANYTHING (ARCHITECTURE §7.1). The tier, the display
	name, the rate, the luck figure and the length of the reveal all arrive in
	the MixResult; this file only chooses how they are drawn. Two consequences
	worth spelling out:

	  * The reel shows INGREDIENT names, never rarity words. A reel that
	    flashed "LEGENDARY" would be the client claiming an outcome it does
	    not have yet, and a player who saw it land on Common would rightly
	    call it rigged. Ingredients are decoration and cannot be mistaken for
	    a result.
	  * The MIX button greys out when a slot is empty or its stack is zero.
	    That is a courtesy so the player is not punished for a tap; the server
	    re-checks ownership on every RequestMix and is the only thing that
	    actually spends an ingredient.

	THE SPIN STARTS BEFORE THE SERVER ANSWERS (GDD §8.1). The machine must
	react on the frame the player taps, so RequestMix goes out and the spin
	begins in the same breath. Three things can then happen and all three are
	handled: the MixResult lands and the spin runs out its remaining time; a
	refusal lands on the Mixer's Notify channel and the spin is torn down
	quietly (AlertController owns the toast); or nothing lands at all, because
	Net dropped the call over its rate limit without telling anyone, and the
	timeout below is the only thing that would ever end the animation.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = ReplicatedStorage:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Config:WaitForChild("Constants"))
local Ingredients = require(Config:WaitForChild("Ingredients"))
local Rarity = require(Config:WaitForChild("Rarity"))
local Assembler = require(Shared:WaitForChild("MixlingAssembler"))
local Net = require(Shared:WaitForChild("Net"))
local Types = require(Shared:WaitForChild("Types"))
local UiKit = require(Shared:WaitForChild("UiKit"))
local Util = require(Shared:WaitForChild("Util"))

local ClientState = require(script.Parent.Parent:WaitForChild("ClientState"))

type MixlingView = Types.MixlingView
type MixResult = Types.MixResult
type Ingredient = Ingredients.Ingredient

local MixerUIController = {}
MixerUIController.Name = "MixerUIController"

-- ── Local tunables ───────────────────────────────────────────────────────
--[[
	Presentation values only. Everything the player earns, waits for or rolls
	against lives in Constants (GDD §17); how fast a reel ticks has never been
	a balance question and burying it there would hide the numbers that are.
	The three that ARE balance — REVEAL_SECONDS, REVEAL_SUSPENSE_SECONDS and
	REVEAL_MIN_SKIP_SECONDS — are read from Constants and never mirrored here.
]]

local PANEL_ORDER = 20 -- above the HUD, below the reveal
local REVEAL_ORDER = 90 -- above every panel, below AlertController's 100

-- Layout. Reserved rows are offsets so the slot row absorbs all slack: the
-- panel then reads the same on a 640x360 phone and a 1920x1080 monitor.
local PAD = 14
local ROW_HEADER = 44
local ROW_LUCK = 36
local ROW_MIX = 56
local ROW_GAP = 8
local ROWS_RESERVED = ROW_HEADER + ROW_LUCK + ROW_MIX + ROW_GAP * 3
local PANEL_MAX = Vector2.new(720, 560)
local STAGE_MAX = Vector2.new(520, 560)
local TOUCH = UiKit.TOUCH_MIN

-- Canonical sizes. Held as constants because UiKit.pop treats whatever size
-- it finds as the size to spring back to; see popTo below.
local PANEL_SIZE = UDim2.fromScale(0.94, 0.9)
local SLOT_SIZE = UDim2.new(0.44, 0, 1, 0)
local CARD_SIZE = UDim2.fromScale(1, 1)
local REEL_SIZE = UDim2.fromScale(0.78, 0.5)
local REEL_SIZE_SUSPENSE = UDim2.fromScale(0.7, 0.44)

-- Reel. Starts lazy, ends frantic; the suspense beat drops it back to a crawl.
local SPIN_INTERVAL_START = 0.16
local SPIN_INTERVAL_END = 0.045
local SPIN_INTERVAL_SUSPENSE = 0.5
local SPIN_ROLL_OFFSET = 0.16 -- how far a new symbol drops in from, in scale
local SLAM_HOLD = 0.12 -- beat between the slam and the card
local FLASH_PEAK = 0.25 -- how opaque the slam flash gets
local CARD_SPIN_SPEED = 0.9 -- radians/second in the result viewport
local RIBBON_PULSE = 0.35

-- Scrim opacity: the spin dims the world, the suspense beat all but removes
-- it. "The light changes" (GDD §8.1) is this plus the rim colour.
local SCRIM_SPIN = 0.15
local SCRIM_SUSPENSE = 0.02

--[[
	How long the reveal will wait for a MixResult that is never coming.
	Net.consume drops an over-budget RequestMix silently and by design, so
	there is no refusal to react to — without this the machine would spin
	until the player force-quit. Generous, because a bad connection deserves
	its reveal; anything later than this is shown as a card with no spin in
	front of it rather than thrown away.
]]
local NO_RESULT_TIMEOUT = 10

-- The Notify channel MixerService refuses on. AlertController owns the toast
-- for it; this controller only needs to know the spin is over.
local MIX_NOTIFY_KIND = "Mixer"

local PROMPT_DISTANCE = 12
local MIXER_PAD_TAG = "MixerPad" -- WorldService tags every pad with this

local STAR_FULL = "★"
local STAR_EMPTY = "☆"
local LUCK_STARS = 8 -- stars drawn before the row switches to "+N"
local ROW_STARS = 5 -- the tighter cap inside a picker row

local SUSPENSE_TEXT = "…something's different"
local SPIN_TEXT = "MIXING…"

--[[
	SoundController ships no RevealUncommon cue (GDD §7.3 gives Uncommon no
	announcement of its own either), so Uncommon rides the Common reveal. Its
	drama comes from the Mixling's own voice, which is pitched per tier.
]]
local REVEAL_CUE: { [number]: string } = {
	[Rarity.COMMON] = "RevealCommon",
	[Rarity.UNCOMMON] = "RevealCommon",
	[Rarity.RARE] = "RevealRare",
	[Rarity.EPIC] = "RevealEpic",
	[Rarity.LEGENDARY] = "RevealLegendary",
	[Rarity.MYTHIC] = "RevealMythic",
	[Rarity.SECRET] = "RevealSecret",
}

-- ── Siblings, captured from the registry ─────────────────────────────────

local sound: any = nil
local alerts: any = nil
local den: any = nil

-- ── State ────────────────────────────────────────────────────────────────

type RevealState = {
	active: boolean,
	phase: string, -- "Spin" | "Suspense" | "Slam" | "Card"
	startedAt: number,
	token: number, -- invalidates every thread and tween of an older reveal
	result: MixResult?,
	skipRequested: boolean,
	aborted: boolean,
	abortMessage: string?,
}

local reveal: RevealState = {
	active = false,
	phase = "Spin",
	startedAt = 0,
	token = 0,
	result = nil,
	skipRequested = false,
	aborted = false,
	abortMessage = nil,
}

local slots: { critter: string?, stuff: string? } = { critter = nil, stuff = nil }

local panelOpen = false
local pickerKind: string? = nil -- "Critter" | "Stuff" while the picker is up
local rng = Random.new() -- cosmetic only: which symbol the reel shows next

local prompts: { [BasePart]: ProximityPrompt } = {}

-- ── Widgets, built once in start() ───────────────────────────────────────

local panelGui: ScreenGui
local panel: Frame
local slotTiles: { [string]: TextButton } = {}
local slotStrokes: { [string]: UIStroke } = {}
local slotNames: { [string]: TextLabel } = {}
local slotCounts: { [string]: TextLabel } = {}
local slotStars: { [string]: TextLabel } = {}
local luckStars: { TextLabel } = {}
local luckOverflow: TextLabel
local mixButton: TextButton

local picker: Frame
local pickerTitle: TextLabel
local pickerScroll: ScrollingFrame
local pickerEmpty: TextLabel

local revealGui: ScreenGui
local scrim: Frame
local stage: Frame
local spinView: Frame
local reelTile: Frame
local reelStroke: UIStroke
local reelLabel: TextLabel
local subtitleLabel: TextLabel
local skipButton: TextButton
local flash: Frame

local card: Frame
local ribbon: TextLabel
local setCardModel: (Model?) -> ()
local cardName: TextLabel
local cardMeta: TextLabel
local cardRate: TextLabel
local placeButton: TextButton
local againButton: TextButton
local cardSpin: RBXScriptConnection? = nil

local uiReady = false

-- ── Small helpers ────────────────────────────────────────────────────────

local function cue(name: string)
	if sound then
		sound.play(name)
	end
end

--[[
	UiKit.pop springs a widget back to the size it is holding when pop is
	called. A second pop landing while the first is still in flight would
	therefore adopt the squashed size as the new resting size, and a panel the
	player opens repeatedly would creep smaller every time. Restoring the
	canonical size first — with no yield before the pop — makes the base exact
	however fast the taps come.
]]
local function popTo(object: GuiObject, size: UDim2, strength: number)
	object.Size = size
	UiKit.pop(object, strength)
end

--[[
	Restores a property that something else tweens. A plain assignment would
	be overwritten a frame later by the tween still in flight, so this starts a
	new, very short one instead: TweenService cancels the earlier tween on any
	property the new tween also touches.
]]
local SNAP = 0.05
local function snap(instance: Instance, props: { [string]: any })
	UiKit.tween(instance, props, SNAP)
end

local function toast(text: string, kind: string?)
	if alerts then
		alerts.toast(text, kind or "Error")
	end
end

local function ownedCount(name: string?): number
	if not name then
		return 0
	end
	local count = ClientState.get().inventory[name]
	return if type(count) == "number" then count else 0
end

--[[
	The player's stock of one kind, tier-ordered.

	ClientState.inventoryOf takes a `kind` and then ignores it (see
	contractIssues), so the filter lives here rather than being trusted there.
]]
local function ownedOf(kind: string): { Ingredient }
	local out: { Ingredient } = {}
	for name, count in ClientState.get().inventory do
		if type(count) ~= "number" or count < 1 then
			continue
		end
		local item = Ingredients.get(name)
		if item and item.kind == kind then
			table.insert(out, item)
		end
	end
	table.sort(out, function(a, b)
		if a.tier ~= b.tier then
			return a.tier > b.tier -- the interesting ingredients first
		end
		return a.name < b.name
	end)
	return out
end

local function starText(luck: number, cap: number): string
	if luck <= 0 then
		return ""
	end
	local shown = math.min(luck, cap)
	local text = string.rep(STAR_FULL, shown)
	if luck > shown then
		text ..= " +" .. tostring(luck - shown)
	end
	return text
end

local function luckOf(name: string?): number
	if not name then
		return 0
	end
	local item = Ingredients.get(name)
	return if item then item.luck else 0
end

--[[
	The luck row's figure: both ingredients plus the player's own luck, which
	MonetizationService folded into the profile view (passes + any running
	Luck Party). It is a PREVIEW of numbers the server already sent, not a
	calculation — the roll uses MixerService's own sum, and `result.luck` is
	what the reveal reports back.
]]
local function previewLuck(): number
	local base = ClientState.get().luck
	if type(base) ~= "number" or base ~= base then
		base = 0
	end
	return math.max(0, base + luckOf(slots.critter) + luckOf(slots.stuff))
end

-- ── Panel construction ───────────────────────────────────────────────────

local function sizeCap(target: GuiObject, maximum: Vector2)
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = maximum
	constraint.Parent = target
end

local function stroke(target: GuiObject, color: Color3, thickness: number): UIStroke
	local line = Instance.new("UIStroke")
	line.Color = color
	line.Thickness = thickness
	line.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	line.Parent = target
	return line
end

-- One geometry for the panel and the picker that covers it, so the picker
-- never looks like a different window opening on top of the Mixer.
local function centeredCard(parent: Instance, zIndex: number): Frame
	local frame = UiKit.frame({
		Parent = parent,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = PANEL_SIZE,
		BackgroundColor3 = UiKit.PALETTE.panel,
		Corner = 18,
		Stroke = UiKit.PALETTE.stroke,
		Padding = PAD,
		ZIndex = zIndex,
	})
	sizeCap(frame, PANEL_MAX)
	return frame
end

-- Every tap target in this file goes through UiKit.button, which is what
-- guarantees the 44 px minimum GDD §10 requires on a phone.
local function iconButton(parent: Instance, text: string, zIndex: number, onClick: () -> ()): TextButton
	return UiKit.button({
		Parent = parent,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(TOUCH, TOUCH),
		BackgroundColor3 = UiKit.PALETTE.panelSoft,
		TextColor3 = UiKit.PALETTE.text,
		Text = text,
		Corner = 12,
		ZIndex = zIndex,
	}, onClick)
end

local function buildSlot(parent: Instance, kind: string, order: number, caption: string)
	local tile = UiKit.button({
		Parent = parent,
		Size = SLOT_SIZE,
		BackgroundColor3 = UiKit.PALETTE.panelSoft,
		Text = "",
		Corner = 16,
		LayoutOrder = order,
		ZIndex = 4,
	}, function()
		cue("Click")
		MixerUIController.openPicker(kind)
	end)
	slotTiles[kind] = tile
	slotStrokes[kind] = stroke(tile, UiKit.PALETTE.stroke, 2)

	UiKit.label({
		Parent = tile,
		Size = UDim2.new(1, -12, 0.15, 0),
		Position = UDim2.new(0, 6, 0.05, 0),
		Text = caption,
		TextColor3 = UiKit.PALETTE.muted,
		ZIndex = 5,
	})
	slotNames[kind] = UiKit.label({
		Parent = tile,
		Size = UDim2.new(1, -12, 0.3, 0),
		Position = UDim2.new(0, 6, 0.26, 0),
		Text = "TAP TO PICK",
		ZIndex = 5,
	})
	slotCounts[kind] = UiKit.label({
		Parent = tile,
		Size = UDim2.new(1, -12, 0.15, 0),
		Position = UDim2.new(0, 6, 0.59, 0),
		Text = "",
		TextColor3 = UiKit.PALETTE.muted,
		ZIndex = 5,
	})
	slotStars[kind] = UiKit.label({
		Parent = tile,
		Size = UDim2.new(1, -12, 0.15, 0),
		Position = UDim2.new(0, 6, 0.77, 0),
		Text = "",
		TextColor3 = UiKit.PALETTE.warn,
		ZIndex = 5,
	})
end

local function buildLuckRow(parent: Instance)
	local row = UiKit.frame({
		Parent = parent,
		Size = UDim2.new(1, 0, 0, ROW_LUCK),
		BackgroundTransparency = 1,
		LayoutOrder = 3,
		ZIndex = 3,
	})
	UiKit.list(row, {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 3),
	})

	UiKit.label({
		Parent = row,
		Size = UDim2.new(0, 62, 1, 0),
		Text = "LUCK",
		TextColor3 = UiKit.PALETTE.muted,
		LayoutOrder = 1,
		ZIndex = 4,
	})
	for index = 1, LUCK_STARS do
		luckStars[index] = UiKit.label({
			Parent = row,
			Size = UDim2.new(0, 22, 1, 0),
			Text = STAR_EMPTY,
			TextColor3 = UiKit.PALETTE.stroke,
			LayoutOrder = 1 + index,
			ZIndex = 4,
		})
	end
	luckOverflow = UiKit.label({
		Parent = row,
		Size = UDim2.new(0, 52, 1, 0),
		Text = "",
		TextColor3 = UiKit.PALETTE.warn,
		LayoutOrder = 2 + LUCK_STARS,
		ZIndex = 4,
	})
end

local function buildPanel()
	panelGui = UiKit.screen("MixerUI", PANEL_ORDER)
	panelGui.Enabled = false

	-- Active, so a tap that misses the panel is eaten here instead of walking
	-- the player's character across the plaza mid-decision.
	UiKit.frame({
		Parent = panelGui,
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = UiKit.PALETTE.ink,
		BackgroundTransparency = 0.45,
		Active = true,
		ZIndex = 1,
	})

	panel = centeredCard(panelGui, 2)
	UiKit.list(panel, { Padding = UDim.new(0, ROW_GAP), HorizontalAlignment = Enum.HorizontalAlignment.Center })

	local header = UiKit.frame({
		Parent = panel,
		Size = UDim2.new(1, 0, 0, ROW_HEADER),
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		ZIndex = 3,
	})
	UiKit.label({
		Parent = header,
		Size = UDim2.new(1, -(TOUCH + 8), 1, 0),
		Text = "THE MIXER",
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 4,
	})
	iconButton(header, "✕", 4, function()
		cue("Click")
		MixerUIController.close()
	end)

	local slotRow = UiKit.frame({
		Parent = panel,
		Size = UDim2.new(1, 0, 1, -ROWS_RESERVED),
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		ZIndex = 3,
	})
	UiKit.list(slotRow, {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 10),
	})
	buildSlot(slotRow, "Critter", 1, "CRITTER")
	UiKit.label({
		Parent = slotRow,
		Size = UDim2.new(0, 28, 0.4, 0),
		Text = "+",
		TextColor3 = UiKit.PALETTE.muted,
		LayoutOrder = 2,
		ZIndex = 4,
	})
	buildSlot(slotRow, "Stuff", 3, "STUFF")

	buildLuckRow(panel)

	mixButton = UiKit.button({
		Parent = panel,
		Size = UDim2.new(1, 0, 0, ROW_MIX),
		BackgroundColor3 = UiKit.PALETTE.goop,
		Text = "MIX",
		Corner = 14,
		LayoutOrder = 4,
		ZIndex = 3,
	}, function()
		MixerUIController.mix()
	end)
end

local function buildPicker()
	picker = centeredCard(panelGui, 6)
	picker.Visible = false

	pickerTitle = UiKit.label({
		Parent = picker,
		Size = UDim2.new(1, -(TOUCH + 8), 0, ROW_HEADER),
		Text = "CHOOSE",
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 7,
	})
	iconButton(picker, "✕", 7, function()
		cue("Click")
		MixerUIController.closePicker()
	end)

	pickerScroll = UiKit.scroll({
		Parent = picker,
		Size = UDim2.new(1, 0, 1, -(ROW_HEADER + ROW_GAP)),
		Position = UDim2.new(0, 0, 0, ROW_HEADER + ROW_GAP),
		ZIndex = 7,
	})
	UiKit.list(pickerScroll, { Padding = UDim.new(0, 6) })

	pickerEmpty = UiKit.label({
		Parent = picker,
		Size = UDim2.new(1, 0, 0, 60),
		Position = UDim2.new(0, 0, 0.4, 0),
		Text = "",
		TextColor3 = UiKit.PALETTE.muted,
		Visible = false,
		ZIndex = 8,
	})
end

-- ── Panel rendering ──────────────────────────────────────────────────────

local function renderSlot(kind: string)
	local chosen = if kind == "Critter" then slots.critter else slots.stuff
	local nameLabel = slotNames[kind]
	local countLabel = slotCounts[kind]
	local starLabel = slotStars[kind]
	local line = slotStrokes[kind]

	if not chosen then
		nameLabel.Text = "TAP TO PICK"
		nameLabel.TextColor3 = UiKit.PALETTE.muted
		countLabel.Text = ""
		starLabel.Text = ""
		line.Color = UiKit.PALETTE.stroke
		return
	end

	local item = Ingredients.get(chosen)
	local count = ownedCount(chosen)
	nameLabel.Text = string.upper(chosen)
	nameLabel.TextColor3 = UiKit.PALETTE.text
	countLabel.Text = if count > 0 then ("x%d owned"):format(count) else "NONE LEFT"
	countLabel.TextColor3 = if count > 0 then UiKit.PALETTE.muted else UiKit.PALETTE.danger
	starLabel.Text = starText(if item then item.luck else 0, ROW_STARS)
	--[[
		The ingredient's own tier is coloured from the rarity table on purpose
		(ARCHITECTURE §7.2, and the rule that colours never come from a
		literal): a T5 Crown and a Legendary Mixling reading the same gold is
		what makes "expensive ingredient" and "rare outcome" one visual idea.
	]]
	line.Color = if item then Rarity.color(item.tier) else UiKit.PALETTE.stroke
end

local function renderLuck()
	local luck = previewLuck()
	local filled = math.min(luck, LUCK_STARS)
	for index, star in luckStars do
		local on = index <= filled
		star.Text = if on then STAR_FULL else STAR_EMPTY
		star.TextColor3 = if on then UiKit.PALETTE.warn else UiKit.PALETTE.stroke
	end
	luckOverflow.Text = if luck > LUCK_STARS then "+" .. tostring(luck - LUCK_STARS) else ""
end

local function canMix(): boolean
	local critter, stuff = slots.critter, slots.stuff
	if not critter or not stuff then
		return false
	end
	return ownedCount(critter) > 0 and ownedCount(stuff) > 0
end

local function renderMixButton()
	local ready = canMix()
	--[[
		Transparency, never colour. UiKit.button captures its BackgroundColor3
		at construction to drive the press/hover tween, so recolouring a
		disabled button here would leave that tween restoring the enabled
		green under the player's finger.
	]]
	mixButton.BackgroundTransparency = if ready then 0 else 0.6
	mixButton.TextColor3 = if ready then UiKit.PALETTE.ink else UiKit.PALETTE.muted
	if ready then
		mixButton.Text = "MIX"
	elseif not slots.critter or not slots.stuff then
		mixButton.Text = "PICK BOTH SLOTS"
	else
		mixButton.Text = "OUT OF INGREDIENTS"
	end
end

local function renderPanel()
	if not uiReady then
		return
	end
	renderSlot("Critter")
	renderSlot("Stuff")
	renderLuck()
	renderMixButton()
end

-- ── Inventory picker ─────────────────────────────────────────────────────

local function addPickerRow(item: Ingredient, count: number, order: number)
	local row = UiKit.button({
		Parent = pickerScroll,
		Size = UDim2.new(1, -10, 0, TOUCH + 12),
		BackgroundColor3 = UiKit.PALETTE.panelSoft,
		Text = "",
		Corner = 12,
		LayoutOrder = order,
		ZIndex = 7,
	}, function()
		cue("Click")
		MixerUIController.choose(item.name)
	end)

	-- Tier chip: the rarity colour again, so a shelf, a slot and a picker row
	-- all say "tier" the same way.
	local chip = UiKit.frame({
		Parent = row,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 10, 0.5, 0),
		Size = UDim2.fromOffset(14, 34),
		BackgroundColor3 = Rarity.color(item.tier),
		Corner = 7,
		ZIndex = 8,
	})
	chip.BorderSizePixel = 0

	UiKit.label({
		Parent = row,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 34, 0.5, -8),
		Size = UDim2.new(0.55, -34, 0, 26),
		Text = item.name,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 8,
	})
	UiKit.label({
		Parent = row,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 34, 0.5, 14),
		Size = UDim2.new(0.55, -34, 0, 18),
		Text = starText(item.luck, ROW_STARS),
		TextColor3 = UiKit.PALETTE.warn,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 8,
	})
	UiKit.label({
		Parent = row,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.new(0.3, 0, 0, 30),
		Text = "x" .. tostring(count),
		TextXAlignment = Enum.TextXAlignment.Right,
		ZIndex = 8,
	})
end

local function renderPicker()
	local kind = pickerKind
	if not kind then
		return
	end
	for _, child in pickerScroll:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	local stock = ownedOf(kind)
	for index, item in stock do
		addPickerRow(item, ownedCount(item.name), index)
	end

	pickerEmpty.Visible = #stock == 0
	pickerEmpty.Text = if kind == "Critter"
		then "No Critters in your bag.\nBuy one at the Critter Pen."
		else "No Stuff in your bag.\nBuy some at the Stuff Shack."
end

--[[
	Public only because the slot tiles and the tutorial both open a picker;
	nothing outside this file is expected to call it.
]]
function MixerUIController.openPicker(kind: string)
	if not uiReady or reveal.active then
		return
	end
	if kind ~= "Critter" and kind ~= "Stuff" then
		return
	end
	pickerKind = kind
	pickerTitle.Text = if kind == "Critter" then "CHOOSE A CRITTER" else "CHOOSE SOME STUFF"
	renderPicker()
	picker.Visible = true
	popTo(picker, PANEL_SIZE, 0.06)
end

function MixerUIController.closePicker()
	pickerKind = nil
	if uiReady then
		picker.Visible = false
	end
end

function MixerUIController.choose(name: string)
	local item = Ingredients.get(name)
	if not item then
		return
	end
	if item.kind == "Critter" then
		slots.critter = name
	else
		slots.stuff = name
	end
	MixerUIController.closePicker()
	renderPanel()
	local tile = slotTiles[item.kind]
	if tile then
		popTo(tile, SLOT_SIZE, 0.1)
	end
end

-- ── The reveal ───────────────────────────────────────────────────────────

local function buildReveal()
	revealGui = UiKit.screen("MixerReveal", REVEAL_ORDER)
	revealGui.Enabled = false

	scrim = UiKit.frame({
		Parent = revealGui,
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = UiKit.PALETTE.ink,
		BackgroundTransparency = SCRIM_SPIN,
		Active = true, -- the reveal owns every tap for its duration
		ZIndex = 1,
	})

	stage = UiKit.frame({
		Parent = revealGui,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.92, 0.92),
		BackgroundTransparency = 1,
		ZIndex = 2,
	})
	sizeCap(stage, STAGE_MAX)

	-- ── Spin view ──
	spinView = UiKit.frame({
		Parent = stage,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 3,
	})
	reelTile = UiKit.frame({
		Parent = spinView,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = REEL_SIZE,
		BackgroundColor3 = UiKit.PALETTE.panelSoft,
		Corner = 20,
		ClipsDescendants = true, -- the symbol rolls in from outside the tile
		ZIndex = 4,
	})
	reelStroke = stroke(reelTile, UiKit.PALETTE.stroke, 3)
	reelLabel = UiKit.label({
		Parent = reelTile,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.9, 0.5),
		Text = SPIN_TEXT,
		ZIndex = 5,
	})
	subtitleLabel = UiKit.label({
		Parent = spinView,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -(TOUCH + 16)),
		Size = UDim2.new(1, 0, 0, 28),
		Text = SPIN_TEXT,
		TextColor3 = UiKit.PALETTE.muted,
		ZIndex = 5,
	})
	skipButton = UiKit.button({
		Parent = spinView,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromOffset(150, TOUCH),
		BackgroundColor3 = UiKit.PALETTE.panelSoft,
		TextColor3 = UiKit.PALETTE.text,
		Text = "SKIP",
		Corner = 12,
		Visible = false,
		ZIndex = 6,
	}, function()
		reveal.skipRequested = true
	end)

	-- ── Result card ──
	card = UiKit.frame({
		Parent = stage,
		Size = CARD_SIZE,
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 3,
	})
	ribbon = UiKit.label({
		Parent = card,
		Size = UDim2.new(1, -(TOUCH + 8), 0, 32),
		Text = "",
		TextColor3 = UiKit.PALETTE.warn,
		Visible = false,
		ZIndex = 5,
	})
	iconButton(card, "✕", 6, function()
		cue("Click")
		MixerUIController.dismiss()
	end)

	-- The ViewportFrame itself is never touched again; the setter it hands
	-- back is the whole of "show this Mixling" and "show nothing".
	local _, setModel = UiKit.viewport({
		Parent = card,
		Size = UDim2.new(1, 0, 1, -190),
		Position = UDim2.new(0, 0, 0, 36),
		ZIndex = 4,
	})
	setCardModel = setModel

	cardName = UiKit.label({
		Parent = card,
		Size = UDim2.new(1, 0, 0, 40),
		Position = UDim2.new(0, 0, 1, -150),
		Text = "",
		ZIndex = 5,
	})
	cardMeta = UiKit.label({
		Parent = card,
		Size = UDim2.new(1, 0, 0, 26),
		Position = UDim2.new(0, 0, 1, -108),
		Text = "",
		TextColor3 = UiKit.PALETTE.muted,
		ZIndex = 5,
	})
	cardRate = UiKit.label({
		Parent = card,
		Size = UDim2.new(1, 0, 0, 26),
		Position = UDim2.new(0, 0, 1, -80),
		Text = "",
		TextColor3 = UiKit.PALETTE.goop,
		ZIndex = 5,
	})

	local buttons = UiKit.frame({
		Parent = card,
		Size = UDim2.new(1, 0, 0, 52),
		Position = UDim2.new(0, 0, 1, -52),
		BackgroundTransparency = 1,
		ZIndex = 4,
	})
	placeButton = UiKit.button({
		Parent = buttons,
		Size = UDim2.new(0.48, 0, 1, 0),
		BackgroundColor3 = UiKit.PALETTE.goop,
		Text = "PLACE",
		Corner = 14,
		ZIndex = 5,
	}, function()
		MixerUIController.place()
	end)
	againButton = UiKit.button({
		Parent = buttons,
		Position = UDim2.fromScale(0.52, 0),
		Size = UDim2.new(0.48, 0, 1, 0),
		BackgroundColor3 = UiKit.PALETTE.accent,
		Text = "MIX AGAIN",
		Corner = 14,
		ZIndex = 5,
	}, function()
		MixerUIController.mixAgain()
	end)

	flash = UiKit.frame({
		Parent = revealGui,
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 1,
		ZIndex = 9,
	})
end

local function setPromptsEnabled(enabled: boolean)
	for _, prompt in prompts do
		prompt.Enabled = enabled
	end
end

local function stopCardSpin()
	local connection = cardSpin
	cardSpin = nil
	if connection then
		connection:Disconnect()
	end
end

--[[
	Everything a reveal leaves behind. Called on the way in as well as the way
	out, so a second mix never inherits the first one's tint, ribbon or model.
]]
local function resetRevealVisuals()
	stopCardSpin()
	setCardModel(nil)
	card.Visible = false
	spinView.Visible = true
	skipButton.Visible = false
	ribbon.Visible = false
	reelLabel.Text = SPIN_TEXT
	reelLabel.TextColor3 = UiKit.PALETTE.text
	subtitleLabel.Text = SPIN_TEXT
	subtitleLabel.TextColor3 = UiKit.PALETTE.muted
	placeButton.BackgroundTransparency = 0
	againButton.BackgroundTransparency = 0

	-- Everything the suspense beat, the reel and the slam leave mid-tween.
	snap(ribbon, { TextTransparency = 0 })
	snap(scrim, { BackgroundTransparency = SCRIM_SPIN })
	snap(reelStroke, { Color = UiKit.PALETTE.stroke, Thickness = 3 })
	snap(reelLabel, { TextTransparency = 0, Position = UDim2.fromScale(0.5, 0.5) })
	snap(reelTile, { Size = REEL_SIZE })
	snap(flash, { BackgroundTransparency = 1 })
end

local function endReveal()
	reveal.active = false
	reveal.result = nil
	reveal.phase = "Spin"
	stopCardSpin()
	setCardModel(nil)
	revealGui.Enabled = false
	setPromptsEnabled(not panelOpen)
end

local function abortReveal(message: string?)
	endReveal()
	resetRevealVisuals()
	if message then
		toast(message)
	end
	renderPanel()
end

-- ── The reel ─────────────────────────────────────────────────────────────

local reelIndex = 0
local nextSymbolAt = 0

--[[
	INGREDIENTS, NOT RARITIES. See the header: the reel is decoration, and the
	only tier it is ever allowed to state is the one the server sent.
]]
local function showSymbol(interval: number)
	reelIndex += 1
	local list: { Ingredient } = if reelIndex % 2 == 1 then Ingredients.Critters else Ingredients.Stuff
	local item = list[rng:NextInteger(1, #list)]
	reelLabel.Text = string.upper(item.name)
	reelLabel.TextColor3 = Rarity.color(item.tier)
	-- Position is reset to the top of the roll every time rather than read
	-- back, so overlapping tweens cannot walk the label off the tile.
	reelLabel.Position = UDim2.fromScale(0.5, 0.5 - SPIN_ROLL_OFFSET)
	UiKit.tween(reelLabel, { Position = UDim2.fromScale(0.5, 0.5) }, math.min(interval, 0.12))
end

local function spinTick(elapsed: number, slow: boolean)
	local now = os.clock()
	if now < nextSymbolAt then
		return
	end
	local interval
	if slow then
		interval = SPIN_INTERVAL_SUSPENSE
	else
		local progress = math.clamp(elapsed / Constants.REVEAL_SECONDS, 0, 1)
		interval = SPIN_INTERVAL_START + (SPIN_INTERVAL_END - SPIN_INTERVAL_START) * progress
	end
	nextSymbolAt = now + interval
	showSymbol(interval)
end

--[[
	GDD §8.1's "…something's different" beat, Epic and above. The reel drops
	to a crawl, the world behind it goes almost black and the rim turns cold.

	The spin CUE keeps playing through it: SoundController's registry API has
	no stop-by-name, and its only silencer is RollSlam, which is the very
	thing this beat delays. The visual carries the moment; see contractIssues.
]]
local function enterSuspense()
	reveal.phase = "Suspense"
	subtitleLabel.Text = SUSPENSE_TEXT
	subtitleLabel.TextColor3 = UiKit.PALETTE.accent
	UiKit.tween(scrim, { BackgroundTransparency = SCRIM_SUSPENSE }, 0.4)
	UiKit.tween(reelLabel, { TextTransparency = 0.45 }, 0.4)
	UiKit.tween(reelStroke, { Color = UiKit.PALETTE.accent, Thickness = 5 }, 0.4)
	UiKit.tween(reelTile, { Size = REEL_SIZE_SUSPENSE }, 0.5, Enum.EasingStyle.Sine)
end

-- The server owns the length of the reveal. Clamped only so a malformed
-- payload cannot leave the machine spinning forever or slam early.
local function revealLength(result: MixResult): number
	local total = result.revealSeconds
	if type(total) ~= "number" or total ~= total then
		total = Constants.REVEAL_SECONDS
	end
	local ceiling = Constants.REVEAL_SECONDS + Constants.REVEAL_SUSPENSE_SECONDS
	return math.clamp(total, Constants.REVEAL_MIN_SKIP_SECONDS, ceiling)
end

-- ── The result card ──────────────────────────────────────────────────────

local function pulseRibbon(token: number)
	task.spawn(function()
		while reveal.active and reveal.token == token do
			UiKit.tween(ribbon, { TextTransparency = 0.5 }, RIBBON_PULSE)
			task.wait(RIBBON_PULSE)
			if reveal.token ~= token then
				break
			end
			UiKit.tween(ribbon, { TextTransparency = 0 }, RIBBON_PULSE)
			task.wait(RIBBON_PULSE)
		end
	end)
end

local function renderCardButtons()
	local view = if reveal.result then reveal.result.mixling else nil
	local stocked = view ~= nil and ownedCount(view.critter) > 0 and ownedCount(view.stuff) > 0
	againButton.BackgroundTransparency = if stocked then 0 else 0.6
	againButton.TextColor3 = if stocked then UiKit.PALETTE.ink else UiKit.PALETTE.muted
	againButton.Text = if stocked then "MIX AGAIN" else "NO INGREDIENTS"
end

local function showCard(result: MixResult, token: number)
	local view = result.mixling
	local tier = Rarity.clamp(view.rarity)
	local color = Rarity.color(tier)

	reveal.phase = "Card"
	spinView.Visible = false
	card.Visible = true

	local settings = ClientState.get().settings
	local model = Assembler.buildDisplay({
		critter = view.critter,
		stuff = view.stuff,
		rarity = view.rarity,
		secretId = view.secretId,
		secretName = view.secretName,
		-- The card's own audio is SoundController's job (playMixling below),
		-- so the model is built silent; two copies of one voice is a mess.
		withSound = false,
		lowFx = settings.lowFx == true,
	}, CFrame.new())
	setCardModel(model)

	local angle = 0
	stopCardSpin()
	cardSpin = RunService.RenderStepped:Connect(function(delta: number)
		angle += delta * CARD_SPIN_SPEED
		model:PivotTo(CFrame.Angles(0, angle, 0))
	end)

	cardName.Text = view.displayName
	cardName.TextColor3 = color
	cardMeta.Text = ("%s · %s + %s"):format(string.upper(Rarity.name(tier)), view.stuff, view.critter)
	cardMeta.TextColor3 = color
	-- Every Goop figure the player reads goes through Util.abbreviate (§10).
	cardRate.Text = ("+%s Goop/sec"):format(Util.abbreviate(view.goopPerSec))

	-- GDD §5: the starter Mixling is the one thing a new player cannot lose,
	-- and the card is where they are told so.
	if view.bound then
		cardMeta.Text ..= "  🔒 BOUND"
	end

	if result.firstDiscovery then
		-- The rarest moment in the game (GDD §7.4): nobody on this server had
		-- produced this recipe before.
		ribbon.Text = "★ FIRST DISCOVERY ★"
		ribbon.TextColor3 = color
		ribbon.Visible = true
		pulseRibbon(token)
		cue("Fanfare")
		cue("Confetti")
	elseif result.newMixdexEntry then
		ribbon.Text = "NEW!"
		ribbon.TextColor3 = UiKit.PALETTE.warn
		ribbon.Visible = true
		pulseRibbon(token)
		cue("Confetti")
	end

	cue(REVEAL_CUE[tier] or "RevealCommon")
	if sound then
		-- No position: the voice plays on the listener, because this Mixling
		-- is on a card in front of the player and not yet in the world.
		sound.playMixling(view)
	end

	renderCardButtons()
	placeButton.BackgroundTransparency = 0
	popTo(card, CARD_SIZE, 0.14)
end

local function slamAndReveal(result: MixResult, token: number)
	reveal.phase = "Slam"
	spinView.Visible = false
	cue("RollSlam") -- also the one cue that silences the spin loop

	flash.BackgroundTransparency = FLASH_PEAK
	UiKit.tween(flash, { BackgroundTransparency = 1 }, 0.3)

	task.wait(SLAM_HOLD)
	if reveal.token ~= token or not reveal.active then
		return
	end
	showCard(result, token)
end

-- ── The reveal driver ────────────────────────────────────────────────────

--[[
	One thread owns the whole sequence. It reads `reveal` every frame instead
	of scheduling the phases up front, because the two things that change the
	schedule — the MixResult landing and the player tapping SKIP — both arrive
	after the animation has already started.
]]
local function driveReveal(token: number)
	while true do
		RunService.Heartbeat:Wait()
		if reveal.token ~= token or not reveal.active then
			return
		end
		if reveal.aborted then
			abortReveal(reveal.abortMessage)
			return
		end

		local elapsed = os.clock() - reveal.startedAt
		local result = reveal.result
		if not result then
			if elapsed >= NO_RESULT_TIMEOUT then
				abortReveal("The Mixer jammed. Give it a second and try again.")
				return
			end
			spinTick(elapsed, false)
			continue
		end

		local total = revealLength(result)
		local skippable = elapsed >= Constants.REVEAL_MIN_SKIP_SECONDS
		if skippable and not skipButton.Visible then
			skipButton.Visible = true
		end

		-- GDD §8.1: Epic+ buys the extra beat, and the server is the one that
		-- decided this roll gets it.
		if reveal.phase == "Spin" and result.suspense and elapsed >= total - Constants.REVEAL_SUSPENSE_SECONDS then
			enterSuspense()
		end

		-- The skip floor is Constants.REVEAL_MIN_SKIP_SECONDS and it is not
		-- negotiable (GDD §8.1: "client may not skip below 1.5 s").
		if elapsed >= total or (reveal.skipRequested and skippable) then
			slamAndReveal(result, token)
			return
		end

		spinTick(elapsed, reveal.phase == "Suspense")
	end
end

local function beginReveal(): number
	reveal.token += 1
	local token = reveal.token
	reveal.active = true
	reveal.phase = "Spin"
	reveal.startedAt = os.clock()
	reveal.result = nil
	reveal.skipRequested = false
	reveal.aborted = false
	reveal.abortMessage = nil

	resetRevealVisuals()
	MixerUIController.closePicker()
	revealGui.Enabled = true
	setPromptsEnabled(false)
	nextSymbolAt = 0
	cue("RollSpin")
	return token
end

-- ── Public API ───────────────────────────────────────────────────────────

function MixerUIController.isRevealing(): boolean
	return reveal.active
end

function MixerUIController.open()
	if not uiReady then
		return
	end
	panelOpen = true
	panelGui.Enabled = true
	setPromptsEnabled(false)
	renderPanel()
	if not reveal.active then
		popTo(panel, PANEL_SIZE, 0.08)
	end
end

--[[
	Refused outright while a reveal is running (ARCHITECTURE §7.5). The card's
	own PLACE / MIX AGAIN / ✕ are the only ways out of a reveal, and they are
	all inside the reveal's own ScreenGui, so nothing that can be covered is
	ever the only exit.
]]
function MixerUIController.close()
	if reveal.active then
		return
	end
	panelOpen = false
	MixerUIController.closePicker()
	if uiReady then
		panelGui.Enabled = false
	end
	setPromptsEnabled(true)
end

-- GDD §5, 10 s: "UI opens with both slots pre-filled."
function MixerUIController.prefill(critter: string?, stuff: string?)
	if critter and Ingredients.isCritter(critter) then
		slots.critter = critter
	end
	if stuff and Ingredients.isStuff(stuff) then
		slots.stuff = stuff
	end
	renderPanel()
end

--[[
	The intent. Fires RequestMix and starts the animation in the same frame so
	the machine answers the tap, not the round trip (GDD §8.1).

	The guard is first and unconditional: one reveal at a time, however fast
	the player taps. Net rate-limits RequestMix as well, but a second mix
	accepted here would orphan the first reveal's result.
]]
function MixerUIController.mix()
	if reveal.active or not uiReady then
		return
	end
	local critter, stuff = slots.critter, slots.stuff
	if not critter or not stuff then
		cue("Error")
		toast("Pick one Critter and one Stuff.")
		return
	end
	if ownedCount(critter) < 1 or ownedCount(stuff) < 1 then
		cue("Error")
		toast("You are out of one of those ingredients.")
		return
	end

	Net.event("RequestMix"):FireServer(critter, stuff)
	local token = beginReveal()
	task.spawn(driveReveal, token)
end

function MixerUIController.mixAgain()
	local result = reveal.result
	if not result then
		return
	end
	local view = result.mixling
	if ownedCount(view.critter) < 1 or ownedCount(view.stuff) < 1 then
		cue("Error")
		toast("You are out of one of those ingredients.")
		return
	end
	-- Same pair, straight back into the machine. Ending the current reveal
	-- first is what lets `mix()` past its own guard.
	slots.critter = view.critter
	slots.stuff = view.stuff
	endReveal()
	resetRevealVisuals()
	renderPanel()
	MixerUIController.mix()
end

--[[
	The first pedestal the player could actually use.

	This mirrors DenService.totalSlots from replicated data only — profile
	`denSlots` plus the pass bonus the profile says they own — so PLACE can
	aim at a real pedestal instead of guessing. It decides nothing: the server
	re-runs the same check on RequestPlace and refuses in its own words.
]]
local function firstFreePedestal(): number?
	local view = ClientState.get()
	local slotCount = view.denSlots
	if type(slotCount) ~= "number" or slotCount ~= slotCount then
		slotCount = Constants.DEN_SLOTS_START
	end
	if view.passes and view.passes.DenSlots then
		slotCount += Constants.PASSES.DenSlots.slotBonus
	end
	slotCount = math.clamp(math.floor(slotCount), 0, Constants.DEN_SLOTS_HARD_MAX)

	for index = 1, slotCount do
		if not view.placed[tostring(index)] then
			return index
		end
	end
	return nil
end

--[[
	PLACE. Straight onto the first free pedestal when there is one — the
	scripted first minute (GDD §5, 18 s) must not stop to ask a new player
	which pedestal they want. When the Den is full the choice is real, so the
	Den panel opens and they make it there.
]]
function MixerUIController.place()
	local result = reveal.result
	if not result then
		return
	end
	local view = result.mixling
	local index = firstFreePedestal()
	if not index then
		MixerUIController.dismiss()
		MixerUIController.close()
		if den then
			den.open()
			return
		end
		toast("Your pedestals are full. Free one in your Den.", "Info")
		return
	end

	cue("Click")
	Net.event("RequestPlace"):FireServer(view.id, index)
	-- Greyed the moment it is sent: the confirmation is a ProfileSync, and a
	-- second tap in that window would ask for the same pedestal twice.
	placeButton.BackgroundTransparency = 0.6
	MixerUIController.dismiss()
	MixerUIController.close()
end

-- Ends the reveal. Everything the player can tap on the card comes here.
function MixerUIController.dismiss()
	if not reveal.active then
		return
	end
	endReveal()
	resetRevealVisuals()
	renderPanel()
end

-- ── Incoming server truth ────────────────────────────────────────────────

local function validView(value: any): MixlingView?
	if type(value) ~= "table" then
		return nil
	end
	local view = value :: MixlingView
	if type(view.id) ~= "string" or type(view.critter) ~= "string" or type(view.stuff) ~= "string" then
		return nil
	end
	if type(view.rarity) ~= "number" or type(view.displayName) ~= "string" or type(view.goopPerSec) ~= "number" then
		return nil
	end
	return view
end

local function validResult(payload: any): MixResult?
	if type(payload) ~= "table" then
		return nil
	end
	local result = payload :: MixResult
	if not validView(result.mixling) then
		return nil
	end
	return result
end

--[[
	A result with no spin in front of it: the reveal timed out on a bad
	connection, or the player closed the game's Mixer between the intent and
	the answer. The roll happened and the Mixling is theirs, so it is shown as
	a card rather than swallowed — a reveal the player never saw is a bug
	report about a missing Mixling.
]]
local function presentLate(result: MixResult)
	reveal.token += 1
	local token = reveal.token
	reveal.active = true
	reveal.result = result
	reveal.skipRequested = false
	reveal.aborted = false

	resetRevealVisuals()
	revealGui.Enabled = true
	setPromptsEnabled(false)
	showCard(result, token)
end

local function onMixResult(payload: any)
	local result = validResult(payload)
	if not result then
		return
	end
	if reveal.active and reveal.result == nil then
		reveal.result = result
		return
	end
	presentLate(result)
end

--[[
	MixerService's refusals ("You have no Frog left.") come back on the Notify
	channel it owns. AlertController shows the line — it is connected to the
	same remote — so all this has to do is take the animation down.
]]
local function onNotify(kind: any, _text: any)
	if kind ~= MIX_NOTIFY_KIND then
		return
	end
	if not reveal.active or reveal.result ~= nil then
		return
	end
	reveal.aborted = true
	reveal.abortMessage = nil
end

-- ── Mixer pads (GDD §6: ten pads so a full server can mix at once) ───────

--[[
	The prompts are built client-side because they are pure interface: the
	server has no interest in who is standing on a pad, and a ProximityPrompt
	is already the touch-friendly control GDD §3 asks for — it renders as a
	tappable button on a phone with no extra work.
]]
local function attachPrompt(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local pad: BasePart = instance
	if prompts[pad] then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "MixerPrompt"
	prompt.ActionText = "Mix"
	prompt.ObjectText = "The Mixer"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	prompt.Enabled = not (panelOpen or reveal.active)
	prompt.Parent = pad
	prompt.Triggered:Connect(function()
		cue("Click")
		MixerUIController.open()
	end)
	prompts[pad] = prompt
end

local function detachPrompt(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local pad: BasePart = instance
	local prompt = prompts[pad]
	prompts[pad] = nil
	if prompt then
		prompt:Destroy()
	end
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

function MixerUIController.init(controllers: { [string]: any })
	sound = controllers.SoundController
	alerts = controllers.AlertController
	-- The Den panel is where a full Den sends the player; captured, never
	-- required (ARCHITECTURE §3).
	den = controllers.DenUIController
end

function MixerUIController.start()
	buildPanel()
	buildPicker()
	buildReveal()
	uiReady = true
	renderPanel()

	Net.event("MixResult").OnClientEvent:Connect(onMixResult)
	Net.event("Notify").OnClientEvent:Connect(onNotify)

	-- The panel is a window onto the profile: every count, every star and the
	-- MIX button's own state come from the last sync.
	ClientState.changed:connect(function(keys: any)
		if type(keys) ~= "table" then
			return
		end
		for _, key in keys :: { string } do
			if key == "inventory" or key == "luck" or key == "passes" or key == "placed" then
				renderPanel()
				if pickerKind then
					renderPicker()
				end
				if reveal.active and reveal.phase == "Card" then
					renderCardButtons()
				end
				return
			end
		end
	end)

	for _, pad in CollectionService:GetTagged(MIXER_PAD_TAG) do
		attachPrompt(pad)
	end
	CollectionService:GetInstanceAddedSignal(MIXER_PAD_TAG):Connect(attachPrompt)
	CollectionService:GetInstanceRemovedSignal(MIXER_PAD_TAG):Connect(detachPrompt)
end

return MixerUIController
