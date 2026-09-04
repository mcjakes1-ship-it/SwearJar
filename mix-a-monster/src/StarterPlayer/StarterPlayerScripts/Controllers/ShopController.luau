--!strict
--[[
	ShopController.luau — the Critter Pen and the Stuff Shack.
	GDD §5 (the 30 s "buy an ingredient" step), §6 (the two stalls), §7.2
	(the ingredient tables), §8.6 (the shelf), §10 (mobile-first), §12 (the
	Weekly Drop).

	THE REGISTRY API. The stall prompts, the HUD and TutorialController reach
	this screen through these and never through a remote:

	    open(kind)   -- "Critter" | "Stuff"; selects that shelf, then opens
	    close()

	ONE PANEL, TWO SHELVES. HudController allows exactly one panel at a time
	and its cluster has a single SHOP button, so both stalls live in one
	registered panel behind a two-tab header. A prompt at the Critter Pen
	opens it on the Critter tab; the HUD button opens it wherever the player
	left it, with the other shelf one tap away. Two registered panels would
	give the HUD one button that could only ever reach one of them.

	PRICES COME FROM THE SHARED TABLE, NOT FROM A ROUND TRIP.
	`Ingredients.catalogue(kind)` is the same frozen list `ShopService.
	priceFor` charges from, already ordered by tier and then price the way
	GDD §8.6 asks, so the shelf renders the server's own numbers with no
	query and no cache to go stale. PlayerService does expose the same figures
	through Query("ShopPrices"); reading the table directly means a row is
	never a round trip behind the purchase that just changed it. The client
	still decides nothing: it never deducts Goop, never marks a row sold, and
	an "Owned: n" only moves when a ProfileSync says so (ARCHITECTURE §7.1).

	AN UNAFFORDABLE ROW IS STILL A BUTTON. It greys and it says how much is
	missing, but it fires like any other row, because the server's refusal
	("Not enough Goop", toasted by AlertController) teaches the price far
	better than a control that does nothing. A dead button reads as a broken
	shop; a refusal reads as a goal.

	THE CONFIRMATION DIALOG IS A CLIENT COURTESY AND NOTHING MORE. GDD §8.6
	asks for a confirm step at or above Constants.SHOP_CONFIRM_THRESHOLD, and
	ShopService's header is explicit that there is NO two-step handshake on
	the server: the same RequestPurchase goes out whether the player confirmed
	or not, and the same price is charged either way. It guards a mis-tap on a
	phone, never an exploiter — who would simply skip the half that is drawn
	here. So this file must never treat the dialog as permission for anything.

	THE PREVIEW IS ALWAYS A PAIR, AND ALWAYS COMMON. A Mixling is a pair by
	definition (GDD §7.1) and MixlingAssembler has no single-ingredient mode,
	so every row is drawn wearing the STARTER partner from Constants.STARTER —
	a Stuff row rides the starter Critter so it reads as a creature part, a
	Critter row wears the starter Stuff. The starter pair is the one pair no
	shelf ever sells (Ingredients.isPurchasable rejects it, DECISIONS D15), so
	the partner can never be mistaken for the goods. The rarity is pinned to
	Common because a shelf that showed a Legendary sheen would be the client
	promising an outcome the roll has not produced yet. The ingredient's own
	colour sits behind the model as a swatch, which is what a Stuff row still
	reads as when no art has landed.

	VIEWPORTS ARE RECYCLED, NOT ISSUED PER ROW. Fifteen ViewportFrames each
	holding an assembled model is a phone-killing shelf. The list is
	virtualised: the canvas is sized for every entry, but only the rows that
	fit on screen exist, they are repositioned and rebound as the canvas
	scrolls, and a model is rebuilt only when the name in a row actually
	changes. Closing the panel releases the models entirely.

	SUCCESS IS OBSERVED, NEVER ASSUMED. The "Purchase" cue plays when the
	inventory count for the thing just tapped RISES in a ProfileSync. Playing
	it on the tap would reward a refusal with a happy noise, which is the
	client claiming an outcome (ARCHITECTURE §7.1).
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
local UiKit = require(Shared:WaitForChild("UiKit"))
local Util = require(Shared:WaitForChild("Util"))

local ClientState = require(script.Parent.Parent:WaitForChild("ClientState"))

type Ingredient = Ingredients.Ingredient

local ShopController = {}
ShopController.Name = "ShopController"

-- ── Wire vocabulary ──────────────────────────────────────────────────────
-- ShopService's `kind` strings and HudController's panel name. Protocol
-- labels, not balance values, so none of them belong in Constants.

local PANEL_NAME = "Shop" -- the name the HUD's SHOP button opens
local PURCHASE_KIND = "Ingredient" -- RequestPurchase(kind, id)

-- ── Local tunables ───────────────────────────────────────────────────────
--[[
	Presentation only. Everything the player earns, spends or waits for lives
	in Constants (GDD §17, ARCHITECTURE §7.2) — the confirm threshold and
	every price on this shelf come from there and from Ingredients. How many
	pixels a row is has never been a balance question.
]]

local TOUCH = UiKit.TOUCH_MIN
local PAD = 10
local GAP = 8

local TAB_HEIGHT = TOUCH + 2
--[[
	The host's own CLOSE button is a child of the stage, not of this panel,
	and sits 88px wide in the stage's top-right corner. The tab row gives that
	corner back rather than drawing tabs underneath a button it does not own.
]]
local CLOSE_CLEAR = 96

local ROW_TALL = 84
local ROW_COMPACT = 58 -- still above UiKit's 44px floor; a squeezed row, never a dead one
local COMPACT_BELOW = 220 -- a stage shorter than this gets compact rows
local ROW_GAP = 6
local ROW_INSET = 12 -- room for the scrollbar so it never sits on a price
local ART_PAD = 6
local ART_GAP = 10
local MIDDLE_SHARE = 0.66 -- name / tier / owned column, as a share of row width
local RIGHT_SHARE = 0.30 -- price column
local POOL_MAX = 24 -- ceiling on live ViewportFrames, whatever a monitor claims

local DIM_TRANSPARENCY = 0.55 -- how far an unaffordable row fades
local TAB_DIM = 0.45
local ROW_SPIN_SPEED = 0.6 -- radians/sec; GDD §6 wants the shelf models alive
local FLASH_SECONDS = 0.9 -- how long a bought row says so

--[[
	How long a tap stays interested in its own outcome. A purchase answers
	within a sync or two; past this the tap is assumed refused and the cue is
	dropped, so an inventory rise from somewhere else entirely (a code, a
	daily) can never borrow the shop's noise.
]]
local PURCHASE_ECHO_SECONDS = 6

local PROMPT_DISTANCE = 12
local STAR = "★"
local ROW_STARS = 6 -- the luck cap a row can draw before it spells the rest

-- The preview's tier. See the header: a shelf may not imply a roll.
local PREVIEW_RARITY = Rarity.COMMON

type Stall = { tag: string, kind: string, label: string, object: string }

-- WorldService tags one trigger part per stall (GDD §6); the tag is the
-- whole contract between that service and this screen.
local STALLS: { Stall } = {
	{ tag = "Shop_Critter", kind = "Critter", label = "CRITTER PEN", object = "Critter Pen" },
	{ tag = "Shop_Stuff", kind = "Stuff", label = "STUFF SHACK", object = "Stuff Shack" },
}

-- ── Siblings, captured from the registry ─────────────────────────────────

local hud: any = nil
local sound: any = nil

-- ── State ────────────────────────────────────────────────────────────────

type Row = {
	button: TextButton,
	stroke: UIStroke, -- the Weekly Drop highlight
	art: Frame, -- the ingredient's colour swatch, behind the model
	artStroke: UIStroke, -- tier colour
	setModel: (Model?) -> (),
	model: Model?,
	nameLabel: TextLabel,
	metaLabel: TextLabel,
	ownedLabel: TextLabel,
	priceLabel: TextLabel,
	statusLabel: TextLabel,
	middle: Frame,
	bound: string?, -- the ingredient currently drawn, so a rebind can skip static work
	item: Ingredient?,
}

local kind = "Critter" -- the shelf on screen; remembered across opens
local entries: { Ingredient } = {}
local featured: string? = nil -- the Weekly Drop, pinned to the front

local rows: { Row } = {}
local poolActive = 0
local firstIndex = 0 -- entry index bound to rows[1]; 0 forces the first bind
local rowHeightNow = ROW_TALL

local prompts: { [BasePart]: ProximityPrompt } = {}

local pending: { name: string, before: number, at: number }? = nil
local flashName: string? = nil
local flashUntil = 0

local spinConnection: RBXScriptConnection? = nil
local spinAngle = 0

-- ── Widgets, built once in start() ───────────────────────────────────────

local panel: Frame
local scroll: ScrollingFrame
local emptyLabel: TextLabel
local tabs: { [string]: TextButton } = {}

local dialog: Frame
local dialogName: TextLabel
local dialogPrice: TextLabel
local dialogTarget: Ingredient? = nil

local uiReady = false

-- ── Small helpers ────────────────────────────────────────────────────────

--[[
	UiKit.label and UiKit.button each attach a UITextSizeConstraint and read
	its ceiling from a `MaxTextSize` prop — but applyCommon assigns every prop
	it does not recognise straight onto the instance, and `MaxTextSize` is not
	a member of a TextLabel, so passing it throws. Reaching for the constraint
	the kit already made is the way to raise a ceiling without editing UiKit.
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

local function ownedCount(name: string): number
	local count = ClientState.get().inventory[name]
	return if type(count) == "number" then count else 0
end

--[[
	The balance the shelf greys against is the last SYNCED one, never
	ClientState.interpolatedGoop(). The interpolation is a HUD rendering trick
	that runs ahead of the server between ticks (GDD §8.2); a row lit by it
	would flicker affordable a second before the server agreed, and the
	refusal that followed would look like a bug rather than a price.
]]
local function syncedGoop(): number
	local goop = ClientState.get().goop
	return if type(goop) == "number" and goop == goop then goop else 0
end

local function starText(luck: number): string
	if luck <= 0 then
		return ""
	end
	local shown = math.min(luck, ROW_STARS)
	local text = string.rep(STAR, shown)
	if luck > shown then
		text ..= " +" .. tostring(luck - shown)
	end
	return text
end

local function panelVisible(): boolean
	return uiReady and panel.Visible
end

local function stride(): number
	return rowHeightNow + ROW_GAP
end

--[[
	One shelf model. See the header for why it is a pair and why it is always
	Common; the sound is left off because a shelf of chirping ingredients is
	the cacophony GDD §7.5 throttles elsewhere, and lowFx is honoured because
	this is the one screen that can have half a dozen models on it at once.
]]
local function buildPreview(item: Ingredient): Model
	local starter = Constants.STARTER
	return Assembler.buildDisplay({
		critter = if item.kind == "Critter" then item.name else starter.critter,
		stuff = if item.kind == "Stuff" then item.name else starter.stuff,
		rarity = PREVIEW_RARITY,
		withSound = false,
		lowFx = ClientState.get().settings.lowFx == true,
	}, CFrame.new())
end

-- ── The shelf ────────────────────────────────────────────────────────────

--[[
	Ingredients.catalogue already drops the starter grant and orders by tier
	then price exactly as GDD §8.6 asks, so the only thing left is the Weekly
	Drop: the newest row of this kind, MOVED to the front rather than copied
	there. A second copy would carry its own "Owned: n" and drift from the
	real one the moment a purchase landed (ShopService's shelf() says the same
	from the server's side). Deriving "newest" from the end of the table is
	what makes a weekly drop a one-line edit to Ingredients.luau and no UI
	work at all (GDD §12).
]]
local function rebuildEntries()
	local list = Ingredients.catalogue(kind)
	local newest = Ingredients.newest(kind)
	featured = if newest and Ingredients.isPurchasable(newest.name) then newest.name else nil

	entries = {}
	local pin = featured
	if pin then
		for index, item in list do
			if item.name == pin then
				table.insert(entries, item)
				table.remove(list, index)
				break
			end
		end
	end
	for _, item in list do
		table.insert(entries, item)
	end
end

-- Everything about a row that only changes when the row changes ingredient.
local function drawStatic(row: Row, item: Ingredient)
	local tint = Rarity.color(item.tier)

	row.nameLabel.Text = string.upper(item.name)
	row.metaLabel.Text = ("TIER %d  %s"):format(item.tier, starText(item.luck))
	row.metaLabel.TextColor3 = tint
	row.art.BackgroundColor3 = item.color
	row.artStroke.Color = tint
	row.stroke.Transparency = if item.name == featured then 0 else 1

	row.model = buildPreview(item)
	row.setModel(row.model)
end

-- Everything a ProfileSync can move: what the player owns and what they can
-- afford. Both are read from the cache; neither is computed here.
local function drawDynamic(row: Row, item: Ingredient)
	local owned = ownedCount(item.name)
	local goop = syncedGoop()
	local affordable = goop >= item.price

	if item.name == featured then
		row.ownedLabel.Text = ("%s WEEKLY DROP  ·  Owned: %d"):format(STAR, owned)
		row.ownedLabel.TextColor3 = UiKit.PALETTE.warn
	else
		row.ownedLabel.Text = ("Owned: %d"):format(owned)
		row.ownedLabel.TextColor3 = UiKit.PALETTE.muted
	end

	--[[
		Transparency, never colour. UiKit.button captures its BackgroundColor3
		at construction to drive the press tween, so recolouring a row here
		would leave that tween restoring the bright colour under the player's
		finger the moment they touched it.
	]]
	row.button.BackgroundTransparency = if affordable then 0 else DIM_TRANSPARENCY
	row.nameLabel.TextColor3 = if affordable then UiKit.PALETTE.text else UiKit.PALETTE.muted
	row.priceLabel.TextColor3 = if affordable then UiKit.PALETTE.goop else UiKit.PALETTE.muted

	if flashName == item.name and os.clock() < flashUntil then
		-- The server said yes. Hold the receipt over the price for a beat.
		row.priceLabel.Text = "BOUGHT!"
		row.priceLabel.TextColor3 = UiKit.PALETTE.ok
		row.statusLabel.Text = ""
		return
	end

	row.priceLabel.Text = ("%s Goop"):format(Util.abbreviate(item.price))
	if affordable then
		row.statusLabel.Text = ""
		return
	end
	-- A shortfall, not a price: both halves came from the server (the frozen
	-- table it charges from, and the balance it last synced).
	row.statusLabel.Text = ("NEED %s MORE"):format(Util.abbreviate(item.price - goop))
	row.statusLabel.TextColor3 = UiKit.PALETTE.danger
end

-- ── Buying ───────────────────────────────────────────────────────────────

local function closeDialog()
	dialogTarget = nil
	if uiReady then
		dialog.Visible = false
	end
end

--[[
	The whole of a purchase from this client's side: an intent, and then a
	wait. Nothing is deducted, nothing is marked owned, and the row does not
	move until a ProfileSync moves it.
]]
local function requestPurchase(item: Ingredient)
	pending = { name = item.name, before = ownedCount(item.name), at = os.clock() }
	Net.event("RequestPurchase"):FireServer(PURCHASE_KIND, item.name)
end

local function openDialog(item: Ingredient)
	dialogTarget = item
	dialogName.Text = string.upper(item.name)
	dialogName.TextColor3 = Rarity.color(item.tier)
	dialogPrice.Text = ("%s Goop"):format(Util.abbreviate(item.price))
	dialog.Visible = true
	UiKit.pop(dialog, 0.06)
end

local function tapRow(row: Row)
	local item = row.item
	if not item then
		return
	end
	cue("Click")
	--[[
		GDD §8.6: instant under the threshold, a confirm at or above it. The
		threshold is Constants' and the price is Ingredients' — this file owns
		neither, and the server charges the same either way (see the header).
	]]
	if item.price >= Constants.SHOP_CONFIRM_THRESHOLD then
		openDialog(item)
		return
	end
	requestPurchase(item)
end

-- ── Rows ─────────────────────────────────────────────────────────────────

local function applyGeometry(row: Row)
	local height = rowHeightNow
	local art = height - ART_PAD * 2
	local left = ART_PAD + art + ART_GAP

	row.button.Size = UDim2.new(1, -ROW_INSET, 0, height)
	row.art.Position = UDim2.fromOffset(ART_PAD, ART_PAD)
	row.art.Size = UDim2.fromOffset(art, art)
	row.middle.Position = UDim2.new(0, left, 0, 4)
	row.middle.Size = UDim2.new(MIDDLE_SHARE, -left, 1, -8)
end

--[[
	One recycled shelf row. Every child is sized in scale against the row, so
	the same widget reads at 84px on a tablet and at 58px on a landscape phone
	with no second layout to keep in step.
]]
local function createRow(): Row
	local row: Row

	local button = UiKit.button({
		Parent = scroll,
		BackgroundColor3 = UiKit.PALETTE.panelSoft,
		Text = "",
		Corner = 14,
		Visible = false,
		ZIndex = 2,
	}, function()
		tapRow(row)
	end)

	local highlight = Instance.new("UIStroke")
	highlight.Color = UiKit.PALETTE.warn
	highlight.Thickness = 3
	highlight.Transparency = 1
	highlight.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	highlight.Parent = button

	--[[
		The swatch AND the frame the model sits in. Its background is the
		ingredient's own colour, which is what a Stuff row still reads as
		before any art has landed (GDD §8.6 wants the model; ARCHITECTURE §6
		says the model may not exist yet). Clipped, because a UICorner rounds
		the frame but does not round the square ViewportFrame inside it.
	]]
	local art = UiKit.frame({
		Parent = button,
		BackgroundColor3 = UiKit.PALETTE.ink,
		Corner = 12,
		ClipsDescendants = true,
		ZIndex = 3,
	})
	local artStroke = Instance.new("UIStroke")
	artStroke.Color = UiKit.PALETTE.stroke
	artStroke.Thickness = 2
	artStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	artStroke.Parent = art

	local _, setModel = UiKit.viewport({
		Parent = art,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 4,
	})

	local middle = UiKit.frame({
		Parent = button,
		BackgroundTransparency = 1,
		ZIndex = 3,
	})
	local nameLabel = UiKit.label({
		Parent = middle,
		Size = UDim2.fromScale(1, 0.40),
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 4,
	})
	local metaLabel = UiKit.label({
		Parent = middle,
		Position = UDim2.fromScale(0, 0.40),
		Size = UDim2.fromScale(1, 0.30),
		Text = "",
		TextColor3 = UiKit.PALETTE.muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 4,
	})
	local ownedLabel = UiKit.label({
		Parent = middle,
		Position = UDim2.fromScale(0, 0.70),
		Size = UDim2.fromScale(1, 0.30),
		Text = "",
		TextColor3 = UiKit.PALETTE.muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 4,
	})
	textCeiling(metaLabel, 20)
	textCeiling(ownedLabel, 18)

	local right = UiKit.frame({
		Parent = button,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -PAD, 0.5, 0),
		Size = UDim2.new(RIGHT_SHARE, -PAD, 1, -8),
		BackgroundTransparency = 1,
		ZIndex = 3,
	})
	local priceLabel = UiKit.label({
		Parent = right,
		Position = UDim2.fromScale(0, 0.10),
		Size = UDim2.fromScale(1, 0.44),
		Text = "",
		TextColor3 = UiKit.PALETTE.goop,
		TextXAlignment = Enum.TextXAlignment.Right,
		ZIndex = 4,
	})
	local statusLabel = UiKit.label({
		Parent = right,
		Position = UDim2.fromScale(0, 0.56),
		Size = UDim2.fromScale(1, 0.34),
		Text = "",
		TextColor3 = UiKit.PALETTE.danger,
		TextXAlignment = Enum.TextXAlignment.Right,
		ZIndex = 4,
	})
	textCeiling(priceLabel, 26)
	textCeiling(statusLabel, 16)

	row = {
		button = button,
		stroke = highlight,
		art = art,
		artStroke = artStroke,
		setModel = setModel,
		model = nil,
		nameLabel = nameLabel,
		metaLabel = metaLabel,
		ownedLabel = ownedLabel,
		priceLabel = priceLabel,
		statusLabel = statusLabel,
		middle = middle,
		bound = nil,
		item = nil,
	}
	applyGeometry(row)
	return row
end

-- Frees a row's model. Called when a row leaves the pool and when the panel
-- closes: a shut shop must not keep half a dozen assembled models resident.
local function releaseRow(row: Row)
	row.setModel(nil)
	row.model = nil
	row.bound = nil
	row.item = nil
	row.button.Visible = false
end

local function bindRow(row: Row, index: number)
	local item = entries[index]
	if not item then
		releaseRow(row)
		return
	end

	row.item = item
	row.button.Visible = true
	row.button.Position = UDim2.fromOffset(0, (index - 1) * stride())

	if row.bound ~= item.name then
		row.bound = item.name
		drawStatic(row, item)
	end
	drawDynamic(row, item)
end

--[[
	The virtualiser. `first` is the entry sitting in rows[1]; every visible
	row is that plus its slot. Rebinding is skipped when the window has not
	moved, so dragging the list a few pixels does not rebuild a single model.
]]
local function bindWindow(force: boolean)
	local total = #entries
	local first = 1
	if total > 0 then
		local top = math.floor(scroll.CanvasPosition.Y / stride()) + 1
		first = math.clamp(top, 1, math.max(1, total - poolActive + 1))
	end
	if first == firstIndex and not force then
		return
	end
	firstIndex = first

	for slot = 1, poolActive do
		bindRow(rows[slot], first + slot - 1)
	end
	for slot = poolActive + 1, #rows do
		releaseRow(rows[slot])
	end
end

local function refreshDynamic()
	for slot = 1, poolActive do
		local row = rows[slot]
		local item = row.item
		if item then
			drawDynamic(row, item)
		end
	end
end

--[[
	Sizes the canvas for the whole shelf and the pool for the screen. Row
	height drops on a short stage — HudController hands a 640x360 window a
	stage barely a few rows tall, and a squeezed row that still clears UiKit's
	44px touch floor beats a perfect row nobody can reach.
]]
local function layout()
	if not uiReady then
		return
	end

	local height = scroll.AbsoluteSize.Y
	local wanted = if height > 0 and height < COMPACT_BELOW then ROW_COMPACT else ROW_TALL
	local resized = wanted ~= rowHeightNow
	rowHeightNow = wanted
	if resized then
		for _, row in rows do
			applyGeometry(row)
		end
	end

	local total = #entries
	scroll.CanvasSize = UDim2.fromOffset(0, math.max(0, total * stride() - ROW_GAP))
	emptyLabel.Visible = total == 0

	local usable = if height > 0 then height else rowHeightNow * 2
	local fits = math.ceil(usable / stride()) + 1
	poolActive = math.clamp(math.min(fits, math.max(total, 1)), 1, POOL_MAX)
	while #rows < poolActive do
		table.insert(rows, createRow())
	end

	bindWindow(true)
end

local function selectKind(next: string)
	-- A shelf swap, not a re-tap of the tab already showing: rebuilding on
	-- every tap would throw away a dozen assembled models and yank the list
	-- back to the top under a player who was only steadying their thumb.
	local swapped = next ~= kind or #entries == 0
	kind = next

	for tabKind, button in tabs do
		local on = tabKind == next
		button.BackgroundTransparency = if on then 0 else TAB_DIM
		button.TextColor3 = if on then UiKit.PALETTE.text else UiKit.PALETTE.muted
	end
	if not swapped then
		return
	end

	rebuildEntries()
	-- A new shelf starts at its Weekly Drop, not at wherever the other one
	-- happened to be scrolled to.
	scroll.CanvasPosition = Vector2.zero
	for _, row in rows do
		row.bound = nil -- the entry list moved under every slot
	end
	layout()
end

-- ── The purchase echo ────────────────────────────────────────────────────

--[[
	The only place this file concludes a purchase happened, and it concludes
	it from the profile: the count for the tapped ingredient went up in a
	sync. A refusal simply never satisfies this and times out silently, which
	is correct — AlertController already toasted the server's reason.
]]
local function onInventorySynced()
	local watch = pending
	if not watch then
		return
	end
	if os.clock() - watch.at > PURCHASE_ECHO_SECONDS then
		pending = nil
		return
	end
	if ownedCount(watch.name) <= watch.before then
		return
	end

	pending = nil
	cue("Purchase")
	flashName = watch.name
	flashUntil = os.clock() + FLASH_SECONDS
	task.delay(FLASH_SECONDS, function()
		if flashName ~= watch.name then
			return
		end
		flashName = nil
		if panelVisible() then
			refreshDynamic()
		end
	end)
end

-- ── The shelf's idle spin (GDD §6) ───────────────────────────────────────

local function stopSpin()
	local connection = spinConnection
	spinConnection = nil
	if connection then
		connection:Disconnect()
	end
end

--[[
	One connection for the whole shelf rather than one per row, and none at
	all under the lowFx setting — this is the screen most likely to be open on
	the weakest phone in the server.
]]
local function startSpin()
	stopSpin()
	if ClientState.get().settings.lowFx == true then
		return
	end
	spinConnection = RunService.RenderStepped:Connect(function(delta: number)
		spinAngle += delta * ROW_SPIN_SPEED
		local turn = CFrame.Angles(0, spinAngle, 0)
		for slot = 1, poolActive do
			local model = rows[slot].model
			if model and model.Parent then
				model:PivotTo(turn)
			end
		end
	end)
end

-- ── Panel construction ───────────────────────────────────────────────────

local function buildDialog(parent: Frame)
	--[[
		Full-panel and Active: a plain Frame does not sink input, so a shelf
		row underneath an inert dialog would still take the tap that was aimed
		at CANCEL. Sizing it to the whole panel is also what makes it legible
		on the short stage a phone gets — a centred card there has no room for
		a message and two 44px buttons.
	]]
	dialog = UiKit.frame({
		Parent = parent,
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = UiKit.PALETTE.panel,
		Corner = 16,
		Stroke = UiKit.PALETTE.warn,
		Padding = PAD,
		Active = true,
		Visible = false,
		ZIndex = 20,
	})

	local text = UiKit.frame({
		Parent = dialog,
		Size = UDim2.new(1, 0, 1, -(TAB_HEIGHT + GAP)),
		BackgroundTransparency = 1,
		ZIndex = 21,
	})
	UiKit.label({
		Parent = text,
		Size = UDim2.fromScale(1, 0.26),
		Text = "CONFIRM PURCHASE",
		TextColor3 = UiKit.PALETTE.warn,
		ZIndex = 22,
	})
	dialogName = UiKit.label({
		Parent = text,
		Position = UDim2.fromScale(0, 0.26),
		Size = UDim2.fromScale(1, 0.40),
		Text = "",
		ZIndex = 22,
	})
	dialogPrice = UiKit.label({
		Parent = text,
		Position = UDim2.fromScale(0, 0.66),
		Size = UDim2.fromScale(1, 0.34),
		Text = "",
		TextColor3 = UiKit.PALETTE.goop,
		ZIndex = 22,
	})

	local buttons = UiKit.frame({
		Parent = dialog,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, TAB_HEIGHT),
		BackgroundTransparency = 1,
		ZIndex = 21,
	})
	UiKit.button({
		Parent = buttons,
		Size = UDim2.new(0.48, 0, 1, 0),
		BackgroundColor3 = UiKit.PALETTE.panelSoft,
		TextColor3 = UiKit.PALETTE.text,
		Text = "CANCEL",
		Corner = 12,
		ZIndex = 22,
	}, function()
		cue("Click")
		closeDialog()
	end)
	UiKit.button({
		Parent = buttons,
		Position = UDim2.fromScale(0.52, 0),
		Size = UDim2.new(0.48, 0, 1, 0),
		BackgroundColor3 = UiKit.PALETTE.goop,
		Text = "BUY",
		Corner = 12,
		ZIndex = 22,
	}, function()
		local item = dialogTarget
		closeDialog()
		if item then
			requestPurchase(item)
		end
	end)
end

local function buildPanel(): Frame
	-- Left at UiKit's default size so the host's stage decides the geometry;
	-- registerPanel fills the stage with a frame that asked for nothing else.
	local frame = UiKit.frame({
		BackgroundColor3 = UiKit.PALETTE.panel,
		Corner = 18,
		Stroke = UiKit.PALETTE.stroke,
		Padding = PAD,
		-- Hidden from the first frame, whether or not a host ever takes it:
		-- panelVisible() gates the repaints, the spin and the stall prompts,
		-- and a panel that started life visible would arm all three.
		Visible = false,
	})
	panel = frame

	--[[
		The two shelves are the header: their labels are the only titles this
		screen needs, and putting them on one row instead of under a title bar
		buys back a whole row of a phone's very short stage.
	]]
	local tabRow = UiKit.frame({
		Parent = frame,
		Size = UDim2.new(1, -CLOSE_CLEAR, 0, TAB_HEIGHT),
		BackgroundTransparency = 1,
	})
	UiKit.list(tabRow, {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, GAP),
	})
	for index, stall in STALLS do
		local button = UiKit.button({
			Parent = tabRow,
			Size = UDim2.new(0.5, -GAP // 2, 1, 0),
			BackgroundColor3 = UiKit.PALETTE.panelSoft,
			TextColor3 = UiKit.PALETTE.text,
			Text = stall.label,
			Corner = 12,
			LayoutOrder = index,
		}, function()
			cue("Click")
			-- Through open(), not selectKind(), so a tab and a stall prompt
			-- take exactly the same route into the shelf.
			ShopController.open(stall.kind)
		end)
		textCeiling(button, 20)
		tabs[stall.kind] = button
	end

	scroll = UiKit.scroll({
		Parent = frame,
		Position = UDim2.new(0, 0, 0, TAB_HEIGHT + GAP),
		Size = UDim2.new(1, 0, 1, -(TAB_HEIGHT + GAP)),
		-- The canvas is sized by layout(), not by the contents: the rows that
		-- exist are only the ones on screen, so automatic sizing would measure
		-- the pool instead of the shelf.
		AutomaticCanvasSize = Enum.AutomaticSize.None,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	})

	emptyLabel = UiKit.label({
		Parent = frame,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.55),
		Size = UDim2.new(0.8, 0, 0, 60),
		Text = "This shelf is empty.",
		TextColor3 = UiKit.PALETTE.muted,
		Visible = false,
		ZIndex = 5,
	})

	buildDialog(frame)
	return frame
end

-- ── Stall prompts (GDD §6) ───────────────────────────────────────────────

local function setPromptsEnabled(enabled: boolean)
	for _, prompt in prompts do
		prompt.Enabled = enabled
	end
end

--[[
	Built client-side because they are pure interface: the server has no
	interest in who is standing at a stall, and a ProximityPrompt is already
	the touch control GDD §3 demands — it draws as a tappable button on a
	phone with no extra work and needs no key.
]]
local function attachPrompt(instance: Instance, stall: Stall)
	if not instance:IsA("BasePart") then
		return
	end
	local trigger: BasePart = instance
	if prompts[trigger] then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ShopPrompt"
	prompt.ActionText = "Shop"
	prompt.ObjectText = stall.object
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	prompt.Enabled = not panelVisible()
	prompt.Parent = trigger
	prompt.Triggered:Connect(function()
		cue("Click")
		ShopController.open(stall.kind)
	end)
	prompts[trigger] = prompt
end

local function detachPrompt(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local trigger: BasePart = instance
	local prompt = prompts[trigger]
	prompts[trigger] = nil
	if prompt then
		prompt:Destroy()
	end
end

-- ── Registry API ─────────────────────────────────────────────────────────

--[[
	`kind` selects a shelf; omitting it keeps whichever shelf the player was
	last on, which is what the HUD's single SHOP button wants. Opening goes
	through the host so "one panel at a time" — and the refusal while a reveal
	is running (GDD §2, pillar 1) — stay the host's to enforce.
]]
function ShopController.open(requested: string?)
	if not uiReady then
		return
	end
	if requested == "Critter" or requested == "Stuff" then
		selectKind(requested)
	end
	if not hud then
		return
	end
	hud.openPanel(PANEL_NAME)
end

function ShopController.close()
	closeDialog()
	if hud then
		hud.closePanel(PANEL_NAME)
	end
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

function ShopController.init(controllers: { [string]: any })
	hud = controllers.HudController
	sound = controllers.SoundController
end

function ShopController.start()
	local frame = buildPanel()
	uiReady = true

	if hud then
		hud.registerPanel(PANEL_NAME, frame)
	else
		-- The host owns the stage, the scrim and the CLOSE button; a shelf
		-- opened outside it would have none of them.
		warn("[Shop] no HudController; the shelves have nowhere to live")
	end

	selectKind(kind)

	--[[
		The HUD's cluster button shows this panel directly, without ever
		calling open(), so the screen wakes off its own visibility rather than
		off the call that revealed it. It also drops a half-finished
		confirmation on the way out and hands the stall prompts back, so
		walking away from an open shop re-arms the prompt you walked away from.
	]]
	frame:GetPropertyChangedSignal("Visible"):Connect(function()
		local visible = frame.Visible
		setPromptsEnabled(not visible)
		if not visible then
			closeDialog()
			stopSpin()
			for _, row in rows do
				releaseRow(row)
			end
			firstIndex = 0
			return
		end
		layout()
		startSpin()
	end)

	-- The stage resizes while the panel is hidden (a rotated phone, a resized
	-- window), so the row height and the pool are measured from the scroll
	-- itself rather than from a viewport read at build time.
	scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if panelVisible() then
			layout()
		end
	end)
	scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		if panelVisible() then
			bindWindow(false)
		end
	end)

	--[[
		Every figure on this shelf is a window onto the last sync: the counts,
		the greying, and whether the tap that just went out was honoured. Goop
		arrives once a second, so the redraw is deliberately the cheap half —
		text and transparency on the rows that exist, never a model rebuild.
	]]
	ClientState.changed:connect(function(keys: any)
		if type(keys) ~= "table" then
			return
		end
		local inventory = false
		local repaint = false
		local effects = false
		for _, key in keys :: { string } do
			if key == "inventory" then
				inventory = true
				repaint = true
			elseif key == "goop" then
				repaint = true
			elseif key == "settings" then
				effects = true
			end
		end

		if inventory then
			onInventorySynced()
		end
		if not panelVisible() then
			return
		end
		if repaint then
			refreshDynamic()
		end
		if effects then
			startSpin() -- re-reads lowFx; stops the spin outright when it is on
		end
	end)

	ClientState.ready:connect(function()
		if panelVisible() then
			refreshDynamic()
		end
	end)

	--[[
		WorldService may not have replicated Blendburg yet when this runs, so
		the tagged set is walked AND subscribed to; whichever arrives first
		wins and attachPrompt is idempotent on a part it already owns.
	]]
	for _, stall in STALLS do
		for _, tagged in CollectionService:GetTagged(stall.tag) do
			attachPrompt(tagged, stall)
		end
		CollectionService:GetInstanceAddedSignal(stall.tag):Connect(function(instance: Instance)
			attachPrompt(instance, stall)
		end)
		CollectionService:GetInstanceRemovedSignal(stall.tag):Connect(detachPrompt)
	end
end

return ShopController
