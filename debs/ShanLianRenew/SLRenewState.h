#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SLPhase) {
    SLPhaseIdle = 0,
    SLPhaseArmed,
    SLPhaseResetting,
    SLPhaseNeedFill,
    SLPhaseDone,
    SLPhaseFailed
};

@interface SLState : NSObject
// 配置
@property (nonatomic) BOOL enabled;
@property (nonatomic) int lead1;      // 分钟
@property (nonatomic) int lead2;
@property (nonatomic) NSString *code;
@property (nonatomic) BOOL notifyOnFail;
@property (nonatomic) BOOL dueNotified;
@property (nonatomic) double testSecs;
@property (nonatomic) double remindAt;
@property (nonatomic) BOOL resetFallback;
@property (nonatomic) int maxAttempts;
// 运行
@property (nonatomic) SLPhase phase;
@property (nonatomic) double deadline;   // epoch
@property (nonatomic) double nextFire1;
@property (nonatomic) double nextFire2;
@property (nonatomic) int attempt;
@property (nonatomic) int signerIdx;     // -1 = 未校准
@property (nonatomic) NSString *lastError;
@property (nonatomic) double lastRun;
@property (nonatomic) NSString *host;
// 回滚快照
@property (nonatomic) NSDictionary *snapPrefs;
@property (nonatomic) NSString *snapToken;
@property (nonatomic) NSString *kcBackup;
@property (nonatomic) NSString *ver;

+ (instancetype)load;
- (void)save;
- (void)armFromDeadline:(double)deadline;   // 依据到期时间算两次闹点
- (void)clearSchedule;
@end
