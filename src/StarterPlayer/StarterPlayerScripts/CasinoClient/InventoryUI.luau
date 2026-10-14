--!nonstrict
-- InventoryUI.luau — grid of owned (unplaced) machines. "Place" starts the
-- placement controller for that item.

local UILib = require(script.Parent:WaitForChild("UILib"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local C = UILib.Colors

local InventoryUI = {}

function InventoryUI.open()
	local panel = UILib.centeredPanel("InventoryPanel", 0.7, 0.78, 720, 560, "Inventory")

	local scroller = UILib.make("ScrollingFrame", {
		Position = UDim2.fromOffset(16, 64), Size = UDim2.new(1, -32, 1, -80),
		BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 6,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = panel })
	UILib.make("UIGridLayout", {
		CellSize = UDim2.fromOffset(150, 142), CellPadding = UDim2.fromOffset(12, 12),
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder, Parent = scroller })

	local empty = UILib.make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1, Visible = false,
		Font = Enum.Font.GothamMedium, TextSize = 16, TextColor3 = C.Sub,
		Text = "No machines yet — buy some at the Machine Shop.", Parent = panel,
		Position = UDim2.fromOffset(0, 120) })

	local function render(state)
		if not panel.Parent then return end
		for _, ch in scroller:GetChildren() do
			if ch:IsA("Frame") then ch:Destroy() end
		end
		local inv = state.inventory or {}
		empty.Visible = #inv == 0
		for i, item in inv do
			local cell = UILib.make("Frame", {
				BackgroundColor3 = C.Panel, LayoutOrder = i, Parent = scroller })
			UILib.corner(cell, 10); UILib.stroke(cell, C.Panel2, 1)

			UILib.make("Frame", {
				Size = UDim2.fromOffset(40, 40), Position = UDim2.fromOffset(10, 10),
				BackgroundColor3 = Color3.new(item.r, item.g, item.b), Parent = cell,
			}, { UILib.make("UICorner", { CornerRadius = UDim.new(0, 8) }) })

			UILib.make("TextLabel", {
				Size = UDim2.new(1, -60, 0, 40), Position = UDim2.fromOffset(56, 10),
				BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 14,
				TextColor3 = C.White, TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left, Text = item.name, Parent = cell })
			UILib.make("TextLabel", {
				Size = UDim2.new(1, -20, 0, 18), Position = UDim2.fromOffset(10, 56),
				BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 12,
				TextColor3 = C.Sub, TextXAlignment = Enum.TextXAlignment.Left,
				Text = item.type, Parent = cell })

			local place = UILib.button({
				Size = UDim2.new(1, -20, 0, 34), Position = UDim2.new(0, 10, 1, -44),
				BackgroundColor3 = C.Green, Text = "Place", TextSize = 15,
				TextColor3 = C.White, Parent = cell })
			place.MouseButton1Click:Connect(function()
				panel:Destroy()
				PlacementController.begin(item)
			end)
		end
	end

	local disconnect = UILib.subscribe(render)
	panel.AncestryChanged:Connect(function(_, parent)
		if not parent then disconnect() end
	end)
end

return InventoryUI
