--!nonstrict
-- RobuxShopUI.luau — the STORE panel:
--   GAME PASSES  permanent perks (MarketplaceService gamepass prompts)
--   CASH PACKS   developer products that grant Cash
--   TICKET SHOP  spend Tickets on timed 2X boosts / a cash bundle (server: Rewards)
-- Live Robux prices come from MarketplaceService; ids still at 0 in Config show
-- as "SOON" and never prompt.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local Config = require(Common:WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))

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

local PASS_LOOK = { vip = { "crown", "Purple" }, space = { "build", "Blue" }, offline2x = { "cash", "Green" } }
local PACK_TONES = { "Green", "Blue", "Purple", "Orange" }

function RobuxShopUI.open(tab: string?)
	local data = Remotes.GetMonetization():InvokeServer()
	if not data then UILib.toast("Store unavailable", "error"); return end

	local p = UILib.panel({ name = "StorePanel", title = "STORE", icon = "gem", width = 1000, height = 548 })
	local content = p.content
	local body = UILib.make("Frame", {
		Name = "Body", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 60),
		Size = UDim2.new(1, 0, 1, -100), Parent = content,
	})
	local footer = UILib.body(content, {
		text = "Perks apply instantly - no rejoin needed!", size = 14, transparency = 0.25,
		anchor = Vector2.new(0, 1), position = UDim2.fromScale(0, 1), frameSize = UDim2.new(1, 0, 0, 30),
	})

	local current
	local function robuxCard(grid, i, look, title, stat, id, infoType, owned, badge)
		local card = UILib.card({
			parent = grid, order = i, tone = look[2], icon = look[1], title = title, stat = stat,
			titleSize = #title > 13 and 18 or 22,
			badge = owned and { text = "OWNED", tone = "Green" } or badge,
			button = owned and { tone = "Purple", text = "OWNED" } or {
				tone = id == 0 and "Purple" or "Green", text = id == 0 and "SOON" or "R$ ...",
				onClick = function()
					if id == 0 then UILib.toast("Coming soon!", "info"); return end
					if infoType == Enum.InfoType.GamePass then
						MarketplaceService:PromptGamePassPurchase(player, id)
					else
						MarketplaceService:PromptProductPurchase(player, id)
					end
				end,
			},
		})
		if not owned and id ~= 0 then
			task.spawn(function()
				local price = fetchPrice(id, infoType)
				if card.button and card.Instance.Parent then
					card.button.setText(price and ("R$ " .. UILib.commas(price)) or "R$ -")
				end
			end)
		end
	end

	local function render(which)
		current = which
		for _, ch in body:GetChildren() do ch:Destroy() end
		local grid = UILib.scroller(body, { grid = true })
		if which == "passes" then
			footer.Text = "Perks apply instantly - no rejoin needed!"
			for i, gp in (data.gamepasses or {}) do
				-- Luckiest Guy has no proper "×" glyph: show 2X instead of 2×
				local title = string.upper(gp.name):gsub("\u{00D7}", "X")
				robuxCard(grid, i, PASS_LOOK[gp.key] or { "star", "Gold" }, title,
					gp.key == "vip" and "2x earnings + badge" or (gp.key == "space" and "+8 machine slots" or "2x offline income"),
					gp.id, Enum.InfoType.GamePass, gp.owned, gp.key == "vip" and { text = "BEST VALUE", tone = "Gold" } or nil)
			end
		elseif which == "cash" then
			footer.Text = "Cash lands in your bankroll instantly."
			for i, pr in (data.products or {}) do
				robuxCard(grid, i, { "cash", PACK_TONES[(i - 1) % #PACK_TONES + 1] }, "$" .. UILib.abbreviate(pr.cashGrant or 0),
					"Cash pack", pr.id, Enum.InfoType.Product, false,
					pr.badge and { text = pr.badge, tone = "Gold" } or nil)
			end
		else -- tickets
			footer.Text = "Earn Tickets from your Daily Reward streak."
			local have = UILib.state.tickets or 0
			for i, item in Config.TicketShop do
				local card = UILib.card({
					parent = grid, order = i, tone = item.tone or "Pink", icon = item.icon or "ticket",
					title = string.upper(item.name), stat = item.desc, titleSize = 22,
					badge = item.badge and { text = item.badge, tone = "Gold" } or nil,
					button = { tone = have >= item.cost and "Pink" or "Red", text = UILib.commas(item.cost), icon = "ticket",
						onClick = function()
							local res = Remotes.BuyTicketItem():InvokeServer(item.id)
							if res and res.ok then
								UILib.toast(string.upper(item.name) .. "!", "ticket", res.message)
							else
								UILib.toast(res and res.message or "Purchase failed", "error")
							end
						end },
				})
				card.Instance:SetAttribute("Cost", item.cost)
			end
		end
	end

	local tabs = UILib.tabs(content, {
		{ id = "passes", label = "GAME PASSES" },
		{ id = "cash", label = "CASH PACKS" },
		{ id = "tickets", label = "TICKET SHOP" },
	}, render)
	tabs.select(tab or "passes")

	-- ticket balance changes -> refresh the ticket tab's affordability
	local first = true
	local unsub = UILib.subscribe(function()
		if first then first = false; return end
		if current == "tickets" and p.alive then render("tickets") end
	end)
	p.onClose(unsub)
end

return RobuxShopUI
