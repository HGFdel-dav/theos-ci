export CLANG_MODULE_CACHE_PATH := $(CURDIR)/.theos/module-cache
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ChoicyWhitelistPrefs

ChoicyWhitelistPrefs_FILES = $(wildcard *.m) $(wildcard *.x) ../Shared.m ../ChoicyPrefsMigrator.m $(wildcard ../external/AltList/*.m) $(wildcard ../external/AltList/*.x) $(wildcard ../external/litehook/src/*.c) $(wildcard ../external/ChOma/src/*.c)
ChoicyWhitelistPrefs_INSTALL_PATH = /Library/PreferenceBundles
ChoicyWhitelistPrefs_FRAMEWORKS = UIKit QuartzCore
ChoicyWhitelistPrefs_PRIVATE_FRAMEWORKS = Preferences MobileCoreServices
ChoicyWhitelistPrefs_CFLAGS += -I../external/SDKHeaders
ChoicyWhitelistPrefs_LIBRARIES += substrate
ChoicyWhitelistPrefs_CFLAGS += -I../external -fobjc-arc -Wno-deprecated-declarations -Wno-tautological-pointer-compare -I../external/ChOma/src -I../external/litehook/src -I../external/litehook/external/include

ChoicyWhitelistPrefs_LDFLAGS += -Wl,-rpath,@loader_path/.jbroot/Library/Frameworks

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/ChoicyWhitelistPrefs.plist$(ECHO_END)
