#!/usr/bin/env python3
from pathlib import Path
from PIL import Image, ImageDraw

BASE, SCALE = 87, 4
im = Image.new("RGBA", (BASE * SCALE, BASE * SCALE), (0, 0, 0, 0))
d = ImageDraw.Draw(im)
def box(c): return tuple(round(v * SCALE) for v in c)

# Original status display: signal bars, active dot, battery on a dark tile.
d.rounded_rectangle(box((3, 3, 84, 84)), radius=19 * SCALE, fill="#152432")
d.rounded_rectangle(box((11, 18, 76, 69)), radius=11 * SCALE, fill="#203747")
for x, h in ((20, 11), (29, 17), (38, 23), (47, 29)):
    d.rounded_rectangle(box((x, 58 - h, x + 5, 58)), radius=2 * SCALE, fill="#77E6C2")
d.ellipse(box((56, 27, 64, 35)), fill="#FFD166")
d.rounded_rectangle(box((56, 42, 73, 53)), radius=3 * SCALE, outline="#EAF4F4", width=2 * SCALE)
d.rounded_rectangle(box((73, 45, 76, 50)), radius=1 * SCALE, fill="#EAF4F4")
d.rounded_rectangle(box((58, 44, 68, 51)), radius=1 * SCALE, fill="#77E6C2")
d.line([(20, 64), (73, 64)], fill="#6B8794", width=1 * SCALE)

master = im.resize((BASE, BASE), Image.Resampling.LANCZOS)
out = Path(__file__).resolve().parents[1] / "LocalCleanStatusPrefs/Resources"
for name, size in (("icon.png", 29), ("icon@2x.png", 58), ("icon@3x.png", 87)):
    image = master if size == BASE else master.resize((size, size), Image.Resampling.LANCZOS)
    image.save(out / name, optimize=True)
print("Wrote 29/58/87 RGBA CleanStatus icons")
