TARGET := iphone:clang:15.5:15.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SLDump
SLDump_FILES = Tweak.xm
SLDump_FRAMEWORKS = Foundation
SLDump_LIBRARIES = substrate
SLDump_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
