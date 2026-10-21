// TWOrigArcController.h
// 直接渲染原版 TriggerSettings.plist（触发设置页），系统原生行。
#import <Preferences/PSListController.h>

NS_ASSUME_NONNULL_BEGIN

@interface TWOrigArcController : PSListController
- (instancetype)initForContentSize:(CGSize)size;
@end

NS_ASSUME_NONNULL_END
