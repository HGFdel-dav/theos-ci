TARGET := iphone:clang:15.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CraneProbe
CraneProbe_FILES = Tweak.xm
CraneProbe_FRAMEWORKS = UIKit Foundation
CraneProbe_LIBRARIES = substrate
CraneProbe_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
