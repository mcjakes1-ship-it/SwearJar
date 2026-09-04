--!strict
--[[
	Client.client.luau — the client boot script (GDD §11.1).

	Mirrors the server contract exactly. Every controller is:

		local MyController = {}
		MyController.Name = "MyController"
		function MyController.init(controllers) end  -- capture references, no work
		function MyController.start() end            -- build UI, connect remotes
		return MyController

	`init` runs for every controller before any `start`. Controllers reach each
	other only through the registry handed to `init`; nothing requires a sibling
	controller directly. ClientState is the exception — it is a leaf module with
	no dependencies, so it is required directly by anyone who needs it.

	NOTHING HERE DECIDES ANYTHING. Controllers render server outcomes and send
	intents. Every number a controller shows came from a ProfileSync.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))

local ClientState = require(script.Parent:WaitForChild("ClientState"))
local Controllers = script.Parent:WaitForChild("Controllers")

-- Make sure the remote folder exists before any controller touches it, so a
-- controller can call Net.event() without each one waiting separately.
Net.init()

-- Start the state cache before controllers boot: the server's first full sync
-- can land during boot and must not be missed.
ClientState.start()

local ORDER = {
	"SoundController", -- everything else may ask it to play something
	"AlertController", -- banners, theft alerts, toasts
	"HudController", -- the always-on layer; owns the button cluster
	"MixerUIController",
	"DenUIController",
	"ShopController",
	"MixdexController",
	"BonkController",
	"TutorialController", -- last: it drives the others through the first 60 s
}

type Controller = {
	Name: string?,
	init: (({ [string]: any }) -> ())?,
	start: (() -> ())?,
}

local registry: { [string]: any } = {}
local ordered: { Controller } = {}

for _, name in ORDER do
	local module = Controllers:WaitForChild(name, 10)
	if not module or not module:IsA("ModuleScript") then
		warn(("[Client] missing controller %q"):format(name))
		continue
	end
	local controller = require(module) :: Controller
	registry[name] = controller
	table.insert(ordered, controller)
end

for _, controller in ordered do
	if controller.init then
		local initFn = controller.init
		local ok, err = pcall(function()
			initFn(registry)
		end)
		if not ok then
			warn(("[Client] %s.init failed: %s"):format(controller.Name or "?", tostring(err)))
		end
	end
end

for _, controller in ordered do
	if controller.start then
		local startFn = controller.start
		local ok, err = pcall(function()
			startFn()
		end)
		if not ok then
			warn(("[Client] %s.start failed: %s"):format(controller.Name or "?", tostring(err)))
		end
	end
end

print(("[Mix a Monster] client ready for %s"):format(Players.LocalPlayer.Name))
