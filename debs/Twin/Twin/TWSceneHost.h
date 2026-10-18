// TWSceneHost.h
// 分屏窗口底座：在 SpringBoard 进程内，把指定应用（Crane 分身）的
// FBScene 挂到 Twin 自己的 overlay window 上，实现独立分屏。
//
// 这是 ParallelX 的核心能力（PXSceneBridge + PXOverlayWindow）的重写版。
// 不依赖、不调用 ParallelX：FBSceneManager / _UISceneLayerHostContainerView
// 都是系统私有 API，Twin 自己持有 scene 的宿主视图。
//
// 生命周期：
//   TWSceneHost *host = [TWSceneHost hostForBundleID:@"com.tencent.xin"];
//   [host present];      // 创建 overlay window 并挂载 scene
//   host.frame = ...;    // 移动/缩放
//   [host dismiss];      // 卸载 scene，销毁窗口
//
// 所有方法主线程调用；内部全量 @try，失败返回 nil 并记录日志，绝不崩溃 SpringBoard。
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TWSceneHost : NSObject

// 指定 bundleID 的宿主；同一 bundleID 单例复用。scene 不可用时返回 nil。
+ (nullable instancetype)hostForBundleID:(NSString *)bundleID;

@property (nonatomic, copy, readonly) NSString *bundleID;
@property (nonatomic, copy) NSString *containerID;     // Crane 容器，空串 = 默认容器
@property (nonatomic, readonly) BOOL hosting;          // scene 是否已挂载
@property (nonatomic, assign) CGRect frame;            // overlay window 的 frame（屏幕坐标）
@property (nonatomic, assign) CGFloat cornerRadius;    // 窗口圆角，默认 16

// 挂载 scene 并显示窗口。返回是否成功。
- (BOOL)present;
// 卸载 scene、销毁窗口。
- (void)dismiss;
// 把 scene 交还给系统全屏（关闭分屏但保留应用）。
- (void)closeForFullscreen;

// 全局状态
+ (BOOL)engineAvailable;          // FrontBoard / FBSceneManager 是否可用
+ (nullable NSArray<NSString *> *)hostedBundleIDs;

@end

NS_ASSUME_NONNULL_END
