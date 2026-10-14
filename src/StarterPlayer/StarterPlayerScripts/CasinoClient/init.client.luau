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
local Sprint = require(script:WaitForChild("Sprint"))

local player = Players.LocalPlayer

-- keep the client state cache in sync with server pushes
Remotes.DataUpdated().OnClientEvent:Connect(function(snap)
	UILib.setState(snap)
end)

-- HUD + welcome popup
HudUI.build({
	onShop = ShopUI.open,
	onInventory = InventoryUI.open,
	onMove = PlacementController.enterSelectMode,
	onUpgrades = UpgradesUI.open,
	onManage = ManageUI.openOverview,
	onStats = StatsUI.open,
	onRobuxShop = RobuxShopUI.open,
})
WelcomeUI.start()
ShowroomUI.start()
Sprint.start()

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
		UILib.toast(res and res.message or "Purchase failed.",
			(res and res.ok) and UILib.Colors.Green or UILib.Colors.Red)
		return
	end

	-- services desk: concessions & staff menu
	if part:HasTag("ServicesKiosk") then
		ShopUI.open()
		return
	end

	local machine = resolveMachine(part)
	if machine and machine:GetAttribute("GameType") then
		if isMyMachine(machine) then
			ManageUI.openForMachine(machine)        -- your own machine: pick up / sell / upgrade
		elseif machine:GetAttribute("Kind") == "concession" then
			UILib.toast("Patrons love your " .. machine.Name .. "!", UILib.Colors.Accent)
		elseif machine:GetAttribute("GameType") == "Slots" then
			SlotsUI.open(machine)
		else
			GamesUI.open(machine)
		end
	end
end)

print("[CasinoTycoon] Client ready — physical showroom + buy-on-E.")
