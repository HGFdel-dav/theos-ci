// TWArcPXBridge.m
// 角落手势 → ParallelX 面板的桥。
//
// 历史：0.9.9～0.9.16 试过借 PXPanelEntry 的 dockSwiped:/dockTapped: 唤出 PX 面板，
// 0.9.16 实测把 SpringBoard 打进安全模式（SIGSEGV，TWArcPXBridgePresent）。
// 原因：这几个入口的形参是真实的 UIGestureRecognizer（Swift 内部直接解引用），
// 外部只能传 nil，必崩。所以这里彻底停用调用，只保留状态查询给面板显示用；
// 角落唤醒的菜单由 Twin 自绘（参数按 ScreenCore TriggerSettings 对齐）。
#import "TWArcPXBridge.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

static __weak id gPXEntry;
static NSString *gLastResult = @"未调用";

#pragma mark - public

void TWArcPXBridgeCapture(id entry) {
    if (!entry) return;
    gPXEntry = entry;
}

UIWindow *TWArcPXBridgeHostWindow(void) {
    // 触发层用自带的小窗口，不再借 PX 的手柄窗口。
    return nil;
}

BOOL TWArcPXBridgeAvailable(void) {
    return gPXEntry != nil;
}

NSString *TWArcPXBridgeLastResult(void) {
    return gLastResult ?: @"";
}

BOOL TWArcPXBridgePresent(NSInteger side) {
    // 0.9.16 崩溃实锤：PXPanelEntry 的 dockSwiped:/dockTapped:/dragHandle:
    // 需要真实手势对象，传 nil 会让 PX 内部解引用 → SpringBoard 安全模式。
    // 这个入口永久停用；Twin 用自绘菜单，绝不把 SpringBoard 搭进去。
    (void)side;
    gLastResult = @"PX 面板入口需要真实手势对象，已停用（避免崩溃）";
    return NO;
}
