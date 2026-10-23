TARGET := iphone:clang:15.5:15.0
ARCHS = arm64e arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ArcX

ArcX_FILES = src/AXGestureEnhancer.m
ArcX_FRAMEWORKS = UIKit
ArcX_CFLAGS = -fobjc-arc -I./src/headers

include $(THEOS_MAKE_PATH)/tweak.mk
ArcX_FILES += src/AXAnimationController.m
ArcX_FILES += src/AXTriggerZoneManager.m
ArcX_FILES += src/AXPreferences.m
