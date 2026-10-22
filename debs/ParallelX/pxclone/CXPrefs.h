// CXPrefs.h — CloneX 偏好（CFPreferences 域 com.niubiprass.clonex）
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const CXKeyHiddenItems;  // [String] "bundle#container" 不在菜单显示
FOUNDATION_EXPORT NSString *const CXKeyDiagCraneOK;  // SpringBoard 里 Crane 是否可用

@interface CXPrefs : NSObject
+ (instancetype)shared;
- (id _Nullable)objectForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)def;
- (void)setBool:(BOOL)value forKey:(NSString *)key;

// 默认全部显示；可单独关掉某个应用的某个容器
- (BOOL)isItemShownInMenu:(NSString *)bundleID containerID:(NSString *)containerID;
- (void)setItemInMenu:(NSString *)bundleID containerID:(NSString *)containerID shown:(BOOL)shown;
- (void)synchronize;
@end

NS_ASSUME_NONNULL_END