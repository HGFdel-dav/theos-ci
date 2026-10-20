// TWChoiceController.h
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// 自绘的「多选一」子页：不依赖 Preferences 的 specifier 上下文，
// 避免 PSListItemsController 被自建时出现"只有导航栏、内容全黑"。
@interface TWChoiceController : UITableViewController
- (instancetype)initWithTitle:(nullable NSString *)title
                          key:(NSString *)key
                       titles:(NSArray<NSString *> *)titles
                       values:(NSArray *)values;
@end

NS_ASSUME_NONNULL_END
