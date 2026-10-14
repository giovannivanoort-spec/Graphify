--!nonstrict
-- Leaderboards.luau — fills the plaza's "TOP CASINOS" board(s) (a part tagged
-- "LeaderboardBoard" by MapBuilder, holding a SurfaceGui "Board" with rows
-- Row1..Row8) with this server's players, ranked by lifetime earnings.
-- Text only, refreshed every few seconds; the SurfaceGui replicates.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local Leaderboards = {}
local Data

local ROWS = 8

local function short(n: number): string
	n = math.floor(n)
	if n >= 1e9 then return ("%.1fB"):format(n / 1e9) end
	if n >= 1e6 then return ("%.1fM"):format(n / 1e6) end
	if n >= 1e4 then return ("%.1fK"):format(n / 1e3) end
	local s, k = tostring(n), nil
	repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
	return s
end

local function refresh()
	local rows = {}
	for _, plr in Players:GetPlayers() do
		local profile = Data.get(plr)
		if profile and profile.Stats then
			table.insert(rows, { name = plr.DisplayName, value = profile.Stats.TotalEarned or 0 })
		end
	end
	table.sort(rows, function(a, b) return a.value > b.value end)

	for _, board in CollectionService:GetTagged("LeaderboardBoard") do
		local gui = board:FindFirstChild("Board")
		local bg = gui and gui:FindFirstChildWhichIsA("Frame")
		if bg then
			for i = 1, ROWS do
				local row = bg:FindFirstChild("Row" .. i)
				local nameLabel = row and row:FindFirstChild("PlayerName")
				local valueLabel = row and row:FindFirstChild("Value")
				if nameLabel and valueLabel then
					local r = rows[i]
					nameLabel.Text = r and r.name or "—"
					valueLabel.Text = r and ("$" .. short(r.value)) or ""
				end
			end
		end
	end
end

function Leaderboards.start(deps)
	Data = deps.Data
	task.spawn(function()
		while true do
			local ok, err = pcall(refresh)
			if not ok then warn("[Leaderboards] " .. tostring(err)) end
			task.wait(5)
		end
	end)
end

return Leaderboards
