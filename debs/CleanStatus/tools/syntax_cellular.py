#!/usr/bin/env python3
"""Parse new Objective-C using the fixed iOS15.5 SDK; NO -c, link or code generation."""
from pathlib import Path
import json,subprocess,sys
ROOT=Path(__file__).resolve().parents[1]
SDK=Path('/opt/theos/sdks/iPhoneOS15.5.sdk')
if not SDK.is_dir():raise SystemExit('SKIP syntax-only: local fixed SDK unavailable; no result claimed.')
base=['clang','-fsyntax-only','-fobjc-arc','-fblocks','-target','arm64e-apple-ios15.5','-isysroot',str(SDK),'-F/opt/theos/vendor/lib','-I/opt/theos/include','-I/opt/theos/vendor/include','-I'+str(ROOT/'Cellular'),'-I'+str(ROOT/'Sources'),'-Wall','-Wextra','-Werror','-DCLEANSTATUS_STRIP_LOGS=1']
files=['Cellular/LCSCellularSettings.m','Cellular/LCSCellularService.m','Cellular/LCSCellularPanel.m','Cellular/LCSCellularHooks.m','LocalCleanStatusDataSwitch/LocalCleanStatusDataModule.m','LocalCleanStatusPrefs/LocalCleanStatusCellularController.m','LocalCleanStatusSIMTool/main.m','tests/cellular/storage_native.m','tests/cellular/service_native.m','Animation/LocalCleanStatusAnimationPreferences.m','tests/cellular/path_reuse_native.m']
cases=[(f,[]) for f in files]+[(f,['-DLCS_CELLULAR_DATA_MODULE=1']) for f in ['Cellular/LCSCellularService.m','Cellular/LCSCellularPanel.m','LocalCleanStatusDataSwitch/LocalCleanStatusDataModule.m','Cellular/LCSCellularSettings.m','Animation/LocalCleanStatusAnimationPreferences.m']]+[('Cellular/LCSCellularService.m',['-DLCS_CELLULAR_SERVICE_TEST=1']),('Cellular/LCSCellularSettings.m',['-DLCS_CELLULAR_STORAGE_TEST=1'])]
results=[]
for name,flags in cases:
    process=subprocess.run(base+flags+[str(ROOT/name)],text=True,capture_output=True)
    results.append({'file':name,'flags':flags,'exit':process.returncode,'diagnostics':process.stdout+process.stderr})
    print(('PASS' if process.returncode==0 else 'FAIL')+' syntax-only '+name+' '+' '.join(flags))
    if process.stdout or process.stderr:print(process.stdout+process.stderr)
fixture=subprocess.run([sys.executable,str(ROOT/'tools/run_cellular_storage_native.py'),'--syntax-only'],text=True,capture_output=True)
print(fixture.stdout+fixture.stderr,end='')
report={'sdk':'15.5','target':'arm64e-apple-ios15.5','mode':'fsyntax-only: no machine code, no link, no native execution','results':results,'fixture_compile_units':{'count':4,'exit':fixture.returncode,'diagnostics':fixture.stdout+fixture.stderr}}
if len(sys.argv)>1:Path(sys.argv[1]).write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
if any(r['exit'] for r in results) or fixture.returncode:raise SystemExit(1)
print('PASS '+str(len(results))+' production/conditional parse cases + 4 native-fixture compile units; no machine code/link/native execution; not macOS CI or device validation.')
