include ../RoutePilotBuild.mk
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = RoutePilotPrefs
RoutePilotPrefs_FILES = $(wildcard *.m)
RoutePilotPrefs_CFLAGS = -fobjc-arc -I../Sources
RoutePilotPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
RoutePilotPrefs_PRIVATE_FRAMEWORKS = Preferences
RoutePilotPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
