TARGET = iphone:15.5:15.0
SDKVERSION = 15.5
FINALPACKAGE = 1
# Theos scheme (roothide/rootless) chooses installation layout; the device is A14 arm64e.
# Build each scheme package as one arm64e slice instead of shipping universal dylibs.
ARCHS = arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MiniSight
MiniSight_FILES = Tweak.xm MiniSightPet.m MiniSightResources.m MiniSightPreferences.m MiniSightRecorder.m MiniSightAI.m MiniSightChatPanel.m MiniSightLog.m MiniSightBlip.m MiniSightRuntimeConfig.m tools/chat/ChatCore.c
MiniSight_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -fvisibility=hidden -DMINISIGHT_STRIP_LOGS=1
MiniSight_LDFLAGS = -Wl,-x -Wl,-dead_strip
# UIKit/QuartzCore 需要显式链接（浮窗绘制 + CABasicAnimation）
# AVFoundation：录屏保存后要读真实时长，确认文件真的生成了
MiniSight_FRAMEWORKS = UIKit Foundation QuartzCore CoreMotion ReplayKit AVFoundation ImageIO

include $(THEOS_MAKE_PATH)/tweak.mk
