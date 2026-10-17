ARCHS = arm64 arm64e
TARGET = iphone:15.5:15.0
SDKVERSION = 15.5
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ParaX
ParaX_FILES = ParaX/Tweak.xm ParaX/PXPPrefs.m ParaX/PXPCraneBridge.m ParaX/PXPArcGeometry.m ParaX/PXPArcMenuView.m ParaX/PXPArcCoordinator.m ParaX/PXPRemember.m ParaX/PXPPlusUI.m ParaX/PXPCraneAppsController.m ParaX/PXPRememberAppsController.m
ParaX_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -IParaX -DPARAX_STRIP_LOGS=1
ParaX_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore AudioToolbox
ParaX_PRIVATE_FRAMEWORKS =

include $(THEOS_MAKE_PATH)/tweak.mk