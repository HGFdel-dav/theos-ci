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
for key in ('enabled','notifications','widgets','controlCenter','duration','density','notificationDirection','widgetDirection','clearAllButton','groupByApp'):
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
 ('CCUIContinuousSliderView','_handleValueChangeGestureRecognizer:','v','@'),
 ('CCUIContinuousSliderView','_beginTrackingWithGestureRecognizer:','v','@'),
 ('CCUIContinuousSliderView','_continueTrackingWithGestureRecognizer:','v','@'),
 ('CCUIContinuousSliderView','_endTrackingWithGestureRecognizer:','v','@'),
 ('CCUIBaseSliderView','setValue:','v','f'),
 ('CCUIContinuousSliderView','layoutSubviews','v','')]
for cls,sel,ret,args in expected:
 require(f'PXCHook("{cls}","{sel}","{ret}","{args}"' in hooks,'hook checked '+cls+' '+sel)
 h=read('reference/'+cls+'.h')
 parts=sel.rstrip(':').split(':')
 require(all(part in h for part in parts) or (sel=='setValue:' and '@property(nonatomic) float value;' in h),'header evidence '+sel)
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
notifications=read('Sources/PXCNotifications.m')
require('group-dismiss-cell' in notifications and 'group-clear-request' in notifications,'pre-removal group routes')
require('notificationIdentifier' in notifications and 'sectionIdentifier' in notifications,'stable request matching')
require('one-key-clear' in notifications and 'clearAllNotificationRequests' in notifications,'native clear sections')
require('(master,clear,master)' not in notifications,'never recursive master clear delegate')
require('visibleViews' in notifications and 'contentViewController' in notifications,'virtualized notification platter source')
require('PXCDisintegrateViews' in notifications,'one texture notification batch')
require('PXCSliderIsTracking' in slider and 'geometry.x=MAX(inset' in slider,'brightness tracking and interior emitter')
require('PXCBrightnessSlider' in slider,'brightness changes scoped away from volume')
shader=read('Sources/PXCDustShader.h')
require('float2 flowDirection' in shader and 'u.flowDirection * forward' in shader,'GPU direction flow')
require('sizeof(PXUniformsGPU)==64' in t and 'PXCReleaseProgress(direction' in t,'CPU/GPU direction ABI')
require('CGImageGetWidth(cg)' in t,'budget from actual bitmap dimensions')
require('notification-batch' in t,'batch renderer source evidence')
for key in ('notificationDirection','widgetDirection'):
 spec=next(s for s in root['items'] if s.get('key')==key)
 require(spec['validValues']==[0,1,2,3,4] and len(spec['validTitles'])==5,'all direction options '+key)
grouping=read('Sources/PXCAppGrouping.m')
require('PXCGRemovalDepth' in grouping and 'PXCGInsertionDepth' in grouping,'group lookup insert/remove scoped')
require('PXCGFind(PXCGObject(self,"notificationGroups"),request,NO)' in grouping,'removal uses exact membership')
require('setThreadIdentifier' not in grouping and 'setNotificationIdentifier' not in grouping,'raw requests untouched')
require('PXCGOrigNew' not in grouping,'no new-family ownership hook')
require('latched until SpringBoard reload' in grouping,'stable grouping policy per process')
require('for (unsigned i=0;i<sizeof(defs)/sizeof(defs[0]);i++) if (!PXCGMethod' in grouping,'all grouping ABI preflight')
require(next(s for s in root['items'] if s.get('key')=='groupByApp')['default'] is False,'grouping candidate opt-in')
for src in (R/'tests').glob('*.c') if (R/'tests').exists() else []:
 with tempfile.TemporaryDirectory() as d:
  exe=str(Path(d)/'test')
  subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-I'+str(R/'Sources'),str(src),'-lm','-o',exe],check=True)
  subprocess.run([exe],check=True)
print(f'PASS: {checks} source/plist/ABI guards; portable tests above. Not an iOS build/runtime test.')
