#import <Foundation/Foundation.h>

@interface SLHttp : NSObject
+ (NSString *)currentToken;                 // 钥匙串里以 eyJ 开头的 JWT
+ (NSString *)newTokenDifferentFrom:(NSString *)old;   // 轮询用
+ (void)send:(NSString *)method path:(NSString *)path body:(NSDictionary *)json
  completion:(void (^)(NSInteger status, NSDictionary *resp, NSError *err))done;
+ (void)calibrateSignerCompletion:(void (^)(NSInteger idx))done;
+ (NSString *)deviceId;
+ (void)probeNet;
+ (void)warmup;
+ (void)probeHeaders;
+ (void)mintTokenCompletion:(void (^)(NSString *token, NSString *raw))done;
@end
