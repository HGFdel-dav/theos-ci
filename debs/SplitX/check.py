#!/usr/bin/env python3
"""SplitX 本地静态自检：不构建、不安装、不联网。"""
from pathlib import Path
import plistlib, re, sys
try:
    from PIL import Image
except ImportError:
    Image = None

ROOT = Path(__file__).resolve().parent
SRC = ROOT / 'SplitX'
PREFS = ROOT / 'SplitXPreferences'
fail = []

def need(cond, msg):
    print(('PASS  ' if cond else 'FAIL  ') + msg)
    if not cond:
        fail.append(msg)

# 1 必需文件
for rel in ('POSplitTarget.h', 'POSplitTarget.m', 'POCraneBridge.h', 'POCraneBridge.m',
            'SplitX.mm', 'SplitViewController.m', 'POApplicationHelper.m',
            'Package/DEBIAN/control', 'Package/Library/MobileSubstrate/DynamicLibraries/SplitX.plist'):
    need((SRC / rel).is_file(), 'file ' + rel)

# 2 导入可解析
for f in list(SRC.glob('*.m')) + list(SRC.glob('*.mm')) + list(SRC.glob('*.h')) + list(PREFS.glob('*.m')):
    for imp in re.findall(r'#import "([^"]+)"', f.read_text(errors='ignore')):
        base = (f.parent / imp).resolve()
        alt = (PREFS / imp).resolve()
        need(base.exists() or alt.exists(), f'import {f.name} -> {imp}')

# 3 包信息
control_text = (SRC / 'Package/DEBIAN/control').read_text()
control = dict(l.split(': ', 1) for l in control_text.splitlines() if ': ' in l)
need(control.get('Package') == 'com.niubiprass.splitx', 'package id')
need(control.get('Author') == 'Niubiprass' and control.get('Maintainer') == 'Niubiprass', 'author is Niubiprass')
need(not [l for l in control_text.splitlines() if 'mlgm' in l and not l.startswith(('Conflicts','Replaces'))], 'no old package id')

# 4 过滤与设置入口
filt = plistlib.loads((SRC / 'Package/Library/MobileSubstrate/DynamicLibraries/SplitX.plist').read_bytes())
need(filt.get('Filter', {}).get('Bundles') == ['com.apple.springboard'], 'springboard only filter')
entry = plistlib.loads((PREFS / 'Package/Library/PreferenceLoader/Preferences/SplitXPreferences.plist').read_bytes())['entry']
need(entry['label'] == 'SplitX' and entry['bundle'] == 'SplitXPreferences', 'settings entry label/bundle')
plistlib.loads((PREFS / 'Package/Library/PreferenceBundles/SplitXPreferences.bundle/SplitXPreferences.plist').read_bytes())

# 5 图标：29/58/87，透明角
bundle = PREFS / 'Package/Library/PreferenceBundles/SplitXPreferences.bundle'
for name, size in (('SplitXPreferencesIcon.png', 29), ('SplitXPreferencesIcon@2x.png', 58), ('SplitXPreferencesIcon@3x.png', 87)):
    p = bundle / name
    ok = p.is_file()
    if ok and Image:
        im = Image.open(p).convert('RGBA')
        ok = im.size == (size, size) and im.getpixel((0, 0))[3] <= 8
    need(ok, f'icon {name} {size}px transparent')

# 6 构建目标与 SDK 锁定
make = (ROOT / 'build.sh').read_text()
need('SDK_VERSION="${SDK_VERSION:-15.5}"' in make, 'SDK pinned to 15.5')
need('SDKROOT="$SDK_PATH"' in make, 'build uses pinned SDK path')
need('miphoneos-version-min="$MIN_IOS"' in make, 'min iOS passed to camera build')
pbx = (ROOT / 'SplitX.xcodeproj/project.pbxproj').read_text()
need(pbx.count('IPHONEOS_DEPLOYMENT_TARGET = "15.0"') >= 2, 'deployment target 15.0')
for f in ('POSplitTarget.m', 'POCraneBridge.m'):
    need(f in pbx, f'{f} in project')

# 7 ABI 与顺序
bridge = (SRC / 'POCraneBridge.m').read_text()
need('usingBiometricsIfNeededWithSuccessHandler:' in bridge, 'biometric selector')
need('terminateApplication:forReason:andReport:withDescription:completion:' in bridge, 'termination selector')
need('kill(pid, 0)' in bridge and 'ESRCH' in bridge, 'wait for real pid exit')
need('isEqualToString:wanted' in bridge, 'read back active container')
need('if (!success)' in bridge and 'switchNow' in bridge, 'auth result gated before switch verify')
need('POSplitDefaultContainerIdentifier' in bridge, 'explicit DEFAULT target')

# 8 菜单携带目标
h = (SRC / 'QuickSwitchTableView.h').read_text()
need('POSplitTarget *target' in h, 'entry carries target')
need('POQuickSwitchBuildTargetPages' in h, 'target paging api')
vc = (SRC / 'SplitViewController.m').read_text()
need('didSelectTarget:' in vc and 'pinTarget:' in vc, 'selection handled by target')
hv = vc[vc.index('didHoverTarget:'):]
need('activeContainerForBundleIdentifier' in hv, 'hover checks container before prewarm')

# 9 旧品牌残留（README/LICENSE 除外）
for pat in ('PullOverXPreferences.bundle', 'com.mlgm.pulloverx', 'PullOverViewController'):
    hits = [p for p in ROOT.rglob('*') if p.is_file() and p.suffix in ('.m', '.mm', '.h', '.plist', '.pbxproj', '.sh') and pat in p.read_text(errors='ignore')]
    need(not hits, f'no leftover {pat} ({len(hits)})')

print()
if fail:
    print(f'{len(fail)} 项失败'); sys.exit(1)
print('全部通过（静态检查，不等于编译或运行通过）')
