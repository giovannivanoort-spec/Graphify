--!nonstrict
-- DailyUI.luau — 7-day DAILY REWARD track (rewards come from Config.DailyRewards,
-- the streak/cooldown from the server snapshot's `daily` field). Claimed days
-- are green with a check, today glows crimson with a TODAY! tag, future days are
-- cream, day 7 is the big purple MEGA tile. A day's main prize is its big icon
-- (a potion beats Cash / Tickets), a second prize rides on the icon's shoulder
-- as a chip, and the MEGA tile lists all of its prizes. Cash shows what the day
-- pays this player now (the server's `daily.cashByDay`, scaled to their income).
-- Opens itself once per session when a reward is waiting.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local Config = require(Common:WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local F = UILib.Fonts

local DailyUI = {}

local TILE_W, TILE_H, MEGA_W, MEGA_H = 112, 172, 172, 214

-- the caption under a prize: "$12.5K", "25", "XP POTION"
local function caption(part, short: boolean?): string
	local n = tonumber(part.amount) or 0
	if part.kind == "cash" then return UILib.moneyShort(n) end
	if part.kind == "tickets" then return short and UILib.commas(n) or (UILib.commas(n) .. " TICKETS") end
	if part.kind == "potion" then return (n > 1 and (n .. "x ") or "") .. string.upper(part.name) end
	if part.kind == "boost" then return ("x3 BOOST %dM"):format(n) end
	if part.kind == "rcoin" then return n .. (n == 1 and " RCOIN" or " RCOINS") end
	return string.upper(tostring(part.name or ""))
end

-- "Potions on days 2, 4 and 6 - day 7 is MEGA!" (from the config)
local function subtitle(): string
	local days = {}
	for i, r in Config.DailyRewards do
		if r.potion and not r.mega then table.insert(days, tostring(i)) end
	end
	local megaDay = #Config.DailyRewards
	if #days == 0 then return ("Come back every day for bigger prizes - day %d is MEGA!"):format(megaDay) end
	local list = #days == 1 and days[1] or (table.concat(days, ", ", 1, #days - 1) .. " and " .. days[#days])
	return ("Come back every day: potions on day%s %s - day %d is MEGA!"):format(#days == 1 and "" or "s", list, megaDay)
end

function DailyUI.open()
	local p = UILib.panel({ name = "DailyPanel", title = "DAILY REWARD", icon = "gift", width = 1000, height = 520 })
	local content = p.content
	UILib.body(content, {
		text = subtitle(), size = 16, xAlign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 0, 24),
	})
	local track = UILib.make("Frame", {
		Name = "Track", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 40),
		Size = UDim2.new(1, 0, 0, MEGA_H + 12), Parent = content,
	})
	UILib.list(track, "x", 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Bottom)

	local claimBtn = UILib.button({
		parent = content, tone = "Gold", text = "CLAIM!", textSize = 38,
		size = UDim2.fromOffset(320, 76), anchor = Vector2.new(0.5, 0), position = UDim2.new(0.5, 0, 0, 284),
	})
	local timer = UILib.body(content, {
		text = "", size = 15, xAlign = Enum.TextXAlignment.Center, transparency = 0.2,
		frameSize = UDim2.new(1, 0, 0, 22), position = UDim2.fromOffset(0, 368),
	})

	local function render(state)
		if not p.alive then return end
		for _, ch in track:GetChildren() do
			if ch:IsA("GuiObject") then ch:Destroy() end
		end
		local d = state.daily or { day = 1, canClaim = false, secondsLeft = 0 }
		local ready = d.canClaim or UILib.secondsLeft(d.secondsLeft) <= 0
		for i, r in Config.DailyRewards do
			local big = r.mega == true
			local claimed = i < d.day
			local today = i == d.day
			local w, h = big and MEGA_W or TILE_W, big and MEGA_H or TILE_H
			local tile = UILib.make("Frame", {
				Name = "Day" .. i, BackgroundColor3 = C.White, LayoutOrder = i, Size = UDim2.fromOffset(w, h), Parent = track,
			})
			UILib.corner(tile, 20)
			local tone = claimed and UILib.Tones.Green or (today and ready and UILib.Tones.Red)
				or (big and UILib.Tones.Purple) or nil
			if tone then
				UILib.gradient(tile, tone.top, tone.base)
			else
				UILib.gradient(tile, C.Cream, C.CreamRow)
			end
			UILib.stroke(tile, (today and ready) and C.Gold or C.Ink, (today and ready) and 6 or 3.5, true)
			local light = tone ~= nil
			local cash = type(d.cashByDay) == "table" and tonumber(d.cashByDay[i]) or nil
			local parts = Config.rewardParts(r, cash)
			local main = parts[1] or { kind = "cash", icon = "coin", tone = "Green", amount = r.cash or 0 }

			-- light tiles: white display text; cream tiles: brown
			local function label(text: string, size: number, y: number, width: number)
				if light then
					local face = UILib.text(tile, {
						text = text, size = size, frameSize = UDim2.fromOffset(width, size + 8),
						anchor = Vector2.new(0.5, 0), position = UDim2.new(0.5, 0, 0, y), shadow = 2,
					})
					UILib.fitText(face, text, size, width, 11)
				else
					local lbl = UILib.body(tile, {
						text = text, font = F.Display, size = size, xAlign = Enum.TextXAlignment.Center,
						frameSize = UDim2.fromOffset(width, size + 8), anchor = Vector2.new(0.5, 0),
						position = UDim2.new(0.5, 0, 0, y),
					})
					UILib.fitText(lbl, text, size, width, 11)
				end
			end
			label("DAY " .. i, 18, 8, w - 10)

			local iconSize = big and 96 or 66
			local img = UILib.image(tile, big and "gift" or main.icon, {
				size = UDim2.fromOffset(iconSize, iconSize), anchor = Vector2.new(0.5, 0.5),
				position = UDim2.new(0.5, 0, 0, big and 82 or 80),
			})
			if not light then img.ImageTransparency = 0.35 end

			if big then
				-- the MEGA tile lists every prize: icon + amount per row
				local rowsFrame = UILib.make("Frame", {
					Name = "Prizes", BackgroundTransparency = 1, Position = UDim2.fromOffset(6, 132),
					Size = UDim2.new(1, -12, 0, 76), Parent = tile,
				})
				UILib.list(rowsFrame, "y", 2, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
				for k, part in parts do
					if k > 3 then break end
					local row = UILib.make("Frame", {
						Name = "Prize" .. k, BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 24),
						AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = k, Parent = rowsFrame,
					})
					UILib.list(row, "x", 4, nil, Enum.VerticalAlignment.Center)
					UILib.image(row, part.icon, { size = UDim2.fromOffset(26, 26), order = 1 })
					UILib.text(row, {
						text = caption(part, true), font = F.Number, size = 17, autoX = true,
						frameSize = UDim2.fromScale(0, 1), order = 2, stroke = 2, shadow = 1,
					})
				end
			else
				label(caption(main), 18, h - 38, w - 10)
				-- a second prize: a chip on the icon's shoulder ("+25" tickets)
				local extra = parts[2]
				if extra then
					local chip = UILib.make("Frame", {
						Name = "Extra", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.1, AnchorPoint = Vector2.new(1, 0),
						Position = UDim2.new(1, -4, 0, 38), Size = UDim2.fromOffset(0, 26),
						AutomaticSize = Enum.AutomaticSize.X, ZIndex = 2, Parent = tile,
					})
					UILib.corner(chip, 999)
					UILib.stroke(chip, C.GoldDeep, 2, true)
					UILib.pad(chip, 2, 0, 8, 0)
					UILib.list(chip, "x", 1, nil, Enum.VerticalAlignment.Center)
					UILib.image(chip, extra.icon, { size = UDim2.fromOffset(24, 24), order = 1, z = 2 })
					UILib.text(chip, {
						text = "+" .. (extra.kind == "cash" and UILib.moneyShort(extra.amount) or UILib.short(extra.amount)),
						font = F.Number, size = 15, autoX = true, frameSize = UDim2.fromScale(0, 1), order = 2,
						stroke = 1.5, shadow = 1, z = 2,
					})
				end
			end
			if claimed then
				UILib.image(tile, UILib.Tex.check, { size = UDim2.fromOffset(40, 40), position = UDim2.new(1, -26, 0, -14), z = 3 })
			end
			if today and ready then
				-- rotating rays, clipped to the tile so they don't spill over the neighbours
				local clip = UILib.make("Frame", {
					Name = "GlowClip", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
					ClipsDescendants = true, ZIndex = 0, Parent = tile,
				})
				local glow = UILib.image(clip, UILib.Tex.sunburst, {
					size = UDim2.fromOffset(260, 260), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5),
					color = C.GoldTop, transparency = 0.55, z = 0,
				})
				UILib.spin(glow, 14)
				local b = UILib.badge(tile, "TODAY!", "Gold", -8, 6)
				b.AnchorPoint = Vector2.new(0.5, 0.5)
				b.Position = UDim2.new(0.5, 0, 0, -6)
			end
		end
		claimBtn.setEnabled(ready)
		claimBtn.setTone(ready and "Gold" or "Purple")
		claimBtn.setText(ready and "CLAIM!" or "COME BACK")
	end

	claimBtn.onClick(function()
		local ok, res = pcall(function() return Remotes.ClaimDaily():InvokeServer() end)
		if ok and res and res.ok then
			local parts = res.parts
			if type(parts) ~= "table" or #parts == 0 then
				parts = {}
				if res.cash then table.insert(parts, UILib.money(res.cash)) end
				if res.tickets then table.insert(parts, UILib.commas(res.tickets) .. " Tickets") end
			end
			UILib.toast(res.mega and "MEGA REWARD!" or ("DAY %d CLAIMED!"):format(res.day or 0), res.mega and "unlock" or "income",
				"+" .. table.concat(parts, " + "))
			if res.mega then UILib.fx("banner", "MEGA REWARD!", table.concat(parts, " + "), "purple") end
		else
			UILib.toast(ok and res and res.message or "Can't claim yet", "error")
		end
	end)

	local unsub = UILib.subscribe(render)
	p.onClose(unsub)

	task.spawn(function()
		local wasReady = nil
		while p.alive do
			local d = UILib.state.daily
			if d then
				local left = UILib.secondsLeft(d.secondsLeft)
				local ready = d.canClaim or left <= 0
				timer.Text = ready and "Your reward is ready!" or ("Next reward in " .. UILib.clock(left))
				-- the cooldown ran out while the panel was open -> unlock the tile/button
				if wasReady ~= nil and ready ~= wasReady then render(UILib.state) end
				wasReady = ready
			end
			task.wait(1)
		end
	end)
end

-- auto-open once per session when a reward is waiting (after the welcome popup)
function DailyUI.start()
	task.spawn(function()
		local t0 = os.clock()
		while os.clock() - t0 < 30 do
			local d = UILib.state.daily
			if d then
				if d.canClaim then
					task.wait(2.5)
					while UILib.hasOpenPanel() do task.wait(1) end
					DailyUI.open()
				end
				return
			end
			task.wait(0.5)
		end
	end)
end

return DailyUI
