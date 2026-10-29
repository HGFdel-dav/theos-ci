#!/usr/bin/env python3
"""Apply the arm64e-only activation patch to the vendor DEB payload."""
import hashlib
import pathlib
import subprocess
import sys

EXPECT = 'a3843c698e98a72abcfd2e07268eb1a4bef5ccf653d4347f1b9a470dd904abd9'
HERE = pathlib.Path(__file__).resolve().parent
WORK = pathlib.Path(__file__).resolve().parent / '.work'

CORE = [
    (0xf58e4, 'e8179f1a', '08008052', 'licensed-branch-1'),
    (0xf594c, 'e8179f1a', '08008052', 'licensed-branch-2'),
    (0xb3bf4, '9a180694', '20008052', 'force-global-license'),
]
PREFS = [
    (0x4c138, 'e8179f1a', '08008052', 'status-cell-authorized'),
    (0x4e4a4, 'e923b96d', 'ff0f5fd6', 'manual-activation-noop'),
    (0x543e4, 'ffc304d1', 'ff0f5fd6', 'auto-activation-noop-a'),
    (0x61ef8, 'fc6fbaa9', 'ff0f5fd6', 'auto-activation-noop-b'),
    (0x5a42c, 'fa67bba9', 'ff0f5fd6', 'preserve-license-on-reset'),
]
CORE_BIN = 'Library/MobileSubstrate/DynamicLibraries/CallAssist.dylib'
PREFS_BIN = 'Library/PreferenceBundles/CallAssistSetting.bundle/CallAssistSetting'
CORE_BASE = 0x338000
PREFS_BASE = 0x118000


def patch(path, base, items):
    data = bytearray(path.read_bytes())
    for va, old, new, why in items:
        off = base + va
        cur = data[off:off + 4].hex()
        if cur != old:
            sys.exit(f'{path.name} @{va:x}: expected {old}, got {cur}')
        data[off:off + 4] = bytes.fromhex(new)
        print(f'{path.name} {why} @{off:x}: {old} -> {new}')
    path.write_bytes(data)


def main():
    deb = HERE / 'orig.deb'
    digest = hashlib.sha256(deb.read_bytes()).hexdigest()
    if digest != EXPECT:
        sys.exit(f'orig.deb sha256 {digest} != {EXPECT}')
    if WORK.exists():
        subprocess.run(['rm', '-rf', str(WORK)], check=True)
    root, ctl = WORK / 'root', WORK / 'ctl'
    root.mkdir(parents=True)
    ctl.mkdir(parents=True)
    subprocess.run(['dpkg-deb', '-x', str(deb), str(root)], check=True)
    subprocess.run(['dpkg-deb', '-e', str(deb), str(ctl)], check=True)
    seed = root / 'var/mobile/Library/CallAssistActivation'
    seed.mkdir(parents=True)
    (seed / 'Activation.plist').write_text('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>ackey</key><string>dGVzdA==</string>
<key>email</key><string>unlocked@local</string>
<key>udid</key><string>00008030-0000000000000000</string>
</dict></plist>
''')
    patch(root / CORE_BIN, CORE_BASE, CORE)
    patch(root / PREFS_BIN, PREFS_BASE, PREFS)
    subprocess.run(['ldid', '-s', str(root / CORE_BIN)], check=True)
    subprocess.run(['ldid', '-s', str(root / PREFS_BIN)], check=True)
    if work_control(ctl):
        pass


def work_control(ctl):
    p = ctl / 'control'
    text = p.read_text()
    lines = []
    for line in text.splitlines():
        lines.append('Version: 2.5.1-unlock1' if line.startswith('Version:') else line)
    p.write_text('\n'.join(lines) + '\n')
    return True


if __name__ == '__main__':
    main()
