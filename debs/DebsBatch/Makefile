ARCHS = arm64 arm64e
TARGET = iphone:15.5:15.0
SDKVERSION = 15.5
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DebsBatch
DebsBatch_FILES = DebsBatch/Tweak.xm DebsBatch/DBCommon.m DebsBatch/DBGitHubClient.m DebsBatch/DBUploadPanel.m
DebsBatch_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
DebsBatch_FRAMEWORKS = UIKit Foundation CoreGraphics
DebsBatch_LIBRARIES = z
DebsBatch_PRIVATE_FRAMEWORKS =

include $(THEOS_MAKE_PATH)/tweak.mk