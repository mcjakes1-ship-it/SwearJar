--!strict
--[[
	MixdexService.luau — the collection log. GDD §8.5.

	OWNS `profile.mixdex`, `profile.secretsFound` and the milestone titles
	that hang off them. Two entry points, both server-side:

	  record(player, critter, stuff, rarity, secretId?) -> boolean  -- true if NEW
	  progress(player) -> (discovered: number, total: number)

	THE KEY IS Ingredients.key(critter, stuff) ("Stuff:Critter"), and the
	value is the BEST rarity that pair has ever produced for this player —
	which is exactly what GDD §8.5 asks the grid to draw ("best tier owned").
	A pair already in the log is not a new entry, but a better roll of it
	still moves the number on the card, so both cases push. Secrets are a
	separate ledger (`profile.secretsFound`) because they are counted against
	SecretsPublic.COUNT and rendered as "???" until found, and because the
	recipe behind one must never be derivable from anything the client holds
	(GDD §7.4, §11.3).

	INGREDIENT NAMES ARE VALIDATED BEFORE THEY BECOME A KEY. `discovered` is
	a count of this table, so a key built from a name that is not in
	Ingredients would inflate the numerator forever and eventually show a
	player 260/261 with no way to find the missing one. A bad name is refused
	here rather than cleaned up later.

	MILESTONES ARE GATED ON THE TITLE, NOT ON THE COUNT. `discovered >= entries`
	stays true forever once it is true, so an `== entries` test would be the
	only thing stopping a milestone from paying twice — and it would silently
	miss whenever one record crosses two thresholds, or whenever a count
	arrives from somewhere other than a single increment. Holding the title is
	the ledger instead: granted once, re-checkable any number of times. That
	is what makes the sweep safe to also run on load, so a milestone missed
	because a sibling service was down gets paid the next time the player
	joins instead of never.

	DELTAS, NOT THE TABLE. `profile.mixdex` grows to 256 entries and would
	otherwise be re-sent on every roll to describe one key. ClientState merges
	`mixdex`, `secretsFound` and `titles` key by key precisely so a discovery
	costs one key on the wire. The progress figures ride along because the HUD
	shows a Mixdex percentage (GDD §10) and it is derived from two numbers
	that live in no profile field, so nothing else would ever push them.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Config:WaitForChild("Constants"))
local Ingredients = require(Config:WaitForChild("Ingredients"))
local Rarity = require(Config:WaitForChild("Rarity"))
local SecretsPublic = require(Config:WaitForChild("SecretsPublic"))
local Net = require(Shared:WaitForChild("Net"))
local Types = require(Shared:WaitForChild("Types"))
local Util = require(Shared:WaitForChild("Util"))

type Profile = Types.Profile
type Announcement = Types.Announcement

-- Constants.MIXDEX_MILESTONES and Constants.BADGES are literals, so their
-- inferred types are sealed records; both are read here through a computed
-- key. Same shape MonetizationService uses over Constants.PASSES.
type Milestone = { entries: number, goop: number, title: string }
local MILESTONES: { Milestone } = Constants.MIXDEX_MILESTONES :: any
local BADGES: { [string]: number } = Constants.BADGES :: any

local MixdexService = {}
MixdexService.Name = "MixdexService"

-- ── Tunables ─────────────────────────────────────────────────────────────
-- Dashboard and protocol labels, not balance values, so none of them belong
-- in Constants (GDD §17 covers what the player feels).

local AWARD_SOURCE = "mixdex" -- the GDD §15 economy row for milestone payouts
local BADGE_PREFIX = "Mixdex" -- Constants.BADGES names them Mixdex50/100/200

-- The denominator (GDD §8.5): every base pair plus every secret. Both halves
-- are frozen config, so this is computed once rather than per push.
local TOTAL_ENTRIES = Ingredients.baseCombinationCount() + SecretsPublic.COUNT

-- ── State ────────────────────────────────────────────────────────────────

local data: any = nil
local economy: any = nil
local announcements: any = nil
local monetization: any = nil

-- ── Counting ─────────────────────────────────────────────────────────────

-- Only truthy entries count: `secretsFound[id] = false` means "still ???",
-- and a key with that value would otherwise fill in a silhouette nobody has
-- earned.
local function countSecrets(found: { [string]: boolean }): number
	local total = 0
	for _, seen in found do
		if seen then
			total += 1
		end
	end
	return total
end

local function discoveredIn(profile: Profile): number
	return Util.count(profile.mixdex) + countSecrets(profile.secretsFound)
end

--[[
	0..100, one decimal — the number the HUD prints, computed here so no
	controller has to know the denominator. Clamped because a mismatch
	between SecretsPublic.COUNT and the real recipe table (which the boot
	script warns about but does not fix) would otherwise show a player 103%.
	`progress` deliberately does NOT clamp: it reports what is actually in
	the profile, which is what a diagnostic wants.
]]
local function percentOf(discovered: number): number
	if TOTAL_ENTRIES <= 0 then
		return 0
	end
	return Util.round(math.clamp(discovered / TOTAL_ENTRIES, 0, 1) * 100, 1)
end

-- Stamps the progress figures onto whatever deltas the caller collected and
-- sends the lot as one ProfileSync. One push per record, never two.
local function push(player: Player, profile: Profile, patch: { [string]: any })
	if not data then
		return
	end
	local discovered = discoveredIn(profile)
	patch.mixdexDiscovered = discovered
	patch.mixdexTotal = TOTAL_ENTRIES
	patch.mixdexPercent = percentOf(discovered)
	data.push(player, patch)
end

-- ── Milestones (GDD §8.5) ────────────────────────────────────────────────

local function announceMilestone(player: Player, milestone: Milestone, discovered: number)
	if not announcements then
		return
	end
	local a: Announcement = {
		scope = "Local",
		kind = "Milestone",
		text = ("MIXDEX %d/%d — you are now a %s! +%s Goop"):format(
			discovered,
			TOTAL_ENTRIES,
			milestone.title,
			Util.abbreviate(milestone.goop)
		),
		fanfare = true,
	}
	announcements.toPlayer(player, a)
end

--[[
	Pays one milestone. Returns false without touching the profile when the
	payout cannot be made, so the grant stays pending and the next sweep
	retries it — a title handed out with no Goop behind it could never be
	repaired, because the title is the very thing that stops a re-grant.

	The title is claimed BEFORE the payout for the opposite reason: `award`
	does not yield, but `awardBadge` and the announcement both spawn, and a
	second sweep landing between them must find the milestone already held.
]]
local function grant(player: Player, profile: Profile, milestone: Milestone, discovered: number): boolean
	if not economy then
		return false
	end
	if not Net.isFiniteNumber(milestone.goop) or milestone.goop < 0 then
		warn(("[MixdexService] milestone %q has a bad goop value; skipping it"):format(tostring(milestone.title)))
		return false
	end

	profile.titles[milestone.title] = true
	economy.award(player, milestone.goop, AWARD_SOURCE)

	-- The badge exists only for the thresholds Constants.BADGES names
	-- (50/100/200); the smaller milestones are a title and a payout only.
	if monetization then
		local badgeKey = BADGE_PREFIX .. tostring(milestone.entries)
		if BADGES[badgeKey] ~= nil then
			monetization.awardBadge(player, badgeKey)
		end
	end

	announceMilestone(player, milestone, discovered)
	return true
end

--[[
	Re-checks every milestone against the current count. Safe to call as often
	as anything likes: a milestone already held is skipped, and one call can
	legitimately grant several at once (a load sweep over a profile that
	predates this system, or a single record crossing two thresholds).

	Returns the titles granted by THIS sweep so the caller can push them as a
	delta rather than the whole titles table.
]]
local function sweep(player: Player, profile: Profile): { [string]: boolean }
	local granted: { [string]: boolean } = {}
	local discovered = discoveredIn(profile)

	for _, milestone in MILESTONES do
		if discovered >= milestone.entries and not profile.titles[milestone.title] then
			if grant(player, profile, milestone, discovered) then
				granted[milestone.title] = true
			end
		end
	end
	return granted
end

-- ── Public API ───────────────────────────────────────────────────────────

--[[
	Writes one discovery. Returns true only when the PAIR was absent — a
	better roll of a pair already logged is a push, not a new entry, and
	MixResult.newMixdexEntry drives the "NEW!" stamp on the reveal card.

	Every argument is re-validated here: this is a public entry point and the
	names originally came off a client, however many services ago.
]]
function MixdexService.record(player: Player, critter: string, stuff: string, rarity: number, secretId: string?): boolean
	if not data then
		return false
	end
	if not Net.isString(critter) or not Net.isString(stuff) then
		return false
	end
	if not Ingredients.isCritter(critter) or not Ingredients.isStuff(stuff) then
		warn(("[MixdexService] refused %s + %s: not a Critter/Stuff pair"):format(critter, stuff))
		return false
	end
	if not Net.isIntInRange(rarity, 1, #Rarity.Tiers) then
		warn(("[MixdexService] refused rarity %s for %s + %s"):format(tostring(rarity), critter, stuff))
		return false
	end

	local profile = data.get(player)
	if not profile then
		return false -- not loaded (or already released); nothing to write into
	end

	local patch: { [string]: any } = {}

	local key = Ingredients.key(critter, stuff)
	local best = profile.mixdex[key]
	local isNew = best == nil
	if best == nil or rarity > best then
		profile.mixdex[key] = rarity
		patch.mixdex = { [key] = rarity }
	end

	-- Narrowed into a local: `Net.isString` returns a boolean, so the
	-- optional parameter is still `string?` to the checker afterwards.
	local secret = secretId
	if secret ~= nil and Net.isString(secret) and not profile.secretsFound[secret] then
		profile.secretsFound[secret] = true
		patch.secretsFound = { [secret] = true }
	end

	local granted = sweep(player, profile)
	if next(granted) ~= nil then
		patch.titles = granted
	end

	push(player, profile, patch)
	return isNew
end

-- Raw figures, unclamped: `discovered` is what the profile actually holds.
function MixdexService.progress(player: Player): (number, number)
	if not data then
		return 0, TOTAL_ENTRIES
	end
	local profile = data.get(player)
	if not profile then
		return 0, TOTAL_ENTRIES
	end
	return discoveredIn(profile), TOTAL_ENTRIES
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

--[[
	The load-time pass: seed the HUD with a percentage nothing else pushes,
	and settle any milestone the player earned but never received (a server
	that shut down between the record and the payout, or a profile older than
	this system).
]]
local function refresh(player: Player)
	if not data then
		return
	end
	local profile = data.get(player)
	if not profile then
		return
	end

	local patch: { [string]: any } = {}
	local granted = sweep(player, profile)
	if next(granted) ~= nil then
		patch.titles = granted
	end
	push(player, profile, patch)
end

function MixdexService.init(services: { [string]: any })
	data = services.DataService
	economy = services.EconomyService
	announcements = services.AnnouncementService
	monetization = services.MonetizationService
end

function MixdexService.start()
	if not data then
		warn("[MixdexService] DataService is missing; no discovery can be recorded.")
		return
	end
	if not economy then
		warn("[MixdexService] EconomyService is missing; milestone payouts will be held until it is present.")
	end

	data.onLoaded:connect(function(player: Player)
		refresh(player)
	end)

	-- Anyone whose profile loaded before this service started. In memory-only
	-- mode DataService.load never yields, so onLoaded can fire during boot.
	for _, player in Players:GetPlayers() do
		refresh(player)
	end
end

return MixdexService
