--!nonstrict
-- SlotsUI.luau — a dynamic slot machine interface with spinning reels.
-- The server decides the outcome; this only animates to that result.
-- Presentation rides on UILib's luxury-casino language (gold-framed panel,
-- backdrop blur, FredokaOne counters); the spin flow itself is unchanged.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))

local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors

local SlotsUI = {}

-- reel symbols: fruit/bell are Creator Store images, BAR and 7 read better as
-- big FredokaOne type (real slot cabinets mix pictures and type the same way)
local SYMBOLS = {
	Cherry = { image = UILib.Icons.Cherry },
	Lemon  = { image = UILib.Icons.Lemon },
	Bell   = { image = UILib.Icons.Bell },
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
	local name = machine.Name
	local bet = minBet
	local spinning = false
	local cashValue = UILib.getCashValue()

	-- cabinet — centeredPanel dedupes any prior "SlotsPanel" and wires its own
	-- ✕ button to dismiss (blur release included)
	local panel, _close, content = UILib.centeredPanel("SlotsPanel", 0.42, 0.72, 470, 570, name)

	-- balance (animated count-up, mirrors leaderstats)
	UILib.make("TextLabel", {
		Size = UDim2.fromOffset(92, 30), BackgroundTransparency = 1, Text = "BALANCE",
		Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = C.Sub,
		TextXAlignment = Enum.TextXAlignment.Left, Parent = content,
	})
	local balanceValue = UILib.make("TextLabel", {
		Size = UDim2.new(1, -96, 0, 30), Position = UDim2.fromOffset(96, 0),
		BackgroundTransparency = 1, Font = Enum.Font.FredokaOne, TextSize = 22,
		TextColor3 = C.GoldLight, TextXAlignment = Enum.TextXAlignment.Left, Parent = content,
	})
	UILib.make("UIStroke", { Color = C.Ink, Thickness = 2, LineJoinMode = Enum.LineJoinMode.Round, Parent = balanceValue })
	UILib.countTo(balanceValue, cashValue.Value, money)
	local cashConn = cashValue.Changed:Connect(function(v)
		UILib.countTo(balanceValue, v, money)
	end)

	-- reel window (card frame; its stroke doubles as the win-flash target)
	local reelCard = UILib.card(content, {
		name = "ReelWindow", size = UDim2.new(1, 0, 0, 150), accent = C.GoldDark,
	})
	reelCard.Position = UDim2.fromOffset(0, 38)
	UILib.make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 10),
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center, Parent = reelCard,
	})
	-- each cell carries an ImageLabel AND a TextLabel; setSymbol shows whichever
	-- representation the symbol uses and hides the other
	local reels = {}
	for i = 1, 3 do
		local cell = UILib.make("Frame", {
			Size = UDim2.fromOffset(110, 120), BackgroundColor3 = C.Dark, Parent = reelCard,
		})
		UILib.corner(cell, 10)
		UILib.gradient(cell, C.Panel, C.Dark)
		UILib.stroke(cell, C.Panel2, 2)
		local img = UILib.make("ImageLabel", {
			Size = UDim2.fromOffset(76, 76), Position = UDim2.new(0.5, -38, 0.5, -38),
			BackgroundTransparency = 1, Image = "", Parent = cell,
		})
		local txt = UILib.make("TextLabel", {
			Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false,
			Text = "", Font = Enum.Font.FredokaOne, TextSize = 44, TextColor3 = C.GoldLight,
			Parent = cell,
		})
		UILib.make("UIStroke", { Color = C.Ink, Thickness = 3, LineJoinMode = Enum.LineJoinMode.Round, Parent = txt })
		reels[i] = { image = img, text = txt }
	end

	local function setSymbol(reel, symName)
		local spec = SYMBOLS[symName]
		if spec and spec.image then
			reel.image.Image = spec.image
			reel.image.Visible = true
			reel.text.Visible = false
		else
			reel.text.Text = (spec and spec.text) or "?"
			reel.text.Visible = true
			reel.image.Visible = false
		end
	end
	setSymbol(reels[1], "Cherry"); setSymbol(reels[2], "Bell"); setSymbol(reels[3], "Seven")

	-- result banner
	local result = UILib.make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 36), Position = UDim2.fromOffset(0, 196),
		BackgroundTransparency = 1, Text = "Place your bet and spin!",
		Font = Enum.Font.GothamBold, TextSize = 20, TextColor3 = C.White, Parent = content,
	})

	-- bet controls (same stepper math/limits as before)
	local function setBet(v)
		bet = math.clamp(math.floor(v), minBet, maxBet)
	end
	local betRow = UILib.make("Frame", {
		Size = UDim2.new(1, 0, 0, 56), Position = UDim2.fromOffset(0, 240),
		BackgroundColor3 = C.Panel, Parent = content,
	})
	UILib.corner(betRow, 12)
	UILib.gradient(betRow)
	UILib.stroke(betRow, C.Panel2, 2)
	local minus = UILib.button({
		Size = UDim2.fromOffset(56, 40), Position = UDim2.fromOffset(8, 8),
		BackgroundColor3 = C.Panel2, Text = "−", TextSize = 28, TextColor3 = C.White, Parent = betRow,
	})
	local betLabel = UILib.make("TextLabel", {
		Size = UDim2.new(1, -272, 1, 0), Position = UDim2.fromOffset(72, 0),
		BackgroundTransparency = 1, Font = Enum.Font.FredokaOne, TextSize = 22,
		TextColor3 = C.Gold, Parent = betRow,
	})
	UILib.make("UIStroke", { Color = C.Ink, Thickness = 2, LineJoinMode = Enum.LineJoinMode.Round, Parent = betLabel })
	local plus = UILib.button({
		Size = UDim2.fromOffset(56, 40), Position = UDim2.new(1, -132, 0, 8),
		BackgroundColor3 = C.Panel2, Text = "+", TextSize = 28, TextColor3 = C.White, Parent = betRow,
	})
	local maxBtn = UILib.button({
		Size = UDim2.fromOffset(60, 40), Position = UDim2.new(1, -68, 0, 8),
		BackgroundColor3 = C.Gold, Text = "MAX", TextSize = 14, TextColor3 = C.Ink, Parent = betRow,
	})
	local step = math.max(5, math.floor(minBet))
	local function refreshBet()
		UILib.countTo(betLabel, bet, function(n) return "Bet: " .. money(n) end)
	end
	refreshBet()
	minus.MouseButton1Click:Connect(function() setBet(bet - step); refreshBet() end)
	plus.MouseButton1Click:Connect(function() setBet(bet + step); refreshBet() end)
	maxBtn.MouseButton1Click:Connect(function() setBet(maxBet); refreshBet() end)

	-- paytable
	UILib.make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 50), Position = UDim2.fromOffset(0, 304),
		BackgroundTransparency = 1, TextWrapped = true,
		Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = C.Sub,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		Text = "Triple: 7 x40  •  BAR x18  •  Bell x10  •  Lemon x5  •  Cherry x3      Any two match: x0.85",
		Parent = content,
	})

	-- spin button (its Text/colour get flipped while a spin is in flight)
	local spinBtn = UILib.button({
		Size = UDim2.new(1, 0, 0, 60), Position = UDim2.new(0, 0, 1, -60),
		BackgroundColor3 = C.Green, Text = "SPIN", TextSize = 26, TextColor3 = C.White,
		Font = Enum.Font.FredokaOne, _radius = 12, Parent = content,
	})

	------------------------------------------------------------------
	-- animation
	------------------------------------------------------------------
	local function cycleReel(reel, finalName, duration)
		local elapsed = 0
		while elapsed < duration do
			setSymbol(reel, ALL[math.random(1, #ALL)])
			task.wait(0.05)
			elapsed += 0.05
		end
		setSymbol(reel, finalName)
	end

	local function doSpin()
		if spinning then return end
		local b = bet
		spinning = true
		spinBtn.Text = "SPINNING…"
		spinBtn.BackgroundColor3 = C.Panel2
		result.Text = ""
		result.TextColor3 = C.White

		local res = Remotes.PlayGame():InvokeServer(machine, b, nil)

		if not res or not res.ok then
			result.Text = (res and res.message) or "Spin failed."
			result.TextColor3 = C.Red
			spinning = false
			spinBtn.Text = "SPIN"
			spinBtn.BackgroundColor3 = C.Green
			return
		end

		local final = (res.detail and res.detail.reels) or { "Cherry", "Cherry", "Cherry" }
		task.spawn(function() cycleReel(reels[1], final[1], 0.9) end)
		task.spawn(function() cycleReel(reels[2], final[2], 1.4) end)
		task.spawn(function() cycleReel(reels[3], final[3], 1.9) end)
		task.wait(2.0)

		if res.net > 0 then
			result.Text = "WIN +" .. money(res.net)
			result.TextColor3 = C.Green
			-- gold flash on the reel-card frame
			local stroke = reelCard:FindFirstChildWhichIsA("UIStroke")
			if stroke then
				stroke.Color = C.GoldLight
				UILib.tween(stroke, { Color = C.GoldDark }, 0.6)
			end
			-- big wins (5x the stake or better) earn a toast too
			if res.net >= b * 5 then
				UILib.toast("BIG WIN +" .. money(res.net), C.Gold)
			end
		elseif res.net == 0 then
			result.Text = "Push — bet returned"
			result.TextColor3 = C.White
		else
			result.Text = "No win — −" .. money(-res.net)
			result.TextColor3 = C.Red
		end

		if res.balance then UILib.countTo(balanceValue, res.balance, money) end
		spinning = false
		spinBtn.Text = "SPIN"
		spinBtn.BackgroundColor3 = C.Green
	end

	spinBtn.MouseButton1Click:Connect(doSpin)

	-- teardown: the panel's ✕ already runs dismiss(); Destroying fires exactly
	-- once for every close path (dismiss, re-open dedupe, external Destroy)
	panel.Destroying:Connect(function()
		open = false
		cashConn:Disconnect()
	end)
end

return SlotsUI
