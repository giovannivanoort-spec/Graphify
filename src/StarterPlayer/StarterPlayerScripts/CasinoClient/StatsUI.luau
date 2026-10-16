--!nonstrict
-- StatsUI.luau — CASINO STATS: a crimson Casino Rank strip on top (rank chip,
-- rank name, clientele, XP progress to the next rank, what's next and how much
-- XP is left), then eight stat tiles (tone + 3D icon + big number): lifetime
-- earnings, Casino XP, games hosted, the biggest payout, paid to winners,
-- rebirths (+ the rebirth coins to spend), machines placed and in your items.
-- Refreshed every 2 s while open (stats change server-side as guests gamble);
-- the XP follows the Player attribute "XP" between snapshots. Money shows every
-- digit while it fits the tile ($1,234,567,890), else $1.23B. The strip hides
-- on a server without ranks.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local Config = require(Common:WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local F = UILib.Fonts

local StatsUI = {}
local player = Players.LocalPlayer

local function refresh()
	task.spawn(function()
		local snap = Remotes.GetData():InvokeServer()
		if snap then UILib.setState(snap) end
	end)
end

local TILES = {
	{ key = "earned",   label = "LIFETIME EARNED", icon = "cash",    tone = "Green",  color = C.Green },
	{ key = "xp",       label = "CASINO XP",       icon = "xp",      tone = "Blue",   color = C.Blue },
	{ key = "spins",    label = "GAMES HOSTED",    icon = "slot",    tone = "Purple", color = C.Purple },
	{ key = "biggest",  label = "BIGGEST PAYOUT",  icon = "crown",   tone = "Gold",   color = C.GoldDeep },
	{ key = "paid",     label = "PAID TO WINNERS", icon = "coin",    tone = "Red",    color = C.Crimson },
	{ key = "rebirths", label = "REBIRTHS",        icon = "rebirth", tone = "Purple", color = C.Purple },
	{ key = "placed",   label = "MACHINES PLACED", icon = "build",   tone = "Blue",   color = C.Blue },
	{ key = "stored",   label = "IN YOUR ITEMS",   icon = "items",   tone = "Orange", color = C.Orange },
}
local STRIP_H = 104
local TILE_H = 92

local function money(n: number): string
	return UILib.moneyFit(n, 14)
end

local function xpText(n: number): string
	return UILib.short(math.max(0, math.floor(tonumber(n) or 0))) .. " XP"
end

local function rankDefs()
	local prog = Config.Progression
	return prog and prog.Ranks or {}
end

local function multText(x): string
	x = tonumber(x) or 1
	if math.abs(x - math.floor(x + 0.5)) < 0.01 then return "x" .. tostring(math.floor(x + 0.5)) end
	return "x" .. string.format("%.1f", x)
end

-- the XP to show: the snapshot's, or the newer Player attribute
local function liveXP(state): number
	local snap = tonumber(state.rankProgress) or tonumber(state.xp) or 0
	local attr = tonumber(player:GetAttribute("XP")) or 0
	return math.max(snap, attr)
end

-- the rank strip; returns render(state) -> boolean (shown?)
local function rankStrip(parent: Instance)
	local strip = UILib.make("Frame", {
		Name = "RankStrip", BackgroundColor3 = C.White, Position = UDim2.fromOffset(4, 4),
		Size = UDim2.new(1, -8, 0, STRIP_H), Visible = false, Parent = parent,
	})
	UILib.corner(strip, 22)
	UILib.gradient(strip, C.CrimsonTop, C.CrimsonDeep)
	UILib.stroke(strip, C.Ink, 4, true)
	local trim = UILib.make("Frame", {
		Name = "Trim", BackgroundTransparency = 1, Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 1, -12),
		Parent = strip,
	})
	UILib.corner(trim, 17)
	UILib.stroke(trim, C.GoldTop, 2, true, 0.2)
	local med = UILib.medallion(strip, { size = 84, number = 1, crown = true, position = UDim2.fromOffset(14, 12), z = 2 })
	local name = UILib.text(strip, {
		name = "RankName", text = "", size = 30, xAlign = Enum.TextXAlignment.Left,
		frameSize = UDim2.fromOffset(336, 36), position = UDim2.fromOffset(112, 8),
		gradient = { C.White, C.GoldTop }, stroke = 3.5, shadow = 3,
	})
	local sub = UILib.body(strip, {
		name = "Perk", text = "", font = F.Heavy, size = 14, color = C.CreamRow,
		frameSize = UDim2.fromOffset(336, 18), position = UDim2.fromOffset(114, 44),
	})
	local bar = UILib.progressBar(strip, {
		name = "RankBar", size = UDim2.fromOffset(336, 26), position = UDim2.fromOffset(112, 66), textSize = 15,
	})
	-- right: what's next
	local nextCap = UILib.body(strip, {
		name = "NextCaption", text = "NEXT RANK", font = F.Display, size = 15, color = C.GoldTop,
		xAlign = Enum.TextXAlignment.Right, frameSize = UDim2.fromOffset(300, 20),
		anchor = Vector2.new(1, 0), position = UDim2.new(1, -20, 0, 12),
	})
	local nextName = UILib.text(strip, {
		name = "NextName", text = "", size = 24, xAlign = Enum.TextXAlignment.Right, frameSize = UDim2.fromOffset(300, 30),
		anchor = Vector2.new(1, 0), position = UDim2.new(1, -20, 0, 32), stroke = 3, shadow = 2,
	})
	local toGo = UILib.text(strip, {
		name = "ToGo", text = "", font = F.Number, size = 20, color = C.GreenTop, xAlign = Enum.TextXAlignment.Right,
		frameSize = UDim2.fromOffset(300, 28), anchor = Vector2.new(1, 0), position = UDim2.new(1, -20, 0, 64),
		stroke = 2.5, shadow = 2,
	})

	return function(state): boolean
		local r = tonumber(state.rank)
		strip.Visible = r ~= nil
		if not r then return false end
		local defs = rankDefs()
		local def = defs[r]
		med.set(r)
		UILib.fitText(name, string.upper(tostring(state.rankName or (def and def.name) or ("Rank " .. r))), 30, 330, 18)
		local clientele = def and def.clientele
		sub.Text = ("RANK %d OF %d"):format(r, math.max(#defs, r))
			.. (clientele and ("   •   GUESTS BRING %s CASH"):format(multText(clientele)) or "")
		local prog = liveXP(state)
		local nxt = tonumber(state.rankNext)
		if nxt then
			local floor = tonumber(state.rankFloor) or 0
			bar.setTone("Gold")
			bar.set((prog - floor) / math.max(1, nxt - floor), UILib.short(math.min(prog, nxt)) .. " / " .. xpText(nxt))
			local nd = defs[r + 1]
			nextCap.Text = "NEXT RANK"
			UILib.fitText(nextName, string.upper(nd and nd.name or ("Rank " .. (r + 1))), 24, 296, 14)
			toGo.Text = xpText(math.max(0, nxt - prog)) .. " TO GO"
		else
			bar.setTone("Purple")
			bar.set(1, xpText(prog))
			nextCap.Text = "TOP OF THE STRIP"
			UILib.fitText(nextName, "YOU'RE THE MASTER!", 24, 296, 14)
			toGo.Text = ""
		end
		return true
	end
end

function StatsUI.open()
	local p = UILib.panel({ name = "StatsPanel", title = "CASINO STATS", icon = "stats", width = 900, height = 640 })
	local renderStrip = rankStrip(p.content)
	local grid = UILib.make("Frame", {
		Name = "Grid", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, STRIP_H + 14),
		Size = UDim2.new(1, 0, 1, -(STRIP_H + 14)), Parent = p.content,
	})
	UILib.make("UIGridLayout", {
		CellSize = UDim2.new(0.5, -8, 0, TILE_H), CellPadding = UDim2.fromOffset(16, 12),
		SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid,
	})
	UILib.pad(grid, 4, 4, 4, 0)

	local values, subs = {}, {}
	for i, t in TILES do
		local tone = UILib.Tones[t.tone]
		local tile = UILib.make("Frame", { Name = t.key, BackgroundColor3 = C.Cream, LayoutOrder = i, Parent = grid })
		UILib.corner(tile, 20)
		UILib.stroke(tile, C.Ink, 3.5, true)
		local box = UILib.make("Frame", {
			BackgroundColor3 = C.White, Position = UDim2.fromOffset(9, 9), Size = UDim2.fromOffset(TILE_H - 18, TILE_H - 18),
			Parent = tile,
		})
		UILib.corner(box, 18)
		UILib.gradient(box, tone.top, tone.base)
		UILib.stroke(box, C.Ink, 3.5, true)
		UILib.image(box, t.icon, { size = UDim2.fromScale(1.05, 1.05), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.46) })
		UILib.body(tile, {
			text = t.label, font = F.Display, size = 17, frameSize = UDim2.new(1, -106, 0, 22),
			position = UDim2.fromOffset(98, 12), transparency = 0.15,
		})
		values[t.key] = UILib.text(tile, {
			text = "0", font = F.Number, size = 31, color = t.color, xAlign = Enum.TextXAlignment.Left,
			frameSize = UDim2.new(1, -106, 0, 40), position = UDim2.fromOffset(96, 38), stroke = 3, shadow = 3,
			strokeColor = C.Ink,
		})
		if t.key == "rebirths" then
			-- the coins to spend, on the right of the tile
			local pill = UILib.make("Frame", {
				Name = "Coins", BackgroundColor3 = C.White, AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -12, 0.62, 0), Size = UDim2.fromOffset(0, 30), AutomaticSize = Enum.AutomaticSize.X,
				Parent = tile,
			})
			UILib.corner(pill, 999)
			UILib.gradient(pill, C.GoldTop, C.GoldDeep)
			UILib.stroke(pill, C.Ink, 2.5, true)
			UILib.pad(pill, 30, 0, 10, 0)
			UILib.image(pill, "rcoin", {
				size = UDim2.fromOffset(34, 34), anchor = Vector2.new(0, 0.5), position = UDim2.new(0, -34, 0.5, 0),
			})
			subs.coins = UILib.text(pill, {
				text = "0 COINS", size = 15, autoX = true, frameSize = UDim2.fromScale(0, 1), stroke = 1.5, shadow = 1,
			})
		end
	end

	local function render(state)
		if not p.alive then return end
		local shown = renderStrip(state)
		-- no ranks (older server): the tiles move up into the strip's place
		grid.Position = UDim2.fromOffset(0, shown and STRIP_H + 14 or 0)
		local s = state.stats or {}
		UILib.countTo(values.earned, s.TotalEarned or 0, money)
		UILib.countTo(values.xp, math.max(tonumber(s.XP) or 0, liveXP(state)), UILib.commas)
		UILib.countTo(values.paid, s.TotalPaidOut or 0, money)
		UILib.countTo(values.spins, s.SpinsHosted or 0, UILib.commas)
		UILib.countTo(values.biggest, s.BiggestWinPaid or 0, money)
		UILib.countTo(values.placed, #(state.placed or {}), UILib.commas)
		UILib.countTo(values.stored, #(state.inventory or {}), UILib.commas)
		local rb = type(state.rebirth) == "table" and state.rebirth or {}
		UILib.countTo(values.rebirths, tonumber(rb.count) or 0, UILib.commas)
		if subs.coins then
			local coins = math.floor(tonumber(rb.coins) or 0)
			subs.coins.Text = ("%s COIN%s"):format(UILib.commas(coins), coins == 1 and "" or "S")
		end
	end
	local unsub = UILib.subscribe(render)
	local xpConn = player:GetAttributeChangedSignal("XP"):Connect(function()
		if p.alive then render(UILib.state) end
	end)
	p.onClose(function()
		unsub()
		xpConn:Disconnect()
	end)

	refresh()
	task.spawn(function()
		while p.alive do
			task.wait(2)
			if p.alive then refresh() end
		end
	end)
end

return StatsUI
