#!/usr/bin/env python3
from pathlib import Path
from PIL import Image, ImageDraw

SIZE, SCALE = 120, 4
im = Image.new("RGBA", (SIZE * SCALE, SIZE * SCALE), (0, 0, 0, 0))
d = ImageDraw.Draw(im)
def box(coords): return tuple(round(v * SCALE) for v in coords)
def line(points, fill, width): d.line([(round(x*SCALE), round(y*SCALE)) for x,y in points], fill=fill, width=width*SCALE, joint="curve")

# A compact status display: signal bars, active indicator, and battery.
d.rounded_rectangle(box((4, 4, 116, 116)), radius=25*SCALE, fill="#152432")
d.rounded_rectangle(box((15, 25, 105, 95)), radius=15*SCALE, fill="#203747")
# Signal bars
for x, h in ((27, 15), (39, 23), (51, 31), (63, 39)):
    d.rounded_rectangle(box((x, 79-h, x+7, 79)), radius=3*SCALE, fill="#77E6C2")
# Active status dot
d.ellipse(box((78, 37, 88, 47)), fill="#FFD166")
# Battery outline and charge level
d.rounded_rectangle(box((77, 57, 101, 72)), radius=4*SCALE, outline="#EAF4F4", width=2*SCALE)
d.rounded_rectangle(box((101, 61, 105, 68)), radius=2*SCALE, fill="#EAF4F4")
d.rounded_rectangle(box((80, 60, 94, 69)), radius=2*SCALE, fill="#77E6C2")
# Small baseline tying the independent indicators together
line([(27, 88), (101, 88)], "#6B8794", 2)

im.resize((SIZE, SIZE), Image.Resampling.LANCZOS).save(
    Path(__file__).resolve().parents[1] / "LocalCleanStatusPrefs/Resources/CleanStatusIcon@2x.png",
    optimize=True,
)
print("Wrote original CleanStatus status-display icon")
