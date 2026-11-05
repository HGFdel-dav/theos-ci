DEBUG = 0
FINALPACKAGE = 1
include LocalCleanStatusBuild.mk
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = LocalCleanStatus
LocalCleanStatus_FILES = $(wildcard Hooks/*.xm Sources/*.m)
LocalCleanStatus_CFLAGS = -g -Os -fobjc-arc -I./Headers -I./Sources -fvisibility=hidden -DCLEANSTATUS_STRIP_LOGS=1 -Wall -Wextra
LocalCleanStatus_FRAMEWORKS = UIKit Foundation CoreFoundation QuartzCore
LocalCleanStatus_LIBRARIES = substrate
LocalCleanStatus_LDFLAGS = -Wl,-x -Wl,-dead_strip -Wl,-S
LocalCleanStatus_EXTRA_CFLAGS = -DLOCAL_CLEANSTATUS_ROOTHIDE_ONLY=1
# Marker consumed by the shared CI workflow; this project is roothide only and emits arm64e.
LOCAL_CLEANSTATUS_ROOTHIDE_ONLY = 1
include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += LocalCleanStatusPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
