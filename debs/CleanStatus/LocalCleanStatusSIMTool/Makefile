include ../LocalCleanStatusBuild.mk
include $(THEOS)/makefiles/common.mk

TOOL_NAME = LocalCleanStatusSIMTool
LocalCleanStatusSIMTool_FILES = main.m ../Cellular/LCSCellularSettings.m
LocalCleanStatusSIMTool_INSTALL_PATH = /usr/libexec/LocalCleanStatus
LocalCleanStatusSIMTool_CFLAGS = -Os -fobjc-arc -I../Cellular -fvisibility=hidden -DCLEANSTATUS_STRIP_LOGS=1 -Wall -Wextra -Werror
LocalCleanStatusSIMTool_FRAMEWORKS = Foundation CoreFoundation Security
LocalCleanStatusSIMTool_LDFLAGS = -Wl,-x -Wl,-dead_strip -Wl,-S
LocalCleanStatusSIMTool_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk
