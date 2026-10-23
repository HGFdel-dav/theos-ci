// SCPreferences.h - 逆向重建自 ScreenCore 2.0.4
#import <Foundation/Foundation.h>

extern NSString *const SCPreferencesDomain;  // com.susudear.screencoreprefs

// === 偏好键（从反汇编字符串提取） ===
extern NSString *const kSCEnabled;

// ARC 触发
extern NSString *const kSCArcEnabled;
extern NSString *const kSCArcTriggerMode;        // 0=扇形 1=矩形
extern NSString *const kSCArcTriggerSide;        // 0=左 1=右 2=双侧
extern NSString *const kSCArcRectangleLength;
extern NSString *const kSCArcRectangleHeight;
extern NSString *const kSCArcRectangleCornerRadius;

// ARC 菜单
extern NSString *const kSCArcMenuRadius;
extern NSString *const kSCArcItemsPerRing;
extern NSString *const kSCArcAnimationDamping;

// 分身选择
extern NSString *const kSCSelectedCraneApplications;  // 勾选的应用+容器

// Crane 开关
extern NSString *const kSCCraneSwitchFullscreenEnabled;  // 切容器后全屏

@interface SCPreferences : NSObject

+ (instancetype)sharedPreferences;

// === 读取 ===
- (id)sc_objectForKey:(NSString *)key;
- (BOOL)sc_boolForKey:(NSString *)key;
- (NSInteger)sc_integerForKey:(NSString *)key;
- (CGFloat)sc_floatForKey:(NSString *)key;

// === 写入 ===
- (void)sc_setObject:(id)object forKey:(NSString *)key;
- (void)sc_setBool:(BOOL)value forKey:(NSString *)key;
- (void)sc_setInteger:(NSInteger)value forKey:(NSString *)key;
- (void)sc_setFloat:(CGFloat)value forKey:(NSString *)key;

// === 同步 ===
- (void)sc_synchronize;
- (void)sc_registerDefaults:(NSDictionary *)defaults;

@end
