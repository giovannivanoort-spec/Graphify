--!nonstrict
-- ShowroomUI.luau — keeps every showroom display honest for YOU (all local):
--   * the price on its card and prompt is your next copy's (Config.machinePrice:
--     each copy you already own makes the next one dearer, your priceDiscount
--     takes its share off), gold when you can afford it, red with the
--     shortfall when you can't
--   * a display above your Casino Rank shows its lock badge ("RANK X"), says
--     LOCKED on its card and prompt (pressing E gets the server's polite "Unlocks
--     at Rank X" refusal)
--   * a Rebirth Wing machine you haven't rebirthed enough for shows its purple
--     RebirthBadge ("REBIRTH N") instead, and says so on its card and prompt
--     (snapshot rebirth.count; the server refuses with needRebirth)
--   * a machine your last rank-up unlocked wears a NEW! badge until you walk up
--     to it (UILib.isNew / markSeen, kind "machine")
-- Updates live as your cash, rank, rebirths, copies or NEW marks change. The
-- purchase itself is handled in init.client (E -> BuyToInventory).

local CollectionService = game:GetService("CollectionService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors

local ShowroomUI = {}
local TAG = "CasinoShopDisplay"
local SEEN_AFTER = 1.2 -- seconds near a NEW display before it counts as seen

local function commas(n: number): string
	local s = tostring(math.floor(n))
	local k
	repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
	return s
end

local function ownedOf(id: string): number
	local owned = UILib.state.ownedCopies
	return (type(owned) == "table" and tonumber(owned[id])) or 0
end

-- your purchase discount (the Bargain Hunter rebirth upgrade: snapshot priceDiscount)
local function discountNow(): number
	return math.clamp(tonumber(UILib.state.priceDiscount) or 0, 0, 0.6)
end

-- your price for the next copy
function ShowroomUI.priceFor(def): number
	if Config.machinePrice then return Config.machinePrice(def, ownedOf(def.id), discountNow()) end
	return def.cost
end

-- locked = above your Casino Rank (no rank in the snapshot yet = nothing locked)
function ShowroomUI.isLocked(def): boolean
	local rank = UILib.state.rank
	return type(rank) == "number" and (def.unlockRank or 1) > rank
end

-- the rebirths a def needs (0 = none) and the ones you have (nil before the
-- first snapshot: nothing locked yet)
function ShowroomUI.rebirthNeed(def): number
	return math.max(0, math.floor(tonumber(def and def.rebirth) or 0))
end
local function rebirthsNow(): number?
	local st = UILib.state
	if type(st.rank) ~= "number" then return nil end
	local rb = st.rebirth
	return type(rb) == "table" and math.max(0, math.floor(tonumber(rb.count) or 0)) or 0
end

-- rebirth-locked = it needs more rebirths than you have
function ShowroomUI.isRebirthLocked(def): boolean
	local need = ShowroomUI.rebirthNeed(def)
	if need <= 0 then return false end
	local have = rebirthsNow()
	return have ~= nil and have < need
end

function ShowroomUI.rankName(r: number?): string?
	local prog = Config.Progression
	local d = prog and prog.Ranks and r and prog.Ranks[r]
	return d and d.name or nil
end

local function isNew(id: string): boolean
	if not UILib.isNew then return false end
	local ok, res = pcall(UILib.isNew, "machine", id)
	return ok and res == true
end

local function displayDef(display: Instance)
	local id = display:GetAttribute("ShopMachineId")
	return id and Config.getMachineDef(id) or nil
end

local function refreshOne(display: Instance, cash: number)
	local def = displayDef(display)
	if not def then return end
	-- a rebirth lock outranks a rank lock (it's the bigger gate)
	local needR = ShowroomUI.rebirthNeed(def)
	local rebirthLocked = ShowroomUI.isRebirthLocked(def)
	local rankLocked = not rebirthLocked and ShowroomUI.isLocked(def)
	local locked = rebirthLocked or rankLocked
	local price = ShowroomUI.priceFor(def)
	local owned = ownedOf(def.id)

	local card = display:FindFirstChild("InfoCard", true)
	if card then
		local priceL = card:FindFirstChild("Price", true)
		if priceL and priceL:IsA("TextLabel") then
			if rebirthLocked then
				priceL.TextColor3 = C.Purple
				priceL.Text = ("LOCKED · REBIRTH %d"):format(needR)
			elseif rankLocked then
				priceL.TextColor3 = C.Crimson
				priceL.Text = ("LOCKED · RANK %d"):format(def.unlockRank or 1)
			elseif cash >= price then
				priceL.TextColor3 = C.Gold
				priceL.Text = ("$%s   [E] Buy"):format(commas(price))
			else
				priceL.TextColor3 = C.Red
				priceL.Text = ("$%s   need $%s more"):format(commas(price), commas(price - cash))
			end
		end
		local meta = card:FindFirstChild("Meta", true)
		if meta and meta:IsA("TextLabel") then
			local text = ("%s • bets $%s–$%s"):format(def.type, commas(def.minBet), commas(def.maxBet))
			if rebirthLocked then
				text = ("Rebirth %d to unlock · %s"):format(needR, def.type)
			elseif rankLocked then
				local name = ShowroomUI.rankName(def.unlockRank)
				text = name and ("Rank %d · %s"):format(def.unlockRank or 1, name) or text
			elseif owned > 0 then
				text ..= (" • you own %d"):format(owned)
			end
			meta.Text = text
		end
	end

	local lock = display:FindFirstChild("LockBadge", true)
	if lock and lock:IsA("BillboardGui") then lock.Enabled = rankLocked end
	local rbBadge = display:FindFirstChild("RebirthBadge", true)
	if rbBadge and rbBadge:IsA("BillboardGui") then rbBadge.Enabled = rebirthLocked end
	local newB = display:FindFirstChild("NewBadge", true)
	if newB and newB:IsA("BillboardGui") then newB.Enabled = (not locked) and isNew(def.id) end

	local prompt = display:FindFirstChild("BuyPrompt", true)
	if prompt and prompt:IsA("ProximityPrompt") then
		if rebirthLocked then
			prompt.ActionText = "Locked"
			prompt.ObjectText = ("%s · Rebirth %d"):format(def.name, needR)
		elseif rankLocked then
			prompt.ActionText = "Locked"
			prompt.ObjectText = ("%s · Rank %d"):format(def.name, def.unlockRank or 1)
		else
			prompt.ActionText = ("Buy  $%s"):format(commas(price))
			prompt.ObjectText = def.name
		end
	end
end

function ShowroomUI.start()
	local cashValue = UILib.getCashValue()

	local function refreshAll()
		local cash = cashValue.Value
		for _, d in CollectionService:GetTagged(TAG) do
			refreshOne(d, cash)
		end
	end

	-- coalesce bursts of changes (an owner's cash ticks on every NPC spin)
	local pending = false
	local function schedule()
		if pending then return end
		pending = true
		task.delay(0.15, function()
			pending = false
			refreshAll()
		end)
	end

	cashValue.Changed:Connect(schedule)
	UILib.subscribe(function() schedule() end)          -- rank, copies owned
	if UILib.onNewChanged then
		UILib.onNewChanged(function(kind)
			if kind == "machine" then schedule() end
		end)
	end
	-- a display streams in part by part: color it as soon as its card / badges /
	-- prompt arrive (no affordability flash)
	local function hook(display: Instance)
		refreshOne(display, cashValue.Value)
		schedule()
		display.DescendantAdded:Connect(function(d)
			if d:IsA("BillboardGui") or d:IsA("ProximityPrompt") then schedule() end
		end)
	end
	for _, d in CollectionService:GetTagged(TAG) do hook(d) end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(hook)

	-- walking up to a NEW display marks it seen (after a moment, so the badge
	-- is noticed on the way in)
	ProximityPromptService.PromptShown:Connect(function(prompt)
		if prompt.Name ~= "BuyPrompt" then return end
		local display = prompt:FindFirstAncestorWhichIsA("Model")
		while display and not display:GetAttribute("ShopMachineId") do
			display = display.Parent and display.Parent:FindFirstAncestorWhichIsA("Model") or nil
		end
		local id = display and display:GetAttribute("ShopMachineId")
		if not (id and isNew(id) and UILib.markSeen) then return end
		task.delay(SEEN_AFTER, function()
			if prompt.Parent then pcall(UILib.markSeen, "machine", id) end
		end)
	end)
	task.defer(refreshAll)
end

return ShowroomUI
