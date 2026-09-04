--!nonstrict
--[[
	spec.luau — behavioural tests for the realm-agnostic modules.

	Run:  tools/spec/run.sh

	Scope is deliberate. These cover the pure logic where a silent bug is
	expensive and a Studio playtest would not notice it:

	  * profile migration (Util.reconcile) — the "zero data-loss bugs" bar in
	    GDD §14 lives or dies here
	  * the roll (Rarity.roll / .odds) — the odds must be the odds
	  * naming, keys and secret matching — one wrong key order silently splits
	    the Mixdex in half
	  * number formatting — every Goop figure the player reads

	Instance-building (MixlingAssembler, UiKit) and anything touching a service
	is covered by the two-client Studio protocol in README.md instead.
]]

local M = require("./bundle")
local Random = M._shim.Random

local Constants = M.Constants
local Ingredients = M.Ingredients
local Rarity = M.Rarity
local Util = M.Util
local SecretRecipes = M.SecretRecipes
local SecretsPublic = M.SecretsPublic

local passed, failed = 0, 0
local failures = {}
local currentGroup = ""

local function group(name)
	currentGroup = name
end

local function check(label, condition, detail)
	if condition then
		passed += 1
	else
		failed += 1
		table.insert(failures, ("%s / %s%s"):format(currentGroup, label, if detail then "  (" .. detail .. ")" else ""))
	end
end

local function equal(label, actual, expected)
	check(label, actual == expected, ("got %s, expected %s"):format(tostring(actual), tostring(expected)))
end

local function near(label, actual, expected, tolerance)
	check(
		label,
		math.abs(actual - expected) <= tolerance,
		("got %.6f, expected %.6f +/- %.6f"):format(actual, expected, tolerance)
	)
end

-- ── Constants integrity ──────────────────────────────────────────────────
group("Constants")

equal("seven rarity tiers", #Constants.RARITY, 7)
equal("Secret has no roll weight", Constants.RARITY[Constants.RARITY_SECRET].weight, 0)
equal("rollable max stops before Secret", Constants.RARITY_ROLLABLE_MAX, 6)
check("goop/sec is strictly increasing by tier", (function()
	for tier = 2, #Constants.RARITY do
		if Constants.RARITY[tier].goopPerSec <= Constants.RARITY[tier - 1].goopPerSec then
			return false
		end
	end
	return true
end)())
check("hold time is strictly increasing by tier", (function()
	for tier = 2, #Constants.RARITY do
		if Constants.RARITY[tier].holdTime <= Constants.RARITY[tier - 1].holdTime then
			return false
		end
	end
	return true
end)())
check("rarer tiers are never more common", (function()
	for tier = 2, Constants.RARITY_ROLLABLE_MAX do
		if Constants.RARITY[tier].weight >= Constants.RARITY[tier - 1].weight then
			return false
		end
	end
	return true
end)())
equal("one den slot price per purchasable slot",
	#Constants.DEN_SLOT_PRICES, Constants.DEN_SLOTS_MAX - Constants.DEN_SLOTS_START)
equal("pass bonus lands exactly on the hard max",
	Constants.DEN_SLOTS_MAX + Constants.DEN_SLOTS_PASS_BONUS, Constants.DEN_SLOTS_HARD_MAX)
check("every den slot is reachable in the world",
	Constants.WORLD.PEDESTAL_COUNT >= Constants.DEN_SLOTS_HARD_MAX,
	"PEDESTAL_COUNT must cover the pass ceiling or bought slots have nowhere to go")
equal("seven daily reward days", #Constants.DAILY_REWARD, 7)
check("daily reward escalates", (function()
	for day = 2, #Constants.DAILY_REWARD do
		if Constants.DAILY_REWARD[day] <= Constants.DAILY_REWARD[day - 1] then
			return false
		end
	end
	return true
end)())
check("four lock levels", #Constants.LOCK == 4)
check("the first lock level is free", Constants.LOCK[1].price == 0)
check("reveal cannot be skipped below the floor",
	Constants.REVEAL_MIN_SKIP_SECONDS < Constants.REVEAL_SECONDS)
check("every rate-limited remote is a real remote name", (function()
	for name in Constants.RATE_LIMITS do
		if type(name) ~= "string" or #name == 0 then
			return false
		end
	end
	return true
end)())

-- ── Ingredients ──────────────────────────────────────────────────────────
group("Ingredients")

equal("16 critters", #Ingredients.Critters, 16)
equal("16 stuff", #Ingredients.Stuff, 16)
equal("256 base combinations", Ingredients.baseCombinationCount(), 256)
equal("key is stuff-first", Ingredients.key("Frog", "Toaster"), "Toaster:Frog")
check("Frog is a critter", Ingredients.isCritter("Frog"))
check("Frog is not stuff", not Ingredients.isStuff("Frog"))
check("Sock is stuff", Ingredients.isStuff("Sock"))
check("unknown names resolve to nil", Ingredients.get("Wombat") == nil)
check("no duplicate ingredient names", (function()
	local seen = {}
	for _, list in { Ingredients.Critters, Ingredients.Stuff } do
		for _, item in list do
			if seen[item.name] then
				return false
			end
			seen[item.name] = true
		end
	end
	return true
end)())
check("luck rises with tier", (function()
	for _, list in { Ingredients.Critters, Ingredients.Stuff } do
		for _, item in list do
			for _, other in list do
				if item.tier < other.tier and item.luck > other.luck then
					return false
				end
			end
		end
	end
	return true
end)())
check("price rises with tier", (function()
	for _, list in { Ingredients.Critters, Ingredients.Stuff } do
		for _, item in list do
			for _, other in list do
				if item.tier < other.tier and item.price >= other.price then
					return false
				end
			end
		end
	end
	return true
end)())
check("every stuff item names a real attachment", (function()
	local valid = { Head = true, Back = true, Hand = true }
	for _, item in Ingredients.Stuff do
		if not item.attach or not valid[item.attach] then
			return false
		end
	end
	return true
end)())
-- The free-roll hole: a 0-priced ingredient must never be sellable.
check("starter ingredients are not purchasable",
	not Ingredients.isPurchasable("Frog") and not Ingredients.isPurchasable("Sock"))
check("no purchasable ingredient is free", (function()
	for _, kind in { "Critter", "Stuff" } do
		for _, item in Ingredients.catalogue(kind) do
			if item.price <= 0 then
				return false
			end
		end
	end
	return true
end)(), "a 0-Goop shop item is an infinite free roll")
check("catalogue is ordered by tier then price", (function()
	for _, kind in { "Critter", "Stuff" } do
		local list = Ingredients.catalogue(kind)
		for index = 2, #list do
			local previous, current = list[index - 1], list[index]
			if current.tier < previous.tier then
				return false
			end
			if current.tier == previous.tier and current.price < previous.price then
				return false
			end
		end
	end
	return true
end)())
check("newest() returns the last row of each table",
	Ingredients.newest("Critter").name == Ingredients.Critters[#Ingredients.Critters].name
		and Ingredients.newest("Stuff").name == Ingredients.Stuff[#Ingredients.Stuff].name)
check("the starter pair exists and is free",
	Ingredients.get(Constants.STARTER.critter) ~= nil
		and Ingredients.get(Constants.STARTER.stuff) ~= nil
		and Ingredients.get(Constants.STARTER.critter).price == 0
		and Ingredients.get(Constants.STARTER.stuff).price == 0)

-- ── Rarity ───────────────────────────────────────────────────────────────
group("Rarity")

equal("Common has no prefix", Rarity.displayName(1, "Frog", "Toaster"), "Toaster Frog")
equal("Uncommon prefixes Shiny", Rarity.displayName(2, "Frog", "Sock"), "Shiny Sock Frog")
equal("Legendary prefixes Golden", Rarity.displayName(5, "Frog", "Toaster"), "Golden Toaster Frog")
equal("tier clamps below range", Rarity.name(0), "Common")
equal("tier clamps above range", Rarity.name(99), "Secret")
equal("NaN clamps to Common", Rarity.name(0 / 0), "Common")
equal("RarestScore matches GDD 8.7", Rarity.score(5), 5 * 1000 + 60)
equal("Secret outscores Mythic", Rarity.score(7) > Rarity.score(6), true)

check("odds sum to 1 at every luck", (function()
	for _, luck in { 0, 1, 3, 6, 12, 17 } do
		local total = 0
		for _, probability in Rarity.odds(luck) do
			total += probability
		end
		if math.abs(total - 1) > 1e-9 then
			return false
		end
	end
	return true
end)())
check("odds never include Secret", #Rarity.odds(0) == Constants.RARITY_ROLLABLE_MAX)
check("luck only ever helps the rare tiers", (function()
	local base, lucky = Rarity.odds(0), Rarity.odds(10)
	for tier = Rarity.RARE, Constants.RARITY_ROLLABLE_MAX do
		if lucky[tier] <= base[tier] then
			return false
		end
	end
	-- and correspondingly hurts the common ones
	for tier = 1, Rarity.UNCOMMON do
		if lucky[tier] >= base[tier] then
			return false
		end
	end
	return true
end)())
near("Mythic is roughly 1 in 400 at luck 0", 1 / Rarity.odds(0)[6], 400, 1)

-- The roll itself: 200k samples against the analytic odds.
do
	local rng = Random.new(20260904)
	local counts = { 0, 0, 0, 0, 0, 0 }
	local samples = 200000
	for _ = 1, samples do
		local tier = Rarity.roll(rng, 0)
		counts[tier] += 1
	end
	local expected = Rarity.odds(0)
	local worst = 0
	for tier = 1, 6 do
		worst = math.max(worst, math.abs(counts[tier] / samples - expected[tier]))
	end
	near("200k rolls match the analytic odds", worst, 0, 0.004)
	check("the roll never produces Secret", counts[Constants.RARITY_SECRET] == nil or counts[7] == nil)
	check("every rollable tier appears", (function()
		for tier = 1, 6 do
			if counts[tier] == 0 then
				return false
			end
		end
		return true
	end)())
end

do
	-- Luck must actually move the distribution, not just the table.
	local rng = Random.new(11)
	local rare0, rare15 = 0, 0
	for _ = 1, 60000 do
		if Rarity.roll(rng, 0) >= Rarity.RARE then
			rare0 += 1
		end
		if Rarity.roll(rng, 15) >= Rarity.RARE then
			rare15 += 1
		end
	end
	check("luck 15 produces meaningfully more Rare+ than luck 0",
		rare15 > rare0 * 1.5, ("%d vs %d"):format(rare15, rare0))
end

-- ── Secrets ──────────────────────────────────────────────────────────────
group("Secrets")

equal("SecretsPublic.COUNT matches the real table", SecretsPublic.COUNT, SecretRecipes.count())
equal("no secret names an unknown ingredient", #SecretRecipes.validate(), 0)
check("Capybara + Crown is King Bara",
	SecretRecipes.match("Capybara", "Crown") ~= nil
		and SecretRecipes.match("Capybara", "Crown").id == "KingBara")
check("the starter pair is a decoy, not a secret",
	SecretRecipes.match(Constants.STARTER.critter, Constants.STARTER.stuff) == nil)
check("an ordinary pair matches nothing", SecretRecipes.match("Frog", "Toaster") == nil)
check("argument order matters and is critter-first",
	SecretRecipes.match("Crown", "Capybara") == nil)
check("byId round-trips every secret", (function()
	for _, secret in SecretRecipes.List do
		if SecretRecipes.byId(secret.id) ~= secret then
			return false
		end
	end
	return true
end)())
check("no two secrets share a pair", (function()
	local seen = {}
	for _, secret in SecretRecipes.List do
		local key = Ingredients.key(secret.critter, secret.stuff)
		if seen[key] then
			return false
		end
		seen[key] = true
	end
	return true
end)())

-- ── Util: profile migration ──────────────────────────────────────────────
-- GDD 11.2: migrations are keyed on version and a field is never deleted, only
-- deprecated. reconcile IS that migration, so it gets the most attention here.
group("Util.reconcile")

do
	local template = {
		version = 1,
		goop = 50,
		nested = { a = 1, b = { c = 2 } },
		list = { 1, 2, 3 },
		flag = false,
	}

	local empty = Util.reconcile({}, template)
	equal("fills a missing scalar", empty.goop, 50)
	equal("fills a nested value", empty.nested.b.c, 2)
	check("fills a list", #empty.list == 3)
	equal("fills a false value", empty.flag, false)

	local existing = { goop = 9999, nested = { a = 7 } }
	local merged = Util.reconcile(existing, template)
	equal("never overwrites an existing scalar", merged.goop, 9999)
	equal("never overwrites an existing nested scalar", merged.nested.a, 7)
	equal("fills a missing sibling inside an existing table", merged.nested.b.c, 2)

	-- The one that matters: a v1 profile gaining a v2 field must keep its data.
	local oldProfile = { version = 1, goop = 1234, mixlings = { { id = "x" } } }
	local newTemplate = { version = 2, goop = 50, mixlings = {}, titles = {}, playSeconds = 0 }
	local migrated = Util.reconcile(oldProfile, newTemplate)
	equal("migration keeps the balance", migrated.goop, 1234)
	equal("migration keeps owned mixlings", #migrated.mixlings, 1)
	equal("migration adds the new field", migrated.playSeconds, 0)
	check("migration adds the new table", type(migrated.titles) == "table")

	-- Deep copies, not shared references: two profiles built from one template
	-- must not alias each other's tables.
	local first = Util.reconcile({}, template)
	local second = Util.reconcile({}, template)
	first.nested.a = 42
	equal("template tables are copied, not shared", second.nested.a, 1)
	equal("the template itself is untouched", template.nested.a, 1)
end

group("Util.deepCopy")
do
	local source = { a = 1, b = { c = { d = 2 } } }
	local copy = Util.deepCopy(source)
	copy.b.c.d = 99
	equal("copies to any depth", source.b.c.d, 2)
	equal("scalars pass through", Util.deepCopy(7), 7)
	equal("strings pass through", Util.deepCopy("x"), "x")
end

-- ── Util: the numbers players read ───────────────────────────────────────
group("Util.abbreviate")
equal("zero", Util.abbreviate(0), "0")
equal("under a thousand is exact", Util.abbreviate(999), "999")
equal("rounds to the nearest whole below 1000", Util.abbreviate(999.4), "999")
equal("thousands", Util.abbreviate(1234), "1.23K")
equal("drops trailing zeroes", Util.abbreviate(1000), "1K")
equal("tens of thousands", Util.abbreviate(12345), "12.3K")
equal("hundreds of thousands", Util.abbreviate(123456), "123K")
equal("millions", Util.abbreviate(1500000), "1.5M")
equal("billions", Util.abbreviate(2500000000), "2.5B")
equal("negatives keep the sign", Util.abbreviate(-1500), "-1.5K")

group("Util.comma")
equal("under a thousand", Util.comma(999), "999")
equal("thousands", Util.comma(1234), "1,234")
equal("millions", Util.comma(1234567), "1,234,567")
equal("exactly a thousand", Util.comma(1000), "1,000")

group("Util.clock")
equal("under a minute", Util.clock(45), "0:45")
equal("a minute", Util.clock(60), "1:00")
equal("lock level 4 duration", Util.clock(Constants.LOCK[4].duration), "2:30")
equal("negative clamps to zero", Util.clock(-5), "0:00")

group("Util.signal")
do
	local signal = Util.signal()
	local seen = {}
	local connection = signal:connect(function(value)
		table.insert(seen, value)
	end)
	signal:fire("a")
	signal:fire("b")
	connection.disconnect(connection)
	signal:fire("c")
	equal("delivers while connected", #seen, 2)
	equal("delivers in order", seen[1] .. seen[2], "ab")

	local onceCount = 0
	signal:once(function()
		onceCount += 1
	end)
	signal:fire()
	signal:fire()
	equal("once fires exactly once", onceCount, 1)
end

group("Util.retry")
do
	local attempts = 0
	local ok, result = Util.retry(3, 0, function()
		attempts += 1
		if attempts < 3 then
			error("transient")
		end
		return "value"
	end)
	check("succeeds after transient failures", ok)
	equal("returns the eventual value", result, "value")
	equal("stops as soon as it succeeds", attempts, 3)

	local tries = 0
	local failedOk = Util.retry(2, 0, function()
		tries += 1
		error("permanent")
	end)
	check("reports permanent failure", not failedOk)
	equal("respects the attempt budget", tries, 2)
end

group("Util.find / shuffle / pick")
do
	local list = { { n = 1 }, { n = 2 }, { n = 3 } }
	local found, index = Util.find(list, function(item)
		return item.n == 2
	end)
	equal("finds the value", found.n, 2)
	equal("returns the index", index, 2)
	check("returns nil when absent", (Util.find(list, function()
		return false
	end)) == nil)

	local rng = Random.new(3)
	local shuffled = Util.shuffle({ 1, 2, 3, 4, 5, 6, 7, 8 }, rng)
	equal("shuffle preserves length", #shuffled, 8)
	check("shuffle preserves membership", (function()
		local total = 0
		for _, value in shuffled do
			total += value
		end
		return total == 36
	end)())
	check("pick returns a member", (function()
		for _ = 1, 50 do
			local value = Util.pick({ "a", "b" }, rng)
			if value ~= "a" and value ~= "b" then
				return false
			end
		end
		return true
	end)())
	check("pick on an empty list is nil", Util.pick({}, rng) == nil)
end

-- ── Report ───────────────────────────────────────────────────────────────
print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	print("")
	for _, failure in failures do
		print("  FAIL: " .. failure)
	end
	error("spec failed", 0)
end
