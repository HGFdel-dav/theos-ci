DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

# Share the SDK and deployment targets with the PreferenceBundle.
include RoutePilotBuild.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RoutePilot
RoutePilot_FILES = $(wildcard Hooks/*.xm Sources/*.m)
RoutePilot_CFLAGS = -fobjc-arc -I./Headers -I./Sources
RoutePilot_FRAMEWORKS = UIKit Foundation CoreFoundation
# Link the injection ABI required by the selected Theos/ElleKit environment.
# Confirm the library name in the active toolchain before building.
RoutePilot_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += RoutePilotPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
