--!nonstrict
-- StatsUI.luau — CASINO STATS: six stat tiles (tone + 3D icon + big number),
-- refreshed every 2 s while open (stats change server-side as NPCs gamble).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local F = UILib.Fonts

local StatsUI = {}

local function refresh()
	task.spawn(function()
		local snap = Remotes.GetData():InvokeServer()
		if snap then UILib.setState(snap) end
	end)
end

local TILES = {
	{ key = "earned",  label = "HOUSE PROFIT",   icon = "cash",  tone = "Green",  color = C.Green },
	{ key = "paid",    label = "PAID TO WINNERS", icon = "coin",  tone = "Red",    color = C.Crimson },
	{ key = "spins",   label = "GAMES HOSTED",   icon = "slot",  tone = "Purple", color = C.Purple },
	{ key = "biggest", label = "BIGGEST PAYOUT", icon = "crown", tone = "Gold",   color = C.GoldDeep },
	{ key = "placed",  label = "MACHINES PLACED", icon = "build", tone = "Blue",   color = C.Blue },
	{ key = "stored",  label = "IN YOUR ITEMS",  icon = "items", tone = "Orange", color = C.Orange },
}

function StatsUI.open()
	local p = UILib.panel({ name = "StatsPanel", title = "CASINO STATS", icon = "stats", width = 900, height = 470 })
	local grid = UILib.make("Frame", { Name = "Grid", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = p.content })
	UILib.make("UIGridLayout", {
		CellSize = UDim2.new(0.5, -8, 0, 104), CellPadding = UDim2.fromOffset(16, 14),
		SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid,
	})
	UILib.pad(grid, 4, 6, 4, 0)

	local values = {}
	for i, t in TILES do
		local tone = UILib.Tones[t.tone]
		local tile = UILib.make("Frame", { Name = t.key, BackgroundColor3 = C.Cream, LayoutOrder = i, Parent = grid })
		UILib.corner(tile, 20)
		UILib.stroke(tile, C.Ink, 3.5, true)
		local box = UILib.make("Frame", {
			BackgroundColor3 = C.White, Position = UDim2.fromOffset(10, 10), Size = UDim2.fromOffset(84, 84), Parent = tile,
		})
		UILib.corner(box, 18)
		UILib.gradient(box, tone.top, tone.base)
		UILib.stroke(box, C.Ink, 3.5, true)
		UILib.image(box, t.icon, { size = UDim2.fromScale(1.05, 1.05), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.46) })
		UILib.body(tile, {
			text = t.label, font = F.Display, size = 18, frameSize = UDim2.new(1, -116, 0, 24),
			position = UDim2.fromOffset(108, 16), transparency = 0.15,
		})
		values[t.key] = UILib.text(tile, {
			text = "0", font = F.Number, size = 34, color = t.color, xAlign = Enum.TextXAlignment.Left,
			frameSize = UDim2.new(1, -116, 0, 44), position = UDim2.fromOffset(108, 44), stroke = 3, shadow = 3,
			strokeColor = C.Ink,
		})
	end

	local function render(state)
		if not p.alive then return end
		local s = state.stats or {}
		UILib.countTo(values.earned, s.TotalEarned or 0, UILib.money)
		UILib.countTo(values.paid, s.TotalPaidOut or 0, UILib.money)
		UILib.countTo(values.spins, s.SpinsHosted or 0, UILib.commas)
		UILib.countTo(values.biggest, s.BiggestWinPaid or 0, UILib.money)
		UILib.countTo(values.placed, #(state.placed or {}), UILib.commas)
		UILib.countTo(values.stored, #(state.inventory or {}), UILib.commas)
	end
	local unsub = UILib.subscribe(render)
	p.onClose(unsub)

	refresh()
	task.spawn(function()
		while p.alive do
			task.wait(2)
			if p.alive then refresh() end
		end
	end)
end

return StatsUI
