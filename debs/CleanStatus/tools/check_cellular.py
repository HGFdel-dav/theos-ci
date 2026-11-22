#!/usr/bin/env python3
"""Local source + production-C gates. Never radios, iOS code generation or device operations."""
from pathlib import Path
import hashlib,json,plistlib,re,subprocess,sys,tempfile,platform,shutil
ROOT=Path(__file__).resolve().parents[1]
def text(n):return (ROOT/n).read_text()
count=0
def need(v,label):
    global count
    if not v:raise AssertionError(label)
    count+=1

def main():
    protected=json.loads(text('docs/BASELINE-031-CELLULAR-PROTECTED.json'))
    for n,h in protected['files'].items():need((ROOT/n).is_file() and hashlib.sha256((ROOT/n).read_bytes()).hexdigest()==h,'original changed/missing '+n)
    allowed=protected['allowed_changes']
    need('Sources/' not in ''.join(allowed),'no original behavior sources on allowlist')
    root_items=plistlib.loads((ROOT/'LocalCleanStatusPrefs/Resources/LocalCleanStatusRoot.plist').read_bytes())['items']
    old_items=protected['original_root_items'];need(root_items[:len(old_items)]==old_items and len(root_items)==len(old_items)+2,'all 0.3.1 preference rows unchanged; only two appended')
    for line in protected['original_target_lines']:need(line in text('Makefile').splitlines(),'original target input unchanged: '+line.split('=')[0])
    info=plistlib.loads((ROOT/'LocalCleanStatusPrefs/Resources/Info.plist').read_bytes())
    for key,value in protected['original_preferences_info'].items():need(info.get(key)==('0.3.4' if key in ('CFBundleVersion','CFBundleShortVersionString') else value),'old bundle metadata except version preserved: '+key)
    for n in ('Cellular/LCSCellularPanel.h','Cellular/LCSCellularPanel.m','Cellular/LCSCellularService.m','LocalCleanStatusDataSwitch/Makefile','LocalCleanStatusDataSwitch/LocalCleanStatusDataModule.m','LocalCleanStatusSIMTool/main.m','LocalCleanStatusSIMTool/Makefile','LocalCleanStatusSIMTool/entitlements.plist'):
        need((ROOT/n).is_file() and (ROOT/n).stat().st_size>50,'missing real implementation '+n)
    panel=text('Cellular/LCSCellularPanel.m');service=text('Cellular/LCSCellularService.m');hook=text('Cellular/LCSCellularHooks.m');settings=text('Cellular/LCSCellularSettings.m');module=text('LocalCleanStatusDataSwitch/LocalCleanStatusDataModule.m');helper=text('LocalCleanStatusSIMTool/main.m')
    need('buttonTapped:' not in re.sub(r'//[^\n]*','',hook).split('LCSTapContract')[0],'stock toggle not replaced')
    need(not re.search(r'LCSInstall\([^\n]*"(?:buttonTapped:|_toggleState)"',hook),'no stock toggle hook')
    need('UIControlEventTouchDown' in hook and 'cancelsTouchesInView=YES' in hook,'early tap action refused; long-press cancels touch')
    need('[LCSState(self) bind]' in hook and 'LCSOriginalLoad(self,sel)' in hook,'stock controller lifecycle forwards')
    need('LCSRequiredHookMask' in hook and 'viewDidAppear:' in hook and 'viewDidDisappear:' in hook,'only verified controller lifecycle hooks enable the feature')
    need('gestureRecognizerShouldBegin' not in hook and 'shouldReceiveTouch' not in hook and 'UIGestureRecognizerDelegate' not in hook,'crash-prone gesture delegate forwarding removed')
    need('windowPress' not in hook and 'LCSRoundBegin' not in hook and 'didMoveToWindow' not in hook,'whole-window fallback and private button hook removed')
    need('initWithTarget:self.target action:@selector(lcs_handlePress:)' in hook and 'gesture.delegate' not in hook,'standard target/action recognizer has no custom delegate')
    need('LCSHasAnyGesture(button,0)' in hook and 'LCSDirectTouch(button)' in hook and 'LCSTapContract(button)' in hook,'only verified direct-touch button without subtree recognizers attaches')
    need('gesture!=self.directPress' in hook and 'self->_handledBeginning' in hook,'unknown and repeated recognizers ignored')
    need('self.panel=panel' in hook and 'state.panel==weakPanel' in hook and 'state.panel=nil' in hook and 'UIApplicationWillResignActiveNotification' in hook,'single-panel close and foreground-loss cleanup retained')
    need('LCSPresentedSIM' in hook and 'LCSCellularSIMController' in hook,'safe stock button long press goes to SIM manager')
    need('LCSCellularDataController' in module and 'setSIMLine:' not in module,'only new data module selects data')
    need('requestExpandModule' in module and 'UIControlEventTouchUpInside' in module,'module tap expands; not a direct radio write')
    need('isSelected' in service and 'getSubscriptionContextUUIDforPlan:' in service and '"iccid"' in service,'SIM identity joins UUID to ICCID')
    need('slot-1' not in service and 'slot - 1' not in service and 'plans[' not in service,'no array-index to SIM-slot guess')
    need('LCSCellularCanWrite' in service and 'LCSCellularReadbackMatches' in service,'actual backend uses production write and readback policies')
    need('"v",2,selectArgs' in service and 'void(*)(id,SEL,id,NSError *__autoreleasing *)' in service,'data setter ABI is void')
    need('readback-verified' in service and 'accepted-not-verified' in service,'accepted is distinct from verified')
    need('waitpid(pid,&status,WNOHANG)' in service and 'LCSAlive(task)' in service and '12*NSEC_PER_SEC' in service,'bounded UI completion and nonblocking helper wait')
    need('system(' not in service+helper and '/bin/sh' not in service+helper,'no arbitrary shell execution')
    need('停用这条 SIM 线路' in panel and 'UIAlertActionStyleCancel' in panel and 'confirmed:YES' in panel,'disable confirmation and cancel path')
    need('[self.token cancel]' in panel and '[self.guardTimer invalidate]' in panel and 'viewDidDisappear:' in panel,'close/hide/OFF cancels pending UI task')
    need('LCSCellularCardBadge(kind,known,observed)' in panel and 'BOOL desired=!line.enabled' in panel and 'verified?' in panel and not re.search(r'line\.(enabled|selected|stateKnown)\s*=',panel),'badges observe model only; tapping cannot optimistically change state')
    need('LCS_CELLULAR_DATA_MODULE' in text('Cellular/LCSCellularService.h') and 'LCS_CELLULAR_DATA_MODULE' in text('Cellular/LCSCellularPanel.h'),'shared classes namespace-isolated')
    need('-DLCS_CELLULAR_DATA_MODULE=1' in text('LocalCleanStatusDataSwitch/Makefile'),'module isolation macro actually compiled')
    need('LCSEnsureMigration(error)' in settings and 'static BOOL LCSMigrationCompleted=NO' in settings,'normal writes do not rescan old roots repeatedly')
    need('NSFileModificationDate' in settings and 'isEqualToData:data' in settings,'migration freshness and saved bytes verified')
    need('events.count>=128' in settings and 'bad].location!=NSNotFound' in settings,'bounded sanitized diagnostic events')
    need('phoneNumber' not in service and 'NSLog(' not in service+helper,'no phone-number reads or raw logging')
    for p in (ROOT/'Cellular').glob('*'):
        if p.is_file():need(not re.search(r'\.jbroot-[A-Fa-f0-9]{8}-',p.read_text()),'no fixed hidden root '+p.name)
    for makefile in ['Makefile','LocalCleanStatusDataSwitch/Makefile','LocalCleanStatusSIMTool/Makefile','LocalCleanStatusPrefs/Makefile']:
        need('LCS_CELLULAR_SERVICE_TEST' not in text(makefile) and 'LCS_CELLULAR_STORAGE_TEST' not in text(makefile),'shipping Makefile cannot enable test bypasses '+makefile)
    need('argc!=3' in helper and 'LCSCellularHelperArgumentValid' in helper and 'LCSHelperUnique(latest,identity)' in helper,'helper independently rejects malformed or changed identity')
    need('MKBGetDeviceLockState' in helper and 'notify_get_state' in helper and 'LCSHelperParent()' in helper,'helper independent lock and parent checks')
    ent=plistlib.loads((ROOT/'LocalCleanStatusSIMTool/entitlements.plist').read_bytes())
    need(ent=={'platform-application':True,'com.apple.CommCenter.fine-grained':['cellular-plan','spi','preferences-write']},'precise helper entitlement scope')
    prefs=plistlib.loads((ROOT/'LocalCleanStatusPrefs/Resources/LocalCleanStatusCellular.plist').read_bytes())
    switches=[v for v in prefs['items'] if v['cell']=='PSSwitchCell'];need({v['key']:v['default'] for v in switches}=={'simManager':False,'dataSwitch':False,'diagnostics':True},'separate defaults')
    info=plistlib.loads((ROOT/'LocalCleanStatusDataSwitch/Resources/Info.plist').read_bytes());need(info['NSPrincipalClass']=='LCSDataSwitchModule' and info['CFBundleExecutable']=='LocalCleanStatusDataSwitch','module executable/principal linkage')
    need(plistlib.loads((ROOT/'LocalCleanStatusCellular.plist').read_bytes())=={'Filter':{'Bundles':['com.apple.springboard']}},'SpringBoard-only injection')
    with tempfile.TemporaryDirectory(prefix='cellular-policy-') as tmp:
        binary=str(Path(tmp)/'policy');subprocess.run(['cc','-std=c11','-O2','-Wall','-Wextra','-Werror','-I'+str(ROOT/'Cellular'),str(ROOT/'tests/cellular/policy_test.c'),'-lm','-o',binary],check=True);subprocess.run([binary],check=True)
    # The required fixed-SDK fixture parser is an explicit CI step after SDK setup.
    # Do not run it from host checks before THEOS is initialized.
    if platform.system()!='Darwin':print('SKIP Apple Foundation service_native: this is not an Apple runtime; no result claimed.')
    else:
        with tempfile.TemporaryDirectory(prefix='cellular-native-') as tmp:
            binary=str(Path(tmp)/'service_native')
            sources=[str(ROOT/'tests/cellular/service_native.m'),str(ROOT/'Cellular/LCSCellularService.m')]
            subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror','-DLCS_CELLULAR_SERVICE_TEST=1','-I'+str(ROOT/'Cellular'),*sources,'-framework','Foundation','-framework','CoreFoundation','-o',binary],check=True);subprocess.run([binary],check=True,timeout=45)
    # 0.3.2's UI script keys all files to its historical metadata. In the 0.3.4 crash candidate, UI file bytes are checked against the original 0.3.3 archive by the crash regression script; retain visual structure assertions here.
    ui_source=text('tools/test_cellular_ui.py')
    need(all(term in text('Cellular/LCSCellularPanel.m') for term in ['UIModalPresentationOverFullScreen','LCSCellularCardBadge(kind,known,observed)','self.rows=rows']),'video-aligned card and two-line rows remain in production UI')
    need('UITableView' not in text('Cellular/LCSCellularPanel.m') and 'UISwitch' not in text('Cellular/LCSCellularPanel.m'),'old settings-list UI not restored')
    subprocess.run([sys.executable,str(ROOT/'tools/test_cellular_crash_fix.py')],check=True)
    print(f'PASS cellular source/preservation checks: {count}; protected original files: {len(protected["files"])}. No UIKit runtime/radio verification.')
if __name__=='__main__':main()
