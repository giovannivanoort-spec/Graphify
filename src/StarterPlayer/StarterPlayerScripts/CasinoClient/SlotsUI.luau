--!nonstrict
-- SlotsUI.luau — slot machine panel in the Showtime style: crimson reel window
-- with three cream reels, bet stepper, big SPIN button. The server decides the
-- outcome (PlayGame); this only animates the reels to that result.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local F = UILib.Fonts

local SlotsUI = {}

-- reel symbols: fruit/bell are images, BAR and 7 read better as big type
local SYMBOLS = {
	Cherry = { image = "rbxassetid://87158052124670" },
	Lemon  = { image = "rbxassetid://18666183636" },
	Bell   = { image = "rbxassetid://14895343020" },
	Bar    = { text = "BAR" },
	Seven  = { text = "7" },
}
local ALL = { "Cherry", "Lemon", "Bell", "Bar", "Seven" }

local function money(n: number): string
	return "$" .. UILib.commas(n)
end

local open = false

function SlotsUI.open(machine: Instance)
	if open then return end
	open = true

	local minBet = machine:GetAttribute("MinBet") or 5
	local maxBet = machine:GetAttribute("MaxBet") or 100
	local bet = minBet
	local spinning = false
	local cashValue = UILib.getCashValue()

	local p = UILib.panel({ name = "SlotsPanel", title = string.upper(machine.Name), icon = "slot", width = 680, height = 620 })
	local content = p.content
	p.onClose(function() open = false end)

	-- balance
	local balRow = UILib.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34), Parent = content })
	UILib.list(balRow, "x", 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	UILib.body(balRow, { text = "BALANCE", font = F.Display, size = 20, autoX = true, frameSize = UDim2.fromScale(0, 1), order = 1 })
	local balance = UILib.text(balRow, {
		text = money(cashValue.Value), font = F.Number, size = 28, color = C.Gold, autoX = true,
		frameSize = UDim2.fromScale(0, 1), order = 2, stroke = 3, shadow = 3,
	})
	UILib.countTo(balance, cashValue.Value, money)
	local cashConn = cashValue.Changed:Connect(function(v) UILib.countTo(balance, v, money) end)
	p.onClose(function() cashConn:Disconnect() end)

	-- reel window
	local windowHolder = UILib.make("Frame", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 42), Size = UDim2.new(1, 0, 0, 186), Parent = content,
	})
	local winBurst = UILib.image(windowHolder, UILib.Tex.sunburst, {
		size = UDim2.fromOffset(700, 700), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5),
		color = C.GoldTop, transparency = 1,
	})
	UILib.spin(winBurst, 30)
	local window = UILib.make("Frame", {
		Name = "ReelWindow", BackgroundColor3 = C.White, AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(528, 182), Parent = windowHolder,
	})
	UILib.corner(window, 26)
	UILib.gradient(window, C.Crimson, C.CrimsonDeep)
	local windowStroke = UILib.stroke(window, C.Ink, 5, true)
	UILib.list(window, "x", 12, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)

	local reels = {}
	for i = 1, 3 do
		local cell = UILib.make("Frame", {
			Name = "Reel" .. i, BackgroundColor3 = C.White, Size = UDim2.fromOffset(156, 150), LayoutOrder = i,
			ClipsDescendants = true, Parent = window,
		})
		UILib.corner(cell, 18)
		UILib.make("UIGradient", {
			Rotation = 90,
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromHex("#D9C9A8")), ColorSequenceKeypoint.new(0.25, Color3.fromHex("#FFFDF5")),
				ColorSequenceKeypoint.new(0.75, Color3.fromHex("#FFFDF5")), ColorSequenceKeypoint.new(1, Color3.fromHex("#D9C9A8")),
			}),
			Parent = cell,
		})
		UILib.stroke(cell, C.Ink, 4, true)
		local mover = UILib.make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = cell })
		local pop = UILib.make("UIScale", { Parent = mover })
		local img = UILib.image(mover, nil, {
			size = UDim2.fromOffset(104, 104), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5),
		})
		local txt, txtHolder = UILib.text(mover, { text = "", size = 72, color = C.Crimson, stroke = 5, shadow = 5 })
		reels[i] = { image = img, text = txt, textHolder = txtHolder, mover = mover, pop = pop }
	end
	local function setSymbol(reel, name)
		local spec = SYMBOLS[name]
		if spec and spec.image then
			reel.image.Image = spec.image
			reel.image.Visible = true
			reel.textHolder.Visible = false
		else
			reel.text.Text = (spec and spec.text) or "?"
			reel.text.TextSize = (spec and spec.text == "7") and 96 or 64
			reel.textHolder.Visible = true
			reel.image.Visible = false
		end
	end
	setSymbol(reels[1], "Seven"); setSymbol(reels[2], "Seven"); setSymbol(reels[3], "Seven")

	-- result banner
	local result = UILib.text(content, {
		text = "PLACE YOUR BET!", size = 34, color = C.White, frameSize = UDim2.new(1, 0, 0, 48),
		position = UDim2.fromOffset(0, 236), stroke = 4, shadow = 4,
	})
	local resultHolder = result.Parent
	local resultPop = UILib.make("UIScale", { Parent = resultHolder })

	-- bet stepper
	local betRow = UILib.make("Frame", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 292), Size = UDim2.new(1, 0, 0, 62), Parent = content,
	})
	UILib.list(betRow, "x", 12, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	local step = math.max(5, math.floor(minBet))
	local betValue
	local function setBet(v)
		bet = math.clamp(math.floor(v), minBet, maxBet)
		UILib.countTo(betValue, bet, money)
	end
	UILib.button({ parent = betRow, tone = "Red", text = "-", font = F.Heavy, textSize = 48, size = UDim2.fromOffset(72, 58),
		order = 1, onClick = function() if not spinning then setBet(bet - step) end end })
	local pill = UILib.make("Frame", {
		BackgroundColor3 = C.Cream, Size = UDim2.fromOffset(220, 56), LayoutOrder = 2, Parent = betRow,
	})
	UILib.corner(pill, 16)
	UILib.stroke(pill, C.Ink, 3.5, true)
	UILib.list(pill, "x", 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	UILib.body(pill, { text = "BET", font = F.Display, size = 20, autoX = true, frameSize = UDim2.fromScale(0, 1), order = 1 })
	betValue = UILib.text(pill, { text = money(bet), font = F.Number, size = 30, color = C.Gold, autoX = true,
		frameSize = UDim2.fromScale(0, 1), order = 2, stroke = 3, shadow = 3 })
	UILib.button({ parent = betRow, tone = "Green", text = "+", font = F.Heavy, textSize = 36, size = UDim2.fromOffset(72, 58),
		order = 3, onClick = function() if not spinning then setBet(bet + step) end end })
	UILib.button({ parent = betRow, tone = "Gold", text = "MAX", textSize = 24, size = UDim2.fromOffset(110, 58),
		order = 4, onClick = function() if not spinning then setBet(maxBet) end end })
	setBet(bet)

	UILib.body(content, {
		text = "3x 7 = x40   3x BAR = x18   3x Bell = x10   3x Lemon = x5   3x Cherry = x3   any pair = x0.85",
		size = 12, xAlign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 0, 20),
		position = UDim2.fromOffset(0, 362), transparency = 0.25,
	})

	local spinBtn = UILib.button({
		parent = content, tone = "Green", text = "SPIN!", textSize = 46,
		size = UDim2.new(1, -40, 0, 84), anchor = Vector2.new(0.5, 1), position = UDim2.new(0.5, 0, 1, -2),
	})

	------------------------------------------------------------------
	-- animation
	------------------------------------------------------------------
	local function cycleReel(reel, finalName, duration)
		local elapsed = 0
		while elapsed < duration and p.alive do
			setSymbol(reel, ALL[math.random(1, #ALL)])
			reel.mover.Position = UDim2.fromOffset(0, -18)
			UILib.tween(reel.mover, { Position = UDim2.fromOffset(0, 0) }, 0.05, Enum.EasingStyle.Linear)
			task.wait(0.05)
			elapsed += 0.05
		end
		setSymbol(reel, finalName)
		reel.mover.Position = UDim2.fromOffset(0, 0)
		reel.pop.Scale = 1.18
		UILib.tween(reel.pop, { Scale = 1 }, 0.3, Enum.EasingStyle.Back)
	end

	local function showResult(text, color, big)
		result.Text = text
		result.TextColor3 = color
		resultPop.Scale = big and 1.35 or 1.12
		UILib.tween(resultPop, { Scale = 1 }, 0.35, Enum.EasingStyle.Back)
	end

	spinBtn.onClick(function()
		if spinning then return end
		local b = bet
		spinning = true
		spinBtn.setEnabled(false)
		spinBtn.setText("SPINNING...")
		showResult("GOOD LUCK!", C.White)

		local res = Remotes.PlayGame():InvokeServer(machine, b, nil)
		if not p.alive then return end
		if not res or not res.ok then
			showResult(string.upper((res and res.message) or "SPIN FAILED"), C.CrimsonTop)
			spinning = false
			spinBtn.setEnabled(true)
			spinBtn.setText("SPIN!")
			return
		end

		local final = (res.detail and res.detail.reels) or { "Cherry", "Cherry", "Cherry" }
		task.spawn(cycleReel, reels[1], final[1], 0.9)
		task.spawn(cycleReel, reels[2], final[2], 1.35)
		task.spawn(cycleReel, reels[3], final[3], 1.8)
		task.wait(2.0)
		if not p.alive then return end

		if res.net > 0 then
			local big = res.net >= b * 5
			showResult((big and "BIG WIN! +" or "WIN +") .. money(res.net), C.GreenTop, big)
			windowStroke.Color = C.GoldTop
			UILib.tween(windowStroke, { Color = C.Ink }, 0.8)
			winBurst.ImageTransparency = 0.35
			UILib.tween(winBurst, { ImageTransparency = 1 }, big and 2.2 or 1.2)
			if big then UILib.toast("BIG WIN!", "unlock", "+" .. money(res.net)) end
		elseif res.net == 0 then
			showResult("PUSH - BET RETURNED", C.White)
		else
			showResult("NO WIN  -" .. money(-res.net), C.CrimsonTop)
		end
		if res.balance then UILib.countTo(balance, res.balance, money) end
		spinning = false
		spinBtn.setEnabled(true)
		spinBtn.setText("SPIN!")
	end)
end

return SlotsUI
