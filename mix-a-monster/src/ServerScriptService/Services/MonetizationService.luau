--!strict
--[[
	MonetizationService.luau — every Roblox platform integration. GDD §9,
	§8.7 (badges), §11.3 (idempotent receipts).

	OWNS: game passes, developer products, `ProcessReceipt`, the server Luck
	Party window, badge awards, and the VIP chat tag. Nothing else in the
	codebase may touch MarketplaceService or BadgeService — one owner means one
	place where a platform call is retried, rate-thought-about, and pcall'd.

	THE CONTRACT OTHER SERVICES RELY ON:
	  hasPass(player, key)        -> boolean   key indexes Constants.PASSES
	  getLuck(player)             -> number    pass luck + active server luck
	  getGoopMultiplier(player)   -> number    1 or the 2x Goop pass
	  getSlotBonus(player)        -> number    0 or the +5 Den Slots pass
	  getServerLuck()             -> number    this server's Luck Party, or 0
	  promptPass(player, key) / promptProduct(player, key)
	  awardBadge(player, badgeKey)             key indexes Constants.BADGES

	WHY `id == 0` IS A FIRST-CLASS STATE, NOT AN ERROR: the owner fills the
	pass, product and badge ids in at Studio setup, which happens after the
	code is written (GDD §9, §14). Every id of 0 means "not wired": the
	Marketplace/Badge call is skipped, the feature reports as unowned, and the
	game runs. The unwired keys are named ONCE at boot rather than per call,
	because a per-call warning from a per-second loop is how a log becomes
	unreadable. This is what makes the repo playable and testable before a
	single asset id exists.

	WHY THE PASS CACHE LIVES IN THE PROFILE: `hasPass` is called from the Goop
	tick and from every slot and luck calculation, so it cannot afford a web
	round trip. `profile.passes[key]` is the cache: `nil` means "never asked",
	`true`/`false` are real answers. Every join re-verifies the whole set
	against the platform (`refreshPasses`), which is what lets an off-site
	purchase — or a refund — land without the player having to do anything.
	`PromptGamePassPurchaseFinished` updates it mid-session so a pass works the
	instant it is bought, not on the next rejoin.

	WHY A RECEIPT IS RECORDED BEFORE IT IS GRANTED: Roblox re-delivers a
	receipt until the handler returns `PurchaseGranted`, so the same purchase
	id can arrive twice. Claiming the id first (GDD §11.3) makes the second
	delivery a no-op ack instead of a second grant. The mirror rule: if the
	profile is not loaded, or the thing that does the granting is missing,
	return `NotProcessedYet` and grant nothing — Roblox keeps the purchase
	alive and retries. Never consume a purchase we cannot honour.
]]

local BadgeService = game:GetService("BadgeService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Config = ReplicatedStorage:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Config:WaitForChild("Constants"))
local Net = require(Shared:WaitForChild("Net"))
local Types = require(Shared:WaitForChild("Types"))
local Util = require(Shared:WaitForChild("Util"))

type Profile = Types.Profile

local MonetizationService = {}
MonetizationService.Name = "MonetizationService"

-- ── Catalogue views ──────────────────────────────────────────────────────
-- Constants.PASSES and Constants.PRODUCTS are deliberately heterogeneous —
-- each entry carries whichever bonus it grants — so iterating them by a
-- runtime key needs one declared shape. These are read-only aliases over the
-- frozen table, never copies: a copy would be a second source of truth.

type PassDef = {
	id: number,
	name: string,
	price: number,
	luck: number?,
	goopMultiplier: number?,
	slotBonus: number?,
	dailyMultiplier: number?,
}

type ProductDef = {
	id: number,
	name: string,
	price: number,
	goop: number?,
	kind: string?,
	luck: number?,
	seconds: number?,
}

local PASSES: { [string]: PassDef } = Constants.PASSES :: any
local PRODUCTS: { [string]: ProductDef } = Constants.PRODUCTS :: any
local BADGES: { [string]: number } = Constants.BADGES :: any

local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
local RETRY = Enum.ProductPurchaseDecision.NotProcessedYet

-- What a VIP's chat line is prefixed with (GDD §9). Not a balance value, so
-- not in Constants — it is presentation, the same call AnnouncementService
-- makes for its own CHAT_PREFIX. TextChatService renders PrefixText as rich
-- text, and the colour is most of what makes a tag read as a tag.
local VIP_CHAT_TAG = '<font color="#FFD04A">[VIP]</font> '

local function sortedKeys(map: { [string]: any }): { string }
	local keys: { string } = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local PASS_KEYS = sortedKeys(PASSES)
local PRODUCT_KEYS = sortedKeys(PRODUCTS)

-- Asset id -> catalogue key. Built in sorted order so a duplicated id (an easy
-- copy-paste slip during Studio setup) resolves to the same key every boot
-- instead of whichever key the hash order happened to visit last.
local passKeyById: { [number]: string } = {}
local productKeyById: { [number]: string } = {}

local passIds: { [string]: number } = {}
local productIds: { [string]: number } = {}

for _, key in PASS_KEYS do
	local id = PASSES[key].id
	passIds[key] = id
	if id ~= 0 and not passKeyById[id] then
		passKeyById[id] = key
	end
end

for _, key in PRODUCT_KEYS do
	local id = PRODUCTS[key].id
	productIds[key] = id
	if id ~= 0 and not productKeyById[id] then
		productKeyById[id] = key
	end
end

-- ── State ────────────────────────────────────────────────────────────────

local data: any = nil
local economy: any = nil
local announcements: any = nil
local analytics: any = nil
local den: any = nil

-- The Luck Party is per-server and in memory by design: it is a property of
-- this server's population, not of anyone's save file.
local partyLuck = 0
local partyEndsAt = 0 -- os.time(); 0 when no party is running
local partyGeneration = 0

-- player -> pass key -> a UserOwnsGamePassAsync call is already in flight.
local querying: { [Player]: { [string]: boolean } } = {}

local function profileOf(player: Player): Profile?
	if not data then
		return nil
	end
	return data.get(player)
end

-- ── Boot report ──────────────────────────────────────────────────────────

--[[
	Names every unwired key once, at boot. The clash warning matters more than
	it looks: two products sharing an id means one purchase grants the other
	product, and the only symptom in the wild is a confused player.
]]
local function reportWiring(label: string, ids: { [string]: number })
	local unwired: { string } = {}
	local byId: { [number]: string } = {}

	for _, key in sortedKeys(ids) do
		local id = ids[key]
		if id == 0 then
			table.insert(unwired, key)
			continue
		end
		local clash = byId[id]
		if clash then
			warn(("[Monetization] %s %q and %q share id %d; a purchase of one would grant the other")
				:format(label, clash, key, id))
			continue
		end
		byId[id] = key
	end

	if #unwired == 0 then
		return
	end
	warn(("[Monetization] %d of %d %s are not wired (id = 0) and stay inert until their ids are filled into Constants: %s")
		:format(#unwired, Util.count(ids), label, table.concat(unwired, ", ")))
end

-- ── Client sync ──────────────────────────────────────────────────────────

--[[
	Pushes the two ProfileView fields this service owns.

	Luck is read straight off the cache rather than through `getLuck`, which
	could start a web query and re-enter this function from the resolve that
	follows it. An unresolved pass simply is not counted yet; the resolve
	pushes again.
]]
local function pushState(player: Player)
	local profile = profileOf(player)
	if not profile then
		return
	end
	local luck = MonetizationService.getServerLuck()
	if profile.passes.LuckyMixer then
		luck += Constants.PASSES.LuckyMixer.luck
	end
	data.push(player, { passes = profile.passes, luck = luck })
end

local function notify(player: Player, kind: string, text: string)
	if not player.Parent then
		return
	end
	Net.fire(player, "Notify", kind, text)
end

-- ── Pass ownership ───────────────────────────────────────────────────────

-- Returns true when the cached answer actually changed.
local function writeCache(player: Player, key: string, owned: boolean): boolean
	local profile = profileOf(player)
	if not profile or profile.passes[key] == owned then
		return false
	end
	profile.passes[key] = owned
	return true
end

--[[
	The cached answer and nothing else: never a web query, never a yield.

	This is what a caller uses when it is somewhere that cannot afford either —
	`installChatTag`'s callback sits between a player pressing enter and their
	message reaching the channel. `nil` (never asked) reads as "no", which is
	right for a cosmetic: refreshPasses resolves the whole set moments after
	the join, and the answer is only ever late, never wrong.
]]
local function ownsCached(player: Player, key: string): boolean
	if passIds[key] ~= 0 then
		local profile = profileOf(player)
		if profile then
			return profile.passes[key] == true
		end
	end
	return false -- unwired (reported at boot), or no profile to have cached one
end

-- Yields. nil means the platform could not be asked, which is NOT the same as
-- "does not own it": a failed query must never be cached as a false.
local function fetchOwnership(player: Player, key: string, id: number): boolean?
	local ok, owned = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, id)
	end)
	if ok then
		return owned == true
	end
	warn(("[Monetization] pass check failed for %s / %s: %s"):format(player.Name, key, tostring(owned)))
	return nil
end

--[[
	Re-verifies every wired pass against the platform and caches the answers.
	Runs once per join, sequentially — four web calls in a row cost less than
	four threads racing to write the same profile, and nothing is waiting on
	the result.
]]
local function refreshPasses(player: Player)
	local changed = false
	for _, key in PASS_KEYS do
		if not player.Parent or not profileOf(player) then
			return
		end
		local id = passIds[key]
		if id ~= 0 then
			local owned = fetchOwnership(player, key, id)
			if owned ~= nil and writeCache(player, key, owned) then
				changed = true
			end
		end
	end
	if not changed then
		return
	end
	-- 2x Goop is a multiplier on placed Mixlings, so the income figure the
	-- player is looking at is wrong until Economy recomputes it.
	if economy then
		economy.recompute(player)
	end
	pushState(player)
end

--[[
	The cached answer, or one fetched now. See the header for why the cache is
	the profile.

	The in-flight guard is load-bearing rather than tidy: this is called from
	per-second loops, so a cache miss that yields must not let the next tick
	start a second query for the same pass. A caller that arrives during a
	query is told "no" — one tick of a wrong answer, never a request storm.
]]
function MonetizationService.hasPass(player: Player, key: string): boolean
	if not Net.isString(key) then
		return false
	end
	local id = passIds[key]
	if id == nil then
		warn(("[Monetization] unknown pass key %q; it must be listed in Constants.PASSES"):format(key))
		return false
	end
	if id == 0 then
		return false -- not wired; reported at boot
	end

	local profile = profileOf(player)
	if not profile then
		-- There is nowhere to cache an answer, so asking the platform would
		-- mean asking again on every single call. The profile is moments away
		-- and refreshPasses resolves the whole set the instant it lands.
		return false
	end
	local cached = profile.passes[key]
	if cached ~= nil then
		return cached
	end

	local inFlight = querying[player] or {}
	if inFlight[key] then
		return false
	end
	querying[player] = inFlight
	inFlight[key] = true

	local owned = fetchOwnership(player, key, id)

	local stillTracked = querying[player]
	if stillTracked then
		stillTracked[key] = nil
	end
	if owned == nil then
		return false
	end
	if writeCache(player, key, owned) then
		pushState(player)
	end
	return owned
end

-- ── Multipliers ──────────────────────────────────────────────────────────

function MonetizationService.getServerLuck(): number
	if partyEndsAt <= os.time() then
		return 0
	end
	return partyLuck
end

function MonetizationService.getLuck(player: Player): number
	local luck = MonetizationService.getServerLuck()
	if MonetizationService.hasPass(player, "LuckyMixer") then
		luck += Constants.PASSES.LuckyMixer.luck
	end
	return luck
end

function MonetizationService.getGoopMultiplier(player: Player): number
	if MonetizationService.hasPass(player, "DoubleGoop") then
		return Constants.PASSES.DoubleGoop.goopMultiplier
	end
	return 1
end

function MonetizationService.getSlotBonus(player: Player): number
	if MonetizationService.hasPass(player, "DenSlots") then
		return Constants.PASSES.DenSlots.slotBonus
	end
	return 0
end

-- ── The VIP chat tag (GDD §9) ────────────────────────────────────────────

--[[
	The first of the three things VIP sells.

	`OnIncomingMessage` is a single-slot callback, the same shape as
	`ProcessReceipt`: a second assignment anywhere in the place would silently
	replace this one. That is why it is here, in the service that owns every
	platform surface, and why it is assigned exactly once.

	IT MUST NOT YIELD. The callback runs between the player pressing enter and
	the message reaching the channel, so it reads the pass cache directly
	rather than through `hasPass`, which starts a web query on a miss. Nothing
	is lost: the cache is filled on join, and `PromptGamePassPurchaseFinished`
	writes it the instant VIP is bought, so the tag lands on the buyer's very
	next line without a rejoin.

	The whole thing is behind a pcall and a ChatVersion check, the way
	AnnouncementService guards its own use of this API: the surface differs
	between legacy chat, TextChatService and hybrid places, and a place where
	it is absent must degrade to no tag rather than to an error on every
	message. An unwired pass id never installs the hook at all — the id == 0
	rule, decided once here instead of per message.
]]
local function onIncomingMessage(message: TextChatMessage): TextChatMessageProperties?
	local source = message.TextSource
	if not source then
		return nil -- a system line (AnnouncementService's, for one) has no sender
	end
	local player = Players:GetPlayerByUserId(source.UserId)
	if not player or not ownsCached(player, "VIP") then
		return nil -- nil means "no overrides", which is the un-tagged message
	end

	local properties = Instance.new("TextChatMessageProperties")
	-- Prefixed, not replaced: PrefixText already holds the display name the
	-- chat is configured to show, and rebuilding it here would quietly undo
	-- whatever the place decided about names.
	properties.PrefixText = VIP_CHAT_TAG .. message.PrefixText
	return properties
end

local function installChatTag()
	if passIds.VIP == 0 then
		return -- not wired; reported at boot, and no tag is the correct state
	end
	-- The annotated return is what lets a two-value pcall type check; the
	-- DenService heartbeat is wrapped the same way.
	local ok, err = pcall(function(): any
		if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
			TextChatService.OnIncomingMessage = onIncomingMessage
		end
		-- Any other chat version is a place with no server-side hook to hang a
		-- tag on. That is a no-op, not a failure.
		return nil
	end)
	if not ok then
		warn("[Monetization] the VIP chat tag is off: " .. tostring(err))
	end
end

-- ── Server Luck Party (GDD §9) ───────────────────────────────────────────

local function endParty()
	partyLuck = 0
	partyEndsAt = 0
	Net.fireAll("ServerLuck", 0, 0)
	if announcements then
		announcements.server({
			scope = "Server",
			kind = "LuckParty",
			text = "The Luck Party is over. Back to normal odds!",
		})
	end
	if data then
		data.forEach(function(player: Player)
			pushState(player)
		end)
	end
end

--[[
	One timer per party. The generation token means an extension simply
	orphans the old timer instead of having to cancel it, and the extra second
	covers os.time()'s one-second granularity so the window can never be cut
	short by rounding.
]]
local function armExpiry()
	partyGeneration += 1
	local generation = partyGeneration
	task.delay(math.max(partyEndsAt - os.time(), 0) + 1, function()
		if generation ~= partyGeneration then
			return
		end
		endParty()
	end)
end

--[[
	Starts (or extends) the server-wide luck window. GDD §9 sells "+2 luck for
	everyone for 10 min", so a second purchase buys more MINUTES, not more
	luck — stacking the value would sell a Mythic rate to whoever spends most,
	which is the one thing §9's principles rule out.
]]
local function startLuckParty(buyer: Player)
	local def = Constants.PRODUCTS.LuckParty
	local now = os.time()
	local extended = partyEndsAt > now

	partyEndsAt = (if extended then partyEndsAt else now) + def.seconds
	partyLuck = def.luck
	armExpiry()

	Net.fireAll("ServerLuck", partyLuck, partyEndsAt)

	if announcements then
		local text = if extended
			then ("%s EXTENDED the Luck Party! +%d luck for everyone, %s left!")
				:format(buyer.DisplayName, def.luck, Util.clock(partyEndsAt - now))
			else ("%s started a SERVER LUCK PARTY! +%d luck for EVERYONE for %s!")
				:format(buyer.DisplayName, def.luck, Util.clock(def.seconds))
		announcements.server({
			scope = "Server",
			kind = "LuckParty",
			text = text,
			playerName = buyer.DisplayName,
			shake = true,
			fanfare = true,
		})
	end

	-- GDD §9: the buyer gets a server banner AND a badge. This is the only
	-- socially-motivated purchase in the game, so the badge is the receipt the
	-- buyer keeps after the ten minutes are up.
	MonetizationService.awardBadge(buyer, "LuckPartyHost")

	-- Everyone's luck figure just changed, not only the buyer's.
	if data then
		data.forEach(function(player: Player)
			pushState(player)
		end)
	end
	if analytics then
		analytics.event("LuckParty", { player = buyer, extended = extended, value = def.luck })
	end
end

-- ── Prompts ──────────────────────────────────────────────────────────────

local function promptUnavailable(player: Player, name: string)
	notify(player, "Error", name .. " isn't in the shop yet — check back soon!")
end

function MonetizationService.promptPass(player: Player, key: string)
	if not player.Parent or not Net.isString(key) then
		return
	end
	local def = PASSES[key]
	if not def then
		warn(("[Monetization] promptPass with unknown key %q"):format(key))
		return
	end
	if def.id == 0 then
		promptUnavailable(player, def.name)
		return
	end
	-- Prompting can throw when Roblox's catalogue is unreachable; a shop
	-- button that does nothing beats a shop button that errors the handler.
	local ok, err = pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, def.id)
	end)
	if not ok then
		warn(("[Monetization] pass prompt failed for %s / %s: %s"):format(player.Name, key, tostring(err)))
		return
	end
	if analytics then
		analytics.event("PromptPass", { player = player, pass = key, value = def.price })
	end
end

function MonetizationService.promptProduct(player: Player, key: string)
	if not player.Parent or not Net.isString(key) then
		return
	end
	local def = PRODUCTS[key]
	if not def then
		warn(("[Monetization] promptProduct with unknown key %q"):format(key))
		return
	end
	if def.id == 0 then
		promptUnavailable(player, def.name)
		return
	end
	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, def.id)
	end)
	if not ok then
		warn(("[Monetization] product prompt failed for %s / %s: %s"):format(player.Name, key, tostring(err)))
		return
	end
	if analytics then
		analytics.event("PromptProduct", { player = player, product = key, value = def.price })
	end
end

-- ── Badges (GDD §8.7) ────────────────────────────────────────────────────

--[[
	Fire-and-forget: the award is a web call and callers are mid-roll or
	mid-steal, where nothing may block (GDD §2, pillar 1).

	`profile.badges` is claimed BEFORE the call rather than after, because two
	callers in the same frame (a Mythic roll is a rarity badge and possibly a
	Mixdex milestone) would otherwise both pass the dedupe. A failed call
	releases the claim so the next time the condition fires it is retried.

	No UserHasBadgeAsync check: AwardBadgeAsync is already idempotent on
	Roblox's side, and one web call is cheaper than two.
]]
function MonetizationService.awardBadge(player: Player, badgeKey: string)
	if not Net.isString(badgeKey) then
		return
	end
	local id = BADGES[badgeKey]
	if id == nil then
		warn(("[Monetization] unknown badge key %q; it must be listed in Constants.BADGES"):format(badgeKey))
		return
	end
	if id == 0 then
		return -- not wired; reported at boot
	end

	local profile = profileOf(player)
	if not profile then
		return -- no ledger means no dedupe; a badge is never worth re-asking every session
	end
	if profile.badges[badgeKey] then
		return
	end
	profile.badges[badgeKey] = true

	task.spawn(function()
		local ok, err = pcall(function()
			-- The return value is deliberately ignored: `false` means Roblox
			-- declined (already owned, badge disabled, or unpublished), and
			-- in every one of those cases re-asking next session is noise.
			BadgeService:AwardBadgeAsync(player.UserId, id)
		end)
		if ok then
			if analytics then
				analytics.event("BadgeAwarded", { player = player, badge = badgeKey })
			end
			return
		end
		local live = profileOf(player)
		if live then
			live.badges[badgeKey] = nil
		end
		warn(("[Monetization] badge %s failed for %s: %s"):format(badgeKey, player.Name, tostring(err)))
	end)
end

-- ── Receipts (GDD §11.3) ─────────────────────────────────────────────────

-- Whether this product's grant path is reachable right now. Checked BEFORE
-- the receipt id is claimed, so a missing sibling service costs a retry
-- rather than the player's Robux.
local function grantableBy(def: ProductDef): (boolean, string)
	if def.goop then
		return economy ~= nil, "EconomyService"
	end
	if def.kind == "LockRefresh" then
		return den ~= nil, "DenService"
	end
	if def.kind == "LuckParty" then
		return true, ""
	end
	return false, "a grant rule for it"
end

local function grant(player: Player, key: string, def: ProductDef)
	if def.goop then
		-- "product:<key>" is the analytics source string for the whole Robux
		-- -> Goop path; GDD §8.2's curve is read per source.
		economy.award(player, def.goop, "product:" .. key)
		notify(player, "Success", ("+%s Goop!"):format(Util.comma(def.goop)))
		return
	end
	if def.kind == "LockRefresh" then
		den.refreshLock(player)
		notify(player, "Success", "Your Den lock is ready again.")
		return
	end
	startLuckParty(player)
end

--[[
	The inverse of `grant`, for the one case where a grant succeeded but could
	not be made durable. Only the Goop packs are reversible — a Lock Refresh and
	a Luck Party are already visible to the whole server by the time we know the
	write failed, so those are let stand and the receipt is re-acked on retry
	(the claim is gone with them, so the retry re-grants rather than double
	granting). Being generous with 49 R$ of lock cooldown beats a stuck receipt.
]]
local function revoke(player: Player, key: string, def: ProductDef): boolean
	if def.goop then
		return economy.trySpend(player, def.goop, "rollback:" .. key)
	end
	return false
end

--[[
	Roblox re-delivers a receipt until this returns PurchaseGranted, and it
	delivers to whichever server the player is on. Every early return here is
	NotProcessedYet on purpose: the purchase stays alive and comes back.

	The receipt table is unbounded by design — it is one boolean per lifetime
	purchase, which is a handful of bytes against DataService's 4 MB ceiling,
	and forgetting an id is the one thing that would let a late retry grant
	twice.
]]
local function processReceipt(info: { [string]: any })
	local userId = info.PlayerId
	local productId = info.ProductId
	local purchaseId = info.PurchaseId
	if not Net.isFiniteNumber(userId) or not Net.isFiniteNumber(productId) or purchaseId == nil then
		warn("[Monetization] malformed receipt; nothing granted")
		return RETRY
	end

	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return RETRY -- they left mid-purchase; Roblox redelivers on their next join
	end
	local profile = profileOf(player)
	if not profile then
		return RETRY -- never grant against a missing profile: the grant would not survive
	end

	local receiptKey = tostring(purchaseId)
	if profile.receipts[receiptKey] then
		return GRANTED -- already honoured; this is the ack Roblox is waiting for
	end

	local key = productKeyById[productId]
	local def = if key then PRODUCTS[key] else nil
	if not key or not def then
		warn(("[Monetization] receipt for unknown product id %s; fill it into Constants.PRODUCTS and it will be granted on retry")
			:format(tostring(productId)))
		return RETRY
	end

	local canGrant, requires = grantableBy(def)
	if not canGrant then
		warn(("[Monetization] cannot grant %s: %s is unavailable. Retrying rather than consuming the purchase.")
			:format(key, requires))
		return RETRY
	end

	profile.receipts[receiptKey] = true
	local granted, err = pcall(function()
		grant(player, key, def)
	end)
	if not granted then
		-- A claimed id with nothing behind it is the one state that silently
		-- eats Robux: every later delivery would ack it. Release the claim and
		-- let Roblox retry the whole thing.
		profile.receipts[receiptKey] = nil
		warn(("[Monetization] granting %s to %s failed: %s"):format(key, player.Name, tostring(err)))
		return RETRY
	end

	--[[
		Do not ack until the grant is DURABLE. Roblox treats PurchaseGranted as
		final and never redelivers, but at this point the claim and the grant
		exist only in a table in this server's memory — up to
		Constants.AUTOSAVE_SECONDS from disk. A crash in that window would take
		something the player paid real money for and leave no trace that they
		paid for it.

		If the write fails, roll the claim and the grant back exactly as the
		failure branch above does and return NotProcessedYet: Roblox retries,
		and a retry that grants twice is impossible because the claim is gone
		along with the grant.
	]]
	if data and data.saveNow and not data.saveNow(player) then
		profile.receipts[receiptKey] = nil
		local undone = pcall(function()
			revoke(player, key, def)
		end)
		warn(("[Monetization] could not persist %s for %s; not acking the receipt (rollback %s)")
			:format(key, player.Name, if undone then "ok" else "FAILED"))
		return RETRY
	end

	if analytics then
		local spent = if Net.isFiniteNumber(info.CurrencySpent) then info.CurrencySpent else def.price
		analytics.event("Purchase", { player = player, product = key, value = spent })
		-- funnel() dedupes against profile.funnel, so this lands on the first
		-- successful receipt ever and is a no-op on every one after it.
		analytics.funnel(player, "FirstPurchase")
	end
	return GRANTED
end

-- ── In-session pass purchases ────────────────────────────────────────────

local function onPassPurchased(player: Player, gamePassId: number, wasPurchased: boolean)
	if not wasPurchased then
		return
	end
	local key = passKeyById[gamePassId]
	if not key then
		return -- a pass from another experience, prompted by something else
	end

	local changed = writeCache(player, key, true)
	if economy then
		economy.recompute(player)
	end
	pushState(player)

	local def = PASSES[key]
	notify(player, "Success", def.name .. " unlocked!")
	if analytics and changed then
		analytics.event("PassPurchased", { player = player, pass = key, value = def.price })
	end
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

function MonetizationService.init(services: { [string]: any })
	data = services.DataService
	economy = services.EconomyService
	announcements = services.AnnouncementService
	analytics = services.AnalyticsService
	den = services.DenService
end

function MonetizationService.start()
	reportWiring("passes", passIds)
	reportWiring("products", productIds)
	reportWiring("badges", BADGES)

	-- Assigned once, here: ProcessReceipt is a single-slot callback, and a
	-- second assignment anywhere would silently replace this one.
	MarketplaceService.ProcessReceipt = processReceipt
	installChatTag()

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(onPassPurchased)

	local function onProfileReady(player: Player)
		-- A player who joins mid-party needs the window too, before the
		-- yielding pass check below.
		local luck = MonetizationService.getServerLuck()
		if luck > 0 then
			Net.fire(player, "ServerLuck", luck, partyEndsAt)
		end
		refreshPasses(player)
	end

	-- Profiles that loaded before this service started (a Studio restart with
	-- a player already in) would otherwise never be verified.
	if data then
		data.forEach(function(player: Player)
			task.spawn(onProfileReady, player)
		end)
		data.onLoaded:connect(function(player: Player)
			onProfileReady(player)
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		querying[player] = nil
	end)
end

return MonetizationService
