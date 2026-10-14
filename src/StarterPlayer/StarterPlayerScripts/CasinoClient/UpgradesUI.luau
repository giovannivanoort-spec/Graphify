--!nonstrict
-- UpgradesUI.luau — list of one-time owner upgrades with Buy buttons.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors

local UpgradesUI = {}

local catalog
local function getCatalog()
	if not catalog then catalog = Remotes.GetCatalog():InvokeServer() end
	return catalog
end

local function row(parent, order)
	local r = UILib.make("Frame", { BackgroundColor3 = C.Panel, LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 70), Parent = parent })
	UILib.corner(r, 8)
	return r
end

function UpgradesUI.open()
	local panel = UILib.centeredPanel("UpgradesPanel", 0.55, 0.75, 560, 540, "Upgrades")

	local scroller = UILib.make("ScrollingFrame", {
		Position = UDim2.fromOffset(16, 64), Size = UDim2.new(1, -32, 1, -80),
		BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 6,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = panel })
	UILib.make("UIListLayout", { Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder, Parent = scroller })

	local function render(state)
		if not panel.Parent then return end
		for _, ch in scroller:GetChildren() do
			if not ch:IsA("UIListLayout") then ch:Destroy() end
		end
		local owned = {}
		for _, id in (state.upgrades or {}) do owned[id] = true end
		local cat = getCatalog()
		for i, u in (cat and cat.upgrades or {}) do
			local r = row(scroller, i)
			UILib.make("TextLabel", { Size = UDim2.new(1, -130, 0, 22), Position = UDim2.fromOffset(12, 8),
				BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = C.White,
				TextXAlignment = Enum.TextXAlignment.Left, Text = u.name, Parent = r })
			UILib.make("TextLabel", { Size = UDim2.new(1, -130, 0, 18), Position = UDim2.fromOffset(12, 30),
				BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = C.Sub,
				TextXAlignment = Enum.TextXAlignment.Left, Text = u.desc, Parent = r })
			UILib.make("TextLabel", { Size = UDim2.new(1, -130, 0, 16), Position = UDim2.fromOffset(12, 48),
				BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = C.Accent,
				TextXAlignment = Enum.TextXAlignment.Left, Text = ("$%d"):format(u.cost), Parent = r })
			local btn = UILib.button({ Size = UDim2.fromOffset(104, 40), Position = UDim2.new(1, -116, 0.5, -20),
				BackgroundColor3 = owned[u.id] and C.Panel2 or C.Green,
				Text = owned[u.id] and "Owned ✓" or "Buy", TextSize = 14, TextColor3 = C.White, Parent = r })
			if not owned[u.id] then
				btn.MouseButton1Click:Connect(function()
					local res = Remotes.BuyUpgrade():InvokeServer(u.id)
					UILib.toast(res and res.message or "Done.", res and res.ok and C.Green or C.Red)
				end)
			end
		end
	end

	local disconnect = UILib.subscribe(render)
	panel.AncestryChanged:Connect(function(_, parent) if not parent then disconnect() end end)
end

return UpgradesUI
