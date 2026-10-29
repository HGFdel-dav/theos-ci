#!/usr/bin/env python3
from pathlib import Path
import plistlib,re,subprocess,tempfile
R=Path(__file__).resolve().parent
checks=0

def require(ok,msg):
 global checks
 checks+=1
 if not ok: raise SystemExit('FAIL: '+msg)

def read(p):return (R/p).read_text()
for p in R.rglob('*.plist'):
 with p.open('rb') as f:plistlib.load(f)
 require(True,'valid plist '+str(p.relative_to(R)))
f=plistlib.loads((R/'ParticleX.plist').read_bytes())
require(f=={'Filter':{'Bundles':['com.apple.springboard']}},'SpringBoard only filter')
prefs=read('Prefs/PXCRootListController.m')
require('@interface PXCRootListController : PSListController' in prefs,'real PSListController')
require('if (!_specifiers) _specifiers =' in prefs,'inherited specifiers cache')
require('PXCPreferencePath()' in prefs and 'PXC_CHANGED_CF' in prefs,'shared config + notify')
root=plistlib.loads((R/'Prefs/Resources/Root.plist').read_bytes())
info=plistlib.loads((R/'Prefs/Resources/Info.plist').read_bytes())
entry=plistlib.loads((R/'layout/Library/PreferenceLoader/Preferences/ParticleX.plist').read_bytes())['entry']
require(info['NSPrincipalClass']==entry['detail']=='PXCRootListController','entry class consistency')
require(entry['bundle']==info['CFBundleExecutable']=='ParticleXPrefs','entry bundle consistency')
for key in ('enabled','notifications','widgets','controlCenter','duration','density'):
 require(any(s.get('key')==key for s in root['items']),'setting '+key)
for s in root['items']:
 require('cellClass' not in s,'no string cellClass overrides')
 if s.get('key'):
  require(s['get']=='readPreferenceValue:' and s['set']=='setPreferenceValue:specifier:','read/write pairing')
hooks=read('Sources/PXCHooks.m')
expected=[
 ('NCNotificationListCell','_executeClearAction','v',''),
 ('NCNotificationStructuredListViewController','notificationListComponent:requestsClearingNotificationRequests:','v','@@'),
 ('NCNotificationStructuredListViewController','notificationListComponent:requestsClearingNotificationRequestsInSections:','v','@@'),
 ('NCNotificationStructuredListViewController','notificationListComponentRequestsClearingAllNotificationRequests:','v','@'),
 ('SBHIconManager','removeIcon:options:completion:','v','@Qk'),
 ('CCUIContinuousSliderView','_handleValueChangeGestureRecognizer:','v','@')]
for cls,sel,ret,args in expected:
 require(f'PXCHook("{cls}","{sel}","{ret}","{args}"' in hooks,'hook checked '+cls+' '+sel)
 h=read('reference/'+cls+'.h')
 parts=sel.rstrip(':').split(':')
 require(all(part in h for part in parts),'header evidence '+sel)
require('PXCMethod' in hooks and 'method_getArgumentType' in hooks,'runtime ABI validation')
for name in ('CellClear','Requests','Sections','All','WidgetRemove','SliderGesture'):
 require(len(re.findall(r'PXCOrig'+name+r'\(self,cmd',hooks))==1,'original exactly once '+name)
require('PXCOrigWidgetRemove(self,cmd,icon,options,completion)' in hooks,'untouched block passthrough')
require('isWidgetIcon' in hooks and 'isWidgetStackIcon' in hooks,'only widget removal')
require('removeFromSuperview",' not in hooks and '"UIView",' not in hooks,'no global UIView hook')
require('new UIWindow' not in hooks,'no floating replacement')
slider=read('Sources/PXCSliderParticles.m')
require('self.userInteractionEnabled=NO' in slider and 'self.clipsToBounds=YES' in slider,'clipped touch-through particles')
require('setBrightness' not in hooks+slider and 'setVolume' not in hooks+slider,'no brightness/volume semantics replacement')
require('CAEmitterLayer' in slider and 'pxcGeneration' in slider,'bounded native slider particles')
require('UIAccessibilityIsReduceMotionEnabled' in slider,'slider reduce motion')
for mf in ('Makefile','Prefs/Makefile'):
 t=read(mf)
 require('iphone:clang:15.5:15.0' in t,'SDK lock '+mf)
 require('arm64 arm64e' in t,'slices '+mf)
paths=read('Sources/PXCPaths.h')
require('jbroot(@"/var/mobile")' in paths,'official active RootHide path mapping')
require('.jbroot-' not in paths,'no random or hardcoded RootHide UUID')
settings=read('Sources/PXCSettings.m')
require('O_NOFOLLOW' in settings and 'S_ISREG' in settings,'bounded safe diagnostic file')
require('256*1024' in settings and '3000' in settings,'log bounded')
require('UIApplicationWillResignActiveNotification' in settings,'overlay lifecycle cleanup')
require('com.apple.springboard.lockcomplete' in settings,'lock cleanup')
require('PXCDustRemoveAll()' in settings and 'PXCSlidersRemoveAll()' in settings,'master disable tears down all effects')
renderer=R/'Sources/PXCDustRenderer.mm'
if renderer.exists():
 t=renderer.read_text()
 require('PXCDisintegrateView' in t and 'MTKView' in t,'original-color Metal renderer')
 require('UIAccessibilityIsReduceMotionEnabled' in t,'dust reduce motion')
 require('newLibraryWithSource' in t,'shader source compilation')
 require('writeToFile' not in t and 'UIImageWriteToSavedPhotosAlbum' not in t,'no snapshot persistence')
else: require(False,'renderer implementation exists')
for src in (R/'tests').glob('*.c') if (R/'tests').exists() else []:
 with tempfile.TemporaryDirectory() as d:
  exe=str(Path(d)/'test')
  subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-I'+str(R/'Sources'),str(src),'-lm','-o',exe],check=True)
  subprocess.run([exe],check=True)
print(f'PASS: {checks} source/plist/ABI guards; portable tests above. Not an iOS build/runtime test.')
