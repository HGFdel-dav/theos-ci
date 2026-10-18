ARCHS = arm64 arm64e
TARGET = iphone:15.5:15.0
SDKVERSION = 15.5
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

# ---------------------------------------------------------------- injected dylib
# SpringBoard only: Twin never touches the Settings process and never replaces
# or conflicts with ParallelX.
TWEAK_NAME = Twin
Twin_FILES = Twin/Tweak.xm Twin/TWPrefs.m Twin/TWCraneBridge.m Twin/TWArcGeometry.m Twin/TWArcMenuView.m Twin/TWArcWindow.m Twin/TWArcCoordinator.m Twin/TWRemember.m Twin/TWProbe.m
Twin_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -ITwin -DTWIN_STRIP_LOGS=1
Twin_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore AudioToolbox

# ------------------------------------------------------- own settings bundle
# A plain PreferenceBundle: loaded by the Preferences process itself,
# no code injection into the Settings app.
BUNDLE_NAME = TwinPrefs
TwinPrefs_FILES = Prefs/TWRootListController.m Prefs/TWSpecifiers.m Prefs/TWArcPanelController.m Prefs/TWContainerListController.m Prefs/TWRememberListController.m Prefs/TWCells.m Prefs/TWStyle.m Twin/TWPrefs.m Twin/TWCraneAppsController.m Twin/TWRememberAppsController.m
TwinPrefs_INSTALL_PATH = /Library/PreferenceBundles
TwinPrefs_RESOURCE_FILES = Prefs/Resources/Info.plist Prefs/Resources/icon.png Prefs/Resources/icon@2x.png Prefs/Resources/icon@3x.png
TwinPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -ITwin -IPrefs -DTWIN_STRIP_LOGS=1
TwinPrefs_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
TwinPrefs_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk