--!nonstrict
-- EventsUI.luau — the client side of the server-wide CASINO EVENTS (Config.Events;
-- server CasinoServer/Events.luau, remote CasinoEvent -> every client):
--   * ~20 s before one starts: an "INCOMING" heads-up toast
--   * the start: a big UXFX banner in the event's style + a coloured vignette pulse
--   * a HUD chip per event (HudUI.addChip, order 30+) with the time left
--     ("BUS TOUR 2:31"); tap it to see what the event does; it pulses in the last 10 s
--   * the end: a short EVENT OVER toast
--   * shouts (someone's Lucky Wheel MEGA JACKPOT...): a toast for everyone else
-- A player who joins during an event gets its chip from the snapshot `event` (and
-- the banner while more than 15 s are left). Times are server os.time, compared with
-- workspace:GetServerTimeNow(). EventsUI.start(deps) (deps: HudUI), EventsUI.current().

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local Config = require(Common:WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors

local EventsUI = {}
local player = Players.LocalPlayer
local deps = {}
local started = false
local chips = {}        -- event id -> HUD chip handle
local live = nil        -- the running event (its "start" payload)
local bannered = {}     -- serial -> true: its banner was shown
local ended = {}        -- serial -> true: its end was handled

local STYLE_COLOR = { purple = C.Purple, crimson = C.Crimson, gold = C.GoldTop, green = C.Green, blue = C.Blue }
-- icons the ICONS2 set adds: a stand-in until they're uploaded
local STANDIN = { cheater = "shield", megaphone = "mic", wheel = "slot" }

local function iconName(name: any): string
	if type(name) == "string" and UILib.resolveIcon(name) ~= "" then return name end
	return (type(name) == "string" and STANDIN[name]) or (UILib.resolveIcon("megaphone") ~= "" and "megaphone") or "star"
end

local function serverNow(): number
	local ok, t = pcall(function() return Workspace:GetServerTimeNow() end)
	return (ok and type(t) == "number") and t or os.time()
end

-- a toast whose tile shows `icon` in `tone` (UILib.toast announces each toast to the
-- fx hooks synchronously: swap the tile's look right there)
local function iconToast(title: string, kind: string, message: string?, icon: string?, tone: string?)
	local t = tone and UILib.Tones[tone]
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

local function leftOf(info): number
	return math.max(0, (tonumber(info and info.endsAt) or 0) - serverNow())
end

local function defOf(id: any)
	return type(id) == "string" and Config.getEvent and Config.getEvent(id) or nil
end

-- a HUD chip that reacts to a tap (the chips are plain frames)
local function clickable(handle, fn)
	local f = handle and handle.Instance
	if not (f and f:IsA("GuiObject")) then return end
	f.Active = true
	f.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			UILib.emit("press", f)
			UILib.fx("pop", f, 1.12)
			fn()
		end
	end)
end

local function showInfo()
	local ev = live
	if not ev then return end
	iconToast(tostring(ev.name or "CASINO EVENT"), "info",
		("%s  (%s left)"):format(tostring(ev.desc or ""), UILib.clock(leftOf(ev))), ev.icon, ev.tone)
end

-- the chip of an event id (made on first use; one per event so each has its icon + tone)
local function chipFor(id: string, info)
	if chips[id] then return chips[id] end
	local Hud = deps.HudUI
	if not (Hud and type(Hud.addChip) == "function") then return nil end
	local def = defOf(id)
	local order = 30
	for i, d in (Config.Events and Config.Events.List or {}) do
		if d.id == id then order = 30 + i end
	end
	local tone = (info and info.tone) or (def and def.tone) or "Gold"
	local chip = Hud.addChip("event_" .. id, UILib.Tones[tone] and tone or "Gold",
		iconName((info and info.icon) or (def and def.icon)), order)
	if chip then
		clickable(chip, showInfo)
		chips[id] = chip
	end
	return chip
end

local function chipText(info): string
	return ("%s %s"):format(tostring(info.short or info.name or "EVENT"), UILib.clock(leftOf(info)))
end

local function onEnd(info, quiet: boolean?)
	if type(info) ~= "table" then return end
	local serial = info.serial
	if serial ~= nil then
		if ended[serial] then return end
		ended[serial] = true
	end
	if live and (serial == nil or live.serial == serial) then live = nil end
	local chip = type(info.id) == "string" and chips[info.id]
	if chip then chip.show(false) end
	if not quiet and not info.replaced then
		iconToast("EVENT OVER", "info", ("%s has ended - the next event is coming soon!"):format(tostring(info.name or "The event")),
			"megaphone", "Blue")
	end
end

local function onStart(info)
	if type(info) ~= "table" or info.active ~= true or type(info.id) ~= "string" then return end
	if info.serial ~= nil and ended[info.serial] then return end
	if live and live.serial ~= info.serial then onEnd(live, true) end
	live = info
	local chip = chipFor(info.id, info)
	if chip then
		chip.set(chipText(info))
		chip.show(true)
	end
	if info.serial ~= nil and not bannered[info.serial] then
		bannered[info.serial] = true
		if leftOf(info) > 15 then
			local color = STYLE_COLOR[info.style] or C.GoldTop
			UILib.fx("banner", tostring(info.name) .. "!", info.desc, info.style or "gold")
			UILib.fx("vignette", color, info.id == "cheaterRaid" and 3 or 2)
			if chip then
				task.delay(0.35, function()
					if chip.Instance.Parent then
						UILib.fx("pop", chip.Instance, 1.3)
						UILib.fx("sparkle", chip.Instance, 8, color)
					end
				end)
			end
		end
	end
end

local function onIncoming(info)
	if type(info) ~= "table" or type(info.name) ~= "string" then return end
	local secs = math.max(1, math.floor((tonumber(info.startsAt) or 0) - serverNow() + 0.5))
	iconToast("INCOMING: " .. info.name, "info", ("Starts in %d s - %s"):format(secs, tostring(info.desc or "")),
		"megaphone", info.tone)
end

local function onShout(info)
	if type(info) ~= "table" or type(info.title) ~= "string" then return end
	if info.userId == player.UserId then return end -- (the winner sees their own celebration)
	iconToast(info.title, "unlock", tostring(info.text or ""), info.icon or "megaphone", info.tone or "Gold")
end

local function onMessage(info)
	if type(info) ~= "table" then return end
	local kind = info.kind
	if kind == "start" or (kind == nil and info.active == true) then
		onStart(info)
	elseif kind == "end" or (kind == nil and info.active == false and info.id) then
		onEnd(info)
	elseif kind == "incoming" then
		onIncoming(info)
	elseif kind == "shout" then
		onShout(info)
	end
end

-- the running event's payload (nil when none)
function EventsUI.current()
	return live
end

-- the chip's countdown (2 Hz); a pulse in the last 10 s; closes an event whose end
-- message is late or lost a few seconds after time's up
local lastPulse = -1
function EventsUI.step()
	local ev = live
	if not ev then return end
	local left = leftOf(ev)
	local chip = chips[ev.id]
	if chip then
		chip.set(chipText(ev))
		local s = math.ceil(left)
		if s <= 10 and s > 0 and s ~= lastPulse then
			lastPulse = s
			UILib.fx("pop", chip.Instance, 1.1)
		end
	end
	if left <= 0 and serverNow() - (tonumber(ev.endsAt) or 0) > 4 then onEnd(ev) end
end

function EventsUI.start(d)
	deps = type(d) == "table" and d or {}
	if started then return end
	started = true

	-- live messages
	task.spawn(function()
		local ok, ev = pcall(function() return Remotes.CasinoEvent() end)
		if not (ok and ev) then
			warn("[EventsUI] CasinoEvent remote missing; event banners are off.")
			return
		end
		ev.OnClientEvent:Connect(function(info)
			local okMsg, err = pcall(onMessage, info)
			if not okMsg then warn("[EventsUI] " .. tostring(err)) end
		end)
	end)

	-- the snapshot: an event already running when we joined, or one whose end we missed
	UILib.subscribe(function(state)
		local ev = type(state) == "table" and state.event
		if type(ev) ~= "table" then return end
		if ev.active == true then
			if not live or live.serial ~= ev.serial then onStart(ev) end
		elseif live then
			onEnd(live, leftOf(live) > 2) -- (stopped early: quietly)
		end
	end)

	task.spawn(function()
		while true do
			local ok, err = pcall(EventsUI.step)
			if not ok then warn("[EventsUI] " .. tostring(err)) end
			task.wait(0.5)
		end
	end)
end

return EventsUI
