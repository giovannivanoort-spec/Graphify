--!nonstrict
-- Economy.luau — Cash is stored in the persistent profile (Data) and mirrored
-- to a leaderstats IntValue so the native leaderboard + client HUD update live.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))

local Economy = {}

-- userId -> { intValue = IntValue, profile = table }
local sessions: {[number]: any} = {}

function Economy.setup(player: Player, profile)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	local cash = Instance.new("IntValue")
	cash.Name = Config.CurrencyName
	cash.Value = math.floor(profile.Cash or 0)
	cash.Parent = leaderstats

	sessions[player.UserId] = { intValue = cash, profile = profile }
end

function Economy.teardown(player: Player)
	sessions[player.UserId] = nil
end

function Economy.getCash(player: Player): number
	local s = sessions[player.UserId]
	return s and s.profile.Cash or 0
end

function Economy.addCash(player: Player, amount: number)
	local s = sessions[player.UserId]
	if not s then return end
	s.profile.Cash = math.max(0, math.floor(s.profile.Cash + amount))
	s.intValue.Value = s.profile.Cash
end

-- Deducts and returns true if affordable, else false.
function Economy.tryWithdraw(player: Player, amount: number): boolean
	local s = sessions[player.UserId]
	if not s then return false end
	amount = math.floor(amount)
	if amount >= 0 and s.profile.Cash >= amount then
		s.profile.Cash -= amount
		s.intValue.Value = s.profile.Cash
		return true
	end
	return false
end

return Economy
