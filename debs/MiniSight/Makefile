TARGET = iphone:15.5:15.0
SDKVERSION = 15.5
FINALPACKAGE = 1
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MiniSight
MiniSight_FILES = Tweak.xm MiniSightPet.m
MiniSight_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
# UIKit/QuartzCore 需要显式链接（浮窗绘制 + CABasicAnimation）
MiniSight_FRAMEWORKS = UIKit Foundation QuartzCore ReplayKit

include $(THEOS_MAKE_PATH)/tweak.mk
