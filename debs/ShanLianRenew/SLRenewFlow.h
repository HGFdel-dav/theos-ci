// 续期主流程：Crane 重置 -> 起 App -> 等新号 -> 填码 -> 验证 -> 通知
#import <Foundation/Foundation.h>

@interface SLRenewFlow : NSObject
+ (void)startWithReason:(NSString *)reason;   // 开始一次完整续期
+ (BOOL)isRunning;
@end
