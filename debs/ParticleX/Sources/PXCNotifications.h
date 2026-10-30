#pragma once
#import <UIKit/UIKit.h>
void PXCNotificationInstallHooks(void);
void PXCNotificationCapture(id controller,id requests,id sections,BOOL all,NSString *route);
void PXCNotificationCaptureCell(UIView *cell,NSString *route,BOOL urgent);
