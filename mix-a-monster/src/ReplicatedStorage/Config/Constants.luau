--!strict
--[[
	Constants.luau — the single source of truth for every tunable number.

	GDD §17. Nothing in this game may hard-code a balance number; if a system
	needs a value, it belongs here. Values marked TUNE are starting guesses
	expected to move after playtests (GDD §0).

	This module is frozen at require time. Mutating it at runtime is a bug.
]]

local Constants = {}

-- ─────────────────────────────────────────────────────────────────────────
-- Server / session
-- ─────────────────────────────────────────────────────────────────────────
Constants.SERVER_SIZE = 10 -- TUNE. Must equal the Den ring size (§6).
Constants.START_GOOP = 50
Constants.GOOP_TICK_SECONDS = 1

-- ─────────────────────────────────────────────────────────────────────────
-- Den
-- ─────────────────────────────────────────────────────────────────────────
Constants.DEN_SLOTS_START = 5
Constants.DEN_SLOTS_MAX = 10 -- purchasable ceiling before the game pass
Constants.DEN_SLOTS_PASS_BONUS = 5 -- +5 via pass → hard ceiling of 15
Constants.DEN_SLOTS_HARD_MAX = 15
Constants.DEN_SLOT_PRICES = { 500, 1500, 4000, 10000, 25000 } -- TUNE. index n = price of slot (DEN_SLOTS_START + n)

Constants.LOCK = {
	{ duration = 60, cooldown = 90, price = 0 },
	{ duration = 90, cooldown = 90, price = 2000 },
	{ duration = 120, cooldown = 90, price = 6000 },
	{ duration = 150, cooldown = 90, price = 15000 },
}

-- ─────────────────────────────────────────────────────────────────────────
-- Theft (GDD §8.4)
-- ─────────────────────────────────────────────────────────────────────────
Constants.NEW_PLAYER_SHIELD_SECONDS = 300
Constants.STEAL_REPEAT_VICTIM_COOLDOWN = 45 -- TUNE
Constants.CARRY_WALKSPEED_MULT = 0.85
Constants.CARRY_MAX_JUMP_POWER = 50 -- default humanoid jump power; carriers may not exceed it
Constants.DROP_RETURN_SECONDS = 8
Constants.DROP_PICKUP_HOLD = 2
Constants.STEAL_INTERRUPT_DISTANCE = 3 -- studs of thief movement that cancels a pickup
Constants.BONK_RANGE = 8
Constants.BONK_COOLDOWN = 0.8
Constants.BONK_RAGDOLL_SECONDS = 2
Constants.BONK_KNOCKBACK_LIFT = 0.45 -- vertical share of the bonk impulse; shapes the arc
--[[
	Network slack on the server's own hold-elapsed check. The ProximityPrompt's
	HoldDuration runs on the thief's client, so the server times the hold itself
	and refuses a trigger that arrives early. This is the allowance for one round
	trip: smaller refuses legitimate steals on a bad connection, larger buys an
	exploiter real time. It is a security threshold, not a feel value.
]]
Constants.STEAL_HOLD_GRACE = 0.35
Constants.BONK_KNOCKBACK = 40 -- applied to non-carriers

-- ─────────────────────────────────────────────────────────────────────────
-- Rarity (GDD §7.3)
-- ─────────────────────────────────────────────────────────────────────────
export type RarityDef = {
	name: string,
	prefix: string,
	weight: number,
	goopPerSec: number,
	holdTime: number,
	luckMult: number,
	color: Color3,
	announce: "None" | "Local" | "Server" | "Global",
}

Constants.RARITY = {
	{ name = "Common", prefix = "", weight = 600, goopPerSec = 1, holdTime = 2.0, luckMult = 0, color = Color3.fromRGB(170, 174, 180), announce = "None" },
	{ name = "Uncommon", prefix = "Shiny", weight = 250, goopPerSec = 3, holdTime = 2.5, luckMult = 0, color = Color3.fromRGB(86, 204, 108), announce = "None" },
	{ name = "Rare", prefix = "Neon", weight = 100, goopPerSec = 8, holdTime = 3.0, luckMult = 0.10, color = Color3.fromRGB(64, 150, 255), announce = "Local" },
	{ name = "Epic", prefix = "Glitched", weight = 35, goopPerSec = 20, holdTime = 3.5, luckMult = 0.15, color = Color3.fromRGB(168, 88, 255), announce = "Server" },
	{ name = "Legendary", prefix = "Golden", weight = 12, goopPerSec = 60, holdTime = 4.0, luckMult = 0.20, color = Color3.fromRGB(255, 196, 42), announce = "Server" },
	{ name = "Mythic", prefix = "Cosmic", weight = 2.5, goopPerSec = 200, holdTime = 5.0, luckMult = 0.25, color = Color3.fromRGB(255, 72, 220), announce = "Server" },
	{ name = "Secret", prefix = "", weight = 0, goopPerSec = 750, holdTime = 6.0, luckMult = 0, color = Color3.fromRGB(226, 42, 60), announce = "Global" },
}

Constants.RARITY_COMMON = 1
Constants.RARITY_UNCOMMON = 2
Constants.RARITY_RARE = 3
Constants.RARITY_EPIC = 4
Constants.RARITY_LEGENDARY = 5
Constants.RARITY_MYTHIC = 6
Constants.RARITY_SECRET = 7
Constants.RARITY_ROLLABLE_MAX = 6 -- Secret is recipe-only; never in the weighted pool

-- Visual overlay per tier, consumed by MixlingAssembler (GDD §7.3).
Constants.RARITY_FX = {
	[1] = { material = Enum.Material.SmoothPlastic, scale = 1.00, glow = 0, particles = "None", pitch = 1.00 },
	[2] = { material = Enum.Material.Metal, scale = 1.00, glow = 0, particles = "None", pitch = 1.02 },
	[3] = { material = Enum.Material.Neon, scale = 1.00, glow = 0.35, particles = "None", pitch = 1.05 },
	[4] = { material = Enum.Material.Neon, scale = 1.10, glow = 0.5, particles = "Glitch", pitch = 1.10 },
	[5] = { material = Enum.Material.Foil, scale = 1.25, glow = 0.6, particles = "Sparkle", pitch = 0.95 },
	[6] = { material = Enum.Material.Neon, scale = 1.50, glow = 0.85, particles = "Cosmic", pitch = 0.90 },
	[7] = { material = Enum.Material.Neon, scale = 1.60, glow = 1.0, particles = "Cosmic", pitch = 0.85 },
}

-- ─────────────────────────────────────────────────────────────────────────
-- The Mixer (GDD §8.1)
-- ─────────────────────────────────────────────────────────────────────────
Constants.REVEAL_SECONDS = 3.0
Constants.REVEAL_MIN_SKIP_SECONDS = 1.5
Constants.REVEAL_SUSPENSE_SECONDS = 1.0 -- extra beat for Epic+
Constants.REVEAL_SUSPENSE_MIN_RARITY = 4
Constants.MIX_COOLDOWN_SECONDS = 0.75 -- server-side floor between rolls from one player
Constants.MIXER_PADS = 10 -- interaction pads so a full server can mix at once (§6)

-- ─────────────────────────────────────────────────────────────────────────
-- Sound (GDD §7.5)
-- ─────────────────────────────────────────────────────────────────────────
Constants.IDLE_SOUND_INTERVAL = { 20, 40 }
Constants.IDLE_SOUND_MIN_GAP_PER_DEN = 5

-- ─────────────────────────────────────────────────────────────────────────
-- Tutorial / first 60 seconds (GDD §5)
-- ─────────────────────────────────────────────────────────────────────────
Constants.STARTER = { critter = "Frog", stuff = "Sock", riggedRarity = 2 }
Constants.TUTORIAL_SHOWCASE_WINDOW = { 30, 60 } -- seconds after first join; fire a ceiling-showing announcement
Constants.TUTORIAL_SHOWCASE_MIN_RARITY = 4
Constants.TUTORIAL_GOAL_GOOP = 50 -- "Earn 50 Goop → buy an ingredient"

-- ─────────────────────────────────────────────────────────────────────────
-- Economy (GDD §8.2)
-- ─────────────────────────────────────────────────────────────────────────
Constants.SHOP_CONFIRM_THRESHOLD = 1000 -- purchases at/above this ask for confirmation (§8.6)
Constants.DAILY_REWARD = { 100, 200, 300, 500, 800, 1200, 2500 }
Constants.DAILY_RESET_SECONDS = 24 * 60 * 60
Constants.DAILY_MISS_SECONDS = 48 * 60 * 60 -- gap beyond this resets the streak

-- ─────────────────────────────────────────────────────────────────────────
-- Leaderboards (GDD §8.7)
-- ─────────────────────────────────────────────────────────────────────────
Constants.LEADERBOARD_REFRESH = 60
Constants.LEADERBOARD_SIZE = 25
Constants.LEADERBOARDS = {
	{ key = "TotalGoopEarned", title = "RICHEST", suffix = " Goop" },
	{ key = "StealsBanked", title = "BEST THIEF", suffix = " steals" },
	{ key = "RarestScore", title = "RAREST OWNED", suffix = "" },
}

-- ─────────────────────────────────────────────────────────────────────────
-- Persistence
-- ─────────────────────────────────────────────────────────────────────────
Constants.PROFILE_VERSION = 1
Constants.PROFILE_STORE_NAME = "MixAMonster_Profiles_v1"
Constants.AUTOSAVE_SECONDS = 120
Constants.SESSION_LOCK_SECONDS = 60 -- a lock older than this is considered dead
Constants.MIXLING_SOFT_CAP = 400 -- profile-size guard; oldest Commons are auto-scrapped above this

-- ─────────────────────────────────────────────────────────────────────────
-- Monetization (GDD §9). IDs are filled in at Studio setup; 0 == not wired.
-- ─────────────────────────────────────────────────────────────────────────
Constants.PASSES = {
	DoubleGoop = { id = 0, name = "2x Goop", price = 399, goopMultiplier = 2 },
	DenSlots = { id = 0, name = "+5 Den Slots", price = 299, slotBonus = 5 },
	LuckyMixer = { id = 0, name = "Lucky Mixer", price = 499, luck = 3 },
	VIP = { id = 0, name = "VIP", price = 699, dailyMultiplier = 1.5 },
}

Constants.PRODUCTS = {
	GoopSmall = { id = 0, name = "5,000 Goop", price = 99, goop = 5000 },
	GoopMedium = { id = 0, name = "20,000 Goop", price = 299, goop = 20000 },
	GoopLarge = { id = 0, name = "60,000 Goop", price = 699, goop = 60000 },
	LockRefresh = { id = 0, name = "Lock Refresh", price = 49, kind = "LockRefresh" },
	LuckParty = { id = 0, name = "Server Luck Party", price = 149, kind = "LuckParty", luck = 2, seconds = 600 },
}

-- ─────────────────────────────────────────────────────────────────────────
-- Codes (GDD §8.8). Server-only redemption; listed here for one-file editing.
-- ─────────────────────────────────────────────────────────────────────────
Constants.CODES = {
	MIXER = { goop = 500 },
	BLENDBURG = { goop = 250 },
}

-- ─────────────────────────────────────────────────────────────────────────
-- Mixdex milestones (GDD §8.5)
-- ─────────────────────────────────────────────────────────────────────────
Constants.MIXDEX_MILESTONES = {
	{ entries = 10, goop = 250, title = "Dabbler" },
	{ entries = 25, goop = 1000, title = "Tinkerer" },
	{ entries = 50, goop = 3000, title = "Blender" },
	{ entries = 100, goop = 10000, title = "Mad Mixer" },
	{ entries = 200, goop = 40000, title = "Blendburg Legend" },
}

-- ─────────────────────────────────────────────────────────────────────────
-- Badges (GDD §8.7). IDs filled in at Studio setup; 0 == not wired.
-- ─────────────────────────────────────────────────────────────────────────
Constants.BADGES = {
	FirstMix = 0,
	FirstPlacement = 0,
	FirstSteal = 0,
	FirstBonk = 0,
	RollRare = 0,
	RollEpic = 0,
	RollLegendary = 0,
	RollMythic = 0,
	SecretDiscoverer = 0,
	Mixdex50 = 0,
	Mixdex100 = 0,
	Mixdex200 = 0,
	Streak7 = 0,
	LuckPartyHost = 0, -- GDD §9: the Server Luck Party buyer gets a banner AND a badge
}

-- ─────────────────────────────────────────────────────────────────────────
-- World layout (GDD §6). Blendburg is built procedurally by WorldService so
-- the repo is playable with zero Studio work; Studio-authored models under
-- ReplicatedStorage/Assets override these when present.
-- ─────────────────────────────────────────────────────────────────────────
Constants.WORLD = {
	PLAZA_RADIUS = 60,
	DEN_RING_RADIUS = 150,
	DEN_SIZE = Vector3.new(48, 24, 48),
	PEDESTAL_RING_RADIUS = 13,
	PEDESTAL_COUNT = 15, -- hard max; slots beyond denSlots are shown locked
	BASE_HEIGHT = 0,
	SHOP_OFFSET = 92,
	SKY_COLOR = Color3.fromRGB(126, 200, 255),
	GROUND_COLOR = Color3.fromRGB(120, 190, 130),
}

-- ─────────────────────────────────────────────────────────────────────────
-- Networking guard rails (GDD §11.3). Requests per player per remote,
-- measured over a 10-second sliding window.
-- ─────────────────────────────────────────────────────────────────────────
Constants.RATE_WINDOW = 10
Constants.RATE_LIMITS = {
	RequestMix = 20,
	RequestPlace = 40,
	RequestUnplace = 40,
	RequestPurchase = 40,
	RequestLock = 10,
	RequestDropCarried = 10,
	RequestBonk = 30,
	RedeemCode = 6,
	ClaimDaily = 4,
	SetSetting = 10,
	RequestTeleport = 8,
	TutorialStep = 30,
	Query = 30,
}

-- ─────────────────────────────────────────────────────────────────────────
-- Analytics funnel (GDD §15)
-- ─────────────────────────────────────────────────────────────────────────
Constants.FUNNEL_STEPS = { "Joined", "FirstMix", "FirstPlace", "FirstShopBuy", "FirstSteal", "FirstPurchase" }

table.freeze(Constants)
return Constants
