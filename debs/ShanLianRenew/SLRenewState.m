#import "SLRenewState.h"
#import "SLRenewPaths.h"

@implementation SLState

+ (instancetype)load {
    SLState *s = [SLState new];
    s.enabled = YES; s.lead1 = 10; s.lead2 = 3;
    s.code = @"88888888"; s.notifyOnFail = YES; s.resetFallback = YES;
    s.maxAttempts = 2; s.phase = SLPhaseIdle; s.signerIdx = -1; s.host = @"";
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:SLStatePath()];
    if ([d isKindOfClass:[NSDictionary class]]) {
        if (d[@"enabled"]) s.enabled = [d[@"enabled"] boolValue];
        if (d[@"lead1"]) s.lead1 = [d[@"lead1"] intValue];
        if (d[@"lead2"]) s.lead2 = [d[@"lead2"] intValue];
        if ([d[@"code"] isKindOfClass:[NSString class]]) s.code = d[@"code"];
        if (d[@"notifyOnFail"]) s.notifyOnFail = [d[@"notifyOnFail"] boolValue];
        if (d[@"dueNotified"]) s.dueNotified = [d[@"dueNotified"] boolValue];
        s.testSecs = [d[@"testSecs"] doubleValue];
        s.remindAt = [d[@"remindAt"] doubleValue];
        if (d[@"resetFallback"]) s.resetFallback = [d[@"resetFallback"] boolValue];
        if (d[@"maxAttempts"]) s.maxAttempts = [d[@"maxAttempts"] intValue];
        if (d[@"phase"]) s.phase = (SLPhase)[d[@"phase"] integerValue];
        s.deadline = [d[@"deadline"] doubleValue];
        s.nextFire1 = [d[@"nextFire1"] doubleValue];
        s.nextFire2 = [d[@"nextFire2"] doubleValue];
        s.attempt = [d[@"attempt"] intValue];
        if (d[@"signerIdx"]) s.signerIdx = [d[@"signerIdx"] intValue];
        if ([d[@"lastError"] isKindOfClass:[NSString class]]) s.lastError = d[@"lastError"];
        s.lastRun = [d[@"lastRun"] doubleValue];
        if ([d[@"host"] isKindOfClass:[NSString class]]) s.host = d[@"host"];
        if ([d[@"snapPrefs"] isKindOfClass:[NSDictionary class]]) s.snapPrefs = d[@"snapPrefs"];
        if ([d[@"snapToken"] isKindOfClass:[NSString class]]) s.snapToken = d[@"snapToken"];
        if ([d[@"kcBackup"] isKindOfClass:[NSString class]]) s.kcBackup = d[@"kcBackup"];
        if ([d[@"ver"] isKindOfClass:[NSString class]]) s.ver = d[@"ver"];
    }
    if (s.lead1 <= 0) s.lead1 = 10;
    if (s.lead2 <= 0) s.lead2 = 3;
    if (s.maxAttempts <= 0) s.maxAttempts = 2;
    if (!s.code.length) s.code = @"88888888";
    return s;
}

- (void)save {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"enabled"] = @(self.enabled);
    d[@"lead1"] = @(self.lead1);
    d[@"lead2"] = @(self.lead2);
    d[@"code"] = self.code ?: @"";
    d[@"notifyOnFail"] = @(self.notifyOnFail);
    d[@"dueNotified"] = @(self.dueNotified);
    d[@"testSecs"] = @(self.testSecs);
    d[@"remindAt"] = @(self.remindAt);
    d[@"resetFallback"] = @(self.resetFallback);
    d[@"maxAttempts"] = @(self.maxAttempts);
    d[@"phase"] = @(self.phase);
    d[@"deadline"] = @(self.deadline);
    d[@"nextFire1"] = @(self.nextFire1);
    d[@"nextFire2"] = @(self.nextFire2);
    d[@"attempt"] = @(self.attempt);
    d[@"signerIdx"] = @(self.signerIdx);
    d[@"lastError"] = self.lastError ?: @"";
    d[@"lastRun"] = @(self.lastRun);
    d[@"host"] = self.host ?: @"";
    if (self.snapPrefs) d[@"snapPrefs"] = self.snapPrefs;
    if (self.snapToken) d[@"snapToken"] = self.snapToken;
    if (self.kcBackup) d[@"kcBackup"] = self.kcBackup;
    if (self.ver) d[@"ver"] = self.ver;
    [d writeToFile:SLStatePath() atomically:YES];
}

- (void)armFromDeadline:(double)deadline {
    self.deadline = deadline;
    self.nextFire1 = deadline - self.lead1 * 60;
    self.nextFire2 = deadline - self.lead2 * 60;
    double now = [NSDate date].timeIntervalSince1970;
    if (self.nextFire1 < now + 20) self.nextFire1 = now + 20;
    self.phase = SLPhaseArmed;
}

- (void)clearSchedule {
    self.nextFire1 = 0; self.nextFire2 = 0;
    if (self.phase == SLPhaseArmed || self.phase == SLPhaseDone) self.phase = SLPhaseIdle;
}
@end
