--!nonstrict
-- PlaytimeUI.luau — the PLAYTIME panel: rewards for the time played today
-- (Config.Playtime.Rewards; CasinoServer/Playtime.luau counts the time and pays).
-- A grid of reward cards: cream while locked (a bar counts down to it), glowing
-- in the reward's tone with a CLAIM button once unlocked, green with a check once
-- claimed; the last one is the double-width GRAND PRIZE. CLAIM ALL takes every
-- unlocked one at once.
-- It also drives the HUD PLAYTIME tile (HudUI.playtime): the timer pill counts
-- down to the next reward ("READY!" when one waits) and the alert shows while
-- something can be claimed.
-- Snapshot `playtime` = { day, seconds, claimed, cash, resetIn, notice? }; the
-- seconds keep running here between pushes (UILib.stateTime).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local Config = require(Common:WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local F = UILib.Fonts
local Tones = UILib.Tones
local make = UILib.make

local PlaytimeUI = {}

local PANEL_W = 1040
local CONTENT_W = PANEL_W - 92   -- the panel's content frame (UILib.panel insets)
local CARD_W, CARD_H, GAP, ROW_GAP, PER_ROW = 176, 206, 13, 14, 5
local HEADER_H = 64

local panelOpen = false

------------------------------------------------------------------
-- state helpers
------------------------------------------------------------------
local function rewardList()
	return (Config.Playtime and Config.Playtime.Rewards) or {}
end

-- seconds played today, now: the server's count + the time since that snapshot
local function playedNow(pt): number
	return (tonumber(pt and pt.seconds) or 0) + math.max(0, os.clock() - UILib.stateTime)
end

local function isClaimed(pt, i: number): boolean
	return type(pt) == "table" and type(pt.claimed) == "table" and pt.claimed[i] == true
end

-- "claimed" | "ready" | "locked", + seconds until it unlocks
local function statusOf(pt, i: number, played: number): (string, number)
	if isClaimed(pt, i) then return "claimed", 0 end
	local left = ((rewardList()[i] or {}).at or 0) * 60 - played
	if left <= 0 then return "ready", 0 end
	return "locked", left
end

-- "5 MIN" / "1 HOUR" / "1H 30M" / "2 HOURS"
local function atLabel(minutes: number): string
	minutes = math.floor(tonumber(minutes) or 0)
	if minutes < 60 then return minutes .. " MIN" end
	local h, m = minutes // 60, minutes % 60
	if m == 0 then return h == 1 and "1 HOUR" or (h .. " HOURS") end
	return ("%dH %02dM"):format(h, m)
end

-- what a reward piece reads under its icon
local function caption(part): string
	local n = tonumber(part.amount) or 0
	if part.kind == "cash" then return UILib.moneyShort(n) end
	if part.kind == "tickets" then return UILib.commas(n) .. " TICKETS" end
	if part.kind == "potion" then return (n > 1 and (n .. "x ") or "") .. string.upper(part.name) end
	if part.kind == "boost" then return ("x3 BOOST %d MIN"):format(n) end
	if part.kind == "rcoin" then return n .. (n == 1 and " REBIRTH COIN" or " REBIRTH COINS") end
	return string.upper(tostring(part.name or ""))
end
PlaytimeUI.caption = caption

local function partsOf(pt, i: number)
	local cash = type(pt) == "table" and type(pt.cash) == "table" and tonumber(pt.cash[i]) or nil
	return Config.rewardParts(rewardList()[i], cash)
end

------------------------------------------------------------------
-- the panel
------------------------------------------------------------------
-- card slots: rows of PER_ROW units, a `grand` card takes two; rows are centred
local function layout(list)
	local slots, rowUnits = {}, {}
	local row, col = 0, 0
	for i, r in list do
		local units = r.grand and 2 or 1
		if col + units > PER_ROW then
			row += 1
			col = 0
		end
		slots[i] = { row = row, col = col, units = units }
		col += units
		rowUnits[row] = col
	end
	for _, s in slots do
		local used = rowUnits[s.row]
		local left = (CONTENT_W - (used * CARD_W + (used - 1) * GAP)) / 2
		s.x = left + s.col * (CARD_W + GAP)
		s.y = s.row * (CARD_H + ROW_GAP)
		s.w = s.units * CARD_W + (s.units - 1) * GAP
	end
	return slots, row + 1
end

-- one reward card; returns { status, bar? } for the live updates
local function buildCard(parent, i: number, slot, pt, played: number, onClaim)
	local r = rewardList()[i]
	local st, left = statusOf(pt, i, played)
	local parts = partsOf(pt, i)
	local main = parts[1] or { kind = "cash", icon = "coin", tone = "Gold", name = "", amount = 0 }
	local tone = Tones[main.tone] or Tones.Gold
	local grand = r.grand == true
	local w = slot.w

	local card = make("Frame", {
		Name = "Reward" .. i, BackgroundColor3 = C.White, Position = UDim2.fromOffset(slot.x, slot.y),
		Size = UDim2.fromOffset(w, CARD_H), Parent = parent,
	})
	UILib.corner(card, 22)
	local lit = st ~= "locked" or grand
	if st == "claimed" then
		UILib.gradient(card, Tones.Green.top, Tones.Green.base)
	elseif st == "ready" then
		UILib.gradient(card, tone.top, tone.base)
	elseif grand then
		-- the grand prize shows off even while locked: deep purple velvet
		UILib.gradient(card, Tones.Purple.base, Tones.Purple.shadow)
	else
		UILib.gradient(card, C.Cream, C.CreamRow)
	end
	UILib.stroke(card, st == "ready" and C.Gold or C.Ink, st == "ready" and 6 or 3.5, true)

	if st == "ready" then
		-- rotating rays behind the prize, clipped to the card
		local clip = make("Frame", {
			Name = "GlowClip", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ClipsDescendants = true,
			ZIndex = 0, Parent = card,
		})
		UILib.corner(clip, 22)
		local glow = UILib.image(clip, UILib.Tex.sunburst, {
			size = UDim2.fromOffset(300, 300), anchor = Vector2.new(0.5, 0.5), position = UDim2.new(0.5, 0, 0, 78),
			color = C.GoldTop, transparency = 0.5, z = 0,
		})
		UILib.spin(glow, 16)
	end

	-- the time it unlocks at: a small ink tag in the corner
	local tag = make("Frame", {
		Name = "At", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.12, Position = UDim2.fromOffset(10, 10),
		Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, Parent = card,
	})
	UILib.corner(tag, 999)
	UILib.pad(tag, 10, 0, 10, 0)
	UILib.text(tag, {
		text = atLabel(r.at), size = 15, color = C.GoldTop, autoX = true, frameSize = UDim2.fromScale(0, 1),
		stroke = 1.5, shadow = 1,
	})

	-- the prize: one big icon, or (grand prize) every piece side by side
	local shown = grand and math.min(#parts, 3) or 1
	local iconSize = grand and 82 or 86
	local span = shown * iconSize + (shown - 1) * 30
	for k = 1, shown do
		local part = parts[k] or main
		local img = UILib.image(card, part.icon, {
			size = UDim2.fromOffset(iconSize, iconSize), anchor = Vector2.new(0.5, 0.5),
			position = UDim2.new(0.5, -span / 2 + (k - 1) * (iconSize + 30) + iconSize / 2, 0, 80),
		})
		if not lit then img.ImageTransparency = 0.3 end
		if k < shown then
			UILib.text(card, {
				text = "+", size = 30, frameSize = UDim2.fromOffset(30, 40), anchor = Vector2.new(0.5, 0.5),
				position = UDim2.new(0.5, -span / 2 + k * (iconSize + 30) - 15, 0, 80),
			})
		end
	end
	-- a second piece on a single card: a small chip on the icon's shoulder
	if not grand and parts[2] then
		local extra = parts[2]
		local chip = make("Frame", {
			Name = "Extra", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.1, AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -8, 0, 40), Size = UDim2.fromOffset(0, 28), AutomaticSize = Enum.AutomaticSize.X,
			Parent = card,
		})
		UILib.corner(chip, 999)
		UILib.stroke(chip, C.GoldDeep, 2, true)
		UILib.pad(chip, 4, 0, 10, 0)
		UILib.list(chip, "x", 2, nil, Enum.VerticalAlignment.Center)
		UILib.image(chip, extra.icon, { size = UDim2.fromOffset(26, 26), order = 1 })
		UILib.text(chip, {
			text = "+" .. (extra.kind == "cash" and UILib.moneyShort(extra.amount) or UILib.short(extra.amount)),
			font = F.Number, size = 16, autoX = true, frameSize = UDim2.fromScale(0, 1), order = 2, stroke = 1.5, shadow = 1,
		})
	end

	-- caption
	local capText = caption(main)
	if grand then
		local list = {}
		for k = 1, shown do table.insert(list, caption(parts[k])) end
		capText = table.concat(list, " + ")
	end
	local capW = w - 16
	if lit then
		local face = UILib.text(card, {
			text = capText, size = 20, frameSize = UDim2.fromOffset(capW, 26), position = UDim2.fromOffset(8, 124),
			stroke = 2.5, shadow = 2,
		})
		UILib.fitText(face, capText, 20, capW, 12)
	else
		local lbl = UILib.body(card, {
			text = capText, font = F.Display, size = 20, color = C.Brown, xAlign = Enum.TextXAlignment.Center,
			frameSize = UDim2.fromOffset(capW, 26), position = UDim2.fromOffset(8, 124),
		})
		UILib.fitText(lbl, capText, 20, capW, 12)
	end

	-- bottom: countdown bar / CLAIM / CLAIMED
	local live = { status = st }
	if st == "locked" then
		local need = math.max(1, (r.at or 0) * 60)
		live.need = need
		live.bar = UILib.progressBar(card, {
			size = UDim2.fromOffset(w - 24, 32), position = UDim2.new(0, 12, 1, -46), tone = grand and "Gold" or main.tone,
			textSize = 17, value = math.clamp(played / need, 0, 1), text = UILib.clock(left),
		})
	elseif st == "ready" then
		UILib.button({
			parent = card, tone = "Gold", text = "CLAIM!", textSize = 24, size = UDim2.fromOffset(w - 24, 44),
			position = UDim2.new(0, 12, 1, -54), onClick = function() onClaim(i) end,
		})
		local b = UILib.badge(card, grand and "GRAND PRIZE!" or "READY!", grand and "Gold" or "Red", -6, 6)
		b.AnchorPoint = Vector2.new(0.5, 0.5)
		b.Position = UDim2.new(0.5, 0, 0, -8)
	else
		UILib.text(card, {
			text = "CLAIMED", size = 22, frameSize = UDim2.new(1, 0, 0, 30), position = UDim2.new(0, 0, 1, -44),
			stroke = 2.5, shadow = 2,
		})
		UILib.image(card, UILib.Tex.check, { size = UDim2.fromOffset(42, 42), position = UDim2.new(1, -28, 0, -14) })
	end
	if grand and st == "locked" then
		local b = UILib.badge(card, "GRAND PRIZE", "Gold", -6, 6)
		b.AnchorPoint = Vector2.new(0.5, 0.5)
		b.Position = UDim2.new(0.5, 0, 0, -8)
	end
	return live
end

function PlaytimeUI.open()
	local list = rewardList()
	local slots, rows = layout(list)
	local gridH = rows * CARD_H + (rows - 1) * ROW_GAP
	local p = UILib.panel({
		name = "PlaytimePanel", title = "PLAYTIME", icon = "playtime", width = PANEL_W,
		height = HEADER_H + 16 + gridH + 120,
	})
	local content = p.content
	panelOpen = true
	p.onClose(function() panelOpen = false end)

	-- header: played today | next reward + reset | CLAIM ALL
	local strip = make("Frame", {
		Name = "Header", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.08, Size = UDim2.new(1, 0, 0, HEADER_H - 6),
		Parent = content,
	})
	UILib.corner(strip, 18)
	UILib.stroke(strip, C.GoldDeep, 3, true)
	UILib.image(strip, "playtime", { size = UDim2.fromOffset(78, 78), position = UDim2.fromOffset(-8, -14), z = 2 })
	UILib.text(strip, {
		text = "PLAYED TODAY", size = 16, color = C.GoldTop, xAlign = Enum.TextXAlignment.Left,
		frameSize = UDim2.fromOffset(220, 20), position = UDim2.fromOffset(76, 6), stroke = 1.5, shadow = 1,
	})
	local playedLabel = UILib.text(strip, {
		text = "0:00", font = F.Number, size = 28, xAlign = Enum.TextXAlignment.Left,
		frameSize = UDim2.fromOffset(220, 32), position = UDim2.fromOffset(76, 25), stroke = 3, shadow = 2,
	})
	local statusLabel = UILib.text(strip, {
		text = "", size = 20, frameSize = UDim2.fromOffset(440, 26), anchor = Vector2.new(0.5, 0),
		position = UDim2.new(0.5, 10, 0, 6), stroke = 2.5, shadow = 2,
	})
	local resetLabel = UILib.body(strip, {
		text = "", size = 13, color = C.CreamRow, xAlign = Enum.TextXAlignment.Center,
		frameSize = UDim2.fromOffset(440, 18), anchor = Vector2.new(0.5, 0), position = UDim2.new(0.5, 10, 0, 34),
	})
	local claimAll = UILib.button({
		parent = strip, tone = "Gold", text = "CLAIM ALL", textSize = 22, size = UDim2.fromOffset(176, 46),
		anchor = Vector2.new(1, 0.5), position = UDim2.new(1, -8, 0.5, -2),
	})
	claimAll.Instance.Visible = false

	local grid = make("Frame", {
		Name = "Rewards", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, HEADER_H + 16),
		Size = UDim2.new(1, 0, 0, gridH), Parent = content,
	})

	local busy = false
	local function claim(index)
		if busy then return end
		busy = true
		local ok, res = pcall(function() return Remotes.ClaimPlaytime():InvokeServer(index) end)
		busy = false
		if ok and type(res) == "table" and res.ok then
			local def = type(index) == "number" and list[index]
			local text = "+" .. table.concat(res.parts or {}, " + ")
			if def and def.grand then
				UILib.toast("GRAND PRIZE!", "unlock", text)
				UILib.fx("banner", "GRAND PRIZE!", table.concat(res.parts or {}, " + "), "purple")
			else
				UILib.toast(index == "all" and "REWARDS CLAIMED!" or "REWARD CLAIMED!", "unlock", text)
			end
		else
			UILib.toast((ok and type(res) == "table" and res.message) or "Can't claim that yet.", "error")
		end
	end
	claimAll.onClick(function() claim("all") end)

	local live = {}
	local signature = nil
	local function sig(pt, played: number): string
		local bits = { tostring(pt.day) }
		for i in list do
			local st = statusOf(pt, i, played)
			table.insert(bits, st .. ":" .. tostring(type(pt.cash) == "table" and pt.cash[i] or 0))
		end
		return table.concat(bits, "|")
	end
	local function render(force: boolean?)
		if not p.alive then return end
		local pt = UILib.state.playtime
		if type(pt) ~= "table" then return end
		local played = playedNow(pt)
		local s = sig(pt, played)
		if not force and s == signature then return end
		signature = s
		for _, ch in grid:GetChildren() do
			if ch:IsA("GuiObject") then ch:Destroy() end
		end
		table.clear(live)
		for i in list do
			live[i] = buildCard(grid, i, slots[i], pt, played, claim)
		end
	end

	-- 1 Hz: clocks + bars; a card whose status changed rebuilds the grid
	local function tick()
		local pt = UILib.state.playtime
		if type(pt) ~= "table" then
			statusLabel.Text = "Loading..."
			return
		end
		local played = playedNow(pt)
		playedLabel.Text = UILib.clock(played)
		for i in list do
			local l = live[i]
			if l and l.status ~= statusOf(pt, i, played) then
				render(true) -- a reward unlocked (or was claimed): rebuild the cards
				break
			end
		end
		local ready, nextLeft = 0, nil
		for i in list do
			local st, left = statusOf(pt, i, played)
			if st == "ready" then
				ready += 1
			elseif st == "locked" and (nextLeft == nil or left < nextLeft) then
				nextLeft = left
			end
			local l = live[i]
			if l and l.bar and st == "locked" then
				l.bar.set(math.clamp(played / l.need, 0, 1), UILib.clock(left))
			end
		end
		if ready > 0 then
			statusLabel.Text = ready == 1 and "A REWARD IS READY!" or (ready .. " REWARDS READY!")
		elseif nextLeft then
			statusLabel.Text = "NEXT REWARD IN " .. UILib.clock(nextLeft)
		else
			statusLabel.Text = "ALL CLAIMED - SEE YOU TOMORROW!"
		end
		resetLabel.Text = ("Rewards reset at midnight UTC - in %s"):format(UILib.clock(UILib.secondsLeft(pt.resetIn)))
		claimAll.Instance.Visible = ready >= 2
	end

	local unsub = UILib.subscribe(function() render(false) end)
	p.onClose(unsub)
	render(true)
	task.spawn(function()
		while p.alive do
			tick()
			task.wait(1)
		end
	end)
end

------------------------------------------------------------------
-- the HUD tile (1 Hz): timer pill + alert, "reward ready" toasts and the
-- server's day-rollover payout notice
------------------------------------------------------------------
function PlaytimeUI.start(deps)
	local HudUI = deps and deps.HudUI
	local announced = {}      -- "day:index" -> true once it was READY this session
	local primed = false      -- (rewards already waiting at join don't toast; the alert shows them)
	local lastNotice = nil
	task.spawn(function()
		while true do
			local pt = UILib.state.playtime
			local hud = HudUI and HudUI.playtime
			if type(pt) == "table" then
				local played = playedNow(pt)
				local ready, nextLeft = 0, nil
				for i, r in rewardList() do
					local st, left = statusOf(pt, i, played)
					if st == "ready" then
						ready += 1
						local key = tostring(pt.day) .. ":" .. i
						if not announced[key] then
							announced[key] = true
							if primed and not panelOpen then
								UILib.toast("PLAYTIME REWARD!", "info",
									("Your %s reward is ready - tap PLAYTIME to claim it."):format(string.lower(atLabel(r.at))))
								if hud and hud.Instance then UILib.fx("pop", hud.Instance, 1.15) end
							end
						end
					elseif st == "locked" and (nextLeft == nil or left < nextLeft) then
						nextLeft = left
					end
				end
				primed = true
				if hud then
					hud.setAlert(ready > 0)
					hud.setText(ready > 0 and "READY!" or (nextLeft and UILib.clock(nextLeft)) or nil)
				end
				local notice = pt.notice
				if type(notice) == "table" and notice.id ~= nil and notice.id ~= lastNotice then
					lastNotice = notice.id
					UILib.toast("PLAYTIME REWARDS ADDED", "unlock", tostring(notice.text or ""))
				end
			elseif hud then
				hud.setAlert(false)
				hud.setText(nil)
			end
			task.wait(1)
		end
	end)
end

return PlaytimeUI
