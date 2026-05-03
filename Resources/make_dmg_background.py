#!/usr/bin/env python3
"""
Generates Resources/dmg-background.png for the LiveWall installer.

Output: a 600 x 420 PNG with a clean light background, a very subtle warm
radial wash across the centre, a brand-coloured (orange → pink) gradient
arrow between the two icon slots, and the instruction
"Drag LiveWall into Applications" near the bottom. The icons themselves
are NOT drawn — Finder places them via AppleScript at the matching
positions, with their default dark labels on the light backdrop.

Re-run after editing this file:
    python3 Resources/make_dmg_background.py
"""

import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 600, 420
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "dmg-background.png")

ICON_LEFT_X, ICON_RIGHT_X, ICON_Y = 160, 440, 200


def lerp(a: int, b: int, t: float) -> int:
    return int(a + (b - a) * t)


def base_canvas() -> Image.Image:
    """Near-white canvas with a very faint vertical gradient so it has a
    little depth without looking flat."""
    img = Image.new("RGB", (W, H))
    px = img.load()
    top = (0xFC, 0xFC, 0xFD)
    bot = (0xF4, 0xF5, 0xF7)
    for y in range(H):
        t = y / (H - 1)
        c = (lerp(top[0], bot[0], t),
             lerp(top[1], bot[1], t),
             lerp(top[2], bot[2], t))
        for x in range(W):
            px[x, y] = c
    return img.convert("RGBA")


def add_warm_wash(img: Image.Image) -> Image.Image:
    """Very subtle warm radial wash centred between the two icon slots,
    just enough to add character without competing with the dark labels."""
    out = img.copy()

    wash = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    wd = ImageDraw.Draw(wash)
    cx, cy = (ICON_LEFT_X + ICON_RIGHT_X) // 2, ICON_Y - 10
    wd.ellipse([(cx - 220, cy - 160), (cx + 220, cy + 160)],
               fill=(255, 195, 175, 60))
    wash = wash.filter(ImageFilter.GaussianBlur(radius=80))
    out.alpha_composite(wash)

    return out


def draw_arrow(img: Image.Image) -> Image.Image:
    """Gradient arrow (orange → pink, matching the LiveWall icon) between
    the two icon slots."""
    out = img.copy()

    arrow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ad = ImageDraw.Draw(arrow)

    shaft_x0 = ICON_LEFT_X + 80
    shaft_x1 = ICON_RIGHT_X - 80
    start_color = (255, 107, 53)   # orange
    end_color = (232, 51, 111)     # pink

    segments = 60
    for i in range(segments):
        t0 = i / segments
        t1 = (i + 1) / segments
        sx = shaft_x0 + (shaft_x1 - shaft_x0) * t0
        ex = shaft_x0 + (shaft_x1 - shaft_x0) * t1
        c = (lerp(start_color[0], end_color[0], (t0 + t1) / 2),
             lerp(start_color[1], end_color[1], (t0 + t1) / 2),
             lerp(start_color[2], end_color[2], (t0 + t1) / 2),
             255)
        ad.line([(sx, ICON_Y), (ex, ICON_Y)], fill=c, width=3)

    head = (232, 51, 111, 255)
    head_size = 12
    ad.line(
        [(shaft_x1 - head_size, ICON_Y - head_size),
         (shaft_x1, ICON_Y),
         (shaft_x1 - head_size, ICON_Y + head_size)],
        fill=head, width=3,
    )

    out.alpha_composite(arrow)
    return out


def draw_instruction(img: Image.Image) -> Image.Image:
    """Single instruction line near the bottom in a soft dark gray."""
    out = img.copy()
    d = ImageDraw.Draw(out)
    text = "Drag LiveWall into Applications"

    font_paths = [
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/HelveticaNeue.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]
    font = None
    for p in font_paths:
        if os.path.exists(p):
            try:
                font = ImageFont.truetype(p, 16)
                break
            except OSError:
                pass
    if font is None:
        font = ImageFont.load_default()

    bbox = d.textbbox((0, 0), text, font=font)
    tw = bbox[2] - bbox[0]
    tx = (W - tw) // 2
    ty = 372
    d.text((tx, ty), text, font=font, fill=(60, 60, 65, 200))
    return out


def main() -> None:
    img = base_canvas()
    img = add_warm_wash(img)
    img = draw_arrow(img)
    img = draw_instruction(img)
    img.convert("RGB").save(OUT, "PNG", optimize=True)
    print(f"wrote {OUT} ({W}x{H})")


if __name__ == "__main__":
    main()
