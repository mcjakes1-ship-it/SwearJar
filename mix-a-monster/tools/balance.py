#!/usr/bin/env python3
"""Balance model for Mix a Monster.

GDD §18: "Balance: Goop curve is a guess. Instrument first, tune weekly."
This is the instrument you can run before a single playtest. It reads the real
Constants.luau — not a copy — and answers the questions §15 sets as targets:

  * what are the odds at each luck level, and does the luck curve do anything?
  * how often does a server see an Epic+ roll?  (target: every ~4 min)
  * does the Goop curve hit ~10/sec at 15 min, ~100/sec by day 3,
    ~1,000/sec by week 2?
  * do the sinks keep up with the faucets, or does the economy run out of
    things to buy?

Run:  python3 tools/balance.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONST = open(os.path.join(ROOT, "src/ReplicatedStorage/Config/Constants.luau")).read()
INGR = open(os.path.join(ROOT, "src/ReplicatedStorage/Config/Ingredients.luau")).read()


def scalar(name, cast=float):
    m = re.search(rf"^Constants\.{name} = ([0-9.]+)", CONST, re.M)
    if not m:
        sys.exit(f"balance.py: could not read Constants.{name}")
    return cast(m.group(1))


def rarity_table():
    block = re.search(r"Constants\.RARITY = \{(.*?)\n\}", CONST, re.S).group(1)
    rows = []
    for line in block.splitlines():
        m = re.search(
            r'name = "(\w+)".*?weight = ([0-9.]+).*?goopPerSec = ([0-9.]+).*?'
            r"holdTime = ([0-9.]+).*?luckMult = ([0-9.]+)",
            line,
        )
        if m:
            rows.append({
                "name": m.group(1), "weight": float(m.group(2)),
                "gps": float(m.group(3)), "hold": float(m.group(4)),
                "luckMult": float(m.group(5)),
            })
    return rows


def ingredients():
    out = {"Critter": [], "Stuff": []}
    for kind, fn in (("Critter", "critter"), ("Stuff", "stuff")):
        for m in re.finditer(rf'\t{fn}\("([^"]+)", (\d+), (\d+), (\d+)', INGR):
            out[kind].append({"name": m.group(1), "tier": int(m.group(2)),
                              "price": int(m.group(3)), "luck": int(m.group(4))})
    return out


RARITY = rarity_table()
ROLLABLE = [r for r in RARITY if r["weight"] > 0]
ING = ingredients()
START_GOOP = scalar("START_GOOP")
SLOT_PRICES = [int(x) for x in re.search(r"DEN_SLOT_PRICES = \{([^}]*)\}", CONST).group(1).replace(" ", "").split(",") if x]
LOCK_PRICES = [int(m) for m in re.findall(r"price = (\d+)", re.search(r"Constants\.LOCK = \{(.*?)\n\}", CONST, re.S).group(1))]
DAILY = [int(x) for x in re.search(r"DAILY_REWARD = \{([^}]*)\}", CONST).group(1).replace(" ", "").split(",") if x]
SERVER_SIZE = scalar("SERVER_SIZE", int)
SLOTS_START = scalar("DEN_SLOTS_START", int)
SLOTS_HARD_MAX = scalar("DEN_SLOTS_HARD_MAX", int)
REVEAL_MIN_SKIP = scalar("REVEAL_MIN_SKIP_SECONDS")


def odds(luck):
    eff = [r["weight"] * (1 + luck * r["luckMult"]) for r in ROLLABLE]
    total = sum(eff)
    return [e / total for e in eff]


def expected_gps(luck):
    return sum(p * r["gps"] for p, r in zip(odds(luck), ROLLABLE))


def rule(title):
    print(f"\n{title}\n" + "─" * len(title))


print("MIX A MONSTER — balance model")
print(f"read from Constants.luau: {len(RARITY)} tiers, "
      f"{len(ING['Critter'])} critters x {len(ING['Stuff'])} stuff "
      f"= {len(ING['Critter']) * len(ING['Stuff'])} base Mixlings")

# ── Odds ─────────────────────────────────────────────────────────────────
rule("1. Roll odds by luck  (GDD §8.1)")
LUCKS = [0, 2, 4, 8, 12, 15]
print(f"{'tier':<10} " + " ".join(f"{'L=' + str(l):>10}" for l in LUCKS))
for i, r in enumerate(ROLLABLE):
    row = " ".join(f"{odds(l)[i] * 100:>9.3f}%" for l in LUCKS)
    print(f"{r['name']:<10} {row}")
print(f"{'1 in':<10} " + " ".join(
    f"{('1/' + str(round(1 / odds(l)[-1]))):>10}" for l in LUCKS) + "   <- Mythic")
print(f"\nmax luck reachable: T5 critter (6) + T5 stuff (6) + Lucky Mixer (3) "
      f"+ Luck Party (2) = 17")
print(f"expected Goop/sec per roll: " + ", ".join(
    f"L={l}:{expected_gps(l):.1f}" for l in LUCKS))

# ── Epic+ cadence ────────────────────────────────────────────────────────
rule("2. Epic+ cadence per server  (GDD §15 target: every ~4 min)")
p_epic_plus = sum(odds(0)[3:])
for rolls_per_min_per_player in (0.7, 1.0, 1.5):
    server_rolls = rolls_per_min_per_player * SERVER_SIZE
    minutes = 1 / (server_rolls * p_epic_plus)
    verdict = "ON TARGET" if 2 <= minutes <= 6 else "OFF TARGET"
    print(f"  {rolls_per_min_per_player:>4.1f} rolls/min/player x {SERVER_SIZE} players "
          f"-> Epic+ every {minutes:>5.1f} min   {verdict}")
print(f"  (P(Epic+) at luck 0 = {p_epic_plus * 100:.2f}%; GDD §4 says a mix every 45-90 s "
      f"early game = 0.7-1.3 rolls/min)")

# ── Goop curve ───────────────────────────────────────────────────────────
rule("3. Goop curve  (GDD §8.2 targets: ~10/sec @ 15 min, ~100/sec @ day 3, ~1000/sec @ week 2)")

import random


def simulate(minutes, luck_bonus=0, pass_multiplier=1.0, seed=7, buy_slots=True):
    """Monte Carlo of one player reinvesting everything.

    Each simulated minute the player banks their income, then greedily buys the
    most expensive Critter+Stuff pair they can afford (higher tier = more luck)
    and rolls it. A roll is kept if it beats the worst thing on a pedestal.
    Den slots are bought when the player can afford one twice over, so slot
    spending never starves the roll loop.

    Optimistic by construction: perfect reinvestment, perfect pair choice, no
    theft, no idle time. Real curves sit below this, which is what makes it a
    useful ceiling."""
    rng = random.Random(seed)
    # Starter ingredients are a one-time GRANT, not stock (GDD §7.2). If the
    # shop ever sold them at their listed price of 0, a player could roll
    # forever for nothing and the economy would not exist. They are excluded
    # here for the same reason ShopService excludes them.
    critters = sorted([i for i in ING["Critter"] if i["price"] > 0], key=lambda i: -i["price"])
    stuffs = sorted([i for i in ING["Stuff"] if i["price"] > 0], key=lambda i: -i["price"])

    # A roll costs Constants.REVEAL_SECONDS of screen time that cannot be
    # skipped below REVEAL_MIN_SKIP_SECONDS, so there is a hard ceiling on
    # rolls per minute no matter how rich the player is. Without this the model
    # reports rates no human could reach.
    rolls_per_minute_cap = 60.0 / REVEAL_MIN_SKIP

    goop = START_GOOP
    slots = SLOTS_START
    placed = []
    rolls = 0
    spent = 0

    def rate():
        return sum(placed) * pass_multiplier

    def roll_tier(luck):
        weights = odds(luck)
        pick = rng.random()
        cursor = 0.0
        for index, weight in enumerate(weights):
            cursor += weight
            if pick <= cursor:
                return index
        return 0

    for _ in range(int(minutes)):
        goop += rate() * 60

        # Den slots first, but only out of surplus.
        while buy_slots and slots < SLOTS_START + len(SLOT_PRICES):
            price = SLOT_PRICES[slots - SLOTS_START]
            if goop < price * 2:
                break
            goop -= price
            spent += price
            slots += 1

        # Then roll until the best affordable pair is out of reach, or the
        # player runs out of minute.
        rolls_this_minute = 0
        while rolls_this_minute < rolls_per_minute_cap:
            pair = None
            for critter in critters:
                for stuff in stuffs:
                    if critter["price"] + stuff["price"] <= goop:
                        pair = (critter, stuff)
                        break
                if pair:
                    break
            if not pair:
                break
            cost = pair[0]["price"] + pair[1]["price"]
            goop -= cost
            spent += cost
            rolls += 1
            rolls_this_minute += 1
            tier = roll_tier(pair[0]["luck"] + pair[1]["luck"] + luck_bonus)
            gained = ROLLABLE[tier]["gps"]
            if len(placed) < slots:
                placed.append(gained)
            elif gained > min(placed):
                placed.remove(min(placed))
                placed.append(gained)
    return rate(), rolls, slots, spent


TARGETS = (
    ("15 min", 15, 10),
    ("1 hour", 60, None),
    ("day 1  (2 h play)", 120, None),
    ("day 3  (6 h play)", 360, 100),
    ("week 2 (28 h play)", 28 * 60, 1000),
)
print(f"  {'checkpoint':<20}{'Goop/sec':>12}{'rolls':>12}{'slots':>7}   vs GDD target")
for label, minutes, target in TARGETS:
    gps, rolls, slots, _ = simulate(minutes)
    if target is None:
        verdict = ""
    else:
        ratio = gps / target
        verdict = f"{target:>6} -> {ratio:>6.1f}x " + (
            "ON TARGET" if 0.5 <= ratio <= 2 else ("MUCH FASTER" if ratio > 2 else "MUCH SLOWER"))
    print(f"  {label:<20}{gps:>12,.0f}{rolls:>12,}{slots:>7}   {verdict}")

gps_free, _, _, _ = simulate(360)
gps_paid, _, _, _ = simulate(360, luck_bonus=3, pass_multiplier=2.0)
print(f"\n  day-3 free player {gps_free:>10,.0f} Goop/sec")
print(f"  day-3 with 2x Goop + Lucky Mixer {gps_paid:>10,.0f} Goop/sec "
      f"({gps_paid / max(gps_free, 1):.2f}x)")
print("  GDD §9: passes sell speed, capacity and luck — never an outcome. A")
print("  multiple much above ~2.5x reads as pay-to-win to a 9-14 audience.")

# ── Sinks vs faucets ─────────────────────────────────────────────────────
rule("4. Sinks vs faucets  (GDD §8.2 lists sinks: ingredients, den slots, lock upgrades)")
one_time = sum(SLOT_PRICES) + sum(LOCK_PRICES)
all_ingredients_once = sum(i["price"] for i in ING["Critter"] + ING["Stuff"])
most_expensive = max(i["price"] for i in ING["Critter"] + ING["Stuff"])
print(f"  every one-time sink in the game (all den slots + all lock levels): "
      f"{one_time:,} Goop")
print(f"  one of every ingredient:                                          "
      f"{all_ingredients_once:,} Goop")
print(f"  the single most expensive purchase:                               "
      f"{most_expensive:,} Goop")
for rate, label in ((10, "15-min player"), (100, "day-3 player"), (1000, "week-2 player")):
    print(f"  a {label:<14} ({rate:>4}/sec) buys out every one-time sink in "
          f"{one_time / rate / 60:>7.1f} min, and the priciest ingredient every "
          f"{most_expensive / rate:>5.0f} s")
free_items = [i["name"] for i in ING["Critter"] + ING["Stuff"] if i["price"] == 0]
print(f"\n  ingredients priced at 0 Goop: {', '.join(free_items) or 'none'}")
if free_items:
    print("  ^ these MUST NOT be sellable. GDD §7.2 grants the starter pair once per")
    print("    profile; a shop that stocks them at 0 is an infinite free roll and the")
    print("    Goop economy stops existing. ShopService excludes them.")

print("\n  READ THIS: the only sink that scales is 'buy another ingredient and roll'.")
print("  Once a player's rate exceeds the most expensive ingredient per few seconds,")
print("  Goop stops being a constraint and the roll stops being a decision. The")
print("  numbers above say roughly when. See DECISIONS.md and GDD §8.2 sinks.")

# ── Daily / codes ────────────────────────────────────────────────────────
rule("5. Retention rewards relative to income  (GDD §8.8)")
week = sum(DAILY)
print(f"  full 7-day daily track: {week:,} Goop "
      f"({week / 60:.1f} min of income at 10/sec, {week / 60 / 100:.2f} min at 100/sec)")
print(f"  launch code MIXER: 500 Goop")
print("  A daily reward worth under a minute of play is not a reason to log in.")
print("  Consider scaling the daily track to the player's rate, or paying it in")
print("  ingredients rather than Goop.")

# ── Progression ceiling ──────────────────────────────────────────────────
rule("6. The progression ceiling  (the number that decides how long the game lasts)")
best = max(r["gps"] for r in RARITY)
mythic = [r for r in RARITY if r["name"] == "Mythic"][0]["gps"]
common = [r for r in RARITY if r["name"] == "Common"][0]["gps"]
floor_rate = SLOTS_START * common
paid_ceiling = SLOTS_HARD_MAX * best
realistic = SLOTS_HARD_MAX * mythic
print(f"  floor   {SLOTS_START} slots x {common:.0f} (all Common)   = {floor_rate:>10,.0f} Goop/sec")
print(f"  ceiling {SLOTS_HARD_MAX} slots x {mythic:.0f} (all Mythic)  = {realistic:>10,.0f} Goop/sec")
print(f"  cap     {SLOTS_HARD_MAX} slots x {best:.0f} (all Secret)  = {paid_ceiling:>10,.0f} Goop/sec")
print(f"  total span floor -> realistic ceiling: {realistic / floor_rate:,.0f}x")
gps_day3, _, _, _ = simulate(360)
print(f"\n  the day-3 simulation above reached {gps_day3:,.0f}/sec, i.e. "
      f"{gps_day3 / realistic * 100:.0f}% of the realistic ceiling.")
print("  Once a player fills every pedestal with a top-tier Mixling there is")
print("  nothing left to increase. The Mixdex and the leaderboards are then the")
print("  only progression, and neither pays out. Anything that widens this span")
print("  (more pedestals, a prestige reset, rarity tiers above Mythic, Mixling")
print("  fusion) buys weeks of retention; anything that speeds the climb costs it.")

print("\ndone. Every number above comes from Constants.luau; change it there and re-run.")
