--!strict
--[[
	Net.luau — the complete remote surface plus its guard rails (GDD §11.3).

	Rules this module exists to enforce:
	  * Clients send INTENTS only. Every name in CLIENT_TO_SERVER is a request
	    the server is free to refuse.
	  * Every client->server remote has a per-player sliding-window rate limit
	    (Constants.RATE_LIMITS) and full argument validation.
	  * Adding a remote anywhere else in the codebase is a bug. If it is not
	    listed here, it does not exist.

	The server creates the folder and its children on boot; the client waits
	for them. Nothing in here reveals a secret recipe.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Constants = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("Constants"))

local FOLDER_NAME = "MixNet"
local IS_SERVER = RunService:IsServer()

local Net = {}

-- ── Remote inventory ─────────────────────────────────────────────────────

-- Client fires these. Server validates, rate-limits, and decides.
Net.CLIENT_TO_SERVER = {
	"RequestMix", -- (critter: string, stuff: string)
	"RequestPlace", -- (mixlingId: string, pedestalIndex: number)
	"RequestUnplace", -- (mixlingId: string)
	"RequestPurchase", -- (kind: string, id: string)
	"RequestLock", -- ()
	"RequestDropCarried", -- ()
	"RequestBonk", -- ()  "I swung"; server validates distance + cooldown
	"RedeemCode", -- (code: string)
	"ClaimDaily", -- ()
	"SetSetting", -- (key: string, value: boolean)
	"RequestTeleport", -- (destination: string)
	"TutorialStep", -- (step: string)
}

-- Server fires these. The client may only render them.
Net.SERVER_TO_CLIENT = {
	"ProfileSync", -- (patch: { [string]: any }, full: boolean)
	"MixResult", -- (result: Types.MixResult)
	"Announce", -- (announcement: Types.Announcement)
	"Notify", -- (kind: string, text: string, data: any?)
	"TheftAlert", -- (alert: Types.TheftAlert, position: Vector3?)
	"DenSync", -- (dens: { Types.DenPublic })
	"LeaderboardSync", -- (boards: { [string]: { Types.LeaderboardEntry } })
	"CarryState", -- (carrying: Types.MixlingView?)
	"ServerLuck", -- (luck: number, endsAt: number)
}

-- Pull-based reads. The server handler must never yield on a client thread.
Net.FUNCTIONS = {
	"Query", -- (kind: string, arg: any?) -> any
}

-- ── Folder plumbing ──────────────────────────────────────────────────────

local folder: Folder? = nil

local function ensureFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	if IS_SERVER then
		local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if existing and existing:IsA("Folder") then
			folder = existing
			return existing
		end
		local created = Instance.new("Folder")
		created.Name = FOLDER_NAME
		for _, name in Net.CLIENT_TO_SERVER do
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = created
		end
		for _, name in Net.SERVER_TO_CLIENT do
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = created
		end
		for _, name in Net.FUNCTIONS do
			local remote = Instance.new("RemoteFunction")
			remote.Name = name
			remote.Parent = created
		end
		created.Parent = ReplicatedStorage
		folder = created
		return created
	end
	local waited = ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder
	folder = waited
	return waited
end

Net.init = ensureFolder

function Net.event(name: string): RemoteEvent
	local parent = ensureFolder()
	local remote = if IS_SERVER then parent:FindFirstChild(name) else parent:WaitForChild(name, 30)
	assert(remote and remote:IsA("RemoteEvent"), "Net: no RemoteEvent named " .. name)
	return remote
end

function Net.func(name: string): RemoteFunction
	local parent = ensureFolder()
	local remote = if IS_SERVER then parent:FindFirstChild(name) else parent:WaitForChild(name, 30)
	assert(remote and remote:IsA("RemoteFunction"), "Net: no RemoteFunction named " .. name)
	return remote
end

-- ── Rate limiting (server only) ──────────────────────────────────────────
-- Sliding window of Constants.RATE_WINDOW seconds. Over budget => the call is
-- dropped silently; the client is never told the limit, so probing is dull.

local buckets: { [number]: { [string]: { number } } } = {}

if IS_SERVER then
	Players.PlayerRemoving:Connect(function(player)
		buckets[player.UserId] = nil
	end)
end

--[[
	Returns true when the call is within budget. Call this FIRST in every
	server-side remote handler, before touching arguments.
]]
function Net.consume(player: Player, remoteName: string): boolean
	if not IS_SERVER then
		return true
	end
	local limit = Constants.RATE_LIMITS[remoteName]
	if not limit then
		return true
	end

	local byPlayer = buckets[player.UserId]
	if not byPlayer then
		byPlayer = {}
		buckets[player.UserId] = byPlayer
	end

	local stamps = byPlayer[remoteName]
	if not stamps then
		stamps = {}
		byPlayer[remoteName] = stamps
	end

	local now = os.clock()
	local cutoff = now - Constants.RATE_WINDOW
	local kept = 0
	for index = 1, #stamps do
		local stamp = stamps[index]
		if stamp > cutoff then
			kept += 1
			stamps[kept] = stamp
		end
	end
	for index = #stamps, kept + 1, -1 do
		stamps[index] = nil
	end

	if kept >= limit then
		return false
	end
	table.insert(stamps, now)
	return true
end

-- ── Argument validation ──────────────────────────────────────────────────
-- Deliberately paranoid: a remote handler may only work with values that
-- survive these. Exploiters send tables, NaN, huge strings and nil.

local MAX_STRING = 64

function Net.isString(value: any, maxLength: number?): boolean
	return type(value) == "string" and #value > 0 and #value <= (maxLength or MAX_STRING)
end

function Net.isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Net.isIntInRange(value: any, minimum: number, maximum: number): boolean
	if not Net.isFiniteNumber(value) then
		return false
	end
	local number = value :: number
	return number % 1 == 0 and number >= minimum and number <= maximum
end

function Net.isBoolean(value: any): boolean
	return type(value) == "boolean"
end

--[[
	Wraps a server handler with rate limiting and a pcall boundary so a
	malformed payload can never kill the connection for everyone else.
]]
function Net.onServerEvent(name: string, handler: (Player, ...any) -> ())
	assert(IS_SERVER, "Net.onServerEvent is server-only")
	local remote = Net.event(name)
	remote.OnServerEvent:Connect(function(player, ...)
		if not Net.consume(player, name) then
			return
		end
		local args = table.pack(...)
		local ok, err = pcall(function()
			handler(player, table.unpack(args, 1, args.n))
		end)
		if not ok then
			warn(("[Net] %s handler error for %s: %s"):format(name, player.Name, tostring(err)))
		end
	end)
end

function Net.onServerInvoke(name: string, handler: (Player, ...any) -> any)
	assert(IS_SERVER, "Net.onServerInvoke is server-only")
	local remote = Net.func(name)
	remote.OnServerInvoke = function(player, ...)
		if not Net.consume(player, name) then
			return nil
		end
		local args = table.pack(...)
		local ok, result = pcall(function()
			return handler(player, table.unpack(args, 1, args.n))
		end)
		if not ok then
			warn(("[Net] %s invoke error for %s: %s"):format(name, player.Name, tostring(result)))
			return nil
		end
		return result
	end
end

function Net.fire(player: Player, name: string, ...: any)
	Net.event(name):FireClient(player, ...)
end

function Net.fireAll(name: string, ...: any)
	Net.event(name):FireAllClients(...)
end

return Net
