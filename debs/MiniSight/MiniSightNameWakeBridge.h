#ifndef MINISIGHT_NAME_WAKE_BRIDGE_H
#define MINISIGHT_NAME_WAKE_BRIDGE_H
#import <Foundation/Foundation.h>
#import "MiniSightNameWakeProtocol.h"
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const MSNWRequestNote;
FOUNDATION_EXPORT NSString *const MSNWResponseNote;
FOUNDATION_EXPORT NSString *const MSNWStateNote;
/* Main-thread interface; fixed-name bounded IO runs on one serial mailbox queue.
   UI/safety belongs to the host. No audio, TTS, App launch or preferences writes. */
@interface MiniSightNameWakeBridge : NSObject
+ (instancetype)sharedBridge;
@property (nonatomic, readonly, copy) NSString *host;
- (void)publishContainer:(nullable NSString *)container revision:(NSString *)revision
              lockKnown:(BOOL)lockKnown unlocked:(BOOL)unlocked
            screenKnown:(BOOL)screenKnown screenOff:(BOOL)screenOff allowed:(BOOL)allowed busy:(BOOL)busy;
- (void)readRequestInContainer:(nullable NSString *)container revision:(NSString *)revision
                   completion:(void (^)(NSDictionary * _Nullable request))completion;
- (BOOL)request:(NSDictionary *)request matchesRevision:(NSString *)revision;
- (void)replyToRequest:(NSDictionary *)request container:(nullable NSString *)container
                state:(NSString *)state responseGeneration:(NSUInteger)responseGeneration
      voiceGeneration:(NSUInteger)voiceGeneration reason:(NSString *)reason;
@end
NS_ASSUME_NONNULL_END
#endif
