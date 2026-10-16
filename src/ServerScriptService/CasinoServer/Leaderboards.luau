--!nonstrict
-- Leaderboards.luau — the plaza's three hall-of-fame boards, GLOBAL: the best of
-- every server. Boards are parts tagged "LeaderboardBoard" (MapBuilder) holding a
-- SurfaceGui "Board" (Title, Subtitle, rows Row1..Row8 with Rank / PlayerName /
-- Value labels). The part's "Board" attribute picks the ranking; the map keeps its
-- old kinds and the boards are re-purposed here at runtime:
--   "earned" -> TOP CASINOS      Casino Rank + XP             OrderedDataStore LB_XP_v1
--   "cash"   -> HIGH ROLLERS     lifetime earnings            LB_Earned_v1
--   "size"   -> REBIRTH LEGENDS  rebirths (XP breaks ties)    LB_Rebirths_v1
-- (each store name + Data.storeSuffix(), so the Studio test store never touches the
-- real boards). Values are integers (the rebirth board stores rebirths x 1e10 + XP).
--   * writes: every online player's values every WRITE_EVERY s (only what changed,
--     a few per tick, while the SetIncrementSortedAsync budget allows) and once
--     more when they leave
--   * reads: each board's top 8 every READ_EVERY s; the live values of the players
--     on this server are merged in, so their climb shows at once
--   * names: this server's display names, else a cached look-up (UserService,
--     then Players:GetNameFromUserIdAsync); a headshot (rbxthumb) on every row
--   * no DataStore (Studio without API access, an outage): the boards rank this
--     server's players and say "THIS SERVER"; the store is retried with backoff.

local CollectionService = game:GetService("CollectionService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local Leaderboards = {}
local Data, Progression

local ROWS = 8
local WRITE_EVERY = 120        -- seconds between writes of one player's values
local READ_EVERY = 60          -- seconds between reads of the global tops
local REFRESH_EVERY = 5        -- seconds between board redraws
local WRITES_PER_TICK = 6      -- spread the writes out
local RETRY_MIN, RETRY_MAX = 60, 600   -- backoff after a failed read (s)
local TIE = 1e10               -- rebirth board: rebirths x TIE + XP
local MAX_VALUE = 2 ^ 52

local BOARDS = {
	earned = { store = "LB_XP_v1", title = "TOP CASINOS", what = "CASINO RANK" },
	cash = { store = "LB_Earned_v1", title = "HIGH ROLLERS", what = "LIFETIME EARNINGS" },
	size = { store = "LB_Rebirths_v1", title = "REBIRTH LEGENDS", what = "REBIRTHS" },
}
local KINDS = { "earned", "cash", "size" }

local stores: {[string]: any} = {}          -- kind -> OrderedDataStore (false = unavailable)
local globalTop: {[string]: any} = {}       -- kind -> { { userId, value } } (best first)
local globalOk = false                      -- the last read worked
local nextRead = 0                          -- os.clock() of the next read
local retryDelay = RETRY_MIN
local written: {[number]: any} = {}         -- userId -> { t = os.clock(), [kind] = value }
local names: {[number]: string} = {}        -- userId -> display name (cached look-ups)
local pendingNames: {[number]: boolean} = {}

------------------------------------------------------------------
-- values
------------------------------------------------------------------
local function short(n: number): string
	n = math.floor(n)
	if n >= 1e12 then return ("%.1fT"):format(n / 1e12) end
	if n >= 1e9 then return ("%.1fB"):format(n / 1e9) end
	if n >= 1e6 then return ("%.1fM"):format(n / 1e6) end
	if n >= 1e4 then return ("%.1fK"):format(n / 1e3) end
	local s, k = tostring(n), nil
	repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
	return s
end

local function xpOf(profile): number
	local stats = profile and profile.Stats
	return math.max(0, math.floor(tonumber(type(stats) == "table" and stats.XP) or 0))
end

local function rebirthsOf(profile): number
	local rb = profile and profile.Rebirth
	return math.max(0, math.floor(tonumber(type(rb) == "table" and rb.count) or 0))
end

-- a profile's value on a board (nil = not on it)
local function valueOf(kind: string, profile): number?
	if not profile then return nil end
	local v
	if kind == "earned" then
		v = xpOf(profile)
	elseif kind == "cash" then
		local stats = profile.Stats
		v = math.max(0, math.floor(tonumber(type(stats) == "table" and stats.TotalEarned) or 0))
	elseif kind == "size" then
		local n = rebirthsOf(profile)
		if n <= 0 then return nil end
		v = n * TIE + math.min(xpOf(profile), TIE - 1)
	end
	if not v or v <= 0 then return nil end
	return math.min(v, MAX_VALUE)
end

local function rankOfXP(xp: number): number
	if Progression and Progression.rankOf then
		local ok, r = pcall(Progression.rankOf, xp)
		if ok and type(r) == "number" then return r end
	end
	return 1
end

local function textOf(kind: string, v: number): string
	if kind == "earned" then
		return ("R%d  •  %s XP"):format(rankOfXP(v), short(v))
	elseif kind == "cash" then
		return "$" .. short(v)
	end
	local n = math.floor(v / TIE)
	return ("%d REBIRTH%s"):format(n, n == 1 and "" or "S")
end

------------------------------------------------------------------
-- the stores (budget-aware, pcall everywhere)
------------------------------------------------------------------
local function suffix(): string
	return (Data and Data.storeSuffix and Data.storeSuffix()) or ""
end

local function storeFor(kind: string)
	local s = stores[kind]
	if s ~= nil then return s or nil end
	if Data and Data.isPersistent and not Data.isPersistent() then
		stores[kind] = false
		return nil
	end
	local ok, res = pcall(function()
		return DataStoreService:GetOrderedDataStore(BOARDS[kind].store .. suffix())
	end)
	stores[kind] = ok and res or false
	return ok and res or nil
end

local function budget(reqType: Enum.DataStoreRequestType): number
	local ok, n = pcall(function() return DataStoreService:GetRequestBudgetForRequestType(reqType) end)
	return ok and n or 0
end

local function writeValue(kind: string, userId: number, value: number): boolean
	local store = storeFor(kind)
	if not store then return false end
	if budget(Enum.DataStoreRequestType.SetIncrementSortedAsync) < 1 then return false end
	local ok, err = pcall(function() store:SetAsync(tostring(userId), math.floor(value)) end)
	if not ok then warn(("[Leaderboards] write %s: %s"):format(kind, tostring(err))) end
	return ok
end

-- write a player's changed values (values captured by the caller)
local function writeAll(userId: number, values, force: boolean?)
	local rec = written[userId] or {}
	for _, kind in KINDS do
		local v = values[kind]
		if v and (force or rec[kind] ~= v) then
			if writeValue(kind, userId, v) then rec[kind] = v end
		end
	end
	rec.t = os.clock()
	written[userId] = rec
end

local function valuesOf(profile)
	local out = {}
	for _, kind in KINDS do out[kind] = valueOf(kind, profile) end
	return out
end

local function readTops()
	local anyOk = false
	for _, kind in KINDS do
		local store = storeFor(kind)
		if store and budget(Enum.DataStoreRequestType.GetSortedAsync) >= 1 then
			local ok, res = pcall(function()
				return store:GetSortedAsync(false, ROWS):GetCurrentPage()
			end)
			if ok and type(res) == "table" then
				local list = {}
				for _, entry in res do
					local uid = tonumber(entry.key)
					local v = tonumber(entry.value)
					if uid and v and v > 0 then table.insert(list, { userId = uid, value = v }) end
				end
				globalTop[kind] = list
				anyOk = true
			elseif not ok then
				warn(("[Leaderboards] read %s: %s"):format(kind, tostring(res)))
			end
		end
	end
	globalOk = anyOk
	if anyOk then
		retryDelay = RETRY_MIN
		nextRead = os.clock() + READ_EVERY
	else
		nextRead = os.clock() + retryDelay
		retryDelay = math.min(RETRY_MAX, retryDelay * 2)
	end
end

------------------------------------------------------------------
-- names (cached; looked up off the board loop)
------------------------------------------------------------------
local function nameOf(userId: number): string
	local plr = Players:GetPlayerByUserId(userId)
	if plr then return plr.DisplayName end
	local cached = names[userId]
	if cached then return cached end
	pendingNames[userId] = true
	return "..."
end

local function resolveNames()
	local ids = {}
	for uid in pendingNames do
		if not names[uid] then table.insert(ids, uid) end
	end
	table.clear(pendingNames)
	if #ids == 0 then return end
	local okSvc, UserService = pcall(game.GetService, game, "UserService")
	if okSvc and UserService then
		local ok, infos = pcall(function() return UserService:GetUserInfosByUserIdsAsync(ids) end)
		if ok and type(infos) == "table" then
			for _, info in infos do
				if type(info) == "table" and info.Id then
					names[info.Id] = info.DisplayName or info.Username
				end
			end
		end
	end
	for _, uid in ids do
		if not names[uid] then
			local ok, name = pcall(function() return Players:GetNameFromUserIdAsync(uid) end)
			names[uid] = (ok and type(name) == "string") and name or "Player"
		end
	end
end

------------------------------------------------------------------
-- the boards
------------------------------------------------------------------
-- global top + this server's live values (fresher), best first
local function rowsFor(kind: string)
	local byId = {}
	if globalOk and globalTop[kind] then
		for _, e in globalTop[kind] do byId[e.userId] = e.value end
	end
	for _, plr in Players:GetPlayers() do
		local v = valueOf(kind, Data.get(plr))
		if v then byId[plr.UserId] = v end
	end
	local rows = {}
	for uid, v in byId do table.insert(rows, { userId = uid, value = v }) end
	table.sort(rows, function(a, b)
		if a.value ~= b.value then return a.value > b.value end
		return a.userId < b.userId
	end)
	return rows
end

-- a headshot between the rank and the name (made once per row)
local function headshot(row: Instance): ImageLabel?
	local img = row:FindFirstChild("Headshot")
	if img then return img end
	local name = row:FindFirstChild("PlayerName")
	if not (name and name:IsA("GuiObject")) then return nil end
	img = Instance.new("ImageLabel")
	img.Name = "Headshot"
	img.BackgroundTransparency = 1
	img.AnchorPoint = Vector2.new(0, 0.5)
	img.Position = UDim2.fromScale(0.115, 0.5)
	img.Size = UDim2.fromScale(0.06, 0.92)
	img.ScaleType = Enum.ScaleType.Fit
	img.ZIndex = 3
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1
	aspect.Parent = img
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = img
	img.Parent = row
	name.Position = UDim2.fromScale(0.17, 0.1)
	name.Size = UDim2.fromScale(0.52, 0.8)
	return img
end

local function fill(board: Instance, kind: string, rows)
	local gui = board:FindFirstChild("Board")
	local bg = gui and gui:FindFirstChildWhichIsA("Frame")
	if not bg then return end
	local def = BOARDS[kind]
	local title = bg:FindFirstChild("Title", true)
	if title and title:IsA("TextLabel") then title.Text = def.title end
	local sub = bg:FindFirstChild("Subtitle")
	if sub and sub:IsA("TextLabel") then
		sub.Text = (globalOk and "GLOBAL  •  ALL SERVERS  •  " or "THIS SERVER  •  ") .. def.what
	end
	for i = 1, ROWS do
		local row = bg:FindFirstChild("Row" .. i)
		local nameLabel = row and row:FindFirstChild("PlayerName")
		local valueLabel = row and row:FindFirstChild("Value")
		if nameLabel and valueLabel then
			local r = rows[i]
			nameLabel.Text = r and nameOf(r.userId) or "—"
			valueLabel.Text = r and textOf(kind, r.value) or ""
			local img = headshot(row)
			if img then
				local want = r and ("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48"):format(r.userId) or ""
				if img.Image ~= want then img.Image = want end
				img.Visible = r ~= nil
			end
		end
	end
end

local function refresh()
	local ranked = {} -- each ranking once per refresh, however many boards show it
	for _, board in CollectionService:GetTagged("LeaderboardBoard") do
		local kind = board:GetAttribute("Board")
		if not BOARDS[kind] then kind = "earned" end
		ranked[kind] = ranked[kind] or rowsFor(kind)
		fill(board, kind, ranked[kind])
	end
end
Leaderboards.refreshNow = refresh -- (redraw at once: tests, after a rebirth)

-- write whoever is due (a few per tick); only while the store answers reads (no
-- write spam in Studio without API access)
local function writeDue()
	if not globalOk then return end
	local n = 0
	local now = os.clock()
	for _, plr in Players:GetPlayers() do
		if n >= WRITES_PER_TICK then break end
		local rec = written[plr.UserId]
		if not rec or now - (rec.t or 0) >= WRITE_EVERY then
			local profile = Data.get(plr)
			if profile then
				if budget(Enum.DataStoreRequestType.SetIncrementSortedAsync) < 2 then break end
				writeAll(plr.UserId, valuesOf(profile))
				n += 1
			end
		end
	end
end

------------------------------------------------------------------
-- join / leave / start
------------------------------------------------------------------
-- (init.server calls leave before the profile is released)
function Leaderboards.leave(player: Player)
	local uid = player.UserId
	local profile = Data and Data.get(player)
	local values = profile and valuesOf(profile)
	task.spawn(function()
		if values and globalOk and storeFor("earned") then
			local ok, err = pcall(writeAll, uid, values)
			if not ok then warn("[Leaderboards] leave: " .. tostring(err)) end
		end
		if not Players:GetPlayerByUserId(uid) then written[uid] = nil end
	end)
end

function Leaderboards.start(deps)
	Data = deps.Data
	Progression = deps.Progression
	-- the boards: drawn every few seconds (cheap, text only)
	task.spawn(function()
		while true do
			local ok, err = pcall(refresh)
			if not ok then warn("[Leaderboards] " .. tostring(err)) end
			task.wait(REFRESH_EVERY)
		end
	end)
	-- the global store: reads, writes, name look-ups (yielding, so on their own loop)
	task.spawn(function()
		task.wait(8) -- let the first profiles load
		while true do
			if storeFor("earned") then
				if os.clock() >= nextRead then
					local ok, err = pcall(readTops)
					if not ok then warn("[Leaderboards] read: " .. tostring(err)) end
				end
				local ok, err = pcall(writeDue)
				if not ok then warn("[Leaderboards] write: " .. tostring(err)) end
			end
			local ok, err = pcall(resolveNames)
			if not ok then warn("[Leaderboards] names: " .. tostring(err)) end
			task.wait(10)
		end
	end)
end

return Leaderboards
