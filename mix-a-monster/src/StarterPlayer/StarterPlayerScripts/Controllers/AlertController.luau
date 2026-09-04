--!strict
--[[
	AlertController.luau — everything that interrupts the player.
	GDD §10 (Alerts), §8.4.2 (theft), §8.8 (announcements), §7.3 (rarity).

	OWNS four independent interrupt channels, all on one ScreenGui whose
	DisplayOrder sits above every panel, so no screen can ever cover an alarm:

	  banners   "Announce"    top of screen, ~3 s, rarity-coloured, QUEUED
	  theft     "TheftAlert"  red HUD alert plus a compass arrow to the thief
	  toasts    "Notify"      bottom-centre stack; every server refusal lands here
	  luck      "ServerLuck"  a persistent strip counting the party down

	REGISTRY API — other controllers call these, never the remotes:
	  AlertController.toast(text, kind?)
	  AlertController.banner(announcement)

	FIVE NON-OBVIOUS DECISIONS:

	1. Banners are a QUEUE, not a stack. Two Legendaries in the same second
	   are two moments; overlapping them turns both into noise. When more are
	   waiting the hold shortens, so a burst drains instead of backing up
	   behind twenty seconds of stale news.

	2. The camera shake multiplies onto the camera's CURRENT CFrame every
	   frame at RenderPriority.Camera + 1, and remembers exactly what it
	   wrote. The default camera scripts rebuild CFrame from scratch each
	   frame, so nothing accumulates. A SCRIPTABLE camera (the §5 opening pan)
	   is NOT rebuilt, so we undo our own last output before applying the next
	   one. Either way the camera ends exactly where it started, which is the
	   whole reason this is not a "tween the camera and hope" implementation.

	3. Player-facing text is drawn with RichText OFF. Every string here is
	   built server-side, but plenty of it contains a DisplayName, and one "<"
	   in a name would otherwise eat the rest of the banner.

	4. Nothing here decides anything (ARCHITECTURE §7.1). Rarity colours come
	   from Rarity.color, the luck figure and its end time come from the
	   server, and the compass points at the position StealService sends. The
	   only numbers this file derives are pixels and seconds.

	5. The compass keys off the thief's userId and follows their character
	   while it is streamed in, falling back to the last position the server
	   sent. StealService sends "Started" once and "Tracking" every second
	   after it; both draw the alert, and only a theft this client has not
	   already seen sounds the alarm.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Config = ReplicatedStorage:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rarity = require(Config:WaitForChild("Rarity"))
local Net = require(Shared:WaitForChild("Net"))
local Types = require(Shared:WaitForChild("Types"))
local UiKit = require(Shared:WaitForChild("UiKit"))
local Util = require(Shared:WaitForChild("Util"))

local ClientState = require(script.Parent.Parent:WaitForChild("ClientState"))

type Announcement = Types.Announcement
type TheftAlert = Types.TheftAlert

local AlertController = {}
AlertController.Name = "AlertController"

-- ── Tunables ─────────────────────────────────────────────────────────────
-- Presentation, not balance: timings and pixels that only this screen has an
-- opinion about, so they stay here rather than in Constants (ARCHITECTURE
-- §7.2 covers balance values, and none of these change the game).

local DISPLAY_ORDER = 100 -- above every panel; an alarm may never be covered

local BANNER_SECONDS = 3 -- GDD §10: banners hold about three seconds
local BANNER_BUSY_SECONDS = 1.6 -- shorter hold while others are queued
local BANNER_SLIDE = 0.22
local BANNER_QUEUE_MAX = 8 -- the same ceiling AnnouncementService keeps

local TOAST_HEIGHT = UiKit.TOUCH_MIN -- a toast is tappable, so it is a target
local TOAST_MIN_SECONDS = 3
local TOAST_MAX_SECONDS = 7
local TOAST_SECONDS_PER_CHARACTER = 0.045
local TOAST_FADE = 0.18
local TOAST_MAX_SMALL = 3 -- a 360-tall phone cannot show more without hiding the game
local TOAST_MAX_LARGE = 5

local SHAKE_SECONDS = 0.55
local SHAKE_STUDS = 1.1
local SHAKE_RADIANS = 0.03
local SHAKE_FREQUENCY = 18
local SHAKE_BINDING = "MixAlertShake"

local COMPASS_BINDING = "MixAlertCompass"
local COMPASS_RADIUS_X = 0.40 -- of the viewport, from centre; pins the arrow near the edge
local COMPASS_RADIUS_Y = 0.28
local COMPASS_CENTRE_Y = 0.58 -- pushed below centre so the ring clears the top stack
local THEFT_STALE_SECONDS = 8 -- the server refreshes every second; silence this long means it is over
local THEFT_PULSE_HZ = 3

local SECRET_GROUND = 0.90 -- how far a rarity colour is dragged to black behind the text
local BANNER_GROUND = 0.78

-- ── State ────────────────────────────────────────────────────────────────

type Ui = {
	gui: ScreenGui,
	column: Frame,
	theftCard: Frame,
	theftTitle: TextLabel,
	theftSub: TextLabel,
	bannerHolder: Frame,
	luckCard: Frame,
	luckLabel: TextLabel,
	compass: Frame,
	compassArrow: TextLabel,
	compassRange: TextLabel,
	toastStack: Frame,
}

type Toast = {
	button: TextButton,
	text: string,
	kind: string,
	count: number,
	expiresAt: number,
	closed: boolean,
}

type Theft = {
	active: boolean,
	userId: number?,
	position: Vector3?,
	rarity: number,
	mixlingName: string,
	refreshedAt: number,
}

local sound: any = nil

local ui: Ui? = nil

local bannerQueue: { Announcement } = {}
local bannerPumping = false

local toasts: { Toast } = {}
local toastSerial = 0

local theft: Theft = {
	active = false,
	userId = nil,
	position = nil,
	rarity = Rarity.COMMON,
	mixlingName = "",
	refreshedAt = 0,
}

local shakeBound = false
local shakeUntil = 0
local shakeSeed = 0
local shakeBase: CFrame? = nil
local shakeApplied: CFrame? = nil

local compassBound = false

local luckActive = false
local luckAmount = 0
local luckEndsAt = 0
local luckSecondShown = -1

-- ── Small helpers ────────────────────────────────────────────────────────

--[[
	SoundController.play(name) is the whole audio surface, and it already
	swallows an unknown cue. The guard here is for the boot path: Client warns
	and carries on when a controller fails to load, and an alarm that cannot
	be drawn because the sound layer is missing is a far worse bug than a
	silent one. Same posture ARCHITECTURE §6 takes with art assets.
]]
local function cue(name: string)
	if type(sound) ~= "table" then
		return
	end
	local play = sound.play
	if type(play) ~= "function" then
		return
	end
	pcall(function()
		play(name)
	end)
end

--[[
	Raises the ceiling on the UITextSizeConstraint UiKit already attached, for
	a label whose size is set after construction.

	This helper predates the fix to UiKit.applyCommon: passing `MaxTextSize` in
	the prop table used to throw, because applyCommon assigned every key it did
	not recognise straight onto the Instance. It no longer does — the prop works
	— but reaching for the constraint is still the only way to change a ceiling
	AFTER the object exists, which is what every call site here is doing.
]]
local function capText(instance: GuiObject, maximum: number)
	local constraint = instance:FindFirstChildOfClass("UITextSizeConstraint")
	if constraint then
		constraint.MaxTextSize = maximum
	end
end

local function sizeBounds(instance: GuiObject, minimum: Vector2, maximum: Vector2)
	local constraint = Instance.new("UISizeConstraint")
	constraint.MinSize = minimum
	constraint.MaxSize = maximum
	constraint.Parent = instance
end

local function validAnnouncement(raw: any): Announcement?
	if type(raw) ~= "table" then
		return nil
	end
	if type(raw.text) ~= "string" or raw.text == "" then
		return nil
	end
	return raw :: Announcement
end

local function validTheftAlert(raw: any): TheftAlert?
	if type(raw) ~= "table" then
		return nil
	end
	if type(raw.kind) ~= "string" or type(raw.mixlingName) ~= "string" then
		return nil
	end
	return raw :: TheftAlert
end

-- ── The screen ───────────────────────────────────────────────────────────
-- One ScreenGui, three regions: a top column (theft, then banners, then the
-- luck strip), a compass ring around the middle, and a toast stack at the
-- bottom. The column is a fixed fraction of the viewport with size
-- constraints on each child, so the layout resolves itself on a 640x360
-- phone and on a 4K monitor without a resize listener.

local function build(): Ui
	local gui = UiKit.screen("MixAlerts", DISPLAY_ORDER)

	local column = UiKit.frame({
		Parent = gui,
		Name = "TopColumn",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, UiKit.topInset()),
		Size = UDim2.new(1, 0, 0.42, 0),
		ZIndex = 5, -- the whole column draws over the compass ring
	})
	UiKit.list(column, { Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Top })

	-- Theft first: while you are being robbed, nothing outranks it.
	local theftCard = UiKit.frame({
		Parent = column,
		Name = "TheftAlert",
		LayoutOrder = 1,
		Visible = false,
		Size = UDim2.new(0.9, 0, 0.34, 0),
		BackgroundColor3 = UiKit.PALETTE.danger:Lerp(Color3.new(0, 0, 0), 0.55),
		Corner = 12,
		Stroke = UiKit.PALETTE.danger,
		Padding = 8,
	})
	sizeBounds(theftCard, Vector2.new(240, 50), Vector2.new(560, 84))

	local theftTitle = UiKit.label({
		Parent = theftCard,
		Name = "Title",
		Size = UDim2.fromScale(1, 0.58),
		RichText = false,
		TextColor3 = UiKit.PALETTE.text,
	})
	capText(theftTitle, 26)

	local theftSub = UiKit.label({
		Parent = theftCard,
		Name = "Sub",
		Position = UDim2.fromScale(0, 0.6),
		Size = UDim2.fromScale(1, 0.4),
		RichText = false,
		Font = UiKit.FONT_BODY,
		TextColor3 = UiKit.PALETTE.muted,
	})
	capText(theftSub, 18)

	local bannerHolder = UiKit.frame({
		Parent = column,
		Name = "BannerHolder",
		LayoutOrder = 2,
		Visible = false,
		BackgroundTransparency = 1,
		ClipsDescendants = false,
		Size = UDim2.new(0.9, 0, 0.28, 0),
	})
	sizeBounds(bannerHolder, Vector2.new(240, 44), Vector2.new(560, 68))

	local luckCard = UiKit.frame({
		Parent = column,
		Name = "LuckParty",
		LayoutOrder = 3,
		Visible = false,
		Size = UDim2.new(0.62, 0, 0.18, 0),
		BackgroundColor3 = UiKit.PALETTE.warn:Lerp(Color3.new(0, 0, 0), 0.7),
		Corner = 10,
		Stroke = UiKit.PALETTE.warn,
		Padding = 4,
	})
	sizeBounds(luckCard, Vector2.new(180, 28), Vector2.new(380, 44))

	local luckLabel = UiKit.label({
		Parent = luckCard,
		Name = "Countdown",
		Size = UDim2.fromScale(1, 1),
		RichText = false,
		TextColor3 = UiKit.PALETTE.warn,
	})
	capText(luckLabel, 20)

	-- The compass is a ring element, not a panel: it moves every frame, so it
	-- lives directly on the ScreenGui outside any layout.
	local discSize = if UiKit.isSmallScreen() then 48 else 60
	local compass = UiKit.frame({
		Parent = gui,
		Name = "Compass",
		Visible = false,
		ZIndex = 2,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(discSize, discSize),
		BackgroundColor3 = UiKit.PALETTE.ink,
		BackgroundTransparency = 0.2,
		Corner = math.floor(discSize / 2),
		Stroke = UiKit.PALETTE.danger,
	})

	-- SourceSansBold rather than the display font: the geometric arrow glyph
	-- is guaranteed there, and an arrow drawn from an asset would make the
	-- compass the one part of the HUD that needs art to work.
	local compassArrow = UiKit.label({
		Parent = compass,
		Name = "Arrow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.72, 0.72),
		Font = Enum.Font.SourceSansBold,
		Text = "\u{25B2}",
		RichText = false,
		TextColor3 = UiKit.PALETTE.danger,
	})
	capText(compassArrow, 44)

	local compassRange = UiKit.label({
		Parent = compass,
		Name = "Range",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 1.02),
		Size = UDim2.new(2, 0, 0, 16),
		Font = UiKit.FONT_BODY,
		RichText = false,
		TextColor3 = UiKit.PALETTE.text,
	})
	capText(compassRange, 15)

	local toastStack = UiKit.frame({
		Parent = gui,
		Name = "Toasts",
		ZIndex = 3,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.new(0.86, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	sizeBounds(toastStack, Vector2.new(160, 0), Vector2.new(520, math.huge))
	-- Newest at the bottom, nearest the eye and the thumb.
	UiKit.list(toastStack, { Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Bottom })

	return {
		gui = gui,
		column = column,
		theftCard = theftCard,
		theftTitle = theftTitle,
		theftSub = theftSub,
		bannerHolder = bannerHolder,
		luckCard = luckCard,
		luckLabel = luckLabel,
		compass = compass,
		compassArrow = compassArrow,
		compassRange = compassRange,
		toastStack = toastStack,
	}
end

--[[
	Built on demand rather than in init(): init() may not yield and
	UiKit.screen waits for PlayerGui. start() calls this immediately, so the
	lazy path only ever runs if a sibling controller alerts unusually early —
	and then it still works instead of dropping the message.
]]
local function ensureUi(): Ui
	local existing = ui
	if existing then
		return existing
	end
	local built = build()
	ui = built
	return built
end

-- ── Toasts (GDD §10) ─────────────────────────────────────────────────────
-- Every refusal the server sends arrives here. A toast is therefore never
-- dropped before it has been on screen: a burst past the cap ages the OLDEST
-- out early, and a repeat of the live message becomes a counter instead of a
-- second card.

-- Net.luau documents the channel names as "Error", "Success", "Info", "Code"
-- and "Chat"; the services also send their own labels ("Shop", "Steal", ...).
-- Anything unlisted reads neutral, so a new channel is never invisible.
local function toastColor(kind: string): Color3
	if kind == "Error" then
		return UiKit.PALETTE.danger
	end
	if kind == "Code" or kind == "Success" then
		return UiKit.PALETTE.ok
	end
	return UiKit.PALETTE.text
end

local function maxToasts(): number
	return if UiKit.isSmallScreen() then TOAST_MAX_SMALL else TOAST_MAX_LARGE
end

local function closeToast(entry: Toast)
	if entry.closed then
		return
	end
	entry.closed = true

	local index = table.find(toasts, entry)
	if index then
		table.remove(toasts, index)
	end

	UiKit.tween(entry.button, { BackgroundTransparency = 1, TextTransparency = 1 }, TOAST_FADE)
	local stroke = entry.button:FindFirstChildOfClass("UIStroke")
	if stroke then
		UiKit.tween(stroke, { Transparency = 1 }, TOAST_FADE)
	end
	task.delay(TOAST_FADE, function()
		entry.button:Destroy()
	end)
end

local function showToast(text: string, kind: string)
	local view = ensureUi()
	local now = os.clock()
	local life = math.clamp(
		TOAST_MIN_SECONDS + #text * TOAST_SECONDS_PER_CHARACTER,
		TOAST_MIN_SECONDS,
		TOAST_MAX_SECONDS
	)

	-- Holding a locked door open sends the same refusal over and over; one
	-- card with a count says it better than five identical ones.
	local live = toasts[#toasts]
	if live and live.text == text and live.kind == kind then
		live.count += 1
		live.button.Text = ("%s  x%d"):format(text, live.count)
		live.expiresAt = now + life
		UiKit.pop(live.button, 0.08)
		return
	end

	toastSerial += 1
	local color = toastColor(kind)

	local entry: Toast
	local button = UiKit.button({
		Parent = view.toastStack,
		Name = "Toast",
		LayoutOrder = toastSerial,
		Size = UDim2.new(1, 0, 0, TOAST_HEIGHT),
		BackgroundColor3 = UiKit.PALETTE.panel,
		BackgroundTransparency = 0.06,
		TextColor3 = color,
		Font = UiKit.FONT_BODY,
		RichText = false,
		Text = text,
		Corner = 10,
		Stroke = color,
	}, function()
		closeToast(entry)
	end)
	capText(button, 18)

	entry = {
		button = button,
		text = text,
		kind = kind,
		count = 1,
		expiresAt = now + life,
		closed = false,
	}
	table.insert(toasts, entry)
	UiKit.pop(button, 0.14)

	-- Only a genuinely new card blips: the dedupe above means holding a
	-- refusal down is one sound, not one per frame the server refuses.
	if kind == "Error" then
		cue("Error")
	end

	while #toasts > maxToasts() do
		local oldest = toasts[1]
		if not oldest then
			break
		end
		closeToast(oldest)
	end
end

--[[
	AnnouncementService falls back to Notify("Chat", ...) when the server
	cannot reach TextChannel:DisplaySystemMessage — that call is client-side
	in most places, which is exactly here. Honour the intent and put the line
	in chat; if chat is unavailable it becomes a toast rather than vanishing.
]]
local function displayChatLine(text: string): boolean
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
		return false
	end
	local channels = TextChatService:FindFirstChild("TextChannels")
	if not channels then
		return false
	end
	local general = channels:FindFirstChild("RBXGeneral")
	if not general or not general:IsA("TextChannel") then
		return false
	end
	local channel = general
	local ok = pcall(function()
		channel:DisplaySystemMessage(text)
	end)
	return ok
end

-- ── Camera shake (GDD §7.3, Legendary and up) ────────────────────────────

local function stopShake()
	if not shakeBound then
		return
	end
	shakeBound = false
	RunService:UnbindFromRenderStep(SHAKE_BINDING)

	local applied, base = shakeApplied, shakeBase
	shakeApplied, shakeBase = nil, nil

	local camera = workspace.CurrentCamera
	if camera and applied and base and camera.CFrame == applied then
		-- Nothing else has touched the camera since our last frame, so the
		-- displacement is ours to undo. If something has, the camera scripts
		-- already own the CFrame and there is nothing left to restore.
		camera.CFrame = base
	end
end

local function updateShake()
	local camera = workspace.CurrentCamera
	if not camera then
		stopShake()
		return
	end

	local now = os.clock()
	local remaining = shakeUntil - now
	if remaining <= 0 then
		stopShake()
		return
	end

	local current = camera.CFrame
	local applied, base = shakeApplied, shakeBase
	if applied and base and current == applied then
		current = base -- see decision 2: never build an offset on our own offset
	end
	shakeBase = current

	local decay = (remaining / SHAKE_SECONDS) ^ 2
	local t = now * SHAKE_FREQUENCY
	local offset = CFrame.new(
		math.noise(t, shakeSeed, 0) * 2 * SHAKE_STUDS * decay,
		math.noise(t, shakeSeed, 8) * 2 * SHAKE_STUDS * decay,
		0
	) * CFrame.Angles(
		math.noise(t, shakeSeed, 16) * 2 * SHAKE_RADIANS * decay,
		math.noise(t, shakeSeed, 24) * 2 * SHAKE_RADIANS * decay,
		math.noise(t, shakeSeed, 32) * 2 * SHAKE_RADIANS * decay
	)

	local next_ = current * offset
	camera.CFrame = next_
	shakeApplied = next_
end

local function startShake()
	-- Low FX is the player's own setting, synced from their profile: honour
	-- it here rather than shaking a phone that asked us not to.
	if ClientState.get().settings.lowFx == true then
		return
	end

	shakeUntil = os.clock() + SHAKE_SECONDS
	if shakeBound then
		return -- a second Legendary just re-arms the window
	end
	shakeBound = true
	shakeSeed = math.random() * 1000
	-- After the camera scripts have written CFrame for this frame.
	RunService:BindToRenderStep(SHAKE_BINDING, Enum.RenderPriority.Camera.Value + 1, updateShake)
end

-- ── Announcement banners (GDD §8.8, §10) ─────────────────────────────────

local function showBanner(a: Announcement)
	local view = ensureUi()
	local tier = a.rarity
	local color = if tier then Rarity.color(tier) else UiKit.PALETTE.accent
	local isSecret = a.kind == "Secret" or tier == Rarity.SECRET

	-- GDD §10's colour list ends "Secret red-black": Secret's rarity colour IS
	-- the red, so both halves of that treatment come out of Rarity.color and
	-- every other tier gets the same darkened-ground look for free.
	local ground = color:Lerp(Color3.new(0, 0, 0), if isSecret then SECRET_GROUND else BANNER_GROUND)

	local card = UiKit.frame({
		Parent = view.bannerHolder,
		Name = "Banner",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, -1.2),
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = ground,
		BackgroundTransparency = 0.05,
		Corner = 12,
		Stroke = color,
		Padding = 8,
	})

	local label = UiKit.label({
		Parent = card,
		Name = "Text",
		Size = UDim2.fromScale(1, 1),
		RichText = false,
		Text = a.text,
		TextColor3 = if isSecret then color else UiKit.PALETTE.text,
	})
	capText(label, 28)

	view.bannerHolder.Visible = true
	UiKit.tween(card, { Position = UDim2.fromScale(0.5, 0.5) }, BANNER_SLIDE, Enum.EasingStyle.Back)

	if a.shake then
		startShake()
	end
	if a.fanfare then
		cue("Fanfare")
	end

	if isSecret then
		local stroke = card:FindFirstChildOfClass("UIStroke")
		if stroke then
			task.spawn(function()
				-- Stops on its own when the card is destroyed below.
				while card.Parent do
					UiKit.tween(stroke, { Thickness = 6 }, 0.24)
					task.wait(0.26)
					UiKit.tween(stroke, { Thickness = 2 }, 0.24)
					task.wait(0.26)
				end
			end)
		end
	end

	task.wait(if #bannerQueue > 0 then BANNER_BUSY_SECONDS else BANNER_SECONDS)

	UiKit.tween(card, { Position = UDim2.fromScale(0.5, -1.2) }, BANNER_SLIDE)
	task.wait(BANNER_SLIDE)
	card:Destroy()

	if #bannerQueue == 0 then
		view.bannerHolder.Visible = false
	end
end

local function pumpBanners()
	if bannerPumping then
		return
	end
	bannerPumping = true
	task.spawn(function()
		while true do
			local next_ = table.remove(bannerQueue, 1)
			if not next_ then
				break
			end
			-- One bad banner must never stop the queue behind it.
			xpcall(showBanner, function(err: any)
				warn("[AlertController] banner failed: " .. tostring(err))
			end, next_)
		end
		bannerPumping = false
	end)
end

--[[
	Registry API. Queues a banner; two Legendaries in the same second play one
	after the other. The queue drops its OLDEST entry when it overflows, the
	same call AnnouncementService makes on its publish queue: a backlog of
	stale news is worse than a missing line.
]]
function AlertController.banner(announcement: Announcement)
	local a = validAnnouncement(announcement)
	if not a then
		return
	end
	table.insert(bannerQueue, a)
	if #bannerQueue > BANNER_QUEUE_MAX then
		table.remove(bannerQueue, 1)
	end
	pumpBanners()
end

-- ── Theft alerts and the compass (GDD §8.4.2) ────────────────────────────

--[[
	The thief's live position when their character is streamed in, and the
	last position the server sent when it is not. The fallback is refreshed
	from the character so a thief who streams out mid-chase leaves the arrow
	pointing where they actually were, not where they were a minute ago.
]]
local function thiefPoint(): Vector3?
	local userId = theft.userId
	if not userId then
		return theft.position
	end
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return theft.position
	end
	local root = Util.rootPart(player)
	if root then
		theft.position = root.Position
	end
	return theft.position
end

local function updateCompass()
	local view = ensureUi()
	local camera = workspace.CurrentCamera
	local target = thiefPoint()
	if not camera or not target then
		view.compass.Visible = false
		return
	end

	-- Flattened look vector: pitch must not tilt a compass that reads as a
	-- map bearing (GDD §8.4.2 "compass arrow").
	local look = camera.CFrame.LookVector
	local forward = Vector3.new(look.X, 0, look.Z)
	if forward.Magnitude < 1e-4 then
		forward = Vector3.new(0, 0, -1) -- looking straight up or down
	end
	forward = forward.Unit
	local right = Vector3.new(-forward.Z, 0, forward.X)

	local delta = target - camera.CFrame.Position
	local flat = Vector3.new(delta.X, 0, delta.Z)
	local angle = math.atan2(flat:Dot(right), flat:Dot(forward))

	local viewport = camera.ViewportSize
	local centreX = viewport.X * 0.5
	local centreY = viewport.Y * COMPASS_CENTRE_Y
	view.compass.Position = UDim2.fromOffset(
		centreX + math.sin(angle) * viewport.X * COMPASS_RADIUS_X,
		centreY - math.cos(angle) * viewport.Y * COMPASS_RADIUS_Y
	)
	view.compassArrow.Rotation = math.deg(angle)
	view.compassRange.Text = ("%dm"):format(math.floor(delta.Magnitude + 0.5))
	view.compass.Visible = true

	-- Free pulse: this step is already running for exactly as long as the
	-- alert is up, so the alarm card breathes without a second connection.
	local beat = 0.5 + 0.5 * math.sin(os.clock() * math.pi * THEFT_PULSE_HZ)
	view.theftCard.BackgroundColor3 = UiKit.PALETTE.danger:Lerp(Color3.new(0, 0, 0), 0.45 + beat * 0.25)
end

local function clearTheft()
	theft.active = false
	theft.userId = nil
	theft.position = nil
	theft.refreshedAt = 0

	if compassBound then
		compassBound = false
		RunService:UnbindFromRenderStep(COMPASS_BINDING)
	end

	local view = ui
	if not view then
		return
	end
	view.compass.Visible = false
	view.theftCard.Visible = false
end

local function beginTheft(alert: TheftAlert, position: Vector3?)
	local view = ensureUi()
	local tier = Rarity.clamp(alert.rarity)

	--[[
		StealService sends "Started" once and then "Tracking" every second with
		a fresh position. Rather than keying on the kind, this asks whether the
		theft is new to US: a client that rejoined mid-chase and only ever sees
		"Tracking" still gets its alarm, and a duplicate of either kind never
		alarms twice.
	]]
	local isNew = not theft.active
		or theft.userId ~= alert.thiefUserId
		or theft.mixlingName ~= alert.mixlingName

	theft.active = true
	theft.userId = alert.thiefUserId
	theft.rarity = tier
	theft.mixlingName = alert.mixlingName
	theft.refreshedAt = os.clock()
	if position then
		theft.position = position
	end

	view.theftTitle.Text = ("Your %s is being stolen!"):format(alert.mixlingName)
	view.theftSub.Text = ("%s  ·  %s"):format(Rarity.name(tier), alert.thiefName or "Someone")
	view.theftSub.TextColor3 = Rarity.color(tier)
	view.compassArrow.TextColor3 = Rarity.color(tier)
	view.theftCard.Visible = true

	if not compassBound then
		compassBound = true
		RunService:BindToRenderStep(COMPASS_BINDING, Enum.RenderPriority.Last.Value, updateCompass)
	end

	if not isNew then
		return
	end

	UiKit.pop(view.theftCard, 0.2)
	cue("Alarm")
end

--[[
	Terminal kinds each get one short line. The server also sends its own
	sentence over Notify for most of these; these stay deliberately short so
	the pair reads as a headline and a detail, not as a stutter.
]]
local function endTheft(alert: TheftAlert)
	clearTheft()
	if alert.kind == "Stolen" then
		showToast(("%s is gone."):format(alert.mixlingName), "Error")
		return
	end
	if alert.kind == "Dropped" then
		showToast(("%s was dropped!"):format(alert.mixlingName), "Info")
		return
	end
	showToast(("%s is home safe."):format(alert.mixlingName), "Success")
end

local function onTheftAlert(rawAlert: any, rawPosition: any)
	local alert = validTheftAlert(rawAlert)
	if not alert then
		return
	end
	local position = if typeof(rawPosition) == "Vector3" then rawPosition :: Vector3 else nil

	if alert.kind == "Started" or alert.kind == "Tracking" then
		beginTheft(alert, position)
		return
	end
	if alert.kind == "Intruder" then
		-- Nothing has been taken yet, so no alarm and no compass: a line is
		-- the whole alert.
		showToast(("%s is prowling your Den."):format(alert.thiefName or "Someone"), "Info")
		return
	end
	endTheft(alert)
end

-- ── Server Luck Party (GDD §9) ───────────────────────────────────────────

local function refreshLuck()
	local view = ensureUi()
	local remaining = math.max(luckEndsAt - os.time(), 0)
	view.luckLabel.Text = ("LUCK PARTY  +%s LUCK  ·  %s"):format(tostring(Util.round(luckAmount, 1)), Util.clock(remaining))
end

local function onServerLuck(rawLuck: any, rawEndsAt: any)
	local view = ensureUi()
	luckAmount = if type(rawLuck) == "number" then rawLuck else 0
	luckEndsAt = if type(rawEndsAt) == "number" then rawEndsAt else 0

	local wasActive = luckActive
	luckActive = luckAmount > 0 and luckEndsAt > os.time()
	view.luckCard.Visible = luckActive
	luckSecondShown = -1

	if not luckActive then
		return
	end
	refreshLuck()
	if not wasActive then
		UiKit.pop(view.luckCard, 0.2)
	end
end

-- ── The one heartbeat ────────────────────────────────────────────────────
-- Toast expiry, the luck countdown and the theft watchdog are all "check a
-- clock" work, so they share a connection instead of holding three.

local function onHeartbeat()
	local now = os.clock()

	for index = #toasts, 1, -1 do
		local entry = toasts[index]
		if entry and now >= entry.expiresAt then
			closeToast(entry)
		end
	end

	if luckActive then
		local remaining = luckEndsAt - os.time()
		if remaining <= 0 then
			luckActive = false
			local view = ui
			if view then
				view.luckCard.Visible = false
			end
		elseif math.floor(remaining) ~= luckSecondShown then
			luckSecondShown = math.floor(remaining)
			refreshLuck()
		end
	end

	-- A carry that stops refreshing has ended somewhere we did not hear about
	-- (a server hiccup, a joining player's first seconds). Better a compass
	-- that gives up than one that points at a thief who left.
	if theft.active and now - theft.refreshedAt > THEFT_STALE_SECONDS then
		clearTheft()
	end
end

-- ── Public API ───────────────────────────────────────────────────────────

--[[
	Registry API. `kind` follows the Notify channel names: "Error" reads red,
	"Code" green, everything else neutral (GDD §10).
]]
function AlertController.toast(text: string, kind: string?)
	if type(text) ~= "string" or text == "" then
		return
	end
	showToast(text, kind or "Info")
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

function AlertController.init(controllers: { [string]: any })
	sound = controllers.SoundController
end

function AlertController.start()
	ensureUi()

	Net.event("Announce").OnClientEvent:Connect(function(announcement: any)
		AlertController.banner(announcement)
	end)

	Net.event("Notify").OnClientEvent:Connect(function(kind: any, text: any, _data: any)
		if type(text) ~= "string" or text == "" then
			return
		end
		local channel = if type(kind) == "string" then kind else "Info"
		if channel == "Chat" and displayChatLine(text) then
			return
		end
		showToast(text, channel)
	end)

	Net.event("TheftAlert").OnClientEvent:Connect(onTheftAlert)

	Net.event("ServerLuck").OnClientEvent:Connect(onServerLuck)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return AlertController
