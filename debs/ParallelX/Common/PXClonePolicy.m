#import "PXClonePolicy.h"

NSString *const PXClonePolicySettlingStatus = @"__settling__";
NSTimeInterval const PXClonePolicyVerifyTimeout = 3.0;
NSTimeInterval const PXClonePolicyVerifyInterval = 0.25;

static NSError *PXPolicyError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.niubiprass.parallelxclone.policy"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface PXCloneTransition () {
    dispatch_queue_t _queue;
    void (^_completion)(BOOL, NSError *);
    NSString * _Nullable (^_verify)(void);
    BOOL _finished;
    BOOL _switchReturned;
    NSUInteger _attempt;
}
@property (nonatomic, readwrite) NSUInteger token;
@property (nonatomic, readwrite) PXClonePolicyState state;
@property (nonatomic, readwrite) NSString *bundleID;
@property (nonatomic, readwrite) NSString *containerID;
- (dispatch_queue_t)queueOrMain;
- (void)verifyNow;
- (void)finish:(BOOL)ok error:(NSError *)error;
@end

@implementation PXCloneTransition

static NSUInteger PXNextToken = 1;

- (instancetype)initWithBundle:(NSString *)bundleID
                     container:(NSString *)containerID
                         queue:(dispatch_queue_t)queue
                    completion:(void (^)(BOOL, NSError *))completion {
    self = [super init];
    if (!self) return nil;
    _bundleID = [bundleID copy];
    _containerID = [containerID copy];
    _queue = queue ?: dispatch_get_main_queue();
    _completion = [completion copy];
    _state = PXClonePolicyStateIdle;
    _token = PXNextToken++;
    return self;
}

- (void)beginWithSwitch:(void (^)(void (^)(BOOL)))switchBlock
                 verify:(NSString * _Nullable (^)(void))verifyBlock {
    if (!self.bundleID.length || !self.containerID.length) {
        [self finish:NO error:PXPolicyError(1, @"empty bundle/container")];
        return;
    }
    if (!switchBlock || !verifyBlock) {
        [self finish:NO error:PXPolicyError(2, @"missing switch/verify block")];
        return;
    }
    if (self.state != PXClonePolicyStateIdle) {
        [self finish:NO error:PXPolicyError(6, @"transaction already started")];
        return;
    }

    self.state = PXClonePolicyStateSwitching;
    _verify = [verifyBlock copy];
    __weak typeof(self) weakSelf = self;

    // The switch block itself has no watchdog; a lost callback must not leave
    // the transition stuck in Switching forever.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(PXClonePolicyVerifyTimeout * NSEC_PER_SEC)),
                   [self queueOrMain], ^{
        PXCloneTransition *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_finished || strongSelf->_switchReturned) return;
        strongSelf.state = PXClonePolicyStateFailed;
        [strongSelf finish:NO error:PXPolicyError(7, @"container switch timed out")];
    });

    switchBlock(^(BOOL ok) {
        dispatch_async(weakSelf.queueOrMain ?: dispatch_get_main_queue(), ^{
            [weakSelf switchDidFinish:ok];
        });
    });
}

- (dispatch_queue_t)queueOrMain {
    return _queue ?: dispatch_get_main_queue();
}

- (void)switchDidFinish:(BOOL)ok {
    if (_finished || _switchReturned) return;
    _switchReturned = YES;

    if (self.state != PXClonePolicyStateSwitching) return;
    if (!ok) {
        [self finish:NO error:PXPolicyError(3, @"container switch failed")];
        return;
    }
    self.state = PXClonePolicyStateVerifying;
    _attempt = 0;
    [self verifyNow];
}

- (void)verifyNow {
    if (_finished || self.state != PXClonePolicyStateVerifying) return;

    NSString *active = _verify ? _verify() : nil;
    if (active && [active isEqualToString:self.containerID]) {
        self.state = PXClonePolicyStateReady;
        [self finish:YES error:nil];
        return;
    }
    // A settling marker is not the target container and can never be success.

    _attempt++;
    NSTimeInterval elapsed = (NSTimeInterval)_attempt * PXClonePolicyVerifyInterval;
    if (elapsed >= PXClonePolicyVerifyTimeout) {
        self.state = PXClonePolicyStateFailed;
        [self finish:NO error:PXPolicyError(4, @"active container did not settle")];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(PXClonePolicyVerifyInterval * NSEC_PER_SEC)),
                   [self queueOrMain], ^{
        [weakSelf verifyNow];
    });
}

- (void)cancel {
    if (_finished) return;
    self.state = PXClonePolicyStateCancelled;
    [self finish:NO error:PXPolicyError(5, @"cancelled")];
}

- (void)finish:(BOOL)ok error:(NSError *)error {
    if (_finished) return;
    _finished = YES;
    _verify = nil;
    void (^completion)(BOOL, NSError *) = _completion;
    _completion = nil;
    if (!completion) return;
    dispatch_async([self queueOrMain], ^{ completion(ok, error); });
}

@end
