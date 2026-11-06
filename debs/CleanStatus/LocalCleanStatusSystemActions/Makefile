include ../LocalCleanStatusBuild.mk
BUNDLE_NAME = LocalCleanStatusSystemActions
LocalCleanStatusSystemActions_FILES = LocalCleanStatusSystemActions.m ../Sources/LocalCleanStatusPaths.m
LocalCleanStatusSystemActions_INSTALL_PATH = /Library/ControlCenter/Bundles
LocalCleanStatusSystemActions_CFLAGS = -fobjc-arc -I./Headers -I../Sources -Wall -Wextra -Werror
LocalCleanStatusSystemActions_FRAMEWORKS = UIKit Foundation
LocalCleanStatusSystemActions_PRIVATE_FRAMEWORKS = ControlCenterUIKit FrontBoardServices SpringBoardServices
include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/bundle.mk
