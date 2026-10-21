// TWLogController.h
// 运行日志页：把引擎/面板记下的操作日志直接显示在设置里，可一键复制。
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>

NS_ASSUME_NONNULL_BEGIN

@interface TWLogController : PSListController
@property (nonatomic, readonly) UITableView *tableView;
- (instancetype)initForContentSize:(CGSize)size;
@end

NS_ASSUME_NONNULL_END
