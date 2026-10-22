ARCHS = arm64 arm64e
TARGET = iphone:15.5:15.0
SDKVERSION = 15.5
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

# ---------------------------------------------------------------- injected dylib
# SpringBoard only. Hooks ParallelX's window-open funnel and settles the Crane
# container before the window is prepared. Never touches Settings process.
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
