#pragma once
#import <UIKit/UIKit.h>
void PXCNotificationInstallHooks(void);
void PXCNotificationCapture(id controller,id requests,id sections,BOOL all,NSString *route);
void PXCNotificationCaptureCell(UIView *cell,NSString *route,BOOL urgent);
void PXCNotificationStage(NSString *route,BOOL urgent);
void PXCNotificationCancelStaged(void);
void PXCNotificationStageSnapshot(UIView *view,NSString *route,BOOL urgent);
void PXCEffectsClearButtonTouches(void);
@protocol PXCNotificationSnapshotSink <NSObject>
- (void)receive:(NSArray<UIView *> *)views route:(NSString *)route urgent:(BOOL)urgent;
@end
