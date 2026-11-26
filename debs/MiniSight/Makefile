TARGET = iphone:15.5:15.0
SDKVERSION = 15.5
FINALPACKAGE = 1
# Default stays source-only; LIVE builds both independent injection targets.
THEOS_PACKAGE_SCHEME ?= roothide
include ../MiniSightRhythmService/build/Flags.mk
# Theos scheme chooses installation layout AND slice: RootHide keeps arm64e
# (PAC), rootless ships plain arm64. Never label an arm64e slice as rootless.
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
ARCHS = arm64
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
ARCHS = arm64e
else
$(error MiniSight requires roothide or rootless scheme)
endif
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MiniSight
MiniSight_FILES = Tweak.xm MiniSightRhythmClient.m MiniSightPet.m MiniSightPetEffects.m MiniSightActionLibrary.m MiniSightLyrics.m MiniSightMusicMonitor.m MiniSightResources.m MiniSightPreferences.m MiniSightRecorder.m MiniSightAI.m MiniSightChatPanel.m MiniSightLog.m MiniSightBlip.m MiniSightRuntimeConfig.m tools/chat/ChatCore.c
MiniSight_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -fvisibility=hidden -DMINISIGHT_STRIP_LOGS=1 -DMINISIGHT_ENABLE_RHYTHM_TRANSPORT=$(MINISIGHT_ENABLE_RHYTHM_TRANSPORT) -DMINISIGHT_ENABLE_RHYTHM_CAPTURE=$(MINISIGHT_ENABLE_RHYTHM_CAPTURE) -DMINISIGHT_RHYTHM_LIVE_BUILD=$(MINISIGHT_RHYTHM_LIVE_BUILD)
MiniSight_LDFLAGS = -Wl,-x -Wl,-dead_strip
# UIKit/QuartzCore 需要显式链接（浮窗绘制 + CABasicAnimation）
# AVFoundation：录屏保存后要读真实时长，确认文件真的生成了
MiniSight_FRAMEWORKS = UIKit Foundation QuartzCore CoreMotion ReplayKit AVFoundation ImageIO

include $(THEOS_MAKE_PATH)/tweak.mk

# Standard Theos aggregate: the service remains an independent subproject with
# its own SDK/minimum, flags and mediaserverd filter. all/clean/internal-stage
# recurse into it; ONLY this top-level control is packaged. No DEB merging.
SUBPROJECTS = ../MiniSightRhythmService
include $(THEOS_MAKE_PATH)/aggregate.mk
