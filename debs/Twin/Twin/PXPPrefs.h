// PXPPrefs.h
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>  // CGFloat
#import "PXPPath.h"

NS_ASSUME_NONNULL_BEGIN

@interface PXPPrefs : NSObject
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