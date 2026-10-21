#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>

@interface TWSplitSettingsController : PSListController
- (instancetype)initForContentSize:(CGSize)size;
@end

@interface TWURLExcludedAppsController : PSListController
- (instancetype)initForContentSize:(CGSize)size;
@end
