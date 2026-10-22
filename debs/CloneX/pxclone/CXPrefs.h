// CXPrefs.h — CloneX 偏好（CFPreferences 域 com.niubiprass.clonex）
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const CXKeyMenuItems;   // [{bundleID, containerID}]

@interface CXPrefs : NSObject
+ (instancetype)shared;
- (id _Nullable)objectForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)def;

// 菜单里要显示的分身条目
- (NSArray<NSDictionary *> *)menuItems;
- (BOOL)isContainer:(NSString *)containerID shownForBundleID:(NSString *)bundleID;
- (void)toggleContainer:(NSString *)containerID bundleID:(NSString *)bundleID;
- (void)removeAllMenuItems;
- (void)synchronize;
@end

NS_ASSUME_NONNULL_END