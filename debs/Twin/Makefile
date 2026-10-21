ARCHS = arm64 arm64e
TARGET = iphone:15.5:15.0
SDKVERSION = 15.5
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

# ---------------------------------------------------------------- injected dylib
# SpringBoard only: Twin never touches the Settings process and never replaces
# or conflicts with ParallelX.
TWEAK_NAME = Twin
Twin_FILES = Twin/Tweak.xm Twin/TWContainerActions.m Twin/TWSplitFeatures.m Twin/TWURLRouting.m Twin/TWPrefs.m Twin/TWCraneBridge.m Twin/TWArcGeometry.m Twin/TWArcPXBridge.m Twin/TWArcMenuView.m Twin/TWArcWindow.m Twin/TWArcCoordinator.m Twin/TWRemember.m Twin/TWProbe.m Twin/TWSceneHost.m Twin/TWContainerExport.m Twin/TWSceneInject.m Twin/TWSystemGesture.m
Twin_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -ITwin -DTWIN_STRIP_LOGS=1
Twin_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore AudioToolbox

# ------------------------------------------------------- own settings bundle
# A plain PreferenceBundle: loaded by the Preferences process itself,
# no code injection into the Settings app.
BUNDLE_NAME = TwinPrefs
TwinPrefs_FILES = Prefs/TWRootListController.m Prefs/TWSpecifiers.m Prefs/TWChoiceController.m Prefs/TWOrigArcController.m Prefs/TWLogController.m Prefs/TWArcPanelController.m Prefs/TWContainerListController.m Prefs/TWRememberListController.m Prefs/TWPXSubpageController.m Prefs/TWActionSettingsController.m Prefs/TWSplitSettingsController.m Prefs/TWAppCatalog.m Prefs/TWContainerActionsPrefs.m Prefs/TWPXPrefs.m Prefs/TWCells.m Prefs/TWStyle.m Prefs/TWIconCells.m Twin/TWPrefs.m Twin/TWCraneBridge.m Twin/TWCraneAppsController.m Twin/TWRememberAppsController.m
TwinPrefs_INSTALL_PATH = /Library/PreferenceBundles
TwinPrefs_RESOURCE_FILES = Prefs/Resources/Info.plist Prefs/Resources/icon.png Prefs/Resources/icon@2x.png Prefs/Resources/icon@3x.png
TwinPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -ITwin -IPrefs -DTWIN_STRIP_LOGS=1
TwinPrefs_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
TwinPrefs_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

# ---------------------------------------------- 原版 ParallelX 引擎（随包分发）
# 一个包 = 原版分屏引擎 + 原版面板（功能页实现）+ Twin 功能层 + Twin 面板。
# Twin 根页的「应用与快捷操作 / 半圆面板 / 手势区域 / 备份与恢复」直接打开
# 原版面板里的 PXPageHostController —— 这四页是原版 Swift 实现，重写无意义，
# 原样带进来才能保证功能一条不少；四个 plist 页（窗口/键盘/通知/系统）由
# Twin 自己渲染成紫色面板，读的正是这个 bundle 里的 plist。
# 原版二进制只有 arm64e，所以 dylib 只在 roothide 包里带上。
before-package::
	install -d "$(THEOS_STAGING_DIR)/Library/PreferenceBundles"
	cp -a vendor/ParallelXPrefs.bundle "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/"
	# 原版 ARC 面板（ScreenCore TriggerSettings）原样搬进来，Twin 引擎读它的设置
	cp -a vendor/TwinArcPrefs.bundle "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/"
ifneq ($(THEOS_PACKAGE_SCHEME),rootless)
	install -d "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries"
	install -m 755 vendor/ParallelX.dylib "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ParallelX.dylib"
	install -m 644 vendor/ParallelX.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ParallelX.plist"
	install -m 755 vendor/ParallelXCameraSupport.dylib "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ParallelXCameraSupport.dylib"
	install -m 644 vendor/ParallelXCameraSupport.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ParallelXCameraSupport.plist"
endif