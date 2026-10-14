--!nonstrict
-- DailyUI.luau — 7-day DAILY REWARD track (rewards come from Config.DailyRewards,
-- the streak/cooldown from the server snapshot's `daily` field). Claimed days
-- are green with a check, today glows crimson with a TODAY! tag, future days are
-- cream, day 7 is the big purple MEGA tile. Opens itself once per session when a
-- reward is waiting.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local Config = require(Common:WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local F = UILib.Fonts

local DailyUI = {}

local function rewardLook(r)
	if r.mega then return "gift", "MEGA" end
	if r.tickets and not r.cash then return "ticket", UILib.commas(r.tickets) end
	return "coin", UILib.money(r.cash or 0)
end

function DailyUI.open()
	local p = UILib.panel({ name = "DailyPanel", title = "DAILY REWARD", icon = "gift", width = 1000, height = 500 })
	local content = p.content
	UILib.body(content, {
		text = "Come back every day for bigger prizes - day 7 is MEGA!", size = 16,
		xAlign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 0, 24),
	})
	local track = UILib.make("Frame", {
		Name = "Track", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 42),
		Size = UDim2.new(1, 0, 0, 210), Parent = content,
	})
	UILib.list(track, "x", 12, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Bottom)

	local claimBtn = UILib.button({
		parent = content, tone = "Gold", text = "CLAIM!", textSize = 38,
		size = UDim2.fromOffset(320, 76), anchor = Vector2.new(0.5, 0), position = UDim2.new(0.5, 0, 0, 268),
	})
	local timer = UILib.body(content, {
		text = "", size = 15, xAlign = Enum.TextXAlignment.Center, transparency = 0.2,
		frameSize = UDim2.new(1, 0, 0, 22), position = UDim2.fromOffset(0, 352),
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
			local tile = UILib.make("Frame", {
				Name = "Day" .. i, BackgroundColor3 = C.White, LayoutOrder = i,
				Size = UDim2.fromOffset(big and 150 or 104, big and 200 or 164), Parent = track,
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
			local icon, amount = rewardLook(r)
			if light then
				UILib.text(tile, { text = "DAY " .. i, size = 18, frameSize = UDim2.new(1, 0, 0, 26), position = UDim2.fromOffset(0, 8), shadow = 2 })
				UILib.text(tile, { text = amount, size = big and 24 or 20, frameSize = UDim2.new(1, 0, 0, 28),
					anchor = Vector2.new(0, 1), position = UDim2.new(0, 0, 1, -10), shadow = 2 })
			else
				UILib.body(tile, { text = "DAY " .. i, font = F.Display, size = 18, xAlign = Enum.TextXAlignment.Center,
					frameSize = UDim2.new(1, 0, 0, 26), position = UDim2.fromOffset(0, 8) })
				UILib.body(tile, { text = amount, font = F.Display, size = 20, xAlign = Enum.TextXAlignment.Center,
					frameSize = UDim2.new(1, 0, 0, 28), anchor = Vector2.new(0, 1), position = UDim2.new(0, 0, 1, -10) })
			end
			local img = UILib.image(tile, icon, {
				size = UDim2.fromOffset(big and 104 or 68, big and 104 or 68), anchor = Vector2.new(0.5, 0.5),
				position = UDim2.fromScale(0.5, 0.52),
			})
			if not light then img.ImageTransparency = 0.35 end
			if claimed then
				UILib.image(tile, UILib.Tex.check, { size = UDim2.fromOffset(40, 40), position = UDim2.new(1, -26, 0, -14) })
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
		local res = Remotes.ClaimDaily():InvokeServer()
		if res and res.ok then
			local parts = {}
			if res.cash then table.insert(parts, UILib.money(res.cash)) end
			if res.tickets then table.insert(parts, UILib.commas(res.tickets) .. " Tickets") end
			UILib.toast(res.mega and "MEGA REWARD!" or ("DAY %d CLAIMED!"):format(res.day or 0), res.mega and "unlock" or "income",
				"+" .. table.concat(parts, " + "))
		else
			UILib.toast(res and res.message or "Can't claim yet", "error")
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
