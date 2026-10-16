"""Casino Masters: procedural, tileable PBR maps for the world materials.

Every map wraps seamlessly: all noise is periodic by construction (FFT
filtered on the tile grid), every repeating unit and motif divides the tile,
and per-unit tone tables are indexed modulo the number of units per tile (run
--selftest to prove it: each material is rendered over a 2x2 tile area and
compared with the single tile repeated).

Tintable colour maps are near-white greyscale, so Part.Color sets the hue
(Materials.paint divides the measured mean back out). Carpets, Hedge and the
tower window maps have their colour baked in (Part.Color white). Normal maps
are OpenGL (+Y, green = up in the image), subtle. Roughness/metalness are
linear grey. Resolutions follow the Phase A contract: 1024 for the Pavers,
PlazaTile, Ashlar, PolishedTile and carpet COLOUR maps, 512 for every other
map, 256 for the Brass colour map; the tower window maps are 1024.

usage:
  python -I gen_textures.py [outdir] [--half-unit] [--shift-studs U,V]
                            [--only Key,Key] [--no-sheets] [--selftest]

  --half-unit        roll every patterned map by half its repeating unit
                     (only for a centre-anchored tile; Studio measured the
                     Regular pattern anchored at the part's +X/+Z corner, where
                     the default joints-on-the-tile-edge layout is right)
  --shift-studs U,V  roll every map by U,V studs (+U = right, +V = down in
                     the image), converted per material with its StudsPerTile
  --only             generate just these keys (plus the sheets)
  --selftest         check that every coordinate-built map tiles exactly

Writes <Key>_color/_normal/_rough.png (+ Brass_metal.png, HonedStone_rough.png,
the shared Carpet_normal/Carpet_rough.png), ParkingStalls.png, Zebra.png,
UvTest.png, TowerWarm/TowerCool _color/_emit/_night.png, means.json (mean RGB
0-255 of every *_color.png), contact.png and scale_check.png.
"""
import argparse
import json
import math
import os
import re
import sys

try:
    import numpy as np
except ImportError:  # python -I skips the user site-packages, where pip --user puts numpy/Pillow
    import site
    sys.path.append(site.getusersitepackages())
    import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
MAP_RES = 512  # normal / roughness / metalness maps

# studs per tile (must match Materials.Defs)
SPT = {
    "Pavers": 8, "PlazaTile": 12, "ConcreteSlab": 64, "SmoothConcrete": 8, "Stucco": 8,
    "Ashlar": 16, "RoofMembrane": 32, "Brass": 8, "PolishedTile": 16, "HonedStone": 16,
    "Hedge": 6, "Carpet": 8, "Tower": 36,
}
CARPETS = ["CarpetCrimson", "CarpetRoyal", "CarpetEmerald", "CarpetBlackGold",
           "CarpetMidnight", "CarpetNeon", "CarpetChips", "CarpetRetro"]


# ============================================================ basics
class Canvas:
    """A square tile of n px, repeated reps x reps (reps 2 = the seam self-test).
    x, y are pixel-centre coordinates, so a joint on a multiple of the unit is
    centred on the tile edge."""

    def __init__(self, n, reps=1):
        self.n, self.reps = n, reps
        m = n * reps
        yy, xx = np.mgrid[0:m, 0:m].astype(np.float32)
        self.x, self.y = xx + 0.5, yy + 0.5
        self.shape = (m, m)

    def noise(self, sigma, seed, sigma_x=None):
        """periodic smooth noise in [-1, 1]; sigma in px (sigma_x: anisotropic)"""
        base = pnoise(self.n, sigma, seed, sigma_x)
        return np.tile(base, (self.reps, self.reps)) if self.reps > 1 else base

    def table(self, ix, iy, nx, ny, seed):
        """per-unit random value in [-1, 1] from an nx x ny table that wraps with the tile"""
        t = np.random.default_rng(seed).uniform(-1, 1, (ny, nx)).astype(np.float32)
        return t[np.mod(iy, ny).astype(np.int64), np.mod(ix, nx).astype(np.int64)]

    def itable(self, ix, iy, values, seed):
        """per-unit pick from a balanced shuffled table (values is an ny x nx int grid)"""
        t = np.asarray(values)
        ny, nx = t.shape
        return t[np.mod(iy, ny).astype(np.int64), np.mod(ix, nx).astype(np.int64)]


_NOISE = {}


def pnoise(n, sigma, seed, sigma_x=None):
    """periodic gaussian-filtered white noise (FFT, numpy only), max |v| = 1"""
    sy = float(sigma)
    sx = sy if sigma_x is None else float(sigma_x)
    key = (n, sy, sx, seed)
    if key not in _NOISE:
        w = np.random.default_rng(seed).standard_normal((n, n))
        f = np.fft.fftfreq(n)
        g = np.exp(-2 * np.pi ** 2 * (sy ** 2 * f[:, None] ** 2 + sx ** 2 * f[None, :] ** 2))
        v = np.real(np.fft.ifft2(np.fft.fft2(w) * g))
        v -= v.mean()
        _NOISE[key] = (v / (np.abs(v).max() + 1e-12)).astype(np.float32)
    return _NOISE[key]


def blur(a, sigma):
    """wrap-around gaussian blur of a 2-D array (FFT, numpy only)"""
    ny, nx = a.shape
    fy, fx = np.fft.fftfreq(ny), np.fft.fftfreq(nx)
    g = np.exp(-2 * np.pi ** 2 * sigma ** 2 * (fy[:, None] ** 2 + fx[None, :] ** 2))
    return np.real(np.fft.ifft2(np.fft.fft2(a) * g)).astype(np.float32)


def aa(d, w=1.2):
    """anti-aliased coverage of a signed distance (inside < 0)"""
    return np.clip(0.5 - d / w, 0.0, 1.0)


def wrapd(v, period):
    """distance of v to the nearest multiple of period"""
    m = np.mod(v, period)
    return np.minimum(m, period - m)


def ramp(d, w):
    """0 at a unit's edge rising to 1 at w px inside (a rounded arris)"""
    return np.sin(np.clip(d / w, 0.0, 1.0) * (np.pi / 2))


def cell_dist(ex, ey, r):
    """distance inside a rounded-corner unit, from its distances to the x and y
    edges (positive inside, negative in the joint)"""
    d = np.minimum(ex, ey)
    cx, cy = np.maximum(r - ex, 0), np.maximum(r - ey, 0)
    return np.where((cx > 0) & (cy > 0), r - np.hypot(cx, cy), d)


def grey(v):
    return np.repeat(v[..., None], 3, -1)


def rgb(r, g, b):
    return np.array([r, g, b], np.float32) / 255.0


def paint(c, mask, col):
    m = mask[..., None]
    return c * (1 - m) + np.asarray(col, np.float32) * m


def luma(c):
    return c[..., 0] * 0.2126 + c[..., 1] * 0.7152 + c[..., 2] * 0.0722


def box_down(a, k):
    """exact k x k box downsample (keeps a periodic image periodic)"""
    if k == 1:
        return a
    h, w = a.shape[:2]
    return a.reshape(h // k, k, w // k, k, *a.shape[2:]).mean(axis=(1, 3))


def normal_from_height(h, strength):
    """OpenGL tangent-space normal map: green = +Y = up in the image"""
    dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5 * strength
    dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5 * strength
    nx, ny, nz = -dx, dy, np.ones_like(h)
    ln = np.sqrt(nx ** 2 + ny ** 2 + nz ** 2)
    n = np.stack([nx / ln, ny / ln, nz / ln], -1)
    return np.clip(np.round((n * 0.5 + 0.5) * 255), 0, 255).astype(np.uint8)


def to8(a):
    return np.clip(np.round(a * 255), 0, 255).astype(np.uint8)


def sd_polygon(px, py, verts):
    """signed distance to a closed polygon, negative inside (IQ's sdPolygon)"""
    vx = [float(v[0]) for v in verts]
    vy = [float(v[1]) for v in verts]
    d = (px - vx[0]) ** 2 + (py - vy[0]) ** 2
    s = np.ones_like(px)
    j = len(verts) - 1
    for i in range(len(verts)):
        ex, ey = vx[j] - vx[i], vy[j] - vy[i]
        wx, wy = px - vx[i], py - vy[i]
        t = np.clip((wx * ex + wy * ey) / (ex * ex + ey * ey), 0, 1)
        bx, by = wx - ex * t, wy - ey * t
        d = np.minimum(d, bx * bx + by * by)
        c1, c2, c3 = py >= vy[i], py < vy[j], ex * wy > ey * wx
        s = np.where((c1 & c2 & c3) | (~c1 & ~c2 & ~c3), -s, s)
        j = i
    return s * np.sqrt(d)


def star_verts(points, r_out, r_in, rot=0.0, r_mid=None):
    """star polygon (first point up in image space); r_mid: alternate long/short points"""
    vs = []
    for k in range(points * 2):
        a = rot + k * math.pi / points
        if k % 2:
            rad = r_in
        elif r_mid is not None and (k // 2) % 2:
            rad = r_mid
        else:
            rad = r_out
        vs.append((rad * math.sin(a), -rad * math.cos(a)))
    return vs


def sd_segment(px, py, ax, ay, bx, by):
    """distance to segment ab, and the 0..1 position along it"""
    ex, ey = bx - ax, by - ay
    t = np.clip(((px - ax) * ex + (py - ay) * ey) / (ex * ex + ey * ey), 0, 1)
    return np.hypot(px - ax - ex * t, py - ay - ey * t), t


def lattice(cv, px, py=None, ox=0.0, oy=0.0, drop=0.0):
    """local coordinates relative to the nearest node of a px x py lattice
    (odd columns dropped by `drop` px) and the node indices"""
    py = px if py is None else py
    x = cv.x - ox
    i = np.floor(x / px + 0.5)
    lx = x - i * px
    y = cv.y - oy - np.mod(i, 2) * drop
    j = np.floor(y / py + 0.5)
    ly = y - j * py
    return lx, ly, i, j


# ============================================================ tintable materials
# Each returns dict(color=HxWx3 [0..1], height=HxW, nstr=normal strength at
# 512 px, rough=HxW, metal=HxW|None, unit=(ux, uy) px at the generation size).

def grain(cv, fine, mid, seed, s_fine=1.0, s_mid=24.0):
    """the shared fine 'material' grain, so every surface reads as one family"""
    return 1 + fine * cv.noise(s_fine, seed) + mid * cv.noise(s_mid, seed + 1)


def pavers(cv):
    """CM_Pavers: 2x1-stud pavers, half bond. spt 8 at 1024 -> 128 px/stud."""
    W, H, G = 256, 128, 6
    row = np.floor(cv.y / H)
    xs = cv.x + np.mod(row, 2) * (W / 2)            # half-bond offset
    col = np.floor(xs / W)                          # the paver that wraps the edge keeps one tone
    d = cell_dist(wrapd(xs, W) - G / 2, wrapd(cv.y, H) - G / 2, 5)
    unit = aa(-d, 1.0)
    tone = 1 + 0.025 * cv.table(col, row, 1024 // W, 1024 // H, 3)
    lum = unit * 0.94 * tone * grain(cv, 0.010, 0.010, 4) + (1 - unit) * 0.80
    h = ramp(d, 7) + 0.03 * cv.noise(1.5, 6)
    rough = unit * (0.78 + 0.02 * cv.noise(30, 7)) + (1 - unit) * 0.90
    return dict(color=grey(lum), height=h, nstr=0.9, rough=rough, unit=(W, H))


def plaza(cv):
    """CM_PlazaTile: 3x3-stud slabs, two-tone checker. spt 12 at 1024 -> 85.3 px/stud."""
    S, G = 256, 6
    ix, iy = np.floor(cv.x / S), np.floor(cv.y / S)
    d = cell_dist(wrapd(cv.x, S) - G / 2, wrapd(cv.y, S) - G / 2, 4)
    unit = aa(-d, 1.0)
    checker = np.where(np.mod(ix + iy, 2) == 0, 1.0, 0.96).astype(np.float32)
    tone = 1 + 0.012 * cv.table(ix, iy, 4, 4, 8)
    lum = unit * 0.95 * checker * tone * grain(cv, 0.010, 0.010, 9) + (1 - unit) * 0.82
    h = ramp(d, 6) + 0.03 * cv.noise(1.5, 10)
    rough = unit * (0.62 + 0.03 * cv.noise(30, 11)) + (1 - unit) * 0.90
    return dict(color=grey(lum), height=h, nstr=0.9, rough=rough, unit=(S, S))


def concrete_slab(cv):
    """CM_ConcreteSlab: 8x8-stud slabs, 8 per tile. spt 64 at 512 -> 8 px/stud."""
    S, G = 64, 3
    ix, iy = np.floor(cv.x / S), np.floor(cv.y / S)
    d = cell_dist(wrapd(cv.x, S) - G / 2, wrapd(cv.y, S) - G / 2, 1)
    unit = aa(-d, 0.6)                                    # crisp: at 8 px/stud any blur widens it
    tone = 1 + 0.02 * cv.table(ix, iy, 8, 8, 12)
    mott = 1 + 0.015 * cv.noise(10, 13) + 0.006 * cv.noise(0.8, 14)
    lum = unit * 0.90 * tone * mott + (1 - unit) * 0.82
    h = 0.03 * cv.noise(1.0, 15)                          # flat: the joint is colour only (no pillowing)
    rough = 0.86 + 0.02 * cv.noise(12, 16)
    return dict(color=grey(lum), height=h, nstr=0.5, rough=rough, unit=(S, S))


def smooth_concrete(cv):
    """CM_SmoothConcrete: joint-free cast concrete (curbs, rims). spt 8 at 512."""
    lum = 0.92 * (1 + 0.013 * cv.noise(40, 17) + 0.006 * cv.noise(6, 18) + 0.004 * cv.noise(0.8, 19))
    h = 0.35 * cv.noise(1.0, 20) + 0.25 * cv.noise(5, 21)
    rough = 0.85 + 0.02 * cv.noise(30, 22)
    return dict(color=grey(lum), height=h, nstr=0.6, rough=rough, unit=(cv.n, cv.n))


def stucco(cv):
    """CM_Stucco: fine sand-float render (owner wall colours). spt 8 at 512."""
    lum = 0.93 * (1 + 0.02 * cv.noise(0.7, 23) + 0.012 * cv.noise(5, 24) + 0.02 * cv.noise(45, 25))
    h = 0.6 * cv.noise(0.7, 23) + 0.25 * cv.noise(3, 26)
    rough = 0.86 + 0.03 * cv.noise(20, 27)
    return dict(color=grey(lum), height=h, nstr=0.6, rough=rough, unit=(cv.n, cv.n))


def ashlar(cv):
    """CM_Ashlar: 4x2-stud stone blocks, running bond. spt 16 at 1024 -> 64 px/stud."""
    W, H, G = 256, 128, 4
    row = np.floor(cv.y / H)
    xs = cv.x + np.mod(row, 2) * (W / 2)
    col = np.floor(xs / W)
    d = cell_dist(wrapd(xs, W) - G / 2, wrapd(cv.y, H) - G / 2, 3)
    unit = aa(-d, 1.0)
    tone = 1 + 0.03 * cv.table(col, row, 1024 // W, 1024 // H, 28)
    lum = unit * 0.94 * tone * grain(cv, 0.010, 0.010, 29, s_mid=16) + (1 - unit) * 0.84
    h = ramp(d, 4) + 0.03 * cv.noise(1.0, 30)
    rough = unit * (0.72 + 0.03 * cv.noise(20, 31)) + (1 - unit) * 0.90
    return dict(color=grey(lum), height=h, nstr=0.75, rough=rough, unit=(W, H))


def roof(cv):
    """CM_RoofMembrane: 8-stud membrane sheets, welded laps. spt 32 at 512 -> 16 px/stud."""
    S = 128
    lap = aa(wrapd(cv.y, S) - 1.5, 1.0)                                    # 3 px welded lap
    shadow = aa(np.abs(np.mod(cv.y, S) - 3.0) - 1.0, 1.5) * 0.7            # soft line below it
    end = aa(wrapd(cv.x + np.mod(np.floor(cv.y / S), 2) * 128, 256) - 1.0, 1.0)
    mott = 1 + 0.015 * cv.noise(40, 32) + 0.006 * cv.noise(4, 33) + 0.005 * cv.noise(0.8, 34)
    lum = 0.90 * mott * (1 + 0.02 * lap - 0.02 * shadow - 0.012 * end)
    h = lap * 0.6 + end * 0.3
    rough = 0.88 + 0.02 * cv.noise(25, 35) - 0.04 * lap
    return dict(color=grey(lum), height=h, nstr=0.4, rough=rough, unit=(256, S))


def brass(cv):
    """CM_Brass: clean painted-on metal, faint brushing. spt 8 at 512 -> 64 px/stud.
    Metalness 0.3 keeps most of the diffuse colour so it still reads gold at night."""
    brush = cv.noise(0.5, 36, sigma_x=18)
    lum = 0.96 * (1 + 0.02 * cv.noise(48, 37) + 0.005 * brush)
    h = 0.25 * brush
    rough = 0.35 + 0.025 * cv.noise(30, 38) + 0.01 * brush
    metal = np.full(cv.shape, 0.30, np.float32)
    return dict(color=grey(lum), height=h, nstr=0.6, rough=rough, metal=metal, unit=(cv.n, cv.n))


def polished_tile(cv):
    """CM_PolishedTile (+ HonedStone roughness): 4x4-stud tiles, faint veins.
    spt 16 at 1024 -> 64 px/stud."""
    S, G = 256, 4
    ix, iy = np.floor(cv.x / S), np.floor(cv.y / S)
    d = cell_dist(wrapd(cv.x, S) - G / 2, wrapd(cv.y, S) - G / 2, 2)
    unit = aa(-d, 1.0)
    tone = 1 + 0.03 * cv.table(ix, iy, 4, 4, 39)
    # long, softly warped veins; each tile runs them in its own direction, so they
    # break at the joints like real cut stone (at most ~5% darker)
    pick = cv.itable(ix, iy, [[0, 1, 2, 3], [2, 3, 0, 1], [1, 0, 3, 2], [3, 2, 1, 0]], 0)
    vein = np.zeros(cv.shape, np.float32)
    lx, ly = cv.x - ix * S, cv.y - iy * S                        # tile-local, so the map wraps
    shift = 0.5 * cv.table(ix, iy, 4, 4, 43)
    for k, deg in enumerate((28, 62, 118, 152)):
        a = math.radians(deg)
        warp = 0.55 * cv.noise(56, 40 + k) + 0.06 * cv.noise(12, 50 + k)
        ph = (lx * math.cos(a) + ly * math.sin(a)) / 230.0 + shift + warp
        dist = np.abs(ph - np.round(ph)) * 230.0                  # px to the vein's centre
        v = 0.022 * np.exp(-(dist / 7.0) ** 2) + 0.016 * np.exp(-(dist / 26.0) ** 2)
        vein = np.where(pick == k, v, vein)
    cloud = 1 + 0.012 * cv.noise(40, 44) + 0.004 * cv.noise(1.0, 47)
    lum = unit * 0.95 * tone * (1 - vein) * cloud + (1 - unit) * 0.84
    h = ramp(d, 3)
    rough = unit * (0.32 + 0.02 * cv.noise(40, 45)) + (1 - unit) * 0.55
    honed = unit * (0.60 + 0.02 * cv.noise(40, 46)) + (1 - unit) * 0.70
    return dict(color=grey(lum), height=h, nstr=0.45, rough=rough, unit=(S, S),
                extra={"HonedStone_rough": honed})


def hedge(cv):
    """CM_Hedge: leaf clumps 0.3-0.5 stud across, colour baked. spt 6 at 512 -> 85.3 px/stud."""
    n = cv.n
    rng = np.random.default_rng(47)
    greens = [rgb(44, 110, 58), rgb(62, 140, 70), rgb(92, 172, 86)]
    col = np.zeros((n, n, 3), np.float32) + rgb(28, 70, 40)
    h = np.zeros((n, n), np.float32)
    leaf = 1 + 0.06 * pnoise(n, 1.0, 48) + 0.04 * pnoise(n, 3.0, 49)
    for _ in range(900):
        cx, cy = rng.uniform(0, n, 2)
        r = rng.uniform(12.8, 21.3)                    # 0.3-0.5 stud diameter
        base = greens[rng.choice(3, p=[0.3, 0.42, 0.28])] * rng.uniform(0.97, 1.03)
        R = int(math.ceil(r + 2))
        ys = np.arange(int(cy) - R, int(cy) + R + 1)
        xs = np.arange(int(cx) - R, int(cx) + R + 1)
        dy = (ys + 0.5 - cy)[:, None]
        dx = (xs + 0.5 - cx)[None, :]
        dist = np.hypot(dx, dy)
        m = aa(dist - r, 1.0)
        dome = np.sqrt(np.clip(1 - (dist / r) ** 2, 0, 1))
        light = 1 + 0.08 * np.clip(-(dx + dy) / (r * 1.414), -1, 1)    # top-left highlight
        rim = 1 - 0.16 * np.clip(dist / r, 0, 1) ** 3                   # clumps separate softly
        iy, ix = np.ix_(np.mod(ys, n), np.mod(xs, n))
        shade = (light * rim)[..., None] * base * leaf[iy, ix][..., None]
        col[iy, ix] = col[iy, ix] * (1 - m[..., None]) + shade * m[..., None]
        h[iy, ix] = h[iy, ix] * (1 - m) + (0.4 + 0.6 * dome) * (r / 21.3) * m
    if cv.reps > 1:
        col, h = np.tile(col, (cv.reps, cv.reps, 1)), np.tile(h, (cv.reps, cv.reps))
    rough = 0.80 + 0.04 * cv.noise(6, 50) + 0.08 * (h < 0.2)
    return dict(color=col, height=h, nstr=1.6, rough=rough, unit=(cv.n, cv.n))


# ============================================================ carpets (colour baked)
# 1024 px at spt 8 -> 128 px/stud; every motif repeats on a 2-stud (256 px) grid.

def fibre(cv, seed):
    """carpet pile: +-3.5% at most"""
    return (1 + 0.025 * cv.noise(0.8, seed) + 0.010 * cv.noise(4, seed + 1))[..., None]


def damask(cv, field, lift, seed):
    """a tonal (same hue, +-lift) soft ground layer: rich without adding motifs"""
    v = cv.noise(60, seed)
    return np.asarray(field, np.float32) * (1 + lift * v)[..., None]


def carpet_crimson(cv):
    """Crimson Royale: gold diamond lattice with a dark keyline, cream rosettes
    on the crossings, gold dots in the diamonds."""
    F, GOLD, KEY = rgb(112, 16, 36), rgb(196, 146, 58), rgb(70, 8, 22)
    CREAM = rgb(226, 196, 140)
    P = 256
    dl = np.minimum(wrapd(cv.x + cv.y, P), wrapd(cv.x - cv.y, P)) / math.sqrt(2)
    line = aa(dl - 6.5)                                   # 13 px gold
    key = aa(dl - 10.5) - line                            # 4 px dark keyline either side
    lx, ly, i, j = lattice(cv, 128)
    on = np.mod(i + j, 2) == 0                            # lattice crossings
    r = np.hypot(lx, ly)
    a = np.arctan2(ly, lx)
    ros = aa(r - (24 + 10 * np.cos(4 * a))) * on
    core = aa(r - 9) * on
    dot = aa(r - 8) * (~on)
    c = damask(cv, F, 0.05, 61) * np.ones(cv.shape + (3,), np.float32)
    for m, col in ((key, KEY), (line, GOLD), (dot, GOLD), (ros, CREAM), (core, GOLD)):
        c = paint(c, m, col)
    return c * fibre(cv, 62), F


def carpet_royal(cv):
    """Royal Stars: gold 5-point stars on a 2-stud grid in a soft halo ring,
    cyan dots in the cell centres."""
    F, GOLD, CYAN, HALO = rgb(52, 24, 92), rgb(204, 160, 70), rgb(63, 170, 220), rgb(76, 42, 126)
    lx, ly, _, _ = lattice(cv, 256)
    star = aa(sd_polygon(lx, ly + 2, star_verts(5, 38, 17)))
    ring = aa(np.abs(np.hypot(lx, ly) - 62) - 7)
    cx, cy, _, _ = lattice(cv, 256, ox=128, oy=128)
    dot = aa(np.hypot(cx, cy) - 8)
    # a faint lighter-violet trellis through the dots ties the field together
    tr = np.minimum(wrapd(cv.x + cv.y, 256), wrapd(cv.x - cv.y, 256)) / math.sqrt(2)
    trellis = aa(tr - 6) * (1 - aa(np.hypot(lx, ly) - 76))
    c = damask(cv, F, 0.05, 63) * np.ones(cv.shape + (3,), np.float32)
    for m, col in ((trellis, HALO), (ring, HALO), (star, GOLD), (dot, CYAN)):
        c = paint(c, m, col)
    return c * fibre(cv, 64), F


def suit_sdf(kind, lx, ly):
    """card-suit signed distance (px, image coords, ~88 px tall, centred)"""
    def heart(px, py):                       # IQ heart, tip at (0,0), lobes up (y up)
        x, y = np.abs(px), py
        d1 = np.hypot(x - 0.25, y - 0.75) - math.sqrt(2) / 4
        m = 0.5 * np.maximum(x + y, 0.0)
        d2 = np.sqrt(np.minimum(x ** 2 + (y - 1) ** 2, (x - m) ** 2 + (y - m) ** 2)) * np.sign(x - y)
        return np.where(y + x > 1.0, d1, d2)
    if kind == 0:                            # spade: inverted heart + flared stem
        k = 66.0
        body = heart(lx / k, (ly + 44) / k) * k
        stem = sd_polygon(lx, ly, [(0, 6), (17, 44), (-17, 44)])
        return np.minimum(body, stem)
    if kind == 1:                            # heart
        k = 74.0
        return heart(lx / k, (41 - ly) / k) * k
    if kind == 2:                            # diamond
        a, b = 33.0, 44.0
        return (np.abs(lx) * b + np.abs(ly) * a - a * b) / math.hypot(a, b)
    # club: three lobes, a centre fill and the stem
    d = np.hypot(lx, ly + 20) - 20
    d = np.minimum(d, np.hypot(lx - 21, ly + 1) - 19)
    d = np.minimum(d, np.hypot(lx + 21, ly + 1) - 19)
    d = np.minimum(d, np.hypot(lx, ly) - 12)
    return np.minimum(d, sd_polygon(lx, ly, [(0, 4), (15, 44), (-15, 44)]))


def carpet_emerald(cv):
    """Emerald Suits: cream card suits cycling spade/heart/diamond/club on a
    2-stud half-drop, each in a gold ring."""
    F, CREAM, GOLD = rgb(14, 70, 50), rgb(214, 198, 162), rgb(200, 156, 64)
    lx, ly, i, j = lattice(cv, 256, drop=128)
    kind = np.mod(i + j, 4)
    suit = np.zeros(cv.shape, np.float32)
    for k in range(4):
        suit = np.where(kind == k, aa(suit_sdf(k, lx, ly)), suit)
    ring = aa(np.abs(np.hypot(lx, ly) - 58) - 6)          # 12 px stroke
    c = damask(cv, F, 0.06, 65) * np.ones(cv.shape + (3,), np.float32)
    for m, col in ((ring, GOLD), (suit, CREAM)):
        c = paint(c, m, col)
    return c * fibre(cv, 66), F


def carpet_blackgold(cv):
    """Black-Gold Deco: Art-Deco fans (1-stud radius) in half-dropped rows on
    a black field: a gold rim, a thin wine band and a rising sun (gold core,
    three bronze wedge rays). The black field stays the dominant colour."""
    F, GOLD, WINE, BRONZE = rgb(23, 18, 26), rgb(198, 150, 62), rgb(84, 16, 34), rgb(128, 94, 46)
    R = 128
    row = np.floor(cv.y / R)
    off = np.mod(row, 2) * R
    cx = np.floor((cv.x + off) / (2 * R)) * 2 * R + R - off
    cy = (row + 1) * R
    lx, ly = cv.x - cx, cy - cv.y                          # ly up from the fan's base
    r = np.hypot(lx, ly)
    rim = aa(np.abs(r - 112) - 6)                           # 12 px gold rim
    band = aa(np.abs(r - 84) - 10)                          # 20 px wine band, black either side
    # rays: the 3 odd sectors of 7 equal sectors of the half disc (straight up
    # and the two diagonals), between r 32 and 62: each wedge is >= 12 px wide
    # even at its inner end, so no hairlines shimmer
    a = np.clip(np.arctan2(ly, lx), 0, math.pi)
    sector = np.minimum(np.floor(a / (math.pi / 7)), 6)
    s_edge = np.abs(np.mod(a, math.pi / 7) - math.pi / 14) * r  # px to the sector's centre line
    wedge = aa(s_edge - r * (math.pi / 14) + 1.0) * (np.mod(sector, 2) == 1)
    rays = wedge * aa(r - 62) * (1 - aa(r - 32))
    core = aa(r - 22)
    c = damask(cv, F, 0.10, 67) * np.ones(cv.shape + (3,), np.float32)
    for m, col in ((band, WINE), (rim, GOLD), (rays, BRONZE), (core, GOLD)):
        c = paint(c, m, col)
    return c * fibre(cv, 68), F


def carpet_midnight(cv):
    """Midnight Compass: two-tone gold 8-point compass roses in navy medallions,
    on a 2-stud checkerboard with small 4-point stars, tied by a navy trellis."""
    F, GOLD, GOLD_D = rgb(20, 28, 68), rgb(214, 176, 96), rgb(168, 128, 62)
    STAR, RING, MED = rgb(196, 160, 90), rgb(40, 52, 110), rgb(28, 38, 88)
    lx, ly, i, j = lattice(cv, 256)
    big = np.mod(i + j, 2) == 0
    r = np.hypot(lx, ly)
    rose = aa(sd_polygon(lx, ly, star_verts(8, 77, 15, r_mid=48))) * big
    a = np.mod(np.arctan2(lx, -ly), 2 * math.pi)            # 0 = up, clockwise
    dark_half = np.mod(np.floor(a / (math.pi / 8)), 2) == 1
    med = aa(r - 100) * big
    ring1 = aa(np.abs(r - 58) - 7) * big
    ring2 = aa(np.abs(r - 100) - 6) * big
    small = aa(sd_polygon(lx, ly, star_verts(4, 30, 10))) * (~big)
    halo = aa(np.abs(r - 44) - 6) * (~big)
    tr = np.minimum(wrapd(cv.x + cv.y, 256), wrapd(cv.x - cv.y, 256)) / math.sqrt(2)
    trellis = aa(tr - 6) * (1 - med) * (1 - aa(r - 50) * (~big))
    c = damask(cv, F, 0.08, 69) * np.ones(cv.shape + (3,), np.float32)
    for m, col in ((med, MED), (trellis, RING), (ring1, RING), (ring2, RING), (halo, RING), (small, STAR)):
        c = paint(c, m, col)
    c = paint(c, rose * dark_half, GOLD_D)
    c = paint(c, rose * (~dark_half), GOLD)
    return c * fibre(cv, 70), F


def carpet_neon(cv):
    """Neon Retro: magenta and cyan zigzags (19 px, 2-stud period, the cyan rows
    phase-shifted into diamonds), amber rings in the diamonds."""
    F, MAG, CYA, AMB = rgb(26, 16, 44), rgb(196, 60, 160), rgb(54, 156, 196), rgb(220, 160, 60)
    A, P = 34.0, 256.0
    row = np.floor(cv.y / 128)
    ly = cv.y - (row * 128 + 64)
    lx = np.mod(cv.x + np.mod(row, 2) * 128, P)
    d = np.full(cv.shape, 1e9, np.float32)
    for o in (-P, 0.0, P):
        d = np.minimum(d, sd_segment(lx, ly, o, A, o + P / 2, -A)[0])
        d = np.minimum(d, sd_segment(lx, ly, o + P / 2, -A, o + P, A)[0])
    zig = aa(d - 9.5)
    mag = zig * (np.mod(row, 2) == 0)
    cya = zig * (np.mod(row, 2) == 1)
    cx, cy, _, _ = lattice(cv, 256)                            # every other diamond centre
    ring = aa(np.abs(np.hypot(cx, cy) - 26) - 7)
    c = damask(cv, F, 0.08, 71) * np.ones(cv.shape + (3,), np.float32)
    for m, col in ((mag, MAG), (cya, CYA), (ring, AMB)):
        c = paint(c, m, col)
    return c * fibre(cv, 72), F


def carpet_chips(cv):
    """Platinum Chips: 1-stud casino chips on a 2-stud half-drop: a cream edge
    with 6 crimson inserts, an ink face with a gold ring."""
    F, CREAM, RED = rgb(38, 36, 44), rgb(212, 200, 178), rgb(170, 26, 46)
    INK, GOLD = rgb(30, 26, 30), rgb(196, 150, 64)
    lx, ly, i, j = lattice(cv, 256, drop=128)
    rot = cv.itable(i, j, [[0, 2, 1, 3], [3, 1, 0, 2], [1, 3, 2, 0], [2, 0, 3, 1]], 0) * (math.pi / 12)
    r = np.hypot(lx, ly)
    a = np.arctan2(ly, lx) - rot
    chip = aa(r - 62)
    seg = np.mod(a, math.pi / 3) - math.pi / 6                 # 6 inserts on the edge
    insert = aa(np.abs(seg) * r - 14) * aa(np.abs(r - 52) - 10) * chip
    face = aa(r - 42)
    goldring = aa(np.abs(r - 28) - 6)
    shadow = aa(r - 66, 6) * (1 - chip) * 0.35                  # soft contact shadow on the field
    c = damask(cv, F, 0.06, 73) * np.ones(cv.shape + (3,), np.float32)
    c = c * (1 - shadow[..., None])
    for m, col in ((chip, CREAM), (insert, RED), (face, INK), (goldring, GOLD)):
        c = paint(c, m, col)
    return c * fibre(cv, 74), F


def carpet_retro(cv):
    """Atomic Teal: orange 1-stud boomerangs turned 0/120/240 degrees,
    cream starbursts in the cell centres."""
    F, ORANGE, CREAM = rgb(16, 72, 80), rgb(232, 124, 44), rgb(220, 200, 164)
    lx, ly, i, j = lattice(cv, 256)
    turn = cv.itable(i, j, [[0, 1, 2, 1], [2, 0, 1, 0], [1, 2, 0, 2], [0, 2, 1, 1]], 0)
    ang = turn * (2 * math.pi / 3) + math.radians(15)
    ca, sa = np.cos(ang), np.sin(ang)
    rx, ry = ca * lx + sa * ly, -sa * lx + ca * ly
    # a rounded V (parabola y = -26 + x^2/62), 26 px thick at the elbow, 12 px round tips
    pts = [(x, -26.0 + x * x / 62.0) for x in np.linspace(-56, 56, 15)]
    d = np.full(cv.shape, 1e9, np.float32)
    for k in range(len(pts) - 1):
        (ax, ay), (bx, by) = pts[k], pts[k + 1]
        dist, t = sd_segment(rx, ry, ax, ay, bx, by)
        u = np.abs((k + t) / (len(pts) - 1) * 2 - 1)               # 0 at the elbow, 1 at a tip
        d = np.minimum(d, dist - (13 - 7 * u ** 1.5))
    boom = aa(d)
    cx, cy, _, _ = lattice(cv, 256, ox=128, oy=128)
    burst = aa(sd_polygon(cx, cy, star_verts(8, 30, 11, r_mid=19)) - 2)
    c = damask(cv, F, 0.05, 75) * np.ones(cv.shape + (3,), np.float32)
    for m, col in ((boom, ORANGE), (burst, CREAM)):
        c = paint(c, m, col)
    return c * fibre(cv, 76), F


CARPET_FN = {
    "CarpetCrimson": carpet_crimson, "CarpetRoyal": carpet_royal, "CarpetEmerald": carpet_emerald,
    "CarpetBlackGold": carpet_blackgold, "CarpetMidnight": carpet_midnight,
    "CarpetNeon": carpet_neon, "CarpetChips": carpet_chips, "CarpetRetro": carpet_retro,
}

MATS = {  # key: (fn, generation size, colour map size)
    "Pavers": (pavers, 1024, 1024),
    "PlazaTile": (plaza, 1024, 1024),
    "ConcreteSlab": (concrete_slab, 512, 512),
    "SmoothConcrete": (smooth_concrete, 512, 512),
    "Stucco": (stucco, 512, 512),
    "Ashlar": (ashlar, 1024, 1024),
    "RoofMembrane": (roof, 512, 512),
    "Brass": (brass, 512, 256),
    "PolishedTile": (polished_tile, 1024, 1024),
    "Hedge": (hedge, 512, 512),
}


# ============================================================ loose images
def font(size):
    for f in ("arialbd.ttf", "Arial Bold.ttf", "DejaVuSans-Bold.ttf"):
        for d in ("C:/Windows/Fonts", "/Library/Fonts", "/usr/share/fonts/truetype/dejavu", ""):
            try:
                return ImageFont.truetype(os.path.join(d, f) if d else f, size)
            except OSError:
                pass
    return ImageFont.load_default(size=size)


def parking_stalls(out):
    """192x1024 transparent: one 7.5-stud stall per U tile (StudsPerTileU 7.5),
    a double-loaded 40-stud module in V (14-stud stalls, 12-stud aisle).
    4 px #F2F0EA separators at 85% alpha, centred on the U edges."""
    W, H = 192, 1024
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32) + 0.5
    v = yy * 40.0 / H                                      # studs along V
    line = aa(wrapd(xx, W) - 2.0, 1.0)                     # 2 px either side of the U edge
    # stalls at v 0..14 and 26..40; lines run on across the module edge (back-to-back stalls)
    stall_a = aa(np.maximum(0.0 - v, v - 14.0) * (H / 40), 1.0)
    stall_b = aa(np.maximum(26.0 - v, v - 40.0) * (H / 40), 1.0)
    alpha = 0.85 * line * np.maximum(stall_a, stall_b)
    img = np.zeros((H, W, 4), np.uint8)
    img[..., 0], img[..., 1], img[..., 2] = 0xF2, 0xF0, 0xEA
    img[..., 3] = to8(alpha)
    Image.fromarray(img, "RGBA").save(os.path.join(out, "ParkingStalls.png"), optimize=True)


def zebra(out):
    """256x256 transparent crosswalk tile: one stripe per U tile (StudsPerTileU
    3.2 -> a 1.6-stud stripe and a 1.6-stud gap), constant along V."""
    n = 256
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32) + 0.5
    alpha = 0.9 * aa(np.abs(xx - n / 2) - n / 4, 1.5)
    img = np.zeros((n, n, 4), np.uint8)
    img[..., 0], img[..., 1], img[..., 2] = 0xF2, 0xF0, 0xEA
    img[..., 3] = to8(alpha)
    Image.fromarray(img, "RGBA").save(os.path.join(out, "Zebra.png"), optimize=True)


def uv_test(out):
    """1024 marker image: which corner of a face does Roblox put the tile origin on?"""
    n = 1024
    im = Image.new("RGB", (n, n))
    dr = ImageDraw.Draw(im)
    quads = {"TL": ((0, 0), (226, 92, 92)), "TR": ((512, 0), (92, 186, 112)),
             "BL": ((0, 512), (92, 132, 226)), "BR": ((512, 512), (232, 196, 70))}
    for name, ((x, y), col) in quads.items():
        dr.rectangle([x, y, x + 511, y + 511], fill=col)
    f_cell, f_quad, f_big = font(24), font(140), font(170)
    for k in range(9):                                         # 1-stud grid at spt 8
        p = k * 128
        dr.line([(p, 0), (p, n)], fill=(40, 30, 36), width=2)
        dr.line([(0, p), (n, p)], fill=(40, 30, 36), width=2)
    for cx in range(8):
        for cy in range(8):
            if (cx < 2 and cy < 2) or (cx % 4 in (1, 2) and cy % 4 == 2):
                continue                          # under the origin block / a quadrant label
            dr.text((cx * 128 + 8, cy * 128 + 6), "ABCDEFGH"[cx] + str(cy + 1),
                    fill=(30, 24, 28), font=f_cell)
    for name, ((x, y), col) in quads.items():
        dr.text((x + 256, y + 320), name, fill=(255, 255, 255), font=f_quad, anchor="mm",
                stroke_width=6, stroke_fill=(30, 24, 28))
    # the origin marker: a black block on the top-left corner with a big "1"
    dr.rectangle([0, 0, 255, 255], fill=(16, 12, 14))
    dr.text((128, 120), "1", fill=(255, 220, 60), font=f_big, anchor="mm")
    dr.text((128, 228), "UV 0,0", fill=(255, 255, 255), font=font(30), anchor="mm")
    for (x, y, t) in ((n - 70, 50, "2"), (50, n - 50, "3"), (n - 70, n - 50, "4")):
        dr.text((x, y), t, fill=(16, 12, 14), font=font(80), anchor="mm")
    dr.text((280, 70), "+U  >>>", fill=(16, 12, 14), font=font(34), anchor="lm")
    dr.text((24, 300), "+V", fill=(16, 12, 14), font=font(34), anchor="lm")
    dr.text((30, 345), "v", fill=(16, 12, 14), font=font(34), anchor="lm")
    c = n // 2                                                  # the tile centre
    dr.ellipse([c - 30, c - 30, c + 30, c + 30], outline=(255, 255, 255), width=8)
    dr.line([(c - 60, c), (c + 60, c)], fill=(255, 255, 255), width=6)
    dr.line([(c, c - 60), (c, c + 60)], fill=(255, 255, 255), width=6)
    dr.rectangle([0, 0, n - 1, n - 1], outline=(16, 12, 14), width=6)
    im.save(os.path.join(out, "UvTest.png"), optimize=True)


def srgb_to_lin(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def lin_to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055)


LIT_WARM = [rgb(255, 217, 160), rgb(255, 200, 120), rgb(255, 230, 184)]   # the old windows_a/_b lights
LIT_COOL = [rgb(191, 230, 255), rgb(159, 211, 255), rgb(216, 240, 255)]


def tower(out, name, seed, cols, rows, lit_p, ribbon, field, slab, frame, glass, curtain, cool_p, blind):
    """Tower window tile (1024, StudsPerTile 36): a light stone field with
    bronze-framed dark glass by day; the emissive mask lights window cells only.
    Same grid as the old windows_a / windows_b, with fractional cell edges so
    the tile wraps exactly.
    <name>_night.png is the same tile with the lit cells baked in as warm/cool
    room light (blind cells: blind above, light below), for the night variant
    CM_TowerX: if the engine multiplies the emissive mask by the colour map,
    the day map's dark glass would barely glow."""
    n = 1024
    rng = np.random.default_rng(seed)
    lit = []                                                     # (gx0, gx1, gy0, gy1, level, blind cut)
    cv = Canvas(n)
    col = np.ones((n, n, 3), np.float32) * field
    col *= (1 + 0.012 * cv.noise(30, seed) + 0.006 * cv.noise(1.0, seed + 1))[..., None]
    emit = np.zeros((n, n), np.float32)
    xe = [round(i * n / cols) for i in range(cols + 1)]
    ye = [round(i * n / rows) for i in range(rows + 1)]
    for r in range(rows):
        y0, y1 = ye[r], ye[r + 1]
        ch = y1 - y0
        sh = max(6, ch // 9)
        col[y0:y0 + sh, :] = col[y0:y0 + sh, :] * (slab / field)   # floor slab line
        top, bot = max(16, ch // 6), max(12, ch // 8)
        for c in range(cols):
            x0, x1 = xe[c], xe[c + 1]
            cw = x1 - x0
            mx = 6 if ribbon else max(12, cw // 7)
            wx0, wx1, wy0, wy1 = x0 + mx, x1 - mx, y0 + top, y1 - bot
            fr = 6                                               # bronze frame
            col[wy0:wy1, wx0:wx1] = frame
            gx0, gx1, gy0, gy1 = wx0 + fr, wx1 - fr, wy0 + fr, wy1 - fr
            gh = gy1 - gy0
            g = glass * rng.uniform(0.93, 1.07)
            grad = np.interp(np.linspace(0, 1, gh), [0, 1], [1.2, 0.86]).astype(np.float32)
            pane = np.ones((gh, gx1 - gx0, 3), np.float32) * g * grad[:, None, None]
            roll = rng.random()
            if roll < 0.28:                                      # drawn curtain by day
                cut = int(gh * rng.uniform(0.35, 0.75))
                if rng.random() < 0.5:
                    pane[:cut] = curtain * rng.uniform(0.94, 1.04)
                else:
                    side = int((gx1 - gx0) * rng.uniform(0.25, 0.45))
                    pane[:, :side] = curtain * rng.uniform(0.94, 1.04)
            col[gy0:gy1, gx0:gx1] = pane
            if ribbon:                                           # ribbon mullions stay dark metal
                col[wy0:wy1, x0:x0 + mx] = frame
                col[wy0:wy1, x1 - mx:x1] = frame
            if rng.random() < lit_p:
                level = rng.uniform(0.55, 1.0)
                if rng.random() < 0.22:                          # half-drawn blind at night
                    cut = gy0 + int(gh * rng.uniform(0.3, 0.6))
                    emit[cut:gy1, gx0:gx1] = level
                else:
                    cut = gy0
                    emit[gy0:gy1, gx0:gx1] = level
                lit.append((gx0, gx1, gy0, gy1, level, cut))
    Image.fromarray(to8(col), "RGB").save(os.path.join(out, f"{name}_color.png"), optimize=True)
    # night colour map: its own rng, so the day map and the mask stay as they are
    nrng = np.random.default_rng(seed + 1000)
    night = col.copy()
    for gx0, gx1, gy0, gy1, level, cut in lit:
        pal = LIT_COOL if nrng.random() < cool_p else LIT_WARM
        base = srgb_to_lin(pal[nrng.integers(len(pal))])
        grad = np.linspace(1.0, 0.82, gy1 - cut, dtype=np.float32)[:, None, None]
        night[cut:gy1, gx0:gx1] = lin_to_srgb(base * level * grad)
        if cut > gy0:
            night[gy0:cut, gx0:gx1] = blind * nrng.uniform(0.94, 1.04)
    Image.fromarray(to8(night), "RGB").save(os.path.join(out, f"{name}_night.png"), optimize=True)
    e8 = to8(lin_to_srgb(emit))
    Image.fromarray(e8).convert("RGB").save(os.path.join(out, f"{name}_emit.png"), optimize=True)


# ============================================================ writing
def roll_px(a, shift_studs, spt):
    """roll a map by (U, V) studs at its own resolution"""
    if not shift_studs or shift_studs == (0, 0):
        return a
    pps = a.shape[1] / spt
    return np.roll(a, (int(round(shift_studs[1] * pps)), int(round(shift_studs[0] * pps))), axis=(0, 1))


def save_rgb(path, a):
    Image.fromarray(a if a.dtype == np.uint8 else to8(a), "RGB").save(path, optimize=True)


def save_l(path, a):
    Image.fromarray(to8(a), "L").save(path, optimize=True)


def write_material(out, key, args):
    fn, gen, cres = MATS[key]
    res = fn(Canvas(gen))
    spt = SPT[key]
    shift = args.shift_studs
    if args.half_unit:
        ux, uy = res["unit"]
        shift = ((shift[0] if shift else 0) + ux / 2 * spt / gen,
                 (shift[1] if shift else 0) + uy / 2 * spt / gen)
    k_c, k_m = gen // cres, gen // MAP_RES
    color = roll_px(box_down(res["color"], k_c), shift, spt)
    save_rgb(os.path.join(out, f"{key}_color.png"), color)
    h = box_down(res["height"], k_m)
    save_rgb(os.path.join(out, f"{key}_normal.png"), roll_px(normal_from_height(h, res["nstr"]), shift, spt))
    save_l(os.path.join(out, f"{key}_rough.png"), roll_px(box_down(res["rough"], k_m), shift, spt))
    if res.get("metal") is not None:
        save_l(os.path.join(out, f"{key}_metal.png"), roll_px(box_down(res["metal"], k_m), shift, spt))
    for name, arr in (res.get("extra") or {}).items():
        save_l(os.path.join(out, f"{name}.png"), roll_px(box_down(arr, k_m), shift, spt))
    return res


def write_carpets(out, keys, args):
    stats = {}
    shift = args.shift_studs
    if args.half_unit:                                   # half the 2-stud motif
        shift = (shift[0] + 1.0, shift[1] + 1.0)
    for key in keys:
        c, field = CARPET_FN[key](Canvas(1024))
        c = roll_px(c, shift, SPT["Carpet"])
        save_rgb(os.path.join(out, f"{key}_color.png"), c)
        lum = luma(np.clip(c, 0, 1))
        fl = float(luma(field[None, None, :])[0, 0])
        motif = np.abs(lum - fl) > 0.10
        stats[key] = dict(avg_luma=round(float(lum.mean()), 3), field_luma=round(fl, 3),
                          motif_cover=round(float(motif.mean()), 3),
                          motif_luma_p99=round(float(np.percentile(lum[motif], 99)) if motif.any() else 0, 3))
    if keys:
        cv = Canvas(MAP_RES)
        save_rgb(os.path.join(out, "Carpet_normal.png"), normal_from_height(0.4 * cv.noise(0.6, 77), 1.0))
        save_l(os.path.join(out, "Carpet_rough.png"), 0.95 + 0.01 * cv.noise(2, 78))
    return stats


# ============================================================ previews
def world_palette():
    pal = {}
    path = os.path.join(REPO, "src", "ReplicatedStorage", "CasinoCommon", "WorldPalette.luau")
    try:
        with open(path, encoding="utf-8") as f:
            for name, r, g, b in re.findall(r"(\w+)\s*=\s*rgb\((\d+),\s*(\d+),\s*(\d+)\)", f.read()):
                pal[name] = (int(r), int(g), int(b))
    except OSError:
        pass
    return pal


def load(out, name, mode="RGB"):
    return np.asarray(Image.open(os.path.join(out, name)).convert(mode)).astype(np.float32) / 255.0


def resized(im, size):
    """like the engine: bilinear when magnifying, area-averaged (mip-like) when shrinking"""
    return im.resize((size, size), Image.BILINEAR if size > im.width else Image.BOX)


def tinted(out, key, target, means, size):
    """the colour map at `size` px, multiplied by Materials.tint(key, target) and
    lit by its normal map from the top-left, like a part in the sun"""
    ckey = "PolishedTile" if key == "HonedStone" else key
    nkey = "Carpet" if key.startswith("Carpet") else ckey
    c = resized(Image.open(os.path.join(out, f"{ckey}_color.png")).convert("RGB"), size)
    nm = resized(Image.open(os.path.join(out, f"{nkey}_normal.png")).convert("RGB"), size)
    c = np.asarray(c).astype(np.float32) / 255
    nv = np.asarray(nm).astype(np.float32) / 255 * 2 - 1
    L = np.array([-0.45, 0.45, 0.77], np.float32)
    L /= np.linalg.norm(L)
    shade = np.clip((nv @ L) / L[2], 0.7, 1.2)[..., None]
    if target is not None:
        m = means[ckey]
        tint = np.array([min(1.0, target[i] / m[i]) for i in range(3)], np.float32)
        c = c * tint
    return np.clip(c * shade, 0, 1)


def avatar(dr, x, y_base, pps, fill=(10, 8, 10)):
    """a 5-stud blocky avatar silhouette standing on y_base"""
    s = pps
    def box(x0, y0, x1, y1):
        dr.rectangle([x + x0 * s, y_base - y1 * s, x + x1 * s - 1, y_base - y0 * s - 1], fill=fill)
    box(0.95, 0, 1.9, 2.0)        # legs
    box(2.1, 0, 3.05, 2.0)
    box(1.0, 2.0, 3.0, 4.0)       # torso
    box(0.0, 2.1, 0.95, 4.0)      # arms
    box(3.05, 2.1, 4.0, 4.0)
    dr.rounded_rectangle([x + 1.4 * s, y_base - 5.0 * s, x + 2.6 * s - 1, y_base - 4.0 * s - 1],
                         radius=int(0.25 * s), fill=fill)


SHEET = [  # key, label, WorldPalette target name (None = colour baked)
    ("Pavers", "Pavers / Sidewalk", "Sidewalk"),
    ("PlazaTile", "PlazaTile / Plaza", "Plaza"),
    ("ConcreteSlab", "ConcreteSlab / Lot", "Lot"),
    ("SmoothConcrete", "SmoothConcrete / Curb", "Curb"),
    ("Stucco", "Stucco / Stone", "Stone"),
    ("Stucco", "Stucco / owner Velvet Wine", (150, 44, 64)),
    ("Ashlar", "Ashlar / Stone", "Stone"),
    ("RoofMembrane", "RoofMembrane / Roof", "Roof"),
    ("Brass", "Brass / Brass", "Brass"),
    ("PolishedTile", "PolishedTile / Ivory", "Ivory"),
    ("HonedStone", "HonedStone / Granite", "Granite"),
    ("Hedge", "Hedge (baked)", None),
] + [(k, k + " (baked)", None) for k in CARPETS]


def contact_sheet(out, means, pal):
    tile, cols, lab = 210, 6, 26
    extras = ["TowerWarm day", "TowerWarm night", "TowerCool day", "TowerCool night",
              "ParkingStalls on lot", "Zebra on asphalt", "UvTest"]
    total = len(SHEET) + len(extras)
    rows = (total + cols - 1) // cols
    W, H = cols * (2 * tile + 12) + 12, rows * (2 * tile + lab + 12) + 12
    sheet = Image.new("RGB", (W, H), (22, 20, 24))
    dr = ImageDraw.Draw(sheet)
    f = font(17)
    k = 0

    def place(img, label):
        nonlocal k
        x = 12 + (k % cols) * (2 * tile + 12)
        y = 12 + (k // cols) * (2 * tile + lab + 12)
        dr.text((x + 2, y + 3), label, fill=(240, 220, 170), font=f)
        sheet.paste(Image.fromarray(to8(img)), (x, y + lab))
        k += 1

    for key, label, tgt in SHEET:
        target = pal.get(tgt) if isinstance(tgt, str) else tgt
        t = tinted(out, key, target, means, tile)
        place(np.tile(t, (2, 2, 1)), label)                     # 2x2: any seam shows
    for name in ("TowerWarm", "TowerCool"):
        c = load(out, f"{name}_color.png")
        e = load(out, f"{name}_emit.png")
        nc = load(out, f"{name}_night.png")
        tintc = rgb(255, 214, 160) if name == "TowerWarm" else rgb(190, 225, 255)
        # night: the night map under a dim violet ambient, plus the mask's glow
        # (taken as colour map x tint, the darker of the two possible engine rules)
        night = np.clip(nc * 0.22 * rgb(120, 110, 170) * 2 + e[..., :1] * nc * tintc * 1.1, 0, 1)
        for img, lbl in ((c, "day"), (night, "night")):
            small = np.asarray(Image.fromarray(to8(img)).resize((tile, tile), Image.LANCZOS)) / 255.0
            place(np.tile(small, (2, 2, 1)), f"{name} {lbl}")
    for name, bg in (("ParkingStalls", (66, 64, 62)), ("Zebra", (56, 54, 54))):
        im = Image.open(os.path.join(out, f"{name}.png")).convert("RGBA")
        if name == "ParkingStalls":
            im = im.resize((int(2 * tile * 7.5 / 40), 2 * tile), Image.LANCZOS)
        else:
            im = im.resize((2 * tile // 4, 2 * tile // 4), Image.LANCZOS)
        canvas = Image.new("RGBA", (2 * tile, 2 * tile), bg + (255,))
        for xx in range(0, 2 * tile, im.width):
            for yy in range(0, 2 * tile, im.height):
                canvas.alpha_composite(im, (xx, yy))
        place(np.asarray(canvas.convert("RGB")) / 255.0, f"{name}")
    uv = Image.open(os.path.join(out, "UvTest.png")).convert("RGB").resize((2 * tile, 2 * tile), Image.LANCZOS)
    place(np.asarray(uv) / 255.0, "UvTest")
    sheet.save(os.path.join(out, "contact.png"), optimize=True)


def scale_check(out, means, pal):
    """each material over a 24x12-stud area at 24 px/stud, painted with its
    WorldPalette target, beside a 5-stud avatar"""
    pps, sw, shh = 24, 24, 12
    pw, ph = sw * pps, shh * pps
    gut, lab, pad = 5 * pps, 24, 14
    items = SHEET + [("Tower", "TowerWarm (spt 36)", None)]
    cols = 2
    rows = (len(items) + cols - 1) // cols
    W = cols * (gut + pw + pad) + pad
    H = rows * (ph + lab + pad) + pad
    sheet = Image.new("RGB", (W, H), (236, 232, 226))
    dr = ImageDraw.Draw(sheet)
    f = font(17)
    for k, (key, label, tgt) in enumerate(items):
        x = pad + (k % cols) * (gut + pw + pad)
        y = pad + (k // cols) * (ph + lab + pad)
        spt = SPT["Carpet"] if key.startswith("Carpet") else SPT[key]
        tpx = spt * pps
        if key == "Tower":
            t = np.asarray(resized(Image.open(os.path.join(out, "TowerWarm_color.png")).convert("RGB"),
                                   tpx)).astype(np.float32) / 255
        else:
            target = pal.get(tgt) if isinstance(tgt, str) else tgt
            t = tinted(out, key, target, means, tpx)
        reps = (ph // tpx + 2, pw // tpx + 2, 1)
        panel = np.tile(t, reps)[:ph, :pw]
        sheet.paste(Image.fromarray(to8(panel)), (x + gut, y + lab))
        dr.text((x + gut + 2, y + 3), f"{label}   spt {spt}", fill=(40, 30, 36), font=f)
        avatar(dr, x + int(0.5 * pps), y + lab + ph, pps)
        for s in range(sw + 1):                                  # 1-stud ruler
            tx = x + gut + s * pps
            dr.line([(tx, y + lab + ph - (8 if s % 4 == 0 else 4)), (tx, y + lab + ph - 1)],
                    fill=(255, 255, 255), width=1)
    sheet.save(os.path.join(out, "scale_check.png"), optimize=True)


# ============================================================ self-test
def selftest():
    """every coordinate-built map must equal its own tile repeated 2x2"""
    ok = True
    for key, (fn, gen, _) in MATS.items():
        if key == "Hedge":                                     # stamped modulo the tile: periodic by construction
            continue
        a = fn(Canvas(gen))
        b = fn(Canvas(gen, 2))
        for ch in ("color", "height", "rough"):
            err = float(np.abs(np.tile(a[ch], (2, 2) + (1,) * (a[ch].ndim - 2)) - b[ch]).max())
            ok &= err < 1e-4
            if err >= 1e-4:
                print(f"  SEAM {key}.{ch}: max err {err:.5f}")
        print(f"  {key}: ok")
    for key, fn in CARPET_FN.items():
        a, _ = fn(Canvas(1024))
        b, _ = fn(Canvas(1024, 2))
        err = float(np.abs(np.tile(a, (2, 2, 1)) - b).max())
        ok &= err < 1e-4
        print(f"  {key}: {'ok' if err < 1e-4 else f'SEAM max err {err:.5f}'}")
    return ok


def edge_report(out, names):
    """wrap check on the written files: the step across the tile edge vs the
    typical step between neighbouring columns/rows"""
    worst = []
    for nm in names:
        a = np.asarray(Image.open(os.path.join(out, nm)).convert("RGB")).astype(np.float32)
        dxs = np.abs(np.diff(a, axis=1)).mean(axis=(0, 2))
        dys = np.abs(np.diff(a, axis=0)).mean(axis=(1, 2))
        ex = np.abs(a[:, 0] - a[:, -1]).mean()
        ey = np.abs(a[0] - a[-1]).mean()
        worst.append((nm, ex / (dxs.max() + 1e-6), ey / (dys.max() + 1e-6)))
    return worst


# ============================================================ main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?", default="out")
    ap.add_argument("--half-unit", action="store_true")
    ap.add_argument("--shift-studs", default="0,0")
    ap.add_argument("--only", default="")
    ap.add_argument("--no-sheets", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    su, sv = (float(v) for v in args.shift_studs.split(","))
    args.shift_studs = (su, sv)
    if args.selftest:
        print("self-test (2x2 tile area == tile repeated):")
        sys.exit(0 if selftest() else 1)

    out = args.out
    os.makedirs(out, exist_ok=True)
    only = set(filter(None, args.only.split(",")))
    want = (lambda k: not only or k in only)

    for key in MATS:
        if want(key):
            write_material(out, key, args)
            print("wrote", key)
    stats = write_carpets(out, [k for k in CARPETS if want(k)], args)
    for k, s in stats.items():
        print("wrote", k, s)
    if want("Images"):
        parking_stalls(out)
        zebra(out)
        uv_test(out)
        tower(out, "TowerWarm", 11, 6, 6, 0.55, False, field=rgb(205, 190, 168), slab=rgb(184, 166, 140),
              frame=rgb(122, 96, 66), glass=rgb(64, 54, 50), curtain=rgb(128, 112, 94),
              cool_p=0.15, blind=rgb(92, 74, 60))
        tower(out, "TowerCool", 23, 4, 7, 0.6, True, field=rgb(202, 192, 176), slab=rgb(178, 166, 148),
              frame=rgb(96, 84, 72), glass=rgb(52, 58, 64), curtain=rgb(128, 128, 124),
              cool_p=0.7, blind=rgb(84, 86, 90))
        print("wrote ParkingStalls, Zebra, UvTest, TowerWarm, TowerCool")

    # means of every *_color.png (0-255); HonedStone reuses PolishedTile's colour map
    means = {}
    for fn in sorted(os.listdir(out)):
        if fn.endswith("_color.png"):
            a = np.asarray(Image.open(os.path.join(out, fn)).convert("RGB")).astype(np.float64)
            means[fn[:-len("_color.png")]] = [round(float(v), 1) for v in a.mean(axis=(0, 1))]
    if "PolishedTile" in means:
        means["HonedStone"] = means["PolishedTile"]
    with open(os.path.join(out, "means.json"), "w") as f:
        json.dump(means, f, indent=1)
    for k, v in means.items():
        print(f"  mean {k}: {v}")

    if not args.no_sheets:
        pal = world_palette()
        contact_sheet(out, means, pal)
        scale_check(out, means, pal)
        print("wrote contact.png, scale_check.png")
    tiles = [f for f in os.listdir(out) if f.endswith(("_color.png", "_normal.png", "_rough.png", "_metal.png"))]
    bad = [w for w in edge_report(out, sorted(tiles)) if max(w[1], w[2]) > 1.25]
    print("edge check:", "all maps wrap cleanly" if not bad else bad)


if __name__ == "__main__":
    main()
