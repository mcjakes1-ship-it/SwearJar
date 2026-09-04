--!strict
--[[
	ShopService.luau — the Goop shops and the two Den sinks. GDD §8.6, §8.3.

	OWNS the "RequestPurchase" handler and the three things Goop buys:

	  Ingredient     one shelf item      -> profile.inventory[name] += 1
	  DenSlot        the next pedestal   -> profile.denSlots += 1
	  LockUpgrade    the next door tier  -> profile.lockLevel += 1

	Public surface:

	  ShopService.priceFor(kind, id, profile) -> (price: number?, reason: string?)
	  ShopService.catalogue(player)           -> what a shelf needs to draw itself
	  ShopService.purchase(player, kind, id)  -> (ok: boolean, reason: string?)

	ONE PRICE FUNCTION, TWO READERS. `priceFor` is the only place in the game
	a Goop price is decided; the shelf label and the till both read it. Two
	functions would drift, and a shelf that says 500 while the till takes 600
	is a support ticket the player is right about. `catalogue` is that same
	function fanned out over the shelves, so the UI never computes a price of
	its own — it is handed one.

	THIS SERVICE HOLDS NO STATE. The profile is the state: slots owned, lock
	tier and inventory all live there. There is nothing to cache, invalidate
	or clean up when a player leaves, which is also why nothing here connects
	to PlayerRemoving.

	IT DOES NOT REGISTER "Query", DELIBERATELY. `Query` is one RemoteFunction
	and a RemoteFunction has exactly one OnServerInvoke, so two services
	claiming it means whichever booted last silently wins and the other's
	branch vanishes with no error. PlayerService owns that callback and routes
	the "ShopPrices" kind into `catalogue` — which is the whole reason the
	pricing functions above are public instead of local.

	THE CONFIRMATION DIALOG IS THE CLIENT'S, AND ONLY THE CLIENT'S. GDD §8.6
	asks for a confirm step at or above Constants.SHOP_CONFIRM_THRESHOLD.
	There is no two-step handshake here and none should be added: a
	confirmation guards against a misclick, not against an exploiter, who
	would simply never send the first half. A server-side "pending purchase"
	state would buy nothing and would add a way to strand a player's Goop.
	The server remains the sole authority on what a thing costs (`priceFor`)
	and on whether it can be afforded (`EconomyService.trySpend`); `confirm`
	in the catalogue is a rendering hint, and the answer is identical whether
	the client asked first or not.

	STARTER INGREDIENTS ARE NOT SOLD, EVEN THOUGH THEY ARE FREE. Frog and
	Sock are priced 0 because GDD §7.2 grants them once per profile, not
	because they are cheap. A 0-Goop shelf item is an unlimited free roll and
	the end of the Goop economy — Ingredients.luau names this service as the
	thing that refuses them and tools/spec asserts it. `priceFor` returns a
	reason instead of a price for anything `Ingredients.isPurchasable`
	rejects; the route from shelf to charge is otherwise identical, so there
	is still exactly one path through this file.

	NOTHING HERE DECREMENTS GOOP. Every charge goes through
	`EconomyService.trySpend`, which is atomic — the affordability check and
	the deduction sit in one non-yielding step, so one balance can never buy
	two things. This file only decides the price and applies the reward.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = ReplicatedStorage:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Config:WaitForChild("Constants"))
local Ingredients = require(Config:WaitForChild("Ingredients"))
local Net = require(Shared:WaitForChild("Net"))
local Types = require(Shared:WaitForChild("Types"))

type Profile = Types.Profile

local ShopService = {}
ShopService.Name = "ShopService"

-- ── Wire vocabulary ──────────────────────────────────────────────────────
-- The `kind` strings a client may send with RequestPurchase, and the Notify
-- channel the shop UI listens on. Protocol labels, not balance values, so
-- none of them belong in Constants (GDD §17 covers what the player feels).

local KIND_INGREDIENT = "Ingredient"
local KIND_DEN_SLOT = "DenSlot"
local KIND_LOCK = "LockUpgrade"

local NOTIFY_KIND = "Shop"

-- Groups every Goop sink this file owns under one prefix in the GDD §15
-- economy rows, so "how much does the shop drain" is one dashboard filter
-- while each shelf item still reports separately.
local SINK_PREFIX = "shop:"

-- Player-facing lines that more than one path needs. Kept together so the
-- shop's voice is edited in one place rather than six.
local NOT_LOADED = "Still loading your stuff — try again in a second."
local NOT_FOR_SALE = "That is not for sale."
local TOO_POOR = "Not enough Goop."
local CLOSED = "The shop is closed right now."

-- ── Public types ─────────────────────────────────────────────────────────
-- The shape PlayerService hands back through the "ShopPrices" Query. Every
-- number the shelf renders is computed here, including `affordable` and
-- `confirm`, so the client never has to know a threshold or a balance rule.

export type ShopItem = {
	name: string,
	kind: "Critter" | "Stuff", -- which shelf it belongs on
	tier: number,
	luck: number,
	price: number,
	owned: number,
	affordable: boolean,
	confirm: boolean,
	featured: boolean, -- the Weekly Drop slot (GDD §8.6, §12)
}

export type SlotOffer = {
	owned: number, -- pedestals this profile has paid for
	max: number, -- the Goop-purchasable ceiling
	hardMax: number, -- the ceiling once the game pass is counted
	price: number?,
	available: boolean,
	reason: string?, -- why not, when `available` is false
	affordable: boolean,
	confirm: boolean,
}

export type LockOffer = {
	level: number,
	maxLevel: number,
	duration: number, -- seconds the door currently holds
	nextDuration: number?, -- what the upgrade buys
	price: number?,
	available: boolean,
	reason: string?,
	affordable: boolean,
	confirm: boolean,
}

export type ShopCatalogue = {
	goop: number,
	confirmThreshold: number,
	critters: { ShopItem },
	stuff: { ShopItem },
	denSlot: SlotOffer,
	lock: LockOffer,
}

-- ── State ────────────────────────────────────────────────────────────────
-- Registry handles only; see the header on why there is nothing else.

local data: any = nil
local economy: any = nil
local den: any = nil
local analytics: any = nil

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

local function confirmNeeded(price: number): boolean
	return price >= Constants.SHOP_CONFIRM_THRESHOLD
end

--[[
	Asks DenService to redraw the padlocks now.

	It would happen anyway: `DenService.totalSlots` reads profile.denSlots
	directly, so the slot is owned the instant it is bumped and that service's
	heartbeat reconciles the pedestals within a tick. This only removes the
	tick of lag between paying and watching the padlock come off, which is the
	entire feeling of buying a slot.

	No pedestal-refresh entry point is listed in ARCHITECTURE §4, so the call
	is made only if one exists and can never throw out of the handler: a slot
	the player has already been charged for must not be undone by a redraw.
]]
local function refreshDenVisuals(player: Player)
	if not den then
		return
	end
	local refresh = (den :: any).refreshSlots
	if type(refresh) ~= "function" then
		return
	end
	local ok, err = pcall(function()
		refresh(player)
	end)
	if not ok then
		warn("[ShopService] DenService pedestal refresh failed: " .. tostring(err))
	end
end

-- ── Prices ───────────────────────────────────────────────────────────────
-- Each returns (price, nil) or (nil, a line to show the player). Never both,
-- never neither: a refusal the player cannot read is the shop button that
-- does nothing, which is the worst outcome in this file.

local function ingredientPrice(_profile: Profile?, name: string): (number?, string?)
	local item = Ingredients.ByName[name]
	if not item then
		return nil, NOT_FOR_SALE
	end
	if not Ingredients.isPurchasable(name) then
		-- The starter grant, not stock. See the header.
		return nil, ("%s came free with your starter kit."):format(item.name)
	end
	return item.price, nil
end

local function slotPrice(profile: Profile?, _id: string): (number?, string?)
	if not profile then
		return nil, NOT_LOADED
	end
	if profile.denSlots >= Constants.DEN_SLOTS_MAX then
		-- The last five pedestals are the DenSlots pass (GDD §8.3, §9), not a
		-- Goop sink, so this is a redirect rather than a dead end.
		return nil, "Den is full — the last slots come with the Den Slots pass."
	end

	local step = profile.denSlots - Constants.DEN_SLOTS_START + 1
	local price = Constants.DEN_SLOT_PRICES[step]
	if not price then
		-- DEN_SLOT_PRICES ran out before DEN_SLOTS_MAX: a Constants edit, not
		-- something the player did. Refuse rather than invent a number.
		warn(("[ShopService] no DEN_SLOT_PRICES entry %d for a Den of %d slots; check Constants.")
			:format(step, profile.denSlots))
		return nil, NOT_FOR_SALE
	end
	return price, nil
end

local function lockPrice(profile: Profile?, _id: string): (number?, string?)
	if not profile then
		return nil, NOT_LOADED
	end
	local upgrade = Constants.LOCK[profile.lockLevel + 1]
	if not upgrade then
		return nil, "Your door is already at the strongest lock."
	end
	return upgrade.price, nil
end

-- ── Rewards ──────────────────────────────────────────────────────────────
-- Reached only after trySpend has returned true. Nothing here yields, so
-- there is no window in which the Goop is gone and the goods are not.

local function grantIngredient(player: Player, profile: Profile, name: string)
	profile.inventory[name] = (profile.inventory[name] or 0) + 1

	if data then
		-- The inventory replicates whole rather than as a delta: it is a
		-- handful of counters, and sending it whole is what lets a stack the
		-- Mixer spent actually disappear on the client.
		data.push(player, { inventory = profile.inventory })
	end
	if analytics then
		-- Unconditional: the funnel is deduped against profile.funnel, so
		-- this counts the first shop buy per player ever, not per session.
		analytics.funnel(player, "FirstShopBuy")
	end
end

local function grantSlot(player: Player, profile: Profile, _id: string)
	profile.denSlots += 1
	if data then
		data.push(player, { denSlots = profile.denSlots })
	end
	refreshDenVisuals(player)
end

local function grantLock(player: Player, profile: Profile, _id: string)
	profile.lockLevel += 1
	if data then
		data.push(player, { lockLevel = profile.lockLevel })
	end
end

-- ── The counter ──────────────────────────────────────────────────────────
--[[
	One row per thing Goop buys. Price, sink label and reward sit together so
	`priceFor` and `purchase` dispatch on `kind` exactly once each and can
	never end up quoting one offer while applying another.
]]

type Offer = {
	price: (Profile?, string) -> (number?, string?),
	apply: (Player, Profile, string) -> (),
	sink: (string) -> string,
	bought: (string) -> string, -- the receipt line
}

local OFFERS: { [string]: Offer } = {
	[KIND_INGREDIENT] = {
		price = ingredientPrice,
		apply = grantIngredient,
		sink = function(name: string): string
			return SINK_PREFIX .. name
		end,
		bought = function(name: string): string
			return ("Bought %s."):format(name)
		end,
	},
	[KIND_DEN_SLOT] = {
		price = slotPrice,
		apply = grantSlot,
		sink = function(_id: string): string
			return SINK_PREFIX .. KIND_DEN_SLOT
		end,
		bought = function(_id: string): string
			return "New pedestal unlocked."
		end,
	},
	[KIND_LOCK] = {
		price = lockPrice,
		apply = grantLock,
		sink = function(_id: string): string
			return SINK_PREFIX .. KIND_LOCK
		end,
		bought = function(_id: string): string
			return "Your door just got tougher."
		end,
	},
}

-- ── Public API ───────────────────────────────────────────────────────────

--[[
	What `kind`/`id` costs this profile right now, or nil plus the line to
	show the player. The shelf and the till both read this; see the header.

	`profile` is optional because an ingredient's price does not depend on
	one, but the two Den offers do — their price is a function of how far up
	the ladder the player already is — and those refuse without it rather than
	quote the first rung to everybody.
]]
function ShopService.priceFor(kind: string, id: string, profile: Profile?): (number?, string?)
	if not Net.isString(kind) then
		return nil, NOT_FOR_SALE
	end
	local offer = OFFERS[kind]
	if not offer then
		return nil, NOT_FOR_SALE
	end
	local target = if Net.isString(id) then id else ""
	return offer.price(profile, target)
end

--[[
	Charges for and hands over one purchase. Returns false plus a player-facing
	reason for every refusal — a shop button that does nothing teaches the
	player that the shop is broken.

	Re-validates its own arguments because this is a public entry point and
	the remote handler is only one of its callers.
]]
function ShopService.purchase(player: Player, kind: string, id: string): (boolean, string?)
	local profile = profileOf(player)
	if not profile then
		return false, NOT_LOADED
	end

	local price, reason = ShopService.priceFor(kind, id, profile)
	if not price then
		return false, reason or NOT_FOR_SALE
	end

	local offer = OFFERS[kind]
	if not offer then
		return false, NOT_FOR_SALE -- unreachable: priceFor already resolved it
	end
	if not economy then
		return false, CLOSED
	end

	local target = if Net.isString(id) then id else ""

	-- The only exit Goop has. Atomic, so the balance cannot be spent twice,
	-- and false here means nothing was deducted.
	if not economy.trySpend(player, price, offer.sink(target)) then
		return false, TOO_POOR
	end

	offer.apply(player, profile, target)
	notify(player, offer.bought(target))
	return true, nil
end

--[[
	Everything the shop UI draws, priced for this player. Routed here by
	PlayerService's "ShopPrices" Query (see the header on why this service
	does not claim the RemoteFunction itself).

	Shelves come from Ingredients.catalogue, which already drops the starter
	grant and sorts by tier then price the way GDD §8.6 asks, so the order the
	client receives is the order it renders.
]]
function ShopService.catalogue(player: Player): ShopCatalogue
	local profile = profileOf(player)
	local goop = if profile then profile.goop else 0

	local function shelf(kind: string): { ShopItem }
		-- The Weekly Drop is flagged, not duplicated: a second copy of the row
		-- would show its own "Owned: n" and drift from the real one. The
		-- client pins the flagged item to the front of the shelf.
		local newest = Ingredients.newest(kind)
		local featured = if newest and Ingredients.isPurchasable(newest.name) then newest.name else nil

		local out: { ShopItem } = {}
		for _, item in Ingredients.catalogue(kind) do
			table.insert(out, {
				name = item.name,
				kind = item.kind,
				tier = item.tier,
				luck = item.luck,
				price = item.price,
				owned = if profile then profile.inventory[item.name] or 0 else 0,
				affordable = goop >= item.price,
				confirm = confirmNeeded(item.price),
				featured = featured == item.name,
			})
		end
		return out
	end

	local slotCost, slotReason = slotPrice(profile, "")
	local lockCost, lockReason = lockPrice(profile, "")

	local level = if profile then profile.lockLevel else 1
	local current = Constants.LOCK[level]
	local upgrade = Constants.LOCK[level + 1]

	return {
		goop = goop,
		confirmThreshold = Constants.SHOP_CONFIRM_THRESHOLD,
		critters = shelf("Critter"),
		stuff = shelf("Stuff"),

		denSlot = {
			owned = if profile then profile.denSlots else Constants.DEN_SLOTS_START,
			max = Constants.DEN_SLOTS_MAX,
			hardMax = Constants.DEN_SLOTS_HARD_MAX,
			price = slotCost,
			available = slotCost ~= nil,
			reason = slotReason,
			affordable = slotCost ~= nil and goop >= slotCost,
			confirm = slotCost ~= nil and confirmNeeded(slotCost),
		},

		lock = {
			level = level,
			maxLevel = #Constants.LOCK,
			duration = if current then current.duration else 0,
			nextDuration = if upgrade then upgrade.duration else nil,
			price = lockCost,
			available = lockCost ~= nil,
			reason = lockReason,
			affordable = lockCost ~= nil and goop >= lockCost,
			confirm = lockCost ~= nil and confirmNeeded(lockCost),
		},
	}
end

-- ── Remotes ──────────────────────────────────────────────────────────────

local function connectRemotes()
	Net.onServerEvent("RequestPurchase", function(player: Player, kind: any, id: any)
		if not Net.isString(kind) then
			return -- no shop button can produce this; only a hand-rolled client
		end
		-- Only Ingredient carries an id; the two Den offers are named by their
		-- kind alone, so a client that sends nothing there is not malformed.
		-- Anything that is not a usable string becomes "", which no offer
		-- resolves, and the player is told so rather than ignored.
		local target = if Net.isString(id) then id :: string else ""

		local ok, reason = ShopService.purchase(player, kind :: string, target)
		if not ok and reason then
			notify(player, reason)
		end
	end)
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

function ShopService.init(services: { [string]: any })
	data = services.DataService
	economy = services.EconomyService
	den = services.DenService
	analytics = services.AnalyticsService
end

function ShopService.start()
	if not data then
		warn("[ShopService] DataService is missing; every purchase will be refused.")
	end
	-- Without a till there is no atomic way to charge, and a shop that hands
	-- out free ingredients is worse than a shop that is shut.
	if not economy then
		warn("[ShopService] EconomyService is missing; nothing can be bought.")
	end
	if not den then
		warn("[ShopService] DenService is missing; bought slots will still count, "
			.. "but their pedestals only redraw on that service's own heartbeat.")
	end

	connectRemotes()
end

return ShopService
