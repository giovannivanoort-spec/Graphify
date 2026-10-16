--!strict
-- Config.luau — one place to tune the whole game.

local Config = {}

------------------------------------------------------------------
-- ECONOMY
------------------------------------------------------------------
Config.CurrencyName = "Cash"
Config.StartingCash = 800                  -- a new player buys 2 machines + an upgrade, then something every ~30 s
Config.DataStoreName = "CasinoTycoon_v3"   -- bump to wipe all saves
Config.DataSchemaVersion = 7               -- v7: Quests, Wheel, CheaterStats; v6: XP rank, Rebirth, Potions, Playtime, Decor, staff levels
Config.AutosaveInterval = 120              -- seconds between background saves

------------------------------------------------------------------
-- TICKETS (second currency) + DAILY REWARD + TICKET SHOP
------------------------------------------------------------------
Config.TicketName = "Tickets"

-- DAILY REWARDS (REWARDS: Rewards.luau / DailyUI.luau)
-- 7-day login streak; day 7 is the MEGA reward, then the cycle restarts.
-- Cash days pay max(cash, `minutes` of the owner's income rate: Stats.IncomeRate,
-- see Rewards.dailyCash), so they keep up with a growing casino. `potion` = a
-- Config.Potions id handed out through Potions.give (count `potionCount`, default 1;
-- while potions aren't available it pays its Ticket Shop price in Tickets instead).
-- Any reward key of Config.Playtime.Rewards works here too (boostMinutes, rcoins).
Config.DailyRewards = {
	{ cash = 500, minutes = 5 },
	{ tickets = 25, potion = "xp" },
	{ cash = 2000, minutes = 10 },
	{ tickets = 60, potion = "cash" },
	{ cash = 8000, minutes = 20 },
	{ tickets = 120, potion = "crowd" },
	{ cash = 25000, minutes = 45, tickets = 250, potion = "mega", mega = true },
}
Config.DailyCooldownHours = 20      -- next reward unlocks this long after the last claim
Config.DailyStreakResetHours = 48   -- no claim within this window -> streak restarts at day 1

-- Spend Tickets here (Store -> TICKET SHOP). boostMinutes stacks onto any
-- running boost; while boosted, positive machine earnings are multiplied.
Config.BoostMultiplier = 2
Config.TicketShop = {
	{ id = "boost_10", name = "2X Cash", desc = "2x earnings - 10 min", cost = 50,
	  boostMinutes = 10, icon = "cash", tone = "Orange" },
	{ id = "boost_30", name = "2X Cash", desc = "2x earnings - 30 min", cost = 120,
	  boostMinutes = 30, icon = "cash", tone = "Purple", badge = "BEST VALUE" },
	-- pays max(cashGrant, cashIncomeMinutes x Stats.IncomeRate)
	{ id = "cash_bundle", name = "Cash Bundle", desc = "10 min of income (min $5,000)", cost = 40,
	  cashGrant = 5000, cashIncomeMinutes = 10, icon = "coin", tone = "Green" },
}

function Config.getTicketItem(id: string)
	for _, def in Config.TicketShop do
		if def.id == id then return def end
	end
	return nil
end

------------------------------------------------------------------
-- HOUSE / BANKROLL MODEL
------------------------------------------------------------------
-- Owner Cash IS the bankroll. Visitor loss -> into owner Cash; visitor win ->
-- out of owner Cash. Owner Cash floored at 0. A machine only accepts a REAL
-- PLAYER's bet it can fully cover (bet * maxMultiplier); NPC guests are never
-- limited by the owner's Cash (a broke new casino keeps earning).
Config.OwnerIsBankroll = true

------------------------------------------------------------------
-- OFFLINE / DAILY INCOME (welcome-back popup)
--   offline = min(away, OfflineCapHours) in minutes x rate x OfflineIncomeShare
--             x (1 + Auto Manager) x gamepass offline multiplier
--   rate    = max(Stats.IncomeRate, OfflineIncomePerMachinePerHour x machines / 60)
-- Stats.IncomeRate is the EMA of the owner's unboosted net casino income
-- ($/min), updated once per online minute: rate += IncomeRateAlpha x (last minute - rate).
------------------------------------------------------------------
Config.OfflineIncomeShare = 0.02              -- 8 h away ~ 9.6 min of income (Auto Manager L4: ~24 min)
Config.OfflineIncomePerMachinePerHour = 80   -- floor of the rate until the owner has an IncomeRate
Config.OfflineCapHours = 8                    -- max hours of offline income that accrue
Config.IncomeRateAlpha = 0.1

------------------------------------------------------------------
-- PLOTS  (free placement)
------------------------------------------------------------------
Config.PlotCount = 6
Config.PlotSize = Vector3.new(70, 1, 70)
Config.PlotSpacing = 95
Config.PlacementMargin = 4
Config.MachineSpacing = 7              -- legacy; placement now checks footprints (+ MachineGap)
Config.MachineGap = 1.2                -- studs of free floor kept between two footprints
Config.WallClearance = 0.6             -- studs between a machine's (turned) footprint and the casino walls
Config.MaxMachinesPerPlot = 14         -- per story (see Config.Building.MachinesPerStory)
Config.MaxInventory = 60
Config.GridSnap = 1                    -- placement grid in studs (G toggles free placement)

------------------------------------------------------------------
-- CASINO BUILDING (every plot is a building; buy more stories with Cash)
------------------------------------------------------------------
Config.Building = {
	StoryHeight = 16,                  -- floor-to-floor
	MaxStories = 5,
	-- cost to unlock story N (story 1 comes with the plot); each floor also needs
	-- Config.Progression.StoryRanks[N]. Priced at 15/45/75/120 min of income at that rank.
	StoryCosts = { 0, 40_000, 4_000_000, 50_000_000, 400_000_000 },
	MachinesPerStory = 14,
	NameMinLength = 3,
	NameMaxLength = 22,
	-- plot-local elevator booth (back-right corner, door facing the street)
	Elevator = { x = 31, z = 32, size = 8 },
	-- colour presets the owner picks from (index into each list). Saved themes
	-- store indices, so the list LENGTHS must never change (Data.luau checks).
	Palettes = {
		-- stucco wall colours: mid-value, so they don't go black in shade
		walls = {
			Color3.fromRGB(150, 44, 64),   -- Velvet Wine
			Color3.fromRGB(79, 75, 141),   -- Indigo
			Color3.fromRGB(43, 128, 141),  -- Deep Teal
			Color3.fromRGB(120, 70, 160),  -- Royal Plum
			Color3.fromRGB(226, 210, 178), -- Champagne
			Color3.fromRGB(136, 132, 142), -- Graphite
			Color3.fromRGB(170, 40, 54),   -- Casino Red
			Color3.fromRGB(44, 141, 97),   -- Emerald
			Color3.fromRGB(190, 120, 82),  -- Terracotta
			Color3.fromRGB(60, 96, 176),   -- Sapphire
		},
		-- metal trim: rendered on the Brass material (Materials.tint)
		trim = {
			Color3.fromRGB(214, 166, 70),  -- Brass
			Color3.fromRGB(196, 202, 210), -- Chrome
			Color3.fromRGB(184, 106, 60),  -- Copper
			Color3.fromRGB(170, 26, 48),   -- Crimson Lacquer
			Color3.fromRGB(238, 228, 206), -- Ivory
			Color3.fromRGB(36, 32, 36),    -- Onyx
			Color3.fromRGB(222, 200, 156), -- Champagne
			Color3.fromRGB(214, 146, 116), -- Rose Gold
		},
		neon = {
			Color3.fromRGB(255, 62, 181),  -- Magenta
			Color3.fromRGB(56, 212, 255),  -- Cyan
			Color3.fromRGB(255, 178, 56),  -- Amber
			Color3.fromRGB(47, 240, 180),  -- Mint
			Color3.fromRGB(255, 61, 90),   -- Ruby
			Color3.fromRGB(166, 107, 255), -- Violet
			Color3.fromRGB(255, 233, 196), -- Warm White
			Color3.fromRGB(255, 138, 42),  -- Tangerine
		},
		-- swatch colours of the carpets below (same order as Carpets)
		carpet = {
			Color3.fromRGB(140, 24, 44),   -- #8C182C Crimson Royale
			Color3.fromRGB(70, 36, 122),   -- #46247A Royal Stars
			Color3.fromRGB(22, 96, 66),    -- #166042 Emerald Suits
			Color3.fromRGB(58, 46, 34),    -- #3A2E22 Black-Gold Deco
			Color3.fromRGB(30, 42, 92),    -- #1E2A5C Midnight Compass
			Color3.fromRGB(58, 26, 90),    -- #3A1A5A Neon Retro
			Color3.fromRGB(58, 56, 63),    -- #3A383F Platinum Chips
			Color3.fromRGB(22, 90, 96),    -- #165A60 Atomic Teal
		},
	},
	-- the patterned carpets (Materials keys) behind Palettes.carpet, in the same
	-- order: theme.carpet = i picks Carpets[i]
	Carpets = {
		{ key = "CarpetCrimson", name = "Crimson Royale" },
		{ key = "CarpetRoyal", name = "Royal Stars" },
		{ key = "CarpetEmerald", name = "Emerald Suits" },
		{ key = "CarpetBlackGold", name = "Black-Gold Deco" },
		{ key = "CarpetMidnight", name = "Midnight Compass" },
		{ key = "CarpetNeon", name = "Neon Retro" },
		{ key = "CarpetChips", name = "Platinum Chips" },
		{ key = "CarpetRetro", name = "Atomic Teal" },
	},
	DefaultTheme = { walls = 1, trim = 1, neon = 1, carpet = 1 },
	-- open (unowned) plots wear one of these, by the plot model's PlotIndex
	-- attribute: ((PlotIndex - 1) % 3) + 1, so a fresh server isn't six twins
	UnownedThemes = {
		{ walls = 1, trim = 1, neon = 1, carpet = 1 },  -- Velvet Wine, Brass, Magenta, Crimson Royale
		{ walls = 3, trim = 7, neon = 3, carpet = 3 },  -- Deep Teal, Champagne, Amber, Emerald Suits
		{ walls = 10, trim = 2, neon = 2, carpet = 5 }, -- Sapphire, Chrome, Cyan, Midnight Compass
	},
}

------------------------------------------------------------------
-- DAY / NIGHT (server advances Lighting.ClockTime; clients light the scene)
------------------------------------------------------------------
Config.DayNight = {
	CycleMinutes = 20,                 -- one full in-game day
	StartClock = 15.5,                 -- servers boot in the late afternoon
	NightStart = 19,                   -- the night rush runs from here...
	NightEnd = 6,                      -- ...until here
	NightCustomerMult = 1.5,           -- +50% patrons can come at night
	LampsOn = 18.2, LampsOff = 6.6,    -- street lamps / sign lights switch on in between
}

------------------------------------------------------------------
-- COLLISION GROUPS (so NPCs don't shove players / each other)
------------------------------------------------------------------
Config.CollisionGroups = {
	NPC = "CasinoNPCs",
	Player = "CasinoPlayers",
}

------------------------------------------------------------------
-- NPC PATRONS
------------------------------------------------------------------
Config.NPC = {
	MaxActive = 30,              -- server-wide cap by day (x NightCustomerMult at night)
	SpawnInterval = 3.0,         -- legacy (the old server-wide spawn clock); the flow below replaced it
	-- Patrons come by car (Config.Traffic): a party of PartyMin..PartyMax (+ the
	-- Party Shuttles upgrade) steps out at the casino's curb stop; leaving patrons
	-- wait at the curb for a ride, walking off after CurbWaitMax seconds without one.
	PartyMin = 1,
	PartyMax = 4,
	PartyPerCapacity = 8,        -- big casinos get fuller cars: at least capacity / this per party
	CurbWaitMax = 80,
	-- Passengers on their way count against a casino's capacity; it takes this
	-- share more (at least 1) so its machines don't sit idle while they drive.
	TransitAllowance = 0.3,
	-- PATRON FLOW (economy_spec 6.3/6.4): every casino has its own arrival rate
	--   demand = (ArrivalBase + ArrivalPerMachine x gambling machines) x (1 + Billboards)
	--            x night rush x (1 + ParkingDemandPerStop x Valet stops) x (1 + PartyDemandPerSeat x Shuttle seats)
	--   lobby  = (capacity + transit allowance) x 60 / nominal visit seconds
	--   rate   = min(demand, lobby) guests/min (the casino's bottleneck: DEMAND or LOBBY)
	-- The server-wide NPC cap is split into visible shares (each casino at least
	-- MinVisiblePerCasino); one visible guest counts as W guests,
	-- W = clamp(rate x measured visit seconds / (60 x visible share), 1, GuestWeightMax),
	-- so a casino earns its rate however full the server is and however slowly NPCs walk.
	ArrivalBase = 2,               -- guests/min every casino with machines attracts by day ...
	ArrivalPerMachine = 0.9,       -- ... plus this per GAMBLING machine (machines draw crowds)
	ParkingDemandPerStop = 0.25,   -- Valet Parking: each extra curb stop -> +25% demand ...
	ParkingTransitPerStop = 0.2,   -- ... and +0.2 TransitAllowance (guests in cars don't fill your lobby)
	PartyDemandPerSeat = 0.10,     -- Party Shuttles: each extra seat -> +10% demand (and PartyMax + seats)
	SpawnTick = 0.5,               -- the flow loop's step (s)
	GuestWeightMax = 250,          -- one visible guest stands for at most this many
	MinVisiblePerCasino = 4,       -- every casino sees at least this many guests when the server is full
	WeightRecompute = 5,           -- seconds between guest-weight updates (a guest keeps the W it spawned with)
	HoldEMAAlpha = 0.1,            -- measured visit time: holdEMA += alpha x (measured - holdEMA) per leaving guest
	-- fill correction: visible guests turned away (no visible room, server cap, jammed
	-- roads) become debt (x W, at most FillDebtMinutes of the casino's rate), paid out
	-- as extra weight on the next guests who come (each counts at most FillBoostMax x W)
	FillDebtMinutes = 2,
	FillBoostMax = 2,
	-- false (economy_spec 6.3): rate = min(demand, lobby). true: rate = demand x (1 -
	-- ErlangB(lobby places, demand x visit / 60)), the economy simulator's model that the
	-- rank thresholds and prices were calibrated on (ranks ~10% later early/mid game).
	-- On: the owner asked for a SLOW climb, and this lands within ~3-9% of the
	-- designed rank times (off: 13-22% faster through R3-R8)
	LobbyLoss = true,
	-- nominal visit seconds = car + (base + perMachine x (machines/visit - 1) + upstairs x upstairs share)
	--   / (1 + Moving Walkways) + rounds x mean think delay x Fast Dealers x machine Speed upgrades
	NominalHold = { car = 23, base = 6, perMachine = 6.5, upstairs = 26 },
	-- the visible flow uses at most this share of the curb's capacity
	-- (Traffic.curbCapacityPerMinute: stops, car lengths, party sizes); above that the
	-- guest weight takes over (the curb only throttles visible cars)
	CurbUse = 0.8,
	WalkwayRounds = 5,             -- Moving Walkways: max rounds per machine + floor(5 x walk-speed bonus + 0.5)
	-- Server-wide cap (patrons in the world + on their way): clamp(MaxActiveBase
	-- + MaxActivePerCasino x casinos with machines, MaxActiveMin, MaxActiveMax),
	-- x NightCustomerMult at night, never above MaxActiveHardCap.
	MaxActiveBase = 10,
	MaxActivePerCasino = 4,
	MaxActiveMin = 30,
	MaxActiveMax = 60,
	MaxActiveHardCap = 80,
	-- Wallet a patron walks in with: floor(U{WalletMin..WalletMax} x clientele of
	-- the owner's Casino Rank x (1 + High Rollers)); VIPs x VIPWalletMultiplier x (1 + Red Carpet).
	-- Guests bet a SMALL share of it per round, so a machine's max bet is what
	-- caps their bets (better machines earn more).
	WalletMin = 50,
	WalletMax = 600,
	-- legacy keys (unused now, kept so older configs don't break)
	StartingWalletMin = 15,
	StartingWalletMax = 200,
	RoundsPerMachineMin = 3,
	RoundsPerMachineMax = 7,
	MachinesPerVisitMin = 1,
	MachinesPerVisitMax = 3,
	BetFractionMin = 0.02,       -- share of the wallet bet per round (+ Big Spenders)
	BetFractionMax = 0.06,
	WalkSpeed = 12,              -- x (1 + Moving Walkways)
	ThinkDelayMin = 0.6,
	ThinkDelayMax = 1.4,
	MoveTimeout = 16,            -- give up walking to a point after this many seconds
	StuckCheckInterval = 2,      -- re-path if no progress in this window
	-- House tilt for patrons: chance that a winning spin gets zeroed to a loss.
	-- 0 = pure RNG (fair), 0.4 = 40% of would-be wins are flipped to losses.
	-- Bump this if owners aren't earning fast enough.
	ExtraLossChance = 0.4,
	-- VIP patrons: rare big-spender wave (gold-crown label, big wallet)
	VIPChance = 0.12,
	VIPWalletMultiplier = 5,
	VIPBetFractionMin = 0.04,
	VIPBetFractionMax = 0.10,
	-- VIPs are rendered as the casino OWNER's real Roblox friends (avatar +
	-- floating username). Pulled live via Players:GetFriendsAsync(ownerId).
	VIPUseOwnerFriends = true,         -- false = VIPs use the random AVATAR_USER_IDS pool
	VIPShowFriendName = true,          -- float the friend's username above the head
	VIPRequireFriend = false,          -- true = no friend loaded -> patron isn't a VIP
	FriendCacheSeconds = 600,          -- re-pull an owner's friend list this often
	FriendFetchMax = 60,               -- cap how many friends we collect per owner
	-- Stands: an arriving guest buys at one with chance min(ConcessionVisitMax,
	-- ConcessionVisitBase + ConcessionVisitPerType x distinct stand types), picking
	-- a stand weighted by its revenuePerVisit; it pays revenuePerVisit x clientele
	-- x (1 + Premium Menu) (x ConcessionVIPMultiplier for VIPs), at most the wallet.
	ConcessionVisitBase = 0.35,
	ConcessionVisitPerType = 0.15,
	ConcessionVisitMax = 0.9,
	ConcessionVisitChance = 0.55,  -- legacy (the old flat chance)
	ConcessionVIPMultiplier = 2,   -- VIPs spend 2x at concessions
	-- Cosmetic R6 walk animation (Roblox public asset). pcall-guarded; if it
	-- fails to load the NPC still walks, just without leg swing.
	WalkAnimId = "rbxassetid://180426354",
	SkinColors = {
		Color3.fromRGB(255, 204, 153), Color3.fromRGB(234, 184, 146),
		Color3.fromRGB(201, 150, 110), Color3.fromRGB(160, 116, 80),
		Color3.fromRGB(120, 84, 56),
	},
	ShirtColors = {
		Color3.fromRGB(231, 76, 60), Color3.fromRGB(52, 152, 219), Color3.fromRGB(46, 204, 113),
		Color3.fromRGB(155, 89, 182), Color3.fromRGB(241, 196, 15), Color3.fromRGB(26, 188, 156),
		Color3.fromRGB(230, 126, 34), Color3.fromRGB(236, 240, 241),
	},
}

------------------------------------------------------------------
-- TRAFFIC (CasinoServer/Traffic plans every car, CasinoClient/TrafficClient
-- drives them; CasinoCommon/RoadNet holds the lanes). Cars come out of the
-- tunnels, bring patrons to their casino's curb, pick them up again and
-- drive through town. Visual only: they never collide with anything.
------------------------------------------------------------------
Config.Traffic = {
	Enabled = true,
	-- speeds (studs/s) and how hard cars speed up / brake (studs/s²)
	CruiseSpeed = 28,            -- on the boulevards
	RingSpeed = 22,              -- on the ring's straights
	CornerSpeed = 19,            -- round the ring's rounded corners
	JunctionSpeed = 14,          -- through the turns on / off the ring and past every ring mouth
	Accel = 12,
	Decel = 12,
	BayRun = 34,                 -- studs of lane change + braking into a curb stop (and out again)
	-- spacing
	Headway = 1.8,               -- seconds between two cars where traffic merges
	BayGap = 2.5,                -- studs (bumper to bumper, at least) between two cars moving in a casino's curb lane...
	ParkedGap = 0.8,             -- ...and between two creeping into / standing at its stops
	LeadTime = 1.0,              -- cars are planned at least this far ahead (time for every client to hear)
	-- curb stops: each casino has a valet lane of 1 + its Parking upgrade's
	-- "parkingBays" stops in a row, the base one (level with the entrance) in
	-- front, the extra ones queued behind it; cars take the one they reach first
	MaxExtraBays = 2,            -- the most extra stops the Parking upgrade can add
	ValetSpacing = 15,           -- studs between two stops of a casino
	ValetSpeed = 12,             -- how fast cars roll along the curb lane past the stops
	FrontTolerance = 3,          -- a car takes a stop further up the queue if it waits at most this much longer for it
	CurbLatAccel = 20,           -- studs/s² sideways at most while turning into / out of the curb lane
	DropoffDwell = 3.0,          -- seconds a car stands at the curb while passengers get out (and riders in)
	PickupDwell = 2.6,
	MaxExtraDwell = 6,           -- a car may wait this much longer at the curb for a gap in the traffic...
	MaxValetWait = 10,           -- ...or this much for the cars ahead of it in the curb lane to pull away
	MaxDropoffDelay = 25,        -- skip a drop-off whose car would wait longer than this in its tunnel
	MaxPickupDelay = 60,         -- (and a pick-up: the patron asks again a little later)
	Seats = 4,                   -- leaving patrons one car takes
	-- how many cars (on the road or waiting in a tunnel)
	MaxCars = 24,
	NightMaxCars = 34,
	CustomerExtra = 20,          -- patrons' cars may go this far over MaxCars
	AmbientInterval = 3.2,       -- seconds between through-traffic cars by day...
	NightAmbientInterval = 2.2,  -- ...and at night
	AmbientShare = 0.6,          -- through traffic pauses while the road holds this share of MaxCars
	AmbientMaxDelay = 6,
	-- looks
	CustomerKinds = { taxi = 5, sedan = 3, sport = 2 },        -- (VIPs always come by limo)
	AmbientKinds = { sedan = 5, taxi = 3, sport = 2, limo = 1 },
	WhiteLimoChance = 0.25,
	BodyColors = {
		Color3.fromRGB(176, 28, 46),   -- casino red
		Color3.fromRGB(30, 44, 78),    -- midnight blue
		Color3.fromRGB(196, 199, 205), -- silver
		Color3.fromRGB(232, 230, 222), -- pearl
		Color3.fromRGB(26, 26, 30),    -- black
		Color3.fromRGB(24, 88, 66),    -- racing green
		Color3.fromRGB(188, 152, 96),  -- champagne
		Color3.fromRGB(104, 36, 84),   -- plum
	},
	CullDistance = 850,          -- clients take cars farther than this from the camera out of the world
}

------------------------------------------------------------------
-- MACHINE CATALOG (the shop)
-- type: "Slots" | "Roulette" | "Blackjack" | "Dice" | "Wheel" | "Plinko"
-- (stands: "Snacks" | "Drinks" | "Souvenirs" | "Vending")
------------------------------------------------------------------
export type MachineDef = {
	id: string, name: string, type: string,
	cost: number, minBet: number, maxBet: number,
	size: Vector3, color: Color3,
	unlockRank: number?,            -- Casino Rank needed to BUY it (Config.Progression); owned copies always keep working
	kind: string?,                  -- "machine" (default) | "concession"
	revenuePerVisit: number?,       -- concessions only: paid to owner each NPC visit
	model: string?,                 -- code-built model name (MachineModels)
	xpTier: number?,                -- XP per play tier (Config.machineXP; default unlockRank)
	xp: number?,                    -- explicit XP per play (overrides xpTier)
	rebirth: number?,               -- rebirths needed to BUY it (0/nil = none)
	-- rebirth-machine perks (machine attributes, see Placement.buildMachine):
	--   income: owner earnings x income   speed: guests play (speed) faster (think time x (1 - speed))
	--   edge: + house tilt vs guests      xp: XP per game x (1 + xp)
	perks: { income: number?, speed: number?, edge: number?, xp: number? }?,
}

Config.SellRefund = 0.5  -- fraction of cost returned when selling a machine

Config.Catalog = {
	-- `model` names a code-built Showtime model (ServerScriptService/CasinoServer/MachineModels);
	-- `size` is its footprint (ghost preview while placing + procedural fallback).
	-- In rank order (economy spec 7.1): bets follow the clientele of the unlock
	-- rank, prices pay back in 4 x 1.3^(rank - 1) minutes at that rank. The next
	-- copy of an id costs more (Config.machinePrice). `xpTier` sets the XP one
	-- game on it earns (Config.machineXP): the rank machines sit at their rank.
	{ id = "slots_basic",          name = "Lucky 7s Slots",       type = "Slots",     cost = 300,        minBet = 5,   maxBet = 75,   unlockRank = 1,  xpTier = 1,  size = Vector3.new(4.1,7.2,3.2),  color = Color3.fromRGB(231, 76, 60),  model = "LuckySevens" },
	{ id = "dice_std",             name = "Dice Game",            type = "Dice",      cost = 400,        minBet = 3,   maxBet = 40,   unlockRank = 1,  xpTier = 1,  size = Vector3.new(3.9,5.6,3.0),  color = Color3.fromRGB(230, 126, 34), model = "Dice" },
	{ id = "roulette_std",         name = "Roulette Table",       type = "Roulette",  cost = 1000,       minBet = 5,   maxBet = 60,   unlockRank = 2,  xpTier = 2,  size = Vector3.new(8.9,4.4,5.0),  color = Color3.fromRGB(39, 174, 96),  model = "Roulette" },
	{ id = "wheel_fortune",        name = "Wheel of Fortune",     type = "Wheel",     cost = 1000,       minBet = 5,   maxBet = 75,   unlockRank = 2,  xpTier = 2,  size = Vector3.new(5.6,9.0,2.6),  color = Color3.fromRGB(241, 196, 15), model = "FortuneWheel" },
	{ id = "plinko_board",         name = "Lucky Plinko",         type = "Plinko",    cost = 2000,       minBet = 10,  maxBet = 150,  unlockRank = 3,  xpTier = 3,  size = Vector3.new(5.2,8.6,3.0),  color = Color3.fromRGB(30, 200, 210), model = "PlinkoBoard" },
	{ id = "blackjack_std",        name = "Blackjack Table",      type = "Blackjack", cost = 2500,       minBet = 8,   maxBet = 100,  unlockRank = 3,  xpTier = 3,  size = Vector3.new(8.2,4.2,4.8),  color = Color3.fromRGB(41, 128, 185), model = "Blackjack" },
	{ id = "slots_deluxe",         name = "Diamond Slots",        type = "Slots",     cost = 5000,       minBet = 20,  maxBet = 250,  unlockRank = 4,  xpTier = 4,  size = Vector3.new(4.1,8.1,3.2),  color = Color3.fromRGB(155, 89, 182), model = "DiamondSlots" },
	{ id = "craps_table",          name = "Craps Table",          type = "Dice",      cost = 6000,       minBet = 12,  maxBet = 150,  unlockRank = 4,  xpTier = 4,  size = Vector3.new(11.3,4.6,5.6), color = Color3.fromRGB(46, 160, 90),  model = "Craps" },
	{ id = "video_poker",          name = "Video Poker Bar",      type = "Slots",     cost = 15_000,     minBet = 30,  maxBet = 400,  unlockRank = 5,  xpTier = 5,  size = Vector3.new(5.0,4.8,3.6),  color = Color3.fromRGB(42, 91, 215),  model = "VideoPoker" },
	{ id = "slots_gold",           name = "Golden 7s",            type = "Slots",     cost = 15_000,     minBet = 30,  maxBet = 400,  unlockRank = 5,  xpTier = 5,  size = Vector3.new(4.9,8.2,4.0),  color = Color3.fromRGB(240, 180, 30), model = "GoldenSevens" },
	{ id = "blackjack_hr",         name = "High Roller 21",       type = "Blackjack", cost = 60_000,     minBet = 30,  maxBet = 400,  unlockRank = 6,  xpTier = 6,  size = Vector3.new(8.2,4.2,5.0),  color = Color3.fromRGB(170, 20, 50),  model = "HighRollerBlackjack" },
	{ id = "sicbo_dome",           name = "Sic Bo Dome",          type = "Dice",      cost = 60_000,     minBet = 30,  maxBet = 400,  unlockRank = 6,  xpTier = 6,  size = Vector3.new(7.0,5.0,7.0),  color = Color3.fromRGB(200, 16, 46),  model = "SicBoDome" },
	{ id = "roulette_vip",         name = "VIP Roulette",         type = "Roulette",  cost = 150_000,    minBet = 50,  maxBet = 600,  unlockRank = 7,  xpTier = 7,  size = Vector3.new(9.2,4.4,5.1),  color = Color3.fromRGB(110, 40, 170), model = "VIPRoulette" },
	{ id = "baccarat_table",       name = "Baccarat Table",       type = "Blackjack", cost = 150_000,    minBet = 50,  maxBet = 600,  unlockRank = 7,  xpTier = 7,  size = Vector3.new(9.6,4.6,5.4),  color = Color3.fromRGB(14, 122, 79),  model = "Baccarat" },
	{ id = "wheel_mega",           name = "Mega Wheel",           type = "Wheel",     cost = 400_000,    minBet = 80,  maxBet = 1200, unlockRank = 8,  xpTier = 8,  size = Vector3.new(7.3,11.6,3.5), color = Color3.fromRGB(170, 70, 255), model = "MegaWheel" },
	{ id = "slots_mega",           name = "Mega Jackpot",         type = "Slots",     cost = 1_000_000,  minBet = 200, maxBet = 2500, unlockRank = 9,  xpTier = 9,  size = Vector3.new(5.8,10.8,4.7), color = Color3.fromRGB(255, 79, 208), model = "MegaJackpot" },
	{ id = "pachinko_palace",      name = "Pachinko Palace",      type = "Plinko",    cost = 1_000_000,  minBet = 200, maxBet = 2500, unlockRank = 9,  xpTier = 9,  size = Vector3.new(8.0,11.5,3.2), color = Color3.fromRGB(255, 79, 216), model = "PachinkoPalace" },
	{ id = "dragon_slots",         name = "Diamond Dragon",       type = "Slots",     cost = 2_000_000,  minBet = 300, maxBet = 4000, unlockRank = 10, xpTier = 10, size = Vector3.new(9.0,11.0,4.6), color = Color3.fromRGB(20, 184, 138), model = "DiamondDragon" },
	{ id = "billionaire_roulette", name = "Billionaire Roulette", type = "Roulette",  cost = 15_000_000, minBet = 500, maxBet = 6000, unlockRank = 12, xpTier = 12, size = Vector3.new(11.5,7.5,6.4), color = Color3.fromRGB(255, 203, 46), model = "BillionaireRoulette" },

	-- THE REBIRTH WING: every one needs `rebirth` rebirths to buy (no rank gate;
	-- the Showroom's back rows). One rule (scratchpad econ_rb/rb_design.py) on a
	-- design tier t per machine (the -- tN note at the end of its line):
	--   bets   minBet of a tier-t machine, maxBet of tier t + 1,
	--   cost   what a rank machine with that max bet costs (the payback price of
	--          tier t + 1: 4 x 1.3^t min x its income at rank t + 1),
	--   xpTier t + 2,
	--   perks  by the rebirth that unlocks it, Rebirth 1 -> 12: owner income
	--          x1.4 -> x2.5 (positive results), guests play 10% -> 30% faster,
	--          house tilt +2 -> +6 points, XP +25% -> +100% (Placement attributes
	--          IncomeMult / PerkSpeed / PerkTilt, Config.machineXP).
	-- At a rebirther's rank each one earns ~1.5-2.7x the rank machine of the same
	-- price (Midas Touch ~4.8x the Billionaire Roulette at R12) and the newest one
	-- is the best machine you can own. Tables: scratchpad/research/xp_rebirth_calibration.md.
	{ id = "phoenix_slots",        name = "Phoenix Fire",         type = "Slots",     cost = 5000,       minBet = 12,   maxBet = 250,    unlockRank = 1, rebirth = 1,  xpTier = 5,  perks = { income = 1.4, speed = 0.1, edge = 0.02, xp = 0.25 }, size = Vector3.new(6.7,10.5,4.4),  color = Color3.fromRGB(255, 90, 31),   model = "PhoenixFire" },        -- t3
	{ id = "thunder_wheel",        name = "Thunder Wheel",        type = "Wheel",     cost = 60_000,     minBet = 20,   maxBet = 400,    unlockRank = 1, rebirth = 1,  xpTier = 7,  perks = { income = 1.4, speed = 0.1, edge = 0.02, xp = 0.25 }, size = Vector3.new(8.6,10.8,3.2),  color = Color3.fromRGB(61, 123, 255),  model = "ThunderWheel" },       -- t5
	{ id = "crystal_dice",         name = "Crystal Cavern",       type = "Dice",      cost = 20_000,     minBet = 12,   maxBet = 250,    unlockRank = 1, rebirth = 2,  xpTier = 6,  perks = { income = 1.5, speed = 0.12, edge = 0.025, xp = 0.3 }, size = Vector3.new(6.6,7.3,4.8),   color = Color3.fromRGB(127, 227, 255), model = "CrystalCavern" },      -- t4
	{ id = "galaxy_plinko",        name = "Galaxy Drop",          type = "Plinko",    cost = 150_000,    minBet = 40,   maxBet = 1000,   unlockRank = 1, rebirth = 2,  xpTier = 8,  perks = { income = 1.5, speed = 0.12, edge = 0.025, xp = 0.3 }, size = Vector3.new(5.1,11.0,3.5),  color = Color3.fromRGB(139, 61, 255),  model = "GalaxyDrop" },         -- t6
	{ id = "pharaoh_roulette",     name = "Pharaoh's Fortune",    type = "Roulette",  cost = 150_000,    minBet = 30,   maxBet = 600,    unlockRank = 1, rebirth = 3,  xpTier = 8,  perks = { income = 1.6, speed = 0.14, edge = 0.025, xp = 0.4 }, size = Vector3.new(10.7,7.4,6.5),  color = Color3.fromRGB(226, 169, 59),  model = "PharaohRoulette" },    -- t6
	{ id = "clover_slots",         name = "Pot o' Gold",          type = "Slots",     cost = 300_000,    minBet = 80,   maxBet = 1500,   unlockRank = 1, rebirth = 3,  xpTier = 9,  perks = { income = 1.6, speed = 0.14, edge = 0.025, xp = 0.4 }, size = Vector3.new(6.7,10.1,4.1),  color = Color3.fromRGB(43, 212, 106),  model = "PotOGold" },           -- t7
	{ id = "royal_blackjack",      name = "Royal Crown 21",       type = "Blackjack", cost = 1_000_000,  minBet = 75,   maxBet = 1500,   unlockRank = 1, rebirth = 4,  xpTier = 10, perks = { income = 1.7, speed = 0.15, edge = 0.03, xp = 0.45 }, size = Vector3.new(9.1,8.8,6.3),   color = Color3.fromRGB(122, 43, 217),  model = "RoyalCrown21" },       -- t8
	{ id = "neptune_plinko",       name = "Neptune's Treasure",   type = "Plinko",    cost = 1_000_000,  minBet = 100,  maxBet = 2500,   unlockRank = 1, rebirth = 5,  xpTier = 10, perks = { income = 1.8, speed = 0.17, edge = 0.035, xp = 0.5 }, size = Vector3.new(7.2,10.9,3.1),  color = Color3.fromRGB(31, 209, 193),  model = "NeptuneTreasure" },    -- t8
	{ id = "volcano_dice",         name = "Volcano Eruption",     type = "Dice",      cost = 2_500_000,  minBet = 120,  maxBet = 2500,   unlockRank = 1, rebirth = 6,  xpTier = 11, perks = { income = 1.9, speed = 0.19, edge = 0.04, xp = 0.6 }, size = Vector3.new(7.4,6.8,7.6),   color = Color3.fromRGB(255, 61, 18),   model = "VolcanoEruption" },    -- t9
	{ id = "emperor_wheel",        name = "Emperor's Wheel",      type = "Wheel",     cost = 6_000_000,  minBet = 200,  maxBet = 4000,   unlockRank = 1, rebirth = 7,  xpTier = 12, perks = { income = 2, speed = 0.21, edge = 0.04, xp = 0.65 }, size = Vector3.new(9.4,12.5,4.1),  color = Color3.fromRGB(224, 24, 45),   model = "EmperorWheel" },       -- t10
	{ id = "vault_slots",          name = "Diamond Vault",        type = "Slots",     cost = 15_000_000, minBet = 500,  maxBet = 10_000, unlockRank = 1, rebirth = 8,  xpTier = 13, perks = { income = 2.1, speed = 0.23, edge = 0.045, xp = 0.75 }, size = Vector3.new(8.1,10.9,4.0),  color = Color3.fromRGB(184, 199, 218), model = "DiamondVault" },       -- t11
	{ id = "celestial_roulette",   name = "Celestial Roulette",   type = "Roulette",  cost = 25_000_000, minBet = 500,  maxBet = 10_000, unlockRank = 1, rebirth = 10, xpTier = 14, perks = { income = 2.3, speed = 0.26, edge = 0.055, xp = 0.85 }, size = Vector3.new(10.3,10.1,6.3), color = Color3.fromRGB(51, 70, 184),   model = "CelestialRoulette" },  -- t12
	{ id = "midas_slots",          name = "Midas Touch",          type = "Slots",     cost = 40_000_000, minBet = 1200, maxBet = 30_000, unlockRank = 1, rebirth = 12, xpTier = 15, perks = { income = 2.5, speed = 0.3, edge = 0.06, xp = 1 }, size = Vector3.new(9.2,11.8,5.6),  color = Color3.fromRGB(255, 210, 63),  model = "MidasTouch" },         -- t13

	-- CONCESSIONS — patrons buy snacks/drinks on visits; revenue flows to you
	-- (revenuePerVisit x the rank's clientele).
	{ id = "vending",          name = "Vending Machine",  type = "Vending",   cost = 100,        minBet = 0, maxBet = 0, unlockRank = 1,  size = Vector3.new(3.2,5.6,2.2), color = Color3.fromRGB(155, 89, 182), kind = "concession", revenuePerVisit = 10, model = "Vending" },
	{ id = "snack_stand",      name = "Snack Stand",      type = "Snacks",    cost = 100,        minBet = 0, maxBet = 0, unlockRank = 1,  size = Vector3.new(4.9,5.2,2.9), color = Color3.fromRGB(244, 162, 97), kind = "concession", revenuePerVisit = 14, model = "SnackStand" },
	{ id = "drink_bar",        name = "Soda Fountain",    type = "Drinks",    cost = 300,        minBet = 0, maxBet = 0, unlockRank = 2,  size = Vector3.new(5.9,4.6,3.0), color = Color3.fromRGB(45, 156, 219), kind = "concession", revenuePerVisit = 18, model = "DrinkBar" },
	{ id = "atm",              name = "ATM",              type = "Vending",   cost = 750,        minBet = 0, maxBet = 0, unlockRank = 3,  size = Vector3.new(2.8,5.6,2.2), color = Color3.fromRGB(30, 155, 234), kind = "concession", revenuePerVisit = 20, model = "ATM" },
	{ id = "souvenir_shop",    name = "Souvenir Cart",    type = "Souvenirs", cost = 750,        minBet = 0, maxBet = 0, unlockRank = 3,  size = Vector3.new(5.5,5.5,2.6), color = Color3.fromRGB(231, 76, 60),  kind = "concession", revenuePerVisit = 24, model = "SouvenirCart" },
	{ id = "icecream_cart",    name = "Ice Cream Cart",   type = "Snacks",    cost = 3000,       minBet = 0, maxBet = 0, unlockRank = 4,  size = Vector3.new(5.4,8.4,2.6), color = Color3.fromRGB(255, 163, 218), kind = "concession", revenuePerVisit = 28, model = "IceCreamCart" },
	{ id = "bubble_tea",       name = "Bubble Tea Bar",   type = "Drinks",    cost = 12_000,     minBet = 0, maxBet = 0, unlockRank = 5,  size = Vector3.new(5.6,6.0,3.0), color = Color3.fromRGB(92, 225, 185), kind = "concession", revenuePerVisit = 32, model = "BubbleTeaBar" },
	{ id = "burger_grill",     name = "Burger Grill",     type = "Snacks",    cost = 40_000,     minBet = 0, maxBet = 0, unlockRank = 6,  size = Vector3.new(6.0,6.8,3.4), color = Color3.fromRGB(255, 138, 31), kind = "concession", revenuePerVisit = 36, model = "BurgerGrill" },
	{ id = "gift_boutique",    name = "Gift Boutique",    type = "Souvenirs", cost = 150_000,    minBet = 0, maxBet = 0, unlockRank = 7,  size = Vector3.new(6.6,6.8,3.4), color = Color3.fromRGB(242, 63, 160), kind = "concession", revenuePerVisit = 42, model = "GiftBoutique" },
	{ id = "sushi_bar",        name = "Sushi Bar",        type = "Snacks",    cost = 600_000,    minBet = 0, maxBet = 0, unlockRank = 8,  size = Vector3.new(6.4,6.2,3.4), color = Color3.fromRGB(215, 38, 61),  kind = "concession", revenuePerVisit = 48, model = "SushiBar" },
	{ id = "jewelry_boutique", name = "Jewelry Boutique", type = "Souvenirs", cost = 20_000_000, minBet = 0, maxBet = 0, unlockRank = 11, size = Vector3.new(6.8,7.2,3.6), color = Color3.fromRGB(138, 77, 232), kind = "concession", revenuePerVisit = 56, model = "JewelryBoutique" },
} :: {MachineDef}

-- id -> def (built on first use; the catalog never changes at runtime)
local defIndex: {[string]: MachineDef}? = nil
function Config.getMachineDef(id: string): MachineDef?
	if not defIndex then
		local idx = {}
		for _, def in Config.Catalog do idx[def.id] = def end
		defIndex = idx
	end
	return (defIndex :: any)[id]
end

function Config.isConcession(def): boolean
	return def and def.kind == "concession" or false
end

-- Price growth per copy (economy spec 7.2): the next copy of the same id costs
-- def.cost x CopyPriceGrowth ^ (copies already owned: placed + in inventory).
-- The Showroom / Shop show it and BuyToInventory charges it.
Config.CopyPriceGrowth = 1.08

-- discount: the owner's `priceDiscount` effect (rebirth upgrade; snapshot field
-- `priceDiscount` on the client), clamped to 0..0.6
function Config.machinePrice(def, ownedCopies: number?, discount: number?): number
	if not def then return 0 end
	local n = math.max(0, math.floor(tonumber(ownedCopies) or 0))
	local d = math.clamp(tonumber(discount) or 0, 0, 0.6)
	return math.floor((def.cost or 0) * Config.CopyPriceGrowth ^ n * (1 - d))
end

-- What each id cost before the economy patch (spec 9.3): the sell refund of a
-- pre-patch copy is capped by min(def.cost, LegacyCost[id]), so old machines
-- whose price went up (Mega Jackpot $48K -> $1M) can't be sold for a profit.
Config.LegacyCost = {
	slots_basic = 2000, slots_deluxe = 6000, roulette_std = 4000, blackjack_std = 3500, dice_std = 2500,
	wheel_fortune = 3000, craps_table = 12000, slots_gold = 15000, blackjack_hr = 20000, roulette_vip = 24000,
	wheel_mega = 36000, slots_mega = 48000,
	snack_stand = 1500, drink_bar = 2500, souvenir_shop = 3500, vending = 800, atm = 2200, icecream_cart = 5000,
	burger_grill = 9500, gift_boutique = 16000,
}

------------------------------------------------------------------
-- SHOWROOM (physical machine shop)
-- A room of pedestals — one per machine in the Catalog. Walk up to a display:
-- a floating card shows its stats + max win, and pressing E buys it into your
-- inventory (if you can afford it). Concessions & staff live at a Services desk.
------------------------------------------------------------------
Config.Showroom = {
	-- the outermost slot on the south boulevard's west side (CityLayout.ShowroomSlot;
	-- CityLayout.showroomFrame() gives these numbers): the room's front plane sits
	-- on the plot-front line, 18 studs east of Center (x = -35)
	Center = Vector3.new(-53, 0.5, 367.5),
	Yaw = 90,                           -- entrance faces east, onto the boulevard
	Spacing = 14,                       -- studs between pedestals
	PerRow = 6,                         -- displays per row; extra rows stack toward the entrance
	RowGap = 16,
	Height = 22,                        -- wall height (the plum ceiling hangs just under it)
	PedestalHeight = 1.4,               -- podium deck height
	BackRowLift = 1.2,                  -- the back row stands this much taller, so it reads over the front row
	KeyShadows = false,                 -- the per-machine ceiling key spots cast shadows (costly on mobile)
	WheelSpinEvery = 12,                -- seconds between spins of the facade prize wheel
	RevealDistance = 14,                -- E-prompt activation distance
	CardDistance = 28,                  -- info-card render distance (shows up close)
	-- the Services desk stands on the Welcome Plaza, facing its centre
	ServicesCFrame = CFrame.new(-54, 0.8, 0) * CFrame.Angles(0, -math.pi / 2, 0), -- plaza west side, facing east to the fountain
}

-- Reel symbol images for the physical Lucky 7s machine (Spinny1/2/3 decals).
-- Add/replace IDs here; the display assigns them so matching result symbols get
-- matching images. Needs at least 3 distinct images.
-- (3D icon renders from UIAssets: coin, gem, star, crown, cash)
Config.SlotReelImages = {
	"rbxassetid://135758119078818",
	"rbxassetid://79822299316617",
	"rbxassetid://95996033511594",
	"rbxassetid://78690067083331",
	"rbxassetid://73844020332102",
}

------------------------------------------------------------------
-- PER-MACHINE UPGRADES (5 tiers each, applied to a single placed machine)
--   speed  → patrons play faster: think delay x max(0.2, 1 - 0.16 L)  (NPCs.luau)
--            L1 0.84, L2 0.68, L3 0.52, L4 0.36, L5 0.20
--   bets   → higher maxBet: x (1 + 0.25 L), x2.25 at L5               (Placement)
--   lucky  → + 0.03 L house tilt vs. patrons, +15% at L5              (NPCs.luau)
--            tilt cap 0.85: 0.40 base + House Edge L5 0.15 + Lucky potion 0.10
--            + Lucky Vibes L5 0.15 = 0.80
-- Level L costs floor(machine cost x MachineUpgradeCostMult[L]); one kind to L5 =
-- 31.75 x the machine's price. Estimator (econ sim): a machine with all three
-- kinds at L5 earns ~1.1-1.7x a fresh machine one to two ranks newer, and each
-- level pays back ~1.5-2x slower than the one before (the late-game sink).
------------------------------------------------------------------
Config.MachineUpgradeMaxLevel = 5
Config.MachineUpgradeCostMult = { 0.75, 2, 5, 9, 15 }      -- x the machine's catalog cost, to go from L-1 -> L
-- legacy flat prices (before the economy pass): only used to refund levels bought
-- back then (Placement sell refund, levels 1-3); kept for older clients that still read them
Config.MachineUpgradeCosts = { 800, 2500, 7000, 15000, 30000 }
Config.MachineUpgrades = {
	speed = { name = "Faster Spins",  desc = "Guests play 16% faster per level.",
	          perLevel = 0.16 },
	bets  = { name = "Higher Limits", desc = "Max bet +25% per level (x2.25 at level 5).",
	          perLevel = 0.25 },
	lucky = { name = "Lucky Vibes",   desc = "+3% house tilt per level (+15% at level 5).",
	          perLevel = 0.03 },
}

-- what upgrading `def` from level-1 to `level` costs (nil past the max level)
function Config.machineUpgradeCost(def, level: number): number?
	local mult = Config.MachineUpgradeCostMult[level]
	if not (def and mult) then return nil end
	return math.floor((def.cost or 0) * mult)
end

------------------------------------------------------------------
-- STAFF (server: CasinoServer/Staff + StaffModels; client: StaffClient + StaffShopUI)
-- profile.Staff[id] = level. HIRE buys level 1 (HireStaff), PROMOTE the next one
-- (PromoteStaff), up to #values. Each role drives ONE effect key through the
-- "staff" effects provider (Upgrades.addProvider; the keys of the UPGRADE TRACKS
-- below, plus cashMult). values[L] is the TOTAL at level L. effect "houseSkim" is
-- the owner's skim instead: Staff.getHouseBonus -> Gambling.payOwner adds
-- floor(bet x skim + 0.5) to the result of every bet.
-- costs[L] = the price of level L, gates[L] = the Casino Rank level L needs.
-- Payback-priced at the gate rank: 4 x 1.3^(rank - 1) minutes of what the level
-- adds to the economy sim's reference casino (scratchpad econ/staff_price.py; a
-- full roster adds ~+11% income at R2, +45% at R6, +87% at R12).
-- team[L] = how many of them work your floor at level L, `post` = where they work
-- (the client clones ReplicatedStorage.StaffTemplates/<id>; see StaffClient).
-- format: "%s" gets the value as a percent (x `show` when set).
-- `cost`, `unlockRank` (= costs[1], gates[1]) and `houseEdgeBonus` are filled in
-- below for older readers (GetCatalog, RankUI). A rebirth fires the whole staff.
------------------------------------------------------------------
export type StaffDef = {
	id: string, name: string, desc: string, icon: string, tone: string, post: string,
	effect: string, format: string, show: number?,
	values: {number}, costs: {number}, gates: {number}, team: {number},
	cost: number?, unlockRank: number?, maxLevel: number?, houseEdgeBonus: number?,
}

Config.Staff = {
	{ id = "greeter", name = "Greeter", icon = "staff", tone = "Pink", post = "entrance",
	  effect = "spawnBonus", format = "+%s guests",
	  desc = "Welcomes everyone at the door: more guests want in.",
	  values = { 0.06, 0.12, 0.20 }, costs = { 100, 1200, 12_000 }, gates = { 1, 3, 5 }, team = { 1, 1, 2 } },
	{ id = "security", name = "Security", icon = "shield", tone = "Green", post = "entrance",
	  effect = "houseSkim", format = "+%s of every bet",
	  desc = "Catches cheaters and walks them out (faster each level), and skims a share of every bet.",
	  values = { 0.01, 0.02, 0.03 }, costs = { 100, 4000, 300_000 }, gates = { 1, 4, 8 }, team = { 1, 2, 3 } },
	{ id = "dealer", name = "Dealer", icon = "bowtie", tone = "Red", post = "tables",
	  effect = "speedBonus", format = "%s faster games",
	  desc = "Deals your tables: every game runs faster.",
	  values = { 0.04, 0.08, 0.12, 0.16, 0.20 }, costs = { 400, 4000, 50_000, 300_000, 2_500_000 },
	  gates = { 2, 4, 6, 8, 10 }, team = { 2, 3, 4, 6, 8 } },
	{ id = "pit_boss", name = "Pit Boss", icon = "cash", tone = "Blue", post = "pit",
	  effect = "houseSkim", format = "+%s of every bet",
	  desc = "Runs the table pit. You skim a share of every bet.",
	  values = { 0.02, 0.03, 0.04 }, costs = { 400, 50_000, 3_000_000 }, gates = { 2, 6, 10 }, team = { 1, 1, 1 } },
	{ id = "bartender", name = "Bartender", icon = "popcorn", tone = "Orange", post = "stands",
	  effect = "concessionBonus", format = "+%s stand sales",
	  desc = "Works your snack and drink stands: guests buy more.",
	  values = { 0.15, 0.30, 0.45, 0.60, 0.80 }, costs = { 400, 4000, 50_000, 400_000, 4_000_000 },
	  gates = { 2, 4, 6, 8, 10 }, team = { 1, 2, 3, 4, 5 } },
	{ id = "valet", name = "Valet", icon = "carkey", tone = "Gold", post = "curb",
	  effect = "tipRate", format = "%s tips on every bet",
	  desc = "Parks the cars at the curb. Happy guests tip.",
	  values = { 0.008, 0.016, 0.024 }, costs = { 1200, 120_000, 6_000_000 }, gates = { 3, 7, 11 }, team = { 1, 1, 2 } },
	{ id = "technician", name = "Technician", icon = "wrench", tone = "Orange", post = "slots",
	  effect = "betBonus", format = "+%s bigger bets", show = 25, -- +0.002 of the wallet = +5% on the 2-6% guests bet
	  desc = "Tunes the machines: guests bet bigger.",
	  values = { 0.002, 0.004, 0.006, 0.008 }, costs = { 1200, 12_000, 120_000, 800_000 },
	  gates = { 3, 5, 7, 9 }, team = { 1, 1, 2, 3 } },
	{ id = "janitor", name = "Janitor", icon = "broom", tone = "Green", post = "wander",
	  effect = "capacityBonus", format = "+%s lobby space",
	  desc = "Keeps the floor spotless: more guests fit inside.",
	  values = { 0.04, 0.08, 0.12, 0.16, 0.20 }, costs = { 4000, 50_000, 300_000, 5_000_000, 40_000_000 },
	  gates = { 4, 6, 8, 10, 12 }, team = { 1, 1, 2, 2, 3 } },
	{ id = "host", name = "VIP Host", icon = "crown", tone = "Purple", post = "vip",
	  effect = "vipChance", format = "+%s VIP guests",
	  desc = "Pampers the high rollers: more VIP big spenders.",
	  values = { 0.015, 0.03, 0.045, 0.06, 0.075 }, costs = { 4000, 50_000, 300_000, 2_500_000, 15_000_000 },
	  gates = { 4, 6, 8, 10, 12 }, team = { 1, 1, 1, 1, 1 } },
	{ id = "entertainer", name = "Entertainer", icon = "mic", tone = "Pink", post = "stage",
	  effect = "nightBonus", format = "+%s guests at night",
	  desc = "Puts on a show on your stage: a bigger night rush.",
	  values = { 0.06, 0.12, 0.18, 0.24, 0.30 }, costs = { 12_000, 120_000, 1_500_000, 10_000_000, 30_000_000 },
	  gates = { 5, 7, 9, 11, 12 }, team = { 1, 1, 1, 2, 2 } },
	{ id = "floor_manager", name = "Floor Manager", icon = "clipboard", tone = "Blue", post = "floor",
	  effect = "cashMult", format = "+%s all earnings",
	  desc = "Runs the whole floor: more money from everything.",
	  values = { 0.02, 0.04, 0.06, 0.08, 0.10 }, costs = { 50_000, 400_000, 4_000_000, 12_000_000, 30_000_000 },
	  gates = { 6, 8, 10, 11, 12 }, team = { 1, 1, 1, 1, 1 } },
} :: {StaffDef}

-- the visible staff (client StaffClient): casinos within Range studs of the camera
-- get their staff (dropped again past Range + 40); per casino (your own: MaxOwn) /
-- in total at most this many people (half on touch devices); name tags show
-- within TagDistance
Config.StaffView = {
	Range = 240,
	MaxCasinos = 4,
	MaxPerCasino = 24,
	MaxOwn = 32,
	MaxRigs = 64,
	TagDistance = 60,
	WalkSpeed = 6.5,             -- studs/s for the walking staff (janitor, technician, managers)
}

local staffIndex: {[string]: StaffDef} = {}
for _, def in Config.Staff do
	def.maxLevel = #def.values
	def.cost = def.costs[1]
	def.unlockRank = def.gates[1]
	if def.effect == "houseSkim" then def.houseEdgeBonus = def.values[1] end
	staffIndex[def.id] = def
end

function Config.getStaffDef(id: string): StaffDef?
	return staffIndex[id]
end

-- what a role gives at `level` (0 when not hired; owned levels past the max count as the max)
function Config.staffValue(def, level: number?): number
	local lvl = math.floor(tonumber(level) or 0)
	if not def or lvl <= 0 then return 0 end
	return def.values[math.min(lvl, #def.values)] or 0
end

-- how many of that role work your floor at `level`
function Config.staffTeam(def, level: number?): number
	local lvl = math.floor(tonumber(level) or 0)
	if not def or lvl <= 0 then return 0 end
	local team = def.team or {}
	return team[math.min(lvl, #team)] or 1
end

-- "+12% guests": a value of that role's effect, as the card shows it
function Config.staffEffectText(def, value: number?): string
	if not def then return "" end
	local pct = (tonumber(value) or 0) * 100 * (def.show or 1)
	local s
	if math.abs(pct - math.floor(pct + 0.5)) < 0.001 then
		s = ("%d%%"):format(math.floor(pct + 0.5))
	else
		s = (("%.1f"):format(pct):gsub("%.0$", "")) .. "%"
	end
	return (def.format or "+%s"):format(s)
end

------------------------------------------------------------------
-- UPGRADE TRACKS (levelled owner upgrades; Upgrades.luau)
-- Each track raises one effect; `values[L]` is the TOTAL effect at level L,
-- `costs[L]` the price of reaching level L and `gates[L]` the Casino Rank that
-- level needs (Config.Progression; owned levels are never taken away). Prices
-- are payback-based at the gate rank (economy_spec 8). `group` is a UI hint.
-- Effect keys the server reads (Upgrades.effect sums them):
--   spawnBonus      guest demand x (1 + v)                      (NPCs flow)
--   walletMult      guest wallets x (1 + v)                     (replaces the flat walletBonus)
--   tiltBonus       + house tilt vs. guests (total capped at 0.85)
--   visitBonus      + machines a guest plays per visit
--   patronSpeed     guest walk speed x (1 + v); + floor(5v + 0.5) max rounds per machine
--   concessionBonus stand sales x (1 + v)
--   capacityBonus   lobby (guests inside at once) x (1 + v)
--   speedBonus      think delay x max(0.4, 1 - v)
--   tipRate         leaving guests tip v x everything they bet
--   parkingBays     + curb stops (Traffic); demand x (1 + 0.25v), transit allowance + 0.2v
--   vipChance       + chance a guest is a VIP big spender
--   offlineBonus    offline income x (1 + v)
--   betBonus        + share of the wallet guests stake per round
--   nightBonus      + night-rush multiplier on top of the x1.5
--   partyBonus      + seats per car (PartyMax + v); demand x (1 + 0.1v)
--   machineSlots    + machine slots in the building
--   vipWalletBonus  VIP wallets x (1 + v)
------------------------------------------------------------------
export type UpgradeTrack = {
	id: string, name: string, desc: string, icon: string, tone: string, effect: string,
	values: {number}, costs: {number}, format: string, gates: {number}?, group: string?,
}

Config.UpgradeTracks = {
	{ id = "marketing", name = "Billboards", icon = "star", tone = "Orange", effect = "spawnBonus", group = "Guests",
	  desc = "More guests want to visit your casino.", format = "+%d%% guests",
	  values = { 0.25, 0.5, 0.8, 1.2, 1.6 },
	  costs = { 100, 1200, 20_000, 120_000, 800_000 },
	  gates = { 1, 3, 5, 7, 9 } },
	{ id = "highRollers", name = "High Rollers", icon = "cash", tone = "Green", effect = "walletMult", group = "Spending",
	  desc = "Guests walk in with fatter wallets.", format = "+%d%% wallets",
	  values = { 0.1, 0.2, 0.35, 0.5, 0.7 },
	  costs = { 100, 1200, 15_000, 600_000, 6_000_000 },
	  gates = { 1, 3, 5, 8, 10 } },
	{ id = "houseEdge", name = "House Edge", icon = "slot", tone = "Purple", effect = "tiltBonus", group = "House",
	  desc = "Guests win a little less often.", format = "+%d%% house edge",
	  values = { 0.03, 0.06, 0.09, 0.12, 0.15 },
	  costs = { 100, 4000, 50_000, 300_000, 6_000_000 },
	  gates = { 1, 4, 6, 8, 11 } },
	{ id = "comps", name = "Free Snacks", icon = "popcorn", tone = "Orange", effect = "visitBonus", group = "House",
	  desc = "Guests play more machines per visit.", format = "+%d machines/visit",
	  values = { 1, 2, 3 },
	  costs = { 400, 25_000, 1_000_000 },
	  gates = { 2, 5, 9 } },
	{ id = "patronSpeed", name = "Moving Walkways", icon = "upgrade", tone = "Blue", effect = "patronSpeed", group = "House",
	  desc = "Guests walk faster and squeeze in extra rounds.", format = "+%d%% walk speed",
	  values = { 0.1, 0.2, 0.3, 0.45, 0.6 },
	  costs = { 400, 4000, 50_000, 400_000, 4_000_000 },
	  gates = { 2, 4, 6, 8, 10 } },  -- NEW
	{ id = "concessions", name = "Premium Menu", icon = "gift", tone = "Pink", effect = "concessionBonus", group = "Business",
	  desc = "Stands earn more from every guest.", format = "+%d%% stand sales",
	  values = { 0.25, 0.5, 0.8, 1.2 },
	  costs = { 400, 12_000, 500_000, 15_000_000 },
	  gates = { 2, 5, 8, 11 } },
	{ id = "capacity", name = "Bigger Lobby", icon = "staff", tone = "Blue", effect = "capacityBonus", group = "Guests",
	  desc = "More guests fit inside at once.", format = "+%d%% lobby",
	  values = { 0.2, 0.4, 0.6, 0.8 },
	  costs = { 1200, 12_000, 500_000, 12_000_000 },
	  gates = { 3, 5, 7, 10 } },
	{ id = "dealers", name = "Fast Dealers", icon = "upgrade", tone = "Green", effect = "speedBonus", group = "House",
	  desc = "Guests play rounds faster.", format = "%d%% faster rounds",
	  values = { 0.1, 0.2, 0.3 },
	  costs = { 1200, 50_000, 1_200_000 },
	  gates = { 3, 6, 9 } },
	{ id = "tipJar", name = "Tip Jar", icon = "coin", tone = "Gold", effect = "tipRate", group = "Spending",
	  desc = "Guests tip a share of everything they bet.", format = "%d%% tips",
	  values = { 0.01, 0.02, 0.03, 0.04 },
	  costs = { 1200, 50_000, 800_000, 10_000_000 },
	  gates = { 3, 6, 9, 12 } },  -- NEW
	{ id = "parking", name = "Valet Parking", icon = "ticket", tone = "Red", effect = "parkingBays", group = "Guests",
	  desc = "Extra curb stops: more cars bring more guests.", format = "+%d curb stops",
	  values = { 1, 2 },
	  costs = { 12_000, 1_500_000 },
	  gates = { 4, 8 } },  -- NEW
	{ id = "vipLounge", name = "VIP Lounge", icon = "crown", tone = "Gold", effect = "vipChance", group = "Spending",
	  desc = "More VIP big spenders show up.", format = "+%d%% VIPs",
	  values = { 0.03, 0.06, 0.09, 0.12 },
	  costs = { 4000, 50_000, 1_500_000, 5_000_000 },
	  gates = { 4, 6, 9, 11 } },
	{ id = "autoManager", name = "Auto Manager", icon = "stats", tone = "Blue", effect = "offlineBonus", group = "Business",
	  desc = "Earn more while you're away.", format = "+%d%% offline income",
	  values = { 0.25, 0.5, 1, 1.5 },
	  costs = { 4000, 50_000, 600_000, 5_000_000 },
	  gates = { 4, 6, 8, 10 } },
	{ id = "bigSpenders", name = "Big Spenders", icon = "coin", tone = "Gold", effect = "betBonus", group = "Spending",
	  desc = "Guests bet a bigger share of their wallet.", format = "+%d%% of wallet per bet",
	  values = { 0.01, 0.02, 0.03 },
	  costs = { 20_000, 750_000, 8_000_000 },
	  gates = { 5, 8, 11 } },
	{ id = "nightLife", name = "Night Life", icon = "star", tone = "Purple", effect = "nightBonus", group = "Guests",
	  desc = "Even more guests during the night rush.", format = "+%d%% at night",
	  values = { 0.15, 0.3, 0.5 },
	  costs = { 15_000, 200_000, 7_500_000 },
	  gates = { 5, 7, 10 } },
	{ id = "partyBus", name = "Party Shuttles", icon = "items", tone = "Pink", effect = "partyBonus", group = "Guests",
	  desc = "Bigger groups arrive in every car.", format = "+%d guests per car",
	  values = { 1, 2, 3 },
	  costs = { 50_000, 800_000, 7_500_000 },
	  gates = { 6, 9, 12 } },  -- NEW
	{ id = "floorPlan", name = "Floor Plan", icon = "build", tone = "Orange", effect = "machineSlots", group = "Business",
	  desc = "Room for more machines.", format = "+%d machine slots",
	  values = { 2, 4, 6 },
	  costs = { 60_000, 800_000, 15_000_000 },
	  gates = { 6, 9, 12 } },
	{ id = "redCarpet", name = "Red Carpet", icon = "gem", tone = "Red", effect = "vipWalletBonus", group = "Spending",
	  desc = "VIP guests bring even more cash.", format = "+%d%% VIP wallets",
	  values = { 0.25, 0.5, 1 },
	  costs = { 120_000, 1_500_000, 7_500_000 },
	  gates = { 7, 10, 12 } },  -- NEW
} :: {UpgradeTrack}

function Config.getUpgradeTrack(id: string): UpgradeTrack?
	for _, def in Config.UpgradeTracks do
		if def.id == id then return def end
	end
	return nil
end

-- the old one-time upgrades are gone (they live on as track levels)
Config.Upgrades = {}
function Config.getUpgradeDef(_id: string) return nil end

-- old one-time upgrade ids -> the track level they become (data v5 migration)
Config.LegacyUpgradeMap = {
	marketing_1 = { "highRollers", 1 }, marketing_2 = { "highRollers", 2 },
	rigged = { "houseEdge", 3 }, comp_drinks = { "comps", 1 },
	neon_sign = { "marketing", 2 }, high_roller = { "highRollers", 4 },
}

------------------------------------------------------------------
-- PROGRESSION: the Casino Rank (CasinoServer/Progression.luau)
-- rank = the highest r with Stats.XP >= Ranks[r].xp (derived, never saved).
-- XP: every game round a guest plays at one of your machines earns
-- Config.machineXP(def) x the guest weight W x (1 + xpMult): better machines
-- give more (a Rank 1 machine 1 XP a game, a Rank 6 one 3.1, a Rank 12 one 11.6).
-- Stands, tips and offline income give no XP; a rebirth keeps it.
-- `clientele` multiplies every guest's wallet. A rank unlocks catalog items
-- (def.unlockRank), upgrade-track levels (track.gates), staff (def.unlockRank),
-- decor (def.unlockRank) and floors (StoryRanks).
-- The thresholds come from the economy simulator (scratchpad/econ_rb/xp_calibrate.py:
-- 6 careers of 2 x 45 min sessions a day, a free player with the staff, decor and
-- 5-level machine upgrades of this update): an engaged player reaches R2 8m, R3 20m,
-- R4 40m, R5 1h15, R6 2h, R7 3h, R8 4h30, R9 6h30, R10 9h, R11 13h, R12 18h of
-- active play. Details: scratchpad/research/xp_rebirth_calibration.md.
-- `threshold` mirrors `xp` for older readers.
------------------------------------------------------------------
Config.Progression = {
	Ranks = {
		{ name = "Back-Alley Parlor", xp = 0, threshold = 0, clientele = 1 },
		{ name = "Corner Card Room", xp = 300, threshold = 300, clientele = 1.6 },
		{ name = "Neon Lounge", xp = 3_000, threshold = 3_000, clientele = 2.5 },
		{ name = "Downtown Casino", xp = 14_000, threshold = 14_000, clientele = 4 },
		{ name = "Boulevard Club", xp = 44_000, threshold = 44_000, clientele = 6.5 },
		{ name = "Strip Hotspot", xp = 110_000, threshold = 110_000, clientele = 10 },
		{ name = "Grand Casino", xp = 310_000, threshold = 310_000, clientele = 16 },
		{ name = "Luxury Resort", xp = 770_000, threshold = 770_000, clientele = 25 },
		{ name = "High Roller Haven", xp = 1_700_000, threshold = 1_700_000, clientele = 40 },
		{ name = "Diamond Palace", xp = 3_700_000, threshold = 3_700_000, clientele = 64 },
		{ name = "Vegas Legend", xp = 9_100_000, threshold = 9_100_000, clientele = 100 },
		{ name = "Casino Master", xp = 19_000_000, threshold = 19_000_000, clientele = 160 },
	},
	-- XP per game round = XPBase x XPGrowth ^ (xpTier - 1), rounded to 0.1 (xpTier
	-- defaults to the machine's unlockRank; rebirth machines set their own), x W,
	-- x (1 + xpMult)
	XPBase = 1,
	XPGrowth = 1.25,
	-- the old money thresholds (Stats.TotalEarned), kept ONLY for the v6 save
	-- migration: an old save keeps its rank and its progress inside it (Data.luau)
	LegacyMoneyThresholds = { 0, 5000, 65_000, 330_000, 1_700_000, 6_800_000, 24_000_000, 88_000_000,
		320_000_000, 1_050_000_000, 4_250_000_000, 10_000_000_000 },
	StoryRanks = { 1, 3, 6, 8, 10 },          -- rank needed to buy story N
	CheckInterval = 1,                        -- seconds: an owner's rank-up check runs at most this often
	-- telemetry (economy_spec 12): print one line per casino per minute (flow, W,
	-- visit time, realized $/min, rank) and mirror it to the plot's "FlowLog" attribute
	MinuteLog = false,
}

-- XP one game round at this machine is worth (before W and xpMult); stands give none
function Config.machineXP(def): number
	if not def or def.kind == "concession" then return 0 end
	if type(def.xp) == "number" then return def.xp end
	local prog = Config.Progression
	local tier = tonumber(def.xpTier or def.unlockRank) or 1
	local perkXP = (type(def.perks) == "table" and tonumber(def.perks.xp)) or 0  -- rebirth-machine perk: +x XP
	return math.floor((prog.XPBase or 1) * (prog.XPGrowth or 1.25) ^ (tier - 1) * (1 + perkXP) * 10 + 0.5) / 10
end

------------------------------------------------------------------
-- SPRINT
------------------------------------------------------------------
Config.Sprint = {
	Enabled = true,
	BaseSpeed = 16,
	SprintSpeed = 26,
	UseStamina = true,
	MaxStamina = 100,
	DrainPerSecond = 22,
	RegenPerSecond = 16,
	RegenDelay = 0.6,    -- seconds after sprinting stops before stamina regens
	MinToStart = 12,     -- need at least this much stamina to begin sprinting
}

------------------------------------------------------------------
-- MONETIZATION (Robux store: CasinoServer/Monetization.luau, client RobuxShopUI)
-- Create each game pass / developer product on the Creator Dashboard
-- (create.roblox.com -> your experience -> Monetization) and paste its id below.
-- id = 0 means "not set up yet": the store shows SOON and never prompts.
-- `robux` is the SUGGESTED price (set the real one on the dashboard; the store
-- shows the live price from MarketplaceService). `icon` / `tone`: the card's look.
--   Game pass `effect` (Monetization): earningsMult / offlineMult (multiply),
--     extraMachines (+ machine slots), vipBadge (the HUD's VIP chip).
--   Game pass `perks` (the Upgrades provider "passes"): upgrade-effect keys added
--     on top of the tracks (xpMult, rebirthCoinMult, spawnBonus, speedBonus, walletMult...).
-- Developer products: three lists, one ProcessReceipt lookup over all of them
-- (an id in none of them is never granted: NotProcessedYet):
--   Products        cash packs: max(cashGrant, incomeMinutes x the owner's income rate)
--   PotionProducts  `count` x potion `potion` (Config.Potions) into the potion stock
--   BoostProducts   `machineBoost` seconds of x3 on the machine picked in its popup
--                   (Remotes.SetBoostTarget), else onto the stored boost time
------------------------------------------------------------------
Config.Monetization = {
	Gamepasses = {
		{ key = "vip", id = 2040224293, name = "VIP Pass", icon = "crown", tone = "Purple", robux = 399, badge = "BEST VALUE",
		  desc = "2x earnings, 2x offline income + a FREE VIP floor that earns x1.25!",
		  effect = { earningsMult = 2, offlineMult = 2, vipBadge = true } },
		{ key = "xp2x", id = 2036288731, name = "2X XP", icon = "xp", tone = "Blue", robux = 249,
		  desc = "Double XP from every game your guests play. Rank up twice as fast!",
		  perks = { xpMult = 1 } },
		{ key = "rebirth2x", id = 2040104330, name = "2X Rebirth Coins", icon = "rcoin", tone = "Gold", robux = 299,
		  desc = "Every rebirth pays out double Rebirth Coins.",
		  perks = { rebirthCoinMult = 1 } },
		{ key = "crowd", id = 2037302710, name = "Crowd Magnet", icon = "staff", tone = "Orange", robux = 199,
		  desc = "50% more guests want to visit your casino.",
		  perks = { spawnBonus = 0.5 } },
		{ key = "highrollers", id = 2037086761, name = "High Roller Club", icon = "cash", tone = "Green", robux = 199,
		  desc = "Every guest walks in with a 50% fatter wallet.",
		  perks = { walletMult = 0.5 } },
		{ key = "fastgames", id = 2036210715, name = "Fast Games", icon = "upgrade", tone = "Pink", robux = 149,
		  desc = "Guests play every game 25% faster.",
		  perks = { speedBonus = 0.25 } },
		{ key = "space", id = 2036852735, name = "Tycoon Expansion", icon = "build", tone = "Blue", robux = 149,
		  desc = "+8 machine slots in your casino.",
		  effect = { extraMachines = 8 } },
		{ key = "offline2x", id = 2036732772, name = "2X Offline Income", icon = "coin", tone = "Green", robux = 99,
		  desc = "Double the Cash your casino makes while you're away.",
		  effect = { offlineMult = 2 } },
	},
	Products = {
		{ key = "cash_5k", id = 3718838823, name = "Pile of Cash", cashGrant = 5000, incomeMinutes = 5, robux = 25 },
		{ key = "cash_25k", id = 3718838880, name = "Bag of Cash", cashGrant = 25_000, incomeMinutes = 20, robux = 75 },
		{ key = "cash_150k", id = 3718838923, name = "Case of Cash", cashGrant = 150_000, incomeMinutes = 60, robux = 199 },
		{ key = "cash_1m", id = 3718839024, name = "Vault of Cash", cashGrant = 1_000_000, incomeMinutes = 180, robux = 499,
		  badge = "BEST VALUE" },
		-- (WHEEL & EVENTS) not a cash pack: 3 bonus Lucky Wheel spins (profile.Wheel.spins);
		-- only offered in the wheel panel, never to players where paid random items are restricted
		{ key = "wheel_spins", id = 0, name = "3 Lucky Spins", wheelSpins = 3, robux = 49 },
	},
	PotionProducts = {
		{ key = "potion_cash", id = 3718839113, potion = "cash", count = 1, robux = 39 },
		{ key = "potion_xp", id = 3718839142, potion = "xp", count = 1, robux = 39 },
		{ key = "potion_crowd", id = 3718839183, potion = "crowd", count = 1, robux = 29 },
		{ key = "potion_speed", id = 3718839231, potion = "speed", count = 1, robux = 25 },
		{ key = "potion_lucky", id = 3718839253, potion = "lucky", count = 1, robux = 25 },
		{ key = "potion_mega", id = 3718839273, potion = "mega", count = 1, robux = 99, badge = "BEST VALUE" },
	},
	BoostProducts = {
		{ key = "machine_boost", id = 3718839302, machineBoost = 900, robux = 10 },
	},
}

-- the x3 machine boost (CasinoServer/MachineBoost.luau): a boosted machine's positive
-- game results x Multiplier for its owner; the time ticks only while the owner is online
Config.MachineBoost = {
	Multiplier = 3,
	Seconds = 900,            -- one purchase / one stored chunk (15 min); buying again ADDS time
	MaxSeconds = 24 * 3600,   -- at most this much on one machine (the rest goes to the stored time)
	TargetTTL = 600,          -- a SetBoostTarget pick counts for purchases this many seconds after it
}

-- every developer product list, for one lookup (ProcessReceipt / the store)
local PRODUCT_LISTS = { "Products", "PotionProducts", "BoostProducts" }

-- what a developer product id grants (nil: unknown / not set up; id 0 never matches)
function Config.getProductByDevId(devProductId: number)
	local id = tonumber(devProductId)
	if not id or id == 0 then return nil end
	for _, listName in PRODUCT_LISTS do
		for _, p in (Config.Monetization :: any)[listName] or {} do
			if p.id == id then return p end
		end
	end
	return nil
end

function Config.getProductByKey(key: string)
	for _, listName in PRODUCT_LISTS do
		for _, p in (Config.Monetization :: any)[listName] or {} do
			if p.key == key then return p end
		end
	end
	return nil
end

function Config.getGamepass(key: string)
	for _, gp in Config.Monetization.Gamepasses do
		if gp.key == key then return gp end
	end
	return nil
end

-- the Robux product that sells potion `potionId` (nil if there is none)
function Config.potionProduct(potionId: string)
	for _, p in Config.Monetization.PotionProducts do
		if p.potion == potionId then return p end
	end
	return nil
end

------------------------------------------------------------------
-- POTIONS (CasinoServer/Potions.luau, client PotionsUI)
-- A potion waits in your stock (profile.Potions[id] = count) until you USE it;
-- using one ADDS minutes x (1 + potionTime effect) to its timer
-- (profile.ActivePotions[id] = seconds left), which runs only while you're online.
-- While its timer runs, a potion's `effects` (upgrade-effect keys, the Upgrades
-- provider "potions") apply; potions sharing a key don't stack (the larger value
-- counts), so MEGA = every potion at once. `short`: the HUD chip text.
-- Sold for Robux (Config.Monetization.PotionProducts) and Tickets (`tickets`: every
-- potion with a price is added to Config.TicketShop below), and given by the daily /
-- playtime rewards (Potions.give(player, id, count)).
------------------------------------------------------------------
Config.Potions = {
	{ id = "cash", name = "Cash Potion", short = "2X CASH", icon = "potion_cash", tone = "Green",
	  desc = "Double Cash from every game", stat = "x2 Cash - 15 min", minutes = 15, tickets = 70,
	  effects = { cashMult = 1 } },
	{ id = "xp", name = "XP Potion", short = "2X XP", icon = "potion_xp", tone = "Blue",
	  desc = "Double XP from every game", stat = "x2 XP - 15 min", minutes = 15, tickets = 70,
	  effects = { xpMult = 1 } },
	{ id = "crowd", name = "Crowd Potion", short = "CROWD", icon = "potion_crowd", tone = "Orange",
	  desc = "50% more guests want to visit", stat = "+50% guests - 15 min", minutes = 15, tickets = 50,
	  effects = { spawnBonus = 0.5 } },
	{ id = "speed", name = "Speed Potion", short = "SPEED", icon = "potion_speed", tone = "Purple",
	  desc = "Guests play every game 30% faster", stat = "Fast games - 15 min", minutes = 15, tickets = 45,
	  effects = { speedBonus = 0.3 } },
	{ id = "lucky", name = "Lucky Potion", short = "LUCKY", icon = "potion_lucky", tone = "Pink",
	  desc = "+10% house edge on every game", stat = "+10% edge - 15 min", minutes = 15, tickets = 45,
	  effects = { tiltBonus = 0.1 } },
	{ id = "mega", name = "Mega Potion", short = "MEGA", icon = "potion_mega", tone = "Gold",
	  desc = "All five potions at once!", stat = "All 5 - 15 min", minutes = 15, tickets = 250,
	  effects = { cashMult = 1, xpMult = 1, spawnBonus = 0.5, speedBonus = 0.3, tiltBonus = 0.1 } },
}
Config.PotionMaxStackMinutes = 24 * 60   -- one potion's timer never stacks past this

function Config.getPotion(id: string)
	for _, def in Config.Potions do
		if def.id == id then return def end
	end
	return nil
end

-- the Ticket Shop sells every potion with a `tickets` price (Rewards.buyTicketItem:
-- an item with `potion` adds `count` of that potion to the stock)
for _, def in Config.Potions do
	if def.tickets and not Config.getTicketItem("potion_" .. def.id) then
		table.insert(Config.TicketShop :: any, {
			id = "potion_" .. def.id, name = def.name, desc = def.stat, cost = def.tickets,
			potion = def.id, count = 1, icon = def.icon, tone = def.tone,
			badge = def.id == "mega" and "ALL 5!" or nil,
		})
	end
end

------------------------------------------------------------------
-- PLAYTIME (REWARDS: CasinoServer/Playtime.luau + Rewards.grant, CasinoClient/PlaytimeUI.luau)
-- Rewards for the time played per UTC day (day = os.time() // 86400): the counter
-- only runs while you're online and restarts at 00:00 UTC. Entry i unlocks after
-- `at` minutes played that day and is claimed once (remote ClaimPlaytime(i));
-- reached rewards still unclaimed when the day rolls over are paid out then.
-- Reward keys (Config.DailyRewards takes the same ones):
--   cash + minutes   Cash: max(cash, minutes x Stats.IncomeRate)   (Rewards.dailyCash)
--   tickets          Tickets
--   potion           a Config.Potions id (Potions.give); potionCount, default 1
--   boostMinutes     stored x3 machine-boost time (MachineBoost.give; the player puts
--                    it on a machine from that machine's popup)
--   rcoins           rebirth coins (Rebirth.giveCoins)
-- A piece whose module isn't running pays Tickets instead: a potion its Ticket Shop
-- price, the others FallbackTickets[kind] (x the count).
-- 2 h of play a day: ~6 min of income in Cash, a 2X Cash potion (~15 min of
-- income when used), Speed / Lucky / XP potions, 55 Tickets, a 15-min x3 boost
-- and 1 rebirth coin: worth having, small next to the income of those 2 h.
------------------------------------------------------------------
Config.Playtime = {
	ClaimSlack = 3,                    -- seconds of client/server clock drift a claim tolerates
	FallbackTickets = { potion = 45, boost = 30, rcoin = 60 },
	Rewards = {
		{ at = 5, cash = 500, minutes = 2 },
		{ at = 10, tickets = 15 },
		{ at = 15, potion = "speed" },
		{ at = 25, cash = 2000, minutes = 4 },
		{ at = 35, potion = "lucky" },
		{ at = 45, tickets = 40 },
		{ at = 60, boostMinutes = 15 },
		{ at = 90, potion = "cash" },
		{ at = 120, rcoins = 1, potion = "xp", grand = true },   -- the GRAND PRIZE card
	},
}

-- names + tones of the reward potions, for when Config.Potions has no entry
local REWARD_POTION_LOOK: {[string]: {string}} = {
	cash = { "Cash Potion", "Green" }, xp = { "XP Potion", "Blue" }, crowd = { "Crowd Potion", "Orange" },
	speed = { "Speed Potion", "Purple" }, lucky = { "Lucky Potion", "Pink" }, mega = { "Mega Potion", "Gold" },
}

-- the Config.Potions entry for a reward's potion id ("xp" also finds "potion_xp"); nil if none
function Config.rewardPotionDef(id: string): any
	local potions = (Config :: any).Potions
	if type(potions) ~= "table" or type(id) ~= "string" then return nil end
	if type(potions[id]) == "table" then return potions[id] end
	for key, def in potions do
		if type(def) == "table" and (def.id == id or def.id == "potion_" .. id or key == "potion_" .. id) then
			return def
		end
	end
	return nil
end

-- the id Potions.give takes for a reward's potion id
function Config.rewardPotionId(id: string): string
	local def = Config.rewardPotionDef(id)
	return (def and type(def.id) == "string" and def.id) or id
end

-- a reward's pieces, rarest first: { kind, icon, tone, name, amount, potion? }
--   kind "rcoin" | "potion" (amount = count) | "boost" (amount = minutes) | "cash" | "tickets"
--   cash: the income-scaled amount the server reports (snapshot), else the flat one
function Config.rewardParts(reward: any, cash: number?): {any}
	local parts = {}
	if type(reward) ~= "table" then return parts end
	if (tonumber(reward.rcoins) or 0) > 0 then
		table.insert(parts, { kind = "rcoin", icon = "rcoin", tone = "Purple",
			name = reward.rcoins == 1 and "Rebirth Coin" or "Rebirth Coins", amount = reward.rcoins })
	end
	if type(reward.potion) == "string" then
		local id = reward.potion
		local def = Config.rewardPotionDef(id)
		local look = REWARD_POTION_LOOK[id] or { string.upper(id:sub(1, 1)) .. id:sub(2) .. " Potion", "Purple" }
		local icon = def and type(def.icon) == "string" and def.icon or ""
		table.insert(parts, { kind = "potion", potion = id,
			icon = (icon ~= "" and not icon:find("rbxasset")) and icon or ("potion_" .. id),
			tone = (def and type(def.tone) == "string" and def.tone) or look[2],
			name = (def and type(def.name) == "string" and def.name) or look[1],
			amount = math.max(1, math.floor(tonumber(reward.potionCount) or 1)) })
	end
	if (tonumber(reward.boostMinutes) or 0) > 0 then
		table.insert(parts, { kind = "boost", icon = "boost", tone = "Orange", name = "x3 Machine Boost",
			amount = reward.boostMinutes })
	end
	if reward.cash then
		table.insert(parts, { kind = "cash", icon = "coin", tone = "Green", name = "Cash",
			amount = math.max(tonumber(cash) or 0, tonumber(reward.cash) or 0) })
	end
	if (tonumber(reward.tickets) or 0) > 0 then
		table.insert(parts, { kind = "tickets", icon = "ticket", tone = "Pink", name = "Tickets", amount = reward.tickets })
	end
	return parts
end

------------------------------------------------------------------
-- DECOR (DECOR: CasinoServer/Decor.luau + DecorModels.luau, the shared placement
-- rules in CasinoCommon/DecorRules.luau, client DecorShopUI.luau)
-- Plants, floors & co. Bought with Cash into profile.DecorInventory (decorId ->
-- count), placed from there like machines (remotes PlaceDecor / MoveDecor /
-- PickupDecor / SellDecor). A rebirth keeps decor; pieces on the floors above
-- the ground floor go back to the inventory (a rebirth drops the building to 1).
--   size        footprint X x Z (Y = height); model space: ground y = 0, centred,
--               front -Z. The placement checks use this box.
--   flat        a floor piece: walkable (no collision), may lie under machines and
--               solid decor; flat pieces on the SAME `layer` may touch but not
--               overlap (1 floors, 2 paths, 3 rugs: a rug can lie on a tile floor)
--   appeal      points; every placed point is +1% guests (spawnBonus), at most
--               +15% (Config.DecorAppeal; Decor's effect provider "decor")
--   unlockRank  the Casino Rank needed to BUY it; rebirth = rebirths needed (0/nil none)
--   model       the DecorModels builder; icon / tone: the shop card
-- Prices: payback doesn't apply (decor earns nothing directly): cheap pieces
-- ($50-$800) at R1-R2, a few minutes of income at their rank above that, and the
-- Golden pieces need a rebirth.
------------------------------------------------------------------
export type DecorDef = {
	id: string, name: string, category: string, cost: number, size: Vector3, flat: boolean?,
	layer: number?, appeal: number, unlockRank: number?, rebirth: number?, model: string,
	icon: string, tone: string,
}

Config.DecorPerStory = 40          -- most placed pieces on one floor (performance)
Config.DecorMaxStack = 99          -- most unplaced copies of one piece in the inventory
Config.DecorSellRefund = 0.5       -- share of today's price a sold piece pays back
Config.DecorMachineGap = 0.6       -- studs between a solid piece and a machine's footprint
Config.DecorAppeal = { PerPoint = 0.01, MaxBonus = 0.15 }

-- the shop's filter chips, in order (DecorShopUI)
Config.DecorCategories = {
	{ id = "plants", label = "PLANTS", icon = "plant", tone = "Green" },
	{ id = "floors", label = "FLOORS", icon = "path", tone = "Red" },
	{ id = "lights", label = "LIGHTS", icon = "lamp", tone = "Orange" },
	{ id = "lounge", label = "LOUNGE", icon = "crown", tone = "Purple" },
	{ id = "showpieces", label = "SHOWPIECES", icon = "statue", tone = "Blue" },
	{ id = "golden", label = "GOLDEN", icon = "sparkles", tone = "Gold" },
}

local V = Vector3.new
Config.Decor = {
	-- PLANTS
	{ id = "fern_pot", name = "Fern Planter", category = "plants", cost = 50, unlockRank = 1, appeal = 1,
	  size = V(2.4, 2.5, 2.4), model = "FernPlanter", icon = "plant", tone = "Green" },
	{ id = "potted_palm", name = "Potted Palm", category = "plants", cost = 150, unlockRank = 1, appeal = 1,
	  size = V(4.0, 6.4, 4.0), model = "PottedPalm", icon = "plant", tone = "Green" },
	{ id = "cactus", name = "Desert Cactus", category = "plants", cost = 250, unlockRank = 1, appeal = 1,
	  size = V(2.2, 4.4, 2.2), model = "DesertCactus", icon = "plant", tone = "Orange" },
	{ id = "flower_bed", name = "Flower Bed", category = "plants", cost = 800, unlockRank = 2, appeal = 2,
	  size = V(4.2, 1.8, 1.8), model = "FlowerBed", icon = "plant", tone = "Pink" },
	{ id = "topiary_hedge", name = "Topiary Hedge", category = "plants", cost = 2500, unlockRank = 3, appeal = 2,
	  size = V(4.0, 3.6, 1.6), model = "TopiaryHedge", icon = "plant", tone = "Green" },
	{ id = "cherry_bonsai", name = "Cherry Bonsai", category = "plants", cost = 12_000, unlockRank = 4, appeal = 3,
	  size = V(2.6, 3.2, 1.8), model = "CherryBonsai", icon = "plant", tone = "Pink" },
	-- FLOORS & PATHS (flat)
	{ id = "red_carpet", name = "Red Carpet", category = "floors", cost = 100, unlockRank = 1, appeal = 1,
	  flat = true, layer = 2, size = V(4, 0.2, 8), model = "RedCarpet", icon = "path", tone = "Red" },
	{ id = "marble_tile", name = "Marble Floor", category = "floors", cost = 250, unlockRank = 1, appeal = 1,
	  flat = true, layer = 1, size = V(4, 0.1, 4), model = "MarbleTile", icon = "path", tone = "Blue" },
	{ id = "checker_tile", name = "Checker Floor", category = "floors", cost = 600, unlockRank = 2, appeal = 1,
	  flat = true, layer = 1, size = V(4, 0.1, 4), model = "CheckerTile", icon = "path", tone = "Purple" },
	{ id = "royal_rug", name = "Royal Rug", category = "floors", cost = 4000, unlockRank = 3, appeal = 2,
	  flat = true, layer = 3, size = V(6, 0.3, 6), model = "RoyalRug", icon = "path", tone = "Purple" },
	{ id = "neon_walkway", name = "Neon Walkway", category = "floors", cost = 20_000, unlockRank = 5, appeal = 3,
	  flat = true, layer = 2, size = V(3, 0.2, 8), model = "NeonWalkway", icon = "path", tone = "Pink" },
	{ id = "fame_star", name = "Walk of Fame Star", category = "floors", cost = 150_000, unlockRank = 7, appeal = 4,
	  flat = true, layer = 2, size = V(4, 0.2, 4), model = "FameStar", icon = "path", tone = "Red" },
	-- LIGHTS
	{ id = "deco_lamp", name = "Deco Lamp", category = "lights", cost = 500, unlockRank = 2, appeal = 1,
	  size = V(1.6, 5.3, 1.6), model = "DecoLamp", icon = "lamp", tone = "Orange" },
	{ id = "neon_star", name = "Neon Star", category = "lights", cost = 15_000, unlockRank = 4, appeal = 3,
	  size = V(2.8, 5.4, 2.8), model = "NeonStar", icon = "lamp", tone = "Pink" },
	{ id = "spotlight", name = "Hollywood Spotlight", category = "lights", cost = 400_000, unlockRank = 8, appeal = 5,
	  size = V(3.0, 4.2, 3.2), model = "Searchlight", icon = "lamp", tone = "Gold" },
	-- LOUNGE
	{ id = "velvet_rope", name = "Velvet Rope", category = "lounge", cost = 200, unlockRank = 1, appeal = 1,
	  size = V(4.2, 2.5, 0.8), model = "VelvetRope", icon = "crown", tone = "Red" },
	{ id = "velvet_bench", name = "Velvet Bench", category = "lounge", cost = 1500, unlockRank = 2, appeal = 2,
	  size = V(4.4, 1.7, 1.6), model = "VelvetBench", icon = "crown", tone = "Red" },
	{ id = "cocktail_table", name = "Cocktail Table", category = "lounge", cost = 6000, unlockRank = 3, appeal = 2,
	  size = V(2.4, 3.7, 2.4), model = "CocktailTable", icon = "crown", tone = "Blue" },
	{ id = "lounge_sofa", name = "VIP Lounge Sofa", category = "lounge", cost = 60_000, unlockRank = 6, appeal = 4,
	  size = V(6.0, 2.6, 2.6), model = "LoungeSofa", icon = "crown", tone = "Purple" },
	-- SHOWPIECES
	{ id = "giant_dice", name = "Giant Dice", category = "showpieces", cost = 8000, unlockRank = 4, appeal = 3,
	  size = V(3.0, 4.2, 3.0), model = "GiantDice", icon = "statue", tone = "Red" },
	{ id = "balloon_arch", name = "Balloon Arch", category = "showpieces", cost = 30_000, unlockRank = 5, appeal = 3,
	  size = V(7.8, 7.0, 1.6), model = "BalloonArch", icon = "gift", tone = "Pink" },
	{ id = "mini_fountain", name = "Mini Fountain", category = "showpieces", cost = 40_000, unlockRank = 5, appeal = 4,
	  size = V(5.0, 4.4, 5.0), model = "MiniFountain", icon = "statue", tone = "Blue" },
	{ id = "golden_lion", name = "Golden Lion", category = "showpieces", cost = 1_500_000, unlockRank = 9, appeal = 6,
	  size = V(3.0, 5.0, 4.4), model = "GoldenLion", icon = "statue", tone = "Gold" },
	-- GOLDEN (rebirth rewards)
	{ id = "golden_palm", name = "Golden Palm", category = "golden", cost = 25_000, unlockRank = 1, rebirth = 1, appeal = 4,
	  size = V(4.0, 6.4, 4.0), model = "GoldenPalm", icon = "plant", tone = "Gold" },
	{ id = "golden_walkway", name = "Golden Walkway", category = "golden", cost = 40_000, unlockRank = 1, rebirth = 2,
	  appeal = 3, flat = true, layer = 2, size = V(4, 0.2, 8), model = "GoldenWalkway", icon = "path", tone = "Gold" },
	{ id = "golden_seven", name = "Golden 7", category = "golden", cost = 250_000, unlockRank = 1, rebirth = 3, appeal = 6,
	  size = V(3.0, 6.6, 2.2), model = "GoldenSeven", icon = "statue", tone = "Gold" },
	{ id = "mega_diamond", name = "Mega Diamond", category = "golden", cost = 2_500_000, unlockRank = 1, rebirth = 5,
	  appeal = 8, size = V(3.2, 5.9, 3.2), model = "MegaDiamond", icon = "gem", tone = "Gold" },
} :: {DecorDef}

-- id -> def (built on first use; the list never changes at runtime)
local decorIndex: {[string]: DecorDef}? = nil
function Config.getDecorDef(id: any): DecorDef?
	if type(id) ~= "string" then return nil end
	if not decorIndex then
		local idx = {}
		for _, def in Config.Decor do idx[def.id] = def end
		decorIndex = idx
	end
	return (decorIndex :: any)[id]
end

-- one piece's price after the owner's priceDiscount effect (0..0.6; snapshot
-- field `priceDiscount` on the client). Decor has no per-copy price growth.
function Config.decorPrice(def: any, discount: number?): number
	if not def then return 0 end
	local d = math.clamp(tonumber(discount) or 0, 0, 0.6)
	return math.floor((def.cost or 0) * (1 - d))
end

-- the guest bonus (spawnBonus) that `points` of appeal give
function Config.decorAppealBonus(points: number?): number
	local a = Config.DecorAppeal
	local v = math.max(0, tonumber(points) or 0) * (a.PerPoint or 0.01)
	return math.min(v, a.MaxBonus or 0.15)
end

------------------------------------------------------------------
-- REBIRTH (PROGRESSION: CasinoServer/Rebirth.luau, client RebirthUI.luau)
-- Money based: the n-th rebirth needs Rebirth.cost(n) Cash ON HAND. It pays
-- Rebirth.coins(n, cash) rebirth coins (+ the rebirthCoinBonus effect, x (1 +
-- rebirthCoinMult): the 2x Rebirth Coins pass) for the REBIRTH SHOP below, and
-- unlocks the catalog / decor items with `rebirth = n`.
-- RESETS: Cash (to max(StartingCash, the startCash effect)), every machine and
-- stand (placed + stored; x3 boost time on them is kept as stored boost time),
-- the 17 upgrade tracks, the floors (back to 1; decor up there goes back to your
-- items) and the staff. KEEPS: Casino Rank + XP, decor, rebirth coins + rebirth
-- upgrades, everything bought with Robux (passes, potions, stored boost time),
-- Tickets, stats, the casino's name + colours, daily + playtime progress.
-- Pacing (econ sim, scratchpad/research/xp_rebirth_calibration.md): a player who
-- saves for it makes the 1st rebirth after ~4 h of active play (around Rank 7),
-- the 2nd run takes ~3 h, the 3rd ~2 h 25, then ~2 h 15 - 2 h 30 a run, slowly
-- longer. Rebirths 1-6 are simulated with the rebirth-machine perks (6 careers);
-- 7-20 follow the curve (x1.3 a rebirth while new rebirth machines unlock, to 12,
-- then x1.2). Coins 4, 6, 8 ... a rebirth (+ Coin Magnet, + the weekly quest's
-- coin): the whole shop after ~16 rebirths.
------------------------------------------------------------------
local REBIRTH_COSTS: {number} = {
	50_000_000, 300_000_000, 750_000_000, 800_000_000, 1_000_000_000,
	1_300_000_000, 1_700_000_000, 2_200_000_000, 2_900_000_000, 3_700_000_000,
	4_800_000_000, 6_300_000_000, 7_500_000_000, 9_000_000_000, 10_000_000_000,
	12_000_000_000, 15_000_000_000, 17_000_000_000, 20_000_000_000, 25_000_000_000,
}
local REBIRTH_LATE_GROWTH = 1.15          -- past the table: each rebirth costs this much more
local REBIRTH_COIN_BASE = 4               -- coins of rebirth n: CoinBase + CoinStep x (n - 1) ...
local REBIRTH_COIN_STEP = 2
local REBIRTH_OVERFLOW_EXP = 1 / 3        -- ... x (Cash on hand / cost)^OverflowExponent, at most
local REBIRTH_OVERFLOW_CAP = 2            -- x OverflowCap: more Cash than it needs pays a few extra coins

-- the Cash on hand the n-th rebirth needs
local function rebirthCost(n: number): number
	local i = math.max(1, math.floor(tonumber(n) or 1))
	local last = #REBIRTH_COSTS
	if i <= last then return REBIRTH_COSTS[i] end
	return math.floor(REBIRTH_COSTS[last] * REBIRTH_LATE_GROWTH ^ (i - last))
end

-- the base rebirth coins of the n-th rebirth made with `cash` on hand (before the
-- coin effects); at least the base, at most OverflowCap x the base
local function rebirthCoins(n: number, cash: number?): number
	local i = math.max(1, math.floor(tonumber(n) or 1))
	local base = REBIRTH_COIN_BASE + REBIRTH_COIN_STEP * (i - 1)
	local ratio = math.max(1, (tonumber(cash) or 0) / math.max(1, rebirthCost(i)))
	return math.floor(base * math.min(REBIRTH_OVERFLOW_CAP, ratio ^ REBIRTH_OVERFLOW_EXP) + 1e-9)
end

Config.Rebirth = {
	Costs = REBIRTH_COSTS,
	LateGrowth = REBIRTH_LATE_GROWTH,
	CoinBase = REBIRTH_COIN_BASE,
	CoinStep = REBIRTH_COIN_STEP,
	OverflowExponent = REBIRTH_OVERFLOW_EXP,
	OverflowCap = REBIRTH_OVERFLOW_CAP,
	cost = rebirthCost,
	coins = rebirthCoins,
}

------------------------------------------------------------------
-- REBIRTH UPGRADES (the REBIRTH SHOP: Rebirth.luau, RebirthUI.luau)
-- Permanent: bought with rebirth coins, never reset. values[L] is the TOTAL
-- effect at level L (the "rebirth" effect provider adds it to its effect key, on
-- top of the tracks, staff, potions and passes); costs[L] = the coins level L
-- costs. `format`: "%%" in it shows the value as a percentage; money = true
-- shows it as Cash. Effect keys: cashMult (positive game results x (1 + v)),
-- xpMult, startCash (Cash after a rebirth), spawnBonus, walletMult, patronSpeed,
-- nightBonus, offlineBonus, priceDiscount (machines + decor; all discounts
-- together at most 60%), potionTime, rebirthCoinBonus (+ coins per rebirth),
-- vipChance (no tiltBonus here: the guest tilt is already at 0.80 of its 0.85 cap
-- with every other source maxed). The whole shop: 340 coins, ~16 rebirths.
------------------------------------------------------------------
export type RebirthUpgrade = {
	id: string, name: string, desc: string, icon: string, tone: string, effect: string,
	values: {number}, costs: {number}, format: string, money: boolean?,
}

Config.RebirthUpgrades = {
	{ id = "goldenTouch", name = "Golden Touch", icon = "cash", tone = "Gold", effect = "cashMult",
	  desc = "Every game in your casino pays you more Cash.", format = "+%d%% Cash",
	  values = { 0.1, 0.2, 0.35, 0.5, 0.75 }, costs = { 2, 4, 7, 11, 16 } },
	{ id = "headStart", name = "Head Start", icon = "coin", tone = "Green", effect = "startCash",
	  desc = "Start every rebirth with more Cash.", format = "Start with %s", money = true,
	  values = { 10_000, 100_000, 1_000_000, 10_000_000 }, costs = { 2, 5, 9, 14 } },
	{ id = "fastLearner", name = "Fast Learner", icon = "xp", tone = "Blue", effect = "xpMult",
	  desc = "Earn Casino XP faster and rank up sooner.", format = "+%d%% XP",
	  values = { 0.1, 0.2, 0.3, 0.4, 0.5 }, costs = { 2, 4, 7, 11, 16 } },
	{ id = "deepPockets", name = "Deep Pockets", icon = "gem", tone = "Pink", effect = "walletMult",
	  desc = "Guests walk in with fatter wallets.", format = "+%d%% wallets",
	  values = { 0.1, 0.2, 0.3, 0.45, 0.6 }, costs = { 2, 4, 7, 11, 16 } },
	{ id = "crowdPleaser", name = "Crowd Pleaser", icon = "staff", tone = "Orange", effect = "spawnBonus",
	  desc = "More guests want to visit your casino.", format = "+%d%% guests",
	  values = { 0.1, 0.2, 0.3, 0.4, 0.5 }, costs = { 2, 4, 7, 11, 16 } },
	{ id = "coinMagnet", name = "Coin Magnet", icon = "rcoin", tone = "Gold", effect = "rebirthCoinBonus",
	  desc = "Extra rebirth coins every time you rebirth.", format = "+%d coins a rebirth",
	  values = { 1, 2, 3 }, costs = { 3, 7, 12 } },
	{ id = "bargainHunter", name = "Bargain Hunter", icon = "shop", tone = "Red", effect = "priceDiscount",
	  desc = "Machines, stands and decor cost less.", format = "-%d%% prices",
	  values = { 0.05, 0.1, 0.15, 0.2 }, costs = { 3, 6, 10, 15 } },
	{ id = "quickFeet", name = "Quick Feet", icon = "upgrade", tone = "Blue", effect = "patronSpeed",
	  desc = "Guests walk faster and squeeze in extra rounds.", format = "+%d%% walk speed",
	  values = { 0.1, 0.2, 0.3 }, costs = { 3, 6, 10 } },
	{ id = "highSociety", name = "High Society", icon = "crown", tone = "Purple", effect = "vipChance",
	  desc = "More VIP big spenders walk in.", format = "+%d%% VIP guests",
	  values = { 0.02, 0.04, 0.06 }, costs = { 3, 6, 10 } },
	{ id = "nightOwl", name = "Night Owl", icon = "star", tone = "Purple", effect = "nightBonus",
	  desc = "Even more guests during the night rush.", format = "+%d%% at night",
	  values = { 0.1, 0.2, 0.3 }, costs = { 2, 5, 9 } },
	{ id = "offlineTycoon", name = "Offline Tycoon", icon = "stats", tone = "Green", effect = "offlineBonus",
	  desc = "Earn more while you're away.", format = "+%d%% offline income",
	  values = { 0.25, 0.5, 0.75, 1 }, costs = { 2, 4, 7, 11 } },
	{ id = "potionMaster", name = "Potion Master", icon = "potion_mega", tone = "Pink", effect = "potionTime",
	  desc = "Every potion you use lasts longer.", format = "+%d%% potion time",
	  values = { 0.1, 0.25, 0.5 }, costs = { 2, 5, 9 } },
} :: {RebirthUpgrade}

function Config.getRebirthUpgrade(id: string): RebirthUpgrade?
	for _, def in Config.RebirthUpgrades do
		if def.id == id then return def end
	end
	return nil
end

------------------------------------------------------------------
-- QUESTS (QUESTS: CasinoServer/Quests.luau, client QuestsUI.luau)
-- 3 daily quests (a new set at 00:00 UTC) + 1 weekly quest (a new one on Monday
-- 00:00 UTC), drawn from the pools below. Progress is server-side (GameEvents) and
-- saved in profile.Quests. CLAIM (remote ClaimQuest) pays `reward` through
-- Rewards.grant (tickets, cash + minutes = max(cash, minutes x income rate), potion,
-- boostMinutes, rcoins); a finished quest still unclaimed when its day / week ends
-- is paid out then. The weekly quests all pay WeeklyReward.
-- Targets:
--   pace kinds (games = W-weighted rounds hosted, xp, cash): `minutes` of the owner's
--     own pace x a random 1 +- Jitter (at least `min`), rounded to 2 significant
--     digits. Pace: games / XP per online minute measured by Quests (an EMA in
--     profile.Quests.pace) once it has PaceMinMinutes, else BaselineShare x the row of
--     their Casino Rank in PaceGames / PaceXP (econ sim, engaged player); cash =
--     Stats.IncomeRate, else BaselineShare x PaceCash[rank]. Weekly quests take at
--     least the row WeeklyRankAhead ranks further on (a casino grows during a week),
--     and one dealt mid-week asks for the share of the week left (>= WeeklyMinShare).
--     A rebirth rescales the open pace quests to the RebirthPaceRank row (the bar
--     keeps its fill) and restarts the measurement.
--   count kinds: count[rank] (the last entry past its end), capped by what the player
--     can still do (machine levels, upgrade levels and staff left to buy, playtime
--     rewards left today). `one` = the title for a target of 1.
-- A daily set takes one quest of each DailyGroups group (an empty group lends its slot
-- to the others), never two of one kind. A quest is only picked when the player can do
-- it: `need` = the server module it needs, `minRank` = the Casino Rank (cheaters also
-- wait for Config.Cheaters.MinRank), and what's left to do (see count kinds).
-- Rerolls: FreeRerolls a day (dailies), then RerollTickets + RerollStep x the paid
-- rerolls already made that day; the weekly costs WeeklyRerollTickets.
-- Studio: ServerStorage attribute CasinoTestQuests = 0.02 scales new targets (tests);
-- CasinoTestQuestsRedeal = true deals everyone a fresh set (it clears itself).
------------------------------------------------------------------
Config.Quests = {
	DailyGroups = { "core", "build", "fun" },
	FreeRerolls = 1,
	RerollTickets = 20,
	RerollStep = 10,
	WeeklyRerollTickets = 60,
	Jitter = 0.15,
	PaceMinMinutes = 5,          -- measured minutes before the own pace replaces the rank table
	PaceAlpha = 0.06,            -- EMA per online minute (~a day/night cycle of smoothing)
	BaselineShare = 0.75,        -- the rank tables are an engaged player's pace: ask a bit less
	RebirthPaceRank = 3,
	WeeklyRankAhead = 1,
	WeeklyMinShare = 0.4,        -- a weekly dealt mid-week asks for the days left (at least this share)
	-- per online minute while at Rank r (scratchpad/quests/pace_table.py, 4 seeds)
	PaceGames = { 46, 260, 420, 640, 940, 1600, 2000, 3100, 3800, 5600, 5600, 6000 },
	PaceXP = { 46, 270, 490, 820, 1300, 3100, 4600, 8200, 12_500, 22_000, 34_000, 41_000 },
	PaceCash = { 330, 2000, 8200, 33_000, 90_000, 260_000, 640_000, 1_600_000, 3_700_000, 10_000_000,
		18_000_000, 38_000_000 },
	Daily = {
		-- core: ~20 minutes of normal play
		{ id = "host", kind = "games", group = "core", weight = 3, minutes = 20, min = 60,
		  title = "Host %s games", desc = "Every round a guest plays at your machines counts.",
		  icon = "chips", tone = "Red", reward = { tickets = 25, cash = 500, minutes = 6 } },
		{ id = "earn", kind = "cash", group = "core", weight = 3, minutes = 20, min = 1000,
		  title = "Earn %s", desc = "Cash from your games, stands and tips.",
		  icon = "cash", tone = "Green", reward = { tickets = 25, potion = "cash" } },
		{ id = "xp", kind = "xp", group = "core", weight = 3, minutes = 20, min = 50,
		  title = "Earn %s XP", desc = "Better machines give more XP for every game.",
		  icon = "xp", tone = "Blue", reward = { tickets = 25, potion = "xp" } },
		-- build: spend on your casino
		{ id = "tuneup", kind = "upgradeMachine", group = "build", weight = 3, count = { 3, 3, 3, 4, 4, 4, 5 },
		  title = "Upgrade machines %s times", one = "Upgrade a machine",
		  desc = "Speed, bets or luck: any level on any machine.",
		  icon = "wrench", tone = "Orange", reward = { tickets = 15, cash = 500, minutes = 5 } },
		{ id = "invest", kind = "upgradeTrack", group = "build", weight = 2, count = { 1, 1, 2 },
		  title = "Buy %s upgrade levels", one = "Buy an upgrade level", desc = "Any level in the UPGRADE menu.",
		  icon = "upgrade", tone = "Pink", reward = { tickets = 15, cash = 500, minutes = 5 } },
		{ id = "staff", kind = "staff", group = "build", weight = 2, count = { 1 }, need = "Staff",
		  title = "Hire or promote %s staff", one = "Hire or promote staff", desc = "Find your team in SHOP > STAFF.",
		  icon = "staff", tone = "Purple", reward = { tickets = 15, potion = "speed" } },
		{ id = "decor", kind = "decor", group = "build", weight = 2, count = { 3, 3, 3, 3, 4 }, need = "Decor",
		  title = "Place %s decor pieces", one = "Place a decor piece",
		  desc = "Plants, floors and lights bring more guests.",
		  icon = "plant", tone = "Green", reward = { tickets = 15, potion = "crowd" } },
		{ id = "shopping", kind = "buyMachine", group = "build", weight = 2, count = { 2 },
		  title = "Buy %s machines", one = "Buy a machine", desc = "From the SHOP or the Showroom.",
		  icon = "shop", tone = "Gold", reward = { tickets = 15, boostMinutes = 10 } },
		-- fun: the casino's extras
		{ id = "cheaters", kind = "cheaters", group = "fun", weight = 3, count = { 2, 2, 2, 2, 2, 3 }, minRank = 2,
		  need = "Cheaters", title = "Bust %s cheaters", one = "Bust a cheater",
		  desc = "Kick them out yourself or let Security catch them.",
		  icon = "cheater", tone = "Red", reward = { tickets = 25, potion = "lucky" } },
		{ id = "wheel", kind = "wheel", group = "fun", weight = 2, count = { 1 }, need = "LuckyWheel",
		  title = "Spin the Lucky Wheel %s times", one = "Spin the Lucky Wheel", desc = "A free spin every few hours.",
		  icon = "wheel", tone = "Gold", reward = { tickets = 15, cash = 500, minutes = 5 } },
		{ id = "potion", kind = "potion", group = "fun", weight = 1, count = { 1 }, need = "Potions",
		  title = "Use %s potions", one = "Use a potion", desc = "Pick one from your POTIONS.",
		  icon = "potion_mega", tone = "Pink", reward = { tickets = 20, boostMinutes = 10 } },
		{ id = "playtime", kind = "playtime", group = "fun", weight = 2, count = { 3 }, need = "Playtime",
		  title = "Claim %s playtime rewards", one = "Claim a playtime reward",
		  desc = "They unlock as you play today.",
		  icon = "playtime", tone = "Blue", reward = { tickets = 15, boostMinutes = 10 } },
		{ id = "events", kind = "events", group = "fun", weight = 2, count = { 2 }, need = "Events",
		  title = "Join %s casino events", one = "Join a casino event",
		  desc = "Be online when one starts - about every 15 minutes.",
		  icon = "megaphone", tone = "Orange", reward = { tickets = 15, cash = 500, minutes = 5 } },
	},
	Weekly = {
		{ id = "w_host", kind = "games", weight = 3, minutes = 120, min = 500,
		  title = "Host %s games", desc = "Every game at your casino this week counts.", icon = "chips", tone = "Red" },
		{ id = "w_xp", kind = "xp", weight = 3, minutes = 120, min = 400,
		  title = "Earn %s XP", desc = "Every game your guests play this week counts.", icon = "xp", tone = "Blue" },
		{ id = "w_earn", kind = "cash", weight = 2, minutes = 120, min = 8000,
		  title = "Earn %s", desc = "Everything your casino earns this week counts.", icon = "cash", tone = "Green" },
		{ id = "w_dailies", kind = "dailies", weight = 3, count = { 10 },
		  title = "Complete %s daily quests", one = "Complete a daily quest",
		  desc = "Claim daily quests on any day this week.", icon = "quests", tone = "Purple" },
		{ id = "w_cheaters", kind = "cheaters", weight = 2, count = { 12 }, minRank = 2, need = "Cheaters",
		  title = "Bust %s cheaters", one = "Bust a cheater", desc = "Kicked out by you or caught by Security.",
		  icon = "cheater", tone = "Red" },
	},
	WeeklyReward = { rcoins = 1, potion = "mega", tickets = 100 },
}

------------------------------------------------------------------
-- LUCKY WHEEL (WHEEL & EVENTS: CasinoServer/LuckyWheel.luau, client WheelUI.luau)
-- One FREE spin every FreeCooldownHours (the clock starts when you use it, so free
-- spins never pile up; a new player's first spin is free at once). More spins cost
-- TicketCost Tickets or use an owned bonus spin (profile.Wheel.spins: the Robux
-- product `wheel_spins` in Monetization.Products, rewards through LuckyWheel.give).
-- The SERVER picks the segment by `weight` and pays it RevealSeconds later, when
-- the client's wheel stops on it. The wheel panel lists every chance (paid random
-- items must show their odds) and hides the Robux offer from players whose
-- PolicyService says paid random items are restricted (e.g. the Netherlands).
-- Segments, clockwise from the top: `reward` = a Rewards.grant table (cash + minutes
-- = max(cash, minutes x the owner's income rate), tickets, potion, boostMinutes =
-- stored x3 machine boost, rcoins); `tone` = the slice colour (UILib tone), `icon` +
-- `short` = what the slice shows; `jackpot` = the server-wide shout + banner.
-- Value of one spin (potions at their Ticket Shop price, 1 Ticket ~ 0.25 min of
-- income): ~7.7 min of income on average, ~4.4 Tickets of it back as Tickets. A
-- Ticket spin (35 Tickets ~ 8.75 min) returns ~88%: a small house edge, so Tickets
-- never loop into more spins. ~2-3 free spins a day for an active player.
------------------------------------------------------------------
Config.LuckyWheel = {
	FreeCooldownHours = 4,
	TicketCost = 35,
	RevealSeconds = 5.5,       -- the prize lands this long after the spin (the client's wheel animation)
	MinSpinGap = 1,            -- seconds between two spin requests of one player
	MaxBonusSpins = 999,
	Segments = {
		{ id = "jackpot", name = "MEGA JACKPOT", short = "JACKPOT", icon = "slot", tone = "Black", weight = 0.5,
		  jackpot = true, reward = { cash = 10_000, minutes = 60, potion = "mega", tickets = 100 } },
		{ id = "cash_s", name = "Cash", short = "CASH", icon = "coin", tone = "Red", weight = 25,
		  reward = { cash = 250, minutes = 3 } },
		{ id = "speed", name = "Speed Potion", short = "SPEED", icon = "potion_speed", tone = "Blue", weight = 7,
		  reward = { potion = "speed" } },
		{ id = "tickets_s", name = "10 Tickets", short = "10", icon = "ticket", tone = "Green", weight = 19,
		  reward = { tickets = 10 } },
		{ id = "rcoin", name = "Rebirth Coin", short = "+1", icon = "rcoin", tone = "Orange", weight = 1.5,
		  reward = { rcoins = 1 } },
		{ id = "lucky", name = "Lucky Potion", short = "LUCKY", icon = "potion_lucky", tone = "Purple", weight = 7,
		  reward = { potion = "lucky" } },
		{ id = "cash_m", name = "Big Cash", short = "CASH", icon = "cash", tone = "Pink", weight = 12,
		  reward = { cash = 750, minutes = 8 } },
		{ id = "boost", name = "x3 Machine Boost", short = "15 MIN", icon = "boost", tone = "Blue", weight = 8,
		  reward = { boostMinutes = 15 } },
		{ id = "xp", name = "XP Potion", short = "2X XP", icon = "potion_xp", tone = "Orange", weight = 3.5,
		  reward = { potion = "xp" } },
		{ id = "tickets_m", name = "25 Tickets", short = "25", icon = "ticket", tone = "Green", weight = 8,
		  reward = { tickets = 25 } },
		{ id = "cashpotion", name = "Cash Potion", short = "2X CASH", icon = "potion_cash", tone = "Purple", weight = 3.5,
		  reward = { potion = "cash" } },
		{ id = "crowd", name = "Crowd Potion", short = "CROWD", icon = "potion_crowd", tone = "Gold", weight = 5,
		  reward = { potion = "crowd" } },
	},
}

-- a wheel segment by id (nil if none)
function Config.getWheelSegment(id: string)
	for _, seg in Config.LuckyWheel.Segments do
		if seg.id == id then return seg end
	end
	return nil
end

------------------------------------------------------------------
-- CASINO EVENTS (WHEEL & EVENTS: CasinoServer/Events.luau, client EventsUI.luau)
-- Server-wide: one random event (never the same twice in a row) every Interval
-- seconds (start to start; the first one FirstDelay after the server starts, never
-- sooner than MinGap after the last one ended) for `duration` seconds. Everyone gets
-- a heads-up WarningSeconds before, a big banner at the start, a HUD chip with the
-- time left and an EVENT OVER toast. While it runs its `effects` add to every
-- casino through the Upgrades provider "events" (existing keys: vipChance, xpMult,
-- concessionBonus, spawnBonus). CHEATER RAID has no effect keys: the Cheaters module
-- asks Events.isActive("cheaterRaid") / Events.value("cheaterMult", 1) (more
-- cheaters) / Events.value("kickMult", 1) (kick rewards); `requires` = an optional
-- server module the event needs (no Cheaters module = no raids). No players = no
-- events (the clock waits). Pacing: ~3 min of event every ~16 min; each kind about
-- once every 80 min, e.g. BUS TOUR's +50% guests averages out to ~+2% guests.
-- Studio test: ServerStorage attribute CasinoTestEvent = "<id>" | "random" starts
-- that event at once and again TestGap seconds after each one ends while it stays
-- set; CasinoTestEventSeconds = n makes the forced events last n seconds.
------------------------------------------------------------------
Config.Events = {
	FirstDelay = { 4 * 60, 7 * 60 },     -- the server's first event
	Interval = { 12 * 60, 20 * 60 },     -- start to start
	MinGap = 5 * 60,                     -- at least this long from one event's end to the next start
	WarningSeconds = 20,                 -- the "incoming" heads-up
	TestGap = 20,                        -- Studio CasinoTestEvent: seconds between forced events
	List = {
		{ id = "vipRush", name = "VIP RUSH", short = "VIP RUSH", icon = "crown", tone = "Purple", style = "purple",
		  desc = "High rollers hit the Strip: +15% VIP guests in every casino!",
		  weight = 1, duration = { 150, 240 }, effects = { vipChance = 0.15 } },
		{ id = "cheaterRaid", name = "CHEATER RAID", short = "RAID", icon = "cheater", tone = "Red", style = "crimson",
		  desc = "Cheaters everywhere! Kick them out for DOUBLE rewards.",
		  weight = 1, duration = { 120, 180 }, effects = {}, requires = "Cheaters", cheaterMult = 3, kickMult = 2 },
		{ id = "jackpotHour", name = "JACKPOT HOUR", short = "JACKPOT", icon = "xp", tone = "Gold", style = "gold",
		  desc = "+50% XP from every game in town!",
		  weight = 1, duration = { 150, 240 }, effects = { xpMult = 0.5 } },
		{ id = "happyHour", name = "HAPPY HOUR", short = "HAPPY HR", icon = "popcorn", tone = "Green", style = "green",
		  desc = "Snacks & drinks fly off the shelves: stands sell 2x!",
		  weight = 1, duration = { 150, 240 }, effects = { concessionBonus = 1 } },
		{ id = "busTour", name = "BUS TOUR", short = "BUS TOUR", icon = "staff", tone = "Blue", style = "blue",
		  desc = "A tour bus just pulled up: +50% guests for every casino!",
		  weight = 1, duration = { 150, 240 }, effects = { spawnBonus = 0.5 } },
	},
}

-- an event definition by id (nil if none)
function Config.getEvent(id: string)
	for _, def in Config.Events.List do
		if def.id == id then return def end
	end
	return nil
end

------------------------------------------------------------------
-- CHEATERS (GUESTS: CasinoServer/Cheaters.luau, the cheater parts of NPCs.luau and
-- Gambling.npcPlay; client CheatersUI.luau + GuestTags.luau)
-- From Casino Rank MinRank on, Chance of the arriving guests (never VIPs) cheat (x
-- SecurityChanceMult[level] with Security hired; x the CHEATER RAID event's
-- cheaterMult), one per MinGapSeconds per casino, at most MaxPerCasino inside at once.
-- A cheater ignores the house tilt and re-rolls WinBoost[type] of their losing rounds
-- until they win (a real outcome, so the machine shows it): every game then pays a
-- cheater ~1.35x the bet (honest guests get back 0.58-0.73x; scratchpad
-- cheaters/cheat_math.py). They bet BetFraction of their wallet (honest guests 2-6%),
-- work at least Machines machines with ExtraRounds more rounds each at their own pace
-- (ThinkDelay: speed upgrades don't hurry them), every round counts min(W, MaxWeight)
-- times (W = the guest weight), and they leave with the loot once they took
-- MaxTakeMinutes of your income. Tells: their wallet tag grows; after SuspectWins wins,
-- a SuspectGain share up or one SuspectBigWin x win they get a red "?" and you get ONE
-- alert. KICK OUT (hold, owner only, a guest inside your casino): a cheater pays back
-- max(KickReturn x what they took, KickMinMinutes of income, KickMinCash x clientele)
-- + bonus XP (KickXPGames games on their machine, x min(W, MaxWeight)); an honest guest
-- just walks off (their spending goes with them). Security level L catches a cheater
-- CatchSeconds[L] after their first round and walks them out: max(SecurityReturn x the
-- take, SecurityMinMinutes of income, SecurityMinCash x clientele). A raid doubles
-- every reward (the event's kickMult).
------------------------------------------------------------------
Config.Cheaters = {
	Enabled = true,
	MinRank = 2,                       -- no cheaters before this Casino Rank
	Chance = 0.05,                     -- share of the arriving guests who cheat (VIPs never do)
	SecurityChanceMult = { 0.85, 0.7, 0.55 },  -- x the chance with Security level 1 / 2 / 3
	MinGapSeconds = 150,               -- at least this long between two cheaters coming to one casino
	MaxPerCasino = 1,                  -- cheaters inside one casino at once
	-- how they play (NPCs.runPatron + Gambling.npcPlay)
	BetFractionMin = 0.06,             -- share of the wallet per bet (honest guests 0.02-0.06)
	BetFractionMax = 0.12,
	Machines = 3,                      -- machines a cheater works per visit (at least)
	ExtraRounds = 5,                   -- + rounds per machine (honest guests 3-7)
	ThinkDelayMin = 1.2,               -- seconds between their rounds (no speed upgrades):
	ThinkDelayMax = 2.0,               -- ~1 min of cheating per visit
	WinBoost = { Slots = 0.15, Wheel = 0.15, Plinko = 0.26, Dice = 0.3, Roulette = 0.37, Blackjack = 0.37,
		default = 0.3 },
	FlipTries = 40,                    -- re-rolls to find the win (Slots: 98% find one)
	MaxWeight = 8,                     -- their rounds count min(W, MaxWeight) times
	MaxTakeMinutes = 1.25,             -- they leave once they took this many minutes of your income ...
	MaxTakeCash = 600,                 -- ... (at least this x your clientele)
	-- tells (the red "?" + ONE CheaterAlert to the owner)
	SuspectWins = 3,
	SuspectGain = 0.25,                -- wallet up this share since their first round
	SuspectBigWin = 8,                 -- one win paying this many x the bet
	SuspectMinRounds = 2,
	-- KICK OUT (the owner; client prompt, the server checks owner / casino / distance)
	KickHoldSeconds = 0.6,
	KickPromptDistance = 10,           -- the prompt's reach (studs)
	KickServerDistance = 22,           -- the server's check (lag slack)
	KickCooldown = 0.4,
	KickReturn = 2,                    -- a kicked cheater's winnings come back x this ...
	KickMinMinutes = 0.5,              -- ... at least this many minutes of your income ...
	KickMinCash = 150,                 -- ... and this x your clientele
	KickXPGames = 30,                  -- bonus XP: this many games on their machine
	RunSpeed = 24,                     -- a busted cheater runs for it
	HonestLeaveSpeed = 14,             -- an honest guest stomps off
	-- Security (staff "security", levels 1-3) catches them by itself
	CatchSeconds = { 40, 22, 10 },     -- after this long cheating (from their first round)
	SecurityReturn = 1,                -- their winnings come back x this ...
	SecurityMinMinutes = 0.2,          -- ... at least this many minutes of your income ...
	SecurityMinCash = 60,              -- ... and this x your clientele
	EscortDelay = 2.5,                 -- the guard walks over before the cheater is led out
	EscortSpeed = 9,
	-- the CHEATER RAID event (Events.isActive("cheaterRaid"); its cheaterMult / kickMult
	-- win, these are the fallbacks)
	RaidChanceMult = 3,
	RaidRewardMult = 2,
	RaidGapMult = 0.5,                 -- the gap between cheaters halves ...
	RaidExtraPerCasino = 1,            -- ... and one more may be inside at once
}

------------------------------------------------------------------
-- VIP FLOOR (VIP FLOOR: CasinoServer/VipFloor.luau, client VipFloorUI.luau)
-- Owning the VIP game pass (PassKey) adds a free "VIP LOUNGE" floor ON TOP of the
-- floors you bought: the building has bought + 1 stories (at most MaxStories + 1).
-- Buying a floor moves the lounge up a story (its machines + decor move along); a
-- rebirth keeps it on top (it comes down to story 2). Without the pass (or in a
-- Studio session without it) there is no lounge: whatever stood up there goes back
-- to your items. It adds Config.Building.MachinesPerStory machine slots, and its
-- machines carry the model attribute VipFloor = true: Gambling multiplies their
-- positive owner earnings by IncomeMult (stands earn as anywhere else).
-- Studio test: ServerStorage attribute CasinoTestPasses = "vip" (+ CasinoTestStore).
------------------------------------------------------------------
Config.VipFloor = {
	Enabled = true,          -- false: no lounge at all (the VIP pass keeps its other perks)
	PassKey = "vip",         -- the game pass (Config.Monetization.Gamepasses key) that opens it
	IncomeMult = 1.25,       -- x the positive owner earnings of every machine up there
	CheckSeconds = 1,        -- how soon a pass bought in-game opens the lounge
	WelcomeSeconds = 90,     -- the first-time welcome (Player attribute VipFloorWelcome) stays armed this long
}

return Config
