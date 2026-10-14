--!nonstrict
-- WelcomeUI.luau — "welcome back" popup showing offline income, with a Claim button.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors

local WelcomeUI = {}

local function commas(n: number): string
	local s = tostring(math.floor(n or 0))
	local k
	repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
	return s
end

function WelcomeUI.show(info)
	local panel = UILib.centeredPanel("WelcomePanel", 0.45, 0.42, 420, 320, "Welcome Back!")

	UILib.make("TextLabel", { Size = UDim2.new(1, -32, 0, 30), Position = UDim2.fromOffset(16, 70),
		BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 15, TextColor3 = C.Sub,
		Text = ("Your %d machine(s) earned while you were away:"):format(info.machines or 0),
		TextWrapped = true, Parent = panel })

	UILib.make("TextLabel", { Size = UDim2.new(1, -32, 0, 64), Position = UDim2.fromOffset(16, 108),
		BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 40, TextColor3 = C.Accent,
		Text = "$" .. commas(info.amount or 0), Parent = panel })

	UILib.make("TextLabel", { Size = UDim2.new(1, -32, 0, 22), Position = UDim2.fromOffset(16, 176),
		BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = C.Sub,
		Text = ("(%.1f hours of offline income)"):format(info.hours or 0), Parent = panel })

	local claim = UILib.button({ Size = UDim2.new(1, -32, 0, 48), Position = UDim2.new(0, 16, 1, -64),
		BackgroundColor3 = C.Green, Text = "Claim", TextSize = 18, TextColor3 = C.White, Parent = panel })
	claim.MouseButton1Click:Connect(function()
		local res = Remotes.ClaimOffline():InvokeServer()
		if res and res.ok then UILib.toast("Claimed $" .. commas(res.amount) .. "!", C.Green) end
		panel:Destroy()
	end)
end

function WelcomeUI.start()
	local ev = Remotes.WelcomeBack()
	if not ev then
		warn("[WelcomeUI] WelcomeBack remote missing; skipping offline popup.")
		return
	end
	ev.OnClientEvent:Connect(function(info)
		if info and (info.amount or 0) > 0 then WelcomeUI.show(info) end
	end)
end

return WelcomeUI
