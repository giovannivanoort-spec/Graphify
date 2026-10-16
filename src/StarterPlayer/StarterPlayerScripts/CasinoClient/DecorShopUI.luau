--!nonstrict
-- DecorShopUI.luau — SHOP > DECOR (ShopUI.registerTab, order 30): plants,
-- floors & co. (Config.Decor; server CasinoServer/Decor.luau).
--   * a left rail: your casino's APPEAL meter (every placed point = +1% guests,
--     up to +15%) and the category chips (ALL + Config.DecorCategories)
--   * one Showtime card per piece (UILib.card): its icon on the stage, +N APPEAL
--     (WALKABLE for floor pieces), BUY with your price (green / red with your
--     Cash, the priceDiscount effect applied), PLACE while you have unplaced
--     copies (build mode: PlacementController.beginDecor), a SELL pill for an
--     unplaced copy (tap twice), RANK / REBIRTH locks, NEW! / OWNED / GOLDEN badges
-- Buying calls BuyDecor; the server pushes a snapshot (key `decor`) and the shop
-- re-renders the tab. DecorShopUI.open() opens the shop on this tab.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local Remotes = require(Common:WaitForChild("Remotes"))
local UILib = require(script.Parent:WaitForChild("UILib"))

local DecorShopUI = {}
local C = UILib.Colors
local F = UILib.Fonts
local make = UILib.make
local deps = {}

local RAIL_W = 156
local ALL = { id = "all", label = "ALL", icon = "shop", tone = "Gold" }

local category = "all"   -- the chip picked (kept across re-renders and visits)
local busy = false
local hooked = setmetatable({}, { __mode = "k" }) -- shop panels we mark NEW items seen on (plain tables)
local shown: {[string]: boolean} = {}             -- NEW decor ids shown in the open panel

------------------------------------------------------------------
-- state
------------------------------------------------------------------
local function decorState()
	local d = UILib.state.decor
	return type(d) == "table" and d or nil
end

local function invCount(id: string): number
	local d = decorState()
	local inv = d and d.inventory
	return type(inv) == "table" and math.max(0, math.floor(tonumber(inv[id]) or 0)) or 0
end

local function placedCount(id: string): number
	local d = decorState()
	local n = 0
	for _, p in ((d and d.placed) or {}) do
		if type(p) == "table" and p.decorId == id then n += 1 end
	end
	return n
end

local function rankNow(): number
	return tonumber(UILib.state.rank) or 1
end

local function rebirthsNow(): number
	local r = UILib.state.rebirth
	return type(r) == "table" and (tonumber(r.count) or 0) or 0
end

local function discountNow(): number
	return math.clamp(tonumber(UILib.state.priceDiscount) or 0, 0, 0.6)
end

local function rankName(r: number): string?
	local d = Config.Progression and Config.Progression.Ranks and Config.Progression.Ranks[r]
	return d and d.name or nil
end

local function isNew(id: string): boolean
	if not UILib.isNew then return false end
	local ok, res = pcall(UILib.isNew, "decor", id)
	return ok and res == true
end

------------------------------------------------------------------
-- actions
------------------------------------------------------------------
local function invoke(remote, ...)
	local args = table.pack(...)
	local ok, res = pcall(function() return remote:InvokeServer(table.unpack(args, 1, args.n)) end)
	if ok and type(res) == "table" then return res end
	return { ok = false, message = "The shop is busy - try again." }
end

local function buy(def)
	if busy then return end
	busy = true
	local res = invoke(Remotes.BuyDecor(), def.id)
	busy = false
	if res.ok then
		UILib.toast("BOUGHT " .. string.upper(def.name) .. "!", "unlock", "Press PLACE to put it in your casino.")
	elseif res.needRank or res.needRebirth then
		UILib.toast(res.message or "Locked", "info")
	else
		UILib.toast(res.message or "Purchase failed", "error")
	end
end

local function place(ctx, def)
	local pc = deps.PlacementController
	if ctx.panel and ctx.panel.close then ctx.panel.close() end
	if pc and type(pc.beginDecor) == "function" then
		pc.beginDecor(def.id)
	elseif pc and type(pc.begin) == "function" then
		pc.begin({ kind = "decor", decorId = def.id, id = def.id, name = def.name, flat = def.flat == true,
			sizeX = def.size.X, sizeY = def.size.Y, sizeZ = def.size.Z, count = invCount(def.id) })
	elseif deps.InventoryUI and deps.InventoryUI.open then
		deps.InventoryUI.open()
	end
end

local function sell(def, button)
	if busy then return end
	busy = true
	local res = invoke(Remotes.SellDecor(), def.id)
	busy = false
	if res.ok then
		UILib.toast("SOLD " .. string.upper(def.name) .. "!", "income", res.message)
		if button and (res.refund or 0) > 0 then UILib.fx("coinBurst", button, res.refund) end
	else
		UILib.toast(res.message or "Couldn't sell that.", "error")
	end
end

------------------------------------------------------------------
-- pieces
------------------------------------------------------------------
-- the APPEAL meter at the top of the rail
local function appealBox(parent: Instance)
	local d = decorState() or {}
	local a = math.max(0, math.floor(tonumber(d.appeal) or 0))
	local maxA = math.max(1, math.floor(tonumber(d.appealMax) or 15))
	local bonus = tonumber(d.appealBonus) or Config.decorAppealBonus(a)
	local box = make("Frame", {
		Name = "Appeal", BackgroundColor3 = C.White, BorderSizePixel = 0, Size = UDim2.fromOffset(RAIL_W, 76),
		LayoutOrder = 0, Parent = parent,
	})
	UILib.corner(box, 16)
	UILib.gradient(box, C.CrimsonTop, C.CrimsonDeep)
	UILib.stroke(box, C.Ink, 3, true)
	UILib.image(box, "star", { size = UDim2.fromOffset(34, 34), position = UDim2.fromOffset(2, -2) })
	UILib.text(box, {
		text = "APPEAL", size = 19, xAlign = Enum.TextXAlignment.Left, gradient = { C.White, C.GoldTop },
		frameSize = UDim2.fromOffset(80, 28), position = UDim2.fromOffset(36, 2),
	})
	UILib.text(box, {
		text = ("%d/%d"):format(math.min(a, maxA), maxA), font = F.Number, size = 16, xAlign = Enum.TextXAlignment.Right,
		frameSize = UDim2.fromOffset(52, 28), position = UDim2.new(1, -58, 0, 2),
	})
	UILib.progressBar(box, {
		size = UDim2.new(1, -16, 0, 16), position = UDim2.fromOffset(8, 33), tone = a >= maxA and "Gold" or "Green",
		value = math.clamp(a / maxA, 0, 1), textSize = 11, text = a >= maxA and "MAX!" or "",
	})
	local hint = a > 0 and ("+%d%% MORE GUESTS"):format(math.floor(bonus * 100 + 0.5)) or "DECOR = MORE GUESTS"
	local hintLabel = UILib.body(box, {
		text = hint, font = F.Heavy, size = 12, color = C.GreenTop, xAlign = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, -12, 0, 18), position = UDim2.fromOffset(6, 53),
	})
	UILib.fitText(hintLabel, hint, 12, RAIL_W - 16, 9) -- stays inside the box
	return box
end

-- a category chip (selected: its tone, else cream)
local function chip(parent: Instance, cat, selected: boolean, order: number, onClick)
	local t = UILib.Tones[cat.tone] or UILib.Tones.Gold
	local f = make("Frame", {
		Name = "Chip_" .. cat.id, BackgroundColor3 = C.White, BorderSizePixel = 0, Size = UDim2.fromOffset(RAIL_W, 30),
		LayoutOrder = order, Parent = parent,
	})
	UILib.corner(f, 15)
	if selected then UILib.gradient(f, t.top, t.base) else UILib.gradient(f, C.Cream, C.CreamRow) end
	UILib.stroke(f, C.Ink, selected and 3 or 2.5, true)
	UILib.image(f, cat.icon, { size = UDim2.fromOffset(30, 30), position = UDim2.fromOffset(4, 0) })
	if selected then
		UILib.text(f, {
			text = cat.label, size = 16, xAlign = Enum.TextXAlignment.Left, shadow = 2,
			frameSize = UDim2.new(1, -44, 1, 0), position = UDim2.fromOffset(40, 0),
		})
	else
		UILib.body(f, {
			text = cat.label, font = F.Display, size = 16, color = C.Brown,
			frameSize = UDim2.new(1, -44, 1, 0), position = UDim2.fromOffset(40, 0),
		})
	end
	local click = make("TextButton", {
		Name = "Click", Text = "", BackgroundTransparency = 1, AutoButtonColor = false, Size = UDim2.fromScale(1, 1),
		ZIndex = 5, Parent = f,
	})
	click.Activated:Connect(onClick)
	return f
end

-- one piece's card
local function card(ctx, def, order: number)
	local need = def.unlockRank or 1
	local needR = math.max(0, math.floor(tonumber(def.rebirth) or 0))
	local rebirthLocked = needR > 0 and rebirthsNow() < needR
	local rankLocked = not rebirthLocked and need > rankNow()
	local locked = rebirthLocked or rankLocked
	local unplaced, owned = invCount(def.id), invCount(def.id) + placedCount(def.id)
	local price = Config.decorPrice(def, discountNow())

	local badge
	if rebirthLocked then
		badge = { text = "REBIRTH " .. needR, tone = "Pink" }
	elseif rankLocked then
		badge = { text = "RANK " .. need, tone = "Purple" }
	elseif isNew(def.id) then
		badge = { text = "NEW!", tone = "Red" }
		shown[def.id] = true
	elseif owned > 0 then
		badge = { text = "OWNED x" .. owned, tone = "Gold" }
	elseif needR > 0 then
		badge = { text = "GOLDEN", tone = "Gold" }
	end
	local len = #def.name
	local c = UILib.card({
		parent = ctx.grid, order = order, tone = def.tone or "Green", icon = def.icon or "plant",
		title = string.upper(def.name), titleSize = len > 17 and 15 or (len > 13 and 18 or 22),
		stat = ("+%d APPEAL"):format(def.appeal or 0) .. (def.flat and "  •  WALKABLE" or ""),
		badge = badge, dim = locked,
		model = { kind = "decor", id = def.id }, -- the real piece (ModelIcons)
	})
	local body = c.Instance:FindFirstChild("Body") or c.Instance
	local pos, full = UDim2.new(0, 10, 1, -72), UDim2.new(1, -20, 0, 60)

	if not decorState() then
		-- the decor server isn't answering: no buttons that would wait forever
		local b = UILib.button({ parent = body, tone = "Purple", text = "SOON", icon = "lock", textSize = 24, iconSize = 28,
			size = full, position = pos })
		b.setEnabled(false)
		return
	end
	if rebirthLocked then
		UILib.button({
			parent = body, tone = "Purple", text = "REBIRTH " .. needR, icon = "rebirth", textSize = 22, iconSize = 28,
			size = full, position = pos,
			onClick = function()
				UILib.toast(("Unlocks at Rebirth %d"):format(needR), "info", "Rebirth from the REBIRTH tile on your HUD.")
			end,
		})
		return
	end
	if rankLocked then
		UILib.button({
			parent = body, tone = "Purple", text = "RANK " .. need, icon = "lock", textSize = 24, iconSize = 28,
			size = full, position = pos,
			onClick = function()
				local name = rankName(need)
				UILib.toast(("Unlocks at Rank %d%s"):format(need, name and (" (" .. name .. ")") or ""), "info",
					"Every game your guests play earns XP for your Casino Rank.")
			end,
		})
		return
	end
	local half = UDim2.new(0.5, -14, 0, 60)
	local buyBtn = UILib.button({
		parent = body, tone = "Green", text = unplaced > 0 and UILib.short(price) or UILib.abbreviate(price), icon = "coin",
		textSize = unplaced > 0 and 20 or 24, iconSize = unplaced > 0 and 24 or 28,
		size = unplaced > 0 and half or full, position = pos,
		onClick = function() buy(def) end,
	})
	ctx.affordable(buyBtn, price)
	if unplaced > 0 then
		UILib.button({
			parent = body, tone = "Blue", text = "PLACE", icon = "build", textSize = 18, iconSize = 22,
			size = half, position = UDim2.new(0.5, 4, 1, -72),
			onClick = function() place(ctx, def) end,
		})
		-- sell one unplaced copy: tap SELL, then SURE? within 3 s
		local armedAt = 0
		local sellBtn
		sellBtn = UILib.button({
			parent = body, name = "Sell", tone = "Red", text = "SELL", textSize = 14, radius = 10,
			size = UDim2.fromOffset(62, 30), position = UDim2.fromOffset(12, 104), z = 4,
			onClick = function()
				if os.clock() - armedAt <= 3 then
					armedAt = 0
					sell(def, sellBtn.Instance)
					return
				end
				armedAt = os.clock()
				sellBtn.setText("SURE?")
				sellBtn.setTone("Orange")
				task.delay(3, function()
					if armedAt ~= 0 and os.clock() - armedAt >= 2.9 and sellBtn.Instance.Parent then
						sellBtn.setText("SELL")
						sellBtn.setTone("Red")
					end
				end)
			end,
		})
	end
end

------------------------------------------------------------------
-- the tab
------------------------------------------------------------------
local function render(ctx)
	-- the rail on the left; the cards keep their full height on the right
	ctx.grid.Position = UDim2.fromOffset(RAIL_W + 12, 0)
	ctx.grid.Size = UDim2.new(1, -(RAIL_W + 12), 1, 0)
	local rail = make("Frame", {
		Name = "DecorRail", BackgroundTransparency = 1, Position = UDim2.fromOffset(4, 6),
		Size = UDim2.new(0, RAIL_W, 1, -6), Parent = ctx.body,
	})
	UILib.list(rail, "y", 4)
	appealBox(rail)
	local cats = { ALL }
	for _, cat in (Config.DecorCategories or {}) do table.insert(cats, cat) end
	for i, cat in cats do
		chip(rail, cat, category == cat.id, i, function()
			if category == cat.id then return end
			category = cat.id
			UILib.fx("sound", "tick")
			ctx.refresh()
		end)
	end

	-- NEW pieces you've looked at are seen once the shop closes
	if ctx.panel and not hooked[ctx.panel] and ctx.panel.onClose then
		hooked[ctx.panel] = true
		ctx.panel.onClose(function()
			if UILib.markSeen then
				for id in shown do pcall(UILib.markSeen, "decor", id) end
			end
			table.clear(shown)
		end)
	end

	local order = 0
	for _, def in Config.Decor or {} do
		if category == "all" or def.category == category then
			order += 1
			local ok, err = pcall(card, ctx, def, order)
			if not ok then warn("[DecorShopUI] " .. tostring(def.id) .. ": " .. tostring(err)) end
		end
	end
end

function DecorShopUI.open()
	if deps.ShopUI and deps.ShopUI.open then deps.ShopUI.open("decor") end
end

function DecorShopUI.start(d)
	deps = d or {}
	if deps.ShopUI and deps.ShopUI.registerTab then
		deps.ShopUI.registerTab({ id = "decor", label = "DECOR", order = 30, render = render })
	end
end

return DecorShopUI
