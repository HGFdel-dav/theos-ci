ARCHS = arm64 arm64e
TARGET = iphone:clang:15.5:15.0
SDKVERSION = 15.5
FINALPACKAGE = 1
DEBUG = 0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ParallelXPayment
ParallelXPayment_FILES = Sources/PXPEntry.m Sources/PXPRuntime.m Sources/PXPRoute.m Sources/PXPProvenance.m Sources/PXPOwnership.m Sources/PXPNative.m Sources/PXPHost.m Sources/PXPAccounts.m
ParallelXPayment_FRAMEWORKS = UIKit Foundation QuartzCore
ParallelXPayment_CFLAGS = -fobjc-arc -Wall -Wextra -Werror=return-type -fvisibility=hidden -DPXP_ENABLE_CANDIDATE=0
ParallelXPayment_LDFLAGS = -Wl,-x -Wl,-dead_strip

# Review branch is deliberately inert. Enabling requires completing STATUS.md
# release gates and a separate approved release change; never silently override.
include $(THEOS_MAKE_PATH)/tweak.mk
