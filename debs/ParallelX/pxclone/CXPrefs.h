// CXPrefs.h — CloneX 偏好（CFPreferences 域 com.niubiprass.clonex）
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const CXKeyHiddenApps;   // [String] 不在菜单显示分身的应用
FOUNDATION_EXPORT NSString *const CXKeyDiagCraneOK;  // SpringBoard 里 Crane 是否可用

@interface CXPrefs : NSObject
+ (instancetype)shared;
- (id _Nullable)objectForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)def;
- (void)setBool:(BOOL)value forKey:(NSString *)key;

// 默认全部显示：Crane 里有的容器就出现在菜单里
- (BOOL)isAppShownInMenu:(NSString *)bundleID;
- (void)setApp:(NSString *)bundleID shownInMenu:(BOOL)shown;
- (void)synchronize;
@end

NS_ASSUME_NONNULL_END