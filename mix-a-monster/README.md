# Mix a Monster

Drop two ingredients into the Mixer, get a random mashup creature, defend it in
your Den, steal better ones from everyone else.

A Roblox experience in Luau, synced with [Rojo](https://rojo.space).
Design intent: [`docs/GDD.md`](docs/GDD.md).
Build contract: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
Every ambiguous call and why it went that way: [`DECISIONS.md`](DECISIONS.md).

---

## Quick start

```bash
rojo serve                 # from this directory
```

Then in Studio: **Plugins → Rojo → Connect**, and press Play. The game is
playable immediately — Blendburg builds itself and every Mixling is generated
procedurally, so **no art or sound assets are required to run it**. Drop real
assets in later (§ *Adding art*) and nothing in the code changes.

Two things to switch on before anything persists or earns:

1. **Game Settings → Security → Enable Studio Access to API Services.** Without
   it `DataService` runs memory-only and warns loudly on boot; nothing saves.
2. **Game Settings → Monetization** — create the passes and products, then paste
   their ids into `Constants.PASSES` / `Constants.PRODUCTS` (see below).

---

## Toolchain

Type checking is a commit gate. Fetch the binaries once:

```bash
mkdir -p .tools && cd .tools
curl -sSL -o luau.zip https://github.com/luau-lang/luau/releases/latest/download/luau-ubuntu.zip
curl -sSL -o lsp.zip  https://github.com/JohnnyMorganz/luau-lsp/releases/latest/download/luau-lsp-linux-x86_64.zip
curl -sSL -o globalTypes.d.luau https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau
unzip -o luau.zip && unzip -o lsp.zip && chmod +x luau* && cd ..
```

`.tools/` is gitignored. Then:

```bash
tools/check.sh                    # syntax + full type check against the real Roblox API
tools/check.sh src/path/File.luau # one file
tools/lint_contract.py            # cross-file rules: remotes, Constants keys, secrecy boundary
tools/spec/run.sh                 # 105 behavioural tests, no Studio needed
tools/balance.py                  # the economy model, read from the live Constants
```

`tools/spec/run.sh` bundles the realm-agnostic modules against a small Roblox
shim and runs them in the standalone interpreter, so profile migration, the roll
distribution, secret matching and every number the player reads are tested
before a place is ever opened. Instance-building and anything touching a service
is covered by the Studio protocol below instead.

`tools/check.sh` generates a Rojo-shaped sourcemap from `src/` so cross-module
`require`s resolve; it does not need Rojo installed.

**All four must be clean before a commit.**

---

## Studio setup checklist

Everything below is a value to paste into `ReplicatedStorage/Config/Constants.luau`.
An id left at `0` means "not wired": the game skips that platform call, warns once
at boot, and keeps running. That is how the repo stays testable before any of it
exists.

| What | Where it goes |
|---|---|
| 4 game passes (2x Goop, +5 Den Slots, Lucky Mixer, VIP) | `Constants.PASSES.<key>.id` |
| 5 developer products (3 Goop packs, Lock Refresh, Server Luck Party) | `Constants.PRODUCTS.<key>.id` |
| 13 badges | `Constants.BADGES.<key>` |

Also at setup:

- **Max players → 10** (must match `Constants.SERVER_SIZE`; the Den ring has
  exactly that many dens).
- **Experience questionnaire → paid random items.** Robux buys Goop, Goop buys
  ingredients, ingredients roll a random rarity. That is an indirect chain to a
  random outcome — enable the disclosure unless Roblox's current policy explicitly
  exempts indirect chains. Verify the policy at setup; this is GDD §9 and §18.
- **Title:** `Mix a Monster [🧪 NEW: X]`, updated each Weekly Drop.

---

## Adding art

`MixlingAssembler` and `WorldService` both look for a Studio asset by name first
and generate a placeholder only when it is missing. Create this under
`ReplicatedStorage/Assets` and the placeholders disappear one at a time:

```
Assets/
  Critters/<Frog|Cat|Shark|…>     Model · PrimaryPart set · Attachments named Head, Back, Hand
  Stuff/<Sock|Toaster|Crown|…>    Model · PrimaryPart set
  Secrets/<KingBara|Sharkpedo|…>  Model · PrimaryPart set
  Sounds/Voices/Voice_<Critter>   Sound · 1–2 s
  Sounds/Layers/Layer_<Stuff>     Sound · 1–2 s
  World/<Mixer|Den|CritterPen|…>  Model — optional overrides for Blendburg
```

Budgets (GDD §11.4): ≤ 1,500 tris per body, ≤ 500 per prop.

---

## The Weekly Drop

One new ingredient, one new secret, one new code — every week, forever
(GDD §12). It is meant to take hours, not weeks:

1. **Ingredient** — one row in `Config/Ingredients.luau` (`Critters` or `Stuff`).
   That row alone creates 16 new Mixlings, and the Mixdex denominator updates
   itself.
2. **Secret** — one row in `ServerStorage/SecretRecipes.luau`, then bump
   `Config/SecretsPublic.luau`'s `COUNT`. The boot check warns if you forget.
3. **Code** — one row in `Constants.CODES`. Codes support an optional `expires`.
4. Add the asset under `Assets/`, update the title tag, ship.

Nothing else changes. That is the point of the assembly engine (GDD §7.1).

---

## Test protocol

Per GDD §11.5, and non-negotiable for anything touching theft:

- **Play Solo** for UI, the tutorial and the Mixer reveal.
- **Test → Local Server, 2+ clients** for stealing, bonking, locks, shields,
  announcements and the Den ring. Every one of those is a two-player interaction
  and single-player testing proves nothing about them.
- **Rejoin** after a session to confirm the profile round-trips: Mixlings,
  placements, Goop, Mixdex, streak.

The bar to clear before launch (GDD §14, week 3): first-mix time ≤ 30 s measured,
no client-side path to Goop or ownership, zero data-loss bugs.

---

## Repo map

```
default.project.json          Rojo project
DECISIONS.md                  every ambiguous call, with the reason
docs/GDD.md                   design intent — the source of truth
docs/ARCHITECTURE.md          module boundaries and the cross-service API
src/ReplicatedStorage/Config  data only: constants, ingredients, rarity
src/ReplicatedStorage/Shared  types, remotes, util, the assembler, the UI kit
src/ServerStorage             secret recipes — never replicated
src/ServerScriptService       one service per system, booted in dependency order
src/StarterPlayer             one controller per screen; renders, never decides
tools/                        type-check and contract-lint harness
```

Read `docs/ARCHITECTURE.md` before adding a file. The rules that are not
negotiable are in its §7.
