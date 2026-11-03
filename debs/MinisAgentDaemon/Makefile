TARGET := iphone:clang:15.5:15.0
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
ARCHS := arm64
else
ARCHS := arm64e
endif
INSTALL_TARGET_PROCESSES :=

include $(THEOS)/makefiles/common.mk

TOOL_NAME := minis-agentd
minis-agentd_FILES := src/agentd.c
minis-agentd_FRAMEWORKS := CoreFoundation
minis-agentd_CFLAGS := -Wall -Wextra -Werror
minis-agentd_CODESIGN_FLAGS := -Slayout/entitlements.plist
minis-agentd_INSTALL_PATH := /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk

# @PREFIX@ is empty for roothide and /var/jb for rootless, exactly as Apelin's
# packaging does it. The scheme also decides the control architecture, because
# Theos does not rewrite layout/DEBIAN itself.
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
PREFIX := /var/jb
ARCH_LINE := iphoneos-arm64
else
PREFIX :=
ARCH_LINE := iphoneos-arm64e
endif

before-package::
	@mkdir -p "$(THEOS_STAGING_DIR)/DEBIAN" "$(THEOS_STAGING_DIR)/Library/LaunchDaemons"
	@sed 's|@PREFIX@|$(PREFIX)|g' layout/Library/LaunchDaemons/com.niubiprass.minisagentd.plist.in \
		> "$(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.niubiprass.minisagentd.plist"
	@for s in postinst prerm postrm; do \
		sed 's|@PREFIX@|$(PREFIX)|g' layout/DEBIAN/$$s.in > "$(THEOS_STAGING_DIR)/DEBIAN/$$s"; \
		chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/$$s"; \
	done
	@sed 's|^Architecture:.*|Architecture: $(ARCH_LINE)|' layout/DEBIAN/control > "$(THEOS_STAGING_DIR)/DEBIAN/control"
	@chmod 0644 "$(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.niubiprass.minisagentd.plist"

after-minis-agentd-stage::
	@python3 tools/adhoc_sign.py "$(THEOS_STAGING_DIR)/usr/libexec/minis-agentd"
