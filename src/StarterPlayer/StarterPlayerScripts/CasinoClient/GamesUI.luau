--!nonstrict
-- GamesUI.luau — luxury bet panel for the non-slots games (roulette, dice, ...).
-- Presentation comes from UILib (gold-framed centeredPanel, juiced buttons,
-- toasts); the play flow is unchanged: one PlayGame invoke, server decides.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))

local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors

local GamesUI = {}
local open = false

function GamesUI.open(machine: Instance)
	if open then return end
	open = true
	local gameType = machine:GetAttribute("GameType")
	local minBet = machine:GetAttribute("MinBet") or 1
	local maxBet = machine:GetAttribute("MaxBet") or 100

	-- centeredPanel dedupes any prior "GamePanel", pops in, blurs the world,
	-- and its close button / dismiss handle full teardown (blur release included).
	local panel, _close, content = UILib.centeredPanel("GamePanel", 0.38, 0.6, 400, 440, gameType)
	panel.Destroying:Connect(function() open = false end)

	UILib.make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1,
		Text = ("Bet ($%d – $%d):"):format(minBet, maxBet),
		Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = C.Sub,
		TextXAlignment = Enum.TextXAlignment.Left, Parent = content,
	})
	local betBox = UILib.make("TextBox", {
		Size = UDim2.new(1, 0, 0, 42), Position = UDim2.fromOffset(0, 22),
		BackgroundColor3 = C.Panel, Text = tostring(minBet), ClearTextOnFocus = false,
		Font = Enum.Font.FredokaOne, TextSize = 20, TextColor3 = C.GoldLight, Parent = content,
	})
	UILib.corner(betBox, 10)
	UILib.gradient(betBox)
	UILib.stroke(betBox, C.GoldDark, 2.5)

	local choice = nil
	if gameType == "Roulette" then
		choice = { kind = "color", value = "red" }
		UILib.make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 16), Position = UDim2.fromOffset(0, 76),
			BackgroundTransparency = 1, Text = "Pick your bet:",
			Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = C.Sub,
			TextXAlignment = Enum.TextXAlignment.Left, Parent = content,
		})
		-- Red/Black colors ARE the game choice — never re-hue these two.
		local opts = {
			{ "Red", C.Red, { kind = "color", value = "red" } },
			{ "Black", C.Black, { kind = "color", value = "black" } },
			{ "Even", C.Panel2, { kind = "parity", value = "even" } },
			{ "Odd", C.Panel2, { kind = "parity", value = "odd" } },
		}
		local rings = {}
		for i, o in opts do
			local b = UILib.button({
				Size = UDim2.new(0.25, -6, 0, 42),
				Position = UDim2.new((i - 1) * 0.25, (i - 1) * 2, 0, 98),
				BackgroundColor3 = o[2], Text = o[1], TextSize = 14, TextColor3 = C.White, Parent = content,
			})
			-- gold ring marks the current selection (red is pre-selected)
			local ring = UILib.make("Frame", {
				Name = "SelRing", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = b })
			UILib.corner(ring, 10)
			rings[i] = UILib.make("UIStroke", {
				Color = C.GoldLight, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				LineJoinMode = Enum.LineJoinMode.Round, Enabled = (i == 1), Parent = ring })
			b.MouseButton1Click:Connect(function()
				choice = o[3]
				for j, r in rings do r.Enabled = (j == i) end
				UILib.toast("Betting on " .. o[1], C.Panel)
			end)
		end
	elseif gameType == "Dice" then
		choice = { target = 50 }
		UILib.make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 16), Position = UDim2.fromOffset(0, 76),
			BackgroundTransparency = 1, Text = "Win if roll is OVER target (2–90):",
			Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = C.Sub,
			TextXAlignment = Enum.TextXAlignment.Left, Parent = content,
		})
		local tBox = UILib.make("TextBox", {
			Size = UDim2.new(1, 0, 0, 40), Position = UDim2.fromOffset(0, 98),
			BackgroundColor3 = C.Panel, Text = "50", Font = Enum.Font.FredokaOne,
			TextSize = 18, TextColor3 = C.GoldLight, Parent = content,
		})
		UILib.corner(tBox, 10)
		UILib.gradient(tBox)
		UILib.stroke(tBox, C.GoldDark, 2.5)
		tBox:GetPropertyChangedSignal("Text"):Connect(function()
			choice = { target = tonumber(tBox.Text) or 50 }
		end)
	end

	-- result card sits above the play button; its stroke flashes with outcomes
	local resultCard = UILib.card(content, {
		name = "ResultCard", size = UDim2.new(1, 0, 0, 56), accent = C.GoldDark })
	resultCard.Position = UDim2.new(0, 0, 1, -126)
	local resultStroke = resultCard:FindFirstChildOfClass("UIStroke")
	local resultScale = UILib.make("UIScale", { Scale = 1, Parent = resultCard })
	local result = UILib.make("TextLabel", {
		Size = UDim2.new(1, -16, 1, 0), Position = UDim2.fromOffset(8, 0),
		BackgroundTransparency = 1, Text = "", TextWrapped = true,
		Font = Enum.Font.GothamBold, TextSize = 15, TextColor3 = C.White, Parent = resultCard,
	})
	UILib.make("UIStroke", { Color = C.Ink, Thickness = 2, Parent = result })

	-- shared pop + stroke flash so wins/losses feel different but never desync
	local function flashResult(textColor, flashColor)
		result.TextColor3 = textColor
		resultStroke.Color = flashColor
		resultStroke.Thickness = 5
		UILib.tween(resultStroke, { Color = C.GoldDark, Thickness = 2 }, 0.6)
		resultScale.Scale = 0.88
		UILib.tween(resultScale, { Scale = 1 }, 0.3, Enum.EasingStyle.Back)
	end

	local playBtn = UILib.button({
		Size = UDim2.new(1, 0, 0, 54), Position = UDim2.new(0, 0, 1, -54),
		BackgroundColor3 = C.Green, Text = "PLAY", TextSize = 22, TextColor3 = C.White,
		Font = Enum.Font.FredokaOne, _radius = 12, Parent = content,
	})
	playBtn.MouseButton1Click:Connect(function()
		local bet = tonumber(betBox.Text) or 0
		local res = Remotes.PlayGame():InvokeServer(machine, bet, choice)
		if not res then return end
		if not res.ok then
			result.Text = res.message
			flashResult(C.Red, C.Red)
			return
		end
		local extra = ""
		local d = res.detail
		if d then
			if d.number ~= nil then extra = (" [%d %s]"):format(d.number, d.color)
			elseif d.roll then extra = (" [rolled %d vs %d]"):format(d.roll, d.target)
			elseif d.multiplier ~= nil then extra = (" [x%s]"):format(tostring(d.multiplier))
			elseif d.player then extra = (" [you %d / dealer %d]"):format(d.player, d.dealer) end
		end
		result.Text = res.message .. extra
		if res.net > 0 then
			flashResult(C.Green, C.GoldLight)
			if res.net >= bet * 5 then
				UILib.toast(("BIG WIN! +$%s"):format(UILib.commas(res.net)), C.Gold)
			end
		elseif res.net < 0 then
			flashResult(C.Red, C.Red)
		else
			result.TextColor3 = C.White
		end
	end)
end

return GamesUI
