--!nonstrict
-- VipFloorUI.luau — the VIP floor's client side (server: VipFloor.luau; snapshot
-- `vipFloor` = { enabled, owned, story, mult, slots, machines, passId }):
--   * MY CASINO > BUILDING: a VIP LOUNGE plate crowns the floor tower
--     (ManageUI.addTabExtra): your lounge's floor + its x1.25, or, without the VIP
--     pass, a quiet upsell ("A FREE FLOOR ON TOP" + GET VIP) that opens the store's
--     GAME PASSES tab. The elevator panel has its own VIP rows (ElevatorUI).
--   * the welcome, the first time your lounge opens (on join, or right after buying
--     the pass): the server arms the Player attribute VipFloorWelcome = its story;
--     a gold flash, the purple banner, confetti, sparkles + "VIP LOUNGE" over your
--     building and a toast that says where it is
--   * a small crown "x1.25" chip over every machine on a VIP floor (any casino: the
--     machine attribute VipFloor); it lives in the machine model, so the cutaway
--     (BuildingView) hides it with the machine
--   * stepping onto a VIP floor (once a session per casino): a toast; visitors
--     without the pass hear that they can have their own
-- start(deps): deps.ManageUI, deps.RobuxShopUI (both optional)

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("CasinoCommon"):WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local F = UILib.Fonts

local VipFloorUI = {}
local player = Players.LocalPlayer
local H = Config.Building.StoryHeight
local CHIP = "VipChip"

local RobuxShopUI = nil
local started = false

------------------------------------------------------------------
-- helpers
------------------------------------------------------------------
local function vipState()
	local vf = UILib.state.vipFloor
	return type(vf) == "table" and vf or nil
end

-- "x1.25" (the snapshot's multiplier, else the config's)
local function multText(): string
	local vf = vipState()
	local m = (vf and tonumber(vf.mult)) or (Config.VipFloor and Config.VipFloor.IncomeMult) or 1.25
	return "x" .. (("%.2f"):format(m):gsub("0+$", ""):gsub("%.$", ""))
end

-- the VIP floor's 3D icon (the crown until ICONS2 uploads it)
local function vipIcon(): string
	return UILib.resolveIcon("vipfloor") ~= "" and "vipfloor" or "crown"
end

local function openPasses()
	local shop = RobuxShopUI
	if not shop then
		local mod = script.Parent:FindFirstChild("RobuxShopUI")
		local ok, res = pcall(function() return mod and require(mod) end)
		shop = ok and type(res) == "table" and res or nil
	end
	if shop and type(shop.open) == "function" then shop.open("passes") end
end

local function vipStoryOf(plot: Instance?): number?
	local b = plot and plot:FindFirstChild("Building")
	local v = b and b:GetAttribute("VipStory")
	return type(v) == "number" and v or nil
end

local function myPlot(): Model?
	local plots = Workspace:FindFirstChild("Plots")
	if not plots then return nil end
	for _, m in plots:GetChildren() do
		if m:GetAttribute("OwnerId") == player.UserId and m:FindFirstChild("Base") then return m end
	end
	return nil
end

-- the casino plot + story the local player stands on (as BuildingView)
local function locate(): (Model?, number?)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local plots = Workspace:FindFirstChild("Plots")
	if not (root and plots) then return nil end
	for _, plot in plots:GetChildren() do
		local base = plot:FindFirstChild("Base")
		local building = plot:FindFirstChild("Building")
		if base and building and base:IsA("BasePart") then
			local rel = base.CFrame:PointToObjectSpace(root.Position)
			if math.abs(rel.X) <= base.Size.X / 2 + 1.5 and math.abs(rel.Z) <= base.Size.Z / 2 + 1.5 then
				local stories = building:GetAttribute("Stories") or 1
				local feet = rel.Y + base.Size.Y / 2 - 3
				if feet > -2 and feet < stories * H + 2 then
					return plot, math.clamp(math.floor((feet - 1) / H + 0.25) + 1, 1, stories)
				end
			end
		end
	end
	return nil
end

------------------------------------------------------------------
-- MY CASINO > BUILDING: the VIP LOUNGE plate on top of the floor tower
------------------------------------------------------------------
local FLOOR_H, FLOOR_GAP, PLATE_H = 64, 8, 56 -- ManageUI's tower rows

local function towerPlate(page: Instance, state)
	local tower = page:FindFirstChild("Tower")
	local vf = type(state) == "table" and type(state.vipFloor) == "table" and state.vipFloor or nil
	if not (tower and vf and vf.enabled) then return end
	local owned = vf.owned == true
	local b = type(state.building) == "table" and state.building or {}
	local rows = tonumber(b.maxStories) or Config.Building.MaxStories
	local plate = UILib.make("Frame", {
		Name = "VipFloor", BackgroundColor3 = C.White, AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -rows * (FLOOR_H + FLOOR_GAP)), Size = UDim2.new(1, 0, 0, PLATE_H), Parent = tower,
	})
	UILib.corner(plate, 14)
	UILib.gradient(plate, C.Purple, C.PurpleShadow)
	UILib.stroke(plate, owned and C.Gold or C.GoldDeep, 3.5, true)
	UILib.image(plate, vipIcon(), {
		size = UDim2.fromOffset(52, 52), anchor = Vector2.new(0, 0.5), position = UDim2.new(0, 4, 0.5, -2),
	})
	UILib.text(plate, {
		text = "VIP LOUNGE", size = 22, xAlign = Enum.TextXAlignment.Left, gradient = { C.White, C.GoldTop },
		frameSize = UDim2.new(1, -160, 0, 28), position = UDim2.fromOffset(60, 4), stroke = 3, shadow = 3,
	})
	UILib.body(plate, {
		text = owned and ("FLOOR %d  •  FREE WITH VIP"):format(tonumber(vf.story) or 0) or "A FREE FLOOR ON TOP",
		font = F.Display, size = 13, color = C.GoldTop,
		frameSize = UDim2.new(1, -160, 0, 16), position = UDim2.fromOffset(61, 33),
	})
	-- the whole plate is a button: your lounge says where it is, the upsell opens the store
	local click = UILib.make("TextButton", {
		Name = "Click", Text = "", BackgroundTransparency = 1, AutoButtonColor = false, Size = UDim2.fromScale(1, 1),
		ZIndex = 2, Parent = plate,
	})
	click.Activated:Connect(function()
		if owned then
			UILib.toast("YOUR VIP LOUNGE", "info", ("Ride the elevator to the top floor: every machine there earns %s."):format(multText()))
		else
			openPasses()
		end
	end)
	if owned then
		local tag = UILib.badge(plate, multText(), "Green", 0, 5)
		tag.AnchorPoint = Vector2.new(1, 0.5)
		tag.Position = UDim2.new(1, -10, 0.5, 0)
	else
		UILib.button({
			parent = plate, tone = "Gold", text = "GET VIP", textSize = 18, size = UDim2.fromOffset(96, 42),
			anchor = Vector2.new(1, 0.5), position = UDim2.new(1, -7, 0.5, -1), z = 3, onClick = openPasses,
		})
	end
end

------------------------------------------------------------------
-- the welcome (the first time your lounge opens)
------------------------------------------------------------------
local welcomed = {}      -- story -> true (played this session)
local seenLounge = {}    -- plot -> true (the step-onto toast, once a session per casino)

local function playWelcome(story: number)
	if welcomed[story] then return end
	welcomed[story] = true
	task.spawn(function()
		-- after the join settles (character in the world, first toasts / popups up)
		local t0 = os.clock()
		while os.clock() - t0 < 20 and not (player.Character and player.Character:FindFirstChild("HumanoidRootPart")) do
			task.wait(0.5)
		end
		task.wait(2)
		UILib.fx("flash", C.GoldTop, 0.3)
		UILib.fx("banner", "VIP LOUNGE OPEN!", ("A FREE FLOOR ON TOP  •  MACHINES EARN %s"):format(multText()), "purple", "fanfare")
		UILib.fx("confetti", nil, 90, "show")
		local plot = myPlot()
		local base = plot and plot:FindFirstChild("Base")
		if base and base:IsA("BasePart") then
			seenLounge[plot] = true -- (no second toast when they ride up)
			local spot = base.CFrame:PointToWorldSpace(Vector3.new(0, base.Size.Y / 2 + (story - 1) * H + 8, 0))
			UILib.fx("sparkle", spot, 24, C.GoldTop)
			UILib.fx("worldText", spot + Vector3.new(0, 6, 0), "VIP LOUNGE", C.GoldTop, 34)
		end
		task.wait(2.4)
		UILib.toast("VIP LOUNGE OPEN", "info",
			("Your free floor is on top: ride the elevator up. Every machine there earns %s."):format(multText()))
	end)
end

local function onWelcomeAttr()
	local story = player:GetAttribute("VipFloorWelcome")
	if type(story) == "number" and story > 0 then playWelcome(story) end
end

------------------------------------------------------------------
-- the x1.25 chip over the machines on a VIP floor
------------------------------------------------------------------
local watched: {[Instance]: {RBXScriptConnection}} = {}

local function refreshChip(m: Instance, tries: number?)
	if not (m:IsA("Model") and m.Parent) then return end
	local want = m:GetAttribute("VipFloor") == true and m:GetAttribute("Kind") ~= "concession"
	local chip = m:FindFirstChild(CHIP)
	if not want then
		if chip then chip:Destroy() end
		return
	end
	if chip then return end
	local body = m.PrimaryPart or m:FindFirstChild("Body")
	if not (body and body:IsA("BasePart")) then
		-- (still streaming in) look again in a moment
		if (tries or 0) < 5 then task.delay(1.5, refreshChip, m, (tries or 0) + 1) end
		return
	end
	local tag = body:FindFirstChild("NameTag")
	local y = ((tag and tag:IsA("BillboardGui")) and tag.StudsOffset.Y or 6) + 1.3
	local bb = UILib.make("BillboardGui", {
		Name = CHIP, Adornee = body, Size = UDim2.fromScale(3.2, 1), StudsOffset = Vector3.new(0, y, 0),
		AlwaysOnTop = true, MaxDistance = 90, LightInfluence = 0, Parent = m,
	})
	local pill = UILib.make("Frame", { Name = "Pill", BackgroundColor3 = C.White, Size = UDim2.fromScale(1, 1), Parent = bb })
	UILib.corner(pill, 999)
	UILib.gradient(pill, C.Purple, C.PurpleShadow)
	UILib.stroke(pill, C.GoldTop, 2, true)
	UILib.make("ImageLabel", {
		Name = "Crown", BackgroundTransparency = 1, Image = UILib.resolveIcon(vipIcon()), ScaleType = Enum.ScaleType.Fit,
		AnchorPoint = Vector2.new(0, 0.5), Size = UDim2.fromScale(0.34, 1.25), Position = UDim2.fromScale(0.01, 0.42), Parent = pill,
	})
	local label = UILib.make("TextLabel", {
		Name = "Mult", BackgroundTransparency = 1, Size = UDim2.fromScale(0.6, 0.84), Position = UDim2.fromScale(0.35, 0.08),
		Text = multText(), TextScaled = true, Font = F.Display, TextColor3 = C.White, Parent = pill,
	})
	UILib.make("UIGradient", { Rotation = 90, Color = ColorSequence.new(C.GoldTop, C.Gold), Parent = label })
	UILib.make("UIStroke", { Color = C.Ink, Thickness = 2, Parent = label })
end

local function watch(m: Instance)
	if watched[m] then return end
	watched[m] = {
		m:GetAttributeChangedSignal("VipFloor"):Connect(function() refreshChip(m) end),
	}
	refreshChip(m)
end

local function unwatch(m: Instance)
	local conns = watched[m]
	watched[m] = nil
	if conns then
		for _, c in conns do c:Disconnect() end
	end
end

------------------------------------------------------------------
-- stepping onto a VIP floor
------------------------------------------------------------------
local function checkLounge()
	local plot, story = locate()
	if not (plot and story) or seenLounge[plot] then return end
	local vs = vipStoryOf(plot)
	if not (vs and story == vs) then return end
	seenLounge[plot] = true
	if plot:GetAttribute("OwnerId") == player.UserId then
		UILib.toast("YOUR VIP LOUNGE", "info", ("Every machine up here earns %s. Fill it up!"):format(multText()))
	else
		local vf = vipState()
		local upsell = vf and vf.enabled and vf.owned == false
		UILib.toast("VIP LOUNGE", "info", ("Machines up here earn %s.%s"):format(multText(),
			upsell and " The VIP pass gives you your own!" or ""))
	end
end

------------------------------------------------------------------
-- start
------------------------------------------------------------------
function VipFloorUI.start(deps)
	if started then return end
	started = true
	deps = deps or {}
	RobuxShopUI = deps.RobuxShopUI
	if deps.ManageUI and type(deps.ManageUI.addTabExtra) == "function" then
		deps.ManageUI.addTabExtra("building", towerPlate)
	end
	-- the welcome may have been armed before this client got here
	player:GetAttributeChangedSignal("VipFloorWelcome"):Connect(onWelcomeAttr)
	onWelcomeAttr()
	CollectionService:GetInstanceAddedSignal("CasinoMachine"):Connect(watch)
	CollectionService:GetInstanceRemovedSignal("CasinoMachine"):Connect(unwatch)
	for _, m in CollectionService:GetTagged("CasinoMachine") do watch(m) end
	task.spawn(function()
		while true do
			task.wait(0.6)
			local ok, err = pcall(checkLounge)
			if not ok then warn("[VipFloorUI] " .. tostring(err)) end
		end
	end)
end

-- (other UIs) open the store on the VIP pass
VipFloorUI.openStore = openPasses

return VipFloorUI
