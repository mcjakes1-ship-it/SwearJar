--!strict
--[[
	CodesService.luau — promo code redemption. GDD §8.8 (codes half), §12.

	OWNS `profile.codes` and the "RedeemCode" handler. One entry point:

	  redeem(player, code) -> (ok: boolean, message: string)

	CODES ARE PUBLIC KNOWLEDGE AND ARE TREATED AS SUCH. GDD §8.8 distributes
	them through code-aggregator sites, so every code is on the internet the
	hour it ships. That is the design, not a leak, and it is why nothing here
	gates anything: a code is worth exactly the Goop `Constants.CODES` says
	and never more, there is no first-N-redeemers race to lose, and no
	ingredient, secret or Mixling is reachable only through one. The list
	consequently lives in `Constants` (which replicates) rather than in
	ServerStorage — hiding it would buy nothing, since the redemption itself
	is server-side. The one real consequence: a code committed to Constants
	before its announcement is datamineable a week early, so a Weekly Drop
	code (GDD §12) should land in the same release as the drop it advertises.

	ONE REDEMPTION PER CODE PER PROFILE, and the ledger is the profile, so
	the limit survives a rejoin, a server hop and a rollback of this file.
	The entry is claimed BEFORE the payout: a double-fired remote must find
	the code already spent, not race the credit.

	"UNKNOWN" AND "ALREADY USED" ARE DIFFERENT SENTENCES ON PURPOSE. Players
	report "the code doesn't work" constantly and the difference between
	those two answers is the entire diagnosis — one is a typo, the other is a
	player who already has the Goop and forgot. Collapsing them into one
	polite line costs a support round-trip every time.

	INPUT AND CONFIG GO THROUGH THE SAME NORMALISER. `normalise` strips
	whitespace and uppercases, and it is applied to the Constants keys at
	require time as well as to whatever the player types. A code pasted out
	of a video description with a trailing newline matches; so does a
	Constants key someone typed as "mixer".

	EXPIRY IS SUPPORTED THOUGH NO LAUNCH CODE USES IT. An entry may carry
	`expires = <unix time>`; the Weekly Drop wants time-limited codes
	(GDD §12) and retro-fitting an expiry check into a live redemption path
	is a far worse change than three lines now that read as dead code today.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Config:WaitForChild("Constants"))
local Net = require(Shared:WaitForChild("Net"))
local Types = require(Shared:WaitForChild("Types"))
local Util = require(Shared:WaitForChild("Util"))

type Profile = Types.Profile

-- Constants.CODES is a literal, so its inferred type is a sealed record and
-- it can only be read through a computed key behind a cast. Same shape
-- MonetizationService uses over Constants.PASSES. `expires` is declared here
-- even though no launch entry sets it (see the header).
type CodeDef = {
	goop: number,
	expires: number?, -- unix time; absent or 0 means the code never expires
}

local CODES: { [string]: CodeDef } = Constants.CODES :: any

local CodesService = {}
CodesService.Name = "CodesService"

-- ── Tunables ─────────────────────────────────────────────────────────────
-- Protocol labels and player-facing lines, not balance values, so none of
-- them belong in Constants (GDD §17 covers what the player feels).

local NOTIFY_KIND = "Code" -- the Notify channel the Codes UI colours by
local SOURCE_PREFIX = "code:" -- the GDD §15 economy row: one per code

--[[
	Longest code this service will even look up. No balance rides on it, so
	it is not a Constants value; it is a bound on a string an exploiter
	chooses. Net.isString already refuses anything over 64 characters, and
	the ceiling is lowered here for two reasons: nothing longer than this can
	reach the analytics rows below, and `SOURCE_PREFIX .. key` stays inside
	that same 64-character limit, so EconomyService logs the real source
	instead of falling back to "Unknown". The longest launch code is
	"BLENDBURG" at 9; the index builder warns about any configured code that
	exceeds this rather than letting it fail silently at redemption time.
]]
local MAX_CODE_LENGTH = 24

local EMPTY = "Type a code in first."
local UNKNOWN = "That's not a code. Check the spelling — codes aren't case sensitive."
local ALREADY_USED = "You've already redeemed that code."
local EXPIRED = "That code has expired."
local NOT_LOADED = "Still loading your stuff — try again in a second."
local UNAVAILABLE = "Codes are down for a moment — try again shortly."
local SUCCESS = "%s redeemed! +%s Goop"

-- ── State ────────────────────────────────────────────────────────────────

local data: any = nil
local economy: any = nil
local analytics: any = nil

-- ── The code index ───────────────────────────────────────────────────────

--[[
	Whitespace is stripped entirely rather than trimmed off the ends: codes
	arrive pasted out of a video description or a chat message, and an
	embedded space or newline is the player's clipboard being helpful, never
	part of a code.
]]
local function normalise(raw: string): string
	local stripped = (raw:gsub("%s", ""))
	return stripped:upper()
end

-- normalised input -> the Constants key it redeems. Built once at require
-- time; Constants is frozen, so nothing can invalidate it later.
local canonical: { [string]: string } = {}

do
	local keys: { string } = {}
	for key in CODES do
		table.insert(keys, key)
	end
	-- Sorted so two keys that normalise to the same code resolve to the same
	-- one every boot, instead of whichever the hash order happened to visit
	-- last. Same reasoning as MonetizationService's asset-id index.
	table.sort(keys)

	for _, key in keys do
		local normalised = normalise(key)
		if normalised == "" then
			warn(("[CodesService] code %q normalises to nothing; it can never be redeemed"):format(key))
			continue
		end
		if #normalised > MAX_CODE_LENGTH then
			warn(("[CodesService] code %q is longer than %d characters; it can never be redeemed")
				:format(key, MAX_CODE_LENGTH))
			continue
		end
		local existing = canonical[normalised]
		if existing then
			warn(("[CodesService] codes %q and %q are the same code once normalised; only %q pays out")
				:format(existing, key, existing))
			continue
		end
		canonical[normalised] = key
	end
end

-- ── Entry reads ──────────────────────────────────────────────────────────
-- Constants is hand-edited config, so every field is validated on the way
-- out rather than trusted.

local function rewardOf(key: string): number?
	local entry = CODES[key]
	if not entry then
		return nil
	end
	if not Net.isFiniteNumber(entry.goop) or entry.goop <= 0 then
		warn(("[CodesService] code %q has no usable goop value (%s); refusing it")
			:format(key, tostring(entry.goop)))
		return nil
	end
	return math.floor(entry.goop)
end

local function hasExpired(key: string): boolean
	local entry = CODES[key]
	local expires = if entry then entry.expires else nil
	if not Net.isFiniteNumber(expires) or (expires :: number) <= 0 then
		return false -- the launch codes carry no expiry and are permanent
	end
	return os.time() >= (expires :: number)
end

-- ── Helpers ──────────────────────────────────────────────────────────────

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

--[[
	Every refused redemption exits through here, so the player always gets
	exactly one line back and the dashboard always gets exactly one row.
	`reason` is the machine-readable half: "how many people are typing a code
	that does not exist" is the number that tells you a video is spreading a
	fake one.
]]
local function refuse(player: Player, message: string, reason: string, code: string?): (boolean, string)
	notify(player, message)
	if analytics then
		analytics.event("CodeRejected", { player = player, reason = reason, code = code })
	end
	return false, message
end

--[[
	EconomyService.award replicates the new balance itself today, but this
	file must not lean on that: Goop credited that the HUD does not show is
	indistinguishable to the player from a code that did nothing, which is
	the exact support ticket this service exists to avoid. One extra
	ProfileSync per redemption is bounded by Constants.RATE_LIMITS.RedeemCode.
	The profile is read rather than `award`'s return value because the
	profile is the balance — `award` reports 0 for a player it could not find.
]]
local function push(player: Player, profile: Profile)
	if not data then
		return
	end
	data.push(player, { goop = profile.goop, totalGoopEarned = profile.totalGoopEarned })
end

-- ── Redemption ───────────────────────────────────────────────────────────

--[[
	The whole service. Notifies the player on every path — success and each
	distinct failure — so a caller cannot forget to, and so a redemption
	triggered from anywhere other than the remote (a future admin grant) says
	the same sentence the Codes button does. Returns the same message it
	sent, for that caller's logs.
]]
function CodesService.redeem(player: Player, code: string): (boolean, string)
	local normalised = if type(code) == "string" then normalise(code) else ""
	if normalised == "" then
		return refuse(player, EMPTY, "Empty")
	end
	-- No configured code is this long (the index builder refuses to register
	-- one), so this is not a typo, it is a probe. It is capped before it can
	-- reach a telemetry column.
	if #normalised > MAX_CODE_LENGTH then
		return refuse(player, UNKNOWN, "TooLong")
	end

	local key = canonical[normalised]
	if not key then
		return refuse(player, UNKNOWN, "Unknown", normalised)
	end

	local profile = profileOf(player)
	if not profile then
		-- The one-per-profile ledger IS the profile. Without it the
		-- redemption could not be recorded and the code would pay out again
		-- on the next attempt, so the honest answer is "wait a second".
		return refuse(player, NOT_LOADED, "NotLoaded", key)
	end
	if profile.codes[key] then
		return refuse(player, ALREADY_USED, "AlreadyUsed", key)
	end
	if hasExpired(key) then
		return refuse(player, EXPIRED, "Expired", key)
	end

	-- Both of these refuse WITHOUT spending the code, so a fixed Constants
	-- entry or a recovered EconomyService makes it redeemable again instead
	-- of leaving it permanently burned for nothing.
	local reward = rewardOf(key)
	if not reward then
		return refuse(player, UNAVAILABLE, "BadReward", key)
	end
	if not economy then
		return refuse(player, UNAVAILABLE, "NoEconomy", key)
	end

	-- Claimed before the payout. `award` does not yield today, but this
	-- entry is the only thing standing between a double-fired remote and a
	-- double payout, and it has to exist before anything that could ever
	-- spawn, yield or fail runs.
	profile.codes[key] = true
	economy.award(player, reward, SOURCE_PREFIX .. key)
	push(player, profile)

	local message = SUCCESS:format(key, Util.abbreviate(reward))
	notify(player, message)
	if analytics then
		analytics.event("CodeRedeemed", { player = player, code = key, value = reward })
	end
	return true, message
end

-- ── Remotes ──────────────────────────────────────────────────────────────

local function connectRemotes()
	Net.onServerEvent("RedeemCode", function(player: Player, code: any)
		if not Net.isString(code) then
			-- An empty text box is a real thing a player can submit, and
			-- silence there reads as a broken button. Anything else — a
			-- table, a number, 300 characters — is a hand-rolled client and
			-- is told nothing at all.
			if code == "" then
				notify(player, EMPTY)
			end
			return
		end
		CodesService.redeem(player, code :: string)
	end)
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

function CodesService.init(services: { [string]: any })
	data = services.DataService
	economy = services.EconomyService
	analytics = services.AnalyticsService
end

function CodesService.start()
	if not data then
		warn("[CodesService] DataService is missing; no redemption can be recorded, so every code will be refused.")
	end
	if not economy then
		warn("[CodesService] EconomyService is missing; codes cannot pay out and will be refused rather than spent.")
	end
	if next(canonical) == nil then
		warn("[CodesService] Constants.CODES is empty; the Codes button has nothing to redeem (GDD §8.8 expects one at launch).")
	end

	connectRemotes()
end

return CodesService
