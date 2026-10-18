// TWContainerExport.h
// SpringBoard 侧：枚举 Crane 的容器，导出到共享文件，供 Settings 进程里的面板读取。
//
// 背景：CraneManager 只存在于 SpringBoard 进程。面板（PreferenceBundle）跑在
// Settings 进程，直接调 CraneManager 永远拿不到东西——这就是"没有发现容器"
// 的根因。本模块在 SpringBoard 里读好，写 /var/mobile/Library/Twin/crane-containers.plist，
// 面板只读文件。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 立即导出一次（幂等，主线程调用）。
FOUNDATION_EXPORT void TWContainerExportNow(void);
// 启动导出：等 Crane 加载后执行，并在应用启动/容器切换后自动刷新。
FOUNDATION_EXPORT void TWContainerExportStart(void);
// 导出文件路径（面板侧也用这个路径）。
FOUNDATION_EXPORT NSString *TWContainerExportPath(void);

NS_ASSUME_NONNULL_END
