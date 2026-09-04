--!strict
--[[
	DenUIController.luau — the Den panel: the pedestal grid, the door lock and
	the two Goop sinks that sit behind them.
	GDD §5 (25 s: "placement, Goop/sec ticking"), §8.3 (pedestals, lock tiers,
	the new-player shield), §8.4 (why a locked door is worth 2,000 Goop),
	§10 ("pedestal grid, drag or tap-to-place, lock button with timer, slot
	purchase").

	REGISTRY API — HudController opens this from the cluster and
	MixerUIController sends a fresh roll here from the result card. Neither
	touches a remote:

	    open()                   -- show the panel
	    close()                  -- hide it
	    promptPlace(mixlingId)   -- open it ARMED: the next empty pedestal the
	                                player taps gets this Mixling

	NOTHING HERE DECIDES ANYTHING (ARCHITECTURE §7.1). The header rate, the
	pedestal contents, the lock level, the shield and every price on this
	screen are read from a ProfileSync, a DenSync or the server's own
	"ShopPrices" quote. The buttons send RequestPlace, RequestUnplace,
	RequestLock and RequestPurchase and then wait; a refusal comes back on the
	Den or Shop Notify channel and AlertController shows the sentence the
	server wrote. No Goop is spent, and no pedestal changes, until a sync says
	it did.

	TAP IS THE WHOLE INTERACTION (GDD §3, §10). §10 offers "drag or
	tap-to-place" and this file ships tap, deliberately. Net has no move
	intent, so dragging one Mixling from pedestal A to pedestal B could only
	be an unplace followed by a place — two requests the server may refuse
	independently, leaving the Mixling in the player's collection and the
	player staring at two empty pedestals wondering which gesture failed. Tap
	is one intent per gesture, needs no hover, no second pointer and no
	precision, which is what a phone has.

	HOW MANY PEDESTALS ARE OPEN. The wire carries `denSlots` (what the profile
	paid for) and `passes`, never a total, so the open count is derived the
	same way DenService.totalSlots derives it: profile slots plus the DenSlots
	pass bonus, clamped to Constants.DEN_SLOTS_HARD_MAX. That derivation is a
	drawing, not a decision — `DenService.place` re-checks its own count on
	every request, so a client that drew one pedestal too many gets "That
	pedestal is locked" and nothing else happens.

	ONLY THE FIRST LOCKED PEDESTAL CARRIES A BUY BUTTON. Slots are bought one
	at a time and the server prices exactly one — the next one — so the rest
	show their Constants.DEN_SLOT_PRICES sticker as a roadmap with no button.
	The k-th locked cell is the k-th purchase from here, whether the five pass
	pedestals are riding on top or not, which is why the price index counts
	from `denSlots` and not from the cell's own number. Cells past the end of
	that table are the pass's five; there is no client-facing remote for
	prompting a game pass, so they say so and do nothing.

	THE CONFIRM STEP IS THIS FILE'S ALONE. GDD §8.6 wants a confirmation above
	Constants.SHOP_CONFIRM_THRESHOLD and ShopService deliberately has no
	two-step handshake — a confirmation guards a misclick, not an exploiter.
	It is an in-place "tap again" on the button rather than a modal: a dialog
	over a panel over a scrim is three layers deep on a 360px-tall phone, and
	the second tap lands where the thumb already is.

	THE LOCK COUNTDOWN IS DRAWN FROM DenSync. `lockEndsAt` arrives in the
	player's own DenPublic row; the cooldown that follows it is
	Constants.LOCK[level].cooldown, added here exactly as DenService.tryLock
	adds it, because the wire has no field for it. Both are os.time() seconds,
	so the countdown is a subtraction and never a guess — and when it is wrong
	the server still refuses the lock and says how long is really left.

	THE BODY IS ONE SCROLL. A landscape phone leaves HudController's stage
	about 135px tall, which is less than the lock button plus one row of
	pedestals. Shrinking controls to fit would break the 44px minimum GDD §10
	makes non-negotiable, so nothing shrinks: the shield strip, the lock block
	and the grid stack in a single scrolling column and the player flicks.

	THE PICKER IS VIRTUALISED, AND NOTHING IN IT HOLDS A MODEL.
	Constants.MIXLING_SOFT_CAP is 400. One row per unplaced Mixling is 400
	rows for a phone to lay out, and 400 ViewportFrames each holding an
	assembled model would be far worse — so the picker does neither. A Mixling
	is identified by a rarity swatch, its name in its rarity colour and its
	rate; the models live on the fifteen pedestal cells, which is a bounded
	number. The rows are a recycled pool sized to the scroll window,
	positioned by offset rather than by a UIListLayout (a layout would repack
	recycled children and undo the recycling) and capped at MAX_PICKER_ROWS,
	with the window itself capped at what that pool can serve. That is
	deliberately the same shape as MixdexController's 261-tile grid: two
	virtualised lists that read alike are worth more than a cleverer second
	design.

	AN OPEN PICKER SURVIVES SOMEONE ELSE'S PLACEMENT. DenSync fires whenever
	ANY player's door or pedestal moves and this panel repaints on every one
	of them, so a repaint recomputes the row list and paints it INTO the pool
	that is already there. Nothing is destroyed, the scroll stays where the
	player left it, and the row under a thumb is still under it when the thumb
	lands. The take-back column is rebuilt only when the sentence it prints
	changes, for the same reason.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = ReplicatedStorage:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Config:WaitForChild("Constants"))
local Rarity = require(Config:WaitForChild("Rarity"))
local Assembler = require(Shared:WaitForChild("MixlingAssembler"))
local Net = require(Shared:WaitForChild("Net"))
local Types = require(Shared:WaitForChild("Types"))
local UiKit = require(Shared:WaitForChild("UiKit"))
local Util = require(Shared:WaitForChild("Util"))

local ClientState = require(script.Parent.Parent:WaitForChild("ClientState"))

type MixlingView = Types.MixlingView
type DenPublic = Types.DenPublic

local DenUIController = {}
DenUIController.Name = "DenUIController"

local LocalPlayer = Players.LocalPlayer

-- ── Local tunables ───────────────────────────────────────────────────────
--[[
	Geometry and cadence only. Everything the player earns, waits for or pays
	lives in Constants (GDD §17); how many pixels a gap is has never been a
	balance question, and burying it there would hide the numbers that are.
]]

local PANEL_NAME = "Den" -- HudController's cluster button opens this key

local PAD = 10
local GAP = 8
local ROW = 46 -- UiKit's 44px touch minimum plus a hair, so nothing clips it
local TITLE_HEIGHT = 30
local CLOSE_RESERVE = 108 -- HudController's CLOSE button owns the stage's top-right

-- The grid drops a column rather than a cell below CELL_MIN, and never grows
-- a cell past CELL_MAX: a pedestal the size of a playing card on a monitor is
-- a grid that reads as five things, not fifteen.
local CELL_MIN = 104
local CELL_MAX = 152
local CELL_ASPECT = 1.5 -- model, name, rate, and room for a BUY button under them
local GRID_MIN_COLUMNS = 2
local GRID_MAX_COLUMNS = 5

local ART_TOP = 4
local ROW_TITLE = 22
local ROW_SUB = 18
local BUY_RESERVE = 52 -- vertical space a locked cell gives its BUY button
local SUB_RESERVE = 4 -- ...and what every other cell gives instead

local PICKER_ROW = 52
local PICKER_NOTE = 34 -- the one line of instruction above the picker's list
local SWATCH = 10 -- width of a picker row's rarity stripe

--[[
	The picker's virtualisation, sized the way MixdexController sizes its
	grid. MAX_PICKER_ROWS is the ceiling on the row pool, and buildSheet caps
	the scroll's own height at the number of rows that pool can serve, so a
	very tall monitor cannot ask for a row that does not exist. That window
	cap works out at 1,320px of list — HudController never gives a panel
	anything close to it, so this is a guarantee rather than a constraint
	anyone will meet.
]]
local PICKER_STRIDE = PICKER_ROW + GAP
local PICKER_OVERSCAN = 1 -- one row painted ahead so a flick never shows a hole
local MAX_PICKER_ROWS = 24

-- The instruction line rides inside the canvas rather than above it, so it
-- scrolls away instead of taking 42px off a landscape phone's picker — where
-- the whole sheet is about 135px tall. Every row sits this far down.
local PICKER_HEAD = PICKER_NOTE + GAP

local SPIN_SPEED = 0.55 -- radians/sec in the pedestal viewports
local TICK_INTERVAL = 0.2 -- countdown repaint; a mm:ss clock does not need 60 Hz
local CONFIRM_SECONDS = 4 -- how long a "tap again" stays armed before it lapses

-- ── State ────────────────────────────────────────────────────────────────
-- Registry handles, the widgets this file owns, and the last thing each
-- server feed said. Nothing derived is cached across a render.

local hud: any = nil
local sound: any = nil

local panel: Frame? = nil

local promptStrip: Frame? = nil
local promptLabel: TextLabel? = nil
local rateLabel: TextLabel? = nil
local filledLabel: TextLabel? = nil
local shieldStrip: Frame? = nil
local shieldLabel: TextLabel? = nil

local lockButton: TextButton? = nil
local lockInfo: TextLabel? = nil
local upgradeRow: Frame? = nil
local upgradeLabel: TextLabel? = nil
local upgradeButton: TextButton? = nil

local gridHolder: Frame? = nil
local gridLayout: UIGridLayout? = nil

local sheet: Frame? = nil
local sheetTitle: TextLabel? = nil
local sheetList: ScrollingFrame? = nil
local sheetRows: { GuiObject } = {}
-- What the rows sheetRow built currently say. nil means "nothing built".
local sheetKey: string? = nil

local pickerNote: TextLabel? = nil
local pickerScroll: ScrollingFrame? = nil

type Cell = {
	index: number,
	button: TextButton,
	art: ViewportFrame,
	setModel: (Model?) -> (),
	glyph: TextLabel,
	title: TextLabel,
	sub: TextLabel,
	mark: TextLabel,
	buy: TextButton,
	stroke: UIStroke?,
	shownId: string?,
	model: Model?,
}

local cells: { Cell } = {}

type PickerRow = {
	button: TextButton,
	swatch: Frame,
	name: TextLabel,
	detail: TextLabel,
	key: string?, -- what this row is currently showing; nil when it shows nothing
	mixlingId: string?,
	wanted: boolean,
}

local pickerPool: { PickerRow } = {}
local pickerChoices: { MixlingView } = {}
local pickerFirst = 0
local pickerLast = -1

-- What the server last quoted for the two Den sinks. Nil until the first
-- "ShopPrices" answer lands; every reader falls back to Constants, which is
-- the same frozen table ShopService prices from.
type SlotOffer = { price: number?, available: boolean, reason: string?, confirm: boolean }
type LockOffer = { level: number, maxLevel: number, price: number?, available: boolean, reason: string?, confirm: boolean }

local slotOffer: SlotOffer? = nil
local lockOffer: LockOffer? = nil
local offerInFlight = false

local denRows: { DenPublic } = {}
local pendingPlaceId: string? = nil
local takeBackIndex: number? = nil
local pickerIndex: number? = nil

local armedKey: string? = nil
local armedUntil = 0

local spinAngle = 0
local tickAccumulator = 0
local lastGridWidth = 0

-- ── Small helpers ────────────────────────────────────────────────────────

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

local function cue(name: string)
	if sound then
		sound.play(name)
	end
end

local function view(): ClientState.View
	return ClientState.get()
end

local function lowFx(): boolean
	local settings = view().settings
	return settings ~= nil and settings.lowFx == true
end

type LockTier = { duration: number, cooldown: number, price: number }

local function lockTier(level: number): LockTier?
	return Constants.LOCK[level]
end

--[[
	DenService.totalSlots, drawn rather than decided — see the header. Both
	halves are read from the sync: `denSlots` is what the profile paid for and
	`passes.DenSlots` is what MonetizationService has already confirmed.
]]
local function unlockedCount(): number
	local current = view()
	local base = if type(current.denSlots) == "number" then current.denSlots else Constants.DEN_SLOTS_START
	local bonus = 0
	if current.passes and current.passes.DenSlots then
		bonus = Constants.PASSES.DenSlots.slotBonus
	end
	return math.clamp(math.floor(base + bonus), 0, Constants.DEN_SLOTS_HARD_MAX)
end

-- The price of the k-th purchase from where this profile stands. Cell number
-- does not enter into it: the pass's five ride on top of `denSlots`, so the
-- first locked cell is still purchase number (denSlots - START + 1).
local function slotPriceAhead(steps: number): number?
	local current = view()
	local base = if type(current.denSlots) == "number" then current.denSlots else Constants.DEN_SLOTS_START
	local step = math.floor(base) - Constants.DEN_SLOTS_START + steps
	if step < 1 then
		return nil
	end
	local price: number? = Constants.DEN_SLOT_PRICES[step]
	return price
end

local function myDen(): DenPublic?
	for _, entry in denRows do
		if entry.userId == LocalPlayer.UserId then
			return entry
		end
	end
	return nil
end

local function placedAt(index: number): MixlingView?
	local id = view().placed[tostring(index)]
	if not id then
		return nil
	end
	return ClientState.mixlingById(id)
end

local function specOf(mixling: MixlingView): Assembler.BuildSpec
	return {
		critter = mixling.critter,
		stuff = mixling.stuff,
		rarity = mixling.rarity,
		secretId = mixling.secretId,
		secretName = mixling.secretName,
		lowFx = lowFx(),
	}
end

local function keysInclude(keys: { string }, wanted: { [string]: boolean }): boolean
	for _, key in keys do
		if wanted[key] then
			return true
		end
	end
	return false
end

--[[
	Two-tap confirmation. Arming is per button key, so arming the slot button
	disarms the lock upgrade — a player who changed their mind about one
	25,000 Goop purchase should not find the other one still cocked.
]]
local function arm(key: string)
	armedKey = key
	armedUntil = os.clock() + CONFIRM_SECONDS
end

local function isArmed(key: string): boolean
	return armedKey == key and os.clock() < armedUntil
end

local function disarm()
	armedKey = nil
	armedUntil = 0
end

-- ── Intents ──────────────────────────────────────────────────────────────
-- Every one of these is a request. The screen does not move until a sync
-- says the server agreed; the toast for a refusal is AlertController's.

local render: () -> ()
local closeSheet: () -> ()

local function sendPlace(mixlingId: string, index: number)
	cue("Click") -- the Mixling's own voice belongs to the model DenService builds
	Net.event("RequestPlace"):FireServer(mixlingId, index)
	pendingPlaceId = nil
	closeSheet()
	render()
end

local function sendUnplace(mixlingId: string)
	cue("Click")
	Net.event("RequestUnplace"):FireServer(mixlingId)
	closeSheet()
	render()
end

local function sendLock()
	cue("Click")
	Net.event("RequestLock"):FireServer()
end

local function sendPurchase(kind: string)
	cue("Purchase")
	Net.event("RequestPurchase"):FireServer(kind, "")
	disarm()
	render()
end

--[[
	Buys through the confirm gate. `confirm` is the server's own flag when a
	quote has arrived and Constants.SHOP_CONFIRM_THRESHOLD otherwise, so the
	dialog appears at the same figure GDD §8.6 names either way.
]]
local function offerTap(key: string, price: number?, needsConfirm: boolean)
	if price and needsConfirm and not isArmed(key) then
		cue("Click")
		arm(key)
		render()
		return
	end
	sendPurchase(key)
end

-- ── Server quotes ────────────────────────────────────────────────────────
--[[
	ShopService prices both Den sinks and PlayerService routes them out
	through the "ShopPrices" Query, so the panel is handed a price instead of
	working one out. It is pulled when the panel opens and whenever the two
	things that move it — slots owned and lock level — change, which is rarely
	enough that a per-second poll would be pure noise on the rate limiter.
]]
local function readSlotOffer(source: any): SlotOffer?
	if type(source) ~= "table" then
		return nil
	end
	local price = source.price
	return {
		price = if type(price) == "number" then price else nil,
		available = source.available == true,
		reason = if type(source.reason) == "string" then source.reason else nil,
		confirm = source.confirm == true,
	}
end

local function readLockOffer(source: any): LockOffer?
	if type(source) ~= "table" then
		return nil
	end
	local price = source.price
	return {
		level = if type(source.level) == "number" then source.level else 1,
		maxLevel = if type(source.maxLevel) == "number" then source.maxLevel else #Constants.LOCK,
		price = if type(price) == "number" then price else nil,
		available = source.available == true,
		reason = if type(source.reason) == "string" then source.reason else nil,
		confirm = source.confirm == true,
	}
end

local function refreshOffers()
	if offerInFlight then
		return
	end
	offerInFlight = true
	task.spawn(function()
		local ok, answer = pcall(function(): any
			return Net.func("Query"):InvokeServer("ShopPrices")
		end)
		offerInFlight = false
		-- A dropped Query (over budget, or a server mid-shutdown) answers nil
		-- by design. The last quote stays on screen rather than blanking the
		-- prices the player is reading.
		if not ok or type(answer) ~= "table" then
			return
		end
		slotOffer = readSlotOffer(answer.denSlot) or slotOffer
		lockOffer = readLockOffer(answer.lock) or lockOffer
		render()
	end)
end

local function refreshDenRows()
	task.spawn(function()
		local ok, answer = pcall(function(): any
			return Net.func("Query"):InvokeServer("DenList")
		end)
		if not ok or type(answer) ~= "table" then
			return
		end
		denRows = answer :: { DenPublic }
		render()
	end)
end

-- ── The pedestal grid ────────────────────────────────────────────────────

local onCellTapped: (number) -> ()

local function buildCell(index: number): Cell
	local button = UiKit.button({
		Text = "",
		BackgroundColor3 = UiKit.PALETTE.panelSoft,
		Corner = 12,
		Stroke = UiKit.PALETTE.stroke,
		LayoutOrder = index,
	}, function()
		onCellTapped(index)
	end)

	local art, setModel = UiKit.viewport({
		Size = UDim2.new(1, -8, 1, -80),
		Position = UDim2.new(0.5, 0, 0, ART_TOP),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = button,
	})

	-- Stands in for the model on an empty or locked pedestal. Same rectangle,
	-- so a cell never changes shape as it fills.
	local glyph = UiKit.label({
		Text = "",
		TextColor3 = UiKit.PALETTE.muted,
		Size = art.Size,
		Position = art.Position,
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = button,
	})
	textCeiling(glyph, 40)

	local title = UiKit.label({
		Text = "",
		TextColor3 = UiKit.PALETTE.text,
		Size = UDim2.new(1, -8, 0, ROW_TITLE),
		Position = UDim2.new(0.5, 0, 1, -(SUB_RESERVE + ROW_SUB)),
		AnchorPoint = Vector2.new(0.5, 1),
		TextWrapped = true,
		Parent = button,
	})
	textCeiling(title, 16)

	local sub = UiKit.label({
		Text = "",
		TextColor3 = UiKit.PALETTE.muted,
		Font = UiKit.FONT_BODY,
		Size = UDim2.new(1, -8, 0, ROW_SUB),
		Position = UDim2.new(0.5, 0, 1, -SUB_RESERVE),
		AnchorPoint = Vector2.new(0.5, 1),
		Parent = button,
	})
	textCeiling(sub, 13)

	-- GDD §8.3: the Bound starter Mixling wears a padlock so its owner knows
	-- why nobody ever takes it.
	local mark = UiKit.label({
		Text = "",
		TextColor3 = UiKit.PALETTE.warn,
		Size = UDim2.fromOffset(22, 22),
		Position = UDim2.new(1, -6, 0, 6),
		AnchorPoint = Vector2.new(1, 0),
		Visible = false,
		Parent = button,
	})
	textCeiling(mark, 18)

	local buy = UiKit.button({
		Text = "",
		BackgroundColor3 = UiKit.PALETTE.goop,
		TextColor3 = UiKit.PALETTE.ink,
		Corner = 10,
		Size = UDim2.new(1, -12, 0, UiKit.TOUCH_MIN),
		Position = UDim2.new(0.5, 0, 1, -4),
		AnchorPoint = Vector2.new(0.5, 1),
		Visible = false,
		Parent = button,
	}, function()
		local offer = slotOffer
		local price = if offer then offer.price else slotPriceAhead(1)
		local needsConfirm = if offer
			then offer.confirm
			else price ~= nil and price >= Constants.SHOP_CONFIRM_THRESHOLD
		offerTap("DenSlot", price, needsConfirm)
	end)
	textCeiling(buy, 18)

	return {
		index = index,
		button = button,
		art = art,
		setModel = setModel,
		glyph = glyph,
		title = title,
		sub = sub,
		mark = mark,
		buy = buy,
		stroke = button:FindFirstChildOfClass("UIStroke"),
		shownId = nil,
		model = nil,
	}
end

-- Keeps the grid full-width without ragged cells: columns come from the space
-- there is, not from a breakpoint guess about what device this is.
local function relayoutGrid()
	local holder = gridHolder
	local layout = gridLayout
	if not holder or not layout then
		return
	end
	local width = holder.AbsoluteSize.X
	if width <= 0 or width == lastGridWidth then
		return
	end
	lastGridWidth = width

	local columns = math.clamp(math.floor((width + GAP) / (CELL_MIN + GAP)), GRID_MIN_COLUMNS, GRID_MAX_COLUMNS)
	local cellWidth = math.min(CELL_MAX, (width - GAP * (columns - 1)) / columns)
	layout.FillDirectionMaxCells = columns
	layout.CellSize = UDim2.fromOffset(math.floor(cellWidth), math.floor(cellWidth * CELL_ASPECT))
end

--[[
	Repositions the plaque rows around whatever the cell is showing. A locked
	cell owes its BUY button 52px of its own; every other cell gives that back
	to the model, which is the thing worth looking at.
]]
local function fitCell(cell: Cell, showBuy: boolean)
	local reserve = if showBuy then BUY_RESERVE else SUB_RESERVE
	cell.sub.Position = UDim2.new(0.5, 0, 1, -reserve)
	cell.title.Position = UDim2.new(0.5, 0, 1, -(reserve + ROW_SUB))
	local artHeight = -(ART_TOP + reserve + ROW_SUB + ROW_TITLE + 4)
	cell.art.Size = UDim2.new(1, -8, 1, artHeight)
	cell.glyph.Size = cell.art.Size
end

local function showModel(cell: Cell, mixling: MixlingView?)
	local wanted = if mixling then mixling.id else nil
	if cell.shownId == wanted then
		return -- the same Mixling is already standing there; rebuilding it would only cost frames
	end
	cell.shownId = wanted
	cell.model = nil
	if not mixling then
		cell.setModel(nil)
		return
	end
	local model = Assembler.buildDisplay(specOf(mixling), CFrame.new())
	cell.setModel(model)
	cell.model = model
end

local function paintCell(cell: Cell)
	local index = cell.index
	local unlocked = unlockedCount()
	local placing = pendingPlaceId ~= nil

	if index > unlocked then
		-- LOCKED. Only the very next one is for sale; see the header.
		local steps = index - unlocked
		local offer = slotOffer
		local sellable = steps == 1 and (offer == nil or offer.available)
		local price = if steps == 1 and offer and offer.price then offer.price else slotPriceAhead(steps)

		showModel(cell, nil)
		fitCell(cell, sellable and price ~= nil)
		cell.art.Visible = false
		cell.glyph.Visible = true
		cell.glyph.Text = "\u{1F512}"
		cell.title.Text = "LOCKED"
		cell.title.TextColor3 = UiKit.PALETTE.muted
		cell.mark.Visible = false
		cell.button.BackgroundColor3 = UiKit.PALETTE.ink

		if price == nil then
			-- Past the end of DEN_SLOT_PRICES: these five arrive with the pass
			-- and there is no client-side remote that can prompt for one.
			cell.sub.Text = if offer and offer.reason then offer.reason else Constants.PASSES.DenSlots.name
			cell.buy.Visible = false
			return
		end

		cell.sub.Text = Util.abbreviate(price) .. " Goop"
		cell.buy.Visible = sellable
		cell.buy.Text = if isArmed("DenSlot") then "TAP AGAIN" else "BUY"
		cell.buy.BackgroundColor3 = if isArmed("DenSlot") then UiKit.PALETTE.warn else UiKit.PALETTE.goop
		return
	end

	local mixling = placedAt(index)
	fitCell(cell, false)
	cell.buy.Visible = false

	if not mixling then
		-- EMPTY.
		showModel(cell, nil)
		cell.art.Visible = false
		cell.glyph.Visible = true
		cell.glyph.Text = "+"
		cell.mark.Visible = false
		cell.title.Text = "EMPTY"
		cell.title.TextColor3 = UiKit.PALETTE.muted
		cell.sub.Text = if placing then "TAP TO PLACE HERE" else "TAP TO FILL"
		cell.button.BackgroundColor3 = UiKit.PALETTE.panelSoft
		local stroke = cell.stroke
		if stroke then
			stroke.Color = if placing then UiKit.PALETTE.accent else UiKit.PALETTE.stroke
		end
		return
	end

	-- FILLED.
	showModel(cell, mixling)
	cell.art.Visible = true
	cell.glyph.Visible = false
	cell.title.Text = mixling.displayName
	cell.title.TextColor3 = Rarity.color(mixling.rarity)
	cell.sub.Text = Util.abbreviate(mixling.goopPerSec) .. " Goop/sec"
	cell.mark.Visible = mixling.bound == true
	cell.mark.Text = "\u{1F512}"
	cell.button.BackgroundColor3 = UiKit.PALETTE.panelSoft
	local stroke = cell.stroke
	if stroke then
		stroke.Color = Rarity.color(mixling.rarity)
	end
end

-- ── The sheet: picker and take-back ──────────────────────────────────────

local function clearSheet()
	for _, row in sheetRows do
		row:Destroy()
	end
	table.clear(sheetRows)
	sheetKey = nil
end

function closeSheet()
	pickerIndex = nil
	takeBackIndex = nil
	clearSheet()
	local frame = sheet
	if frame then
		frame.Visible = false
	end
end

local function sheetRow(order: number, height: number): Frame
	local list = sheetList
	local holder = UiKit.frame({
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, height),
		LayoutOrder = order,
		Parent = list,
	})
	table.insert(sheetRows, holder)
	return holder
end

local function sheetNote(order: number, text: string, color: Color3)
	local holder = sheetRow(order, 34)
	local label = UiKit.label({
		Text = text,
		TextColor3 = color,
		Font = UiKit.FONT_BODY,
		TextWrapped = true,
		Size = UDim2.fromScale(1, 1),
		Parent = holder,
	})
	textCeiling(label, 15)
end

--[[
	Rarity first, then newest. MixlingView carries no createdAt, but
	ClientState appends every roll to the end of `mixlings` in the order the
	server sent it, so position in that list IS age — which is why the sort
	carries the original index rather than reading a timestamp that is not on
	the wire.
]]
local function unplacedSorted(): { MixlingView }
	local unplaced = ClientState.unplacedMixlings()
	local order: { [string]: number } = {}
	for index, mixling in unplaced do
		order[mixling.id] = index
	end
	table.sort(unplaced, function(a: MixlingView, b: MixlingView): boolean
		if a.rarity ~= b.rarity then
			return a.rarity > b.rarity
		end
		return (order[a.id] or 0) > (order[b.id] or 0)
	end)
	return unplaced
end

-- ── The picker's row pool ────────────────────────────────────────────────

local function buildPickerRow(): PickerRow
	local button = UiKit.button({
		Text = "",
		BackgroundColor3 = UiKit.PALETTE.panelSoft,
		Corner = 10,
		Size = UDim2.new(1, 0, 0, PICKER_ROW),
		Visible = false,
		Parent = pickerScroll,
	})

	-- A colour swatch rather than a model: see the header on why no row in
	-- this list carries a ViewportFrame.
	local swatch = UiKit.frame({
		BackgroundColor3 = UiKit.PALETTE.stroke,
		Size = UDim2.new(0, SWATCH, 1, -12),
		Position = UDim2.fromOffset(8, 6),
		Corner = 5,
		Parent = button,
	})

	local name = UiKit.label({
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -(SWATCH + 122), 0, 24),
		Position = UDim2.new(0, SWATCH + 16, 0, 6),
		Parent = button,
	})
	textCeiling(name, 19)

	local detail = UiKit.label({
		Text = "",
		TextColor3 = UiKit.PALETTE.muted,
		Font = UiKit.FONT_BODY,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -(SWATCH + 122), 0, 16),
		Position = UDim2.new(0, SWATCH + 16, 0, 30),
		Parent = button,
	})
	textCeiling(detail, 13)

	local place = UiKit.label({
		Text = "PLACE",
		TextColor3 = UiKit.PALETTE.goop,
		Size = UDim2.fromOffset(96, 24),
		Position = UDim2.new(1, -10, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		Parent = button,
	})
	textCeiling(place, 18)

	local row: PickerRow = {
		button = button,
		swatch = swatch,
		name = name,
		detail = detail,
		key = nil,
		mixlingId = nil,
		wanted = false,
	}

	--[[
		Both the Mixling and the pedestal are read at tap time rather than
		captured. One pooled row serves every Mixling in the list and every
		pedestal the player opens the picker from, so a captured pair would
		place the wrong Mixling on the wrong plinth the second time round.
	]]
	button.Activated:Connect(function()
		local id = row.mixlingId
		local index = pickerIndex
		if not id or not index then
			return
		end
		sendPlace(id, index)
	end)

	return row
end

-- A row leaving the window forgets what it was showing, so nothing stale can
-- be tapped and the next paint cannot mistake it for a hit.
local function hidePickerRow(row: PickerRow)
	if not row.button.Visible and row.key == nil then
		return
	end
	row.button.Visible = false
	row.key = nil
	row.mixlingId = nil
end

--[[
	The recycle key. Two rows showing the same Mixling at the same rate are
	interchangeable, so a scroll that moves the window repaints only the rows
	whose contents actually changed — and the rate is in the key because a
	multiplier the server applied moves it under a row already on screen.
]]
local function pickerKeyOf(mixling: MixlingView): string
	return mixling.id .. "@" .. tostring(mixling.goopPerSec)
end

local function paintPickerRow(row: PickerRow, mixling: MixlingView)
	local color = Rarity.color(mixling.rarity)
	row.mixlingId = mixling.id
	row.swatch.BackgroundColor3 = color
	row.name.Text = mixling.displayName
	row.name.TextColor3 = color
	row.detail.Text =
		("%s · %s Goop/sec"):format(Rarity.name(mixling.rarity), Util.abbreviate(mixling.goopPerSec))
end

--[[
	Assigns the visible slice of `pickerChoices` to the pool. Index -> row is
	modular rather than sequential on purpose: as the window moves by one row,
	only the rows that actually left change hands, so a flick repaints what
	entered the screen and nothing else.
]]
local function paintPicker(force: boolean)
	local scroll = pickerScroll
	if not scroll or #pickerChoices == 0 then
		-- Unconditional: an empty list has to take the rows off the screen,
		-- and the range check below would happily keep them.
		for _, row in pickerPool do
			hidePickerRow(row)
		end
		pickerFirst, pickerLast = 0, -1
		return
	end

	-- Negative while the instruction line is still on screen; the clamps below
	-- are what make that harmless rather than a row index of -1.
	local top = scroll.CanvasPosition.Y - PICKER_HEAD
	local windowHeight = math.max(scroll.AbsoluteWindowSize.Y, 1)
	local firstRow = math.max(0, math.floor(top / PICKER_STRIDE))
	local lastRow = math.max(firstRow, math.floor((top + windowHeight) / PICKER_STRIDE) + PICKER_OVERSCAN)

	local wanted = math.min(MAX_PICKER_ROWS, lastRow - firstRow + 1)
	local first = firstRow + 1
	local last = math.min(#pickerChoices, first + wanted - 1)
	if not force and first == pickerFirst and last == pickerLast then
		return
	end
	pickerFirst, pickerLast = first, last

	while #pickerPool < wanted do
		table.insert(pickerPool, buildPickerRow())
	end

	for _, row in pickerPool do
		row.wanted = false
	end

	local pool = #pickerPool
	for index = first, last do
		local mixling = pickerChoices[index]
		local row = pickerPool[(index - 1) % pool + 1]
		row.wanted = true
		row.button.Position = UDim2.fromOffset(0, PICKER_HEAD + (index - 1) * PICKER_STRIDE)
		row.button.Visible = true

		local key = pickerKeyOf(mixling)
		if force or row.key ~= key then
			row.key = key
			paintPickerRow(row, mixling)
		end
	end

	for _, row in pickerPool do
		if not row.wanted then
			hidePickerRow(row)
		end
	end
end

--[[
	The list itself, recomputed from the sync. The canvas comes from the row
	count and the scroll position is left where the player put it: a DenSync
	arrives whenever ANY player places something, and an open picker that
	jumped — or was destroyed and rebuilt — on every one of those would steal
	the tap the player was in the middle of making.
]]
local function rebuildPickerRows()
	pickerChoices = unplacedSorted()

	local scroll = pickerScroll
	if scroll then
		local height = if #pickerChoices == 0
			then PICKER_NOTE
			else PICKER_HEAD + #pickerChoices * PICKER_STRIDE - GAP
		scroll.CanvasSize = UDim2.fromOffset(0, height)
		scroll.CanvasPosition = Vector2.new(0, math.min(scroll.CanvasPosition.Y, height))
	end
end

-- ── The sheet's two bodies ───────────────────────────────────────────────

-- The take-back column is four rows packed by a UIListLayout; the picker is
-- the virtualised list above. Exactly one of them is ever up.
local function showPickerBody(picking: boolean)
	local scroll = pickerScroll
	if scroll then
		scroll.Visible = picking
	end
	local list = sheetList
	if list then
		list.Visible = not picking
	end
end

local function renderPicker(index: number)
	local title = sheetTitle
	if title then
		title.Text = ("PEDESTAL %d"):format(index)
	end

	rebuildPickerRows()

	local note = pickerNote
	if note then
		note.Text = if #pickerChoices == 0
			then "Every Mixling you own is already on a pedestal. Go mix another one."
			else "Rarest first. Tap one to stand it on this pedestal."
	end

	paintPicker(true)
end

local function renderTakeBack(index: number)
	local mixling = placedAt(index)
	if not mixling then
		closeSheet()
		return
	end

	local title = sheetTitle
	if title then
		title.Text = ("PEDESTAL %d"):format(index)
	end

	--[[
		Rebuilt only when what it says changes. DenSync fires on any player's
		door or pedestal, and tearing this column down and putting it back
		under the player's thumb on every one of those is both waste and a
		lost tap, so the key carries everything the column draws.
	]]
	local key = ("%d|%s|%s|%s"):format(
		index,
		mixling.id,
		tostring(mixling.bound == true),
		Util.abbreviate(mixling.goopPerSec)
	)
	if sheetKey == key then
		return
	end
	clearSheet()
	sheetKey = key

	local head = sheetRow(1, 56)
	local name = UiKit.label({
		Text = mixling.displayName,
		TextColor3 = Rarity.color(mixling.rarity),
		Size = UDim2.new(1, 0, 0, 32),
		Parent = head,
	})
	textCeiling(name, 26)
	local detail = UiKit.label({
		Text = ("%s · %s Goop/sec"):format(Rarity.name(mixling.rarity), Util.abbreviate(mixling.goopPerSec)),
		TextColor3 = UiKit.PALETTE.muted,
		Font = UiKit.FONT_BODY,
		Size = UDim2.new(1, 0, 0, 20),
		Position = UDim2.fromOffset(0, 34),
		Parent = head,
	})
	textCeiling(detail, 15)

	sheetNote(2, "Taking it back stops it earning until you stand it somewhere again.", UiKit.PALETTE.muted)
	if mixling.bound then
		sheetNote(3, "Bound: nobody can ever steal this one.", UiKit.PALETTE.warn)
	end

	local action = sheetRow(4, ROW)
	local button = UiKit.button({
		Text = "TAKE BACK",
		BackgroundColor3 = UiKit.PALETTE.danger,
		TextColor3 = UiKit.PALETTE.text,
		Corner = 12,
		Size = UDim2.fromScale(1, 1),
		Parent = action,
	}, function()
		sendUnplace(mixling.id)
	end)
	textCeiling(button, 22)
end

local function renderSheet()
	local frame = sheet
	if not frame then
		return
	end

	local picking = pickerIndex
	local taking = takeBackIndex
	frame.Visible = picking ~= nil or taking ~= nil
	showPickerBody(picking ~= nil)
	if picking then
		renderPicker(picking)
		return
	end
	if taking then
		renderTakeBack(taking)
	end
end

local function openPicker(index: number)
	cue("Click")
	pickerIndex = index
	takeBackIndex = nil
	-- A fresh gesture starts at the top of the list. A repaint driven by a
	-- sync deliberately does not — see rebuildPickerRows.
	local scroll = pickerScroll
	if scroll then
		scroll.CanvasPosition = Vector2.new(0, 0)
	end
	renderSheet()
end

local function openTakeBack(index: number)
	cue("Click")
	takeBackIndex = index
	pickerIndex = nil
	renderSheet()
end

function onCellTapped(index: number)
	if index > unlockedCount() then
		cue("Error") -- the BUY button is the only thing a locked pedestal does
		return
	end

	local mixling = placedAt(index)
	if mixling then
		openTakeBack(index)
		return
	end

	local pending = pendingPlaceId
	if pending then
		-- Armed by promptPlace. If the sync moved out from under us the id no
		-- longer resolves, and the picker is the honest fallback.
		if ClientState.mixlingById(pending) then
			sendPlace(pending, index)
			return
		end
		pendingPlaceId = nil
	end
	openPicker(index)
end

-- ── The lock, the shield and the header ──────────────────────────────────

--[[
	Lock state, entirely from the wire: `locked` and `lockEndsAt` come in the
	player's own DenSync row, and the recharge that follows is the same
	Constants.LOCK cooldown DenService.tryLock adds. Returns the state and the
	seconds left in it.
]]
local function lockState(): (string, number)
	local entry = myDen()
	if not entry then
		return "Waiting", 0
	end
	local now = os.time()
	if entry.locked and now < entry.lockEndsAt then
		return "Locked", entry.lockEndsAt - now
	end
	local tier = lockTier(view().lockLevel)
	local readyAt = entry.lockEndsAt + (if tier then tier.cooldown else 0)
	if now < readyAt then
		return "Cooling", readyAt - now
	end
	return "Ready", 0
end

local function renderLock()
	local button = lockButton
	local info = lockInfo
	if not button or not info then
		return
	end

	local state, remaining = lockState()
	if state == "Locked" then
		button.Text = "DOOR LOCKED · " .. Util.clock(remaining)
		button.BackgroundColor3 = UiKit.PALETTE.warn
		button.Interactable = false
		button.BackgroundTransparency = 0
	elseif state == "Cooling" then
		button.Text = "RECHARGING · " .. Util.clock(remaining)
		button.BackgroundColor3 = UiKit.PALETTE.panelSoft
		button.Interactable = false
		button.BackgroundTransparency = 0.25
	elseif state == "Waiting" then
		button.Text = "DEN LOADING"
		button.BackgroundColor3 = UiKit.PALETTE.panelSoft
		button.Interactable = false
		button.BackgroundTransparency = 0.25
	else
		button.Text = "LOCK THE DOOR"
		button.BackgroundColor3 = UiKit.PALETTE.accent
		button.Interactable = true
		button.BackgroundTransparency = 0
	end

	local level = view().lockLevel
	local tier = lockTier(level)
	if tier then
		info.Text = ("Lock level %d · holds %s · recharges %s"):format(
			level,
			Util.clock(tier.duration),
			Util.clock(tier.cooldown)
		)
	else
		info.Text = ("Lock level %d"):format(level)
	end
end

local function renderUpgrade()
	local row = upgradeRow
	local label = upgradeLabel
	local button = upgradeButton
	if not row or not label or not button then
		return
	end

	local offer = lockOffer
	local level = view().lockLevel
	local next_ = lockTier(level + 1)
	local price: number? = if offer and offer.price then offer.price else (if next_ then next_.price else nil)

	if not next_ or (offer and not offer.available) then
		label.Text = if offer and offer.reason then offer.reason else "Your door is already at the strongest lock."
		label.TextColor3 = UiKit.PALETTE.muted
		button.Visible = false
		return
	end

	label.Text = ("Level %d holds %s"):format(level + 1, Util.clock(next_.duration))
	label.TextColor3 = UiKit.PALETTE.text
	button.Visible = true
	button.Text = if isArmed("LockUpgrade")
		then "TAP AGAIN"
		else "UPGRADE · " .. Util.abbreviate(price or next_.price)
	button.BackgroundColor3 = if isArmed("LockUpgrade") then UiKit.PALETTE.warn else UiKit.PALETTE.goop
end

--[[
	GDD §8.3's five minutes. A new player who has not been told why nobody is
	robbing them learns the wrong lesson about this game, so the strip says it
	out loud and counts down to the moment it stops being true.
]]
local function renderShield()
	local strip = shieldStrip
	local label = shieldLabel
	if not strip or not label then
		return
	end
	local current = view()
	local remaining = current.shieldEndsAt - os.time()
	strip.Visible = current.shielded == true and remaining > 0
	if not strip.Visible then
		return
	end
	label.Text = ("NEW MIXER · nobody can take from your Den for %s"):format(Util.clock(remaining))
end

local function renderHeader()
	local rate = rateLabel
	local filled = filledLabel
	if not rate or not filled then
		return
	end

	local current = view()
	rate.Text = Util.abbreviate(current.goopPerSec) .. " Goop/sec"

	local unlocked = unlockedCount()
	local used = 0
	for index = 1, unlocked do
		if current.placed[tostring(index)] then
			used += 1
		end
	end
	filled.Text = ("%d of %d pedestals filled"):format(used, unlocked)
end

local function renderPrompt()
	local strip = promptStrip
	local label = promptLabel
	if not strip or not label then
		return
	end
	local pending = pendingPlaceId
	local mixling = if pending then ClientState.mixlingById(pending) else nil
	strip.Visible = mixling ~= nil
	if not mixling then
		return
	end
	label.Text = ("Tap a pedestal for %s"):format(mixling.displayName)
	label.TextColor3 = Rarity.color(mixling.rarity)
end

-- The countdown half of a render: cheap enough to run five times a second
-- while nothing else on the panel has changed.
local function renderClocks()
	renderLock()
	renderShield()
end

function render()
	local frame = panel
	if not frame or not frame.Visible then
		return -- a hidden panel is redrawn the moment it is shown again
	end
	renderPrompt()
	renderHeader()
	renderShield()
	renderLock()
	renderUpgrade()
	relayoutGrid()
	for _, cell in cells do
		paintCell(cell)
	end
	if sheet and sheet.Visible then
		renderSheet()
	end
end

-- ── Construction ─────────────────────────────────────────────────────────

local function buildLockBlock(parent: GuiObject, order: number)
	local block = UiKit.frame({
		BackgroundColor3 = UiKit.PALETTE.panelSoft,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Corner = 12,
		Padding = GAP,
		LayoutOrder = order,
		Parent = parent,
	})
	UiKit.list(block, { Padding = UDim.new(0, GAP) })

	local button = UiKit.button({
		Text = "LOCK THE DOOR",
		BackgroundColor3 = UiKit.PALETTE.accent,
		TextColor3 = UiKit.PALETTE.ink,
		Corner = 12,
		Size = UDim2.new(1, 0, 0, ROW + 6),
		LayoutOrder = 1,
		Parent = block,
	}, function()
		-- Guarded as well as greyed: `Interactable` is the look, and a tap
		-- that slipped through would only earn the server's own refusal.
		local state = lockState()
		if state ~= "Ready" then
			cue("Error")
			return
		end
		sendLock()
	end)
	textCeiling(button, 24)
	lockButton = button

	local info = UiKit.label({
		Text = "",
		TextColor3 = UiKit.PALETTE.muted,
		Font = UiKit.FONT_BODY,
		Size = UDim2.new(1, 0, 0, 20),
		TextWrapped = true,
		LayoutOrder = 2,
		Parent = block,
	})
	textCeiling(info, 14)
	lockInfo = info

	local row = UiKit.frame({
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, ROW),
		LayoutOrder = 3,
		Parent = block,
	})
	upgradeRow = row

	local label = UiKit.label({
		Text = "",
		TextColor3 = UiKit.PALETTE.text,
		Font = UiKit.FONT_BODY,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Size = UDim2.new(1, -150, 1, 0),
		Parent = row,
	})
	textCeiling(label, 15)
	upgradeLabel = label

	local upgrade = UiKit.button({
		Text = "",
		BackgroundColor3 = UiKit.PALETTE.goop,
		TextColor3 = UiKit.PALETTE.ink,
		Corner = 10,
		Size = UDim2.new(0, 142, 1, 0),
		Position = UDim2.fromScale(1, 0),
		AnchorPoint = Vector2.new(1, 0),
		Parent = row,
	}, function()
		local offer = lockOffer
		local next_ = lockTier(view().lockLevel + 1)
		local price: number? = if offer and offer.price then offer.price else (if next_ then next_.price else nil)
		local needsConfirm = if offer
			then offer.confirm
			else price ~= nil and price >= Constants.SHOP_CONFIRM_THRESHOLD
		offerTap("LockUpgrade", price, needsConfirm)
	end)
	textCeiling(upgrade, 18)
	upgradeButton = upgrade
end

local function buildSheet(parent: Frame)
	--[[
		An overlay inside the panel rather than a second ScreenGui: it must sit
		under HudController's CLOSE button, which lives in the stage at ZIndex
		20, so closing the whole Den panel is never blocked by a picker the
		player opened by accident.
	]]
	local frame = UiKit.frame({
		BackgroundColor3 = UiKit.PALETTE.panel,
		Size = UDim2.fromScale(1, 1),
		Corner = 16,
		ZIndex = 10,
		Visible = false,
		Parent = parent,
	})
	sheet = frame

	local title = UiKit.label({
		Text = "",
		TextColor3 = UiKit.PALETTE.accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -(PAD * 2 + CLOSE_RESERVE), 0, TITLE_HEIGHT),
		Position = UDim2.fromOffset(PAD, PAD),
		Parent = frame,
	})
	textCeiling(title, 26)
	sheetTitle = title

	local bodyTop = PAD + TITLE_HEIGHT + GAP
	local bodyDrop = -(PAD * 2 + TITLE_HEIGHT + GAP * 2 + ROW)

	local list = UiKit.scroll({
		Position = UDim2.fromOffset(PAD, bodyTop),
		Size = UDim2.new(1, -PAD * 2, 1, bodyDrop),
		Parent = frame,
	})
	UiKit.list(list, { Padding = UDim.new(0, GAP) })
	sheetList = list

	--[[
		The picker gets its own scroll rather than a mode of the one above: the
		take-back column is four rows packed by a UIListLayout, and a layout
		over the picker would repack the recycled rows and undo the recycling
		— the same reason MixdexController's grid places its tiles by offset.
	]]
	local picker = UiKit.scroll({
		-- Virtualised: the canvas is set from the row count and the rows are
		-- placed by offset, so AutomaticCanvasSize must be off or it would
		-- measure a canvas that only ever holds the visible slice.
		AutomaticCanvasSize = Enum.AutomaticSize.None,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		CanvasSize = UDim2.new(),
		Visible = false,
		Position = UDim2.fromOffset(PAD, bodyTop),
		Size = UDim2.new(1, -PAD * 2, 1, bodyDrop),
		Parent = frame,
	})
	pickerScroll = picker

	-- Inside the canvas, above every row: see PICKER_HEAD.
	local note = UiKit.label({
		Text = "",
		TextColor3 = UiKit.PALETTE.muted,
		Font = UiKit.FONT_BODY,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Size = UDim2.new(1, 0, 0, PICKER_NOTE),
		Position = UDim2.fromOffset(0, 0),
		Parent = picker,
	})
	textCeiling(note, 15)
	pickerNote = note

	--[[
		The window is capped at what the pool can serve, the way
		MixdexController caps the height of its grid: a very tall monitor must
		not be able to ask paintPicker for a row the pool has not got. Two
		rows come off the count first — the part-row at the bottom edge and
		the overscan one below it — because paintPicker asks for both.
	]]
	local ceiling = Instance.new("UISizeConstraint")
	ceiling.MaxSize = Vector2.new(math.huge, (MAX_PICKER_ROWS - PICKER_OVERSCAN - 1) * PICKER_STRIDE)
	ceiling.Parent = picker

	-- A flick repaints the slice that moved; a resize changes how big the
	-- slice is. Neither is a rebuild.
	picker:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		paintPicker(false)
	end)
	picker:GetPropertyChangedSignal("AbsoluteWindowSize"):Connect(function()
		paintPicker(false)
	end)

	local cancel = UiKit.button({
		Text = "BACK",
		BackgroundColor3 = UiKit.PALETTE.panelSoft,
		TextColor3 = UiKit.PALETTE.text,
		Corner = 12,
		Size = UDim2.new(1, -PAD * 2, 0, ROW),
		Position = UDim2.new(0.5, 0, 1, -PAD),
		AnchorPoint = Vector2.new(0.5, 1),
		Parent = frame,
	}, function()
		cue("Click")
		closeSheet()
	end)
	textCeiling(cancel, 22)
end

local function buildPanel(): Frame
	local frame = UiKit.frame({
		BackgroundColor3 = UiKit.PALETTE.panel,
		Corner = 16,
		Stroke = UiKit.PALETTE.stroke,
	})

	local heading = UiKit.label({
		Text = "MY DEN",
		TextColor3 = UiKit.PALETTE.accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -(PAD * 2 + CLOSE_RESERVE), 0, TITLE_HEIGHT),
		Position = UDim2.fromOffset(PAD, PAD),
		Parent = frame,
	})
	textCeiling(heading, 28)

	local scroll = UiKit.scroll({
		Position = UDim2.fromOffset(PAD, PAD + TITLE_HEIGHT + GAP),
		Size = UDim2.new(1, -PAD * 2, 1, -(PAD * 2 + TITLE_HEIGHT + GAP)),
		Parent = frame,
	})
	UiKit.list(scroll, { Padding = UDim.new(0, GAP) })

	-- Placement prompt. LayoutOrder 1 so an armed panel says what it is
	-- waiting for above everything else on the screen.
	local prompt = UiKit.frame({
		BackgroundColor3 = UiKit.PALETTE.ink,
		Size = UDim2.new(1, 0, 0, ROW),
		Corner = 10,
		Padding = 6,
		LayoutOrder = 1,
		Visible = false,
		Parent = scroll,
	})
	promptStrip = prompt

	local promptText = UiKit.label({
		Text = "",
		TextColor3 = UiKit.PALETTE.accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Size = UDim2.new(1, -110, 1, 0),
		Parent = prompt,
	})
	textCeiling(promptText, 17)
	promptLabel = promptText

	local cancelPlace = UiKit.button({
		Text = "CANCEL",
		BackgroundColor3 = UiKit.PALETTE.panelSoft,
		TextColor3 = UiKit.PALETTE.text,
		Corner = 8,
		Size = UDim2.new(0, 100, 1, 0),
		Position = UDim2.fromScale(1, 0.5),
		AnchorPoint = Vector2.new(1, 0.5),
		Parent = prompt,
	}, function()
		cue("Click")
		pendingPlaceId = nil
		render()
	end)
	textCeiling(cancelPlace, 16)

	-- The number the player came here to grow (GDD §8.2, §10).
	local readout = UiKit.frame({
		BackgroundColor3 = UiKit.PALETTE.ink,
		Size = UDim2.new(1, 0, 0, 62),
		Corner = 12,
		Padding = 6,
		LayoutOrder = 2,
		Parent = scroll,
	})

	local rate = UiKit.label({
		Text = "0 Goop/sec",
		TextColor3 = UiKit.PALETTE.goop,
		Size = UDim2.new(1, 0, 0, 32),
		Parent = readout,
	})
	textCeiling(rate, 30)
	rateLabel = rate

	local filled = UiKit.label({
		Text = "",
		TextColor3 = UiKit.PALETTE.muted,
		Font = UiKit.FONT_BODY,
		Size = UDim2.new(1, 0, 0, 18),
		Position = UDim2.fromOffset(0, 32),
		Parent = readout,
	})
	textCeiling(filled, 14)
	filledLabel = filled

	local shield = UiKit.frame({
		BackgroundColor3 = UiKit.PALETTE.ink,
		Size = UDim2.new(1, 0, 0, 34),
		Corner = 10,
		Padding = 4,
		LayoutOrder = 3,
		Visible = false,
		Parent = scroll,
	})
	shieldStrip = shield

	local shieldText = UiKit.label({
		Text = "",
		TextColor3 = UiKit.PALETTE.warn,
		Font = UiKit.FONT_BODY,
		TextWrapped = true,
		Size = UDim2.fromScale(1, 1),
		Parent = shield,
	})
	textCeiling(shieldText, 15)
	shieldLabel = shieldText

	buildLockBlock(scroll, 4)

	local holder = UiKit.frame({
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 5,
		Parent = scroll,
	})
	gridHolder = holder
	gridLayout = UiKit.grid(holder, UDim2.fromOffset(CELL_MIN, math.floor(CELL_MIN * CELL_ASPECT)), UDim2.fromOffset(GAP, GAP))

	for index = 1, Constants.WORLD.PEDESTAL_COUNT do
		local cell = buildCell(index)
		cell.button.Parent = holder
		table.insert(cells, cell)
	end

	holder:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayoutGrid)

	buildSheet(frame)
	return frame
end

-- ── Registry API ─────────────────────────────────────────────────────────

function DenUIController.open()
	if hud then
		hud.openPanel(PANEL_NAME)
	end
end

function DenUIController.close()
	if hud then
		hud.closePanel(PANEL_NAME)
	end
end

--[[
	MixerUIController's result card sends a fresh roll here when the Den is
	full or the player asked to choose a pedestal. The Mixling is remembered,
	not placed: the next empty pedestal tapped gets it, which keeps the choice
	in the player's hands and this file down to one intent per gesture.
]]
function DenUIController.promptPlace(mixlingId: string)
	if type(mixlingId) ~= "string" or mixlingId == "" then
		return
	end
	pendingPlaceId = mixlingId
	closeSheet()
	DenUIController.open()
	render()
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

function DenUIController.init(controllers: { [string]: any })
	hud = controllers.HudController
	sound = controllers.SoundController
end

function DenUIController.start()
	local frame = buildPanel()
	panel = frame

	if hud then
		hud.registerPanel(PANEL_NAME, frame)
	else
		warn("[DenUI] no HudController; the Den panel has nowhere to live")
	end

	--[[
		The HUD's cluster button opens this panel directly, without going
		through open(), so the panel repaints off its own visibility rather
		than off the call that showed it. It also drops any half-finished
		gesture on the way out: a picker left open behind a closed panel is a
		tap the player does not remember making.
	]]
	frame:GetPropertyChangedSignal("Visible"):Connect(function()
		if not frame.Visible then
			disarm()
			closeSheet()
			return
		end
		lastGridWidth = 0 -- the stage resizes while hidden; re-measure on show
		refreshOffers()
		render()
	end)

	local WATCHED = {
		placed = true,
		mixlings = true,
		denSlots = true,
		lockLevel = true,
		passes = true,
		goopPerSec = true,
		shielded = true,
		shieldEndsAt = true,
		settings = true,
	}
	local REPRICED = { denSlots = true, lockLevel = true, passes = true }

	ClientState.changed:connect(function(keys: any)
		if type(keys) ~= "table" then
			return
		end
		local changed = keys :: { string }
		if keysInclude(changed, REPRICED) then
			refreshOffers()
		end
		if keysInclude(changed, WATCHED) then
			render()
		end
	end)

	-- Lock state is public (every Den's door shows a countdown from the
	-- street, GDD §8.3), so it arrives on the same broadcast the nameplates
	-- read rather than in this player's private profile.
	Net.event("DenSync").OnClientEvent:Connect(function(rows: any)
		if type(rows) ~= "table" then
			return
		end
		denRows = rows :: { DenPublic }
		render()
	end)

	RunService.Heartbeat:Connect(function(dt: number)
		if not frame.Visible then
			return
		end

		if not lowFx() then
			spinAngle += dt * SPIN_SPEED
			local pivot = CFrame.Angles(0, spinAngle, 0)
			for _, cell in cells do
				local model = cell.model
				if model then
					model:PivotTo(pivot)
				end
			end
		end

		tickAccumulator += dt
		if tickAccumulator < TICK_INTERVAL then
			return
		end
		tickAccumulator = 0
		renderClocks()
		-- A lapsed confirmation has to un-say "TAP AGAIN" on its own; nothing
		-- else on the panel is going to change to trigger the repaint.
		if armedKey and os.clock() >= armedUntil then
			disarm()
			render()
		end
	end)

	-- One pull each so a player who joined between broadcasts sees a real
	-- door and a real price instead of an empty panel.
	refreshDenRows()
	refreshOffers()
end

return DenUIController
