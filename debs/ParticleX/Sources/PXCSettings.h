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
} PXCSettings;

#ifdef __cplusplus
extern "C" {
#endif
FOUNDATION_EXPORT PXCSettings PXCSettingsGet(void);
FOUNDATION_EXPORT void PXCSettingsStart(void);
FOUNDATION_EXPORT void PXCRemoveAllEffects(void);
FOUNDATION_EXPORT BOOL PXCDisintegrateView(UIView *view);
FOUNDATION_EXPORT void PXCSliderObserve(UIView *slider, double value);
FOUNDATION_EXPORT void PXCSliderStop(UIView *slider);
FOUNDATION_EXPORT void PXCInstallHooks(void);
FOUNDATION_EXPORT void PXCLog(NSString *message);
FOUNDATION_EXPORT void PXCDustPrewarm(void);
FOUNDATION_EXPORT void PXCDustRemoveAll(void);
#ifdef __cplusplus
}
#endif
