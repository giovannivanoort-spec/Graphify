--!nonstrict
-- HudUI.luau — always-on cash pill (gold) + a vertical action rail on the left
-- edge. The cash pill's "+" and the rail's Shop button both open the Robux
-- shop. Shows a crown VIP pill for VIP-pass owners. Icons are Creator Store
-- images (UILib.Icons) — no emoji.

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors

local HudUI = {}
local player = Players.LocalPlayer

function HudUI.build(openers)
	local screen = UILib.getScreen()
	if screen:FindFirstChild("HUD") then screen.HUD:Destroy() end
	if screen:FindFirstChild("ActionDock") then screen.ActionDock:Destroy() end
	openers = openers or {}
	local topInset = GuiService:GetGuiInset().Y

	local hud = UILib.make("Frame", {
		Name = "HUD", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 64),
		Position = UDim2.fromOffset(0, 8 + topInset), Parent = screen })

	-- cash pill (top-left). The "+" opens the Robux shop. The number eases to
	-- its new value and the pill pops when cash goes UP.
	local cashValue = UILib.getCashValue()
	local pill, cashLabel = UILib.currencyPill(hud, {
		name = "CashPill", color = C.Cash, icon = "$", size = UDim2.fromOffset(214, 46),
		text = UILib.abbreviate(cashValue.Value), onPlus = openers.onRobuxShop })
	pill.Position = UDim2.fromOffset(12, 6)
	local pillScale = UILib.make("UIScale", { Scale = 1, Parent = pill })
	local lastCash = cashValue.Value
	local function render()
		local v = cashValue.Value
		UILib.countTo(cashLabel, v)
		if v > lastCash then
			UILib.tween(pillScale, { Scale = 1.09 }, 0.1)
			task.delay(0.11, function()
				UILib.tween(pillScale, { Scale = 1 }, 0.2, Enum.EasingStyle.Back)
			end)
		end
		lastCash = v
	end
	render()
	cashValue.Changed:Connect(render)

	-- VIP pill (crown image + label, shown when the player owns the VIP pass)
	local vip = UILib.make("Frame", {
		Name = "VipPill", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromOffset(236, 29),
		Size = UDim2.fromOffset(64, 26), BackgroundColor3 = C.Gold, Parent = hud })
	UILib.corner(vip, 13)
	UILib.stroke(vip, UILib.darken(C.Gold, 0.4), 1.5)
	UILib.make("ImageLabel", {
		Size = UDim2.fromOffset(18, 18), Position = UDim2.fromOffset(6, 4),
		BackgroundTransparency = 1, Image = UILib.Icons.Crown, Parent = vip })
	local vipLbl = UILib.make("TextLabel", {
		Size = UDim2.new(1, -28, 1, 0), Position = UDim2.fromOffset(26, 0),
		BackgroundTransparency = 1, Text = "VIP", Font = Enum.Font.FredokaOne,
		TextSize = 13, TextColor3 = C.Ink, TextXAlignment = Enum.TextXAlignment.Left, Parent = vip })
	UILib.make("UIStroke", { Color = C.GoldLight, Thickness = 1, Transparency = 0.5, Parent = vipLbl })
	vip.Visible = UILib.state.vip == true
	UILib.subscribe(function(state) vip.Visible = state.vip == true end)

	-- left action rail — vertical, centered on the screen edge. Uniform dark
	-- buttons so the colorful icons carry the identity; gold ring on hover.
	local dock = UILib.make("Frame", {
		Name = "ActionDock", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0),
		AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.fromOffset(74, 0),
		BackgroundColor3 = C.Panel, BackgroundTransparency = 0.12, Parent = screen })
	UILib.corner(dock, 16)
	UILib.gradient(dock, UILib.lighten(C.Panel, 0.1), C.Panel)
	UILib.stroke(dock, C.Gold, 1.5)
	if UILib.IsTouch then
		UILib.make("UIScale", { Scale = 0.85, Parent = dock })
	end
	UILib.make("UIPadding", {
		PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6),
		PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), Parent = dock })
	UILib.make("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical, Padding = UDim.new(0, 8),
		HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder, Parent = dock })

	local order = 0
	local function mkBtn(iconId, label, cb)
		order += 1
		local b = UILib.button({
			Size = UDim2.fromOffset(62, 58), LayoutOrder = order, BackgroundColor3 = C.Panel2,
			Text = "", _stroke = UILib.darken(C.Panel2, 0.35), Parent = dock })
		local icon = UILib.make("ImageLabel", {
			Size = UDim2.fromOffset(28, 28), Position = UDim2.new(0.5, -14, 0, 5),
			BackgroundTransparency = 1, Image = iconId, ZIndex = b.ZIndex + 1, Parent = b })
		local lbl = UILib.make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 12), Position = UDim2.new(0, 0, 1, -16), BackgroundTransparency = 1,
			Text = label, TextSize = 10, Font = Enum.Font.GothamBold, TextColor3 = C.White,
			ZIndex = b.ZIndex + 1, Parent = b })
		UILib.make("UIStroke", { Color = C.Ink, Thickness = 1.5, LineJoinMode = Enum.LineJoinMode.Round, Parent = lbl })
		-- gold ring on hover (touch devices just get the press juice)
		if not UILib.IsTouch then
			local ring = UILib.make("Frame", {
				Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = b.ZIndex, Parent = b })
			UILib.corner(ring, 10)
			local ringStroke = UILib.make("UIStroke", {
				Color = C.Gold, Thickness = 2, Transparency = 1,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = ring })
			b.MouseEnter:Connect(function() UILib.tween(ringStroke, { Transparency = 0 }, 0.12) end)
			b.MouseLeave:Connect(function() UILib.tween(ringStroke, { Transparency = 1 }, 0.12) end)
		end
		if cb then b.MouseButton1Click:Connect(cb) end
		return b
	end
	mkBtn(UILib.Icons.Services, "Services", openers.onShop)
	mkBtn(UILib.Icons.Inventory, "Items", openers.onInventory)
	mkBtn(UILib.Icons.Move, "Move", openers.onMove)
	mkBtn(UILib.Icons.Upgrades, "Upgrades", openers.onUpgrades)
	mkBtn(UILib.Icons.Casino, "Casino", openers.onManage)
	mkBtn(UILib.Icons.Stats, "Stats", openers.onStats)
	mkBtn(UILib.Icons.Shop, "Shop", openers.onRobuxShop)
end

return HudUI
