include ../LocalCleanStatusBuild.mk
include $(THEOS)/makefiles/common.mk
BUNDLE_NAME = LocalCleanStatusDataSwitch
LocalCleanStatusDataSwitch_FILES = LocalCleanStatusDataModule.m ../Cellular/LCSCellularPanel.m ../Cellular/LCSCellularService.m ../Cellular/LCSCellularSettings.m ../Animation/LocalCleanStatusAnimationPreferences.m
LocalCleanStatusDataSwitch_CFLAGS = -g -Os -fobjc-arc -I../Cellular -I../Sources -DLCS_CELLULAR_DATA_MODULE=1 -fvisibility=hidden -DCLEANSTATUS_STRIP_LOGS=1 -Wall -Wextra -Werror
LocalCleanStatusDataSwitch_FRAMEWORKS = UIKit Foundation CoreFoundation CoreGraphics QuartzCore CoreTelephony
LocalCleanStatusDataSwitch_RESOURCE_FILES = Resources/Info.plist Resources/DataSwitch.png Resources/DataSwitch@2x.png Resources/DataSwitch@3x.png Resources/SettingsIcon.png Resources/SettingsIcon@2x.png Resources/SettingsIcon@3x.png
LocalCleanStatusDataSwitch_INSTALL_PATH = /Library/ControlCenter/Bundles
LocalCleanStatusDataSwitch_LDFLAGS = -Wl,-x -Wl,-dead_strip -Wl,-S
include $(THEOS_MAKE_PATH)/bundle.mk
