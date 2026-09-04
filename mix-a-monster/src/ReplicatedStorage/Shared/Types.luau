--!strict
--[[
	Types.luau — the profile schema (GDD §11.2) and the wire shapes shared
	between server and client.

	Rule from the GDD: migrations are keyed on `version`; never delete a
	field, deprecate it.
]]

export type Mixling = {
	id: string, -- HttpService:GenerateGUID(false)
	critter: string,
	stuff: string,
	rarity: number, -- 1..7
	secretId: string?,
	bound: boolean?, -- starter Mixling; can never be stolen (GDD §5, §8.3)
	createdAt: number, -- os.time()
}

export type Stats = {
	stealsBanked: number,
	stealsFoiled: number,
	goopStolen: number,
	rolls: number,
	byRarity: { number }, -- index 1..7
}

export type Daily = {
	streak: number,
	lastClaim: number,
}

export type Settings = {
	friendlyFire: boolean, -- may friends steal from me (GDD §18 open question)
	music: boolean,
	sfx: boolean,
	lowFx: boolean,
}

export type Profile = {
	version: number,
	goop: number,
	totalGoopEarned: number,
	inventory: { [string]: number }, -- ingredientName -> count
	mixlings: { Mixling }, -- everything owned, placed or not
	placed: { [string]: string }, -- tostring(pedestalIndex) -> mixling.id
	denSlots: number, -- 5..15
	lockLevel: number, -- 1..4
	mixdex: { [string]: number }, -- "Toaster:Frog" -> best rarity seen
	secretsFound: { [string]: boolean },
	stats: Stats,
	daily: Daily,
	codes: { [string]: boolean },
	passes: { [string]: boolean },
	badges: { [string]: boolean },
	receipts: { [string]: boolean }, -- ProcessReceipt idempotency (GDD §11.3)
	titles: { [string]: boolean },
	settings: Settings,
	funnel: { [string]: number }, -- funnel step -> os.time() first reached
	firstJoin: number,
	tutorialDone: boolean,
	playSeconds: number,
}

-- ── Wire shapes ──────────────────────────────────────────────────────────

-- What the client is allowed to know about its own profile. This is a strict
-- subset: nothing here reveals a secret recipe (GDD §11.3).
export type ProfileView = {
	goop: number,
	goopPerSec: number,
	totalGoopEarned: number,
	inventory: { [string]: number },
	mixlings: { Mixling },
	placed: { [string]: string },
	denSlots: number,
	lockLevel: number,
	mixdex: { [string]: number },
	secretsFound: { [string]: boolean },
	stats: Stats,
	daily: Daily,
	passes: { [string]: boolean },
	titles: { [string]: boolean },
	settings: Settings,
	tutorialDone: boolean,
	shielded: boolean,
	shieldEndsAt: number,
	luck: number,
}

-- Enough for the client to name and draw a Mixling it has never seen.
export type MixlingView = {
	id: string,
	critter: string,
	stuff: string,
	rarity: number,
	secretId: string?,
	secretName: string?,
	bound: boolean?,
	displayName: string,
	goopPerSec: number,
}

export type MixResult = {
	mixling: MixlingView,
	revealSeconds: number,
	suspense: boolean,
	luck: number,
	newMixdexEntry: boolean,
	firstDiscovery: boolean,
}

export type Announcement = {
	scope: "Local" | "Server" | "Global",
	kind: "Roll" | "Secret" | "Steal" | "LuckParty" | "Milestone" | "System",
	text: string,
	rarity: number?,
	playerName: string?,
	shake: boolean?,
	fanfare: boolean?,
}

export type TheftAlert = {
	kind: "Started" | "Stolen" | "Recovered" | "Dropped" | "Intruder",
	mixlingName: string,
	rarity: number,
	thiefName: string?,
	thiefUserId: number?,
}

export type DenPublic = {
	userId: number,
	displayName: string,
	goopPerSec: number,
	locked: boolean,
	lockEndsAt: number,
	slotIndex: number, -- which den in the ring
}

export type LeaderboardEntry = {
	userId: number,
	name: string,
	value: number,
}

return {}
