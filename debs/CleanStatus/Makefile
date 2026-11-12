DEBUG = 0
FINALPACKAGE = 1
include LocalCleanStatusBuild.mk
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = LocalCleanStatus LocalCleanStatusAnimations
LocalCleanStatus_FILES = $(wildcard Hooks/*.xm Sources/*.m) Shared/LocalCleanStatusCCDiagnostics.m Shared/LocalCleanStatusCCEnvironment.m
LocalCleanStatus_CFLAGS = -g -Os -fobjc-arc -I./Headers -I./Sources -I./Shared -fvisibility=hidden -DCLEANSTATUS_STRIP_LOGS=1 -Wall -Wextra
LocalCleanStatus_FRAMEWORKS = UIKit Foundation CoreFoundation QuartzCore
LocalCleanStatus_LIBRARIES = substrate
LocalCleanStatus_LDFLAGS = -Wl,-x -Wl,-dead_strip -Wl,-S
LocalCleanStatus_EXTRA_CFLAGS = -DLOCAL_CLEANSTATUS_ROOTHIDE_ONLY=1
# Animation code/configuration lives in its own dylib; the existing feature
# target and its preference-path implementation keep their 0.2.5 source input.
LocalCleanStatusAnimations_FILES = Animation/LocalCleanStatusAnimations.xm Animation/LocalCleanStatusAnimationPreferences.m
LocalCleanStatusAnimations_CFLAGS = -g -Os -fobjc-arc -I. -I./Headers -I./Sources -I./Animation -fvisibility=hidden -DCLEANSTATUS_STRIP_LOGS=1 -Wall -Wextra
LocalCleanStatusAnimations_CCFLAGS = -std=c++14
LocalCleanStatusAnimations_FRAMEWORKS = UIKit Foundation CoreFoundation QuartzCore CoreGraphics
LocalCleanStatusAnimations_LIBRARIES = substrate
LocalCleanStatusAnimations_LDFLAGS = -Wl,-x -Wl,-dead_strip -Wl,-S
# Marker consumed by the shared CI workflow; this project is roothide only and emits arm64e.
LOCAL_CLEANSTATUS_ROOTHIDE_ONLY = 1
include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += LocalCleanStatusPrefs LocalCleanStatusSystemActions
include $(THEOS_MAKE_PATH)/aggregate.mk
