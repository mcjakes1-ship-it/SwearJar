--!strict
--[[
	MixdexController.luau — the collection log.
	GDD §8.5 (the grid, the progress bar, the milestone track), §7.3 (rarity
	colour and the best tier owned), §7.4 (secrets stay "???"), §6 (the
	Mixdex Kiosk in the plaza), §10 (mobile-first, 44px touch minimum),
	§11.4 (performance).

	REGISTRY API — HudController's cluster button and the kiosk prompt are the
	only ways in; nothing else reaches into this file:

	    open()
	    close()
	    progress() -> (discovered: number, total: number, percent: number)

	NOTHING HERE DECIDES ANYTHING (ARCHITECTURE §7.1). Every tier on this
	screen is `ClientState.mixdex[key]`, every secret is a row the server sent
	after this player produced it, and the numerator and denominator of the
	progress bar are `mixdexDiscovered` / `mixdexTotal` off the sync. This
	screen sends no intent at all — it is a window onto the profile — so there
	is no remote in this file and nothing to refuse.

	261 TILES, AT MOST MAX_TILES VIEWPORTS. This is the single biggest client
	performance risk in the game: 16 x 16 base pairs plus SecretsPublic.COUNT
	secrets is 261 tiles, and 261 ViewportFrames each holding an assembled
	model would lock a phone solid. So the grid is VIRTUALISED. The tiles are
	a recycled pool sized to the scroll window, positioned by offset rather
	than by a UIGridLayout (a layout would repack recycled children and undo
	the recycling), and the pool never exceeds MAX_TILES. A tile holds at most
	one assembled model and releases it the moment it scrolls out of the
	pool's reach, so the number of live models is bounded by MAX_TILES and not
	by the size of the collection. The visible row count is capped from the
	same number, so even a very tall window cannot ask for a bigger pool than
	the cap allows. Nothing in the grid spins, either: one Heartbeat driving
	dozens of PivotTo calls is the other half of the same bill, and only the
	detail card — exactly one model — turns.

	WHAT AN UNDISCOVERED TILE MAY SAY. It shows a "?" plate, the pair in muted
	grey, and NO rarity colour, NO prefix and NO model. The pair itself is not
	a secret: both ingredient tables are public config and this grid is
	literally their cross product, so hiding "Sock Frog" would only stop the
	player searching for the thing they came here to find. What discovery buys
	is the tier, and the tier is the one thing a silhouette must not leak. The
	GDD's other option — the assembled model rendered fully black — is
	deliberately not taken: at 0% discovered that is 256 assembled models to
	draw one shade of black, which is the phone-killer described above.

	SECRETS ARE NEVER DERIVED (DECISIONS D11, GDD §7.4). The client has no
	recipe table and must not look as though it has one. An unfound secret is
	a "???" tile with no name, no ingredients and no model; it cannot be
	searched for, and no filter can turn one up. A found secret is drawn from
	the row the server put in `secrets` when the player produced it — that row
	carries the name and the pair, and the fallback when only `secretsFound`
	has arrived is the server's own id, never a guess. The count of secrets
	still hidden is SecretsPublic.COUNT minus what the sync says was found,
	which is exactly what GDD §7.4 asks the tiles to show.

	THE SHEET IS WHERE A SMALL SCREEN PUTS EVERYTHING. On a 640x360 phone
	HudController's stage is about 135px tall, and a header plus a filter
	strip already costs 96 of it. Nothing shrinks below UiKit's 44px touch
	minimum (GDD §10 does not negotiate that), so the panel folds instead: the
	milestone track and every filter live in one in-panel overlay reached by a
	tap, the header collapses onto a single line, and the grid takes what is
	left with the player flicking through it. Every control on this screen is
	a tap — no hover, no keyboard, no right-click — and the one text field is
	a search box with its own CLEAR button so a phone keyboard is never the
	only way back out.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = ReplicatedStorage:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Config:WaitForChild("Constants"))
local Ingredients = require(Config:WaitForChild("Ingredients"))
local Rarity = require(Config:WaitForChild("Rarity"))
local SecretsPublic = require(Config:WaitForChild("SecretsPublic"))
local Assembler = require(Shared:WaitForChild("MixlingAssembler"))
local UiKit = require(Shared:WaitForChild("UiKit"))
local Util = require(Shared:WaitForChild("Util"))

local ClientState = require(script.Parent.Parent:WaitForChild("ClientState"))

local MixdexController = {}
MixdexController.Name = "MixdexController"

-- ── Local tunables ───────────────────────────────────────────────────────
--[[
	Geometry and cadence only. Everything the player earns or waits for lives
	in Constants (GDD §17) — the milestone track below is read from
	Constants.MIXDEX_MILESTONES and the denominator from
	Ingredients.baseCombinationCount() plus SecretsPublic.COUNT — and how many
	pixels a gap is has never been a balance question.
]]

local PANEL_NAME = "Mixdex" -- HudController's cluster button opens this key
local MIXER_PANEL = "Mixer" -- where the detail card's MIX THIS sends the player
local KIOSK_TAG = "Kiosk_Mixdex" -- WorldService tags the kiosk's trigger volume

local PAD = 10
local GAP = 8
local ROW = 46 -- UiKit's 44px touch minimum plus a hair, so nothing clips it
local CLOSE_RESERVE = 108 -- HudController's CLOSE button owns the stage's top-right

local TITLE_HEIGHT = 24
local BAR_HEIGHT = 8
local NEXT_HEIGHT = 16
local HEADER_TALL = TITLE_HEIGHT + 4 + BAR_HEIGHT + 4 + NEXT_HEIGHT
local HEADER_COMPACT = UiKit.TOUCH_MIN -- the header is a button; this is its floor
local FILTER_HEIGHT = UiKit.TOUCH_MIN
local MILESTONE_HEIGHT = 30
local MILESTONE_WIDTH = 132
local SEARCH_WIDTH = 190
local CHIP_WIDE = 158
local CHIP_NARROW = 104

-- Panel height under which the milestone strip folds into the sheet and the
-- header collapses onto one line. A landscape phone lands well under it.
local COMPACT_HEIGHT = 300

local CELL_MIN = 96 -- the grid drops a column rather than a cell below this
local CELL_MAX = 132 -- ...and never grows one past this, so 261 still reads as a grid
local CELL_ASPECT = 1.2 -- art, name, tier word
local GRID_MIN_COLUMNS = 2
local GRID_MAX_COLUMNS = 6
local OVERSCAN_ROWS = 1 -- one row built ahead so a flick does not show holes

--[[
	The ceiling on live ViewportFrames, and therefore on assembled models.
	Six columns of the widest cell fill the 900px HudController allows a
	stage, so this is eight visible rows: far more than any phone shows and
	still a number a phone could survive if it did.
]]
local MAX_TILES = 48

local ART_TOP = 4
local TILE_TITLE = 20
local TILE_SUB = 14
local DETAIL_ART = 148
local DETAIL_ROW = 20

local SPIN_SPEED = 0.6 -- radians/sec, detail card only
local PROMPT_DISTANCE = 12 -- studs; the kiosk trigger volume is nine wide
local SEARCH_MAX = 32 -- longest query kept; past this it cannot match anything anyway

-- Constants.MIXDEX_MILESTONES is a literal, so its inferred type is a sealed
-- record. Same cast MixdexService makes over the same table.
type Milestone = { entries: number, goop: number, title: string }
local MILESTONES: { Milestone } = Constants.MIXDEX_MILESTONES :: any

-- The denominator MixdexService computes server-side, mirrored here as the
-- fallback for the frames before the first sync lands. Both halves are frozen
-- config, so the two can only agree.
local TOTAL_ENTRIES = Ingredients.baseCombinationCount() + SecretsPublic.COUNT

-- ── Types ────────────────────────────────────────────────────────────────

--[[
	One grid tile's worth of identity. Base rows are built once and never
	change; secret rows are rebuilt per pass because which of them are found
	is a property of the sync, not of the config. Empty strings rather than
	optionals: every one of these fields is read on the hot paint path.
]]
type Entry = {
	kind: string, -- "Base" | "Secret"
	critter: string, -- "" for an unfound secret
	stuff: string,
	key: string, -- Ingredients.key(...) for a base pair, "" for a secret
	pair: string, -- "Sock Frog"; "" for an unfound secret
	search: string, -- lowercased haystack; "" for an unfound secret
	slot: number, -- which "???" slot a secret occupies, 0 for a base pair
	secretId: string,
	name: string, -- the server's display name for a found secret
	found: boolean,
}

-- What the server put in the sync's `secrets` map for a secret this player
-- has produced. Read defensively: it is a wire shape, not a local table.
type SecretRow = {
	id: string,
	name: string,
	critter: string,
	stuff: string,
}

type Tile = {
	button: TextButton,
	art: ViewportFrame,
	setModel: (Model?) -> (),
	glyph: TextLabel,
	title: TextLabel,
	sub: TextLabel,
	stroke: UIStroke?,
	key: string?, -- what this tile is currently showing; nil when it shows nothing
	entry: Entry?,
	wanted: boolean,
}

-- ── State ────────────────────────────────────────────────────────────────
-- Registry handles, the widgets this file owns, and the filter the player
-- last chose. Nothing derived is cached across a render.

local hud: any = nil
local sound: any = nil
local mixer: any = nil

local panel: Frame? = nil
local header: TextButton? = nil
local titleLabel: TextLabel? = nil
local statLabel: TextLabel? = nil
local barBack: Frame? = nil
local barFill: Frame? = nil
local barTicks: { Frame } = {}
local nextLabel: TextLabel? = nil

local filterStrip: ScrollingFrame? = nil
local rarityChip: TextButton? = nil
local critterChip: TextButton? = nil
local stuffChip: TextButton? = nil
local unseenChip: TextButton? = nil

local milestoneStrip: ScrollingFrame? = nil
local milestonePills: { { frame: Frame, label: TextLabel, sub: TextLabel } } = {}

local gridScroll: ScrollingFrame? = nil
local emptyLabel: TextLabel? = nil

local sheet: Frame? = nil
local sheetTitle: TextLabel? = nil
local sheetList: ScrollingFrame? = nil
local sheetRows: { GuiObject } = {}
local detail: Frame? = nil
local detailArt: ViewportFrame? = nil
local detailSetModel: ((Model?) -> ())? = nil
local detailName: TextLabel? = nil
local detailTier: TextLabel? = nil
local detailRate: TextLabel? = nil
local detailRecipe: TextLabel? = nil
local detailHint: TextLabel? = nil
local detailMix: TextButton? = nil
local detailModel: Model? = nil
local detailEntry: Entry? = nil

local tiles: { Tile } = {}
local rows: { Entry } = {}
local secretByPair: { [string]: SecretRow } = {}

local columns = GRID_MIN_COLUMNS
local cellWidth = CELL_MIN
local cellHeight = math.floor(CELL_MIN * CELL_ASPECT)
local stride = cellHeight + GAP
local paintedFirst = 0
local paintedLast = -1

local rarityFilter = 0 -- 0 = every tier
local critterFilter = ""
local stuffFilter = ""
local unseenOnly = false
local query = ""

local prompts: { [BasePart]: ProximityPrompt } = {}
local spinAngle = 0
local dirty = true -- a sync landed while the panel was closed

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

local function tierOf(key: string): number?
	local tier = view().mixdex[key]
	return if type(tier) == "number" then tier else nil
end

-- The same arithmetic HudController prints in its own Mixdex row, so the two
-- readouts can never disagree by a rounding step. Both figures are the
-- server's; this only divides them.
local function percentOf(discovered: number, total: number): number
	if total <= 0 then
		return 0
	end
	return math.floor(discovered / total * 100)
end

local function discoveredNow(): (number, number)
	local current = view()
	local total = if type(current.mixdexTotal) == "number" and current.mixdexTotal > 0
		then current.mixdexTotal
		else TOTAL_ENTRIES
	local found = if type(current.mixdexDiscovered) == "number" then current.mixdexDiscovered else 0
	return found, total
end

local function keysInclude(keys: { string }, wanted: { [string]: boolean }): boolean
	for _, key in keys do
		if wanted[key] then
			return true
		end
	end
	return false
end

local function setStroke(gui: GuiObject, color: Color3)
	local stroke = gui:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = color
	end
end

-- ── The base grid, built once ────────────────────────────────────────────
-- Ingredients.Critters x Ingredients.Stuff, critter-major so the grid reads
-- in the order the shop shelves do. This is the frozen half of the list; only
-- the secret rows below it move.

local BASE: { Entry } = table.create(Ingredients.baseCombinationCount())

for _, critter in Ingredients.Critters do
	for _, stuff in Ingredients.Stuff do
		-- Rarity.displayName at Common is the unprefixed pair, which is the
		-- name an undiscovered tile is allowed to print (see the header).
		local pair = Rarity.displayName(Rarity.COMMON, critter.name, stuff.name)
		table.insert(BASE, {
			kind = "Base",
			critter = critter.name,
			stuff = stuff.name,
			key = Ingredients.key(critter.name, stuff.name),
			pair = pair,
			search = string.lower(pair .. " " .. critter.name .. " " .. stuff.name),
			slot = 0,
			secretId = "",
			name = "",
			found = false,
		})
	end
end

-- Filled by the tap handler on a tile; defined with the sheet, far below.
local openEntry: (Entry) -> ()
local refresh: () -> ()

-- ── The tile pool ────────────────────────────────────────────────────────

local function buildTile(): Tile
	local button = UiKit.button({
		Text = "",
		BackgroundColor3 = UiKit.PALETTE.panelSoft,
		Corner = 12,
		Stroke = UiKit.PALETTE.stroke,
		Size = UDim2.fromOffset(cellWidth, cellHeight),
		Visible = false,
		Parent = gridScroll,
	})

	local art, setModel = UiKit.viewport({
		Size = UDim2.new(1, -8, 1, -(ART_TOP + TILE_TITLE + TILE_SUB + 6)),
		Position = UDim2.new(0.5, 0, 0, ART_TOP),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = button,
	})

	-- Stands in for the model on every tile that has none: the "?" plate of an
	-- undiscovered pair and the "???" of a secret. Same rectangle, so a tile
	-- never changes shape as the collection fills.
	local glyph = UiKit.label({
		Text = "",
		TextColor3 = UiKit.PALETTE.muted,
		Size = art.Size,
		Position = art.Position,
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = button,
	})
	textCeiling(glyph, 44)

	local title = UiKit.label({
		Text = "",
		Size = UDim2.new(1, -8, 0, TILE_TITLE),
		Position = UDim2.new(0.5, 0, 1, -(TILE_SUB + 4)),
		AnchorPoint = Vector2.new(0.5, 1),
		TextWrapped = true,
		Parent = button,
	})
	textCeiling(title, 15)

	local sub = UiKit.label({
		Text = "",
		TextColor3 = UiKit.PALETTE.muted,
		Font = UiKit.FONT_BODY,
		Size = UDim2.new(1, -8, 0, TILE_SUB),
		Position = UDim2.new(0.5, 0, 1, -4),
		AnchorPoint = Vector2.new(0.5, 1),
		Parent = button,
	})
	textCeiling(sub, 12)

	local tile: Tile = {
		button = button,
		art = art,
		setModel = setModel,
		glyph = glyph,
		title = title,
		sub = sub,
		stroke = button:FindFirstChildOfClass("UIStroke"),
		key = nil,
		entry = nil,
		wanted = false,
	}

	button.Activated:Connect(function()
		local entry = tile.entry
		if not entry then
			return
		end
		cue("Click")
		openEntry(entry)
	end)

	return tile
end

-- A tile leaving the window gives its model back immediately; that release is
-- what keeps the live-model count at the size of the pool rather than the
-- size of everything the player has ever scrolled past.
local function hideTile(tile: Tile)
	if not tile.button.Visible and tile.key == nil then
		return
	end
	tile.button.Visible = false
	tile.setModel(nil)
	tile.key = nil
	tile.entry = nil
end

local function specFor(critter: string, stuff: string, tier: number, secret: SecretRow?): Assembler.BuildSpec
	return {
		critter = critter,
		stuff = stuff,
		rarity = tier,
		secretId = if secret then secret.id else nil,
		secretName = if secret then secret.name else nil,
		lowFx = lowFx(),
	}
end

--[[
	The recycle key. Two tiles showing the same thing are interchangeable, so
	a scroll that moves a row only rebuilds the models that actually changed —
	and a discovery that improves a tier changes the key, which is what makes
	a better roll repaint the card it belongs to.
]]
local function keyOf(entry: Entry): string
	if entry.kind == "Secret" then
		if entry.found then
			return "S:" .. entry.secretId
		end
		return "S?:" .. tostring(entry.slot)
	end
	return entry.key .. "@" .. tostring(tierOf(entry.key))
end

local function paintContent(tile: Tile, entry: Entry)
	if entry.kind == "Secret" then
		if not entry.found then
			-- GDD §7.4: no name, no ingredients, no model. The client could
			-- not fill this in if it wanted to, and must not look as if it
			-- could (DECISIONS D11).
			tile.setModel(nil)
			tile.art.Visible = false
			tile.glyph.Visible = true
			tile.glyph.Text = "?"
			tile.glyph.TextColor3 = Rarity.color(Rarity.SECRET)
			tile.title.Text = "???"
			tile.title.TextColor3 = UiKit.PALETTE.muted
			tile.sub.Text = "SECRET"
			tile.sub.TextColor3 = UiKit.PALETTE.muted
			tile.button.BackgroundColor3 = UiKit.PALETTE.ink
			setStroke(tile.button, UiKit.PALETTE.stroke)
			return
		end

		local row: SecretRow = { id = entry.secretId, name = entry.name, critter = entry.critter, stuff = entry.stuff }
		local hasPair = entry.critter ~= "" and entry.stuff ~= ""
		if hasPair then
			tile.setModel(Assembler.buildDisplay(specFor(entry.critter, entry.stuff, Rarity.SECRET, row), CFrame.new()))
			tile.art.Visible = true
			tile.glyph.Visible = false
		else
			-- Found, but only `secretsFound` has arrived: the display row that
			-- carries the pair is still on its way. The tile says so rather
			-- than inventing a model.
			tile.setModel(nil)
			tile.art.Visible = false
			tile.glyph.Visible = true
			tile.glyph.Text = "!"
			tile.glyph.TextColor3 = Rarity.color(Rarity.SECRET)
		end
		tile.title.Text = entry.name
		tile.title.TextColor3 = Rarity.color(Rarity.SECRET)
		tile.sub.Text = "SECRET"
		tile.sub.TextColor3 = Rarity.color(Rarity.SECRET)
		tile.button.BackgroundColor3 = UiKit.PALETTE.panelSoft
		setStroke(tile.button, Rarity.color(Rarity.SECRET))
		return
	end

	local tier = tierOf(entry.key)
	if tier == nil then
		tile.setModel(nil)
		tile.art.Visible = false
		tile.glyph.Visible = true
		tile.glyph.Text = "?"
		tile.glyph.TextColor3 = UiKit.PALETTE.stroke
		tile.title.Text = entry.pair
		tile.title.TextColor3 = UiKit.PALETTE.muted
		tile.sub.Text = "NOT MIXED"
		tile.sub.TextColor3 = UiKit.PALETTE.muted
		tile.button.BackgroundColor3 = UiKit.PALETTE.ink
		setStroke(tile.button, UiKit.PALETTE.stroke)
		return
	end

	--[[
		A pair that produced a Secret is logged in `mixdex` at tier 7 like any
		other, so the tile borrows that secret's own row for the model and the
		name. The row exists only because the player produced it; there is no
		path here for a pair they have not solved.
	]]
	local secret = if tier >= Rarity.SECRET then secretByPair[entry.key] else nil
	local color = Rarity.color(tier)

	tile.setModel(Assembler.buildDisplay(specFor(entry.critter, entry.stuff, tier, secret), CFrame.new()))
	tile.art.Visible = true
	tile.glyph.Visible = false
	tile.title.Text = if secret then secret.name else Rarity.displayName(tier, entry.critter, entry.stuff)
	tile.title.TextColor3 = color
	tile.sub.Text = string.upper(Rarity.name(tier))
	tile.sub.TextColor3 = color
	tile.button.BackgroundColor3 = UiKit.PALETTE.panelSoft
	setStroke(tile.button, color)
end

--[[
	Assigns the visible slice of `rows` to the pool. Index -> tile is modular
	rather than sequential on purpose: as the window moves by one row, only
	the tiles holding the rows that actually left change hands, so a flick
	rebuilds the models that entered the screen and nothing else.
]]
local function paint(force: boolean)
	local scroll = gridScroll
	if not scroll or #rows == 0 or columns <= 0 or stride <= 0 then
		-- Unconditional: a filter that matches nothing must take the tiles off
		-- the screen, and the range check below would happily keep them.
		for _, tile in tiles do
			hideTile(tile)
		end
		paintedFirst, paintedLast = 0, -1
		return
	end

	local top = scroll.CanvasPosition.Y
	local windowHeight = scroll.AbsoluteWindowSize.Y
	local firstRow = math.max(0, math.floor(top / stride))
	local lastRow = math.floor((top + math.max(windowHeight, 1)) / stride) + OVERSCAN_ROWS

	local wanted = math.min(MAX_TILES, (lastRow - firstRow + 1) * columns)
	local first = firstRow * columns + 1
	local last = math.min(#rows, first + wanted - 1)
	if not force and first == paintedFirst and last == paintedLast then
		return
	end
	paintedFirst, paintedLast = first, last

	while #tiles < wanted do
		table.insert(tiles, buildTile())
	end

	for _, tile in tiles do
		tile.wanted = false
	end

	local pool = #tiles
	for index = first, last do
		local entry = rows[index]
		local tile = tiles[(index - 1) % pool + 1]
		tile.wanted = true
		tile.entry = entry

		local column = (index - 1) % columns
		local row = (index - 1) // columns
		tile.button.Size = UDim2.fromOffset(cellWidth, cellHeight)
		tile.button.Position = UDim2.fromOffset(column * (cellWidth + GAP), row * stride)
		tile.button.Visible = true

		local key = keyOf(entry)
		if force or tile.key ~= key then
			tile.key = key
			paintContent(tile, entry)
		end
	end

	for _, tile in tiles do
		if not tile.wanted then
			hideTile(tile)
		end
	end
end

-- ── Rows and filters ─────────────────────────────────────────────────────

--[[
	The secret strip. Found secrets come from the sync's `secrets` rows, which
	are the only place a name may come from; a secret in `secretsFound` whose
	row has not arrived still gets a tile, labelled with the server's own id.
	The remainder of SecretsPublic.COUNT are "???" placeholders, so the strip
	always states how many are left without ever hinting what they are.
]]
local function secretEntries(): { Entry }
	local current = view()
	local out: { Entry } = {}

	local sourceRows: { [string]: any } = {}
	if type(current.secrets) == "table" then
		sourceRows = current.secrets :: { [string]: any }
	end

	local found: { [string]: boolean } = {}
	if type(current.secretsFound) == "table" then
		for id, seen in current.secretsFound :: { [string]: any } do
			if seen and type(id) == "string" then
				found[id] = true
			end
		end
	end
	-- A row without a matching ledger entry still means "found": both halves
	-- are written by the same server pass and either one arriving is proof.
	for id, row in sourceRows do
		if type(id) == "string" and type(row) == "table" then
			found[id] = true
		end
	end

	for id in found do
		local row = sourceRows[id]
		local name = id
		local critter = ""
		local stuff = ""
		if type(row) == "table" then
			local sent = row :: { [string]: any }
			if type(sent.name) == "string" then
				name = sent.name
			end
			if type(sent.critter) == "string" and type(sent.stuff) == "string" then
				critter = sent.critter
				stuff = sent.stuff
			end
		end
		table.insert(out, {
			kind = "Secret",
			critter = critter,
			stuff = stuff,
			key = "",
			pair = "",
			search = string.lower(name),
			slot = 0,
			secretId = id,
			name = name,
			found = true,
		})
	end

	table.sort(out, function(a: Entry, b: Entry): boolean
		return a.name < b.name
	end)

	for slot = 1, SecretsPublic.COUNT - #out do
		table.insert(out, {
			kind = "Secret",
			critter = "",
			stuff = "",
			key = "",
			pair = "",
			search = "",
			slot = slot,
			secretId = "",
			name = "",
			found = false,
		})
	end
	return out
end

local function matchesBase(entry: Entry): boolean
	local tier = tierOf(entry.key)
	if unseenOnly and tier ~= nil then
		return false
	end
	if rarityFilter > 0 and tier ~= rarityFilter then
		return false
	end
	if critterFilter ~= "" and entry.critter ~= critterFilter then
		return false
	end
	if stuffFilter ~= "" and entry.stuff ~= stuffFilter then
		return false
	end
	if query == "" then
		return true
	end
	if string.find(entry.search, query, 1, true) then
		return true
	end
	-- A discovered pair also answers to the tier's own word, so "golden" finds
	-- the Legendaries. An undiscovered one does not: that word is the reward.
	if tier ~= nil then
		local prefix = string.lower(Rarity.prefix(tier))
		if prefix ~= "" and string.find(prefix, query, 1, true) then
			return true
		end
	end
	return false
end

local function matchesSecret(entry: Entry): boolean
	if unseenOnly and entry.found then
		return false
	end
	if rarityFilter > 0 and rarityFilter ~= Rarity.SECRET then
		return false
	end
	if critterFilter ~= "" and entry.critter ~= critterFilter then
		return false
	end
	if stuffFilter ~= "" and entry.stuff ~= stuffFilter then
		return false
	end
	if query == "" then
		return true
	end
	-- An unfound secret has an empty haystack, so no query can ever surface
	-- one. That is the point.
	return entry.found and string.find(entry.search, query, 1, true) ~= nil
end

local function rebuildRows()
	table.clear(rows)
	table.clear(secretByPair)

	local secrets = secretEntries()
	for _, entry in secrets do
		if entry.found and entry.critter ~= "" and entry.stuff ~= "" then
			secretByPair[Ingredients.key(entry.critter, entry.stuff)] =
				{ id = entry.secretId, name = entry.name, critter = entry.critter, stuff = entry.stuff }
		end
	end

	for _, entry in BASE do
		if matchesBase(entry) then
			table.insert(rows, entry)
		end
	end
	for _, entry in secrets do
		if matchesSecret(entry) then
			table.insert(rows, entry)
		end
	end

	local scroll = gridScroll
	if scroll then
		local rowCount = math.ceil(#rows / math.max(columns, 1))
		scroll.CanvasSize = UDim2.fromOffset(0, math.max(0, rowCount * stride - GAP))
		scroll.CanvasPosition = Vector2.new(0, math.min(scroll.CanvasPosition.Y, math.max(0, rowCount * stride - GAP)))
	end
	local empty = emptyLabel
	if empty then
		empty.Visible = #rows == 0
	end
end

-- ── Layout ───────────────────────────────────────────────────────────────

--[[
	Columns come from the width there is, not from a breakpoint guess about
	what device this is, and the grid's own height is capped at what the tile
	pool can serve — see MAX_TILES. On anything smaller than a desktop window
	the cap is never the binding constraint; on a very tall one it is, and the
	Mixdex stays a panel instead of becoming a wall of viewports.
]]
local function layout()
	local frame = panel
	local scroll = gridScroll
	if not frame or not scroll then
		return
	end
	local size = frame.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return
	end

	local compact = size.Y < COMPACT_HEIGHT
	local headerHeight = if compact then HEADER_COMPACT else HEADER_TALL
	local width = size.X - PAD * 2

	local head = header
	if head then
		head.Size = UDim2.new(1, -(PAD * 2 + CLOSE_RESERVE), 0, headerHeight)
		head.Position = UDim2.fromOffset(PAD, PAD)
	end
	local title = titleLabel
	if title then
		-- The compact header carries the counts itself, so it takes back the
		-- width the stat column holds on a taller panel.
		title.Size = UDim2.new(1, if compact then 0 else -140, 0, TITLE_HEIGHT)
	end
	local stat = statLabel
	if stat then
		stat.Visible = not compact
	end
	local nextText = nextLabel
	if nextText then
		nextText.Visible = not compact
	end
	local back = barBack
	if back then
		back.Position = UDim2.new(0, 0, 0, if compact then TITLE_HEIGHT + 6 else TITLE_HEIGHT + 4)
		back.Size = UDim2.new(1, 0, 0, if compact then 6 else BAR_HEIGHT)
	end

	local top = PAD + headerHeight + GAP
	local strip = filterStrip
	if strip then
		strip.Position = UDim2.fromOffset(PAD, top)
		strip.Size = UDim2.new(1, -PAD * 2, 0, FILTER_HEIGHT)
	end
	top += FILTER_HEIGHT + GAP

	local bottom = PAD
	local milestones = milestoneStrip
	if milestones then
		milestones.Visible = not compact
		if not compact then
			bottom += MILESTONE_HEIGHT + GAP
			milestones.Position = UDim2.new(0, PAD, 1, -(PAD + MILESTONE_HEIGHT))
			milestones.Size = UDim2.new(1, -PAD * 2, 0, MILESTONE_HEIGHT)
		end
	end

	columns = math.clamp(math.floor((width + GAP) / (CELL_MIN + GAP)), GRID_MIN_COLUMNS, GRID_MAX_COLUMNS)
	cellWidth = math.floor(math.min(CELL_MAX, (width - GAP * (columns - 1)) / columns))
	cellHeight = math.floor(cellWidth * CELL_ASPECT)
	stride = cellHeight + GAP

	local poolRows = math.max(1, MAX_TILES // columns - OVERSCAN_ROWS)
	local available = size.Y - top - bottom
	local gridHeight = math.max(UiKit.TOUCH_MIN, math.min(available, poolRows * stride))

	scroll.Position = UDim2.fromOffset(PAD, top)
	scroll.Size = UDim2.new(1, -PAD * 2, 0, gridHeight)

	local empty = emptyLabel
	if empty then
		empty.Position = scroll.Position
		empty.Size = UDim2.new(1, -PAD * 2, 0, gridHeight)
	end

	rebuildRows()
	paint(true)
end

-- ── Progress and milestones (GDD §8.5) ───────────────────────────────────

-- The first milestone this profile has not been given the title for. The
-- title is the server's own ledger (MixdexService grants it), so "claimed"
-- here is read, never inferred from the count.
local function nextMilestone(): Milestone?
	local titles = view().titles
	for _, milestone in MILESTONES do
		if not (titles and titles[milestone.title]) then
			return milestone
		end
	end
	return nil
end

local function renderProgress()
	local found, total = discoveredNow()
	local percent = percentOf(found, total)
	local ratio = if total > 0 then math.clamp(found / total, 0, 1) else 0

	local title = titleLabel
	if title then
		title.Text = if panel and panel.AbsoluteSize.Y < COMPACT_HEIGHT
			then ("MIXDEX  %d/%d  ·  %d%%"):format(found, total, percent)
			else "MIXDEX"
	end
	local stat = statLabel
	if stat then
		stat.Text = ("%d / %d  ·  %d%%"):format(found, total, percent)
	end
	local fill = barFill
	if fill then
		UiKit.tween(fill, { Size = UDim2.fromScale(ratio, 1) }, 0.25)
	end

	local titles = view().titles
	for index, tick in barTicks do
		local milestone = MILESTONES[index]
		if milestone then
			local claimed = titles ~= nil and titles[milestone.title] == true
			tick.BackgroundColor3 = if claimed then UiKit.PALETTE.goop else UiKit.PALETTE.stroke
		end
	end

	local nextText = nextLabel
	if nextText then
		local milestone = nextMilestone()
		if not milestone then
			nextText.Text = "EVERY MILESTONE CLAIMED"
			nextText.TextColor3 = UiKit.PALETTE.goop
		else
			nextText.Text = ("NEXT: %s at %d  ·  +%s Goop  ·  %d to go"):format(
				milestone.title,
				milestone.entries,
				Util.abbreviate(milestone.goop),
				math.max(0, milestone.entries - found)
			)
			nextText.TextColor3 = UiKit.PALETTE.muted
		end
	end
end

local function renderMilestones()
	local titles = view().titles
	local found = discoveredNow()
	local pending = nextMilestone()

	for index, pill in milestonePills do
		local milestone = MILESTONES[index]
		if not milestone then
			continue
		end
		local claimed = titles ~= nil and titles[milestone.title] == true
		local isNext = pending ~= nil and pending.title == milestone.title

		pill.label.Text = string.upper(milestone.title)
		pill.sub.Text = if claimed
			then ("%d ✓"):format(milestone.entries)
			else ("%d/%d · +%s"):format(math.min(found, milestone.entries), milestone.entries, Util.abbreviate(milestone.goop))

		local color = if claimed then UiKit.PALETTE.goop elseif isNext then UiKit.PALETTE.accent else UiKit.PALETTE.muted
		pill.label.TextColor3 = color
		pill.frame.BackgroundColor3 = if claimed then UiKit.PALETTE.panelSoft else UiKit.PALETTE.ink
		setStroke(pill.frame, color)
	end
end

local function renderChips()
	local chip = rarityChip
	if chip then
		chip.Text = if rarityFilter > 0 then ("RARITY: %s"):format(string.upper(Rarity.name(rarityFilter))) else "RARITY: ALL"
		chip.BackgroundColor3 = if rarityFilter > 0 then Rarity.color(rarityFilter) else UiKit.PALETTE.panelSoft
		chip.TextColor3 = if rarityFilter > 0 then UiKit.PALETTE.ink else UiKit.PALETTE.text
	end
	local critter = critterChip
	if critter then
		critter.Text = if critterFilter ~= "" then ("CRITTER: %s"):format(string.upper(critterFilter)) else "CRITTER: ALL"
		critter.BackgroundColor3 = if critterFilter ~= "" then UiKit.PALETTE.accent else UiKit.PALETTE.panelSoft
		critter.TextColor3 = if critterFilter ~= "" then UiKit.PALETTE.ink else UiKit.PALETTE.text
	end
	local stuff = stuffChip
	if stuff then
		stuff.Text = if stuffFilter ~= "" then ("STUFF: %s"):format(string.upper(stuffFilter)) else "STUFF: ALL"
		stuff.BackgroundColor3 = if stuffFilter ~= "" then UiKit.PALETTE.accent else UiKit.PALETTE.panelSoft
		stuff.TextColor3 = if stuffFilter ~= "" then UiKit.PALETTE.ink else UiKit.PALETTE.text
	end
	local unseen = unseenChip
	if unseen then
		unseen.Text = if unseenOnly then "UNSEEN ONLY ✓" else "UNSEEN ONLY"
		unseen.BackgroundColor3 = if unseenOnly then UiKit.PALETTE.warn else UiKit.PALETTE.panelSoft
		unseen.TextColor3 = if unseenOnly then UiKit.PALETTE.ink else UiKit.PALETTE.text
	end
end

-- One repaint of everything the sync feeds. Cheap enough to run on any change
-- while the panel is open, and skipped entirely while it is closed.
function refresh()
	dirty = false
	renderChips()
	renderProgress()
	renderMilestones()
	rebuildRows()
	paint(true)
end

-- ── The sheet: filters, milestones and one entry ─────────────────────────

local function clearSheet()
	for _, row in sheetRows do
		row:Destroy()
	end
	table.clear(sheetRows)
end

local function releaseDetail()
	detailModel = nil
	local setModel = detailSetModel
	if setModel then
		setModel(nil)
	end
end

local function closeSheet()
	detailEntry = nil
	releaseDetail()
	clearSheet()
	local frame = sheet
	if frame then
		frame.Visible = false
	end
end

local function optionRow(order: number, label: string, note: string, color: Color3, selected: boolean, onTap: () -> ())
	local button = UiKit.button({
		Text = "",
		BackgroundColor3 = if selected then UiKit.PALETTE.panelSoft else UiKit.PALETTE.ink,
		Corner = 10,
		Stroke = if selected then UiKit.PALETTE.accent else UiKit.PALETTE.stroke,
		Size = UDim2.new(1, 0, 0, ROW),
		LayoutOrder = order,
		Parent = sheetList,
	}, onTap)

	local text = UiKit.label({
		Text = label,
		TextColor3 = color,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -130, 1, 0),
		Position = UDim2.fromOffset(12, 0),
		Parent = button,
	})
	textCeiling(text, 20)

	local count = UiKit.label({
		Text = note,
		TextColor3 = UiKit.PALETTE.muted,
		Font = UiKit.FONT_BODY,
		TextXAlignment = Enum.TextXAlignment.Right,
		Size = UDim2.new(0, 116, 1, 0),
		Position = UDim2.new(1, -12, 0, 0),
		AnchorPoint = Vector2.new(1, 0),
		Parent = button,
	})
	textCeiling(count, 15)

	table.insert(sheetRows, button)
end

-- Counts over the sync's own tables. A count of what the server said is a
-- drawing, not a decision.
local function countAtTier(tier: number): number
	local total = 0
	for _, value in view().mixdex do
		if value == tier then
			total += 1
		end
	end
	if tier == Rarity.SECRET then
		for _, entry in secretEntries() do
			if entry.found then
				total += 1
			end
		end
	end
	return total
end

local function countFor(field: string, name: string): number
	local total = 0
	for _, entry in BASE do
		if (if field == "Critter" then entry.critter else entry.stuff) == name and tierOf(entry.key) ~= nil then
			total += 1
		end
	end
	return total
end

local function showSheet(title: string, withDetail: boolean)
	local frame = sheet
	local list = sheetList
	local card = detail
	if not frame or not list or not card then
		return
	end
	clearSheet()
	local heading = sheetTitle
	if heading then
		heading.Text = title
	end
	list.Visible = not withDetail
	card.Visible = withDetail
	frame.Visible = true
	UiKit.pop(frame, 0.05)
end

local function openRarityFilter()
	showSheet("FILTER BY RARITY", false)
	optionRow(1, "ALL RARITIES", "", UiKit.PALETTE.text, rarityFilter == 0, function()
		cue("Click")
		rarityFilter = 0
		closeSheet()
		refresh()
	end)
	for tier = 1, #Rarity.Tiers do
		local captured = tier
		optionRow(
			tier + 1,
			string.upper(Rarity.name(tier)),
			("%d found"):format(countAtTier(tier)),
			Rarity.color(tier),
			rarityFilter == tier,
			function()
				cue("Click")
				rarityFilter = captured
				closeSheet()
				refresh()
			end
		)
	end
end

local function openIngredientFilter(kind: string)
	local isCritter = kind == "Critter"
	showSheet(if isCritter then "FILTER BY CRITTER" else "FILTER BY STUFF", false)

	optionRow(1, if isCritter then "ALL CRITTERS" else "ALL STUFF", "", UiKit.PALETTE.text, (if isCritter then critterFilter else stuffFilter) == "", function()
		cue("Click")
		if isCritter then
			critterFilter = ""
		else
			stuffFilter = ""
		end
		closeSheet()
		refresh()
	end)

	-- Annotated: the two branches are separately-inferred table types, and an
	-- unannotated union of them is not something generalized iteration can walk.
	local source: { Ingredients.Ingredient } = if isCritter then Ingredients.Critters else Ingredients.Stuff
	local perRow = if isCritter then #Ingredients.Stuff else #Ingredients.Critters
	for index, item in source do
		local name = item.name
		local selected = (if isCritter then critterFilter else stuffFilter) == name
		optionRow(
			index + 1,
			string.upper(name),
			("%d/%d"):format(countFor(kind, name), perRow),
			item.color,
			selected,
			function()
				cue("Click")
				if isCritter then
					critterFilter = name
				else
					stuffFilter = name
				end
				closeSheet()
				refresh()
			end
		)
	end
end

--[[
	The milestone track (GDD §8.5). It is also the whole of the progress panel
	on a phone, where the strip along the bottom has folded away — which is
	why the header is a button and this is what it opens.
]]
local function openMilestones()
	showSheet("MIXDEX MILESTONES", false)
	local found, total = discoveredNow()
	local titles = view().titles

	optionRow(1, ("%d / %d DISCOVERED"):format(found, total), ("%d%%"):format(percentOf(found, total)), UiKit.PALETTE.accent, false, function()
		cue("Click")
	end)

	for index, milestone in MILESTONES do
		local claimed = titles ~= nil and titles[milestone.title] == true
		local note = if claimed
			then "CLAIMED"
			else ("+%s Goop · %d to go"):format(Util.abbreviate(milestone.goop), math.max(0, milestone.entries - found))
		optionRow(
			index + 1,
			("%d — %s"):format(milestone.entries, string.upper(milestone.title)),
			note,
			if claimed then UiKit.PALETTE.goop else UiKit.PALETTE.text,
			claimed,
			function()
				cue("Click")
			end
		)
	end
end

--[[
	One entry, big. The card is the only spinning model on this screen, and
	the only place the tier's Goop/sec is spelled out: that figure is the
	tier's own constant (GDD §7.3), read out of frozen config the same way
	both realms read it, never a rate this file worked out for itself.
]]
function openEntry(entry: Entry)
	detailEntry = entry
	releaseDetail()

	local isSecret = entry.kind == "Secret"
	local tier = if isSecret then (if entry.found then Rarity.SECRET else nil) else tierOf(entry.key)
	local hasPair = entry.critter ~= "" and entry.stuff ~= ""

	showSheet(if isSecret then "SECRET" else "MIXDEX ENTRY", true)

	local name = detailName
	local tierText = detailTier
	local rate = detailRate
	local recipe = detailRecipe
	local hint = detailHint
	local mix = detailMix
	local art = detailArt
	local setModel = detailSetModel
	if not name or not tierText or not rate or not recipe or not hint or not mix or not art or not setModel then
		return
	end

	if tier == nil then
		art.Visible = false
		if isSecret then
			-- GDD §7.4 again: the count is the only thing a "???" may tell you.
			local hidden = 0
			for _, row in secretEntries() do
				if not row.found then
					hidden += 1
				end
			end
			name.Text = "???"
			name.TextColor3 = Rarity.color(Rarity.SECRET)
			tierText.Text = "UNDISCOVERED SECRET"
			tierText.TextColor3 = UiKit.PALETTE.muted
			rate.Text = ("%d of %d secrets still hidden"):format(hidden, SecretsPublic.COUNT)
			recipe.Text = ""
			hint.Text = "Secret recipes are not written down anywhere. Keep mixing."
			mix.Visible = false
			return
		end
		name.Text = entry.pair
		name.TextColor3 = UiKit.PALETTE.muted
		tierText.Text = "NOT DISCOVERED"
		tierText.TextColor3 = UiKit.PALETTE.muted
		rate.Text = ""
		recipe.Text = ("%s + %s"):format(entry.critter, entry.stuff)
		hint.Text = "Mix this pair at the Mixer to log it."
		mix.Visible = true
		return
	end

	local secret = if isSecret then { id = entry.secretId, name = entry.name, critter = entry.critter, stuff = entry.stuff } else secretByPair[entry.key]
	local color = Rarity.color(tier)

	if hasPair then
		local model = Assembler.buildDisplay(specFor(entry.critter, entry.stuff, tier, secret), CFrame.new())
		setModel(model)
		detailModel = model
		art.Visible = true
	else
		art.Visible = false
	end

	name.Text = if secret then secret.name else Rarity.displayName(tier, entry.critter, entry.stuff)
	name.TextColor3 = color
	tierText.Text = string.upper(Rarity.name(tier)) .. "  ·  BEST TIER OWNED"
	tierText.TextColor3 = color
	rate.Text = ("%s Goop/sec at this tier"):format(Util.abbreviate(Rarity.goopPerSec(tier)))
	recipe.Text = if hasPair then ("%s + %s"):format(entry.critter, entry.stuff) else ""
	hint.Text = if isSecret then "Found. It is yours to keep in the log." else "Mix it again for a better tier."
	mix.Visible = hasPair
end

-- ── Build ────────────────────────────────────────────────────────────────

local function buildHeader(parent: Frame)
	local block = UiKit.button({
		Text = "",
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Size = UDim2.new(1, -(PAD * 2 + CLOSE_RESERVE), 0, HEADER_TALL),
		Position = UDim2.fromOffset(PAD, PAD),
		Parent = parent,
	}, function()
		cue("Click")
		openMilestones()
	end)
	header = block

	local title = UiKit.label({
		Text = "MIXDEX",
		TextColor3 = UiKit.PALETTE.accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -140, 0, TITLE_HEIGHT),
		Parent = block,
	})
	textCeiling(title, 26)
	titleLabel = title

	local stat = UiKit.label({
		Text = "",
		TextColor3 = UiKit.PALETTE.text,
		Font = UiKit.FONT_BODY,
		TextXAlignment = Enum.TextXAlignment.Right,
		Size = UDim2.new(0, 136, 0, TITLE_HEIGHT),
		Position = UDim2.fromScale(1, 0),
		AnchorPoint = Vector2.new(1, 0),
		Parent = block,
	})
	textCeiling(stat, 17)
	statLabel = stat

	local back = UiKit.frame({
		BackgroundColor3 = UiKit.PALETTE.ink,
		Size = UDim2.new(1, 0, 0, BAR_HEIGHT),
		Position = UDim2.fromOffset(0, TITLE_HEIGHT + 4),
		Corner = 4,
		Parent = block,
	})
	barBack = back

	local fill = UiKit.frame({
		BackgroundColor3 = UiKit.PALETTE.accent,
		Size = UDim2.fromScale(0, 1),
		Corner = 4,
		Parent = back,
	})
	barFill = fill

	-- One tick per milestone, at its share of the bar: the track is legible
	-- even on the compact header, where the strip below has folded away.
	for index, milestone in MILESTONES do
		local tick = UiKit.frame({
			BackgroundColor3 = UiKit.PALETTE.stroke,
			Size = UDim2.new(0, 2, 1, 0),
			Position = UDim2.fromScale(math.clamp(milestone.entries / TOTAL_ENTRIES, 0, 1), 0),
			ZIndex = 2,
			Parent = back,
		})
		barTicks[index] = tick
	end

	local upcoming = UiKit.label({
		Text = "",
		TextColor3 = UiKit.PALETTE.muted,
		Font = UiKit.FONT_BODY,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, 0, 0, NEXT_HEIGHT),
		Position = UDim2.fromOffset(0, TITLE_HEIGHT + 4 + BAR_HEIGHT + 4),
		Parent = block,
	})
	textCeiling(upcoming, 14)
	nextLabel = upcoming
end

local function buildFilters(parent: Frame)
	local strip = UiKit.scroll({
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 4,
		Size = UDim2.new(1, -PAD * 2, 0, FILTER_HEIGHT),
		Position = UDim2.fromOffset(PAD, PAD + HEADER_TALL + GAP),
		Parent = parent,
	})
	UiKit.list(strip, {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
	})
	filterStrip = strip

	local holder = UiKit.frame({
		BackgroundColor3 = UiKit.PALETTE.ink,
		Size = UDim2.fromOffset(SEARCH_WIDTH, FILTER_HEIGHT),
		Corner = 12,
		LayoutOrder = 1,
		Parent = strip,
	})

	--[[
		The one instance on this screen the kit cannot make: UiKit has no text
		entry primitive and this file may not add one (the kit is frozen
		contract), so the field is built through Util.create — the shared
		instance helper — and styled from the same palette and font as
		everything around it. It is 44px tall like every other control here,
		and the CLEAR button beside it means a phone player never has to find
		the keyboard's own dismiss to get their grid back.
	]]
	local box = Util.create("TextBox", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -(UiKit.TOUCH_MIN + 16), 1, 0),
		Position = UDim2.fromOffset(12, 0),
		Font = UiKit.FONT_BODY,
		Text = "",
		PlaceholderText = "Search",
		PlaceholderColor3 = UiKit.PALETTE.muted,
		TextColor3 = UiKit.PALETTE.text,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ClearTextOnFocus = false,
		ClipsDescendants = true,
		Parent = holder,
	}) :: TextBox

	box:GetPropertyChangedSignal("Text"):Connect(function()
		local text = string.lower(string.sub(box.Text, 1, SEARCH_MAX))
		if text == query then
			return
		end
		query = text
		refresh()
	end)

	local clear = UiKit.button({
		Text = "✕",
		BackgroundColor3 = UiKit.PALETTE.panelSoft,
		TextColor3 = UiKit.PALETTE.text,
		Corner = 10,
		Size = UDim2.fromOffset(UiKit.TOUCH_MIN, UiKit.TOUCH_MIN),
		Position = UDim2.fromScale(1, 0.5),
		AnchorPoint = Vector2.new(1, 0.5),
		Parent = holder,
	}, function()
		cue("Click")
		box.Text = ""
		box:ReleaseFocus()
	end)
	textCeiling(clear, 20)

	local function chip(order: number, width: number, onTap: () -> ()): TextButton
		local button = UiKit.button({
			Text = "",
			BackgroundColor3 = UiKit.PALETTE.panelSoft,
			TextColor3 = UiKit.PALETTE.text,
			Corner = 12,
			Size = UDim2.fromOffset(width, FILTER_HEIGHT),
			LayoutOrder = order,
			Parent = strip,
		}, onTap)
		textCeiling(button, 16)
		return button
	end

	rarityChip = chip(2, CHIP_WIDE, function()
		cue("Click")
		openRarityFilter()
	end)
	critterChip = chip(3, CHIP_WIDE, function()
		cue("Click")
		openIngredientFilter("Critter")
	end)
	stuffChip = chip(4, CHIP_WIDE, function()
		cue("Click")
		openIngredientFilter("Stuff")
	end)
	unseenChip = chip(5, CHIP_WIDE, function()
		cue("Click")
		unseenOnly = not unseenOnly
		refresh()
	end)

	local reset = chip(6, CHIP_NARROW, function()
		cue("Click")
		rarityFilter = 0
		critterFilter = ""
		stuffFilter = ""
		unseenOnly = false
		query = ""
		box.Text = ""
		refresh()
	end)
	reset.Text = "RESET"
	reset.BackgroundColor3 = UiKit.PALETTE.ink
end

local function buildMilestoneStrip(parent: Frame)
	local strip = UiKit.scroll({
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 4,
		Size = UDim2.new(1, -PAD * 2, 0, MILESTONE_HEIGHT),
		Position = UDim2.new(0, PAD, 1, -(PAD + MILESTONE_HEIGHT)),
		Parent = parent,
	})
	UiKit.list(strip, {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
	})
	milestoneStrip = strip

	for index, milestone in MILESTONES do
		local pill = UiKit.frame({
			BackgroundColor3 = UiKit.PALETTE.ink,
			Size = UDim2.fromOffset(MILESTONE_WIDTH, MILESTONE_HEIGHT),
			Corner = 10,
			Stroke = UiKit.PALETTE.stroke,
			LayoutOrder = index,
			Parent = strip,
		})

		local label = UiKit.label({
			Text = string.upper(milestone.title),
			TextXAlignment = Enum.TextXAlignment.Left,
			Size = UDim2.new(1, -16, 0, 15),
			Position = UDim2.fromOffset(8, 1),
			Parent = pill,
		})
		textCeiling(label, 14)

		local sub = UiKit.label({
			Text = "",
			TextColor3 = UiKit.PALETTE.muted,
			Font = UiKit.FONT_BODY,
			TextXAlignment = Enum.TextXAlignment.Left,
			Size = UDim2.new(1, -16, 0, 12),
			Position = UDim2.fromOffset(8, 16),
			Parent = pill,
		})
		textCeiling(sub, 11)

		milestonePills[index] = { frame = pill, label = label, sub = sub }
	end
end

local function buildSheet(parent: Frame)
	--[[
		An overlay inside the panel rather than a second ScreenGui: it must sit
		under HudController's CLOSE button, which lives in the stage at ZIndex
		20, so closing the whole Mixdex is never blocked by a filter list the
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
	textCeiling(title, 24)
	sheetTitle = title

	local body = UDim2.new(1, -PAD * 2, 1, -(PAD * 2 + TITLE_HEIGHT + GAP * 2 + ROW))
	local bodyAt = UDim2.fromOffset(PAD, PAD + TITLE_HEIGHT + GAP)

	local list = UiKit.scroll({
		Position = bodyAt,
		Size = body,
		Parent = frame,
	})
	UiKit.list(list, { Padding = UDim.new(0, GAP) })
	sheetList = list

	local card = UiKit.frame({
		BackgroundTransparency = 1,
		Position = bodyAt,
		Size = body,
		Visible = false,
		Parent = frame,
	})
	detail = card

	local art, setModel = UiKit.viewport({
		Size = UDim2.fromOffset(DETAIL_ART, DETAIL_ART),
		Position = UDim2.new(0.5, 0, 0, 0),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = card,
	})
	detailArt = art
	detailSetModel = setModel

	local function line(order: number, height: number, color: Color3, font: Enum.Font, ceiling: number): TextLabel
		local label = UiKit.label({
			Text = "",
			TextColor3 = color,
			Font = font,
			TextWrapped = true,
			Size = UDim2.new(1, 0, 0, height),
			Position = UDim2.fromOffset(0, DETAIL_ART + 4 + order * DETAIL_ROW),
			Parent = card,
		})
		textCeiling(label, ceiling)
		return label
	end

	detailName = line(0, 26, UiKit.PALETTE.text, UiKit.FONT, 26)
	detailTier = line(1, DETAIL_ROW, UiKit.PALETTE.muted, UiKit.FONT_BODY, 15)
	detailRate = line(2, DETAIL_ROW, UiKit.PALETTE.goop, UiKit.FONT_BODY, 15)
	detailRecipe = line(3, DETAIL_ROW, UiKit.PALETTE.text, UiKit.FONT_BODY, 15)
	detailHint = line(4, DETAIL_ROW * 2, UiKit.PALETTE.muted, UiKit.FONT_BODY, 14)

	--[[
		The one thing this screen can send the player off to do. It fills the
		Mixer's two slots and opens it through the host; it spends nothing and
		promises nothing — MixerUIController greys its own MIX button when the
		ingredients are not owned, and the server re-checks that anyway.
	]]
	local mix = UiKit.button({
		Text = "MIX THIS",
		BackgroundColor3 = UiKit.PALETTE.goop,
		TextColor3 = UiKit.PALETTE.ink,
		Corner = 12,
		Size = UDim2.new(1, 0, 0, ROW),
		Position = UDim2.new(0.5, 0, 1, 0),
		AnchorPoint = Vector2.new(0.5, 1),
		Parent = card,
	}, function()
		local entry = detailEntry
		if not entry or entry.critter == "" or entry.stuff == "" then
			return
		end
		cue("Click")
		closeSheet()
		if mixer and mixer.prefill then
			mixer.prefill(entry.critter, entry.stuff)
		end
		if hud then
			hud.openPanel(MIXER_PANEL)
		end
	end)
	textCeiling(mix, 22)
	detailMix = mix

	local back = UiKit.button({
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
	textCeiling(back, 22)
end

local function buildPanel(): Frame
	local frame = UiKit.frame({
		BackgroundColor3 = UiKit.PALETTE.panel,
		Corner = 16,
		Stroke = UiKit.PALETTE.stroke,
		ClipsDescendants = true,
	})

	buildHeader(frame)
	buildFilters(frame)

	local scroll = UiKit.scroll({
		-- Virtualised: the canvas is set from the row count and the tiles are
		-- placed by offset, so AutomaticCanvasSize must be off or it would
		-- measure a canvas that only ever holds the visible slice.
		AutomaticCanvasSize = Enum.AutomaticSize.None,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		CanvasSize = UDim2.new(),
		Position = UDim2.fromOffset(PAD, PAD + HEADER_TALL + GAP + FILTER_HEIGHT + GAP),
		Size = UDim2.new(1, -PAD * 2, 0, CELL_MIN),
		Parent = frame,
	})
	gridScroll = scroll

	local empty = UiKit.label({
		Text = "NOTHING MATCHES THAT FILTER",
		TextColor3 = UiKit.PALETTE.muted,
		Font = UiKit.FONT_BODY,
		Visible = false,
		Size = UDim2.new(1, -PAD * 2, 0, CELL_MIN),
		Position = scroll.Position,
		Parent = frame,
	})
	textCeiling(empty, 18)
	emptyLabel = empty

	buildMilestoneStrip(frame)
	buildSheet(frame)

	scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		paint(false)
	end)
	frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)

	return frame
end

-- ── The kiosk (GDD §6) ───────────────────────────────────────────────────

--[[
	Built client-side because it is pure interface: the server has no interest
	in who is standing at the kiosk, and a ProximityPrompt is already the
	touch-friendly control GDD §3 asks for — it renders as a tappable button
	on a phone with no extra work.
]]
local function setPromptsEnabled(on: boolean)
	for _, prompt in prompts do
		prompt.Enabled = on
	end
end

local function attachPrompt(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local part: BasePart = instance
	if prompts[part] then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "MixdexPrompt"
	prompt.ActionText = "Mixdex"
	prompt.ObjectText = "Collection Log"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	prompt.Enabled = not (panel ~= nil and panel.Visible)
	prompt.Parent = part
	prompt.Triggered:Connect(function()
		cue("Click")
		MixdexController.open()
	end)
	prompts[part] = prompt
end

local function detachPrompt(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local part: BasePart = instance
	local prompt = prompts[part]
	prompts[part] = nil
	if prompt then
		prompt:Destroy()
	end
end

-- ── Registry API ─────────────────────────────────────────────────────────

function MixdexController.open()
	if hud then
		hud.openPanel(PANEL_NAME)
	end
end

function MixdexController.close()
	if hud then
		hud.closePanel(PANEL_NAME)
	end
end

--[[
	What MixdexService.progress reports, plus the percentage this panel and
	the HUD both print. Every figure is the server's; the fallback denominator
	is the frozen config both realms count from, and it is only ever seen in
	the frames before the first sync lands.
]]
function MixdexController.progress(): (number, number, number)
	local found, total = discoveredNow()
	return found, total, percentOf(found, total)
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

function MixdexController.init(controllers: { [string]: any })
	hud = controllers.HudController
	sound = controllers.SoundController
	-- The detail card's MIX THIS fills the Mixer's slots; captured, never
	-- required (ARCHITECTURE §3).
	mixer = controllers.MixerUIController
end

function MixdexController.start()
	local frame = buildPanel()
	panel = frame

	if hud then
		hud.registerPanel(PANEL_NAME, frame)
	else
		warn("[Mixdex] no HudController; the Mixdex panel has nowhere to live")
	end

	--[[
		The HUD's cluster button shows this panel directly, without going
		through open(), so it repaints off its own visibility rather than off
		the call that opened it. Closing drops the sheet and hands the kiosk
		prompt back, so walking away and returning is never a second tap on a
		prompt that is still disabled.
	]]
	frame:GetPropertyChangedSignal("Visible"):Connect(function()
		if not frame.Visible then
			closeSheet()
			setPromptsEnabled(true)
			-- Nothing off-screen keeps a model: the pool is released whole.
			for _, tile in tiles do
				hideTile(tile)
			end
			paintedFirst, paintedLast = 0, -1
			return
		end
		setPromptsEnabled(false)
		if dirty then
			-- Discoveries that landed while this was closed; the chrome is
			-- cheap and the grid is repainted by layout() a line below either
			-- way, so nothing is drawn twice.
			dirty = false
			renderChips()
			renderProgress()
			renderMilestones()
		end
		-- The stage resizes while hidden, so the grid is re-measured, rebuilt
		-- and repainted on every show rather than trusting stale geometry.
		layout()
	end)

	--[[
		While the panel is closed a discovery only sets a flag: rebuilding 261
		rows on every roll for a screen nobody is looking at is exactly the
		cost this file exists to avoid.
	]]
	local WATCHED = {
		mixdex = true,
		secretsFound = true,
		secrets = true,
		titles = true,
		mixdexDiscovered = true,
		mixdexTotal = true,
		settings = true,
	}

	ClientState.changed:connect(function(keys: any)
		if type(keys) ~= "table" then
			return
		end
		if not keysInclude(keys :: { string }, WATCHED) then
			return
		end
		dirty = true
		if panel and panel.Visible then
			refresh()
		end
	end)

	-- One repaint on the first full sync for a player who opened the panel
	-- before their profile landed.
	ClientState.ready:connect(function()
		dirty = true
		if panel and panel.Visible then
			refresh()
		end
	end)

	--[[
		The only per-frame work on this screen, and it drives exactly one
		model: the detail card's. The grid's tiles are deliberately static —
		see the header.
	]]
	RunService.Heartbeat:Connect(function(delta: number)
		local model = detailModel
		if not model or lowFx() then
			return
		end
		spinAngle += delta * SPIN_SPEED
		model:PivotTo(CFrame.Angles(0, spinAngle, 0))
	end)

	for _, trigger in CollectionService:GetTagged(KIOSK_TAG) do
		attachPrompt(trigger)
	end
	CollectionService:GetInstanceAddedSignal(KIOSK_TAG):Connect(attachPrompt)
	CollectionService:GetInstanceRemovedSignal(KIOSK_TAG):Connect(detachPrompt)

	renderChips()
	renderProgress()
	renderMilestones()
end

return MixdexController
