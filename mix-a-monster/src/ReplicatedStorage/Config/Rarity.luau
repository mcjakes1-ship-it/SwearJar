--!strict
--[[
	Rarity.luau — read helpers over Constants.RARITY (GDD §7.3).

	Systems ask this module questions ("what does tier 5 pay?") instead of
	indexing the constants table directly, so a change to the tier shape is a
	one-file change.
]]

local Constants = require(script.Parent.Constants)

local Rarity = {}

Rarity.Tiers = Constants.RARITY
Rarity.COMMON = Constants.RARITY_COMMON
Rarity.UNCOMMON = Constants.RARITY_UNCOMMON
Rarity.RARE = Constants.RARITY_RARE
Rarity.EPIC = Constants.RARITY_EPIC
Rarity.LEGENDARY = Constants.RARITY_LEGENDARY
Rarity.MYTHIC = Constants.RARITY_MYTHIC
Rarity.SECRET = Constants.RARITY_SECRET
Rarity.ROLLABLE_MAX = Constants.RARITY_ROLLABLE_MAX

local function clampTier(tier: number): number
	if tier ~= tier or tier < 1 then -- NaN or under-range
		return 1
	end
	if tier > #Constants.RARITY then
		return #Constants.RARITY
	end
	return math.floor(tier)
end

Rarity.clamp = clampTier

function Rarity.get(tier: number)
	return Constants.RARITY[clampTier(tier)]
end

function Rarity.name(tier: number): string
	return Rarity.get(tier).name
end

function Rarity.prefix(tier: number): string
	return Rarity.get(tier).prefix
end

function Rarity.color(tier: number): Color3
	return Rarity.get(tier).color
end

function Rarity.goopPerSec(tier: number): number
	return Rarity.get(tier).goopPerSec
end

function Rarity.holdTime(tier: number): number
	return Rarity.get(tier).holdTime
end

function Rarity.announceScope(tier: number): string
	return Rarity.get(tier).announce
end

function Rarity.fx(tier: number)
	return Constants.RARITY_FX[clampTier(tier)] or Constants.RARITY_FX[1]
end

-- "{Prefix} {Stuff} {Critter}" (GDD §7.1). Common has no prefix.
function Rarity.displayName(tier: number, critter: string, stuff: string): string
	local prefix = Rarity.prefix(tier)
	if prefix == "" then
		return stuff .. " " .. critter
	end
	return prefix .. " " .. stuff .. " " .. critter
end

--[[
	Weighted roll over rollable tiers 1..6 (GDD §8.1).
	eff[t] = baseWeight[t] * (1 + L * luckMult[t])

	`rng` must be a Random the caller owns; the server seeds one per server so
	rolls are never client-influenced (GDD §11.3).
]]
function Rarity.roll(rng: Random, luck: number): number
	local total = 0
	local effective = table.create(Rarity.ROLLABLE_MAX)
	for tier = 1, Rarity.ROLLABLE_MAX do
		local def = Constants.RARITY[tier]
		local weight = def.weight * (1 + luck * def.luckMult)
		effective[tier] = weight
		total += weight
	end

	if total <= 0 then
		return Rarity.COMMON
	end

	local pick = rng:NextNumber() * total
	local cursor = 0
	for tier = 1, Rarity.ROLLABLE_MAX do
		cursor += effective[tier]
		if pick <= cursor then
			return tier
		end
	end
	return Rarity.COMMON
end

-- Exposed for balance tooling and the odds panel: probability of each tier at
-- a given luck value. Returns a 6-entry array summing to 1.
function Rarity.odds(luck: number): { number }
	local total = 0
	local effective = table.create(Rarity.ROLLABLE_MAX)
	for tier = 1, Rarity.ROLLABLE_MAX do
		local def = Constants.RARITY[tier]
		local weight = def.weight * (1 + luck * def.luckMult)
		effective[tier] = weight
		total += weight
	end
	for tier = 1, Rarity.ROLLABLE_MAX do
		effective[tier] = if total > 0 then effective[tier] / total else 0
	end
	return effective
end

-- RarestScore for the leaderboard (GDD §8.7): rarity * 1000 + goop/sec.
function Rarity.score(tier: number): number
	return clampTier(tier) * 1000 + Rarity.goopPerSec(tier)
end

return Rarity
