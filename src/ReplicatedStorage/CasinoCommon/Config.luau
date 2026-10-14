--!strict
-- Config.luau — one place to tune the whole game.

local Config = {}

------------------------------------------------------------------
-- ECONOMY
------------------------------------------------------------------
Config.CurrencyName = "Cash"
Config.StartingCash = 8000
Config.DataStoreName = "CasinoTycoon_v3"   -- bump to wipe all saves
Config.DataSchemaVersion = 3
Config.AutosaveInterval = 120              -- seconds between background saves

------------------------------------------------------------------
-- HOUSE / BANKROLL MODEL
------------------------------------------------------------------
-- Owner Cash IS the bankroll. Visitor loss -> into owner Cash; visitor win ->
-- out of owner Cash. A machine only accepts a bet it can fully cover
-- (bet * maxMultiplier). Owner Cash floored at 0.
Config.OwnerIsBankroll = true

------------------------------------------------------------------
-- OFFLINE / DAILY INCOME (welcome-back popup)
------------------------------------------------------------------
Config.OfflineIncomePerMachinePerHour = 80   -- passive Cash each placed machine earns while away
Config.OfflineCapHours = 8                    -- max hours of offline income that accrue

------------------------------------------------------------------
-- PLOTS  (free placement)
------------------------------------------------------------------
Config.PlotCount = 6
Config.PlotSize = Vector3.new(70, 1, 70)
Config.PlotSpacing = 95
Config.PlacementMargin = 4
Config.MachineSpacing = 7
Config.MaxMachinesPerPlot = 14
Config.MaxInventory = 60

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
	MaxActive = 12,
	SpawnInterval = 3.5,
	-- Wallet a patron walks in with. Starts small; upgradable later via
	-- a future "marketing" / "VIP host" tier that bumps these numbers.
	WalletMin = 15,
	WalletMax = 200,
	-- legacy keys (unused now, kept so older configs don't break)
	StartingWalletMin = 15,
	StartingWalletMax = 200,
	RoundsPerMachineMin = 3,
	RoundsPerMachineMax = 7,
	MachinesPerVisitMin = 1,
	MachinesPerVisitMax = 3,
	BetFractionMin = 0.05,
	BetFractionMax = 0.20,
	WalkSpeed = 12,
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
	VIPBetFractionMin = 0.10,
	VIPBetFractionMax = 0.30,
	-- VIPs are rendered as the casino OWNER's real Roblox friends (avatar +
	-- floating username). Pulled live via Players:GetFriendsAsync(ownerId).
	VIPUseOwnerFriends = true,         -- false = VIPs use the random AVATAR_USER_IDS pool
	VIPShowFriendName = true,          -- float the friend's username above the head
	VIPRequireFriend = false,          -- true = no friend loaded -> patron isn't a VIP
	FriendCacheSeconds = 600,          -- re-pull an owner's friend list this often
	FriendFetchMax = 60,               -- cap how many friends we collect per owner
	-- Concession behavior: chance an arriving patron buys at a concession too.
	ConcessionVisitChance = 0.55,
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
-- MACHINE CATALOG (the shop)
-- type: "Slots" | "Roulette" | "Blackjack" | "Dice" | "Wheel"
------------------------------------------------------------------
export type MachineDef = {
	id: string, name: string, type: string,
	cost: number, minBet: number, maxBet: number,
	size: Vector3, color: Color3,
	kind: string?,                  -- "machine" (default) | "concession"
	revenuePerVisit: number?,       -- concessions only: paid to owner each NPC visit
}

Config.SellRefund = 0.5  -- fraction of cost returned when selling a machine

Config.Catalog = {
	{ id = "slots_basic",   name = "Lucky 7s Slots",   type = "Slots",     cost = 2000, minBet = 5,  maxBet = 75,  size = Vector3.new(4,6,3),  color = Color3.fromRGB(231, 76, 60), model = "Lucky7" },
	{ id = "slots_deluxe",  name = "Diamond Slots",     type = "Slots",     cost = 6000, minBet = 25, maxBet = 200, size = Vector3.new(4,6,3),  color = Color3.fromRGB(155, 89, 182) },
	{ id = "roulette_std",  name = "Roulette Table",    type = "Roulette",  cost = 4000, minBet = 10, maxBet = 60,  size = Vector3.new(8,3,5),  color = Color3.fromRGB(39, 174, 96) },
	{ id = "blackjack_std", name = "Blackjack Table",   type = "Blackjack", cost = 3500, minBet = 20, maxBet = 300, size = Vector3.new(8,3,5),  color = Color3.fromRGB(41, 128, 185) },
	{ id = "dice_std",      name = "Dice Game",         type = "Dice",      cost = 2500, minBet = 10, maxBet = 150, size = Vector3.new(4,4,3),  color = Color3.fromRGB(230, 126, 34) },
	{ id = "wheel_fortune", name = "Wheel of Fortune",  type = "Wheel",     cost = 3000, minBet = 15, maxBet = 80,  size = Vector3.new(5,7,3),  color = Color3.fromRGB(241, 196, 15) },

	-- CONCESSIONS — patrons buy snacks/drinks on visits; revenue flows to you.
	{ id = "snack_stand",    name = "Snack Stand",     type = "Snacks",    cost = 1500, minBet = 0, maxBet = 0, size = Vector3.new(5,4,3), color = Color3.fromRGB(244, 162, 97),  kind = "concession", revenuePerVisit = 18 },
	{ id = "drink_bar",      name = "Drink Bar",       type = "Drinks",    cost = 2500, minBet = 0, maxBet = 0, size = Vector3.new(6,4,3), color = Color3.fromRGB(45, 156, 219),  kind = "concession", revenuePerVisit = 28 },
	{ id = "souvenir_shop",  name = "Souvenir Cart",   type = "Souvenirs", cost = 3500, minBet = 0, maxBet = 0, size = Vector3.new(5,4,3), color = Color3.fromRGB(231, 76, 60),   kind = "concession", revenuePerVisit = 42 },
	{ id = "vending",        name = "Vending Machine", type = "Vending",   cost = 800,  minBet = 0, maxBet = 0, size = Vector3.new(3,5,2), color = Color3.fromRGB(155, 89, 182),  kind = "concession", revenuePerVisit = 9  },
} :: {MachineDef}

function Config.getMachineDef(id: string): MachineDef?
	for _, def in Config.Catalog do
		if def.id == id then return def end
	end
	return nil
end

function Config.isConcession(def): boolean
	return def and def.kind == "concession" or false
end

------------------------------------------------------------------
-- SHOWROOM (physical machine shop)
-- A room of pedestals — one per machine in the Catalog. Walk up to a display:
-- a floating card shows its stats + max win, and pressing E buys it into your
-- inventory (if you can afford it). Concessions & staff live at a Services desk.
------------------------------------------------------------------
Config.Showroom = {
	Center = Vector3.new(0, 0.5, 220),  -- placed clear of the plot pads
	Spacing = 14,                       -- studs between pedestals
	PedestalHeight = 2.4,
	RevealDistance = 14,                -- E-prompt activation distance
	CardDistance = 28,                  -- info-card render distance (shows up close)
}

-- Reel symbol images for the physical Lucky 7s machine (Spinny1/2/3 decals).
-- Add/replace IDs here; the display assigns them so matching result symbols get
-- matching images. Needs at least 3 distinct images.
Config.SlotReelImages = {
	"rbxassetid://47671241",
	"rbxassetid://47671036",
	"rbxassetid://47671152",
	"rbxassetid://47671141",
}

------------------------------------------------------------------
-- PER-MACHINE UPGRADES (3 tiers each, applied to a single placed machine)
--   speed  → patrons play faster (less ThinkDelay)
--   bets   → higher maxBet
--   lucky  → +5% extra house tilt vs. patrons (per level)
------------------------------------------------------------------
Config.MachineUpgradeMaxLevel = 3
Config.MachineUpgradeCosts = { 800, 2500, 7000 }   -- cost to go from L-1 -> L
Config.MachineUpgrades = {
	speed = { name = "Faster Spins",  desc = "Patrons play +25% faster.",
	          perLevel = 0.25 },
	bets  = { name = "Higher Limits", desc = "Max bet +50% per level.",
	          perLevel = 0.5 },
	lucky = { name = "Lucky Vibes",   desc = "+5% house tilt per level.",
	          perLevel = 0.05 },
}

------------------------------------------------------------------
-- STAFF
------------------------------------------------------------------
Config.Staff = {
	{ id = "pit_boss", name = "Pit Boss",  cost = 3000, houseEdgeBonus = 0.02 },
	{ id = "security", name = "Security",  cost = 2000, houseEdgeBonus = 0.01 },
	{ id = "host",     name = "VIP Host",  cost = 6000, houseEdgeBonus = 0.03 },
}

function Config.getStaffDef(id: string)
	for _, def in Config.Staff do
		if def.id == id then return def end
	end
	return nil
end

------------------------------------------------------------------
-- UPGRADES (one-time purchases that buff the owner permanently)
-- effect keys understood by the server:
--   walletBonus  (number) -> added to every patron's wallet at this casino
--   tiltBonus    (number) -> added to NPC ExtraLossChance (capped at 0.85)
--   visitBonus   (number) -> added to MachinesPerVisitMax for patrons here
--   spawnBonus   (number) -> increases this casino's spawn weight
------------------------------------------------------------------
export type UpgradeDef = {
	id: string, name: string, desc: string, cost: number,
	effect: { walletBonus: number?, tiltBonus: number?, visitBonus: number?, spawnBonus: number? },
}

Config.Upgrades = {
	{ id = "marketing_1", name = "Marketing I",     desc = "Patrons walk in with +$150.",                cost = 4000,  effect = { walletBonus = 150 } },
	{ id = "marketing_2", name = "Marketing II",    desc = "Patrons walk in with +$400 more.",           cost = 12000, effect = { walletBonus = 400 } },
	{ id = "rigged",      name = "Rigged Wheels",   desc = "+15% house tilt vs. patrons.",               cost = 9000,  effect = { tiltBonus = 0.15 } },
	{ id = "comp_drinks", name = "Comp Drinks",     desc = "Patrons play +1 more machine per visit.",    cost = 5500,  effect = { visitBonus = 1 } },
	{ id = "neon_sign",   name = "Neon Sign",       desc = "Your casino attracts 2x more patrons.",      cost = 7000,  effect = { spawnBonus = 1 } },
	{ id = "high_roller", name = "High-Roller Lounge", desc = "Patrons walk in with +$1500 more.",       cost = 30000, effect = { walletBonus = 1500 } },
} :: {UpgradeDef}

function Config.getUpgradeDef(id: string): UpgradeDef?
	for _, def in Config.Upgrades do
		if def.id == id then return def end
	end
	return nil
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
-- MONETIZATION (Robux shop)
-- Create each gamepass / developer product on the Roblox Creator dashboard
-- (create.roblox.com → your experience → Monetization), then paste its asset ID
-- below. id = 0 means "not set up yet" → the shop shows it as "Coming soon" and
-- never prompts a purchase.
--   Gamepass effect keys: earningsMult / offlineMult (multiplicative),
--     extraMachines (additive to MaxMachinesPerPlot), vipBadge (cosmetic flag).
--   Product reward keys: cashGrant (Cash added on purchase).
------------------------------------------------------------------
Config.Monetization = {
	Gamepasses = {
		{ key = "vip",      id = 0, name = "VIP Pass",          icon = "rbxassetid://0",
		  desc = "2× all casino earnings, 2× offline income, and a VIP badge.",
		  effect = { earningsMult = 2, offlineMult = 2, vipBadge = true } },
		{ key = "space",    id = 0, name = "Tycoon Expansion",  icon = "rbxassetid://0",
		  desc = "+8 machine slots on your plot.",
		  effect = { extraMachines = 8 } },
		{ key = "offline2x", id = 0, name = "2× Offline Income", icon = "rbxassetid://0",
		  desc = "Double the Cash your machines earn while you're away.",
		  effect = { offlineMult = 2 } },
	},
	Products = {
		{ key = "cash_5k",   id = 0, name = "$5,000 Cash",     cashGrant = 5000 },
		{ key = "cash_25k",  id = 0, name = "$25,000 Cash",    cashGrant = 25000 },
		{ key = "cash_150k", id = 0, name = "$150,000 Cash",   cashGrant = 150000 },
		{ key = "cash_1m",   id = 0, name = "$1,000,000 Cash", cashGrant = 1000000, badge = "BEST VALUE" },
	},
}

function Config.getProductByDevId(devProductId: number)
	for _, p in Config.Monetization.Products do
		if p.id == devProductId then return p end
	end
	return nil
end

return Config
