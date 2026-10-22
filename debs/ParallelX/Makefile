ARCHS = arm64 arm64e
TARGET = iphone:15.5:15.0
SDKVERSION = 15.5
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

# ---------------------------------------------------------------- SpringBoard 注入
TWEAK_NAME = CloneX
CloneX_FILES = pxclone/CXHook.m pxclone/CXCraneBridge.m pxclone/CXMenuInjector.m pxclone/CXRemember.m pxclone/CXArcWake.m pxclone/CXPrefs.m pxclone/CXLog.m
CloneX_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Ipxclone
CloneX_FRAMEWORKS = UIKit Foundation CoreGraphics

# ------------------------------------------- 设置进程注入（分身页控制器，不跨 bundle）
LIBRARY_NAME = CloneXPrefsUI
CloneXPrefsUI_FILES = Prefs/CXRootListController.m pxclone/CXCraneBridge.m pxclone/CXPrefs.m pxclone/CXLog.m
CloneXPrefsUI_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
CloneXPrefsUI_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Ipxclone -IPrefs
CloneXPrefsUI_FRAMEWORKS = UIKit Foundation CoreGraphics
CloneXPrefsUI_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/library.mk

# ------------------------------------------------ 原版 ParallelX 引擎（原样随包）
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
