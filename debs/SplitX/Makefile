ARCHS = arm64 arm64e
TARGET = iphone:15.5:15.0
SDKVERSION = 15.5
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

# No tweak target: both engines ship as their original binaries, unchanged.

BUNDLE_NAME = SplitXPrefs
SplitXPrefs_FILES = Prefs/SplitXRootListController.m
SplitXPrefs_INSTALL_PATH = /Library/PreferenceBundles
SplitXPrefs_RESOURCE_FILES = Prefs/Resources/Info.plist Prefs/Resources/icon.png Prefs/Resources/icon@2x.png Prefs/Resources/icon@3x.png
SplitXPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -IPrefs
SplitXPrefs_FRAMEWORKS = UIKit Foundation CoreGraphics
SplitXPrefs_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/bundle.mk

before-package::
	install -d "$(THEOS_STAGING_DIR)/Library/PreferenceBundles"
	cp -a vendor/ScreenCorePrefs.bundle "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/"
	cp -a vendor/ParallelXPrefs.bundle "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/"
	install -d "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries"
	install -m 755 vendor/ScreenCore.dylib vendor/ScreenCoreCamera.dylib vendor/ScreenCoreHelper.dylib "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/"
	install -m 644 vendor/ScreenCore.plist vendor/ScreenCoreCamera.plist vendor/ScreenCoreHelper.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/"
	install -m 755 vendor/ParallelX.dylib vendor/ParallelXCameraSupport.dylib "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/"
	install -m 644 vendor/ParallelX.plist vendor/ParallelXCameraSupport.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/"
