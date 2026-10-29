DEBUG = 0
FINALPACKAGE = 1
ARCHS = arm64 arm64e
TARGET = iphone:clang:15.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = ParticleX
ParticleX_FILES = $(wildcard Sources/*.m Sources/*.mm)
ParticleX_CFLAGS = -fobjc-arc -fvisibility=hidden -I./Sources -Wall -Wextra -Wno-unused-parameter
ParticleX_CCFLAGS = -std=c++17
ParticleX_FRAMEWORKS = UIKit Foundation CoreFoundation QuartzCore Metal MetalKit
ParticleX_LIBRARIES = substrate
ParticleX_LDFLAGS = -Wl,-x -Wl,-dead_strip
include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += Prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
