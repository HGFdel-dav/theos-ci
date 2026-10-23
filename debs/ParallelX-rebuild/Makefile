TARGET := iphone:clang:15.5:15.0
ARCHS = arm64e arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ParallelX

ParallelX_FILES = src/PXSceneBridge.m
ParallelX_FRAMEWORKS = UIKit
ParallelX_CFLAGS = -fobjc-arc -I./src/headers

include $(THEOS_MAKE_PATH)/tweak.mk
ParallelX_FILES += src/PXPanelEntry.m
ParallelX_FILES += src/PXHostViewController.m
ParallelX_FILES += src/PXAppRailSelection.m
