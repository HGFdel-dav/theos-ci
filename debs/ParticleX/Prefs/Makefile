ARCHS = arm64 arm64e
TARGET = iphone:clang:15.5:15.0
include $(THEOS)/makefiles/common.mk
BUNDLE_NAME = ParticleXPrefs
ParticleXPrefs_FILES = PXCRootListController.m
ParticleXPrefs_CFLAGS = -fobjc-arc -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter
ParticleXPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
ParticleXPrefs_PRIVATE_FRAMEWORKS = Preferences
ParticleXPrefs_INSTALL_PATH = /Library/PreferenceBundles
ParticleXPrefs_RESOURCE_DIRS = Resources
include $(THEOS_MAKE_PATH)/bundle.mk
