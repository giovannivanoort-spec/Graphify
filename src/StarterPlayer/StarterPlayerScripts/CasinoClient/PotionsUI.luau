--!nonstrict
-- PotionsUI.luau — your potions (Config.Potions; server: Potions.luau):
--   * the POTIONS panel: a tile per potion (two columns) with how many you own,
--     USE, the time left while it runs (timers only tick while you play) and BUY with
--     Robux (into your stock) or Tickets (the Ticket Shop's potion items)
--   * HUD chips (HudUI.addChip, order 10+): "POTIONS x3" while you own unused potions
--     and one countdown chip per running potion ("2X CASH 12:34"); clicking a chip
--     opens the panel
--   * toasts when a potion runs out and when a Robux potion lands in your stock
-- Snapshot field `potions` = { owned = { id = n }, active = { id = seconds left },
-- perUse = { id = seconds one use adds }, maxStack }.
-- PotionsUI.open(focusId?)   PotionsUI.start(deps)   (deps: HudUI, RobuxShopUI, ...)

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local Config = require(Common:WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local F = UILib.Fonts

local PotionsUI = {}
local player = Players.LocalPlayer
local deps = {}
local started = false

local TILE = Vector2.new(466, 128)   -- two tiles side by side fill the panel
local ROBUX_TOAST_WINDOW = 30        -- s after a Robux potion purchase its arrival gets a toast

------------------------------------------------------------------
-- state helpers (UILib.state.potions)
------------------------------------------------------------------
local function potionState()
	local st = UILib.state and UILib.state.potions
	return type(st) == "table" and st or nil
end

local function ownedOf(id: string): number
	local st = potionState()
	local owned = st and st.owned
	return type(owned) == "table" and math.max(0, math.floor(tonumber(owned[id]) or 0)) or 0
end

-- seconds left on a running potion, counted down since the snapshot arrived
local function leftOf(id: string): number
	local st = potionState()
	local active = st and st.active
	local v = type(active) == "table" and tonumber(active[id]) or 0
	return v > 0 and UILib.secondsLeft(v) or 0
end

local function perUseOf(def): number
	local st = potionState()
	local per = st and st.perUse
	return (type(per) == "table" and tonumber(per[def.id])) or (tonumber(def.minutes) or 15) * 60
end

local function ticketItem(def)
	return Config.getTicketItem("potion_" .. def.id)
end

-- the store module (required lazily: it requires this one for its MY POTIONS button)
local function store()
	if deps.RobuxShopUI then return deps.RobuxShopUI end
	local mod = script.Parent:FindFirstChild("RobuxShopUI")
	if not mod then return nil end
	local ok, res = pcall(require, mod)
	return ok and type(res) == "table" and res or nil
end

------------------------------------------------------------------
-- actions
------------------------------------------------------------------
local function usePotion(def, fromGui: GuiObject?)
	local ok, res = pcall(function() return Remotes.UsePotion():InvokeServer(def.id) end)
	if ok and type(res) == "table" and res.ok then
		UILib.toast(string.upper(def.short or def.name) .. "!", "unlock", res.message)
		local tone = UILib.Tones[def.tone] or UILib.Tones.Gold
		if fromGui then UILib.fx("sparkle", fromGui, 8, tone.top) end
		if def.id == "mega" then UILib.fx("banner", "MEGA POTION!", "Every potion at once", "purple") end
		return true
	end
	UILib.toast(ok and type(res) == "table" and res.message or "Couldn't use that potion.", "error")
	return false
end

local function buyRobux(def)
	local prod = Config.potionProduct(def.id)
	local s = store()
	if not (s and s.promptProduct) then
		UILib.toast("Store unavailable", "error")
		return
	end
	s.promptProduct(prod and prod.id or 0)
end

local function buyTickets(def)
	local item = ticketItem(def)
	if not item then return end
	local ok, res = pcall(function() return Remotes.BuyTicketItem():InvokeServer(item.id) end)
	if ok and type(res) == "table" and res.ok then
		UILib.toast(string.upper(def.name) .. "!", "ticket", res.message)
	else
		UILib.toast(ok and type(res) == "table" and res.message or "Purchase failed", "error")
	end
end

------------------------------------------------------------------
-- a potion tile: icon (+ count), name, what it does, timer / per-use time,
-- USE on top, R$ and Tickets below
------------------------------------------------------------------
local function buildTile(parent: Instance, def, order: number)
	local tone = UILib.Tones[def.tone] or UILib.Tones.Gold
	local root = UILib.make("Frame", {
		Name = "Potion_" .. def.id, BackgroundColor3 = C.White, Size = UDim2.fromOffset(TILE.X, TILE.Y),
		LayoutOrder = order, Parent = parent,
	})
	UILib.corner(root, 22)
	UILib.gradient(root, C.Cream, C.CreamRow)
	local rim = UILib.stroke(root, C.Ink, 3.5, true)

	-- the icon on its tone tile, a glow behind it while the potion runs
	local aura = UILib.image(root, UILib.Tex.glow, {
		name = "Aura", size = UDim2.fromOffset(170, 170), anchor = Vector2.new(0.5, 0.5),
		position = UDim2.fromOffset(64, 64), color = tone.top, transparency = 0.2,
	})
	aura.Visible = false
	local iconTile = UILib.make("Frame", {
		Name = "IconTile", BackgroundColor3 = C.White, Position = UDim2.fromOffset(12, 12),
		Size = UDim2.fromOffset(104, 104), Parent = root,
	})
	UILib.corner(iconTile, 18)
	UILib.gradient(iconTile, tone.top, tone.base)
	UILib.stroke(iconTile, C.Ink, 3.5, true)
	UILib.image(iconTile, UILib.Tex.glow, {
		size = UDim2.fromScale(1.15, 1.15), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5),
		transparency = 0.4,
	})
	UILib.image(iconTile, def.icon, {
		size = UDim2.fromScale(1.08, 1.08), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.46),
	})
	-- how many you own: an ink pill on the tile's corner
	local countPill = UILib.make("Frame", {
		Name = "Count", BackgroundColor3 = C.Ink, AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 8, 1, 8), Size = UDim2.fromOffset(0, 30), AutomaticSize = Enum.AutomaticSize.X,
		ZIndex = 3, Parent = iconTile,
	})
	UILib.corner(countPill, 999)
	UILib.stroke(countPill, C.GoldDeep, 2.5, true)
	UILib.pad(countPill, 10, 0, 10, 0)
	local countText = UILib.text(countPill, {
		text = "x0", font = F.Number, size = 18, autoX = true, frameSize = UDim2.fromScale(0, 1), z = 3,
		color = C.GoldTop, stroke = 2, shadow = 2,
	})
	local activeBadge = UILib.badge(root, "ACTIVE", def.tone or "Gold", -8, 6)
	activeBadge.Position = UDim2.fromOffset(-6, -10)
	activeBadge.Visible = false

	-- name + what it does (the text column stops 14 px short of the buttons: their
	-- stroke and hover grow reach past their edge)
	local textW = TILE.X - 162 - 128 - 14
	local title = UILib.body(root, {
		name = "Title", text = string.upper(def.name), font = F.Display, size = 24, color = C.Crimson,
		frameSize = UDim2.fromOffset(textW, 28), position = UDim2.fromOffset(128, 10),
	})
	UILib.fitText(title, string.upper(def.name), 24, textW, 15)
	UILib.body(root, {
		name = "Desc", text = def.desc or "", size = 14, wrap = true, color = C.Brown,
		frameSize = UDim2.fromOffset(textW, 38), position = UDim2.fromOffset(128, 40),
		yAlign = Enum.TextYAlignment.Top,
	})
	-- the timer while it runs, else what one use adds
	local bar = UILib.progressBar(root, {
		name = "Timer", size = UDim2.fromOffset(textW, 24), position = UDim2.fromOffset(128, 90),
		tone = def.tone or "Gold", textSize = 14,
	})
	local idle = UILib.body(root, {
		name = "PerUse", text = "", font = F.Display, size = 16, color = C.Brown, transparency = 0.2,
		frameSize = UDim2.fromOffset(textW, 24), position = UDim2.fromOffset(128, 90),
	})

	-- buttons: USE, then R$ | Tickets
	local bx = TILE.X - 162
	local useBtn
	useBtn = UILib.button({
		parent = root, tone = "Green", text = "USE", textSize = 26, size = UDim2.fromOffset(150, 56),
		position = UDim2.fromOffset(bx, 10),
		onClick = function() usePotion(def, useBtn and useBtn.Instance) end,
	})
	local prod = Config.potionProduct(def.id)
	local robuxBtn = UILib.button({
		parent = root, tone = (prod and prod.id ~= 0) and "Gold" or "Purple", text = "R$", textSize = 17,
		size = UDim2.fromOffset(72, 44), position = UDim2.fromOffset(bx, 74), radius = 12,
		onClick = function() buyRobux(def) end,
	})
	local s = store()
	if s and s.priceText then
		s.priceText(prod and prod.id or 0, Enum.InfoType.Product, function(text)
			if robuxBtn.Instance.Parent then robuxBtn.setText(text) end
		end)
	else
		robuxBtn.setText("SOON")
	end
	local item = ticketItem(def)
	local ticketBtn = UILib.button({
		parent = root, tone = "Pink", text = item and UILib.commas(item.cost) or "-", icon = "ticket", textSize = 17,
		iconSize = 22, size = UDim2.fromOffset(72, 44), position = UDim2.fromOffset(bx + 78, 74), radius = 12,
		onClick = function() buyTickets(def) end,
	})
	if not item then ticketBtn.setEnabled(false) end

	local api = { Instance = root, def = def }
	local peak = 0   -- the timer bar is full at the most time seen since the panel opened
	local function setTimer(left: number)
		if left > peak then peak = left end
		bar.set(math.clamp(left / math.max(1, peak), 0, 1), UILib.clock(left) .. " LEFT")
	end
	function api.refresh()
		local have = ownedOf(def.id)
		local left = leftOf(def.id)
		local per = perUseOf(def)
		countText.Text = "x" .. have
		countPill.Visible = have > 0
		useBtn.setEnabled(have > 0)
		if left > 0 then
			if peak <= 0 then peak = math.max(per, left) end
			bar.Instance.Visible = true
			idle.Visible = false
			setTimer(left)
			rim.Color = C.GoldDeep
			rim.Thickness = 5
			activeBadge.Visible = true
			aura.Visible = true
		else
			peak = 0
			bar.Instance.Visible = false
			idle.Visible = true
			idle.Text = ("+%s PER USE"):format(UILib.clock(per))
			rim.Color = C.Ink
			rim.Thickness = 3.5
			activeBadge.Visible = false
			aura.Visible = false
		end
		if item then ticketBtn.setTone((tonumber(UILib.state.tickets) or 0) >= item.cost and "Pink" or "Red") end
	end
	-- 1 Hz: the countdown only (a potion that just ran out re-renders the tile)
	function api.tick()
		local left = leftOf(def.id)
		if left > 0 and bar.Instance.Visible then
			setTimer(left)
		elseif (left > 0) ~= bar.Instance.Visible then
			api.refresh()
		end
	end
	api.refresh()
	return api
end

------------------------------------------------------------------
-- the panel
------------------------------------------------------------------
function PotionsUI.open(focusId: any)
	if type(focusId) ~= "string" then focusId = nil end
	local p = UILib.panel({ name = "PotionsPanel", title = "POTIONS", icon = "potion_mega", width = 1060, height = 620 })
	local content = p.content

	local top = UILib.make("Frame", {
		Name = "Top", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 48), Parent = content,
	})
	local summary = UILib.body(top, {
		name = "Summary", text = "", rich = true, wrap = true, size = 15, color = C.Brown,
		frameSize = UDim2.new(1, -220, 1, 0),
	})
	UILib.button({
		parent = top, tone = "Gold", text = "STORE", icon = "gem", textSize = 20, iconSize = 30,
		size = UDim2.fromOffset(190, 48), anchor = Vector2.new(1, 0), position = UDim2.new(1, -4, 0, 0),
		onClick = function()
			local s = store()
			if s and s.open then s.open("potions") end
		end,
	})

	local grid = UILib.scroller(content, {
		grid = true, cell = UDim2.fromOffset(TILE.X, TILE.Y), gap = UDim2.fromOffset(16, 14),
		position = UDim2.fromOffset(0, 54), size = UDim2.new(1, 0, 1, -54),
	})
	local tiles = {}
	for i, def in Config.Potions do
		tiles[def.id] = buildTile(grid, def, i)
	end

	local function refreshAll()
		if not p.alive then return end
		local running = {}
		for _, def in Config.Potions do
			local t = tiles[def.id]
			if t then t.refresh() end
			local left = leftOf(def.id)
			if left > 0 then table.insert(running, ("<b>%s</b> %s"):format(def.short or def.name, UILib.clock(left))) end
		end
		summary.Text = #running > 0
			and ("ACTIVE: %s. Using one again ADDS time."):format(table.concat(running, ", "))
			or "Use a potion to supercharge your casino! Timers only run while you play, and using one again ADDS time."
	end
	refreshAll()
	local unsub = UILib.subscribe(function() refreshAll() end)
	p.onClose(unsub)
	task.spawn(function()
		local beat = 0
		while p.alive do
			task.wait(1)
			if not p.alive then break end
			beat += 1
			for _, t in tiles do t.tick() end
			if beat % 5 == 0 then refreshAll() end
		end
	end)

	-- a chip / reward that pointed at one potion: make it pop
	local focus = focusId and tiles[focusId]
	if focus then
		task.delay(0.35, function()
			if not (p.alive and focus.Instance.Parent) then return end
			UILib.fx("pop", focus.Instance, 1.06)
			local tone = UILib.Tones[focus.def.tone] or UILib.Tones.Gold
			UILib.fx("sparkle", focus.Instance, 6, tone.top)
		end)
	end
end

------------------------------------------------------------------
-- HUD chips + toasts
------------------------------------------------------------------
-- a HudUI chip (a Frame) that opens something when clicked / tapped
local function clickable(handle, fn)
	local f = handle and handle.Instance
	if not (f and f:IsA("GuiObject")) then return end
	f.Active = true
	f.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			UILib.emit("press", f)
			UILib.fx("pop", f, 1.12)
			fn()
		end
	end)
end

local chips = {}       -- potion id -> chip handle
local stockChip = nil  -- "POTIONS x3"

local function refreshChips()
	local total = 0
	for _, def in Config.Potions do
		total += ownedOf(def.id)
		local chip = chips[def.id]
		if chip then
			local left = leftOf(def.id)
			chip.show(left > 0)
			if left > 0 then chip.set(("%s  %s"):format(def.short or string.upper(def.name), UILib.clock(left))) end
		end
	end
	if stockChip then
		stockChip.show(total > 0)
		if total > 0 then stockChip.set(("POTIONS x%d"):format(total)) end
	end
end

local function isPotionProduct(productId: number): boolean
	for _, p in (Config.Monetization.PotionProducts or {}) do
		if p.id ~= 0 and p.id == productId then return true end
	end
	return false
end

function PotionsUI.start(d)
	deps = type(d) == "table" and d or {}
	if started then return end
	started = true

	local Hud = deps.HudUI
	if Hud and type(Hud.addChip) == "function" then
		stockChip = Hud.addChip("potions_owned", "Purple", "potion_mega", 10)
		clickable(stockChip, function() PotionsUI.open() end)
		for i, def in Config.Potions do
			local chip = Hud.addChip("potion_" .. def.id, def.tone or "Gold", def.icon, 10 + i)
			clickable(chip, function() PotionsUI.open(def.id) end)
			chips[def.id] = chip
		end
	end

	-- a Robux potion: its arrival in the stock gets a toast
	local robuxAt = -math.huge
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, purchased)
		if purchased and userId == player.UserId and isPotionProduct(productId) then robuxAt = os.clock() end
	end)

	local prevOwned, prevActive = nil, nil
	UILib.subscribe(function(state)
		local st = type(state) == "table" and state.potions
		if type(st) ~= "table" then return end
		local owned = type(st.owned) == "table" and st.owned or {}
		local active = type(st.active) == "table" and st.active or {}
		if prevOwned then
			for _, def in Config.Potions do
				local now, before = tonumber(owned[def.id]) or 0, tonumber(prevOwned[def.id]) or 0
				if now > before and os.clock() - robuxAt < ROBUX_TOAST_WINDOW then
					robuxAt = -math.huge
					UILib.toast(("+%d %s!"):format(now - before, string.upper(def.name)), "unlock",
						"It's in your potions - tap the POTIONS chip to use it.")
				end
				-- a potion that ran out (not one that was just used up from the stock)
				if (tonumber(prevActive[def.id]) or 0) > 0 and (tonumber(active[def.id]) or 0) <= 0 then
					local more = tonumber(owned[def.id]) or 0
					UILib.toast(string.upper(def.name) .. " ENDED", "info",
						more > 0 and ("You have %d more - tap the POTIONS chip."):format(more) or "Get more in the STORE.")
				end
			end
		end
		prevOwned, prevActive = table.clone(owned), table.clone(active)
		refreshChips()
	end)

	task.spawn(function()
		while true do
			task.wait(1)
			local ok, err = pcall(refreshChips)
			if not ok then warn("[PotionsUI] chips: " .. tostring(err)) end
		end
	end)
end

return PotionsUI
