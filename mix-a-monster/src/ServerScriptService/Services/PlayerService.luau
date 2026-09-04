--!strict
--[[
	PlayerService.luau — the session. GDD §5, §7.2, §8.8, §11.2, §11.3.

	OWNS everything that hangs off "a player is here": spawn placement, the
	one full ProfileSync that seeds the client, the starter grant, the daily
	track, `profile.tutorialDone`, `profile.playSeconds`, the shortcut
	teleports, the settings toggles, the scripted 30–60 s showcase, and the
	single `Query` RemoteFunction.

	IT BOOTS LAST, so everything it routes to is already wired. It computes no
	balance number of its own: prices come from ShopService, odds from Rarity,
	luck from MonetizationService's ledger, Den geometry from WorldService.

	NO LOBBY, EVER (GDD §6). WorldService deliberately creates no
	SpawnLocation, so every character — first spawn and every respawn — is
	pivoted into its owner's own Den here. A character that spawns before its
	Den slot exists is standing on the plaza, so placement WAITS for the slot
	rather than dropping the player somewhere they did not choose; a Den that
	never arrives (a server over its ring size) leaves them in the plaza with
	a warning, which is walkable, rather than in the void.

	THE FULL SYNC WAITS FOR THE DEN TOO. `placed` and the two shield fields
	describe a Den, so a full view sent before DenService has a slot would
	tell the client its pedestals are empty and be corrected a second later.
	One full sync per session, sent when there is something true to say;
	everything after it is a delta from whichever service owns the field.

	THE STARTER PAIR IS GATED ON A FLAG, NOT ON AN EMPTY INVENTORY (GDD §7.2,
	"granted once per new profile"). A player who spends Frog + Sock and
	rejoins must not be handed another pair — that is an unlimited free roll,
	which is the exact thing ShopService refuses to sell (a starter ingredient
	is priced 0 and `Ingredients.isPurchasable` rejects it). Types.Profile is
	frozen contract, so the flag is written as an additive key on the profile
	table: `Util.reconcile` only ever FILLS missing keys, so no migration
	strips it, and DataService persists the table whole.

	THE 30–60 s SHOWCASE IS SCRIPTED AND IT IS NOT A REAL ROLL. GDD §5 asks
	for "a bot-roll announcement if the server is quiet" so a new player sees
	the ceiling inside their first minute. If a real Epic+ roll lands while
	they are here, that already did the job and nothing is faked. Otherwise
	one banner goes to that one player. Three safeguards keep the lie
	contained: it is sent through `AnnouncementService.toPlayer` (nobody else
	receives it), it carries no `playerName` so nothing can resolve it back to
	a Player, and it touches no ledger — no `analytics.roll`, no leaderboard
	submit, no Mixdex entry, no profile write. It can only ever be scheduled
	for a profile this server created (see `isFirstSession`), so a returning
	player never sees one.

	TELEPORTING WHILE CARRYING IS REFUSED (DECISIONS D9). "Teleport to my Den"
	while carrying a stolen Mixling is an instant bank; it deletes the chase,
	the bonk and pillar 2 with them. That refusal is the whole reason the
	destination list lives on the server.

	`Query` NEVER YIELDS. A RemoteFunction runs on the caller's thread, so a
	yielding branch stalls that client until it returns — and one
	RemoteFunction has exactly one OnServerInvoke, which is why this service
	owns the callback and every other service exposes a plain read instead
	(ShopService's header explains the same thing from the other side).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = ReplicatedStorage:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Config:WaitForChild("Constants"))
local Ingredients = require(Config:WaitForChild("Ingredients"))
local Rarity = require(Config:WaitForChild("Rarity"))
local Assembler = require(Shared:WaitForChild("MixlingAssembler"))
local Net = require(Shared:WaitForChild("Net"))
local Types = require(Shared:WaitForChild("Types"))
local Util = require(Shared:WaitForChild("Util"))

-- Server-only (GDD §11.3). A found secret's display row is resolved here and
-- sent to the one player who found it; nothing about an unfound secret ever
-- reaches a client.
local SecretRecipes = require(ServerStorage:WaitForChild("SecretRecipes"))

type Profile = Types.Profile
type Mixling = Types.Mixling
type MixlingView = Types.MixlingView
type Announcement = Types.Announcement

local PlayerService = {}
PlayerService.Name = "PlayerService"

-- ── Wire shapes ──────────────────────────────────────────────────────────

--[[
	What a found secret looks like to its finder. The ingredients are in here
	because the Mixdex card draws the assembled model, and the player already
	holds a Mixling that names them — this reveals nothing they did not earn.
]]
export type SecretView = {
	id: string,
	name: string,
	critter: string,
	stuff: string,
	rarity: number,
	displayName: string,
	goopPerSec: number,
}

-- Everything the daily panel needs to draw the 7-day track without knowing a
-- single rule. Derived, so it is a sibling of `daily` rather than part of it:
-- `profile.daily` is persisted state and stays exactly Types.Daily.
export type DailyState = {
	streak: number,
	lastClaim: number,
	day: number, -- which slot of the track the NEXT claim pays
	days: number, -- length of the track
	amount: number, -- what that claim pays, VIP included
	multiplier: number,
	ready: boolean,
	nextAt: number, -- os.time() when the next claim opens
}

--[[
	The full sync payload: Types.ProfileView, with two deliberate departures.

	  * `mixlings` carries MixlingViews, not raw Mixlings. Every delta already
	    does (MixerService's `mixlingAdded`) and the client's cache is typed
	    that way, so a full send of raw rows would be the only shape on the
	    wire without a display name or a rate.
	  * `secrets`, `dailyState` and the two Mixdex figures are added: all of
	    them are server-resolved data the client cannot derive, and none of
	    them exists as a profile field.
]]
type SyncView = {
	goop: number,
	goopPerSec: number,
	totalGoopEarned: number,
	inventory: { [string]: number },
	mixlings: { MixlingView },
	placed: { [string]: string },
	denSlots: number,
	denSlotsTotal: number,
	lockLevel: number,
	mixdex: { [string]: number },
	secretsFound: { [string]: boolean },
	secrets: { [string]: SecretView },
	mixdexDiscovered: number,
	mixdexTotal: number,
	stats: Types.Stats,
	daily: Types.Daily,
	dailyState: DailyState,
	passes: { [string]: boolean },
	titles: { [string]: boolean },
	settings: Types.Settings,
	codes: { [string]: boolean },
	tutorialDone: boolean,
	shielded: boolean,
	shieldEndsAt: number,
	luck: number,
}

-- ── Tunables ─────────────────────────────────────────────────────────────
-- Cadences, waits, protocol labels and stand-off geometry. None of them is a
-- balance value — GDD §17 covers what the player feels — so none belongs in
-- Constants, the same call EconomyService and DenService make for their own.

local CHARACTER_WAIT = 10 -- seconds to wait for a HumanoidRootPart to exist
local DEN_WAIT = 30 -- seconds to wait for DenService to hand out a slot
local POLL = 0.1 -- how often those two waits look again

local PLAY_TICK_SECONDS = 15 -- how often playSeconds is written; one loop for everyone
local TELEPORT_HEIGHT = 4 -- a spawn CFrame positions the HumanoidRootPart, not the feet
local TELEPORT_STAND_OFF = 18 -- studs plaza-side of a structure's anchor: outside its wall, facing it

local DAILY_SOURCE = "daily" -- the GDD §15 economy row for the retention faucet
local BADGE_STREAK = "Streak7" -- indexes Constants.BADGES
local NOTIFY_DAILY = "Daily"
local NOTIFY_SESSION = "Session"

local NOT_LOADED = "Still loading your stuff — try again in a second."
local DAILY_CLOSED = "The daily reward is unavailable right now."
local CARRYING = "Not while you are carrying that — run it home yourself!"

-- The client reports these three beats (GDD §5). The server records that they
-- happened and nothing else: the beams, bubbles and paths are the client's,
-- and nothing here gates movement.
--[[
	The three steps that MEAN the tutorial is finished. tutorialDone flips when
	the profile holds all three, so the server decides completion from what the
	player actually did rather than from a client saying it is done.

	"done" is accepted as a synonym for "the client believes it has finished"
	and is recorded for telemetry, but it does not by itself complete anything —
	see recordStep.
]]
local TUTORIAL_STEPS = { "mixed", "placed", "bought" }
local TUTORIAL_DONE_STEP = "done"

-- The scripted banner names its roller in prose only. It is deliberately not
-- a username: no player rolled this, and nothing may be able to look one up.
local SHOWCASE_ROLLER = "a mixer across the plaza"
local SHOWCASE_EVENT = "TutorialShowcase" -- its own telemetry row; never a roll row

-- ── State ────────────────────────────────────────────────────────────────

local data: any = nil
local den: any = nil
local economy: any = nil
local shop: any = nil
local steal: any = nil
local monetization: any = nil
local announcements: any = nil
local leaderboards: any = nil
local mixdex: any = nil
local analytics: any = nil
local world: any = nil
local mixer: any = nil

-- Session bookkeeping. `sessionStart` doubles as "this service has handled
-- this player's load", which is what stops the connect-then-sweep in `start`
-- from running the arrival twice.
local sessionStart: { [Player]: number } = {} -- os.clock() at profile load
local creditedSeconds: { [Player]: number } = {} -- playSeconds already written
local tutorialSeen: { [Player]: { [string]: boolean } } = {}
local claiming: { [Player]: boolean } = {} -- a daily claim in flight

-- os.clock() of the last Epic+ roll anywhere in this server. A new player who
-- joined before it has seen the ceiling for real, and gets no scripted one.
local lastBigRollAt = 0

local rng = Random.new() -- cosmetic only: which pair the scripted banner names

-- ── Small helpers ────────────────────────────────────────────────────────

local function profileOf(player: Player): Profile?
	if not data then
		return nil
	end
	return data.get(player)
end

local function notify(player: Player, kind: string, text: string)
	if not player.Parent then
		return
	end
	Net.fire(player, "Notify", kind, text)
end

local function flatUnit(vector: Vector3, fallback: Vector3): Vector3
	local flat = Vector3.new(vector.X, 0, vector.Z)
	if flat.Magnitude < 1e-3 then
		return fallback
	end
	return flat.Unit
end

-- CFrame.lookAt errors when the two points coincide; a stand position that
-- lands dead on its target is a degenerate geometry case, not a reason to
-- refuse a teleport.
local function lookAtFlat(from: Vector3, target: Vector3): CFrame
	local level = Vector3.new(target.X, from.Y, target.Z)
	if (level - from).Magnitude < 1e-3 then
		return CFrame.new(from)
	end
	return CFrame.lookAt(from, level)
end

local function plazaCenter(): Vector3
	if not world then
		return Vector3.zero
	end
	local center = world.getPlazaCenter()
	return if typeof(center) == "Vector3" then center else Vector3.zero
end

-- The Den slot this player holds in the ring, or nil while they hold none.
local function slotOf(player: Player): number?
	if not den then
		return nil
	end
	local record = den.getDen(player)
	if not record then
		return nil
	end
	local index = record.slotIndex
	if not Net.isIntInRange(index, 1, Constants.SERVER_SIZE) then
		return nil
	end
	return index
end

local function waitForSlot(player: Player): number?
	local deadline = os.clock() + DEN_WAIT
	while true do
		local index = slotOf(player)
		if index then
			return index
		end
		if not player.Parent or os.clock() >= deadline then
			return nil
		end
		task.wait(POLL)
	end
end

-- ── Derived view fields ──────────────────────────────────────────────────

--[[
	Luck without a yield. `MonetizationService.getLuck` calls `hasPass`, which
	queries the platform when the profile's pass cache is cold — and this is
	read from the `Query` handler, which runs on a client thread. The cached
	ledger is the same one that service pushes from, so a cold cache costs one
	stale answer and is corrected by its own push moments later.
]]
local function luckOf(profile: Profile): number
	local luck = 0
	if monetization then
		local server = monetization.getServerLuck()
		if Net.isFiniteNumber(server) then
			luck += server
		end
	end
	if profile.passes.LuckyMixer then
		luck += Constants.PASSES.LuckyMixer.luck
	end
	return luck
end

--[[
	The two figures behind the HUD's Mixdex percentage (GDD §10) live in no
	profile field, so a full view without them would leave the header reading
	0 until MixdexService's own load push arrived. Both are derived from the
	same profile by the same service, so the two pushes cannot disagree.
]]
local function mixdexProgress(player: Player): (number, number)
	if not mixdex then
		return 0, 0
	end
	local discovered, total = mixdex.progress(player)
	if not Net.isFiniteNumber(discovered) or not Net.isFiniteNumber(total) then
		return 0, 0
	end
	return discovered, total
end

local function goopPerSecOf(player: Player): number
	if not economy then
		return 0
	end
	local rate = economy.getGoopPerSec(player)
	return if Net.isFiniteNumber(rate) and rate > 0 then rate else 0
end

--[[
	DenService owns the new-player shield (GDD §8.3) but publishes only the
	boolean, so the stamp the HUD counts down to is recomputed from the same
	profile field and the same constant its `beginShield` uses. Zero whenever
	the shield is not up, so the client never renders a stale countdown.
]]
local function shieldEndsAt(player: Player, profile: Profile): number
	if not den or not den.isShielded(player) then
		return 0
	end
	return profile.firstJoin + Constants.NEW_PLAYER_SHIELD_SECONDS
end

local function specOf(mixling: Mixling): Assembler.BuildSpec
	local secretId = mixling.secretId
	local secret = if secretId ~= nil then SecretRecipes.byId(secretId) else nil
	return {
		critter = mixling.critter,
		stuff = mixling.stuff,
		rarity = mixling.rarity,
		secretId = secretId,
		secretName = if secret then secret.name else nil,
	}
end

-- The same shape MixerService and StealService send, built from the same
-- Assembler call, so one Mixling reads identically on a reveal card, a
-- pedestal plaque and this list (GDD §7.1).
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

local function secretRow(secret: SecretRecipes.Secret): SecretView
	return {
		id = secret.id,
		name = secret.name,
		critter = secret.critter,
		stuff = secret.stuff,
		rarity = Rarity.SECRET,
		displayName = secret.name,
		goopPerSec = Rarity.goopPerSec(Rarity.SECRET),
	}
end

--[[
	Display rows for the secrets this profile has ALREADY FOUND, and nothing
	else. The loop is over `profile.secretsFound` rather than over the recipe
	table precisely so an unfound secret has no path into this payload; a
	falsy entry means "still ???" (MixdexService's ledger) and is skipped.
]]
local function secretRows(profile: Profile): { [string]: SecretView }
	local rows: { [string]: SecretView } = {}
	for id, found in profile.secretsFound do
		if found and Net.isString(id) then
			local secret = SecretRecipes.byId(id)
			if secret then
				rows[id] = secretRow(secret)
			end
		end
	end
	return rows
end

-- ── Daily reward (GDD §8.8) ──────────────────────────────────────────────

local function trackLength(): number
	return #Constants.DAILY_REWARD
end

--[[
	Which day of the escalating track a claim made at `now` would pay.

	Day 1 for a first claim, for a gap past DAILY_MISS_SECONDS (the streak is
	broken), and for the claim after a completed week (the track loops rather
	than paying the last day forever).
]]
local function dayFor(daily: Types.Daily, now: number): number
	if daily.lastClaim <= 0 or now - daily.lastClaim > Constants.DAILY_MISS_SECONDS then
		return 1
	end
	local day = math.floor(daily.streak) + 1
	if day < 1 or day > trackLength() then
		return 1
	end
	return day
end

local function dailyMultiplier(player: Player): number
	if not monetization then
		return 1
	end
	if not monetization.hasPass(player, "VIP") then
		return 1
	end
	local multiplier = Constants.PASSES.VIP.dailyMultiplier
	return if Net.isFiniteNumber(multiplier) and multiplier > 0 then multiplier else 1
end

local function rewardFor(day: number, multiplier: number): number
	local base = Constants.DAILY_REWARD[day]
	if not base or not Net.isFiniteNumber(base) then
		return 0
	end
	return math.floor(base * multiplier)
end

--[[
	A stamp in the future can only come from a clock that moved backwards, and
	it would otherwise hold the track shut forever (every gap reads as
	negative, which is always "too soon"). Repairing it to now costs the
	player one day and self-heals.
]]
local function repairClaimStamp(daily: Types.Daily, now: number)
	if daily.lastClaim > now then
		daily.lastClaim = now
	end
end

local function dailyState(player: Player, profile: Profile): DailyState
	local now = os.time()
	local daily = profile.daily
	repairClaimStamp(daily, now)

	local day = dayFor(daily, now)
	local multiplier = dailyMultiplier(player)
	local nextAt = if daily.lastClaim > 0 then daily.lastClaim + Constants.DAILY_RESET_SECONDS else now

	return {
		streak = daily.streak,
		lastClaim = daily.lastClaim,
		day = day,
		days = trackLength(),
		amount = rewardFor(day, multiplier),
		multiplier = multiplier,
		ready = now >= nextAt,
		nextAt = nextAt,
	}
end

local function pushDaily(player: Player, profile: Profile)
	if not data then
		return
	end
	data.push(player, { daily = profile.daily, dailyState = dailyState(player, profile) })
end

--[[
	One claim. The order is deliberate:

	  1. every refusal happens before anything is written;
	  2. the VIP multiplier is resolved BEFORE the commit, because `hasPass`
	     can yield on a cold cache and the timing check has to still be true
	     at the moment the stamp is written — so it is re-tested afterwards;
	  3. the streak and the stamp are written before the payout, so a second
	     ClaimDaily arriving in the same breath is refused by the clock rather
	     than paid twice. `award` does not yield, so there is no window in
	     which the day is spent and the Goop does not exist.
]]
local function claimDaily(player: Player)
	local profile = profileOf(player)
	if not profile then
		notify(player, NOTIFY_DAILY, NOT_LOADED)
		return
	end
	if not economy then
		notify(player, NOTIFY_DAILY, DAILY_CLOSED)
		return
	end

	local daily = profile.daily
	local now = os.time()
	repairClaimStamp(daily, now)

	if daily.lastClaim > 0 and now - daily.lastClaim < Constants.DAILY_RESET_SECONDS then
		local remaining = Constants.DAILY_RESET_SECONDS - (now - daily.lastClaim)
		notify(player, NOTIFY_DAILY, ("Next reward in %s."):format(Util.clock(remaining)))
		pushDaily(player, profile)
		return
	end

	local multiplier = dailyMultiplier(player)

	-- Re-read after the possible yield: the profile can be released, and the
	-- claim can have landed already, while we were asking about the pass.
	local current = profileOf(player)
	if not current or current.daily ~= daily then
		return
	end
	now = os.time()
	if daily.lastClaim > 0 and now - daily.lastClaim < Constants.DAILY_RESET_SECONDS then
		return
	end

	local day = dayFor(daily, now)
	local amount = rewardFor(day, multiplier)
	if amount <= 0 then
		warn(("[PlayerService] daily day %d has no reward; check Constants.DAILY_REWARD"):format(day))
		notify(player, NOTIFY_DAILY, DAILY_CLOSED)
		return
	end

	daily.streak = day
	daily.lastClaim = now
	economy.award(player, amount, DAILY_SOURCE)

	-- The badge is the completed week (GDD §8.7), so it hangs off the last
	-- day of the track rather than off a hard-coded 7.
	if day >= trackLength() and monetization then
		monetization.awardBadge(player, BADGE_STREAK)
	end

	notify(player, NOTIFY_DAILY, ("Day %d of %d — +%s Goop!"):format(day, trackLength(), Util.abbreviate(amount)))
	pushDaily(player, profile)

	if analytics then
		analytics.event("DailyClaim", { day = day, streak = daily.streak, amount = amount, multiplier = multiplier })
	end
end

-- ── The full sync ────────────────────────────────────────────────────────

local function fullView(player: Player, profile: Profile): SyncView
	local mixlings: { MixlingView } = table.create(#profile.mixlings)
	for _, mixling in profile.mixlings do
		table.insert(mixlings, viewOf(mixling))
	end
	local discovered, total = mixdexProgress(player)

	-- Profile tables go over by reference, the way every delta push does:
	-- Net serialises at fire time and nothing here mutates them afterwards.
	return {
		goop = profile.goop,
		goopPerSec = goopPerSecOf(player),
		totalGoopEarned = profile.totalGoopEarned,
		inventory = profile.inventory,
		mixlings = mixlings,
		placed = profile.placed,
		denSlots = profile.denSlots,
		denSlotsTotal = if den then den.totalSlots(player) else profile.denSlots,
		lockLevel = profile.lockLevel,
		mixdex = profile.mixdex,
		secretsFound = profile.secretsFound,
		secrets = secretRows(profile),
		mixdexDiscovered = discovered,
		mixdexTotal = total,
		stats = profile.stats,
		daily = profile.daily,
		dailyState = dailyState(player, profile),
		passes = profile.passes,
		titles = profile.titles,
		settings = profile.settings,
		codes = profile.codes,
		tutorialDone = profile.tutorialDone,
		shielded = den ~= nil and den.isShielded(player) == true,
		shieldEndsAt = shieldEndsAt(player, profile),
		luck = luckOf(profile),
	}
end

local function sendFullSync(player: Player, profile: Profile)
	if not data or not player.Parent then
		return
	end
	data.push(player, (fullView(player, profile) :: any) :: { [string]: any }, true)
end

-- ── Starter grant (GDD §7.2) ─────────────────────────────────────────────

-- Types.Profile is frozen contract and names no such field; see the header
-- for why an additive key is safe and why the inventory cannot be the ledger.
local STARTER_FLAG = "starterGranted"

local function starterGranted(profile: Profile): boolean
	return (profile :: any)[STARTER_FLAG] == true
end

--[[
	Brand new means "this server created this profile". The starter flag is
	the ledger; `playSeconds` is the second opinion, so a profile that
	predates the flag is repaired with its starter pair exactly once and is
	still never shown the scripted first-minute beat again.
]]
local function isFirstSession(profile: Profile): boolean
	return not starterGranted(profile) and profile.playSeconds <= 0
end

local function grantStarter(player: Player, profile: Profile)
	if starterGranted(profile) then
		return
	end
	(profile :: any)[STARTER_FLAG] = true

	local critter = Constants.STARTER.critter
	local stuff = Constants.STARTER.stuff
	if not Ingredients.isCritter(critter) or not Ingredients.isStuff(stuff) then
		warn(("[PlayerService] Constants.STARTER names %s + %s, which is not a Critter/Stuff pair")
			:format(tostring(critter), tostring(stuff)))
		return
	end

	profile.inventory[critter] = (profile.inventory[critter] or 0) + 1
	profile.inventory[stuff] = (profile.inventory[stuff] or 0) + 1

	if data then
		data.push(player, { inventory = profile.inventory })
	end
	if analytics then
		analytics.event("StarterGranted", { critter = critter, stuff = stuff })
	end
end

-- ── Spawn placement (GDD §5, §6) ─────────────────────────────────────────

local function placeInDen(player: Player, character: Model)
	local root = character:WaitForChild("HumanoidRootPart", CHARACTER_WAIT)
	if not root or not root:IsA("BasePart") then
		warn(("[PlayerService] %s spawned with no HumanoidRootPart; leaving them where they landed"):format(player.Name))
		return
	end

	local slot = waitForSlot(player)
	if not slot then
		-- Every Den in the ring is taken, or the profile never loaded. The
		-- plaza is walkable and every shop is on it, so the session still
		-- works; it is just not the opening GDD §5 asks for.
		warn(("[PlayerService] no Den slot for %s within %ds; spawning them in the plaza"):format(player.Name, DEN_WAIT))
		return
	end

	-- The wait can outlive the character it was started for.
	if character.Parent == nil or player.Character ~= character then
		return
	end
	if not world then
		return
	end

	local target = world.getSpawnFor(slot)
	if typeof(target) ~= "CFrame" then
		warn(("[PlayerService] WorldService gave no spawn CFrame for Den slot %d"):format(slot))
		return
	end
	character:PivotTo(target)
end

local function watchCharacter(player: Player)
	player.CharacterAdded:Connect(function(character: Model)
		task.spawn(placeInDen, player, character)
	end)
	local existing = player.Character
	if existing then
		task.spawn(placeInDen, player, existing)
	end
end

-- ── playSeconds ──────────────────────────────────────────────────────────
-- One loop for every player, the discipline the Goop tick uses (GDD §11.4):
-- ten players cost one loop, not ten. Each player is credited from their own
-- join stamp, so somebody who arrived mid-interval is not paid for it.

local function creditPlayer(player: Player, profile: Profile)
	local started = sessionStart[player]
	if not started then
		return
	end
	local total = os.clock() - started
	local credited = creditedSeconds[player] or 0
	local owed = total - credited
	if owed <= 0 then
		return
	end
	creditedSeconds[player] = total
	profile.playSeconds += owed
end

-- Idempotent: a second call in the same instant credits nothing, which is
-- what lets both PlayerRemoving and onReleasing call it without double
-- counting whichever of them Roblox happens to run first.
local function flushPlaySeconds(player: Player)
	local profile = profileOf(player)
	if profile then
		creditPlayer(player, profile)
	end
end

local function creditEveryone()
	if not data then
		return
	end
	data.forEach(function(player: Player, profile: Profile)
		creditPlayer(player, profile)
	end)
end

-- ── Tutorial (GDD §5) ────────────────────────────────────────────────────
-- The server records that the beats happened. It never gates anything on
-- them: "the tutorial never blocks movement", so there is deliberately no
-- state here that anything else can wait on.

--[[
	Seeded from what the profile already proves, so a returning player who
	rolled and placed long ago finishes the tutorial on the step they are
	actually missing rather than repeating all three. "bought" has no trace in
	a profile — inventory is spent — so it is the one beat only the client can
	report, which is also the beat GDD §5 ends the tutorial on.
]]
local function seedSteps(profile: Profile): { [string]: boolean }
	return {
		mixed = profile.stats.rolls > 0,
		placed = next(profile.placed) ~= nil,
		bought = false,
	}
end

local function recordStep(player: Player, step: string)
	local profile = profileOf(player)
	if not profile or profile.tutorialDone then
		return
	end

	local seen = tutorialSeen[player]
	if not seen then
		seen = seedSteps(profile)
		tutorialSeen[player] = seen
	end
	seen[step] = true

	for _, required in TUTORIAL_STEPS do
		if not seen[required] then
			return
		end
	end

	profile.tutorialDone = true
	if data then
		data.push(player, { tutorialDone = true })
	end
	if analytics then
		analytics.event("TutorialDone", { seconds = Util.round(os.clock() - (sessionStart[player] or os.clock()), 1) })
	end
end

-- ── The scripted showcase (GDD §5, the 30–60 s beat) ─────────────────────

-- A pair that could plausibly have produced an Epic. Any purchasable pair
-- can: luck moves the odds, it never gates a tier.
local function showcasePair(): (string?, string?)
	local critters = Ingredients.catalogue("Critter")
	local stuff = Ingredients.catalogue("Stuff")
	local critter = Util.pick(critters, rng)
	local prop = Util.pick(stuff, rng)
	if not critter or not prop then
		return nil, nil
	end
	return critter.name, prop.name
end

--[[
	The synthetic banner. It fires only when no real Epic+ roll has landed
	since this player joined — a real one already showed them the ceiling, and
	faking a second would be noise on top of a lie.

	The tier is exactly Constants.TUTORIAL_SHOWCASE_MIN_RARITY: the floor of
	what the game shouts about, so the scripted beat can never advertise a
	rarer roll than the one the constants call newsworthy, and never mimics
	the Legendary shake or the Mythic fanfare.
]]
local function fireShowcase(player: Player)
	if not player.Parent or not announcements then
		return
	end
	local joined = sessionStart[player]
	if not joined or lastBigRollAt > joined then
		return
	end

	local critter, stuff = showcasePair()
	if not critter or not stuff then
		return
	end

	local tier = Rarity.clamp(Constants.TUTORIAL_SHOWCASE_MIN_RARITY)
	local announcement: Announcement = {
		-- Scoped as a server banner because that is what it is imitating;
		-- `toPlayer` still sends it to this one player and nobody else.
		scope = "Server",
		kind = "Roll",
		text = ("%s! %s just mixed a %s!"):format(
			Rarity.name(tier):upper(),
			SHOWCASE_ROLLER,
			Rarity.displayName(tier, critter, stuff)
		),
		rarity = tier,
		-- No playerName, deliberately: nothing may resolve this line back to
		-- a Player, because no player rolled it.
	}
	announcements.toPlayer(player, announcement)

	if analytics then
		analytics.event(SHOWCASE_EVENT, { rarity = tier, critter = critter, stuff = stuff })
	end
end

local function scheduleShowcase(player: Player)
	local window = Constants.TUTORIAL_SHOWCASE_WINDOW
	local opensAt = window[1]
	local closesAt = math.max(window[2], opensAt)
	task.delay(opensAt + rng:NextNumber() * (closesAt - opensAt), function()
		fireShowcase(player)
	end)
end

-- ── Teleports (GDD §6, DECISIONS D9) ─────────────────────────────────────

type Destination = (Player) -> CFrame?

-- Plaza-side of the structure and turned to face it, derived from the plaza
-- rather than from a stall's dimensions: the same offset then works for a
-- shop, a shack and a kiosk, and survives any change to how they are built.
local function approach(anchor: CFrame): CFrame
	local center = plazaCenter()
	local ground = Vector3.new(anchor.Position.X, center.Y, anchor.Position.Z)
	local direction = flatUnit(center - ground, flatUnit(anchor.LookVector, Vector3.new(0, 0, 1)))
	local stand = ground + direction * TELEPORT_STAND_OFF + Vector3.new(0, TELEPORT_HEIGHT, 0)
	return lookAtFlat(stand, ground)
end

-- GDD §6 gives the Mixer one pad per player so a full server can mix at once;
-- a shortcut that always lands on pad 1 would undo that.
local function emptiestPad(pads: { BasePart }, mover: Player): BasePart
	local best = pads[1]
	local bestClearance = -1
	for _, pad in pads do
		local clearance = math.huge
		for _, other in Players:GetPlayers() do
			if other ~= mover then
				local root = Util.rootPart(other)
				if root then
					clearance = math.min(clearance, (root.Position - pad.Position).Magnitude)
				end
			end
		end
		if clearance > bestClearance then
			best = pad
			bestClearance = clearance
		end
	end
	return best
end

local function mixerTarget(player: Player): CFrame?
	if not world then
		return nil
	end
	local center = plazaCenter()
	local pads: { BasePart } = world.getMixerPads()
	if type(pads) ~= "table" or #pads == 0 then
		return CFrame.new(center + Vector3.new(0, TELEPORT_HEIGHT, 0))
	end
	local pad = emptiestPad(pads, player)
	return lookAtFlat(pad.Position + Vector3.new(0, TELEPORT_HEIGHT, 0), center)
end

local function denTarget(player: Player): CFrame?
	if not world then
		return nil
	end
	local slot = slotOf(player)
	if not slot then
		return nil
	end
	local target = world.getSpawnFor(slot)
	return if typeof(target) == "CFrame" then target else nil
end

local function shopTarget(kind: string): Destination
	return function(_player: Player): CFrame?
		if not world then
			return nil
		end
		local anchor = world.getShopAnchor(kind)
		if typeof(anchor) ~= "CFrame" then
			return nil
		end
		return approach(anchor)
	end
end

-- The whole destination list, server-side. A name that is not in here does
-- not exist, however the client asks.
local DESTINATIONS: { [string]: Destination } = {
	Mixer = mixerTarget,
	Den = denTarget,
	CritterPen = shopTarget("Critter"),
	StuffShack = shopTarget("Stuff"),
	Mixdex = shopTarget("Mixdex"),
}

local function teleport(player: Player, destination: string)
	local resolve = DESTINATIONS[destination]
	if not resolve then
		return
	end

	-- The refusal that justifies the whole remote: ownership transfers at the
	-- bank (GDD §8.4.3), so a teleport home while carrying skips the chase.
	if steal and steal.isCarrying(player) then
		notify(player, NOTIFY_SESSION, CARRYING)
		return
	end

	local character = player.Character
	if not character then
		return
	end
	local humanoid = Util.humanoid(player)
	if not humanoid or humanoid.Health <= 0 then
		return -- mid-respawn; the spawn placement owns where they land
	end

	local target = resolve(player)
	if not target then
		notify(player, NOTIFY_SESSION, "Cannot get there right now.")
		return
	end
	character:PivotTo(target)
end

-- ── Query (the one RemoteFunction) ───────────────────────────────────────

type QueryRoute = (Player) -> any

local function queryShopPrices(player: Player): any
	if not shop then
		return nil
	end
	return shop.catalogue(player)
end

local function queryDenList(_player: Player): any
	if not den then
		return nil
	end
	return den.publicList()
end

local function queryOdds(player: Player): any
	local profile = profileOf(player)
	if not profile then
		return nil
	end
	return Rarity.odds(luckOf(profile))
end

--[[
	ARCHITECTURE §4 publishes only `submit` on LeaderboardService, so the
	contract names no read. The boards are that service's data and are
	refreshed on its own Constants.LEADERBOARD_REFRESH cadence, so this probes
	for a cached accessor and returns nil when it finds none — which the
	client reads as "wait for the LeaderboardSync push" rather than as three
	empty boards.
]]
local LEADERBOARD_READS = { "snapshot", "boards", "getBoards" }

local function queryLeaderboards(_player: Player): any
	if not leaderboards then
		return nil
	end
	for _, name in LEADERBOARD_READS do
		local accessor = leaderboards[name]
		if type(accessor) == "function" then
			return accessor()
		end
	end
	return nil
end

local ROUTES: { [string]: QueryRoute } = {
	ShopPrices = queryShopPrices,
	Leaderboards = queryLeaderboards,
	DenList = queryDenList,
	Odds = queryOdds,
}

-- ── Remotes ──────────────────────────────────────────────────────────────

local function connectRemotes()
	Net.onServerEvent("ClaimDaily", function(player: Player)
		-- Two claims in one breath would both pass the clock check before
		-- either wrote its stamp, and the multiplier lookup between them can
		-- yield. One in flight per player, cleared on every path out.
		if claiming[player] then
			return
		end
		claiming[player] = true
		local ok, err = pcall(function()
			claimDaily(player)
		end)
		claiming[player] = nil
		if not ok then
			warn(("[PlayerService] daily claim failed for %s: %s"):format(player.Name, tostring(err)))
		end
	end)

	--[[
		Only the keys the template names, and only booleans. `friendlyFire` is
		GDD §18's open question and defaults to on; this stores the player's
		answer, and the services that could act on it (who may enter a Den,
		who may take from a pedestal) read the profile rather than being told
		by the client.
	]]
	Net.onServerEvent("SetSetting", function(player: Player, key: any, value: any)
		if not Net.isString(key) or not Net.isBoolean(value) then
			return
		end
		local profile = profileOf(player)
		if not profile then
			return
		end
		local settings = profile.settings :: { [string]: boolean }
		if settings[key] == nil or settings[key] == value then
			return -- an unknown key, or no change to make
		end
		settings[key] = value
		if data then
			data.push(player, { settings = profile.settings })
		end
	end)

	Net.onServerEvent("RequestTeleport", function(player: Player, destination: any)
		if not Net.isString(destination) then
			return
		end
		teleport(player, destination :: string)
	end)

	Net.onServerEvent("TutorialStep", function(player: Player, step: any)
		if not Net.isString(step) then
			return
		end
		local name = step :: string
		if name == TUTORIAL_DONE_STEP then
			-- The client saying "I am finished" is telemetry, not authority:
			-- tutorialDone still flips only once the profile holds all three
			-- real steps. Recorded so a funnel can see a player who skipped
			-- ahead by walking away, which GDD §5 explicitly allows.
			if analytics then
				analytics.event("TutorialClientDone", { player = player })
			end
			return
		end
		if not table.find(TUTORIAL_STEPS, name) then
			return
		end
		recordStep(player, name)
	end)

	-- Read-only pulls. Every route below is non-yielding; see the header.
	Net.onServerInvoke("Query", function(player: Player, kind: any): any
		if not Net.isString(kind) then
			return nil
		end
		local route = ROUTES[kind :: string]
		if not route then
			return nil
		end
		return route(player)
	end)
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

local function onLoaded(player: Player, profile: Profile)
	if sessionStart[player] then
		return -- already handled; `start` connects and then sweeps
	end
	sessionStart[player] = os.clock()
	creditedSeconds[player] = 0

	if analytics then
		analytics.funnel(player, "Joined")
	end

	-- Read before the grant writes the flag: after it, nobody is new.
	local firstSession = isFirstSession(profile)
	if firstSession then
		grantStarter(player, profile)
	end

	-- The full view describes a Den — `placed` and both shield fields — so it
	-- waits for one rather than describing an empty Den and correcting itself
	-- a second later. Yielding here is fine: DataService fires onLoaded
	-- through Util.signal, which spawns every handler on its own thread.
	if not waitForSlot(player) then
		warn(("[PlayerService] syncing %s without a Den slot; their pedestals will fill in when one frees up")
			:format(player.Name))
	end
	if not player.Parent then
		return
	end

	local current = profileOf(player)
	if current then
		sendFullSync(player, current)
	end

	if firstSession then
		scheduleShowcase(player)
	end
end

local function forget(player: Player)
	flushPlaySeconds(player)
	sessionStart[player] = nil
	creditedSeconds[player] = nil
	tutorialSeen[player] = nil
	claiming[player] = nil
end

function PlayerService.init(services: { [string]: any })
	data = services.DataService
	den = services.DenService
	economy = services.EconomyService
	shop = services.ShopService
	steal = services.StealService
	monetization = services.MonetizationService
	announcements = services.AnnouncementService
	leaderboards = services.LeaderboardService
	mixdex = services.MixdexService
	analytics = services.AnalyticsService
	world = services.WorldService
	-- Not a route: MixerService.onRolled is how this service learns that a
	-- real Epic+ roll made the scripted showcase unnecessary, and that a
	-- secret was just discovered.
	mixer = services.MixerService
end

function PlayerService.start()
	if not data then
		warn("[PlayerService] DataService is missing; no session can be set up.")
		return
	end
	if not world then
		warn("[PlayerService] WorldService is missing; players will spawn wherever Roblox puts them, not in their Den.")
	end
	if not den then
		warn("[PlayerService] DenService is missing; there is no Den to spawn into and no Den list to serve.")
	end
	if not mixdex then
		warn("[PlayerService] MixdexService is missing; the full sync will carry no collection progress.")
	end

	connectRemotes()

	for _, player in Players:GetPlayers() do
		watchCharacter(player)
	end
	Players.PlayerAdded:Connect(watchCharacter)
	Players.PlayerRemoving:Connect(forget)

	data.onLoaded:connect(onLoaded)
	-- Anyone whose profile loaded before this service started. In memory-only
	-- mode DataService.load never yields, so onLoaded can fire during boot.
	data.forEach(onLoaded)

	-- The last synchronous moment the profile still exists, so the tail of
	-- the session is counted before it is written (GDD §11.2).
	data.onReleasing:connect(function(player: Player)
		flushPlaySeconds(player)
	end)

	if mixer then
		mixer.onRolled:connect(function(_player: Player, mixling: Mixling)
			if type(mixling) ~= "table" then
				return
			end
			if Net.isIntInRange(mixling.rarity, Constants.TUTORIAL_SHOWCASE_MIN_RARITY, #Rarity.Tiers) then
				lastBigRollAt = os.clock()
			end
		end)

		-- A secret found mid-session needs its display row now; otherwise the
		-- Mixdex would show the "???" the player just solved until they
		-- rejoined and got a full sync.
		mixer.onRolled:connect(function(player: Player, _mixling: Mixling, _isNew: boolean, secretId: string?)
			if not secretId or not Net.isString(secretId) then
				return
			end
			local profile = profileOf(player)
			if not profile or not profile.secretsFound[secretId] then
				return
			end
			local secret = SecretRecipes.byId(secretId)
			if secret then
				data.push(player, { secrets = { [secretId] = secretRow(secret) } })
			end
		end)
	end

	task.spawn(function()
		while true do
			task.wait(PLAY_TICK_SECONDS)
			-- The declared `any` return is what makes pcall hand back the
			-- error text. The loop has to outlive one bad pass: a dead thread
			-- silently stops counting playtime for the whole server.
			local ok, err = pcall(function(): any
				creditEveryone()
				return nil
			end)
			if not ok then
				warn("[PlayerService] playtime pass failed: " .. tostring(err))
			end
		end
	end)
end

return PlayerService
