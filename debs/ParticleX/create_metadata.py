from pathlib import Path
import plistlib, math, random
from PIL import Image,ImageDraw,ImageFilter
from icon_assets import write_rounded_icons
root=Path(__file__).resolve().parent

def text(name,s):
 p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(s)
def plist(name,obj):
 p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(plistlib.dumps(obj,sort_keys=False))
text('Makefile','''DEBUG = 0
FINALPACKAGE = 1
ARCHS = arm64 arm64e
TARGET = iphone:clang:15.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = ParticleX
ParticleX_FILES = $(wildcard Sources/*.m Sources/*.mm)
ParticleX_CFLAGS = -fobjc-arc -fvisibility=hidden -I./Sources -Wall -Wextra -Wno-unused-parameter
ParticleX_CCFLAGS = -std=c++17
ParticleX_FRAMEWORKS = UIKit Foundation CoreFoundation QuartzCore Metal MetalKit
ParticleX_LIBRARIES = substrate
ParticleX_LDFLAGS = -Wl,-x -Wl,-dead_strip
include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += Prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
''')
text('Prefs/Makefile','''ARCHS = arm64 arm64e
TARGET = iphone:clang:15.5:15.0
include $(THEOS)/makefiles/common.mk
BUNDLE_NAME = ParticleXPrefs
ParticleXPrefs_FILES = PXCRootListController.m
ParticleXPrefs_CFLAGS = -fobjc-arc -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter
ParticleXPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
ParticleXPrefs_PRIVATE_FRAMEWORKS = Preferences
ParticleXPrefs_INSTALL_PATH = /Library/PreferenceBundles
ParticleXPrefs_RESOURCE_DIRS = Resources
include $(THEOS_MAKE_PATH)/bundle.mk
''')
text('control','''Package: com.niubiprass.particlex
Name: ParticleX
Version: 0.1.0dev11
Architecture: iphoneos-arm
Description: Original-color notification and widget dust, and particles inside native Control Center sliders. iOS 15.5.
Maintainer: Niubiprass
Author: Niubiprass
Section: Tweaks
Depends: mobilesubstrate, preferenceloader, firmware (>= 15.0)
''')
plist('ParticleX.plist',{'Filter':{'Bundles':['com.apple.springboard']}})
plist('Prefs/Resources/Info.plist',{'CFBundleDevelopmentRegion':'zh_CN','CFBundleDisplayName':'ParticleX','CFBundleExecutable':'ParticleXPrefs','CFBundleIdentifier':'com.niubiprass.particlex.prefs','CFBundleInfoDictionaryVersion':'6.0','CFBundleName':'ParticleXPrefs','CFBundlePackageType':'BNDL','CFBundleShortVersionString':'0.1.0dev11','CFBundleVersion':'0.1.0dev11','NSPrincipalClass':'PXCRootListController'})
items=[]
def group(label,footer=None):
 d={'cell':'PSGroupCell','label':label}
 if footer:d['footerText']=footer
 items.append(d)
def switch(label,key,default=True):
 items.append({'cell':'PSSwitchCell','label':label,'key':key,'default':default,'defaults':'com.niubiprass.particlex','get':'readPreferenceValue:','set':'setPreferenceValue:specifier:'})
group('ParticleX · 原色粒子','Niubiprass · iOS 15.5\n只添加动画，不更改原生通知删除、亮度或音量逻辑。')
switch('启用 ParticleX','enabled')
group('动画场景')
switch('通知清除消散','notifications');switch('桌面小组件移除消散','widgets');switch('控制中心内部粒子','controlCenter');switch('删除 App 消散','appDeletion')
group('消散参数','四档密度保留原色。默认随风轻散；切换模式后，通知、小组件和 App 删除统一使用同一效果。低电量会自动降档，严重发热或内存告警时暂时停用。')
items.append({'cell':'PSLinkListCell','label':'消散风格','key':'effectStyle','default':0,'detail':'PSListItemsController','validValues':[0,1],'validTitles':['随风轻散','晶砂解体'],'defaults':'com.niubiprass.particlex','get':'readPreferenceValue:','set':'setPreferenceValue:specifier:'})
items.append({'cell':'PSSliderCell','label':'消散时长','key':'duration','default':1.15,'min':0.65,'max':1.8,'showValue':True,'isSegmented':False,'defaults':'com.niubiprass.particlex','get':'readPreferenceValue:','set':'setPreferenceValue:specifier:'})
items.append({'cell':'PSLinkListCell','label':'粒子密度','key':'density','default':1,'detail':'PSListItemsController','validValues':[0,1,2,3],'validTitles':['省电','标准','细腻','密集'],'defaults':'com.niubiprass.particlex','get':'readPreferenceValue:','set':'setPreferenceValue:specifier:'})
group('通知','「通知按 App 归类」更改后需要重新载入 SpringBoard，已有通知分组不会立即重排。')
switch('显示一键清除按钮','clearAllButton')
items.append({'cell':'PSLinkListCell','label':'清除按钮样式','key':'clearButtonStyle','default':0,'detail':'PSListItemsController','validValues':[0,1],'validTitles':['文字胶囊 · 一键清除','圆形图标 · 垃圾桶'],'defaults':'com.niubiprass.particlex','get':'readPreferenceValue:','set':'setPreferenceValue:specifier:'})
switch('通知按 App 归类','groupByApp',False)
group('诊断','只记录 Hook 安装状态和动画数量，不保存通知内容或截图。首版为测试版，编译通过不等于真机效果验收。')
items.append({'cell':'PSButtonCell','label':'查看诊断日志','action':'showDiagnostics'})
plist('Prefs/Resources/Root.plist',{'title':'ParticleX','items':items})
plist('layout/Library/PreferenceLoader/Preferences/ParticleX.plist',{'entry':{'bundle':'ParticleXPrefs','cell':'PSLinkCell','detail':'PXCRootListController','icon':'icon.png','isController':True,'label':'ParticleX'}})
random.seed(1337)
img=Image.new('RGBA',(1024,1024),(16,22,47,255));draw=ImageDraw.Draw(img)
for y in range(1024):
 f=y/1023;draw.line((0,y,1024,y),fill=(int(24-12*f),int(34-12*f),int(75-24*f),255))
for _ in range(750):
 x=random.uniform(215,870);y=random.gauss(512,110);r=random.uniform(2,9)
 a=int(255*(1-max(0,x-600)/320));col=(int(96+100*(x/1024)),int(200-65*(x/1024)),255,max(30,a))
 draw.ellipse((x-r,y-r,x+r,y+r),fill=col)
draw.rounded_rectangle((185,335,565,685),radius=80,fill=(120,210,255,255))
for _ in range(200):
 x=random.uniform(480,680);y=random.uniform(335,685);r=random.uniform(3,14)
 draw.rectangle((x,y,x+r,y+r),fill=(16,29,59,255))
img.save(root/'icon-1024.png')
write_rounded_icons(img,root)
print('Project metadata and antialiased rounded settings icons generated.')
