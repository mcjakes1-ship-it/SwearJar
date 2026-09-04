--!strict
--[[
	MixerService.luau — the roll. GDD §8.1, §5, §7.4, §11.3.

	OWNS the three most important seconds in the game: the `RequestMix`
	handler, the weighted roll behind it, and every write that turns two
	ingredients into a Mixling. Nothing else in the codebase may mint one.

	The public surface is a single signal:

	  MixerService.onRolled : Signal(player, mixling, isNewEntry, secretId?)

	`rollFor(player, critter, stuff)` is that same roll with the remote peeled
	off. It is the whole behaviour, not a slice of it, so the interesting part
	of this file can be driven from a test or the command bar without faking a
	client.

	ONE Random PER SERVER (GDD §8.1, §11.3). Seeded once at module scope and
	never reseeded. A per-roll `Random.new(seed)` is a sequence someone can
	line up against a known clock, and re-entering the Mixer must not be a way
	to re-draw from a fresh stream. The client contributes exactly zero bits
	to the outcome: it sends two ingredient names and is told what happened.

	THREE OUTCOMES, IN PRIORITY ORDER:

	  1. Secret recipe — bypasses the roll entirely (GDD §7.4). The recipe
	     table lives in ServerStorage and is never mirrored, summarised or
	     hinted at anywhere the client can read; a player learns a pair only
	     by producing it. Note the decoy: Frog + Sock, the starter pair, is
	     deliberately NOT a secret. Everyone tries it first; that is the joke.
	  2. Rigged first roll — a profile that has never rolled, mixing the
	     starter pair, gets Constants.STARTER.riggedRarity guaranteed and the
	     result is Bound so it can never be stolen (GDD §5, §8.3). The first
	     60 seconds are scripted, and a Common there is a bad first impression
	     we only get to make once.
	  3. Weighted roll — Rarity.roll over tiers 1..6 at the player's luck.

	INGREDIENTS ARE CONSUMED, AND THEY ARE CONSUMED FIRST (GDD §7.2). The
	debit and the cooldown stamp happen the moment the mix is committed,
	ahead of anything that could warn or degrade, so no path through this file
	can hand out a free roll.

	THE ROLL IS NEVER INTERRUPTED (GDD §2, pillar 1). Every sibling service is
	optional here and every call into one is guarded: a missing Mixdex, a
	throttled MessagingService or a dead badge endpoint costs a banner or a
	telemetry row, never the Mixling. The MixResult goes out before any of
	them for the same reason — the reveal is the product.

	THE COOLDOWN IS A SECOND FLOOR, NOT THE ONLY ONE. Net already rate-limits
	RequestMix per player over a sliding window; Constants.MIX_COOLDOWN_SECONDS
	is the tighter per-roll spacing that keeps one player from turning a burst
	allowance into a dozen rolls in the same frame.
]]

local HttpService = game:GetService("HttpService")
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

-- Server-only (GDD §11.3). Required here and in DenService and nowhere else;
-- tools/lint_contract.py fails the build if this name appears under
-- ReplicatedStorage.
local SecretRecipes = require(ServerStorage:WaitForChild("SecretRecipes"))

type Profile = Types.Profile
type Mixling = Types.Mixling
type MixlingView = Types.MixlingView
type MixResult = Types.MixResult
type Ingredient = Ingredients.Ingredient

local MixerService = {}
MixerService.Name = "MixerService"

MixerService.onRolled = Util.signal()

-- ── Tunables ─────────────────────────────────────────────────────────────
-- Presentation labels, not balance values, so they do not belong in
-- Constants (GDD §17 covers what the player feels).

local NOTIFY_KIND = "Mixer" -- the Notify channel the Mixer UI listens on

-- One badge per exact tier (GDD §8.7). Secret is absent on purpose: it earns
-- SecretDiscoverer, which is the rarer and more interesting award.
local TIER_BADGE: { [number]: string } = {
	[Constants.RARITY_RARE] = "RollRare",
	[Constants.RARITY_EPIC] = "RollEpic",
	[Constants.RARITY_LEGENDARY] = "RollLegendary",
	[Constants.RARITY_MYTHIC] = "RollMythic",
}

-- ── State ────────────────────────────────────────────────────────────────

-- The server's one and only roll stream. See the header.
local rng = Random.new()

local data: any = nil
local economy: any = nil
local mixdex: any = nil
local announcements: any = nil
local monetization: any = nil
local analytics: any = nil

local lastRollAt: { [Player]: number } = {}

-- Secrets this server has already seen produced. GDD §7.4 makes the
-- DISCOVERED feed a per-server first, so this is what separates "news" from
-- "the same player farming Capybara + Crown".
local discoveredHere: { [string]: boolean } = {}

-- ── Helpers ──────────────────────────────────────────────────────────────

local function notify(player: Player, text: string)
	if not player.Parent then
		return
	end
	Net.fire(player, "Notify", NOTIFY_KIND, text)
end

local function profileOf(player: Player): Profile?
	if not data then
		return nil
	end
	return data.get(player)
end

--[[
	L = critter.luck + stuff.luck + passes + active server luck (GDD §8.1).

	Clamped at zero because the weight curve is `base * (1 + L * luckMult)`:
	a negative L does not make rare tiers rarer, it drives their weights
	negative and corrupts the whole distribution. A luck debuff, if one ever
	ships, has to be a different shape than this.
]]
local function luckFor(player: Player, critterDef: Ingredient, stuffDef: Ingredient): number
	local luck = critterDef.luck + stuffDef.luck
	if monetization then
		local bonus = monetization.getLuck(player)
		if Net.isFiniteNumber(bonus) then
			luck += bonus
		end
	end
	if not Net.isFiniteNumber(luck) then
		return 0
	end
	return math.max(0, luck)
end

-- Spent stacks are dropped, not left at zero: the inventory replicates whole,
-- and a profile that keeps a zero row for every ingredient ever bought grows
-- forever for nothing.
local function consume(profile: Profile, name: string)
	local left = (profile.inventory[name] or 0) - 1
	if left > 0 then
		profile.inventory[name] = left
		return
	end
	-- The map's value type is `number`, so clearing a key has to be spelled
	-- out for the checker; the profile shape genuinely allows a missing name.
	local stacks: { [string]: number? } = profile.inventory
	stacks[name] = nil
end

--[[
	The wire shape (GDD §11.3). The name is built by the Assembler so the
	label on the reveal, the pedestal plaque and the banner all come from one
	place (GDD §7.1), and `secretName` is the single field here the client
	could not have derived on its own — which is exactly the moment it is
	allowed to learn it.
]]
local function viewOf(mixling: Mixling, secretName: string?): MixlingView
	return {
		id = mixling.id,
		critter = mixling.critter,
		stuff = mixling.stuff,
		rarity = mixling.rarity,
		secretId = mixling.secretId,
		secretName = secretName,
		bound = mixling.bound,
		displayName = Assembler.displayName({
			critter = mixling.critter,
			stuff = mixling.stuff,
			rarity = mixling.rarity,
			secretId = mixling.secretId,
			secretName = secretName,
		}),
		goopPerSec = Rarity.goopPerSec(mixling.rarity),
	}
end

-- ── The roll ─────────────────────────────────────────────────────────────

--[[
	The whole mix, with the remote peeled off: validate, debit, roll, record,
	tell everyone. Returns the new Mixling, or nil plus a line to show the
	player.

	Every refusal happens before the debit, and everything after it is
	non-yielding, so there is no window in which the ingredients are gone and
	the Mixling does not exist.
]]
function MixerService.rollFor(player: Player, critterName: string, stuffName: string): (Mixling?, string?)
	-- Re-validated here rather than trusted from the caller: this is a public
	-- entry point, and the remote handler is only one of its callers.
	if not Net.isString(critterName) or not Net.isString(stuffName) then
		return nil, "Pick one Critter and one Stuff."
	end
	if not Ingredients.isCritter(critterName) or not Ingredients.isStuff(stuffName) then
		return nil, "The Mixer takes one Critter and one Stuff."
	end
	local critterDef = Ingredients.get(critterName)
	local stuffDef = Ingredients.get(stuffName)
	if not critterDef or not stuffDef then
		return nil, "That ingredient does not exist."
	end

	local profile = profileOf(player)
	if not profile then
		return nil, "Your Mixlings are still loading. Try again in a moment."
	end

	local now = os.clock()
	local previous = lastRollAt[player]
	if previous and now - previous < Constants.MIX_COOLDOWN_SECONDS then
		return nil, "The Mixer is still spinning."
	end

	-- Ownership, not just existence: the client picked these names, so the
	-- only thing that decides whether the player has them is the profile.
	if (profile.inventory[critterName] or 0) < 1 then
		return nil, ("You have no %s left."):format(critterName)
	end
	if (profile.inventory[stuffName] or 0) < 1 then
		return nil, ("You have no %s left."):format(stuffName)
	end

	-- Committed. Charge for it before anything else can go wrong.
	lastRollAt[player] = now
	consume(profile, critterName)
	consume(profile, stuffName)

	local firstRoll = profile.stats.rolls == 0
	local starterPair = critterName == Constants.STARTER.critter and stuffName == Constants.STARTER.stuff
	local rigged = firstRoll and starterPair

	local secret = SecretRecipes.match(critterName, stuffName)
	local luck = luckFor(player, critterDef, stuffDef)

	local tier: number
	if secret then
		tier = Constants.RARITY_SECRET
	elseif rigged then
		-- Clamped rather than trusted: a typo in Constants.STARTER must not
		-- put a tier that has no rarity row into a saved profile.
		tier = Rarity.clamp(Constants.STARTER.riggedRarity)
	else
		tier = Rarity.roll(rng, luck)
	end

	local mixling: Mixling = {
		id = HttpService:GenerateGUID(false),
		critter = critterName,
		stuff = stuffName,
		rarity = tier,
		secretId = if secret then secret.id else nil,
		-- Bound is the padlock in GDD §5: the Mixling handed out during the
		-- scripted first minute is the one thing a new player cannot lose.
		bound = if rigged then true else nil,
		createdAt = os.time(),
	}

	table.insert(profile.mixlings, mixling)

	local stats = profile.stats
	stats.rolls += 1
	stats.byRarity[tier] = (stats.byRarity[tier] or 0) + 1

	local firstDiscovery = false
	if secret then
		profile.secretsFound[secret.id] = true
		if not discoveredHere[secret.id] then
			discoveredHere[secret.id] = true
			firstDiscovery = true
		end
		if monetization then
			monetization.awardBadge(player, "SecretDiscoverer")
		end
	end

	local newMixdexEntry = false
	if mixdex then
		newMixdexEntry = mixdex.record(player, critterName, stuffName, tier, mixling.secretId) == true
	end

	local view = viewOf(mixling, if secret then secret.name else nil)

	-- The reveal first, everything else after. Epic and above buy an extra
	-- "…something's different" beat before the slam (GDD §8.1); the client
	-- owns the animation but not its length, because a client that shortened
	-- its own reveal would be reading the outcome early.
	local suspense = tier >= Constants.REVEAL_SUSPENSE_MIN_RARITY
	local result: MixResult = {
		mixling = view,
		revealSeconds = Constants.REVEAL_SECONDS + (if suspense then Constants.REVEAL_SUSPENSE_SECONDS else 0),
		suspense = suspense,
		luck = luck,
		newMixdexEntry = newMixdexEntry,
		firstDiscovery = firstDiscovery,
	}
	Net.fire(player, "MixResult", result)

	if announcements then
		-- One entry point: which tier shouts how loud lives in
		-- AnnouncementService, driven by Constants.RARITY[tier].announce.
		--
		-- GDD §7.4 wants the DISCOVERED feed gated on a per-server first, and
		-- `firstDiscovery` is that answer — but `forRoll` takes a tier, not a
		-- volume, and Secret routes Global. Suppressing the repeat would mean
		-- either rebuilding the banner text here (the one thing that service
		-- exists to own) or lying about the tier, which would recolour the
		-- banner. So a repeat re-publishes; it costs one extra global line for
		-- a pair that needs two T4/T5 ingredients to reproduce.
		announcements.forRoll(player, view, tier)
	end

	if monetization then
		if firstRoll then
			monetization.awardBadge(player, "FirstMix")
		end
		local badge = TIER_BADGE[tier]
		if badge then
			monetization.awardBadge(player, badge)
		end
	end

	if analytics then
		analytics.roll(player, tier, luck)
		-- Unconditional: the funnel is deduped against profile.funnel, which
		-- counts a step once per player ever rather than once per session.
		analytics.funnel(player, "FirstMix")
	end

	if data then
		-- The new Mixling goes over as a delta. ProfileSync understands
		-- `mixlingAdded` precisely so a roll does not re-send a collection of
		-- hundreds to describe one addition; inventory and stats are small
		-- enough to send whole, and sending inventory whole is what lets a
		-- spent stack actually disappear on the client.
		local patch: { [string]: any } = {
			mixlingAdded = view,
			inventory = profile.inventory,
			stats = profile.stats,
		}
		if secret then
			-- Nobody else writes secretsFound, so nobody else would push it,
			-- and the Mixdex would keep showing a "???" the player just
			-- solved until their next full sync.
			patch.secretsFound = profile.secretsFound
		end
		data.push(player, patch)
	end

	MixerService.onRolled:fire(player, mixling, newMixdexEntry, mixling.secretId)

	return mixling, nil
end

-- ── Remotes ──────────────────────────────────────────────────────────────

local function connectRemotes()
	Net.onServerEvent("RequestMix", function(player: Player, critterName: any, stuffName: any)
		if not Net.isString(critterName) or not Net.isString(stuffName) then
			return
		end
		local mixling, reason = MixerService.rollFor(player, critterName, stuffName)
		if not mixling and reason then
			notify(player, reason)
		end
	end)
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

function MixerService.init(services: { [string]: any })
	data = services.DataService
	-- Captured because the boot contract lists it, and because a Mixling's
	-- rate is Economy's number even though a freshly rolled one is unplaced
	-- and therefore earns nothing until DenService says otherwise.
	economy = services.EconomyService
	mixdex = services.MixdexService
	announcements = services.AnnouncementService
	monetization = services.MonetizationService
	analytics = services.AnalyticsService
end

function MixerService.start()
	if not data then
		warn("[MixerService] DataService is missing; every mix will be refused.")
	end
	-- A mix is paid for in ingredients, not Goop (GDD §8.1), so a missing
	-- EconomyService cannot stop one — but a registry short a service is a
	-- boot-order bug, and it is worth saying so once.
	if not economy then
		warn("[MixerService] EconomyService is missing from the registry.")
	end

	Players.PlayerRemoving:Connect(function(player)
		lastRollAt[player] = nil
	end)

	connectRemotes()
end

return MixerService
