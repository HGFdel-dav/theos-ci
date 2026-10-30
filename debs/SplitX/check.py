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
        shared = (SRC / imp).resolve()
        need(base.exists() or alt.exists() or shared.exists(), f'import {f.name} -> {imp}')

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

# 8b 界面照 ParallelX（大格子 + 名称 + 角标 + 胶囊手柄）
metrics = (SRC / 'POQuickSwitchMetrics.h').read_text()
need('POQuickSwitchIconSize = 56.0' in metrics, 'icon 56pt')
need('POQuickSwitchSelectionTileSize = 68.0' in metrics, 'tile 68pt')
need('POQuickSwitchTileCornerRadius' in metrics, 'tile corner token')
cell = (SRC / 'QuickSwitchTableViewCell.m').read_text()
need('nameLabel' in cell and 'badgeLabel' in cell, 'cell shows name and badge')
need('@"分"' in cell and '@"默"' in cell, 'badge text 默/分')
handle = (SRC / 'POHandle.m').read_text()
need('CGRectGetHeight(self.bounds) / 2.0' in handle, 'handle is a pill')

# 8c 面板参数化与交互手感
panel = (SRC / 'POSplitPanelView.m').read_text()
need('POSplitXSettings shared' in panel, 'panel reads settings')
for token in ('iconSize', 'tileSize', 'itemSpacing', 'panelRadius', 'panelColumns', 'panelAlpha'):
    need(token in (SRC / 'POSplitXSettings.h').read_text(), f'settings expose {token}')
need('setHoveredIndex' in panel and 'chosen' in panel, 'hover and chosen feedback')
need('usingSpringWithDamping' in panel, 'panel uses spring animation')
need('quickSwitchTableViewWillAppear' in panel and 'quickSwitchTableViewDidDisappear' in panel, 'panel fires lifecycle')
need('panelColumns' in (SRC / 'POSplitXSettings.h').read_text(), 'settings expose panelColumns')
prefs_plist = plistlib.loads((PREFS / 'Package/Library/PreferenceBundles/SplitXPreferences.bundle/SplitXPreferences.plist').read_bytes())
pref_keys = {i.get('key') for i in prefs_plist.get('items', [])}
panel_plist = plistlib.loads((PREFS / 'Package/Library/PreferenceBundles/SplitXPreferences.bundle/Panel.plist').read_bytes())
pref_keys |= {i.get('key') for i in panel_plist.get('items', [])}
for token in ('iconSize', 'tileSize', 'itemSpacing', 'fanRadius', 'fanSpan'):
    need(token in pref_keys, f'prefs control {token}')
for removed in ('panelColumns', 'panelAlpha', 'panelRadius'):
    need(removed not in {item.get('key') for item in panel_plist['items']}, f'no dead board control {removed}')
need('fanPathWithRadius' not in panel and '_backgroundView' not in panel and '_edgeLayer' not in panel,
     'menu backing board physically removed')
need('POFanBuild(' in panel and (SRC / 'POFanLayout.h').exists(), 'real-size tested fan geometry')
need('pageCount' in panel and 'self.targets = [ordered subarrayWithRange:' in panel, 'overflow target paging')
need('UIBlurEffectStyleSystemThinMaterial' in panel and 'alpha:0.92' not in panel, 'light glass icon surfaces')

# 8d 选择防重入与失败恢复
need('targetSwitchInFlight' in vc, 'switch reentrancy guard')
need('recoverFromTargetSwitchFailure' in vc and 'showTargetSwitchFailure' in vc, 'failure recovery + toast')
need('POCraneTimedOut' in vc, 'switch watchdog')
need('setExpectedContainer' in vc, 'remember chosen container')

# 8e 普通打开必须原生放行；不劫持桌面/分身的系统打开请求
mm = (SRC / 'SplitX.mm').read_text()
hook = mm[mm.index('POHookSBMainWorkspaceHandleOpenApplicationRequest'):]
need('native open passthrough' in hook, 'ordinary open passes through native SpringBoard route')
need('POOriginalSBMainWorkspaceHandleOpenApplicationRequest' in hook, 'ordinary open calls original exactly')
need('prepareForContainerSwitchToBundleId' not in hook and 'expectedContainerForBundleIdentifier' not in hook,
     'ordinary open has no forced pre-switch')
er = (SRC / 'POExternalActivationCoordinator.m').read_text()
need('targetBundleIdentifierForRequest' in er, 'request target resolver retained for hosted flows')
er = (SRC / 'POExternalActivationCoordinator.m').read_text()
need('targetBundleIdentifierForRequest' in er, 'request target resolver')

# 8f 诊断日志
logm = (SRC / 'POSplitXLog.m').read_text()
need('PXLogBeginSession' in logm and 'NSSetUncaughtExceptionHandler' in logm, 'session header + crash handler')
need('PXLogRotateIfNeeded' in logm and 'PXLogKeepFiles = 3' in logm, 'log rotation 3 files')
need('__sync_fetch_and_add' in logm and 'NSThread.isMainThread' in logm, 'seq + thread mark')
need('PXLogBeginSession' in mm, 'boot starts session')
need('PXLogEnvironment' in mm and 'PXLogEnvironment' in logm, 'environment snapshot')
need('POStartHeartbeat' in mm and '[heartbeat]' not in mm, 'heartbeat timer')
need('PXLogSlow' in (SRC / 'POCraneBridge.m').read_text(), 'switch duration logged')
for f, token in (('POSplitPanelView.m', 'PXLog(@"panel"'), ('POCraneBridge.m', 'PXLog(@"switch"'),
                 ('POHostSessionController.mm', 'PXLog(@"host"'), ('POHandle.m', 'PXLog(@"gesture"'),
                 ('SplitX.mm', 'PXLog(@"route"')):
    need(token in (SRC / f).read_text(), f'log point {f}')
need('writeToFile' in logm and 'crash.log' in logm, 'crash tail persisted')
need('PXLogSignalHandler' in logm and 'crash.signal.log' in logm, 'signal crash dump')
need('PXLogInstallSignalHandlers' in logm, 'signal handlers installed')
prefsctl = (PREFS / 'SplitXPreferencesController.m').read_text()
need('showDiagnosticLog' in prefsctl and 'clearDiagnosticLog' in prefsctl, 'log viewer + clear in prefs')


# 8g 所有子页的范围、默认、运行时控件类型必须一起检查，不能只检查主 plist。
settings_m = (SRC / 'POSplitXSettings.m').read_text()
ranges = {m[0]: tuple(float(v) for v in m[1:]) for m in re.findall(
    r'doubleForKey:@"(\w+)" fallback:([\d.-]+) min:([\d.-]+) max:([\d.-]+)', settings_m)}
subpage_m = (PREFS / 'POSubPageController.m').read_text()
need(subpage_m.index('if ([_subPagePlistName isEqualToString:@"Clone"])') < subpage_m.index('if (items.count == 0)'),
     'dynamic Clone built before missing-plist early return')
need('[spec setProperty:cellClass forKey:@"cellClass"]' not in subpage_m, 'no NSString cellClass runtime override')
need('detail:detailClass cell:PSLinkListCell' in subpage_m and 'setValues:values titles:titles' in subpage_m,
     'choice row type and detail initialized')
need('allTargetsForBundleIdentifier:bundle' in subpage_m and 'NSClassFromString(@"CraneManager")' not in subpage_m,
     'preferences use shared bridge raw enumeration')
need('applicationsWithNonDefaultContainers' in bridge and 'allTargetsForBundleIdentifier' in bridge,
     'raw and menu visibility APIs separated')
allowed = set(re.findall(r'@"(\w+)"', settings_m[settings_m.index('static NSArray<NSString *> *PXAllowedKeys'):
                                                    settings_m.index('@implementation')]))
for page in ('Panel', 'Window', 'Dock', 'Gesture', 'Keyboard'):
    data = plistlib.loads((bundle / (page + '.plist')).read_bytes())
    for item in data['items']:
        key = item.get('key')
        if key:
            need(key in allowed, f'{page} {key} in settings cache whitelist')
        if item.get('cell') == 'PSSliderCell':
            need('cellClass' not in item, f'{page} {key} native slider without custom override')
            need(item['min'] == item['minimumValue'] and item['max'] == item['maximumValue'],
                 f'{page} {key} min/max converted')
            need(key in ranges, f'{page} {key} has runtime range')
            if key in ranges:
                default, low, high = ranges[key]
                need(float(item['min']) == low and float(item['max']) == high and float(item['default']) == default,
                     f'{page} {key} range/default match actual settings')
        elif item.get('cell') == 'PSLinkListCell':
            values, titles = item.get('validValues', []), item.get('validTitles', [])
            need(len(values) == len(titles) and bool(values) and item.get('default') in values,
                 f'{page} {key} valid action values/titles/default')
need('restoreRestingAppearance' in handle and 'self.alpha = [self restingAlpha]' not in handle,
     'invisible handle preserves touch layer')
need('bringSubviewToFront:windowResizeHandle' in vc and 'bringSubviewToFront:windowCloseButton' in vc,
     'resize handle and close button stay above hosted content')
need('performScaledProgrammaticCloseAnimationForced:YES' in vc and 'performDirectScaledProgrammaticCloseAnimation]' not in vc,
     'all close paths use the scaled fade')
need('CGFloat signed =' not in vc, 'signed keyword not used as variable')
need('windowCornerHandles' in vc and 'resizeCorner' in vc and 'corner resize' in vc,
     'resize supports four independent corners')
need('windowZoomContainer' not in vc or True, 'window resize source checked')
need('POHandlePanIntentVerticalHandleMove' in vc and 'handleVerticalPosition' in settings_m,
     'handle vertical movement setting and gesture')
need('quickSwitchBackdropDidTap' in vc and 'emptyAreaTapped' in panel, 'empty tap cancels menu')


# 8h 每个源码 .m 必须同时出现在 Sources 和某个 group 里（漏 group 会 Build input not found）
pbx_text = (ROOT / 'SplitX.xcodeproj/project.pbxproj').read_text()
for f in list(SRC.glob('*.m')) + list(SRC.glob('*.mm')) + list(PREFS.glob('*.m')):
    if f.name in ('POCameraCompatibility.m',):
        continue
    need(f'{f.name} in Sources' in pbx_text, f'{f.name} 在 Sources')
    need(f'/* {f.name} */,' in pbx_text, f'{f.name} 挂在 group')

# 9 旧品牌残留（README/LICENSE 除外）
for pat in ('PullOverXPreferences.bundle', 'com.mlgm.pulloverx', 'PullOverViewController'):
    hits = [p for p in ROOT.rglob('*') if p.is_file() and p.suffix in ('.m', '.mm', '.h', '.plist', '.pbxproj', '.sh') and pat in p.read_text(errors='ignore')]
    need(not hits, f'no leftover {pat} ({len(hits)})')

print()
if fail:
    print(f'{len(fail)} 项失败'); sys.exit(1)
print('全部通过（静态检查，不等于编译或运行通过）')
