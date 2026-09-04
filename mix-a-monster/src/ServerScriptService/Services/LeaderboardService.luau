--!strict
--[[
	LeaderboardService.luau — the three global boards on the plaza wall and the
	LeaderboardSync the HUD reads. GDD §8.7.

	OWNS one OrderedDataStore per Constants.LEADERBOARDS entry
	("TotalGoopEarned", "StealsBanked", "RarestScore"), the userId -> name
	cache behind them, and every row of UI on the wall. One entry point:

	  LeaderboardService.submit(player, key, value)

	RARESTSCORE IS COMPUTED, NEVER STORED. It is max(Rarity.score(tier)) over
	the profile's Mixlings — rarity * 1000 + Goop/sec. Keeping it as a profile
	field would mean every path that adds, banks, scraps or steals a Mixling
	had to remember to recompute it, and one missed call leaves a player
	permanently on the board for something they no longer own. Deriving it
	from `profile.mixlings` at refresh time cannot drift.

	STORE NAMES CARRY THEIR OWN VERSION, not PROFILE_VERSION. A leaderboard
	reset (a fresh season, a wipe after an exploit) must be possible without
	touching profiles, and an additive profile migration — the common case,
	which bumps PROFILE_VERSION — must NOT silently blank three boards. The
	two versions are deliberately independent knobs.

	A FAILED READ KEEPS THE LAST GOOD BOARD. Blanking the wall on a transient
	DataStore hiccup looks exactly like "the leaderboard is broken" to a
	player, and a stale board one minute old is indistinguishable from a fresh
	one. Same reasoning for writes: a failed write clears its memo so the next
	refresh retries the value rather than assuming it landed.

	NAMES ARE CACHED FOR THE LIFE OF THE SERVER. GetNameFromUserIdAsync is
	rate-limited per server; re-resolving 75 ids every 60 seconds would
	throttle it within minutes and start returning errors for names we already
	knew. A name that fails to resolve is retried on a timer instead of being
	poisoned into the cache, so one bad minute does not label somebody
	"User 12345" until the server restarts.

	ROWS ARE RECYCLED, NEVER REBUILT. Each board keeps its Frames and only
	rewrites their text; destroying 75 GuiObjects a minute is 75 replication
	deletes and 75 creates for a board that usually changed by one row.

	IN MEMORY-ONLY MODE (Studio with API access off) the boards fall back to
	the players in this server, sorted locally. The wall would otherwise be
	blank forever in the exact environment where the feature is being built.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Config:WaitForChild("Constants"))
local Rarity = require(Config:WaitForChild("Rarity"))
local Net = require(Shared:WaitForChild("Net"))
local Types = require(Shared:WaitForChild("Types"))
local Util = require(Shared:WaitForChild("Util"))

type Profile = Types.Profile
type LeaderboardEntry = Types.LeaderboardEntry

type BoardDef = { key: string, title: string, suffix: string }

type Row = {
	frame: Frame,
	rank: TextLabel,
	name: TextLabel,
	value: TextLabel,
}

type Board = {
	def: BoardDef,
	entries: { LeaderboardEntry }, -- last good read, newest first
	store: OrderedDataStore?,
	part: BasePart?,
	frame: ScrollingFrame?,
	rows: { Row },
}

-- Constants.LEADERBOARDS is a literal, so its inferred type is a sealed
-- record; it is read here through a computed key. Same shape MixdexService
-- uses over Constants.MIXDEX_MILESTONES.
local BOARD_DEFS: { BoardDef } = Constants.LEADERBOARDS :: any

local LeaderboardService = {}
LeaderboardService.Name = "LeaderboardService"

-- ── Local tunables ───────────────────────────────────────────────────────
-- None of these is a balance value (GDD §17 covers what the player feels):
-- they are store naming, infrastructure retry budgets and sign geometry.

local STORE_PREFIX = "MixAMonster_LB_"
local STORE_VERSION = 1 -- bump to reset every board; independent of PROFILE_VERSION on purpose

local RETRY_ATTEMPTS = 3 -- DataService uses 4 for profiles; a board is worth less than a save
local RETRY_BACKOFF = 1

-- OrderedDataStore takes a 64-bit integer, but a Luau number stops being an
-- exact integer past 2^53 and a value that rounds on the way in reads back as
-- a different score. Clamp there rather than at the store's own ceiling.
local MAX_VALUE = 2 ^ 53 - 1

local NAME_RETRY_SECONDS = 300 -- how long a failed name lookup is left alone
local MEMO_TTL = 60 -- how long a leaver's submitted-value memo is kept alive

-- The board is a wall panel: nothing can scroll it, so every rank has to be
-- on screen at once. A fixed slot height also means rank 3 is always a third
-- of the way down, whether the board holds four names or twenty-five.
local ROW_HEIGHT = 1 / Constants.LEADERBOARD_SIZE
local RANK_X, RANK_W = 0.02, 0.13
local NAME_X, NAME_W = 0.17, 0.50
local VALUE_X, VALUE_W = 0.68, 0.30

local TEXT_COLOR = Color3.fromRGB(248, 246, 255)
local MUTED_COLOR = Color3.fromRGB(178, 170, 205)
local VALUE_COLOR = Color3.fromRGB(146, 232, 96) -- the Goop green the rest of the town signs use
local STRIPE_COLOR = Color3.fromRGB(255, 255, 255)
local STRIPE_TRANSPARENCY = 0.92
local RANK_COLORS = { -- gold, silver, bronze; every other rank is muted
	Color3.fromRGB(255, 210, 74),
	Color3.fromRGB(214, 219, 232),
	Color3.fromRGB(214, 148, 88),
}

local EMPTY_TEXT = "NO SCORES YET"
local ROW_HEIGHT_SCORE = 1000 -- Rarity.score packs the tier as score // 1000

-- ── State ────────────────────────────────────────────────────────────────

local data: any = nil
local analytics: any = nil
local world: any = nil

local boards: { Board } = {}
local byKey: { [string]: Board } = {}

local nameCache: { [number]: string } = {}
local nameRetryAt: { [number]: number } = {}

-- userId -> board key -> the value last written for it. Values on all three
-- boards only ever grow, so re-writing an unchanged number buys nothing and
-- spends from a per-minute write budget shared with every other player.
local submitted: { [number]: { [string]: number } } = {}

local storesDisabled = false
local refreshedAt = 0

for _, def in BOARD_DEFS do
	local board: Board = { def = def, entries = {}, store = nil, part = nil, frame = nil, rows = {} }
	table.insert(boards, board)
	byKey[def.key] = board
end

-- ── Values ───────────────────────────────────────────────────────────────
-- The three keys GDD §8.7 names. They are config keys rather than balance
-- numbers, so they are matched literally here; a fourth board added to
-- Constants without a case below would sit at zero forever, which is why the
-- boot check further down says so out loud.

local KEY_GOOP = "TotalGoopEarned"
local KEY_STEALS = "StealsBanked"
local KEY_RAREST = "RarestScore"

local function rarestScore(profile: Profile): number
	local best = 0
	for _, mixling in profile.mixlings do
		local score = Rarity.score(mixling.rarity)
		if score > best then
			best = score
		end
	end
	return best
end

local function valueFor(profile: Profile, key: string): number
	if key == KEY_GOOP then
		return profile.totalGoopEarned
	elseif key == KEY_STEALS then
		return profile.stats.stealsBanked
	elseif key == KEY_RAREST then
		return rarestScore(profile)
	end
	return 0
end

--[[
	Returns the value as the store must hold it, or nil when it must not be
	written at all. Zero is refused deliberately: a player with no steals on
	the "BEST THIEF" board is not a thief, and on a quiet day a wall of zeroes
	is what the whole server would read.
]]
local function storeValue(value: any): number?
	if not Net.isFiniteNumber(value) then
		return nil
	end
	local whole = math.floor(value :: number)
	if whole < 1 then
		return nil
	end
	return math.min(whole, MAX_VALUE)
end

-- ── Store access ─────────────────────────────────────────────────────────

local function offline(): boolean
	if storesDisabled then
		return true
	end
	return data ~= nil and data.isMemoryOnly()
end

local function storeFor(board: Board): OrderedDataStore?
	local existing = board.store
	if existing then
		return existing
	end
	if offline() then
		return nil
	end

	local name = ("%s%s_v%d"):format(STORE_PREFIX, board.def.key, STORE_VERSION)
	local ok, result = pcall(function()
		return DataStoreService:GetOrderedDataStore(name)
	end)
	if ok then
		board.store = result
		return result
	end

	-- One failure here means DataStores are unavailable for this whole
	-- server, not for this board; stop asking and fall back to local boards.
	storesDisabled = true
	warn(("[Leaderboard] DataStores unavailable (%s); the wall will show this server only."):format(tostring(result)))
	return nil
end

-- ── Writing ──────────────────────────────────────────────────────────────

--[[
	Records the intent to write and answers whether a write is actually
	needed. Splitting this from the write itself is what lets `submit` stay
	non-yielding for its callers while the refresh loop writes sequentially.
]]
local function claim(userId: number, key: string, value: number): number?
	local wanted = storeValue(value)
	if not wanted then
		return nil
	end
	local memo = submitted[userId]
	if not memo then
		memo = {}
		submitted[userId] = memo
	end
	if memo[key] == wanted then
		return nil
	end
	memo[key] = wanted
	return wanted
end

local function writeValue(board: Board, userId: number, value: number)
	local store = storeFor(board)
	if not store then
		return
	end

	local ok, err = Util.retry(RETRY_ATTEMPTS, RETRY_BACKOFF, function()
		return store:SetAsync(tostring(userId), value)
	end)
	if ok then
		return
	end

	-- Drop the memo so the next refresh retries this value instead of
	-- believing the board already holds it.
	local memo = submitted[userId]
	if memo then
		memo[board.def.key] = nil
	end
	warn(("[Leaderboard] write to %s failed for %d: %s"):format(board.def.key, userId, tostring(err)))
	if analytics then
		analytics.event("LeaderboardWriteFailed", { key = board.def.key, userId = userId })
	end
end

-- ── Names ────────────────────────────────────────────────────────────────

local function nameFor(userId: number): string
	local cached = nameCache[userId]
	if cached then
		return cached
	end

	-- Free for anyone standing in the server, and a username never changes
	-- mid-session, so it is worth caching from here too.
	local present = Players:GetPlayerByUserId(userId)
	if present then
		nameCache[userId] = present.Name
		return present.Name
	end

	local retryAt = nameRetryAt[userId]
	local fallback = "User " .. tostring(userId)
	if retryAt and os.clock() < retryAt then
		return fallback
	end

	local ok, result = Util.retry(RETRY_ATTEMPTS, RETRY_BACKOFF, function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and type(result) == "string" and #result > 0 then
		nameCache[userId] = result
		nameRetryAt[userId] = nil
		return result
	end

	-- Deleted accounts and a throttled endpoint look identical from here, so
	-- the id is parked rather than poisoned with the fallback.
	nameRetryAt[userId] = os.clock() + NAME_RETRY_SECONDS
	return fallback
end

-- ── Reading ──────────────────────────────────────────────────────────────

local function readBoard(board: Board)
	local store = storeFor(board)
	if not store then
		return
	end

	local ok, result = Util.retry(RETRY_ATTEMPTS, RETRY_BACKOFF, function()
		return store:GetSortedAsync(false, Constants.LEADERBOARD_SIZE):GetCurrentPage()
	end)
	if not ok then
		warn(("[Leaderboard] read of %s failed, keeping the last board: %s"):format(board.def.key, tostring(result)))
		if analytics then
			analytics.event("LeaderboardReadFailed", { key = board.def.key })
		end
		return
	end

	local page = result :: { any }
	local entries: { LeaderboardEntry } = {}
	for _, row in page do
		if type(row) ~= "table" then
			continue
		end
		local userId = tonumber(row.key)
		local value = storeValue(row.value)
		if userId and value then
			table.insert(entries, { userId = userId, name = nameFor(userId), value = value })
		end
		if #entries >= Constants.LEADERBOARD_SIZE then
			break
		end
	end
	board.entries = entries
end

--[[
	The Studio path: no DataStores, so the board is whoever is standing here.
	Same shape and the same ordering, so nothing downstream knows the
	difference.
]]
local function readLocalBoards()
	if not data then
		return
	end

	local collected: { [string]: { LeaderboardEntry } } = {}
	for _, board in boards do
		collected[board.def.key] = {}
	end

	data.forEach(function(player: Player, profile: Profile)
		for _, board in boards do
			local value = storeValue(valueFor(profile, board.def.key))
			if value then
				table.insert(collected[board.def.key], { userId = player.UserId, name = player.Name, value = value })
			end
		end
	end)

	for _, board in boards do
		local list = collected[board.def.key]
		table.sort(list, function(a: LeaderboardEntry, b: LeaderboardEntry)
			return a.value > b.value
		end)
		for index = #list, Constants.LEADERBOARD_SIZE + 1, -1 do
			list[index] = nil
		end
		board.entries = list
	end
end

-- ── Rendering ────────────────────────────────────────────────────────────

local function label(parent: Instance, name: string, x: number, width: number, color: Color3, alignment: Enum.TextXAlignment): TextLabel
	local instance = Instance.new("TextLabel")
	instance.Name = name
	instance.BackgroundTransparency = 1
	instance.Position = UDim2.fromScale(x, 0)
	instance.Size = UDim2.fromScale(width, 1)
	instance.Font = Enum.Font.FredokaOne
	instance.Text = ""
	instance.TextColor3 = color
	instance.TextScaled = true
	instance.TextXAlignment = alignment
	instance.Parent = parent
	return instance
end

local function newRow(parent: ScrollingFrame, rank: number): Row
	local frame = Instance.new("Frame")
	frame.Name = ("Row%02d"):format(rank)
	frame.LayoutOrder = rank
	frame.Size = UDim2.fromScale(1, ROW_HEIGHT)
	frame.BorderSizePixel = 0
	-- Zebra striping over the board's own dark panel; the alternative is a
	-- twenty-five line wall of identical text nobody can track a row across.
	frame.BackgroundColor3 = STRIPE_COLOR
	frame.BackgroundTransparency = if rank % 2 == 0 then STRIPE_TRANSPARENCY else 1
	frame.Parent = parent

	return {
		frame = frame,
		rank = label(frame, "Rank", RANK_X, RANK_W, MUTED_COLOR, Enum.TextXAlignment.Right),
		name = label(frame, "Name", NAME_X, NAME_W, TEXT_COLOR, Enum.TextXAlignment.Left),
		value = label(frame, "Value", VALUE_X, VALUE_W, VALUE_COLOR, Enum.TextXAlignment.Right),
	}
end

--[[
	WorldService builds each panel with an empty ScrollingFrame named
	"Entries" and tags the part with its board key, precisely so this service
	only ever writes rows into it (WorldService header, GDD §6).
]]
local function frameFor(board: Board): ScrollingFrame?
	local existing = board.frame
	if existing and existing.Parent then
		return existing
	end

	local part = board.part
	if not part or not part.Parent then
		return nil
	end
	local found = part:FindFirstChild("Entries", true)
	if not found or not found:IsA("ScrollingFrame") then
		return nil
	end
	board.frame = found
	return found
end

local function bindParts()
	if not world then
		return
	end
	-- Panels are built once at boot and never move, so this only ever does
	-- work on the first refresh (or if a board part was destroyed under us).
	local missing = false
	for _, board in boards do
		local part = board.part
		if not part or not part.Parent then
			missing = true
			break
		end
	end
	if not missing then
		return
	end

	local parts: { BasePart } = world.getLeaderboardBoards()
	for index, part in parts do
		local tagged = part:GetAttribute("BoardKey")
		local board = if type(tagged) == "string" then byKey[tagged] else boards[index]
		if board and board.part ~= part then
			board.part = part
			board.frame = nil
			board.rows = {}
		end
	end
end

-- The RarestScore board reads as a colour before it reads as a number: the
-- score packs the tier as its thousands digit (Rarity.score).
local function valueColor(board: Board, value: number): Color3
	if board.def.key ~= KEY_RAREST then
		return VALUE_COLOR
	end
	return Rarity.color(math.floor(value / ROW_HEIGHT_SCORE))
end

local function render(board: Board)
	local frame = frameFor(board)
	if not frame then
		return
	end

	local entries = board.entries
	local shown = math.max(#entries, 1) -- an empty board still says so

	for rank = 1, shown do
		local row = board.rows[rank]
		if not row then
			row = newRow(frame, rank)
			board.rows[rank] = row
		end

		local entry = entries[rank]
		if entry then
			row.rank.Text = tostring(rank)
			row.rank.TextColor3 = RANK_COLORS[rank] or MUTED_COLOR
			row.name.Text = entry.name
			row.name.TextColor3 = TEXT_COLOR
			row.value.Text = Util.abbreviate(entry.value) .. board.def.suffix
			row.value.TextColor3 = valueColor(board, entry.value)
		else
			row.rank.Text = ""
			row.name.Text = EMPTY_TEXT
			row.name.TextColor3 = MUTED_COLOR
			row.value.Text = ""
		end
		row.frame.Visible = true
	end

	-- Kept, not destroyed: the next refresh usually needs them back, and a
	-- hidden Frame is skipped by the UIListLayout anyway.
	for rank = shown + 1, #board.rows do
		board.rows[rank].frame.Visible = false
	end
end

-- ── Sync ─────────────────────────────────────────────────────────────────

--[[
	The wire shape is { [boardKey]: { LeaderboardEntry } }. Whole boards go
	out, not a truncated top few: the HUD shows a compact slice (GDD §10) but
	a full-board panel is the same data, and a minute-old table of 75 rows is
	cheaper than a second remote for the long form.

	`board.entries` is replaced wholesale on every read and never mutated in
	place, so handing the live table to Net is safe.
]]
local function payload(): { [string]: { LeaderboardEntry } }
	local out: { [string]: { LeaderboardEntry } } = {}
	for _, board in boards do
		out[board.def.key] = board.entries
	end
	return out
end

-- ── Refresh ──────────────────────────────────────────────────────────────

--[[
	Values are collected first and written afterwards. `data.forEach` walks
	the live profile table, so yielding inside it would let a player load or
	release mid-iteration; and writing sequentially, rather than spawning a
	task per value, keeps this server inside the per-minute OrderedDataStore
	write budget instead of firing thirty requests at once.
]]
local function submitEveryone()
	if not data or offline() then
		return
	end

	type PendingWrite = { board: Board, userId: number, value: number }
	local writes: { PendingWrite } = {}

	data.forEach(function(player: Player, profile: Profile)
		for _, board in boards do
			local value = claim(player.UserId, board.def.key, valueFor(profile, board.def.key))
			if value then
				table.insert(writes, { board = board, userId = player.UserId, value = value })
			end
		end
	end)

	for _, write in writes do
		writeValue(write.board, write.userId, write.value)
	end
end

local function refresh()
	bindParts()
	submitEveryone()

	if offline() then
		readLocalBoards()
	else
		for _, board in boards do
			readBoard(board)
		end
	end

	for _, board in boards do
		render(board)
	end

	refreshedAt = os.clock()
	Net.fireAll("LeaderboardSync", payload())
end

-- ── Public API ───────────────────────────────────────────────────────────

--[[
	Records `value` for `player` on the `key` board. Never yields: the write
	is spawned, so this is safe to call from a remote handler or from
	DataService.onReleasing.

	The server decides what a score is; `key` and `value` come from server
	code only, and both are validated here because a wrong key would create a
	store nobody reads and a NaN would corrupt an ordered index.
]]
function LeaderboardService.submit(player: Player, key: string, value: number)
	if not Net.isString(key) then
		warn("[Leaderboard] submit() called with a bad key: " .. tostring(key))
		return
	end
	local board = byKey[key]
	if not board then
		warn(("[Leaderboard] submit() called with unknown key %q; it must be listed in Constants.LEADERBOARDS"):format(key))
		return
	end
	if not Net.isFiniteNumber(value) then
		warn(("[Leaderboard] submit() called with a bad value for %s: %s"):format(key, tostring(value)))
		return
	end
	if offline() then
		return
	end

	local wanted = claim(player.UserId, key, value)
	if not wanted then
		return
	end
	task.spawn(writeValue, board, player.UserId, wanted)
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

function LeaderboardService.init(services: { [string]: any })
	data = services.DataService
	analytics = services.AnalyticsService
	-- Not in the documented dependency list for this service, but the boards
	-- are WorldService's parts: without it there is nothing to render into.
	world = services.WorldService
end

function LeaderboardService.start()
	if not data then
		warn("[Leaderboard] DataService is missing; the boards will read but nothing will be submitted.")
	end
	if not world then
		warn("[Leaderboard] WorldService is missing; scores still sync to clients but no wall panel will be drawn.")
	end

	for _, board in boards do
		if board.def.key ~= KEY_GOOP and board.def.key ~= KEY_STEALS and board.def.key ~= KEY_RAREST then
			warn(("[Leaderboard] no value is computed for board %q; it will stay empty until valueFor() knows it"):format(board.def.key))
		end
	end

	-- A player who joins between refreshes should not stare at an empty HUD
	-- board for up to a minute.
	Players.PlayerAdded:Connect(function(player)
		if refreshedAt > 0 then
			Net.fire(player, "LeaderboardSync", payload())
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		local userId = player.UserId
		-- Outlives the release submit below, then stops this table from
		-- growing for the life of the server.
		task.delay(MEMO_TTL, function()
			if not Players:GetPlayerByUserId(userId) then
				submitted[userId] = nil
			end
		end)
	end)

	if data then
		-- A player who leaves right after a big steal would otherwise miss the
		-- board entirely until their next session. This runs on the leaving
		-- profile's last synchronous moment and never yields it.
		data.onReleasing:connect(function(player: Player, profile: Profile)
			for _, board in boards do
				LeaderboardService.submit(player, board.def.key, valueFor(profile, board.def.key))
			end
		end)
	end

	task.spawn(function()
		while true do
			-- One bad refresh (a hostile page payload, a destroyed board part)
			-- must not end the loop for the rest of the server's life.
			-- The declared `any` return is what makes pcall hand back the
			-- error text; pcall over a function returning nothing yields
			-- only the success flag.
			local ok, err = pcall(function(): any
				refresh()
				return nil
			end)
			if not ok then
				warn("[Leaderboard] refresh failed: " .. tostring(err))
			end
			task.wait(Constants.LEADERBOARD_REFRESH)
		end
	end)
end

return LeaderboardService
