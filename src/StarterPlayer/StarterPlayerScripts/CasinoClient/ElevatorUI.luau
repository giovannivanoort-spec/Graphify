--!nonstrict
-- ElevatorUI.luau — the floor picker. Every story of a casino building has an
-- elevator booth whose call button (tag "ElevatorCall") carries a prompt;
-- triggering it opens a small panel with one button per floor. The server
-- (Buildings.ride) checks you're at the elevator and moves you up or down.
-- Walking away from the elevator closes the panel (the ride would be refused).
-- In build mode the build floor follows you (PlacementController).
-- The VIP floor (Building attribute VipStory, VipFloor.luau) gets a gold VIP
-- LOUNGE button; in your own casino without the VIP pass a gold "VIP FLOOR"
-- row opens the store's game passes instead.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage:WaitForChild("CasinoCommon"):WaitForChild("Remotes"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors

local ElevatorUI = {}
local player = Players.LocalPlayer

local function flash()
	local sc = UILib.getScreen()
	local f = UILib.make("Frame", {
		Name = "ElevatorFlash", BackgroundColor3 = C.Ink, BackgroundTransparency = 0, Size = UDim2.fromScale(1, 1),
		ZIndex = 50, Parent = sc,
	})
	TweenService:Create(f, TweenInfo.new(0.45), { BackgroundTransparency = 1 }):Play()
	task.delay(0.5, function() f:Destroy() end)
end

-- the VIP floor's story in this building (nil without one)
local function vipStoryOf(building: Instance?): number?
	local v = building and building:GetAttribute("VipStory")
	return type(v) == "number" and v or nil
end

-- the VIP floor's 3D icon (the crown until ICONS2 uploads it)
local function vipIcon(): string
	return UILib.resolveIcon("vipfloor") ~= "" and "vipfloor" or "crown"
end

-- my own casino, and I don't have its VIP floor (yet): the upsell row
local function upsellHere(plot: Model): boolean
	if plot:GetAttribute("OwnerId") ~= player.UserId then return false end
	local vf = UILib.state.vipFloor
	return type(vf) == "table" and vf.enabled == true and vf.owned == false
end

-- "x1.25" from the snapshot's multiplier
local function multText(): string
	local vf = UILib.state.vipFloor
	local m = type(vf) == "table" and tonumber(vf.mult) or 1.25
	return "x" .. (("%.2f"):format(m):gsub("0+$", ""):gsub("%.$", ""))
end

-- the store's GAME PASSES tab (required lazily: RobuxShopUI is optional here)
local function openPasses()
	local mod = script.Parent:FindFirstChild("RobuxShopUI")
	local ok, shop = pcall(function() return mod and require(mod) end)
	if ok and type(shop) == "table" and type(shop.open) == "function" then shop.open("passes") end
end

-- button (optional): the call button used; the panel closes once you walk away from it
function ElevatorUI.open(plot: Model, currentStory: number, button: BasePart?)
	local building = plot:FindFirstChild("Building")
	local stories = building and building:GetAttribute("Stories") or 1
	local vipStory = vipStoryOf(building)
	local upsell = upsellHere(plot)
	if stories <= 1 then
		UILib.toast("ONLY ONE FLOOR", "info", upsell and "Build more floors in MY CASINO > BUILDING, or get the VIP pass for a free VIP floor!"
			or "Build more floors in MY CASINO > BUILDING.")
		return
	end
	local rows = stories + (upsell and 1 or 0)
	local p = UILib.panel({ name = "ElevatorPanel", title = "ELEVATOR", icon = "build", width = 520, height = 140 + rows * 76 })
	local col = UILib.make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = p.content })
	UILib.list(col, "y", 10, Enum.HorizontalAlignment.Center)
	if upsell then
		-- a free floor on top with the VIP pass: to the store
		local b = UILib.button({
			parent = col, tone = "Gold", order = -1, icon = vipIcon(), text = "VIP FLOOR  •  FREE WITH VIP",
			textSize = 22, size = UDim2.fromOffset(420, 64),
			onClick = function()
				p.close()
				openPasses()
			end,
		})
		local tag = UILib.badge(b.Instance, multText(), "Purple", 8, 6)
		tag.AnchorPoint = Vector2.new(1, 0)
		tag.Position = UDim2.new(1, 10, 0, -12)
	end
	for s = stories, 1, -1 do
		local here = s == currentStory
		local vip = s == vipStory
		UILib.button({
			parent = col, tone = vip and "Gold" or (here and "Purple" or "Blue"), order = stories - s,
			icon = vip and vipIcon() or nil,
			text = (vip and "VIP LOUNGE" or (s == 1 and "GROUND FLOOR" or ("FLOOR " .. s))) .. (here and "  •  YOU ARE HERE" or ""),
			textSize = 22, size = UDim2.fromOffset(420, 64),
			onClick = function()
				if here then p.close(); return end
				local res = Remotes.RideElevator():InvokeServer(plot, s)
				p.close()
				if res and res.ok then
					flash()
				else
					UILib.toast(res and res.message or "The elevator is stuck!", "error")
				end
			end,
		})
	end
	if button then
		task.spawn(function()
			while p.alive do
				task.wait(0.3)
				local char = player.Character
				local root = char and char:FindFirstChild("HumanoidRootPart")
				if p.alive and (not root or not button.Parent or (root.Position - button.Position).Magnitude > 12) then
					p.close()
				end
			end
		end)
	end
end

function ElevatorUI.start()
	ProximityPromptService.PromptTriggered:Connect(function(prompt, plr)
		if plr ~= player then return end
		local button = prompt.Parent
		if not (button and button:HasTag("ElevatorCall")) then return end
		local plot = button:FindFirstAncestorWhichIsA("Model")
		while plot and not plot:FindFirstChild("Base") do
			plot = plot.Parent and plot.Parent:IsA("Model") and plot.Parent or nil
		end
		if plot then ElevatorUI.open(plot, button:GetAttribute("Story") or 1, button:IsA("BasePart") and button or nil) end
	end)
end

return ElevatorUI
