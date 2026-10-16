--!nonstrict
-- NPCs.luau — patrons that come to the casinos by car and gamble.
--   * They arrive by car (Traffic.luau): a taxi / car / the VIP's limo comes
--     out of a tunnel and pulls into the casino's curb stop; its passengers
--     (a party of 1-4, more with Party Shuttles) step out beside the doors and
--     walk in (at Moving Walkways speed). When they're
--     done they walk back out to the curb, wait, and ride off (sharing any car
--     that's coming to that stop). Plots without a curb stop (no Arm
--     attribute, e.g. an older map) fall back to appearing at the entrance
--     and walking off.
--   * Patron flow (economy_spec 6.3/6.4): every casino has its own arrival
--     rate = min(DEMAND, LOBBY) guests/min (Config.NPC flow keys). The
--     server-wide NPC cap (Config.NPC.MaxActive*) is split into visible shares
--     and one visible guest counts as W guests (the guest weight, from the
--     casino's measured visit time), so a casino earns its rate however full
--     the server is and however slowly the NPCs walk. The capacity counters
--     count passengers on their way (plus a small TransitAllowance, so machines
--     don't idle while they drive).
--   * Guests: wallet x the owner's Casino Rank clientele (Progression), a small
--     share of it per bet (so max bets matter), affordable / high-limit machine
--     choice, a stand stop, a Tip Jar tip on the way out; every payout to the
--     owner is x W (Gambling.npcPlay / npcSpend).
--   * Real player-looking avatars via Players:CreateHumanoidModelFromUserId
--     (falls back to a built rig if that call fails), built while their car is
--     still on its way.
--   * Animator + LoadAnimation on the default Roblox walk/idle so they animate
--     like real characters.
--   * SetNetworkOwner(nil) so the SERVER simulates movement.
--   * PathfindingService nav with per-waypoint MoveTo, stuck detection, repath.
--   * Collision group so NPCs don't shove players or each other.
--   * One patron per machine (reservation table).
--   * The tag over their head (wallet, VIP, suspect, BUSTED) is drawn by the
--     clients (CasinoClient/GuestTags) from attributes on the model (see initGuestTag).
--   * Cheaters (Cheaters.luau attaches itself, NPCs.attachCheaters): a share of the
--     guests cheat (bigger bets, no house tilt, more wins); the owner or Security can
--     throw any guest out (NPCs.eject).

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")
local CollectionService = game:GetService("CollectionService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local CityLayout = require(Common:WaitForChild("CityLayout"))

local NPCs = {}
local Gambling, Plots, Upgrades, Data, Economy, Traffic, Progression
local DayNight = require(script.Parent:WaitForChild("DayNight"))
local Buildings = require(script.Parent:WaitForChild("Buildings"))

local rng = Random.new()
local active = {}        -- npc -> true
local activeCount = 0    -- patrons in the world + passengers on their way (the server-wide cap)
local casinoActive = {}  -- plot record -> patrons visiting it + on their way there (its capacity)
local machineUsers = {}  -- machine -> npc   (one patron per machine)
local flow = {}          -- plot record -> its patron-flow state (see flowStateFor)

-- cheating guests: Cheaters.luau attaches itself (NPCs.attachCheaters) and hears when
-- guests come and go; every call is guarded, so guests never depend on it
local Cheaters = nil
local function cheaterCall(fnName: string, ...)
	local f = Cheaters and Cheaters[fnName]
	if type(f) ~= "function" then return nil end
	local ok, res = pcall(f, ...)
	if not ok then
		warn("[NPCs] Cheaters." .. fnName .. ": " .. tostring(res))
		return nil
	end
	return res
end

-- the owner's profile for a casino record (nil when the owner left)
local function ownerProfileOf(casino)
	if not (casino and casino.ownerId and Data) then return nil end
	local owner = Players:GetPlayerByUserId(casino.ownerId)
	return owner and Data.get(owner) or nil
end

local function ownerEffect(casino, key: string): number
	local profile = ownerProfileOf(casino)
	return (Upgrades and profile) and Upgrades.effect(profile, key) or 0
end

-- every upgrade effect the guests / the flow read, in one go (0 when not owned)
local EFFECT_KEYS = {
	"spawnBonus", "walletMult", "tiltBonus", "visitBonus", "patronSpeed", "concessionBonus",
	"capacityBonus", "speedBonus", "tipRate", "parkingBays", "vipChance", "betBonus",
	"nightBonus", "partyBonus", "vipWalletBonus",
}
local function ownerEffects(casino)
	local profile = ownerProfileOf(casino)
	local all = (Upgrades and profile and Upgrades.effects) and Upgrades.effects(profile) or nil
	local out = {}
	for _, key in EFFECT_KEYS do
		if all then
			out[key] = all[key] or 0
		else
			out[key] = (Upgrades and profile) and Upgrades.effect(profile, key) or 0
		end
	end
	return out
end

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
	local isVIP = rng:NextNumber() < (Config.NPC.VIPChance or 0) + ownerEffect(casino, "vipChance")
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
	-- a share of the other guests cheat (Cheaters: chance, rank, security, raids)
	local cheater = not isVIP and cheaterCall("rollCheater", casino) == true
	return { isVIP = isVIP, userId = userId, vipName = vipName, cheater = cheater }
end

------------------------------------------------------------------
-- avatar build (with a tiny block rig fallback)
------------------------------------------------------------------
local function applyCollisionGroup(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then d.CollisionGroup = Config.CollisionGroups.NPC end
	end
	-- (accessories load in after the avatar is built: they must not bump players either)
	model.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then d.CollisionGroup = Config.CollisionGroups.NPC end
	end)
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
-- the tag above the head: drawn by every client (CasinoClient/GuestTags) from
-- attributes on the guest's model, so the server sends a number, not a GUI:
--   Wallet (whole $)   WalletNote ("stand" | "tip": what the last change was)
--   GuestTier ("vip")  GuestName (a VIP's friend name)   CasinoOwner (userId)
--   Inside / Leaving   OnVipFloor (playing a VIP-floor machine: the x1.25 chip)
--   Cheaters.luau adds Suspect, Busted ("owner" | "security") and Kicked.
------------------------------------------------------------------
local function initGuestTag(model: Model, hum: Humanoid)
	-- no default Roblox name plate: the Showtime tag shows a VIP's name itself
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	-- the whole avatar streams in at once (the tag needs the head)
	pcall(function() model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic end)
	model:SetAttribute("Wallet", 0)
end

-- The avatar, set up but not yet in the world. Yields (the avatar call), so
-- passengers are built while their car is still on its way.
local function prepareAvatar(avatarUserId: number?, vipName: string?): Model?
	local model = loadAvatar(avatarUserId)
	model.Name = vipName or "CasinoNPC"
	local hum = model:FindFirstChildOfClass("Humanoid")
	local hrp = model:FindFirstChild("HumanoidRootPart")
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
	applyCollisionGroup(model)

	-- The avatar from CreateHumanoidModelFromUserId ships a default "Animate"
	-- LocalScript. It never runs on a server-owned NPC (LocalScripts only run in
	-- the local player's own character), so it does nothing but spam
	-- "failed to load animation" warnings on clients. Remove it and drive the
	-- animations ourselves from the server.
	local bundledAnimate = model:FindFirstChild("Animate")
	if bundledAnimate then bundledAnimate:Destroy() end
	return model
end

-- put a prepared avatar into the world, standing at `at` (ground level,
-- facing its look vector), and start driving its animations
local function placeNPC(model: Model, at: CFrame)
	local hum = model:FindFirstChildOfClass("Humanoid")
	local hrp = model:FindFirstChild("HumanoidRootPart") :: BasePart
	model:PivotTo(at + Vector3.new(0, 3, 0))
	initGuestTag(model, hum)

	-- clients hide patrons on the stories above them (BuildingView)
	CollectionService:AddTag(model, "CasinoPatron")
	model.Parent = Workspace

	if hrp:CanSetNetworkOwnership() then
		hrp:SetNetworkOwner(nil)
	end

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
		walkTrack = walkTrack, idleTrack = idleTrack,
		animConn = animConn,
		-- phase: nil (walking in) | "inside" | "leaving"; ejected = NPCs.eject's `how`;
		-- abortWalk cuts walks / waits short; leaveNow ends the visit (a cheater's loot is big enough)
	}
end

local function buildNPC(spawnPos: Vector3, avatarUserId: number?, vipName: string?)
	local model = prepareAvatar(avatarUserId, vipName)
	return model and placeNPC(model, CFrame.new(spawnPos)) or nil
end

------------------------------------------------------------------
-- a wait the guest cuts short when they're thrown out (NPCs.eject). (The
-- "+$X / -$X" pops are the clients' now: GuestTags, from the Wallet attribute.)
------------------------------------------------------------------
local function pause(npc, seconds: number)
	local untilT = os.clock() + seconds
	while not npc.abortWalk and npc.root.Parent do
		local left = untilT - os.clock()
		if left <= 0 then break end
		task.wait(math.min(0.25, left))
	end
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
	while root.Parent and os.clock() < stepDeadline and not npc.abortWalk do
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
	while root.Parent and os.clock() < deadline and attempts < 4 and not npc.abortWalk do
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
-- multi-story casinos: patrons ride the elevator (a short teleport between
-- the booths) to reach machines upstairs
------------------------------------------------------------------
local function goToStory(npc, casino, story: number?)
	story = story or 1
	local from = npc.story or 1
	if from == story then return end
	walkTo(npc, Buildings.elevatorExit(casino, from).Position)
	if npc.abortWalk then return end -- (thrown out on the way: they leave from here)
	task.wait(0.35)
	if not npc.root.Parent then return end
	npc.root.CFrame = Buildings.elevatorExit(casino, story)
	npc.story = story
	task.wait(0.35)
end

------------------------------------------------------------------
-- leaving: by car from the curb, or on foot (plots without a curb stop)
------------------------------------------------------------------
-- out the front door and a few steps toward the street, then gone. With a
-- curb stop (no car came) they walk off along the sidewalk instead: the
-- entrance sits on the walk 3.5 studs from the curb, so "toward the street"
-- would end in the travel lane (10 along keeps the path agent clear of the
-- porte-cochère's column bases at +-15.5)
local function walkAway(npc, casino, bay)
	local leaveTarget = (casino.entrance or Plots.PlazaCenter) + Vector3.new(0, 0, 14)
	if bay then
		leaveTarget = bay.stop + bay.heading * 10 + bay.curbDir * 7.5 + Vector3.new(0, CityLayout.Y.Walk, 0)
	elseif casino.entrance and casino.base then
		-- away from the building, toward the street
		local out = casino.entrance - casino.base.Position
		out = Vector3.new(out.X, 0, out.Z)
		if out.Magnitude > 0.1 then leaveTarget = casino.entrance + out.Unit * 14 end
	end
	walkTo(npc, leaveTarget)
	task.wait(0.4)
end

local curbTurn = {} -- bay id -> the next waiting spot

-- a spot on the sidewalk by the curb stop, facing the road (the bay's stop
-- is in the curb lane; the sidewalk starts 4.5 studs further out)
local function curbSpot(bay): CFrame
	local i = (curbTurn[bay.id] or 0) % 7
	curbTurn[bay.id] = i + 1
	local p = bay.stop + bay.heading * ((i - 3) * 2.6) + bay.curbDir * 7.5 + Vector3.new(0, CityLayout.Y.Walk, 0)
	return CFrame.lookAt(p, p - bay.curbDir)
end

-- wait at the curb for a ride, step to its door and get in. False when no
-- car came (the patron then walks off instead).
local function rideHome(npc, casino, bay): boolean
	local spot = curbSpot(bay)
	walkTo(npc, spot.Position)
	local root = npc.root
	if not root.Parent then return true end
	root.CFrame = CFrame.lookAt(root.Position, root.Position + spot.LookVector) -- watching the road

	local doors, info
	local deadline = os.clock() + (Config.NPC.CurbWaitMax or 80)
	local ride
	while root.Parent and not ride and os.clock() < deadline do
		local why
		ride, why = Traffic.requestPickup(casino, function(spots, i)
			doors, info = spots, i
		end)
		if why == "nobay" then return false end
		if not ride then task.wait(rng:NextNumber(2.5, 4)) end -- the roads are full: try again shortly
	end
	if not ride then return false end
	-- a car due at one of the extra valet stops: wait beside that one instead
	if ride.curb and flatDist(root.Position, ride.curb.Position) > 3 then
		walkTo(npc, ride.curb.Position)
		if not root.Parent then return true end
		root.CFrame = CFrame.lookAt(root.Position, root.Position + ride.curb.LookVector)
	end
	-- (a little slack past its arrival, in case the server hitches)
	local giveUp = os.clock() + math.max(0, ride.arriveAt - Workspace:GetServerTimeNow()) + 10
	while root.Parent and not doors and os.clock() < giveUp do task.wait(0.2) end
	if not (doors and root.Parent) then return false end

	-- step to the door and in before it pulls away
	local door = doors[info.seat or 1] or doors[1]
	npc.hum:MoveTo(door.Position)
	local leaveBy = info.departAt - 0.35
	while root.Parent and Workspace:GetServerTimeNow() < leaveBy and flatDist(root.Position, door.Position) > 1.5 do
		task.wait(0.1)
	end
	return true
end

------------------------------------------------------------------
-- patron flow state (economy_spec 6.3 / 6.4), per casino
------------------------------------------------------------------
local function flowStateFor(casino)
	local st = flow[casino]
	if not st or st.ownerId ~= casino.ownerId then
		st = {
			ownerId = casino.ownerId,
			credit = 0,              -- visible guests owed (they arrive when a whole party is due)
			party = nil,             -- the size of the next party (rolled when due)
			weight = 1,              -- W: the guests one visible guest stands for
			wAt = -math.huge,        -- when W was last recomputed
			holdEMA = nil,           -- measured visit seconds (car dispatched -> out of the casino)
			nominal = 45,            -- nominal visit seconds (the flow model's estimate)
			rate = 0, demand = 0, lobby = 0, want = 0, visible = 0, visibleEff = 0,
			bottleneck = "DEMAND",
			retryAt = 0,             -- the roads were jammed: next dispatch not before this
			-- fill correction: guests the visible flow had to turn away (no visible
			-- room / server cap / jammed roads), x W; paid out as extra weight on the
			-- next guests who do come, so the casino still earns its full rate
			debt = 0,
		}
		flow[casino] = st
	end
	return st
end

-- a guest walked out: their visit (car dispatched -> left the casino) trains the
-- casino's measured visit time, which sets the guest weight
local function noteVisit(casino, seconds: number)
	local st = flow[casino]
	if not (st and st.ownerId == casino.ownerId) then return end
	local hold = st.holdEMA or st.nominal
	st.holdEMA = hold + (Config.NPC.HoldEMAAlpha or 0.1) * (math.clamp(seconds, 5, 900) - hold)
end

------------------------------------------------------------------
-- one patron's visit
------------------------------------------------------------------
-- weight: how many guests this one visible guest stands for (every payout to the
-- owner is x weight; the guest's own wallet, bets and pop-text are unchanged)
local function runPatron(npc, casino, spec, bay, weight)
	local cfg = Config.NPC
	weight = weight or 1
	local eff = ownerEffects(casino)
	local clientele = (Progression and casino and casino.ownerId) and Progression.clientele(casino.ownerId) or 1
	local concessionMult = 1 + eff.concessionBonus
	local thinkScale = math.max(0.4, 1 - eff.speedBonus)
	local patronTilt = (cfg.ExtraLossChance or 0) + eff.tiltBonus
	-- Moving Walkways: faster feet (the walk animation follows, see placeNPC) and extra rounds
	local walkBonus = eff.patronSpeed
	local extraRounds = math.floor((cfg.WalkwayRounds or 5) * walkBonus + 0.5)
	npc.hum.WalkSpeed = cfg.WalkSpeed * (1 + walkBonus)
	npc.story = 1

	-- VIP status was decided at spawn (a VIP is one of the owner's real friends)
	local isVIP = spec and spec.isVIP or false
	local vipMult = isVIP and (cfg.VIPWalletMultiplier or 5) * (1 + eff.vipWalletBonus) or 1
	local betFracMin = (isVIP and cfg.VIPBetFractionMin or cfg.BetFractionMin) + eff.betBonus
	local betFracMax = (isVIP and cfg.VIPBetFractionMax or cfg.BetFractionMax) + eff.betBonus
	-- every guest checks in with Cheaters (anyone can be kicked out); a cheater gets the
	-- profile they play with: big bets, no house tilt, their own (unhurried) pace
	local cheat = cheaterCall("guestEntered", npc, casino, spec, weight)
	if cheat then
		betFracMin = cheat.betMin + eff.betBonus
		betFracMax = cheat.betMax + eff.betBonus
	end

	-- the owner's Casino Rank (clientele) and High Rollers make guests richer
	local wallet = math.floor(rng:NextInteger(cfg.WalletMin, cfg.WalletMax) * clientele * (1 + eff.walletMult) * vipMult)
	local wagered = 0          -- everything they bet (the Tip Jar's share)
	local lastMachine = nil    -- the last machine they played (the tip's "+$" pops there)
	-- the tag over their head is the clients' (GuestTags): the server sets attributes
	local model = npc.model
	local walletNote = nil
	local function setWallet(v, note: string?)
		wallet = math.max(0, v)
		if note ~= walletNote then
			walletNote = note
			model:SetAttribute("WalletNote", note)  -- ("stand" / "tip": how the client pops it)
		end
		model:SetAttribute("Wallet", math.floor(wallet))
	end
	model:SetAttribute("CasinoOwner", casino and casino.ownerId or nil)
	if isVIP then
		model:SetAttribute("GuestTier", "vip")
		if spec.vipName and cfg.VIPShowFriendName then model:SetAttribute("GuestName", spec.vipName) end
	end
	setWallet(wallet)

	local heldMachine: Instance? = nil
	local function release()
		if heldMachine and machineUsers[heldMachine] == npc then
			machineUsers[heldMachine] = nil
		end
		heldMachine = nil
		model:SetAttribute("OnVipFloor", nil)
	end
	-- the patron holds one of the casino's places until they walk out of it
	local inside = true
	local function leaveCasino()
		if inside then
			inside = false
			casinoActive[casino] = math.max(0, (casinoActive[casino] or 1) - 1)
			if spec and spec.heldAt then noteVisit(casino, os.clock() - spec.heldAt) end
		end
	end
	local function cleanup()
		release()
		leaveCasino()
		cheaterCall("guestLeft", npc)
		active[npc] = nil
		activeCount -= 1
		if npc.animConn then npc.animConn:Disconnect(); npc.animConn = nil end
		if npc.model.Parent then npc.model:Destroy() end
	end

	local function visit()
		if not casino or #casino.machines == 0 then return end
		-- inside: from here on the owner (or Security) can throw them out
		npc.phase = "inside"
		model:SetAttribute("Inside", true)

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

		-- a stand on arrival: more kinds of stands -> more guests stop by; the
		-- better a stand sells, the likelier they pick it
		if #concessions > 0 then
			local kinds, nKinds, totalRev = {}, 0, 0
			for _, c in concessions do
				local kind = c:GetAttribute("GameType") or c.Name
				if not kinds[kind] then kinds[kind] = true; nKinds += 1 end
				totalRev += math.max(0, c:GetAttribute("RevenuePerVisit") or 0)
			end
			local chance = math.min(cfg.ConcessionVisitMax or 0.9,
				(cfg.ConcessionVisitBase or 0.35) + (cfg.ConcessionVisitPerType or 0.15) * nKinds)
			if rng:NextNumber() < chance then
				local c = concessions[rng:NextInteger(1, #concessions)]
				if totalRev > 0 then
					local pick = rng:NextNumber() * totalRev
					for _, s in concessions do
						pick -= math.max(0, s:GetAttribute("RevenuePerVisit") or 0)
						if pick <= 0 then c = s; break end
					end
				end
				local cp = c.PrimaryPart
				if cp then
					goToStory(npc, casino, c:GetAttribute("Story"))
					-- code-built models say how far their front edge sits from the PrimaryPart
					local reach = c:GetAttribute("ApproachDistance") or 3
					walkTo(npc, cp.Position + cp.CFrame.LookVector * (reach + 3))
					walkTo(npc, cp.Position + cp.CFrame.LookVector * reach)
					local rp = npc.root.Position
					npc.root.CFrame = CFrame.lookAt(rp, Vector3.new(cp.Position.X, rp.Y, cp.Position.Z))
					local revenue = math.floor((c:GetAttribute("RevenuePerVisit") or 0) * clientele * concessionMult)
					if isVIP then revenue = math.floor(revenue * (cfg.ConcessionVIPMultiplier or 1)) end
					revenue = math.min(revenue, wallet)
					if revenue > 0 and c.Parent and not npc.ejected then
						setWallet(wallet - revenue, "stand")
						-- the owner gets it x W x the earnings multiplier (+ TotalEarned, "+$" pop)
						Gambling.npcSpend(casino.ownerId, c, revenue, weight)
					end
					pause(npc, rng:NextNumber(0.5, 1.0))
				end
			end
		end

		local visits = rng:NextInteger(cfg.MachinesPerVisitMin, cfg.MachinesPerVisitMax + eff.visitBonus)
		if cheat then visits = math.max(visits, cheat.machines) end -- (a cheater works the floor)
		local candidates, weights = {}, {}
		for _ = 1, visits do
			if wallet < 10 or #gambleMachines == 0 or npc.ejected or npc.leaveNow then break end
			-- only machines whose minimum bet they can afford; none left: done for today
			local affordable = {}
			for _, m in gambleMachines do
				if m.Parent and (m:GetAttribute("MinBet") or 5) <= wallet then table.insert(affordable, m) end
			end
			if #affordable == 0 then break end

			-- busy casino (the night rush lets in more patrons than machines):
			-- hang around up to ~8 s for a free machine before giving up a round
			local waitUntil = os.clock() + 8
			repeat
				table.clear(candidates)
				for _, m in affordable do
					if m.Parent and not machineUsers[m] then table.insert(candidates, m) end
				end
				if #candidates == 0 then pause(npc, rng:NextNumber(0.8, 1.4)) end
			until #candidates > 0 or os.clock() > waitUntil or not npc.root.Parent or npc.ejected
			if #candidates == 0 or npc.ejected then continue end
			-- rich guests prefer high-limit tables: each machine weighs the bet the
			-- guest would like to place there (its max bet caps it)
			local wish = wallet * (betFracMin + betFracMax) / 2
			local total = 0
			table.clear(weights)
			for i, m in candidates do
				weights[i] = math.max(1, math.min(m:GetAttribute("MaxBet") or 100, wish))
				total += weights[i]
			end
			local machine = candidates[#candidates]
			local pick = rng:NextNumber() * total
			for i, m in candidates do
				pick -= weights[i]
				if pick <= 0 then machine = m; break end
			end
			local mp = machine.PrimaryPart
			if not mp then continue end

			machineUsers[machine] = npc
			heldMachine = machine
			-- (the tag's x1.25 chip while they play on the VIP floor)
			model:SetAttribute("OnVipFloor", machine:GetAttribute("VipFloor") == true or nil)
			goToStory(npc, casino, machine:GetAttribute("Story"))
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
			local maxBet = math.max(minBet, machine:GetAttribute("MaxBet") or 100)
			local speedLvl = machine:GetAttribute("SpeedLevel") or 0
			local luckyLvl = machine:GetAttribute("LuckyLevel") or 0
			-- + the machine's rebirth perks (PerkSpeed / PerkTilt attributes, Placement.buildMachine)
			local perkSpeed = tonumber(machine:GetAttribute("PerkSpeed")) or 0
			local perkTilt = tonumber(machine:GetAttribute("PerkTilt")) or 0
			local speedScale = math.max(0.2, (1 - speedLvl * (Config.MachineUpgrades.speed.perLevel)) * (1 - perkSpeed))
			local machineTilt = math.min(0.85, patronTilt + luckyLvl * (Config.MachineUpgrades.lucky.perLevel) + perkTilt)
			local rounds = rng:NextInteger(cfg.RoundsPerMachineMin, cfg.RoundsPerMachineMax + extraRounds)
			if cheat then rounds += cheat.extraRounds end

			for _ = 1, rounds do
				if wallet < minBet or not machine.Parent or npc.ejected or npc.leaveNow then break end
				local frac = rng:NextNumber(betFracMin, betFracMax)
				local bet = math.clamp(math.floor(wallet * frac), minBet, maxBet)
				local res = Gambling.npcPlay(machine, bet, choiceFor(gameType), machineTilt, weight, cheat)
				if res then
					wagered += res.bet or bet
					lastMachine = machine
					setWallet(wallet + res.npcNet)
					if cheat then cheaterCall("cheaterRound", npc, machine, res, wallet) end
				end
				-- (a cheater takes their time: speed upgrades don't hurry them)
				pause(npc, cheat and rng:NextNumber(cheat.thinkMin, cheat.thinkMax)
					or rng:NextNumber(cfg.ThinkDelayMin, cfg.ThinkDelayMax) * speedScale * thinkScale)
			end
			release()
		end
	end

	-- Tip Jar: on the way out, a share of everything they bet (at most what's left)
	local function tip()
		local tipRate = eff.tipRate
		if tipRate <= 0 or wagered <= 0 or wallet <= 0 then return end
		local amount = math.min(wallet, math.floor(wagered * tipRate))
		if amount <= 0 then return end
		setWallet(wallet - amount, "tip")
		Gambling.npcSpend(casino.ownerId, lastMachine, amount, weight)
	end

	local ok, err = pcall(function()
		-- off the road and onto the walk by the front door: straight steps (the
		-- entrance is ~5 studs from the car door, nothing solid in between), so
		-- it never hangs on whether the navmesh links road and curb. A car at
		-- one of the extra valet stops halts up to 30 studs further back: first
		-- along the curb to the door (clear of the pylon and the columns)
		if bay and casino.entrance then
			moveStep(npc, bay.stop + bay.curbDir * 3.4, os.clock() + 5)
			moveStep(npc, casino.entrance, os.clock() + 5)
		end
		visit()
		-- done (or thrown out): back down to the ground floor and out (room for the next guest)
		npc.abortWalk = nil
		npc.phase = "leaving"
		model:SetAttribute("Inside", nil)
		model:SetAttribute("Leaving", true)
		cheaterCall("guestLeaving", npc)
		local out = npc.ejected
		if out then
			-- thrown out: stand still a moment (Security walks over), then off at their pace, on foot
			local hold = (tonumber(out.at) or 0) + (tonumber(out.delay) or 0) - os.clock()
			if hold > 0 then task.wait(hold) end
			npc.hum.WalkSpeed = tonumber(out.speed) or npc.hum.WalkSpeed
		end
		goToStory(npc, casino, 1)
		leaveCasino()
		if not (out or cheat) then tip() end -- (cheaters don't tip)
		if out or not (bay and Traffic and rideHome(npc, casino, bay)) then
			walkAway(npc, casino, bay)
		end
	end)
	if not ok then warn("[NPCs] patron error: " .. tostring(err)) end
	cleanup()
end

-- How many patrons a casino holds at once: one per gambling machine (or a few
-- for a concession-only casino), raised by the Bigger Lobby upgrade and by the
-- night rush (+50%, more with the Night Life upgrade). Above one per machine,
-- patrons wait their turn.
local function capacityOf(gamble: number, conc: number, eff): number
	local usable = gamble > 0 and gamble or math.min(conc, 3)
	if usable == 0 then return 0 end
	local mult = DayNight.customerMultiplier(eff.nightBonus) * (1 + eff.capacityBonus)
	return math.max(1, math.floor(usable * mult + 0.5))
end

-- the server-wide patron cap: grows with the open casinos, x the night rush
local function maxActive(casinos: number): number
	local cfg = Config.NPC
	local base = math.clamp((cfg.MaxActiveBase or 10) + (cfg.MaxActivePerCasino or 4) * casinos,
		cfg.MaxActiveMin or 30, cfg.MaxActiveMax or 60)
	return math.min(math.floor(base * DayNight.customerMultiplier()), cfg.MaxActiveHardCap or 80)
end

-- the visit a guest of this casino takes on paper (fitted to the economy sim):
-- car + walking (/ Moving Walkways) + rounds x think delay
local function nominalHold(eff, gamble): number
	local cfg = Config.NPC
	local nh = cfg.NominalHold or { car = 23, base = 6, perMachine = 6.5, upstairs = 26 }
	local m = (cfg.MachinesPerVisitMin + cfg.MachinesPerVisitMax + eff.visitBonus) / 2
	local rounds = m * (cfg.RoundsPerMachineMin + cfg.RoundsPerMachineMax
		+ math.floor((cfg.WalkwayRounds or 5) * eff.patronSpeed + 0.5)) / 2
	local up, speedSum = 0, 0
	for _, machine in gamble do
		if (machine:GetAttribute("Story") or 1) > 1 then up += 1 end
		speedSum += math.max(0.2, (1 - (machine:GetAttribute("SpeedLevel") or 0) * Config.MachineUpgrades.speed.perLevel)
			* (1 - (tonumber(machine:GetAttribute("PerkSpeed")) or 0)))
	end
	local n = #gamble
	local upShare = n > 0 and up / n or 0
	local speedScale = n > 0 and speedSum / n or 1
	local think = (cfg.ThinkDelayMin + cfg.ThinkDelayMax) / 2 * math.max(0.4, 1 - eff.speedBonus)
	return nh.car + (nh.base + nh.perMachine * (m - 1) + nh.upstairs * upShare) / (1 + eff.patronSpeed)
		+ rounds * think * speedScale
end

------------------------------------------------------------------
-- arrivals
------------------------------------------------------------------
-- passengers on their way already count against the caps
local function hold(casino, n: number)
	activeCount += n
	casinoActive[casino] = (casinoActive[casino] or 0) + n
end
local function unhold(casino, n: number)
	activeCount -= n
	casinoActive[casino] = math.max(0, (casinoActive[casino] or n) - n)
end

-- a party comes by car: it pulls into the casino's curb stop, they step out
-- one after another and walk in. Their avatars load while the car drives.
-- onBusy(party): the roads were jammed and the car never left (the flow loop
-- gets those guests back and tries again shortly).
local function arriveByCar(casino, bay, party: number, weight: number, onBusy)
	hold(casino, party)
	local heldAt = os.clock()
	task.spawn(function()
		local ownerId = casino.ownerId
		local specs, vip = {}, false
		for i = 1, party do
			specs[i] = rollPatronSpec(casino)
			specs[i].heldAt = heldAt
			vip = vip or specs[i].isVIP
		end
		local seats = {} -- per passenger: { model = Model | false (failed) | nil (loading), abandoned }
		for i = 1, party do seats[i] = {} end

		local function stepOut(i: number, spot: CFrame)
			local seat, spec = seats[i], specs[i]
			local waitUntil = os.clock() + 8
			while seat.model == nil and os.clock() < waitUntil do task.wait(0.1) end
			local stillOpen = casino.ownerId == ownerId and #casino.machines > 0
			local placed, npc = false, nil
			if seat.model and stillOpen then
				placed, npc = pcall(placeNPC, seat.model, spot)
			end
			if not (placed and npc) then
				-- (the casino closed while they drove in, or the avatar never loaded)
				seat.abandoned = true
				if seat.model then seat.model:Destroy() end
				unhold(casino, 1)
				return
			end
			active[npc] = true
			runPatron(npc, casino, spec, bay, weight)
		end

		-- VIPs ride a limo (Party Shuttles parties of 5+ a van; past 8 seats Traffic
		-- splits the party over several cars and calls back once per car with the
		-- party indices in it: info.passengers, spots keyed by those indices)
		local ok, handle = pcall(Traffic.requestDropoff, casino, party, function(spots, info)
			local seated = info and info.passengers
			if seated then
				for j, i in seated do
					task.delay((j - 1) * 0.35, stepOut, i, spots[i] or spots[seated[1]])
				end
			else
				for i = 1, party do
					task.delay((i - 1) * 0.35, stepOut, i, spots[i] or spots[1])
				end
			end
		end, { kind = vip and "limo" or nil, vip = vip })
		if not (ok and handle) then
			unhold(casino, party) -- the roads are jammed: they'll come another time
			if onBusy then onBusy(party) end
			return
		end
		for i = 1, party do
			task.spawn(function()
				local spec = specs[i]
				local model = prepareAvatar(spec.userId, spec.isVIP and spec.vipName or nil)
				if seats[i].abandoned then
					if model then model:Destroy() end
				else
					seats[i].model = model or false
				end
			end)
		end
	end)
end

-- no curb stop here (no traffic / an older map): they appear at the entrance
local function arriveOnFoot(casino, party: number, weight: number)
	hold(casino, party)
	local heldAt = os.clock()
	local ownerId = casino.ownerId
	for _ = 1, party do
		task.spawn(function()
			local spec = rollPatronSpec(casino)
			spec.heldAt = heldAt
			local npc = buildNPC(casino.entrance or Plots.PlazaCenter, spec.userId, spec.isVIP and spec.vipName or nil)
			if npc and not (casino.ownerId == ownerId and #casino.machines > 0) then
				if npc.animConn then npc.animConn:Disconnect() end
				npc.model:Destroy()
				npc = nil
			end
			if not npc then
				unhold(casino, 1)
				return
			end
			active[npc] = true
			runPatron(npc, casino, spec, nil, weight)
		end)
	end
end

------------------------------------------------------------------
-- the flow loop: every casino's guests/min, visible share, guest weight, arrivals
------------------------------------------------------------------
local function round(x: number, places: number): number
	local k = 10 ^ places
	return math.floor(x * k + 0.5) / k
end

-- the casino's numbers on its plot model (live readout / Studio debugging)
local function publishFlow(casino, st)
	local model = casino.model
	if not model then return end
	model:SetAttribute("FlowRate", st and round(st.rate, 1) or nil)
	model:SetAttribute("FlowDemand", st and round(st.demand, 1) or nil)
	model:SetAttribute("FlowLobby", st and round(st.lobby, 1) or nil)
	model:SetAttribute("FlowWeight", st and round(st.weight, 2) or nil)
	model:SetAttribute("FlowBottleneck", st and st.bottleneck or nil)
	model:SetAttribute("FlowHold", st and round(st.holdEMA or st.nominal, 1) or nil)
end

-- Erlang B: the share of guests who find all `c` places taken at offered load `a`
local function erlangB(c: number, a: number): number
	if a <= 0 then return 0 end
	local b = 1
	for k = 1, math.max(0, math.floor(c)) do
		b = a * b / (k + a * b)
	end
	return b
end

local function partyRange(capNow: number, eff): (number, number)
	local cfg = Config.NPC
	local most = (cfg.PartyMax or 4) + math.floor(eff.partyBonus + 0.5)
	local least = math.clamp(math.floor(capNow / (cfg.PartyPerCapacity or 8)), cfg.PartyMin or 1, most)
	return least, most
end

local function flowTick(dt: number)
	local cfg = Config.NPC
	local now = os.clock()
	local casinos = Plots.getOwnedPlotsWithMachines()
	local cap = maxActive(#casinos)
	local open = {}
	local inCasinos = 0
	for _, n in casinoActive do inCasinos += n end

	-- 1) every casino's demand, lobby and rate (guests/min)
	for _, c in casinos do
		local st = flowStateFor(c)
		local eff = ownerEffects(c)
		local gamble, conc = {}, 0
		for _, m in c.machines do
			if m.Parent then
				if m:GetAttribute("Kind") == "concession" then conc += 1 else table.insert(gamble, m) end
			end
		end
		local capNow = capacityOf(#gamble, conc, eff)
		st.eff, st.capNow = eff, capNow
		if capNow > 0 then
			local transit = (cfg.TransitAllowance or 0) + (cfg.ParkingTransitPerStop or 0) * eff.parkingBays
			st.want = capNow + math.max(1, math.floor(capNow * transit + 0.5))   -- guests on the way + inside
			st.demand = ((cfg.ArrivalBase or 2) + (cfg.ArrivalPerMachine or 0.9) * #gamble)
				* (1 + eff.spawnBonus) * DayNight.customerMultiplier(eff.nightBonus)
				* (1 + (cfg.ParkingDemandPerStop or 0) * eff.parkingBays)
				* (1 + (cfg.PartyDemandPerSeat or 0) * eff.partyBonus)
			st.nominal = nominalHold(eff, gamble)
			st.holdEMA = st.holdEMA or st.nominal
			st.lobby = st.want * 60 / st.nominal                                   -- guests/min the lobby can cycle
			if cfg.LobbyLoss then
				-- (optional) the economy simulator's model: guests who'd find the lobby full stay away
				st.rate = st.demand * (1 - erlangB(st.want, st.demand * st.nominal / 60))
			else
				st.rate = math.min(st.demand, st.lobby)                            -- economy_spec 6.3
			end
			st.bottleneck = st.demand <= st.lobby and "DEMAND" or "LOBBY"
			st.bay = Traffic and Traffic.bayFor(c) or nil
			table.insert(open, { c = c, st = st })
		else
			st.rate, st.want, st.visible, st.visibleEff = 0, 0, 0, 0
		end
	end

	-- 2) split the server-wide cap into visible shares: each casino first gets a
	--    few (MinVisiblePerCasino), the rest goes by size. Guests already on their
	--    way home still hold their server slots.
	local pool = math.max(0, cap - math.max(0, activeCount - inCasinos))
	local floorSum, roomSum = 0, 0
	for _, e in open do
		e.st.visible = math.min(e.st.want, cfg.MinVisiblePerCasino or 4)
		floorSum += e.st.visible
		roomSum += e.st.want - e.st.visible
	end
	if floorSum > pool then
		for _, e in open do e.st.visible *= pool / floorSum end
	elseif roomSum > 0 then
		local share = math.min(1, (pool - floorSum) / roomSum)
		for _, e in open do e.st.visible += (e.st.want - e.st.visible) * share end
	end

	-- 3) guest weight and arrivals
	local wMax = cfg.GuestWeightMax or 250
	for _, e in open do
		local c, st = e.c, e.st
		local least, most = partyRange(st.capNow, st.eff)
		-- the curb unloads only so many visible guests a minute (its stops, car
		-- lengths and party sizes: Traffic); above CurbUse of that, W takes over
		local visible = st.visible
		if st.bay and Traffic and Traffic.curbCapacityPerMinute then
			local perMin = Traffic.curbCapacityPerMinute(c, (least + most) / 2) * (cfg.CurbUse or 0.8)
			if perMin > 0 then visible = math.min(visible, perMin * st.holdEMA / 60) end
		end
		st.visibleEff = visible
		if now - st.wAt >= (cfg.WeightRecompute or 5) then
			st.wAt = now
			local w = math.clamp(st.rate * st.holdEMA / (60 * math.max(visible, 1e-3)), 1, wMax)
			st.credit *= st.weight / w        -- (guests owed keep their worth when W changes)
			st.weight = w
			publishFlow(c, st)
		end
		-- visible guests arrive at rate / W (each counts W times). A casino owed more
		-- than 2 full cars turns the rest away: they (x W) become debt, at most
		-- FillDebtMinutes of its rate
		local creditCap = 2 * most
		local debtCap = st.rate * (cfg.FillDebtMinutes or 2)
		local function addCredit(n: number, w: number)
			st.credit += n
			if st.credit > creditCap then
				st.debt = math.min(st.debt + (st.credit - creditCap) * w, debtCap)
				st.credit = creditCap
			end
		end
		addCredit(st.rate / st.weight / 60 * dt, st.weight)
		st.party = st.party or rng:NextInteger(least, most)
		if st.credit >= st.party and now >= st.retryAt then
			local room = math.min(math.floor(visible + 1e-6) - (casinoActive[c] or 0), cap - activeCount)
			if room >= 1 then
				local party = math.min(st.party, room)
				local w = st.weight
				-- pay off debt: up to (FillBoostMax - 1) x W more per guest (never past GuestWeightMax)
				local extra = math.clamp(st.debt, 0, party * math.max(0, math.min(w * ((cfg.FillBoostMax or 2) - 1), wMax - w)))
				st.debt -= extra
				local pay = w + extra / party
				st.credit -= party
				st.party = nil
				if st.bay then
					arriveByCar(c, st.bay, party, pay, function(n)
						addCredit(n * w / st.weight, st.weight)   -- (the roads were jammed: they come a bit later)
						st.debt = math.min(st.debt + extra, debtCap)
						st.retryAt = os.clock() + 2
					end)
				else
					arriveOnFoot(c, party, pay)
				end
			end
		end
	end

	-- 4) forget casinos that closed (their guests finish on their own)
	for c, st in flow do
		if c.ownerId ~= st.ownerId or #c.machines == 0 then
			flow[c] = nil
			publishFlow(c, nil)
		end
	end
end

-- the snapshot's `flow` (ManageUI readout): nil until the casino's first tick
function NPCs.flowFor(ownerId: number)
	for c, st in flow do
		if st.ownerId == ownerId and c.ownerId == ownerId then
			return {
				rate = round(st.rate, 1), demand = round(st.demand, 1), lobby = round(st.lobby, 1),
				weight = round(st.weight, 2),   -- W: the guests one visible guest counts for
				bottleneck = st.bottleneck,
				hold = round(st.holdEMA or st.nominal, 1), nominalHold = round(st.nominal, 1),
				visible = round(st.visibleEff, 1), inside = casinoActive[c] or 0,
				debt = round(st.debt, 1),
			}
		end
	end
	return nil
end

-- Cheaters.luau plugs in here (its start): rollCheater / guestEntered / cheaterRound /
-- guestLeaving / guestLeft are then called through cheaterCall (guarded)
function NPCs.attachCheaters(mod)
	Cheaters = type(mod) == "table" and mod or nil
end

-- throw a guest out (Cheaters: a KICK OUT or Security). npc = the record Cheaters got in
-- guestEntered; how = { by, cheater, at (os.clock()), speed (studs/s on the way out),
-- delay (seconds they stand still first) }. They stop where they are, drop the visit
-- and leave on foot. False when they aren't inside a casino any more.
function NPCs.eject(npc, how): boolean
	if type(npc) ~= "table" or not (npc.model and npc.model.Parent) then return false end
	if npc.ejected or npc.phase ~= "inside" then return false end
	npc.ejected = type(how) == "table" and how or {}
	npc.abortWalk = true
	pcall(function() npc.hum:MoveTo(npc.root.Position) end) -- stop right there
	return true
end

function NPCs.start(deps)
	Gambling = deps.Gambling
	Plots = deps.Plots
	Upgrades = deps.Upgrades
	Data = deps.Data
	Economy = deps.Economy
	Traffic = deps.Traffic
	Progression = deps.Progression

	task.spawn(function()
		local last = os.clock()
		while true do
			task.wait(Config.NPC.SpawnTick or 0.5)
			local now = os.clock()
			local dt = math.min(now - last, 2)
			last = now
			local ok, err = pcall(flowTick, dt)
			if not ok then warn("[NPCs] flow: " .. tostring(err)) end
		end
	end)
end

return NPCs
