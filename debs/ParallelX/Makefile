# Apple clang already implements the arm64e ABI, including return-address PAC.
# Generic pac-ret plus the arm64e ABI produced two PAC instructions in clone0.4.
# Do not restore Linux linker/header workarounds here.
ifneq ($(shell uname -s),Darwin)
$(error Build on a GitHub macOS runner; iSH/Linux builds are not supported)
endif

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
ARCHS = arm64
else
ARCHS = arm64e
endif
PACKAGE_FORMAT = deb

TARGET = iphone:15.5:15.0
SDKVERSION = 15.5
FINALPACKAGE = 1

# Generate scheme-specific control and the in-page Root.plist before Theos
# parses package metadata. This keeps rootless/roothide filenames correct.
$(shell ./tools/generate_maintainer_scripts.sh "$(THEOS_PACKAGE_SCHEME)" >/dev/null 2>&1)
$(shell python3 ./tools/make_parallelx_root_overlay.py >/dev/null 2>&1)

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ParallelXClone
ParallelXClone_FILES = Tweak.xm \
	Common/PXCloneCrane.m \
	Common/PXCloneMenu.m \
	Common/PXCloneLaunch.m \
	Common/PXCloneURLRouter.m \
	Common/PXClonePaths.m \
	Common/PXCloneProbe.m \
	Common/PXClonePolicy.m \
	Common/PXClonePrefs.m \
	Common/PXCloneTrace.m \
	Common/PXCloneRuntime.m
ParallelXClone_CFLAGS = -fobjc-arc -DPXCLONE_PROBE_OFF -I$(THEOS_PROJECT_DIR) -Wno-unused-parameter -fvisibility=hidden -DPXCLONE_STRIP_LOGS=1
ParallelXClone_LDFLAGS = -Wl,-x -Wl,-dead_strip
ParallelXClone_FRAMEWORKS = Foundation UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

LIBRARY_NAME = ParallelXPrefsUI
ParallelXPrefsUI_FILES = Prefs/PXCloneAccountsController.m \
	Common/PXCloneCrane.m \
	Common/PXClonePaths.m \
	Common/PXCloneProbe.m \
	Common/PXClonePrefs.m \
	Common/PXCloneTrace.m \
	Common/PXCloneRuntime.m
ParallelXPrefsUI_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR) -Wno-unused-parameter -fvisibility=hidden
ParallelXPrefsUI_LDFLAGS = -Wl,-x -Wl,-dead_strip
ParallelXPrefsUI_FRAMEWORKS = Foundation UIKit
ParallelXPrefsUI_PRIVATE_FRAMEWORKS = Preferences
ParallelXPrefsUI_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk

# Reject corrupted arm64e return-address signing in the actual staged images.
# This runs on the CI runner after both injected dylibs are staged.
PX_EXPECTED_ARCH = $(if $(filter rootless,$(THEOS_PACKAGE_SCHEME)),arm64,arm64e)
after-stage::
	@python3 tools/check_pac.py --expect-arch $(PX_EXPECTED_ARCH) \
		"$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ParallelXClone.dylib" \
		"$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ParallelXPrefsUI.dylib"

# One merged ParallelX package: preserve the alpha391 vendor payload, then
# overlay only the original Root.plist with the new in-page account row.
before-package::
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries"
	@cp vendor/alpha391/Library/MobileSubstrate/DynamicLibraries/ParallelX.dylib "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ParallelX.dylib"
	@chmod 755 "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ParallelX.dylib"
	@cp vendor/alpha391/Library/MobileSubstrate/DynamicLibraries/ParallelX.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ParallelX.plist"
	@chmod 644 "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ParallelX.plist"
	@cp vendor/alpha391/Library/MobileSubstrate/DynamicLibraries/ParallelXCameraSupport.dylib "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ParallelXCameraSupport.dylib"
	@chmod 755 "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ParallelXCameraSupport.dylib"
	@cp vendor/alpha391/Library/MobileSubstrate/DynamicLibraries/ParallelXCameraSupport.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ParallelXCameraSupport.plist"
	@chmod 644 "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ParallelXCameraSupport.plist"
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/ParallelXPrefs.bundle"
	@cp -a vendor/alpha391/Library/PreferenceBundles/ParallelXPrefs.bundle/. "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/ParallelXPrefs.bundle/"
	@cp layout/Library/PreferenceBundles/ParallelXPrefs.bundle/Root.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/ParallelXPrefs.bundle/Root.plist"
	@chmod 644 "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/ParallelXPrefs.bundle/Root.plist"
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"
	@cp vendor/alpha391/Library/PreferenceLoader/Preferences/ParallelX.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/ParallelX.plist"
	@chmod 644 "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/ParallelX.plist"
	@cp ParallelXPrefsUI.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ParallelXPrefsUI.plist"
	@chmod 644 "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/ParallelXPrefsUI.plist"

before-all::
	@./tools/generate_maintainer_scripts.sh "$(THEOS_PACKAGE_SCHEME)"
	@python3 ./tools/make_parallelx_root_overlay.py
