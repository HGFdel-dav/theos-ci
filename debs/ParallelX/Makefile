ARCHS = arm64 arm64e
TARGET = iphone:15.5:15.0
SDKVERSION = 15.5
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

# ---------------------------------------------------------------- injected dylib
# SpringBoard only: 分身菜单注入 + 点击拦截。原版 ParallelX 二进制原样随包。
TWEAK_NAME = CloneX
CloneX_FILES = pxclone/CXHook.m pxclone/CXCraneBridge.m pxclone/CXMenuInjector.m pxclone/CXPrefs.m pxclone/CXLog.m
CloneX_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Ipxclone
CloneX_FRAMEWORKS = UIKit Foundation CoreGraphics

# ------------------------------------------------------- own settings bundle
BUNDLE_NAME = CloneXPrefs
CloneXPrefs_FILES = Prefs/CXRootListController.m Prefs/CXContainerPicker.m pxclone/CXCraneBridge.m pxclone/CXPrefs.m pxclone/CXLog.m
CloneXPrefs_INSTALL_PATH = /Library/PreferenceBundles
CloneXPrefs_RESOURCE_FILES = Prefs/Resources/Info.plist Prefs/Resources/icon.png Prefs/Resources/icon@2x.png Prefs/Resources/icon@3x.png
CloneXPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Ipxclone -IPrefs
CloneXPrefs_FRAMEWORKS = UIKit Foundation CoreGraphics
CloneXPrefs_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

# ------------------------------------------------ 原版 ParallelX 引擎（原样随包）
# 一个包 = 原版分屏引擎 + 原版面板 + 分身菜单注入。装它即替换原版 ParallelX。
before-package::
	install -d "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries"
	install -m 755 vendor/PX/dylib/ParallelX.dylib "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ParallelX.dylib"
	install -m 644 vendor/PX/dylib/ParallelX.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ParallelX.plist"
	install -m 755 vendor/PX/dylib/ParallelXCameraSupport.dylib "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ParallelXCameraSupport.dylib"
	install -m 644 vendor/PX/dylib/ParallelXCameraSupport.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ParallelXCameraSupport.plist"
	install -d "$(THEOS_STAGING_DIR)/Library/PreferenceBundles"
	cp -a vendor/PX/ParallelXPrefs.bundle "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/"
	install -d "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"
	install -m 644 vendor/PX/pl/ParallelX.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/ParallelX.plist"
