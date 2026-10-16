--!nonstrict
-- WheelUI.luau — the LUCKY WHEEL panel and its HUD tile (Config.LuckyWheel; server
-- CasinoServer/LuckyWheel.luau, remote SpinWheel(kind)).
--   * a big Showtime prize wheel: one rainbow slice per segment (clockwise from the
--     top, with its 3D icon, what it pays and its chance), gold frets with pegs, a
--     gold rim of chasing bulbs, a gold pointer with a ruby cap, a SPIN hub
--   * a spin: the wheel pulls back, spins up while the server picks the prize, then
--     eases out over the server's RevealSeconds and stops exactly on that segment;
--     the pointer kicks on every peg (tick sounds), the bulbs chase with the speed
--     and flash on the stop, the winning slice blinks and a prize card pops with
--     confetti (MEGA JACKPOT: banner, flash, punch). The server pays the prize as
--     the wheel stops, so the coins fly into the HUD right then.
--   * right column: the free-spin clock, SPIN FREE, SPIN for Tickets, BONUS SPIN
--     (owned spins), +3 SPINS for Robux (only where paid random items are allowed:
--     snapshot canBuy) and PRIZES & ODDS (every segment's chance, required for paid
--     random items)
--   * the HUD tile SPIN (HudUI.addRailTile, order 20): pill "1:23:45" / "FREE!",
--     alert while a free or bonus spin waits, a toast when the free spin is back and
--     when bonus spins arrive
-- Snapshot `wheel` = { nextFree (server os.time), spins, total, ticketCost,
-- cash = { [segment] = Cash it pays now }, canBuy, productId, spinning }.
-- WheelUI.open(), WheelUI.start(deps) (deps: HudUI, RobuxShopUI).

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local Config = require(Common:WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local F = UILib.Fonts
local Tones = UILib.Tones
local make = UILib.make

local WheelUI = {}
local deps = {}
local started = false
local panelOpen = false
local lockUntil = 0       -- os.clock(): a spin's prize is still on its way (no new spin before)

-- design px (the panel scales with the viewport)
local PANEL_W, PANEL_H = 1040, 640
local STAGE = 520         -- the wheel's square stage (and its spinning disc)
local R_RIM = 238         -- the gold rim
local R_BULB = 223        -- the ring of bulbs
local R_FACE = 205        -- the slices end here (an ink ring)
local R_LIGHT = 108       -- the lighter inner band
local R_HUB = 56          -- the SPIN hub
local STRIPS = 16         -- thin rotated strips per slice: their seams hide under the frets
local FRET_W = 7
local BULBS = 24
local OMEGA = 1080        -- deg/s while the server picks
local WINDUP, ACCEL = 0.2, 0.45

-- icons the ICONS2 set adds: a stand-in until they're uploaded
local STANDIN = { wheel = "slot", megaphone = "mic", cheater = "shield" }
local function iconName(name: string): string
	if UILib.resolveIcon(name) ~= "" then return name end
	return STANDIN[name] or "star"
end

-- a toast whose tile shows `icon` in `tone` (UILib.toast announces each toast to the
-- fx hooks synchronously: swap the tile's look right there)
local function iconToast(title: string, kind: string, message: string?, icon: string?, tone: string?)
	local t = tone and Tones[tone]
	local done = false
	local unsub = UILib.onFx(function(event, _kind, _card, tile, toastTitle)
		if done or event ~= "toast" or toastTitle ~= title or typeof(tile) ~= "Instance" then return end
		done = true
		local img = tile:FindFirstChildWhichIsA("ImageLabel")
		if img and icon then img.Image = UILib.resolveIcon(iconName(icon)) end
		local grad = tile:FindFirstChildOfClass("UIGradient")
		if grad and t then grad.Color = ColorSequence.new(t.top, t.base) end
	end)
	UILib.toast(title, kind, message)
	unsub()
end

------------------------------------------------------------------
-- state helpers
------------------------------------------------------------------
local function segments()
	return (Config.LuckyWheel and Config.LuckyWheel.Segments) or {}
end

local function wheelState()
	local st = UILib.state.wheel
	return type(st) == "table" and st or nil
end

local function serverNow(): number
	local ok, t = pcall(function() return Workspace:GetServerTimeNow() end)
	return (ok and type(t) == "number") and t or os.time()
end

-- seconds until the free spin (0 = ready; huge while the state isn't loaded)
local function freeIn(st): number
	if not st then return math.huge end
	return math.max(0, (tonumber(st.nextFree) or 0) - serverNow())
end

local function totalWeight(): number
	local t = 0
	for _, seg in segments() do t += math.max(0, tonumber(seg.weight) or 0) end
	return t
end

-- "25%", "7%", "1.5%", "0.5%"
local function chanceText(seg): string
	local total = totalWeight()
	local p = total > 0 and math.max(0, tonumber(seg.weight) or 0) / total * 100 or 0
	if p >= 10 then return ("%d%%"):format(math.floor(p + 0.5)) end
	if p >= 1 then return (("%.1f"):format(p):gsub("%.0$", "")) .. "%" end
	return (("%.2f"):format(p):gsub("0$", "")) .. "%"
end

-- the Cash a segment pays this player now (the server's income-scaled amount)
local function cashOf(i: number, seg, st): number
	local v = st and type(st.cash) == "table" and tonumber(st.cash[i])
	if v and v > 0 then return v end
	return tonumber(seg.reward and seg.reward.cash) or 0
end

-- what a slice reads under its icon: "$3K", "10", "SPEED"
local function sliceCaption(i: number, seg, st): string
	if seg.reward and seg.reward.cash and not seg.jackpot then return UILib.moneyShort(cashOf(i, seg, st)) end
	return tostring(seg.short or "")
end

-- one prize piece as text ("+$3K", "SPEED POTION", "15 MIN x3 BOOST", ...)
local function partText(part): string
	local n = tonumber(part.amount) or 0
	if part.kind == "cash" then return "+" .. UILib.moneyShort(n) end
	if part.kind == "tickets" then return "+" .. UILib.commas(n) .. " TICKETS" end
	if part.kind == "potion" then return (n > 1 and (n .. "x ") or "") .. string.upper(tostring(part.name or "Potion")) end
	if part.kind == "boost" then return ("%d MIN x3 BOOST"):format(n) end
	if part.kind == "rcoin" then return "+" .. n .. (n == 1 and " REBIRTH COIN" or " REBIRTH COINS") end
	return string.upper(tostring(part.name or ""))
end

local function partsText(parts, sep: string?): string
	local list = {}
	for _, part in (parts or {}) do table.insert(list, partText(part)) end
	return table.concat(list, sep or " + ")
end

-- the odds list's second line for a segment
local function detailOf(i: number, seg, st): string
	local r = seg.reward or {}
	if seg.jackpot then return partsText(Config.rewardParts(r, cashOf(i, seg, st))) end
	if r.cash then return ("%s - %d min of your income"):format(UILib.moneyShort(cashOf(i, seg, st)), r.minutes or 0) end
	if r.potion then
		local def = Config.rewardPotionDef(r.potion)
		return def and def.stat or "A potion for your stock"
	end
	if r.boostMinutes then return ("x3 Cash on one machine for %d min"):format(r.boostMinutes) end
	if r.rcoins then return "For the Rebirth Shop" end
	if r.tickets then return ("%d Tickets"):format(r.tickets) end
	return ""
end

------------------------------------------------------------------
-- the wheel
------------------------------------------------------------------
-- a point `r` px from the wheel's centre, `deg` clockwise from the top (scale of the stage)
local function at(r: number, deg: number): UDim2
	local a = math.rad(deg)
	return UDim2.fromScale(0.5 + r * math.sin(a) / STAGE, 0.5 - r * math.cos(a) / STAGE)
end

local function sq(px: number): UDim2
	return UDim2.fromScale(px / STAGE, px / STAGE)
end

local CENTER = Vector2.new(0.5, 0.5)

local function buildWheel(stage: Frame, st)
	local list = segments()
	local n = math.max(1, #list)
	local w = 360 / n
	local api = { slices = {}, captions = {}, blur = {}, bulbs = {}, n = n, w = w }

	-- rays + glow behind, the drop shadow and the gold rim
	local rays = UILib.image(stage, UILib.Tex.sunburst, {
		size = UDim2.fromOffset(700, 700), anchor = CENTER, position = UDim2.fromScale(0.5, 0.5),
		color = C.GoldTop, transparency = 0.62, z = 1,
	})
	UILib.spin(rays, 7)
	UILib.image(stage, UILib.Tex.glow, {
		size = UDim2.fromOffset(640, 640), anchor = CENTER, position = UDim2.fromScale(0.5, 0.5),
		color = C.GoldTop, transparency = 0.4, z = 1,
	})
	local shadow = make("Frame", {
		Name = "Shadow", BackgroundColor3 = C.Ink, BorderSizePixel = 0, AnchorPoint = CENTER,
		Position = UDim2.new(0.5, 0, 0.5, 12), Size = sq(2 * R_RIM), ZIndex = 2, Parent = stage,
	})
	UILib.corner(shadow, 999)
	local rim = make("Frame", {
		Name = "Rim", BackgroundColor3 = C.White, BorderSizePixel = 0, AnchorPoint = CENTER,
		Position = UDim2.fromScale(0.5, 0.5), Size = sq(2 * R_RIM), ZIndex = 3, Parent = stage,
	})
	UILib.corner(rim, 999)
	UILib.gradient(rim, C.GoldTop, C.GoldDeep, C.Gold)
	UILib.stroke(rim, C.Ink, 5, true)

	-- the spinning disc: everything on it turns with its Rotation
	local disc = make("Frame", {
		Name = "Disc", BackgroundTransparency = 1, AnchorPoint = CENTER, Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1), ZIndex = 4, Parent = stage,
	})
	api.disc = disc

	-- slices: STRIPS thin strips each, centre to rim, shaded rim -> hub
	local delta = w / STRIPS
	local stripW = 2 * R_FACE * math.tan(math.rad(delta / 2)) + 1
	local rIn = R_HUB - 8
	local stripL = R_FACE - rIn
	local rMid = (R_FACE + rIn) / 2
	for i, seg in list do
		local tone = Tones[seg.tone] or Tones.Gold
		local seq = ColorSequence.new({
			ColorSequenceKeypoint.new(0, UILib.lighten(tone.base, 0.14)),
			ColorSequenceKeypoint.new(0.55, tone.base),
			ColorSequenceKeypoint.new(1, UILib.darken(tone.base, 0.32)),
		})
		local grads = {}
		for j = 0, STRIPS - 1 do
			local deg = (i - 1) * w + (j + 0.5) * delta
			local strip = make("Frame", {
				Name = "Strip", BackgroundColor3 = C.White, BorderSizePixel = 0, AnchorPoint = CENTER,
				Position = at(rMid, deg), Size = UDim2.fromScale(stripW / STAGE, stripL / STAGE), Rotation = deg,
				ZIndex = 1, Parent = disc,
			})
			table.insert(grads, make("UIGradient", { Rotation = 90, Color = seq, Parent = strip }))
		end
		api.slices[i] = { grads = grads, seq = seq, tone = tone }
	end

	-- the lighter inner band
	local light = make("Frame", {
		Name = "Light", BackgroundColor3 = C.White, BackgroundTransparency = 0.8, BorderSizePixel = 0,
		AnchorPoint = CENTER, Position = UDim2.fromScale(0.5, 0.5), Size = sq(2 * R_LIGHT), ZIndex = 2, Parent = disc,
	})
	UILib.corner(light, 999)

	-- gold frets (ink edged) between the slices, a peg at each fret's rim end
	local fretIn = R_HUB - 4
	for i = 1, n do
		local deg = (i - 1) * w
		local fret = make("Frame", {
			Name = "Fret", BackgroundColor3 = C.Ink, BorderSizePixel = 0, AnchorPoint = CENTER,
			Position = at((R_FACE + fretIn) / 2, deg), Size = UDim2.fromScale(FRET_W / STAGE, (R_FACE - fretIn) / STAGE),
			Rotation = deg, ZIndex = 3, Parent = disc,
		})
		make("Frame", {
			Name = "Core", BackgroundColor3 = C.GoldTop, BorderSizePixel = 0, AnchorPoint = CENTER,
			Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(0, 3, 1, -6), ZIndex = 3, Parent = fret,
		})
		local peg = make("Frame", {
			Name = "Peg", BackgroundColor3 = C.White, BorderSizePixel = 0, AnchorPoint = CENTER,
			Position = at(R_FACE - 10, deg), Size = sq(12), ZIndex = 4, Parent = disc,
		})
		UILib.corner(peg, 999)
		UILib.gradient(peg, C.GoldTop, C.GoldDeep)
		UILib.stroke(peg, C.Ink, 2, true)
	end

	-- each slice's prize: icon near the rim, what it pays, its chance
	for i, seg in list do
		local deg = (i - 0.5) * w
		if seg.jackpot then
			local burst = UILib.image(disc, UILib.Tex.sunburst, {
				size = sq(150), anchor = CENTER, position = at(160, deg), rotation = deg, color = C.GoldTop,
				transparency = 0.3, z = 5,
			})
			burst.Name = "JackpotRays"
			UILib.image(disc, UILib.Tex.glow, {
				size = sq(120), anchor = CENTER, position = at(160, deg), color = C.GoldTop, transparency = 0.2, z = 5,
			})
		end
		local icon = UILib.image(disc, seg.icon, {
			size = sq(seg.jackpot and 70 or 62), anchor = CENTER, position = at(163, deg), rotation = deg, z = 6,
		})
		local caption = sliceCaption(i, seg, st)
		local face = UILib.text(disc, {
			name = "Caption", text = caption, size = 18, frameSize = UDim2.fromScale(76 / STAGE, 24 / STAGE),
			anchor = CENTER, position = at(121, deg), rotation = deg, z = 6, stroke = 2.5, shadow = 2,
			gradient = seg.jackpot and { C.White, C.GoldTop } or nil,
		})
		UILib.fitText(face, caption, 18, 60, 10)
		local chance = UILib.text(disc, {
			name = "Chance", text = chanceText(seg), font = F.Number, size = 13,
			frameSize = UDim2.fromScale(52 / STAGE, 17 / STAGE), anchor = CENTER, position = at(90, deg), rotation = deg,
			z = 6, color = seg.jackpot and C.GoldTop or C.White, stroke = 1.5, shadow = 0,
		})
		api.captions[i] = face
		table.insert(api.blur, { img = icon })
		table.insert(api.blur, { text = face })
		table.insert(api.blur, { text = chance })
	end

	-- the ink ring the slices end in (static: above the spinning disc)
	local ring = make("Frame", {
		Name = "Ring", BackgroundTransparency = 1, AnchorPoint = CENTER, Position = UDim2.fromScale(0.5, 0.5),
		Size = sq(2 * R_FACE), ZIndex = 5, Parent = stage,
	})
	UILib.corner(ring, 999)
	UILib.stroke(ring, C.Ink, 5, true)

	-- bulbs around the rim
	for k = 1, BULBS do
		local deg = (k - 0.5) * 360 / BULBS
		local glow = UILib.image(stage, UILib.Tex.glow, {
			size = UDim2.fromOffset(32, 32), anchor = CENTER, position = at(R_BULB, deg), color = C.GoldTop,
			transparency = 0.25, z = 6,
		})
		local b = make("Frame", {
			Name = "Bulb", BackgroundColor3 = C.GoldTop, BorderSizePixel = 0, AnchorPoint = CENTER,
			Position = at(R_BULB, deg), Size = UDim2.fromOffset(13, 13), ZIndex = 6, Parent = stage,
		})
		UILib.corner(b, 999)
		UILib.stroke(b, C.GoldShadow, 2, true)
		api.bulbs[k] = { bulb = b, glow = glow, on = true }
	end

	-- the pointer: a gold diamond hanging under a ruby cap, pivoting on the cap
	local pivot = make("Frame", {
		Name = "Pointer", BackgroundTransparency = 1, AnchorPoint = CENTER, Position = at(R_RIM - 2, 0),
		Size = UDim2.fromOffset(48, 48), ZIndex = 8, Parent = stage,
	})
	local diamond = make("Frame", {
		Name = "Flapper", BackgroundColor3 = C.White, BorderSizePixel = 0, AnchorPoint = CENTER,
		Position = UDim2.new(0.5, 0, 0.5, 30), Size = UDim2.fromOffset(36, 36), Rotation = 45, ZIndex = 8, Parent = pivot,
	})
	UILib.corner(diamond, 6)
	UILib.gradient(diamond, C.GoldTop, C.GoldDeep)
	UILib.stroke(diamond, C.Ink, 4, true)
	local cap = make("Frame", {
		Name = "Cap", BackgroundColor3 = C.White, BorderSizePixel = 0, AnchorPoint = CENTER,
		Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(48, 48), ZIndex = 9, Parent = pivot,
	})
	UILib.corner(cap, 999)
	UILib.gradient(cap, C.CrimsonTop, C.CrimsonDeep)
	UILib.stroke(cap, C.Ink, 4, true)
	local capRing = make("Frame", {
		Name = "Gold", BackgroundTransparency = 1, AnchorPoint = CENTER, Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(32, 32), ZIndex = 9, Parent = cap,
	})
	UILib.corner(capRing, 999)
	UILib.stroke(capRing, C.GoldTop, 2.5, true)
	make("Frame", {
		Name = "Shine", BackgroundColor3 = C.White, BackgroundTransparency = 0.45, BorderSizePixel = 0,
		Position = UDim2.fromScale(0.24, 0.12), Size = UDim2.fromScale(0.36, 0.22), ZIndex = 9, Parent = cap,
	}, { make("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
	api.pointer = pivot

	-- the SPIN hub (static, a button)
	local hub = make("Frame", {
		Name = "Hub", BackgroundTransparency = 1, AnchorPoint = CENTER, Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(2 * R_HUB + 8, 2 * R_HUB + 8), ZIndex = 7, Parent = stage,
	})
	local hubScale = make("UIScale", { Name = "PressScale", Parent = hub }) :: UIScale
	local hubDrop = make("Frame", {
		Name = "Drop", BackgroundColor3 = C.Ink, BorderSizePixel = 0, Position = UDim2.fromOffset(0, 5),
		Size = UDim2.fromScale(1, 1), ZIndex = 7, Parent = hub,
	})
	UILib.corner(hubDrop, 999)
	local hubMover = make("Frame", {
		Name = "Mover", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 7, Parent = hub,
	})
	local hubBody = make("Frame", {
		Name = "Body", BackgroundColor3 = C.White, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 7,
		Parent = hubMover,
	})
	UILib.corner(hubBody, 999)
	UILib.gradient(hubBody, C.GoldTop, C.GoldDeep, C.Gold)
	UILib.stroke(hubBody, C.Ink, 4, true)
	for k = 0, 7 do -- casino-chip notches on the gold ring
		local deg = k * 45 + 22.5
		make("Frame", {
			Name = "Notch", BackgroundColor3 = C.Cream, BorderSizePixel = 0, AnchorPoint = CENTER,
			Position = UDim2.new(0.5, math.sin(math.rad(deg)) * (R_HUB - 3), 0.5, -math.cos(math.rad(deg)) * (R_HUB - 3)),
			Size = UDim2.fromOffset(6, 11), Rotation = deg, ZIndex = 7, Parent = hubBody,
		}, { make("UICorner", { CornerRadius = UDim.new(0, 2) }) })
	end
	local hubFace = make("Frame", {
		Name = "Face", BackgroundColor3 = C.White, BorderSizePixel = 0, AnchorPoint = CENTER,
		Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, -30, 1, -30), ZIndex = 7, Parent = hubBody,
	})
	UILib.corner(hubFace, 999)
	UILib.gradient(hubFace, C.CrimsonTop, C.CrimsonDeep)
	UILib.stroke(hubFace, C.GoldShadow, 2, true)
	make("Frame", {
		Name = "Shine", BackgroundColor3 = C.White, BackgroundTransparency = 0.7, BorderSizePixel = 0,
		Position = UDim2.fromScale(0.2, 0.08), Size = UDim2.fromScale(0.6, 0.28), ZIndex = 7, Parent = hubBody,
	}, { make("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
	local hubLabel = UILib.text(hubFace, {
		name = "Label", text = "SPIN", size = 27, z = 7, stroke = 3, shadow = 3, gradient = { C.White, C.GoldTop },
	})
	local hubClick = make("TextButton", {
		Name = "Click", Text = "", BackgroundTransparency = 1, AutoButtonColor = false, Size = UDim2.fromScale(1, 1),
		ZIndex = 9, Parent = hub,
	}) :: TextButton
	UILib.pressJuice(hubClick, hubScale, hubMover)
	api.hub = { root = hub, label = hubLabel, click = hubClick }

	-- live captions (income-scaled Cash changes)
	function api.setCaptions(state)
		for i, seg in list do
			local face = api.captions[i]
			if face then
				local text = sliceCaption(i, seg, state)
				if face.Text ~= text then UILib.fitText(face, text, 18, 60, 10) end
			end
		end
	end
	return api
end

------------------------------------------------------------------
-- the panel
------------------------------------------------------------------
-- a prize as a toast (when the panel was closed before the wheel stopped)
local function toastPrize(res)
	if type(res) ~= "table" or type(res.prize) ~= "table" then return end
	local prize = res.prize
	local main = type(prize.parts) == "table" and prize.parts[1] or {}
	if prize.jackpot then
		UILib.fx("banner", "MEGA JACKPOT!", partsText(prize.parts), "gold", "jackpot")
		iconToast("MEGA JACKPOT!", "unlock", "Lucky Wheel: " .. partsText(prize.parts), "slot", "Gold")
	else
		iconToast("LUCKY WHEEL!", "unlock", "You won " .. partsText(prize.parts) .. "!", main.icon or "wheel", main.tone)
	end
end

function WheelUI.open()
	local list = segments()
	local p = UILib.panel({ name = "WheelPanel", title = "LUCKY WHEEL", icon = iconName("wheel"),
		width = PANEL_W, height = PANEL_H })
	local content = p.content
	panelOpen = true

	local stage = make("Frame", {
		Name = "Stage", BackgroundTransparency = 1, Position = UDim2.fromOffset(-4, 6),
		Size = UDim2.fromOffset(STAGE, STAGE), Parent = content,
	})
	local wheel = buildWheel(stage, wheelState())
	local w = wheel.w

	-- right column
	local COL_X = STAGE + 14
	local col = make("Frame", {
		Name = "Column", BackgroundTransparency = 1, Position = UDim2.fromOffset(COL_X, 0),
		Size = UDim2.new(1, -COL_X, 1, 0), Parent = content,
	})
	local status = make("Frame", {
		Name = "Status", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.08, Position = UDim2.fromOffset(0, 4),
		Size = UDim2.new(1, 0, 0, 66), Parent = col,
	})
	UILib.corner(status, 20)
	UILib.stroke(status, C.GoldDeep, 3, true)
	UILib.image(status, iconName("wheel"), { size = UDim2.fromOffset(84, 84), position = UDim2.fromOffset(-12, -12), z = 2 })
	local statusTitle = UILib.text(status, {
		text = "NEXT FREE SPIN", size = 17, color = C.GoldTop, xAlign = Enum.TextXAlignment.Left,
		frameSize = UDim2.new(1, -96, 0, 22), position = UDim2.fromOffset(82, 7), stroke = 1.5, shadow = 1,
	})
	local statusValue = UILib.text(status, {
		text = "...", font = F.Number, size = 30, xAlign = Enum.TextXAlignment.Left,
		frameSize = UDim2.new(1, -96, 0, 34), position = UDim2.fromOffset(82, 27), stroke = 3, shadow = 2,
	})

	local spin -- (below)
	local freeBtn = UILib.button({
		parent = col, tone = "Green", text = "SPIN FREE!", icon = "gift", textSize = 28, iconSize = 40,
		size = UDim2.new(1, 0, 0, 62), position = UDim2.fromOffset(0, 82),
		onClick = function() spin("free") end,
	})
	local pair = make("Frame", {
		Name = "Pair", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 154), Size = UDim2.new(1, 0, 0, 56),
		Parent = col,
	})
	local ticketBtn = UILib.button({
		parent = pair, tone = "Pink", text = "SPIN 35", icon = "ticket", textSize = 23, iconSize = 34,
		size = UDim2.new(1, 0, 1, 0), onClick = function() spin("tickets") end,
	})
	local bonusBtn = UILib.button({
		parent = pair, tone = "Purple", text = "BONUS x0", icon = "star", textSize = 23, iconSize = 34,
		size = UDim2.new(0.5, -6, 1, 0), anchor = Vector2.new(1, 0), position = UDim2.fromScale(1, 0),
		onClick = function() spin("bonus") end,
	})
	bonusBtn.Instance.Visible = false
	local robux = deps.RobuxShopUI
	local prod = Config.getProductByKey and Config.getProductByKey("wheel_spins")
	local prodId = prod and tonumber(prod.id) or 0
	local spinsPerPack = prod and tonumber(prod.wheelSpins) or 3
	local priceLabel = "R$ ..."
	local buyBtn = UILib.button({
		parent = col, tone = "Gold", text = ("+%d SPINS"):format(spinsPerPack), icon = "gem", textSize = 22, iconSize = 32,
		size = UDim2.new(1, 0, 0, 50), position = UDim2.fromOffset(0, 220),
		onClick = function()
			if robux and robux.promptProduct then robux.promptProduct(prodId) end
		end,
	})
	buyBtn.Instance.Visible = false
	if robux and robux.priceText then
		robux.priceText(prodId, Enum.InfoType.Product, function(text)
			priceLabel = text
			if p.alive then buyBtn.setText(("+%d SPINS  %s"):format(spinsPerPack, priceLabel)) end
		end)
	end

	-- PRIZES & ODDS
	local oddsHead = UILib.body(col, {
		text = "PRIZES & ODDS", font = F.Display, size = 21, color = C.Crimson, frameSize = UDim2.new(0, 210, 0, 24),
		position = UDim2.fromOffset(2, 280),
	})
	UILib.pad(oddsHead, 40, 0, 0, 0)
	UILib.image(oddsHead, iconName("chance"), {
		size = UDim2.fromOffset(34, 34), anchor = Vector2.new(0, 0.5), position = UDim2.new(0, -40, 0.5, -1), z = 2,
	})
	local oddsNote = UILib.body(col, {
		text = "Chances per spin", size = 12, transparency = 0.25,
		xAlign = Enum.TextXAlignment.Right, frameSize = UDim2.new(1, -214, 0, 24), position = UDim2.fromOffset(212, 280),
	})
	local odds = UILib.scroller(col, { padding = 6, size = UDim2.new(1, 0, 0, 220), position = UDim2.fromOffset(0, 306) })
	local order = {}
	for i in list do table.insert(order, i) end
	table.sort(order, function(a, b)
		local wa, wb = tonumber(list[a].weight) or 0, tonumber(list[b].weight) or 0
		if wa ~= wb then return wa > wb end
		return a < b
	end)
	local details = {}
	for rank, i in order do
		local seg = list[i]
		local tone = Tones[seg.tone] or Tones.Gold
		local row = make("Frame", {
			Name = "Odds_" .. tostring(seg.id), BackgroundColor3 = C.Cream, Size = UDim2.new(1, -4, 0, 44),
			LayoutOrder = rank, Parent = odds,
		})
		UILib.corner(row, 14)
		UILib.stroke(row, C.Ink, 2.5, true)
		if seg.jackpot then UILib.gradient(row, C.GoldTop, C.Gold) end
		local tile = make("Frame", {
			Name = "Tile", BackgroundColor3 = C.White, Position = UDim2.fromOffset(6, 5), Size = UDim2.fromOffset(34, 34),
			Parent = row,
		})
		UILib.corner(tile, 10)
		UILib.gradient(tile, tone.top, tone.base)
		UILib.stroke(tile, C.Ink, 2, true)
		UILib.image(tile, seg.icon, {
			size = UDim2.fromScale(1.15, 1.15), anchor = CENTER, position = UDim2.fromScale(0.5, 0.5),
		})
		UILib.body(row, {
			text = string.upper(tostring(seg.name or seg.id)), font = F.Display, size = 16, color = C.Crimson,
			frameSize = UDim2.new(1, -124, 0, 20), position = UDim2.fromOffset(48, 3),
		})
		details[i] = UILib.body(row, {
			text = detailOf(i, seg, wheelState()), size = 12, frameSize = UDim2.new(1, -124, 0, 16),
			position = UDim2.fromOffset(48, 23),
		})
		local pill = make("Frame", {
			Name = "Chance", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.05, AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.fromOffset(64, 28), Parent = row,
		})
		UILib.corner(pill, 999)
		UILib.stroke(pill, C.GoldDeep, 2, true)
		UILib.text(pill, {
			text = chanceText(seg), font = F.Number, size = 16, color = seg.jackpot and C.GoldTop or C.White,
			stroke = 1.5, shadow = 1,
		})
	end

	------------------------------------------------------------------
	-- the spin animation
	------------------------------------------------------------------
	local rot = 0                 -- the disc's rotation (deg, keeps counting up)
	local omega = 0               -- deg/s
	local mode = "idle"           -- idle | windup | accel | cruise | decel
	local windFrom, windT0, accT0 = 0, 0, 0
	local plan = nil              -- decel: { t0, T, from, D, p }
	local result = nil            -- the server's answer, waiting for the cruise
	local resAt = 0               -- os.clock() it arrived
	local landing = nil           -- what the decel lands on: { res, index } | { failed, res }
	local pendingRes, pendingAt = nil, 0  -- a won prize not shown yet + when it lands (os.clock)
	local busy = false
	local tickIdx = math.floor(rot / w)
	local kick = 0
	local bulbStep = 0
	local flashUntil = 0
	local blurred = false
	local revealCard = nil

	local function setBlur(on: boolean)
		if on == blurred then return end
		blurred = on
		for _, b in wheel.blur do
			if b.img then UILib.tween(b.img, { ImageTransparency = on and 0.45 or 0 }, 0.25) end
			if b.text then UILib.tween(b.text, { TextTransparency = on and 0.7 or 0 }, 0.25) end
		end
	end

	local function setBulb(b, on: boolean)
		if b.on == on then return end
		b.on = on
		b.bulb.BackgroundColor3 = on and C.GoldTop or C.GoldDeep
		b.glow.Visible = on
	end

	local function hideReveal()
		local card = revealCard
		if not card then return end
		revealCard = nil
		UILib.tween(card.scale, { Scale = 0.01 }, 0.18, Enum.EasingStyle.Back, Enum.EasingDirection.In)
		task.delay(0.2, function() card.root:Destroy() end)
	end

	local function blinkSlice(i: number)
		local sl = wheel.slices[i]
		if not sl then return end
		local bright = ColorSequence.new(UILib.lighten(sl.tone.base, 0.65), UILib.lighten(sl.tone.base, 0.3))
		task.spawn(function()
			for _ = 1, 4 do
				for _, g in sl.grads do g.Color = bright end
				task.wait(0.14)
				for _, g in sl.grads do g.Color = sl.seq end
				task.wait(0.14)
			end
		end)
	end

	local function reveal(res, i: number)
		hideReveal()
		local seg = list[i] or {}
		local prize = type(res.prize) == "table" and res.prize or {}
		local parts = type(prize.parts) == "table" and prize.parts or {}
		local main = parts[1] or { kind = "", icon = seg.icon, name = seg.name }
		local jackpot = prize.jackpot == true
		local tone = jackpot and Tones.Gold or (Tones[seg.tone] or Tones.Gold)
		local root = make("Frame", {
			Name = "Reveal", BackgroundTransparency = 1, AnchorPoint = CENTER, Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(340, 254), ZIndex = 20, Parent = stage,
		})
		local scale = make("UIScale", { Scale = 0.2, Parent = root }) :: UIScale
		local rays = UILib.image(root, UILib.Tex.sunburst, {
			size = UDim2.fromOffset(470, 470), anchor = CENTER, position = UDim2.fromScale(0.5, 0.45), color = C.GoldTop,
			transparency = 0.3, z = 19,
		})
		UILib.spin(rays, 30)
		local shadowF = make("Frame", {
			Name = "Shadow", BackgroundColor3 = C.Ink, BorderSizePixel = 0, Position = UDim2.fromOffset(0, 9),
			Size = UDim2.fromScale(1, 1), ZIndex = 20, Parent = root,
		})
		UILib.corner(shadowF, 26)
		local body = make("Frame", {
			Name = "Body", BackgroundColor3 = C.White, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 21,
			Parent = root,
		})
		UILib.corner(body, 26)
		UILib.gradient(body, tone.top, tone.base)
		UILib.stroke(body, C.Ink, 5, true)
		local trim = make("Frame", {
			Name = "Trim", BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 8), Size = UDim2.new(1, -16, 1, -16),
			ZIndex = 21, Parent = body,
		})
		UILib.corner(trim, 20)
		UILib.stroke(trim, C.GoldTop, 2.5, true, 0.1)
		UILib.text(body, {
			text = jackpot and "MEGA JACKPOT!" or "YOU WON!", size = 36, frameSize = UDim2.new(1, -20, 0, 42),
			position = UDim2.fromOffset(10, 12), z = 22, stroke = 4, shadow = 4, gradient = { C.White, C.GoldTop },
		})
		local icons = jackpot and math.min(#parts, 3) or 1
		local big = jackpot and 76 or 112
		local span = icons * big + (icons - 1) * 18
		local firstIcon = nil
		for k = 1, icons do
			local part = parts[k] or main
			local img = UILib.image(body, part.icon or seg.icon, {
				size = UDim2.fromOffset(big, big), anchor = CENTER,
				position = UDim2.new(0.5, -span / 2 + (k - 1) * (big + 18) + big / 2, 0, 116), z = 22,
			})
			firstIcon = firstIcon or img
			UILib.fx("pop", img, 1.3)
		end
		local text = jackpot and partsText(parts, "  +  ") or partText(main)
		local face = UILib.text(body, {
			text = text, size = 26, frameSize = UDim2.new(1, -24, 0, 34), position = UDim2.fromOffset(12, 180), z = 22,
			stroke = 3, shadow = 3,
		})
		UILib.fitText(face, text, jackpot and 22 or 28, 310, 12)
		UILib.body(body, {
			text = "Tap to close", size = 12, color = C.White, transparency = 0.25, xAlign = Enum.TextXAlignment.Center,
			frameSize = UDim2.new(1, 0, 0, 16), position = UDim2.new(0, 0, 1, -26), z = 22,
		})
		local click = make("TextButton", {
			Name = "Click", Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 25, Parent = root,
		})
		click.Activated:Connect(hideReveal)
		UILib.tween(scale, { Scale = 1 }, 0.42, Enum.EasingStyle.Back)
		local card = { root = root, scale = scale }
		revealCard = card
		task.delay(jackpot and 4.6 or 3.4, function()
			if revealCard == card then hideReveal() end
		end)

		-- juice: the coins of a Cash prize fly from here when the server pays it (UXFX
		-- reads lastPress); the toast gives the ka-ching + confetti
		local centre = stage.AbsolutePosition + stage.AbsoluteSize / 2
		UILib.lastPress = { gui = firstIcon or root, at = centre, t = os.clock() }
		local kind = (main.kind == "cash" and not jackpot) and "income" or (main.kind == "tickets" and "ticket" or "unlock")
		if jackpot then
			UILib.fx("banner", "MEGA JACKPOT!", partsText(parts), "gold", "jackpot")
			UILib.fx("flash", C.GoldTop, 0.6)
			UILib.fx("punch", 0.7)
			UILib.fx("confetti", root, 72, "show")
			UILib.fx("sparkle", root, 10, C.GoldTop)
			iconToast("MEGA JACKPOT!", "unlock", "Lucky Wheel: " .. partsText(parts), "slot", "Gold")
		else
			UILib.fx("sound", main.kind == "rcoin" and "fanfare" or "kaching")
			UILib.fx("confetti", root, 44, main.kind == "cash" and "money" or (main.kind == "tickets" and "ticket" or "show"))
			UILib.fx("sparkle", root, 6, C.White)
			iconToast("LUCKY WHEEL!", kind, "You won " .. partsText(parts) .. "!", main.icon or seg.icon, main.tone or seg.tone)
		end
	end

	local refresh -- (below)

	local function onLanded()
		local L = landing
		landing = nil
		busy = false
		flashUntil = os.clock() + 1.3
		if not L then return end
		if L.failed then
			local res = L.res
			UILib.toast((type(res) == "table" and res.message) or "The wheel jammed - try again.", "error")
		else
			pendingRes = nil
			blinkSlice(L.index)
			reveal(L.res, L.index)
		end
		if refresh then refresh() end
		-- the buttons come back the moment the server has paid
		task.delay(math.max(0, lockUntil - os.clock()) + 0.05, function()
			if refresh then refresh() end
		end)
	end

	local function startDecel(now: number)
		local res = result
		result = nil
		if type(res) ~= "table" or not res.ok or not list[tonumber(res.index) or 0] then
			-- no prize: coast to a stop
			local T = 1.1
			plan = { t0 = now, T = T, from = rot, D = math.max(1, omega * T / 2), p = 2 }
			landing = { failed = true, res = res }
			mode = "decel"
			return
		end
		local index = tonumber(res.index) :: number
		local T = math.max(2.2, pendingAt - 0.25 - now) -- land just before the server pays
		local jitter = (math.random() - 0.5) * 0.7 * w -- anywhere in the middle 70% of the slice
		local want = -((index - 0.5) * w + jitter) % 360
		local D0 = omega * T / 3
		local D = D0 + ((want - (rot + D0)) % 360)
		plan = { t0 = now, T = T, from = rot, D = D, p = omega * T / D }
		landing = { res = res, index = index }
		mode = "decel"
	end

	local function step(dt: number)
		if not p.alive then return end
		dt = math.min(dt, 0.1)
		local now = os.clock()
		if mode == "windup" then
			local u = math.min(1, (now - windT0) / WINDUP)
			rot = windFrom - 16 * math.sin(u * math.pi / 2)
			omega = 0
			if u >= 1 then
				mode = "accel"
				accT0 = now
			end
		elseif mode == "accel" then
			local u = math.min(1, (now - accT0) / ACCEL)
			omega = OMEGA * u * u
			rot += omega * dt
			if u >= 1 then mode = "cruise" end
		elseif mode == "cruise" then
			omega = OMEGA
			rot += omega * dt
			if result ~= nil then startDecel(now) end
		elseif mode == "decel" and plan then
			local u = math.min(1, (now - plan.t0) / plan.T)
			rot = plan.from + plan.D * (1 - (1 - u) ^ plan.p)
			omega = plan.D * plan.p / plan.T * (1 - u) ^ (plan.p - 1)
			if u >= 1 then
				rot = plan.from + plan.D
				omega = 0
				mode = "idle"
				plan = nil
				task.spawn(onLanded)
			end
		end
		wheel.disc.Rotation = rot % 360
		setBlur(omega > 650)

		-- a peg passes the pointer: tick + kick
		local idx = math.floor(rot / w)
		if idx ~= tickIdx then
			tickIdx = idx
			kick = 1
			UILib.fx("sound", "tick", 1.2 + math.random() * 0.25, omega > 500 and 0.4 or 1)
		end
		kick = math.max(0, kick - dt * (omega > 500 and 3 or 8))
		wheel.pointer.Rotation = -24 * kick

		-- bulbs: flash on the stop, chase with the speed, idle twinkle
		if now < flashUntil then
			local on = math.floor(now * 9) % 2 == 0
			for _, b in wheel.bulbs do setBulb(b, on) end
		elseif mode ~= "idle" then
			bulbStep += math.min(omega, 700) * dt / 24
			local ph = math.floor(bulbStep)
			for k, b in wheel.bulbs do setBulb(b, (k + ph) % 4 < 2) end
		else
			local ph = math.floor(now / 0.45) % 2
			for k, b in wheel.bulbs do setBulb(b, (k + ph) % 2 == 0) end
		end
	end
	local conn = RunService.RenderStepped:Connect(step)

	-- one spin: "free" | "tickets" | "bonus"
	spin = function(kind: string)
		if busy or os.clock() < lockUntil then return end
		local st = wheelState()
		if not st then
			UILib.toast("The wheel is warming up...", "info")
			return
		end
		if st.spinning then
			UILib.toast("The wheel is still spinning!", "info")
			return
		end
		if kind == "free" and freeIn(st) > 0 then
			UILib.toast("FREE SPIN IN " .. UILib.clock(freeIn(st)), "info", "Spin for Tickets or use a bonus spin meanwhile.")
			return
		end
		if kind == "tickets" then
			local cost = tonumber(st.ticketCost) or 35
			local have = tonumber(UILib.state.tickets) or 0
			if have < cost then
				UILib.toast("NOT ENOUGH TICKETS", "error",
					("You need %d more - earn them from the Daily Reward and Playtime."):format(cost - have))
				return
			end
		end
		if kind == "bonus" and (tonumber(st.spins) or 0) < 1 then return end
		busy = true
		hideReveal()
		windFrom, windT0 = rot, os.clock()
		mode = "windup"
		result = nil
		UILib.fx("sound", "pop", 0.85)
		if refresh then refresh() end
		task.spawn(function()
			local ok, res = pcall(function() return Remotes.SpinWheel():InvokeServer(kind) end)
			if not ok or type(res) ~= "table" then res = { ok = false, message = "Can't reach the wheel - try again." } end
			resAt = os.clock()
			if res.ok then
				pendingRes = res
				pendingAt = resAt + (tonumber(res.revealIn) or 5.5)
				lockUntil = pendingAt
			end
			if p.alive then
				result = res
			else
				busy = false
				if res.ok then task.delay(math.max(0, pendingAt - os.clock()), toastPrize, res) end
			end
		end)
	end

	wheel.hub.click.Activated:Connect(function()
		local st = wheelState()
		if busy then return end
		if st and freeIn(st) <= 0 then
			spin("free")
		elseif st and (tonumber(st.spins) or 0) > 0 then
			spin("bonus")
		else
			UILib.fx("shake", wheel.hub.root, 0.8)
			UILib.toast("NO FREE SPIN YET", "info", "Spin with Tickets below, or wait for your free spin.")
		end
	end)

	-- buttons + texts from the live state (snapshot pushes + 1 Hz)
	local lastCash = nil
	refresh = function()
		if not p.alive then return end
		local st = wheelState()
		local fin = freeIn(st)
		local freeReady = st ~= nil and fin <= 0
		local locked = busy or os.clock() < lockUntil or (st ~= nil and st.spinning == true)
		if not st then
			statusTitle.Text = "LUCKY WHEEL"
			statusValue.Text = "LOADING..."
		elseif freeReady then
			statusTitle.Text = "FREE SPIN READY!"
			statusValue.Text = "SPIN NOW!"
		else
			statusTitle.Text = "NEXT FREE SPIN IN"
			statusValue.Text = UILib.clock(fin)
		end
		freeBtn.setText(freeReady and "SPIN FREE!" or (st and ("FREE IN " .. UILib.clock(fin)) or "LOADING..."))
		freeBtn.setTone(freeReady and "Green" or "Blue")
		freeBtn.setEnabled(freeReady and not locked)
		local cost = st and tonumber(st.ticketCost) or (Config.LuckyWheel and Config.LuckyWheel.TicketCost) or 35
		local have = tonumber(UILib.state.tickets) or 0
		ticketBtn.setText(("SPIN %d"):format(cost))
		ticketBtn.setTone(have >= cost and "Pink" or "Red")
		ticketBtn.setEnabled(st ~= nil and not locked)
		local spins = st and math.max(0, math.floor(tonumber(st.spins) or 0)) or 0
		bonusBtn.Instance.Visible = spins > 0
		bonusBtn.setText(("BONUS x%d"):format(spins))
		bonusBtn.setEnabled(not locked)
		ticketBtn.Instance.Size = spins > 0 and UDim2.new(0.5, -6, 1, 0) or UDim2.new(1, 0, 1, 0)
		local canBuy = st ~= nil and st.canBuy == true and robux ~= nil
		buyBtn.Instance.Visible = canBuy
		buyBtn.setText(("+%d SPINS  %s"):format(spinsPerPack, priceLabel))
		-- the odds list fills what the buttons leave
		local y = canBuy and 280 or 222
		oddsHead.Position = UDim2.fromOffset(2, y)
		oddsNote.Position = UDim2.fromOffset(212, y)
		odds.Position = UDim2.fromOffset(0, y + 26)
		odds.Size = UDim2.new(1, 0, 0, 530 - (y + 26))
		-- income-scaled Cash on the slices + the odds
		local sig = st and type(st.cash) == "table" and table.concat(st.cash, ",") or ""
		if sig ~= lastCash then
			lastCash = sig
			wheel.setCaptions(st)
			for i, lbl in details do lbl.Text = detailOf(i, list[i], st) end
		end
	end

	local unsub = UILib.subscribe(function() refresh() end)
	task.spawn(function()
		while p.alive do
			refresh()
			task.wait(1)
		end
	end)
	p.onClose(function()
		panelOpen = false
		conn:Disconnect()
		unsub()
		-- a prize still on its way: tell the player when it lands
		if pendingRes then
			local res = pendingRes
			pendingRes = nil
			task.delay(math.max(0, pendingAt - os.clock()), toastPrize, res)
		end
	end)
	refresh()
end

------------------------------------------------------------------
-- the HUD tile (1 Hz): timer pill + alert, "free spin ready" / "+3 spins" toasts
------------------------------------------------------------------
function WheelUI.start(d)
	deps = type(d) == "table" and d or {}
	if started then return end
	started = true
	local Hud = deps.HudUI
	local tile = nil
	local wasFree = nil
	local lastSpins = nil

	local function ensureTile()
		if tile or not (Hud and type(Hud.addRailTile) == "function") then return end
		tile = Hud.addRailTile({
			id = "wheel", label = "SPIN", icon = iconName("wheel"), tone = "Gold", order = 20,
			onClick = function() WheelUI.open() end,
		})
	end

	-- the tile appears with the first snapshot that has a wheel (no wheel on the server = no tile)
	UILib.subscribe(function(state)
		local st = type(state) == "table" and state.wheel
		if type(st) ~= "table" then return end
		ensureTile()
		local spins = math.max(0, math.floor(tonumber(st.spins) or 0))
		if lastSpins and spins > lastSpins then
			local more = spins - lastSpins
			iconToast(("+%d LUCKY SPIN%s!"):format(more, more == 1 and "" or "S"), "unlock",
				"Tap SPIN to use " .. (more == 1 and "it." or "them."), "wheel", "Purple")
			if tile and tile.Instance then UILib.fx("pop", tile.Instance, 1.18) end
		end
		lastSpins = spins
	end)

	task.spawn(function()
		while true do
			local st = wheelState()
			if tile and st then
				local fin = freeIn(st)
				local free = fin <= 0
				tile.setText(free and "FREE!" or UILib.clock(fin))
				tile.setAlert(free or (tonumber(st.spins) or 0) > 0)
				if wasFree == false and free and not panelOpen then
					iconToast("FREE SPIN READY!", "info", "Your Lucky Wheel spin is waiting - tap SPIN!", "wheel", "Gold")
					if tile.Instance then UILib.fx("pop", tile.Instance, 1.18) end
				end
				wasFree = free
			end
			task.wait(1)
		end
	end)
end

return WheelUI
