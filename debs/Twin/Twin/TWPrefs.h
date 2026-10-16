// TWPrefs.h
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>  // CGFloat
#import "TWPath.h"

NS_ASSUME_NONNULL_BEGIN

@interface TWPrefs : NSObject
+ (instancetype)shared;
- (void)reload;   // re-read plist from disk (call before reads when SpringBoard was backgrounded)
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
@end

NS_ASSUME_NONNULL_END