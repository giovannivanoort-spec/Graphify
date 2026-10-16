--!nonstrict
-- RebirthUI.luau — the REBIRTH panel (the HUD's REBIRTH tile), Showtime style.
--   REBIRTH tab: the next rebirth as a goal — a purple rebirth chip on a spinning
--     sunburst, CASH ON HAND against the cost (a live bar), the rebirth coins it
--     pays (live: bring more Cash for a few extra coins, the 2x pass, Coin Magnet),
--     what it unlocks (catalog machines / decor with rebirth = n), what RESETS and
--     what you KEEP, and the big REBIRTH button -> a confirm card (what you lose,
--     what you get) -> Remotes.Rebirth(n).
--   REBIRTH SHOP tab: the permanent upgrades (Config.RebirthUpgrades), one cream
--     row each: tone tile + 3D icon, what it does, level pips, the effect now ->
--     next, and a coin-price button (green: you can afford it, red: not yet,
--     MAXED) -> Remotes.BuyRebirthUpgrade(id).
--   * Remotes.RebirthDone { count, coins, coinsTotal, unlocks } plays the fanfare:
--     a purple UXFX banner, a flash, confetti from the HUD rank chip, NEW marks on
--     what the rebirth unlocked, then the REBIRTH SHOP when there's something to buy.
--   * the HUD REBIRTH tile's alert (HudUI.tiles.REBIRTH.setAlert) is on while you
--     can rebirth or afford a rebirth upgrade; the first time in a session a rebirth
--     becomes affordable a toast says so.
-- RebirthUI.open(tab?)   "shop" / "rebirth"; anything else (the HUD tile): the shop when a
--                        rebirth upgrade is affordable but the rebirth isn't, else REBIRTH
-- RebirthUI.start(deps)  init.client: { HudUI, PlacementController, ... }

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local Config = require(Common:WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local A = UILib.Assets
local C = UILib.Colors
local F = UILib.Fonts
local make = UILib.make

local RebirthUI = {}
local player = Players.LocalPlayer
local deps = {}
local started = false

local function hexOf(c: Color3): string
	return "#" .. c:ToHex()
end
local TXT_NOW, TXT_ARROW, TXT_NEXT = hexOf(C.Brown), hexOf(C.Crimson), hexOf(C.GreenShadow)
local TXT_MAX, TXT_RED, TXT_GOOD = hexOf(C.PurpleShadow), hexOf(C.CrimsonDeep), hexOf(C.GreenShadow)

------------------------------------------------------------------
-- data
------------------------------------------------------------------
local function upgradeDefs()
	return Config.RebirthUpgrades or {}
end

local function rebirthState(state)
	local st = type(state) == "table" and state.rebirth
	return type(st) == "table" and st or nil
end

local function countOf(st): number
	return math.max(0, math.floor(tonumber(st and st.count) or 0))
end

local function costOf(n: number): number
	local rc = Config.Rebirth
	if rc and type(rc.cost) == "function" then
		local ok, v = pcall(rc.cost, n)
		if ok and type(v) == "number" then return v end
	end
	return math.huge
end

local function nextCostOf(st): number
	return tonumber(st and st.nextCost) or costOf(countOf(st) + 1)
end

-- the coins the next rebirth pays with `cash` on hand (the snapshot's coin effects)
local function coinsWith(st, cash: number): number
	local n = countOf(st) + 1
	local rc = Config.Rebirth
	local base = 0
	if rc and type(rc.coins) == "function" then
		local ok, v = pcall(rc.coins, n, math.max(cash, nextCostOf(st)))
		if ok and type(v) == "number" then base = v end
	end
	local bonus = tonumber(st and st.coinBonus) or 0
	local mult = tonumber(st and st.coinMult) or 1
	return math.floor((base + bonus) * mult + 1e-9)
end

local function levelOf(st, id: string): number
	local ups = st and st.upgrades
	return math.max(0, math.floor(tonumber(type(ups) == "table" and ups[id]) or 0))
end

local function coinsHeld(st): number
	return math.max(0, math.floor(tonumber(st and st.coins) or 0))
end

local function affordableCount(st): number
	local coins, n = coinsHeld(st), 0
	for _, def in upgradeDefs() do
		local c = def.costs[levelOf(st, def.id) + 1]
		if c and coins >= c then n += 1 end
	end
	return n
end

-- an upgrade's effect at a level ("+35% Cash", "Start with $1M", "+2 coins a rebirth")
local function describe(def, level: number): string
	if level <= 0 then return "Not owned" end
	local v = tonumber(def.values[math.min(level, #def.values)]) or 0
	if def.money then return string.format(def.format, UILib.moneyShort(v)) end
	if string.find(def.format, "%%%%") then v *= 100 end
	local n = math.floor(v + 0.5)
	local s = string.format(def.format, n)
	if n == 1 then s = (s:gsub("(%d) coins", "%1 coin")) end
	return s
end

local function machineLook(def): (string, string)
	local t = def and def.type
	local icon = (def and type(def.icon) == "string" and def.icon) or A.TypeIcon[t] or "slot"
	return icon, A.TypeTone[t] or "Purple"
end

-- what the next rebirth unlocks, as tiles (the snapshot's ids, else the shared catalog)
local function unlockItems(st)
	local n = countOf(st) + 1
	local u = type(st.unlocks) == "table" and st.unlocks or nil
	local machineIds, decorIds = u and u.machines, u and u.decor
	if type(machineIds) ~= "table" then
		machineIds = {}
		for _, def in Config.Catalog do
			if (tonumber(def.rebirth) or 0) == n then table.insert(machineIds, def.id) end
		end
	end
	if type(decorIds) ~= "table" then
		decorIds = {}
		for _, def in (type(Config.Decor) == "table" and Config.Decor or {}) do
			if type(def) == "table" and (tonumber(def.rebirth) or 0) == n then table.insert(decorIds, def.id) end
		end
	end
	local items = {}
	for _, id in machineIds do
		local def = Config.getMachineDef(id)
		local icon, tone = machineLook(def)
		table.insert(items, { kind = "machine", id = id, label = def and def.name or tostring(id), icon = icon, tone = tone })
	end
	for _, id in decorIds do
		local def = Config.getDecorDef and Config.getDecorDef(id)
		table.insert(items, {
			kind = "decor", id = id, label = def and def.name or tostring(id),
			icon = def and def.icon or "sparkles", tone = def and def.tone or "Gold",
		})
	end
	return items
end

-- what a rebirth takes from the casino right now (for the confirm card)
local function losses(state)
	local machines = #(state.placed or {}) + #(state.inventory or {})
	local levels = 0
	for _, lvl in (type(state.upgradeLevels) == "table" and state.upgradeLevels or {}) do
		levels += tonumber(lvl) or 0
	end
	local stories = type(state.building) == "table" and tonumber(state.building.stories) or 1
	local staff = type(state.staff) == "table" and #state.staff or 0
	return machines, levels, stories, staff
end

------------------------------------------------------------------
-- small pieces
------------------------------------------------------------------
-- an unlock tile: tone box + 3D icon, the name below (RankUI's look)
local TILE_W, TILE_H = 84, 104
local function unlockTile(parent: Instance, item, order: number)
	local root = make("Frame", {
		Name = "Unlock_" .. tostring(item.id), BackgroundTransparency = 1, Size = UDim2.fromOffset(TILE_W, TILE_H),
		LayoutOrder = order, Parent = parent,
	})
	local tone = UILib.Tones[item.tone] or UILib.Tones.Purple
	local box = make("Frame", {
		Name = "Box", BackgroundColor3 = C.White, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 2),
		Size = UDim2.fromOffset(70, 70), Parent = root,
	})
	UILib.corner(box, 18)
	UILib.gradient(box, tone.top, tone.base)
	UILib.stroke(box, C.Ink, 3, true)
	UILib.image(box, UILib.Tex.glow, {
		size = UDim2.fromScale(1.1, 1.1), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5), transparency = 0.45,
	})
	local img = UILib.image(box, item.icon, {
		size = UDim2.fromScale(1.08, 1.08), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.46),
	})
	if item.kind == "machine" or item.kind == "decor" then
		-- the real machine / piece (ModelIcons), the icon as its fallback
		UILib.modelIcon(box, item.kind, item.id, {
			name = "Model", position = UDim2.fromOffset(3, 3), size = UDim2.new(1, -6, 1, -6), z = 3, fallback = img,
			hover = root, shadow = true, align = "bottom", bottom = 0.1,
		})
		local b = UILib.badge(box, item.kind == "decor" and "DECOR" or "NEW", item.kind == "decor" and "Green" or "Red", 8, 4)
		b.AnchorPoint = Vector2.new(0.5, 0.5)
		b.Position = UDim2.new(1, -6, 0, 0)
		b.Size = UDim2.fromOffset(0, 22)
	end
	UILib.body(root, {
		name = "Label", text = string.upper(tostring(item.label or "")), font = F.Display, size = 13, color = C.Brown,
		wrap = true, xAlign = Enum.TextXAlignment.Center, yAlign = Enum.TextYAlignment.Top,
		frameSize = UDim2.fromOffset(TILE_W + 10, 30), position = UDim2.fromOffset(-5, 76),
	})
	return root
end

-- a tone header pill + icon rows (RESETS / YOU KEEP)
local function listBox(parent: Instance, title: string, tone: string, rows, pos: UDim2, size: UDim2)
	local box = make("Frame", {
		Name = "Box_" .. title, BackgroundColor3 = C.Cream, Position = pos, Size = size, Parent = parent,
	})
	UILib.corner(box, 20)
	UILib.stroke(box, C.Ink, 3.5, true)
	local t = UILib.Tones[tone] or UILib.Tones.Gold
	local head = make("Frame", {
		Name = "Head", BackgroundColor3 = C.White, Position = UDim2.fromOffset(10, 10), Size = UDim2.new(1, -20, 0, 34),
		Parent = box,
	})
	UILib.corner(head, 14)
	UILib.gradient(head, t.top, t.base)
	UILib.stroke(head, C.Ink, 3, true)
	UILib.text(head, { text = title, size = 20, shadow = 2, stroke = 2.5 })
	local list = make("Frame", {
		Name = "Rows", BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 52), Size = UDim2.new(1, -20, 1, -58),
		Parent = box,
	})
	UILib.list(list, "y", 2)
	local labels = {}
	for i, r in rows do
		local row = make("Frame", { Name = "Row" .. i, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 33), LayoutOrder = i, Parent = list })
		UILib.image(row, r.icon, { size = UDim2.fromOffset(32, 32), anchor = Vector2.new(0, 0.5), position = UDim2.new(0, 0, 0.5, 0) })
		labels[r.key or i] = UILib.body(row, {
			text = r.text, rich = true, font = F.Heavy, size = 14, color = C.Brown, wrap = true,
			frameSize = UDim2.new(1, -40, 1, 0), position = UDim2.fromOffset(38, 0),
		})
	end
	return box, labels
end

-- a tag on a tab (READY / a count), UpgradesUI-style
local function makeTag(tabFrame: Instance)
	local tag = make("Frame", {
		Name = "Tag", BackgroundColor3 = C.White, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, 18, 0, 3),
		Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, Rotation = 8, ZIndex = 6, Visible = false,
		Parent = tabFrame,
	})
	UILib.corner(tag, 999)
	local grad = UILib.gradient(tag, C.GreenTop, C.Green)
	UILib.stroke(tag, C.Ink, 2.5, true)
	UILib.pad(tag, 8, 0, 8, 0)
	local label = UILib.text(tag, { text = "", size = 14, autoX = true, frameSize = UDim2.fromScale(0, 1), shadow = 1, stroke = 2, z = 6 })
	return function(text: string?, tone: string?)
		tag.Visible = text ~= nil
		if not text then return end
		local t = UILib.Tones[tone or "Green"] or UILib.Tones.Green
		grad.Color = ColorSequence.new(t.top, t.base)
		label.Text = text
	end
end

------------------------------------------------------------------
-- the REBIRTH page
------------------------------------------------------------------
local LW = 420 -- the goal card's width (design px)

local RESET_ROWS = {
	{ key = "cash", icon = "cash", text = "Cash" },
	{ key = "machines", icon = "slot", text = "Machines & stands" },
	{ key = "levels", icon = "upgrade", text = "Upgrade levels" },
	{ key = "floors", icon = "build", text = "Floors (back to 1)" },
	{ key = "staff", icon = "staff", text = "Staff" },
}
local KEEP_ROWS = {
	{ icon = "crown", text = "Casino Rank & XP" },
	{ icon = "plant", text = "Your decor" },
	{ icon = "rcoin", text = "Coins & the rebirth shop" },
	{ icon = "gem", text = "Robux items & potions" },
	{ icon = "ticket", text = "Tickets & stats" },
	{ icon = "star", text = "Casino name & colours" },
}

local function buildRebirthPage(parent: Instance, ctx)
	local page = make("Frame", { Name = "RebirthPage", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = parent })

	-- LEFT: the goal
	local card = make("Frame", { Name = "Goal", BackgroundColor3 = C.White, Size = UDim2.new(0, LW, 1, 0), Parent = page })
	UILib.corner(card, 22)
	UILib.gradient(card, C.Cream, C.CreamRow)
	UILib.stroke(card, C.Ink, 3.5, true)
	local burst = UILib.image(card, UILib.Tex.sunburst, {
		name = "Burst", size = UDim2.fromOffset(150, 150), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromOffset(78, 76),
		color = C.PurpleTop, transparency = 0.45,
	})
	UILib.spin(burst, 12)
	local med = UILib.medallion(card, { name = "RebirthChip", size = 108, number = "1", caption = "REBIRTH", position = UDim2.fromOffset(24, 22), z = 2 })
	local faceGrad = med.Face:FindFirstChildOfClass("UIGradient")
	if faceGrad then faceGrad.Color = ColorSequence.new(C.PurpleTop, C.PurpleShadow) end
	UILib.body(card, {
		text = "NEXT REBIRTH", font = F.Display, size = 16, color = C.Brown, transparency = 0.2,
		frameSize = UDim2.fromOffset(250, 20), position = UDim2.fromOffset(148, 24),
	})
	local title = UILib.text(card, {
		name = "Title", text = "REBIRTH 1", size = 40, color = C.Purple, xAlign = Enum.TextXAlignment.Left,
		frameSize = UDim2.fromOffset(262, 46), position = UDim2.fromOffset(146, 44), stroke = 3, shadow = 3,
	})
	UILib.body(card, {
		text = "Start fresh - come back stronger!", font = F.Heavy, size = 14, color = C.Brown,
		frameSize = UDim2.fromOffset(262, 18), position = UDim2.fromOffset(148, 96),
	})

	-- the requirement
	UILib.body(card, {
		text = "CASH ON HAND", font = F.Display, size = 17, color = C.Crimson,
		frameSize = UDim2.fromOffset(LW - 32, 22), position = UDim2.fromOffset(16, 138),
	})
	local bar = UILib.progressBar(card, {
		name = "CashBar", size = UDim2.fromOffset(LW - 32, 34), position = UDim2.fromOffset(16, 162), textSize = 17,
	})
	local need = UILib.body(card, {
		name = "Need", text = "", rich = true, font = F.Heavy, size = 14, color = C.Brown, xAlign = Enum.TextXAlignment.Center,
		frameSize = UDim2.fromOffset(LW - 32, 20), position = UDim2.fromOffset(16, 202),
	})

	-- what it pays
	local get = make("Frame", {
		Name = "YouGet", BackgroundColor3 = C.White, Position = UDim2.fromOffset(16, 232), Size = UDim2.fromOffset(LW - 32, 96),
		Parent = card,
	})
	UILib.corner(get, 18)
	UILib.gradient(get, C.GoldTop, C.Gold)
	UILib.stroke(get, C.Ink, 3, true)
	UILib.image(get, UILib.Tex.glow, {
		size = UDim2.fromOffset(150, 120), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromOffset(48, 48), transparency = 0.3,
	})
	local coinIcon = UILib.image(get, "rcoin", {
		name = "CoinIcon", size = UDim2.fromOffset(100, 100), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromOffset(48, 46), z = 2,
	})
	UILib.body(get, {
		text = "YOU GET", font = F.Display, size = 15, color = C.Brown, transparency = 0.15,
		frameSize = UDim2.fromOffset(200, 18), position = UDim2.fromOffset(100, 8),
	})
	local amountRow = make("Frame", {
		Name = "Amount", BackgroundTransparency = 1, Position = UDim2.fromOffset(98, 26), Size = UDim2.fromOffset(LW - 140, 42),
		Parent = get,
	})
	UILib.list(amountRow, "x", 8, nil, Enum.VerticalAlignment.Center)
	local coinsBig = UILib.text(amountRow, {
		name = "Coins", text = "+0", font = F.Number, size = 40, autoX = true, frameSize = UDim2.fromScale(0, 1), order = 1,
		stroke = 3.5, shadow = 3,
	})
	UILib.text(amountRow, {
		text = "REBIRTH COINS", size = 20, autoX = true, frameSize = UDim2.fromScale(0, 1), order = 2, stroke = 2.5, shadow = 2,
		gradient = { C.White, C.GoldTop },
	})
	local bonusLine = UILib.body(get, {
		name = "Bonus", text = "", rich = true, font = F.Heavy, size = 12, color = C.Brown, wrap = true,
		yAlign = Enum.TextYAlignment.Top, frameSize = UDim2.fromOffset(LW - 136, 26), position = UDim2.fromOffset(100, 67),
	})

	-- the button + what it starts you with
	local btn = UILib.button({
		parent = card, name = "RebirthButton", tone = "Gold", text = "REBIRTH!", icon = "rebirth", textSize = 30, iconSize = 46,
		size = UDim2.fromOffset(LW - 32, 70), position = UDim2.fromOffset(16, 342),
		onClick = function() ctx.press() end,
	})
	local foot = UILib.body(card, {
		name = "Foot", text = "", font = F.Heavy, size = 13, color = C.Brown, transparency = 0.1,
		xAlign = Enum.TextXAlignment.Center, frameSize = UDim2.fromOffset(LW - 32, 18), position = UDim2.fromOffset(16, 420),
	})

	-- RIGHT: unlocks, resets, keeps
	local RX = LW + 16
	local right = make("Frame", {
		Name = "Right", BackgroundTransparency = 1, Position = UDim2.fromOffset(RX, 0), Size = UDim2.new(1, -RX, 1, 0),
		Parent = page,
	})
	local ub = make("Frame", { Name = "Unlocks", BackgroundColor3 = C.Cream, Size = UDim2.new(1, 0, 0, 178), Parent = right })
	UILib.corner(ub, 20)
	UILib.stroke(ub, C.Ink, 3.5, true)
	local ubTitle = UILib.body(ub, {
		text = "", font = F.Display, size = 20, color = C.Crimson, frameSize = UDim2.new(1, -28, 0, 26),
		position = UDim2.fromOffset(14, 8),
	})
	local tiles = make("Frame", {
		Name = "Tiles", BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 42), Size = UDim2.new(1, -16, 0, 128),
		Parent = ub,
	})
	UILib.list(tiles, "x", 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	local rk = make("Frame", {
		Name = "ResetKeep", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 190), Size = UDim2.new(1, 0, 1, -190),
		Parent = right,
	})
	local _, resetLabels = listBox(rk, "RESETS", "Red", RESET_ROWS, UDim2.fromOffset(0, 0), UDim2.new(0.5, -6, 1, 0))
	listBox(rk, "YOU KEEP", "Green", KEEP_ROWS, UDim2.new(0.5, 6, 0, 0), UDim2.new(0.5, -6, 1, 0))

	local api = { Instance = page, Button = btn }
	local tilesKey = nil
	local ready = false
	function api.isReady(): boolean return ready end
	function api.update(state, cash: number)
		local st = rebirthState(state)
		if not st then return end
		local n = countOf(st) + 1
		med.set(n)
		title.Text = "REBIRTH " .. n
		local cost = nextCostOf(st)
		ready = cash >= cost
		bar.setTone(ready and "Green" or "Gold")
		bar.set(math.clamp(cash / math.max(1, cost), 0, 1),
			UILib.moneyShort(math.min(cash, cost)) .. " / " .. UILib.moneyShort(cost))
		if ready then
			need.Text = ('<font color="%s">READY!</font>  Rebirth whenever you like'):format(TXT_GOOD)
		else
			need.Text = ('<font color="%s">%s</font> more Cash to go'):format(TXT_RED, UILib.moneyShort(cost - cash))
		end
		local coins = coinsWith(st, cash)
		coinsBig.Text = "+" .. UILib.commas(coins)
		local parts = {}
		local mult = tonumber(st.coinMult) or 1
		if mult > 1 then table.insert(parts, ('<font color="%s">x%s PASS</font>'):format(TXT_MAX, tostring(mult))) end
		local bonus = tonumber(st.coinBonus) or 0
		if bonus > 0 then table.insert(parts, ('<font color="%s">+%d MAGNET</font>'):format(TXT_MAX, bonus)) end
		local atCost = coinsWith(st, cost)
		if coins > atCost then
			table.insert(parts, ('<font color="%s">+%d for extra Cash</font>'):format(TXT_GOOD, coins - atCost))
		else
			table.insert(parts, #parts > 0 and "More Cash = more coins" or "Bring more Cash for more coins (up to x2)")
		end
		bonusLine.Text = table.concat(parts, "  •  ")
		if ready then
			btn.setTone("Gold")
			btn.setIcon("rebirth")
			btn.setText("REBIRTH!")
		else
			btn.setTone("Purple")
			btn.setIcon("lock")
			btn.setText("NEED " .. UILib.moneyShort(cost))
		end
		local start = tonumber(st.startCash) or Config.StartingCash or 0
		foot.Text = ("You start over with %s - your rank and XP stay."):format(UILib.moneyShort(start))
		if resetLabels.cash then
			resetLabels.cash.Text = ("Cash (back to %s)"):format(UILib.moneyShort(start))
		end
		-- the unlock tiles (rebuilt when the next rebirth changes)
		local key = tostring(n)
		if key ~= tilesKey then
			tilesKey = key
			for _, ch in tiles:GetChildren() do
				if ch:IsA("GuiObject") then ch:Destroy() end
			end
			local items = unlockItems(st)
			ubTitle.Text = ("REBIRTH %d UNLOCKS"):format(n)
			local shown = #items <= 5 and #items or 4 -- five tiles fit the row
			for i = 1, shown do unlockTile(tiles, items[i], i) end
			if #items > shown then
				unlockTile(tiles, { kind = "more", id = "more", label = ("+%d more"):format(#items - shown), icon = "star", tone = "Purple" }, shown + 1)
			end
			if #items == 0 then
				local holder = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 120), Parent = tiles })
				UILib.image(holder, "rcoin", {
					size = UDim2.fromOffset(76, 76), anchor = Vector2.new(0.5, 0), position = UDim2.new(0.5, 0, 0, 0), rotation = -8,
				})
				UILib.body(holder, {
					text = "More rebirth coins for the REBIRTH SHOP!", font = F.Display, size = 17, color = C.Brown,
					xAlign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 0, 24), position = UDim2.fromOffset(0, 84),
				})
			end
		end
	end
	function api.pulse()
		if ready and page.Visible then
			UILib.fx("pop", btn.Instance, 1.06)
			UILib.fx("sparkle", coinIcon, 4, C.GoldTop)
		end
	end
	return api
end

------------------------------------------------------------------
-- the REBIRTH SHOP page
------------------------------------------------------------------
local ROW_H, ROW_GAP = 108, 12

local function drawPips(holder: Frame, lvl: number, max: number)
	for _, ch in holder:GetChildren() do
		if ch:IsA("GuiObject") then ch:Destroy() end
	end
	for i = 1, max do
		local owned = i <= lvl
		local p = make("Frame", {
			Name = "Pip", Size = UDim2.fromOffset(30, 12), BorderSizePixel = 0, LayoutOrder = i,
			BackgroundColor3 = owned and C.White or C.CreamLine, Parent = holder,
		})
		UILib.corner(p, 6)
		UILib.stroke(p, C.Ink, 2.5, true)
		if owned then UILib.gradient(p, C.PurpleTop, C.Purple) end
	end
	UILib.body(holder, {
		text = ("LV %d/%d"):format(lvl, max), font = F.Display, size = 15, color = C.Brown,
		frameSize = UDim2.fromOffset(70, 16), order = max + 1,
	})
end

local function effectText(def, lvl: number, max: number): string
	if lvl >= max then
		return ('<font color="%s">%s</font>   <font color="%s">ALL LEVELS OWNED</font>'):format(TXT_NEXT, describe(def, lvl), TXT_MAX)
	end
	return ('<font color="%s">%s</font>  <font color="%s">→</font>  <font color="%s">%s</font>'):format(
		TXT_NOW, describe(def, lvl), TXT_ARROW, TXT_NEXT, describe(def, lvl + 1))
end

local function buildShopRow(ctx, list: Instance, def, order: number)
	local row = UILib.row({
		parent = list, order = order, height = ROW_H, tone = def.tone, icon = def.icon,
		title = string.upper(def.name), desc = def.desc, rightWidth = 190, name = "Upgrade_" .. tostring(def.id),
	})
	local pips = make("Frame", { Name = "Pips", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 3, Parent = row.info })
	UILib.list(pips, "x", 6, nil, Enum.VerticalAlignment.Center)
	local effect = UILib.body(row.info, {
		name = "Effect", text = "", rich = true, size = 14, font = F.Heavy, frameSize = UDim2.new(1, 0, 0, 18), order = 4,
	})
	local r = { def = def, tile = row.Instance:FindFirstChild("Tile"), mode = "buy", cost = 0, level = 0, busy = false, drawn = nil }
	r.button = UILib.button({
		parent = row.right, tone = "Green", text = "", icon = "rcoin", textSize = 28, iconSize = 40,
		size = UDim2.fromOffset(166, 60), onClick = function() ctx.buy(r) end,
	})
	function r.update(st)
		local lvl = levelOf(st, def.id)
		local max = #def.values
		if lvl ~= r.drawn then
			r.drawn = lvl
			drawPips(pips, lvl, max)
		end
		effect.Text = effectText(def, lvl, max)
		r.level = lvl
		if lvl >= max then
			r.mode = "maxed"
			r.button.setTone("Purple")
			r.button.setIcon(nil)
			r.button.setText("MAXED")
		else
			r.mode = "buy"
			r.cost = tonumber(def.costs[lvl + 1]) or 0
			r.button.setIcon("rcoin")
			r.button.setText(tostring(r.cost))
			r.button.setTone(coinsHeld(st) >= r.cost and "Green" or "Red")
		end
	end
	return r
end

local function buildShopPage(parent: Instance, ctx)
	local page = make("Frame", { Name = "ShopPage", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, Parent = parent })
	UILib.body(page, {
		text = "Rebirth coins buy upgrades that last forever - a rebirth never takes them away.", size = 15,
		frameSize = UDim2.new(1, -8, 0, 26), position = UDim2.fromOffset(4, 0),
	})
	local list = UILib.scroller(page, { padding = ROW_GAP, position = UDim2.fromOffset(0, 30), size = UDim2.new(1, 0, 1, -30) })
	local rows = {}
	for i, def in upgradeDefs() do rows[def.id] = buildShopRow(ctx, list, def, i) end
	local api = { Instance = page, rows = rows }
	function api.update(state)
		local st = rebirthState(state)
		if not st then return end
		for _, r in rows do r.update(st) end
	end
	return api
end

------------------------------------------------------------------
-- the confirm card (inside the panel)
------------------------------------------------------------------
local function confirm(ctx)
	local state = UILib.state
	local st = rebirthState(state)
	if not st or ctx.confirmOpen then return end
	ctx.confirmOpen = true
	local n = countOf(st) + 1
	local cash = ctx.cash()
	local coins = coinsWith(st, cash)
	local machines, levels, stories, staff = losses(state)

	local overlay = make("TextButton", {
		Name = "Confirm", Text = "", AutoButtonColor = false, BackgroundColor3 = C.Ink, BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1), ZIndex = 20, Parent = ctx.content,
	})
	UILib.tween(overlay, { BackgroundTransparency = 0.35 }, 0.15)
	local card = make("Frame", {
		Name = "Card", BackgroundColor3 = C.White, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.52),
		Size = UDim2.fromOffset(620, 360), ZIndex = 21, Parent = overlay,
	})
	local pop = make("UIScale", { Scale = 0.7, Parent = card }) :: UIScale
	UILib.tween(pop, { Scale = 1 }, 0.28, Enum.EasingStyle.Back)
	UILib.corner(card, 26)
	UILib.gradient(card, C.Cream, C.CreamRow)
	UILib.stroke(card, C.Crimson, 5, true)
	UILib.image(card, "rebirth", {
		size = UDim2.fromOffset(96, 96), anchor = Vector2.new(0.5, 0.5), position = UDim2.new(0.5, 0, 0, 4), rotation = -8, z = 22,
	})
	UILib.text(card, {
		text = ("REBIRTH %d?"):format(n), size = 42, color = C.Crimson, frameSize = UDim2.new(1, -40, 0, 48),
		position = UDim2.fromOffset(20, 48), stroke = 3.5, shadow = 3, z = 22,
	})
	local lose = {}
	table.insert(lose, ("<b>%s</b> Cash"):format(UILib.moneyShort(cash)))
	if machines > 0 then table.insert(lose, ("<b>%d</b> machine%s"):format(machines, machines == 1 and "" or "s")) end
	if levels > 0 then table.insert(lose, ("<b>%d</b> upgrade level%s"):format(levels, levels == 1 and "" or "s")) end
	if stories == 2 then
		table.insert(lose, "floor <b>2</b>")
	elseif stories > 2 then
		table.insert(lose, ("floors <b>2-%d</b>"):format(stories))
	end
	if staff > 0 then table.insert(lose, ("<b>%d</b> staff"):format(staff)) end
	UILib.body(card, {
		text = ('<font color="%s">YOU LOSE</font>  '):format(TXT_RED) .. table.concat(lose, ", "),
		rich = true, font = F.Heavy, size = 16, color = C.Brown, wrap = true, xAlign = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, -60, 0, 44), position = UDim2.fromOffset(30, 102), z = 22,
	})
	UILib.body(card, {
		text = ('<font color="%s">YOU KEEP</font>  your Casino Rank, XP, decor, coins and everything bought with Robux'):format(TXT_GOOD),
		rich = true, font = F.Heavy, size = 15, color = C.Brown, wrap = true, xAlign = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, -60, 0, 40), position = UDim2.fromOffset(30, 148), z = 22,
	})
	-- what you get
	local getRow = make("Frame", {
		Name = "Get", BackgroundColor3 = C.White, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 196),
		Size = UDim2.fromOffset(0, 54), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 22, Parent = card,
	})
	UILib.corner(getRow, 999)
	UILib.gradient(getRow, C.GoldTop, C.Gold)
	UILib.stroke(getRow, C.Ink, 3, true)
	UILib.pad(getRow, 58, 0, 20, 0)
	UILib.image(getRow, "rcoin", {
		size = UDim2.fromOffset(66, 66), anchor = Vector2.new(0, 0.5), position = UDim2.new(0, -64, 0.5, 0), z = 23,
	})
	local items = unlockItems(st)
	local names = {}
	for i = 1, math.min(2, #items) do table.insert(names, items[i].label) end
	local getText = ("+%s REBIRTH COINS"):format(UILib.commas(coins))
	if #names > 0 then
		getText ..= "  •  NEW: " .. string.upper(table.concat(names, ", ")) .. (#items > 2 and " ..." or "")
	end
	UILib.text(getRow, {
		text = getText, size = 20, autoX = true, frameSize = UDim2.fromScale(0, 1), stroke = 2.5, shadow = 2, z = 23,
	})

	local function close()
		ctx.confirmOpen = false
		if overlay.Parent then
			UILib.tween(pop, { Scale = 0.75 }, 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			UILib.tween(overlay, { BackgroundTransparency = 1 }, 0.12)
			task.delay(0.13, function() overlay:Destroy() end)
		end
	end
	local buttons = make("Frame", {
		Name = "Buttons", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 272), Size = UDim2.new(1, 0, 0, 66),
		ZIndex = 22, Parent = card,
	})
	UILib.list(buttons, "x", 18, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	local go
	go = UILib.button({
		parent = buttons, tone = "Red", text = "REBIRTH!", icon = "rebirth", textSize = 30, iconSize = 44,
		size = UDim2.fromOffset(270, 64), order = 1, z = 22,
		onClick = function()
			if ctx.busy then return end
			ctx.busy = true
			go.setEnabled(false)
			go.setText("...")
			-- a machine being placed would land in a casino that's gone
			local pc = deps.PlacementController
			if pc and type(pc.isBusy) == "function" and pc.isBusy() and type(pc.cancel) == "function" then
				pcall(pc.cancel)
			end
			local ok, res = pcall(function() return Remotes.Rebirth():InvokeServer(n) end)
			ctx.busy = false
			if ok and type(res) == "table" and res.ok then
				close()
				ctx.close() -- the RebirthDone fanfare takes over
			else
				go.setEnabled(true)
				go.setText("REBIRTH!")
				UILib.toast(ok and type(res) == "table" and res.message or "Rebirth failed - try again.", "error")
			end
		end,
	})
	UILib.button({
		parent = buttons, tone = "Blue", text = "NOT YET", textSize = 28, size = UDim2.fromOffset(220, 64), order = 2, z = 22,
		onClick = close,
	})
	overlay.Activated:Connect(function()
		if not ctx.busy then close() end
	end)
end

------------------------------------------------------------------
-- the panel
------------------------------------------------------------------
local TABS = { { id = "rebirth", label = "REBIRTH" }, { id = "shop", label = "REBIRTH SHOP" } }

function RebirthUI.open(tab: any?)
	local initial = (tab == "shop") and "shop" or "rebirth"
	if tab ~= "shop" and tab ~= "rebirth" then
		-- from the HUD tile: straight to the shop when that's what its alert is about
		local st = rebirthState(UILib.state)
		local okCash, cashNow = pcall(function() return UILib.getCashValue().Value end)
		if st and affordableCount(st) > 0 and okCash and cashNow < nextCostOf(st) then initial = "shop" end
	end
	local p = UILib.panel({ name = "RebirthPanel", title = "REBIRTH", icon = "rebirth", width = 1000, height = 620 })
	local content = p.content
	if not (Config.Rebirth and Config.RebirthUpgrades) or not rebirthState(UILib.state) then
		UILib.image(content, "rebirth", {
			size = UDim2.fromOffset(160, 160), anchor = Vector2.new(0.5, 0), position = UDim2.new(0.5, 0, 0, 90),
		})
		UILib.body(content, {
			text = "Rebirths open as soon as your casino reports in - try again in a moment!", font = F.Display, size = 22,
			color = C.Brown, wrap = true, xAlign = Enum.TextXAlignment.Center,
			frameSize = UDim2.new(1, -80, 0, 70), position = UDim2.fromOffset(40, 270),
		})
		return
	end
	local cashValue = UILib.getCashValue()
	local ctx = { content = content, confirmOpen = false, busy = false }
	function ctx.cash(): number return cashValue.Value end
	function ctx.close() p.close() end

	-- the coin balance (top right, beside the tabs)
	local coinPill = make("Frame", {
		Name = "CoinBalance", BackgroundColor3 = C.White, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -6, 0, 5),
		Size = UDim2.fromOffset(0, 42), AutomaticSize = Enum.AutomaticSize.X, Parent = content,
	})
	UILib.corner(coinPill, 999)
	UILib.gradient(coinPill, C.PurpleTop, C.Purple)
	UILib.stroke(coinPill, C.Ink, 3, true)
	UILib.pad(coinPill, 50, 0, 16, 0)
	UILib.image(coinPill, "rcoin", {
		size = UDim2.fromOffset(58, 58), anchor = Vector2.new(0, 0.5), position = UDim2.new(0, -56, 0.5, -1), z = 2,
	})
	local coinText = UILib.text(coinPill, { text = "0 COINS", size = 22, autoX = true, frameSize = UDim2.fromScale(0, 1), stroke = 2.5, shadow = 2 })

	local body = make("Frame", {
		Name = "Body", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 60), Size = UDim2.new(1, 0, 1, -60),
		Parent = content,
	})
	local rebirthPage
	rebirthPage = buildRebirthPage(body, {
		press = function()
			if rebirthPage.isReady() then
				confirm(ctx)
			else
				local st = rebirthState(UILib.state)
				local left = st and (nextCostOf(st) - ctx.cash()) or 0
				UILib.toast("NOT YET!", "info", ("Save %s more Cash on hand to rebirth."):format(UILib.moneyShort(math.max(0, left))))
			end
		end,
	})
	local shopCtx = {}
	local shopPage
	function shopCtx.buy(r)
		if r.busy then return end
		if r.mode == "maxed" then
			UILib.fx("pop", r.button.Instance, 1.08)
			return
		end
		local st = rebirthState(UILib.state)
		if coinsHeld(st) < r.cost then
			UILib.toast(("NEEDS %d COINS"):format(r.cost), "error", "Rebirth to earn more rebirth coins.")
			return
		end
		r.busy = true
		local ok, res = pcall(function() return Remotes.BuyRebirthUpgrade():InvokeServer(r.def.id) end)
		r.busy = false
		if ok and type(res) == "table" and res.ok then
			local lvl = tonumber(res.level) or (r.level + 1)
			UILib.toast(("%s  LV %d"):format(string.upper(r.def.name), lvl), "unlock", describe(r.def, lvl))
			local live = shopPage and shopPage.rows[r.def.id]
			local tile = live and live.tile
			if tile and tile.Parent then
				UILib.fx("pop", tile, 1.25)
				if lvl >= #r.def.values then
					UILib.fx("celebrate", "small", tile)
					UILib.fx("confetti", tile, 26, "night")
				end
			end
		else
			UILib.toast(ok and type(res) == "table" and res.message or "Purchase failed", "error")
		end
	end
	shopPage = buildShopPage(body, shopCtx)

	local setTag = {}
	local function render()
		if not p.alive then return end
		local state = UILib.state
		local st = rebirthState(state)
		if not st then return end
		local cash = ctx.cash()
		local coins = coinsHeld(st)
		coinText.Text = ("%s COIN%s"):format(UILib.commas(coins), coins == 1 and "" or "S")
		rebirthPage.update(state, cash)
		shopPage.update(state)
		if setTag.rebirth then setTag.rebirth(cash >= nextCostOf(st) and "READY" or nil, "Green") end
		if setTag.shop then
			local n = affordableCount(st)
			setTag.shop(n > 0 and tostring(n) or nil, "Green")
		end
	end

	local tabsApi = UILib.tabs(content, TABS, function(id)
		rebirthPage.Instance.Visible = id == "rebirth"
		shopPage.Instance.Visible = id == "shop"
		if id == "shop" then
			shopPage.Instance:FindFirstChildWhichIsA("ScrollingFrame").CanvasPosition = Vector2.zero
		end
	end, initial)
	for _, t in TABS do
		local frame = tabsApi.Instance:FindFirstChild("Tab_" .. t.id)
		if frame then setTag[t.id] = makeTag(frame) end
	end
	rebirthPage.Instance.Visible = initial == "rebirth"
	shopPage.Instance.Visible = initial == "shop"
	render()

	-- live: snapshots, Cash (throttled), the ready button's pulse
	local unsub = UILib.subscribe(function() render() end)
	local pendingCash = false
	local cashConn = cashValue.Changed:Connect(function()
		if pendingCash then return end
		pendingCash = true
		task.delay(0.25, function()
			pendingCash = false
			render()
		end)
	end)
	p.onClose(function()
		unsub()
		cashConn:Disconnect()
	end)
	task.spawn(function()
		while p.alive do
			task.wait(1.6)
			if p.alive then rebirthPage.pulse() end
		end
	end)
end

------------------------------------------------------------------
-- the fanfare (Remotes.RebirthDone)
------------------------------------------------------------------
local function onRebirthDone(payload)
	if type(payload) ~= "table" then return end
	local n = math.floor(tonumber(payload.count) or 0)
	local coins = math.floor(tonumber(payload.coins) or 0)
	UILib.closeActivePanel()
	local hasFx = UILib.FX ~= nil
	UILib.fx("banner", "REBIRTH!", ("REBIRTH %d  •  +%s REBIRTH COINS"):format(n, UILib.commas(coins)), "purple")
	UILib.fx("flash", C.PurpleTop, 0.55)
	local anchor = UILib.fxTargets.rank
	UILib.fx("celebrate", "big", (typeof(anchor) == "Instance" and anchor.Parent) and anchor or nil)
	task.delay(0.5, function() UILib.fx("confetti", nil, 60, "night") end)
	-- what it unlocked: NEW in the Showroom / shop
	local names = {}
	local u = type(payload.unlocks) == "table" and payload.unlocks or {}
	for _, id in (type(u.machines) == "table" and u.machines or {}) do
		UILib.markNew("machine", id)
		local def = Config.getMachineDef(id)
		table.insert(names, def and def.name or tostring(id))
	end
	for _, id in (type(u.decor) == "table" and u.decor or {}) do
		UILib.markNew("decor", id)
		local def = Config.getDecorDef and Config.getDecorDef(id)
		table.insert(names, def and def.name or tostring(id))
	end
	if not hasFx then
		UILib.toast(("REBIRTH %d!"):format(n), "unlock", ("+%s rebirth coins"):format(UILib.commas(coins)))
	end
	task.delay(hasFx and 3.4 or 1.2, function()
		if #names > 0 then
			UILib.toast("NEW UNLOCKS!", "unlock", table.concat(names, ", ", 1, math.min(3, #names)) .. (#names > 3 and " ..." or ""))
		end
		local st = rebirthState(UILib.state)
		if st and affordableCount(st) > 0 and not UILib.hasOpenPanel() then
			RebirthUI.open("shop")
		else
			UILib.toast("FRESH START!", "info", "Buy machines and build your casino back up - your rank stays.")
		end
	end)
end

------------------------------------------------------------------
-- the HUD tile's alert + the "ready" toast
------------------------------------------------------------------
local readyToasted: {[number]: boolean} = {}
local lastAlert = nil

local function refreshAlert(cash: number)
	local hud = deps.HudUI
	local tile = hud and hud.tiles and hud.tiles.REBIRTH
	local st = rebirthState(UILib.state)
	local ready = st ~= nil and cash >= nextCostOf(st)
	local on = st ~= nil and (ready or affordableCount(st) > 0)
	if tile and on ~= lastAlert then
		lastAlert = on
		tile.setAlert(on)
	end
	if ready then
		local n = countOf(st) + 1
		if not readyToasted[n] then
			readyToasted[n] = true
			if tile and tile.Instance then UILib.fx("sparkle", tile.Instance, 8, C.PurpleTop) end
			UILib.toast("REBIRTH READY!", "unlock", ("Rebirth %d pays +%s coins - tap REBIRTH."):format(n, UILib.commas(coinsWith(st, cash))))
		end
	end
end

function RebirthUI.start(d): boolean
	if started then return true end
	started = true
	deps = type(d) == "table" and d or {}
	-- the fanfare
	task.spawn(function()
		local ok, ev = pcall(function() return Remotes.RebirthDone() end)
		if ok and typeof(ev) == "Instance" and ev:IsA("RemoteEvent") then
			ev.OnClientEvent:Connect(function(payload)
				local fine, err = pcall(onRebirthDone, payload)
				if not fine then warn("[RebirthUI] rebirth fanfare: " .. tostring(err)) end
			end)
		else
			warn("[RebirthUI] RebirthDone remote missing.")
		end
	end)
	-- the HUD alert: snapshots + Cash (throttled)
	task.spawn(function()
		local cashValue = UILib.getCashValue()
		local function run()
			local ok, err = pcall(refreshAlert, cashValue.Value)
			if not ok then warn("[RebirthUI] alert: " .. tostring(err)) end
		end
		UILib.subscribe(function() run() end)
		local pending = false
		cashValue.Changed:Connect(function()
			if pending then return end
			pending = true
			task.delay(0.5, function()
				pending = false
				run()
			end)
		end)
		run()
	end)
	return true
end

return RebirthUI
