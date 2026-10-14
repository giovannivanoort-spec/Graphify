--!nonstrict
-- UILib.luau — the "Showtime" design system + a small client state cache that
-- mirrors the server's DataUpdated pushes.
--
-- Design language (see Figma "Casino Masters — UI Rework", page v2):
--   * crimson velvet panels framed by chasing marquee bulbs, cream inner panels
--     with a gold trim and a faint diamond pattern, a gold ribbon title
--   * every item / action gets its own vivid tone (Pet-Sim style), glossy 3D
--     buttons (shadow body + gradient face + shine band) that press down
--   * ink (#2B0A12) outlines everywhere, Luckiest Guy display type with a hard
--     extrusion shadow, Fredoka One numbers, 3D-rendered icons (UIAssets)
-- Layout is authored at 1280x720 and scaled with the viewport (autoScale).

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Assets = require(Common:WaitForChild("UIAssets"))
local player = Players.LocalPlayer

local UILib = {}
UILib.Assets = Assets
UILib.Icons = Assets.Icons
UILib.Tex = Assets.Textures

------------------------------------------------------------------
-- tokens
------------------------------------------------------------------
local hex = Color3.fromHex
UILib.Colors = {
	Ink = hex("#2B0A12"),
	CrimsonTop = hex("#FF5468"), Crimson = hex("#D7263D"), CrimsonDeep = hex("#8E0F22"),
	GoldTop = hex("#FFF3A8"), Gold = hex("#FFCB2E"), GoldDeep = hex("#E89A0C"), GoldShadow = hex("#9A5A00"),
	Cream = hex("#FFF4DC"), CreamRow = hex("#FFE6B5"), CreamLine = hex("#E2BE7E"),
	GreenTop = hex("#9BF78F"), Green = hex("#36C23A"), GreenShadow = hex("#1C7A1C"),
	BlueTop = hex("#8EE0FF"), Blue = hex("#1E9BEA"), BlueShadow = hex("#0F5A99"),
	PinkTop = hex("#FFA3DA"), Pink = hex("#F23FA0"), PinkShadow = hex("#9E1A63"),
	PurpleTop = hex("#C9A0FF"), Purple = hex("#8A4DE8"), PurpleShadow = hex("#4E2496"),
	OrangeTop = hex("#FFC27A"), Orange = hex("#FF8A1F"), OrangeShadow = hex("#A84E00"),
	Brown = hex("#5A2A12"), White = Color3.new(1, 1, 1),
}
local C = UILib.Colors
C.Red = C.Crimson -- semantic alias

UILib.Tones = {
	Green  = { top = C.GreenTop,   base = C.Green,     shadow = C.GreenShadow },
	Gold   = { top = C.GoldTop,    base = C.GoldDeep,  shadow = C.GoldShadow },
	Blue   = { top = C.BlueTop,    base = C.Blue,      shadow = C.BlueShadow },
	Pink   = { top = C.PinkTop,    base = C.Pink,      shadow = C.PinkShadow },
	Red    = { top = C.CrimsonTop, base = C.Crimson,   shadow = C.CrimsonDeep },
	Purple = { top = C.PurpleTop,  base = C.Purple,    shadow = C.PurpleShadow },
	Orange = { top = C.OrangeTop,  base = C.Orange,    shadow = C.OrangeShadow },
	Black  = { top = hex("#6B5A60"), base = hex("#2E2428"), shadow = hex("#120A0C") }, -- roulette black only
}
local Tones = UILib.Tones

UILib.Fonts = {
	Display = Enum.Font.LuckiestGuy,
	Number = Enum.Font.FredokaOne,
	Body = Enum.Font.GothamBold,
	Heavy = Enum.Font.GothamBlack,
}
local F = UILib.Fonts

UILib.IsTouch = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

------------------------------------------------------------------
-- small helpers
------------------------------------------------------------------
function UILib.darken(c: Color3, f: number?): Color3
	f = f or 0.45
	return Color3.new(c.R * (1 - f), c.G * (1 - f), c.B * (1 - f))
end
function UILib.lighten(c: Color3, f: number?): Color3
	f = f or 0.18
	return Color3.new(c.R + (1 - c.R) * f, c.G + (1 - c.G) * f, c.B + (1 - c.B) * f)
end

function UILib.commas(n: number): string
	local s = tostring(math.floor(n or 0))
	local k
	repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
	return s
end
-- compact form for big numbers (1.2M); full commas below 1M
function UILib.abbreviate(n: number): string
	n = n or 0
	if math.abs(n) < 1e6 then return UILib.commas(n) end
	local suf = { "", "K", "M", "B", "T", "Qa", "Qi" }
	local i = 1
	while math.abs(n) >= 1000 and i < #suf do n /= 1000; i += 1 end
	return string.format("%.2f", n):gsub("%.?0+$", "") .. suf[i]
end
function UILib.money(n: number): string
	return "$" .. UILib.abbreviate(n)
end
function UILib.clock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local h, m, s = seconds // 3600, (seconds % 3600) // 60, seconds % 60
	if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
	return string.format("%d:%02d", m, s)
end

function UILib.make(class: string, props, children): Instance
	local inst = Instance.new(class)
	for k, v in props do
		if k ~= "Parent" then (inst :: any)[k] = v end
	end
	if children then for _, c in children do c.Parent = inst end end
	if props.Parent then inst.Parent = props.Parent end
	return inst
end
local make = UILib.make

function UILib.corner(parent: Instance, radius: number?)
	local r = radius or 12
	return make("UICorner", { CornerRadius = r >= 999 and UDim.new(0.5, 0) or UDim.new(0, r), Parent = parent })
end
function UILib.stroke(parent: Instance, color: Color3, thickness: number?, border: boolean?, transparency: number?)
	return make("UIStroke", {
		Color = color, Thickness = thickness or 3, Transparency = transparency or 0,
		LineJoinMode = Enum.LineJoinMode.Round,
		ApplyStrokeMode = border and Enum.ApplyStrokeMode.Border or Enum.ApplyStrokeMode.Contextual,
		Parent = parent })
end
function UILib.pad(parent: Instance, l: number, t: number?, r: number?, b: number?)
	return make("UIPadding", {
		PaddingLeft = UDim.new(0, l), PaddingTop = UDim.new(0, t or l),
		PaddingRight = UDim.new(0, r or l), PaddingBottom = UDim.new(0, b or t or l), Parent = parent })
end
-- vertical gradient on a white-filled frame
function UILib.gradient(parent: Instance, top: Color3, bottom: Color3, mid: Color3?)
	local seq = mid and ColorSequence.new({
		ColorSequenceKeypoint.new(0, top), ColorSequenceKeypoint.new(0.55, mid), ColorSequenceKeypoint.new(1, bottom),
	}) or ColorSequence.new(top, bottom)
	return make("UIGradient", { Rotation = 90, Color = seq, Parent = parent })
end
function UILib.list(parent: Instance, dir: string?, padding: number?, hAlign, vAlign)
	return make("UIListLayout", {
		FillDirection = dir == "x" and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical,
		Padding = UDim.new(0, padding or 0), SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Left,
		VerticalAlignment = vAlign or Enum.VerticalAlignment.Top, Parent = parent })
end
local corner, stroke, gradient = UILib.corner, UILib.stroke, UILib.gradient

-- tween wrapper that cancels the previous tween on the same object
local active: {[Instance]: Tween} = setmetatable({}, { __mode = "k" }) :: any
function UILib.tween(obj: Instance, props, t: number?, style, dir)
	if active[obj] then active[obj]:Cancel() end
	local tw = TweenService:Create(obj,
		TweenInfo.new(t or 0.18, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	active[obj] = tw
	tw:Play()
	return tw
end
local tween = UILib.tween

local function resolveIcon(icon: string?): string
	if not icon or icon == "" then return "" end
	if string.find(icon, "rbxasset") then return icon end
	return Assets.Icons[icon] or Assets.Textures[icon] or ""
end
UILib.resolveIcon = resolveIcon

------------------------------------------------------------------
-- screen + viewport scaling (designs are authored at 1280x720)
------------------------------------------------------------------
local screen: ScreenGui?
function UILib.getScreen(): ScreenGui
	if not (screen and screen.Parent) then
		screen = make("ScreenGui", {
			Name = "CasinoUI", ResetOnSpawn = false, IgnoreGuiInset = false,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
			Parent = player:WaitForChild("PlayerGui"),
		}) :: ScreenGui
	end
	return screen :: ScreenGui
end

local function viewport(): Vector2
	local cam = Workspace.CurrentCamera
	return cam and cam.ViewportSize or Vector2.new(1280, 720)
end
local function baseScale(): number
	local vp = viewport()
	return math.clamp(math.min(vp.X / 1280, vp.Y / 720), 0.5, 1.4)
end

-- UIScale that follows the viewport. opts.fit = Vector2(w, h) also keeps a
-- panel of that design size inside the screen.
-- NOTE: strong table on purpose. Instance userdata in a weak-keyed table can be
-- collected while the Instance is still alive, silently dropping the entry.
local scaled: {[UIScale]: any} = {}
local function scaleFor(opts): number
	local s = baseScale() * (opts.mult or 1)
	if opts.fit then
		local vp = viewport()
		s = math.min(s, (vp.Y * 0.92) / (opts.fit.Y + 70), (vp.X * 0.96) / opts.fit.X)
	end
	return s
end
function UILib.autoScale(inst: Instance, opts)
	opts = opts or {}
	local sc = make("UIScale", { Name = "AutoScale", Scale = scaleFor(opts), Parent = inst }) :: UIScale
	scaled[sc] = opts
	sc.Destroying:Connect(function() scaled[sc] = nil end)
	return sc
end
local function rescaleAll()
	for sc, opts in scaled do
		if sc.Parent then sc.Scale = scaleFor(opts) else scaled[sc] = nil end
	end
end
local hookedCam: Camera?
local function hookCamera()
	local cam = Workspace.CurrentCamera
	if cam and cam ~= hookedCam then
		hookedCam = cam
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(rescaleAll)
	end
end
hookCamera()
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function() hookCamera(); rescaleAll() end)
-- the viewport is often still tiny while the client boots: re-check a few times
task.spawn(function()
	for _, t in { 0.5, 1, 2, 4 } do
		task.wait(t)
		hookCamera()
		rescaleAll()
	end
end)

------------------------------------------------------------------
-- display text with ink outline + hard extrusion shadow
-- returns (face TextLabel, holder Frame). Position/size the holder; set
-- face.Text — the shadow copy follows automatically.
------------------------------------------------------------------
function UILib.text(parent: Instance?, o)
	o = o or {}
	local size = o.size or 24
	local holder = make("Frame", {
		Name = o.name or "Text", BackgroundTransparency = 1,
		Size = o.frameSize or UDim2.fromScale(1, 1), Position = o.position or UDim2.new(),
		AnchorPoint = o.anchor or Vector2.zero, LayoutOrder = o.order or 0, ZIndex = o.z or 1,
		Rotation = o.rotation or 0, Parent = parent,
	})
	local strokeW = o.stroke
	if strokeW == nil then strokeW = math.max(1.5, size / 8.5) end
	local shadowPx = o.shadow
	if shadowPx == nil then shadowPx = math.max(2, math.floor(size / 8)) end

	local function lbl(name: string, color: Color3)
		local l = make("TextLabel", {
			Name = name, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
			Text = o.text or "", Font = o.font or F.Display, TextSize = size, TextColor3 = color,
			TextXAlignment = o.xAlign or Enum.TextXAlignment.Center,
			TextYAlignment = o.yAlign or Enum.TextYAlignment.Center,
			TextWrapped = o.wrap or false, RichText = o.rich or false,
			TextTransparency = o.transparency or 0, ZIndex = holder.ZIndex, Parent = holder,
		})
		if o.autoX then
			l.AutomaticSize = Enum.AutomaticSize.X
			l.Size = UDim2.fromScale(0, 1)
		end
		return l
	end
	if o.autoX then holder.AutomaticSize = Enum.AutomaticSize.X end

	local shadow
	if shadowPx and shadowPx > 0 then
		shadow = lbl("Shadow", C.Ink)
		shadow.Position = UDim2.fromOffset(0, shadowPx)
		if strokeW > 0 then stroke(shadow, C.Ink, strokeW) end
	end
	local face = lbl("Face", o.color or C.White)
	if strokeW > 0 then stroke(face, o.strokeColor or C.Ink, strokeW) end
	if o.gradient then
		face.TextColor3 = C.White
		make("UIGradient", { Rotation = 90, Color = ColorSequence.new(o.gradient[1], o.gradient[2]), Parent = face })
	end
	if shadow then
		face:GetPropertyChangedSignal("Text"):Connect(function() shadow.Text = face.Text end)
		face:GetPropertyChangedSignal("TextTransparency"):Connect(function() shadow.TextTransparency = face.TextTransparency end)
		face:GetPropertyChangedSignal("TextSize"):Connect(function() shadow.TextSize = face.TextSize end)
	end
	return face, holder
end

-- plain body text (no outline / shadow)
function UILib.body(parent: Instance?, o)
	o = o or {}
	return make("TextLabel", {
		Name = o.name or "Body", BackgroundTransparency = 1,
		Size = o.frameSize or UDim2.new(1, 0, 0, (o.size or 14) + 6), Position = o.position or UDim2.new(),
		AnchorPoint = o.anchor or Vector2.zero, LayoutOrder = o.order or 0, ZIndex = o.z or 1,
		Text = o.text or "", Font = o.font or F.Body, TextSize = o.size or 14,
		TextColor3 = o.color or C.Brown, TextTransparency = o.transparency or 0,
		TextXAlignment = o.xAlign or Enum.TextXAlignment.Left,
		TextYAlignment = o.yAlign or Enum.TextYAlignment.Center,
		TextWrapped = o.wrap or false, RichText = o.rich or false,
		AutomaticSize = o.autoY and Enum.AutomaticSize.Y or (o.autoX and Enum.AutomaticSize.X or Enum.AutomaticSize.None),
		Parent = parent,
	})
end

function UILib.image(parent: Instance?, icon: string?, o)
	o = o or {}
	return make("ImageLabel", {
		Name = o.name or "Icon", BackgroundTransparency = 1, Image = resolveIcon(icon),
		ScaleType = Enum.ScaleType.Fit, Size = o.size or UDim2.fromOffset(64, 64),
		Position = o.position or UDim2.new(), AnchorPoint = o.anchor or Vector2.zero,
		ImageColor3 = o.color or C.White, ImageTransparency = o.transparency or 0,
		Rotation = o.rotation or 0, LayoutOrder = o.order or 0, ZIndex = o.z or 1, Parent = parent,
	})
end

------------------------------------------------------------------
-- slowly rotating sunbursts (one shared loop)
------------------------------------------------------------------
local spinning: {[GuiObject]: number} = {} -- strong: see the note on `scaled`
function UILib.spin(obj: GuiObject, degPerSec: number?)
	spinning[obj] = degPerSec or 10
	obj.Destroying:Connect(function() spinning[obj] = nil end)
end
RunService.RenderStepped:Connect(function(dt)
	for obj, speed in spinning do
		if obj.Parent then
			obj.Rotation = (obj.Rotation + speed * dt) % 360
		else
			spinning[obj] = nil
		end
	end
end)

------------------------------------------------------------------
-- backdrop blur, counted so overlapping panels don't fight over it
------------------------------------------------------------------
local blurCount = 0
local blurFx: BlurEffect?
function UILib.blur(on: boolean)
	blurCount = math.max(0, blurCount + (on and 1 or -1))
	if not blurFx or not blurFx.Parent then
		blurFx = make("BlurEffect", { Name = "CasinoPanelBlur", Size = 0, Parent = Lighting }) :: BlurEffect
	end
	tween(blurFx :: BlurEffect, { Size = blurCount > 0 and 12 or 0 }, 0.22)
end

------------------------------------------------------------------
-- animated number: eases a label from its last shown value to `target`
------------------------------------------------------------------
local counting: {[TextLabel]: thread} = {} -- strong; entries clear when a count finishes
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
		local dur = 0.5
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

------------------------------------------------------------------
-- glossy 3D button
-- o: parent, size, position, anchor, tone, text, textSize, font, icon,
--    iconSize, onClick, order, z, name, radius
-- returns handle { Instance, Button, Label, setText, setTone, setEnabled,
--                  setIcon, onClick }
------------------------------------------------------------------
local function pressJuice(click: GuiButton, scale: UIScale, face: GuiObject, extra: GuiObject?)
	local hovered = false
	local function rest() return hovered and 1.05 or 1 end
	if not UILib.IsTouch then
		click.MouseEnter:Connect(function() hovered = true; tween(scale, { Scale = 1.05 }, 0.12) end)
		click.MouseLeave:Connect(function()
			hovered = false
			tween(scale, { Scale = 1 }, 0.12)
			face.Position = UDim2.fromOffset(0, 0)
			if extra then extra.Position = UDim2.fromOffset(0, 0) end
		end)
	end
	click.MouseButton1Down:Connect(function()
		tween(scale, { Scale = 0.95 }, 0.07)
		face.Position = UDim2.fromOffset(0, 4)
		if extra then extra.Position = UDim2.fromOffset(0, 4) end
	end)
	local function up()
		tween(scale, { Scale = rest() }, 0.16, Enum.EasingStyle.Back)
		face.Position = UDim2.fromOffset(0, 0)
		if extra then extra.Position = UDim2.fromOffset(0, 0) end
	end
	click.MouseButton1Up:Connect(up)
	click.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then up() end
	end)
end

function UILib.button(o)
	o = o or {}
	local tone = Tones[o.tone or "Green"] or Tones.Green
	local radius = o.radius or 16
	local z = o.z or 1
	local root = make("Frame", {
		Name = o.name or "Button", BackgroundTransparency = 1,
		Size = o.size or UDim2.fromOffset(170, 58), Position = o.position or UDim2.new(),
		AnchorPoint = o.anchor or Vector2.zero, LayoutOrder = o.order or 0, ZIndex = z, Parent = o.parent,
	})
	local scale = make("UIScale", { Name = "PressScale", Parent = root }) :: UIScale
	local body = make("Frame", {
		Name = "Body", Size = UDim2.fromScale(1, 1), BackgroundColor3 = tone.shadow,
		BorderSizePixel = 0, ZIndex = z, Parent = root,
	})
	corner(body, radius)
	stroke(body, C.Ink, 4, true)
	local face = make("Frame", {
		Name = "Face", Size = UDim2.new(1, 0, 1, -7), BackgroundColor3 = C.White,
		BorderSizePixel = 0, ZIndex = z, Parent = body,
	})
	corner(face, radius - 1)
	local grad = make("UIGradient", { Rotation = 90, Color = ColorSequence.new(tone.top, tone.base), Parent = face })
	local shine = make("Frame", {
		Name = "Shine", BackgroundColor3 = C.White, BackgroundTransparency = 0.68,
		Size = UDim2.new(1, -12, 0.42, 0), Position = UDim2.fromOffset(6, 4),
		BorderSizePixel = 0, ZIndex = z, Parent = face,
	})
	corner(shine, math.max(4, radius - 5))
	local content = make("Frame", {
		Name = "Content", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = z, Parent = face,
	})
	UILib.list(content, "x", 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)

	local iconImg
	local function ensureIcon()
		if iconImg then return iconImg end
		local s = o.iconSize or math.floor((o.textSize or 26) * 1.25)
		iconImg = UILib.image(content, nil, { size = UDim2.fromOffset(s, s), order = 1, z = z })
		return iconImg
	end
	if o.icon then ensureIcon().Image = resolveIcon(o.icon) end

	local label = UILib.text(content, {
		text = o.text or "", size = o.textSize or 26, font = o.font or F.Display, autoX = true,
		frameSize = UDim2.fromScale(0, 1), order = 2, z = z,
	})

	local disabledShade = make("Frame", {
		Name = "Disabled", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.55, Visible = false,
		Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, ZIndex = z + 2, Parent = root,
	})
	corner(disabledShade, radius)

	local click = make("TextButton", {
		Name = "Click", Text = "", BackgroundTransparency = 1, AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1), ZIndex = z + 3, Parent = root,
	}) :: TextButton
	pressJuice(click, scale, face)

	local handlers = {}
	if o.onClick then table.insert(handlers, o.onClick) end
	local enabled = true
	click.Activated:Connect(function()
		if not enabled then return end
		for _, fn in handlers do task.spawn(fn) end
	end)

	local h = { Instance = root, Button = click, Label = label, Face = face }
	function h.setText(t: string) label.Text = t end
	function h.setTone(name: string)
		local t = Tones[name]
		if not t then return end
		body.BackgroundColor3 = t.shadow
		grad.Color = ColorSequence.new(t.top, t.base)
	end
	function h.setEnabled(b: boolean)
		enabled = b
		disabledShade.Visible = not b
	end
	function h.setIcon(icon: string?)
		if not icon then
			if iconImg then iconImg.Visible = false end
			return
		end
		local img = ensureIcon()
		img.Visible = true
		img.Image = resolveIcon(icon)
	end
	function h.onClick(fn) table.insert(handlers, fn) end
	return h
end

-- round red close button with the X texture
function UILib.closeButton(parent: Instance, onClick, z: number?)
	z = z or 1
	local root = make("Frame", {
		Name = "Close", Size = UDim2.fromOffset(56, 56), BackgroundTransparency = 1, ZIndex = z, Parent = parent,
	})
	local scale = make("UIScale", { Parent = root }) :: UIScale
	local body = make("Frame", {
		Name = "Body", Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.CrimsonDeep, BorderSizePixel = 0,
		ZIndex = z, Parent = root,
	})
	corner(body, 999)
	stroke(body, C.Ink, 4, true)
	local face = make("Frame", {
		Name = "Face", Size = UDim2.new(1, 0, 1, -6), BackgroundColor3 = C.White, BorderSizePixel = 0,
		ZIndex = z, Parent = body,
	})
	corner(face, 999)
	gradient(face, C.CrimsonTop, C.Crimson)
	make("Frame", {
		Name = "Shine", BackgroundColor3 = C.White, BackgroundTransparency = 0.6, BorderSizePixel = 0,
		Size = UDim2.new(0.62, 0, 0.3, 0), Position = UDim2.fromScale(0.19, 0.07), ZIndex = z, Parent = face,
	}, { make("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
	UILib.image(face, UILib.Tex.close, {
		size = UDim2.fromScale(0.78, 0.78), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5), z = z,
	})
	local click = make("TextButton", {
		Name = "Click", Text = "", BackgroundTransparency = 1, AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1), ZIndex = z + 3, Parent = root,
	}) :: TextButton
	pressJuice(click, scale, face)
	if onClick then click.Activated:Connect(onClick) end
	return root, click
end

------------------------------------------------------------------
-- badge — small tilted tag (NEW! / HOT! / OWNED / x2 ...)
------------------------------------------------------------------
function UILib.badge(parent: Instance, text: string, tone: string?, rotation: number?, z: number?)
	local t = Tones[tone or "Red"] or Tones.Red
	z = z or 5
	local b = make("Frame", {
		Name = "Badge", BackgroundColor3 = C.White, Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X, Rotation = rotation or -9, ZIndex = z, Parent = parent,
	})
	gradient(b, t.top, t.base)
	corner(b, 10)
	stroke(b, C.Ink, 3, true)
	UILib.pad(b, 12, 0, 12, 0)
	UILib.text(b, { text = text, size = 17, autoX = true, frameSize = UDim2.fromScale(0, 1), z = z, shadow = 2 })
	return b
end

------------------------------------------------------------------
-- level pips (filled gold / empty)
------------------------------------------------------------------
function UILib.pips(parent: Instance, level: number, max: number, order: number?)
	local row = make("Frame", {
		Name = "Pips", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16),
		LayoutOrder = order or 0, Parent = parent,
	})
	UILib.list(row, "x", 6, nil, Enum.VerticalAlignment.Center)
	for i = 1, max do
		local p = make("Frame", {
			Size = UDim2.fromOffset(30, 12), BackgroundColor3 = i <= level and C.White or C.CreamLine,
			BorderSizePixel = 0, LayoutOrder = i, Parent = row,
		})
		corner(p, 6)
		stroke(p, C.Ink, 2.5, true)
		if i <= level then gradient(p, C.GoldTop, C.GoldDeep) end
	end
	UILib.body(row, {
		text = ("LV %d/%d"):format(level, max), font = F.Display, size = 15, color = C.Brown,
		frameSize = UDim2.fromOffset(70, 16), order = max + 1,
	})
	return row
end

------------------------------------------------------------------
-- panels (exclusive: opening one closes the previous)
-- o: name, title, icon, width, height, onClose
-- returns { holder, content, inner, close(), onClose(fn), alive }
------------------------------------------------------------------
local activePanel = nil
local function bulbPositions(w: number, h: number)
	local pts, band, step = {}, 12, 30
	for x = 40, w - 40, step do table.insert(pts, Vector2.new(x, band)) end
	for y = 40 + step, h - 40 - step, step do table.insert(pts, Vector2.new(w - band, y)) end
	for x = w - 40, 40, -step do table.insert(pts, Vector2.new(x, h - band)) end
	for y = h - 40 - step, 40 + step, -step do table.insert(pts, Vector2.new(band, y)) end
	return pts
end

function UILib.panel(o)
	o = o or {}
	local sc = UILib.getScreen()
	local w, h = o.width or 900, o.height or 520
	local name = o.name or "Panel"
	local existing = sc:FindFirstChild(name)
	if existing then existing:Destroy() end
	if activePanel and activePanel.alive then activePanel.close(true) end

	local Z = 30
	local backdrop = make("TextButton", {
		Name = name .. "Backdrop", Text = "", AutoButtonColor = false, Modal = true,
		BackgroundColor3 = C.Ink, BackgroundTransparency = 1, BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, 80), Position = UDim2.fromOffset(0, -60), ZIndex = Z, Parent = sc,
	})
	tween(backdrop, { BackgroundTransparency = 0.45 }, 0.2)

	local holder = make("Frame", {
		Name = name, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.53),
		Size = UDim2.fromOffset(w, h), BackgroundTransparency = 1, ZIndex = Z + 1, Parent = sc,
	})
	UILib.autoScale(holder, { fit = Vector2.new(w, h) })
	local popper = make("Frame", {
		Name = "Pop", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = Z + 1, Parent = holder,
	})
	local pop = make("UIScale", { Scale = 0.55, Parent = popper }) :: UIScale

	-- hard drop shadow + velvet frame
	local shadow = make("Frame", {
		Name = "HardShadow", BackgroundColor3 = C.Ink, Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromOffset(0, 12), BorderSizePixel = 0, ZIndex = Z, Parent = popper,
	})
	corner(shadow, 36)
	local velvet = make("Frame", {
		Name = "Velvet", BackgroundColor3 = C.White, Size = UDim2.fromScale(1, 1),
		BorderSizePixel = 0, ZIndex = Z + 1, Parent = popper,
	})
	corner(velvet, 36)
	gradient(velvet, C.CrimsonTop, C.CrimsonDeep)
	stroke(velvet, C.Ink, 5, true)

	-- marquee bulbs (chase animation below)
	local bulbs = {}
	for i, p in bulbPositions(w, h) do
		local glow = UILib.image(velvet, UILib.Tex.glow, {
			size = UDim2.fromOffset(34, 34), anchor = Vector2.new(0.5, 0.5),
			position = UDim2.fromOffset(p.X, p.Y), color = C.GoldTop, transparency = 0.3, z = Z + 1,
		})
		local b = make("Frame", {
			Name = "Bulb", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(p.X, p.Y),
			Size = UDim2.fromOffset(11, 11), BackgroundColor3 = C.GoldTop, BorderSizePixel = 0,
			ZIndex = Z + 1, Parent = velvet,
		})
		corner(b, 999)
		stroke(b, C.GoldShadow, 1.5, true)
		bulbs[i] = { bulb = b, glow = glow }
	end

	-- thin highlight line + cream inner with gold trim, pattern and top shade
	local trim = make("Frame", {
		Name = "Trim", BackgroundTransparency = 1, Position = UDim2.fromOffset(18, 18),
		Size = UDim2.new(1, -36, 1, -36), ZIndex = Z + 1, Parent = velvet,
	})
	corner(trim, 27)
	stroke(trim, C.GoldTop, 2, true, 0.15)
	local inner = make("Frame", {
		Name = "Inner", BackgroundColor3 = C.White, Position = UDim2.fromOffset(24, 24),
		Size = UDim2.new(1, -48, 1, -48), BorderSizePixel = 0, ZIndex = Z + 1, Parent = velvet,
	})
	corner(inner, 22)
	gradient(inner, C.Cream, C.CreamRow)
	stroke(inner, C.Gold, 4, true)
	local pattern = make("ImageLabel", {
		Name = "Pattern", BackgroundTransparency = 1, Image = UILib.Tex.pattern, ScaleType = Enum.ScaleType.Tile,
		TileSize = UDim2.fromOffset(34, 34), ImageColor3 = hex("#C98A3A"), ImageTransparency = 0.88,
		Size = UDim2.fromScale(1, 1), ZIndex = Z + 1, Parent = inner,
	})
	corner(pattern, 22)
	local shade = make("Frame", {
		Name = "TopShade", BackgroundColor3 = C.Ink, Size = UDim2.new(1, 0, 0, 28), BorderSizePixel = 0,
		ZIndex = Z + 1, Parent = inner,
	})
	corner(shade, 22)
	make("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(0.8, 1), Parent = shade })
	local content = make("Frame", {
		Name = "Content", BackgroundTransparency = 1, Position = UDim2.fromOffset(22, 44),
		Size = UDim2.new(1, -44, 1, -62), ZIndex = Z + 2, Parent = inner,
	})

	-- ribbon title (tails + gold band + icon + extruded title)
	if o.title then
		local tw = TextService:GetTextSize(o.title, 46, F.Display, Vector2.new(2000, 100)).X
		local hasIcon = o.icon ~= nil
		local RW = tw + (hasIcon and 150 or 100)
		local ribbon = make("Frame", {
			Name = "Ribbon", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, -42),
			Size = UDim2.fromOffset(RW, 78), BackgroundTransparency = 1, ZIndex = Z + 4, Parent = popper,
		})
		UILib.image(ribbon, UILib.Tex.ribbonTail, {
			size = UDim2.fromOffset(62, 52), position = UDim2.fromOffset(-2, 24), z = Z + 3,
		})
		UILib.image(ribbon, UILib.Tex.ribbonTail, {
			size = UDim2.fromOffset(62, 52), position = UDim2.new(1, -60, 0, 24), rotation = 180, z = Z + 3,
		})
		local band = make("Frame", {
			Name = "Band", BackgroundColor3 = C.White, Position = UDim2.fromOffset(30, 4),
			Size = UDim2.new(1, -60, 0, 62), BorderSizePixel = 0, ZIndex = Z + 4, Parent = ribbon,
		})
		corner(band, 14)
		gradient(band, C.GoldTop, C.GoldDeep, C.Gold)
		stroke(band, C.Ink, 5, true)
		make("Frame", {
			Name = "Shine", BackgroundColor3 = C.White, BackgroundTransparency = 0.5, BorderSizePixel = 0,
			Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -20, 0, 16), ZIndex = Z + 4, Parent = band,
		}, { make("UICorner", { CornerRadius = UDim.new(0, 8) }) })
		local row = make("Frame", {
			Name = "Row", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = Z + 5, Parent = band,
		})
		UILib.list(row, "x", 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
		if hasIcon then
			UILib.image(row, o.icon, { size = UDim2.fromOffset(66, 66), order = 1, z = Z + 5 })
		end
		UILib.text(row, {
			text = o.title, size = 46, autoX = true, frameSize = UDim2.fromScale(0, 1), order = 2, z = Z + 5,
			stroke = 5, shadow = 5, gradient = { C.White, C.GoldTop },
		})
	end

	local p = { holder = holder, content = content, inner = inner, alive = true }
	local closers = {}
	if o.onClose then table.insert(closers, o.onClose) end

	local closeBtn = UILib.closeButton(popper, nil, Z + 6)
	closeBtn.Position = UDim2.new(1, -40, 0, -24)

	UILib.blur(true)
	local released = false
	function p.close(instant: boolean?)
		if not p.alive then return end
		p.alive = false
		if activePanel == p then activePanel = nil end
		if not released then released = true; UILib.blur(false) end
		for _, fn in closers do task.spawn(fn) end
		if instant then
			holder:Destroy(); backdrop:Destroy()
			return
		end
		tween(pop, { Scale = 0.6 }, 0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tween(backdrop, { BackgroundTransparency = 1 }, 0.14)
		task.delay(0.15, function() holder:Destroy(); backdrop:Destroy() end)
	end
	function p.onClose(fn) table.insert(closers, fn) end
	closeBtn:FindFirstChild("Click").Activated:Connect(function() p.close() end)
	backdrop.Activated:Connect(function() p.close() end)
	holder.Destroying:Connect(function()
		if p.alive then
			p.alive = false
			if activePanel == p then activePanel = nil end
			if not released then released = true; UILib.blur(false) end
			for _, fn in closers do task.spawn(fn) end
			if backdrop.Parent then backdrop:Destroy() end
		end
	end)

	tween(pop, { Scale = 1 }, 0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

	-- marquee chase: alternate bulbs swap every 0.35 s while open
	task.spawn(function()
		local phase = 0
		while p.alive and holder.Parent do
			phase = 1 - phase
			for i, b in bulbs do
				local on = (i + phase) % 2 == 0
				b.bulb.BackgroundColor3 = on and C.GoldTop or C.GoldDeep
				b.glow.Visible = on
			end
			task.wait(0.35)
		end
	end)

	activePanel = p
	return p
end

function UILib.closeActivePanel()
	if activePanel and activePanel.alive then activePanel.close() end
end
function UILib.hasOpenPanel(): boolean
	return activePanel ~= nil and activePanel.alive
end

UserInputService.InputBegan:Connect(function(input, gp)
	if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then
		if activePanel and activePanel.alive then activePanel.close() end
	end
end)

------------------------------------------------------------------
-- tabs — returns { select(id) }; onSelect(id) fires on change
------------------------------------------------------------------
function UILib.tabs(parent: Instance, items, onSelect, initial)
	local row = make("Frame", {
		Name = "Tabs", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 50), Parent = parent,
	})
	UILib.list(row, "x", 10, nil, Enum.VerticalAlignment.Center)
	local entries = {}
	local current
	local api = {}
	local function style(e, on: boolean)
		e.frame.BackgroundColor3 = C.White
		e.grad.Color = on and ColorSequence.new(C.CrimsonTop, C.Crimson) or ColorSequence.new(C.Cream, C.CreamRow)
		e.stroke.Thickness = on and 4 or 3
		e.onLabel.Visible = on
		e.offLabel.Visible = not on
	end
	function api.select(id)
		if current == id then return end
		current = id
		for _, e in entries do style(e, e.id == id) end
		if onSelect then task.spawn(onSelect, id) end
	end
	for i, it in items do
		local f = make("Frame", {
			Name = "Tab_" .. it.id, BackgroundColor3 = C.White, Size = UDim2.fromOffset(0, 44),
			AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = i, Parent = row,
		})
		corner(f, 14)
		local grad = make("UIGradient", { Rotation = 90, Parent = f })
		local st = stroke(f, C.Ink, 3, true)
		UILib.pad(f, 22, 0, 22, 0)
		local onLabel = select(2, UILib.text(f, {
			text = it.label, size = 22, autoX = true, frameSize = UDim2.fromScale(0, 1), shadow = 3,
		}))
		local offLabel = UILib.body(f, {
			text = it.label, font = F.Display, size = 22, color = C.Brown, transparency = 0.2,
			frameSize = UDim2.fromScale(0, 1), autoX = true, xAlign = Enum.TextXAlignment.Center,
		})
		local click = make("TextButton", {
			Text = "", BackgroundTransparency = 1, Size = UDim2.new(1, 44, 1, 0), Position = UDim2.fromOffset(-22, 0),
			ZIndex = 5, Parent = f,
		})
		local e = { id = it.id, frame = f, grad = grad, stroke = st, onLabel = onLabel, offLabel = offLabel }
		table.insert(entries, e)
		click.Activated:Connect(function() api.select(it.id) end)
	end
	if initial then
		current = initial
		for _, e in entries do style(e, e.id == initial) end
	end
	api.Instance = row
	return api
end

------------------------------------------------------------------
-- item card (shop / inventory / store)
-- o: parent, tone, title, stat, icon, order, button = { tone, text, icon,
--    onClick }, badge = { text, tone }, dim
-- returns { Instance, button }
------------------------------------------------------------------
function UILib.card(o)
	local t = Tones[o.tone or "Blue"] or Tones.Blue
	local root = make("Frame", {
		Name = o.name or "Card", BackgroundTransparency = 1, Size = o.size or UDim2.fromOffset(204, 296),
		LayoutOrder = o.order or 0, Parent = o.parent,
	})
	local hover = make("UIScale", { Parent = root }) :: UIScale
	local body = make("Frame", {
		Name = "Body", BackgroundColor3 = C.White, Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, Parent = root,
	})
	corner(body, 24)
	gradient(body, t.top, t.base)
	stroke(body, C.Ink, 4, true)

	-- CanvasGroup clips to the rounded corners. Its background lives on a child
	-- frame: a UIGradient on the CanvasGroup itself would tint every descendant.
	local stage = make("CanvasGroup", {
		Name = "Stage", BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 0, 132), BorderSizePixel = 0, Parent = body,
	})
	corner(stage, 18)
	local stageBg = make("Frame", {
		Name = "Bg", BackgroundColor3 = C.White, Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, Parent = stage,
	})
	gradient(stageBg, t.base, t.shadow)
	-- static on purpose: animating inside a CanvasGroup re-renders it every frame
	UILib.image(stage, UILib.Tex.sunburst, {
		size = UDim2.fromOffset(300, 300), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.62),
		transparency = 0.84,
	})
	UILib.image(stage, UILib.Tex.glow, {
		size = UDim2.fromOffset(190, 160), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.55),
		transparency = 0.35,
	})
	make("Frame", {
		Name = "Floor", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.7, BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 1, -16), Size = UDim2.fromOffset(112, 18),
		Parent = stage,
	}, { make("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
	local icon = UILib.image(stage, o.icon, {
		size = UDim2.fromOffset(118, 118), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5),
	})
	local stageRing = make("Frame", {
		Name = "StageRing", BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 0, 132), Parent = body,
	})
	corner(stageRing, 18)
	stroke(stageRing, C.Ink, 3, true)

	UILib.text(body, {
		name = "Title", text = o.title or "", size = o.titleSize or 22,
		frameSize = UDim2.new(1, -12, 0, 30), position = UDim2.fromOffset(6, 150),
	})
	local statPill = make("Frame", {
		Name = "Stat", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 186),
		Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = C.Cream,
		Parent = body,
	})
	corner(statPill, 999)
	stroke(statPill, C.Ink, 2.5, true)
	UILib.pad(statPill, 12, 0, 12, 0)
	UILib.body(statPill, {
		text = o.stat or "", size = 13, font = F.Heavy, autoX = true, frameSize = UDim2.fromScale(0, 1),
		xAlign = Enum.TextXAlignment.Center,
	})

	local btn
	if o.button then
		btn = UILib.button({
			parent = body, tone = o.button.tone or "Green", text = o.button.text or "",
			icon = o.button.icon, textSize = 24, iconSize = 28,
			size = UDim2.new(1, -20, 0, 60), position = UDim2.new(0, 10, 1, -72), onClick = o.button.onClick,
		})
	end
	if o.badge then
		local b = UILib.badge(root, o.badge.text, o.badge.tone or "Red", -10, 8)
		b.AnchorPoint = Vector2.new(1, 0)
		b.Position = UDim2.new(1, 8, 0, -12)
	end
	if o.dim then
		icon.ImageTransparency = 0.25
		icon.ImageColor3 = Color3.fromRGB(150, 150, 160)
	end
	if not UILib.IsTouch then
		root.MouseEnter:Connect(function() tween(hover, { Scale = 1.04 }, 0.15) end)
		root.MouseLeave:Connect(function() tween(hover, { Scale = 1 }, 0.15) end)
	end
	return { Instance = root, button = btn, icon = icon }
end

------------------------------------------------------------------
-- list row (upgrades / manage / stats)
-- o: parent, tone, icon, title, desc, order, height
-- returns { Instance, info (Frame), right (Frame for buttons) }
------------------------------------------------------------------
function UILib.row(o)
	local t = Tones[o.tone or "Gold"] or Tones.Gold
	local hgt = o.height or 96
	local r = make("Frame", {
		Name = o.name or "Row", BackgroundColor3 = C.Cream, Size = UDim2.new(1, -8, 0, hgt),
		LayoutOrder = o.order or 0, BorderSizePixel = 0, Parent = o.parent,
	})
	corner(r, 20)
	stroke(r, C.Ink, 3.5, true)
	local tileSize = hgt - 20
	local tile = make("Frame", {
		Name = "Tile", BackgroundColor3 = C.White, Position = UDim2.fromOffset(10, 10),
		Size = UDim2.fromOffset(tileSize, tileSize), BorderSizePixel = 0, Parent = r,
	})
	corner(tile, 18)
	gradient(tile, t.top, t.base)
	stroke(tile, C.Ink, 3.5, true)
	UILib.image(tile, UILib.Tex.glow, {
		size = UDim2.fromScale(1.1, 1.1), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5),
		transparency = 0.45,
	})
	UILib.image(tile, o.icon, {
		size = UDim2.fromScale(1.05, 1.05), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.46),
	})
	local info = make("Frame", {
		Name = "Info", BackgroundTransparency = 1, Position = UDim2.fromOffset(tileSize + 26, 0),
		Size = UDim2.new(1, -(tileSize + 26) - (o.rightWidth or 210), 1, 0), Parent = r,
	})
	UILib.list(info, "y", 3, nil, Enum.VerticalAlignment.Center)
	UILib.body(info, {
		name = "Title", text = o.title or "", font = F.Display, size = 26, color = C.Crimson,
		frameSize = UDim2.new(1, 0, 0, 28), order = 1,
	})
	if o.desc then
		UILib.body(info, {
			name = "Desc", text = o.desc, size = 14, frameSize = UDim2.new(1, 0, 0, 18), order = 2, wrap = true,
			autoY = true,
		})
	end
	local right = make("Frame", {
		Name = "Right", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0), Size = UDim2.fromOffset(0, hgt - 24),
		AutomaticSize = Enum.AutomaticSize.X, Parent = r,
	})
	UILib.list(right, "x", 8, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
	return { Instance = r, info = info, right = right }
end

-- scrolling container with a vertical list or a grid
function UILib.scroller(parent: Instance, o)
	o = o or {}
	local s = make("ScrollingFrame", {
		Name = o.name or "Scroll", BackgroundTransparency = 1, BorderSizePixel = 0,
		Size = o.size or UDim2.fromScale(1, 1), Position = o.position or UDim2.new(),
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 8, ScrollBarImageColor3 = C.Crimson, ScrollingDirection = Enum.ScrollingDirection.Y,
		LayoutOrder = o.order or 0, Parent = parent,
	})
	UILib.pad(s, 6, 14, 14, 14)
	if o.grid then
		make("UIGridLayout", {
			CellSize = o.cell or UDim2.fromOffset(204, 296), CellPadding = o.gap or UDim2.fromOffset(20, 26),
			SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Left, Parent = s,
		})
	else
		UILib.list(s, "y", o.padding or 12)
	end
	return s
end

------------------------------------------------------------------
-- HUD pieces
------------------------------------------------------------------
-- currency pill: dark capsule, big overlapping icon, value, "+" button
function UILib.currencyPill(parent: Instance, o)
	local root = make("Frame", {
		Name = o.name or "CurrencyPill", Size = UDim2.fromOffset(o.width or 228, 52),
		Position = o.position or UDim2.new(), BackgroundColor3 = C.Ink, BackgroundTransparency = 0.2,
		LayoutOrder = o.order or 0, Parent = parent,
	})
	corner(root, 999)
	stroke(root, C.GoldDeep, 3, true)
	local pop = make("UIScale", { Parent = root }) :: UIScale
	UILib.image(root, o.icon, { size = UDim2.fromOffset(76, 76), position = UDim2.fromOffset(-22, -13), z = 2 })
	local value = UILib.text(root, {
		text = o.text or "0", font = F.Number, size = 28, xAlign = Enum.TextXAlignment.Left,
		frameSize = UDim2.new(1, -116, 1, 0), position = UDim2.fromOffset(60, 0), stroke = 3.5, shadow = 3,
	})
	if o.onPlus then
		UILib.button({
			parent = root, tone = o.plusTone or "Green", text = "+", font = F.Heavy, textSize = 30,
			size = UDim2.fromOffset(46, 42), anchor = Vector2.new(1, 0.5), position = UDim2.new(1, -4, 0.5, 0),
			radius = 13, onClick = o.onPlus,
		})
	end
	local api = { Instance = root, Value = value }
	function api.set(n: number, formatter)
		UILib.countTo(value, n, formatter)
	end
	function api.bump()
		pop.Scale = 1.08
		tween(pop, { Scale = 1 }, 0.3, Enum.EasingStyle.Back)
	end
	return api
end

-- square action tile for the HUD rail: own tone, overflowing icon, label
function UILib.railButton(parent: Instance, o)
	local t = Tones[o.tone or "Gold"] or Tones.Gold
	local root = make("Frame", {
		Name = o.name or ("Rail_" .. (o.label or "")), BackgroundTransparency = 1,
		Size = UDim2.fromOffset(92, 104), LayoutOrder = o.order or 0, Parent = parent,
	})
	local scale = make("UIScale", { Parent = root }) :: UIScale
	local body = make("Frame", {
		Name = "Body", BackgroundColor3 = t.shadow, Position = UDim2.fromOffset(4, 12),
		Size = UDim2.fromOffset(84, 84), BorderSizePixel = 0, Parent = root,
	})
	corner(body, 24)
	stroke(body, C.Ink, 4, true)
	local mover = make("Frame", {
		Name = "Mover", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = root,
	})
	local face = make("Frame", {
		Name = "Face", BackgroundColor3 = C.White, Position = UDim2.fromOffset(4, 6),
		Size = UDim2.fromOffset(84, 80), BorderSizePixel = 0, Parent = mover,
	})
	corner(face, 24)
	gradient(face, t.top, t.base)
	stroke(face, C.Ink, 4, true)
	make("Frame", {
		Name = "Shine", BackgroundColor3 = C.White, BackgroundTransparency = 0.7, BorderSizePixel = 0,
		Position = UDim2.fromOffset(7, 5), Size = UDim2.fromOffset(70, 30), Parent = face,
	}, { make("UICorner", { CornerRadius = UDim.new(0, 16) }) })
	local icon = UILib.image(mover, o.icon, { size = UDim2.fromOffset(82, 82), position = UDim2.fromOffset(5, -12) })
	UILib.text(mover, {
		text = o.label or "", size = 19, frameSize = UDim2.fromOffset(124, 26), position = UDim2.fromOffset(-16, 72),
		stroke = 3.5, shadow = 3,
	})
	local alert = make("Frame", {
		Name = "Alert", BackgroundColor3 = C.White, Size = UDim2.fromOffset(30, 30),
		Position = UDim2.fromOffset(68, -4), Visible = false, Parent = root,
	})
	corner(alert, 999)
	gradient(alert, C.CrimsonTop, C.Crimson)
	stroke(alert, C.Ink, 3, true)
	UILib.text(alert, { text = "!", size = 20, shadow = 2, stroke = 2 })
	local alertScale = make("UIScale", { Parent = alert }) :: UIScale

	local click = make("TextButton", {
		Name = "Click", Text = "", BackgroundTransparency = 1, AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1), ZIndex = 5, Parent = root,
	}) :: TextButton
	pressJuice(click, scale, mover)
	if not UILib.IsTouch then
		click.MouseEnter:Connect(function() tween(icon, { Rotation = -8 }, 0.15) end)
		click.MouseLeave:Connect(function() tween(icon, { Rotation = 0 }, 0.15) end)
	end
	if o.onClick then click.Activated:Connect(o.onClick) end

	local api = { Instance = root }
	local pulsing = false
	function api.setAlert(on: boolean)
		alert.Visible = on
		if on and not pulsing then
			pulsing = true
			task.spawn(function()
				while alert.Visible and root.Parent do
					tween(alertScale, { Scale = 1.18 }, 0.35, Enum.EasingStyle.Sine)
					task.wait(0.4)
					tween(alertScale, { Scale = 1 }, 0.35, Enum.EasingStyle.Sine)
					task.wait(0.9)
				end
				pulsing = false
			end)
		end
	end
	return api
end

------------------------------------------------------------------
-- toasts — cream cards that slide in at the top centre and stack
-- UILib.toast(title, kind?, message?) ; kind = "income" | "unlock" | "error" | "info"
-- (a Color3 is still accepted as `kind` for older call sites)
------------------------------------------------------------------
local TOAST_KINDS = {
	income = { tone = "Green", icon = "coin" },
	unlock = { tone = "Gold", icon = "star" },
	error = { tone = "Red", icon = "close" },
	info = { tone = "Blue", icon = "gem" },
	ticket = { tone = "Pink", icon = "ticket" },
}
-- Two stacks: top-centre normally; top-right while a panel is open (the HUD is
-- dimmed then, and panels are centred), so toasts never cover a panel.
local toastHosts: {[string]: Frame} = {}
local activeToasts: {[string]: {Frame}} = { top = {}, side = {} }
local function getToastHost(where: string): Frame
	local h = toastHosts[where]
	if h and h.Parent then return h end
	local side = where == "side"
	h = make("Frame", {
		Name = side and "ToastsSide" or "Toasts", BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(side and 1 or 0.5, 0),
		Position = side and UDim2.new(1, -10, 0, 12) or UDim2.new(0.5, 0, 0, 12),
		Size = UDim2.fromOffset(460, 300), ZIndex = 60, Parent = UILib.getScreen(),
	}) :: Frame
	UILib.autoScale(h, { mult = side and 0.85 or 1 })
	toastHosts[where] = h
	return h
end
local function reflow(where: string)
	local y = 0
	for i = #activeToasts[where], 1, -1 do -- newest on top
		local t = activeToasts[where][i]
		tween(t, { Position = UDim2.new(0.5, 0, 0, y) }, 0.22)
		y += t.Size.Y.Offset + 10
	end
end
function UILib.toast(title: string, kind, message: string?)
	if typeof(kind) == "Color3" then
		kind = (kind == C.Green or kind == C.GreenTop) and "income"
			or ((kind == C.Crimson or kind == C.Red) and "error" or "unlock")
	end
	local k = TOAST_KINDS[kind or "info"] or TOAST_KINDS.info
	local t = Tones[k.tone]
	local where = UILib.hasOpenPanel() and "side" or "top"
	local host = getToastHost(where)
	local list = activeToasts[where]
	-- slide in from above the screen (top stack) or from the right edge (side stack)
	local offscreen = where == "side" and UDim2.new(1.6, 0, 0, 0) or UDim2.new(0.5, 0, 0, -140)
	local card = make("Frame", {
		Name = "Toast", AnchorPoint = Vector2.new(0.5, 0), Position = offscreen,
		Size = UDim2.fromOffset(440, message and 82 or 70), BackgroundColor3 = C.White, ZIndex = 60, Parent = host,
	})
	corner(card, 22)
	gradient(card, C.Cream, C.CreamRow)
	stroke(card, C.Ink, 4, true)
	local tile = make("Frame", {
		BackgroundColor3 = C.White, Position = UDim2.fromOffset(10, 8), ZIndex = 60,
		Size = UDim2.fromOffset(message and 64 or 54, message and 64 or 54), Parent = card,
	})
	corner(tile, 16)
	gradient(tile, t.top, t.base)
	stroke(tile, C.Ink, 3, true)
	UILib.image(tile, k.icon, {
		size = UDim2.fromScale(0.86, 0.86), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5), z = 60,
	})
	local textX = (message and 64 or 54) + 22
	UILib.body(card, {
		text = title, font = F.Display, size = message and 24 or 22, color = t.base, z = 60,
		frameSize = UDim2.new(1, -textX - 12, 0, message and 30 or 54), position = UDim2.fromOffset(textX, message and 10 or 8),
		wrap = true,
	})
	if message then
		UILib.body(card, {
			text = message, size = 13, z = 60, wrap = true,
			frameSize = UDim2.new(1, -textX - 12, 0, 34), position = UDim2.fromOffset(textX, 40),
			yAlign = Enum.TextYAlignment.Top,
		})
	end
	table.insert(list, card)
	while #list > 3 do
		local old = table.remove(list, 1)
		if old then old:Destroy() end
	end
	reflow(where)
	task.delay(3, function()
		if not card.Parent then return end
		local idx = table.find(list, card)
		if idx then table.remove(list, idx) end
		tween(card, { Position = offscreen }, 0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		task.delay(0.26, function() card:Destroy(); reflow(where) end)
	end)
end

-- "+$250" that floats up out of a GUI object (parented to it, so it inherits
-- the HUD's scale) and fades
function UILib.floatText(text: string, color: Color3?, from: GuiObject)
	local face, holder = UILib.text(from, {
		text = text, font = F.Number, size = 26, color = color or C.GreenTop, stroke = 3, shadow = 3,
		frameSize = UDim2.fromOffset(200, 34), anchor = Vector2.new(0.5, 0),
		position = UDim2.new(0.55, 0, 1, 2), z = 10,
	})
	tween(holder, { Position = UDim2.new(0.55, 0, 1, 40) }, 0.9, Enum.EasingStyle.Quad)
	task.delay(0.45, function()
		if face.Parent then tween(face, { TextTransparency = 1 }, 0.45) end
	end)
	task.delay(0.95, function() holder:Destroy() end)
end

------------------------------------------------------------------
-- leaderstats + catalog helpers
------------------------------------------------------------------
function UILib.getCashValue(): IntValue
	local ls = player:WaitForChild("leaderstats")
	return ls:WaitForChild("Cash") :: IntValue
end

local catalog
function UILib.getCatalog()
	if not catalog then
		local Remotes = require(Common:WaitForChild("Remotes"))
		local ok, res = pcall(function() return Remotes.GetCatalog():InvokeServer() end)
		if ok then catalog = res end
	end
	return catalog
end

------------------------------------------------------------------
-- client state cache (mirrors server DataUpdated snapshots)
------------------------------------------------------------------
UILib.state = { cash = 0, tickets = 0, inventory = {}, placed = {}, staff = {}, stats = {}, upgrades = {} }
UILib.stateTime = os.clock()
local subs: {(any) -> ()} = {}

function UILib.setState(snap)
	if snap then
		UILib.state = snap
		UILib.stateTime = os.clock()
	end
	for _, fn in subs do task.spawn(fn, UILib.state) end
end

function UILib.subscribe(fn): () -> ()
	table.insert(subs, fn)
	task.spawn(fn, UILib.state)
	return function()
		local i = table.find(subs, fn)
		if i then table.remove(subs, i) end
	end
end

-- seconds left on a server-sent countdown field, corrected for time since the snapshot
function UILib.secondsLeft(field: number?): number
	return math.max(0, (field or 0) - (os.clock() - UILib.stateTime))
end

return UILib
