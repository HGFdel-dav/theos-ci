#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef struct {
    BOOL enabled;
    BOOL notifications;
    BOOL widgets;
    BOOL controlCenter;
    double duration;
    NSUInteger density;
    BOOL clearAllButton;
    BOOL groupByApp;
    NSUInteger clearButtonStyle;
    BOOL appDeletion;
    NSUInteger effectStyle; // 0 Wind / 随风轻散, 1 Crystal / 晶砂解体
} PXCSettings;

#ifdef __cplusplus
extern "C" {
#endif
FOUNDATION_EXPORT PXCSettings PXCSettingsGet(void);
FOUNDATION_EXPORT void PXCSettingsStart(void);
FOUNDATION_EXPORT void PXCRemoveAllEffects(void);
FOUNDATION_EXPORT BOOL PXCDisintegrateView(UIView *view);
FOUNDATION_EXPORT BOOL PXCDisintegrateViews(NSArray<UIView *> *views);
/* urgent=YES removes the release/mesh startup pause after an explicit tap.
 * The preview is already on screen; native removal may continue underneath. */
FOUNDATION_EXPORT void PXCDustBeginSession(void);
FOUNDATION_EXPORT void PXCDustEndSession(void);
FOUNDATION_EXPORT BOOL PXCDisintegrateViewsUrgent(NSArray<UIView *> *views, BOOL urgent);
/* A separate, bounded fine-grain path: widgets/icons keep their accepted look. */
FOUNDATION_EXPORT BOOL PXCDisintegrateNotificationViews(NSArray<UIView *> *views, BOOL urgent);
FOUNDATION_EXPORT void PXCNotificationSettingsChanged(void);
FOUNDATION_EXPORT void PXCSliderObserve(UIView *slider, double value);
FOUNDATION_EXPORT void PXCSliderStop(UIView *slider);
FOUNDATION_EXPORT void PXCSliderSetTracking(UIView *slider, BOOL tracking);
FOUNDATION_EXPORT BOOL PXCSliderIsTracking(UIView *slider);
FOUNDATION_EXPORT void PXCSliderLayout(UIView *slider);
FOUNDATION_EXPORT void PXCInstallHooks(void);
FOUNDATION_EXPORT void PXCLog(NSString *message);
FOUNDATION_EXPORT void PXCDustRemoveAll(void);
#ifdef __cplusplus
}
#endif
