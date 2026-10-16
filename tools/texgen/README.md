# texgen: procedural world materials

Generates the tileable PBR maps behind `Materials.luau` (every material except the AI Asphalt), the loose images (parking stalls, zebra crossings, tower windows, a UV test), and the `MaterialIds.luau` manifest once the images are uploaded. Needs numpy and Pillow (scipy is not used: blurs are FFT-based). `python -I` is fine: the scripts add the user site-packages back themselves.

```
python -I tools/texgen/gen_textures.py <outdir>            # all maps + means.json + contact.png + scale_check.png
python -I tools/texgen/gen_textures.py --selftest          # proves every coordinate-built map tiles exactly
python -I tools/texgen/gen_textures.py <outdir> --only Pavers,CarpetNeon   # iterate on a few keys
python -I tools/texgen/write_manifest.py <uploads.json> <outdir>/means.json src/ReplicatedStorage/CasinoCommon/MaterialIds.luau
```

`uploads.json` maps each uploaded file (any URL or path; only the file name counts) to its id, e.g. `{"http://127.0.0.1:47823/tex/Pavers_color.png": "rbxassetid://123"}`. Missing uploads are written as `""` and listed on stderr (`--strict` refuses to write instead).

## What it writes

| Key | spt | Unit | Colour map | Notes |
|---|---|---|---|---|
| Pavers | 8 | 2x1 studs, half bond | 1024, paver 0.94 +-2.5%, grout 6 px @ 0.80 | rough 0.78 / 0.90 |
| PlazaTile | 12 | 3x3 slabs | 1024, checker 1.00/0.96, grout 6 px @ 0.82 | rough 0.62 / 0.90 |
| ConcreteSlab | 64 | 8x8 slabs | 512, slab 0.90 +-2% (8x8 table), mottle 1.5%, joint 3 px @ 0.82 | flat normal |
| SmoothConcrete | 8 | none | 512, 0.92 +-2% soft | Organic |
| Stucco | 8 | sand float | 512, 0.93 +-2% | Organic |
| Ashlar | 16 | 4x2 running bond | 1024, block 0.94 +-3%, joint 4 px @ 0.84 | faces >= 4x4 studs only |
| RoofMembrane | 32 | 8-stud sheets | 512, 0.90, faint laps | |
| Brass | 8 | faint brushing | 256, 0.96 +-2.5% | rough 0.35, metal 0.3 |
| PolishedTile | 16 | 4x4 tiles | 1024, tile 0.95 +-3%, soft veins <= 4%, joint 4 px @ 0.84 | rough 0.32 / 0.55 |
| HonedStone | 16 | same tiles | reuses PolishedTile colour + normal | `HonedStone_rough.png` 0.60 / 0.70 |
| Hedge | 6 | 0.3-0.5 stud leaf clumps | 512, colour baked | |
| Carpet* (8) | 8 | 2-stud motifs | 1024, colour baked | shared `Carpet_normal/_rough.png` |

Normal, roughness and metalness maps are 512. Normals are OpenGL (+Y = green = up in the image). Tintable colour maps are near-white greyscale: paint them with `Materials.paint(part, key, WorldPalette.X)`, which divides the measured mean (`means.json`, copied into the manifest) back out.

Loose images: `ParkingStalls.png` (192x1024, Texture StudsPerTileU 7.5 / V 40, 14-stud stalls either side of a 12-stud aisle), `Zebra.png` (Texture StudsPerTileU 3.2: a 1.6-stud stripe centred in each tile), `TowerWarm/TowerCool_color.png` + `_emit.png` + `_night.png` (1024, StudsPerTile 36, same window grid as the old windows_a / windows_b), `UvTest.png` (see below).

Tower maps: `_color` is the day look (stone/bronze field, dark glass; colour baked, Part.Color white), `_emit` the emissive mask (lit window cells only, sRGB-encoded like the old one), and `_night` the same tile with the lit cells baked in as warm/cool room light. Use `_night` (manifest `Images.TowerWarmNightColor` / `TowerCoolNightColor`) as the ColorMap of the emissive night variants `CM_TowerWarm` / `CM_TowerCool`, and `_color` for the `...Day` variants: if the engine multiplies the emissive mask by the colour map, the day map's dark glass would barely glow.

Upload every PNG in the output folder except `contact.png` and `scale_check.png` (51 images).

`contact.png` shows every map tinted with its WorldPalette target and tiled 2x2 (any seam would show). `scale_check.png` shows each material over a 24x12-stud area at 24 px/stud next to a 5-stud avatar. Sign off on both before uploading.

## UV origin

Measured in Studio (Regular pattern): on a top face the tile is anchored at the part's local (+X, +Z) corner, image u runs toward -X and v toward -Z, and partial tiles end at the -X / -Z edges. Every joint sits on the tile edge (half a joint on each side of u=0 / v=0), so a part sized in whole units shows whole units with a half joint along each edge. Never move geometry to align grout. `UvTest.png` (the black "1" block marks UV 0,0) is kept for re-checking other faces; `--half-unit` (rolls every map by half its unit) and `--shift-studs U,V` exist for a different anchor and are not needed with the measured one.

## Carpet rules (checked and printed per carpet)

Average luma (Rec.709 on sRGB) 0.15-0.30, motif luma <= 0.80, motif coverage <= 30% (pixels more than 0.10 luma from the field), strokes >= 12 px (0.09 stud), fibre noise <= 3.5%. Keep the order of `CARPETS`: it is `Config.Building.Carpets`.
