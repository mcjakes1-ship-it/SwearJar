--!strict
--[[
	ClientState.luau — the client's single copy of what the server says it owns.

	Every controller reads from here and nothing else. There is exactly one
	writer (the ProfileSync handler below), so a screen can never disagree with
	another screen about how much Goop you have.

	This is a CACHE, not a source of truth. The server owns all of it
	(GDD §11.3); if this table and the server disagree, this table is wrong and
	the next sync fixes it. Nothing here may be used to decide an outcome —
	only to draw one.

	Patch semantics for ProfileSync(patch, full):
	  * full = true      -> replace the whole view
	  * a MERGE_KEY      -> merge the patch table into the existing one, key by
	                        key. These are append-only collections (mixdex,
	                        secretsFound, passes, titles, badges), so a delta is
	                        always safe and a full send is never needed.
	  * mixlingAdded / mixlingRemoved -> apply to the mixlings list, so rolling
	                        does not re-send an inventory of hundreds.
	  * anything else    -> replace that key outright. Small tables (inventory,
	                        placed, stats, daily, settings) are always sent whole
	                        because they are small and deletion is then free.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Util = require(Shared:WaitForChild("Util"))
local Types = require(Shared:WaitForChild("Types"))

local ClientState = {}

-- Merged rather than replaced. All append-only.
local MERGE_KEYS = {
	mixdex = true,
	secretsFound = true,
	passes = true,
	titles = true,
	badges = true,
}

export type View = {
	goop: number,
	goopPerSec: number,
	totalGoopEarned: number,
	inventory: { [string]: number },
	mixlings: { Types.MixlingView },
	placed: { [string]: string },
	denSlots: number,
	lockLevel: number,
	mixdex: { [string]: number },
	secretsFound: { [string]: any },
	stats: { [string]: any },
	daily: { [string]: any },
	settings: { [string]: any },
	titles: { [string]: boolean },
	passes: { [string]: boolean },
	tutorialDone: boolean,
	shielded: boolean,
	shieldEndsAt: number,
	luck: number,
	mixdexDiscovered: number,
	mixdexTotal: number,
	[string]: any,
}

local view: View = {
	goop = 0,
	goopPerSec = 0,
	totalGoopEarned = 0,
	inventory = {},
	mixlings = {},
	placed = {},
	denSlots = 5,
	lockLevel = 1,
	mixdex = {},
	secretsFound = {},
	stats = {},
	daily = {},
	settings = { friendlyFire = true, music = true, sfx = true, lowFx = false },
	titles = {},
	passes = {},
	tutorialDone = false,
	shielded = false,
	shieldEndsAt = 0,
	luck = 0,
	mixdexDiscovered = 0,
	mixdexTotal = 0,
}

--[[
	Fires after every sync with the list of top-level keys that changed, so a
	controller can redraw only what it cares about instead of rebuilding a
	screen once a second for the Goop tick.
]]
ClientState.changed = Util.signal()
ClientState.ready = Util.signal()

local isReady = false

function ClientState.get(): View
	return view
end

function ClientState.isReady(): boolean
	return isReady
end

-- The Goop the HUD should be showing right now. The server ticks once a second
-- (Constants.GOOP_TICK_SECONDS) and the client interpolates between ticks so
-- the number climbs smoothly (GDD §8.2).
local lastSyncClock = 0

function ClientState.interpolatedGoop(): number
	local elapsed = math.clamp(os.clock() - lastSyncClock, 0, 2)
	return view.goop + view.goopPerSec * elapsed
end

function ClientState.mixlingById(id: string): Types.MixlingView?
	for _, mixling in view.mixlings do
		if mixling.id == id then
			return mixling
		end
	end
	return nil
end

function ClientState.placedIds(): { [string]: boolean }
	local placed = {}
	for _, id in view.placed do
		placed[id] = true
	end
	return placed
end

function ClientState.unplacedMixlings(): { Types.MixlingView }
	local placed = ClientState.placedIds()
	local out = {}
	for _, mixling in view.mixlings do
		if not placed[mixling.id] then
			table.insert(out, mixling)
		end
	end
	return out
end

function ClientState.inventoryOf(kind: string): { { name: string, count: number } }
	local out = {}
	for name, count in view.inventory do
		if count > 0 then
			table.insert(out, { name = name, count = count })
		end
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

local function applyPatch(patch: { [string]: any }, full: boolean)
	local changedKeys: { string } = {}

	if full then
		for key, value in patch do
			view[key] = Util.deepCopy(value)
			table.insert(changedKeys, key)
		end
		isReady = true
	else
		for key, value in patch do
			if key == "mixlingAdded" then
				table.insert(view.mixlings, Util.deepCopy(value))
				table.insert(changedKeys, "mixlings")
			elseif key == "mixlingRemoved" then
				for index = #view.mixlings, 1, -1 do
					if view.mixlings[index].id == value then
						table.remove(view.mixlings, index)
					end
				end
				table.insert(changedKeys, "mixlings")
			elseif MERGE_KEYS[key] and type(value) == "table" and type(view[key]) == "table" then
				for subKey, subValue in value do
					view[key][subKey] = subValue
				end
				table.insert(changedKeys, key)
			else
				view[key] = Util.deepCopy(value)
				table.insert(changedKeys, key)
			end
		end
	end

	if patch.goop ~= nil or patch.goopPerSec ~= nil then
		lastSyncClock = os.clock()
	end

	ClientState.changed:fire(changedKeys)
	if full and not isReady then
		isReady = true
	end
	if full then
		ClientState.ready:fire(view)
	end
end

function ClientState.start()
	Net.event("ProfileSync").OnClientEvent:Connect(function(patch: any, full: any)
		if type(patch) ~= "table" then
			return
		end
		applyPatch(patch, full == true)
	end)
end

return ClientState
