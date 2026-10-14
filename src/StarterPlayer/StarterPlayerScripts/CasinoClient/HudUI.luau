--!nonstrict
-- HudUI.luau — always-on HUD in the Showtime style:
--   top-left : Cash + Tickets pills (count-up, "+$X" floats on income), VIP / boost chips
--   left     : 2x3 grid of action tiles (each its own tone, 3D icon overflowing the tile)
--   right    : Store + Daily tiles (Daily pulses when a reward is ready)
--   bottom   : income ticker ($/min over the last minute + machines placed)
-- Each cluster carries its own viewport UIScale anchored to its corner.

local Players = game:GetService("Players")
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local F = UILib.Fonts

local HudUI = {}
local player = Players.LocalPlayer

function HudUI.build(openers)
	openers = openers or {}
	local screen = UILib.getScreen()
	for _, n in { "HudLeft", "HudRight", "HudBottom" } do
		local old = screen:FindFirstChild(n)
		if old then old:Destroy() end
	end
	local touchMult = UILib.IsTouch and 1.12 or 1

	------------------------------------------------------------------
	-- left cluster: currencies, chips, action grid
	------------------------------------------------------------------
	local left = UILib.make("Frame", {
		Name = "HudLeft", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.fromOffset(14, 14), Size = UDim2.fromOffset(540, 480), Parent = screen,
	})
	UILib.autoScale(left, { mult = touchMult })

	local cashValue = UILib.getCashValue()
	local cash = UILib.currencyPill(left, {
		name = "CashPill", icon = "coin", text = UILib.money(cashValue.Value),
		position = UDim2.fromOffset(24, 4), plusTone = "Green",
		onPlus = function() if openers.onStore then openers.onStore("cash") end end,
	})
	local tickets = UILib.currencyPill(left, {
		name = "TicketPill", icon = "ticket", text = "0", width = 200,
		position = UDim2.fromOffset(280, 4), plusTone = "Pink",
		onPlus = function() if openers.onStore then openers.onStore("tickets") end end,
	})

	-- cash: count up, bump + float the gain (coalesced so NPC spins don't spam)
	local lastCash = cashValue.Value
	local pendingGain, gainScheduled = 0, false
	local gains = {} -- { t, amount } for the income ticker
	local function renderCash()
		local v = cashValue.Value
		cash.set(v, UILib.money)
		local delta = v - lastCash
		lastCash = v
		if delta > 0 then
			table.insert(gains, { t = os.clock(), amount = delta })
			pendingGain += delta
			if not gainScheduled then
				gainScheduled = true
				task.delay(0.35, function()
					gainScheduled = false
					if pendingGain > 0 then
						cash.bump()
						UILib.floatText("+" .. UILib.money(pendingGain), C.GreenTop, cash.Instance)
						pendingGain = 0
					end
				end)
			end
		end
	end
	cash.set(cashValue.Value, UILib.money)
	cashValue.Changed:Connect(renderCash)

	-- chips row: VIP + active boost countdown
	local chips = UILib.make("Frame", {
		Name = "Chips", BackgroundTransparency = 1, Position = UDim2.fromOffset(18, 66),
		Size = UDim2.fromOffset(480, 34), Parent = left,
	})
	UILib.list(chips, "x", 8, nil, Enum.VerticalAlignment.Center)
	local function chip(tone, icon, text, order)
		local t = UILib.Tones[tone]
		local f = UILib.make("Frame", {
			Name = "Chip", BackgroundColor3 = C.White, Size = UDim2.fromOffset(0, 32),
			AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = order, Visible = false, Parent = chips,
		})
		UILib.corner(f, 999)
		UILib.gradient(f, t.top, t.base)
		UILib.stroke(f, C.Ink, 3, true)
		UILib.pad(f, 40, 0, 14, 0)
		UILib.image(f, icon, { size = UDim2.fromOffset(42, 42), position = UDim2.fromOffset(-44, -6) })
		local label = UILib.text(f, { text = text, size = 18, autoX = true, frameSize = UDim2.fromScale(0, 1), shadow = 2 })
		return f, label
	end
	local vipChip = chip("Gold", "crown", "VIP", 1)
	local boostChip, boostLabel = chip("Orange", "cash", "2X 0:00", 2)

	-- action grid (2 columns x 3 rows)
	local grid = UILib.make("Frame", {
		Name = "Actions", BackgroundTransparency = 1, Position = UDim2.fromOffset(4, 116),
		Size = UDim2.fromOffset(210, 350), Parent = left,
	})
	UILib.make("UIGridLayout", {
		CellSize = UDim2.fromOffset(92, 104), CellPadding = UDim2.fromOffset(16, 14),
		SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid,
	})
	local tiles = {}
	local actions = {
		{ "Gold", "shop", "SHOP", openers.onShop },
		{ "Blue", "items", "ITEMS", openers.onInventory },
		{ "Green", "build", "BUILD", openers.onBuild },
		{ "Pink", "upgrade", "UPGRADE", openers.onUpgrades },
		{ "Purple", "slot", "CASINO", openers.onCasino },
		{ "Orange", "stats", "STATS", openers.onStats },
	}
	for i, a in actions do
		tiles[a[3]] = UILib.railButton(grid, { tone = a[1], icon = a[2], label = a[3], order = i, onClick = a[4] })
	end

	------------------------------------------------------------------
	-- right cluster: Store + Daily
	------------------------------------------------------------------
	local right = UILib.make("Frame", {
		Name = "HudRight", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 130), Size = UDim2.fromOffset(100, 240), Parent = screen,
	})
	UILib.autoScale(right, { mult = touchMult })
	UILib.list(right, "y", 14, Enum.HorizontalAlignment.Right)
	UILib.railButton(right, {
		tone = "Green", icon = "gem", label = "STORE", order = 1,
		onClick = function() if openers.onStore then openers.onStore() end end,
	})
	local daily = UILib.railButton(right, {
		tone = "Red", icon = "gift", label = "DAILY", order = 2, onClick = openers.onDaily,
	})

	------------------------------------------------------------------
	-- bottom ticker
	------------------------------------------------------------------
	local bottom = UILib.make("Frame", {
		Name = "HudBottom", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -12), Size = UDim2.fromOffset(330, 56), Parent = screen,
	})
	UILib.autoScale(bottom, { mult = touchMult })
	local ticker = UILib.make("Frame", {
		Name = "Ticker", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.2,
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(0, 50), AutomaticSize = Enum.AutomaticSize.X, Parent = bottom,
	})
	UILib.corner(ticker, 999)
	UILib.stroke(ticker, C.GoldDeep, 3, true)
	UILib.pad(ticker, 64, 0, 22, 0)
	UILib.list(ticker, "x", 12, nil, Enum.VerticalAlignment.Center)
	-- the coin hangs over the pill's left edge, so it lives outside the list layout
	UILib.image(bottom, "coin", {
		size = UDim2.fromOffset(70, 70), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5), z = 3,
		name = "TickerCoin",
	})
	local coin = bottom:FindFirstChild("TickerCoin")
	local function placeCoin()
		-- keep the coin on the ticker's left edge as the pill's width changes
		coin.Position = UDim2.new(0.5, -ticker.AbsoluteSize.X / 2 / math.max(0.01, bottom.AbsoluteSize.X / 330) + 26, 0.5, 0)
	end
	ticker:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeCoin)
	task.defer(placeCoin)
	local rate = UILib.text(ticker, {
		text = "$0/MIN", font = F.Number, size = 26, color = C.GreenTop, autoX = true,
		frameSize = UDim2.fromScale(0, 1), order = 1, stroke = 3.5, shadow = 3,
	})
	local machines = UILib.text(ticker, {
		text = "0 MACHINES", size = 17, color = C.CreamRow, autoX = true,
		frameSize = UDim2.fromScale(0, 1), order = 2, stroke = 2.5, shadow = 2,
	})

	------------------------------------------------------------------
	-- live state
	------------------------------------------------------------------
	local catalog = nil
	task.spawn(function() catalog = UILib.getCatalog() end)

	local function anyAffordableUpgrade(state)
		if not catalog then return false end
		local owned = {}
		for _, id in (state.upgrades or {}) do owned[id] = true end
		for _, u in (catalog.upgrades or {}) do
			if not owned[u.id] and cashValue.Value >= u.cost then return true end
		end
		return false
	end

	local lastTickets = nil
	UILib.subscribe(function(state)
		local t = state.tickets or 0
		tickets.set(t, UILib.commas)
		if lastTickets and t > lastTickets then
			tickets.bump()
			UILib.floatText("+" .. UILib.commas(t - lastTickets), C.PinkTop, tickets.Instance)
		end
		lastTickets = t
		vipChip.Visible = state.vip == true
		machines.Text = ("%d MACHINES"):format(#(state.placed or {}))
		tiles.ITEMS.setAlert(#(state.inventory or {}) > 0)
		tiles.UPGRADE.setAlert(anyAffordableUpgrade(state))
	end)

	-- 1 Hz: ticker, boost countdown, daily availability
	task.spawn(function()
		while left.Parent do
			local now = os.clock()
			local sum = 0
			for i = #gains, 1, -1 do
				if now - gains[i].t > 60 then table.remove(gains, i) else sum += gains[i].amount end
			end
			rate.Text = UILib.money(sum) .. "/MIN"

			local st = UILib.state
			local boostLeft = UILib.secondsLeft(st.boostSeconds)
			boostChip.Visible = boostLeft > 0
			if boostLeft > 0 then
				boostLabel.Text = ("%dX  %s"):format(st.boostMult or 2, UILib.clock(boostLeft))
			end
			local d = st.daily
			daily.setAlert(d ~= nil and (d.canClaim or UILib.secondsLeft(d.secondsLeft) <= 0))
			tiles.UPGRADE.setAlert(anyAffordableUpgrade(st))
			task.wait(1)
		end
	end)
end

return HudUI
