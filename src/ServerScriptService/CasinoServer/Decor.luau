--!nonstrict
-- Decor.luau — plants, floors & co. (Config.Decor; models: DecorModels.luau):
--   * BuyDecor(decorId): Cash -> profile.DecorInventory[decorId] += 1 (Casino Rank
--     gate def.unlockRank, rebirth gate def.rebirth, the priceDiscount effect)
--   * PlaceDecor(decorId, x, z, rotY, story) / MoveDecor(placedId, x, z, rotY, story):
--     x, z = world ground point, rotY = world yaw in degrees (as machines). Checked
--     by the shared rules (CasinoCommon/DecorRules: inside the casino, wall
--     clearance, elevator, machines + the lane in front of them, other decor) and
--     Config.DecorPerStory. Saved in profile.Decor as { placedId, decorId,
--     cf = 12 numbers relative to the plot Base centre } (like profile.Placed).
--   * PickupDecor(placedId): back to the inventory. SellDecor(placedId) pays
--     Config.DecorSellRefund x today's price; SellDecor(decorId) sells one unplaced
--     copy. (Move / Pickup / Sell also take the placed model itself.)
--   * join: rebuilds the saved pieces (a piece on a floor the casino no longer has
--     goes back to the inventory); leave: takes them down
--   * Decor.onRebirth(player) (Rebirth.luau): pieces above the ground floor go back
--     to the inventory (a rebirth drops the building to one floor), except on the
--     VIP floor, which stays on top (Buildings moves it down, Decor.shiftStory)
--   * the VIP floor (VipFloor.luau): Decor.shiftStory(player, from, to) moves the
--     pieces of one story to another (it moved up / down), Decor.returnStory(player,
--     story) sends a story's pieces back to the inventory (the VIP pass is gone)
--   * effect provider "decor": the placed pieces' appeal (+ `appeal` from any other
--     provider) becomes spawnBonus: Config.decorAppealBonus (+1% guests a point, max +15%)
--   * ReplicatedStorage.DecorPreviews/<decorId>: the build-mode ghosts (no lights,
--     particles or collision)
--   * Placement.decorCheck(player, def, pos, rotY): machines can't be placed onto
--     solid decor or facing straight into it (Placement.validateSpot calls it)
-- Placed models live in <plot model>.PlacedDecor, tagged CasinoDecor (+ CasinoProp
-- when they animate, so client MachineFX chases their bulbs / turns their
-- spinners), with attributes OwnerId, DecorId, PlacedId, Story, Flat.
-- Snapshot (key "decor"): { inventory = { [decorId] = count }, placed = { { placedId,
-- decorId, story } }, appeal, appealBonus, appealMax, perStory = { count per story },
-- cap = Config.DecorPerStory }.

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local Remotes = require(Common:WaitForChild("Remotes"))

-- report to GameEvents (quests & co. listen); never in the way of the action
local function gameEvent(player, name: string, amount: number?)
	local m = script.Parent:FindFirstChild("GameEvents")
	if not m then return end
	local ok, GE = pcall(require, m)
	if ok and type(GE) == "table" and GE.emit then pcall(GE.emit, player, name, amount) end
end
local DecorRules = require(Common:WaitForChild("DecorRules"))
local DecorModels = require(script.Parent:WaitForChild("DecorModels"))

local Decor = {}
local Data, Economy, Plots, Buildings, Progression, Upgrades, Rebirth, pushData

local H = Config.Building.StoryHeight
local FOLDER = "PlacedDecor"
local TAG = DecorRules.Tag

-- userId -> placedId -> model (a strong table: never key weak tables by Instances)
local models: {[number]: {[string]: Model}} = {}
-- profile -> { n = #profile.Decor, v = appeal points } (profiles are plain tables)
local appealCache = setmetatable({}, { __mode = "k" })

------------------------------------------------------------------
-- profile helpers
------------------------------------------------------------------
local function inventoryOf(profile)
	if type(profile.DecorInventory) ~= "table" then profile.DecorInventory = {} end
	return profile.DecorInventory
end

local function placedOf(profile)
	if type(profile.Decor) ~= "table" then profile.Decor = {} end
	return profile.Decor
end

local function addToInventory(profile, decorId: string, n: number?)
	local inv = inventoryOf(profile)
	inv[decorId] = math.max(0, math.floor(tonumber(inv[decorId]) or 0)) + (n or 1)
	if inv[decorId] <= 0 then inv[decorId] = nil end
end

-- the story of a saved cf (relative to the plot Base centre), as init.server's snapshot
local function storyOfRel(relY: number, rec): number
	local baseTop = rec and rec.base.Size.Y / 2 or 0.5
	return math.max(1, math.floor((relY - baseTop) / H + 0.25) + 1)
end

local function entryStory(entry, rec): number
	return storyOfRel(Data.decodeCF(entry.cf).Y, rec)
end

local function findEntry(profile, placedId: any)
	if type(placedId) ~= "string" then return nil end
	for i, e in placedOf(profile) do
		if type(e) == "table" and e.placedId == placedId then return e, i end
	end
	return nil
end

-- placed pieces (known ids) on a story
local function countOnStory(profile, rec, story: number): number
	local n = 0
	for _, e in placedOf(profile) do
		if type(e) == "table" and Config.getDecorDef(e.decorId) and entryStory(e, rec) == story then n += 1 end
	end
	return n
end

-- a request may name a piece by its placedId or hand over its model
local function placedIdOf(player: Player, key: any): string?
	if typeof(key) == "Instance" then
		if key:GetAttribute("OwnerId") ~= player.UserId then return nil end
		local id = key:GetAttribute("PlacedId")
		return type(id) == "string" and id or nil
	end
	return type(key) == "string" and key or nil
end

local function cleanNumber(v: any): number?
	local n = tonumber(v)
	if not n or n ~= n or math.abs(n) > 1e6 then return nil end
	return n
end

------------------------------------------------------------------
-- appeal (the effect provider) + price
------------------------------------------------------------------
local function appealOf(profile): number
	if type(profile) ~= "table" then return 0 end
	local list = placedOf(profile)
	local c = appealCache[profile]
	if c and c.n == #list then return c.v end
	local total = 0
	for _, e in list do
		local def = type(e) == "table" and Config.getDecorDef(e.decorId)
		if def then total += tonumber(def.appeal) or 0 end
	end
	appealCache[profile] = { n = #list, v = total }
	return total
end

local function dirtyAppeal(profile)
	appealCache[profile] = nil
end

-- appeal other providers add (a potion, a rebirth upgrade ...): read through
-- Upgrades.effect while our own provider stays quiet, so nothing counts twice
local inProvider = false
local function extraAppeal(profile): number
	if not Upgrades or inProvider then return 0 end
	inProvider = true
	local ok, v = pcall(Upgrades.effect, profile, "appeal")
	inProvider = false
	return (ok and tonumber(v)) or 0
end

local function provider(profile)
	if inProvider or type(profile) ~= "table" then return nil end
	local own = appealOf(profile)
	local total = own + extraAppeal(profile)
	if own <= 0 and total <= 0 then return nil end
	return { appeal = own, spawnBonus = Config.decorAppealBonus(total) }
end
Decor.effects = provider

local function discountOf(profile): number
	if not Upgrades then return 0 end
	local ok, v = pcall(Upgrades.effect, profile, "priceDiscount")
	return math.clamp((ok and tonumber(v)) or 0, 0, 0.6)
end

------------------------------------------------------------------
-- gates
------------------------------------------------------------------
local function rebirthCount(player: Player, profile): number
	if Rebirth and type(Rebirth.count) == "function" then
		local ok, n = pcall(Rebirth.count, player)
		if ok and tonumber(n) then return tonumber(n) end
	end
	local st = profile and profile.Rebirth
	return type(st) == "table" and math.max(0, math.floor(tonumber(st.count) or 0)) or 0
end

local function rebirthAllows(player: Player, profile, need: number): boolean
	if need <= 0 then return true end
	if Rebirth and type(Rebirth.allows) == "function" then
		local ok, res = pcall(Rebirth.allows, player, need)
		if ok then return res == true end
	end
	return rebirthCount(player, profile) >= need
end

local function rebirthLocked(need: number): string
	if Rebirth and type(Rebirth.lockedMessage) == "function" then
		local ok, msg = pcall(Rebirth.lockedMessage, need)
		if ok and type(msg) == "string" then return msg end
	end
	return ("Unlocks at Rebirth %d"):format(need)
end

------------------------------------------------------------------
-- models
------------------------------------------------------------------
local function folderFor(rec): Folder
	local f = rec.model:FindFirstChild(FOLDER)
	if not f then
		f = Instance.new("Folder")
		f.Name = FOLDER
		f.Parent = rec.model
	end
	return f
end

local function modelOf(player: Player, placedId: string): Model?
	local byId = models[player.UserId]
	local m = byId and byId[placedId]
	if m and m.Parent then return m end
	return nil
end

local function destroyModel(player: Player, placedId: string)
	local byId = models[player.UserId]
	local m = byId and byId[placedId]
	if m then
		byId[placedId] = nil
		m:Destroy()
	end
end

local function spawnModel(player: Player, rec, def, cf: CFrame, placedId: string, story: number): Model?
	local m = DecorModels.build(def)
	if not m then return nil end
	m:PivotTo(cf)
	m:SetAttribute("OwnerId", player.UserId)
	m:SetAttribute("DecorId", def.id)
	m:SetAttribute("PlacedId", placedId)
	m:SetAttribute("Story", story)
	m:SetAttribute("Flat", def.flat == true)
	-- the Walk of Fame star carries its owner's name
	local label = m:FindFirstChild("OwnerName", true)
	if label and label:IsA("TextLabel") then label.Text = string.upper(player.DisplayName) end
	CollectionService:AddTag(m, TAG)
	if m:GetAttribute("Animated") then CollectionService:AddTag(m, "CasinoProp") end
	m.Parent = folderFor(rec)
	local byId = models[player.UserId]
	if not byId then
		byId = {}
		models[player.UserId] = byId
	end
	byId[placedId] = m
	return m
end

-- the world ground CFrame a request asks for (or nil + why) and its story
local function spotFor(player: Player, x: any, z: any, rotY: any, story: any): (CFrame?, string?, number?)
	local px, pz = cleanNumber(x), cleanNumber(z)
	if not (px and pz) then return nil, "Bad position." end
	local rot = cleanNumber(rotY) or 0
	local s = math.floor(tonumber(story) or 1)
	if s < 1 or s > Buildings.stories(player) then return nil, "You don't own that floor yet." end
	local y = Plots.surfaceY(player.UserId) + (s - 1) * H
	return CFrame.new(px, y, pz) * CFrame.Angles(0, math.rad(rot), 0), nil, s
end

local function floorFull(): string
	return ("This floor has all the decor it can take (%d)."):format(Config.DecorPerStory or 40)
end

------------------------------------------------------------------
-- actions
------------------------------------------------------------------
function Decor.buy(player: Player, decorId: any)
	local def = Config.getDecorDef(decorId)
	if not def then return { ok = false, message = "Unknown decor." } end
	local profile = Data.get(player)
	if not profile then return { ok = false, message = "Data not ready." } end
	local need = def.unlockRank or 1
	if Progression and not Progression.allows(player, need) then
		return { ok = false, message = Progression.lockedMessage(need), needRank = need }
	end
	local needR = math.max(0, math.floor(tonumber(def.rebirth) or 0))
	if not rebirthAllows(player, profile, needR) then
		return { ok = false, message = rebirthLocked(needR), needRebirth = needR }
	end
	local held = math.floor(tonumber(inventoryOf(profile)[def.id]) or 0)
	if held >= (Config.DecorMaxStack or 99) then
		return { ok = false, message = "You have plenty of those - place some first!" }
	end
	local price = Config.decorPrice(def, discountOf(profile))
	if Economy.getCash(player) < price then
		return { ok = false, message = "Not enough " .. Config.CurrencyName .. "." }
	end
	if price > 0 and not Economy.tryWithdraw(player, price) then
		return { ok = false, message = "Purchase failed." }
	end
	addToInventory(profile, def.id, 1)
	gameEvent(player, "decorBought", 1)
	return { ok = true, message = "Bought " .. def.name .. "!", price = price, decorId = def.id,
		count = inventoryOf(profile)[def.id] }
end

function Decor.place(player: Player, decorId: any, x: any, z: any, rotY: any, story: any)
	local def = Config.getDecorDef(decorId)
	if not def then return { ok = false, message = "Unknown decor." } end
	local profile = Data.get(player)
	local rec = Plots.getRecordForOwner(player.UserId)
	if not (profile and rec) then return { ok = false, message = "You don't own a casino." } end
	if math.floor(tonumber(inventoryOf(profile)[def.id]) or 0) < 1 then
		return { ok = false, message = "Buy one in the Shop first." }
	end
	local cf, why, s = spotFor(player, x, z, rotY, story)
	if not cf then return { ok = false, message = why } end
	if countOnStory(profile, rec, s) >= (Config.DecorPerStory or 40) then
		return { ok = false, message = floorFull() }
	end
	local ok, reason = DecorRules.check(rec.base, player.UserId, def, cf, nil)
	if not ok then return { ok = false, message = reason } end
	local placedId = HttpService:GenerateGUID(false)
	if not spawnModel(player, rec, def, cf, placedId, s) then
		return { ok = false, message = "Couldn't build that piece." }
	end
	addToInventory(profile, def.id, -1)
	table.insert(placedOf(profile), { placedId = placedId, decorId = def.id,
		cf = Data.encodeCF(rec.base.CFrame:ToObjectSpace(cf)) })
	dirtyAppeal(profile)
	gameEvent(player, "decorPlaced", 1)
	return { ok = true, message = "Placed " .. def.name .. "!", placedId = placedId, decorId = def.id }
end

function Decor.move(player: Player, key: any, x: any, z: any, rotY: any, story: any)
	local profile = Data.get(player)
	local rec = Plots.getRecordForOwner(player.UserId)
	if not (profile and rec) then return { ok = false, message = "You don't own a casino." } end
	local placedId = placedIdOf(player, key)
	local entry = findEntry(profile, placedId)
	if not entry then return { ok = false, message = "That's not your decor." } end
	local def = Config.getDecorDef(entry.decorId)
	if not def then return { ok = false, message = "Unknown decor." } end
	local cf, why, s = spotFor(player, x, z, rotY, story)
	if not cf then return { ok = false, message = why } end
	if s ~= entryStory(entry, rec) and countOnStory(profile, rec, s) >= (Config.DecorPerStory or 40) then
		return { ok = false, message = floorFull() }
	end
	local m = modelOf(player, entry.placedId)
	local ok, reason = DecorRules.check(rec.base, player.UserId, def, cf, m)
	if not ok then return { ok = false, message = reason } end
	if m then
		m:PivotTo(cf)
		m:SetAttribute("Story", s)
	elseif not spawnModel(player, rec, def, cf, entry.placedId, s) then
		return { ok = false, message = "Couldn't build that piece." }
	end
	entry.cf = Data.encodeCF(rec.base.CFrame:ToObjectSpace(cf))
	return { ok = true, message = "Moved.", placedId = entry.placedId, decorId = def.id }
end

function Decor.pickup(player: Player, key: any)
	local profile = Data.get(player)
	if not profile then return { ok = false, message = "Data not ready." } end
	local entry, index = findEntry(profile, placedIdOf(player, key))
	if not entry then return { ok = false, message = "That's not your decor." } end
	table.remove(placedOf(profile), index)
	if type(entry.decorId) == "string" then addToInventory(profile, entry.decorId, 1) end
	destroyModel(player, entry.placedId)
	dirtyAppeal(profile)
	return { ok = true, message = "Back in your items.", decorId = entry.decorId }
end

-- a placed piece (placedId / model), else one unplaced copy (decorId)
function Decor.sell(player: Player, key: any)
	local profile = Data.get(player)
	if not profile then return { ok = false, message = "Data not ready." } end
	local entry, index = findEntry(profile, placedIdOf(player, key))
	local def
	if entry then
		def = Config.getDecorDef(entry.decorId)
	else
		def = Config.getDecorDef(key)
		if not (def and math.floor(tonumber(inventoryOf(profile)[def.id]) or 0) > 0) then
			return { ok = false, message = "Nothing to sell." }
		end
	end
	local refund = def and math.floor((Config.DecorSellRefund or 0.5) * Config.decorPrice(def, discountOf(profile))) or 0
	if entry then
		table.remove(placedOf(profile), index)
		destroyModel(player, entry.placedId)
	else
		addToInventory(profile, def.id, -1)
	end
	if refund > 0 then Economy.addCash(player, refund) end
	dirtyAppeal(profile)
	return { ok = true, message = ("Sold for $%d."):format(refund), refund = refund,
		decorId = def and def.id or (entry and entry.decorId) }
end

------------------------------------------------------------------
-- join / leave / rebirth
------------------------------------------------------------------
function Decor.join(player: Player)
	local profile = Data.get(player)
	local rec = Plots.getRecordForOwner(player.UserId)
	if not (profile and rec) then return end
	folderFor(rec):ClearAllChildren() -- leftovers of an earlier owner
	models[player.UserId] = {}
	local stories = Buildings.stories(player)
	local list = placedOf(profile)
	local seen = {}
	for i = #list, 1, -1 do
		local e = list[i]
		if type(e) ~= "table" or type(e.decorId) ~= "string" then
			table.remove(list, i)
		else
			if type(e.placedId) ~= "string" or seen[e.placedId] then e.placedId = HttpService:GenerateGUID(false) end
			seen[e.placedId] = true
			local def = Config.getDecorDef(e.decorId)
			if def then -- (an id no longer in the catalog stays saved, unbuilt)
				local relCF = Data.decodeCF(e.cf)
				local s = storyOfRel(relCF.Y, rec)
				if s > stories then
					table.remove(list, i)
					addToInventory(profile, def.id, 1)
				else
					spawnModel(player, rec, def, rec.base.CFrame:ToWorldSpace(relCF), e.placedId, s)
				end
			end
		end
	end
	dirtyAppeal(profile)
end

function Decor.leave(player: Player)
	local byId = models[player.UserId]
	models[player.UserId] = nil
	if byId then
		for _, m in byId do
			if m.Parent then m:Destroy() end
		end
	end
	local rec = Plots and Plots.getRecordForOwner(player.UserId)
	local f = rec and rec.model:FindFirstChild(FOLDER)
	if f then f:ClearAllChildren() end
end

-- A rebirth drops the building to one floor: the pieces up there go back to the
-- inventory (the caller pushes the snapshot). The VIP floor keeps its pieces: it
-- stays on top (Buildings.setStories moves it down right after). Returns how many moved.
function Decor.onRebirth(player: Player): number
	local profile = Data.get(player)
	if not profile then return 0 end
	local rec = Plots.getRecordForOwner(player.UserId)
	local vip = Buildings and Buildings.vipStory and Buildings.vipStory(player)
	local list = placedOf(profile)
	local moved = 0
	for i = #list, 1, -1 do
		local e = list[i]
		local s = type(e) == "table" and entryStory(e, rec) or 1
		if s > 1 and s ~= vip then
			table.remove(list, i)
			if type(e.decorId) == "string" then addToInventory(profile, e.decorId, 1) end
			if type(e.placedId) == "string" then destroyModel(player, e.placedId) end
			moved += 1
		end
	end
	dirtyAppeal(profile)
	return moved
end

-- The VIP floor moved (VipFloor: a floor bought / a rebirth): every piece on
-- story `from` goes to story `to`, same spot on the plan (the floors are alike).
-- Saved spots move along. Returns how many moved.
function Decor.shiftStory(player: Player, from: number, to: number): number
	local profile = Data.get(player)
	if not profile or from == to then return 0 end
	local rec = Plots.getRecordForOwner(player.UserId)
	local lift = Vector3.new(0, (to - from) * H, 0)
	local moved = 0
	for _, e in placedOf(profile) do
		if type(e) == "table" and entryStory(e, rec) == from then
			e.cf = Data.encodeCF(Data.decodeCF(e.cf) + lift)
			local m = type(e.placedId) == "string" and modelOf(player, e.placedId)
			if m then
				m:PivotTo(m:GetPivot() + lift)
				m:SetAttribute("Story", to)
			end
			moved += 1
		end
	end
	return moved
end

-- The pieces on `story` back to the inventory (the VIP floor went away with its
-- pass). The caller pushes the snapshot. Returns how many.
function Decor.returnStory(player: Player, story: number): number
	local profile = Data.get(player)
	if not profile then return 0 end
	local rec = Plots.getRecordForOwner(player.UserId)
	local list = placedOf(profile)
	local n = 0
	for i = #list, 1, -1 do
		local e = list[i]
		if type(e) == "table" and entryStory(e, rec) == story then
			table.remove(list, i)
			if type(e.decorId) == "string" then addToInventory(profile, e.decorId, 1) end
			if type(e.placedId) == "string" then destroyModel(player, e.placedId) end
			n += 1
		end
	end
	if n > 0 then dirtyAppeal(profile) end
	return n
end

------------------------------------------------------------------
-- snapshot (init.server: key "decor")
------------------------------------------------------------------
function Decor.snapshot(player: Player, profile)
	local rec = Plots.getRecordForOwner(player.UserId)
	local inv = {}
	for id, n in inventoryOf(profile) do
		local c = math.floor(tonumber(n) or 0)
		if type(id) == "string" and c > 0 then inv[id] = c end
	end
	local placed = {}
	local perStory = {}
	for s = 1, (Config.Building.MaxStories or 5) + 1 do perStory[s] = 0 end -- (+1: the VIP floor on top)
	for _, e in placedOf(profile) do
		if type(e) == "table" and type(e.decorId) == "string" then
			local s = entryStory(e, rec)
			table.insert(placed, { placedId = e.placedId, decorId = e.decorId, story = s })
			if perStory[s] then perStory[s] += 1 end
		end
	end
	local own = appealOf(profile)
	local a = Config.DecorAppeal
	return {
		inventory = inv, placed = placed, appeal = own,
		appealBonus = Config.decorAppealBonus(own + extraAppeal(profile)),
		appealMax = math.ceil((a.MaxBonus or 0.15) / (a.PerPoint or 0.01) - 1e-9),
		perStory = perStory, cap = Config.DecorPerStory,
	}
end

-- the placed appeal points of a player (UIs, other modules)
function Decor.appeal(player: Player): number
	local profile = Data and Data.get(player)
	return profile and appealOf(profile) or 0
end

------------------------------------------------------------------
-- start
------------------------------------------------------------------
-- copies of every piece for the build-mode ghost: no lights, particles, beams,
-- sounds or prompts, nothing collidable or clickable
local function publishPreviews()
	local folder = ReplicatedStorage:FindFirstChild("DecorPreviews")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "DecorPreviews"
	end
	for _, def in Config.Decor do
		if not folder:FindFirstChild(def.id) then
			local ok, m = pcall(DecorModels.build, def)
			if ok and m then
				for _, d in m:GetDescendants() do
					if d:IsA("LuaSourceContainer") or d:IsA("Sound") or d:IsA("ProximityPrompt") or d:IsA("Light")
						or d:IsA("ParticleEmitter") or d:IsA("Beam") then
						d:Destroy()
					elseif d:IsA("BasePart") then
						d.Anchored = true
						d.CanCollide = false
						d.CanQuery = false
						d.CanTouch = false
					end
				end
				m.Name = def.id
				m:SetAttribute("DecorId", def.id)
				m:SetAttribute("Flat", def.flat == true)
				m.Parent = folder
			else
				warn("[Decor] no preview for " .. tostring(def.id))
			end
		end
	end
	folder.Parent = ReplicatedStorage
end

-- how far in front of a machine its guests stand (its model's ApproachDistance)
local function reachOf(def): number
	local previews = ReplicatedStorage:FindFirstChild("MachinePreviews")
	local m = previews and previews:FindFirstChild(def.id)
	local a = m and m:GetAttribute("ApproachDistance")
	return tonumber(a) or (def.size.Z / 2 + 1.4)
end

-- Placement.validateSpot asks this before a machine goes down (or moves)
local function machineCheck(player: Player, def, pos: Vector3, rotY: number, ignore: Instance?)
	local rec = Plots and Plots.getRecordForOwner(player.UserId)
	if not (rec and def and def.size) then return true, nil end
	local radius = math.max(def.size.X, def.size.Z) * 0.5
	return DecorRules.machineCheck(rec.base, player.UserId, pos, rotY, radius, reachOf(def), ignore)
end

-- remote wrapper: errors become a polite refusal; success pushes a snapshot
local function handler(fn)
	return function(player: Player, ...)
		local ok, res = pcall(fn, player, ...)
		if not ok then
			warn("[Decor] " .. tostring(res))
			return { ok = false, message = "Something went wrong - try again." }
		end
		if type(res) == "table" and res.ok and pushData then pushData(player) end
		return res
	end
end

function Decor.start(deps)
	Data = deps.Data
	Economy = deps.Economy
	Plots = deps.Plots
	Buildings = deps.Buildings
	Progression = deps.Progression
	Upgrades = deps.Upgrades
	Rebirth = deps.Rebirth
	pushData = deps.pushData

	if Upgrades and Upgrades.addProvider then Upgrades.addProvider("decor", provider) end
	if deps.Placement then deps.Placement.decorCheck = machineCheck end

	Remotes.BuyDecor().OnServerInvoke = handler(Decor.buy)
	Remotes.PlaceDecor().OnServerInvoke = handler(Decor.place)
	Remotes.MoveDecor().OnServerInvoke = handler(Decor.move)
	Remotes.PickupDecor().OnServerInvoke = handler(Decor.pickup)
	Remotes.SellDecor().OnServerInvoke = handler(Decor.sell)

	task.spawn(publishPreviews)
	print(("[CasinoTycoon] Decor: %d pieces in the shop."):format(#Config.Decor))
end

return Decor
