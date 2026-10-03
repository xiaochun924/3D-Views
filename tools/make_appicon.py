"""Draws the app icon for Views.

The mark is a wireframe cube seen in slight perspective, drawn in the same blue
the app uses for selection and measurement — a viewer that measures solids, in
one glyph. Regenerate with:

    python tools/make_appicon.py
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
OUT = Path(__file__).resolve().parent.parent / "Views" / "Assets.xcassets" / "AppIcon.appiconset"

# The app's accent blue, top-lit so the tile reads as a solid object rather than
# a flat swatch. background: dark graphite so a white-ish wireframe carries.
BG_TOP = (32, 44, 66)
BG_BOTTOM = (12, 16, 26)
EDGE = (90, 168, 255)
EDGE_BRIGHT = (170, 214, 255)

# A wireframe cube: two squares (back and front) offset by the projection of the
# depth axis, with the four connecting edges. All eight corners are projected
# from 3D so the perspective is consistent rather than hand-placed.
CUBE = 1.0
DEPTH = 0.62
FOCAL = 5.0


def project(x: float, y: float, z: float) -> tuple[float, float]:
    """Weak perspective projection of a point on the unit cube."""
    scale = FOCAL / (FOCAL + z)
    return x * scale, y * scale


def cube_corners() -> list[tuple[float, float]]:
    h = CUBE / 2
    corners = []
    for z in (-h, h):
        for sx, sy in ((-h, -h), (h, -h), (h, h), (-h, h)):
            # Slight yaw so the front face is not dead-on: a straight-on cube
            # loses the depth cue that makes it read as 3D at icon sizes.
            yaw = math.radians(18)
            rx = sx * math.cos(yaw) - z * math.sin(yaw)
            rz = sx * math.sin(yaw) + z * math.cos(yaw)
            corners.append(project(rx, sy, rz))
    return corners


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)

    # Vertical gradient background.
    img = Image.new("RGB", (SIZE, SIZE), BG_BOTTOM)
    draw = ImageDraw.Draw(img)
    for y in range(SIZE):
        t = y / (SIZE - 1)
        r = round(BG_TOP[0] + (BG_BOTTOM[0] - BG_TOP[0]) * t)
        g = round(BG_TOP[1] + (BG_BOTTOM[1] - BG_TOP[1]) * t)
        b = round(BG_TOP[2] + (BG_BOTTOM[2] - BG_TOP[2]) * t)
        draw.line([(0, y), (SIZE, y)], fill=(r, g, b))

    # Soft radial glow behind the cube so the wireframe sits in light.
    glow = Image.new("L", (SIZE, SIZE), 0)
    gdraw = ImageDraw.Draw(glow)
    for i in range(64, 0, -1):
        radius = SIZE * 0.5 * i / 64
        gdraw.ellipse(
            [SIZE / 2 - radius, SIZE / 2 - radius, SIZE / 2 + radius, SIZE / 2 + radius],
            fill=int(9 * (64 - i) / 64 * 8),
        )
    img = Image.composite(Image.new("RGB", (SIZE, SIZE), (60, 120, 200)), img, glow)
    draw = ImageDraw.Draw(img)

    # Fit the projected cube into the tile with margin.
    raw = cube_corners()
    xs = [p[0] for p in raw]
    ys = [p[1] for p in raw]
    span = max(max(xs) - min(xs), max(ys) - min(ys))
    target = SIZE * 0.62
    k = target / span
    cx = (max(xs) + min(xs)) / 2
    cy = (max(ys) + min(ys)) / 2
    pts = [(SIZE / 2 + (x - cx) * k, SIZE / 2 + (y - cy) * k) for x, y in raw]

    back, front = pts[:4], pts[4:]

    def polygon(points, width, color):
        draw.line(list(points) + [points[0]], fill=color, width=width, joint="curve")

    # Back face dimmer, front face bright: the depth ordering reads instantly.
    polygon(back, 16, (56, 104, 168))
    for i in range(4):
        draw.line([back[i], front[i]], fill=(70, 132, 208), width=14)
    polygon(front, 22, EDGE_BRIGHT)

    # Corner nodes.
    for x, y in front:
        draw.ellipse([x - 13, y - 13, x + 13, y + 13], fill=EDGE_BRIGHT)
    for x, y in back:
        draw.ellipse([x - 9, y - 9, x + 9, y + 9], fill=EDGE)

    # A dimension line under the cube: the "measure" half of the app.
    y0 = SIZE * 0.845
    x0, x1 = SIZE * 0.26, SIZE * 0.74
    draw.line([(x0, y0), (x1, y0)], fill=EDGE_BRIGHT, width=20)
    for x, direction in ((x0, 1), (x1, -1)):
        draw.line([(x, y0 - 30), (x, y0 + 30)], fill=EDGE_BRIGHT, width=20)
    draw.polygon(
        [(x0 + 26 * direction, y0 - 22), (x0 + 26 * direction, y0 + 22), (x0 - 12 * direction, y0)],
        fill=EDGE_BRIGHT,
    )
    draw.polygon(
        [(x1 + 26 * -direction, y0 - 22), (x1 + 26 * -direction, y0 + 22), (x1 - 12 * -direction, y0)],
        fill=EDGE_BRIGHT,
    )

    img.save(OUT / "AppIcon-1024.png")
    print(f"wrote {OUT / 'AppIcon-1024.png'}")


if __name__ == "__main__":
    main()
