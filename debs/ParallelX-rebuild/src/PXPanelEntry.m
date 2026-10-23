#import "../headers/PXPanelEntry.h"

@implementation PXPanelEntry

+ (void)applicationActivated:(NSString *)bundleID {
    // TODO: 激活应用（从菜单点击触发）
    NSLog(@"[PX] applicationActivated %@", bundleID);
    // 调用 PXSceneBridge 开分屏窗口
}

+ (void)externalOpenApplication:(NSString *)bundleID {
    // TODO: 外部打开应用（URL scheme 触发）
    NSLog(@"[PX] externalOpenApplication %@", bundleID);
}

@end
