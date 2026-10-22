// CXPrefs.h — CloneX 偏好（CFPreferences 域 com.niubiprass.clonex）
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const CXKeyCloneApps;     // { bundleID : containerID }
FOUNDATION_EXPORT NSString *const CXKeyAskEachTime;   // BOOL, 默认 NO

@interface CXPrefs : NSObject
+ (instancetype)shared;
- (id _Nullable)objectForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)def;

// 每个应用在「菜单打开窗口」时使用的容器（@"DEFAULT" 表示默认容器）
- (NSDictionary<NSString *, NSString *> *)cloneApps;
- (NSString * _Nullable)containerForBundleID:(NSString *)bundleID;
- (void)setContainer:(NSString *)containerID forBundleID:(NSString *)bundleID;
- (void)removeContainerForBundleID:(NSString *)bundleID;
- (void)synchronize;
@end

NS_ASSUME_NONNULL_END
