TARGET := iphone:clang:15.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ShanLianRenew
ShanLianRenew_FILES = Tweak.xm SLRenewFlow.m SLRenewPaths.m SLRenewState.m SLSigner.m SLHttp.m SLCacheDB.m SLDiag.m SLWipe.m
ShanLianRenew_FRAMEWORKS = UIKit Foundation UserNotifications CoreFoundation Security
ShanLianRenew_LIBRARIES = substrate
ShanLianRenew_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
