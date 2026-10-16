--!nonstrict
-- QuestsUI.luau — the QUESTS panel and its HUD tile (server: CasinoServer/Quests.luau,
-- Config.Quests).
--   * the panel: 3 daily quest cards (icon tile, title, how-to, progress bar, reward
--     chips, CLAIM! / REROLL / CLAIMED) and the weekly quest as a big purple card with
--     a treasure chest (rays behind it; it bounces once the quest is done), plus the
--     countdowns to the next daily set (00:00 UTC) and the next weekly (Monday)
--   * the HUD tile QUESTS (HudUI.addRailTile, order 10): a "2/3" pill (dailies done)
--     and the alert while a reward waits
--   * juice: QuestDone (server) -> "QUEST COMPLETE!" toast + the tile pops; CLAIM ->
--     ka-ching + confetti, Tickets / Cash fly to the HUD; the weekly chest -> a purple
--     banner; a reroll flips the new card in; a new day -> "NEW DAILY QUESTS!"
-- A paid reroll (or one that throws away progress) asks twice: the first tap arms it.
-- Live bars between snapshot pushes: the Player attribute QuestProgress
-- ("q17:3400|q18:2|...", written by the server at most once a second).
-- Snapshot key `quests` (Quests.snapshot): { day, week, resetIn, weekResetIn, daily,
-- weekly, ready, rerolls = { used, free, cost }, weeklyRerollCost, notice? }.
-- QuestsUI.open()   QuestsUI.start(deps)   (deps: HudUI, ...)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local Config = require(Common:WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local F = UILib.Fonts
local Tones = UILib.Tones
local make = UILib.make

local QuestsUI = {}
local player = Players.LocalPlayer
local deps = {}
local started = false
local tile = nil          -- the HUD tile handle
local panelOpen = false
local flipId = nil        -- a quest that just replaced a rerolled one: it flips in

local PANEL_W, PANEL_H = 1100, 650
local CONTENT_W = PANEL_W - 92           -- UILib.panel's content frame
local HEADER_H = 58
local TOP = HEADER_H + 12
local CARD_W, CARD_H, CARD_GAP = 604, 138, 12
local RIGHT_W = 172                      -- a card's reward / button column
local INFO_X = 130
local INFO_W = CARD_W - INFO_X - RIGHT_W - 26
local WEEK_X = CARD_W + 16
local WEEK_W = CONTENT_W - WEEK_X
local WEEK_H = 3 * CARD_H + 2 * CARD_GAP
local ARM_SECONDS = 3                    -- a paid reroll waits this long for the second tap

-- a 3D icon per quest kind, if a quest names none (or its own isn't uploaded)
local KIND_ICON = {
	games = "chips", cash = "cash", xp = "xp", upgradeMachine = "wrench", upgradeTrack = "upgrade",
	staff = "staff", decor = "plant", buyMachine = "shop", cheaters = "cheater", wheel = "wheel",
	potion = "potion_mega", playtime = "playtime", dailies = "quests", events = "megaphone",
}

------------------------------------------------------------------
-- state helpers
------------------------------------------------------------------
local function questState()
	local st = UILib.state and UILib.state.quests
	return type(st) == "table" and st or nil
end

local function iconOr(name: string?, fallback: string?): string?
	if type(name) == "string" and UILib.resolveIcon(name) ~= "" then return name end
	return fallback
end

local function questIcon(q): string
	return iconOr(q.icon, nil) or iconOr(KIND_ICON[q.kind], nil) or "star"
end

-- live progress (id -> amount) from the QuestProgress attribute
local live: {[string]: number} = {}
local function readLive()
	table.clear(live)
	local s = player:GetAttribute("QuestProgress")
	if type(s) ~= "string" then return end
	for id, v in string.gmatch(s, "([%w_]+):(%d+)") do
		live[id] = tonumber(v)
	end
end

local function targetOf(q): number
	return math.max(1, tonumber(q.target) or 1)
end

local function progressOf(q): number
	local p = tonumber(q.progress) or 0
	local l = live[q.id]
	if l and l > p then p = l end
	return math.clamp(p, 0, targetOf(q))
end

local function isDone(q): boolean
	return q.done == true or progressOf(q) >= targetOf(q)
end

local function isReady(q): boolean
	return q.claimed ~= true and isDone(q)
end

local function amountText(q, n: number): string
	n = math.floor(tonumber(n) or 0)
	if q.kind == "cash" then return UILib.moneyShort(n) end
	return UILib.short(n)
end

local function barText(q): string
	return amountText(q, progressOf(q)) .. " / " .. amountText(q, targetOf(q)) .. (q.kind == "xp" and " XP" or "")
end

-- "3D 04H" / "5H 12M" / "4:59"
local function longClock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	local d, h, m = s // 86400, (s % 86400) // 3600, (s % 3600) // 60
	if d > 0 then return ("%dD %02dH"):format(d, h) end
	if h > 0 then return ("%dH %02dM"):format(h, m) end
	return UILib.clock(s)
end

------------------------------------------------------------------
-- reward chips (Config.rewardParts: rarest first)
------------------------------------------------------------------
local function chipText(part): string
	local n = tonumber(part.amount) or 0
	if part.kind == "cash" then return UILib.moneyShort(n) end
	if part.kind == "tickets" then return UILib.short(n) end
	if part.kind == "potion" then
		local def = Config.getPotion and Config.getPotion(part.potion)
		local name = (def and def.short) or string.upper(tostring(part.name or "POTION"))
		return (n > 1 and (math.floor(n) .. "x ") or "") .. name
	end
	if part.kind == "boost" then return ("x3 %d MIN"):format(math.floor(n)) end
	if part.kind == "rcoin" then return n == 1 and "1 COIN" or (math.floor(n) .. " COINS") end
	return UILib.short(n)
end

local function rewardChip(parent: Instance, part, order: number, h: number)
	local tone = Tones[part.tone] or Tones.Gold
	local chip = make("Frame", {
		Name = "Chip_" .. tostring(part.kind), BackgroundColor3 = C.Ink, BackgroundTransparency = 0.08,
		Size = UDim2.fromOffset(0, h), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = order, Parent = parent,
	})
	UILib.corner(chip, 999)
	UILib.stroke(chip, tone.top, 2, true)
	UILib.pad(chip, h + 4, 0, 10, 0)
	UILib.image(chip, part.icon, {
		size = UDim2.fromOffset(h + 10, h + 10), position = UDim2.fromOffset(-(h + 8), -5),
	})
	UILib.text(chip, {
		text = chipText(part), font = F.Number, size = math.floor(h * 0.62), autoX = true,
		frameSize = UDim2.fromScale(0, 1), stroke = 1.5, shadow = 1,
	})
	return chip
end

local function partsOf(q)
	return Config.rewardParts(q.reward, q.cash)
end

------------------------------------------------------------------
-- small pieces
------------------------------------------------------------------
-- a soft endless pulse on a wrapper frame (buttons own their press UIScale)
local function pulse(gui: GuiObject, amount: number?)
	local sc = make("UIScale", { Name = "Pulse", Parent = gui })
	task.spawn(function()
		while gui.Parent do
			UILib.tween(sc, { Scale = amount or 1.06 }, 0.45, Enum.EasingStyle.Sine)
			task.wait(0.5)
			if not gui.Parent then break end
			UILib.tween(sc, { Scale = 1 }, 0.45, Enum.EasingStyle.Sine)
			task.wait(0.75)
		end
	end)
	return sc
end

-- an ink price tag on a button's shoulder: [ticket] 20 / FREE
local function costTag(parent: Instance, cost: number)
	local tag = make("Frame", {
		Name = "Cost", BackgroundColor3 = C.Ink, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 6, 0, 0),
		Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 8, Parent = parent,
	})
	UILib.corner(tag, 999)
	UILib.stroke(tag, cost > 0 and C.PinkTop or C.GreenTop, 2, true)
	if cost > 0 then
		UILib.pad(tag, 26, 0, 9, 0)
		UILib.image(tag, "ticket", { size = UDim2.fromOffset(30, 30), position = UDim2.fromOffset(-30, -3), z = 8 })
	else
		UILib.pad(tag, 9, 0, 9, 0)
	end
	UILib.text(tag, {
		text = cost > 0 and UILib.short(cost) or "FREE", font = cost > 0 and F.Number or F.Display, size = 15,
		autoX = true, frameSize = UDim2.fromScale(0, 1), stroke = 1.5, shadow = 1, z = 8,
		color = cost > 0 and C.White or C.GreenTop,
	})
	return tag
end

-- REROLL with a two-tap confirm when it costs Tickets or throws away progress
local function rerollButton(parent: Instance, o)
	local wrap = make("Frame", {
		Name = "RerollWrap", BackgroundTransparency = 1, Size = o.size, Position = o.position,
		AnchorPoint = o.anchor or Vector2.zero, Parent = parent,
	})
	local btn = UILib.button({
		parent = wrap, tone = "Blue", text = "REROLL", textSize = o.textSize or 20, size = UDim2.fromScale(1, 1),
		radius = 14,
	})
	costTag(wrap, o.cost)
	local careful = o.cost > 0 or o.hasProgress
	local armedAt = 0
	btn.onClick(function()
		if careful and os.clock() - armedAt > ARM_SECONDS then
			armedAt = os.clock()
			btn.setTone("Orange")
			btn.setText("SURE?")
			UILib.fx("shake", wrap, 0.4)
			local why = {}
			if o.cost > 0 then table.insert(why, ("it costs %d %s"):format(o.cost, Config.TicketName or "Tickets")) end
			if o.hasProgress then table.insert(why, "this quest's progress is lost") end
			UILib.toast("TAP REROLL AGAIN", "info", "A new quest - " .. table.concat(why, " and ") .. ".")
			task.delay(ARM_SECONDS, function()
				if wrap.Parent and os.clock() - armedAt >= ARM_SECONDS - 0.05 then
					btn.setTone("Blue")
					btn.setText("REROLL")
				end
			end)
			return
		end
		armedAt = 0
		o.onReroll(wrap)
	end)
	return wrap
end

local function claimButton(parent: Instance, o)
	local wrap = make("Frame", {
		Name = "ClaimWrap", BackgroundTransparency = 1, Size = o.size, Position = o.position,
		AnchorPoint = o.anchor or Vector2.zero, Parent = parent,
	})
	UILib.button({
		parent = wrap, tone = "Gold", text = o.text or "CLAIM!", icon = o.icon, iconSize = o.iconSize,
		textSize = o.textSize or 24, size = UDim2.fromScale(1, 1), onClick = function() o.onClaim(wrap) end,
	})
	pulse(wrap, 1.07)
	return wrap
end

local function claimedStamp(parent: Instance, position: UDim2, text: string?)
	local b = UILib.badge(parent, text or "CLAIMED", "Green", -8, 6)
	b.AnchorPoint = Vector2.new(0.5, 0.5)
	b.Position = position
	UILib.image(b, UILib.Tex.check, {
		size = UDim2.fromOffset(34, 34), anchor = Vector2.new(0.5, 0.5), position = UDim2.new(1, 8, 0, 2), z = 7,
	})
	return b
end

------------------------------------------------------------------
-- a daily quest card
------------------------------------------------------------------
local function buildDaily(parent: Instance, q, y: number, ctx)
	local tone = Tones[q.tone] or Tones.Gold
	local ready, claimed = isReady(q), q.claimed == true
	local card = make("Frame", {
		Name = "Quest_" .. tostring(q.id), BackgroundColor3 = C.White, AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(CARD_W / 2, y + CARD_H / 2), Size = UDim2.fromOffset(CARD_W, CARD_H),
		Parent = parent,
	})
	local pop = make("UIScale", { Name = "Pop", Parent = card })
	UILib.corner(card, 22)
	if ready then
		UILib.gradient(card, tone.top, tone.base)
	else
		UILib.gradient(card, C.Cream, C.CreamRow)
	end
	UILib.stroke(card, ready and C.Gold or C.Ink, ready and 6 or 3.5, true)

	-- the icon on its tone tile; rays behind it once the quest is done
	if ready then
		local clip = make("Frame", {
			Name = "RayClip", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ClipsDescendants = true,
			Parent = card,
		})
		UILib.corner(clip, 22)
		local rays = UILib.image(clip, UILib.Tex.sunburst, {
			size = UDim2.fromOffset(150, 150), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromOffset(64, CARD_H / 2),
			color = C.GoldTop, transparency = 0.3,
		})
		UILib.spin(rays, 24)
	end
	local tileF = make("Frame", {
		Name = "Tile", BackgroundColor3 = C.White, Position = UDim2.fromOffset(14, (CARD_H - 100) / 2),
		Size = UDim2.fromOffset(100, 100), Parent = card,
	})
	UILib.corner(tileF, 20)
	UILib.gradient(tileF, tone.top, tone.base)
	UILib.stroke(tileF, C.Ink, 3.5, true)
	UILib.image(tileF, UILib.Tex.glow, {
		size = UDim2.fromScale(1.15, 1.15), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5),
		transparency = 0.4,
	})
	local icon = UILib.image(tileF, questIcon(q), {
		size = UDim2.fromScale(1.1, 1.1), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.46),
	})
	if claimed then
		icon.ImageTransparency = 0.35
		UILib.image(tileF, UILib.Tex.check, {
			size = UDim2.fromOffset(46, 46), anchor = Vector2.new(0.5, 0.5), position = UDim2.new(1, -6, 1, -8), z = 3,
		})
	end

	-- title + how-to
	local title = tostring(q.title or "Quest")
	if ready then
		local face = UILib.text(card, {
			name = "Title", text = title, size = 24, xAlign = Enum.TextXAlignment.Left,
			frameSize = UDim2.fromOffset(INFO_W, 30), position = UDim2.fromOffset(INFO_X, 12), stroke = 3, shadow = 2,
		})
		UILib.fitText(face, title, 24, INFO_W, 14)
		UILib.text(card, {
			name = "Desc", text = "YOUR REWARD IS WAITING!", size = 16, xAlign = Enum.TextXAlignment.Left,
			frameSize = UDim2.fromOffset(INFO_W, 22), position = UDim2.fromOffset(INFO_X, 48),
			stroke = 2, shadow = 1,
		})
	else
		local lbl = UILib.body(card, {
			name = "Title", text = title, font = F.Display, size = 24, color = claimed and C.Brown or C.Crimson,
			frameSize = UDim2.fromOffset(INFO_W, 30), position = UDim2.fromOffset(INFO_X, 12),
		})
		UILib.fitText(lbl, title, 24, INFO_W, 14)
		UILib.body(card, {
			name = "Desc", text = tostring(q.desc or ""), size = 14,
			wrap = true, frameSize = UDim2.fromOffset(INFO_W, 36), position = UDim2.fromOffset(INFO_X, 44),
			yAlign = Enum.TextYAlignment.Top, transparency = claimed and 0.4 or 0,
		})
	end

	-- progress
	local bar = UILib.progressBar(card, {
		size = UDim2.fromOffset(INFO_W, 32), position = UDim2.fromOffset(INFO_X, 92),
		tone = (ready and "Gold") or (claimed and "Green") or (Tones[q.tone] and q.tone or "Gold"), textSize = 17,
		value = progressOf(q) / targetOf(q), text = barText(q),
	})

	-- rewards + the button
	local right = make("Frame", {
		Name = "Right", BackgroundTransparency = 1, Position = UDim2.fromOffset(CARD_W - RIGHT_W - 14, 0),
		Size = UDim2.fromOffset(RIGHT_W, CARD_H), Parent = card,
	})
	if ready then
		UILib.text(right, {
			text = "REWARD", size = 14, xAlign = Enum.TextXAlignment.Left, frameSize = UDim2.fromOffset(RIGHT_W, 18),
			position = UDim2.fromOffset(4, 5), stroke = 1.5, shadow = 1,
		})
	else
		UILib.body(right, {
			text = "REWARD", font = F.Display, size = 14, color = C.Brown, transparency = 0.25,
			frameSize = UDim2.fromOffset(RIGHT_W, 18), position = UDim2.fromOffset(4, 5),
		})
	end
	local chips = make("Frame", {
		Name = "Rewards", BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 24),
		Size = UDim2.fromOffset(RIGHT_W - 8, 54), Parent = right,
	})
	UILib.list(chips, "y", 2)
	for i, part in partsOf(q) do
		if i > 2 then break end
		rewardChip(chips, part, i, 26)
	end
	if ready then
		claimButton(right, {
			size = UDim2.fromOffset(RIGHT_W, 42), position = UDim2.fromOffset(0, 88), onClaim = function(from)
				ctx.claim(q, from)
			end,
		})
		local b = UILib.badge(card, "COMPLETE!", "Red", -7, 6)
		b.AnchorPoint = Vector2.new(0.5, 0.5)
		b.Position = UDim2.fromOffset(64, 4)
	elseif claimed then
		claimedStamp(right, UDim2.fromOffset(RIGHT_W / 2, 108))
	else
		rerollButton(right, {
			size = UDim2.fromOffset(RIGHT_W - 12, 38), position = UDim2.fromOffset(0, 92), cost = ctx.rerollCost,
			hasProgress = progressOf(q) > 0, onReroll = function() ctx.reroll(q) end,
		})
	end
	return { card = card, pop = pop, bar = bar, q = q }
end

------------------------------------------------------------------
-- the weekly quest: a big purple card with the chest
------------------------------------------------------------------
local function buildWeekly(parent: Instance, q, ctx)
	local ready, claimed = isReady(q), q.claimed == true
	local card = make("Frame", {
		Name = "Weekly_" .. tostring(q.id), BackgroundColor3 = C.White, AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(WEEK_X + WEEK_W / 2, TOP + WEEK_H / 2), Size = UDim2.fromOffset(WEEK_W, WEEK_H),
		Parent = parent,
	})
	local pop = make("UIScale", { Name = "Pop", Parent = card })
	UILib.corner(card, 26)
	UILib.gradient(card, Tones.Purple.base, Tones.Purple.shadow)
	UILib.stroke(card, ready and C.GoldTop or C.Gold, ready and 6 or 5, true)
	local trim = make("Frame", {
		Name = "Trim", BackgroundTransparency = 1, Position = UDim2.fromOffset(9, 9), Size = UDim2.new(1, -18, 1, -18),
		Parent = card,
	})
	UILib.corner(trim, 20)
	UILib.stroke(trim, C.GoldTop, 2, true, 0.45)
	local pattern = make("ImageLabel", {
		Name = "Pattern", BackgroundTransparency = 1, Image = UILib.Tex.pattern, ScaleType = Enum.ScaleType.Tile,
		TileSize = UDim2.fromOffset(34, 34), ImageColor3 = C.PurpleTop, ImageTransparency = 0.88,
		Size = UDim2.fromScale(1, 1), Parent = card,
	})
	UILib.corner(pattern, 26)

	-- rays + glow + the chest
	local clip = make("Frame", {
		Name = "RayClip", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ClipsDescendants = true, Parent = card,
	})
	UILib.corner(clip, 26)
	local rays = UILib.image(clip, UILib.Tex.sunburst, {
		size = UDim2.fromOffset(250, 250), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromOffset(WEEK_W / 2, 126),
		color = C.GoldTop, transparency = ready and 0.2 or 0.6,
	})
	UILib.spin(rays, ready and 30 or 8)
	UILib.image(card, UILib.Tex.glow, {
		size = UDim2.fromOffset(230, 200), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromOffset(WEEK_W / 2, 126),
		color = ready and C.GoldTop or C.PinkTop, transparency = ready and 0.15 or 0.45,
	})
	local chest = UILib.image(card, iconOr("chest", "gift"), {
		name = "Chest", size = UDim2.fromOffset(156, 156), anchor = Vector2.new(0.5, 0.5),
		position = UDim2.fromOffset(WEEK_W / 2, 124),
	})
	if claimed then
		chest.ImageTransparency = 0.4
	elseif ready then
		-- a hop and a wiggle, again and again, until it's opened
		task.spawn(function()
			while chest.Parent do
				UILib.tween(chest, { Position = UDim2.fromOffset(WEEK_W / 2, 112), Rotation = -6 }, 0.18, Enum.EasingStyle.Quad)
				task.wait(0.2)
				UILib.tween(chest, { Position = UDim2.fromOffset(WEEK_W / 2, 124), Rotation = 5 }, 0.22, Enum.EasingStyle.Bounce)
				task.wait(0.3)
				UILib.tween(chest, { Rotation = 0 }, 0.2)
				task.wait(1.1)
			end
		end)
	end
	local badge = UILib.badge(card, "WEEKLY QUEST", "Gold", -4, 6)
	badge.AnchorPoint = Vector2.new(0.5, 0.5)
	badge.Position = UDim2.new(0.5, 0, 0, -4)

	-- countdown pill under the chest
	local pill = make("Frame", {
		Name = "Ends", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.1, AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromOffset(WEEK_W / 2, 206), Size = UDim2.fromOffset(0, 26), AutomaticSize = Enum.AutomaticSize.X,
		Parent = card,
	})
	UILib.corner(pill, 999)
	UILib.stroke(pill, C.GoldDeep, 2, true)
	UILib.pad(pill, 12, 0, 12, 0)
	local endsLabel = UILib.text(pill, {
		text = "", size = 15, color = C.GoldTop, autoX = true, frameSize = UDim2.fromScale(0, 1), stroke = 1.5, shadow = 1,
	})

	-- title, how-to, progress
	local title = tostring(q.title or "Weekly quest")
	local face = UILib.text(card, {
		name = "Title", text = title, size = 26, frameSize = UDim2.fromOffset(WEEK_W - 32, 32),
		position = UDim2.fromOffset(16, 236), stroke = 3, shadow = 3, gradient = { C.White, C.GoldTop },
	})
	UILib.fitText(face, title, 26, WEEK_W - 40, 14)
	UILib.body(card, {
		name = "Desc", text = ready and "Done! Open your chest." or (claimed and "Chest opened - a new one comes Monday!"
			or tostring(q.desc or "")), size = 14, color = C.Cream, wrap = true, xAlign = Enum.TextXAlignment.Center,
		frameSize = UDim2.fromOffset(WEEK_W - 40, 34), position = UDim2.fromOffset(20, 268),
		yAlign = Enum.TextYAlignment.Top,
	})
	local bar = UILib.progressBar(card, {
		size = UDim2.fromOffset(WEEK_W - 40, 34), position = UDim2.fromOffset(20, 304), tone = claimed and "Green" or "Gold",
		textSize = 18, value = progressOf(q) / targetOf(q), text = barText(q),
	})

	-- the chest's contents
	local row = make("Frame", {
		Name = "Rewards", BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 346),
		Size = UDim2.fromOffset(WEEK_W - 24, 28), Parent = card,
	})
	UILib.list(row, "x", 16, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	for i, part in partsOf(q) do
		rewardChip(row, part, i, 28)
	end

	-- CLAIM / REROLL / opened
	if ready then
		claimButton(card, {
			text = "OPEN CHEST!", icon = iconOr("chest", "gift"), iconSize = 34, textSize = 24,
			size = UDim2.fromOffset(WEEK_W - 40, 44), position = UDim2.fromOffset(20, 388),
			onClaim = function(from) ctx.claim(q, from) end,
		})
	elseif claimed then
		claimedStamp(card, UDim2.fromOffset(WEEK_W / 2, 410), "OPENED")
	else
		rerollButton(card, {
			size = UDim2.fromOffset(190, 38), position = UDim2.fromOffset(WEEK_W / 2, 412), anchor = Vector2.new(0.5, 0.5),
			cost = ctx.weeklyCost, hasProgress = progressOf(q) > 0, textSize = 18,
			onReroll = function() ctx.reroll(q) end,
		})
	end
	return { card = card, pop = pop, bar = bar, q = q, ends = endsLabel, chest = chest }
end

------------------------------------------------------------------
-- actions
------------------------------------------------------------------
local busy = false

local function claim(q, from: GuiObject?)
	if busy then return end
	busy = true
	local ok, res = pcall(function() return Remotes.ClaimQuest():InvokeServer(q.id) end)
	busy = false
	if not (ok and type(res) == "table" and res.ok) then
		UILib.toast(ok and type(res) == "table" and res.message or "Can't claim that yet.", "error")
		return
	end
	local text = table.concat(res.parts or {}, " + ")
	if res.slot == "weekly" then
		UILib.fx("banner", "WEEKLY CHEST!", text, "purple")
		UILib.toast("CHEST OPENED!", "unlock", "+" .. text)
	else
		UILib.toast("QUEST CLAIMED!", "unlock", "+" .. text)
	end
	if (tonumber(res.tickets) or 0) > 0 then UILib.fx("coinBurst", from, res.tickets, "tickets") end
	if (tonumber(res.cash) or 0) > 0 then UILib.fx("coinBurst", from, res.cash) end
end

local function reroll(q)
	if busy then return end
	busy = true
	local ok, res = pcall(function() return Remotes.RerollQuest():InvokeServer(q.id) end)
	busy = false
	if ok and type(res) == "table" and res.ok then
		flipId = res.id
		UILib.toast("NEW QUEST!", (tonumber(res.cost) or 0) > 0 and "ticket" or "info", tostring(res.title or ""))
	else
		UILib.toast(ok and type(res) == "table" and res.message or "Can't reroll that now.", "error")
	end
end

------------------------------------------------------------------
-- the panel
------------------------------------------------------------------
-- what decides the cards' look: rebuilt when it changes, bars move in place otherwise
local function signatureOf(st): string
	local bits = { tostring(st.day), tostring(st.week) }
	local function add(q)
		table.insert(bits, ("%s:%s:%s:%s:%s"):format(tostring(q.id), isDone(q) and "1" or "0",
			q.claimed == true and "1" or "0", tostring(q.target), progressOf(q) > 0 and "p" or "-"))
	end
	for _, q in st.daily or {} do add(q) end
	if type(st.weekly) == "table" then add(st.weekly) end
	local rr = type(st.rerolls) == "table" and st.rerolls or {}
	table.insert(bits, tostring(rr.cost) .. ":" .. tostring(st.weeklyRerollCost))
	return table.concat(bits, "|")
end

function QuestsUI.open()
	local p = UILib.panel({ name = "QuestsPanel", title = "QUESTS", icon = "quests", width = PANEL_W, height = PANEL_H })
	local content = p.content
	panelOpen = true
	p.onClose(function() panelOpen = false end)
	readLive()

	-- header: daily set + reset timer | done pips | ticket balance
	local strip = make("Frame", {
		Name = "Header", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.08, Size = UDim2.new(1, 0, 0, HEADER_H),
		Parent = content,
	})
	UILib.corner(strip, 18)
	UILib.stroke(strip, C.GoldDeep, 3, true)
	UILib.image(strip, "quests", { size = UDim2.fromOffset(80, 80), position = UDim2.fromOffset(-10, -16), z = 2 })
	UILib.text(strip, {
		text = "DAILY QUESTS", size = 16, color = C.GoldTop, xAlign = Enum.TextXAlignment.Left,
		frameSize = UDim2.fromOffset(260, 20), position = UDim2.fromOffset(78, 6), stroke = 1.5, shadow = 1,
	})
	local resetLabel = UILib.text(strip, {
		text = "", font = F.Number, size = 22, xAlign = Enum.TextXAlignment.Left,
		frameSize = UDim2.fromOffset(300, 28), position = UDim2.fromOffset(78, 25), stroke = 2.5, shadow = 2,
	})
	local pipRow = make("Frame", {
		Name = "Pips", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 40, 0.5, 0), Size = UDim2.fromOffset(300, 40), Parent = strip,
	})
	UILib.list(pipRow, "x", 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	local ticketPill = make("Frame", {
		Name = "Tickets", BackgroundColor3 = C.White, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(0, 36), AutomaticSize = Enum.AutomaticSize.X, Parent = strip,
	})
	UILib.corner(ticketPill, 999)
	UILib.gradient(ticketPill, Tones.Pink.top, Tones.Pink.base)
	UILib.stroke(ticketPill, C.Ink, 2.5, true)
	UILib.pad(ticketPill, 40, 0, 14, 0)
	UILib.image(ticketPill, "ticket", { size = UDim2.fromOffset(46, 46), position = UDim2.fromOffset(-44, -5), z = 2 })
	local ticketLabel = UILib.text(ticketPill, {
		text = "0", font = F.Number, size = 20, autoX = true, frameSize = UDim2.fromScale(0, 1), stroke = 2, shadow = 1,
	})

	local cardsFrame = make("Frame", {
		Name = "Cards", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = content,
	})
	local emptyLabel = UILib.body(content, {
		name = "Loading", text = "Dealing your quests...", font = F.Display, size = 26, color = C.Brown,
		xAlign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 0, 40), position = UDim2.fromOffset(0, 240),
	})

	local ctx = { claim = claim, reroll = reroll, rerollCost = 0, weeklyCost = 0 }
	local built = {}       -- id -> the card's live handle
	local wasReady = {}    -- id -> ready at the last build (a quest finishing while you watch pops)
	local weeklyCard = nil
	local signature = nil
	local first = true

	local function renderPips(st)
		for _, ch in pipRow:GetChildren() do
			if ch:IsA("GuiObject") then ch:Destroy() end
		end
		local done, total = 0, 0
		for i, q in st.daily or {} do
			total += 1
			local isOn = isDone(q)
			if isOn then done += 1 end
			local pip = make("Frame", {
				Name = "Pip" .. i, BackgroundColor3 = C.White, Size = UDim2.fromOffset(30, 30), LayoutOrder = i, Parent = pipRow,
			})
			UILib.corner(pip, 999)
			UILib.stroke(pip, C.Ink, 2.5, true)
			if isOn then
				UILib.gradient(pip, q.claimed and Tones.Green.top or C.GoldTop, q.claimed and Tones.Green.base or C.GoldDeep)
				UILib.image(pip, UILib.Tex.check, {
					size = UDim2.fromOffset(28, 28), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5),
				})
			else
				UILib.gradient(pip, Color3.fromHex("#5A4048"), Color3.fromHex("#2E2428"))
			end
		end
		UILib.text(pipRow, {
			text = total > 0 and ("%d/%d DONE"):format(done, total) or "", size = 18, autoX = true,
			frameSize = UDim2.fromOffset(0, 30), order = 99, color = done >= total and total > 0 and C.GreenTop or C.White,
			stroke = 2, shadow = 1,
		})
	end

	-- the countdowns (1 Hz, and right after the cards are rebuilt)
	local function tick()
		local st = questState()
		if not st then
			resetLabel.Text = ""
			return
		end
		resetLabel.Text = "NEW QUESTS IN " .. UILib.clock(UILib.secondsLeft(st.resetIn))
		if weeklyCard and weeklyCard.ends.Parent then
			local left = longClock(UILib.secondsLeft(st.weekResetIn))
			weeklyCard.ends.Text = weeklyCard.q.claimed == true and ("NEW CHEST IN " .. left) or ("ENDS IN " .. left)
		end
	end

	local function render(force: boolean?)
		if not p.alive then return end
		local st = questState()
		ticketLabel.Text = UILib.commas(tonumber(UILib.state.tickets) or 0)
		if not st or #(st.daily or {}) == 0 then
			emptyLabel.Visible = true
			return
		end
		emptyLabel.Visible = false
		local s = signatureOf(st)
		if not force and s == signature then
			-- just the bars
			for _, h in built do
				h.bar.set(progressOf(h.q) / targetOf(h.q), barText(h.q))
			end
			return
		end
		signature = s
		local rr = type(st.rerolls) == "table" and st.rerolls or {}
		ctx.rerollCost = math.max(0, tonumber(rr.cost) or 0)
		ctx.weeklyCost = math.max(0, tonumber(st.weeklyRerollCost) or 0)
		for _, ch in cardsFrame:GetChildren() do
			if ch:IsA("GuiObject") then ch:Destroy() end
		end
		table.clear(built)
		renderPips(st)
		local order = 0
		local function enter(h)
			order += 1
			local nowReady = isReady(h.q)
			if h.q.id == flipId then
				flipId = nil
				h.pop.Scale = 0.15
				UILib.tween(h.pop, { Scale = 1 }, 0.4, Enum.EasingStyle.Back)
				UILib.fx("sparkle", h.card, 10, C.GoldTop)
				UILib.fx("sound", "pop")
			elseif first then
				h.pop.Scale = 0.6
				local delayT = 0.05 * order
				task.delay(delayT, function()
					if h.card.Parent then UILib.tween(h.pop, { Scale = 1 }, 0.32, Enum.EasingStyle.Back) end
				end)
			elseif nowReady and wasReady[h.q.id] == false then
				h.pop.Scale = 0.85
				UILib.tween(h.pop, { Scale = 1 }, 0.35, Enum.EasingStyle.Back)
				UILib.fx("celebrate", "small", h.card)
			end
			wasReady[h.q.id] = nowReady
		end
		for i, q in st.daily do
			local h = buildDaily(cardsFrame, q, TOP + (i - 1) * (CARD_H + CARD_GAP), ctx)
			built[q.id] = h
			enter(h)
		end
		weeklyCard = nil
		if type(st.weekly) == "table" then
			weeklyCard = buildWeekly(cardsFrame, st.weekly, ctx)
			built[st.weekly.id] = weeklyCard
			enter(weeklyCard)
		end
		first = false
		tick()
	end

	local unsub = UILib.subscribe(function() render(false) end)
	p.onClose(unsub)
	local conn = player:GetAttributeChangedSignal("QuestProgress"):Connect(function()
		readLive()
		render(false)
	end)
	p.onClose(function() conn:Disconnect() end)
	render(true)
	task.spawn(function()
		while p.alive do
			tick()
			task.wait(1)
		end
	end)
end

------------------------------------------------------------------
-- the HUD tile + server pushes
------------------------------------------------------------------
local function hudRefresh()
	if not tile then return end
	local st = questState()
	if not st then
		tile.setAlert(false)
		tile.setText(nil)
		return
	end
	local ready, done, total = 0, 0, 0
	for _, q in st.daily or {} do
		total += 1
		if isDone(q) then done += 1 end
		if isReady(q) then ready += 1 end
	end
	if type(st.weekly) == "table" and isReady(st.weekly) then ready += 1 end
	tile.setAlert(ready > 0)
	tile.setText(total > 0 and ("%d/%d"):format(done, total) or nil)
end

local function tilePop()
	if tile and tile.Instance then
		UILib.fx("pop", tile.Instance, 1.2)
		UILib.fx("sparkle", tile.Instance, 8, C.PurpleTop)
	end
end

function QuestsUI.start(d)
	deps = d or {}
	if started then return end
	started = true
	local HudUI = deps.HudUI
	if HudUI and type(HudUI.addRailTile) == "function" then
		local ok, res = pcall(HudUI.addRailTile, {
			id = "quests", label = "QUESTS", icon = "quests", tone = "Purple", order = 10,
			onClick = function() QuestsUI.open() end,
		})
		if ok then tile = res else warn("[QuestsUI] HUD tile: " .. tostring(res)) end
	end
	readLive()

	-- a quest finished (server): toast + the tile pops (+ a banner for the weekly)
	Remotes.QuestDone().OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then return end
		local title = tostring(payload.title or "")
		if payload.slot == "weekly" then
			UILib.fx("banner", "WEEKLY QUEST DONE!", title, "purple")
			UILib.toast("WEEKLY QUEST DONE!", "unlock", title .. " - open your chest in QUESTS!")
		else
			UILib.toast("QUEST COMPLETE!", "unlock", title .. " - claim it in QUESTS!")
		end
		tilePop()
	end)

	-- a new day's set while playing, rewards paid out at a rollover
	local lastDay, lastNotice = nil, nil
	UILib.subscribe(function(snap)
		local st = type(snap) == "table" and snap.quests or nil
		if type(st) ~= "table" then return end
		local day = tonumber(st.day)
		if day and lastDay and day > lastDay then
			UILib.toast("NEW DAILY QUESTS!", "info", "Three new quests are waiting - tap QUESTS.")
			tilePop()
		end
		lastDay = day or lastDay
		local notice = st.notice
		if type(notice) == "table" and notice.id ~= nil and notice.id ~= lastNotice then
			lastNotice = notice.id
			UILib.toast("QUEST REWARDS PAID OUT", "unlock", tostring(notice.text or ""))
		end
		hudRefresh()
	end)
	player:GetAttributeChangedSignal("QuestProgress"):Connect(function()
		readLive()
		hudRefresh()
	end)
	task.spawn(function()
		while true do
			hudRefresh()
			task.wait(1)
		end
	end)
end

return QuestsUI
