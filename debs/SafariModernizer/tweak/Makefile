# Unofficial iOS 15.5 / RootHide compatibility rebuild, based on upstream 1.0.1.
# Compile natively with roothide/theos; never copy the rootless binary into a DEB.
override TARGET := iphone:clang:15.5:15.0
override ARCHS := arm64e
THEOS_PACKAGE_SCHEME ?= roothide
ifneq ($(THEOS_PACKAGE_SCHEME),roothide)
$(error This compatibility rebuild only supports THEOS_PACKAGE_SCHEME=roothide)
endif
FINALPACKAGE = 1
INSTALL_TARGET_PROCESSES = MobileSafari SafariViewService

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SafariModernizer
SafariModernizer_FILES = Tweak.x
SafariModernizer_CFLAGS = -fobjc-arc -fvisibility=hidden -DSM_TARGET_ROOTHIDE=1
SafariModernizer_LDFLAGS = -Wl,-x -Wl,-dead_strip -Wl,-fixup_chains
SafariModernizer_FRAMEWORKS = Foundation UIKit WebKit

include $(THEOS_MAKE_PATH)/tweak.mk
