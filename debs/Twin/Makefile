ARCHS = arm64 arm64e
TARGET = iphone:15.5:15.0
SDKVERSION = 15.5
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Twin
Twin_FILES = Twin/Tweak.xm Twin/TWPrefs.m Twin/TWCraneBridge.m Twin/TWArcGeometry.m Twin/TWArcMenuView.m Twin/TWArcCoordinator.m
Twin_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -ITwin -DTWIN_STRIP_LOGS=1
Twin_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore AudioToolbox
Twin_PRIVATE_FRAMEWORKS =

BUNDLE_NAME = TwinSettings
TwinSettings_FILES = TwinSettings/TWRootListController.m TwinSettings/TWCraneAppsController.m Twin/TWPrefs.m
TwinSettings_INSTALL_PATH = /Library/PreferenceBundles
TwinSettings_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -ITwin
TwinSettings_FRAMEWORKS = UIKit Foundation
TwinSettings_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk