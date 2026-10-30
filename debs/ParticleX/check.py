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
require('if (!_specifiers) {' in prefs and '_specifiers=items;' in prefs,'inherited specifiers cache')
require('PXCPreferencePath()' in prefs and 'PXC_CHANGED_CF' in prefs,'shared config + notify')
root=plistlib.loads((R/'Prefs/Resources/Root.plist').read_bytes())
info=plistlib.loads((R/'Prefs/Resources/Info.plist').read_bytes())
entry=plistlib.loads((R/'layout/Library/PreferenceLoader/Preferences/ParticleX.plist').read_bytes())['entry']
require(info['NSPrincipalClass']==entry['detail']=='PXCRootListController','entry class consistency')
require(entry['bundle']==info['CFBundleExecutable']=='ParticleXPrefs','entry bundle consistency')
for key in ('enabled','notifications','widgets','controlCenter','duration','density','clearAllButton','groupByApp','clearButtonStyle','appDeletion','effectStyle'):
 require(any(s.get('key')==key for s in root['items']),'setting '+key)
keys=[s['key'] for s in root['items'] if 'key' in s]
require(len(keys)==len(set(keys)),'no duplicated settings')
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
require('PXCDisintegrateNotificationViews(sources,urgent)' in notifications,'notification-only fine-sand entry')
require('all || [route isEqualToString:@"one-key-clear"]' in notifications,'one-key clear uses urgent handoff')
require('PXCDustMakeSandGroups' in t and 'pxcNoticeRegions' in t,'sparse notification parent groups')
require('PXCNotificationSandMakePlan' in t and 'remainingDraws' in t and 'pxcReservedDrawCount' in t,'notification buffer and draw budget both reserved')
require('instanceCount:self.pxcDrawCount' in t,'GPU children actually drawn')
require('overlay.sources=sources.count' not in t and 'densityBoost' not in t,'no undefined source variable or ineffective multiplier')
require('PXCSliderIsTracking' in slider and 'geometry.x=MAX(inset' in slider,'brightness tracking and interior emitter')
require('PXCBrightnessSlider' in slider,'brightness changes scoped away from volume')
shader=read('Sources/PXCDustShader.h')
require('uint childCount = n * n' in shader and 'particles[instanceID / childCount]' in shader,'notification shader child index')
require('PXCSandDiameter' in shader and 'p.size = float2(diameter) / u.localSize' in shader,'notification grain size bounded in points')
require('p.center = uv' in shader and 'p.releaseAt = PXCSandReleaseAt(flowUV.x, flowUV.y' in shader,'notification child position and release independent')
require('flowSize = cardSize * u.localSize' in shader and 'flowPhase = fract(u.flowPhase' in shader,'notification wind fields local to each card')
require('PXCNotificationSandKeep' in t and 'eligible>target' in t and '++rank' not in t,'all occupied notice groups covered without dropping cells')
require('else if (in.grain > 0.001)' in shader and 'smoothstep(0.60, 1.0, radius)' in shader,'notification circle bypasses tile-mask branch')
require('float2 flowDirection' in shader and 'u.flowDirection * forward' in shader,'GPU direction flow')
require('PXCWindStreamAt' in shader and 'PXCWindWarpAt' in shader and 'u.flowPhase' in shader,'coherent warp and local eddies')
require('effectStyle & 2u' in shader and 'urgent' in shader,'urgent tap handoff bit')
require('sizeof(PXUniformsGPU)==72' in t and 'PXCReleaseProgressAngle' in t,'CPU/GPU mode and direction ABI')
require('CGImageGetWidth(cg)' in t,'budget from actual bitmap dimensions')
require('notification-batch' in t,'batch renderer source evidence')
require(all(s.get('key') not in ('notificationDirection','widgetDirection','appDeletionDirection') for s in root['items']),'direction options removed')
require('PXCDustUnit(arc4random())*6.28318530718' in t,'random full-circle flow angle')
grouping=read('Sources/PXCAppGrouping.m')
require('PXCGRemovalDepth' in grouping and 'PXCGInsertionDepth' in grouping,'group lookup insert/remove scoped')
require('PXCGFind(PXCGObject(self,"notificationGroups"),request,NO)' in grouping,'removal uses exact membership')
require('setThreadIdentifier' not in grouping and 'setNotificationIdentifier' not in grouping,'raw requests untouched')
require('PXCGOrigNew' not in grouping,'no new-family ownership hook')
require('latched until SpringBoard reload' in grouping,'stable grouping policy per process')
require('for (unsigned i=0;i<sizeof(defs)/sizeof(defs[0]);i++) if (!PXCGMethod' in grouping,'all grouping ABI preflight')
require(next(s for s in root['items'] if s.get('key')=='groupByApp')['default'] is False,'grouping candidate opt-in')
appSetting=next(s for s in root['items'] if s.get('key')=='appDeletion')
require(appSetting['default'] is True,'app deletion setting')
require(info['CFBundleVersion']=='0.1.0dev11','release preferences version')
appearance=read('Sources/PXCClearAppearance.m')
density=next(s for s in root['items'] if s.get('key')=='density')
require(density['validValues']==[0,1,2,3] and density['validTitles']==['省电','标准','细腻','密集'],'four density levels in UI')
require('PXCDensityGet' in t and 'count > 16000' in t,'bounded four-level dust grid')
require('PXCDensityGet' in read('Sources/PXCSliderMath.h') and 'density.sliderScale' in slider,'density controls emitter rate and scale')
require('MIN(3, [p[@"density"] integerValue])' in settings,'four density values loaded')
style=next(s for s in root['items'] if s.get('key')=='clearButtonStyle')
require(style['validValues']==[0,1] and len(style['validTitles'])==2,'two clear button styles')
require('PXCClearGlassButton alloc' in notifications and 'PXCClearAppearancePlace(button,vc.view)' in notifications,'glass button used by native clear target')
require('constraintEqualToConstant:124' not in notifications and 'constraintEqualToConstant:44' not in notifications,'no fixed legacy clear button constraints')
require('UIVisualEffectView' in appearance and 'UIBlurEffectStyleSystemUltraThinMaterialDark' in appearance,'true frosted glass material')
require('UIAccessibilityIsReduceTransparencyEnabled' in appearance,'reduce-transparency support')
require('flashlightButton' in appearance and 'cameraButton' in appearance and '_backgroundEffectView' in appearance,'native visual circle metrics')
require('weakObjectsHashTable' in appearance and 'PXCClearQuickLayout' in appearance,'weak native view cache and late layout refresh')
appdel=read('Sources/PXCAppDeletion.m')
require('uninstallIcon:animate:completion:' in appdel and 'uninstallIcon:animate:' in appdel and 'uninstallIcon:' in appdel,'desktop uninstall overload hooks')
require('isApplicationIcon' in appdel and 'isWidgetIcon' in appdel and 'isWidgetStackIcon' in appdel,'application-only icon filter')
require('PXCDisintegrateAppView(view)' in appdel,'app deletion renderer')
require('PXCOrigUninstall3(self,cmd,icon,animate,completion)' in appdel and 'PXCOrigUninstall2(self,cmd,icon,animate)' in appdel and 'PXCOrigUninstall1(self,cmd,icon)' in appdel,'native uninstall forwarded once')
require('PXCDelUninstallDepth' in appdel and '@try' in appdel and '@finally' in appdel,'nested uninstall guard and exception isolation')
require('PXCDelMethod(cls,s,"v",defs[i].a)' in appdel and '"@bk"' in appdel,'typed uninstall ABI and Block check')
require('off-main native call' in appdel and 'no mounted visible matching icon' in appdel,'app deletion diagnostic skips')
require('PXCOrigUninstall3(self,cmd,icon,animate,completion)' in appdel,'app uninstall completion forwarded once')
require('PXCOrigUninstall2(self,cmd,icon,animate)' in appdel and 'PXCOrigUninstall1(self,cmd,icon)' in appdel,'all uninstall overloads forward')
require('PXCDelUninstallDepth' in appdel and 'PXCDelEnter' in appdel,'nested uninstall de-duplication')
require('"@bk"' in appdel,'uninstall completion Block ABI')
require('uninstallIcon' in appdel and 'PXCAppDeletionInstallHooks();' in hooks,'app deletion installer wired')
require('SBIconScrollView' in hooks and 'PXCScrollCheck' in hooks,'home page swipe drops stale dust')
require('PXCNHostWindow' in notifications and '[[s view] window]' not in notifications,'dismiss timeout never sends -view to group list')
require('(master,clear,master)' not in notifications,'native clear semantics preserved')
require('viewWillDisappear:' in notifications and 'PXCButtonActiveKey' in notifications,'clear button page lifecycle')
mode=next(s for s in root['items'] if s.get('key')=='effectStyle')
require(mode['validValues']==[0,1] and mode['validTitles']==['随风轻散','晶砂解体'],'two global effect styles')
require('PXCDustPrewarm' not in settings+t,'no boot/idle GPU preparation')
require('gPXCDustDevice=nil;gPXCDustQueue=nil;gPXCDustPipeline=nil' in t,'idle GPU references released')
require('releaseDrawables' in t and 'pxcPreview.image=nil' in t and 'pxcTexture=nil;self.pxcParticles=nil' in t,'all large per-effect resources released')
require('PXCDustReadPose' in t and 'poses appendBytes:&pose' in t and 'pose.clip' in t,'single display pose for capture and clipping')
require('PXCPerformancePolicy' in settings and 'NSProcessInfoThermalStateDidChangeNotification' in settings,'event-driven battery/thermal protection')
require('clearAllButton' in prefs and 'removeObjectsAtIndexes:hidden' in prefs,'off switch hides clear style options')
require('if (!s.enabled || !s.clearAllButton)' in notifications and 'objc_setAssociatedObject(vc,PXCButtonKey,nil' in notifications,'off switch removes the button and its UI resources')
require('PXCPerformanceGet().maxDensity' in slider and '0.9*NSEC_PER_SEC' in slider,'CC lower-power profile and trailing cleanup')
require('CGImageRetain' not in slider and 'PXCDotImage' in slider,'no permanent particle-image cache')
require('[effect pxcEndEmission]' in slider and 'Only while a live gesture exists' in slider,'stop tracking always schedules resource release')
require('slider.window.hidden' in slider,'hidden windows stop active-emission checks')
subprocess.run(['python3',str(R/'tests/icon_assets_test.py')],check=True)
subprocess.run(['python3',str(R/'tests/shader_syntax_test.py')],check=True)
subprocess.run(['python3',str(R/'tests/notification_shader_test.py')],check=True)
subprocess.run(['python3',str(R/'generate_motion_source.py'),'--check'],check=True)
for src in (R/'tests').glob('*.c') if (R/'tests').exists() else []:
 with tempfile.TemporaryDirectory() as d:
  exe=str(Path(d)/'test')
  subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-I'+str(R/'Sources'),str(src),'-lm','-o',exe],check=True)
  subprocess.run([exe],check=True)
print(f'PASS: {checks} source/plist/ABI guards; portable tests above. Not an iOS build/runtime test.')
