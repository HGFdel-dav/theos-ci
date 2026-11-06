#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const PXCloneTraceNotification;

typedef NS_ENUM(NSUInteger, PXCloneTraceState) {
    PXCloneTraceStateUnknown = 0,
    PXCloneTraceStatePersisted,
    PXCloneTraceStatePathFailure,
    PXCloneTraceStateSerializationFailure,
    PXCloneTraceStateWriteFailure,
    PXCloneTraceStateReadbackFailure,
};

// Status is available through Darwin notify state even when the trace file
// cannot be created. No credentials or account content are in that channel.
@interface PXCloneTrace : NSObject
+ (PXCloneTraceState)state;
+ (NSString *)descriptionForState:(PXCloneTraceState)state;
+ (void)writeEvents:(NSArray<NSDictionary *> *)events
        completion:(void (^ _Nullable)(PXCloneTraceState state, NSError * _Nullable error))completion;
@end
NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
