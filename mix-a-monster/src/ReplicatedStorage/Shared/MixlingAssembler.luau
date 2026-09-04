--!strict
--[[
	MixlingAssembler.luau — GDD §7.1, the content engine.

	A Mixling is never a hand-made model:

		Mixling = CritterBody(critter) + StuffProp(stuff) on a named Attachment
		        + RarityFX(rarity) + Sound(voice, layer, rarity pitch)

	Used by the server to build world models and by the client to preview
	results in a ViewportFrame, so it must be realm-agnostic and side-effect
	free apart from the Instances it returns.

	ASSETS ARE OPTIONAL. If ReplicatedStorage/Assets/Critters/<Name> or
	Assets/Stuff/<Name> exists it is cloned; otherwise a deterministic
	procedural placeholder is generated from the ingredient's name and colour,
	so the game is playable and testable before a single mesh is imported.
	Swapping in real art later changes nothing but the look.

	Every returned model is fully welded to its PrimaryPart and unanchored, so
	a caller can either anchor the PrimaryPart (pedestal) or weld it to a
	character (carry) without touching the internals.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Config = ReplicatedStorage:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Config:WaitForChild("Constants"))
local Ingredients = require(Config:WaitForChild("Ingredients"))
local Rarity = require(Config:WaitForChild("Rarity"))
local Util = require(Shared:WaitForChild("Util"))

local Assembler = {}

export type BuildSpec = {
	critter: string,
	stuff: string,
	rarity: number,
	secretId: string?,
	secretName: string?,
	withSound: boolean?,
	lowFx: boolean?,
}

local ATTACHMENTS = { "Head", "Back", "Hand" }

-- ── Deterministic per-ingredient variation ───────────────────────────────
-- Placeholder bodies must be told apart at a glance. A stable hash of the
-- name drives silhouette choices so "Frog" always looks like Frog.

local function hash(text: string): number
	local h = 5381
	for index = 1, #text do
		h = (h * 33 + string.byte(text, index)) % 2147483647
	end
	return h
end

local function variant(seed: number, index: number, count: number): number
	return (math.floor(seed / (7 ^ index)) % count) + 1
end

-- ── Asset lookup ─────────────────────────────────────────────────────────

local function assetsFolder(): Instance?
	return ReplicatedStorage:FindFirstChild("Assets")
end

local function findAsset(category: string, name: string): Model?
	local assets = assetsFolder()
	if not assets then
		return nil
	end
	local folder = assets:FindFirstChild(category)
	if not folder then
		return nil
	end
	local found = folder:FindFirstChild(name)
	return if found and found:IsA("Model") then found else nil
end

local function findSound(category: string, name: string): Sound?
	local assets = assetsFolder()
	if not assets then
		return nil
	end
	local sounds = assets:FindFirstChild("Sounds")
	if not sounds then
		return nil
	end
	local folder = sounds:FindFirstChild(category)
	if not folder then
		return nil
	end
	local found = folder:FindFirstChild(name)
	return if found and found:IsA("Sound") then found else nil
end

-- ── Primitive helpers ────────────────────────────────────────────────────

local function part(name: string, size: Vector3, color: Color3, shape: Enum.PartType?): Part
	local instance = Instance.new("Part")
	instance.Name = name
	instance.Size = size
	instance.Color = color
	instance.Shape = shape or Enum.PartType.Block
	instance.Anchored = false
	instance.CanCollide = false
	instance.CanQuery = false
	instance.CanTouch = false
	instance.Massless = true
	instance.TopSurface = Enum.SurfaceType.Smooth
	instance.BottomSurface = Enum.SurfaceType.Smooth
	return instance
end

local function attachment(parent: BasePart, name: string, offset: Vector3): Attachment
	local point = Instance.new("Attachment")
	point.Name = name
	point.Position = offset
	point.Parent = parent
	return point
end

-- ── CritterBody ──────────────────────────────────────────────────────────

local function buildProceduralCritter(name: string, color: Color3): Model
	local seed = hash(name)
	local model = Instance.new("Model")
	model.Name = name

	local bodyShape = variant(seed, 1, 3)
	local bodyHeight = 1.6 + (variant(seed, 2, 4) - 1) * 0.35
	local bodyWidth = 1.5 + (variant(seed, 3, 3) - 1) * 0.3

	local body = part("Body", Vector3.new(bodyWidth, bodyHeight, bodyWidth * 1.1), color, if bodyShape == 1 then Enum.PartType.Ball else Enum.PartType.Block)
	body.Parent = model
	model.PrimaryPart = body

	local headSize = 0.75 + (variant(seed, 4, 4) - 1) * 0.22
	local head = part("HeadPart", Vector3.new(headSize, headSize, headSize) * 1.25, color:Lerp(Color3.new(1, 1, 1), 0.15), Enum.PartType.Ball)
	head.CFrame = body.CFrame * CFrame.new(0, bodyHeight * 0.62 + headSize * 0.45, 0)
	head.Parent = model

	-- Eyes read as "alive" for almost no cost and make every placeholder
	-- immediately legible as a creature.
	for side = -1, 1, 2 do
		local eye = part("Eye", Vector3.new(0.22, 0.22, 0.1), Color3.fromRGB(20, 20, 26), Enum.PartType.Ball)
		eye.CFrame = head.CFrame * CFrame.new(side * headSize * 0.34, headSize * 0.12, -headSize * 0.62)
		eye.Parent = model
	end

	local legCount = if variant(seed, 5, 2) == 1 then 2 else 4
	local legLength = 0.4 + (variant(seed, 6, 3) - 1) * 0.3
	for index = 1, legCount do
		local across = if index % 2 == 1 then -1 else 1
		local along = if index <= 2 then -1 else 1
		local leg = part("Leg", Vector3.new(0.28, legLength, 0.28), color:Lerp(Color3.new(0, 0, 0), 0.25))
		leg.CFrame = body.CFrame
			* CFrame.new(across * bodyWidth * 0.3, -bodyHeight * 0.5 - legLength * 0.5, (if legCount == 4 then along else 0) * bodyWidth * 0.3)
		leg.Parent = model
	end

	-- Ears / fin / antenna: the third silhouette cue.
	local topper = variant(seed, 7, 3)
	if topper == 1 then
		for side = -1, 1, 2 do
			local ear = part("Ear", Vector3.new(0.2, 0.5, 0.2), color:Lerp(Color3.new(1, 1, 1), 0.1))
			ear.CFrame = head.CFrame * CFrame.new(side * headSize * 0.4, headSize * 0.6, 0)
			ear.Parent = model
		end
	elseif topper == 2 then
		local fin = part("Fin", Vector3.new(0.16, 0.7, 0.5), color:Lerp(Color3.new(0, 0, 0), 0.15))
		fin.CFrame = body.CFrame * CFrame.new(0, bodyHeight * 0.55, 0)
		fin.Parent = model
	end

	attachment(body, "Back", Vector3.new(0, bodyHeight * 0.1, bodyWidth * 0.6))
	attachment(body, "Hand", Vector3.new(bodyWidth * 0.7, 0, 0))
	attachment(head, "Head", Vector3.new(0, headSize * 0.7, 0))
	return model
end

-- ── StuffProp ────────────────────────────────────────────────────────────

local function buildProceduralStuff(name: string, color: Color3): Model
	local seed = hash(name)
	local model = Instance.new("Model")
	model.Name = name

	local shape = variant(seed, 1, 3)
	local width = 0.55 + (variant(seed, 2, 3) - 1) * 0.18
	local height = 0.5 + (variant(seed, 3, 4) - 1) * 0.18

	local core = part(
		"Prop",
		Vector3.new(width, height, width * 0.9),
		color,
		if shape == 1 then Enum.PartType.Ball elseif shape == 2 then Enum.PartType.Cylinder else Enum.PartType.Block
	)
	core.Parent = model
	model.PrimaryPart = core

	local detail = part("Detail", Vector3.new(width * 0.6, height * 0.28, width * 0.6), color:Lerp(Color3.new(0, 0, 0), 0.35))
	detail.CFrame = core.CFrame * CFrame.new(0, height * 0.5, 0)
	detail.Parent = model
	return model
end

-- ── Welding ──────────────────────────────────────────────────────────────

local function weldTo(model: Model, root: BasePart)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= root then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.Massless = true
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = descendant
			weld.Parent = root
		end
	end
end

-- ── Rarity FX ────────────────────────────────────────────────────────────

local function applyRarityFx(model: Model, tier: number, lowFx: boolean)
	local fx = Rarity.fx(tier)
	local color = Rarity.color(tier)

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			if tier >= Constants.RARITY_RARE then
				descendant.Material = fx.material
			end
			if tier >= Constants.RARITY_LEGENDARY then
				descendant.Color = descendant.Color:Lerp(color, 0.45)
			elseif tier >= Constants.RARITY_RARE then
				descendant.Color = descendant.Color:Lerp(color, 0.18)
			end
		end
	end

	local root = model.PrimaryPart
	if not root then
		return
	end

	if fx.glow > 0 and not lowFx then
		local light = Instance.new("PointLight")
		light.Name = "RarityGlow"
		light.Color = color
		light.Brightness = fx.glow * 3
		light.Range = 8 + fx.glow * 8
		light.Shadows = false
		light.Parent = root
	end

	if fx.particles ~= "None" and not lowFx then
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "RarityParticles"
		emitter.Color = ColorSequence.new(color)
		emitter.LightEmission = 0.8
		emitter.Lifetime = NumberRange.new(0.5, 1.1)
		emitter.Speed = NumberRange.new(0.4, 1.4)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Size = NumberSequence.new(0.35)
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.15),
			NumberSequenceKeypoint.new(1, 1),
		})

		if fx.particles == "Glitch" then
			emitter.Rate = 14
			emitter.Lifetime = NumberRange.new(0.12, 0.3)
			emitter.Size = NumberSequence.new(0.6)
		elseif fx.particles == "Sparkle" then
			emitter.Rate = 18
		else -- Cosmic
			emitter.Rate = 26
			emitter.Speed = NumberRange.new(0.1, 0.4)
			emitter.Acceleration = Vector3.new(0, 1.2, 0)
		end
		emitter.Parent = root
	end
end

--[[
	Every Mixling sound is routed through one SoundGroup so a client can silence
	them all at once.

	This matters because the idle chirps on pedestals are played by the SERVER
	(GDD §18 requires that throttle to be server-side), and a server-played
	Sound is not the client's to stop. Muting a SoundGroup, on the other hand,
	is a purely local property change: it silences the chirps for the player who
	turned sfx off and for nobody else.

	The server creates the group; the client only ever finds it.
]]
Assembler.SOUND_GROUP = "MixlingSFX"

local function soundGroup(): SoundGroup?
	local existing = SoundService:FindFirstChild(Assembler.SOUND_GROUP)
	if existing and existing:IsA("SoundGroup") then
		return existing
	end
	if not RunService:IsServer() then
		return nil -- the client waits for replication rather than making a second one
	end
	local group = Instance.new("SoundGroup")
	group.Name = Assembler.SOUND_GROUP
	group.Volume = 1
	group.Parent = SoundService
	return group
end

Assembler.soundGroup = soundGroup

-- ── Sound (GDD §7.5) ─────────────────────────────────────────────────────
-- voice + layer played together, rarity applying PlaybackSpeed and a reverb
-- preset. Sounds live under the model so any consumer can play them.

function Assembler.buildSound(parent: BasePart, critter: string, stuff: string, tier: number): Folder
	local folder = Instance.new("Folder")
	folder.Name = "MixSound"

	local fx = Rarity.fx(tier)
	local critterDef = Ingredients.get(critter)
	local stuffDef = Ingredients.get(stuff)

	local voiceTemplate = if critterDef and critterDef.voice then findSound("Voices", critterDef.voice) else nil
	local layerTemplate = if stuffDef and stuffDef.layer then findSound("Layers", stuffDef.layer) else nil

	local function make(name: string, template: Sound?): Sound
		local sound = if template then template:Clone() else Instance.new("Sound")
		sound.Name = name
		sound.PlaybackSpeed = fx.pitch
		sound.RollOffMaxDistance = 60
		sound.RollOffMode = Enum.RollOffMode.InverseTapered
		sound.Volume = if template then sound.Volume else 0.5
		sound.SoundGroup = soundGroup()
		sound.Parent = folder
		return sound
	end

	local voice = make("Voice", voiceTemplate)
	make("Layer", layerTemplate)

	if tier >= Constants.RARITY_EPIC then
		local reverb = Instance.new("ReverbSoundEffect")
		reverb.DecayTime = 1.2 + (tier - Constants.RARITY_EPIC) * 0.6
		reverb.WetLevel = -6
		reverb.Parent = voice
	end

	folder.Parent = parent
	return folder
end

-- Guarantees a rooted model. A missing or malformed asset must degrade to a
-- visible blob, never crash the Den it was about to be placed in.
local function resolveRoot(model: Model): BasePart
	local existing = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if existing then
		return existing
	end
	local fallback = part("Body", Vector3.new(1.5, 1.6, 1.6), Color3.fromRGB(160, 160, 170), Enum.PartType.Ball)
	fallback.Parent = model
	return fallback
end

-- ── Assembly ─────────────────────────────────────────────────────────────

function Assembler.displayName(spec: BuildSpec): string
	if spec.secretName then
		return spec.secretName
	end
	return Rarity.displayName(spec.rarity, spec.critter, spec.stuff)
end

--[[
	Builds the model. The caller owns the result: nothing is parented to the
	world here.
]]
function Assembler.build(spec: BuildSpec): Model
	local critterDef = Ingredients.get(spec.critter)
	local stuffDef = Ingredients.get(spec.stuff)

	-- Secret Mixlings are hand-modelled (GDD §7.4) and bypass assembly, but
	-- fall through to the procedural path when the art has not landed yet.
	local secretAsset = if spec.secretId then findAsset("Secrets", spec.secretId) else nil

	local body: Model
	if secretAsset then
		body = secretAsset:Clone()
	else
		local template = findAsset("Critters", spec.critter)
		if template then
			body = template:Clone()
		else
			body = buildProceduralCritter(spec.critter, if critterDef then critterDef.color else Color3.fromRGB(160, 160, 170))
		end
	end

	local root = resolveRoot(body)
	body.PrimaryPart = root
	root.Anchored = false
	root.CanCollide = false

	if not secretAsset then
		local propTemplate = findAsset("Stuff", spec.stuff)
		local prop: Model = if propTemplate
			then propTemplate:Clone()
			else buildProceduralStuff(spec.stuff, if stuffDef then stuffDef.color else Color3.fromRGB(200, 200, 210))

		local propRoot: BasePart? = prop.PrimaryPart or prop:FindFirstChildWhichIsA("BasePart", true)
		if propRoot ~= nil then
			local propBase: BasePart = propRoot
			prop.PrimaryPart = propBase
			local wanted = (stuffDef and stuffDef.attach) or "Head"
			if not table.find(ATTACHMENTS, wanted) then
				wanted = "Head"
			end

			local point = body:FindFirstChild(wanted, true)
			local anchorPoint = if point and point:IsA("Attachment") then point else nil
			local pivot = if anchorPoint then anchorPoint.WorldCFrame else root.CFrame * CFrame.new(0, 1.2, 0)

			local scale = (stuffDef and stuffDef.scale) or 1
			for _, descendant in prop:GetDescendants() do
				if descendant:IsA("BasePart") then
					descendant.Size *= scale
				end
			end
			prop:PivotTo(pivot * CFrame.new(0, propBase.Size.Y * 0.4, 0))

			for _, child in prop:GetChildren() do
				child.Parent = body
			end
			prop:Destroy()
		else
			prop:Destroy()
		end
	end

	applyRarityFx(body, spec.rarity, spec.lowFx == true)

	local fx = Rarity.fx(spec.rarity)
	if fx.scale ~= 1 then
		for _, descendant in body:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Size *= fx.scale
			end
		end
	end

	weldTo(body, root)

	if spec.withSound then
		Assembler.buildSound(root, spec.critter, spec.stuff, spec.rarity)
	end

	body.Name = Assembler.displayName(spec)
	Util.create("IntValue", { Name = "RarityTier", Value = spec.rarity, Parent = body })

	-- The ingredient pair is stamped on ordinary Mixlings because it is already
	-- public — the model is literally named "Golden Toaster Frog". It is NOT
	-- stamped on a Secret: a Secret's pair IS the recipe, and a model sitting on
	-- a pedestal in workspace is readable by every client in the server. Leaving
	-- these on would hand the recipe table out one placement at a time
	-- (GDD §11.3: "Secret recipes never replicate to the client").
	if not spec.secretId then
		Util.create("StringValue", { Name = "Critter", Value = spec.critter, Parent = body })
		Util.create("StringValue", { Name = "Stuff", Value = spec.stuff, Parent = body })
	end
	return body
end

--[[
	The wire shape. A `Types.Mixling` is what a PROFILE stores; a
	`Types.MixlingView` is what the CLIENT is sent, and it carries the display
	name and the rate so a Mixling reads identically on a reveal card, a
	pedestal plaque and a Den list without the client deriving anything.

	This lives here, in the one module both realms already share, because the
	conversion was previously hand-rolled in three services — and the moment one
	of them pushed a raw profile row onto a `mixlings` wire key instead, the
	client cached rows with no `displayName` and every screen reading it threw.
	One implementation is the fix; there is no second place for it to drift.

	`secretName` is passed in rather than looked up: this module is shared, and
	resolving it would mean reading the server-only recipe table from a file the
	client requires (GDD §11.3).
]]
function Assembler.toView(mixling: {
	id: string,
	critter: string,
	stuff: string,
	rarity: number,
	secretId: string?,
	bound: boolean?,
}, secretName: string?)
	return {
		id = mixling.id,
		critter = mixling.critter,
		stuff = mixling.stuff,
		rarity = mixling.rarity,
		secretId = mixling.secretId,
		secretName = secretName,
		bound = mixling.bound,
		displayName = Assembler.displayName({
			critter = mixling.critter,
			stuff = mixling.stuff,
			rarity = mixling.rarity,
			secretId = mixling.secretId,
			secretName = secretName,
		}),
		goopPerSec = Rarity.goopPerSec(mixling.rarity),
	}
end

--[[
	A display copy for pedestals and result cards: anchored, non-colliding,
	slowly spinning is left to the caller.
]]
function Assembler.buildDisplay(spec: BuildSpec, pivot: CFrame): Model
	local model = Assembler.build(spec)
	model:PivotTo(pivot)
	local root = model.PrimaryPart
	if root then
		root.Anchored = true
	end
	return model
end

return Assembler
