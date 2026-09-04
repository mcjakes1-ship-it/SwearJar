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
	--[[
		GDD §7.2: "Starter pair is granted once per new profile." Gating on the
		inventory being empty would re-grant to anyone who spent theirs, so the
		grant needs its own ledger. Optional because profiles written before it
		existed will not carry one — Util.reconcile fills it from the template.
	]]
	starterGranted: boolean?,
}

-- ── Wire shapes ──────────────────────────────────────────────────────────

-- What the client is allowed to know about its own profile. This is a strict
-- subset: nothing here reveals a secret recipe (GDD §11.3).
export type ProfileView = {
	goop: number,
	goopPerSec: number,
	totalGoopEarned: number,
	inventory: { [string]: number },
	-- MixlingView, not Mixling: the wire always carries the display name and the
	-- rate alongside the row, so one Mixling reads identically on a reveal card,
	-- a pedestal plaque and this list, and the client never has to derive a name.
	mixlings: { MixlingView },
	placed: { [string]: string },
	denSlots: number, -- what Goop has bought, matching the profile field
	--[[
		What DenService.totalSlots() actually returns: denSlots plus the game
		pass bonus, clamped to DEN_SLOTS_HARD_MAX. It is on the wire because
		otherwise every screen that draws a pedestal grid has to re-implement
		that sum from `passes` and Constants — two of them did, which is two
		places for the rule to drift from the one the server enforces.
	]]
	denSlotsTotal: number,
	lockLevel: number,
	mixdex: { [string]: number },
	secretsFound: { [string]: boolean },
	stats: Stats,
	daily: Daily,
	passes: { [string]: boolean },
	titles: { [string]: boolean },
	settings: Settings,
	codes: { [string]: boolean }, -- lets a Codes screen grey out what is already spent
	mixdexDiscovered: number,
	mixdexTotal: number,
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
	-- "None" mirrors Constants.RARITY[tier].announce so a routing function can
	-- carry the tier's own scope value without translating it first.
	scope: "None" | "Local" | "Server" | "Global",
	kind: "Roll" | "Secret" | "Steal" | "LuckParty" | "Milestone" | "System",
	text: string,
	rarity: number?,
	playerName: string?,
	shake: boolean?,
	fanfare: boolean?,
}

export type TheftAlert = {
	--[[
		"Tracking" is the once-a-second position refresh that keeps the owner's
		compass arrow pointed at a moving thief. It is deliberately a separate
		kind from "Started": a client that treated a repeated "Started" as a new
		event would toast the victim every second of the chase.
	]]
	kind: "Started" | "Tracking" | "Stolen" | "Recovered" | "Dropped" | "Intruder",
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
