# DECISIONS

GDD §0: *"When a design decision is ambiguous, prefer the option that (a) is
simplest to ship, (b) keeps the server authoritative, (c) protects the first 60
seconds of play. Flag the decision in a `DECISIONS.md` log rather than silently
choosing."*

This is that log. Every entry is a place the GDD was silent, self-contradictory,
or specified something that would not survive contact with the platform. Each
records what was chosen, why, and what it would cost to reverse.

---

## D1 — The project lives in `mix-a-monster/`, not at the repo root

**GDD:** §11.1 shows `default.project.json` at the root of the tree.
**Chosen:** the whole Rojo project sits under `mix-a-monster/`.
**Why:** this repository already contains an unrelated shipped artifact
(`swearjar-release/`). Dropping a `src/` and a `default.project.json` at the root
would interleave two projects that have nothing to do with each other. Rojo does
not care where the project file lives — you run it from this directory.
**Reversing:** move the contents up one level and delete this line. Nothing in the
code refers to the directory name.

---

## D2 — Persistence is vendored, not ProfileService/ProfileStore

**GDD:** §11.1 names "ProfileStore/ProfileService session-locked profiles".
**Chosen:** `DataService` implements session locking, autosave, `BindToClose` and
additive migration itself, with no external dependency.
**Why:** those libraries arrive through Wally or a Studio model import. Either makes
the repo un-bootable until a contributor installs a toolchain, and a Rojo tree that
cannot be synced and played is not "simplest to ship". The behaviour that actually
matters is about 250 lines: an envelope of `{ lock = { jobId, at }, data = ... }`
written through `UpdateAsync`, a lock older than `SESSION_LOCK_SECONDS` treated as
dead, and a write that refuses to clobber a lock another server holds.
**Reversing:** swap the body of `DataService`. Every other service talks to it
through `get` / `waitFor` / `push` / `onLoaded` / `onReleasing` and would not
change.
**Watch:** the dead-lock steal window is the risk. Too short and a slow shutdown
loses the last session's writes; too long and a crashed server locks a player out
of their own profile. 60 s is the starting value and it is a **[TUNE]**.

---

## D3 — `profile.placed` is keyed by string, not number

**GDD:** §11.2 declares `placed: { [number]: string }`.
**Chosen:** `{ [string]: string }`, keys are `tostring(pedestalIndex)`.
**Why:** DataStores serialise through JSON. A Lua table with non-contiguous integer
keys — which `placed` always is, because pedestal 3 can be full while 1 and 2 are
empty — round-trips as a *string*-keyed object. Declaring the type as
`{ [number]: string }` means the type checker agrees with the code exactly until
the first save/load cycle, and then silently disagrees forever. Making the on-disk
shape the declared shape removes a class of bug that would only ever appear in
production.
**Reversing:** don't.

---

## D4 — One canonical ingredient-pair key, `"Stuff:Critter"`

**GDD:** §8.1 looks up secrets as `SecretRecipes[critter..":"..stuff]`; §11.2's
Mixdex example key is `"Toaster:Frog"`, which is stuff-first.
**Chosen:** one helper, `Ingredients.key(critter, stuff)`, returning
`"Stuff:Critter"` for both systems.
**Why:** two orders for the same concept is a bug waiting to happen, and the
stuff-first order matches the display name `"{Prefix} {Stuff} {Critter}"`. The
secret table is internal; nothing observable depends on which order it uses.

---

## D5 — Art and world geometry are optional, and the code never waits for them

**GDD:** §0 says assets live in Studio under `ReplicatedStorage/Assets`; §6
describes Blendburg as a built map; §18 flags the 32-model workload as the launch
critical path.
**Chosen:** `MixlingAssembler` generates a deterministic procedural body/prop from
each ingredient's name and colour when the Studio asset is absent, and
`WorldService` builds all of Blendburg from parts at runtime. Studio assets under
`ReplicatedStorage/Assets/{Critters,Stuff,Secrets,Sounds,World}` override both,
by name, with no code change.
**Why:** the GDD itself names the model workload as the thing most likely to slip.
A codebase that cannot be played until 37 models exist cannot be tested, tuned or
demoed, and every day of that is a day the balance numbers stay guesses. The
placeholders vary silhouette by a stable hash of the ingredient name, so sixteen
critters are visually distinct enough to test the loop.
**Cost:** the placeholder look is not shippable. This buys testability, not art.

---

## D6 — All UI is built in code

**GDD:** §11.1 — "UI built in Studio or via code; keep one approach."
**Chosen:** code, through one shared `UiKit`.
**Why:** the GDD asked for a choice; this is the one that makes a design change a
reviewable diff instead of a manual pass over binary files, and the one that lets a
single `UiKit` enforce the 44 px touch minimum (§10) across every screen rather
than trusting eight screens to remember it.

---

## D7 — Services never require each other; they get a registry

**GDD:** silent.
**Chosen:** `Server.server.luau` requires every service, calls `init(registry)` on
all of them, then `start()` on all of them. A service reaches a sibling only
through the registry it captured in `init`.
**Why:** a `require` cycle between two Luau ModuleScripts either deadlocks or hands
back a half-built table, and both failure modes are extremely hard to see in a live
server. This makes the graph acyclic by construction and puts the boot order in one
readable list instead of leaving it as an emergent property of thirty `require`s.

---

## D8 — The remote list differs from GDD §11.3

**GDD:** §11.3 lists `RequestMix`, `RequestPlace`, `RequestPurchase`,
`RequestLock`, `RequestPickup`, `RequestDrop`, `RedeemCode`.
**Chosen:** `RequestPickup` and `RequestDrop` do **not** exist. Stealing a placed
Mixling and picking up a dropped one both happen through server-created
`ProximityPrompt`s, which §11.3 itself specifies two bullets later — a remote
alongside them would be a second, unvalidated path to the same state transition.
Added: `RequestUnplace`, `RequestDropCarried`, `RequestBonk`, `ClaimDaily`,
`SetSetting`, `RequestTeleport`, `TutorialStep`, and one `Query` RemoteFunction for
read-only pulls.
**Why:** each addition is an intent the v1 scope (§13) requires and §11.3 did not
enumerate. Every one is rate-limited and argument-validated in `Net.luau`; the rule
that matters — *a remote that is not in `Net.luau` does not exist* — is intact.

---

## D9 — `RequestTeleport` is refused while carrying a stolen Mixling

**GDD:** silent. §8.4.3 says the thief must *reach* their own Den.
**Chosen:** the server refuses a teleport while `StealService.isCarrying` is true.
**Why:** mobile needs shortcut travel buttons, and "teleport to my Den" while
carrying is an instant bank — it deletes the chase, the bonk, and pillar 2 along
with them. This is exactly why the destination list is server-side.

---

## D10 — Two services the GDD's file list does not name

**GDD:** §11.1 lists eleven services.
**Chosen:** added `WorldService` (builds Blendburg, owns every world coordinate) and
`PlayerService` (spawn placement, the first-60-seconds handshake, daily reward,
settings, the `Query` route).
**Why:** without them, world geometry would be duplicated across `DenService` and
the shops, and session lifecycle would land in whichever service happened to load
first. Both are seams the GDD implies but does not name.
**Also:** badges live in `MonetizationService` rather than a service of their own —
it already owns every other Roblox platform call (passes, products, receipts), and
badge awarding has the same "id is 0 until Studio setup, pcall everything, dedupe in
the profile" shape.

---

## D11 — The client never sees the secret recipes, or their names

**GDD:** §11.3 — "Secret recipes never replicate to the client."
**Chosen:** `ServerStorage/SecretRecipes.luau` is the only copy.
`ReplicatedStorage/Config/SecretsPublic.luau` contains `COUNT` and nothing else —
no names, no ingredients, no hints. A client that dumps `ReplicatedStorage` learns
only how many secrets are left to find. The server sends a secret's display data to
one player at the moment they produce it.
**Why:** §11.1 lists `Config/SecretRecipes.luau` in ReplicatedStorage and then says
it "must NOT exist client-side". The file is simply not created; a boot check warns
if `COUNT` and the real table disagree, so the Mixdex denominator cannot drift.

---

## D12 — The Bonk target is chosen by the server

**GDD:** §11.3 — "the client only reports 'I swung'."
**Chosen:** `RequestBonk` takes no arguments. The server picks the nearest valid
target within `BONK_RANGE` itself.
**Why:** taking a target from the client, even validated by distance, still lets an
exploiter pick *which* of several in-range players gets hit and when. Taking no
argument removes the choice entirely.

---

## D13 — `DEN_SLOTS_HARD_MAX` added to Constants

**GDD:** §17 gives `DEN_SLOTS_MAX = 10` and `DEN_SLOTS_PASS_BONUS = 5`; §8.3 says
the pass "raises cap to 15".
**Chosen:** added an explicit `DEN_SLOTS_HARD_MAX = 15`.
**Why:** `MAX` meaning "the Goop-purchasable ceiling" while the real ceiling is
`MAX + PASS_BONUS` is the kind of implicit arithmetic that gets a clamp wrong once
and hands out a 16th pedestal. Both numbers are now named.

---

## D14 — Type checking is a gate, and the toolchain is vendored

**GDD:** §11.5 describes the Studio test protocol.
**Chosen:** added `tools/check.sh`, which runs `luau-compile` for syntax and
`luau-lsp analyze` against the real Roblox API definitions, using a sourcemap
generated from `src/` by `tools/sourcemap.py`. The binaries live in a gitignored
`.tools/`; `README.md` has the one-line fetch.
**Why:** the GDD's test protocol catches behaviour, not API misuse, and it needs
Studio. Checking every file against the actual Roblox API catches wrong property
names, wrong `Enum` members and bad method signatures before a place is ever
opened. This is the cheapest quality gate available in a repo with no runtime.
**Standing rule:** `tools/check.sh` must be clean before a commit.

---

*Append to this file on every material decision. Update the GDD's version header
when a decision changes design intent rather than implementation.*

---

## D15 — Starter ingredients are a grant, never shop stock

**GDD:** §7.2 prices Frog and Sock at 0 and calls them "(starter, free)", and in
the same section says "Starter pair is granted once per new profile".
**Chosen:** `Ingredients.isPurchasable` returns false for anything flagged
`starter`. `ShopService` refuses to sell them and the shop UI never lists them.
**Why:** a shop that stocks a 0-Goop ingredient is an infinite free roll. A player
would never need to earn anything: buy Frog, buy Sock, mix, repeat, forever, at
luck 0. The Goop economy — the primary sink, the reason to place Mixlings, the
reason to defend a Den — would simply stop existing. `tools/balance.py` prints
the list of 0-priced ingredients and says this out loud, so a future Weekly Drop
cannot reintroduce the hole by accident.

---

## D16 — A balance model, checked in and run against the real constants

**GDD:** §18 — "Balance: Goop curve is a guess. Instrument first, tune weekly."
**Chosen:** `tools/balance.py` reads `Constants.luau` and `Ingredients.luau`
directly (never a copy) and reports the odds table, the Epic+ cadence, a Monte
Carlo of the Goop curve against §8.2's targets, sinks versus faucets, and the
progression ceiling.
**Why:** every one of those is a number the GDD states as a target and does not
check. Running it on the launch constants found four things worth a decision
before a playtest, listed below. The tool is the deliverable; the numbers move.

### What it currently says about the launch constants

These are findings, not changes — every one is a **[TUNE]** value and the call
belongs to the owner. Nothing below has been altered in `Constants.luau`.

1. **The Goop curve runs hot.** §8.2 targets ~10/sec at 15 min and ~100/sec by
   day 3. The model reaches ~38/sec and ~1,580/sec — about 4x and 16x. The
   day-3 player is already past the *week-2* target. Lower ingredient prices are
   not the cause; the cause is that a placed Mixling pays forever and rolls are
   cheap relative to income.
2. **Epic+ fires more often than intended.** §15 wants one every ~4 min per
   server. At the GDD's own stated cadence (a mix every 45–90 s, §4) the model
   gives one every 1.3–2.9 min. Epic is 3.5% at luck 0; halving its weight would
   land it on target. Worth deciding whether "more often than planned" is
   actually bad — the announcement *is* the hype machine.
3. **The progression ceiling is ~600x and is reached in days.** Floor is 5 slots
   × 1 Goop/sec; the realistic ceiling is 15 slots × 200. The day-3 simulation
   is already at 53% of it. Once every pedestal holds a top-tier Mixling there is
   nothing left to increase, and neither the Mixdex nor the leaderboards pay out.
   This is the structural retention question, and it is bigger than any single
   constant: v1.5's pity timer and v2's trading do not widen this span.
4. **The daily reward stops mattering on day 3.** The full 7-day track is 5,600
   Goop — 93 minutes of income at 10/sec, but 56 seconds at 100/sec. A daily
   reward worth under a minute of play is not a reason to open the app. Paying
   the daily in *ingredients* rather than Goop would keep its value indexed to
   progression instead of decaying against it.

Re-run `python3 tools/balance.py` after any change to `Constants.luau`.
