--!nonstrict
-- NPCs.luau — patrons that walk to casinos and gamble.
--   * Real player-looking avatars via Players:CreateHumanoidModelFromUserId
--     (falls back to a built rig if that call fails).
--   * Animator + LoadAnimation on the default Roblox walk/idle so they animate
--     like real characters.
--   * SetNetworkOwner(nil) so the SERVER simulates movement.
--   * PathfindingService nav with per-waypoint MoveTo, stuck detection, repath.
--   * Collision group so NPCs don't shove players or each other.
--   * One patron per machine (reservation table).
--   * Wallet shown above the head ($X), starts in [WalletMin, WalletMax] and
--     updates as they win/lose. Upgradable later via Config.NPC.WalletMin/Max.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))

local NPCs = {}
local Gambling, Plots, Upgrades, Data, Economy

local rng = Random.new()
local active = {}        -- npc -> true
local activeCount = 0
local machineUsers = {}  -- machine -> npc   (one patron per machine)

-- Curated public user IDs so avatars look like real players.
-- Add more for more variety.
local AVATAR_USER_IDS = {
	1, 156, 261, 268, 7733466, 16, 8125969, 13268404,
	2231221, 5097175, 9707030, 1146521, 17262540, 30086683,
}

-- Roblox default anim IDs (public). Try R15 first, fall back to R6 ids if the
-- avatar is R6 or the R15 track fails to load.
local ANIM_WALK_R15 = "rbxassetid://913402848"
local ANIM_IDLE_R15 = "rbxassetid://507766388"
local ANIM_WALK_R6  = "rbxassetid://180426354"
local ANIM_IDLE_R6  = "rbxassetid://180435571"

local function flatDist(a: Vector3, b: Vector3): number
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

------------------------------------------------------------------
-- owner friend list (for VIP avatars)
--   VIPs are rendered as the casino owner's real Roblox friends. Friend lists
--   come from Players:GetFriendsAsync(ownerId), which yields and is rate-limited,
--   so we cache per owner and refresh every Config.NPC.FriendCacheSeconds.
--   Works whether or not the owner is currently online.
------------------------------------------------------------------
local friendCache = {}  -- ownerId -> { list = {{Id=, Username=}, ...}, ts = os.clock() }

local function fetchFriends(userId: number)
	local list = {}
	local ok, pages = pcall(function()
		return Players:GetFriendsAsync(userId)
	end)
	if not ok or not pages then return list end
	local cap = Config.NPC.FriendFetchMax or 60
	local done = false
	pcall(function()
		while not done do
			for _, info in pages:GetCurrentPage() do
				if info.Id then
					table.insert(list, { Id = info.Id, Username = info.Username or info.DisplayName or "Friend" })
					if #list >= cap then done = true; break end
				end
			end
			if done or pages.IsFinished then break end
			pages:AdvanceToNextPageAsync()
		end
	end)
	return list
end

local function getOwnerFriends(ownerId: number?)
	if not ownerId then return nil end
	local ttl = Config.NPC.FriendCacheSeconds or 600
	local cached = friendCache[ownerId]
	if cached and (os.clock() - cached.ts) < ttl then
		return cached.list
	end
	local list = fetchFriends(ownerId)
	friendCache[ownerId] = { list = list, ts = os.clock() }
	return list
end

-- Roll a patron's spec at spawn time. VIPs are shown as one of the casino
-- owner's real friends (avatar + name); everyone else uses the random pool.
local function rollPatronSpec(casino)
	local isVIP = rng:NextNumber() < (Config.NPC.VIPChance or 0)
	local userId, vipName = nil, nil
	if isVIP and Config.NPC.VIPUseOwnerFriends and casino and casino.ownerId then
		local friends = getOwnerFriends(casino.ownerId)
		if friends and #friends > 0 then
			local f = friends[rng:NextInteger(1, #friends)]
			userId = f.Id
			vipName = f.Username
		elseif Config.NPC.VIPRequireFriend then
			isVIP = false  -- no friend to show -> demote to a normal patron
		end
	end
	if not userId then
		userId = AVATAR_USER_IDS[rng:NextInteger(1, #AVATAR_USER_IDS)]
	end
	return { isVIP = isVIP, userId = userId, vipName = vipName }
end

------------------------------------------------------------------
-- avatar build (with a tiny block rig fallback)
------------------------------------------------------------------
local function applyCollisionGroup(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then d.CollisionGroup = Config.CollisionGroups.NPC end
	end
end

local function buildFallbackRig(): Model
	local model = Instance.new("Model")
	model.Name = "CasinoNPC"
	local function part(name, size, color, parent)
		local p = Instance.new("Part")
		p.Name = name; p.Size = size; p.Color = color
		p.TopSurface = Enum.SurfaceType.Smooth; p.BottomSurface = Enum.SurfaceType.Smooth
		p.Material = Enum.Material.SmoothPlastic
		p.Parent = parent
		return p
	end
	local hrp = part("HumanoidRootPart", Vector3.new(2, 2, 1), Color3.new(), model)
	hrp.Transparency = 1; hrp.CanCollide = false; hrp.Massless = true
	local torso = part("Torso", Vector3.new(2, 2, 1), Color3.fromRGB(70, 75, 95), model)
	local head = part("Head", Vector3.new(2, 1, 1), Color3.fromRGB(245, 215, 175), model)
	head.CFrame = torso.CFrame * CFrame.new(0, 1.5, 0)
	local function joint(name, p0, p1, c0, c1, parent)
		local m = Instance.new("Motor6D")
		m.Name = name; m.Part0 = p0; m.Part1 = p1; m.C0 = c0; m.C1 = c1
		m.Parent = parent
	end
	joint("RootJoint", hrp, torso, CFrame.new(), CFrame.new(), hrp)
	joint("Neck", torso, head, CFrame.new(0, 1, 0), CFrame.new(0, -0.5, 0), torso)
	local hum = Instance.new("Humanoid")
	hum.RigType = Enum.HumanoidRigType.R6
	hum.Parent = model
	Instance.new("Animator").Parent = hum
	model.PrimaryPart = hrp
	return model
end

local function loadAvatar(userId: number?): Model
	userId = userId or AVATAR_USER_IDS[rng:NextInteger(1, #AVATAR_USER_IDS)]
	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromUserId(userId)
	end)
	if ok and model then return model end
	return buildFallbackRig()
end

------------------------------------------------------------------
-- wallet billboard above the head
------------------------------------------------------------------
local function makeWalletGui(head: BasePart): TextLabel
	local bb = Instance.new("BillboardGui")
	bb.Name = "WalletGui"
	bb.Size = UDim2.fromScale(4, 1)
	bb.StudsOffset = Vector3.new(0, 2.4, 0)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.Adornee = head
	bb.Parent = head

	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
	bg.BackgroundTransparency = 0.25
	bg.BorderSizePixel = 0
	bg.Parent = bb
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6); corner.Parent = bg
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(245, 197, 24); stroke.Thickness = 1.5
	stroke.Parent = bg

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundTransparency = 1
	lbl.TextScaled = true; lbl.Font = Enum.Font.GothamBold
	lbl.TextColor3 = Color3.fromRGB(245, 197, 24)
	lbl.Text = "$0"
	lbl.Parent = bg
	return lbl
end

local function buildNPC(spawnPos: Vector3, avatarUserId: number?, vipName: string?)
	local model = loadAvatar(avatarUserId)
	model.Name = vipName or "CasinoNPC"
	local hum = model:FindFirstChildOfClass("Humanoid")
	local hrp = model:FindFirstChild("HumanoidRootPart") :: BasePart
	if not hum or not hrp then
		model:Destroy()
		return nil
	end
	hum.WalkSpeed = Config.NPC.WalkSpeed
	hum.BreakJointsOnDeath = false
	hum:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
	hum:SetStateEnabled(Enum.HumanoidStateType.Seated, false)
	-- float the friend's username above VIP heads
	if vipName and Config.NPC.VIPShowFriendName then
		hum.DisplayName = vipName
	end

	model:PivotTo(CFrame.new(spawnPos + Vector3.new(0, 3, 0)))

	applyCollisionGroup(model)

	local head = model:FindFirstChild("Head") :: BasePart
	local walletLabel = head and makeWalletGui(head)

	model.Parent = Workspace

	if hrp:CanSetNetworkOwnership() then
		hrp:SetNetworkOwner(nil)
	end

	-- The avatar from CreateHumanoidModelFromUserId ships a default "Animate"
	-- LocalScript. It never runs on a server-owned NPC (LocalScripts only run in
	-- the local player's own character), so it does nothing but spam
	-- "failed to load animation" warnings on clients. Remove it and drive the
	-- animations ourselves from the server.
	local bundledAnimate = model:FindFirstChild("Animate")
	if bundledAnimate then bundledAnimate:Destroy() end

	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = hum
	end

	local isR6 = hum.RigType == Enum.HumanoidRigType.R6
	local function tryLoad(id)
		local ok, track = pcall(function()
			local a = Instance.new("Animation"); a.AnimationId = id
			return animator:LoadAnimation(a)
		end)
		return ok and track or nil
	end
	local walkTrack = tryLoad(isR6 and ANIM_WALK_R6 or ANIM_WALK_R15)
		or tryLoad(ANIM_WALK_R15) or tryLoad(ANIM_WALK_R6)
	local idleTrack = tryLoad(isR6 and ANIM_IDLE_R6 or ANIM_IDLE_R15)
		or tryLoad(ANIM_IDLE_R15) or tryLoad(ANIM_IDLE_R6)
	if walkTrack then walkTrack.Looped = true; walkTrack.Priority = Enum.AnimationPriority.Movement end
	if idleTrack then idleTrack.Looped = true; idleTrack.Priority = Enum.AnimationPriority.Idle end

	-- start in the idle pose so they're never frozen in a T/A-pose
	if idleTrack then idleTrack:Play(0.2) end

	-- Drive walk vs. idle from the humanoid's own Running signal. This is the
	-- reliable trigger for server-simulated NPCs (fires whenever MoveTo starts or
	-- stops them) and replaces the per-frame MoveDirection polling.
	local baseSpeed = math.max(1, Config.NPC.WalkSpeed)
	local animConn = hum.Running:Connect(function(speed)
		if speed > 0.1 then
			if idleTrack and idleTrack.IsPlaying then idleTrack:Stop(0.15) end
			if walkTrack then
				if not walkTrack.IsPlaying then walkTrack:Play(0.15) end
				walkTrack:AdjustSpeed(speed / baseSpeed) -- feet match actual speed
			end
		else
			if walkTrack and walkTrack.IsPlaying then walkTrack:Stop(0.15) end
			if idleTrack and not idleTrack.IsPlaying then idleTrack:Play(0.15) end
		end
	end)

	return {
		model = model, hum = hum, root = hrp,
		walletLabel = walletLabel,
		walkTrack = walkTrack, idleTrack = idleTrack,
		animConn = animConn,
	}
end

------------------------------------------------------------------
-- floating "+X / -X" feedback
------------------------------------------------------------------
local function popText(adornee: BasePart, text: string, color: Color3)
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromScale(3, 1); bb.StudsOffset = Vector3.new(0, 3.4, 0)
	bb.AlwaysOnTop = true; bb.Adornee = adornee; bb.Parent = adornee
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1); lbl.BackgroundTransparency = 1
	lbl.TextScaled = true; lbl.Font = Enum.Font.GothamBold
	lbl.TextColor3 = color; lbl.Text = text; lbl.Parent = bb
	task.spawn(function()
		for i = 1, 12 do
			bb.StudsOffset += Vector3.new(0, 0.13, 0)
			lbl.TextTransparency = i / 12
			task.wait(0.05)
		end
		bb:Destroy()
	end)
end

------------------------------------------------------------------
-- navigation: pathfinding + per-waypoint MoveTo with timeout/recompute
------------------------------------------------------------------
local function moveStep(npc, point: Vector3, deadline: number): boolean
	local hum, root = npc.hum, npc.root
	local stepDeadline = math.min(deadline, os.clock() + 6)
	hum:MoveTo(Vector3.new(point.X, root.Position.Y, point.Z))
	local start = os.clock()
	local startPos = root.Position
	while root.Parent and os.clock() < stepDeadline do
		if flatDist(root.Position, point) < 3 then return true end
		task.wait(0.15)
		if os.clock() - start > Config.NPC.StuckCheckInterval
			and (root.Position - startPos).Magnitude < 1 then
			return false
		end
	end
	return root.Parent ~= nil and flatDist(root.Position, point) < 3
end

local function walkTo(npc, dest: Vector3): boolean
	local root = npc.root
	local deadline = os.clock() + Config.NPC.MoveTimeout
	local attempts = 0
	while root.Parent and os.clock() < deadline and attempts < 4 do
		attempts += 1
		local path = PathfindingService:CreatePath({
			AgentRadius = 2.5, AgentHeight = 5, AgentCanJump = false,
			AgentJumpHeight = 0, AgentMaxSlope = 45,
		})
		local ok = pcall(function() path:ComputeAsync(root.Position, dest) end)
		if not ok or path.Status ~= Enum.PathStatus.Success then
			task.wait(0.25); continue
		end
		local waypoints = path:GetWaypoints()
		local stuck = false
		for i = 2, #waypoints do
			local wp = waypoints[i]
			if not root.Parent or os.clock() > deadline then break end
			if not moveStep(npc, wp.Position, deadline) then stuck = true; break end
		end
		if not stuck and flatDist(root.Position, dest) < 4 then return true end
		task.wait(0.15)
	end
	-- no teleport fallback: if they can't get there, they just give up
	return root.Parent ~= nil and flatDist(root.Position, dest) < 4
end

local function choiceFor(gameType: string)
	if gameType == "Roulette" then
		return { kind = "color", value = rng:NextInteger(0, 1) == 0 and "red" or "black" }
	elseif gameType == "Dice" then
		return { target = rng:NextInteger(40, 70) }
	end
	return nil
end

------------------------------------------------------------------
-- one patron's visit
------------------------------------------------------------------
local function runPatron(npc, casino, spec)
	local ownerProfile = casino.ownerId and Data and Data.get(Players:GetPlayerByUserId(casino.ownerId)) or nil
	local walletBonus = (Upgrades and ownerProfile) and Upgrades.effect(ownerProfile, "walletBonus") or 0
	local tiltBonus = (Upgrades and ownerProfile) and Upgrades.effect(ownerProfile, "tiltBonus") or 0
	local visitBonus = (Upgrades and ownerProfile) and Upgrades.effect(ownerProfile, "visitBonus") or 0
	local patronTilt = (Config.NPC.ExtraLossChance or 0) + tiltBonus

	-- VIP status was decided at spawn (a VIP is one of the owner's real friends)
	local isVIP = spec and spec.isVIP or false
	local walletMult = isVIP and (Config.NPC.VIPWalletMultiplier or 5) or 1
	local betFracMin = isVIP and Config.NPC.VIPBetFractionMin or Config.NPC.BetFractionMin
	local betFracMax = isVIP and Config.NPC.VIPBetFractionMax or Config.NPC.BetFractionMax

	local wallet = (rng:NextInteger(Config.NPC.WalletMin, Config.NPC.WalletMax) + walletBonus) * walletMult
	local function setWallet(v)
		wallet = math.max(0, v)
		if npc.walletLabel then
			npc.walletLabel.Text = (isVIP and "\u{1F451} $" or "$") .. wallet
		end
	end
	setWallet(wallet)
	if isVIP and npc.walletLabel then
		npc.walletLabel.TextColor3 = Color3.fromRGB(255, 215, 0)
	end

	local heldMachine: Instance? = nil
	local function release()
		if heldMachine and machineUsers[heldMachine] == npc then
			machineUsers[heldMachine] = nil
		end
		heldMachine = nil
	end
	local function cleanup()
		release()
		active[npc] = nil
		activeCount -= 1
		if npc.animConn then npc.animConn:Disconnect(); npc.animConn = nil end
		if npc.model.Parent then npc.model:Destroy() end
	end

	local ok = pcall(function()
		if not casino or #casino.machines == 0 then return end

		-- split casino objects into gambling machines and concessions
		local gambleMachines, concessions = {}, {}
		for _, m in casino.machines do
			if m.Parent then
				if m:GetAttribute("Kind") == "concession" then
					table.insert(concessions, m)
				else
					table.insert(gambleMachines, m)
				end
			end
		end

		-- optional concession visit on arrival
		if #concessions > 0
			and rng:NextNumber() < (Config.NPC.ConcessionVisitChance or 0) then
			local c = concessions[rng:NextInteger(1, #concessions)]
			local cp = c.PrimaryPart
			if cp then
				-- code-built models say how far their front edge sits from the PrimaryPart
				local reach = c:GetAttribute("ApproachDistance") or 3
				walkTo(npc, cp.Position + cp.CFrame.LookVector * (reach + 3))
				walkTo(npc, cp.Position + cp.CFrame.LookVector * reach)
				local rp = npc.root.Position
				npc.root.CFrame = CFrame.lookAt(rp, Vector3.new(cp.Position.X, rp.Y, cp.Position.Z))
				local revenue = c:GetAttribute("RevenuePerVisit") or 0
				if isVIP then revenue = math.floor(revenue * (Config.NPC.ConcessionVIPMultiplier or 1)) end
				revenue = math.min(revenue, wallet)
				if revenue > 0 then
					setWallet(wallet - revenue)
					local owner = casino.ownerId and Players:GetPlayerByUserId(casino.ownerId)
					if owner and Economy then Economy.addCash(owner, revenue) end
					popText(npc.root, "-" .. revenue, Color3.fromRGB(241, 196, 15))
				end
				task.wait(rng:NextNumber(0.5, 1.0))
			end
		end

		local visits = rng:NextInteger(Config.NPC.MachinesPerVisitMin, Config.NPC.MachinesPerVisitMax + visitBonus)
		for _ = 1, visits do
			if wallet < 10 or #gambleMachines == 0 then break end

			local candidates = {}
			for _, m in gambleMachines do
				if m.Parent and not machineUsers[m] then table.insert(candidates, m) end
			end
			if #candidates == 0 then task.wait(rng:NextNumber(0.8, 1.6)); continue end
			local machine = candidates[rng:NextInteger(1, #candidates)]
			local mp = machine.PrimaryPart
			if not mp then continue end

			machineUsers[machine] = npc
			heldMachine = machine
			-- approach the FRONT of the machine; first step to a side waypoint so
			-- we don't try to walk straight through the body
			local reach = machine:GetAttribute("ApproachDistance") or 3
			local front = mp.Position + mp.CFrame.LookVector * (reach + 3)
			walkTo(npc, front)
			walkTo(npc, mp.Position + mp.CFrame.LookVector * reach)
			if not machine.Parent then release(); continue end

			-- face the machine (yaw only)
			do
				local rp = npc.root.Position
				local mpos = mp.Position
				npc.root.CFrame = CFrame.lookAt(rp, Vector3.new(mpos.X, rp.Y, mpos.Z))
			end

			local gameType = machine:GetAttribute("GameType")
			local minBet = machine:GetAttribute("MinBet") or 5
			local maxBet = machine:GetAttribute("MaxBet") or 100
			local speedLvl = machine:GetAttribute("SpeedLevel") or 0
			local luckyLvl = machine:GetAttribute("LuckyLevel") or 0
			local speedScale = math.max(0.2, 1 - speedLvl * (Config.MachineUpgrades.speed.perLevel))
			local machineTilt = math.min(0.85, patronTilt + luckyLvl * (Config.MachineUpgrades.lucky.perLevel))
			local rounds = rng:NextInteger(Config.NPC.RoundsPerMachineMin, Config.NPC.RoundsPerMachineMax)

			for _ = 1, rounds do
				if wallet < minBet or not machine.Parent then break end
				local frac = rng:NextNumber(betFracMin, betFracMax)
				local bet = math.clamp(math.floor(wallet * frac), minBet, maxBet)
				local res = Gambling.npcPlay(machine, bet, choiceFor(gameType), machineTilt)
				if res then
					setWallet(wallet + res.npcNet)
					if res.npcNet > 0 then popText(npc.root, "+" .. res.npcNet, Color3.fromRGB(46, 204, 113))
					elseif res.npcNet < 0 then popText(npc.root, tostring(res.npcNet), Color3.fromRGB(231, 76, 60)) end
				end
				task.wait(rng:NextNumber(Config.NPC.ThinkDelayMin, Config.NPC.ThinkDelayMax) * speedScale)
			end
			release()
		end

		-- exit: walk back out the front door and away
		local leaveTarget = (casino.entrance or Plots.PlazaCenter) + Vector3.new(0, 0, 14)
		walkTo(npc, leaveTarget)
		task.wait(0.4)
	end)
	if not ok then warn("[NPCs] patron error") end
	cleanup()
end

-- Is there anything for a new patron to do at this casino *right now*? True if a
-- gambling machine is free, or (for a concession-only casino) there's a stand to
-- visit. Prevents spawning patrons that would just wander and leave.
local function casinoHasOpening(casino): boolean
	local hasGamble, freeGamble, hasConc = false, false, false
	for _, m in casino.machines do
		if m.Parent then
			if m:GetAttribute("Kind") == "concession" then
				hasConc = true
			else
				hasGamble = true
				if not machineUsers[m] then freeGamble = true end
			end
		end
	end
	if hasGamble then return freeGamble end
	return hasConc
end

-- Soft cap on simultaneous patrons: roughly the number of usable machines, so we
-- never keep more NPCs around than there are things to do.
local function spawnCapacity(casinos): number
	local gamble, conc = 0, 0
	for _, c in casinos do
		for _, m in c.machines do
			if m.Parent then
				if m:GetAttribute("Kind") == "concession" then conc += 1 else gamble += 1 end
			end
		end
	end
	local usable = gamble > 0 and gamble or math.min(conc, 3)
	return math.max(1, usable)
end

function NPCs.start(deps)
	Gambling = deps.Gambling
	Plots = deps.Plots
	Upgrades = deps.Upgrades
	Data = deps.Data
	Economy = deps.Economy

	task.spawn(function()
		while true do
			task.wait(Config.NPC.SpawnInterval)
			if activeCount >= Config.NPC.MaxActive then continue end
			local casinos = Plots.getOwnedPlotsWithMachines()
			if #casinos == 0 then continue end
			-- Anti-churn: don't run more patrons than there are usable machines, and only
				-- spawn toward a casino that has a free machine/stand right now.
				if activeCount >= math.min(Config.NPC.MaxActive, spawnCapacity(casinos)) then continue end
				local openCasinos = {}
				for _, cc in casinos do
					if casinoHasOpening(cc) then table.insert(openCasinos, cc) end
				end
				if #openCasinos == 0 then continue end
				casinos = openCasinos  -- only weight/pick casinos that have an opening

				-- weighted pick: casinos with the spawnBonus upgrade are more likely
			local weighted = {}
			local totalWeight = 0
			for _, c in casinos do
				local prof = c.ownerId and Data and Data.get(game:GetService("Players"):GetPlayerByUserId(c.ownerId)) or nil
				local w = 1 + ((Upgrades and prof) and Upgrades.effect(prof, "spawnBonus") or 0)
				totalWeight += w
				table.insert(weighted, { c = c, cum = totalWeight })
			end
			local pick = rng:NextNumber() * totalWeight
			local casino = weighted[#weighted].c
			for _, w in weighted do if pick <= w.cum then casino = w.c; break end end
			local spawnPos = casino.entrance or Plots.PlazaCenter
			local spec = rollPatronSpec(casino)
			local npc = buildNPC(spawnPos, spec.userId, spec.isVIP and spec.vipName or nil)
			if npc then
				active[npc] = true
				activeCount += 1
				task.spawn(function() runPatron(npc, casino, spec) end)
			end
		end
	end)
end

return NPCs
