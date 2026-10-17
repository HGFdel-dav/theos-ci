ARCHS = arm64
TARGET = iphone:15.5:15.0
SDKVERSION = 15.5

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = DebsBatch
DebsBatch_FILES = DebsBatch/Tweak.m DebsBatch/DBCommon.m DebsBatch/DBGitHubClient.m DebsBatch/DBUploadPanel.m
DebsBatch_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
DebsBatch_FRAMEWORKS = UIKit Foundation CoreGraphics
DebsBatch_LIBRARIES = z
DebsBatch_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk