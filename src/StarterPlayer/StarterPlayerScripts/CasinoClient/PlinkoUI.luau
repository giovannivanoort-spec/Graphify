--!nonstrict
-- PlinkoUI.luau — play someone's Plinko machine (Lucky Plinko, Pachinko
-- Palace) in the Showtime style: a pin board with nine multiplier bins, a bet
-- stepper and a big DROP! button. One PlayGame invoke per drop; the server
-- decides the path (detail.path: true = right at that row, detail.pocket =
-- 1 + rights), this only animates the ball down to it. The machine's own 3D
-- board replays the same drop for everyone around (MachineFX).
-- Opened from GamesUI.open for GameType "Plinko".

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local GameLogic = require(Common:WaitForChild("GameLogic"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local F = UILib.Fonts

local PlinkoUI = {}
local open = false

local MULTS = GameLogic.PlinkoMultipliers or { 16, 4, 1.5, 0.5, 0.2, 0.5, 1.5, 4, 16 }
local ROWS = 8
local DX, DY = 50, 27         -- pin pitch (px)
local BIN_TONES = { "Red", "Orange", "Gold", "Green", "Blue", "Green", "Gold", "Orange", "Red" }

local function money(n: number): string
	return "$" .. UILib.commas(n)
end

function PlinkoUI.open(machine: Instance)
	if open then return end
	open = true

	local minBet = machine:GetAttribute("MinBet") or 10
	local maxBet = machine:GetAttribute("MaxBet") or 150
	local bet = minBet
	local dropping = false
	local cashValue = UILib.getCashValue()

	local p = UILib.panel({ name = "PlinkoPanel", title = string.upper(machine.Name), icon = "gem", width = 720, height = 660 })
	local content = p.content
	p.onClose(function() open = false end)

	-- the board: a deep teal plate, gold pins in a triangle, nine bins
	local boardW, boardH = 9 * DX + 40, ROWS * DY + 96
	local board = UILib.make("Frame", {
		Name = "Board", BackgroundColor3 = C.White, AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 0), Size = UDim2.fromOffset(boardW, boardH), ClipsDescendants = false,
		Parent = content,
	})
	UILib.corner(board, 24)
	UILib.gradient(board, Color3.fromHex("#145E6A"), Color3.fromHex("#0B2A33"))
	local boardStroke = UILib.stroke(board, C.Ink, 5, true)
	local cx = boardW / 2
	local top = 26
	for r = 1, ROWS do
		for j = 0, r + 1 do
			local pin = UILib.make("Frame", {
				Name = "Pin", BackgroundColor3 = C.GoldTop, AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(cx + (j - (r + 1) / 2) * DX, top + r * DY), Size = UDim2.fromOffset(9, 9),
				Parent = board,
			})
			UILib.corner(pin, 99)
			UILib.stroke(pin, C.GoldShadow, 1.5, true)
		end
	end
	local binY = top + (ROWS + 1) * DY + 4
	local bins = {}
	for k = 1, 9 do
		local tone = UILib.Tones[BIN_TONES[k]] or UILib.Tones.Gold
		local bin = UILib.make("Frame", {
			Name = "Bin" .. k, BackgroundColor3 = C.White, AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromOffset(cx + (k - 5) * DX, binY), Size = UDim2.fromOffset(DX - 6, 34), Parent = board,
		})
		UILib.corner(bin, 10)
		UILib.gradient(bin, tone.top, tone.base)
		local st = UILib.stroke(bin, C.Ink, 3, true)
		local pop = UILib.make("UIScale", { Parent = bin })
		UILib.text(bin, { text = tostring(MULTS[k]) .. "x", font = F.Number, size = 17, stroke = 2.5, shadow = 0 })
		bins[k] = { frame = bin, stroke = st, pop = pop }
	end
	local ball = UILib.make("Frame", {
		Name = "Ball", BackgroundColor3 = C.White, AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(cx, top - 4), Size = UDim2.fromOffset(18, 18), ZIndex = 5, Parent = board,
	})
	UILib.corner(ball, 99)
	UILib.gradient(ball, C.White, C.PinkTop)
	UILib.stroke(ball, C.Ink, 2.5, true)

	-- result line
	local result = UILib.text(content, {
		text = "PICK YOUR BET AND DROP!", size = 30, color = C.Brown, frameSize = UDim2.new(1, 0, 0, 40),
		position = UDim2.fromOffset(0, boardH + 8), stroke = 0, shadow = 0,
	})
	local resultHolder = result.Parent
	local resultPop = UILib.make("UIScale", { Parent = resultHolder })
	local function showResult(text: string, color: Color3, big: boolean?)
		result.Text = text
		result.TextColor3 = color
		resultPop.Scale = big and 1.3 or 1.1
		UILib.tween(resultPop, { Scale = 1 }, 0.35, Enum.EasingStyle.Back)
	end

	-- bet stepper
	local betRow = UILib.make("Frame", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(0, boardH + 54), Size = UDim2.new(1, 0, 0, 60),
		Parent = content,
	})
	UILib.list(betRow, "x", 12, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	local step = math.max(5, math.floor(minBet))
	local betValue
	local function setBet(v)
		bet = math.clamp(math.floor(v), minBet, maxBet)
		UILib.countTo(betValue, bet, money)
	end
	UILib.button({ parent = betRow, tone = "Red", text = "-", font = F.Heavy, textSize = 46, size = UDim2.fromOffset(70, 56),
		order = 1, onClick = function() if not dropping then setBet(bet - step) end end })
	local pill = UILib.make("Frame", { BackgroundColor3 = C.Cream, Size = UDim2.fromOffset(230, 54), LayoutOrder = 2, Parent = betRow })
	UILib.corner(pill, 16)
	UILib.stroke(pill, C.Ink, 3.5, true)
	UILib.list(pill, "x", 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	UILib.body(pill, { text = "BET", font = F.Display, size = 20, autoX = true, frameSize = UDim2.fromScale(0, 1), order = 1 })
	betValue = UILib.text(pill, { text = money(bet), font = F.Number, size = 28, color = C.Gold, autoX = true,
		frameSize = UDim2.fromScale(0, 1), order = 2, stroke = 3, shadow = 3 })
	UILib.button({ parent = betRow, tone = "Green", text = "+", font = F.Heavy, textSize = 34, size = UDim2.fromOffset(70, 56),
		order = 3, onClick = function() if not dropping then setBet(bet + step) end end })
	UILib.button({ parent = betRow, tone = "Gold", text = "MAX", textSize = 22, size = UDim2.fromOffset(104, 56),
		order = 4, onClick = function() if not dropping then setBet(maxBet) end end })
	setBet(bet)

	local dropBtn = UILib.button({
		parent = content, tone = "Green", text = "DROP!", textSize = 44,
		size = UDim2.new(1, -40, 0, 78), anchor = Vector2.new(0.5, 1), position = UDim2.new(0.5, 0, 1, -2),
	})

	------------------------------------------------------------------
	-- the drop
	------------------------------------------------------------------
	local function moveBall(x: number, y: number, t: number, style)
		UILib.tween(ball, { Position = UDim2.fromOffset(x, y) }, t, style or Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		task.wait(t)
	end

	local function animate(path, pocket: number)
		ball.Position = UDim2.fromOffset(cx, top - 4)
		local k = 0
		for r = 1, ROWS do
			-- onto the pin this row, then off to its left or right
			local x = cx + (k - (r - 1) / 2) * DX
			moveBall(x, top + r * DY - 11, r == 1 and 0.16 or 0.11)
			UILib.fx("sound", "tick", 1 + r * 0.06, 0.6)
			if not p.alive then return end
			if path[r] then k += 1 end
		end
		local bx = cx + (pocket - 5) * DX
		moveBall(bx, binY + 12, 0.2)
	end

	dropBtn.onClick(function()
		if dropping then return end
		local b = bet
		dropping = true
		dropBtn.setEnabled(false)
		dropBtn.setText("DROPPING...")
		showResult("GOOD LUCK!", C.Brown)

		local res = Remotes.PlayGame():InvokeServer(machine, b, nil)
		if not p.alive then return end
		if not res or not res.ok then
			showResult(string.upper((res and res.message) or "DROP FAILED"), C.Crimson)
			UILib.fx("shake", board, 0.6)
			dropping = false
			dropBtn.setEnabled(true)
			dropBtn.setText("DROP!")
			return
		end
		local d = res.detail or {}
		local path = type(d.path) == "table" and d.path or {}
		local pocket = tonumber(d.pocket) or 5
		animate(path, pocket)
		if not p.alive then return end

		-- the bin lights up
		local bin = bins[pocket]
		if bin then
			bin.stroke.Color = C.GoldTop
			bin.stroke.Thickness = 6
			bin.pop.Scale = 1.25
			UILib.tween(bin.pop, { Scale = 1 }, 0.35, Enum.EasingStyle.Back)
			task.delay(0.8, function()
				if bin.frame.Parent then
					UILib.tween(bin.stroke, { Color = C.Ink, Thickness = 3 }, 0.4)
				end
			end)
		end
		local mult = d.multiplier or MULTS[pocket] or 0
		if res.net > 0 then
			local big = mult >= 4
			showResult(("%sx  WIN +%s"):format(tostring(mult), money(res.net)), C.Green, big)
			boardStroke.Color = C.GoldTop
			UILib.tween(boardStroke, { Color = C.Ink }, 0.8)
			UILib.fx("celebrate", big and "big" or "small", bin and bin.frame or board)
			UILib.fx("coinBurst", bin and bin.frame or board, res.net)
			if mult >= 16 then UILib.fx("banner", "PLINKO JACKPOT!", ("16x  +%s"):format(money(res.net)), "gold", "jackpot") end
		elseif res.net == 0 then
			showResult("PUSH - BET RETURNED", C.Brown)
		else
			showResult(("%sx  %s"):format(tostring(mult), "-" .. money(-res.net)), C.Crimson)
		end
		task.wait(0.35)
		if not p.alive then return end
		dropping = false
		dropBtn.setEnabled(true)
		dropBtn.setText("DROP!")
	end)

	local _ = cashValue
end

return PlinkoUI
