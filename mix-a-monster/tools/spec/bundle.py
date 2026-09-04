#!/usr/bin/env python3
"""Bundle the realm-agnostic Config/Shared modules into one Luau script that
the standalone `luau` interpreter can run, so their behaviour can be tested
without Studio.

Roblox resolves requires through Instances (`require(ReplicatedStorage
:WaitForChild("Config"):WaitForChild("Constants"))`). The standalone
interpreter has no DataModel, so this rewrites each of those into a lookup in a
module table and concatenates the modules in dependency order, in front of a
small shim for the Roblox globals the pure modules touch (Color3, Vector3,
Enum, task, os.clock).

Only modules whose behaviour does not depend on the DataModel are bundled.
Anything that builds Instances (MixlingAssembler, UiKit) or talks to a service
(Net, every Service) is out of scope here and is covered by the Studio test
protocol in README.md instead.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# name -> path, in dependency order.
MODULES = [
    ("Constants", "src/ReplicatedStorage/Config/Constants.luau"),
    ("Ingredients", "src/ReplicatedStorage/Config/Ingredients.luau"),
    ("Rarity", "src/ReplicatedStorage/Config/Rarity.luau"),
    ("SecretsPublic", "src/ReplicatedStorage/Config/SecretsPublic.luau"),
    ("Util", "src/ReplicatedStorage/Shared/Util.luau"),
    ("Types", "src/ReplicatedStorage/Shared/Types.luau"),
    ("SecretRecipes", "src/ServerStorage/SecretRecipes.luau"),
]

SHIM = r'''
-- ── Roblox shim ──────────────────────────────────────────────────────────
-- Just enough of the API surface for the pure modules. These are LOCALS, not
-- globals: the standalone interpreter freezes the global table, and the module
-- bodies below are closures over this scope, so upvalues work where
-- assignment would not.
--
-- Anything a module reaches for that is not here fails loudly, which is the
-- point: it means the module is not realm-agnostic and does not belong in the
-- MODULES list.

local Color3 = {}
Color3.__index = Color3
function Color3.new(r, g, b)
	return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, Color3)
end
function Color3.fromRGB(r, g, b)
	return Color3.new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
end
function Color3:Lerp(other, alpha)
	return Color3.new(
		self.R + (other.R - self.R) * alpha,
		self.G + (other.G - self.G) * alpha,
		self.B + (other.B - self.B) * alpha
	)
end

local Vector3 = {}
Vector3.__index = Vector3
function Vector3.new(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3)
end

local Vector2 = { new = function(x, y) return { X = x, Y = y } end }
local NumberRange = { new = function(a, b) return { Min = a, Max = b or a } end }

local function enumItem(parent, name)
	return setmetatable({ Name = name, EnumType = parent }, {
		__tostring = function() return "Enum." .. parent .. "." .. name end,
	})
end
local Enum = setmetatable({}, {
	__index = function(_, enumName)
		return setmetatable({}, {
			__index = function(_, itemName) return enumItem(enumName, itemName) end,
		})
	end,
})

local task = {
	wait = function() return 0 end,
	spawn = function(fn, ...) fn(...) end,
	defer = function(fn, ...) fn(...) end,
	delay = function(_, fn, ...) fn(...) end,
}

-- A deterministic stand-in for Roblox's Random, delegating to Luau's own
-- math.random (a PCG) rather than a hand-rolled LCG — the odds test compares a
-- 200k-sample histogram against the analytic distribution, and a weak
-- generator fails that on its own bias rather than on any bug in Rarity.roll.
--
-- Instances share math.random's global state, so determinism here comes from
-- seeding once at the start of a run, not from per-instance independence.
-- That is enough for a test suite and would not be enough for a game.
local Random = {}
Random.__index = Random
function Random.new(seed)
	if seed then
		math.randomseed(seed)
	end
	return setmetatable({}, Random)
end
function Random:NextNumber(minimum, maximum)
	if minimum == nil then
		return math.random()
	end
	return minimum + math.random() * ((maximum or 1) - minimum)
end
function Random:NextInteger(minimum, maximum)
	return math.random(minimum, maximum)
end

local game = {
	GetService = function(_, name)
		error("spec bundle: a bundled module called game:GetService(" .. name .. "); "
			.. "it is not realm-agnostic and must not be in MODULES", 2)
	end,
	JobId = "spec",
}
'''

FOOTER = r'''
_MODULES._shim = {
	Color3 = Color3,
	Vector3 = Vector3,
	Vector2 = Vector2,
	NumberRange = NumberRange,
	Enum = Enum,
	Random = Random,
	task = task,
}
'''



def rewrite(source, name):
    """Turn Roblox instance requires into module-table lookups."""
    # require(A:WaitForChild("Config"):WaitForChild("Name")) — greedy so the
    # LAST WaitForChild in the chain is the module being required.
    source = re.sub(
        r'require\(.*WaitForChild\("(\w+)"\)\s*\)', r"_MODULES.\1", source)
    source = re.sub(
        r'require\(script\.Parent\.(\w+)\)', r"_MODULES.\1", source)
    # Service lookups that only exist to reach a module.
    source = re.sub(
        r'local \w+ = game:GetService\("(ReplicatedStorage|ServerStorage)"\)\n', "", source)
    source = re.sub(
        r'local \w+ = \w+:WaitForChild\("(Config|Shared)"\)\n', "", source)
    if "GetService" in source:
        sys.exit(f"bundle.py: {name} still calls GetService after rewriting; "
                 "it is not realm-agnostic")
    return source


def main():
    out = ["--!nonstrict", "-- GENERATED by tools/spec/bundle.py — do not edit.", SHIM,
           "local _MODULES = {}"]
    for name, path in MODULES:
        with open(os.path.join(ROOT, path)) as handle:
            body = rewrite(handle.read(), name)
        body = body.replace("--!strict", "").replace("--!nonstrict", "")
        out.append(f"\n-- ═══ {name} ({path}) ═══")
        out.append(f"_MODULES.{name} = (function()\n{body}\nend)()")
    out.append(FOOTER)
    out.append("return _MODULES")
    target = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "tools/spec/bundle.luau")
    with open(target, "w") as handle:
        handle.write("\n".join(out))
    print(target, file=sys.stderr)


if __name__ == "__main__":
    main()
