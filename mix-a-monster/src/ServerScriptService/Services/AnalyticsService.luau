--!strict
--[[
	AnalyticsService.luau — every KPI line the game emits. GDD §15.

	OWNS: the four telemetry entry points every other service calls, the
	per-player funnel ledger, and the per-server roll histogram used to check
	a playtest against the intended odds.

	  AnalyticsService.event(name, props?)
	  AnalyticsService.funnel(player, step)
	  AnalyticsService.economy(player, "Earn"|"Spend", source, amount)
	  AnalyticsService.roll(player, tier, luck)
	  AnalyticsService.readSummary() -> a snapshot of this server's aggregates

	WHY EVERY BACKEND CALL IS WRAPPED: Roblox's own AnalyticsService is absent
	in some contexts (older Studio settings, unpublished places, restricted
	universes) and its calls can throw. Telemetry is never load-bearing, so a
	failure here warns and degrades to local aggregates; it must never
	propagate into the remote handler that happened to be reporting. After a
	run of consecutive failures the backend is dropped entirely so a broken
	minute of Roblox infrastructure cannot fill the log.

	WHY THE FUNNEL IS DEDUPED AGAINST THE PROFILE: GDD §15 counts each step
	once per player, ever, not once per session. `profile.funnel` (step ->
	os.time() first reached) is the ledger, so a rejoin cannot re-count a step
	and inflate retention. Elapsed session seconds ride along with every step
	because the headline metric is a time — "first mix <= 30 s (median)" — and
	a step ordinal alone cannot answer it.

	This service is the first to boot and depends on nothing but DataService,
	which it uses read-only apart from that one funnel ledger write.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = ReplicatedStorage:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Config:WaitForChild("Constants"))
local Rarity = require(Config:WaitForChild("Rarity"))
local Net = require(Shared:WaitForChild("Net"))
local Util = require(Shared:WaitForChild("Util"))

local AnalyticsService = {}
AnalyticsService.Name = "AnalyticsService"

local JOB_ID = if game.JobId ~= "" then game.JobId else "studio-" .. tostring(math.random(1, 1e9))
local IS_STUDIO = RunService:IsStudio()
local SERVER_START = os.clock()

-- Dashboard labels, not balance values: the funnel's name and the currency
-- name are how these rows are grouped in Roblox's analytics UI.
local FUNNEL_NAME = "Onboarding"
local CURRENCY = "Goop"

-- Roblox allows exactly these three free-form columns per event.
local CUSTOM_FIELD_KEYS = {
	Enum.AnalyticsCustomFieldKeys.CustomField01.Name,
	Enum.AnalyticsCustomFieldKeys.CustomField02.Name,
	Enum.AnalyticsCustomFieldKeys.CustomField03.Name,
}

-- Not balance numbers, so they are not in Constants:
-- how much of a stringified prop survives into a dashboard column,
-- how many consecutive backend failures disable telemetry, and
-- how many per-step timings are kept for the median in readSummary.
local FIELD_TEXT_LIMIT = 64
local BACKEND_FAILURE_LIMIT = 5
local FUNNEL_SAMPLE_CAP = 256

-- ── Backend ──────────────────────────────────────────────────────────────
-- Typed `any` on purpose: the handle is nilled out when telemetry is
-- disabled, and every call goes through `send` rather than being type-checked
-- at each site.

local backend: any = nil
local backendFailures = 0

do
	local ok, service = pcall(function()
		return game:GetService("AnalyticsService")
	end)
	if ok then
		backend = service
	else
		warn("[Analytics] Roblox AnalyticsService unavailable; this server keeps local aggregates only.")
	end
end

local function send(what: string, fn: () -> ())
	if not backend then
		return
	end
	-- The wrapper's declared `any` return is what makes pcall hand back the
	-- error text; pcall over a function that returns nothing yields only the
	-- success flag.
	local ok, err = pcall(function(): any
		fn()
		return nil
	end)
	if ok then
		backendFailures = 0
		return
	end

	backendFailures += 1
	if backendFailures == 1 then
		warn(("[Analytics] %s failed: %s"):format(what, tostring(err)))
	end
	if backendFailures >= BACKEND_FAILURE_LIMIT then
		backend = nil
		warn(("[Analytics] telemetry disabled after %d consecutive failures; aggregates still work."):format(backendFailures))
	end
end

-- ── Aggregates ───────────────────────────────────────────────────────────
-- Per server, in memory, reset on restart. This is what makes a solo
-- playtest readable without waiting a day for a dashboard.

type Session = { joinedAt: number, sessionId: string }
type FunnelStat = { reached: number, sum: number, samples: { number } }
type EconomyStat = { earned: number, spent: number, events: number }

local data: any = nil
local sessions: { [Player]: Session } = {}

local rollsByTier: { number } = table.create(#Constants.RARITY, 0)
local rollCount = 0
local luckSum = 0
local epicPlus = 0
local lastEpicPlusAt = 0
local funnelStats: { [string]: FunnelStat } = {}
local economyStats: { [string]: EconomyStat } = {}
local eventCounts: { [string]: number } = {}

local STEP_INDEX: { [string]: number } = {}
for index, step in Constants.FUNNEL_STEPS do
	STEP_INDEX[step] = index
end

-- ── Formatting ───────────────────────────────────────────────────────────

local function studio(line: string)
	if not IS_STUDIO then
		return
	end
	print("[Analytics] " .. line)
end

local function fieldText(value: any): string
	local text: string
	if typeof(value) == "Instance" then
		text = value.Name
	elseif type(value) == "number" then
		text = tostring(Util.round(value, 3))
	else
		text = tostring(value)
	end
	if #text > FIELD_TEXT_LIMIT then
		text = text:sub(1, FIELD_TEXT_LIMIT)
	end
	return text
end

--[[
	Flattens props into Roblox's three columns in a stable (sorted) key order,
	so a given column always means the same thing across events of one name.
	`player` and `value` are excluded: they have dedicated argument slots.
]]
local function customFields(props: { [string]: any }?): { [string]: any }?
	if not props then
		return nil
	end
	local keys: { string } = {}
	for key, value in props do
		if key ~= "player" and key ~= "value" and value ~= nil then
			table.insert(keys, key)
		end
	end
	if #keys == 0 then
		return nil
	end
	table.sort(keys)

	local fields: { [string]: any } = {}
	for index = 1, math.min(#keys, #CUSTOM_FIELD_KEYS) do
		local key = keys[index]
		fields[CUSTOM_FIELD_KEYS[index]] = key .. "=" .. fieldText(props[key])
	end
	return fields
end

-- The Studio line keeps every prop, unlike the three-column backend form.
local function describe(props: { [string]: any }?): string
	if not props then
		return ""
	end
	local parts: { string } = {}
	for key, value in props do
		if key ~= "player" then
			table.insert(parts, key .. "=" .. fieldText(value))
		end
	end
	table.sort(parts)
	return table.concat(parts, " ")
end

local function playerOf(props: { [string]: any }?): Player?
	if not props then
		return nil
	end
	local candidate = props.player
	if typeof(candidate) == "Instance" and candidate:IsA("Player") then
		return candidate
	end
	return nil
end

-- ── Sessions ─────────────────────────────────────────────────────────────
-- Created on join, but lazily too: a funnel step must never be lost just
-- because it beat the PlayerAdded connection.

local function sessionFor(player: Player): Session
	local existing = sessions[player]
	if existing then
		return existing
	end
	local session: Session = {
		joinedAt = os.clock(),
		-- Groups one player's steps into one journey on the dashboard.
		sessionId = ("%s:%d:%d"):format(JOB_ID, player.UserId, os.time()),
	}
	sessions[player] = session
	return session
end

-- ── Public API ───────────────────────────────────────────────────────────

--[[
	Generic telemetry line. `props.player` scopes the event to a player and
	`props.value` supplies the numeric slot; everything else becomes a column.

	Roblox's custom events are player-scoped, so a server-wide line (a failed
	save, a boot warning) can only reach the log and the local aggregates.
]]
function AnalyticsService.event(name: string, props: { [string]: any }?)
	if not Net.isString(name) then
		warn("[Analytics] event() called with a bad name: " .. tostring(name))
		return
	end
	eventCounts[name] = (eventCounts[name] or 0) + 1

	local player = playerOf(props)
	local value = 0
	if props ~= nil and Net.isFiniteNumber(props.value) then
		value = props.value
	end

	studio(("event  %-16s %-14s %s"):format(name, if player then player.Name else "-", describe(props)))

	if not player then
		return
	end
	local fields = customFields(props)
	send("LogCustomEvent " .. name, function()
		backend:LogCustomEvent(player, name, value, fields)
	end)
end

--[[
	Advances `player` through Constants.FUNNEL_STEPS. At most once per player
	per step, ever — the ledger is `profile.funnel`, so the dedupe survives a
	rejoin and a server hop.
]]
function AnalyticsService.funnel(player: Player, step: string)
	if not Net.isString(step) then
		warn("[Analytics] funnel() called with a bad step: " .. tostring(step))
		return
	end
	local index = STEP_INDEX[step]
	if not index then
		warn(("[Analytics] unknown funnel step %q; it must be listed in Constants.FUNNEL_STEPS"):format(step))
		return
	end

	local profile = if data then data.get(player) else nil
	if not profile then
		-- With no ledger there is no way to tell a first arrival from a
		-- rejoin, and a double-counted step quietly corrupts retention.
		-- Dropping the line is the honest failure.
		warn(("[Analytics] funnel %s dropped for %s: profile not loaded yet"):format(step, player.Name))
		return
	end
	if profile.funnel[step] then
		return
	end
	profile.funnel[step] = os.time()

	local session = sessionFor(player)
	local seconds = Util.round(os.clock() - session.joinedAt, 2)

	local stat = funnelStats[step]
	if not stat then
		stat = { reached = 0, sum = 0, samples = {} }
		funnelStats[step] = stat
	end
	stat.reached += 1
	stat.sum += seconds
	if #stat.samples < FUNNEL_SAMPLE_CAP then
		table.insert(stat.samples, seconds)
	end

	studio(("funnel %d/%d %-14s %-14s t+%.1fs"):format(index, #Constants.FUNNEL_STEPS, step, player.Name, seconds))

	send("LogFunnelStepEvent " .. step, function()
		backend:LogFunnelStepEvent(player, FUNNEL_NAME, session.sessionId, index, step)
	end)
	-- LogFunnelStepEvent has no numeric slot, and GDD §15's headline metric is
	-- a time ("first mix <= 30 s median"), so the elapsed seconds go out as a
	-- custom event alongside the step itself.
	send("LogCustomEvent FunnelSeconds", function()
		backend:LogCustomEvent(player, "FunnelSeconds", seconds, {
			[CUSTOM_FIELD_KEYS[1]] = "step=" .. step,
			[CUSTOM_FIELD_KEYS[2]] = "index=" .. tostring(index),
		})
	end)
end

--[[
	One Goop source or sink. GDD §8.2's target curve is tuned from these rows,
	so `source` is passed through as the transaction type verbatim rather than
	being flattened into one of Roblox's generic buckets — the whole point is
	to see which sources pay and which sinks bite.
]]
function AnalyticsService.economy(player: Player, kind: string, source: string, amount: number)
	if not Net.isString(kind) or not Net.isString(source) or not Net.isFiniteNumber(amount) then
		warn(("[Analytics] economy() called with bad arguments: %s / %s"):format(tostring(kind), tostring(source)))
		return
	end
	if kind ~= "Earn" and kind ~= "Spend" then
		warn(("[Analytics] economy() kind must be Earn or Spend, got %q"):format(kind))
		return
	end
	-- Callers pass a positive magnitude; a stray sign must not subtract from
	-- the curve it is supposed to be measuring.
	local magnitude = math.abs(amount)

	local stat = economyStats[source]
	if not stat then
		stat = { earned = 0, spent = 0, events = 0 }
		economyStats[source] = stat
	end
	stat.events += 1
	if kind == "Earn" then
		stat.earned += magnitude
	else
		stat.spent += magnitude
	end

	-- Read straight off the profile rather than through EconomyService: this
	-- service depends on nothing else, and the balance is only a data point.
	local profile = if data then data.get(player) else nil
	local balance = if profile then profile.goop else 0
	local flow = if kind == "Earn" then Enum.AnalyticsEconomyFlowType.Source else Enum.AnalyticsEconomyFlowType.Sink

	studio(("%-6s %-16s %8s Goop  %-14s bal %s"):format(
		kind,
		source,
		Util.abbreviate(magnitude),
		player.Name,
		Util.abbreviate(balance)
	))

	send("LogEconomyEvent " .. source, function()
		backend:LogEconomyEvent(player, flow, CURRENCY, magnitude, balance, source)
	end)
end

--[[
	One roll outcome plus the luck it was rolled at. The weights in
	Constants.RARITY are tuned against these two numbers together — an Epic
	rate means nothing without the luck that produced it (GDD §15: "Epic+ roll
	every ~4 min per server").
]]
function AnalyticsService.roll(player: Player, tier: number, luck: number)
	if not Net.isIntInRange(tier, 1, #Constants.RARITY) then
		warn("[Analytics] roll() called with a bad tier: " .. tostring(tier))
		return
	end
	local safeLuck = if Net.isFiniteNumber(luck) then luck else 0

	rollCount += 1
	rollsByTier[tier] += 1
	luckSum += safeLuck
	if tier >= Constants.RARITY_EPIC then
		epicPlus += 1
		lastEpicPlusAt = os.clock()
	end

	studio(("roll   %-10s (t%d) luck %.2f  %s"):format(Rarity.name(tier), tier, safeLuck, player.Name))

	send("LogCustomEvent Roll", function()
		backend:LogCustomEvent(player, "Roll", tier, {
			[CUSTOM_FIELD_KEYS[1]] = "rarity=" .. Rarity.name(tier),
			[CUSTOM_FIELD_KEYS[2]] = ("luck=%.2f"):format(safeLuck),
			[CUSTOM_FIELD_KEYS[3]] = "tier=" .. tostring(tier),
		})
	end)
end

-- ── Summary ──────────────────────────────────────────────────────────────

local function median(samples: { number }): number
	local count = #samples
	if count == 0 then
		return 0
	end
	local sorted = table.clone(samples)
	table.sort(sorted)
	if count % 2 == 1 then
		return sorted[(count + 1) // 2]
	end
	return (sorted[count // 2] + sorted[count // 2 + 1]) / 2
end

--[[
	A snapshot of this server's aggregates. `tiers[i].share` is what actually
	happened and `tiers[i].expected` is Rarity.odds() at the mean luck rolled,
	so a playtest is checked against the intended distribution by reading two
	columns side by side. Secret (tier 7) has no weighted odds — it is
	recipe-only — so its expected share is 0 by design.

	Returns fresh tables; callers may not mutate the live counters.
]]
function AnalyticsService.readSummary(): { [string]: any }
	local uptime = os.clock() - SERVER_START
	local meanLuck = if rollCount > 0 then luckSum / rollCount else 0
	local expected = Rarity.odds(meanLuck)

	local tiers = {}
	for tier = 1, #Constants.RARITY do
		local count = rollsByTier[tier]
		table.insert(tiers, {
			tier = tier,
			name = Rarity.name(tier),
			count = count,
			share = if rollCount > 0 then Util.round(count / rollCount, 4) else 0,
			expected = Util.round(expected[tier] or 0, 4),
		})
	end

	local funnel = {}
	for _, step in Constants.FUNNEL_STEPS do
		local stat = funnelStats[step]
		funnel[step] = {
			reached = if stat then stat.reached else 0,
			meanSeconds = if stat and stat.reached > 0 then Util.round(stat.sum / stat.reached, 2) else 0,
			medianSeconds = if stat then Util.round(median(stat.samples), 2) else 0,
		}
	end

	return {
		jobId = JOB_ID,
		uptimeSeconds = Util.round(uptime, 1),
		telemetry = backend ~= nil,
		players = #Players:GetPlayers(),

		rolls = rollCount,
		meanLuck = Util.round(meanLuck, 3),
		tiers = tiers,
		epicPlus = epicPlus,
		secondsPerEpicPlus = if epicPlus > 0 then Util.round(uptime / epicPlus, 1) else 0,
		sinceLastEpicPlus = if lastEpicPlusAt > 0 then Util.round(os.clock() - lastEpicPlusAt, 1) else 0,

		funnel = funnel,
		economy = Util.deepCopy(economyStats),
		events = Util.deepCopy(eventCounts),
	}
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

function AnalyticsService.init(services: { [string]: any })
	data = services.DataService
end

function AnalyticsService.start()
	-- Analytics boots first, so it sees PlayerAdded before any service that
	-- could report a funnel step for that player.
	for _, player in Players:GetPlayers() do
		sessionFor(player)
	end
	Players.PlayerAdded:Connect(function(player)
		sessionFor(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		local session = sessions[player]
		sessions[player] = nil
		if not session then
			return
		end
		AnalyticsService.event("SessionEnd", {
			player = player,
			value = Util.round(os.clock() - session.joinedAt, 1),
		})
	end)
end

return AnalyticsService
