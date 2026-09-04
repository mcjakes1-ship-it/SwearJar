# Mix a Monster — architecture

The design intent lives in [`GDD.md`](GDD.md). This document is the *build*
contract: module boundaries, the cross-service API, and the rules that keep a
server-authoritative game server-authoritative.

---

## 1. Layers

```
ReplicatedStorage/Config     data only, no behaviour, frozen at require time
ReplicatedStorage/Shared     realm-agnostic code (types, net, util, assembly, UI kit)
ServerStorage                secrets — never replicated, never mirrored
ServerScriptService/Services one service per system, booted in dependency order
StarterPlayerScripts         one controller per screen; renders, never decides
```

**The one-way rule.** Config knows nothing. Shared may require Config. Services
may require Config and Shared. Controllers may require Config and Shared.
Nothing requires a sibling service or controller — see §3.

---

## 2. Boot

`Server.server.luau` requires each service in `ORDER`, calls every `init(registry)`,
then every `start()`. That list is the entire dependency graph:

```
AnalyticsService → DataService → AnnouncementService → EconomyService
→ MonetizationService → WorldService → DenService → MixerService
→ StealService → ShopService → MixdexService → CodesService
→ LeaderboardService → PlayerService
```

`Client.client.luau` does the same for controllers with a `Controllers/` registry.

Every service module is exactly:

```lua
local MyService = {}
MyService.Name = "MyService"
function MyService.init(services) end  -- capture references only, never yield
function MyService.start() end         -- connect events, start loops
return MyService
```

`init` must not yield and must not do work. Anything that waits belongs in `start`.

---

## 3. Why services never require each other

A service reaches a sibling only through the `registry` table handed to `init`:

```lua
local economy
function ShopService.init(services)
    economy = services.EconomyService
end
```

This makes the graph acyclic by construction — Luau's `require` would deadlock or
silently return a half-built module on a cycle, and that failure mode is very hard
to see in a live server. It also means boot order is readable in one place instead
of being an emergent property of thirty `require` calls.

---

## 4. Cross-service API

Only these are public. Anything else in a service module is private, whatever
Luau lets you reach.

### AnalyticsService
```lua
event(name: string, props: {[string]: any}?)          -- generic telemetry line
funnel(player: Player, step: string)                  -- once per player per step
economy(player, kind: "Earn"|"Spend", source: string, amount: number)
roll(player, tier: number, luck: number)              -- GDD §15 roll distribution
```

### DataService
```lua
get(player) -> Profile?                 -- nil until loaded; never cache across sessions
waitFor(player, timeout: number?) -> Profile?
push(player, patch: {[string]: any}, full: boolean?)   -- replicate a ProfileView subset
forEach(fn: (Player, Profile) -> ())
saveAll(releaseLocks: boolean)
isMemoryOnly() -> boolean
template() -> Profile
onLoaded    : Signal(player, profile)
onReleasing : Signal(player, profile)   -- last synchronous chance to write state
```

### AnnouncementService
```lua
toPlayer(player, a: Announcement)
nearby(position: Vector3, radius: number, a: Announcement)   -- "Local" scope
server(a: Announcement)                                       -- this server's banner
global(a: Announcement)                                       -- MessagingService, all servers
forRoll(player, mixlingView, tier)   -- routes by Rarity.announceScope
```

### EconomyService
```lua
getBalance(player) -> number
award(player, amount: number, source: string) -> number   -- returns new balance
trySpend(player, amount: number, sink: string) -> boolean -- atomic; false if short
getGoopPerSec(player) -> number        -- placed Mixlings x multipliers
recompute(player)                      -- call after any placement change
getMultiplier(player) -> number
onBalanceChanged : Signal(player, goop)
```

### MonetizationService
Owns every Roblox platform integration: passes, products, receipts, badges.
```lua
hasPass(player, key: string) -> boolean            -- key indexes Constants.PASSES
getLuck(player) -> number                          -- pass luck + active server luck
getGoopMultiplier(player) -> number
getSlotBonus(player) -> number
getServerLuck() -> number
promptPass(player, key)
promptProduct(player, key)
awardBadge(player, badgeKey: string)               -- key indexes Constants.BADGES
```

### WorldService
Builds Blendburg procedurally so the repo is playable with zero Studio work
(GDD §6). Studio-authored models under `ReplicatedStorage/Assets/World` override
it when present.
```lua
getPlazaCenter() -> Vector3
getMixerPads() -> {BasePart}
getDenAnchor(slotIndex: number) -> CFrame          -- 1..Constants.SERVER_SIZE
getDenFolder(slotIndex: number) -> Folder
getSpawnFor(slotIndex: number) -> CFrame
getShopAnchor(kind: "Critter"|"Stuff"|"Mixdex") -> CFrame
getLeaderboardBoards() -> {BasePart}               -- one per Constants.LEADERBOARDS
```

### DenService
```lua
getDen(player) -> Den?
getPedestal(player, index: number) -> BasePart?
place(player, mixlingId: string, index: number) -> (boolean, string?)
unplace(player, mixlingId: string) -> boolean
bank(thief: Player, mixling: Mixling) -> number?   -- returns pedestal index or nil
takeFromPedestal(owner: Player, index: number) -> Mixling?  -- StealService only
returnToOwner(owner: Player, mixling: Mixling)     -- drop timeout / rage-quit path
isLocked(player) -> boolean
tryLock(player) -> (boolean, string?)
refreshLock(player)                                -- Lock Refresh product
canEnter(visitor: Player, ownerUserId: number) -> boolean
isShielded(player) -> boolean
totalSlots(player) -> number                       -- profile.denSlots + pass bonus
publicList() -> {DenPublic}
ownerOfDen(model: Instance) -> Player?
onPedestalPrompt : Signal(thief: Player, owner: Player, index: number)
```

### MixerService
```lua
onRolled : Signal(player, mixling: Mixling, isNewEntry: boolean, secretId: string?)
```
Handles `RequestMix` itself. The roll is server-side only, from a per-server
`Random` (GDD §11.3), and the client is told the result, never asked for it.

### StealService
```lua
isCarrying(player) -> boolean
getCarried(player) -> CarriedInfo?
dropCarried(player, reason: string)
onBanked : Signal(thief, victimUserId: number, mixling)
```

### MixdexService
```lua
record(player, critter, stuff, rarity, secretId: string?) -> boolean  -- true if new
progress(player) -> (discovered: number, total: number)
```

### CodesService
```lua
redeem(player, code: string) -> (boolean, string)   -- ok, message
```

### LeaderboardService
```lua
submit(player, key: string, value: number)
```

### PlayerService
Session lifecycle: spawn into your own Den, the first-60-seconds handshake, the
daily reward, `SetSetting`, `RequestTeleport`, and the initial full ProfileSync.

---

## 5. The remote surface

Defined once in `Shared/Net.luau`. **A remote that is not listed there does not
exist.** Adding one anywhere else is a bug.

Every server handler goes through `Net.onServerEvent` / `Net.onServerInvoke`,
which rate-limit per player and wrap the handler so a malformed payload cannot
kill the connection for everyone else. Handlers validate every argument with
`Net.isString` / `Net.isIntInRange` / `Net.isBoolean` before use.

Clients send intents. `RequestMix` is a request; the server decides whether a mix
happens, what it produces, and what it costs.

---

## 6. Assets are optional

`MixlingAssembler` clones `ReplicatedStorage/Assets/{Critters,Stuff,Secrets}/<Name>`
when it exists and generates a deterministic placeholder from the ingredient's
name and colour when it does not. `WorldService` does the same for Blendburg.
This is deliberate: the model workload is the launch critical path (GDD §18), and
code must never be blocked on art.

Expected Studio layout when the art lands:

```
ReplicatedStorage/Assets/
  Critters/<Frog|Cat|Shark|...>            Model, PrimaryPart set,
                                           Attachments named Head / Back / Hand
  Stuff/<Sock|Toaster|Crown|...>           Model, PrimaryPart set
  Secrets/<KingBara|Sharkpedo|...>         Model, PrimaryPart set
  Sounds/Voices/Voice_<Critter>            Sound
  Sounds/Layers/Layer_<Stuff>              Sound
  World/<Mixer|Den|CritterPen|...>         Model (optional overrides)
```

---

## 7. Rules that are not negotiable

1. **Server-authoritative.** Goop, inventory, Mixling ownership and every state
   transition are decided server-side. The client renders outcomes.
2. **No magic numbers.** If it is a balance value, it is in `Constants`.
3. **Secrets never replicate.** `ServerStorage/SecretRecipes` is required only by
   server code. The client gets `SecretsPublic.COUNT`.
4. **Ownership transfers at bank, never at pickup** (GDD §8.4.3).
5. **The roll is never interrupted** (GDD §2, pillar 1).
6. **The tutorial never blocks movement** (GDD §5).
7. **`--!strict` everywhere**, and `bash tools/check.sh` must be clean before a
   commit.

---

## 8. Type-checking

```bash
tools/check.sh              # whole project
tools/check.sh src/path.luau
```

Runs `luau-compile` for syntax and `luau-lsp analyze` against the real Roblox API
definitions, using a sourcemap generated from `src/` by `tools/sourcemap.py` so
cross-module `require`s resolve. See `README.md` → Toolchain for the one-time
binary fetch.
