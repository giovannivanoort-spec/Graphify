--!nonstrict
-- ShopUI.luau — the SHOP panel: MACHINES / SNACKS & BAR / STAFF tabs of item
-- cards. Machines & concessions buy into your Inventory (BuyToInventory, same
-- remote the physical Showroom uses); staff hire permanently. The Showroom
-- button takes you to the physical displays.
--
-- Every card shows YOUR price for the next copy (Config.machinePrice: each copy
-- you own makes the next one dearer, your priceDiscount takes its share off).
-- Items above your Casino Rank stay on the shelf, dimmed, with a "RANK X" lock
-- instead of a price; Rebirth Wing machines you haven't rebirthed enough for
-- with a "REBIRTH N" lock (snapshot rebirth.count); what your last rank-up or
-- rebirth unlocked wears a NEW! badge until you've looked (UILib.isNew).
--
-- Other modules add tabs: ShopUI.registerTab({ id, label, order, render = fn(ctx) })
-- (DecorShopUI: DECOR, StaffShopUI: STAFF replaces the built-in one). ctx =
-- { grid, body, cat, cashValue, panel, state, affordable(handle, cost), shownNew,
-- refresh() }. Built-in orders: MACHINES 10, SNACKS & BAR 20, STAFF 40.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local Config = require(Common:WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local A = UILib.Assets

local player = Players.LocalPlayer
local ShopUI = {}

local registered: {[string]: any} = {} -- tab id -> { id, label, order, render }
function ShopUI.registerTab(def)
	if type(def) ~= "table" or type(def.id) ~= "string" or type(def.render) ~= "function" then return end
	registered[def.id] = def
end

local STAFF_TONES = { pit_boss = "Blue", security = "Green", host = "Purple" }
-- the newer game types until UIAssets has their own entries
local TYPE_ICON = { Plinko = "gem" }
local TYPE_TONE = { Plinko = "Blue" }

local function unlockRankOf(item): number
	if item.unlockRank then return item.unlockRank end
	local def = Config.getMachineDef(item.id)
	return (def and def.unlockRank) or 1
end

local function rankName(r: number): string?
	local prog = Config.Progression
	local d = prog and prog.Ranks and prog.Ranks[r]
	return d and d.name or nil
end

local function isLocked(need: number): boolean
	local rank = UILib.state.rank
	return type(rank) == "number" and need > rank
end

local function isNew(id: string): boolean
	if not UILib.isNew then return false end
	local ok, res = pcall(UILib.isNew, "machine", id)
	return ok and res == true
end

-- copies owned per id: the snapshot's count, else inventory + placed
local function ownedCounts()
	local owned = UILib.state.ownedCopies
	if type(owned) == "table" then return owned end
	local counts = {}
	for _, it in (UILib.state.inventory or {}) do counts[it.machineId] = (counts[it.machineId] or 0) + 1 end
	for _, m in (UILib.state.placed or {}) do counts[m.machineId] = (counts[m.machineId] or 0) + 1 end
	return counts
end

-- your next copy's price (minus your priceDiscount: the Bargain Hunter rebirth upgrade)
local function priceOf(item, owned: number): number
	local def = Config.getMachineDef(item.id) or item
	local discount = math.clamp(tonumber(UILib.state.priceDiscount) or 0, 0, 0.6)
	if Config.machinePrice then return Config.machinePrice(def, owned, discount) end
	return item.cost or def.cost or 0
end

-- the rebirths you have (nil before the first snapshot: nothing locked yet)
local function rebirthsNow(): number?
	if type(UILib.state.rank) ~= "number" then return nil end
	local rb = UILib.state.rebirth
	return type(rb) == "table" and math.max(0, math.floor(tonumber(rb.count) or 0)) or 0
end

function ShopUI.open(tab: string?)
	local cat = UILib.getCatalog()
	if not cat then UILib.toast("Shop unavailable", "error"); return end
	local cashValue = UILib.getCashValue()

	local p = UILib.panel({ name = "ShopPanel", title = "SHOP", icon = "shop", width = 1000, height = 548 })
	local content = p.content

	local body = UILib.make("Frame", {
		Name = "Body", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 60),
		Size = UDim2.new(1, 0, 1, -104), Parent = content,
	})
	local footer = UILib.make("Frame", {
		Name = "Footer", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 40), Parent = content,
	})
	UILib.body(footer, {
		text = "Tip: walk through the Showroom to see every machine up close!", size = 14,
		frameSize = UDim2.new(1, -230, 1, 0), transparency = 0.25,
	})
	UILib.button({
		parent = footer, tone = "Blue", text = "SHOWROOM", textSize = 20, icon = "slot", iconSize = 30,
		size = UDim2.fromOffset(210, 46), anchor = Vector2.new(1, 0.5), position = UDim2.new(1, 0, 0.5, -2),
		onClick = function()
			-- the server's travel hop (same as the HUD travel bar: cooldown, streaming)
			local ok, res = pcall(function() return Remotes.TravelTo():InvokeServer("showroom") end)
			if ok and res and res.ok then
				p.close()
			elseif ok and res and res.message then
				UILib.toast(res.message, "info")
			else
				local char = player.Character
				local hrp = char and char:FindFirstChild("HumanoidRootPart")
				if hrp then
					local ctr = Config.Showroom.Center
					hrp.CFrame = CFrame.new(ctr.X, ctr.Y + 4, ctr.Z + 12) * CFrame.Angles(0, math.rad(180), 0)
					p.close()
				end
			end
		end,
	})

	local buttons = {} -- { handle, cost } so affordability can recolour live
	local function refreshAffordability()
		local cash = cashValue.Value
		for _, b in buttons do
			if b.cost then b.handle.setTone(cash >= b.cost and "Green" or "Red") end
		end
	end
	local conn = cashValue.Changed:Connect(refreshAffordability)
	p.onClose(function() conn:Disconnect() end)

	local function buy(item, price: number)
		local res = Remotes.BuyToInventory():InvokeServer(item.id)
		if res and res.ok then
			UILib.toast("BOUGHT " .. string.upper(item.name) .. "!", "unlock",
				("It's in your Items — place it on your plot. (%s)"):format(UILib.money(res.price or price)))
		elseif res and (res.needRank or res.needRebirth) then
			UILib.toast(res.message or "Locked", "info")
		else
			UILib.toast(res and res.message or "Purchase failed", "error")
		end
	end

	-- NEW items the player has seen in this panel: marked seen when it closes
	local shownNew = {}
	p.onClose(function()
		if not UILib.markSeen then return end
		for id in shownNew do pcall(UILib.markSeen, "machine", id) end
	end)

	local current
	local render
	local function render0(which)
		current = which
		for _, ch in body:GetChildren() do ch:Destroy() end
		table.clear(buttons)
		local grid = UILib.scroller(body, { grid = true, memory = which }) -- (keeps its scroll on re-render)

		local ext = registered[which]
		if ext then
			local ctx = {
				grid = grid, body = body, cat = cat, cashValue = cashValue, panel = p, state = UILib.state,
				shownNew = shownNew,
				affordable = function(handle, cost) table.insert(buttons, { handle = handle, cost = cost }) end,
				refresh = function() if p.alive then render(which) end end,
			}
			local ok, err = pcall(ext.render, ctx)
			if not ok then warn("[ShopUI] tab " .. which .. ": " .. tostring(err)) end
		elseif which == "machines" or which == "concessions" then
			local list = which == "machines" and cat.machines or cat.concessions
			local owned = ownedCounts()
			for i, item in (list or {}) do
				local isConc = which == "concessions"
				local need = unlockRankOf(item)
				-- Rebirth Wing machines need rebirths first (a bigger gate than the rank)
				local needR = math.max(0, math.floor(tonumber(item.rebirth) or 0))
				local haveR = rebirthsNow()
				local rebirthLocked = needR > 0 and haveR ~= nil and haveR < needR
				local locked = rebirthLocked or isLocked(need)
				local n = tonumber(owned[item.id]) or 0
				local price = priceOf(item, n)
				local stat = isConc and ("+$%d per visit"):format(item.revenuePerVisit or 0)
					or ("Bets $%s-$%s"):format(UILib.abbreviate(item.minBet or 0), UILib.abbreviate(item.maxBet or 0))
				local badge
				if rebirthLocked then
					badge = { text = "REBIRTH " .. needR, tone = "Pink" }
				elseif locked then
					badge = { text = "RANK " .. need, tone = "Purple" }
				elseif isNew(item.id) then
					badge = { text = "NEW!", tone = "Red" }
					shownNew[item.id] = true
				elseif n > 0 then
					badge = { text = "OWNED x" .. n, tone = "Gold" }
				elseif needR > 0 then
					badge = { text = "REBIRTH", tone = "Gold" }
				end
				local nameLen = #item.name
				local card = UILib.card({
					parent = grid, order = i, tone = A.TypeTone[item.type] or TYPE_TONE[item.type] or "Blue",
					icon = A.TypeIcon[item.type] or TYPE_ICON[item.type] or "star", title = string.upper(item.name), stat = stat,
					titleSize = nameLen > 17 and 15 or (nameLen > 13 and 18 or 22),
					badge = badge, dim = locked,
					model = { kind = "machine", id = item.id }, -- the real machine / stand (ModelIcons)
					button = rebirthLocked and {
						tone = "Purple", text = "REBIRTH " .. needR, icon = "rebirth",
						onClick = function()
							UILib.toast(("Unlocks at Rebirth %d"):format(needR), "info", "Rebirth from the REBIRTH tile on your HUD.")
						end,
					} or locked and {
						tone = "Purple", text = "RANK " .. need, icon = "lock",
						onClick = function()
							local name = rankName(need)
							UILib.toast(("Unlocks at Rank %d%s"):format(need, name and (" (" .. name .. ")") or ""), "info",
								"Every game your guests play earns XP for your Casino Rank.")
						end,
					} or {
						tone = "Green", text = UILib.abbreviate(price), icon = "coin",
						onClick = function() buy(item, price) end,
					},
				})
				if not locked then table.insert(buttons, { handle = card.button, cost = price }) end
			end
		else -- staff
			local hired = {}
			for _, id in (UILib.state.staff or {}) do hired[id] = true end
			for i, s in (cat.staff or {}) do
				local owned = hired[s.id] == true
				local need = s.unlockRank or 1
				local locked = not owned and isLocked(need)
				local card = UILib.card({
					parent = grid, order = i, tone = STAFF_TONES[s.id] or "Purple", icon = "staff",
					title = string.upper(s.name), stat = ("+%d%% house edge"):format(math.floor((s.bonus or 0) * 100 + 0.5)),
					badge = owned and { text = "HIRED", tone = "Green" } or (locked and { text = "RANK " .. need, tone = "Purple" } or nil),
					dim = locked,
					button = owned and { tone = "Purple", text = "HIRED" } or (locked and {
						tone = "Purple", text = "RANK " .. need, icon = "lock",
						onClick = function()
							local name = rankName(need)
							UILib.toast(("Unlocks at Rank %d%s"):format(need, name and (" (" .. name .. ")") or ""), "info")
						end,
					}) or {
						tone = "Green", text = UILib.abbreviate(s.cost), icon = "coin",
						onClick = function()
							local res = Remotes.HireStaff():InvokeServer(s.id)
							if res and res.ok then
								UILib.toast(string.upper(res.message or "Hired!"), "unlock")
							else
								UILib.toast(res and res.message or "Hire failed", "error")
							end
						end,
					},
				})
				if not owned and not locked then table.insert(buttons, { handle = card.button, cost = s.cost }) end
			end
		end
		refreshAffordability()
	end
	render = render0

	-- built-in tabs + the registered ones (a registered id replaces a built-in)
	local list = {
		{ id = "machines", label = "MACHINES", order = 10 },
		{ id = "concessions", label = "SNACKS & BAR", order = 20 },
		{ id = "staff", label = "STAFF", order = 40 },
	}
	for _, def in registered do
		local replaced = false
		for _, t in list do
			if t.id == def.id then
				t.label = def.label or t.label
				t.order = def.order or t.order
				replaced = true
			end
		end
		if not replaced then table.insert(list, { id = def.id, label = def.label or string.upper(def.id), order = def.order or 50 }) end
	end
	table.sort(list, function(a, b) return a.order < b.order end)
	local tabDefs, known = {}, {}
	for _, t in list do
		table.insert(tabDefs, { id = t.id, label = t.label })
		known[t.id] = true
	end
	local tabs = UILib.tabs(content, tabDefs, render)
	tabs.select((tab and known[tab]) and tab or "machines")

	-- re-render when a purchase/hire lands (owned badges, prices, HIRED state)
	local first = true
	local unsub = UILib.subscribe(function()
		if first then first = false; return end
		if current and p.alive then render(current) end
	end)
	p.onClose(unsub)
end

return ShopUI
