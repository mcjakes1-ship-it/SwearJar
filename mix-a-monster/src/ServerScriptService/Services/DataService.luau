--!strict
--[[
	DataService.luau — session-locked profiles, autosave, BindToClose.
	GDD §11.1, §11.2.

	WHY THIS IS VENDORED RATHER THAN ProfileService/ProfileStore:
	the GDD names those libraries, but pulling a Wally dependency into a
	Rojo-only repo means every contributor needs a toolchain before the place
	will even boot. The behaviour that actually matters — a session lock so
	two servers can never write the same profile, autosave, a BindToClose
	flush, and additive migration — is ~250 lines and is implemented here with
	no dependencies. Swapping in ProfileStore later is a change to this one
	file. Logged in DECISIONS.md.

	THE CONTRACT OTHER SERVICES RELY ON:
	  DataService.get(player)            -> Profile? (nil until loaded)
	  DataService.waitFor(player, secs)  -> Profile? (yields)
	  DataService.push(player, patch)    -> replicate a subset to the owner
	  DataService.onLoaded  : Signal(player, profile)
	  DataService.onReleasing : Signal(player, profile)  -- last chance to save

	A service must never cache a Profile table across a player's session
	boundary; always ask `get`.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = ReplicatedStorage:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Config:WaitForChild("Constants"))
local Net = require(Shared:WaitForChild("Net"))
local Util = require(Shared:WaitForChild("Util"))
local Types = require(Shared:WaitForChild("Types"))

type Profile = Types.Profile

local DataService = {}
DataService.Name = "DataService"

DataService.onLoaded = Util.signal()
DataService.onReleasing = Util.signal()

local JOB_ID = if game.JobId ~= "" then game.JobId else "studio-" .. tostring(math.random(1, 1e9))

local store: DataStore? = nil
local memoryOnly = false
local profiles: { [Player]: Profile } = {}
local loading: { [Player]: boolean } = {}
local memoryStore: { [string]: any } = {}
local analytics: any = nil
-- Bumped by every failed write, so saveNow can report whether its own landed.
local saveFailures = 0

-- ── Template ─────────────────────────────────────────────────────────────
-- Every field a Profile can have. `Util.reconcile` fills missing keys from
-- this on load, which IS the migration path for additive changes (GDD §11.2:
-- never delete a field, deprecate it).

local function template(): Profile
	return {
		version = Constants.PROFILE_VERSION,
		goop = Constants.START_GOOP,
		totalGoopEarned = 0,
		inventory = {},
		mixlings = {},
		placed = {},
		denSlots = Constants.DEN_SLOTS_START,
		lockLevel = 1,
		mixdex = {},
		secretsFound = {},
		stats = { stealsBanked = 0, stealsFoiled = 0, goopStolen = 0, rolls = 0, byRarity = { 0, 0, 0, 0, 0, 0, 0 } },
		daily = { streak = 0, lastClaim = 0 },
		codes = {},
		passes = {},
		badges = {},
		receipts = {},
		titles = {},
		settings = { friendlyFire = true, music = true, sfx = true, lowFx = false },
		funnel = {},
		firstJoin = 0,
		tutorialDone = false,
		playSeconds = 0,
	}
end

DataService.template = template

local function keyFor(userId: number): string
	return "Player_" .. tostring(userId)
end

-- ── Store access ─────────────────────────────────────────────────────────

local function getStore(): DataStore?
	if memoryOnly then
		return nil
	end
	if store then
		return store
	end
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(Constants.PROFILE_STORE_NAME)
	end)
	if ok then
		store = result
		return result
	end
	memoryOnly = true
	warn("[DataService] DataStores unavailable; running MEMORY ONLY. Nothing will persist. "
		.. "In Studio enable Game Settings > Security > Enable Studio Access to API Services.")
	return nil
end

--[[
	Session locking. The stored envelope is { lock = { jobId, at }, data = ... }.

	A lock older than SESSION_LOCK_SECONDS is treated as dead and stolen: the
	owning server either crashed or lost its BindToClose window. This is the
	trade the GDD's "no data loss" bar demands — a player who rejoins after a
	crash must not be locked out of their own profile.
]]
local function acquire(userId: number): (boolean, Profile?)
	local dataStore = getStore()
	if not dataStore then
		local cached = memoryStore[keyFor(userId)]
		return true, if cached then Util.deepCopy(cached) else nil
	end

	local loaded: Profile? = nil
	local blocked = false

	local ok, err = Util.retry(4, 1, function()
		dataStore:UpdateAsync(keyFor(userId), function(stored: any)
			local envelope = stored
			if type(envelope) ~= "table" then
				envelope = { lock = nil, data = nil }
			end

			local lock = envelope.lock
			if type(lock) == "table" and lock.jobId ~= JOB_ID then
				local age = os.time() - (tonumber(lock.at) or 0)
				if age < Constants.SESSION_LOCK_SECONDS then
					blocked = true
					return nil -- abort the write; another server owns this profile
				end
			end

			envelope.lock = { jobId = JOB_ID, at = os.time() }
			loaded = envelope.data
			return envelope
		end)
		return true
	end)

	if not ok then
		warn(("[DataService] load failed for %d: %s"):format(userId, tostring(err)))
		return false, nil
	end
	if blocked then
		return false, nil
	end
	return true, loaded
end

local function write(userId: number, profile: Profile, release: boolean)
	local dataStore = getStore()
	if not dataStore then
		memoryStore[keyFor(userId)] = Util.deepCopy(profile)
		return
	end

	local ok, err = Util.retry(4, 1, function()
		dataStore:UpdateAsync(keyFor(userId), function(stored: any)
			local envelope = if type(stored) == "table" then stored else {}
			local lock = envelope.lock
			-- Only the lock holder may write. If another server stole the lock
			-- (because we hung past SESSION_LOCK_SECONDS) we drop our write
			-- rather than clobber the session that is actually live.
			if type(lock) == "table" and lock.jobId ~= JOB_ID then
				return nil
			end
			envelope.data = profile
			envelope.lock = if release then nil else { jobId = JOB_ID, at = os.time() }
			return envelope
		end)
		return true
	end)

	if not ok then
		saveFailures += 1
		warn(("[DataService] save failed for %d: %s"):format(userId, tostring(err)))
		if analytics then
			analytics.event("SaveFailed", { userId = userId, err = tostring(err) })
		end
	end
end

--[[
	Hands a lock back without writing data. `acquire` stamps the lock as a side
	effect of the read, so the moment it returns ok this server owns the profile
	— and every path that then declines to use it has to give it back, or the
	player is locked out of their own profile for SESSION_LOCK_SECONDS on their
	next join.
]]
local function releaseLock(userId: number)
	local dataStore = getStore()
	if not dataStore then
		return
	end
	Util.retry(3, 1, function()
		dataStore:UpdateAsync(keyFor(userId), function(stored: any)
			if type(stored) ~= "table" then
				return nil
			end
			local lock = stored.lock
			if type(lock) == "table" and lock.jobId ~= JOB_ID then
				return nil -- not ours to clear
			end
			stored.lock = nil
			return stored
		end)
		return true
	end)
end

-- ── Size guard ───────────────────────────────────────────────────────────
-- A profile that grows without bound eventually exceeds the 4 MB DataStore
-- limit and starts failing every save. Trim the least valuable, unplaced
-- Mixlings first, and only above the cap.

local function trim(profile: Profile)
	if #profile.mixlings <= Constants.MIXLING_SOFT_CAP then
		return
	end
	local placedIds: { [string]: boolean } = {}
	for _, id in profile.placed do
		placedIds[id] = true
	end

	local removable = {}
	for index, mixling in profile.mixlings do
		if not placedIds[mixling.id] and not mixling.bound then
			table.insert(removable, { index = index, rarity = mixling.rarity, createdAt = mixling.createdAt })
		end
	end
	table.sort(removable, function(a, b)
		if a.rarity ~= b.rarity then
			return a.rarity < b.rarity
		end
		return a.createdAt < b.createdAt
	end)

	local excess = #profile.mixlings - Constants.MIXLING_SOFT_CAP
	local doomed: { [number]: boolean } = {}
	for index = 1, math.min(excess, #removable) do
		doomed[removable[index].index] = true
	end
	for index = #profile.mixlings, 1, -1 do
		if doomed[index] then
			table.remove(profile.mixlings, index)
		end
	end
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

local function load(player: Player)
	if loading[player] or profiles[player] then
		return
	end
	loading[player] = true

	local ok, stored = acquire(player.UserId)

	-- A blocked lock means the previous session is still shutting down. Give
	-- it one grace window before refusing, then kick with an explanation
	-- rather than silently handing out a fresh profile (which would look like
	-- total data loss to the player).
	if not ok then
		task.wait(6)
		ok, stored = acquire(player.UserId)
	end

	loading[player] = nil

	if not player.Parent then
		-- They left while we were reading. The lock is already ours, so hand it
		-- straight back: otherwise their own next join is refused by a lock
		-- nobody is using.
		if ok then
			task.spawn(releaseLock, player.UserId)
		end
		return
	end

	if not ok then
		player:Kick("Your Mixlings are still saving from your last session. Rejoin in a few seconds — nothing is lost.")
		return
	end

	local profile: Profile
	if type(stored) == "table" then
		profile = Util.reconcile(stored :: any, template()) :: any
		profile.version = Constants.PROFILE_VERSION
	else
		profile = template()
		profile.firstJoin = os.time()
	end
	if profile.firstJoin == 0 then
		profile.firstJoin = os.time()
	end

	profiles[player] = profile
	DataService.onLoaded:fire(player, profile)
end

local function release(player: Player)
	local profile = profiles[player]
	if not profile then
		loading[player] = nil
		return
	end
	-- Services get one genuinely synchronous chance to write final state (a
	-- carried Mixling returning home, GDD §8.4.6) before the profile leaves
	-- memory. fireSync, not fire: `fire` spawns each handler, so a handler that
	-- yields — and returning a carried Mixling does yield — would still be
	-- running when the write below took its snapshot.
	DataService.onReleasing:fireSync(player, profile)

	profiles[player] = nil
	trim(profile)
	write(player.UserId, profile, true)
end

-- ── Public API ───────────────────────────────────────────────────────────

function DataService.get(player: Player): Profile?
	return profiles[player]
end

function DataService.waitFor(player: Player, timeout: number?): Profile?
	local deadline = os.clock() + (timeout or 20)
	while os.clock() < deadline do
		local profile = profiles[player]
		if profile then
			return profile
		end
		if not player.Parent then
			return nil
		end
		task.wait(0.1)
	end
	return nil
end

--[[
	Replicates a subset of the profile to its owner (GDD §11.3: the client is
	told what it owns, never what it could have). `patch` is a plain table of
	ProfileView fields; `full` marks a complete refresh so the client can
	replace rather than merge.
]]
function DataService.push(player: Player, patch: { [string]: any }, full: boolean?)
	if not player.Parent then
		return
	end
	Net.fire(player, "ProfileSync", patch, full == true)
end

function DataService.forEach(fn: (Player, Profile) -> ())
	for player, profile in profiles do
		fn(player, profile)
	end
end

-- Saves everyone right now. Used by BindToClose and by the autosave loop.
function DataService.saveAll(releaseLocks: boolean)
	--[[
		A shutdown save is the same irreversible moment as a player leaving, so
		it gets the same hook. Without this, BindToClose snapshots profiles
		while a stolen Mixling is mid-carry — and a carried Mixling belongs to
		no profile (StealService is the only thing holding it), so it is written
		out of existence. GDD §8.4.6 says it goes home to its owner; this is
		where that happens for everyone at once.
	]]
	if releaseLocks then
		for player, profile in profiles do
			DataService.onReleasing:fireSync(player, profile)
		end
	end

	local pending = 0
	for player, profile in profiles do
		pending += 1
		task.spawn(function()
			--[[
				Only trim on the way out. Trimming a profile that is still
				loaded deletes Mixlings the client is currently listing, with
				no push to say they are gone — the player keeps seeing them,
				and placing one silently fails. On a shutdown save the client
				is about to stop existing, so there is nothing to desync.
			]]
			if releaseLocks then
				trim(profile)
			end
			write(player.UserId, profile, releaseLocks)
			pending -= 1
		end)
	end
	local deadline = os.clock() + 25
	while pending > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end

--[[
	Writes ONE profile right now and reports whether it landed.

	This exists for ProcessReceipt. Everything else in the game can afford to
	wait for the autosave, because losing a minute of Goop accrual is a minute
	of Goop. A purchase is different: Roblox treats PurchaseGranted as final and
	never redelivers, so acking a receipt whose grant is still only in memory
	means a crash inside the autosave window destroys something the player paid
	real money for. The caller must not return GRANTED until this returns true.
]]
function DataService.saveNow(player: Player): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	if memoryOnly then
		memoryStore[keyFor(player.UserId)] = Util.deepCopy(profile)
		return true
	end
	local before = saveFailures
	write(player.UserId, profile, false)
	return saveFailures == before
end

function DataService.isMemoryOnly(): boolean
	return memoryOnly
end

function DataService.init(services: { [string]: any })
	analytics = services.AnalyticsService
end

function DataService.start()
	for _, player in Players:GetPlayers() do
		task.spawn(load, player)
	end
	Players.PlayerAdded:Connect(function(player)
		task.spawn(load, player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		release(player)
	end)

	task.spawn(function()
		while true do
			task.wait(Constants.AUTOSAVE_SECONDS)
			DataService.saveAll(false)
		end
	end)

	game:BindToClose(function()
		if RunService:IsStudio() then
			return
		end
		DataService.saveAll(true)
	end)
end

return DataService
