#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PXClonePolicyState) {
    PXClonePolicyStateIdle = 0,
    PXClonePolicyStateSwitching,
    PXClonePolicyStateVerifying,
    PXClonePolicyStateReady,
    PXClonePolicyStateFailed,
    PXClonePolicyStateCancelled,
};

// Main-queue-only transaction. A monotonically increasing token makes late
// switch/verify callbacks from older transactions harmless.
//
// Rules:
//  * switch completion is accepted once, only for the current token;
//  * success alone is not enough: the active container must be re-read and
//    equal the target, with bounded retries;
//  * switch failure, wrong container at deadline, or cancel finishes exactly
//    once with NO and never opens the stale account;
//  * completion is copied and fires exactly once on the provided queue
//    (main when the queue is nil).
@interface PXCloneTransition : NSObject

@property (nonatomic, readonly) NSUInteger token;
@property (nonatomic, readonly) PXClonePolicyState state;
@property (nonatomic, readonly) NSString *bundleID;
@property (nonatomic, readonly) NSString *containerID;

- (instancetype)initWithBundle:(NSString *)bundleID
                     container:(NSString *)containerID
                         queue:(dispatch_queue_t)queue
                    completion:(void (^)(BOOL ok, NSError * _Nullable error))completion;

// Kicks the provided switch block. The block must call -switchDidFinish: exactly
// once; duplicate calls are ignored.
- (void)beginWithSwitch:(void (^)(void (^done)(BOOL ok)))switchBlock
             verify:(NSString * _Nullable (^)(void))verifyBlock;

- (void)switchDidFinish:(BOOL)ok;
- (void)cancel;

@end

FOUNDATION_EXPORT NSString *const PXClonePolicySettlingStatus;
FOUNDATION_EXPORT NSTimeInterval const PXClonePolicyVerifyTimeout;
FOUNDATION_EXPORT NSTimeInterval const PXClonePolicyVerifyInterval;

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
