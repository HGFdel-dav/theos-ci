TARGET := iphone:clang:15.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SLFlutter
SLFlutter_FILES = Tweak.xm
SLFlutter_FRAMEWORKS = Foundation
SLFlutter_LIBRARIES = substrate
SLFlutter_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
