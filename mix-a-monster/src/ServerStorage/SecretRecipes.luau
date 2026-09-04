--!strict
--[[
	SecretRecipes.luau — THE REAL RECIPE TABLE. SERVER ONLY.

	GDD §7.4 / §11.3: secret recipes never replicate to the client. This file
	lives in ServerStorage and must never be required from, mirrored into, or
	summarised inside ReplicatedStorage. The client learns a recipe only by
	producing the result. The public side of this data is
	ReplicatedStorage/Config/SecretsPublic.luau, which carries the COUNT and
	nothing else.

	Launch set is 5 (GDD §7.4). Weekly Drops add one each (GDD §12).

	Note the decoy: Frog + Sock, the starter pair, is deliberately NOT a
	secret. Players will try it first; that is the point.
]]

export type Secret = {
	id: string,
	name: string,
	critter: string,
	stuff: string,
	-- Line shown in the global DISCOVERED feed. "%s" is the player's name.
	feed: string,
}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Ingredients = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("Ingredients"))

local list: { Secret } = {
	{ id = "KingBara", name = "KING BARA", critter = "Capybara", stuff = "Crown", feed = "%s discovered KING BARA" },
	{ id = "Sharkpedo", name = "SHARKPEDO", critter = "Shark", stuff = "Rocket", feed = "%s discovered SHARKPEDO" },
	{ id = "DJWhiskerz", name = "DJ WHISKERZ", critter = "Cat", stuff = "Disco Ball", feed = "%s discovered DJ WHISKERZ" },
	{ id = "SlothyTony", name = "SLOTHY TONY", critter = "Sloth", stuff = "Skateboard", feed = "%s discovered SLOTHY TONY" },
	{ id = "MCWormz", name = "MC WORMZ", critter = "Worm", stuff = "Boombox", feed = "%s discovered MC WORMZ" },
}

local SecretRecipes = {}
SecretRecipes.List = list

local byKey: { [string]: Secret } = {}
local byId: { [string]: Secret } = {}
for _, secret in list do
	byKey[Ingredients.key(secret.critter, secret.stuff)] = secret
	byId[secret.id] = secret
end

--[[
	The only lookup MixerService performs. Returns nil for every ordinary
	pair, which is the overwhelmingly common case.
]]
function SecretRecipes.match(critter: string, stuff: string): Secret?
	return byKey[Ingredients.key(critter, stuff)]
end

function SecretRecipes.byId(id: string): Secret?
	return byId[id]
end

function SecretRecipes.count(): number
	return #list
end

--[[
	Sanity guard run at boot: a recipe naming an ingredient that no longer
	ships is unreachable, and would silently reduce the discoverable count the
	Mixdex advertises.
]]
function SecretRecipes.validate(): { string }
	local problems = {}
	for _, secret in list do
		if not Ingredients.isCritter(secret.critter) then
			table.insert(problems, ("secret %s names unknown critter %q"):format(secret.id, secret.critter))
		end
		if not Ingredients.isStuff(secret.stuff) then
			table.insert(problems, ("secret %s names unknown stuff %q"):format(secret.id, secret.stuff))
		end
	end
	return problems
end

return SecretRecipes
