include ../LocalCleanStatusBuild.mk
BUNDLE_NAME = LocalCleanStatusSystemActions
LocalCleanStatusSystemActions_FILES = LocalCleanStatusSystemActions.m ../Shared/LocalCleanStatusCCEnvironment.m ../Shared/LocalCleanStatusCCDiagnostics.m ../Sources/LocalCleanStatusPaths.m
LocalCleanStatusSystemActions_RESOURCE_FILES = Resources/SettingsIcon.png Resources/SettingsIcon@2x.png Resources/SettingsIcon@3x.png
LocalCleanStatusSystemActions_INSTALL_PATH = /Library/ControlCenter/Bundles
LocalCleanStatusSystemActions_CFLAGS = -g -Os -fobjc-arc -I./Headers -I../Sources -I../Shared -fvisibility=hidden -DCLEANSTATUS_STRIP_LOGS=1 -Wall -Wextra -Werror
LocalCleanStatusSystemActions_FRAMEWORKS = UIKit Foundation CoreFoundation
LocalCleanStatusSystemActions_PRIVATE_FRAMEWORKS = ControlCenterUIKit FrontBoardServices SpringBoardServices
include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/bundle.mk
