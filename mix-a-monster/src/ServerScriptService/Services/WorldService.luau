--!strict
--[[
	WorldService.luau — Blendburg, generated from Parts at boot. GDD §6.

	OWNS every stud of static geometry in the place: the floating island, the
	Mixer and its interaction pads, the Den ring shells, the two shops, the
	Mixdex kiosk, the leaderboard wall, the Junk Cliffs barrier, and the
	Lighting rig. Nothing else may parent world geometry at boot.

	THE CONTRACT OTHER SERVICES RELY ON:
	  getPlazaCenter()            -> Vector3
	  getMixerPads()              -> { BasePart }   stable order, pad 1..N
	  getDenAnchor(slotIndex)     -> CFrame         den centre, facing the plaza
	  getDenFolder(slotIndex)     -> Folder         "Den1".."DenN"
	  getSpawnFor(slotIndex)      -> CFrame         just inside that Den's door
	  getShopAnchor(kind)         -> CFrame         "Critter" | "Stuff" | "Mixdex"
	  getLeaderboardBoards()      -> { BasePart }   one per Constants.LEADERBOARDS

	WHAT IT DOES NOT OWN: anything that changes while the server runs. The
	pedestals and their prompts are DenService's — this file hands it an empty
	`Pedestals` folder per Den. The text on a Den sign and on a leaderboard
	board is written by DenService and LeaderboardService into labels created
	here (`Owner`, `Rate`, `Entries`), so those two services never have to
	know how a sign is built.

	WHY GENERATE INSTEAD OF SHIPPING A .rbxl: the model workload is the launch
	critical path (GDD §18) and code must never be blocked on art. A fresh
	clone of this repo is a playable town. When the art lands, a Model dropped
	at ReplicatedStorage/Assets/World/<Name> replaces that structure and
	nothing in this file changes — the same override pattern MixlingAssembler
	uses for Mixlings. See "Asset overrides" for the per-structure contract.

	NO SPAWNLOCATION IS CREATED, deliberately: "No lobby. Ever." (GDD §6).
	PlayerService spawns every player into their own Den via getSpawnFor.

	NOTHING MAY BLOCK THE WALK FROM A DEN TO THE MIXER (GDD §6). Every
	structure that stands between the Den ring and the plaza is placed on a
	`gapAngle` — the middle of the gap between two Dens — and the leaderboard
	panels hang above head height on two narrow pylons. That rule is why the
	town is laid out on angles instead of on a grid.

	MOBILE BUDGET. This is a phone game, so the whole town is ~180 Parts, all
	Anchored and SmoothPlastic, and decoration is CanCollide/CanQuery/CanTouch
	false so it costs nothing in physics, raycasts or touch. Where detail and
	draw calls fought, draw calls won; each of those trades is commented where
	it was made.
]]

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = ReplicatedStorage:WaitForChild("Config")
local Constants = require(Config:WaitForChild("Constants"))

local WorldService = {}
WorldService.Name = "WorldService"

local WORLD = Constants.WORLD
local ROOT_NAME = "Blendburg"

-- ── Art direction ────────────────────────────────────────────────────────
--[[
	Constants.WORLD owns every dimension a designer would re-tune (§17). What
	is left here is millwork — wall thickness, how far the spout sticks out,
	how high a sign hangs — plus the palette and the lighting rig. None of it
	is a balance value: moving any of it changes how Blendburg looks and
	nothing else, so it lives next to the code that draws it.

	Ratios are expressed against a Constants.WORLD dimension wherever one
	exists, so re-tuning PLAZA_RADIUS or DEN_SIZE re-proportions the town
	instead of breaking it.
]]
local SHAPE = {
	ISLAND_THICKNESS = 12,
	SCRAP_LAYERS = 4, -- stacked slabs under the island: it has to read as floating
	PLAZA_LIP = 0.5, -- the plaza disc and the paths are painted on, not stepped up
	WALL = 2, -- every wall and floor slab in town

	DEN_WALL_RATIO = 0.60, -- of DEN_SIZE.Y; short enough to see a Den's pedestals from the plaza
	DOOR_WIDTH_RATIO = 0.36, -- of DEN_SIZE.X; wide enough for a mobile stick to steer through
	DOOR_HEIGHT_RATIO = 0.62, -- of the wall height; the rest is the lintel the sign hangs on
	SIGN_DEPTH = 0.6,
	PATH_WIDTH = 14,
	SPAWN_INSET = 7, -- studs inside the doorway
	SPAWN_HEIGHT = 4, -- a spawn CFrame positions the HumanoidRootPart, not the feet

	MIXER_RADIUS_RATIO = 0.22, -- of PLAZA_RADIUS
	MIXER_HEIGHT_RATIO = 0.34,
	PAD_RING_RATIO = 0.45, -- §6: the pads ring the Mixer at PLAZA_RADIUS * 0.45
	PAD_DIAMETER = 10,
	PAD_THICKNESS = 0.6,

	SHOP_WIDTH_RATIO = 0.50, -- of PLAZA_RADIUS
	SHOP_DEPTH_RATIO = 0.30,
	SHOP_HEIGHT = 15,
	KIOSK_HEIGHT = 9,
	KIOSK_RING_RATIO = 0.86, -- of PLAZA_RADIUS: inside the plaza, outside the pad ring

	BOARD_SIZE = Vector3.new(22, 14, 1.2),
	BOARD_GAP = 2,
	BOARD_CLEARANCE = 8, -- panels start this high so players walk under the wall

	FENCE_HEIGHT = 13,
	FENCE_PANELS = 9,
	FENCE_ARC_DENS = 2, -- how many Den steps of fringe the barrier walls off

	VOID_DEPTH = 400, -- how far below the island a fallen player is caught
	SIGN_PIXELS = 26, -- SurfaceGui PixelsPerStud
	SIGN_DISTANCE = 320, -- MaxDistance: readable across the plaza, culled beyond it
}

local PALETTE = {
	GROUND = WORLD.GROUND_COLOR,
	PLAZA = Color3.fromRGB(255, 224, 158),
	SCRAP = Color3.fromRGB(92, 146, 172),
	SCRAP_DARK = Color3.fromRGB(66, 110, 134),
	MIXER_BODY = Color3.fromRGB(64, 160, 235),
	MIXER_TRIM = Color3.fromRGB(255, 92, 150),
	MIXER_LID = Color3.fromRGB(255, 196, 42),
	GOOP = Color3.fromRGB(146, 232, 96),
	METAL = Color3.fromRGB(196, 204, 214),
	FLOOR = Color3.fromRGB(240, 234, 222),
	SIGN = Color3.fromRGB(44, 52, 78),
	SIGN_TEXT = Color3.fromRGB(255, 255, 255),
	CRITTER = Color3.fromRGB(112, 214, 140),
	STUFF = Color3.fromRGB(176, 128, 240),
	KIOSK = Color3.fromRGB(72, 156, 255),
	BOARD = Color3.fromRGB(36, 42, 62),
	HAZARD = Color3.fromRGB(255, 168, 48),
	HAZARD_ALT = Color3.fromRGB(246, 246, 246),
}

-- ── Layout ───────────────────────────────────────────────────────────────
-- Pure arithmetic over Constants.WORLD, evaluated once at require time. The
-- anchors are therefore correct even if `start` never runs (Server.server
-- downgrades a failed start to a warning), which is what lets PlayerService
-- still spawn a player into the right place on a bad boot.

local PLAZA_CENTER = Vector3.new(0, WORLD.BASE_HEIGHT, 0)
local ISLAND_RADIUS = WORLD.DEN_RING_RADIUS + WORLD.DEN_SIZE.X -- den ring plus a den of shoulder
local DEN_STEP = (2 * math.pi) / Constants.SERVER_SIZE

local function ringPoint(angle: number, radius: number, height: number): Vector3
	return Vector3.new(math.sin(angle) * radius, WORLD.BASE_HEIGHT + height, math.cos(angle) * radius)
end

-- A level CFrame at `position` whose front (-Z — the face a SurfaceGui calls
-- "Front", and the direction CFrame.LookVector points) looks at the plaza.
-- Every structure is built in this frame, so "toward the plaza" is always -Z
-- and "left/right along the facade" is always X.
local function facingPlaza(position: Vector3): CFrame
	return CFrame.lookAt(position, Vector3.new(PLAZA_CENTER.X, position.Y, PLAZA_CENTER.Z))
end

--[[
	The middle of the gap between two Dens, nearest to `target`. Both shops,
	the kiosk and the leaderboard wall sit on one of these, so the radial walk
	from any Den door to the Mixer never meets a wall — the one hard layout
	rule in §6. It stays true for any Constants.SERVER_SIZE, odd or even,
	which a hard-coded ±X placement would not.
]]
local function gapAngle(target: number): number
	return (math.floor(target / DEN_STEP) + 0.5) * DEN_STEP
end

local function denAnchor(index: number): CFrame
	return facingPlaza(ringPoint((index - 1) * DEN_STEP, WORLD.DEN_RING_RADIUS, 0))
end

local SHOP_ANCHORS: { [string]: CFrame } = {
	Critter = facingPlaza(ringPoint(gapAngle(math.pi * 0.5), WORLD.SHOP_OFFSET, 0)),
	Stuff = facingPlaza(ringPoint(gapAngle(math.pi * 1.5), WORLD.SHOP_OFFSET, 0)),
	-- The kiosk faces OUT of the plaza: a player arriving from their Den
	-- should read the screen on approach, not walk around the back of it.
	Mixdex = facingPlaza(ringPoint(gapAngle(0), WORLD.PLAZA_RADIUS * SHAPE.KIOSK_RING_RATIO, 0))
		* CFrame.Angles(0, math.pi, 0),
}

local LEADERBOARD_ANCHOR = facingPlaza(ringPoint(gapAngle(math.pi), WORLD.SHOP_OFFSET, 0))

-- A caller that asks for slot 0 or slot 99 has a bug; clamping keeps the
-- non-optional return types in the §4 API honest while the warn names it.
local function slotOf(index: number): number
	if index ~= index then
		warn("[WorldService] slot index is NaN; using 1")
		return 1
	end
	local clamped = math.clamp(math.floor(index), 1, Constants.SERVER_SIZE)
	if clamped ~= index then
		warn(("[WorldService] slot %s is outside 1..%d; clamped to %d"):format(tostring(index), Constants.SERVER_SIZE, clamped))
	end
	return clamped
end

-- ── State ────────────────────────────────────────────────────────────────

local built = false
local root: Folder? = nil
local dens: { Folder } = {}
local pads: { BasePart } = {}
local boards: { BasePart } = {}

-- ── Primitives ───────────────────────────────────────────────────────────

local function newPart(name: string, size: Vector3, cframe: CFrame, color: Color3, parent: Instance): Part
	local instance = Instance.new("Part")
	instance.Name = name
	instance.Size = size
	instance.CFrame = cframe
	instance.Color = color
	instance.Material = Enum.Material.SmoothPlastic
	instance.Anchored = true
	instance.TopSurface = Enum.SurfaceType.Smooth
	instance.BottomSurface = Enum.SurfaceType.Smooth
	instance.Parent = parent
	return instance
end

-- Decoration: it may never collide with a player, stop a raycast, or fire a
-- Touched event. Everything a player is meant to walk past goes through here.
local function decor(part: Part): Part
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	return part
end

-- Roblox cylinders run along their own X axis, so every disc in town is a
-- Part turned a quarter turn about Z. `cframe` is the level frame of the
-- disc; its yaw is irrelevant to the shape and only matters to its children.
local function newDisc(name: string, diameter: number, thickness: number, cframe: CFrame, color: Color3, parent: Instance): Part
	local part = newPart(name, Vector3.new(thickness, diameter, diameter), cframe * CFrame.Angles(0, 0, math.pi * 0.5), color, parent)
	part.Shape = Enum.PartType.Cylinder
	return part
end

-- A cylinder lying along `cframe`'s look direction — the Mixer's spout.
local function newTube(name: string, diameter: number, length: number, cframe: CFrame, color: Color3, parent: Instance): Part
	local part = newPart(name, Vector3.new(length, diameter, diameter), cframe * CFrame.Angles(0, math.pi * 0.5, 0), color, parent)
	part.Shape = Enum.PartType.Cylinder
	return part
end

local function findPart(scope: Instance, name: string): BasePart?
	local found = scope:FindFirstChild(name, true)
	return if found and found:IsA("BasePart") then found else nil
end

-- ── Surface GUIs ─────────────────────────────────────────────────────────
-- Signs are the game's only diegetic UI. They are LightInfluence 0 so they
-- stay readable at any ClockTime, and MaxDistance-culled so twelve of them
-- across a plaza cost nothing on a phone.

local function newSurface(part: BasePart, face: Enum.NormalId): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Display"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = SHAPE.SIGN_PIXELS
	gui.LightInfluence = 0
	gui.MaxDistance = SHAPE.SIGN_DISTANCE
	gui.Parent = part
	return gui
end

local function newLabel(parent: Instance, name: string, text: string, color: Color3): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Text = text
	label.TextColor3 = color
	label.FontFace = Font.fromEnum(Enum.Font.FredokaOne)
	label.TextScaled = true
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Size = UDim2.fromScale(1, 1)
	label.Parent = parent
	return label
end

-- A one-line sign: shop fascias, the kiosk, the COMING SOON barrier.
local function dressSign(part: BasePart, text: string)
	if part:FindFirstChildOfClass("SurfaceGui") then
		return -- a Studio-authored model brought its own
	end
	newLabel(newSurface(part, Enum.NormalId.Front), "Title", text, PALETTE.SIGN_TEXT)
end

-- The board above a Den door. DenService writes `Owner` and `Rate`; both
-- exist from boot so it never has to build UI on a hot path.
local function dressDenSign(part: BasePart)
	if part:FindFirstChildOfClass("SurfaceGui") then
		return
	end
	local gui = newSurface(part, Enum.NormalId.Front)
	local owner = newLabel(gui, "Owner", "VACANT DEN", PALETTE.SIGN_TEXT)
	owner.Size = UDim2.fromScale(1, 0.58)
	local rate = newLabel(gui, "Rate", "0 Goop/sec", PALETTE.GOOP)
	rate.Size = UDim2.fromScale(1, 0.42)
	rate.Position = UDim2.fromScale(0, 0.58)
end

-- One leaderboard panel. LeaderboardService appends rows to `Entries`; the
-- UIListLayout and AutomaticCanvasSize mean it only has to parent them.
local function dressBoard(part: BasePart, title: string)
	if part:FindFirstChildOfClass("SurfaceGui") then
		return
	end
	local gui = newSurface(part, Enum.NormalId.Front)

	local heading = newLabel(gui, "Title", title, PALETTE.SIGN_TEXT)
	heading.Size = UDim2.fromScale(1, 0.17)
	heading.BackgroundColor3 = PALETTE.MIXER_TRIM
	heading.BackgroundTransparency = 0

	local entries = Instance.new("ScrollingFrame")
	entries.Name = "Entries"
	entries.Size = UDim2.fromScale(1, 0.83)
	entries.Position = UDim2.fromScale(0, 0.17)
	entries.BackgroundTransparency = 1
	entries.BorderSizePixel = 0
	entries.CanvasSize = UDim2.new()
	entries.AutomaticCanvasSize = Enum.AutomaticSize.Y
	entries.ScrollingDirection = Enum.ScrollingDirection.Y
	entries.ScrollBarThickness = 6
	entries.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = entries
end

-- ── Asset overrides ──────────────────────────────────────────────────────
--[[
	A Model at ReplicatedStorage/Assets/World/<Name> replaces the placeholder
	for that structure: it is cloned, anchored, and pivoted onto the same
	anchor CFrame the generated version would have used. Names:

	    Island  Mixer  Den  CritterPen  StuffShack  MixdexKiosk
	    LeaderboardWall  JunkCliffs

	The functional parts are looked up inside whatever ends up in the folder
	and created only if the art did not provide them, so a model may opt in to
	any of them by name:

	    Den              Folder "Pedestals", Part "Sign"
	    Mixer            Parts named "MixerPad" (any number; else a ring is
	                     generated around the model)
	    CritterPen /
	    StuffShack /
	    MixdexKiosk      Part "Trigger" (the tagged volume)
	    LeaderboardWall  Parts "Board1".."BoardN", one per Constants.LEADERBOARDS

	Author models facing -Z (toward the plaza) with the pivot at floor level.
]]
local function worldAsset(name: string): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return nil
	end
	local world = assets:FindFirstChild("World")
	if not world then
		return nil
	end
	local found = world:FindFirstChild(name)
	return if found and found:IsA("Model") then found else nil
end

local function placeAsset(name: string, pivot: CFrame, parent: Instance): Model?
	local template = worldAsset(name)
	if not template then
		return nil
	end
	local model = template:Clone()
	model.Name = name
	-- Art is authored however the artist likes; the town is static, so every
	-- part of it is anchored on the way in rather than trusting the file.
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end
	model:PivotTo(pivot)
	model.Parent = parent
	return model
end

-- ── The island (GDD §6: a floating island of stacked scrap) ──────────────

local function buildIsland(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Island"
	folder.Parent = parent

	if placeAsset("Island", CFrame.new(PLAZA_CENTER), folder) then
		return
	end

	newDisc(
		"Ground",
		ISLAND_RADIUS * 2,
		SHAPE.ISLAND_THICKNESS,
		CFrame.new(0, WORLD.BASE_HEIGHT - SHAPE.ISLAND_THICKNESS * 0.5, 0),
		PALETTE.GROUND,
		folder
	)

	-- The plaza is painted, not built: a half-stud non-colliding disc reads as
	-- a town square from the air and cannot trip anyone at its rim.
	decor(newDisc(
		"Plaza",
		WORLD.PLAZA_RADIUS * 2,
		SHAPE.PLAZA_LIP,
		CFrame.new(0, WORLD.BASE_HEIGHT + SHAPE.PLAZA_LIP * 0.5, 0),
		PALETTE.PLAZA,
		folder
	))

	-- Four shrinking slabs and two girders sell "this rock is floating" for
	-- six draw calls. Real stalactite meshes are one Assets/World/Island drop
	-- away and would replace the whole function.
	local depth = WORLD.BASE_HEIGHT - SHAPE.ISLAND_THICKNESS
	for step = 1, SHAPE.SCRAP_LAYERS do
		local fraction = step / (SHAPE.SCRAP_LAYERS + 1)
		local thickness = SHAPE.ISLAND_THICKNESS * (1.3 - fraction * 0.5)
		local radius = ISLAND_RADIUS * (1 - fraction * 0.82)
		local sway = radius * 0.12
		depth -= thickness * 0.5
		decor(newDisc(
			"Scrap",
			radius * 2,
			thickness,
			CFrame.new(math.sin(step * 2) * sway, depth, math.cos(step * 2) * sway),
			if step % 2 == 0 then PALETTE.SCRAP else PALETTE.SCRAP_DARK,
			folder
		))
		depth -= thickness * 0.55
	end

	for index = 1, 2 do
		decor(newPart(
			"Girder",
			Vector3.new(ISLAND_RADIUS * 0.95, 3, 7),
			CFrame.new(0, WORLD.BASE_HEIGHT - SHAPE.ISLAND_THICKNESS - 7, 0)
				* CFrame.Angles(0, index * math.pi / 3, math.rad(10)),
			PALETTE.METAL,
			folder
		))
	end
end

-- ── The Mixer (GDD §6, §8.1) ─────────────────────────────────────────────

local function buildPads(parent: Instance)
	local radius = WORLD.PLAZA_RADIUS * SHAPE.PAD_RING_RATIO
	for index = 1, Constants.MIXER_PADS do
		local angle = ((index - 1) / Constants.MIXER_PADS) * math.pi * 2
		-- Stacked on the plaza lip, not sunk into it: two up-facing surfaces at
		-- the same height z-fight, and a flickering pad reads as a broken game.
		local frame = facingPlaza(ringPoint(angle, radius, SHAPE.PLAZA_LIP + SHAPE.PAD_THICKNESS * 0.5))
		-- One hue per pad: "meet me on the pink pad" is free wayfinding, and
		-- it makes a full server of ten mixers legible in one screenshot
		-- (GDD §2, pillar 3).
		local hue = (index - 1) / Constants.MIXER_PADS
		local pad = newDisc("MixerPad", SHAPE.PAD_DIAMETER, SHAPE.PAD_THICKNESS, frame, Color3.fromHSV(hue, 0.55, 1), parent)
		-- Walk-over, not step-over: a pad may never snag a player mid-sprint,
		-- but it must still answer prompts and Touched.
		pad.CanCollide = false
		pad.CastShadow = false
		pad:SetAttribute("PadIndex", index)
		CollectionService:AddTag(pad, "MixerPad")

		local plate = decor(newPart(
			"Number",
			Vector3.new(SHAPE.PAD_DIAMETER * 0.55, 0.2, SHAPE.PAD_DIAMETER * 0.55),
			frame * CFrame.new(0, SHAPE.PAD_THICKNESS * 0.5 + 0.1, 0),
			PALETTE.SIGN,
			pad
		))
		newLabel(newSurface(plate, Enum.NormalId.Top), "Number", tostring(index), PALETTE.SIGN_TEXT)

		table.insert(pads, pad)
	end
end

local function buildMixer(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Mixer"
	folder.Parent = parent

	local override = placeAsset("Mixer", CFrame.new(PLAZA_CENTER), folder)
	if override then
		-- An authored Mixer may bring its own pads; only generate the ring if
		-- it did not, so the art can decide where players stand.
		for _, descendant in override:GetDescendants() do
			if descendant.Name == "MixerPad" and descendant:IsA("BasePart") then
				descendant:SetAttribute("PadIndex", #pads + 1)
				CollectionService:AddTag(descendant, "MixerPad")
				table.insert(pads, descendant)
			end
		end
		if #pads > 0 then
			return
		end
	else
		local radius = WORLD.PLAZA_RADIUS * SHAPE.MIXER_RADIUS_RATIO
		local height = WORLD.PLAZA_RADIUS * SHAPE.MIXER_HEIGHT_RATIO
		local plinth = height * 0.18
		local base = WORLD.BASE_HEIGHT + plinth

		newDisc("Plinth", radius * 2.3, plinth, CFrame.new(0, WORLD.BASE_HEIGHT + plinth * 0.5, 0), PALETTE.METAL, folder)

		-- Body in three bands: opaque tank, transparent viewing window, opaque
		-- collar. The window is a hole in the silhouette rather than a decal,
		-- which is what makes the roll visible from anywhere on the plaza
		-- (GDD §6: "roll happens inside it, visible to everyone nearby").
		local tank = height * 0.45
		local glass = height * 0.30
		local collar = height * 0.25
		newDisc("Tank", radius * 2, tank, CFrame.new(0, base + tank * 0.5, 0), PALETTE.MIXER_BODY, folder)

		local goop = decor(newDisc(
			"Goop",
			radius * 1.7,
			glass * 0.72,
			CFrame.new(0, base + tank + glass * 0.36, 0),
			PALETTE.GOOP,
			folder
		))
		goop.Material = Enum.Material.Neon

		local window = decor(newDisc(
			"Window",
			radius * 2.02,
			glass,
			CFrame.new(0, base + tank + glass * 0.5, 0),
			PALETTE.GOOP,
			folder
		))
		window.Material = Enum.Material.Neon
		window.Transparency = 0.62

		newDisc(
			"Collar",
			radius * 2,
			collar,
			CFrame.new(0, base + tank + glass + collar * 0.5, 0),
			PALETTE.MIXER_BODY,
			folder
		)

		local lidY = base + height
		decor(newDisc("Lid", radius * 2.24, height * 0.09, CFrame.new(0, lidY + height * 0.045, 0), PALETTE.MIXER_LID, folder))
		decor(newDisc("Knob", radius * 0.36, height * 0.14, CFrame.new(0, lidY + height * 0.155, 0), PALETTE.MIXER_TRIM, folder))

		-- The spout points down the leaderboard corridor so it never overhangs
		-- a pad a player is standing on.
		local spoutAngle = gapAngle(math.pi)
		local spoutY = WORLD.BASE_HEIGHT + plinth + tank * 0.55
		local spoutFrame = facingPlaza(ringPoint(spoutAngle, radius * 1.45, spoutY - WORLD.BASE_HEIGHT))
			* CFrame.Angles(0, math.pi, 0)
		decor(newTube("Spout", radius * 0.34, radius * 1.1, spoutFrame, PALETTE.METAL, folder))
		decor(newDisc(
			"SpoutRim",
			radius * 0.44,
			height * 0.06,
			CFrame.new(ringPoint(spoutAngle, radius * 1.95, spoutY - WORLD.BASE_HEIGHT)),
			PALETTE.MIXER_TRIM,
			folder
		))
	end

	buildPads(folder)
end

-- ── The Den ring (GDD §6, §8.3) ──────────────────────────────────────────

local function buildDenShell(folder: Folder, anchor: CFrame, tint: Color3)
	local size = WORLD.DEN_SIZE
	local halfX, halfZ = size.X * 0.5, size.Z * 0.5
	local wallHeight = size.Y * SHAPE.DEN_WALL_RATIO
	local doorWidth = size.X * SHAPE.DOOR_WIDTH_RATIO
	local doorHeight = wallHeight * SHAPE.DOOR_HEIGHT_RATIO
	local lintel = wallHeight - doorHeight
	local front = -(halfZ - SHAPE.WALL * 0.5)

	-- Open-topped on purpose: the mobile camera has to see a player's
	-- pedestals from outside, because being seen is the point of placing
	-- (GDD §3, "pride"). A roof would also be ten more draw calls.

	-- The floor sits a lip proud of the ground, flush with the painted path
	-- outside the door. Laying it level with the island instead would put two
	-- up-facing surfaces at the same height, and coplanar faces z-fight.
	newPart(
		"Floor",
		Vector3.new(size.X, SHAPE.WALL, size.Z),
		anchor * CFrame.new(0, SHAPE.PLAZA_LIP - SHAPE.WALL * 0.5, 0),
		PALETTE.FLOOR,
		folder
	)
	newPart(
		"BackWall",
		Vector3.new(size.X, wallHeight, SHAPE.WALL),
		anchor * CFrame.new(0, wallHeight * 0.5, halfZ - SHAPE.WALL * 0.5),
		tint,
		folder
	)
	for _, side in { -1, 1 } do
		newPart(
			"SideWall",
			Vector3.new(SHAPE.WALL, wallHeight, size.Z),
			anchor * CFrame.new(side * (halfX - SHAPE.WALL * 0.5), wallHeight * 0.5, 0),
			tint,
			folder
		)
	end

	-- Three walls and a doorway: the facade is two jambs and a lintel, so the
	-- gap is a real door DenService can put a forcefield across (§8.3).
	local jamb = (size.X - doorWidth) * 0.5
	for _, side in { -1, 1 } do
		newPart(
			"DoorJamb",
			Vector3.new(jamb, wallHeight, SHAPE.WALL),
			anchor * CFrame.new(side * (doorWidth + jamb) * 0.5, wallHeight * 0.5, front),
			tint,
			folder
		)
	end
	newPart(
		"Lintel",
		Vector3.new(doorWidth, lintel, SHAPE.WALL),
		anchor * CFrame.new(0, doorHeight + lintel * 0.5, front),
		tint:Lerp(PALETTE.FLOOR, 0.35),
		folder
	)
	decor(newPart(
		"Sign",
		Vector3.new(doorWidth * 0.94, lintel * 0.78, SHAPE.SIGN_DEPTH),
		anchor * CFrame.new(0, doorHeight + lintel * 0.5, -(halfZ + SHAPE.SIGN_DEPTH * 0.5)),
		PALETTE.SIGN,
		folder
	))

	-- The Goop vault prop (§6). Decoration, in a back corner, where it cannot
	-- crowd the pedestal ring DenService lays out at PEDESTAL_RING_RADIUS.
	local vault = Vector3.new(size.X * 0.16, size.Y * 0.28, size.X * 0.12)
	local vaultFrame = anchor
		* CFrame.new(-(halfX - SHAPE.WALL - vault.X * 0.6), vault.Y * 0.5, halfZ - SHAPE.WALL - vault.Z * 0.7)
	decor(newPart("Vault", vault, vaultFrame, PALETTE.METAL, folder))
	decor(newDisc(
		"VaultDial",
		vault.X * 0.5,
		0.4,
		vaultFrame * CFrame.new(0, 0, -(vault.Z * 0.5 + 0.2)) * CFrame.Angles(-math.pi * 0.5, 0, 0),
		PALETTE.MIXER_LID,
		folder
	))
end

local function buildDen(index: number, parent: Instance): Folder
	local folder = Instance.new("Folder")
	folder.Name = "Den" .. index
	folder:SetAttribute("SlotIndex", index)
	folder.Parent = parent

	local anchor = denAnchor(index)
	-- A hue per Den: ten identical boxes in a ring are unnavigable, and
	-- "the orange Den" is how players will actually describe a raid.
	local tint = Color3.fromHSV((index - 1) / Constants.SERVER_SIZE, 0.55, 1)

	if not placeAsset("Den", anchor, folder) then
		buildDenShell(folder, anchor, tint)
	end

	-- The walk from this door to the plaza, painted flat. One part per Den
	-- buys the wayfinding that GDD §5 asks a tutorial beam to reinforce.
	local run = WORLD.DEN_RING_RADIUS - WORLD.DEN_SIZE.Z * 0.5 - WORLD.PLAZA_RADIUS
	if run > 0 then
		decor(newPart(
			"Path",
			Vector3.new(SHAPE.PATH_WIDTH, SHAPE.PLAZA_LIP, run),
			anchor * CFrame.new(0, SHAPE.PLAZA_LIP * 0.5, -(WORLD.DEN_SIZE.Z * 0.5 + run * 0.5)),
			tint:Lerp(PALETTE.PLAZA, 0.55),
			folder
		))
	end

	-- Recursive, because an authored Den model is allowed to carry its own
	-- Pedestals folder wherever its hierarchy puts it.
	if not folder:FindFirstChild("Pedestals", true) then
		local pedestals = Instance.new("Folder")
		pedestals.Name = "Pedestals"
		pedestals.Parent = folder
	end

	local sign = findPart(folder, "Sign")
	if sign then
		dressDenSign(sign)
	end
	return folder
end

-- ── Shops and the kiosk (GDD §6, §8.6) ───────────────────────────────────

local function tagTrigger(folder: Folder, anchor: CFrame, size: Vector3, tag: string)
	local trigger = findPart(folder, "Trigger")
	if not trigger then
		local created = newPart("Trigger", size, anchor * CFrame.new(0, size.Y * 0.5, 0), PALETTE.METAL, folder)
		created.Transparency = 1
		created.CanCollide = false
		created.CanQuery = false -- prompts live on it; nothing needs to raycast it
		created.CastShadow = false
		trigger = created
	end
	CollectionService:AddTag(trigger, tag)
end

local function buildStall(name: string, assetName: string, tag: string, title: string, color: Color3, anchor: CFrame, parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent

	local width = WORLD.PLAZA_RADIUS * SHAPE.SHOP_WIDTH_RATIO
	local depth = WORLD.PLAZA_RADIUS * SHAPE.SHOP_DEPTH_RATIO
	local height = SHAPE.SHOP_HEIGHT

	if not placeAsset(assetName, anchor, folder) then
		newPart(
			"Floor",
			Vector3.new(width, SHAPE.WALL, depth),
			anchor * CFrame.new(0, SHAPE.PLAZA_LIP - SHAPE.WALL * 0.5, 0),
			PALETTE.FLOOR,
			folder
		)
		newPart(
			"BackWall",
			Vector3.new(width, height, SHAPE.WALL),
			anchor * CFrame.new(0, height * 0.5, depth * 0.5 - SHAPE.WALL * 0.5),
			color,
			folder
		)

		-- Two long shelves, not one slot per ingredient: 16 Critters and 16
		-- Stuff would be 32 draw calls of backdrop for a list the shop UI
		-- already shows (§8.6). Idle-animated ingredient models drop in here
		-- as Assets/World/CritterPen when they exist.
		for shelf = 1, 2 do
			decor(newPart(
				"Shelf",
				Vector3.new(width * 0.86, 0.8, depth * 0.34),
				anchor * CFrame.new(0, height * (0.2 * shelf + 0.16), depth * 0.5 - SHAPE.WALL - depth * 0.18),
				PALETTE.METAL,
				folder
			))
		end

		for _, side in { -1, 1 } do
			decor(newPart(
				"Post",
				Vector3.new(1.6, height, 1.6),
				anchor * CFrame.new(side * (width * 0.5 - 1), height * 0.5, -(depth * 0.5 - 1)),
				PALETTE.METAL,
				folder
			))
		end
		decor(newPart(
			"Roof",
			Vector3.new(width + 3, SHAPE.WALL, depth + 3),
			anchor * CFrame.new(0, height + SHAPE.WALL * 0.5, 0),
			color:Lerp(Color3.new(1, 1, 1), 0.3),
			folder
		))

		local fascia = decor(newPart(
			"Fascia",
			Vector3.new(width * 0.76, height * 0.2, SHAPE.SIGN_DEPTH),
			anchor * CFrame.new(0, height * 0.86, -(depth * 0.5 + 1.6)),
			PALETTE.SIGN,
			folder
		))
		dressSign(fascia, title)
	end

	tagTrigger(folder, anchor, Vector3.new(width, height, depth), tag)
end

local function buildKiosk(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "MixdexKiosk"
	folder.Parent = parent

	local anchor = SHOP_ANCHORS.Mixdex
	local height = SHAPE.KIOSK_HEIGHT

	if not placeAsset("MixdexKiosk", anchor, folder) then
		newPart("Base", Vector3.new(7, height * 0.55, 3), anchor * CFrame.new(0, height * 0.275, 0), PALETTE.KIOSK, folder)
		local screen = decor(newPart(
			"Screen",
			Vector3.new(7, height * 0.5, 0.8),
			anchor * CFrame.new(0, height * 0.78, -0.9) * CFrame.Angles(math.rad(-18), 0, 0),
			PALETTE.SIGN,
			folder
		))
		dressSign(screen, "MIXDEX")
	end

	tagTrigger(folder, anchor, Vector3.new(9, height, 6), "Kiosk_Mixdex")
end

-- ── Leaderboard wall (GDD §6, §8.7) ──────────────────────────────────────

local function buildLeaderboardWall(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "LeaderboardWall"
	folder.Parent = parent

	local anchor = LEADERBOARD_ANCHOR
	local count = #Constants.LEADERBOARDS
	local pitch = SHAPE.BOARD_SIZE.X + SHAPE.BOARD_GAP
	local span = pitch * count
	local top = SHAPE.BOARD_CLEARANCE + SHAPE.BOARD_SIZE.Y

	if not placeAsset("LeaderboardWall", anchor, folder) then
		-- The panels hang above head height from a cantilevered beam on two
		-- narrow pylons, and the pylons are pulled well inside the span. That
		-- is the whole trick: seventy studs of readable board standing on six
		-- studs of collision, none of it within reach of the painted path a
		-- neighbouring Den walks in on (§6: nothing blocks that walk).
		for _, side in { -1, 1 } do
			newPart(
				"Pylon",
				Vector3.new(3, top + 2, 3),
				anchor * CFrame.new(side * span * 0.25, (top + 2) * 0.5, 0),
				PALETTE.METAL,
				folder
			)
		end
		decor(newPart(
			"Header",
			Vector3.new(span + 3, 2.4, 3),
			anchor * CFrame.new(0, top + 3.2, 0),
			PALETTE.MIXER_TRIM,
			folder
		))
	end

	for index, board in Constants.LEADERBOARDS do
		local part = findPart(folder, "Board" .. index)
		if not part then
			part = decor(newPart(
				"Board" .. index,
				SHAPE.BOARD_SIZE,
				anchor * CFrame.new((index - (count + 1) * 0.5) * pitch, SHAPE.BOARD_CLEARANCE + SHAPE.BOARD_SIZE.Y * 0.5, 0),
				PALETTE.BOARD,
				folder
			))
		end
		if part then
			part:SetAttribute("BoardKey", board.key)
			dressBoard(part, board.title)
			table.insert(boards, part)
		end
	end
end

-- ── Junk Cliffs barrier (GDD §6, v1.5) ───────────────────────────────────

local function buildJunkCliffs(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "JunkCliffs"
	folder.Parent = parent

	local center = gapAngle(0)
	local radius = WORLD.DEN_RING_RADIUS + WORLD.DEN_SIZE.Z * 0.75
	local anchor = facingPlaza(ringPoint(center, radius, 0))

	if placeAsset("JunkCliffs", anchor, folder) then
		return
	end

	-- Build the barrier, not the zone: the fringe behind it stays empty until
	-- v1.5 fills it with wild Mixlings.
	local arc = DEN_STEP * SHAPE.FENCE_ARC_DENS
	local panels = SHAPE.FENCE_PANELS
	local panelWidth = 2 * radius * math.sin(arc / (2 * panels)) + 1 -- +1 so neighbours overlap, no seams
	for index = 1, panels do
		local offset = ((index - 0.5) / panels - 0.5) * arc
		local frame = facingPlaza(ringPoint(center + offset, radius, SHAPE.FENCE_HEIGHT * 0.5))
		newPart(
			"Barrier",
			Vector3.new(panelWidth, SHAPE.FENCE_HEIGHT, SHAPE.WALL),
			frame,
			if index % 2 == 0 then PALETTE.HAZARD else PALETTE.HAZARD_ALT,
			folder
		)
	end

	-- Two diagonal braces read as scaffolding. An honest truss is sixty thin
	-- parts for the same silhouette at mobile draw distance.
	for _, side in { -1, 1 } do
		local frame = facingPlaza(ringPoint(center + side * arc * 0.28, radius + 1.5, SHAPE.FENCE_HEIGHT * 0.5))
		decor(newPart(
			"Brace",
			Vector3.new(1.4, SHAPE.FENCE_HEIGHT * 1.5, 1.4),
			frame * CFrame.Angles(0, 0, math.rad(side * 26)),
			PALETTE.METAL,
			folder
		))
	end

	local sign = decor(newPart(
		"ComingSoon",
		Vector3.new(34, 9, SHAPE.SIGN_DEPTH),
		facingPlaza(ringPoint(center, radius - 1.4, SHAPE.FENCE_HEIGHT + 5)),
		PALETTE.SIGN,
		folder
	))
	dressSign(sign, "JUNK CLIFFS · COMING SOON")
end

-- ── Lighting (GDD §6: bright sky, saturated toy colours, no grunge) ──────

local function applyLighting()
	Lighting.Ambient = Color3.fromRGB(122, 130, 142)
	Lighting.OutdoorAmbient = Color3.fromRGB(152, 162, 178)
	Lighting.Brightness = 2.6
	Lighting.ClockTime = 14
	Lighting.GeographicLatitude = 12
	Lighting.ExposureCompensation = 0.15
	Lighting.EnvironmentDiffuseScale = 0.6
	Lighting.EnvironmentSpecularScale = 0.3
	Lighting.GlobalShadows = true
	Lighting.ColorShift_Top = Color3.fromRGB(255, 248, 232)

	-- Idempotent, and it never overwrites art: a Sky or Atmosphere already in
	-- Lighting was put there by a human and wins.
	if not Lighting:FindFirstChildOfClass("Sky") then
		local sky = Instance.new("Sky")
		sky.Name = "BlendburgSky"
		sky.StarCount = 0
		sky.SunAngularSize = 16
		sky.MoonAngularSize = 0
		sky.Parent = Lighting
	end

	if not Lighting:FindFirstChildOfClass("Atmosphere") then
		local atmosphere = Instance.new("Atmosphere")
		atmosphere.Name = "BlendburgAir"
		-- Thin on purpose: the Den ring is 150 studs out and its owner signs
		-- have to stay readable at mobile draw distance.
		atmosphere.Density = 0.24
		atmosphere.Offset = 0.1
		atmosphere.Color = WORLD.SKY_COLOR
		atmosphere.Decay = WORLD.SKY_COLOR:Lerp(Color3.fromRGB(255, 232, 190), 0.5)
		atmosphere.Glare = 0.15
		atmosphere.Haze = 1
		atmosphere.Parent = Lighting
	end
end

-- ── Build ────────────────────────────────────────────────────────────────

local function build()
	-- A leftover town (a Studio play-test that did not clean up, or a service
	-- restart) would double every draw call and hand DenService folders that
	-- nothing else points at.
	local stale = Workspace:FindFirstChild(ROOT_NAME)
	if stale then
		stale:Destroy()
	end
	table.clear(dens)
	table.clear(pads)
	table.clear(boards)

	local folder = Instance.new("Folder")
	folder.Name = ROOT_NAME

	buildIsland(folder)
	buildMixer(folder)

	local denRing = Instance.new("Folder")
	denRing.Name = "Dens"
	denRing.Parent = folder
	for index = 1, Constants.SERVER_SIZE do
		dens[index] = buildDen(index, denRing)
	end

	buildStall("CritterPen", "CritterPen", "Shop_Critter", "CRITTER PEN", PALETTE.CRITTER, SHOP_ANCHORS.Critter, folder)
	buildStall("StuffShack", "StuffShack", "Shop_Stuff", "STUFF SHACK", PALETTE.STUFF, SHOP_ANCHORS.Stuff, folder)
	buildKiosk(folder)
	buildLeaderboardWall(folder)
	buildJunkCliffs(folder)

	-- Parented last: one replication burst for the whole town instead of ~180
	-- individual property streams to every client that is already in.
	folder.Parent = Workspace
	root = folder
	built = true
end

--[[
	Every getter that hands out an Instance goes through here, so the town is
	built on demand as well as in `start`. Two reasons: Server.server.luau
	downgrades a failed `start` to a warning, and a Den rebuilt late is a much
	better failure than DenService indexing nil. Building is pure Instance
	work — it never yields — so a getter can do it inline.
]]
local function ensureBuilt()
	local existing = root
	if built and existing and existing.Parent then
		return
	end
	build()
end

-- ── Public API ───────────────────────────────────────────────────────────

function WorldService.getPlazaCenter(): Vector3
	return PLAZA_CENTER
end

-- Pad 1..Constants.MIXER_PADS, in ring order. A copy: the order is ours.
function WorldService.getMixerPads(): { BasePart }
	ensureBuilt()
	return table.clone(pads)
end

function WorldService.getDenAnchor(slotIndex: number): CFrame
	return denAnchor(slotOf(slotIndex))
end

function WorldService.getDenFolder(slotIndex: number): Folder
	ensureBuilt()
	return dens[slotOf(slotIndex)]
end

--[[
	Just inside the doorway, turned to face the pedestals: GDD §5 opens on
	"your empty pedestals" and pans from there to the Mixer, which only works
	if the player is not already looking at the plaza.
]]
function WorldService.getSpawnFor(slotIndex: number): CFrame
	local anchor = denAnchor(slotOf(slotIndex))
	return anchor
		* CFrame.new(0, SHAPE.SPAWN_HEIGHT, -(WORLD.DEN_SIZE.Z * 0.5 - SHAPE.SPAWN_INSET))
		* CFrame.Angles(0, math.pi, 0)
end

function WorldService.getShopAnchor(kind: "Critter" | "Stuff" | "Mixdex"): CFrame
	local anchor = SHOP_ANCHORS[kind]
	if not anchor then
		warn(("[WorldService] no shop anchor named %q; using the plaza"):format(tostring(kind)))
		return CFrame.new(PLAZA_CENTER)
	end
	return anchor
end

-- One board per Constants.LEADERBOARDS, in that order.
function WorldService.getLeaderboardBoards(): { BasePart }
	ensureBuilt()
	return table.clone(boards)
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

-- WorldService is a leaf: it draws the town and answers questions about it,
-- so it captures no siblings.
function WorldService.init(_services: { [string]: any }) end

function WorldService.start()
	applyLighting()

	-- The island floats, so walking off the rim would otherwise be an infinite
	-- fall. Some place configurations refuse the write; losing it costs a slow
	-- respawn, never a boot.
	local ok = pcall(function()
		Workspace.FallenPartsDestroyHeight = WORLD.BASE_HEIGHT - SHAPE.VOID_DEPTH
	end)
	if not ok then
		warn("[WorldService] could not set FallenPartsDestroyHeight; a player who falls off the island will fall a long way")
	end

	ensureBuilt()
end

return WorldService
