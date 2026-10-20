// TWPrefs.h
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>  // CGFloat
#import "TWPath.h"

NS_ASSUME_NONNULL_BEGIN

// 原版（ScreenCore）ARC 设置：Twin 的 ARC 参数完全读原版这一份设置域，
// 面板也是原版面板（TwinArcPrefs.bundle）——"抄过来、结合起来"。
FOUNDATION_EXPORT double TWArcOrigNumber(NSString *key, double fallback);
FOUNDATION_EXPORT BOOL TWArcOrigBool(NSString *key, BOOL fallback);


@interface TWPrefs : NSObject
+ (instancetype)shared;
// Darwin notification + read-through refresh; retains locally pending keys.
- (void)reload;
- (id _Nullable)objectForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)def;
- (NSInteger)integerForKey:(NSString *)key defaultValue:(NSInteger)def;
- (CGFloat)floatForKey:(NSString *)key defaultValue:(CGFloat)def;
- (void)setObject:(id _Nullable)obj forKey:(NSString *)key;
- (void)setBool:(BOOL)value forKey:(NSString *)key;
- (void)setInteger:(NSInteger)value forKey:(NSString *)key;
- (void)setFloat:(CGFloat)value forKey:(NSString *)key;
- (void)synchronize;
- (NSDictionary<NSString *,NSString *> *)craneApps;      // cached copy
- (void)setCraneApp:(NSString *)containerID forBundleID:(NSString *)bundleID;
- (void)removeCraneAppForBundleID:(NSString *)bundleID;
// Remembered window frames (ScreenCore-style per-app size/position memory).
- (CGRect)rememberedFrameForBundleID:(NSString *)bundleID;
- (void)setRememberedFrame:(CGRect)frame forBundleID:(NSString *)bundleID;
- (void)clearRememberedFrames;
@end

NS_ASSUME_NONNULL_END