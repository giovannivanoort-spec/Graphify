--!nonstrict
-- ManageUI.luau — manage your casino: see placed machines (sell), hire staff,
-- and a quick Pickup/Sell popup when you interact with your own machine.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local C = UILib.Colors

local ManageUI = {}

local catalog
local function getCatalog()
	if not catalog then catalog = Remotes.GetCatalog():InvokeServer() end
	return catalog
end

local function findMachine(placedId: string)
	for _, m in Workspace:GetChildren() do
		if m:IsA("Model") and m:GetAttribute("PlacedId") == placedId then return m end
	end
	return nil
end

local function row(parent, order)
	local r = UILib.make("Frame", { BackgroundColor3 = C.Panel, LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 48), Parent = parent })
	UILib.corner(r, 8)
	return r
end

function ManageUI.openOverview()
	local panel = UILib.centeredPanel("ManagePanel", 0.66, 0.82, 660, 600, "Manage Casino")

	local scroller = UILib.make("ScrollingFrame", {
		Position = UDim2.fromOffset(16, 64), Size = UDim2.new(1, -32, 1, -80),
		BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 6,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = panel })
	UILib.make("UIListLayout", { Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder, Parent = scroller })

	local function header(text, order)
		UILib.make("TextLabel", { Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold, TextSize = 15, TextColor3 = C.Accent, LayoutOrder = order,
			TextXAlignment = Enum.TextXAlignment.Left, Text = text, Parent = scroller })
	end

	local function render(state)
		if not panel.Parent then return end
		for _, ch in scroller:GetChildren() do
			if not ch:IsA("UIListLayout") then ch:Destroy() end
		end

		local placed = state.placed or {}
		header(("Placed Machines (%d)"):format(#placed), 1)
		if #placed == 0 then
			UILib.make("TextLabel", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1,
				Font = Enum.Font.Gotham, TextSize = 14, TextColor3 = C.Sub, LayoutOrder = 2,
				Text = "Nothing placed yet. Open your Inventory to place machines.", Parent = scroller })
		end
		for i, m in placed do
			local r = row(scroller, 2 + i)
			UILib.make("TextLabel", { Size = UDim2.new(1, -300, 1, 0), Position = UDim2.fromOffset(12, 0),
				BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 15, TextColor3 = C.White,
				TextXAlignment = Enum.TextXAlignment.Left, Text = ("%s  \u{2022}  %s"):format(m.name, m.type), Parent = r })

			local move = UILib.button({ Size = UDim2.fromOffset(72, 34), Position = UDim2.new(1, -280, 0.5, -17),
				BackgroundColor3 = C.Accent, Text = "Move", TextSize = 14, TextColor3 = C.White, Parent = r })
			move.MouseButton1Click:Connect(function()
				local inst = findMachine(m.placedId)
				if inst then
					panel:Destroy()
					PlacementController.beginMove(inst)
				end
			end)

			local pickup = UILib.button({ Size = UDim2.fromOffset(86, 34), Position = UDim2.new(1, -190, 0.5, -17),
				BackgroundColor3 = C.Blue, Text = "Pick up", TextSize = 14, TextColor3 = C.White, Parent = r })
			pickup.MouseButton1Click:Connect(function()
				local inst = findMachine(m.placedId)
				if inst then
					local res = Remotes.PickupMachine():InvokeServer(inst)
					UILib.toast(res and res.message or "Done.", res and res.ok and C.Green or C.Red)
				end
			end)
			local sell = UILib.button({ Size = UDim2.fromOffset(86, 34), Position = UDim2.new(1, -96, 0.5, -17),
				BackgroundColor3 = C.Red, Text = "Sell", TextSize = 14, TextColor3 = C.White, Parent = r })
			sell.MouseButton1Click:Connect(function()
				local inst = findMachine(m.placedId)
				if inst then
					local res = Remotes.SellMachine():InvokeServer(inst)
					UILib.toast(res and res.message or "Done.", res and res.ok and C.Green or C.Red)
				end
			end)
		end

		-- staff
		local hired = {}
		for _, id in (state.staff or {}) do hired[id] = true end
		header("Staff (permanent house-edge boosts)", 100)
		local cat = getCatalog()
		for i, s in (cat and cat.staff or {}) do
			local r = row(scroller, 100 + i)
			UILib.make("TextLabel", { Size = UDim2.new(1, -130, 1, 0), Position = UDim2.fromOffset(12, 0),
				BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 15, TextColor3 = C.White,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = ("%s  •  +%d%% edge  •  $%d"):format(s.name, math.floor(s.bonus * 100), s.cost), Parent = r })
			local btn = UILib.button({ Size = UDim2.fromOffset(104, 34), Position = UDim2.new(1, -114, 0.5, -17),
				BackgroundColor3 = hired[s.id] and C.Panel2 or C.Green, Text = hired[s.id] and "Hired ✓" or "Hire",
				TextSize = 14, TextColor3 = C.White, Parent = r })
			if not hired[s.id] then
				btn.MouseButton1Click:Connect(function()
					local res = Remotes.HireStaff():InvokeServer(s.id)
					UILib.toast(res and res.message or "Done.", res and res.ok and C.Green or C.Red)
				end)
			end
		end
	end

	local disconnect = UILib.subscribe(render)
	panel.AncestryChanged:Connect(function(_, parent) if not parent then disconnect() end end)
end

-- Quick popup when the owner interacts with their own machine.
function ManageUI.openForMachine(machine: Instance)
	local isConc = machine:GetAttribute("Kind") == "concession"
	local panel = UILib.centeredPanel("MachinePanel", 0.5, 0.6, 460, 480,
		machine.Name or "Your Machine")

	local y = 64
	local function addBtn(text, color, h, cb)
		local b = UILib.button({ Size = UDim2.new(1, -32, 0, h), Position = UDim2.fromOffset(16, y),
			BackgroundColor3 = color, Text = text, TextSize = 14, TextColor3 = C.White, Parent = panel })
		b.MouseButton1Click:Connect(cb)
		y += h + 8
		return b
	end

	if not isConc then
		UILib.make("TextLabel", { Size = UDim2.new(1, -32, 0, 22), Position = UDim2.fromOffset(16, y),
			BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = C.Accent,
			TextXAlignment = Enum.TextXAlignment.Left, Text = "Upgrades", Parent = panel })
		y += 26
		local cat = getCatalog()
		local specs = cat and cat.machineUpgrades or {}
		for _, spec in specs do
			local lvl = machine:GetAttribute(spec.key:sub(1,1):upper() .. spec.key:sub(2) .. "Level") or 0
			local nextCost = spec.costs[lvl + 1]
			local label
			if lvl >= spec.maxLevel then
				label = ("%s  L%d/%d  •  MAX"):format(spec.name, lvl, spec.maxLevel)
			else
				label = ("%s  L%d/%d  •  $%d"):format(spec.name, lvl, spec.maxLevel, nextCost or 0)
			end
			addBtn(label, lvl >= spec.maxLevel and C.Panel2 or C.Green, 36, function()
				if lvl >= spec.maxLevel then return end
				local res = Remotes.UpgradeMachine():InvokeServer(machine, spec.key)
				UILib.toast(res and res.message or "Done.", res and res.ok and C.Green or C.Red)
				if res and res.ok then panel:Destroy(); ManageUI.openForMachine(machine) end
			end)
		end
		y += 4
	end

	addBtn("Move", C.Accent, 40, function()
		panel:Destroy(); PlacementController.beginMove(machine)
	end)
	addBtn("Pick up (return to inventory)", C.Blue, 40, function()
		local res = Remotes.PickupMachine():InvokeServer(machine)
		UILib.toast(res and res.message or "Done.", res and res.ok and C.Green or C.Red)
		if res and res.ok then panel:Destroy() end
	end)
	addBtn("Sell", C.Red, 40, function()
		local res = Remotes.SellMachine():InvokeServer(machine)
		UILib.toast(res and res.message or "Done.", res and res.ok and C.Green or C.Red)
		if res and res.ok then panel:Destroy() end
	end)
end

return ManageUI
