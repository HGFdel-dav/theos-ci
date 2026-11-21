TARGET := iphone:clang:15.5:15.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SLHeadless2
SLHeadless2_FILES = Tweak.xm
SLHeadless2_FRAMEWORKS = Foundation
SLHeadless2_LIBRARIES = substrate
SLHeadless2_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
