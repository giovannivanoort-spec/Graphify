--!nonstrict
-- RobuxShopUI.luau — the Robux shop: gamepasses (permanent perks) + cash packs
-- (developer products). Live Robux prices/icons come from MarketplaceService;
-- ownership comes from the server (GetMonetization). Items whose Config id is
-- still 0 render as "Coming soon" and never prompt a purchase.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors

local RobuxShopUI = {}
local player = Players.LocalPlayer

local priceCache = {}
local function fetchPrice(id: number, infoType): number?
	if not id or id == 0 then return nil end
	local key = tostring(infoType) .. "_" .. id
	if priceCache[key] ~= nil then return priceCache[key] or nil end
	local ok, info = pcall(function() return MarketplaceService:GetProductInfo(id, infoType) end)
	local price = (ok and info and info.PriceInRobux) or false
	priceCache[key] = price
	return price or nil
end

function RobuxShopUI.open()
	local data = Remotes.GetMonetization():InvokeServer()
	if not data then UILib.toast("Shop unavailable.", C.Red); return end

	local _, _, content = UILib.centeredPanel("RobuxShop", 0.64, 0.85, 580, 640, "Robux Shop")
	local list = UILib.make("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 6, ScrollBarImageColor3 = C.Gold,
		Parent = content })
	UILib.make("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder, Parent = list })
	UILib.pad(list, 4)

	local function buildCard(item, isPass: boolean)
		local accent = isPass and C.Premium or C.Cash
		local card = UILib.card(list, { accent = accent, size = UDim2.new(1, 0, 0, 86) })

		UILib.make("TextLabel", { Size = UDim2.new(1, -150, 0, 24), Position = UDim2.fromOffset(14, 10),
			BackgroundTransparency = 1, Text = item.name, Font = Enum.Font.GothamBold, TextSize = 17,
			TextColor3 = C.White, TextXAlignment = Enum.TextXAlignment.Left, Parent = card })

		local desc = isPass and item.desc or ("Instantly adds $" .. UILib.commas(item.cashGrant or 0) .. " Cash to your bankroll.")
		UILib.make("TextLabel", { Size = UDim2.new(1, -150, 0, 38), Position = UDim2.fromOffset(14, 36),
			BackgroundTransparency = 1, Text = desc, Font = Enum.Font.Gotham, TextSize = 12.5,
			TextColor3 = C.Sub, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true, Parent = card })

		if item.badge then
			local badge = UILib.badge(card, item.badge, C.Gold)
			badge.AnchorPoint = Vector2.new(1, 0)
			badge.Position = UDim2.new(1, -12, 0, 8)
		end

		local infoType = isPass and Enum.InfoType.GamePass or Enum.InfoType.Product
		if isPass and item.owned then
			local owned = UILib.badge(card, "✓ OWNED", C.Green)
			owned.AnchorPoint = Vector2.new(1, 0.5)
			owned.Position = UDim2.new(1, -14, 0.62, 0)
			card.BackgroundTransparency = 0.4
		else
			local price = fetchPrice(item.id, infoType)
			local txt = (item.id == 0 and "Coming soon") or (price and ("R$ " .. UILib.commas(price))) or "R$ —"
			local buy = UILib.button({
				Size = UDim2.fromOffset(120, 46), Position = UDim2.new(1, -14, 0.62, 0), AnchorPoint = Vector2.new(1, 0.5),
				BackgroundColor3 = (item.id == 0) and C.Panel2 or C.Premium, Text = txt, TextSize = 15,
				TextColor3 = C.White, Parent = card })
			if item.id ~= 0 then
				buy.MouseButton1Click:Connect(function()
					if isPass then
						MarketplaceService:PromptGamePassPurchase(player, item.id)
					else
						MarketplaceService:PromptProductPurchase(player, item.id)
					end
				end)
			end
		end
	end

	UILib.sectionHeader(list, "GAMEPASSES — permanent perks")
	for _, gp in (data.gamepasses or {}) do buildCard(gp, true) end

	UILib.sectionHeader(list, "CASH PACKS")
	for _, p in (data.products or {}) do buildCard(p, false) end

	-- footer hint while ids are placeholders
	UILib.make("TextLabel", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1,
		Text = "Perks apply instantly after purchase — no rejoin needed.", Font = Enum.Font.Gotham,
		TextSize = 12, TextColor3 = C.Sub, Parent = list })
end

return RobuxShopUI
