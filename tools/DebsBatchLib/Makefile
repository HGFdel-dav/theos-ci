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
# install name 修正：匹配主二进制 LC_LOAD_DYLIB 的 @executable_path/Frameworks 路径
DebsBatch_LDFLAGS = -install_name @executable_path/Frameworks/libDebsBatch.dylib

include $(THEOS_MAKE_PATH)/library.mk