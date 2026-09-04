#!/usr/bin/env python3
"""Contract linter for Mix a Monster.

The type checker proves each file is internally sound against the Roblox API.
This proves the files agree with each other, and that the rules in
docs/ARCHITECTURE.md §7 actually hold:

  1. every remote name used exists in Shared/Net.luau
  2. every Constants.<KEY> referenced exists in Constants.luau
  3. no service requires a sibling service (the registry is the only seam)
  4. no controller requires a sibling controller
  5. nothing outside ServerStorage/ServerScriptService touches SecretRecipes
  6. no secret name or ingredient pair leaks into ReplicatedStorage
  7. every service named in the boot ORDER exists, and every service file is
     in the ORDER
  8. every registry key captured in an init() is a real service

Exit code 1 on any violation.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")

problems = []
notes = []


def read(*parts):
    path = os.path.join(ROOT, *parts)
    with open(path) as handle:
        return handle.read()


def walk(rel):
    base = os.path.join(SRC, rel)
    for dirpath, _dirs, files in os.walk(base):
        for name in sorted(files):
            if name.endswith(".luau"):
                full = os.path.join(dirpath, name)
                yield os.path.relpath(full, ROOT), open(full).read()


def strip_comments(text):
    text = re.sub(r"--\[\[.*?\]\]", "", text, flags=re.S)
    return re.sub(r"--[^\n]*", "", text)


# ── 1. remote names ──────────────────────────────────────────────────────
net = read("src", "ReplicatedStorage", "Shared", "Net.luau")


def names_in(block_name):
    match = re.search(rf"Net\.{block_name} = \{{(.*?)\n\}}", net, re.S)
    if not match:
        problems.append(f"Net.luau: could not parse Net.{block_name}")
        return set()
    # Strip comments first: the blocks carry doc comments that quote other
    # vocabularies (Notify's `kind` values, for one), and reading those as
    # remote names both invents remotes that do not exist and, worse, would
    # let a genuinely undefined remote pass if its name happened to appear in
    # a comment.
    return set(re.findall(r'^\s*"([A-Za-z]+)"', strip_comments(match.group(1)), re.M))


REMOTES = names_in("CLIENT_TO_SERVER") | names_in("SERVER_TO_CLIENT") | names_in("FUNCTIONS")
notes.append(f"{len(REMOTES)} remotes defined in Net.luau")

USE_PATTERNS = [
    r'Net\.event\(\s*"([A-Za-z]+)"',
    r'Net\.func\(\s*"([A-Za-z]+)"',
    r'Net\.fire\([^,]+,\s*"([A-Za-z]+)"',
    r'Net\.fireAll\(\s*"([A-Za-z]+)"',
    r'Net\.onServerEvent\(\s*"([A-Za-z]+)"',
    r'Net\.onServerInvoke\(\s*"([A-Za-z]+)"',
    r'Net\.consume\([^,]+,\s*"([A-Za-z]+)"',
]

used = set()
for rel, text in list(walk("")):
    if rel.endswith("Net.luau"):
        continue
    body = strip_comments(text)
    for pattern in USE_PATTERNS:
        for name in re.findall(pattern, body):
            used.add(name)
            if name not in REMOTES:
                problems.append(f"{rel}: uses undefined remote {name!r}")
    if re.search(r'Instance\.new\(\s*"Remote(Event|Function)"', body) and "Net.luau" not in rel:
        problems.append(f"{rel}: creates a remote directly; only Net.luau may do that")

for name in sorted(REMOTES - used):
    notes.append(f"remote {name!r} is defined but never used")

# ── 2. Constants keys ────────────────────────────────────────────────────
constants = read("src", "ReplicatedStorage", "Config", "Constants.luau")
CONST_KEYS = set(re.findall(r"^Constants\.([A-Z][A-Z0-9_]*)\s*=", constants, re.M))
CONST_KEYS |= set(re.findall(r"^Constants\.([A-Za-z][A-Za-z0-9_]*)\s*=", constants, re.M))
notes.append(f"{len(CONST_KEYS)} top-level Constants keys")

for rel, text in walk(""):
    if rel.endswith("Constants.luau"):
        continue
    for key in re.findall(r"\bConstants\.([A-Za-z][A-Za-z0-9_]*)", strip_comments(text)):
        if key not in CONST_KEYS:
            problems.append(f"{rel}: references Constants.{key}, which does not exist")

# ── 3/4. no sibling requires ─────────────────────────────────────────────
for rel, text in walk("ServerScriptService/Services"):
    body = strip_comments(text)
    for match in re.findall(r'require\([^)]*?["\']?([A-Za-z]+Service)["\']?[^)]*\)', body):
        if match != os.path.basename(rel)[:-5]:
            problems.append(f"{rel}: requires sibling service {match}; use the init(services) registry")

for rel, text in walk("StarterPlayer/StarterPlayerScripts/Controllers"):
    body = strip_comments(text)
    for match in re.findall(r'require\([^)]*?["\']?([A-Za-z]+Controller)["\']?[^)]*\)', body):
        if match != os.path.basename(rel)[:-5]:
            problems.append(f"{rel}: requires sibling controller {match}; use the init(controllers) registry")

# ── 5/6. the secrecy boundary ────────────────────────────────────────────
secret_src = read("src", "ServerStorage", "SecretRecipes.luau")
SECRET_NAMES = set(re.findall(r'name = "([^"]+)"', secret_src))
SECRET_IDS = set(re.findall(r'id = "([^"]+)"', secret_src))
SECRET_PAIRS = re.findall(r'critter = "([^"]+)", stuff = "([^"]+)"', secret_src)

for rel, text in walk("ReplicatedStorage"):
    body = strip_comments(text)
    if "SecretRecipes" in body:
        problems.append(f"{rel}: mentions SecretRecipes; it is ServerStorage-only")
    for name in SECRET_NAMES | SECRET_IDS:
        if name in body:
            problems.append(f"{rel}: leaks secret identifier {name!r} into ReplicatedStorage")
    for critter, stuff in SECRET_PAIRS:
        if re.search(rf'"{re.escape(critter)}"[^\n]*"{re.escape(stuff)}"', body) or \
           re.search(rf'"{re.escape(stuff)}"[^\n]*"{re.escape(critter)}"', body):
            problems.append(f"{rel}: leaks the secret pair {critter}+{stuff}")

for rel, text in walk("StarterPlayer"):
    if "SecretRecipes" in strip_comments(text):
        problems.append(f"{rel}: client code references SecretRecipes")

# ── 7/8. boot order vs. files vs. registry use ───────────────────────────
boot = read("src", "ServerScriptService", "Server.server.luau")
match = re.search(r"local ORDER = \{(.*?)\n\}", boot, re.S)
ORDER = set(re.findall(r'"([A-Za-z]+)"', match.group(1))) if match else set()
ON_DISK = {
    f[:-5]
    for f in os.listdir(os.path.join(SRC, "ServerScriptService", "Services"))
    if f.endswith(".luau")
}
for missing in sorted(ORDER - ON_DISK):
    problems.append(f"Server.server.luau: boot ORDER names {missing}, which has no file")
for orphan in sorted(ON_DISK - ORDER):
    problems.append(f"Services/{orphan}.luau exists but is not in the boot ORDER")

for rel, text in walk("ServerScriptService/Services"):
    for key in re.findall(r"services\.([A-Za-z]+Service)", strip_comments(text)):
        if key not in ORDER:
            problems.append(f"{rel}: captures services.{key}, which is not a booted service")

client = read("src", "StarterPlayer", "StarterPlayerScripts", "Client.client.luau")
match = re.search(r"local ORDER = \{(.*?)\n\}", client, re.S)
CORDER = set(re.findall(r'"([A-Za-z]+)"', match.group(1))) if match else set()
cdir = os.path.join(SRC, "StarterPlayer", "StarterPlayerScripts", "Controllers")
CON_DISK = {f[:-5] for f in os.listdir(cdir) if f.endswith(".luau")} if os.path.isdir(cdir) else set()
for missing in sorted(CORDER - CON_DISK):
    problems.append(f"Client.client.luau: boot ORDER names {missing}, which has no file")
for orphan in sorted(CON_DISK - CORDER):
    problems.append(f"Controllers/{orphan}.luau exists but is not in the client boot ORDER")

# ── 9. house rules ───────────────────────────────────────────────────────
for rel, text in walk(""):
    if not text.lstrip().startswith("--!strict"):
        problems.append(f"{rel}: missing --!strict")
    for marker in ("TODO", "FIXME", "XXX"):
        if marker in strip_comments(text) or marker in text:
            problems.append(f"{rel}: contains a {marker}")

# ── report ───────────────────────────────────────────────────────────────
for note in notes:
    print(f"  note: {note}")
if problems:
    print()
    for problem in problems:
        print(f"  FAIL: {problem}")
    print(f"\n{len(problems)} contract violation(s)")
    sys.exit(1)
print("\ncontract: clean")
