TARGET := iphone:clang:15.5:15.0
ARCHS = arm64e arm64
THEOS_DEVICE_IP = localhost

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ScreenCore

ScreenCore_FILES = src/impl/SCArcGestureCoordinator.m \ \
                   src/impl/SCLaunchBridge.m \
                   src/impl/SCSystemGesture.m
                   src/impl/SCApplicationTarget.m \
                   src/impl/SCFloatingContainerView.m \
                   src/impl/SCMenuViewController.m
ScreenCore_FRAMEWORKS = UIKit CoreGraphics
ScreenCore_CFLAGS = -fobjc-arc -I./src/headers

include $(THEOS_MAKE_PATH)/tweak.mk

after-stage::
	@echo "[SC] Staged $(TWEAK_NAME)"

ScreenCore_FILES += src/impl/SCPreferences.m \
                    src/impl/SCCraneIntegration.m

ScreenCore_FILES += src/impl/SCArcGestureStateMachine.m \
                    src/impl/SCMenuLayoutEngine.m

ScreenCore_FILES += src/impl/SCSceneManager.m \
                    src/impl/SCRootListController.m \
                    src/impl/SCCornerSelectionController.m

ScreenCore_FILES += src/impl/SCNotificationObserver.m \
                    src/impl/SCDebugOverlay.m

ScreenCore_FILES += src/impl/SCApplicationListController.m \
                    src/impl/SCContainerListController.m

ScreenCore_FRAMEWORKS += Preferences
ScreenCore_FILES += src/impl/SCAdvancedSettings1.m
ScreenCore_FILES += src/impl/SCAdvancedSettings2.m
ScreenCore_FILES += src/impl/SCGestureVelocityTracker.m src/impl/SCIconCache.m src/impl/SCWindowMemory.m
ScreenCore_FILES += src/impl/SCAdvancedSettings3.m
ScreenCore_FILES += src/impl/SCAdvancedSettings4.m
ScreenCore_FILES += src/impl/SCAdvancedSettings5.m
ScreenCore_FILES += src/impl/SCAdvancedSettings6.m
ScreenCore_FILES += src/impl/SCAdvancedSettings7.m
ScreenCore_FILES += src/impl/SCAdvancedSettings8.m
