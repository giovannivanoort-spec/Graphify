# Workspace

Part of [[Casino Masters — World]]. The "Vegas Strip" map, built into the place on 2026-10-14 by the Edit-time tool `src/ServerStorage/MapTools/MapBuilder.luau` (props in `MapProps.luau`). Re-run it from the Studio command bar to rebuild `Map` and `Plots`:

```lua
require(game.ServerStorage.MapTools.MapBuilder:Clone()).build()
```

Total: about 3,100 parts and 68 lights in Edit mode. The Showroom building (about 400 parts) is added at runtime by `Showroom.luau`.

## Layout

x runs along the Strip. The moon (the fake-night "sun") hangs low in the west, above the showroom.

| Area | Where | What |
|---|---|---|
| Strip | x −150…150, road \|z\| ≤ 23 | 2 lanes each way, palm median with a fountain pool (\|x\| ≤ 62), sidewalks \|z\| 23…35 |
| Casinos | 3 north (z 75.5) + 3 south (z −75.5) at x = 0, 101, −101 | 79 × 81 plots, fronts facing the Strip |
| Welcome Plaza | x 150…242 | spawn, welcome sign, leaderboard, daily + VIP kiosks, Services desk |
| Showroom | x −194…−158 | runtime building, entrance east, sky beam on the roof |
| Backdrop | beyond \|z\| 126 and \|x\| 250 | back streets, 14 resort towers, observation wheel, LED sphere, mountains |

## Contents

- **Map** (Folder, attribute `MapBuilder`)
  - **Ground**: desert tiles (3 × 3 × 2048 studs) plus city paving.
  - **Strip**: road, markings, curbs, sidewalks, 24 lights.
    - Median: palms, double lamps, a fountain pool with 13 dancing jets (tag `MapFountainJet`).
    - StreetFurniture: lamps and bins.
  - **Alleys**: 4 string-light runs between the casinos (tag `CasinoProp`).
  - **Plaza**:
    - Inlaid neon ring and benches.
    - WelcomeSign: front reads "WELCOME / CASINO MASTERS", back reads "COME BACK SOON".
    - Leaderboard: its `Board` part is tagged `LeaderboardBoard` and filled by `Leaderboards.luau`.
    - DailyKiosk (tag `DailyKiosk`, opens the daily reward) and StoreKiosk (tag `StoreKiosk`, opens the Robux store).
    - 6 uplit palms, 2 searchlights (tag `MapSearchlight`), a taxi and a limo.
  - **ShowroomForecourt**: paving, red carpet, palms, 2 searchlights.
  - **Backdrop**:
    - BackStreets with lamps.
    - Towers: 14 resort towers with emissive window MaterialVariants (`CM_TowerWarm`, `CM_TowerCool`).
    - Landmarks: ObservationWheel (tag `MapWheel`) and LEDSphere (tag `MapSphere`).
    - Mountains: corner-up cube peaks, Persistent streaming.
- **Plots** (Folder): Plot1…Plot6, discovered by `Plots.luau`.
  - Assignment order: centre north, centre south, east north, east south, west north, west south.
  - Each plot has:
    - A `Base` part with a damask carpet texture.
    - An `Entrance` attachment on the sidewalk, used for player teleports and NPC spawns.
    - A `Frontage` folder: casino pylon with `OwnerSign` SurfaceGuis, entrance arch, red carpet, velvet ropes, hedges, low walls, an "expansion coming soon" hoarding, two floor SpotLights and a parked car.
- **StripSpawn**: SpawnLocation at (204, 0.9, 0) on the plaza, facing west down the Strip.

## Elsewhere

- `ServerStorage.LegacyMap`: the old flat map (roads, sidewalks, grass, 6 bare plots) plus a stray generated roulette model. Safe to delete.
- `ServerStorage.ArchivedMachines`: the old machine models, replaced by `MachineModels.luau`.
- Client FX for the map live in `src/StarterPlayer/StarterPlayerScripts/CasinoClient/MapFX.luau`.
