TARGET := iphone:clang:15.5:15.5
SDKVERSION := 15.5
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
ARCHS := arm64e
else
ARCHS := arm64
endif
INSTALL_TARGET_PROCESSES := hellomemorystatusd
FINALPACKAGE := 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := HMSDiagnostic
HMSDiagnostic_FILES := Tweak.m
HMSDiagnostic_CFLAGS := -fobjc-arc -fvisibility=hidden -Wno-deprecated-declarations
HMSDiagnostic_LDFLAGS := -Wl,-x -Wl,-dead_strip

include $(THEOS_MAKE_PATH)/tweak.mk
