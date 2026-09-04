--!strict
--[[
	Util.luau — small, dependency-free helpers shared by both realms.

	Nothing game-specific belongs here. If a helper needs Constants, it lives
	in the system that owns the behaviour.
]]

local Util = {}

-- ── Signal ───────────────────────────────────────────────────────────────
-- A minimal BindableEvent-free signal. Used for service-to-service events so
-- services never reach into each other's internals.

export type Connection = { disconnect: (Connection) -> () }

local Signal = {}
Signal.__index = Signal

export type Signal = {
	connect: (Signal, (...any) -> ()) -> Connection,
	once: (Signal, (...any) -> ()) -> Connection,
	fire: (Signal, ...any) -> (),
	fireSync: (Signal, ...any) -> (),
	destroy: (Signal) -> (),
	_handlers: { [number]: ((...any) -> ())? },
	_nextId: number,
}

function Util.signal(): Signal
	return (setmetatable({ _handlers = {}, _nextId = 0 }, Signal) :: any) :: Signal
end

function Signal:connect(handler: (...any) -> ()): Connection
	local self_ = self :: any
	self_._nextId += 1
	local id = self_._nextId
	self_._handlers[id] = handler
	return {
		disconnect = function()
			self_._handlers[id] = nil
		end,
	}
end

function Signal:once(handler: (...any) -> ()): Connection
	local connection: Connection
	connection = (self :: any):connect(function(...)
		connection.disconnect(connection)
		handler(...)
	end)
	return connection
end

function Signal:fire(...: any)
	local self_ = self :: any
	for _, handler in self_._handlers do
		task.spawn(handler, ...)
	end
end

--[[
	Runs every handler to completion, in place, before returning — including
	their yields. `fire` uses task.spawn, so a handler that yields hands control
	straight back to the caller; that is right for a notification and WRONG for
	a last-chance hook, where the caller is about to do something irreversible
	(write a profile to a DataStore, shut a server down) and needs the handlers
	to have actually finished.

	A handler that errors is isolated: the rest still run.
]]
function Signal:fireSync(...: any)
	local self_ = self :: any
	local args = table.pack(...)
	for _, handler in self_._handlers do
		local ok, err = pcall(function()
			handler(table.unpack(args, 1, args.n))
		end)
		if not ok then
			warn("[Signal] fireSync handler error: " .. tostring(err))
		end
	end
end

function Signal:destroy()
	local self_ = self :: any
	table.clear(self_._handlers)
end

-- ── Numbers ──────────────────────────────────────────────────────────────

local SUFFIXES = { "", "K", "M", "B", "T", "Qa", "Qi" }

-- 1234 -> "1.2K". Used for every Goop figure the player reads (GDD §10).
function Util.abbreviate(value: number): string
	if value ~= value then
		return "0"
	end
	local sign = if value < 0 then "-" else ""
	local n = math.abs(value)
	if n < 1000 then
		return sign .. tostring(math.floor(n + 0.5))
	end
	local index = 1
	while n >= 1000 and index < #SUFFIXES do
		n /= 1000
		index += 1
	end
	local text = if n < 10 then ("%.2f"):format(n) elseif n < 100 then ("%.1f"):format(n) else ("%d"):format(n)
	text = text:gsub("%.?0+$", "")
	return sign .. text .. SUFFIXES[index]
end

-- 1234567 -> "1,234,567". For the exact figures in tooltips and receipts.
function Util.comma(value: number): string
	local text = tostring(math.floor(math.abs(value) + 0.5))
	local out = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	out = out:gsub("^,", "")
	return (if value < 0 then "-" else "") .. out
end

function Util.round(value: number, places: number?): number
	local factor = 10 ^ (places or 0)
	return math.floor(value * factor + 0.5) / factor
end

-- mm:ss for lock timers and cooldowns.
function Util.clock(seconds: number): string
	local total = math.max(0, math.floor(seconds + 0.5))
	return ("%d:%02d"):format(total // 60, total % 60)
end

-- ── Tables ───────────────────────────────────────────────────────────────

function Util.deepCopy<T>(source: T): T
	if type(source) ~= "table" then
		return source
	end
	local copy = {}
	for key, value in source :: any do
		copy[key] = Util.deepCopy(value)
	end
	return (copy :: any) :: T
end

-- Fills missing keys in `target` from `template`, recursively. This is the
-- whole of profile migration for additive changes (GDD §11.2: never delete a
-- field, deprecate it).
function Util.reconcile(target: { [any]: any }, template: { [any]: any }): { [any]: any }
	for key, value in template do
		if target[key] == nil then
			target[key] = Util.deepCopy(value)
		elseif type(value) == "table" and type(target[key]) == "table" then
			Util.reconcile(target[key], value)
		end
	end
	return target
end

function Util.count(map: { [any]: any }): number
	local total = 0
	for _ in map do
		total += 1
	end
	return total
end

function Util.find<T>(list: { T }, predicate: (T) -> boolean): (T?, number?)
	for index, value in list do
		if predicate(value) then
			return value, index
		end
	end
	return nil, nil
end

function Util.shuffle<T>(list: { T }, rng: Random): { T }
	for index = #list, 2, -1 do
		local swap = rng:NextInteger(1, index)
		list[index], list[swap] = list[swap], list[index]
	end
	return list
end

function Util.pick<T>(list: { T }, rng: Random): T?
	if #list == 0 then
		return nil
	end
	return list[rng:NextInteger(1, #list)]
end

-- ── Retry ────────────────────────────────────────────────────────────────
-- DataStore and BadgeService calls fail transiently; every one of them goes
-- through here so a bad minute of Roblox infrastructure never loses a profile.

function Util.retry<T>(attempts: number, backoff: number, fn: () -> T): (boolean, T | string)
	local lastError: string = "no attempts"
	for attempt = 1, attempts do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastError = tostring(result)
		if attempt < attempts then
			task.wait(backoff * 2 ^ (attempt - 1))
		end
	end
	return false, lastError
end

-- ── Instances ────────────────────────────────────────────────────────────

function Util.create(className: string, props: { [string]: any }, children: { Instance }?): Instance
	local instance = Instance.new(className)
	local parent = props.Parent
	for key, value in props do
		if key ~= "Parent" then
			(instance :: any)[key] = value
		end
	end
	if children then
		for _, child in children do
			child.Parent = instance
		end
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

function Util.rootPart(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

function Util.humanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

function Util.distanceBetween(a: Player, b: Player): number?
	local rootA, rootB = Util.rootPart(a), Util.rootPart(b)
	if not rootA or not rootB then
		return nil
	end
	return (rootA.Position - rootB.Position).Magnitude
end

return Util
