--!nonstrict
-- GuestTags.luau — the Showtime tag over every guest's head (GUESTS package). The
-- server only sets attributes on the guest's model (NPCs.luau initGuestTag + runPatron,
-- Cheaters.luau); this draws them, locally:
--   Wallet (whole $)   WalletNote ("stand" | "tip")   GuestTier ("vip")   GuestName
--   CasinoOwner        OnVipFloor                     Suspect   Busted ("owner" | "security")   Kicked
-- The tag: a compact velvet pill (crimson -> ink, gold rim, glossy band) with the 3D coin
-- and a gold-gradient amount with an ink outline ("$1.2K").
--   VIP      purple velvet, a thicker gold rim, the crown, the friend's name above
--   suspect  a bobbing red "?" badge on the corner + a red rim (your own casino's suspects
--            show from across the floor)
--   BUSTED   a crimson stamp "BUSTED!" / "CAUGHT!" with the handcuffs, slammed on
--   KICKED   grey, "KICKED OUT" (an honest guest thrown out)
--   x1.25    a small gold chip in the pill while they play on the VIP floor
-- When the wallet changes, a tiny "+$12" / "-$30" ("TIP $5" gold, stand snacks orange)
-- floats out of the pill and the pill bumps (only near the camera).
-- Light: one BillboardGui per guest under its Head (so BuildingView cuts it away with
-- the stories above you), AlwaysOnTop, distance-limited (MaxDistance); the size is studs +
-- pixels (small up close, still readable far off). Works with StreamingEnabled (guests
-- are tracked by their "CasinoPatron" tag as they stream in and out). Never touches the
-- tag's Enabled (BuildingView owns it).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local F = UILib.Fonts

local GuestTags = {}
local player = Players.LocalPlayer

local TAG = "CasinoPatron"
local RANGE = 72                          -- studs: a tag shows within this distance of the camera
local SUSPECT_RANGE = 180                 -- your own casino's suspects: from across the floor
local BUSTED_RANGE = 130
local POP_RANGE = 46                      -- the wallet pops / bumps only this close
local SIZE = UDim2.new(2.5, 34, 1.4, 18)  -- studs + px
local OFFSET = Vector3.new(0, 2.2, 0)     -- above the head's centre

local hex = Color3.fromHex
local LOOKS = {
	-- body gradient top / bottom, rim colour + thickness, icon, text gradient
	normal  = { top = hex("#9A1C38"), bottom = hex("#33071A"), rim = C.Gold, rimW = 2, icon = "coin" },
	vip     = { top = hex("#A46BFF"), bottom = hex("#35106F"), rim = C.GoldTop, rimW = 2.6, icon = "crown" },
	suspect = { top = hex("#9A1C38"), bottom = hex("#33071A"), rim = C.CrimsonTop, rimW = 2.6, icon = "coin" },
	busted  = { top = C.CrimsonTop, bottom = C.CrimsonDeep, rim = C.White, rimW = 2.6, icon = "handcuffs" },
	kicked  = { top = hex("#A69BA0"), bottom = hex("#4A3F45"), rim = C.CreamLine, rimW = 2, icon = nil },
}
local ICON_FALLBACK = { handcuffs = "lock", cheater = "staff" }
local POP_COLORS = { gain = C.GreenTop, loss = C.CrimsonTop, tip = C.GoldTop, stand = C.OrangeTop }

local tags = {}  -- guest model -> tag state (false while it's being built)

------------------------------------------------------------------
-- helpers
------------------------------------------------------------------
local function icon(name: string?): string
	if not name then return "" end
	local id = UILib.resolveIcon(name)
	if id == "" and ICON_FALLBACK[name] then id = UILib.resolveIcon(ICON_FALLBACK[name]) end
	return id
end

-- "$950", "$1.2K", "$12.3K", "$123K", "$1.2M" (rounded down: never more than they have)
local UNITS = { "K", "M", "B", "T", "Qa" }
local function money(n: number): string
	n = math.max(0, math.floor(tonumber(n) or 0))
	if n < 1000 then return "$" .. tostring(n) end
	local v, i = n / 1000, 1
	while v >= 1000 and i < #UNITS do
		v /= 1000
		i += 1
	end
	local s
	if v < 100 then
		s = (string.format("%.1f", math.floor(v * 10) / 10):gsub("%.0$", ""))
	else
		s = tostring(math.floor(v))
	end
	return "$" .. s .. UNITS[i]
end
GuestTags.money = money

local function make(class: string, props)
	return UILib.make(class, props)
end

local function cameraDistance(part: BasePart): number
	local cam = Workspace.CurrentCamera
	return cam and (cam.CFrame.Position - part.Position).Magnitude or math.huge
end

------------------------------------------------------------------
-- building one tag
------------------------------------------------------------------
local function build(model: Model, head: BasePart)
	local bb = make("BillboardGui", {
		Name = "GuestTag", Adornee = head, Size = SIZE, StudsOffset = OFFSET, AlwaysOnTop = true,
		LightInfluence = 0, MaxDistance = RANGE, ClipsDescendants = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	-- the pill (bottom half; the top half is for the name, the badge and the pops)
	local pill = make("Frame", {
		Name = "Pill", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -2),
		Size = UDim2.fromScale(0.84, 0.52), BackgroundColor3 = C.White, BorderSizePixel = 0, ZIndex = 2, Parent = bb,
	})
	UILib.corner(pill, 999)
	local body = make("UIGradient", { Rotation = 90, Parent = pill })
	local rim = make("UIStroke", {
		Color = C.Gold, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		LineJoinMode = Enum.LineJoinMode.Round, Parent = pill,
	})
	local bump = make("UIScale", { Name = "Bump", Scale = 1, Parent = pill })
	local shine = make("Frame", {
		Name = "Shine", Position = UDim2.fromScale(0.1, 0.1), Size = UDim2.fromScale(0.8, 0.34),
		BackgroundColor3 = C.White, BackgroundTransparency = 0.84, BorderSizePixel = 0, ZIndex = 3, Parent = pill,
	})
	UILib.corner(shine, 999)
	local ico = make("ImageLabel", {
		Name = "Icon", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.07, 0.48),
		Size = UDim2.fromScale(1.55, 1.55), SizeConstraint = Enum.SizeConstraint.RelativeYY,
		BackgroundTransparency = 1, ScaleType = Enum.ScaleType.Fit, Image = icon("coin"), ZIndex = 5, Parent = pill,
	})
	local amount = make("TextLabel", {
		Name = "Amount", BackgroundTransparency = 1, Position = UDim2.fromScale(0.22, 0.1),
		Size = UDim2.fromScale(0.72, 0.8), Font = F.Number, TextScaled = true, Text = "$0",
		TextColor3 = C.White, ZIndex = 4, Parent = pill,
	})
	make("UIGradient", { Rotation = 90, Color = ColorSequence.new(C.GoldTop, C.Gold), Parent = amount })
	make("UIStroke", { Color = C.Ink, Thickness = 1.6, LineJoinMode = Enum.LineJoinMode.Round, Parent = amount })
	-- BUSTED! / CAUGHT! / KICKED OUT (the amount's place)
	local stamp = make("TextLabel", {
		Name = "Stamp", BackgroundTransparency = 1, Position = UDim2.fromScale(0.2, 0.06),
		Size = UDim2.fromScale(0.76, 0.88), Font = F.Display, TextScaled = true, Text = "",
		TextColor3 = C.White, Visible = false, ZIndex = 4, Parent = pill,
	})
	make("UIStroke", { Color = C.Ink, Thickness = 1.8, LineJoinMode = Enum.LineJoinMode.Round, Parent = stamp })
	-- x1.25: playing on the VIP floor
	local chip = make("Frame", {
		Name = "VipChip", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(0.95, 0.5),
		Size = UDim2.fromScale(0.3, 0.66), BackgroundColor3 = C.White, Visible = false, ZIndex = 5, Parent = pill,
	})
	UILib.corner(chip, 999)
	UILib.gradient(chip, C.GoldTop, C.GoldDeep)
	make("UIStroke", { Color = C.Ink, Thickness = 1.2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = chip })
	make("TextLabel", {
		Name = "Text", BackgroundTransparency = 1, Position = UDim2.fromScale(0.08, 0.08),
		Size = UDim2.fromScale(0.84, 0.84), Font = F.Number, TextScaled = true, Text = "x1.25",
		TextColor3 = C.Ink, ZIndex = 6, Parent = chip,
	})
	-- a VIP's name over the pill
	local name = make("TextLabel", {
		Name = "Name", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 0.47), Size = UDim2.fromScale(0.96, 0.26), Font = F.Heavy, TextScaled = true,
		Text = "", TextColor3 = C.White, Visible = false, ZIndex = 3, Parent = bb,
	})
	make("UIGradient", { Rotation = 90, Color = ColorSequence.new(C.White, C.PurpleTop), Parent = name })
	make("UIStroke", { Color = C.Ink, Thickness = 1.4, LineJoinMode = Enum.LineJoinMode.Round, Parent = name })
	-- the suspect's red "?" (bobs on the pill's corner)
	local badge = make("Frame", {
		Name = "Suspect", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.9, 0.42),
		Size = UDim2.fromScale(0.5, 0.5), SizeConstraint = Enum.SizeConstraint.RelativeYY,
		BackgroundColor3 = C.White, Visible = false, ZIndex = 7, Parent = bb,
	})
	UILib.corner(badge, 999)
	UILib.gradient(badge, C.CrimsonTop, C.CrimsonDeep)
	make("UIStroke", { Color = C.Ink, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = badge })
	local q = make("TextLabel", {
		Name = "Q", BackgroundTransparency = 1, Position = UDim2.fromScale(0.1, 0.06), Size = UDim2.fromScale(0.8, 0.84),
		Font = F.Display, TextScaled = true, Text = "?", TextColor3 = C.White, ZIndex = 8, Parent = badge,
	})
	make("UIStroke", { Color = C.Ink, Thickness = 1.6, Parent = q })
	bb.Parent = head
	return {
		model = model, head = head, bb = bb, pill = pill, body = body, rim = rim, bump = bump, icon = ico,
		amount = amount, stamp = stamp, chip = chip, name = name, badge = badge,
		variant = nil, wallet = nil, tweens = {}, pop = nil,
	}
end

------------------------------------------------------------------
-- variants
------------------------------------------------------------------
local function stopTweens(state)
	for _, tw in state.tweens do tw:Cancel() end
	table.clear(state.tweens)
end

local function loop(state, inst: Instance, info: TweenInfo, props)
	local tw = TweenService:Create(inst, info, props)
	table.insert(state.tweens, tw)
	tw:Play()
	return tw
end

local function variantOf(m: Model): string
	if m:GetAttribute("Busted") then return "busted" end
	if m:GetAttribute("Kicked") == true then return "kicked" end
	if m:GetAttribute("Suspect") == true then return "suspect" end
	if m:GetAttribute("GuestTier") == "vip" then return "vip" end
	return "normal"
end

local function applyVariant(state, variant: string)
	local was = state.variant
	state.variant = variant
	local look = LOOKS[variant] or LOOKS.normal
	stopTweens(state)
	state.body.Color = ColorSequence.new(look.top, look.bottom)
	state.rim.Color = look.rim
	state.rim.Thickness = look.rimW
	state.icon.Image = icon(look.icon)
	state.icon.Visible = look.icon ~= nil
	state.icon.Rotation = 0
	state.pill.Rotation = 0
	state.bump.Scale = 1
	local stamped = variant == "busted" or variant == "kicked"
	state.amount.Visible = not stamped
	state.stamp.Visible = stamped
	state.badge.Visible = variant == "suspect"
	state.badge.Position = UDim2.fromScale(0.9, 0.42)
	state.badge.Rotation = 0
	if variant == "busted" then
		state.stamp.Text = state.model:GetAttribute("Busted") == "security" and "CAUGHT!" or "BUSTED!"
		state.stamp.TextColor3 = C.White
		state.stamp.Position = UDim2.fromScale(0.24, 0.06)
		state.stamp.Size = UDim2.fromScale(0.72, 0.88)
		-- slammed on like a rubber stamp
		state.pill.Rotation = -5
		state.bump.Scale = 1.7
		TweenService:Create(state.bump, TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = 1 }):Play()
		loop(state, state.icon, TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Rotation = 14 })
	elseif variant == "kicked" then
		state.stamp.Text = "KICKED OUT"
		state.stamp.TextColor3 = C.Cream
		state.stamp.Position = UDim2.fromScale(0.1, 0.12)
		state.stamp.Size = UDim2.fromScale(0.8, 0.76)
	elseif variant == "suspect" then
		-- the "?" bobs and wiggles; the rim flashes red / gold
		if was ~= "suspect" then
			state.badge.Size = UDim2.fromScale(0.05, 0.05)
			TweenService:Create(state.badge, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Size = UDim2.fromScale(0.5, 0.5) }):Play()
		end
		loop(state, state.badge, TweenInfo.new(0.42, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Position = UDim2.fromScale(0.9, 0.3) })
		loop(state, state.rim, TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Color = C.Gold })
	end
end

-- range, chip and name (cheap: on every attribute change that matters)
local function refresh(state)
	local m = state.model
	local variant = variantOf(m)
	if variant ~= state.variant then applyVariant(state, variant) end
	local stamped = variant == "busted" or variant == "kicked"
	local onVip = m:GetAttribute("OnVipFloor") == true and not stamped
	state.chip.Visible = onVip
	state.amount.Size = onVip and UDim2.fromScale(0.5, 0.8) or UDim2.fromScale(0.72, 0.8)
	local guestName = m:GetAttribute("GuestName")
	local showName = variant == "vip" and type(guestName) == "string" and guestName ~= ""
	state.name.Visible = showName
	if showName then state.name.Text = guestName end
	local mine = m:GetAttribute("CasinoOwner") == player.UserId
	state.bb.MaxDistance = (variant == "suspect" and mine) and SUSPECT_RANGE
		or (variant == "busted" and BUSTED_RANGE) or RANGE
end

------------------------------------------------------------------
-- the wallet + its little pop
------------------------------------------------------------------
local function pop(state, delta: number, note: string?)
	if state.pop then state.pop:Destroy() end
	local kind, text
	if note == "tip" and delta < 0 then
		kind, text = "tip", "TIP " .. money(-delta)
	elseif note == "stand" and delta < 0 then
		kind, text = "stand", "-" .. money(-delta)
	elseif delta > 0 then
		kind, text = "gain", "+" .. money(delta)
	else
		kind, text = "loss", "-" .. money(-delta)
	end
	local label = make("TextLabel", {
		Name = "Pop", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.64, 0.5), Size = UDim2.fromScale(0.62, 0.3), Font = F.Number,
		TextScaled = true, Text = text, TextColor3 = POP_COLORS[kind], ZIndex = 9, Parent = state.bb,
	})
	local outline = make("UIStroke", { Color = C.Ink, Thickness = 1.5, LineJoinMode = Enum.LineJoinMode.Round, Parent = label })
	state.pop = label
	local info = TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(label, info, { Position = UDim2.fromScale(0.64, 0.12) }):Play()
	TweenService:Create(label, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, 0.35),
		{ TextTransparency = 1 }):Play()
	TweenService:Create(outline, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, 0.35),
		{ Transparency = 1 }):Play()
	task.delay(0.85, function()
		if label.Parent then label:Destroy() end
		if state.pop == label then state.pop = nil end
	end)
	-- the pill bumps (bigger for a win)
	if state.variant ~= "busted" then
		local up = TweenService:Create(state.bump, TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Scale = delta > 0 and 1.16 or 1.08 })
		up.Completed:Connect(function()
			if state.variant ~= "busted" then
				TweenService:Create(state.bump, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
					{ Scale = 1 }):Play()
			end
		end)
		up:Play()
	end
end

local function onWallet(state, quiet: boolean?)
	local value = math.max(0, math.floor(tonumber(state.model:GetAttribute("Wallet")) or 0))
	state.amount.Text = money(value)
	local before = state.wallet
	state.wallet = value
	-- (0 -> their wallet is the server filling it in, not a win)
	if quiet or before == nil or before == 0 or before == value then return end
	if cameraDistance(state.head) > POP_RANGE then return end
	pop(state, value - before, state.model:GetAttribute("WalletNote"))
end

------------------------------------------------------------------
-- tracking (CollectionService, streaming-safe)
------------------------------------------------------------------
local REFRESH_ON = {
	GuestTier = true, GuestName = true, Suspect = true, Busted = true, Kicked = true,
	OnVipFloor = true, CasinoOwner = true,
}

local function detach(model: Instance)
	local state = tags[model]
	tags[model] = nil
	if not state then return end
	if state.conn then state.conn:Disconnect() end
	stopTweens(state)
	if state.bb then state.bb:Destroy() end
end

local function attach(model: Instance)
	if not model:IsA("Model") or tags[model] ~= nil then return end
	tags[model] = false
	task.spawn(function()
		local head = model:WaitForChild("Head", 10)
		if tags[model] ~= false then return end -- (gone while we waited)
		if not (head and head:IsA("BasePart") and model.Parent) then
			tags[model] = nil
			return
		end
		local ok, state = pcall(build, model, head)
		if not ok then
			tags[model] = nil
			warn("[GuestTags] " .. tostring(state))
			return
		end
		tags[model] = state
		refresh(state)
		onWallet(state, true)
		state.conn = model.AttributeChanged:Connect(function(attr)
			if attr == "Wallet" then
				onWallet(state)
			elseif REFRESH_ON[attr] then
				refresh(state)
			end
		end)
	end)
end

-- (CheatersUI asks for a guest's tag, e.g. to pop the BUSTED stamp at once)
function GuestTags.refresh(model: Instance)
	local state = tags[model]
	if state then refresh(state) end
end

function GuestTags.start()
	if GuestTags.started then return end
	GuestTags.started = true
	for _, m in CollectionService:GetTagged(TAG) do attach(m) end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(attach)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(detach)
end

return GuestTags
