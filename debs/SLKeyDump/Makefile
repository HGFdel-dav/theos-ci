TARGET := iphone:clang:15.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SLKeyDump
SLKeyDump_FILES = Tweak.xm
SLKeyDump_FRAMEWORKS = Foundation UIKit
SLKeyDump_LIBRARIES = substrate
SLKeyDump_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
