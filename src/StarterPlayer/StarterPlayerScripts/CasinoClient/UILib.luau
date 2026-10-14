--!nonstrict
-- UILib.luau — shared client UI toolkit + a small client-side state cache that
-- mirrors the server's DataUpdated pushes, so every panel can read/refresh.
--
-- Design language (luxury casino: dark navy + champagne gold):
--   * thick colored strokes (never 1px black), vertical depth gradients,
--   * 9-slice drop shadows, outlined text, FredokaOne numbers,
--   * pop-in panels + hover/press button juice.
-- Old helpers keep their signatures; new ones (currencyPill/card/badge/
-- sectionHeader/shadow/gradient/tween + darken/lighten/abbreviate) are additive.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local player = Players.LocalPlayer

local UILib = {}

UILib.Colors = {
	-- backgrounds (dark desaturated navy, never pure black)
	Dark    = Color3.fromRGB(20, 22, 33),
	Panel   = Color3.fromRGB(34, 38, 58),
	Panel2  = Color3.fromRGB(44, 49, 74),
	PanelHi = Color3.fromRGB(54, 60, 88),

	-- brand: champagne gold
	Gold      = Color3.fromRGB(212, 175, 60),
	GoldLight = Color3.fromRGB(240, 214, 120),
	GoldDark  = Color3.fromRGB(140, 110, 28),

	-- currency / accent identities
	Cash    = Color3.fromRGB(212, 175, 60),
	Premium = Color3.fromRGB(46, 204, 113),
	Neon    = Color3.fromRGB(255, 64, 129),
	NeonBlue= Color3.fromRGB(64, 196, 255),

	-- semantic
	Green = Color3.fromRGB(46, 204, 113),
	Red   = Color3.fromRGB(231, 76, 60),
	Blue  = Color3.fromRGB(64, 158, 240),
	Orange= Color3.fromRGB(230, 126, 34),

	-- text
	White = Color3.fromRGB(245, 245, 250),
	Sub   = Color3.fromRGB(168, 174, 196),
	Ink   = Color3.fromRGB(16, 17, 26),

	-- back-compat aliases (older panels reference these)
	Accent = Color3.fromRGB(212, 175, 60),
	Black  = Color3.fromRGB(16, 17, 26),
}
local C = UILib.Colors

UILib.IsTouch = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
UILib.Shadow9 = "rbxassetid://1316045217"

-- free Creator Store icons, visually verified. These are the resolved IMAGE
-- ids (ImageLabels can't load raw decal ids — they never resolve).
UILib.Icons = {
	Services  = "rbxassetid://135780702746673", -- white outline shopping bag
	Inventory = "rbxassetid://124233015832617", -- solid white backpack
	Move      = "rbxassetid://10896796825",     -- white wrench glyph
	Upgrades  = "rbxassetid://15640528020",     -- teal chevrons up
	Casino    = "rbxassetid://15775768789",     -- classical bank columns
	Stats     = "rbxassetid://8587689304",      -- white bar chart
	Shop      = "rbxassetid://9650296110",      -- blue faceted gem
	Crown     = "rbxassetid://360172301",       -- gold crown (VIP)
	Cherry    = "rbxassetid://87158052124670",  -- slot reel symbol
	Lemon     = "rbxassetid://18666183636",     -- slot reel symbol
	Bell      = "rbxassetid://14895343020",     -- slot reel symbol
}

------------------------------------------------------------------
-- color + number helpers
------------------------------------------------------------------
function UILib.darken(c: Color3, f: number?): Color3
	f = f or 0.45
	return Color3.new(c.R * (1 - f), c.G * (1 - f), c.B * (1 - f))
end
function UILib.lighten(c: Color3, f: number?): Color3
	f = f or 0.18
	return Color3.new(c.R + (1 - c.R) * f, c.G + (1 - c.G) * f, c.B + (1 - c.B) * f)
end
local darken, lighten = UILib.darken, UILib.lighten
local function luminance(c: Color3): number
	return 0.299 * c.R + 0.587 * c.G + 0.114 * c.B
end

function UILib.commas(n: number): string
	local s = tostring(math.floor(n))
	local k
	repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
	return s
end
-- compact form for big numbers (1.2M); full commas below 1M.
function UILib.abbreviate(n: number): string
	if n < 1e6 then return UILib.commas(n) end
	local suf = { "", "K", "M", "B", "T", "qa", "Qi" }
	local i = 1
	while n >= 1000 and i < #suf do n /= 1000; i += 1 end
	return string.format("%.1f", n) .. suf[i]
end

------------------------------------------------------------------
-- low-level builders
------------------------------------------------------------------
function UILib.make(class: string, props, children): Instance
	local inst = Instance.new(class)
	for k, v in props do
		if typeof(k) ~= "string" or string.sub(k, 1, 1) ~= "_" then
			(inst :: any)[k] = v
		end
	end
	if children then for _, c in children do c.Parent = inst end end
	return inst
end

function UILib.corner(parent: Instance, radius: number)
	return UILib.make("UICorner", { CornerRadius = UDim.new(0, radius or 8), Parent = parent })
end
function UILib.stroke(parent: Instance, color: Color3, thickness: number?)
	return UILib.make("UIStroke", {
		Color = color, Thickness = thickness or 2,
		LineJoinMode = Enum.LineJoinMode.Round, Parent = parent })
end
function UILib.pad(parent: Instance, p: number)
	return UILib.make("UIPadding", {
		PaddingTop = UDim.new(0, p), PaddingBottom = UDim.new(0, p),
		PaddingLeft = UDim.new(0, p), PaddingRight = UDim.new(0, p), Parent = parent })
end

-- vertical depth gradient (top lighter). Pass explicit colors or it derives them.
function UILib.gradient(parent: Instance, top: Color3?, bottom: Color3?)
	local fill = parent.BackgroundColor3
	return UILib.make("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(top or lighten(fill, 0.16), bottom or fill),
		Parent = parent })
end

-- soft 9-slice drop shadow drawn BEHIND `target` (call after target.Parent set).
function UILib.shadow(target: GuiObject, transparency: number?)
	local s = UILib.make("ImageLabel", {
		Name = "Shadow", BackgroundTransparency = 1, Image = UILib.Shadow9,
		ScaleType = Enum.ScaleType.Slice, SliceCenter = Rect.new(10, 10, 118, 118),
		ImageColor3 = C.Ink, ImageTransparency = transparency or 0.5,
		AnchorPoint = target.AnchorPoint,
		Size = UDim2.new(target.Size.X.Scale, target.Size.X.Offset + 26,
			target.Size.Y.Scale, target.Size.Y.Offset + 26),
		Position = UDim2.new(target.Position.X.Scale, target.Position.X.Offset,
			target.Position.Y.Scale, target.Position.Y.Offset + 6),
		ZIndex = (target.ZIndex or 1) - 1, Parent = target.Parent })
	return s
end

-- tween wrapper that cancels the prior tween on the same object (no stuck anims).
local active: {[Instance]: Tween} = setmetatable({}, { __mode = "k" }) :: any
function UILib.tween(obj: Instance, props, t: number?, style, dir)
	if active[obj] then active[obj]:Cancel() end
	local tw = TweenService:Create(obj,
		TweenInfo.new(t or 0.18, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	active[obj] = tw
	tw:Play()
	return tw
end

------------------------------------------------------------------
-- backdrop blur — counted so overlapping panels don't fight over it.
-- A locally-created BlurEffect never replicates, so this is per-player.
------------------------------------------------------------------
local Lighting = game:GetService("Lighting")
local blurCount = 0
local blurFx: BlurEffect?
function UILib.blur(on: boolean)
	blurCount = math.max(0, blurCount + (on and 1 or -1))
	if not blurFx or not blurFx.Parent then
		blurFx = UILib.make("BlurEffect", { Name = "CasinoPanelBlur", Size = 0, Parent = Lighting }) :: BlurEffect
	end
	UILib.tween(blurFx, { Size = blurCount > 0 and 14 or 0 }, 0.22)
end

------------------------------------------------------------------
-- animated number: eases a label from its last shown value to `target`.
-- The current value rides on a CountValue attribute so re-targets mid-flight
-- pick up from wherever the animation is.
------------------------------------------------------------------
local counting: {[TextLabel]: thread} = setmetatable({}, { __mode = "k" }) :: any
function UILib.countTo(label: TextLabel, target: number, formatter: ((number) -> string)?)
	local fmt = formatter or UILib.abbreviate
	local from = label:GetAttribute("CountValue")
	label:SetAttribute("CountValue", target)
	if counting[label] then task.cancel(counting[label]); counting[label] = nil end
	if from == nil or from == target then
		label.Text = fmt(target)
		return
	end
	counting[label] = task.spawn(function()
		local t0 = os.clock()
		local dur = 0.45
		while label.Parent do
			local a = math.min((os.clock() - t0) / dur, 1)
			a = 1 - (1 - a) ^ 3
			label.Text = fmt(from + (target - from) * a)
			if a >= 1 then break end
			task.wait()
		end
		counting[label] = nil
	end)
end

local screen
function UILib.getScreen(): ScreenGui
	if not screen then
		screen = UILib.make("ScreenGui", {
			Name = "CasinoUI", ResetOnSpawn = false, IgnoreGuiInset = false,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			Parent = player:WaitForChild("PlayerGui"),
		})
	end
	return screen
end

------------------------------------------------------------------
-- buttons (gradient fill + colored border + outlined text + juice)
------------------------------------------------------------------
local function addJuice(btn: GuiButton, scale: UIScale)
	local hovered = false
	local function to(s, tt) UILib.tween(scale, { Scale = s }, tt, Enum.EasingStyle.Quad) end
	if not UILib.IsTouch then
		btn.MouseEnter:Connect(function() hovered = true; to(1.05, 0.12) end)
		btn.MouseLeave:Connect(function() hovered = false; to(1, 0.12) end)
	end
	btn.MouseButton1Down:Connect(function() to(0.92, 0.08) end)
	btn.MouseButton1Up:Connect(function() to(hovered and 1.05 or 1, 0.1) end)
end

function UILib.button(props): TextButton
	local fill = props.BackgroundColor3 or C.Panel2
	local radius = props._radius or 10
	local b = UILib.make("TextButton", props) :: TextButton
	b.AutoButtonColor = false
	b.Font = props.Font or Enum.Font.GothamBold
	b.BackgroundColor3 = fill
	b.BorderSizePixel = 0
	UILib.corner(b, radius)
	UILib.gradient(b, lighten(fill, 0.18), fill)
	-- outlined text: pick a stroke color that stays legible against the
	-- button's OWN text color — dark text (e.g. black price labels on a gold
	-- fill) previously always got a dark ink outline too, so it disappeared
	-- into itself. Light text keeps the original dark outline unchanged.
	local strokeColor = luminance(b.TextColor3) < 0.42 and C.White or C.Ink
	UILib.make("UIStroke", { Color = strokeColor, Thickness = props._textStroke or 2,
		LineJoinMode = Enum.LineJoinMode.Round, Parent = b })
	-- colored rounded-rectangle border (own frame so it never fights the text stroke)
	local border = UILib.make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
		ZIndex = b.ZIndex, Parent = b })
	UILib.corner(border, radius)
	UILib.make("UIStroke", { Color = props._stroke or darken(fill, 0.5),
		Thickness = props._strokeThickness or 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		LineJoinMode = Enum.LineJoinMode.Round, Parent = border })
	if props._juice ~= false then
		local sc = UILib.make("UIScale", { Scale = 1, Parent = b })
		addJuice(b, sc)
	end
	return b
end

------------------------------------------------------------------
-- panels (shadow + gold-framed window + gold header + pop-in)
-- returns (panel, closeButton, contentFrame). Older callers use (panel, close)
-- and parent their content into `panel` at a y-offset below the 52px header.
--
-- Exclusive by design: only one centeredPanel may be open at a time. Opening
-- a new one animates-closes whichever different panel is currently open,
-- so menus never stack on top of each other.
------------------------------------------------------------------
local activePanel: { holder: Frame, dismiss: () -> () }? = nil

function UILib.centeredPanel(name, scaleW, scaleH, maxW, maxH, title)
	local sc = UILib.getScreen()
	local existing = sc:FindFirstChild(name)
	if existing then existing:Destroy() end

	-- a DIFFERENT panel is open (same-name reopen was just handled above) —
	-- close it with its own animation before this one pops in
	if activePanel and activePanel.holder.Parent then
		activePanel.dismiss()
	end

	local restPosition = UDim2.fromScale(0.5, 0.5)
	local holder = UILib.make("Frame", {
		Name = name, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 36),
		Size = UDim2.fromScale(scaleW, scaleH), BackgroundTransparency = 1, Parent = sc })
	UILib.make("UISizeConstraint", { MaxSize = Vector2.new(maxW, maxH), MinSize = Vector2.new(260, 220), Parent = holder })
	local scaler = UILib.make("UIScale", { Scale = 0, Parent = holder })

	UILib.make("ImageLabel", {
		Name = "Shadow", BackgroundTransparency = 1, Image = UILib.Shadow9,
		ScaleType = Enum.ScaleType.Slice, SliceCenter = Rect.new(10, 10, 118, 118),
		ImageColor3 = C.Ink, ImageTransparency = 0.4,
		Size = UDim2.new(1, 36, 1, 36), Position = UDim2.new(0, -18, 0, -12), ZIndex = 0, Parent = holder })

	local panel = UILib.make("Frame", {
		Name = "Window", Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.Dark, ZIndex = 1, Parent = holder })
	UILib.corner(panel, 18)
	UILib.gradient(panel, C.Panel, C.Dark)
	UILib.stroke(panel, C.Gold, 3)

	local header = UILib.make("Frame", {
		Name = "Header", Size = UDim2.new(1, 0, 0, 52), BackgroundColor3 = C.Gold, ZIndex = 2, Parent = panel })
	UILib.corner(header, 18)
	UILib.gradient(header, C.GoldLight, C.Gold)
	UILib.make("Frame", { Size = UDim2.new(1, 0, 0, 20), Position = UDim2.new(0, 0, 1, -20),
		BackgroundColor3 = C.Gold, BorderSizePixel = 0, ZIndex = 2, Parent = header })
	if title then
		local t = UILib.make("TextLabel", {
			Size = UDim2.new(1, -64, 1, 0), Position = UDim2.fromOffset(18, 0), BackgroundTransparency = 1,
			Text = title, Font = Enum.Font.FredokaOne, TextSize = 22, TextColor3 = C.Ink,
			TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 3, Parent = header })
		UILib.make("UIStroke", { Color = C.GoldLight, Thickness = 1, Transparency = 0.4, Parent = t })
	end

	-- gold-gloss shimmer that sweeps the header every few seconds
	local shine = UILib.make("Frame", {
		Name = "Shine", BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromScale(1, 1),
		BorderSizePixel = 0, ZIndex = 4, Parent = header })
	UILib.corner(shine, 18)
	local shineGrad = UILib.make("UIGradient", {
		Rotation = 20,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.42, 1),
			NumberSequenceKeypoint.new(0.5, 0.72), NumberSequenceKeypoint.new(0.58, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Offset = Vector2.new(-1, 0), Parent = shine }) :: UIGradient
	task.spawn(function()
		while shine.Parent do
			local tw = TweenService:Create(shineGrad,
				TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
				{ Offset = Vector2.new(1, 0) })
			tw:Play()
			tw.Completed:Wait()
			if not shine.Parent then break end
			shineGrad.Offset = Vector2.new(-1, 0)
			task.wait(2.6)
		end
	end)

	local close = UILib.button({
		Size = UDim2.fromOffset(38, 38), Position = UDim2.new(1, -14, 0, -12),
		AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = C.Red, Text = "✕",
		TextSize = 20, TextColor3 = C.White, Font = Enum.Font.GothamBold, ZIndex = 6, _radius = 19, Parent = panel })

	local content = UILib.make("Frame", {
		Name = "Content", BackgroundTransparency = 1,
		Size = UDim2.new(1, -24, 1, -66), Position = UDim2.fromOffset(12, 60), ZIndex = 2, Parent = panel })

	-- pop in AND rise up together for a punchier open than a plain scale-in
	local targetScale = UILib.IsTouch and 1.1 or 1
	UILib.tween(scaler, { Scale = targetScale }, 0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	UILib.tween(holder, { Position = restPosition }, 0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

	-- blur the world behind the panel; released exactly once no matter which
	-- close path runs (dismiss animation OR a caller's raw panel:Destroy())
	UILib.blur(true)
	local blurReleased = false
	local function releaseBlur()
		if blurReleased then return end
		blurReleased = true
		UILib.blur(false)
	end

	local dismissed = false
	local function dismiss()
		if dismissed then return end
		dismissed = true
		releaseBlur()
		-- Destroying does NOT propagate from an ancestor to a descendant in
		-- this engine, and this path destroys `holder` (panel's ancestor), so
		-- `panel.Destroying` below would never fire for it. Clear the
		-- registry here directly instead of depending on that event.
		if activePanel and activePanel.holder == holder then activePanel = nil end
		UILib.tween(scaler, { Scale = 0 }, 0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		UILib.tween(holder, { Position = UDim2.new(0.5, 0, 0.5, 24) }, 0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		task.delay(0.17, function() if holder then holder:Destroy() end end)
	end
	close.MouseButton1Click:Connect(dismiss)

	-- Older panels close themselves with `panel:Destroy()` (the returned Window),
	-- which would orphan the holder's drop-shadow on screen. Tear down the whole
	-- holder when the window is destroyed so no ghost shadow lingers.
	panel.Destroying:Connect(function()
		releaseBlur()
		if activePanel and activePanel.holder == holder then activePanel = nil end
		if holder.Parent then holder:Destroy() end
	end)

	activePanel = { holder = holder, dismiss = dismiss }

	return panel, close, content, dismiss
end

------------------------------------------------------------------
-- currency pill — capsule with an icon backplate overhanging the left edge,
-- an outlined number, and a green "+" that opens a callback (e.g. Robux shop).
------------------------------------------------------------------
function UILib.currencyPill(parent, opts)
	opts = opts or {}
	local color = opts.color or C.Cash
	local pill = UILib.make("Frame", {
		Name = opts.name or "CurrencyPill", Size = opts.size or UDim2.fromOffset(210, 46),
		BackgroundColor3 = C.Panel, Parent = parent })
	UILib.corner(pill, 23)
	UILib.gradient(pill, lighten(C.Panel, 0.12), C.Panel)
	UILib.stroke(pill, darken(color, 0.35), 3)

	local plate = UILib.make("Frame", {
		Size = UDim2.fromOffset(46, 46), Position = UDim2.fromOffset(-6, 0), BackgroundColor3 = color, Parent = pill })
	UILib.corner(plate, 23)
	UILib.stroke(plate, darken(color, 0.45), 3)
	UILib.make("TextLabel", {
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = opts.icon or "$",
		Font = Enum.Font.FredokaOne, TextSize = 22, TextColor3 = C.Ink, Parent = plate })

	local label = UILib.make("TextLabel", {
		Name = "Value", Size = UDim2.new(1, -96, 1, 0), Position = UDim2.fromOffset(50, 0),
		BackgroundTransparency = 1, Text = opts.text or "0", Font = Enum.Font.FredokaOne, TextSize = 20,
		TextColor3 = color, TextXAlignment = Enum.TextXAlignment.Left, Parent = pill })
	UILib.make("UIStroke", { Color = C.Ink, Thickness = 3, LineJoinMode = Enum.LineJoinMode.Round, Parent = label })

	if opts.onPlus then
		local plus = UILib.button({
			Size = UDim2.fromOffset(34, 34), Position = UDim2.new(1, -40, 0.5, -17),
			BackgroundColor3 = C.Premium, Text = "+", TextSize = 24, TextColor3 = C.White, _radius = 17, Parent = pill })
		plus.MouseButton1Click:Connect(opts.onPlus)
	end
	return pill, label
end

------------------------------------------------------------------
-- card — framed container for shop items / catalog rows
------------------------------------------------------------------
function UILib.card(parent, opts)
	opts = opts or {}
	local accent = opts.accent or C.Gold
	local card = UILib.make("Frame", {
		Name = opts.name or "Card", Size = opts.size or UDim2.new(1, 0, 0, 76),
		BackgroundColor3 = C.Panel2, Parent = parent })
	UILib.corner(card, 12)
	UILib.gradient(card, C.PanelHi, C.Panel2)
	UILib.stroke(card, accent, 2)
	return card
end

------------------------------------------------------------------
-- badge — small pill (OWNED / BEST VALUE / 2x ...)
------------------------------------------------------------------
function UILib.badge(parent, text, color)
	color = color or C.Gold
	local b = UILib.make("Frame", { Name = "Badge", BackgroundColor3 = color,
		Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X, Parent = parent })
	UILib.corner(b, 11)
	UILib.stroke(b, darken(color, 0.4), 1.5)
	UILib.pad(b, 6)
	local lbl = UILib.make("TextLabel", { Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1, Text = text, Font = Enum.Font.FredokaOne, TextSize = 12,
		TextColor3 = C.White, Parent = b })
	UILib.make("UIStroke", { Color = C.Ink, Thickness = 1.5, Parent = lbl })
	return b
end

------------------------------------------------------------------
-- section header — gold label with an underline
------------------------------------------------------------------
function UILib.sectionHeader(parent, text)
	local h = UILib.make("Frame", { Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, Parent = parent })
	local lbl = UILib.make("TextLabel", { Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, Text = text,
		Font = Enum.Font.FredokaOne, TextSize = 14, TextColor3 = C.Gold,
		TextXAlignment = Enum.TextXAlignment.Left, Parent = h })
	UILib.make("UIStroke", { Color = C.Ink, Thickness = 2, Parent = lbl })
	UILib.make("Frame", { Size = UDim2.new(1, 0, 0, 2), Position = UDim2.new(0, 0, 1, -2),
		BackgroundColor3 = C.Gold, BackgroundTransparency = 0.4, BorderSizePixel = 0, Parent = h })
	return h
end

------------------------------------------------------------------
-- toast — slides in from the top with shadow + stroke. Toasts stack instead
-- of overlapping, and re-flow upward as earlier ones expire. The shadow lives
-- INSIDE the toast so it moves and dies with it (a screen-level sibling
-- shadow would be left behind forever).
------------------------------------------------------------------
local activeToasts: {TextLabel} = {}
local function toastSlotY(slot: number): number
	return 16 + (slot - 1) * 54
end
local function reflowToasts()
	for i, t in activeToasts do
		UILib.tween(t, { Position = UDim2.new(0.5, 0, 0, toastSlotY(i)) }, 0.2)
	end
end

function UILib.toast(text: string, color: Color3?)
	local sc = UILib.getScreen()
	local t = UILib.make("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.fromOffset(400, 46),
		Position = UDim2.new(0.5, 0, 0, -60), BackgroundColor3 = color or C.Panel2, Text = text,
		Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = C.White, ZIndex = 50, Parent = sc })
	UILib.corner(t, 12)
	UILib.gradient(t, lighten(color or C.Panel2, 0.15), color or C.Panel2)
	UILib.stroke(t, darken(color or C.Panel2, 0.45), 2.5)
	UILib.make("UIStroke", { Color = C.Ink, Thickness = 2, Parent = t })
	UILib.make("ImageLabel", {
		Name = "Shadow", BackgroundTransparency = 1, Image = UILib.Shadow9,
		ScaleType = Enum.ScaleType.Slice, SliceCenter = Rect.new(10, 10, 118, 118),
		ImageColor3 = C.Ink, ImageTransparency = 0.55,
		Size = UDim2.new(1, 26, 1, 26), Position = UDim2.fromOffset(-13, -7),
		ZIndex = 49, Parent = t })

	table.insert(activeToasts, t)
	UILib.tween(t, { Position = UDim2.new(0.5, 0, 0, toastSlotY(#activeToasts)) },
		0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	task.delay(2.6, function()
		if t and t.Parent then
			for i, x in activeToasts do
				if x == t then table.remove(activeToasts, i) break end
			end
			reflowToasts()
			UILib.tween(t, { Position = UDim2.new(0.5, 0, 0, -60) }, 0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			task.delay(0.26, function() if t then t:Destroy() end end)
		end
	end)
end

function UILib.getCashValue(): IntValue
	local ls = player:WaitForChild("leaderstats")
	return ls:WaitForChild("Cash") :: IntValue
end

------------------------------------------------------------------
-- client state cache (mirrors server DataUpdated snapshots)
------------------------------------------------------------------
UILib.state = { cash = 0, inventory = {}, placed = {}, staff = {}, stats = {} }
local subs: {(any) -> ()} = {}

function UILib.setState(snap)
	if snap then UILib.state = snap end
	for _, fn in subs do task.spawn(fn, UILib.state) end
end

function UILib.subscribe(fn): () -> ()
	table.insert(subs, fn)
	task.spawn(fn, UILib.state)
	return function()
		for i, f in subs do if f == fn then table.remove(subs, i) break end end
	end
end

return UILib
