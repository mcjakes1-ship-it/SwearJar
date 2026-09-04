--!strict
--[[
	Ingredients.luau — the launch ingredient tables (GDD §7.2).

	16 Critters x 16 Stuff = 256 base Mixlings. Adding one row here adds 16
	new Mixlings; this is the content engine described in GDD §7.1.

	`attach` on a Stuff item names the CritterBody attachment the prop prefers
	("Head", "Back", "Hand"); `scale` is a hint multiplier applied by the
	MixlingAssembler. `color` is the fallback tint used when no Studio asset
	with a matching name exists under ReplicatedStorage/Assets.
]]

export type Ingredient = {
	name: string,
	kind: "Critter" | "Stuff",
	tier: number,
	price: number,
	luck: number,
	starter: boolean?,
	attach: string?,
	scale: number?,
	color: Color3,
	voice: string?, -- Critter: sound asset name under Assets/Sounds/Voices
	layer: string?, -- Stuff: sound asset name under Assets/Sounds/Layers
}

local function critter(name: string, tier: number, price: number, luck: number, r: number, g: number, b: number, starter: boolean?): Ingredient
	return {
		name = name,
		kind = "Critter",
		tier = tier,
		price = price,
		luck = luck,
		starter = starter,
		color = Color3.fromRGB(r, g, b),
		voice = "Voice_" .. name,
	}
end

local function stuff(name: string, tier: number, price: number, luck: number, attach: string, scale: number, r: number, g: number, b: number, starter: boolean?): Ingredient
	return {
		name = name,
		kind = "Stuff",
		tier = tier,
		price = price,
		luck = luck,
		starter = starter,
		attach = attach,
		scale = scale,
		color = Color3.fromRGB(r, g, b),
		layer = "Layer_" .. name,
	}
end

local Ingredients = {}

-- ── Critters ─────────────────────────────────────────────────────────────
Ingredients.Critters = {
	-- T1
	critter("Frog", 1, 0, 0, 108, 194, 74, true),
	critter("Chicken", 1, 25, 0, 245, 240, 226),
	critter("Snail", 1, 40, 0, 196, 158, 112),
	critter("Worm", 1, 40, 0, 236, 146, 160),
	-- T2
	critter("Cat", 2, 120, 1, 232, 168, 78),
	critter("Goat", 2, 150, 1, 224, 220, 208),
	critter("Pigeon", 2, 150, 1, 138, 152, 178),
	critter("Raccoon", 2, 200, 1, 118, 122, 132),
	-- T3
	critter("Shark", 3, 600, 2, 92, 140, 182),
	critter("Penguin", 3, 650, 2, 48, 54, 66),
	critter("Sloth", 3, 700, 2, 150, 126, 100),
	critter("Bat", 3, 800, 2, 84, 62, 104),
	-- T4
	critter("Octopus", 4, 2500, 4, 196, 92, 168),
	critter("Llama", 4, 2800, 4, 226, 200, 160),
	critter("Axolotl", 4, 3200, 4, 250, 158, 196),
	-- T5
	critter("Capybara", 5, 12000, 6, 158, 116, 78),
}

-- ── Stuff ────────────────────────────────────────────────────────────────
Ingredients.Stuff = {
	-- T1
	stuff("Sock", 1, 0, 0, "Head", 1.0, 236, 236, 226, true),
	stuff("Traffic Cone", 1, 25, 0, "Head", 1.0, 244, 120, 42),
	stuff("Rubber Duck", 1, 40, 0, "Head", 0.8, 252, 216, 62),
	stuff("Umbrella", 1, 40, 0, "Back", 1.2, 208, 72, 88),
	-- T2
	stuff("Toaster", 2, 120, 1, "Head", 1.1, 202, 206, 212),
	stuff("Sneaker", 2, 150, 1, "Head", 1.0, 240, 244, 248),
	stuff("Pizza", 2, 150, 1, "Head", 1.0, 236, 176, 84),
	stuff("Skateboard", 2, 200, 1, "Back", 1.2, 96, 88, 108),
	-- T3
	stuff("Cactus", 3, 600, 2, "Back", 1.1, 96, 168, 96),
	stuff("Microwave", 3, 650, 2, "Back", 1.2, 188, 192, 198),
	stuff("Lava Lamp", 3, 700, 2, "Head", 1.0, 224, 92, 168),
	stuff("Fire Hydrant", 3, 800, 2, "Back", 1.1, 220, 62, 62),
	-- T4
	stuff("Boombox", 4, 2500, 4, "Hand", 1.1, 44, 44, 52),
	stuff("Rocket", 4, 2800, 4, "Back", 1.3, 232, 232, 236),
	stuff("Disco Ball", 4, 3200, 4, "Head", 1.0, 198, 206, 226),
	-- T5
	stuff("Crown", 5, 12000, 6, "Head", 0.9, 255, 206, 64),
}

-- ── Indexes ──────────────────────────────────────────────────────────────
local byName: { [string]: Ingredient } = {}
for _, list in { Ingredients.Critters, Ingredients.Stuff } do
	for _, item in list do
		byName[item.name] = item
	end
end
Ingredients.ByName = byName

function Ingredients.get(name: string): Ingredient?
	return byName[name]
end

function Ingredients.isCritter(name: string): boolean
	local item = byName[name]
	return item ~= nil and item.kind == "Critter"
end

function Ingredients.isStuff(name: string): boolean
	local item = byName[name]
	return item ~= nil and item.kind == "Stuff"
end

-- Total number of non-secret Mixdex entries (GDD §8.5).
function Ingredients.baseCombinationCount(): number
	return #Ingredients.Critters * #Ingredients.Stuff
end

-- Canonical Mixdex key. Ordered Stuff-first to match the display name
-- "{Prefix} {Stuff} {Critter}" (GDD §7.1).
function Ingredients.key(critter: string, stuffName: string): string
	return stuffName .. ":" .. critter
end

return Ingredients
