--!nonstrict
-- init.client.luau — boots the client UI, keeps state in sync with the server,
-- and routes interaction prompts to the right panel.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))

local UILib = require(script:WaitForChild("UILib"))
local HudUI = require(script:WaitForChild("HudUI"))
local InventoryUI = require(script:WaitForChild("InventoryUI"))
local ManageUI = require(script:WaitForChild("ManageUI"))
local StatsUI = require(script:WaitForChild("StatsUI"))
local WelcomeUI = require(script:WaitForChild("WelcomeUI"))
local ShopUI = require(script:WaitForChild("ShopUI"))
local SlotsUI = require(script:WaitForChild("SlotsUI"))
local GamesUI = require(script:WaitForChild("GamesUI"))
local UpgradesUI = require(script:WaitForChild("UpgradesUI"))
local PlacementController = require(script:WaitForChild("PlacementController"))
local ShowroomUI = require(script:WaitForChild("ShowroomUI"))
local RobuxShopUI = require(script:WaitForChild("RobuxShopUI"))
local DailyUI = require(script:WaitForChild("DailyUI"))
local MachineFX = require(script:WaitForChild("MachineFX"))
local MapFX = require(script:WaitForChild("MapFX"))
local Sprint = require(script:WaitForChild("Sprint"))
local DayNightFX = require(script:WaitForChild("DayNightFX"))
local BuildingView = require(script:WaitForChild("BuildingView"))
local ElevatorUI = require(script:WaitForChild("ElevatorUI"))
-- the cars build RoadNet on require: a failure there must not take the UI down
local trafficLoaded, TrafficClient = pcall(require, script:WaitForChild("TrafficClient"))
if not trafficLoaded then warn("[CasinoTycoon] TrafficClient failed to load: " .. tostring(TrafficClient)) end
-- the juice layer (sounds, coins, confetti, banners) is optional too: every UI
-- reaches it through UILib.fx, which is a no-op when it isn't running
local uxLoaded, UXFX = pcall(require, script:WaitForChild("UXFX"))
if not uxLoaded then warn("[CasinoTycoon] UXFX failed to load: " .. tostring(UXFX)) end
-- the Casino Rank layer (rank-up fanfare + unlock card, NEW markers, the rank
-- panel) is optional as well: the HUD badge just opens STATS without it
local rankLoaded, RankUI = pcall(require, script:WaitForChild("RankUI", 10))
if not rankLoaded then warn("[CasinoTycoon] RankUI failed to load: " .. tostring(RankUI)) end

-- the Rebirth & Rewards UIs: each optional (a missing or broken one is skipped)
local function optionalUI(name: string)
	local mod = script:FindFirstChild(name)
	if not mod then return nil end
	local ok, res = pcall(require, mod)
	if not ok then
		warn(("[CasinoTycoon] %s failed to load: %s"):format(name, tostring(res)))
		return nil
	end
	return res
end
local RebirthUI = optionalUI("RebirthUI")       -- the REBIRTH tile's panel + rebirth shop
local PotionsUI = optionalUI("PotionsUI")       -- owned / active potions
local PlaytimeUI = optionalUI("PlaytimeUI")     -- the PLAYTIME tile's rewards
local StaffClient = optionalUI("StaffClient")   -- hired staff walking around the casinos
local BoostFX = optionalUI("BoostFX")           -- the x3 machine-boost aura
local DecorShopUI = optionalUI("DecorShopUI")   -- SHOP > DECOR
local StaffShopUI = optionalUI("StaffShopUI")   -- SHOP > STAFF
-- the Cheaters & VIP update
local CheatersUI = optionalUI("CheatersUI")     -- cheater alerts, KICK prompts, busted effects
local VipFloorUI = optionalUI("VipFloorUI")     -- the VIP floor's client side (upsell, effects)
local QuestsUI = optionalUI("QuestsUI")         -- daily / weekly quests (HUD tile)
local WheelUI = optionalUI("WheelUI")           -- the lucky wheel (HUD tile)
local EventsUI = optionalUI("EventsUI")         -- casino event banners + timer chip

local player = Players.LocalPlayer

-- guests and staff never bump into you: your character is in the player collision
-- group from its first frame (the server sets it too, but only after its join work)
do
	local Config = require(Common:WaitForChild("Config"))
	local group = Config.CollisionGroups and Config.CollisionGroups.Player
	local function setGroup(d: Instance)
		if group and d:IsA("BasePart") then pcall(function() d.CollisionGroup = group end) end
	end
	local function onCharacter(char: Model)
		for _, d in char:GetDescendants() do setGroup(d) end
		char.DescendantAdded:Connect(setGroup)
	end
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then onCharacter(player.Character) end
end

-- keep the client state cache in sync with server pushes
Remotes.DataUpdated().OnClientEvent:Connect(function(snap)
	UILib.setState(snap)
end)

-- started before the HUD so the very first toasts / purchases get their effects
if uxLoaded then
	local ok, err = pcall(UXFX.start, { MachineFX = MachineFX })
	if not ok then warn("[CasinoTycoon] UXFX.start: " .. tostring(err)) end
end

-- HUD
HudUI.build({
	onShop = function() ShopUI.open() end,
	-- GO SHOPPING lands on the tab you came from (DECOR -> the decor shop)
	onInventory = function() InventoryUI.open(function(tab) ShopUI.open(tab) end) end,
	-- the REBIRTH tile took the BUILD tile's place (building starts from ITEMS)
	onRebirth = function()
		if RebirthUI and RebirthUI.open then RebirthUI.open() else UILib.toast("Rebirth is coming soon!", "info") end
	end,
	onUpgrades = UpgradesUI.open,
	onCasino = ManageUI.openOverview,
	onStats = StatsUI.open,
	onStore = function(tab)
		-- the "+" on the Cash pill lands on cash packs, the Tickets "+" on the ticket shop
		RobuxShopUI.open(type(tab) == "string" and tab or nil)
	end,
	onDaily = DailyUI.open,
	onPlaytime = function()
		if PlaytimeUI and PlaytimeUI.open then PlaytimeUI.open() end
	end,
	onPotions = function()
		if PotionsUI and PotionsUI.open then PotionsUI.open() else RobuxShopUI.open("potions") end
	end,
	-- the Casino Rank badge (under the clock): the rank panel
	onRank = function()
		if rankLoaded then RankUI.open() else StatsUI.open() end
	end,
	-- the travel bar refuses hops mid-placement: while a machine is being
	-- placed / moved / picked to move
	isPlacing = PlacementController.isBusy,
})
-- after the HUD (its rank chip is the fanfare's anchor), before the first snapshot
if rankLoaded then
	local ok, err = pcall(RankUI.start, {
		travelTo = function(dest) if HudUI.travelTo then HudUI.travelTo(dest) end end,
		openUpgrades = function(opts) UpgradesUI.open(opts) end,
		openShop = function(tab) ShopUI.open(tab) end,
		openCasino = function(tab) ManageUI.openOverview(tab) end,
		isBusy = PlacementController.isBusy, -- the unlock card waits while a machine is being placed
	})
	if not ok then warn("[CasinoTycoon] RankUI.start: " .. tostring(err)) end
end
-- the Rebirth & Rewards UIs (after the HUD: they hang chips / timers on it)
for name, mod in { RebirthUI = RebirthUI, PotionsUI = PotionsUI, PlaytimeUI = PlaytimeUI, StaffClient = StaffClient,
	BoostFX = BoostFX, DecorShopUI = DecorShopUI, StaffShopUI = StaffShopUI, CheatersUI = CheatersUI,
	VipFloorUI = VipFloorUI, QuestsUI = QuestsUI, WheelUI = WheelUI, EventsUI = EventsUI } do
	if mod and type(mod.start) == "function" then
		local ok, err = pcall(mod.start, {
			HudUI = HudUI, ShopUI = ShopUI, RobuxShopUI = RobuxShopUI, ManageUI = ManageUI,
			PlacementController = PlacementController, InventoryUI = InventoryUI, MachineFX = MachineFX,
			RankUI = rankLoaded and RankUI or nil, UXFX = uxLoaded and UXFX or nil,
			PotionsUI = PotionsUI, RebirthUI = RebirthUI, PlaytimeUI = PlaytimeUI,
			QuestsUI = QuestsUI, WheelUI = WheelUI, EventsUI = EventsUI, CheatersUI = CheatersUI,
			StaffClient = StaffClient, DailyUI = DailyUI, StatsUI = StatsUI, UpgradesUI = UpgradesUI,
		})
		if not ok then warn(("[CasinoTycoon] %s.start: %s"):format(name, tostring(err))) end
	end
end
WelcomeUI.start()
DailyUI.start()
ShowroomUI.start()
MachineFX.start()
MapFX.start()
Sprint.start()
DayNightFX.start()     -- sky colours + street lamps follow the server's clock
BuildingView.start()   -- cut away the floors above you inside a casino
ElevatorUI.start()     -- floor picker at the elevator buttons
if trafficLoaded then  -- the city's cars (the server plans them, we drive them)
	local ok, err = pcall(TrafficClient.start)
	if not ok then warn("[CasinoTycoon] TrafficClient.start: " .. tostring(err)) end
end

-- initial snapshot (in case we connected after the server's first push)
task.spawn(function()
	local snap = Remotes.GetData():InvokeServer()
	if snap then UILib.setState(snap) end
end)

-- Climb from the prompt's part to the machine model (the ancestor carrying the
-- GameType attribute), so prompts work no matter how the model is nested.
local function resolveMachine(inst)
	while inst and inst ~= workspace do
		if inst:GetAttribute("GameType") then return inst end
		inst = inst.Parent
	end
	return nil
end

-- Climb to the showroom display model carrying the ShopMachineId attribute.
local function resolveShopDisplay(inst)
	while inst and inst ~= workspace do
		if inst:GetAttribute("ShopMachineId") then return inst end
		inst = inst.Parent
	end
	return nil
end

-- A machine is "mine" if the server stamped my UserId on it OR it appears in my
-- synced placed-machines list. The second check makes ownership robust even if
-- the OwnerId attribute hasn't replicated to this client yet.
local function isMyMachine(machine)
	if not (machine and machine:GetAttribute("GameType")) then return false end
	if machine:GetAttribute("OwnerId") == player.UserId then return true end
	local placedId = machine:GetAttribute("PlacedId")
	if placedId then
		for _, m in (UILib.state.placed or {}) do
			if m.placedId == placedId then return true end
		end
	end
	return false
end

-- Per-player prompt text: the prompt is created on the server as "Play" for
-- everyone, but on YOUR OWN machine it should advertise the upgrade/manage menu.
-- ActionText/HoldDuration are changed locally here so only this client sees it.
ProximityPromptService.PromptShown:Connect(function(prompt)
	local part = prompt.Parent
	if not part then return end
	local machine = resolveMachine(part)
	if not isMyMachine(machine) then return end

	prompt.ActionText = machine:GetAttribute("Kind") == "concession" and "Manage" or "Upgrade"
	prompt.ObjectText = machine.Name
	prompt.HoldDuration = 0.4  -- makes it read "Hold E" instead of "Press E"
end)

-- prompt routing
ProximityPromptService.PromptTriggered:Connect(function(prompt, plr)
	if plr ~= player then return end
	local part = prompt.Parent
	if not part then return end

	-- physical showroom: press E to buy the displayed machine into your inventory
	local display = resolveShopDisplay(part)
	if display then
		local machineId = display:GetAttribute("ShopMachineId")
		local res = Remotes.BuyToInventory():InvokeServer(machineId)
		if res and res.ok then
			UILib.toast("BOUGHT!", "unlock", res.message)
		else
			-- a machine above your rank (or your rebirths) is a goal, not a mistake: no error buzz
			local msg = res and res.message or "Purchase failed."
			local ranked = (res and (res.needRank or res.needRebirth)) or msg:find("^Unlocks at R") ~= nil
			UILib.toast(msg, ranked and "info" or "error")
		end
		return
	end

	-- services desk: concessions & staff
	if part:HasTag("ServicesKiosk") then
		ShopUI.open("concessions")
		return
	end

	-- Welcome Plaza kiosks
	if part:HasTag("DailyKiosk") then
		DailyUI.open()
		return
	end
	if part:HasTag("StoreKiosk") then
		RobuxShopUI.open()
		return
	end

	local machine = resolveMachine(part)
	if machine and machine:GetAttribute("GameType") then
		if isMyMachine(machine) then
			ManageUI.openForMachine(machine)        -- your own machine: upgrade / move / store / sell
		elseif machine:GetAttribute("Kind") == "concession" then
			UILib.toast("Patrons love your " .. machine.Name .. "!", "info")
		elseif machine:GetAttribute("GameType") == "Slots" then
			SlotsUI.open(machine)
		else
			GamesUI.open(machine)
		end
	end
end)

print("[CasinoTycoon] Client ready — Showtime UI.")
