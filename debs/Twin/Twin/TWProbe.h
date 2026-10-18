// TWProbe.h
// 运行时探针：把 ParallelX 真正"能被外部调用"的方法列出来。
//
// 背景（2026-10-18 实测）：ParallelX.dylib 只有 7 个 ObjC 类名、664 个对外选择子，
// 里面**没有任何** present/show panel 之类"显示我的面板"的入口，所以唤醒后的菜单
// 没法直接复用它的面板。为了判断它到底哪些成员是 @objc 可调的（Swift 类多数不是），
// 只能在真机进程里用 class_copyMethodList 现场 dump，再把结果写文件取回分析。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// 幂等；只在 SpringBoard 进程调用。内部延迟执行 + 全量 @try 兜底，绝不因探针崩溃。
FOUNDATION_EXPORT void TWProbeStart(void);
// 探针结果文件路径（取不到返回 nil）。
FOUNDATION_EXPORT NSString *_Nullable TWProbeOutputPath(void);
NS_ASSUME_NONNULL_END