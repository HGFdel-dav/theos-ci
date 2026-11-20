#import <Foundation/Foundation.h>

// 从 App 自己的 NSURLCache 数据库里取最近一次真实请求的
// Authorization / peach / lightningx，用于复刻签名。
@interface SLCacheDB : NSObject
+ (BOOL)refresh:(NSString *)host;
+ (NSString *)token;
+ (NSString *)peach;
+ (NSString *)signature;
+ (NSString *)firstDeviceLoginBody;
@end
