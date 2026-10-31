#!/usr/bin/env python3
"""Static guard: the Settings row must keep the Reynard icon wired up.

Run: python3 tests/icon_check.py  (from the project root)
Exits non-zero on any regression, so it can run in CI before make.
"""
import plistlib
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ENTRY = ROOT / "ReynardDefaultPrefs/layout/Library/PreferenceLoader/Preferences/ReynardDefaultPrefs.plist"
RES = ROOT / "ReynardDefaultPrefs/Resources"
CCRES = ROOT / "ReynardDefaultCC/Resources"

fails = []


def check(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        fails.append(msg)


entry = plistlib.load(ENTRY.open("rb"))["entry"]
check(entry.get("icon") == "icon.png", "entry icon key == icon.png")
check(entry.get("cell") == "PSLinkCell", "entry cell is PSLinkCell")
check(entry.get("isController") is True, "entry isController")
check(entry.get("detail") == "RDRootVC", "detail matches the compiled class")
check(entry.get("bundle") == "ReynardDefaultPrefs", "bundle matches the installed bundle")

for name, size in [("icon.png", 29), ("icon@2x.png", 58), ("icon@3x.png", 87)]:
    p = RES / name
    check(p.is_file(), f"{name} exists")
    if p.is_file():
        im = Image.open(p)
        check(im.size == (size, size), f"{name} is {size}x{size} (got {im.size})")
        check(im.mode == "RGBA", f"{name} has alpha")
        check(im.convert("RGBA").getpixel((0, 0))[3] < 40, f"{name} corner is transparent")
        check(im.convert("RGBA").getpixel((size // 2, size // 2))[3] == 255, f"{name} centre is opaque")

for name, size, want in [("SettingsIcon@2x.png", (116, 116), "40f3"), ("SettingsIcon@3x.png", (174, 174), "9b1e")]:
    p = CCRES / name
    check(p.is_file() and Image.open(p).size == size, f"{name} kept {size}")
    if p.is_file():
        check(Image.open(p).mode == "RGBA", f"{name} stays the coloured image")

for name, size in [("icon@2x.png", (140, 192)), ("icon@3x.png", (210, 288))]:
    p = CCRES / name
    check(p.is_file() and Image.open(p).size == size, f"CC glyph {name} canvas {size}")
    if p.is_file():
        g = Image.open(p).convert("RGBA")
        check(g.mode == "RGBA" and Image.open(p).mode == "LA", f"CC glyph {name} stays a template (LA)")
        check(g.getpixel((0, 0))[3] == 0, f"CC glyph {name} has no coloured block (transparent corner)")
        check(any(a > 200 for a in g.split()[3].getdata()), f"CC glyph {name} is not empty")

print(f"\n{len(fails)} failure(s)")
sys.exit(1 if fails else 0)
