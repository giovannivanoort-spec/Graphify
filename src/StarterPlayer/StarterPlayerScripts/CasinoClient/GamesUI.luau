--!nonstrict
-- GamesUI.luau — table games (roulette, dice, blackjack, wheel) in the Showtime
-- style. One PlayGame invoke per round; the server decides the outcome.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local F = UILib.Fonts
local A = UILib.Assets

local GamesUI = {}
local open = false

local function inputBox(parent, text, position, size)
	local frame = UILib.make("Frame", {
		BackgroundColor3 = C.Cream, Position = position, Size = size, Parent = parent,
	})
	UILib.corner(frame, 16)
	UILib.stroke(frame, C.Ink, 3.5, true)
	local box = UILib.make("TextBox", {
		BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Text = text, ClearTextOnFocus = false,
		Font = F.Number, TextSize = 28, TextColor3 = C.GoldDeep, PlaceholderColor3 = C.CreamLine, Parent = frame,
	})
	UILib.stroke(box, C.Ink, 2)
	return box
end

function GamesUI.open(machine: Instance)
	if open then return end
	open = true
	local gameType = machine:GetAttribute("GameType") or "Game"
	local minBet = machine:GetAttribute("MinBet") or 1
	local maxBet = machine:GetAttribute("MaxBet") or 100

	local p = UILib.panel({
		name = "GamePanel", title = string.upper(gameType), icon = A.TypeIcon[gameType] or "star", width = 640, height = 560,
	})
	p.onClose(function() open = false end)
	local content = p.content

	UILib.body(content, {
		text = ("YOUR BET  ($%d - $%d)"):format(minBet, maxBet), font = F.Display, size = 20,
		frameSize = UDim2.new(1, 0, 0, 26),
	})
	local betBox = inputBox(content, tostring(minBet), UDim2.fromOffset(0, 30), UDim2.new(1, 0, 0, 58))

	local choice = nil
	if gameType == "Roulette" then
		choice = { kind = "color", value = "red" }
		UILib.body(content, { text = "PICK YOUR BET", font = F.Display, size = 20, frameSize = UDim2.new(1, 0, 0, 26),
			position = UDim2.fromOffset(0, 102) })
		local row = UILib.make("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 132),
			Size = UDim2.new(1, 0, 0, 64), Parent = content })
		UILib.list(row, "x", 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
		-- Red/Black ARE the game choice; their tones are part of the rules
		local opts = {
			{ "RED", "Red", { kind = "color", value = "red" } },
			{ "BLACK", "Black", { kind = "color", value = "black" } },
			{ "EVEN", "Blue", { kind = "parity", value = "even" } },
			{ "ODD", "Orange", { kind = "parity", value = "odd" } },
		}
		local rings = {}
		for i, o in opts do
			local b = UILib.button({ parent = row, tone = o[2], text = o[1], textSize = 22, size = UDim2.fromOffset(128, 60), order = i })
			local ring = UILib.make("Frame", {
				BackgroundTransparency = 1, Size = UDim2.new(1, 10, 1, 10), Position = UDim2.fromOffset(-5, -5), Parent = b.Instance,
			})
			UILib.corner(ring, 20)
			rings[i] = UILib.stroke(ring, C.Gold, 4, true)
			rings[i].Enabled = i == 1
			b.onClick(function()
				choice = o[3]
				for j, r in rings do r.Enabled = (j == i) end
			end)
		end
	elseif gameType == "Dice" then
		choice = { target = 50 }
		UILib.body(content, { text = "WIN IF THE ROLL IS OVER (2-90)", font = F.Display, size = 20,
			frameSize = UDim2.new(1, 0, 0, 26), position = UDim2.fromOffset(0, 102) })
		local tBox = inputBox(content, "50", UDim2.fromOffset(0, 132), UDim2.new(1, 0, 0, 58))
		tBox:GetPropertyChangedSignal("Text"):Connect(function()
			choice = { target = tonumber(tBox.Text) or 50 }
		end)
	end

	-- result card
	local resultCard = UILib.make("Frame", {
		BackgroundColor3 = C.Cream, Position = UDim2.fromOffset(0, 214), Size = UDim2.new(1, 0, 0, 74), Parent = content,
	})
	UILib.corner(resultCard, 18)
	local resultStroke = UILib.stroke(resultCard, C.Ink, 3.5, true)
	local resultPop = UILib.make("UIScale", { Parent = resultCard })
	local result = UILib.body(resultCard, {
		text = "GOOD LUCK!", font = F.Display, size = 24, xAlign = Enum.TextXAlignment.Center, wrap = true,
		frameSize = UDim2.new(1, -20, 1, 0), position = UDim2.fromOffset(10, 0),
	})
	local function flash(textColor, strokeColor)
		result.TextColor3 = textColor
		resultStroke.Color = strokeColor
		resultStroke.Thickness = 6
		UILib.tween(resultStroke, { Color = C.Ink, Thickness = 3.5 }, 0.6)
		resultPop.Scale = 0.88
		UILib.tween(resultPop, { Scale = 1 }, 0.3, Enum.EasingStyle.Back)
	end

	UILib.button({
		parent = content, tone = "Green", text = "PLAY!", textSize = 44,
		size = UDim2.new(1, -40, 0, 82), anchor = Vector2.new(0.5, 1), position = UDim2.new(0.5, 0, 1, -2),
		onClick = function()
			local bet = tonumber(betBox.Text) or 0
			local res = Remotes.PlayGame():InvokeServer(machine, bet, choice)
			if not res or not p.alive then return end
			if not res.ok then
				result.Text = string.upper(res.message or "Can't play")
				flash(C.Crimson, C.Crimson)
				return
			end
			local extra = ""
			local d = res.detail
			if d then
				if d.number ~= nil then extra = (" [%d %s]"):format(d.number, tostring(d.color))
				elseif d.roll then extra = (" [rolled %d vs %d]"):format(d.roll, d.target)
				elseif d.multiplier ~= nil then extra = (" [x%s]"):format(tostring(d.multiplier))
				elseif d.player then extra = (" [you %d / dealer %d]"):format(d.player, d.dealer) end
			end
			result.Text = string.upper(res.message) .. extra
			if res.net > 0 then
				flash(C.Green, C.Gold)
				if res.net >= bet * 5 then UILib.toast("BIG WIN!", "unlock", "+$" .. UILib.commas(res.net)) end
			elseif res.net < 0 then
				flash(C.Crimson, C.Crimson)
			else
				result.TextColor3 = C.Brown
			end
		end,
	})
end

return GamesUI
