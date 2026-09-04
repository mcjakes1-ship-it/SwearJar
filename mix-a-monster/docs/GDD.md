# MIX A MONSTER — Game Design Document (v1.0)

**Platform:** Roblox (Luau, Rojo project) · **Owner:** MC Jakes · **Status:** Pre-production · **Target:** Live and earning ≥ $1 within 30 days

---

## 0. How to use this document (read this first, Claude Code)

- This is the source of truth for design intent. All tunable numbers live in **§17 Constants** and must be implemented as a single `Config` module, never hard-coded in systems.
- Build in the order given in **§14 Milestones**. Do not start v1.5/v2 features until v1 is shippable.
- When a design decision is ambiguous, prefer the option that (a) is simplest to ship, (b) keeps the server authoritative, (c) protects the first 60 seconds of play. Flag the decision in a `DECISIONS.md` log rather than silently choosing.
- Anything marked **[TUNE]** is a starting value expected to change after playtests.
- Assets (meshes, sounds, textures) are NOT in the Rojo tree. They live in Studio under `ReplicatedStorage/Assets`. Code references them by name via `Config`.

---

## 1. Pitch

**One line:** Drop two ingredients into the Mixer, get a random mashup creature, defend it in your Den, steal better ones from everyone else.

**Elevator version:** Mix a Monster is a collect-and-steal game set in Blendburg, a floating scrapyard town built around one giant machine. Players are Mixers. They combine a Critter (frog, cat, shark…) with a Stuff item (toaster, sneaker, disco ball…) to create a Mixling — a mashup creature with a rarity tier, a signature sound, and a Goop-per-second income. Mixlings sit on pedestals in your Den generating Goop. Other players can walk in and steal them. You can steal theirs. Rare recipes are secret and discovered by the community.

**Why now:** The current top of Roblox (Sept 2026) is built on: random rolls with rarity, theft of other players' stuff, income that ticks up while you play, titles that describe the loop, and a constant cadence of new content. "Steal a ___" as a title is saturated; "Mix a ___" is an ownable verb with the same DNA plus a combinatorial content engine.

---

## 2. Design pillars

1. **The roll is the show.** Every mix is a 3-second reveal with escalating drama by rarity. Nothing else in the game may interrupt it.
2. **Your stuff can be taken.** Theft is real, visible, and reversible by skill. It creates stories, revenge, and reasons to come back.
3. **Legible in one screenshot.** A new player understands the game from the icon, the title, and the first 15 seconds.
4. **Content is combinatorial.** One new ingredient = dozens of new Mixlings. Weekly drops must cost hours, not weeks.
5. **Sound is identity.** Every Mixling has an original audio hook. Sounds are the viral vector for Shorts/TikTok.

---

## 3. Audience and player fantasy

- **Core:** Roblox players 9–14, mobile-first (touch controls are mandatory, all prompts must work with ProximityPrompt + on-screen buttons).
- **Fantasy:** Mad-scientist-meets-kid-with-a-blender. "I made a thing, it's rare, it's mine, get away from it."
- **Session shape:** 8–20 minute sessions. Log in → check Den → mix a few → raid → defend → log off with a bigger Goop/sec number than you started with.
- **Emotional beats to hit every session:** anticipation (roll), pride (placement + public Goop/sec), tension (someone's in my Den), triumph (banked a steal), envy (server-wide Legendary announcement).

---

## 4. Core loop

```
      ┌────────────────────────────────────────────────┐
      │                                                │
      ▼                                                │
  BUY INGREDIENTS ──► MIX (roll) ──► PLACE IN DEN ──► EARN GOOP/sec
      ▲                                    │              │
      │                                    ▼              │
      │                              DEFEND (lock/bonk)   │
      │                                    │              │
      │                                    ▼              │
      └────────────── BANK A STEAL ◄── RAID OTHERS ◄──────┘
```

**Loop timings [TUNE]:** first mix ≤ 30 s from spawn; a mix every 45–90 s early game; a raid attempt every 3–5 min; a Den lock cycle every ~2.5 min.

---

## 5. First 60 seconds (scripted, non-negotiable)

| Time | What happens | System |
|---|---|---|
| 0 s | Spawn inside your own Den. Camera pans once from your empty pedestals to the Mixer in the plaza. | Spawn + cinematic |
| 3 s | Bubble prompt: "Take these to the Mixer!" Starter ingredients (Frog + Sock) already in inventory. Glowing path on the floor to the Mixer. | Tutorial beam |
| 10 s | Player reaches Mixer. UI opens with both slots pre-filled. One button: **MIX**. | Mixer UI |
| 13 s | Roll animation. Starter roll is rigged: guaranteed Uncommon ("Shiny Sock Frog"). Sound plays. | Rigged first roll |
| 18 s | Bubble: "Put it on a pedestal in your Den." Glowing path back. | Tutorial beam |
| 25 s | Placement. Goop/sec counter appears over head and in HUD, ticking. Confetti. | Den + HUD |
| 30 s | Bubble: "Earn 50 Goop → buy a new ingredient at the shelves." Path to Critter Pen. | Shop |
| 30–60 s | Within this window, the server triggers a **nearby scripted event**: another player's roll (or a bot-roll announcement if server is quiet) hits Rare+ and the announcement banner fires. Purpose: show the ceiling. | Announcement system |
| ~60 s | Player buys first ingredient pair, mixes for real. Tutorial ends. Starter Mixling is **Bound** (padlock icon; cannot be stolen). | Bound flag |

**Rule:** the tutorial never blocks movement. Every prompt is skippable by walking away.

---

## 6. World: Blendburg

A floating island of stacked scrap, painted in saturated toy colors (no grunge). Bright sky, drifting junk-clouds. Low-poly, high-saturation, readable at mobile draw distance.

| Zone | Purpose | Notes |
|---|---|---|
| **The Mixer (Plaza center)** | The gacha machine. Giant blender/cauldron hybrid with a viewing window; roll happens inside it, visible to everyone nearby. | Multiple interaction pads so 10 players can mix at once. Roll VFX scales with rarity. |
| **Den Ring** | 10 Dens in a ring around the plaza, one per player slot. | Each Den: door (lockable), 10 pedestal positions (5 unlocked at start), a small Goop vault prop. Owner name + Goop/sec on a sign above the door. |
| **Critter Pen** | Shop for Critter ingredients. | Physical shelves with pickup prompts + a UI list. Ingredient models idle-animate on the shelf. |
| **Stuff Shack** | Shop for Stuff ingredients. | Same pattern. |
| **Mixdex Kiosk** | Collection log terminal. | Also accessible from HUD. |
| **Leaderboard Wall** | Three boards: Richest, Best Thief, Rarest Owned. | OrderedDataStore, refresh every 60 s. |
| **Junk Cliffs (Fringe)** | Wild Mixling spawns. **[v1.5]** | Walled off with "COMING SOON" scaffolding in v1. |
| **Spawn / Sky** | Players spawn in their own Den, not a lobby. | No lobby. Ever. |

**Server size:** 10 players **[TUNE]**. Dens are per-server-session: your Den exists only while you're in the server; your Mixlings persist in your profile.

---

## 7. Characters: Mixlings

### 7.1 Assembly engine (this is what makes weekly content cheap)

A Mixling is never a hand-made model. It's assembled at runtime:

```
Mixling = CritterBody(critter) + StuffProp(stuff) attached to named Attachment
        + RarityFX(rarity) + Sound(critter.voice, stuff.layer, rarity.pitch)
```

- **CritterBody:** one rigged low-poly body per Critter, with attachments named `Head`, `Back`, `Hand` and an idle animation. ~16 at launch.
- **StuffProp:** one prop mesh per Stuff item with metadata: which attachment it prefers (`Head` for Crown, `Back` for Rocket, `Hand` for Boombox) and a scale hint. ~16 at launch.
- **RarityFX:** material/particle/scale overlay per tier (see 7.3).
- **Naming:** `"{RarityPrefix} {Stuff} {Critter}"` → "Golden Toaster Frog". Secrets override with a unique name.

Content math: 16 × 16 = 256 Mixlings at launch from 32 assets. Adding one Stuff item adds 16 new Mixlings.

### 7.2 Launch ingredients

**Critters (shelf tier · Goop price · luck):**

| Tier | Critters | Price | Luck |
|---|---|---|---|
| T1 | Frog (starter, free), Chicken, Snail, Worm | 0 / 25 / 40 / 40 | 0 |
| T2 | Cat, Goat, Pigeon, Raccoon | 120 / 150 / 150 / 200 | 1 |
| T3 | Shark, Penguin, Sloth, Bat | 600 / 650 / 700 / 800 | 2 |
| T4 | Octopus, Llama, Axolotl | 2,500 / 2,800 / 3,200 | 4 |
| T5 | Capybara | 12,000 | 6 |

**Stuff:**

| Tier | Stuff | Price | Luck |
|---|---|---|---|
| T1 | Sock (starter, free), Traffic Cone, Rubber Duck, Umbrella | 0 / 25 / 40 / 40 | 0 |
| T2 | Toaster, Sneaker, Pizza, Skateboard | 120 / 150 / 150 / 200 | 1 |
| T3 | Cactus, Microwave, Lava Lamp, Fire Hydrant | 600 / 650 / 700 / 800 | 2 |
| T4 | Boombox, Rocket, Disco Ball | 2,500 / 2,800 / 3,200 | 4 |
| T5 | Crown | 12,000 | 6 |

Ingredients are **consumed on mix**. Starter pair is granted once per new profile.

### 7.3 Rarity tiers

| Tier | Name | Prefix | Base weight | Goop/sec | Steal hold time | Visual FX | Announcement |
|---|---|---|---|---|---|---|---|
| 1 | Common | — | 600 | 1 | 2.0 s | none | none |
| 2 | Uncommon | Shiny | 250 | 3 | 2.5 s | reflective material | none |
| 3 | Rare | Neon | 100 | 8 | 3.0 s | Neon material, soft glow | local (nearby) |
| 4 | Epic | Glitched | 35 | 20 | 3.5 s | flicker + scanline particles, 1.1× scale | server banner |
| 5 | Legendary | Golden | 12 | 60 | 4.0 s | gold material + sparkles, 1.25× scale | server banner + screen shake |
| 6 | Mythic | Cosmic | 2.5 | 200 | 5.0 s | galaxy texture + orbiting particles, 1.5× scale | server banner + fanfare + chat message |
| 7 | Secret | (unique) | recipe only | 750 | 6.0 s | unique model + all FX | server + global "DISCOVERED" feed |

All values **[TUNE]**.

### 7.4 Secret recipes

- Fixed Critter + Stuff pairs that **always** produce a unique, hand-modeled Secret Mixling (bypasses the roll).
- Unlisted anywhere in-game. The Mixdex shows "???" silhouettes with the count of undiscovered secrets.
- Launch with 5. Add 1 per weekly drop.
- First discovery per server fires a global feed line ("Jakes discovered KING BARA"). First discovery ever earns a badge.
- Launch set (do not put these anywhere public): Capybara + Crown → **King Bara**; Frog + Sock → nothing (people will try it; that's the point — the starter pair is a decoy); Shark + Rocket → **Sharkpedo**; Cat + Disco Ball → **DJ Whiskerz**; Sloth + Skateboard → **Slothy Tony**; Worm + Boombox → **MC Wormz** (Easter egg for the creator brand).

### 7.5 Sound design (owner produces all audio)

- Each Critter has a 1–2 s **voice** (original, human-performed/produced, not TTS clones).
- Each Stuff item has a **layer** (toaster ding, boombox 1-bar beat, disco stab).
- Mixling sound = voice + layer, mixed at runtime by playing both `Sound` objects; rarity applies `PlaybackSpeed` and a reverb/`EqualizerSoundEffect` preset.
- Plays on: roll reveal, placement, steal pickup, and idle on pedestal every 20–40 s (throttled per Den to avoid cacophony; max 1 idle sound per 5 s per Den).
- Every sound must be a **standalone meme candidate**: short, quotable, loopable.

---

## 8. Systems

### 8.1 The Mixer (gacha)

**Input:** two ingredients from inventory (one Critter, one Stuff).
**Luck:** `L = ingredientA.luck + ingredientB.luck + passLuck + activeBoostLuck`.
**Roll:**

```
if SecretRecipes[critter..":"..stuff] then return Secret
for tier t in 1..6:
    eff[t] = baseWeight[t] * (1 + L * luckMult[t])
    -- luckMult = {0, 0, 0.10, 0.15, 0.20, 0.25}   [TUNE]
tier = weightedRandom(eff)
```

- Roll is **server-side only**, using `Random.new()` seeded per server. Client receives the result and plays the reveal.
- Reveal: 3.0 s spin → slam → reveal. Client may not skip below 1.5 s. Rarity ≥ Epic adds a 1 s "…something's different" pre-reveal beat.
- Result goes to inventory; a "Place in Den" button appears immediately.
- **Pity [v1.5]:** guarantee a Rare+ within 15 rolls. Do not ship pity in v1; measure first.

### 8.2 Goop economy

- Goop/sec = sum of placed Mixlings' rates × multipliers (2x pass, events).
- Server accrues Goop every 1 s per player; client interpolates the HUD number for smoothness.
- Starting balance: 50. Max balance: none.
- **Sinks:** ingredients (primary), Den slots, lock upgrades, cosmetic Den skins [v1.5].
- **Faucets:** placed Mixlings, daily reward, codes, dev product purchases.
- **Target curve [TUNE]:** a first-session player should reach ~10 Goop/sec in 15 min; a day-3 player ~100 Goop/sec; a week-2 grinder ~1,000 Goop/sec.

### 8.3 The Den

- 10 pedestals; 5 active at start. Unlock more with Goop: 500 / 1,500 / 4,000 / 10,000 / 25,000 **[TUNE]**. +5 via game pass (raises cap to 15, pedestals 11–15 spawn on purchase).
- **Door lock:** a button inside the Den. Locks the door for `lockDuration`, then `lockCooldown` before reuse. L1: 60 s / 90 s. Upgrades: L2 90 s (2,000), L3 120 s (6,000), L4 150 s (15,000) **[TUNE]**. Locked door is an obvious forcefield with a countdown visible from outside.
- Owner may **not** be locked out of their own Den. Owner's friends (Roblox friend list) can enter a locked Den.
- Den despawns when the owner leaves. All Mixlings in it are saved to profile at leave (and on autosave).
- The **Bound** starter Mixling shows a padlock and cannot be picked up by others.
- **New-player shield:** 5 minutes of unstealable status on first-ever join (server flag, visible bubble "NEW MIXER"). Not on rejoins.

### 8.4 Stealing and Bonk

**States for a Mixling:** `Placed` → `Carried` → (`Banked` | `Dropped` → `Placed`/`Carried`).

1. A thief inside an unlocked Den holds the ProximityPrompt on a pedestal for the rarity's hold time. Interrupt if the thief moves > 3 studs or is bonked.
2. On completion: Mixling detaches and floats above the thief's head. Thief gets `WalkSpeed × 0.85`, cannot jump higher than default, cannot use Bonk. A red "THIEF" tag shows to the owner only, plus a Den alarm sound + HUD alert for the owner ("Your Toaster Frog is being stolen!") with a compass arrow.
3. Thief must reach **their own** Den and touch an empty pedestal → `Banked`. Ownership transfers **only at bank**.
4. **Bonk:** every player carries a Bonk Bat (tool). Hitting a `Carried` player ragdolls them 2 s and drops the Mixling. Bonk on non-carriers does knockback only. Server validates hit distance (≤ 8 studs) and cooldown (0.8 s).
5. **Dropped:** anyone can pick up (2 s hold). If untouched for 8 s it returns to the original owner's pedestal (or their inventory if the pedestal is filled).
6. If the original owner leaves the server while their Mixling is `Carried` or `Dropped`, it is saved to the owner's profile and the in-world copy is destroyed. (Anti-rage-quit measures are v2 — measure first.)
7. Stealing from the same victim is rate-limited: after banking, that thief cannot start a pickup in the same Den for 45 s **[TUNE]**.

**Stats tracked:** steals banked, steals foiled (bonks on carriers), Goop stolen (value of banked Mixlings by Goop/sec × 60).

### 8.5 Mixdex (collection log)

- Grid of all 256 + secrets. Discovered entries show the assembled model, name, rarity, and best tier owned. Undiscovered show a silhouette.
- Progress % in HUD. Milestones at 10/25/50/100/200 entries grant Goop + a title.
- Secrets shown as "???" with the unlocked count.

### 8.6 Shops

- Buy ingredients with Goop. Purchases are instant, no confirmation for < 1,000 Goop; confirmation above.
- Shelf UI shows: model, name, tier, luck stars, price, "Owned: n". Sort by tier.
- Rotating **Weekly Drop** slot at the front of each shop: the newest ingredient, highlighted.

### 8.7 Leaderboards and badges

- OrderedDataStores: `TotalGoopEarned`, `StealsBanked`, `RarestScore` (= rarity × 1000 + Goop/sec of best owned).
- Badges: First Mix, First Placement, First Steal, First Bonk, Rare/Epic/Legendary/Mythic Roll, Secret Discoverer, Mixdex 50/100/200, 7-Day Streak.

### 8.8 Retention hooks (v1)

- **Daily reward:** escalating 7-day Goop track, resets on miss.
- **Codes:** `MIXER` (500 Goop) at launch; new code with every weekly drop. Codes are free distribution via code-aggregator sites.
- **Announcements:** Epic+ rolls, secret discoveries, and big steals fire server-wide banners. These are the game's own hype machine.
- **Weekly Drop:** every week, one new ingredient + one new secret recipe + one code.

---

## 9. Monetization

Principles: sell **speed, capacity, and luck**, never Mythics directly. Everything purchasable is also reachable with Goop or is cosmetic. Watch the like ratio; players downvote greed reliably.

**Game passes [prices TUNE]:**
- 2x Goop — 399 R$
- +5 Den Slots — 299 R$
- Lucky Mixer (+3 luck on every roll) — 499 R$
- VIP (chat tag, Den aura, +50% daily reward) — 699 R$

**Developer products:**
- Goop packs: 5,000 / 20,000 / 60,000 for 99 / 299 / 699 R$
- Lock Refresh (skip cooldown) — 49 R$
- **Server Luck Party:** +2 luck for everyone in the server for 10 min — 149 R$. Buyer gets a server banner and a badge. (Social spend; drives group purchase.)

**Compliance check:** because random outcomes are reachable from Robux → Goop → ingredients, enable the "paid random items" disclosure in the experience questionnaire unless Roblox's current policy says indirect chains are exempt. Verify at setup.

**First-dollar path:** one 99 R$ Goop pack or one 299 R$ pass ≈ $1 after Roblox's cut. That's the finish line for "shipped."

---

## 10. UI / UX

- **HUD (always on):** Goop balance (top center, large), Goop/sec below it, Mixdex %, buttons: Mixer / Den / Shop / Mixdex / Codes / Settings. Mobile: buttons ≥ 44 px, bottom-right cluster.
- **Mixer screen:** two big slots (Critter left, Stuff right), tap to open inventory picker, luck stars total, MIX button. After the roll: result card (model spin, name, rarity color, Goop/sec) with PLACE and MIX AGAIN.
- **Den panel:** pedestal grid, drag or tap-to-place, lock button with timer, slot purchase.
- **Alerts:** theft alarm with compass arrow; announcement banners (top, 3 s, rarity-colored).
- **Over-head:** name + Goop/sec for every player (public flex is a core motivator). Thieves carrying show the Mixling model over their head, not text.
- **Rarity colors:** Common gray, Uncommon green, Rare blue, Epic purple, Legendary gold, Mythic magenta/galaxy, Secret red-black.

---

## 11. Technical architecture

### 11.1 Rojo layout

```
default.project.json
src/
  ServerScriptService/
    Server.server.luau            -- boots services in order
    Services/
      DataService.luau            -- ProfileStore/ProfileService session-locked profiles, autosave, BindToClose
      EconomyService.luau         -- Goop accrual tick, balances, multipliers
      MixerService.luau           -- roll logic, secret recipes, inventory grant
      DenService.luau             -- Den assignment, pedestals, lock, slots, bound flag, new-player shield
      StealService.luau           -- carry/bank/drop state machine, bonk validation
      ShopService.luau            -- ingredient purchases
      MixdexService.luau          -- discovery tracking, milestones
      LeaderboardService.luau     -- OrderedDataStore updates, board rendering
      MonetizationService.luau    -- passes, products, receipts (ProcessReceipt, idempotent)
      AnnouncementService.luau    -- server/global banners (MessagingService for global)
      CodesService.luau
      AnalyticsService.luau       -- funnel + economy events
  ReplicatedStorage/
    Config/
      Constants.luau              -- §17
      Ingredients.luau            -- tables from §7.2
      Rarity.luau                 -- table from §7.3
      SecretRecipes.luau          -- SERVER-ONLY copy lives in ServerStorage; this file must NOT exist client-side
    Shared/
      Types.luau
      Net.luau                    -- remote definitions + rate limits
      MixlingAssembler.luau       -- builds a model from (critter, stuff, rarity) — used by client for preview, server for world
      Util.luau
  ServerStorage/
    SecretRecipes.luau            -- the real recipe table
  StarterPlayer/StarterPlayerScripts/
    Client.client.luau
    Controllers/
      HudController.luau
      MixerUIController.luau
      DenUIController.luau
      ShopController.luau
      MixdexController.luau
      SoundController.luau
      AlertController.luau
      TutorialController.luau
  StarterGui/                     -- UI built in Studio or via code; keep one approach
```

### 11.2 Data schema (profile)

```lua
export type Mixling = {
    id: string,            -- HttpService:GenerateGUID(false)
    critter: string,
    stuff: string,
    rarity: number,        -- 1..7
    secretId: string?,
    bound: boolean?,
    createdAt: number,
}

export type Profile = {
    version: number,
    goop: number,
    totalGoopEarned: number,
    inventory: { [string]: number },        -- ingredientName -> count
    mixlings: { Mixling },                  -- everything owned, placed or not
    placed: { [number]: string },           -- pedestalIndex -> mixling.id
    denSlots: number,                       -- 5..15
    lockLevel: number,                      -- 1..4
    mixdex: { [string]: number },           -- "Toaster:Frog" -> best rarity seen
    secretsFound: { [string]: true },
    stats: { stealsBanked: number, stealsFoiled: number, rolls: number, byRarity: { number } },
    daily: { streak: number, lastClaim: number },
    codes: { [string]: true },
    passes: { [string]: true },
    firstJoin: number,
    tutorialDone: boolean,
}
```

Migrations keyed on `version`. Never delete fields; deprecate.

### 11.3 Networking and security

- Server-authoritative for **everything** that touches Goop, inventory, Mixlings, or state. Clients send intents only: `RequestMix`, `RequestPlace`, `RequestPurchase`, `RequestLock`, `RequestPickup`, `RequestDrop`, `RedeemCode`.
- Every remote has a per-player rate limit and full argument validation (type, range, ownership).
- Bonk hits are validated server-side by distance and cooldown; the client only reports "I swung."
- Secret recipes never replicate to the client. The client learns a recipe only when it produces the result.
- Pedestal prompts are server-created `ProximityPrompt`s; hold duration set server-side from rarity.
- `ProcessReceipt` must be idempotent (store purchase IDs in profile).

### 11.4 Performance

- Mixling models: ≤ 1,500 tris body, ≤ 500 tris prop. Particles capped per Den. Idle sounds throttled (§7.5).
- Use `CollectionService` tags for pedestals/doors; `StreamingEnabled` on.
- Goop tick is one server loop over players, not one loop per player.

### 11.5 Tooling

- Rojo sync from `src/`. Studio "Studio as MCP server" is enabled for Claude Code to inspect the place, run Luau, and read output.
- Test protocol per feature: play-solo for UI, then **Local Server with 2+ clients** for anything involving stealing, locks, or announcements.

---

## 12. Content plan

**Launch:** 16 Critters, 16 Stuff, 7 rarity FX sets, 5 secret models, ~32 sounds + 5 secret sounds, 1 map, 3 Den skins [cosmetic, v1.5], 12 badges, icon + 3 thumbnails.

**Weekly Drop (every week, forever):** 1 ingredient (alternate Critter/Stuff), 1 secret recipe, 1 code, 1 limited-time luck event window. Name the drop, put it in the title tag: `[🧪 NEW: CAPYBARA]`.

**Seasonal [v2]:** themed ingredient sets (Halloween: Pumpkin, Bat already exists → "Pumpkin Bat"), limited Mixlings that leave the shop and become trade-only.

---

## 13. Scope

**v1 (ship this):** Mixer + assembler, Den + pedestals + lock, Goop economy, stealing + Bonk, shops, Mixdex, HUD, tutorial/first-60-seconds, persistence, leaderboards, badges, daily reward, codes, announcements, passes + products, analytics funnel.

**v1.5 (weeks 5–8):** Junk Cliffs wild spawns (net catch, server-wide rare spawn alerts), pity timer, Den skins, traps, storage overflow UI.

**v2 (months 2–3):** Trading (with confirmation + value display + scam guards), Goop Storm co-op raid events every 15 min, anti-rage-quit rules, seasonal sets, friends-only servers, Den decoration.

**Never:** a lobby, a hub of mini-games, selling Mythic/Secret Mixlings directly, unskippable cutscenes.

---

## 14. Milestones (30 days)

| Week | Deliverable | Definition of done |
|---|---|---|
| 1 | **Core:** Config, DataService, MixerService + roll, MixlingAssembler (2 critters × 2 stuff placeholder assets), Den + pedestals, Goop tick, HUD | 2 clients can mix, place, and watch Goop climb; profiles persist across rejoin |
| 2 | **Conflict:** StealService full state machine, Bonk, lock, shields, alerts, shops with real ingredient tables, Mixdex | 2 clients can steal from each other, bonk, lock; no client-side exploit path for Goop or ownership |
| 3 | **Polish + money:** first-60-seconds script, all launch assets + sounds wired, announcements, leaderboards, badges, daily, codes, passes/products + receipts, analytics funnel, icon/thumbnails | Private test with ≥ 5 friends; first-mix time ≤ 30 s measured; zero data-loss bugs |
| 4 | **Launch:** public release, Weekly Drop #1 queued, Shorts seeding live, code `MIXER` published | ≥ 1 real purchase. Then iterate on D1 retention weekly |

Parallel track (weeks 1–4, owner): produce sounds; model bodies/props; cut 20–30 Shorts of Mixling sound clips; set up Discord; prepare code-site submissions.

---

## 15. KPIs and telemetry

Funnel events (AnalyticsService): `Joined → FirstMix → FirstPlace → FirstShopBuy → FirstSteal → FirstPurchase`.
Economy events: Goop earned/spent by source/sink; roll outcomes by tier and luck.

Targets **[TUNE]**: first mix ≤ 30 s (median); D1 retention ≥ 25%; average session ≥ 10 min; like ratio ≥ 90%; Epic+ roll every ~4 min per server (tune weights until true); ARPDAU tracked from day 1.

---

## 16. Launch and growth

1. **Sound-meme seeding (pre-launch, 3–4 weeks):** 20–30 vertical clips, each = one Mixling doing its sound + a 1-line caption ("POV: your Toaster Frog is being stolen"). Post to TikTok/Shorts/IG Reels on a schedule via the existing Shorts automation. Goal: one sound catches. Include game name in every caption from day 1.
2. **Roblox listing:** icon = single shocked Mixling, big; title = `Mix a Monster [🧪 NEW: X]`; first thumbnail shows theft in progress; description leads with the loop in one sentence.
3. **Codes:** submit to code-aggregator sites at launch and with each weekly drop.
4. **Creator/UGC track:** publish Mixling avatar accessories (Toaster Hat, Sock Frog shoulder pet) on the catalog; each is a billboard for the game.
5. **Cross-promo:** portal from Cosbrostimulator to Mix a Monster (one-way at first; separate places, same Roblox group).
6. **Community:** Discord with a "secret recipe rumors" channel; never confirm recipes there.

---

## 17. Constants (implement as `ReplicatedStorage/Config/Constants.luau`)

```lua
return {
    SERVER_SIZE = 10,
    START_GOOP = 50,
    GOOP_TICK_SECONDS = 1,

    DEN_SLOTS_START = 5,
    DEN_SLOTS_MAX = 10,
    DEN_SLOTS_PASS_BONUS = 5,
    DEN_SLOT_PRICES = { 500, 1500, 4000, 10000, 25000 },

    LOCK = {
        { duration = 60,  cooldown = 90, price = 0 },
        { duration = 90,  cooldown = 90, price = 2000 },
        { duration = 120, cooldown = 90, price = 6000 },
        { duration = 150, cooldown = 90, price = 15000 },
    },

    NEW_PLAYER_SHIELD_SECONDS = 300,
    STEAL_REPEAT_VICTIM_COOLDOWN = 45,
    CARRY_WALKSPEED_MULT = 0.85,
    DROP_RETURN_SECONDS = 8,
    DROP_PICKUP_HOLD = 2,
    BONK_RANGE = 8,
    BONK_COOLDOWN = 0.8,
    BONK_RAGDOLL_SECONDS = 2,

    RARITY = {
        { name = "Common",    prefix = "",         weight = 600, goopPerSec = 1,   holdTime = 2.0, luckMult = 0    },
        { name = "Uncommon",  prefix = "Shiny",    weight = 250, goopPerSec = 3,   holdTime = 2.5, luckMult = 0    },
        { name = "Rare",      prefix = "Neon",     weight = 100, goopPerSec = 8,   holdTime = 3.0, luckMult = 0.10 },
        { name = "Epic",      prefix = "Glitched", weight = 35,  goopPerSec = 20,  holdTime = 3.5, luckMult = 0.15 },
        { name = "Legendary", prefix = "Golden",   weight = 12,  goopPerSec = 60,  holdTime = 4.0, luckMult = 0.20 },
        { name = "Mythic",    prefix = "Cosmic",   weight = 2.5, goopPerSec = 200, holdTime = 5.0, luckMult = 0.25 },
        { name = "Secret",    prefix = "",         weight = 0,   goopPerSec = 750, holdTime = 6.0, luckMult = 0    },
    },

    REVEAL_SECONDS = 3.0,
    REVEAL_MIN_SKIP_SECONDS = 1.5,
    IDLE_SOUND_INTERVAL = { 20, 40 },
    IDLE_SOUND_MIN_GAP_PER_DEN = 5,

    STARTER = { critter = "Frog", stuff = "Sock", riggedRarity = 2 },

    DAILY_REWARD = { 100, 200, 300, 500, 800, 1200, 2500 },
    LEADERBOARD_REFRESH = 60,
}
```

---

## 18. Risks and open questions

- **Name collision:** search Roblox for "Mix a Monster" before creating the place. If taken, fallback verbs: "Blend a Monster", "Brew a Monster". Keep "a Monster".
- **Rage-quit theft dodge:** owner leaving saves their Mixling (§8.4.6). Acceptable for v1; measure how often carried Mixlings vanish this way.
- **Cacophony:** 10 Dens × idle sounds. Throttles in §7.5 must be enforced server-side, not just client.
- **Model workload:** 32 assets + 5 secrets is the critical path. If behind, launch with 12 + 12 and add the rest as Weekly Drops (this is a feature, not a cut).
- **Balance:** Goop curve is a guess. Instrument first, tune weekly.
- **Policy:** paid-random-items disclosure (§9). Verify current Roblox policy at setup.
- **Open:** should friends be able to steal from each other? (Default: yes, with a "friendly fire" toggle in settings — decide in week 2.)

---

*End of document. Update the version header on every material change and log the change in `DECISIONS.md`.*
