--!strict
--[[
	AnnouncementService.luau — the hype machine. GDD §8.8, §7.3, §7.4.

	OWNS: every banner line the game shows itself. Four delivery routes over
	the one "Announce" remote —

	  toPlayer(player, a)              one person
	  nearby(position, radius, a)      everyone standing near a thing
	  server(a)                        this server
	  global(a)                        every server, via MessagingService

	— plus `forRoll`, the routing table that turns a roll into whichever of
	those the rarity deserves. `forRoll` is the ONLY entry point MixerService
	needs: the "which tier shouts how loud" decision lives here, once, driven
	by Constants.RARITY[tier].announce, so re-tuning the noise floor is a
	one-line change in Constants.

	TWO NON-OBVIOUS DECISIONS:

	1. Global announcements are stamped with this server's JobId and dropped
	   on receipt if the stamp is ours. MessagingService echoes a published
	   message back to the publisher, so without the stamp every Secret would
	   banner twice on the server that rolled it.

	2. PublishAsync is quota'd per server (and going over throttles the topic
	   for everyone in the experience, not just us). Globals therefore go
	   through a small queue drained at most once every GLOBAL_MIN_INTERVAL
	   seconds, and the queue drops its OLDEST entry when it overflows. A
	   dropped banner is invisible; a throttled MessagingService is a dead
	   feature for the whole game.

	Everything that talks to Roblox infrastructure (MessagingService,
	TextChatService) is wrapped in pcall and degrades to "no banner" rather
	than erroring into a caller mid-roll — the roll is never interrupted
	(GDD §2, pillar 1).
]]

local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Config = ReplicatedStorage:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rarity = require(Config:WaitForChild("Rarity"))
local Net = require(Shared:WaitForChild("Net"))
local Types = require(Shared:WaitForChild("Types"))
local Util = require(Shared:WaitForChild("Util"))

type Announcement = Types.Announcement
type MixlingView = Types.MixlingView

local AnnouncementService = {}
AnnouncementService.Name = "AnnouncementService"

-- ── Tunables ─────────────────────────────────────────────────────────────
-- None of these are balance values, so none of them are in Constants: they
-- are platform limits and presentation caps. The one exception worth calling
-- out is LOCAL_RADIUS, which is a design number the GDD gives in prose only.

local TOPIC = "MixAMonster_Announce_v1" -- bump the suffix if the payload shape ever changes
local GLOBAL_MIN_INTERVAL = 2 -- seconds between PublishAsync calls; see decision 2 above
local GLOBAL_QUEUE_MAX = 8 -- pending globals before the oldest is dropped
local DRAIN_POLL = 0.25 -- how often the drain loop looks at the queue
local WARN_INTERVAL = 30 -- seconds between repeated MessagingService complaints
local SUBSCRIBE_ATTEMPTS = 4
local SUBSCRIBE_BACKOFF = 2
local MAX_TEXT = 140 -- characters; keeps a payload far under the 1 KB MessagingService limit and a banner on one line
local MAX_NAME = 64 -- generous ceiling for a display name inside a payload
local LOCAL_RADIUS = 90 -- studs for a "Local" roll: the plaza (60) plus a walk toward the den ring, i.e. everyone who could plausibly have watched it
local CHAT_PREFIX = "[Blendburg] "
local CHAT_MIN_RARITY = Rarity.MYTHIC -- Mythic and Secret also get a chat line (GDD §7.3)

-- MessagingService echoes our own publishes back to us. JobId is empty in
-- Studio, so fall back to a random id the way DataService does for its
-- session lock — two Studio instances must still be able to tell each other
-- apart.
local JOB_ID = if game.JobId ~= "" then game.JobId else "studio-" .. tostring(math.random(1, 1e9))

local KINDS: { [string]: boolean } = {
	Roll = true,
	Secret = true,
	Steal = true,
	LuckParty = true,
	Milestone = true,
	System = true,
}

local SCOPES: { [string]: boolean } = { Local = true, Server = true, Global = true }

-- ── State ────────────────────────────────────────────────────────────────

local analytics: any = nil
local queue: { Announcement } = {}
local lastPublishAt = 0
local lastWarnAt = 0

-- ── Shaping ──────────────────────────────────────────────────────────────
-- Every announcement, wherever it came from, is rebuilt into a known-good
-- table before it reaches a client. Callers are server code, but a banner
-- built from a player's display name is still player-influenced text, and a
-- global one arrived over the wire from another server.

local function clip(text: string): string
	if #text <= MAX_TEXT then
		return text
	end
	-- Cut on a codepoint boundary: half a UTF-8 sequence renders as garbage
	-- and can break the whole TextLabel, not just the truncated word.
	local boundary = utf8.offset(text, 0, MAX_TEXT)
	local stop = if boundary then boundary - 1 else MAX_TEXT
	return text:sub(1, stop) .. "..."
end

--[[
	Returns a fresh, validated Announcement stamped with `scope`, or nil when
	there is nothing worth showing. The scope is stamped rather than trusted
	so a caller cannot mislabel a personal toast as a server banner.
]]
local function normalize(a: Announcement, scope: string): Announcement?
	if not Net.isString(a.text, MAX_TEXT * 4) then
		return nil
	end

	local kind = if Net.isString(a.kind, 32) and KINDS[a.kind] then a.kind else "System"
	local playerName = if Net.isString(a.playerName, MAX_NAME) then a.playerName else nil
	local rarity = if Net.isIntInRange(a.rarity, 1, #Rarity.Tiers) then a.rarity else nil

	local shaped: Announcement = {
		scope = (if SCOPES[scope] then scope else "Server") :: any,
		kind = kind :: any,
		text = clip(a.text),
		rarity = rarity,
		playerName = playerName,
		shake = a.shake == true,
		fanfare = a.fanfare == true,
	}
	return shaped
end

--[[
	Validates a payload that arrived from another server. Anything malformed
	is dropped outright rather than coerced — a cross-server line is the one
	input here we did not build ourselves.
]]
local function decode(raw: any): Announcement?
	if type(raw) ~= "table" then
		return nil
	end
	if not Net.isString(raw.text, MAX_TEXT * 4) then
		return nil
	end
	if not Net.isString(raw.kind, 32) or not KINDS[raw.kind] then
		return nil
	end
	if raw.rarity ~= nil and not Net.isIntInRange(raw.rarity, 1, #Rarity.Tiers) then
		return nil
	end
	if raw.playerName ~= nil and not Net.isString(raw.playerName, MAX_NAME) then
		return nil
	end
	if raw.shake ~= nil and not Net.isBoolean(raw.shake) then
		return nil
	end
	if raw.fanfare ~= nil and not Net.isBoolean(raw.fanfare) then
		return nil
	end
	return normalize(raw :: any, "Global")
end

-- Falls back through secret name -> display name -> rebuilt "{Prefix} {Stuff}
-- {Critter}", so a caller that hands over a raw Mixling instead of a view
-- still produces a readable line instead of an empty banner.
local function mixlingLabel(view: MixlingView, tier: number): string
	if Net.isString(view.secretName, MAX_NAME) then
		return view.secretName :: string
	end
	if Net.isString(view.displayName, MAX_NAME) then
		return view.displayName
	end
	if Net.isString(view.critter, 32) and Net.isString(view.stuff, 32) then
		return Rarity.displayName(tier, view.critter, view.stuff)
	end
	return "Mixling"
end

-- ── Chat ─────────────────────────────────────────────────────────────────

--[[
	The chat half of "server banner + fanfare + chat message" (GDD §7.3).

	TextChatService's system-message API is a client-side call in every
	current place, so the direct attempt is expected to fail on the server —
	it is kept because the surface differs between legacy, TextChatService and
	hybrid places, and where it does work it is the cheapest path. When it
	does not, the line goes out on the existing Notify remote with kind
	"Chat"; the client renders it into the chat window. Adding a remote for
	this would be a bug (Net.luau is the whole surface).
]]
local function chatBroadcast(text: string)
	local delivered = false
	pcall(function()
		if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
			return
		end
		local channels = TextChatService:FindFirstChild("TextChannels")
		if not channels then
			return
		end
		local general = channels:FindFirstChild("RBXGeneral")
		if not general or not general:IsA("TextChannel") then
			return
		end
		general:DisplaySystemMessage(text)
		delivered = true
	end)
	if not delivered then
		Net.fireAll("Notify", "Chat", text)
	end
end

local function maybeChat(a: Announcement)
	if (a.rarity or 0) < CHAT_MIN_RARITY then
		return
	end
	chatBroadcast(CHAT_PREFIX .. a.text)
end

-- ── Cross-server pipe ────────────────────────────────────────────────────

local function warnMessaging(message: string)
	local now = os.clock()
	if now - lastWarnAt < WARN_INTERVAL then
		return -- one voice every WARN_INTERVAL; an outage must not flood the log
	end
	lastWarnAt = now
	local hint = if RunService:IsStudio()
		then " (MessagingService does not run in Studio; globals stay server-local here)"
		else ""
	warn("[AnnouncementService] " .. message .. hint)
end

local function publish(a: Announcement)
	-- Stamped before the call, not after: a failed publish still spent its
	-- share of the quota, so it must still cost us the interval.
	lastPublishAt = os.clock()
	local ok, err = pcall(function()
		MessagingService:PublishAsync(TOPIC, { jobId = JOB_ID, sentAt = os.time(), a = a })
	end)
	if ok then
		return
	end
	warnMessaging("global publish failed: " .. tostring(err))
	if analytics then
		analytics.event("AnnouncePublishFailed", { kind = a.kind, rarity = a.rarity })
	end
end

local function enqueue(a: Announcement)
	table.insert(queue, a)
	if #queue <= GLOBAL_QUEUE_MAX then
		return
	end
	local dropped = table.remove(queue, 1)
	warnMessaging("global queue full; dropped the oldest banner")
	if analytics and dropped then
		analytics.event("AnnounceDropped", { kind = dropped.kind, rarity = dropped.rarity })
	end
end

local function drain()
	if #queue == 0 then
		return
	end
	if os.clock() - lastPublishAt < GLOBAL_MIN_INTERVAL then
		return
	end
	local next_ = table.remove(queue, 1)
	if next_ then
		publish(next_)
	end
end

local function onRemoteMessage(message: any)
	local data = if type(message) == "table" then message.Data else nil
	if type(data) ~= "table" then
		return
	end
	if data.jobId == JOB_ID then
		return -- our own line; the local banner already fired through server()
	end
	local a = decode(data.a)
	if not a then
		return
	end
	Net.fireAll("Announce", a)
	maybeChat(a)
end

-- ── Public API ───────────────────────────────────────────────────────────

function AnnouncementService.toPlayer(player: Player, a: Announcement)
	if not player.Parent then
		return
	end
	-- A directed line keeps whatever scope the caller chose (a late joiner
	-- can be shown the server banner it missed); anything unlabelled is a
	-- personal toast.
	local shaped = normalize(a, if SCOPES[a.scope] then a.scope else "Local")
	if not shaped then
		return
	end
	Net.fire(player, "Announce", shaped)
end

function AnnouncementService.nearby(position: Vector3, radius: number, a: Announcement)
	if typeof(position) ~= "Vector3" or not Net.isFiniteNumber(radius) or radius <= 0 then
		return
	end
	local shaped = normalize(a, "Local")
	if not shaped then
		return
	end

	local limit = radius * radius
	for _, player in Players:GetPlayers() do
		local root = Util.rootPart(player)
		if root then
			local delta = root.Position - position
			if delta:Dot(delta) <= limit then -- squared compare; no sqrt per player
				Net.fire(player, "Announce", shaped)
			end
		end
	end
end

function AnnouncementService.server(a: Announcement)
	local shaped = normalize(a, "Server")
	if not shaped then
		return
	end
	Net.fireAll("Announce", shaped)
	maybeChat(shaped)
end

--[[
	Queues a line for every server in the experience. This does NOT show it
	locally — the sender pairs it with `server()` (as `forRoll` does) so the
	local banner is instant and never waits on the publish interval.
]]
function AnnouncementService.global(a: Announcement)
	local shaped = normalize(a, "Global")
	if not shaped then
		return
	end
	enqueue(shaped)
end

--[[
	The routing table (GDD §8.8). Rarity decides the volume:

	  None   nothing at all — Common and Uncommon are not news
	  Local  a shout to the people who could see it happen
	  Server this server's banner; shake at Legendary+, fanfare at Mythic+
	  Global the DISCOVERED feed (GDD §7.4): Secret only, every server, plus
	         our own banner so the roller's server sees it immediately
]]
function AnnouncementService.forRoll(player: Player, mixling: MixlingView, tier: number)
	local rarity = Rarity.clamp(if Net.isFiniteNumber(tier) then tier else mixling.rarity)
	local scope = Rarity.announceScope(rarity)
	if scope == "None" then
		return
	end

	local who = player.DisplayName
	local what = mixlingLabel(mixling, rarity)
	local isSecret = rarity == Rarity.SECRET or Net.isString(mixling.secretId, MAX_NAME)

	local text: string
	if scope == "Local" then
		text = ("%s mixed a %s!"):format(who, what)
	elseif isSecret then
		text = ("SECRET DISCOVERED! %s just unlocked %s!"):format(who, what)
	else
		text = ("%s! %s just mixed a %s!"):format(Rarity.name(rarity):upper(), who, what)
	end

	local a: Announcement = {
		scope = scope :: any,
		kind = (if isSecret then "Secret" else "Roll") :: any,
		text = text,
		rarity = rarity,
		playerName = who,
		shake = rarity >= Rarity.LEGENDARY,
		fanfare = rarity >= Rarity.MYTHIC,
	}

	if scope == "Local" then
		local root = Util.rootPart(player)
		if not root then
			-- Rolled while dead or still loading a character: the moment is
			-- still theirs, so at least they see it.
			AnnouncementService.toPlayer(player, a)
			return
		end
		AnnouncementService.nearby(root.Position, LOCAL_RADIUS, a)
		return
	end

	if scope == "Global" then
		AnnouncementService.global(a)
	end
	AnnouncementService.server(a)
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

function AnnouncementService.init(services: { [string]: any })
	-- Nothing here is load-bearing: analytics is used for drop/failure lines
	-- only, and a banner must never depend on a sibling being present.
	analytics = services.AnalyticsService
end

function AnnouncementService.start()
	task.spawn(function()
		local ok, result = Util.retry(SUBSCRIBE_ATTEMPTS, SUBSCRIBE_BACKOFF, function()
			return MessagingService:SubscribeAsync(TOPIC, onRemoteMessage)
		end)
		if not ok then
			warnMessaging("could not subscribe to " .. TOPIC .. "; this server will not receive globals: " .. tostring(result))
			if analytics then
				analytics.event("AnnounceSubscribeFailed", { topic = TOPIC })
			end
		end
	end)

	task.spawn(function()
		while true do
			task.wait(DRAIN_POLL)
			drain()
		end
	end)
end

return AnnouncementService
