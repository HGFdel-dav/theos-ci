ARCHS = arm64 arm64e
TARGET = iphone:15.5:15.0
SDKVERSION = 15.5
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TIMCleanKit
TIMCleanKit_FILES = TIMCleanKit/Tweak.xm
TIMCleanKit_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -fvisibility=hidden -DTIMCK_STRIP_LOGS=1
TIMCleanKit_FRAMEWORKS = UIKit Foundation CoreGraphics
TIMCleanKit_LDFLAGS = -Wl,-x -Wl,-dead_strip
TIMCleanKit_PRIVATE_FRAMEWORKS =

include $(THEOS_MAKE_PATH)/tweak.mk
