--!strict
--[[
	Server.server.luau — the boot script. GDD §11.1.

	SERVICE CONTRACT (every module in Services/ obeys this, no exceptions):

		local MyService = {}
		MyService.Name = "MyService"
		function MyService.init(services) end   -- wire references, no work
		function MyService.start() end          -- connect events, begin loops
		return MyService

	`init` runs for every service before any `start`, in the order listed
	below. That ordering is the ONLY dependency graph: a service may call any
	other service it captured in `init`, and may never `require` a sibling
	directly. This is what keeps the graph acyclic without a framework.

	Nothing in `init` may yield. Yielding work belongs in `start`.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))

-- Create the remote folder before anything can reference it, and before any
-- client finishes loading.
Net.init()

local Services = ServerScriptService:WaitForChild("Services")

-- Boot order is dependency order. Read top to bottom as "what must exist
-- before the next thing can be wired".
local ORDER = {
	"AnalyticsService", -- no dependencies; everything reports into it
	"DataService", -- profiles; every service below reads or writes one
	"AnnouncementService", -- banners; needs nothing but Net
	"EconomyService", -- Goop balances and the accrual tick
	"MonetizationService", -- passes and receipts; feeds multipliers to Economy
	"WorldService", -- builds Blendburg; Dens need its geometry
	"DenService", -- pedestals, locks, slots, shields
	"MixerService", -- the roll
	"StealService", -- carry/bank/drop state machine, bonk
	"ShopService",
	"MixdexService",
	"CodesService",
	"LeaderboardService",
	"PlayerService", -- spawn, tutorial handshake, session lifecycle; runs last
}

type Service = {
	Name: string?,
	init: (({ [string]: any }) -> ())?,
	start: (() -> ())?,
}

local registry: { [string]: any } = {}
local ordered: { Service } = {}

for _, name in ORDER do
	local module = Services:FindFirstChild(name)
	if not module or not module:IsA("ModuleScript") then
		error(("[Boot] missing service module %q"):format(name), 0)
	end
	local service = require(module) :: Service
	registry[name] = service
	table.insert(ordered, service)
end

-- Boot-time integrity checks. These are cheap and they fail loudly in Studio
-- rather than quietly shipping a broken Mixdex denominator or an unreachable
-- secret (GDD §7.4).
do
	local SecretRecipes = require(ServerStorage:WaitForChild("SecretRecipes"))
	local SecretsPublic = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("SecretsPublic"))
	for _, problem in SecretRecipes.validate() do
		warn("[Boot] " .. problem)
	end
	if SecretRecipes.count() ~= SecretsPublic.COUNT then
		warn(("[Boot] SecretsPublic.COUNT is %d but %d secrets are defined; the Mixdex will show the wrong number of ??? entries")
			:format(SecretsPublic.COUNT, SecretRecipes.count()))
	end
end

local startedAt = os.clock()

for _, service in ordered do
	if service.init then
		local initFn = service.init
		local ok, err = pcall(function()
			initFn(registry)
		end)
		if not ok then
			error(("[Boot] %s.init failed: %s"):format(service.Name or "?", tostring(err)), 0)
		end
	end
end

for _, service in ordered do
	if service.start then
		local startFn = service.start
		local ok, err = pcall(function()
			startFn()
		end)
		if not ok then
			-- A failed start is loud but not fatal: one broken leaderboard
			-- must not stop players from mixing.
			warn(("[Boot] %s.start failed: %s"):format(service.Name or "?", tostring(err)))
		end
	end
end

print(("[Mix a Monster] %d services booted in %.0f ms%s"):format(
	#ordered,
	(os.clock() - startedAt) * 1000,
	if RunService:IsStudio() then " (Studio)" else ""
))
