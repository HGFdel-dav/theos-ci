#import <Preferences/PSListController.h>
#import <UIKit/UIKit.h>

// 根页接线使用 TWActionSettingsController；其余都是真正的 Preferences 子页。
@interface TWActionSettingsController : PSListController
- (instancetype)initForContentSize:(CGSize)size;
@end
@interface TWSystemToolsController : TWActionSettingsController @end
@interface TWURLShortcutsController : TWActionSettingsController @end
@interface TWWorkflowActionsController : TWActionSettingsController @end
@interface TWApplicationActionsController : TWActionSettingsController @end
@interface TWCustomActionsController : TWActionSettingsController @end
