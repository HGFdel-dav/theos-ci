// CXMenuInjector.h — 把 CloneX 的分身条目写进 ParallelX 的菜单模型
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const CXMenuIDPrefix;   // px.custom.<uuid>

// 本条 id 对应的 bundle / container（不是我们的条目返回 nil）
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> * _Nullable CXVirtualItemForID(NSString * _Nullable itemID);

@interface CXMenuInjector : NSObject
// 按当前 CloneX 配置重写 PX 偏好里的菜单条目（只增删自己的，不碰用户原有条目）
+ (void)sync;
+ (NSString *)menuIDForBundleID:(NSString *)bundleID containerID:(NSString *)containerID;
@end

NS_ASSUME_NONNULL_END