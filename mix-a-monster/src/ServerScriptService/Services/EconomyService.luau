--!strict
--[[
	EconomyService.luau — Goop: the balance, the faucet, and the only door
	out. GDD §8.2, §11.4.

	OWNS every read and write of `profile.goop`:

	  getBalance(player)                   -> number
	  award(player, amount, source)        -> new balance
	  trySpend(player, amount, sink)       -> boolean; atomic, false if short
	  getGoopPerSec(player)                -> placed Mixlings x multipliers
	  recompute(player)                    -- after any placement change
	  getMultiplier(player)                -> number
	  onBalanceChanged : Signal(player, goop)

	TRYSPEND IS THE ONLY EXIT. Ingredients, Den slots, lock upgrades — every
	sink in the game goes through `trySpend`, and no other service may
	decrement `profile.goop`. "Can they afford it?" and "take it" have to be
	one indivisible step; two services each doing their own check-then-write
	is exactly how one balance buys two things.

	ONE TICK, NOT ONE PER PLAYER (GDD §11.4). A single loop wakes every
	Constants.GOOP_TICK_SECONDS and walks the loaded profiles once through
	DataService.forEach. Ten players cost one loop, not ten.

	THE TICK NEVER WALKS A MIXLING LIST. `recompute` does that — on load and
	after a placement change — and caches the base rate. The tick multiplies
	that cache by the current multiplier, which is O(1) and is also how a 2x
	pass bought mid-session is picked up within a second with nobody telling
	us about it.

	FRACTIONS CARRY. Balances are whole Goop, so a 1.5x event on a 1 Goop/sec
	Den would otherwise round up to 2 (a silent 33% raise) or floor to 1 (a
	silent pay cut). The remainder is carried between ticks instead, so a
	player earns exactly what the HUD's goopPerSec promised them.

	IDLE TELEMETRY IS ROLLED UP. `award` logs one economy row per call, which
	is what GDD §15 wants from a faucet — but the accrual tick is a constant
	trickle, and a row per player per second would swamp both the dashboard
	and Roblox's event budget describing something one number already
	describes. The tick sums its own earnings instead and emits a single
	"Idle" row per player per IDLE_REPORT_SECONDS, plus a final one when the
	profile is released.
]]

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

local EconomyService = {}
EconomyService.Name = "EconomyService"

EconomyService.onBalanceChanged = Util.signal()

-- ── Tunables ─────────────────────────────────────────────────────────────
-- Telemetry cadences and dashboard labels, not balance values, so none of
-- them belong in Constants (GDD §17 covers what the player feels).

local IDLE_SOURCE = "Idle" -- the GDD §15 economy row for placed-Mixling income
local IDLE_REPORT_SECONDS = 60 -- how often the rolled-up accrual row is emitted
local WARN_INTERVAL = 30 -- seconds between repeated complaints from the tick

-- ── State ────────────────────────────────────────────────────────────────

local data: any = nil
local monetization: any = nil
local analytics: any = nil

-- Goop/sec from what is on the pedestals, BEFORE multipliers. Rebuilt only
-- by `recompute`; absent means "this player's cache has not been built yet".
local baseRate: { [Player]: number } = {}

-- Goop/sec after multipliers: what getGoopPerSec returns and what the client
-- interpolates between pushes (GDD §8.2).
local liveRate: { [Player]: number } = {}

local carry: { [Player]: number } = {} -- sub-1 Goop held over between ticks
local idlePending: { [Player]: number } = {} -- accrued Goop awaiting its analytics row
local lastIdleReportAt = 0
local lastWarnAt = 0

-- Server-wide Goop event. 1x with an elapsed deadline means "no event".
local eventMultiplier = 1
local eventEndsAt = 0

-- ── Amounts ──────────────────────────────────────────────────────────────

local function profileOf(player: Player): Profile?
	if not data then
		return nil
	end
	return data.get(player)
end

--[[
	Whole Goop, never negative, never NaN. A NaN balance can never again be
	compared, spent or repaired — every later `<` against it is false — so it
	must never reach a profile in the first place. A negative amount is a
	caller that meant `trySpend`, and saying so is more use than silently
	treating it as zero. Returns nil when the amount is refused.
]]
local function amountOf(what: string, player: Player, amount: number): number?
	if not Net.isFiniteNumber(amount) or amount < 0 then
		warn(("[EconomyService] %s for %s refused: amount must be a finite, non-negative number, got %s")
			:format(what, player.Name, tostring(amount)))
		return nil
	end
	return math.max(0, Util.round(amount))
end

local function pushBalance(player: Player, profile: Profile)
	if not data then
		return
	end
	data.push(player, { goop = profile.goop, totalGoopEarned = profile.totalGoopEarned })
end

--[[
	The single mutation point for a Goop increase. `source` names the faucet
	for GDD §15; omitting it means the caller reports its own row — only the
	accrual tick does that, and only because it rolls a minute of ticks into
	one line (see the header).
]]
local function credit(player: Player, profile: Profile, amount: number, source: string?): number
	profile.goop += amount
	-- totalGoopEarned is the "TotalGoopEarned" leaderboard key (GDD §8.7) and
	-- a lifetime figure: it counts every faucet and no sink ever reduces it.
	profile.totalGoopEarned += amount

	if source and analytics then
		analytics.economy(player, "Earn", source, amount)
	end
	pushBalance(player, profile)
	EconomyService.onBalanceChanged:fire(player, profile.goop)
	return profile.goop
end

-- ── Rates ────────────────────────────────────────────────────────────────

--[[
	Every multiplier that applies to idle income: the 2x pass (owned by
	MonetizationService, which owns every platform call) times any running
	server event. Defaults to 1 whenever a source is missing or hands back
	something that is not a positive finite number — a bad multiplier must
	degrade to "normal pay", never to a zeroed or NaN rate.
]]
local function computeMultiplier(player: Player): number
	local multiplier = 1

	if monetization then
		local fromPasses = monetization.getGoopMultiplier(player)
		if Net.isFiniteNumber(fromPasses) and fromPasses > 0 then
			multiplier *= fromPasses
		end
	end

	if os.clock() < eventEndsAt then
		multiplier *= eventMultiplier
	end

	return multiplier
end

--[[
	O(1). Re-derives the live rate from the cached base and pushes it to the
	owner only when it actually moved, so a mid-session pass purchase reaches
	the HUD on the next tick without costing a walk of anyone's Mixlings.
]]
local function refreshRate(player: Player): number
	local base = baseRate[player]
	if not base then
		return liveRate[player] or 0
	end

	local perSec = base * computeMultiplier(player)
	if perSec ~= liveRate[player] then
		liveRate[player] = perSec
		if data then
			data.push(player, { goopPerSec = perSec })
		end
	end
	return perSec
end

--[[
	Rebuilds a player's base rate from what is actually on their pedestals.
	Called on load and after every placement change; never from the tick.

	`profile.placed` maps tostring(pedestalIndex) -> mixling.id (DECISIONS
	D3), so ids are resolved against `profile.mixlings`. An id that no longer
	resolves is a Mixling that was stolen, scrapped, or dropped by the profile
	size guard while its pedestal entry outlived it; that entry is deleted
	here rather than re-checked forever.
]]
local function recompute(player: Player)
	local profile = profileOf(player)
	if not profile then
		baseRate[player] = nil
		liveRate[player] = nil
		return
	end

	local tierOf: { [string]: number } = {}
	for _, mixling in profile.mixlings do
		tierOf[mixling.id] = mixling.rarity
	end

	local base = 0
	local counted: { [string]: boolean } = {}
	local stale: { string } = {}

	for slot, id in profile.placed do
		local tier = tierOf[id]
		if not tier then
			table.insert(stale, slot)
		elseif not counted[id] then
			-- One Mixling pays once even if two pedestals claim it. A
			-- duplicate is DenService's to resolve; paying for it twice here
			-- would be silent inflation nobody could trace.
			counted[id] = true
			base += Rarity.goopPerSec(tier)
		end
	end

	-- Collected first, deleted after: removing keys from the table being
	-- iterated is exactly the case generalized iteration does not promise.
	for _, slot in stale do
		profile.placed[slot] = nil
	end

	baseRate[player] = base
	refreshRate(player)
end

-- ── Public API ───────────────────────────────────────────────────────────

EconomyService.getMultiplier = computeMultiplier
EconomyService.recompute = recompute

function EconomyService.getBalance(player: Player): number
	local profile = profileOf(player)
	return if profile then profile.goop else 0
end

function EconomyService.getGoopPerSec(player: Player): number
	if baseRate[player] == nil then
		recompute(player) -- first ask for this session; build the cache once
	end
	return liveRate[player] or 0
end

--[[
	Adds Goop and returns the new balance. `source` is the GDD §15 economy
	row — "Mix", "Daily", "Code", "Product", "Steal" — so it names the faucet,
	not the calling service.
]]
function EconomyService.award(player: Player, amount: number, source: string): number
	local profile = profileOf(player)
	if not profile then
		return 0 -- not loaded (or already released): there is nothing to pay into
	end

	local value = amountOf("award", player, amount)
	if not value or value <= 0 then
		return profile.goop
	end

	local label = if Net.isString(source) then source else "Unknown"
	return credit(player, profile, value, label)
end

--[[
	The one way Goop leaves a profile. Atomic by construction: the balance
	check and the deduction sit in the same function with no yield between
	them, so nothing can interleave and spend the same Goop twice. Returns
	false having mutated nothing when the player is short.
]]
function EconomyService.trySpend(player: Player, amount: number, sink: string): boolean
	local profile = profileOf(player)
	if not profile then
		return false
	end

	local value = amountOf("spend", player, amount)
	if not value then
		return false
	end
	if value <= 0 then
		return true -- free is always affordable, and not worth a telemetry row
	end
	if profile.goop < value then
		return false
	end

	profile.goop -= value
	if analytics then
		analytics.economy(player, "Spend", if Net.isString(sink) then sink else "Unknown", value)
	end
	pushBalance(player, profile)
	EconomyService.onBalanceChanged:fire(player, profile.goop)
	return true
end

--[[
	Starts a server-wide Goop event (GDD §8.2: "multipliers (2x pass,
	events)"). Deliberately NOT part of the ARCHITECTURE §4 cross-service
	contract — nothing in v1 starts one, because the only event product is
	LuckParty and that multiplies luck, not Goop. It lives here so the
	multiplier has exactly one authoritative home when an event does land, and
	so `getMultiplier` already accounts for it today.

	`multiplier` and `seconds` come from the caller rather than Constants
	because no Goop-event balance values exist there to read.
]]
function EconomyService.startEvent(multiplier: number, seconds: number)
	if not Net.isFiniteNumber(multiplier) or multiplier <= 0 then
		return
	end
	if not Net.isFiniteNumber(seconds) or seconds <= 0 then
		return
	end
	eventMultiplier = multiplier
	eventEndsAt = os.clock() + seconds
	-- No cache to invalidate: the next tick re-derives every live rate from
	-- its base, and a multiplier change never needs a Mixling walk.
end

-- ── The tick ─────────────────────────────────────────────────────────────

local function reportIdle(player: Player)
	local amount = idlePending[player]
	idlePending[player] = nil
	if not amount or amount <= 0 or not analytics then
		return
	end
	analytics.economy(player, "Earn", IDLE_SOURCE, amount)
end

local function flushIdle()
	local now = os.clock()
	if now - lastIdleReportAt < IDLE_REPORT_SECONDS then
		return
	end
	lastIdleReportAt = now

	-- Swapped rather than cleared in place: the rows below are reported after
	-- the table stops being the live accumulator.
	local batch = idlePending
	idlePending = {}
	if not analytics then
		return
	end
	for player, amount in batch do
		if amount > 0 then
			analytics.economy(player, "Earn", IDLE_SOURCE, amount)
		end
	end
end

local function accrue(player: Player, profile: Profile)
	if baseRate[player] == nil then
		-- In memory-only mode DataService.load never yields, so onLoaded can
		-- fire before this service has connected to it.
		recompute(player)
	end

	local perSec = refreshRate(player)
	if perSec <= 0 then
		return -- an empty Den is the common case; it costs nothing here
	end

	-- The nominal tick length, not the measured one: the client interpolates
	-- at exactly goopPerSec between pushes (GDD §8.2), so paying the nominal
	-- amount keeps the ledger and the number on screen in agreement. A
	-- hitching server pays a little less rather than a lump sum afterwards.
	local pending = (carry[player] or 0) + perSec * Constants.GOOP_TICK_SECONDS
	local whole = math.floor(pending)
	carry[player] = pending - whole
	if whole <= 0 then
		return
	end

	credit(player, profile, whole) -- no source: reported rolled up by flushIdle
	idlePending[player] = (idlePending[player] or 0) + whole
end

local function tick()
	if not data then
		return
	end
	data.forEach(function(player: Player, profile: Profile)
		accrue(player, profile)
	end)
	flushIdle()
end

local function warnTick(message: string)
	local now = os.clock()
	if now - lastWarnAt < WARN_INTERVAL then
		return -- a per-second loop failing repeatedly must not become the log
	end
	lastWarnAt = now
	warn("[EconomyService] " .. message)
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

local function forget(player: Player)
	reportIdle(player) -- idempotent; onReleasing normally got here first
	baseRate[player] = nil
	liveRate[player] = nil
	carry[player] = nil
end

function EconomyService.init(services: { [string]: any })
	data = services.DataService
	monetization = services.MonetizationService
	analytics = services.AnalyticsService
end

function EconomyService.start()
	if not data then
		warn("[EconomyService] DataService is missing; no Goop can accrue or be spent.")
		return
	end

	data.onLoaded:connect(function(player: Player)
		recompute(player)
	end)
	-- The last synchronous moment the profile still exists, so the closing
	-- accrual row is logged against a real balance.
	data.onReleasing:connect(function(player: Player)
		reportIdle(player)
	end)

	-- Anyone whose profile loaded before this service started (see accrue).
	for _, player in Players:GetPlayers() do
		recompute(player)
	end
	Players.PlayerRemoving:Connect(forget)

	task.spawn(function()
		while true do
			task.wait(Constants.GOOP_TICK_SECONDS)
			-- The declared `any` return is what makes pcall hand back the
			-- error text, the same shape AnalyticsService.send uses. The loop
			-- has to outlive one bad tick: a dead accrual thread is a game
			-- with no faucet and no error to show for it.
			local ok, err = pcall(function(): any
				tick()
				return nil
			end)
			if not ok then
				warnTick("accrual tick failed: " .. tostring(err))
			end
		end
	end)
end

return EconomyService
