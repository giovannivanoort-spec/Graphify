# Lighting

Part of [[Casino Masters — World]]. This is the "fake night" setup, chosen on 2026-10-14 after research into popular Roblox games. At runtime `src/ServerScriptService/CasinoServer/LightingSetup.luau` applies it. The Edit-mode values in the place are set to match.

## Place settings (not scriptable at runtime)

- `LightingStyle = Realistic` and `PrioritizeLightingQuality = true`. Together these are what the old Future technology was. Local lights get real shadows and specular highlights.

## Global

| Property | Value |
|---|---|
| ClockTime | 16.9 (the "sun" sits low in the west, wearing the moon texture) |
| GeographicLatitude | 23 |
| Brightness | 1.6 |
| ExposureCompensation | 0.35 |
| Ambient | 48, 42, 76 |
| OutdoorAmbient | 100, 90, 146 |
| ColorShift_Top | 150, 170, 255 (cool moonlight) |
| ColorShift_Bottom | 60, 35, 100 |
| EnvironmentDiffuseScale | 0.3 |
| EnvironmentSpecularScale | 1 |
| ShadowSoftness | 0.2 |

## Children

- **CasinoSky** (Sky)
  - Faces: the custom dusk-violet skybox from `assets/map/sky_*.png` (ids in `UIAssets.Sky`).
  - Sun: `rbxasset://sky/moon.jpg`, SunAngularSize 10.
  - Stars are painted into the texture, so StarCount is 0.
  - Fallback: `MapFX.luau` switches to the star field `rbxassetid://45944972` on the client if the custom faces can't be fetched (e.g. still in moderation). The Edit-mode place currently uses that star field.
- **CasinoAtmosphere**: Density 0.32, Offset 0.12, Color 90,70,140, Decay 40,30,70, Glare 0, Haze 0.9.
- **CasinoBloom**: Intensity 0.8, Size 32, Threshold 1.25.
- **CasinoGrade** (ColorCorrection): Contrast 0.1, Saturation 0.08, Tint 245,240,255.
- **SunRays**: Intensity 0.02, Spread 0.2 (a moon halo).
- **DepthOfField**: disabled during play.

## Local lights

- No light casts shadows.
- Most local lights are SpotLights pointing down: street lamps, casino-floor washes, sign downlights and showroom floodlights.
- Coloured uplights on the plaza palms.
- Neon parts only glow through bloom; they don't light anything.
