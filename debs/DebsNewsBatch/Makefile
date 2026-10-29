TARGET = iphone:15.5:15.0
ARCHS = arm64 arm64e
SDKVERSION = 15.5

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DebsNewsBatch
DebsNewsBatch_FILES = $(wildcard DebsNewsBatch/*.m)
DebsNewsBatch_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-parameter -IDebsNewsBatch
DebsNewsBatch_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
