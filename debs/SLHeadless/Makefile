TARGET := iphone:clang:15.5:15.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TOOL_NAME = slheadless
slheadless_FILES = main.m
slheadless_FRAMEWORKS = Foundation UIKit
slheadless_CFLAGS = -fobjc-arc
slheadless_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
