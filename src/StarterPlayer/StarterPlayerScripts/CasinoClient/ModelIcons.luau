--!nonstrict
-- ModelIcons.luau — the ACTUAL machines, stands, decor pieces and staff as UI
-- icons: a ViewportFrame with the real model, so players see exactly what they
-- buy and place.
--   * sources (the server publishes them at boot, they replicate):
--       "machine" (also "stand" / "concession")  ReplicatedStorage.MachinePreviews/<catalog id>
--       "decor"                                  ReplicatedStorage.DecorPreviews/<decor id>
--       "staff"                                  ReplicatedStorage.StaffTemplates/<staff id> (R15 rig)
--     Model space: ground at y = 0, centred, FRONT = -Z (a rig faces its root's LookVector).
--   * the look: one 3/4 "hero" camera for everything (the front and the right-hand
--     side, from a little above, through a long lens), fitted to each model's real
--     extent, so a 3-stud ATM and a 12-stud Mega Wheel fill their frames alike.
--     Low wide pieces (tables, benches) are seen from a bit higher, flat decor
--     (floors, rugs) from high up, staff as a waist-up portrait. A warm key light
--     from the upper left over a plum ambient (a ViewportFrame has one directional
--     light), a transparent background so the card's tone gradient and glow show
--     through, and a slow turntable spin while the mouse is over the card.
--   * cheap: one stripped copy per model (no GUIs, joints, sounds or invisible
--     carriers; LRU-cached), one clone per icon, built only when the frame is (about
--     to be) on screen, a few ms of building per frame at most, released again
--     after a while off screen. A static icon does no per-frame work; only a
--     hovered one turns.
--   * fallback: while there is no preview the old 3D icon shows (opts.fallback, or
--     opts.fallbackIcon); the model takes over if the preview lands later.
--   NB: a ViewportFrame draws parts, meshes, decals and textures, not SurfaceGuis
--   or lights: sign texts and screens show as their plain plates.
--
-- API
--   ModelIcons.attach(parent, kind, id, opts?) -> ViewportFrame
--     opts: name, size (UDim2, default: fills the parent), position, anchor, z, order,
--           framing ("hero" | "low" | "top" | "bust" | "full"; default by kind / shape),
--           align ("center" | "bottom"), margin (share of the frame left free on each
--           side), bottom (the bottom margin when align = "bottom"), yaw / pitch (degrees),
--           fallback (a GuiObject shown only while there is no model),
--           fallbackIcon (a UIAssets icon name: makes that fallback),
--           hover (the GuiObject whose mouse-over turns the model; default: the parent),
--           spin (false: never turns), dim (the locked look), color / transparency
--           (the rest look), shadow (a soft ink ellipse under the model, for tiles
--           without a floor of their own), eager (build even while off screen),
--           onModel (fn(shown): true when the model takes over, false when the
--           fallback shows: callers toggle their own extras with it)
--   ModelIcons.has(kind, id) -> boolean    the preview is there right now
--   ModelIcons.setDim(viewport, on)        the locked look on / off
--   ModelIcons.LOOK                        camera + light presets (tuning)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModelIcons = {}

local TOUCH = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
local TAU = math.pi * 2

------------------------------------------------------------------
-- the look
------------------------------------------------------------------
local LOOK = {
	fov = 24,                                    -- vertical, degrees: a long lens, little distortion
	margin = 0.07,                               -- share of the frame left free on each side
	ambient = Color3.fromRGB(146, 134, 150),     -- the unlit sides: a warm plum, never black
	light = Color3.fromRGB(255, 236, 210),       -- the key: warm white
	key = Vector3.new(-0.55, 0.85, 0.6),         -- the key in camera space: left, above, from the viewer's side
	turnSpeed = math.rad(40),                    -- the hover turntable, per second
	dimColor = Color3.fromRGB(150, 150, 160),    -- the locked look (as UILib.card dims its image)
	dimTransparency = 0.25,
	presets = {
		hero = { yaw = -30, pitch = 17 },        -- machines, stands, decor
		low = { yaw = -30, pitch = 26 },         -- low wide pieces (tables, benches): more of the top
		top = { yaw = -30, pitch = 52 },         -- flat decor (floors, paths, rugs)
		bust = { yaw = -20, pitch = 5, fov = 22, cut = 0.4 }, -- staff: waist up (fits the top 60 %)
		full = { yaw = -20, pitch = 6 },         -- staff head to toe
	},
}
ModelIcons.LOOK = LOOK

local BUDGET = 0.004       -- s of building per frame
local SCAN_EVERY = 0.1     -- s between looks at the waiting icons
local PREFETCH = 0.75      -- build this many icon heights before the frame scrolls into view
local KEEP_PAD = 2         -- ... and keep it until it's this far out
local UNLOAD_AFTER = 8     -- s out of view before a model is released
local MAX_TEMPLATES = 40   -- stripped copies kept (LRU)
local FADE = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

------------------------------------------------------------------
-- sources
------------------------------------------------------------------
local CANON = { machine = "machine", stand = "machine", concession = "machine", decor = "decor", staff = "staff" }
local FOLDER = { machine = "MachinePreviews", decor = "DecorPreviews", staff = "StaffTemplates" }
local KIND_OF_FOLDER = { MachinePreviews = "machine", DecorPreviews = "decor", StaffTemplates = "staff" }

local function sourceOf(kind: string, id: string): Model?
	local name = FOLDER[kind]
	local folder = name and ReplicatedStorage:FindFirstChild(name)
	local m = folder and folder:FindFirstChild(id)
	return (m and m:IsA("Model")) and m or nil
end

function ModelIcons.has(kind: string, id: any): boolean
	local k = CANON[kind]
	return k ~= nil and id ~= nil and sourceOf(k, tostring(id)) ~= nil
end

------------------------------------------------------------------
-- templates: a stripped copy of the preview + the points its framing is fitted to
------------------------------------------------------------------
-- what a ViewportFrame can't draw or doesn't need (it has no physics, no GUIs, no lights)
local STRIP_CLASS = {
	Sound = true, ProximityPrompt = true, ClickDetector = true, DragDetector = true, ParticleEmitter = true,
	Beam = true, Trail = true, Fire = true, Smoke = true, Sparkles = true, Attachment = true, Bone = true,
	WeldConstraint = true, NoCollisionConstraint = true, Animator = true, AnimationController = true,
	Highlight = true, SelectionBox = true, ForceField = true, SurfaceGui = true, BillboardGui = true,
}
local STRIP_ABSTRACT = { "LuaSourceContainer", "JointInstance", "Constraint", "Light", "LayerCollector" }

local function stripped(d: Instance): boolean
	if STRIP_CLASS[d.ClassName] then return true end
	for _, cls in STRIP_ABSTRACT do
		if d:IsA(cls) then return true end
	end
	return false
end

-- a MaterialVariant's colour map multiplies Part.Color (Materials.paint: hedges keep
-- their colour in the texture and a white Part.Color). A viewport that skips the
-- variant would show that white, so the icon bakes the map's mean colour in.
local MaterialsMod = nil
local function variantMean(name: string)
	if MaterialsMod == nil then
		local common = ReplicatedStorage:FindFirstChild("CasinoCommon")
		local mod = common and common:FindFirstChild("Materials")
		local ok, res = false, nil
		if mod then ok, res = pcall(require, mod) end
		MaterialsMod = (ok and type(res) == "table") and res or false
	end
	local key = string.match(name, "^CM_(.+)$")
	local def = MaterialsMod and key and MaterialsMod.Defs and MaterialsMod.Defs[key]
	return def and def.mean or nil
end

local CORNERS = {}
for _, x in { -1, 1 } do
	for _, y in { -1, 1 } do
		for _, z in { -1, 1 } do table.insert(CORNERS, Vector3.new(x, y, z)) end
	end
end
local AXES = { Vector3.xAxis, -Vector3.xAxis, Vector3.yAxis, -Vector3.yAxis, Vector3.zAxis, -Vector3.zAxis }

local function vmin(a: Vector3, b: Vector3): Vector3
	return Vector3.new(math.min(a.X, b.X), math.min(a.Y, b.Y), math.min(a.Z, b.Z))
end
local function vmax(a: Vector3, b: Vector3): Vector3
	return Vector3.new(math.max(a.X, b.X), math.max(a.Y, b.Y), math.max(a.Z, b.Z))
end

-- points on a part's surface hull (box corners; balls and cylinders a little tighter)
local function partPoints(p: BasePart, out)
	local cf, s = p.CFrame, p.Size
	local shape = p:IsA("Part") and (p :: Part).Shape or nil
	if shape == Enum.PartType.Ball then
		local r = math.min(s.X, s.Y, s.Z) / 2
		local c = cf.Position
		for _, v in AXES do table.insert(out, c + v * r) end
		for _, v in CORNERS do table.insert(out, c + v * (r * 0.5774)) end
	elseif shape == Enum.PartType.Cylinder then
		local L, r = s.X / 2, math.min(s.Y, s.Z) / 2
		for _, x in { -L, L } do
			for i = 0, 7 do
				local a = i * math.pi / 4
				table.insert(out, cf * Vector3.new(x, math.cos(a) * r, math.sin(a) * r))
			end
		end
	else
		local h = s / 2
		for _, v in CORNERS do table.insert(out, cf * (v * h)) end
	end
end

-- a stripped clone of the preview: { model, points, frame, axis, low, framing, fits }
local function prepare(kind: string, src: Model)
	local model = src:Clone()
	-- which way it faces (before the root part goes): machines / decor pivot at the
	-- ground centre facing -Z, a rig at its root
	local pivot = model:GetPivot()
	local look = Vector3.new(pivot.LookVector.X, 0, pivot.LookVector.Z)
	look = look.Magnitude > 1e-3 and look.Unit or Vector3.new(0, 0, -1)
	local frame = CFrame.lookAt(pivot.Position, pivot.Position + look)
	for _, d in model:GetDescendants() do
		if d.Parent ~= nil and stripped(d) then d:Destroy() end
	end
	local points = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d.Parent ~= nil then
			if d.Transparency >= 0.99 and #d:GetChildren() == 0 then
				d:Destroy() -- an invisible carrier (sign prints, a rig's root)
			else
				d.Reflectance = 0 -- nothing to reflect in a viewport: it would only grey the gold
				if d.MaterialVariant ~= "" then
					local mean = variantMean(d.MaterialVariant)
					if mean then
						local c = d.Color
						d.Color = Color3.new(c.R * mean[1] / 255, c.G * mean[2] / 255, c.B * mean[3] / 255)
					end
					d.MaterialVariant = ""
				end
				if d.Transparency < 0.95 then partPoints(d, points) end
			end
		end
	end
	if #points == 0 then
		model:Destroy()
		return nil
	end
	-- the extent in the model's own frame (x right of its front, y up, z back)
	local lo = Vector3.one * math.huge
	local hi = -Vector3.one * math.huge
	for _, p in points do
		local q = frame:PointToObjectSpace(p)
		lo = vmin(lo, q)
		hi = vmax(hi, q)
	end
	local size = hi - lo
	local framing = "hero"
	if kind == "staff" then
		framing = "bust"
	elseif src:GetAttribute("Flat") == true or size.Y < 0.2 * math.max(size.X, size.Z) then
		framing = "top"
	elseif size.Y < 0.62 * math.max(size.X, size.Z) then
		framing = "low"
	end
	return {
		model = model, points = points, frame = frame, lo = lo, hi = hi, framing = framing, fits = {},
		axis = frame * Vector3.new((lo.X + hi.X) / 2, 0, (lo.Z + hi.Z) / 2), -- the turntable's spindle
		used = os.clock(),
	}
end

local templates = {}   -- "kind/id" -> template
local templateCount = 0

local function evictOldest()
	local oldKey, oldT = nil, math.huge
	for key, t in templates do
		if t.used < oldT then oldKey, oldT = key, t.used end
	end
	if oldKey then
		templates[oldKey].model:Destroy()
		templates[oldKey] = nil
		templateCount -= 1
	end
end

local function template(kind: string, id: string)
	local key = kind .. "/" .. id
	local t = templates[key]
	if t and t.model then
		t.used = os.clock()
		return t
	end
	local src = sourceOf(kind, id)
	if not src then return nil end
	t = prepare(kind, src)
	if not t then return nil end
	templates[key] = t
	templateCount += 1
	if templateCount > MAX_TEMPLATES then evictOldest() end
	t.used = os.clock()
	return t
end

------------------------------------------------------------------
-- framing: a perspective camera fitted to the points (pure maths)
------------------------------------------------------------------
-- the camera basis for a view `yaw` to the viewer's right (-X) and `pitch` above
local function basis(frame: CFrame, yawDeg: number, pitchDeg: number): (Vector3, Vector3, Vector3)
	local yaw, pitch = math.rad(yawDeg), math.rad(pitchDeg)
	local toCam = frame:VectorToWorldSpace(Vector3.new(
		math.sin(yaw) * math.cos(pitch), math.sin(pitch), -math.cos(yaw) * math.cos(pitch)))
	local F = -toCam.Unit -- the camera looks along F
	local R = F:Cross(frame.UpVector).Unit
	local U = R:Cross(F).Unit
	return R, U, F
end

-- how far back the camera must stand (looking at T) for every point to fit
-- inside +-tH / +-tV (the tangents of the usable half angles)
local function needDistance(pts, T: Vector3, R: Vector3, U: Vector3, F: Vector3, tH: number, tV: number): number
	local need = 0
	for _, p in pts do
		local d = p - T
		local n = math.max(math.abs(d:Dot(R)) / tH, math.abs(d:Dot(U)) / tV) - d:Dot(F)
		if n > need then need = n end
	end
	return need
end

-- the points' bounds on screen, -1..1 across the frame
local function screenBounds(pts, T: Vector3, R: Vector3, U: Vector3, F: Vector3, D: number, tH: number, tV: number)
	local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
	for _, p in pts do
		local d = p - T
		local depth = D + d:Dot(F)
		if depth > 1e-3 then
			local sx, sy = d:Dot(R) / (depth * tH), d:Dot(U) / (depth * tV)
			if sx < x0 then x0 = sx end
			if sx > x1 then x1 = sx end
			if sy < y0 then y0 = sy end
			if sy > y1 then y1 = sy end
		end
	end
	return x0, x1, y0, y1
end

local function project(p: Vector3, T: Vector3, R: Vector3, U: Vector3, F: Vector3, D: number, tH: number, tV: number)
	local d = p - T
	local depth = math.max(1e-3, D + d:Dot(F))
	return d:Dot(R) / (depth * tH), d:Dot(U) / (depth * tV)
end

-- o: framing, yaw, pitch, fov, margin, align, bottom, aspect (width / height)
local function fit(t, o)
	local preset = LOOK.presets[o.framing] or LOOK.presets.hero
	local frame = t.frame
	local R, U, F = basis(frame, o.yaw or preset.yaw, o.pitch or preset.pitch)
	local fov = o.fov or preset.fov or LOOK.fov
	local tV = math.tan(math.rad(fov) / 2)
	local tH = tV * o.aspect
	local margin = math.clamp(o.margin or preset.margin or LOOK.margin, 0, 0.4)
	local use = 1 - 2 * margin
	-- a portrait fits the top of the body only (the rest runs out of the frame)
	local pts = t.points
	if preset.cut then
		local cutY = t.lo.Y + (t.hi.Y - t.lo.Y) * preset.cut
		local kept = {}
		for _, p in pts do
			if frame:PointToObjectSpace(p).Y >= cutY then table.insert(kept, p) end
		end
		if #kept > 0 then pts = kept end
	end
	-- start at the middle of the box, then re-centre for perspective (the near side
	-- reads bigger) and fit again
	local lo = Vector3.one * math.huge
	local hi = -Vector3.one * math.huge
	for _, p in pts do
		lo = vmin(lo, p)
		hi = vmax(hi, p)
	end
	local T = (lo + hi) / 2
	local D = math.max(0.5, needDistance(pts, T, R, U, F, tH * use, tV * use))
	for _ = 1, 3 do
		local x0, x1, y0, y1 = screenBounds(pts, T, R, U, F, D, tH, tV)
		T += R * ((x0 + x1) / 2 * tH * D) + U * ((y0 + y1) / 2 * tV * D)
		D = math.max(0.5, needDistance(pts, T, R, U, F, tH * use, tV * use))
	end
	-- stand it on the frame's floor when it doesn't fill the height
	if o.align == "bottom" then
		local want = -1 + 2 * math.clamp(o.bottom or margin, 0, 0.45)
		for _ = 1, 2 do
			local _, _, y0 = screenBounds(pts, T, R, U, F, D, tH, tV)
			if y0 <= want + 1e-3 then break end
			T += U * ((y0 - want) * tV * D)
		end
	end
	local cf = CFrame.fromMatrix(T - F * D, R, U, -F)
	local k = LOOK.key
	local keyFrom = (R * k.X + U * k.Y - F * k.Z).Unit
	-- where the footprint's centre lands (for a contact shadow), 0..1 of the frame
	local gx, gy = project(frame * Vector3.new((t.lo.X + t.hi.X) / 2, t.lo.Y, (t.lo.Z + t.hi.Z) / 2), T, R, U, F, D, tH, tV)
	local lx = project(frame * Vector3.new(t.lo.X, t.lo.Y, (t.lo.Z + t.hi.Z) / 2), T, R, U, F, D, tH, tV)
	local rx = project(frame * Vector3.new(t.hi.X, t.lo.Y, (t.lo.Z + t.hi.Z) / 2), T, R, U, F, D, tH, tV)
	return {
		cf = cf, focus = T, dist = D, fov = fov, light = -keyFrom, axis = t.axis,
		pts = pts, tH = tH * use, tV = tV * use,
		ground = Vector2.new((gx + 1) / 2, (1 - gy) / 2), footprint = math.abs(rx - lx) / 2,
	}
end
ModelIcons._fit = fit -- (headless tests)
ModelIcons._prepare = prepare

-- how far back the camera has to stand to keep the whole model in view while it
-- turns (worst of eight angles around the spindle)
local function turnDistance(f): number
	local worst = f.dist
	local rest = f.cf.Rotation
	for i = 1, 7 do
		local rot = CFrame.new(f.axis) * CFrame.Angles(0, i * TAU / 8, 0) * CFrame.new(-f.axis)
		local cam = rot.Rotation * rest
		worst = math.max(worst, needDistance(f.pts, rot * f.focus, cam.RightVector, cam.UpVector, cam.LookVector, f.tH, f.tV))
	end
	return worst
end

------------------------------------------------------------------
-- icons
------------------------------------------------------------------
-- rec: { vf, kind, id, key, state ("pending" | "ready" | "missing"), dead, model, cam,
--        fit, angle, dist, hovered, seen, conns, fallback, shadow, restColor, restT, ... }
local live = {}      -- rec -> true
local byFrame = {}   -- ViewportFrame -> rec
local turning = {}   -- rec -> true (hovered, or easing home)
local pendingCount = 0
local recentlyBuilt = {} -- key -> os.clock(): a re-render shows it at once, without the fade
local nextScan = 0       -- the builder's next look at the waiting icons
local burstUntil = 0     -- new icons: look every frame for a moment (they may not be laid out yet)

local buildConn: RBXScriptConnection? = nil
local turnConn: RBXScriptConnection? = nil
local upkeepRunning = false
local warned = 0

local function warnOnce(msg: string)
	if warned < 6 then
		warned += 1
		warn("[ModelIcons] " .. msg)
	end
end

local startBuilder -- (forward)

local function setState(rec, state: string)
	if rec.state == state then return end
	if rec.state == "pending" then pendingCount -= 1 end
	rec.state = state
	if state == "pending" then
		pendingCount += 1
		nextScan = 0
		burstUntil = os.clock() + 0.5
		startBuilder()
	end
end

local Assets = nil
local function iconImage(name: string?): string
	if not name or name == "" then return "" end
	if string.find(name, "rbxasset") then return name end
	if Assets == nil then
		local common = ReplicatedStorage:FindFirstChild("CasinoCommon")
		local mod = common and common:FindFirstChild("UIAssets")
		local ok, res = false, nil
		if mod then ok, res = pcall(require, mod) end
		Assets = (ok and type(res) == "table") and res or false
	end
	if not Assets then return "" end
	local fb = Assets.Fallback and Assets.Fallback[name]
	return Assets.Icons[name] or (Assets.Textures and Assets.Textures[name]) or (fb and Assets.Icons[fb]) or ""
end

local function showFallback(rec, on: boolean)
	if on and not rec.fallback and rec.fallbackIcon and rec.vf.Parent then
		local vf = rec.vf
		local img = Instance.new("ImageLabel")
		img.Name = "ModelIconFallback"
		img.BackgroundTransparency = 1
		img.ScaleType = Enum.ScaleType.Fit
		img.Image = iconImage(rec.fallbackIcon)
		img.Size, img.Position, img.AnchorPoint, img.ZIndex = vf.Size, vf.Position, vf.AnchorPoint, vf.ZIndex
		img.LayoutOrder = vf.LayoutOrder
		img.Parent = vf.Parent
		rec.fallback = img
		rec.ownFallback = true
	end
	if rec.fallback and rec.fallback.Parent then rec.fallback.Visible = on end
	if rec.onModel and rec.modelShown ~= not on then
		rec.modelShown = not on
		local ok, err = pcall(rec.onModel, not on)
		if not ok then warnOnce("onModel: " .. tostring(err)) end
	end
end

local function release(rec)
	if rec.dead then return end
	rec.dead = true
	if rec.state == "pending" then pendingCount -= 1 end
	rec.state = "dead"
	live[rec] = nil
	turning[rec] = nil
	if byFrame[rec.vf] == rec then byFrame[rec.vf] = nil end
	for _, c in rec.conns do c:Disconnect() end
	table.clear(rec.conns)
	if rec.model then
		rec.model:Destroy()
		rec.model = nil
	end
	if rec.ownFallback and rec.fallback then rec.fallback:Destroy() end
	if rec.shadowImg then rec.shadowImg:Destroy() end
end

local function isDead(rec): boolean
	return rec.dead or rec.vf.Parent == nil
end

-- is the frame on screen (or within `pad` of its own height of it)? Walks up to
-- its ScreenGui: hidden ancestors, scrolling frames and clipping frames count.
local playerGui: Instance? = nil
local function onScreen(vf: GuiObject, pad: number): boolean
	local pos, size = vf.AbsolutePosition, vf.AbsoluteSize
	if size.X < 1 or size.Y < 1 then return false end
	local px = size.Y * pad
	local x0, y0, x1, y1 = pos.X, pos.Y, pos.X + size.X, pos.Y + size.Y
	local node: Instance? = vf
	while node do
		if node:IsA("LayerCollector") then
			if not (node :: LayerCollector).Enabled then return false end
			if node:IsA("ScreenGui") then
				if not playerGui or not playerGui.Parent then
					local lp = Players.LocalPlayer
					playerGui = lp and lp:FindFirstChildOfClass("PlayerGui")
				end
				if node.Parent ~= playerGui then return false end
				local s = (node :: ScreenGui).AbsoluteSize
				x0, y0 = math.max(x0, -px), math.max(y0, -px)
				x1, y1 = math.min(x1, s.X + px), math.min(y1, s.Y + px)
			end
			return x1 > x0 and y1 > y0
		elseif node:IsA("GuiObject") then
			local g = node :: GuiObject
			if not g.Visible then return false end
			if g.ClipsDescendants and g ~= vf then
				local p, s = g.AbsolutePosition, g.AbsoluteSize
				x0, y0 = math.max(x0, p.X - px), math.max(y0, p.Y - px)
				x1, y1 = math.min(x1, p.X + s.X + px), math.min(y1, p.Y + s.Y + px)
				if x1 <= x0 or y1 <= y0 then return false end
			end
		end
		node = node.Parent
	end
	return false
end

-- the camera (and the light, which turns with it) at the record's angle / distance
local function pose(rec)
	local f = rec.fit
	local rot = CFrame.new(f.axis) * CFrame.Angles(0, rec.angle, 0) * CFrame.new(-f.axis)
	local spin = rot.Rotation
	local camRot = spin * f.cf.Rotation
	rec.cam.CFrame = camRot + (rot * f.focus - camRot.LookVector * rec.dist)
	rec.vf.LightDirection = spin:VectorToWorldSpace(f.light)
end

local function turnStep(dt: number)
	local k = 1 - math.exp(-dt * 6)
	for rec in turning do
		if rec.dead or rec.state ~= "ready" or not rec.cam or not rec.fit then
			turning[rec] = nil
			continue
		end
		local f = rec.fit
		if rec.hovered then
			rec.angle += LOOK.turnSpeed * dt
			rec.dist += ((f.turnDist or f.dist) - rec.dist) * k
		else
			local home = math.floor(rec.angle / TAU + 0.5) * TAU
			rec.angle += (home - rec.angle) * k
			rec.dist += (f.dist - rec.dist) * k
			if math.abs(home - rec.angle) < 0.002 and math.abs(f.dist - rec.dist) < 0.005 then
				rec.angle, rec.dist = 0, f.dist
				turning[rec] = nil
			end
		end
		pose(rec)
	end
	if next(turning) == nil and turnConn then
		turnConn:Disconnect()
		turnConn = nil
	end
end

local function startTurn(rec)
	if rec.dead or rec.state ~= "ready" or not rec.fit then return end
	if rec.fit.turnDist == nil then
		local ok, d = pcall(turnDistance, rec.fit)
		rec.fit.turnDist = ok and d or rec.fit.dist
	end
	turning[rec] = true
	if not turnConn then turnConn = RunService.RenderStepped:Connect(turnStep) end
end

-- the soft ink ellipse under the model (rec.shadow)
local function placeShadow(rec)
	local vf, f = rec.vf, rec.fit
	local img = rec.shadowImg
	if not img then
		local tex = iconImage("glow")
		img = Instance.new("ImageLabel")
		img.Name = "ModelIconShadow"
		img.BackgroundTransparency = 1
		img.Image = tex
		img.ImageColor3 = Color3.fromHex("#2B0A12")
		img.AnchorPoint = Vector2.new(0.5, 0.5)
		img.ZIndex = vf.ZIndex - 1
		img.Parent = vf.Parent
		rec.shadowImg = img
	end
	-- placed in the parent's scale space from absolute sizes (any layout, any UIScale)
	local parent = vf.Parent :: GuiObject
	local pp, ps = parent.AbsolutePosition, parent.AbsoluteSize
	local vp, vs = vf.AbsolutePosition, vf.AbsoluteSize
	if ps.X < 1 or ps.Y < 1 then return end
	local w = vs.X * math.clamp(f.footprint * 1.25, 0.3, 1.1) -- px
	local cx = vp.X - pp.X + f.ground.X * vs.X
	local cy = vp.Y - pp.Y + math.min(f.ground.Y, 0.97) * vs.Y
	img.Position = UDim2.fromScale(cx / ps.X, cy / ps.Y)
	img.Size = UDim2.fromScale(w / ps.X, w * 0.3 / ps.Y)
	img.ImageTransparency = math.clamp(0.4 + rec.restT * 0.6, 0, 1)
	img.Visible = true
end

-- clone the model into its frame (the builder calls this once the frame is on screen)
local function build(rec)
	local vf = rec.vf
	local px = vf.AbsoluteSize
	if px.X < 2 or px.Y < 2 then return end -- not laid out yet: the next scan
	local t = template(rec.kind, rec.id)
	if not t then
		setState(rec, "missing")
		showFallback(rec, true)
		rec.watch(rec)
		return
	end
	local aspect = px.X / px.Y
	local fitKey = table.concat({ rec.framing or t.framing, tostring(rec.yaw), tostring(rec.pitch), tostring(rec.margin),
		rec.align or "center", tostring(rec.bottom), tostring(math.floor(aspect * 40 + 0.5)) }, "|")
	local f = t.fits[fitKey]
	if not f then
		f = fit(t, {
			framing = rec.framing or t.framing, yaw = rec.yaw, pitch = rec.pitch, margin = rec.margin,
			align = rec.align, bottom = rec.bottom, aspect = aspect,
		})
		t.fits[fitKey] = f
	end
	local model = t.model:Clone()
	local cam = rec.cam
	if not cam or not cam.Parent then
		cam = Instance.new("Camera")
		cam.Name = "IconCamera"
		cam.Parent = vf
		rec.cam = cam
	end
	cam.FieldOfView = f.fov
	rec.fit, rec.angle, rec.dist = f, 0, f.dist
	vf.CurrentCamera = cam
	pose(rec)
	model.Parent = vf
	rec.model = model
	rec.seen = os.clock()
	setState(rec, "ready")
	showFallback(rec, false)
	if rec.shadow then placeShadow(rec) end
	vf.ImageColor3 = rec.restColor
	local now = os.clock()
	if now - (recentlyBuilt[rec.key] or -100) < 5 then
		vf.ImageTransparency = rec.restT -- a re-render of what was just on screen: no flicker
	else
		vf.ImageTransparency = 1
		TweenService:Create(vf, FADE, { ImageTransparency = rec.restT }):Play()
	end
	recentlyBuilt[rec.key] = now
	if rec.hovered then startTurn(rec) end
end

-- back to "pending" after a while off screen (the frame stays, the clone goes)
local function unload(rec)
	if rec.model then
		rec.model:Destroy()
		rec.model = nil
	end
	turning[rec] = nil
	rec.vf.ImageTransparency = 1
	if rec.shadowImg then rec.shadowImg.Visible = false end
	setState(rec, "pending")
end

local function buildStep()
	local now = os.clock()
	if now < nextScan then return end
	nextScan = now < burstUntil and 0 or now + SCAN_EVERY
	local ready = {}
	for rec in live do
		if rec.state == "pending" then
			if isDead(rec) then
				release(rec)
			elseif rec.eager or onScreen(rec.vf, PREFETCH) then
				table.insert(ready, rec)
			end
		end
	end
	if #ready == 0 then
		if pendingCount <= 0 and buildConn then
			buildConn:Disconnect()
			buildConn = nil
		end
		return
	end
	-- top-left first, as the eye reads
	if #ready > 1 then
		local at = {}
		for _, rec in ready do
			local p = rec.vf.AbsolutePosition
			at[rec] = p.Y * 4096 + p.X
		end
		table.sort(ready, function(a, b) return at[a] < at[b] end)
	end
	local t0 = os.clock()
	for _, rec in ready do
		if os.clock() - t0 > BUDGET then
			nextScan = 0 -- more to build: carry on next frame
			break
		end
		local ok, err = pcall(build, rec)
		if not ok then
			warnOnce(("%s: %s"):format(rec.key, tostring(err)))
			setState(rec, "missing")
			showFallback(rec, true)
		end
	end
end

startBuilder = function()
	if not buildConn then
		nextScan = 0
		buildConn = RunService.Heartbeat:Connect(buildStep)
	end
end

-- 1 Hz: drop dead icons, release clones that have been out of view a while
local function upkeep()
	while next(live) do
		task.wait(1)
		local now = os.clock()
		for rec in live do
			if isDead(rec) then
				release(rec)
			elseif rec.state == "ready" and not rec.eager then
				if turning[rec] or onScreen(rec.vf, KEEP_PAD) then
					rec.seen = now
				elseif now - (rec.seen or now) > UNLOAD_AFTER then
					unload(rec)
				end
			end
		end
	end
	upkeepRunning = false
end

------------------------------------------------------------------
-- a preview that arrives late (staff rigs build in the background; a client
-- may open a shop before the previews are published)
------------------------------------------------------------------
local waiting = {}   -- "kind/id" -> { rec = true }
local hooked = {}    -- folder -> true (its ChildAdded is watched)

local function wake(key: string)
	local list = waiting[key]
	if not list then return end
	waiting[key] = nil
	for rec in list do
		if not rec.dead and rec.state == "missing" then setState(rec, "pending") end
	end
end

local function hookFolder(folder: Instance)
	if hooked[folder] then return end
	hooked[folder] = true
	local kind = KIND_OF_FOLDER[folder.Name]
	folder.ChildAdded:Connect(function(child)
		wake(kind .. "/" .. child.Name)
	end)
	-- everything already in it (the folder may have just arrived)
	for _, child in folder:GetChildren() do wake(kind .. "/" .. child.Name) end
end

local rootHooked = false
local function watch(rec)
	local key = rec.key
	waiting[key] = waiting[key] or {}
	waiting[key][rec] = true
	local folder = ReplicatedStorage:FindFirstChild(FOLDER[rec.kind] or "")
	if folder then hookFolder(folder) end
	if not rootHooked then
		rootHooked = true
		ReplicatedStorage.ChildAdded:Connect(function(child)
			if KIND_OF_FOLDER[child.Name] then hookFolder(child) end
		end)
	end
end

------------------------------------------------------------------
-- API
------------------------------------------------------------------
function ModelIcons.attach(parent: Instance, kind: string, id: any, opts): ViewportFrame
	opts = opts or {}
	local canon = CANON[kind] or tostring(kind)
	local sid = tostring(id)
	local vf = Instance.new("ViewportFrame")
	vf.Name = opts.name or "ModelIcon"
	vf.BackgroundTransparency = 1
	vf.BorderSizePixel = 0
	vf.Size = opts.size or UDim2.fromScale(1, 1)
	vf.Position = opts.position or UDim2.new()
	vf.AnchorPoint = opts.anchor or Vector2.zero
	if opts.z then vf.ZIndex = opts.z end
	if opts.order then vf.LayoutOrder = opts.order end
	vf.Ambient = LOOK.ambient
	vf.LightColor = LOOK.light
	vf.ImageTransparency = 1 -- faded in once the model is in
	vf:SetAttribute("ModelIcon", canon .. "/" .. sid)

	local rec = {
		vf = vf, kind = canon, id = sid, key = canon .. "/" .. sid, state = "new", conns = {},
		framing = opts.framing, align = opts.align, margin = opts.margin, bottom = opts.bottom,
		yaw = opts.yaw, pitch = opts.pitch, eager = opts.eager == true, shadow = opts.shadow == true,
		fallback = opts.fallback, fallbackIcon = opts.fallbackIcon, onModel = opts.onModel,
		restColor = opts.color or (opts.dim and LOOK.dimColor or Color3.new(1, 1, 1)),
		restT = opts.transparency or (opts.dim and LOOK.dimTransparency or 0),
		angle = 0, hovered = false, watch = watch,
	}
	vf.ImageColor3 = rec.restColor
	vf.Parent = parent
	live[rec] = true
	byFrame[vf] = rec

	if FOLDER[canon] and (templates[rec.key] or sourceOf(canon, sid)) then
		showFallback(rec, false)
		setState(rec, "pending")
	else
		setState(rec, "missing")
		showFallback(rec, true)
		if FOLDER[canon] then watch(rec) end
	end

	-- the hover turntable (mouse only)
	local target = opts.hover
	if target == nil and parent:IsA("GuiObject") then target = parent end
	if not TOUCH and opts.spin ~= false and typeof(target) == "Instance" and target:IsA("GuiObject") then
		table.insert(rec.conns, target.MouseEnter:Connect(function()
			if rec.dead then return end
			rec.hovered = true
			startTurn(rec)
		end))
		table.insert(rec.conns, target.MouseLeave:Connect(function()
			rec.hovered = false -- the turntable eases home
		end))
	end
	table.insert(rec.conns, vf.Destroying:Connect(function() release(rec) end))

	if not upkeepRunning then
		upkeepRunning = true
		task.spawn(upkeep)
	end
	return vf
end

function ModelIcons.setDim(vf: ViewportFrame, on: boolean)
	local rec = byFrame[vf]
	if not rec then return end
	rec.restColor = on and LOOK.dimColor or Color3.new(1, 1, 1)
	rec.restT = on and LOOK.dimTransparency or 0
	vf.ImageColor3 = rec.restColor
	if rec.state == "ready" then vf.ImageTransparency = rec.restT end
end

return ModelIcons
