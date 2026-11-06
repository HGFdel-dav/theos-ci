#pragma once
#import <UIKit/UIKit.h>
#import "CCUIButtonModuleViewController.h"

@interface CCUIContentModule : NSObject
@end
@protocol CCUIContentModule <NSObject>
@required
- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController;
- (UIViewController *)backgroundViewController;
@end
