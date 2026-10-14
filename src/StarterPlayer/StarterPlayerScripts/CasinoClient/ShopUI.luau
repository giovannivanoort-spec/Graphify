--!nonstrict
-- ShopUI.luau — the Services menu (concessions & staff), opened from the
-- Services desk in the Showroom or the HUD button. Machines are no longer sold
-- here — they're bought physically in the Showroom (walk up + press E).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local Config = require(Common:WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors

local player = Players.LocalPlayer

local ShopUI = {}
local catalog = nil

local function fetchCatalog()
	if not catalog then catalog = Remotes.GetCatalog():InvokeServer() end
	return catalog
end

local function row(parent, title, subtitle, btnText, btnColor, onClick)
	local r = UILib.make("Frame", { Size = UDim2.new(1, 0, 0, 60), BackgroundColor3 = C.Panel, Parent = parent })
	UILib.corner(r, 8)
	UILib.make("TextLabel", { Size = UDim2.new(1, -150, 0, 26), Position = UDim2.fromOffset(12, 8),
		BackgroundTransparency = 1, Text = title, Font = Enum.Font.GothamBold, TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.White, Parent = r })
	UILib.make("TextLabel", { Size = UDim2.new(1, -150, 0, 18), Position = UDim2.fromOffset(12, 34),
		BackgroundTransparency = 1, Text = subtitle, Font = Enum.Font.Gotham, TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.Sub, Parent = r })
	local b = UILib.button({ Size = UDim2.fromOffset(120, 40), Position = UDim2.new(1, -132, 0.5, -20),
		BackgroundColor3 = btnColor, Text = btnText, TextSize = 14, TextColor3 = C.Black, Parent = r })
	b.MouseButton1Click:Connect(onClick)
end

function ShopUI.open()
	local data = fetchCatalog()
	if not data then UILib.toast("Services unavailable.", C.Red); return end

	local panel = UILib.centeredPanel("ShopPanel", 0.6, 0.8, 520, 560, "Concessions & Staff")
	local list = UILib.make("ScrollingFrame", {
		Size = UDim2.new(1, -32, 1, -80), Position = UDim2.fromOffset(16, 64),
		BackgroundTransparency = 1, CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 6, Parent = panel })
	UILib.make("UIListLayout", { Padding = UDim.new(0, 8), Parent = list })

	local function header(text)
		UILib.make("TextLabel", { Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1, Text = text,
			Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = C.Accent,
			TextXAlignment = Enum.TextXAlignment.Left, Parent = list })
	end

	UILib.make("TextLabel", { Size = UDim2.new(1, 0, 0, 38), BackgroundTransparency = 1,
		Text = "Machines are on display in the Showroom — walk up to one and press E to buy.",
		Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = C.Sub, TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left, Parent = list })

	local tele = UILib.button({ Size = UDim2.new(1, 0, 0, 42), BackgroundColor3 = C.Accent,
		Text = "Take me to the Showroom", TextSize = 15, TextColor3 = C.Black, Parent = list })
	tele.MouseButton1Click:Connect(function()
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp then
			local ctr = Config.Showroom.Center
			hrp.CFrame = CFrame.new(ctr.X, ctr.Y + 4, ctr.Z + 12) * CFrame.Angles(0, math.rad(180), 0)
			panel:Destroy()
		end
	end)

	header("CONCESSIONS — patrons buy snacks/drinks, revenue is paid to you")
	for _, m in (data.concessions or {}) do
		row(list, m.name, ("%s • +$%d per patron visit"):format(m.type, m.revenuePerVisit),
			"$" .. m.cost, C.Accent, function()
				local res = Remotes.BuyToInventory():InvokeServer(m.id)
				UILib.toast(res and res.message or "Purchase failed.", res and res.ok and C.Green or C.Red)
			end)
	end

	header("STAFF — permanent house-edge boost")
	for _, s in data.staff do
		row(list, s.name, ("+%d%% edge on every play at your casino"):format(math.floor(s.bonus * 100)),
			"$" .. s.cost, C.Blue, function()
				local res = Remotes.HireStaff():InvokeServer(s.id)
				UILib.toast(res and res.message or "Hire failed.", res and res.ok and C.Green or C.Red)
			end)
	end
end

return ShopUI
