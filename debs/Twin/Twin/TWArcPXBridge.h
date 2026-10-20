// TWArcPXBridge.h
// 把角落手势接到 ParallelX 自己的面板上：动画、图标、流畅度全部来自 PX 本体，
// Twin 只负责"从哪个角落起手"。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// 由 TWRemember 的 -[PXPanelEntry init] 钩子捕获实例。
void TWArcPXBridgeCapture(id _Nullable entry);

// 是否已经抓到可用的 PXPanelEntry。
BOOL TWArcPXBridgeAvailable(void);

// 让 ParallelX 自己弹出面板。side: 0 = 右侧，1 = 左侧。
// 返回 YES 表示调用发出（不代表面板一定出现），NO 表示只能走 Twin 自绘兜底。
BOOL TWArcPXBridgePresent(NSInteger side);

// ParallelX 自己的手柄窗口（handleWindow，退回 panelWindow / searchWindow）。
// Twin 把角落热区挂在这个窗口上——触摸路径是 PX 验证过的，不需要自己造窗口。
UIWindow * _Nullable TWArcPXBridgeHostWindow(void);

// 诊断：最近一次调用的结果，写进 Twin 的诊断日志。
NSString *TWArcPXBridgeLastResult(void);

NS_ASSUME_NONNULL_END
