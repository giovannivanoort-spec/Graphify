--!strict
-- WorldPalette.luau — every colour in the world (map, buildings, showroom)
-- comes from here, so the city reads as one place. Ground and material
-- entries are RENDERED targets: pass them to Materials.paint, which works out
-- the tint for the texture underneath. The machines and the Showtime UI keep
-- their own, more saturated palette (MachineModels / UILib): the world is
-- their stage, never louder than they are.

local rgb = Color3.fromRGB

return {
	-- ground, darkest to lightest: asphalt < lots < roofs < sidewalk < plaza
	Asphalt = rgb(56, 54, 54), LotAsphalt = rgb(66, 64, 62), Lot = rgb(118, 110, 100),
	Roof = rgb(150, 144, 136), Curb = rgb(176, 170, 162), Sidewalk = rgb(186, 176, 162),
	WalkBorder = rgb(138, 128, 116), Plaza = rgb(206, 192, 170), PlazaBand = rgb(164, 148, 128),
	Sand = rgb(154, 122, 92), RockA = rgb(122, 78, 60), RockB = rgb(160, 104, 78),
	Lawn = rgb(78, 128, 62), Gravel = rgb(181, 154, 118),
	LaneWhite = rgb(237, 230, 216), LaneYellow = rgb(232, 181, 58),

	-- architecture
	Stone = rgb(222, 206, 176), DeepStone = rgb(176, 156, 124), Granite = rgb(44, 38, 42),
	Ink = rgb(36, 26, 32), Ceiling = rgb(42, 30, 36), Plum = rgb(42, 20, 32), Soffit = rgb(255, 240, 214),
	Lacquer = rgb(179, 21, 46), Wine = rgb(126, 14, 34), Ivory = rgb(238, 228, 210),
	Brass = rgb(214, 166, 70), DarkMetal = rgb(47, 42, 46),
	GlassClear = rgb(226, 222, 210), GlassSmoke = rgb(96, 78, 66),

	-- light (neon accents: at most these four world hues + warm white)
	Magenta = rgb(255, 62, 181), Cyan = rgb(56, 212, 255), Amber = rgb(255, 178, 56), Ruby = rgb(255, 61, 90),
	WarmNeon = rgb(255, 217, 160), BulbA = rgb(255, 226, 168), BulbB = rgb(255, 243, 214),
	Sodium = rgb(255, 201, 138), Interior = rgb(255, 220, 184),
}
