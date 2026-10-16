--!nonstrict
-- Cheaters.luau — cheating guests (Config.Cheaters; the GUESTS package).
--   * who cheats: NPCs.rollPatronSpec asks Cheaters.rollCheater(casino) for every
--     arriving guest who isn't a VIP: Config.Cheaters.Chance from Casino Rank MinRank
--     on (x SecurityChanceMult with Security hired, x the CHEATER RAID event), one per
--     MinGapSeconds per casino, at most MaxPerCasino inside at once.
--   * the visit: NPCs tells us when a guest walks in (guestEntered: every guest is
--     registered, a cheater gets the cheat profile NPCs.runPatron and Gambling.npcPlay
--     play with), after each cheater round (cheaterRound: what they took, the tells),
--     when they head out (guestLeaving) and when they're gone (guestLeft). A cheater
--     who took MaxTakeMinutes of the owner's income leaves with it ("got away").
--   * tells: the model attribute Suspect (the client's GuestTags draws a red "?") and
--     ONE CheaterAlert to the owner ({ kind = "suspect", npc, machine, name, story });
--     { kind = "escaped", amount, name } when one walks off with the owner's money.
--   * KICK OUT: remote KickGuest(npcModel) -> Cheaters.kick (owner only, a guest inside
--     their casino, within KickServerDistance). A cheater: Busted = "owner", runs out,
--     the owner gets max(KickReturn x what they took, KickMinMinutes of income,
--     KickMinCash x clientele) + bonus XP; an honest guest: Kicked = true, walks off.
--   * security: a 0.5 s loop; Security level L catches a cheater CatchSeconds[L] after
--     their first round (Busted = "security", stands still EscortDelay seconds while the
--     client's guard walks over, then is led out; SecurityReturn x the take).
--   * GuestKicked -> every client { npc, by, cheater, reward, xp, take, raid, ownerId, pos };
--     GameEvents cheaterKicked / cheaterCaught / honestKicked; profile.CheaterStats.
--   * the CHEATER RAID event (Events.isActive("cheaterRaid"); Events.value("cheaterMult")
--     / ("kickMult") when Events has them, else Config.Cheaters.Raid*): more cheaters,
--     double rewards. Events may be missing: every call is guarded.
-- API: Cheaters.isCheater(model), Cheaters.kick(player, model), Cheaters.activeIn(ownerId).
-- init.server: start(deps), leave(player), snapshot(player, profile) (key `cheaters`).
-- Studio test: ServerStorage attribute CasinoTestCheaters = true (any rank, a cheater every 20 s).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))

local Cheaters = {}
local CC = Config.Cheaters or {}
local NPCs, Staff, Data, Economy, Progression, Remotes, GameEvents, Events, pushData

local rng = Random.new()
local guests = {}        -- npc model -> rec (every guest inside a casino right now)
local casinoState = {}   -- ownerId -> { lastRollAt = os.clock() of the last cheater rolled }
local lastKick = {}      -- userId -> os.clock() of their last KICK OUT
local started = false

------------------------------------------------------------------
-- small helpers
------------------------------------------------------------------
local function num(v: any, default: number): number
	local n = tonumber(v)
	if n == nil or n ~= n then return default end
	return n
end

-- the value of a per-level list (levels past the end count as the last)
local function perLevel(list: any, level: number, default: number): number
	if type(list) ~= "table" or #list == 0 or level <= 0 then return default end
	return num(list[math.min(level, #list)], default)
end

local function ownerOf(ownerId: number?): Player?
	return ownerId and Players:GetPlayerByUserId(ownerId) or nil
end

local function profileOf(player: Player?)
	return (player and Data) and Data.get(player) or nil
end

local function securityLevel(profile): number
	if not (Staff and profile and type(Staff.level) == "function") then return 0 end
	local ok, lvl = pcall(Staff.level, profile, "security")
	return ok and math.max(0, math.floor(num(lvl, 0))) or 0
end

local function rankOf(profile): number
	if not (Progression and profile) then return 1 end
	local ok, r = pcall(Progression.rank, profile)
	return ok and num(r, 1) or 1
end

local function gameEvent(player: Player?, name: string, amount: number?)
	if GameEvents and player then pcall(GameEvents.emit, player, name, amount) end
end

------------------------------------------------------------------
-- the CHEATER RAID event (Events.luau may not exist: every call guarded)
------------------------------------------------------------------
local function raidActive(): boolean
	if not (Events and type(Events.isActive) == "function") then return false end
	local ok, on = pcall(Events.isActive, "cheaterRaid")
	return ok and on == true
end

-- a raid's multiplier: the event's own number (Events.value) when it has one
local function raidMult(key: string, fallback: number): number
	if Events and type(Events.value) == "function" then
		local ok, v = pcall(Events.value, key, fallback)
		if ok and type(v) == "number" and v > 0 then return v end
	end
	return fallback
end

------------------------------------------------------------------
-- who cheats
------------------------------------------------------------------
-- cheaters inside (or walking in to) that owner's casino right now
function Cheaters.activeIn(ownerId: number?): number
	local n = 0
	for _, rec in guests do
		if rec.cheater and rec.ownerId == ownerId and not rec.done and rec.npc.phase ~= "leaving" then
			n += 1
		end
	end
	return n
end

-- Studio test: ServerStorage attribute CasinoTestCheaters = true -> any rank, every
-- guest who may cheat does, one every 20 s per casino (read live: toggle it in Play)
local function testMode(): boolean
	return RunService:IsStudio() and ServerStorage:GetAttribute("CasinoTestCheaters") == true
end

-- NPCs.rollPatronSpec: is this arriving guest (not a VIP) a cheater?
function Cheaters.rollCheater(casino): boolean
	if CC.Enabled == false or not (casino and casino.ownerId) then return false end
	local profile = profileOf(ownerOf(casino.ownerId))
	local test = testMode()
	if not profile or (rankOf(profile) < num(CC.MinRank, 2) and not test) then return false end
	local raid = raidActive()
	local st = casinoState[casino.ownerId]
	if not st then
		st = { lastRollAt = -math.huge }
		casinoState[casino.ownerId] = st
	end
	local now = os.clock()
	local gap = test and 20 or num(CC.MinGapSeconds, 150) * (raid and num(CC.RaidGapMult, 0.5) or 1)
	if now - st.lastRollAt < gap then return false end
	local most = num(CC.MaxPerCasino, 1) + (raid and num(CC.RaidExtraPerCasino, 1) or 0)
	if Cheaters.activeIn(casino.ownerId) >= most then return false end
	local chance = num(CC.Chance, 0.05) * perLevel(CC.SecurityChanceMult, securityLevel(profile), 1)
	if raid then chance *= raidMult("cheaterMult", num(CC.RaidChanceMult, 3)) end
	if test then chance = 1 end
	if rng:NextNumber() >= chance then return false end
	st.lastRollAt = now
	return true
end

------------------------------------------------------------------
-- a visit (NPCs.runPatron calls these)
------------------------------------------------------------------
-- how a cheater plays (NPCs.runPatron + Gambling.npcPlay): one shared table (read only)
local cheatProfile = nil
local function getCheatProfile()
	if not cheatProfile then
		cheatProfile = {
			betMin = num(CC.BetFractionMin, 0.06), betMax = num(CC.BetFractionMax, 0.12),
			machines = num(CC.Machines, 3), extraRounds = num(CC.ExtraRounds, 5),
			thinkMin = num(CC.ThinkDelayMin, 1.2), thinkMax = num(CC.ThinkDelayMax, 2.0),
			winBoost = CC.WinBoost or 0.3, tries = num(CC.FlipTries, 40), maxWeight = num(CC.MaxWeight, 8),
		}
	end
	return cheatProfile
end

-- a guest walked into a casino (every guest: KICK OUT works on honest ones too).
-- Returns the cheat profile for a cheater, nil for everyone else.
function Cheaters.guestEntered(npc, casino, spec, weight)
	if type(npc) ~= "table" or not npc.model or not casino then return nil end
	local cheater = type(spec) == "table" and spec.cheater == true
	local w = math.max(1, num(weight, 1))
	guests[npc.model] = {
		npc = npc, model = npc.model, ownerId = casino.ownerId, cheater = cheater, enteredAt = os.clock(),
		weightC = math.min(w, num(CC.MaxWeight, 8)),  -- their rounds' weight (cheaters)
		take = 0,              -- Cash the owner paid them so far (x their round weight)
		rounds = 0, wins = 0, startWallet = nil, firstRoundAt = nil, cap = nil, machine = nil,
		suspect = false, alerted = false,
		done = false,          -- busted / kicked (no second kick, no security catch)
	}
	if not cheater then return nil end
	return getCheatProfile()
end

local function machineName(machine: Instance?): string
	if not machine then return "your casino" end
	local def = Config.getMachineDef(machine:GetAttribute("MachineId"))
	return def and def.name or machine.Name
end

local function fireAlert(rec, payload)
	local owner = ownerOf(rec.ownerId)
	if not (owner and Remotes) then return end
	pcall(function() Remotes.CheaterAlert():FireClient(owner, payload) end)
end

-- the red "?" over their head + ONE alert to the owner
local function markSuspect(rec)
	if rec.suspect then return end
	rec.suspect = true
	pcall(function() rec.model:SetAttribute("Suspect", true) end)
	if rec.alerted then return end
	rec.alerted = true
	local m = rec.machine
	fireAlert(rec, { kind = "suspect", npc = rec.model, machine = m, name = machineName(m),
		story = m and m:GetAttribute("Story") or 1 })
end

-- after each of a cheater's rounds: res = Gambling.npcPlay's result, wallet = theirs now
function Cheaters.cheaterRound(npc, machine, res, wallet)
	local rec = type(npc) == "table" and guests[npc.model] or nil
	if not (rec and rec.cheater and type(res) == "table") or rec.done then return end
	local bet = num(res.bet, 0)
	local payout = num(res.payout, 0)
	wallet = num(wallet, 0)
	if not rec.firstRoundAt then
		rec.firstRoundAt = os.clock()
		rec.startWallet = math.max(1, wallet - num(res.npcNet, 0))
		-- the most they walk off with: MaxTakeMinutes of the owner's income (a floor for new casinos)
		local owner = ownerOf(rec.ownerId)
		local profile = profileOf(owner)
		local income = (Progression and profile) and Progression.incomeRate(profile) or 0
		local clientele = Progression and Progression.clientele(rec.ownerId) or 1
		rec.cap = math.max(income * num(CC.MaxTakeMinutes, 1.25), num(CC.MaxTakeCash, 600) * clientele)
	end
	rec.rounds += 1
	rec.machine = machine
	rec.take -= num(res.ownerDelta, 0)
	if payout > bet then rec.wins += 1 end
	-- the tells: a few wins, a fat wallet or one big win
	if not rec.suspect and rec.rounds >= num(CC.SuspectMinRounds, 2) then
		local up = (wallet - rec.startWallet) / rec.startWallet
		if rec.wins >= num(CC.SuspectWins, 3) or up >= num(CC.SuspectGain, 0.25)
			or (bet > 0 and payout >= bet * num(CC.SuspectBigWin, 8)) then
			markSuspect(rec)
		end
	end
	-- loot enough: off they go (NPCs ends the visit)
	if rec.cap and rec.take >= rec.cap then npc.leaveNow = true end
end

-- the guest walks out (visit over, or thrown out): a cheater nobody caught got away
function Cheaters.guestLeaving(npc)
	local rec = type(npc) == "table" and guests[npc.model] or nil
	if not rec or rec.leaving then return end
	rec.leaving = true
	if rec.cheater and not rec.done and not npc.ejected and rec.take >= 1 then
		fireAlert(rec, { kind = "escaped", npc = rec.model, amount = math.floor(rec.take),
			name = machineName(rec.machine), suspect = rec.suspect })
	end
end

-- the guest is gone (NPCs cleanup)
function Cheaters.guestLeft(npc)
	if type(npc) == "table" and npc.model then guests[npc.model] = nil end
end

function Cheaters.isCheater(model: Instance?): boolean
	local rec = model and guests[model]
	return rec ~= nil and rec.cheater == true
end

------------------------------------------------------------------
-- throwing them out
------------------------------------------------------------------
local function fireKicked(rec, info)
	if not Remotes then return end
	local root = rec.npc.root
	info.npc = rec.model
	info.ownerId = rec.ownerId
	info.pos = (root and root.Parent) and root.Position or nil
	pcall(function() Remotes.GuestKicked():FireAllClients(info) end)
end

local function statsOf(profile)
	local s = profile.CheaterStats
	if type(s) ~= "table" then
		s = { kicked = 0, caught = 0, honestKicked = 0 }
		profile.CheaterStats = s
	end
	return s
end

-- a cheater caught: by = "owner" (KICK OUT) | "security". Pays the owner, throws the
-- cheater out (NPCs.eject) and tells everyone. Returns reward, xp (nil when they
-- couldn't be thrown out any more).
local function bust(rec, owner: Player, by: string)
	local profile = profileOf(owner)
	if not profile or rec.done then return nil end
	local manual = by == "owner"
	local how = {
		by = by, cheater = true, at = os.clock(),
		speed = manual and num(CC.RunSpeed, 24) or num(CC.EscortSpeed, 9),
		delay = manual and 0.35 or num(CC.EscortDelay, 2.5),
	}
	if not (NPCs and type(NPCs.eject) == "function" and NPCs.eject(rec.npc, how)) then return nil end
	rec.done = true
	pcall(function()
		rec.model:SetAttribute("Suspect", nil)
		rec.model:SetAttribute("Busted", by)
	end)

	-- their winnings come back (x2 for a KICK OUT), at least a slice of your income
	local raid = raidActive()
	local income = Progression and Progression.incomeRate(profile) or 0
	local clientele = Progression and Progression.clientele(rec.ownerId) or 1
	local take = math.max(0, math.floor(rec.take))
	local reward
	if manual then
		reward = math.max(take * num(CC.KickReturn, 2), income * num(CC.KickMinMinutes, 0.5),
			num(CC.KickMinCash, 150) * clientele)
	else
		reward = math.max(take * num(CC.SecurityReturn, 1), income * num(CC.SecurityMinMinutes, 0.2),
			num(CC.SecurityMinCash, 60) * clientele)
	end
	local mult = raid and raidMult("kickMult", num(CC.RaidRewardMult, 2)) or 1
	reward = math.floor(reward * mult)
	-- bonus XP (KICK OUT only): KickXPGames games on the machine they cheated at
	local xp = 0
	if manual then
		local def = rec.machine and Config.getMachineDef(rec.machine:GetAttribute("MachineId"))
		local per = def and Config.machineXP(def) or 1
		xp = math.floor(num(CC.KickXPGames, 30) * math.max(per, 1) * rec.weightC * mult)
	end
	if reward > 0 and Economy then Economy.addCash(owner, reward) end
	if xp > 0 and Progression and Progression.addXP then Progression.addXP(owner, xp) end

	local stats = statsOf(profile)
	if manual then
		stats.kicked = num(stats.kicked, 0) + 1
	else
		stats.caught = num(stats.caught, 0) + 1
	end
	gameEvent(owner, manual and "cheaterKicked" or "cheaterCaught", 1)
	fireKicked(rec, { by = by, cheater = true, reward = reward, xp = xp, take = take, raid = raid or nil })
	if pushData then pcall(pushData, owner) end
	return reward, xp
end

local function refuse(message: string)
	return { ok = false, message = message }
end

-- KICK OUT (remote KickGuest; other modules may call it too)
function Cheaters.kick(player: Player, model: Instance?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return refuse("Who's kicking?") end
	if typeof(model) ~= "Instance" then return refuse("That isn't a guest.") end
	local rec = guests[model]
	if not rec then return refuse("That guest already left.") end
	if rec.ownerId ~= player.UserId then return refuse("You can only kick guests out of your own casino.") end
	local npc = rec.npc
	if rec.done or npc.ejected then return refuse("They're already on their way out!") end
	if npc.phase ~= "inside" then return refuse("They're not inside your casino.") end
	local char = player.Character
	local mine = char and char:FindFirstChild("HumanoidRootPart")
	local theirs = npc.root
	if not (mine and theirs and theirs.Parent)
		or (mine.Position - theirs.Position).Magnitude > num(CC.KickServerDistance, 22) then
		return refuse("Get closer to kick them out.")
	end
	local now = os.clock()
	if now - (lastKick[player.UserId] or -math.huge) < num(CC.KickCooldown, 0.4) then return refuse("Slow down!") end
	lastKick[player.UserId] = now

	if rec.cheater then
		local reward, xp = bust(rec, player, "owner")
		if not reward then return refuse("They're already on their way out!") end
		return { ok = true, cheater = true, reward = reward, xp = xp, message = "Cheater busted!" }
	end

	-- an honest guest: they walk off (and their wallet goes with them)
	local how = { by = "owner", cheater = false, at = now, speed = num(CC.HonestLeaveSpeed, 14), delay = 0.5 }
	if not (NPCs and type(NPCs.eject) == "function" and NPCs.eject(npc, how)) then
		return refuse("They're already on their way out!")
	end
	rec.done = true
	pcall(function() model:SetAttribute("Kicked", true) end)
	local profile = profileOf(player)
	if profile then
		local stats = statsOf(profile)
		stats.honestKicked = num(stats.honestKicked, 0) + 1
	end
	gameEvent(player, "honestKicked", 1)
	fireKicked(rec, { by = "owner", cheater = false, reward = 0 })
	if pushData then pcall(pushData, player) end
	return { ok = true, cheater = false, reward = 0, message = "Oops - that guest was honest!" }
end

------------------------------------------------------------------
-- security: catches cheaters by itself
------------------------------------------------------------------
local function securityTick()
	local now = os.clock()
	for model, rec in guests do
		if model.Parent == nil and now - rec.enteredAt > 10 then
			guests[model] = nil -- (a guest whose cleanup never told us)
		elseif rec.cheater and not rec.done and rec.firstRoundAt and rec.npc.phase == "inside"
			and not rec.npc.ejected then
			local owner = ownerOf(rec.ownerId)
			local lvl = securityLevel(profileOf(owner))
			if owner and lvl > 0 and now - rec.firstRoundAt >= perLevel(CC.CatchSeconds, lvl, 40) then
				bust(rec, owner, "security")
			end
		end
	end
end

------------------------------------------------------------------
-- init.server hooks
------------------------------------------------------------------
-- snapshot key `cheaters`
function Cheaters.snapshot(player: Player, profile)
	local stats = type(profile) == "table" and type(profile.CheaterStats) == "table" and profile.CheaterStats or {}
	local lvl = securityLevel(profile)
	return {
		active = Cheaters.activeIn(player.UserId),       -- cheaters in your casino right now
		kicked = num(stats.kicked, 0), caught = num(stats.caught, 0), honestKicked = num(stats.honestKicked, 0),
		security = lvl,                                  -- your Security level (0 = none)
		catchSeconds = lvl > 0 and perLevel(CC.CatchSeconds, lvl, 40) or nil,
		raid = raidActive(),
		minRank = num(CC.MinRank, 2),
	}
end

function Cheaters.leave(player: Player)
	casinoState[player.UserId] = nil
	lastKick[player.UserId] = nil
end

function Cheaters.start(deps)
	NPCs = deps.NPCs
	Staff = deps.Staff
	Data = deps.Data
	Economy = deps.Economy
	Progression = deps.Progression
	Remotes = deps.Remotes
	GameEvents = deps.GameEvents
	Events = deps.Events
	pushData = deps.pushData
	if started then return end
	started = true

	if NPCs and type(NPCs.attachCheaters) == "function" then
		NPCs.attachCheaters(Cheaters)
	else
		warn("[Cheaters] NPCs has no cheater hooks: no cheaters this session.")
	end
	if Remotes and Remotes.KickGuest then
		Remotes.KickGuest().OnServerInvoke = function(player, model)
			local ok, res = pcall(Cheaters.kick, player, model)
			if ok then return res end
			warn("[Cheaters] kick: " .. tostring(res))
			return refuse("Couldn't kick them out right now.")
		end
	end
	task.spawn(function()
		while true do
			task.wait(0.5)
			local ok, err = pcall(securityTick)
			if not ok then warn("[Cheaters] security: " .. tostring(err)) end
		end
	end)
end

-- (headless tests)
Cheaters._debug = { guests = guests, casinoState = casinoState, bust = bust, securityTick = securityTick }

return Cheaters
