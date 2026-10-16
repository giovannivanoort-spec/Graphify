--!nonstrict
-- RobuxShopUI.luau — the STORE panel (Config.Monetization; server: Monetization):
--   GAME PASSES  permanent perks; every card shows its pass's own `desc`, icon and tone
--   POTIONS      Robux potions (they go into your stock: USE them from the POTIONS
--                panel) + the x3 machine boost (bought here = stored boost time)
--   CASH PACKS   developer products that grant Cash (the server scales them with
--                your income: max(pack, minutes x your income rate))
--   TICKET SHOP  spend Tickets on timed 2X boosts, potions and a cash bundle (server: Rewards)
-- RobuxShopUI.open(tab?)   tab = "passes" | "potions" | "cash" | "tickets"
-- Live Robux prices come from MarketplaceService; ids still at 0 in Config show as
-- "SOON" and never prompt. Shared with PotionsUI and the machine popup (BoostFX):
--   RobuxShopUI.price(id, infoType?) -> number?   (yields; cached)
--   RobuxShopUI.priceText(id, infoType?, onText)  calls onText("R$ 39" | "R$ -" | "SOON")
--   RobuxShopUI.promptProduct(id) / .promptPass(id) -> boolean (false + toast for id 0)

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local Config = require(Common:WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local F = UILib.Fonts

local RobuxShopUI = {}
local player = Players.LocalPlayer

------------------------------------------------------------------
-- Robux prices + prompts (shared)
------------------------------------------------------------------
local priceCache = {}
function RobuxShopUI.price(id: number?, infoType): number?
	if not id or id == 0 then return nil end
	infoType = infoType or Enum.InfoType.Product
	local key = tostring(infoType) .. "_" .. id
	if priceCache[key] ~= nil then return priceCache[key] or nil end
	local ok, info = pcall(function() return MarketplaceService:GetProductInfoAsync(id, infoType) end)
	local price = (ok and info and info.PriceInRobux) or false
	priceCache[key] = price
	return price or nil
end

-- the label a buy button shows: "SOON" at once for id 0, else "R$ ..." then the live price
function RobuxShopUI.priceText(id: number?, infoType, onText: (string) -> ())
	if not id or id == 0 then
		onText("SOON")
		return
	end
	onText("R$ ...")
	task.spawn(function()
		local price = RobuxShopUI.price(id, infoType)
		onText(price and ("R$ " .. UILib.commas(price)) or "R$ -")
	end)
end

function RobuxShopUI.promptProduct(id: number?): boolean
	if not id or id == 0 then
		UILib.toast("COMING SOON!", "info", "This isn't on sale yet - check back soon.")
		return false
	end
	local ok, err = pcall(function() MarketplaceService:PromptProductPurchase(player, id) end)
	if not ok then
		warn("[RobuxShopUI] prompt: " .. tostring(err))
		UILib.toast("Store unavailable", "error")
	end
	return ok
end

function RobuxShopUI.promptPass(id: number?): boolean
	if not id or id == 0 then
		UILib.toast("COMING SOON!", "info", "This pass isn't on sale yet - check back soon.")
		return false
	end
	local ok, err = pcall(function() MarketplaceService:PromptGamePassPurchase(player, id) end)
	if not ok then
		warn("[RobuxShopUI] prompt: " .. tostring(err))
		UILib.toast("Store unavailable", "error")
	end
	return ok
end

------------------------------------------------------------------
-- helpers
------------------------------------------------------------------
local PACK_TONES = { "Green", "Blue", "Purple", "Orange" }
local TABS = {
	{ id = "passes", label = "GAME PASSES" },
	{ id = "potions", label = "POTIONS" },
	{ id = "cash", label = "CASH PACKS" },
	{ id = "tickets", label = "TICKET SHOP" },
}
local ALIASES = { gamepasses = "passes", pass = "passes", potion = "potions", boost = "potions", boosts = "potions",
	packs = "cash", ticket = "tickets" }

local function tabId(tab: any): string
	if type(tab) ~= "string" then return "passes" end
	tab = string.lower(tab)
	tab = ALIASES[tab] or tab
	for _, t in TABS do
		if t.id == tab then return tab end
	end
	return "passes"
end

-- minutes -> "5 MIN" / "1 HOUR" / "3 HOURS"
local function span(minutes: number): string
	if minutes >= 60 and minutes % 60 == 0 then
		local h = minutes // 60
		return h == 1 and "1 HOUR" or (h .. " HOURS")
	end
	return ("%d MIN"):format(minutes)
end

local function potionOwned(id: string): number
	local st = UILib.state.potions
	local owned = type(st) == "table" and st.owned
	return type(owned) == "table" and math.max(0, math.floor(tonumber(owned[id]) or 0)) or 0
end

-- the PotionsUI module (required lazily: it uses this one)
local function potionsUI()
	local mod = script.Parent:FindFirstChild("PotionsUI")
	if not mod then return nil end
	local ok, res = pcall(require, mod)
	return ok and type(res) == "table" and res or nil
end

-- a card whose stat pill makes way for a wrapped description (game passes)
local function descCard(o, desc: string)
	o.size = UDim2.fromOffset(204, 326)
	o.stat = ""
	local card = UILib.card(o)
	local body = card.Instance:FindFirstChild("Body")
	local stat = body and body:FindFirstChild("Stat")
	if stat then stat.Visible = false end
	if body then
		local box = UILib.make("Frame", {
			Name = "Desc", BackgroundColor3 = C.Cream, Position = UDim2.fromOffset(10, 184),
			Size = UDim2.new(1, -20, 0, 58), Parent = body,
		})
		UILib.corner(box, 12)
		UILib.stroke(box, C.Ink, 2.5, true)
		UILib.pad(box, 8, 4, 8, 4)
		UILib.body(box, {
			text = desc or "", size = 13, font = F.Body, color = C.Brown, wrap = true,
			xAlign = Enum.TextXAlignment.Center, frameSize = UDim2.fromScale(1, 1),
		})
	end
	return card
end

------------------------------------------------------------------
-- the panel
------------------------------------------------------------------
function RobuxShopUI.open(tab: string?)
	local data = Remotes.GetMonetization():InvokeServer()
	if not data then UILib.toast("Store unavailable", "error"); return end

	local p = UILib.panel({ name = "StorePanel", title = "STORE", icon = "gem", width = 1000, height = 600 })
	local content = p.content
	local body = UILib.make("Frame", {
		Name = "Body", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 60),
		Size = UDim2.new(1, 0, 1, -104), Parent = content,
	})
	local footerRow = UILib.make("Frame", {
		Name = "Footer", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 40), Parent = content,
	})
	local footer = UILib.body(footerRow, {
		text = "", size = 14, transparency = 0.25, frameSize = UDim2.new(1, -200, 1, 0),
	})
	local footerButton = UILib.button({
		parent = footerRow, tone = "Purple", text = "MY POTIONS", icon = "potion_mega", textSize = 18, iconSize = 30,
		size = UDim2.fromOffset(190, 40), anchor = Vector2.new(1, 0.5), position = UDim2.new(1, 0, 0.5, 0),
		onClick = function()
			local ui = potionsUI()
			if ui and ui.open then ui.open() end
		end,
	})
	footerButton.Instance.Visible = false

	local current
	local signature = nil

	-- a Robux card: OWNED / SOON / the live price
	local function robuxCard(grid, i, o, id: number, infoType, owned: boolean, desc: string?)
		o.parent = grid
		o.order = i
		o.titleSize = o.titleSize or (#o.title > 13 and 18 or 22)
		o.button = owned and { tone = "Purple", text = "OWNED" } or {
			tone = id == 0 and "Purple" or "Green", text = id == 0 and "SOON" or "R$ ...",
			onClick = function()
				if infoType == Enum.InfoType.GamePass then
					RobuxShopUI.promptPass(id)
				else
					if o.beforePrompt and not o.beforePrompt() then return end
					RobuxShopUI.promptProduct(id)
				end
			end,
		}
		if owned then o.badge = { text = "OWNED", tone = "Green" } end
		local card = desc and descCard(o, desc) or UILib.card(o)
		-- long names shrink to fit the card
		local holder = card.Instance:FindFirstChild("Body") and card.Instance.Body:FindFirstChild("Title")
		local face = holder and holder:FindFirstChild("Face")
		if face then UILib.fitText(face, o.title, o.titleSize, 184, 13) end
		if not owned and id ~= 0 then
			RobuxShopUI.priceText(id, infoType, function(text)
				if card.button and card.Instance.Parent then card.button.setText(text) end
			end)
		end
		return card
	end

	-- what each tab shows from the live state (re-render only when it changes)
	local function signatureOf(which: string): string
		if which == "tickets" then
			local parts = { tostring(UILib.state.tickets or 0) }
			for _, def in Config.Potions do table.insert(parts, tostring(potionOwned(def.id))) end
			return table.concat(parts, ",")
		elseif which == "potions" then
			local parts = {}
			for _, def in Config.Potions do table.insert(parts, tostring(potionOwned(def.id))) end
			local b = UILib.state.boosts
			table.insert(parts, tostring(type(b) == "table" and b.stored or 0))
			return table.concat(parts, ",")
		end
		return which
	end

	local function render(which)
		current = which
		signature = signatureOf(which)
		for _, ch in body:GetChildren() do ch:Destroy() end
		footerButton.Instance.Visible = false
		local grid = UILib.scroller(body, { grid = true, cell = UDim2.fromOffset(204, which == "passes" and 326 or 296),
			memory = which })
		if which == "passes" then
			footer.Text = "Perks apply instantly - no rejoin needed!"
			-- passes you don't own yet first (in Config order), owned ones after
			local list = {}
			for i, gp in (data.gamepasses or {}) do table.insert(list, { gp = gp, i = i }) end
			table.sort(list, function(a, b)
				if (a.gp.owned == true) ~= (b.gp.owned == true) then return not a.gp.owned end
				return a.i < b.i
			end)
			for i, entry in list do
				local gp = entry.gp
				local title = string.upper(gp.name or gp.key):gsub("\u{00D7}", "X")
				robuxCard(grid, i, {
					tone = gp.tone or "Gold", icon = gp.icon or "star", title = title,
					badge = gp.badge and { text = gp.badge, tone = "Gold" } or nil,
				}, gp.id or 0, Enum.InfoType.GamePass, gp.owned == true, gp.desc or "")
			end
		elseif which == "potions" then
			footer.Text = "Potions wait in your stock - use one any time. Timers only run while you play."
			footerButton.Instance.Visible = true
			local byPotion = {}
			for _, pr in (data.potions or {}) do byPotion[pr.potion] = pr end
			local i = 0
			for _, def in Config.Potions do
				local pr = byPotion[def.id]
				if pr then
					i += 1
					local have = potionOwned(def.id)
					robuxCard(grid, i, {
						tone = def.tone or "Gold", icon = def.icon, title = string.upper(def.name), stat = def.stat,
						badge = have > 0 and { text = ("x%d OWNED"):format(have), tone = "Green" }
							or (pr.badge and { text = pr.badge, tone = "Gold" } or nil),
					}, pr.id or 0, Enum.InfoType.Product, false)
				end
			end
			-- the x3 machine boost: bought here it lands on your stored boost time
			for _, pr in (data.boosts or {}) do
				i += 1
				local b = UILib.state.boosts
				local stored = type(b) == "table" and tonumber(b.stored) or 0
				local mult = type(b) == "table" and tonumber(b.mult) or (Config.MachineBoost and Config.MachineBoost.Multiplier) or 3
				robuxCard(grid, i, {
					tone = "Purple", icon = "boost", title = ("X%d MACHINE BOOST"):format(mult), titleSize = 18,
					stat = ("1 machine - %d min"):format(math.floor((tonumber(pr.seconds) or 900) / 60)),
					badge = stored > 0 and { text = UILib.clock(stored) .. " STORED", tone = "Purple" } or nil,
					-- (no machine picked: the time goes to the stored boost)
					beforePrompt = function()
						local ok, res = pcall(function() return Remotes.SetBoostTarget():InvokeServer(nil) end)
						if ok and type(res) == "table" and res.ok == true then return true end
						UILib.toast("Store unavailable", "error", "Try again in a moment.")
						return false
					end,
				}, pr.id or 0, Enum.InfoType.Product, false)
			end
		elseif which == "cash" then
			footer.Text = "Cash lands in your bankroll instantly - packs grow with your income."
			for i, pr in (data.products or {}) do
				local minutes = tonumber(pr.incomeMinutes)
				robuxCard(grid, i, {
					tone = PACK_TONES[(i - 1) % #PACK_TONES + 1], icon = "cash",
					title = "$" .. UILib.short(tonumber(pr.cashGrant) or 0),
					stat = minutes and (span(minutes) .. " OF INCOME") or "Cash pack",
					badge = pr.badge and { text = pr.badge, tone = "Gold" } or nil,
				}, pr.id or 0, Enum.InfoType.Product, false)
			end
		else -- tickets
			footer.Text = "Earn Tickets from your Daily Reward streak and playtime rewards."
			local have = UILib.state.tickets or 0
			for i, item in Config.TicketShop do
				local owned = item.potion and potionOwned(item.potion) or 0
				local card = UILib.card({
					parent = grid, order = i, tone = item.tone or "Pink", icon = item.icon or "ticket",
					title = string.upper(item.name), stat = item.desc, titleSize = #item.name > 13 and 18 or 22,
					badge = owned > 0 and { text = ("x%d OWNED"):format(owned), tone = "Green" }
						or (item.badge and { text = item.badge, tone = "Gold" } or nil),
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

	local tabs = UILib.tabs(content, TABS, render)
	tabs.select(tabId(tab))

	-- ticket / potion / stored-boost changes: refresh the tab that shows them
	local first = true
	local unsub = UILib.subscribe(function()
		if first then first = false; return end
		if p.alive and current and signatureOf(current) ~= signature then render(current) end
	end)
	-- a game pass bought here: fetch the catalog again so it shows OWNED
	local passConn = MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(plr, _passId, purchased)
		if plr ~= player or not purchased then return end
		task.delay(1, function()
			if not p.alive then return end
			local ok, fresh = pcall(function() return Remotes.GetMonetization():InvokeServer() end)
			if ok and fresh and p.alive then
				data = fresh
				if current == "passes" then render("passes") end
			end
		end)
	end)
	p.onClose(function()
		unsub()
		passConn:Disconnect()
	end)
end

return RobuxShopUI
