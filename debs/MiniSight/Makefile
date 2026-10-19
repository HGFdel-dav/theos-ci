TARGET = iphoneos:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MiniSight
MiniSight_FILES = Tweak.xm
MiniSight_CFLAGS = -fobjc-arc
# UIKit/QuartzCore 需要显式链接（浮窗绘制 + CABasicAnimation）
MiniSight_FRAMEWORKS = UIKit Foundation QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
