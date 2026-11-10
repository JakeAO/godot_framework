#!/usr/bin/env python3
"""Generate themed placeholder art at the canonical paths (ART_MANIFEST.md, G1).

Every generated file is a flat-color / silhouette PNG drawn from the
ThemeFactory palette so the UI reads as "real but unfinished". Real art later
drops onto the SAME paths at the SAME pixel sizes with zero code changes (G2):
  - assets/sprites/icons/<key>.png           128x128 transparent silhouettes
                                             (one per ProtoIcon key)
  - assets/sprites/portraits/icons/<id>.png  128x128 circular avatars
  - assets/sprites/portraits/flairs/<id>.png 128x128 transparent overlays
  - assets/sprites/portraits/crowns/<id>.png  96x96 transparent crowns
  - assets/sprites/backgrounds/bg_default.png 720x1560 gradient

The tool ONLY writes inside those five placeholder directories. It never
touches existing real art (assets/sprites/ui_generic/, team_banners/, the
offer sprite frame dirs). WARNING: once real art replaces a placeholder, do
NOT re-run this tool for that category, or it will overwrite the real file.

Geometry mirrors scripts/ui/proto_icon.gd unit-for-unit so the texture path
and the code-drawn fallback look like siblings. Drawn at 2x and LANCZOS-
downsampled for antialiased edges.

Usage:
  python3 tools/gen_placeholders.py [icons|portraits|backgrounds ...]
  (no args = all categories)
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets" / "sprites"

# --- ThemeFactory palette (keep in sync with scripts/ui/theme_factory.gd) ----
GOLD = (245, 197, 66)  # #f5c542
BLUE = (79, 140, 255)  # #4f8cff
TEXT = (238, 242, 251)  # #eef2fb
DIM = (154, 167, 199)  # #9aa7c7
INK = (16, 20, 31)  # #10141f
SILVER = (199, 207, 221)  # #c7cfdd
DIAMOND = (111, 211, 242)  # #6fd3f2
GREEN = (88, 196, 112)  # #58c470
ORANGE = (232, 151, 58)  # #e8973a


def darken(color, t):
    return tuple(int(c * (1.0 - t)) for c in color)


def lighten(color, t):
    return tuple(int(c + (255 - c) * t) for c in color)


class Canvas:
    """Unit-space drawing surface. Unit coords match proto_icon.gd: origin at
    center, x right, y down, u = half the final canvas size."""

    def __init__(self, final_size, supersample=2):
        self.u = float(final_size) / 2.0 * supersample
        self.size = int(self.u * 2)
        self.img = Image.new("RGBA", (self.size, self.size), (0, 0, 0, 0))
        self.d = ImageDraw.Draw(self.img)

    def _pt(self, x, y):
        return (self.u + x * self.u, self.u + y * self.u)

    def poly(self, points, color):
        self.d.polygon([self._pt(x, y) for x, y in points], fill=color + (255,))

    def rect(self, x0, y0, x1, y1, color, radius=0.0):
        box = [self._pt(x0, y0), self._pt(x1, y1)]
        if radius > 0:
            self.d.rounded_rectangle(box, radius=radius * self.u, fill=color + (255,))
        else:
            self.d.rectangle(box, fill=color + (255,))

    def circle(self, x, y, r, color):
        c = self._pt(x, y)
        rr = r * self.u
        self.d.ellipse(
            [c[0] - rr, c[1] - rr, c[0] + rr, c[1] + rr], fill=color + (255,)
        )

    def ring(self, x, y, r, color, width_units):
        c = self._pt(x, y)
        rr = r * self.u
        w = max(2, int(width_units * self.u))
        self.d.ellipse(
            [c[0] - rr, c[1] - rr, c[0] + rr, c[1] + rr],
            outline=color + (255,),
            width=w,
        )

    def line(self, x0, y0, x1, y1, color, width_units):
        w = max(2, int(width_units * self.u))
        self.d.line([self._pt(x0, y0), self._pt(x1, y1)], fill=color + (255,), width=w)

    def arc(self, x, y, r, start_rad, end_rad, color, width_units):
        import math

        c = self._pt(x, y)
        rr = r * self.u
        w = max(2, int(width_units * self.u))
        # PIL angles are degrees, 0 at 3 o'clock, increasing clockwise in
        # image space — the same orientation as Godot's radian angles.
        self.d.arc(
            [c[0] - rr, c[1] - rr, c[0] + rr, c[1] + rr],
            start=math.degrees(start_rad),
            end=math.degrees(end_rad),
            fill=color + (255,),
            width=w,
        )

    def finish(self, final_size):
        return self.img.resize((final_size, final_size), Image.LANCZOS)


STROKE = 0.16  # proto_icon.gd _stroke(u) = max(2, u * 0.16)


# --- ProtoIcon silhouettes (geometry mirrors proto_icon.gd) -------------------


def i_trophy(c):
    c.poly([(-0.35, -0.5), (0.35, -0.5), (0.2, 0.05), (-0.2, 0.05)], GOLD)
    c.rect(-0.08, 0.05, 0.08, 0.23, GOLD)
    c.rect(-0.25, 0.23, 0.25, 0.37, GOLD)


def i_xp(c):
    c.poly(
        [
            (0, -0.9),
            (0.22, -0.22),
            (0.9, 0),
            (0.22, 0.22),
            (0, 0.9),
            (-0.22, 0.22),
            (-0.9, 0),
            (-0.22, -0.22),
        ],
        BLUE,
    )


def i_coin(c):
    c.circle(0, 0, 0.45, GOLD)
    c.circle(0, 0, 0.30, darken(GOLD, 0.35))


def i_gem(c):
    c.poly([(0, -0.85), (0.6, -0.1), (0, 0.85), (-0.6, -0.1)], DIAMOND)
    c.line(-0.6, -0.1, 0.6, -0.1, TEXT, 0.04)


def i_gift(c):
    c.rect(-0.45, -0.35, 0.45, 0.45, GOLD)
    c.rect(-0.5, -0.5, 0.5, -0.3, lighten(GOLD, 0.2))
    c.line(0, -0.5, 0, 0.45, INK, 0.06)
    c.line(-0.5, -0.4, 0.5, -0.4, INK, 0.06)


def i_bank(c):
    c.circle(0, 0, 0.45, DIM)
    c.rect(-0.18, -0.32, 0.18, -0.23, INK)


def i_booster(c):
    c.poly([(0, -0.8), (0.55, 0), (0, 0.8), (-0.55, 0)], BLUE)
    c.line(-0.18, 0, 0.18, 0, TEXT, 0.06)
    c.line(0, -0.18, 0, 0.18, TEXT, 0.06)


def i_crown(c):
    c.poly(
        [
            (-0.7, 0.4),
            (-0.7, -0.3),
            (-0.35, 0.0),
            (0, -0.55),
            (0.35, 0.0),
            (0.7, -0.3),
            (0.7, 0.4),
        ],
        GOLD,
    )


def i_chat(c):
    c.rect(-0.6, -0.5, 0.6, 0.3, BLUE)
    c.poly([(-0.3, 0.3), (-0.05, 0.3), (-0.4, 0.6)], BLUE)
    for i in range(3):
        c.circle((i - 1) * 0.28, -0.1, 0.06, INK)


def i_team(c):
    c.circle(-0.25, 0.0, 0.35, GOLD)
    c.circle(0.25, 0.0, 0.35, BLUE)


def i_search(c):
    c.ring(-0.1, -0.1, 0.4, TEXT, STROKE)
    c.line(0.18, 0.18, 0.6, 0.6, TEXT, STROKE)


def i_info(c):
    c.ring(0, 0, 0.45, GOLD, STROKE)
    c.circle(0, -0.18, 0.07, GOLD)
    c.line(0, -0.02, 0, 0.25, GOLD, STROKE)


def i_warning(c):
    c.poly([(-0.6, 0.45), (0, -0.55), (0.6, 0.45)], GOLD)
    c.line(0, -0.15, 0, 0.12, INK, 0.08)
    c.circle(0, 0.28, 0.06, INK)


def i_check(c):
    c.line(-0.45, 0.05, -0.1, 0.4, GREEN, 0.24)
    c.line(-0.1, 0.4, 0.5, -0.35, GREEN, 0.24)


def i_bell(c):
    c.circle(0, -0.15, 0.38, GOLD)
    c.line(-0.45, 0.25, 0.45, 0.25, GOLD, 0.1)
    c.circle(0, 0.38, 0.09, GOLD)
    c.circle(0, -0.55, 0.08, GOLD)


def i_music(c):
    c.circle(-0.15, 0.3, 0.2, BLUE)
    c.line(0.03, 0.3, 0.03, -0.45, BLUE, 0.1)
    c.poly([(0.03, -0.45), (0.45, -0.25), (0.03, -0.05)], BLUE)


def i_sfx(c):
    c.poly(
        [
            (-0.5, -0.2),
            (-0.15, -0.2),
            (0.15, -0.45),
            (0.15, 0.45),
            (-0.15, 0.2),
            (-0.5, 0.2),
        ],
        TEXT,
    )
    c.arc(0.2, 0.0, 0.3, -0.9, 0.9, GOLD, STROKE)


def i_shield(c):
    c.poly(
        [(0, -0.75), (0.6, -0.45), (0.6, 0.1), (0, 0.75), (-0.6, 0.1), (-0.6, -0.45)],
        BLUE,
    )


def i_support(c):
    c.ring(0, 0, 0.5, GOLD, 0.2)
    c.ring(0, 0, 0.25, BLUE, 0.2)


def i_pile(c):
    for x, y, half, color in [
        (-0.32, 0.34, 0.20, GOLD),
        (0.32, 0.34, 0.20, darken(GOLD, 0.25)),
        (0.0, -0.34, 0.22, lighten(GOLD, 0.15)),
    ]:
        c.rect(x - half, y - half, x + half, y + half, color)
        c.line(x, y - half, x, y + half, INK, 0.06)


ICONS = {
    "trophy": i_trophy,
    "xp": i_xp,
    "coin": i_coin,
    "gem": i_gem,
    "gift": i_gift,
    "bank": i_bank,
    "booster": i_booster,
    "crown": i_crown,
    "chat": i_chat,
    "team": i_team,
    "search": i_search,
    "info": i_info,
    "warning": i_warning,
    "check": i_check,
    "bell": i_bell,
    "music": i_music,
    "sfx": i_sfx,
    "shield": i_shield,
    "support": i_support,
    "pile": i_pile,
}

# --- Portrait catalogs (ids/colors mirror portrait_catalog.gd) ---------------

PORTRAIT_ICONS = {
    "default": BLUE,
    "gold": GOLD,
    "silver": SILVER,
    "diamond": DIAMOND,
    "ember": ORANGE,
    "forest": GREEN,
}

FLAIRS = {
    "ring_gold": ("ring", GOLD),
    "ring_blue": ("ring", BLUE),
    "banner_gold": ("banner", GOLD),
    "banner_blue": ("banner", BLUE),
    "capsule_gold": ("capsule", GOLD),
    "capsule_blue": ("capsule", BLUE),
}

CROWNS = {"crown_gold": GOLD, "crown_silver": SILVER, "crown_diamond": DIAMOND}


def portrait_icon(color):
    def draw(c):
        c.circle(0, 0, 0.48, darken(color, 0.35))
        c.circle(0, 0, 0.44, color)

    return draw


def flair(kind, color):
    def draw(c):
        if kind == "ring":
            c.ring(0, 0, 0.47, color, 6.0 / 128.0)
        elif kind == "banner":
            # Band sits at 10..26% of the icon square (PortraitView banner
            # anchors 0.42/0.58 of the full composite minus the crown row).
            c.rect(-0.5, 0.10, 0.5, 0.26, color, radius=0.03)
        elif kind == "capsule":
            c.ring(0, 0, 0.49, color, 6.0 / 128.0)

    return draw


def crown(color):
    def draw(c):
        c.poly(
            [
                (-0.7, 0.4),
                (-0.7, -0.3),
                (-0.35, 0.0),
                (0, -0.55),
                (0.35, 0.0),
                (0.7, -0.3),
                (0.7, 0.4),
            ],
            color,
        )

    return draw


def background():
    w, h = 720, 1560
    top = (23, 30, 46)  # slightly lifted #171e2e
    bottom = (13, 17, 25)  # #0d1119 (theme progress-track tone)
    img = Image.new("RGB", (w, h))
    for y in range(h):
        t = y / float(h - 1)
        row = tuple(int(a + (b - a) * t) for a, b in zip(top, bottom))
        ImageDraw.Draw(img).line([(0, y), (w, y)], fill=row)
    return img


# --- Generation ----------------------------------------------------------------


def write_png(path, image):
    if path.exists() and path.stat().st_size == 0:
        sys.exit("FAIL %s exists but is empty; refusing to continue" % path)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)
    print("wrote %-72s %dx%d" % (path.relative_to(ROOT), image.width, image.height))


def gen_icons():
    outdir = ASSETS / "icons"
    for key, draw in ICONS.items():
        c = Canvas(128)
        draw(c)
        write_png(outdir / ("%s.png" % key), c.finish(128))


def gen_portraits():
    icons = ASSETS / "portraits" / "icons"
    flairs = ASSETS / "portraits" / "flairs"
    crowns = ASSETS / "portraits" / "crowns"
    for pid, color in PORTRAIT_ICONS.items():
        c = Canvas(128)
        portrait_icon(color)(c)
        write_png(icons / ("%s.png" % pid), c.finish(128))
    for fid, (kind, color) in FLAIRS.items():
        c = Canvas(128)
        flair(kind, color)(c)
        write_png(flairs / ("%s.png" % fid), c.finish(128))
    for cid, color in CROWNS.items():
        c = Canvas(96)
        crown(color)(c)
        write_png(crowns / ("%s.png" % cid), c.finish(96))


def gen_backgrounds():
    outdir = ASSETS / "backgrounds"
    write_png(outdir / "bg_default.png", background())


GENERATORS = {
    "icons": gen_icons,
    "portraits": gen_portraits,
    "backgrounds": gen_backgrounds,
}


def main():
    categories = sys.argv[1:] or list(GENERATORS)
    for name in categories:
        if name not in GENERATORS:
            sys.exit(
                "FAIL unknown category '%s' (choose from %s)"
                % (name, ", ".join(GENERATORS))
            )
    for name in categories:
        GENERATORS[name]()
    print("gen_placeholders: done (%s)" % ", ".join(categories))


if __name__ == "__main__":
    main()
