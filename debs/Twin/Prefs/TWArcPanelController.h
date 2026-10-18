// TWArcPanelController.h — 「Arc 面板与手势」子页。
// 真正编译的 PSListController 子类（Preferences 进程内由 controllerForSpecifier:
// 直接 new 出来，不依赖 specifier plist）。
#import <Preferences/PSListController.h>

@interface TWArcPanelController : PSListController
@end