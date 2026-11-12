include ../LocalCleanStatusBuild.mk
include $(THEOS)/makefiles/common.mk
BUNDLE_NAME = LocalCleanStatusPrefs
LocalCleanStatusPrefs_FILES = $(wildcard *.m) ../Sources/LocalCleanStatusPaths.m ../Animation/LocalCleanStatusAnimationPreferences.m
LocalCleanStatusPrefs_CFLAGS = -g -Os -fobjc-arc -I../Sources -fvisibility=hidden -DCLEANSTATUS_STRIP_LOGS=1 -Wall -Wextra
LocalCleanStatusPrefs_RESOURCE_FILES = Resources/icon.png Resources/icon@2x.png Resources/icon@3x.png
LocalCleanStatusPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
LocalCleanStatusPrefs_PRIVATE_FRAMEWORKS = Preferences
LocalCleanStatusPrefs_INSTALL_PATH = /Library/PreferenceBundles
LocalCleanStatusPrefs_LDFLAGS = -Wl,-x -Wl,-dead_strip -Wl,-S
include $(THEOS_MAKE_PATH)/bundle.mk
