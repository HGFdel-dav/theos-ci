ARCHS = arm64 arm64e
TARGET = iphone:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TIMCleanKit
TIMCleanKit_FILES = TIMCleanKit/Tweak.xm
TIMCleanKit_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
TIMCleanKit_FRAMEWORKS = UIKit Foundation CoreGraphics
TIMCleanKit_PRIVATE_FRAMEWORKS =

include $(THEOS_MAKE_PATH)/tweak.mk
