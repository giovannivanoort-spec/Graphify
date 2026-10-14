--!nonstrict
-- StatsUI.luau — earnings & casino performance, read from the synced state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors

local StatsUI = {}

-- Stats change server-side as NPCs gamble, but the server only pushes a fresh
-- snapshot on buy/place/etc. Pull a fresh one so the panel isn't showing stale
-- (often all-zero) numbers.
local function refresh()
	task.spawn(function()
		local snap = Remotes.GetData():InvokeServer()
		if snap then UILib.setState(snap) end
	end)
end

local function commas(n: number): string
	local s = tostring(math.floor(n or 0))
	local k
	repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
	return s
end

function StatsUI.open()
	local panel = UILib.centeredPanel("StatsPanel", 0.56, 0.6, 520, 460, "Casino Stats")

	local list = UILib.make("Frame", { Position = UDim2.fromOffset(16, 64),
		Size = UDim2.new(1, -32, 1, -80), BackgroundTransparency = 1, Parent = panel })
	UILib.make("UIListLayout", { Padding = UDim.new(0, 10),
		SortOrder = Enum.SortOrder.LayoutOrder, Parent = list })

	local function statRow(label, value, color, order)
		local r = UILib.make("Frame", { BackgroundColor3 = C.Panel, LayoutOrder = order,
			Size = UDim2.new(1, 0, 0, 52), Parent = list })
		UILib.corner(r, 10)
		UILib.make("TextLabel", { Size = UDim2.new(0.6, -16, 1, 0), Position = UDim2.fromOffset(14, 0),
			BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 15, TextColor3 = C.Sub,
			TextXAlignment = Enum.TextXAlignment.Left, Text = label, Parent = r })
		UILib.make("TextLabel", { Size = UDim2.new(0.4, -16, 1, 0), Position = UDim2.new(0.6, 0, 0, 0),
			BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 18, TextColor3 = color or C.White,
			TextXAlignment = Enum.TextXAlignment.Right, Text = value, Parent = r })
	end

	local function render(state)
		if not panel.Parent then return end
		for _, ch in list:GetChildren() do if not ch:IsA("UIListLayout") then ch:Destroy() end end
		local s = state.stats or {}
		statRow("Total earned (house profit)", "$" .. commas(s.TotalEarned), C.Green, 1)
		statRow("Total paid to winners", "$" .. commas(s.TotalPaidOut), C.Red, 2)
		statRow("Games hosted", commas(s.SpinsHosted), C.White, 3)
		statRow("Biggest single payout", "$" .. commas(s.BiggestWinPaid), C.Accent, 4)
		statRow("Machines placed", commas(#(state.placed or {})), C.Blue, 5)
		statRow("In inventory", commas(#(state.inventory or {})), C.Blue, 6)
	end

	local disconnect = UILib.subscribe(render)

	-- pull fresh stats now, then keep refreshing while the panel is open
	refresh()
	local open = true
	task.spawn(function()
		while open and panel.Parent do
			task.wait(2)
			if open and panel.Parent then refresh() end
		end
	end)

	panel.AncestryChanged:Connect(function(_, parent)
		if not parent then open = false; disconnect() end
	end)
end

return StatsUI
