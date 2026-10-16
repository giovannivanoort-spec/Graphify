--!nonstrict
-- HudUI.luau — always-on HUD in the Showtime style:
--   top-left : Cash + Tickets pills (count-up, "+$X" floats on income), VIP / boost chips
--   top      : travel bar — one-tap hops to your casino / the Showroom / the Plaza
--   left     : 2x3 grid of action tiles (each its own tone, 3D icon overflowing the tile);
--              REBIRTH took the old BUILD tile's place (building starts from ITEMS)
--   right    : (DayNightFX's clock pill) then the Casino Rank badge — rank chip, name,
--              XP progress to the next rank (live from the Player attribute "XP"), tap for
--              the rank panel — then Store, Daily and Playtime tiles (alerts when ready)
-- APIs for the other UIs: HudUI.tiles[LABEL].setAlert(on), HudUI.addChip(id, tone,
-- icon, order) -> { set(text), show(on), Instance }, HudUI.playtime.setAlert(on) /
-- .setText(text), HudUI.travelTo(dest).
--   bottom   : income ticker ($/min over the last minute + machines placed)
-- Each cluster carries its own viewport UIScale anchored to its corner.
-- The pills are the landing spots for UXFX's flying coins (UILib.fxTargets);
-- cash gains / spends are reported to it through UILib.fx (a no-op without it).
-- Tile alerts: UPGRADE = a level you can buy now (rank gates respected) or a
-- level a rank-up just unlocked; CASINO = a floor you can build now / just
-- unlocked; SHOP / SHOWROOM = stands / machines a rank-up unlocked since you
-- last went there (UILib's NEW markers).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local F = UILib.Fonts

local HudUI = {}
local player = Players.LocalPlayer

-- full-screen ink veil that hides a travel hop's camera snap. It has its own
-- ScreenGui so it also covers the top-bar inset and notch areas.
local function veil(on: boolean)
	local pg = player:WaitForChild("PlayerGui")
	local gui = pg:FindFirstChild("CasinoTravelVeil")
	if not gui then
		gui = UILib.make("ScreenGui", {
			Name = "CasinoTravelVeil", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 20,
			ScreenInsets = Enum.ScreenInsets.None, ClipToDeviceSafeArea = false, Parent = pg,
		})
		UILib.make("Frame", {
			Name = "Veil", BackgroundColor3 = C.Ink, BackgroundTransparency = 1, BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1), Visible = false, Parent = gui,
		})
	end
	local v = gui.Veil
	if on then
		v.Visible = true
		UILib.tween(v, { BackgroundTransparency = 0 }, 0.14)
		task.wait(0.14)
	else
		UILib.tween(v, { BackgroundTransparency = 1 }, 0.35).Completed:Connect(function(state)
			if state == Enum.PlaybackState.Completed then v.Visible = false end
		end)
	end
end

-- look the way the hop faces (the server picks the facing; the default camera
-- keeps whatever look vector the camera has, so set it once)
local function faceArrival(cf)
	local cam = Workspace.CurrentCamera
	if typeof(cf) ~= "CFrame" or not cam or cam.CameraType ~= Enum.CameraType.Custom then return end
	local at = cf.Position + Vector3.new(0, 1.5, 0)
	cam.CFrame = CFrame.lookAt(at - cf.LookVector * 12 + Vector3.new(0, 3, 0), at)
end

-- rank gates (spec 6.1): a level / floor whose gate is above your rank can't be
-- bought yet. No rank in the snapshot (older server) = no gates.
local function gateOpen(gate, rank): boolean
	gate, rank = tonumber(gate), tonumber(rank)
	return gate == nil or rank == nil or gate <= rank
end

------------------------------------------------------------------
-- Casino Rank badge (right column, under the clock pill): a gold rank chip
-- overlapping an ink capsule with the rank's name and a bar from this rank's
-- XP to the next rank's ("12.4K / 50K XP": every game your guests play earns
-- XP). Hidden while the snapshot has no rank. A rank-up fills the old bar, then
-- rolls the chip over with a pop. After the first rebirth a small purple chip
-- under the rank chip shows the rebirth count (snapshot rebirth.count).
------------------------------------------------------------------
local BADGE_NAME_W = 168 -- design px for the rank name inside the capsule
local function rankBadge(parent: Instance, order: number, onClick)
	-- visible from the start (a placeholder until the first snapshot) so the
	-- Store / Daily tiles below don't jump when it arrives
	local root = UILib.make("Frame", {
		Name = "RankBadge", BackgroundTransparency = 1, Size = UDim2.fromOffset(262, 70),
		LayoutOrder = order, Parent = parent,
	})
	local press = UILib.make("UIScale", { Name = "PressScale", Parent = root }) :: UIScale
	local mover = UILib.make("Frame", {
		Name = "Mover", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = root,
	})
	local pill = UILib.make("Frame", {
		Name = "Pill", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.2, Position = UDim2.fromOffset(22, 7),
		Size = UDim2.fromOffset(240, 56), Parent = mover,
	})
	UILib.corner(pill, 999)
	UILib.stroke(pill, C.GoldDeep, 3, true)
	local name = UILib.text(pill, {
		name = "RankName", text = "CASINO RANK", size = 19, xAlign = Enum.TextXAlignment.Left,
		frameSize = UDim2.new(1, -66, 0, 24), position = UDim2.fromOffset(54, 4),
		gradient = { C.White, C.GoldTop }, stroke = 2.5, shadow = 2,
	})
	local bar = UILib.progressBar(pill, {
		name = "RankBar", size = UDim2.new(1, -66, 0, 18), position = UDim2.fromOffset(54, 31), textSize = 13,
	})
	local med = UILib.medallion(mover, { name = "RankChip", size = 70, number = "", z = 2 })
	-- rebirths: a purple chip hanging under the rank chip (hidden before the first one)
	local rbChip = UILib.make("Frame", {
		Name = "RebirthChip", BackgroundColor3 = C.White, AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(37, 66), Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X,
		Visible = false, ZIndex = 4, Parent = mover,
	})
	UILib.corner(rbChip, 999)
	UILib.gradient(rbChip, C.PurpleTop, C.Purple)
	UILib.stroke(rbChip, C.Ink, 2.5, true)
	UILib.pad(rbChip, 20, 0, 9, 0)
	UILib.image(rbChip, "rebirth", {
		name = "RebirthIcon", size = UDim2.fromOffset(30, 30), anchor = Vector2.new(0, 0.5),
		position = UDim2.new(0, -27, 0.5, -1), z = 5,
	})
	local rbText = UILib.text(rbChip, {
		name = "Count", text = "0", size = 16, autoX = true, frameSize = UDim2.fromScale(0, 1), stroke = 1.5, shadow = 1,
		z = 5,
	})
	local click = UILib.make("TextButton", {
		Name = "Click", Text = "", BackgroundTransparency = 1, AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1), ZIndex = 6, Parent = root,
	}) :: TextButton
	UILib.pressJuice(click, press, mover)
	click.Activated:Connect(function()
		if onClick then onClick() end
	end)

	local api = { Instance = root, Medallion = med, Bar = bar, RebirthChip = rbChip }
	local shown = nil
	local shownRebirths = nil
	local lastState = nil
	local function renderRebirths(state)
		local rb = type(state.rebirth) == "table" and math.floor(tonumber(state.rebirth.count) or 0) or 0
		rbChip.Visible = rb > 0
		rbText.Text = tostring(rb)
		if shownRebirths and rb > shownRebirths then
			UILib.fx("pop", rbChip, 1.5)
			UILib.fx("sparkle", rbChip, 8, C.PurpleTop)
		end
		shownRebirths = rb
	end
	-- progress through this rank in XP; `liveXP` (the Player attribute "XP", newer than
	-- the snapshot) moves the bar between snapshots, full until the rank-up arrives
	local function progress(state, liveXP: number?): (number, string)
		local prog = math.max(tonumber(state.rankProgress) or 0, tonumber(liveXP) or 0)
		local nxt = tonumber(state.rankNext)
		if not nxt then return 1, "MAX  •  " .. UILib.short(prog) .. " XP" end
		local floor = tonumber(state.rankFloor) or 0
		local frac = math.clamp((prog - floor) / math.max(1, nxt - floor), 0, 1)
		return frac, UILib.short(math.min(prog, nxt)) .. " / " .. UILib.short(nxt) .. " XP"
	end
	function api.live(xp: number?)
		if not (lastState and tonumber(lastState.rank) and root.Visible) then return end
		local frac, text = progress(lastState, xp)
		bar.set(frac, text)
	end
	function api.render(state)
		lastState = state
		local r = tonumber(state.rank)
		if not r then
			-- a real snapshot without a rank = a server without ranks: give the slot back
			if state.upgradeLevels ~= nil then root.Visible = false end
			return
		end
		root.Visible = true
		renderRebirths(state)
		local frac, text = progress(state)
		local label = string.upper(tostring(state.rankName or ("Rank " .. r)))
		bar.setTone(state.rankNext == nil and "Purple" or "Gold")
		if shown and r > shown then
			-- rank up: finish the old bar first, then roll over (RankUI plays the fanfare)
			bar.set(1)
			task.delay(0.45, function()
				if not root.Parent then return end
				med.set(r)
				UILib.fitText(name, label, 19, BADGE_NAME_W, 12)
				bar.set(0, text, true)
				bar.set(frac)
				UILib.fx("pop", med.Instance, 1.35)
				UILib.fx("sparkle", med.Instance, 10, C.GoldTop)
			end)
		else
			med.set(r)
			UILib.fitText(name, label, 19, BADGE_NAME_W, 12)
			bar.set(frac, text)
		end
		shown = r
	end
	return api
end

------------------------------------------------------------------
-- fold tabs: a small arrow tab beside a group of HUD buttons slides the group
-- off its screen edge and back (left action tiles, right rail tiles, the top
-- travel bar). Cash, tickets, chips, the rank badge and the clock never fold.
-- A red dot on a folded tab says one of its hidden buttons wants attention.
------------------------------------------------------------------
local FOLD_INFO = TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- a white "<" (rotation 0) built from two rounded bars; rotate it to point elsewhere
local function chevron(parent: Instance, rotation: number): Frame
	local box = UILib.make("Frame", {
		Name = "Chevron", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(22, 22), Rotation = rotation, Parent = parent,
	})
	for i, rot in { -45, 45 } do
		local bar = UILib.make("Frame", {
			Name = "Bar", BackgroundColor3 = C.White, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(10, i == 1 and 7 or 15), Size = UDim2.fromOffset(14, 5), Rotation = rot, Parent = box,
		})
		UILib.corner(bar, 999)
	end
	return box :: Frame
end

-- o = { name, parent, size, target (the group's frame), open() / folded() -> UDim2
-- of the target, tabPos(folded) -> UDim2, arrow(folded) -> rotation, onChanged? }
local function foldTab(o)
	local root = UILib.make("Frame", {
		Name = o.name or "FoldTab", BackgroundTransparency = 1, Size = o.size, AnchorPoint = o.anchor or Vector2.zero,
		Position = o.tabPos(false), ZIndex = 6, Parent = o.parent,
	})
	local scale = UILib.make("UIScale", { Name = "PressScale", Parent = root }) :: UIScale
	local mover = UILib.make("Frame", { Name = "Mover", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = root })
	local face = UILib.make("Frame", {
		Name = "Face", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.12, Size = UDim2.fromScale(1, 1), Parent = mover,
	})
	UILib.corner(face, 12)
	UILib.stroke(face, C.GoldDeep, 3, true)
	UILib.make("UIGradient", {
		Rotation = 90, Transparency = NumberSequence.new(0, 0.25), Parent = face,
	})
	local arrow = chevron(face, o.arrow(false))
	local dot = UILib.make("Frame", {
		Name = "TabAlert", BackgroundColor3 = C.White, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(16, 16), Visible = false, ZIndex = 7, Parent = root,
	})
	UILib.corner(dot, 999)
	UILib.gradient(dot, C.CrimsonTop, C.Crimson)
	UILib.stroke(dot, C.Ink, 2, true)
	local click = UILib.make("TextButton", {
		Name = "Click", Text = "", BackgroundTransparency = 1, AutoButtonColor = false, Size = UDim2.fromScale(1, 1),
		ZIndex = 8, Parent = root,
	}) :: TextButton
	UILib.pressJuice(click, scale, mover)

	local api = { Instance = root, folded = false }
	function api.set(folded: boolean, instant: boolean?)
		api.folded = folded
		local goal, tab, rot = folded and o.folded() or o.open(), o.tabPos(folded), o.arrow(folded)
		if instant then
			o.target.Position, root.Position, arrow.Rotation = goal, tab, rot
		else
			TweenService:Create(o.target, FOLD_INFO, { Position = goal }):Play()
			TweenService:Create(root, FOLD_INFO, { Position = tab }):Play()
			TweenService:Create(arrow, FOLD_INFO, { Rotation = rot }):Play()
		end
		if not folded then dot.Visible = false end
		if o.onChanged then o.onChanged(folded) end
	end
	-- (only shown while folded: open, the buttons show their own alerts)
	function api.setAlert(on: boolean) dot.Visible = on and api.folded end
	click.Activated:Connect(function() api.set(not api.folded) end)
	return api
end

-- is any button in `group` showing its red "!" (railButton's Alert)?
local function anyAlert(group: Instance?): boolean
	if not group then return false end
	for _, d in group:GetDescendants() do
		if d.Name == "Alert" and d:IsA("GuiObject") and d.Visible then return true end
	end
	return false
end

function HudUI.build(openers)
	openers = openers or {}
	local screen = UILib.getScreen()
	for _, n in { "HudLeft", "HudRight", "HudBottom", "HudTravel" } do
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

	-- where flying coins land (UXFX)
	UILib.fxTargets.cash = cash
	UILib.fxTargets.tickets = tickets

	-- cash: count up, bump + float the gain (coalesced so NPC spins don't spam).
	-- With the juice layer running, money that came from a button / a sold
	-- machine / a Robux pack flies in as coins first: the number rolls and the
	-- "+$X" pops as they land. Spending shows at once.
	local lastCash = cashValue.Value
	local pendingGain, gainScheduled = 0, false
	local gains = {} -- { t, amount } for the income ticker
	local function flushGain()
		gainScheduled = false
		local gain = pendingGain
		pendingGain = 0
		if gain <= 0 then return end
		local landed = false
		local function land()
			if landed then return end
			landed = true
			cash.set(cashValue.Value, UILib.money, 0.7)
		end
		if UILib.fx("cashGain", gain, land, cashValue.Value) == true then
			task.delay(2, land) -- never leave the number behind
		else
			land()
			cash.bump()
			UILib.floatText("+" .. UILib.money(gain), C.GreenTop, cash.Instance)
		end
	end
	local function renderCash()
		local v = cashValue.Value
		local delta = v - lastCash
		lastCash = v
		if delta > 0 then
			table.insert(gains, { t = os.clock(), amount = delta })
			pendingGain += delta
			if not gainScheduled then
				gainScheduled = true
				task.delay(0.35, flushGain)
			end
		elseif delta < 0 then
			cash.set(v, UILib.money, 0.35)
			UILib.fx("cashSpend", -delta)
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
	-- more chips for the other UIs (potions: order 10+), hidden until shown
	local extraChips = {}
	function HudUI.addChip(id: string, tone: string, icon: string, order: number?)
		local old = extraChips[id]
		if old and old.Instance.Parent then return old end
		local f, label = chip(tone, icon, "", order or 10)
		f.Name = "Chip_" .. tostring(id)
		local handle = { Instance = f, Label = label }
		function handle.set(text: string) label.Text = text end
		function handle.show(on: boolean) f.Visible = on == true end
		extraChips[id] = handle
		return handle
	end

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
	-- when the player last looked at stands / the Showroom (their tile alerts
	-- show only what a rank-up unlocked after that)
	local ack = { shop = 0, showroom = 0 }
	local refreshAlerts -- set below, once the state helpers exist
	local actions = {
		{ "Gold", "shop", "SHOP", function()
			ack.shop = os.clock()
			if refreshAlerts then refreshAlerts() end
			if openers.onShop then openers.onShop() end
		end },
		{ "Blue", "items", "ITEMS", openers.onInventory },
		{ "Green", "rebirth", "REBIRTH", openers.onRebirth },
		{ "Pink", "upgrade", "UPGRADE", openers.onUpgrades },
		{ "Purple", "slot", "CASINO", openers.onCasino },
		{ "Orange", "stats", "STATS", openers.onStats },
	}
	for i, a in actions do
		tiles[a[3]] = UILib.railButton(grid, { tone = a[1], icon = a[2], label = a[3], order = i, onClick = a[4] })
	end
	HudUI.tiles = tiles
	-- the arrow tab on the grid's right side: folds the tiles away to the left
	local leftFold = foldTab({
		name = "FoldLeft", parent = left, size = UDim2.fromOffset(30, 70), target = grid,
		open = function() return UDim2.fromOffset(4, 116) end,
		folded = function() return UDim2.fromOffset(-250, 116) end,
		tabPos = function(folded) return UDim2.fromOffset(folded and 0 or 222, 116 + 170 - 35) end,
		arrow = function(folded) return folded and 180 or 0 end,
	})

	------------------------------------------------------------------
	-- right column: (clock pill) -> Casino Rank badge -> Store + Daily
	------------------------------------------------------------------
	local right = UILib.make("Frame", {
		Name = "HudRight", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 14), Size = UDim2.fromOffset(270, 530), Parent = screen,
	})
	UILib.autoScale(right, { mult = touchMult })
	UILib.list(right, "y", 14, Enum.HorizontalAlignment.Right)
	-- DayNightFX's clock pill owns the corner above (250x44, 48 tall in the night rush)
	UILib.make("Frame", {
		Name = "ClockSpace", BackgroundTransparency = 1, Size = UDim2.fromOffset(10, 44), LayoutOrder = 0, Parent = right,
	})
	local badge = rankBadge(right, 1, function()
		if openers.onRank then openers.onRank() end
	end)
	UILib.fxTargets.rank = badge.Medallion.Instance -- RankUI's rank-up confetti starts here
	-- the tiles under the badge: a grid that fills the right edge top to bottom
	-- (STORE, DAILY, PLAYTIME), then the next column to its left (QUESTS, SPIN...)
	-- (a holder keeps the slot in the column's list layout; the grid inside it slides)
	local rightHolder = UILib.make("Frame", {
		Name = "RightTilesHolder", BackgroundTransparency = 1, Size = UDim2.fromOffset(200, 340), LayoutOrder = 2,
		Parent = right,
	})
	local rightGrid = UILib.make("Frame", {
		Name = "RightTiles", BackgroundTransparency = 1, Size = UDim2.fromOffset(200, 340), Parent = rightHolder,
	})
	UILib.make("UIGridLayout", {
		CellSize = UDim2.fromOffset(92, 104), CellPadding = UDim2.fromOffset(16, 14),
		FillDirection = Enum.FillDirection.Vertical, FillDirectionMaxCells = 3,
		StartCorner = Enum.StartCorner.TopRight, SortOrder = Enum.SortOrder.LayoutOrder, Parent = rightGrid,
	})
	-- a small timer pill on a tile ("4:59", "READY!")
	local function withPill(tile)
		local pill = UILib.make("Frame", {
			Name = "TimerPill", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.15, AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, -10), Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X,
			Visible = false, ZIndex = 4, Parent = tile.Instance,
		})
		UILib.corner(pill, 999)
		UILib.stroke(pill, C.GoldDeep, 2, true)
		UILib.pad(pill, 8, 0, 8, 0)
		local label = UILib.text(pill, {
			text = "", size = 14, autoX = true, frameSize = UDim2.fromScale(0, 1), stroke = 1.5, shadow = 1,
		})
		label.ZIndex = 5
		return {
			Instance = tile.Instance,
			setAlert = function(on: boolean) tile.setAlert(on == true) end,
			setText = function(text: string?)
				pill.Visible = text ~= nil and text ~= ""
				label.Text = text or ""
			end,
		}
	end
	UILib.railButton(rightGrid, {
		tone = "Green", icon = "gem", label = "STORE", order = 1,
		onClick = function() if openers.onStore then openers.onStore() end end,
	})
	local daily = UILib.railButton(rightGrid, {
		tone = "Red", icon = "gift", label = "DAILY", order = 2, onClick = openers.onDaily,
	})
	-- PLAYTIME: rewards for time played today; the pill counts down to the next one
	-- (PlaytimeUI drives it through HudUI.playtime)
	HudUI.playtime = withPill(UILib.railButton(rightGrid, {
		tone = "Blue", icon = "playtime", label = "PLAYTIME", order = 3, onClick = openers.onPlaytime,
	}))
	-- more tiles for the other UIs (QuestsUI: order 10, WheelUI: 20 ...):
	-- HudUI.addRailTile({ id, tone, icon, label, order, onClick }) -> { setAlert(on), setText(text), Instance }
	local railTiles = {}
	function HudUI.addRailTile(o)
		local id = tostring(o.id or o.label)
		local old = railTiles[id]
		if old and old.Instance.Parent then return old end
		local handle = withPill(UILib.railButton(rightGrid, {
			tone = o.tone or "Gold", icon = o.icon, label = o.label or id, order = o.order or 10, onClick = o.onClick,
		}))
		railTiles[id] = handle
		return handle
	end
	-- the arrow tab left of the tiles: folds them away to the right
	local rightFold = foldTab({
		name = "FoldRight", parent = rightHolder, size = UDim2.fromOffset(30, 70), target = rightGrid,
		open = function() return UDim2.fromOffset(0, 0) end,
		folded = function() return UDim2.fromOffset(260, 0) end,
		tabPos = function(folded) return UDim2.fromOffset(folded and 170 or -40, 170 - 35) end,
		arrow = function(folded) return folded and 0 or 180 end,
	})

	------------------------------------------------------------------
	-- top centre: travel bar (one-tap hops, like Grow a Garden's)
	------------------------------------------------------------------
	-- a notch smaller than the action tiles: centred on 16:9 without touching the pills
	local TRAVEL_SCALE = 0.85
	local travel = UILib.make("Frame", {
		Name = "HudTravel", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 14), Size = UDim2.fromOffset(316, 104), Parent = screen,
	})
	UILib.autoScale(travel, { mult = touchMult * TRAVEL_SCALE })
	-- the buttons sit in their own row (the fold tab under them isn't part of the layout)
	local travelRow = UILib.make("Frame", {
		Name = "Row", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = travel,
	})
	UILib.list(travelRow, "x", 20, Enum.HorizontalAlignment.Center)
	local TOAST_INSET = math.ceil(104 * touchMult * TRAVEL_SCALE) + 10
	UILib.setToastTopInset(TOAST_INSET)

	local traveling, nextHop = false, 0 -- the server says how long each hop's cooldown is
	local function travelTo(dest: string)
		if traveling then return end
		if openers.isPlacing and openers.isPlacing() then
			UILib.toast("Place or cancel first!", "error")
			return
		end
		local remaining = nextHop - os.clock()
		if remaining > 0 then
			UILib.toast(("Travel ready in %ds."):format(math.ceil(remaining)), "error")
			return
		end
		traveling = true
		veil(true)
		local ok, res = pcall(function() return Remotes.TravelTo():InvokeServer(dest) end)
		local moved = ok and type(res) == "table" and res.ok == true
		if moved then
			nextHop = os.clock() + (tonumber(res.cooldown) or 0)
			faceArrival(res.cframe)
		end
		veil(false)
		traveling = false
		if not moved then
			UILib.toast(ok and type(res) == "table" and res.message or "Can't travel right now.", "error")
		elseif dest == "showroom" then
			ack.showroom = os.clock()
			if refreshAlerts then refreshAlerts() end
		end
	end
	HudUI.travelTo = travelTo -- RankUI's "SHOW ME" hops to the Showroom the same way
	local travelTiles = {}
	for i, d in {
		{ "casino", "Green", "slot", "MY CASINO" },
		{ "showroom", "Blue", "shop", "SHOWROOM" },
		{ "plaza", "Pink", "star", "PLAZA" },
	} do
		travelTiles[d[1]] = UILib.railButton(travelRow, {
			tone = d[2], icon = d[3], label = d[4], order = i, onClick = function() travelTo(d[1]) end,
		})
	end

	-- on narrow (4:3) screens slide right so the bar never covers the currency pills
	local shift = 0
	local topFold
	local function travelPos(folded: boolean): UDim2
		-- folded: the bar sits just above the screen; its tab hangs into view
		return UDim2.new(0.5, shift, 0, folded and -(travel.AbsoluteSize.Y + 2) or 14)
	end
	local function fitTravel()
		local pill = tickets.Instance
		local clear = pill.AbsolutePosition.X + pill.AbsoluteSize.X + 10
		local want = math.max(0, math.ceil(clear - (travel.AbsolutePosition.X - shift)))
		if want ~= shift then
			shift = want
			travel.Position = travelPos(topFold ~= nil and topFold.folded)
		end
	end
	-- the arrow tab under the bar: folds it up out of the way
	topFold = foldTab({
		name = "FoldTop", parent = travel, size = UDim2.fromOffset(70, 28), anchor = Vector2.new(0.5, 0), target = travel,
		open = function() return travelPos(false) end,
		folded = function() return travelPos(true) end,
		tabPos = function() return UDim2.new(0.5, 0, 1, 4) end,
		arrow = function(folded) return folded and -90 or 90 end,
		onChanged = function(folded)
			UILib.setToastTopInset(folded and 46 or TOAST_INSET)
		end,
	})
	travel:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitTravel)
	left:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitTravel)
	screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitTravel)
	task.defer(fitTravel)

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
	local standIds = {} -- catalog ids of concessions (sold at the SHOP / Services desk)
	task.spawn(function()
		catalog = UILib.getCatalog()
		for _, def in (catalog and catalog.concessions or {}) do standIds[tostring(def.id)] = true end
		if refreshAlerts then refreshAlerts() end
	end)

	-- a level you can buy right now: not maxed, its rank gate open, affordable
	local function anyAffordableUpgrade(state)
		if not catalog then return false end
		local levels = state.upgradeLevels or {}
		for _, track in (catalog.upgradeTracks or {}) do
			local nextLevel = (levels[track.id] or 0) + 1
			local nextCost = track.costs[nextLevel]
			if nextCost and cashValue.Value >= nextCost
				and gateOpen(track.gates and track.gates[nextLevel], state.rank) then
				return true
			end
		end
		return false
	end
	-- the next floor: just unlocked by a rank-up, or unlocked and affordable
	local function floorAlert(state): boolean
		local b = state.building
		if type(b) ~= "table" then return false end
		local stories = tonumber(b.stories) or 1
		if stories >= (tonumber(b.maxStories) or 5) then return false end
		local n = stories + 1
		if UILib.isNew("floor", n) then return true end
		local cost = tonumber(b.nextStoryCost)
		return cost ~= nil and cashValue.Value >= cost and gateOpen(state.storyRanks and state.storyRanks[n], state.rank)
	end
	-- machines (or stands) a rank-up unlocked after the player last went to look
	local function newMachines(stands: boolean, since: number): boolean
		for id, t in UILib.newIds("machine") do
			if t > since and (standIds[id] == true) == stands then return true end
		end
		return false
	end
	refreshAlerts = function()
		local st = UILib.state
		tiles.UPGRADE.setAlert(anyAffordableUpgrade(st) or UILib.newCount("upgrade") > 0)
		tiles.CASINO.setAlert(floorAlert(st))
		tiles.SHOP.setAlert(newMachines(true, ack.shop))
		travelTiles.showroom.setAlert(newMachines(false, ack.showroom))
	end
	local unNew = UILib.onNewChanged(function() refreshAlerts() end)
	left.Destroying:Connect(unNew)

	local lastTickets = nil
	UILib.subscribe(function(state)
		local t = state.tickets or 0
		tickets.set(t, UILib.commas)
		if lastTickets and t > lastTickets then
			tickets.bump()
			UILib.floatText("+" .. UILib.commas(t - lastTickets), C.PinkTop, tickets.Instance)
			UILib.fx("ticketGain", t - lastTickets)
		end
		lastTickets = t
		vipChip.Visible = state.vip == true
		machines.Text = ("%d MACHINES"):format(#(state.placed or {}))
		-- something to place: machines / stands, or unplaced decor
		local decorLeft = false
		local decor = state.decor
		if type(decor) == "table" and type(decor.inventory) == "table" then
			for _, n in decor.inventory do
				if (tonumber(n) or 0) > 0 then decorLeft = true break end
			end
		end
		tiles.ITEMS.setAlert(#(state.inventory or {}) > 0 or decorLeft)
		badge.render(state)
		refreshAlerts()
	end)

	-- 1 Hz: ticker, boost countdown, daily availability
	local lastRate, lastRatePop = 0, 0
	local lastGlint = 0
	task.spawn(function()
		while left.Parent do
			local now = os.clock()
			local sum = 0
			for i = #gains, 1, -1 do
				if now - gains[i].t > 60 then table.remove(gains, i) else sum += gains[i].amount end
			end
			rate.Text = UILib.money(sum) .. "/MIN"
			-- the ticker gives a little pop when the income rate climbs (at most every 5 s)
			if sum >= lastRate * 1.12 and sum - lastRate >= 5 and now - lastRatePop >= 5 then
				lastRatePop = now
				UILib.fx("pop", ticker, 1.07)
			end
			lastRate = sum

			local st = UILib.state
			local boostLeft = UILib.secondsLeft(st.boostSeconds)
			boostChip.Visible = boostLeft > 0
			if boostLeft > 0 then
				boostLabel.Text = ("%dX  %s"):format(st.boostMult or 2, UILib.clock(boostLeft))
			end
			local d = st.daily
			daily.setAlert(d ~= nil and (d.canClaim or UILib.secondsLeft(d.secondsLeft) <= 0))
			-- a folded group whose buttons want attention shows a red dot on its tab
			leftFold.setAlert(anyAlert(grid))
			rightFold.setAlert(anyAlert(rightGrid))
			topFold.setAlert(anyAlert(travelRow))
			-- the rank bar follows the XP the server mirrors onto the player
			local liveXP = player:GetAttribute("XP")
			if type(liveXP) == "number" then badge.live(liveXP) end
			refreshAlerts()
			-- nearly at the next rank: a glint runs over the bar every few seconds
			if badge.Instance.Visible and st.rankNext ~= nil and badge.Bar.value >= 0.9 and now - lastGlint >= 6 then
				lastGlint = now
				UILib.fx("sparkle", badge.Bar.Instance, 3, C.GoldTop)
			end
			task.wait(1)
		end
	end)
end

return HudUI
