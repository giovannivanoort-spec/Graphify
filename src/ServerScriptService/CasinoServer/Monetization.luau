--!nonstrict
-- Monetization.luau — Robux gamepasses + developer products.
--
-- Gamepass ownership is checked server-side (UserOwnsGamePassAsync) and cached
-- per session; benefits are read by the economy (VIP 2× earnings), the offline
-- income calc, and placement (extra machine slots). Developer products grant
-- Cash through ProcessReceipt with per-purchase idempotency (receipts are stored
-- on the profile so a purchase is never granted twice).
--
-- Asset IDs live in Config.Monetization. id == 0 means "not set up yet" — no web
-- call is made and the shop shows the item as "Coming soon".

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))

local Monetization = {}
local Economy, Data
local onChanged   -- callback(player): the server sets this to push a fresh snapshot

-- userId -> { [gamepassKey] = boolean }
local owned: {[number]: {[string]: boolean}} = {}

local function ownsPass(userId: number, passId: number): boolean
	if not passId or passId == 0 then return false end
	local ok, res = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(userId, passId)
	end)
	return ok and res == true
end

-- (Re)load which passes a player owns. Yields; safe to call repeatedly.
function Monetization.refreshOwnership(player: Player)
	local map = {}
	for _, gp in Config.Monetization.Gamepasses do
		map[gp.key] = ownsPass(player.UserId, gp.id)
	end
	owned[player.UserId] = map
	return map
end

function Monetization.teardown(player: Player)
	owned[player.UserId] = nil
end

function Monetization.ownedMap(player: Player)
	return owned[player.UserId] or {}
end

function Monetization.owns(player: Player, key: string): boolean
	local m = owned[player.UserId]
	return (m ~= nil and m[key]) == true
end

-- multiply an effect across all owned passes (for *Mult effects)
local function effectProduct(player: Player, effectKey: string): number
	local mult = 1
	local m = owned[player.UserId]
	if not m then return mult end
	for _, gp in Config.Monetization.Gamepasses do
		local e = gp.effect
		if m[gp.key] and e and e[effectKey] then mult *= e[effectKey] end
	end
	return mult
end

-- sum an effect across all owned passes (for additive effects)
local function effectSum(player: Player, effectKey: string): number
	local total = 0
	local m = owned[player.UserId]
	if not m then return total end
	for _, gp in Config.Monetization.Gamepasses do
		local e = gp.effect
		if m[gp.key] and e and e[effectKey] then total += e[effectKey] end
	end
	return total
end

-- Optional hook (set by the server boot): extra multiplier from the Ticket Shop boost.
Monetization.boostMultiplier = nil :: ((Player) -> number)?

function Monetization.getEarningsMultiplier(player: Player): number
	local mult = effectProduct(player, "earningsMult")
	if Monetization.boostMultiplier then
		mult *= Monetization.boostMultiplier(player)
	end
	return mult
end
function Monetization.getOfflineMultiplier(player: Player): number
	return effectProduct(player, "offlineMult")
end
function Monetization.getMaxMachines(player: Player): number
	return Config.MaxMachinesPerPlot + effectSum(player, "extraMachines")
end
function Monetization.hasVipBadge(player: Player): boolean
	local m = owned[player.UserId]
	if not m then return false end
	for _, gp in Config.Monetization.Gamepasses do
		if m[gp.key] and gp.effect and gp.effect.vipBadge then return true end
	end
	return false
end

------------------------------------------------------------------
-- purchases
------------------------------------------------------------------
local function onGamePassFinished(player: Player, passId: number, wasPurchased: boolean)
	if not wasPurchased then return end
	for _, gp in Config.Monetization.Gamepasses do
		if gp.id == passId then
			local m = owned[player.UserId]
			if not m then m = {}; owned[player.UserId] = m end
			m[gp.key] = true
			if onChanged then onChanged(player) end
			break
		end
	end
end

local function processReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then return Enum.ProductPurchaseDecision.NotProcessedYet end
	local profile = Data.get(player)
	if not profile then return Enum.ProductPurchaseDecision.NotProcessedYet end

	profile.Receipts = profile.Receipts or {}
	local pid = tostring(receiptInfo.PurchaseId)
	if profile.Receipts[pid] then
		return Enum.ProductPurchaseDecision.PurchaseGranted   -- already granted, don't double up
	end

	local prod = Config.getProductByDevId(receiptInfo.ProductId)
	if prod and prod.cashGrant then
		Economy.addCash(player, prod.cashGrant)
	end
	profile.Receipts[pid] = true

	-- Persist the grant before telling Roblox it's done. If the save fails on a
	-- persistent store, return NotProcessedYet so Roblox re-delivers (the receipt
	-- id guards the re-grant). In-memory (no DataStore, e.g. Studio w/o API) we
	-- can't persist, so grant anyway.
	local saved = Data.save(player)
	if Data.isPersistent() and not saved then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if onChanged then onChanged(player) end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function Monetization.start(deps)
	Economy = deps.Economy
	Data = deps.Data
	onChanged = deps.onChanged
	MarketplaceService.ProcessReceipt = processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(onGamePassFinished)
end

-- The catalog the client renders (ids + names + descs; the client pulls live
-- Robux prices/icons from MarketplaceService). Includes this player's owned state.
function Monetization.catalogFor(player: Player)
	local passes = {}
	for _, gp in Config.Monetization.Gamepasses do
		table.insert(passes, { key = gp.key, id = gp.id, name = gp.name, desc = gp.desc,
			owned = Monetization.owns(player, gp.key) })
	end
	local products = {}
	for _, p in Config.Monetization.Products do
		table.insert(products, { key = p.key, id = p.id, name = p.name,
			cashGrant = p.cashGrant, badge = p.badge })
	end
	return { gamepasses = passes, products = products }
end

return Monetization
