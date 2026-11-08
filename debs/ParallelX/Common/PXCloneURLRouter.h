#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

// Only verified payment URLs with multiple Crane accounts may be delayed.
// Plain links and notifications decline synchronously. No global opener,
// catalog retry chain, cross-process time window or scene-less key window.
@interface PXCloneURLRouter : NSObject
+ (BOOL)isShareRequest:(nullable id)request options:(nullable id)options;
// Any request that really carries a URL (payment, link share, document).
+ (BOOL)hasTargetURL:(nullable id)request options:(nullable id)options;

// Pure classification: no Crane, writes, timers or UI.
+ (BOOL)isPaymentURL:(nullable NSURL *)url;
+ (nullable NSURL *)paymentURLForRequest:(nullable id)request options:(nullable id)options;

// YES means owned; the opener runs at most once and only after selection,
// process-state validation and active-container readback. Cancel/failure never
// open. These methods are main-thread-only; other callers get NO immediately.
+ (BOOL)handleOpenRequest:(nullable id)request
                  options:(nullable id)options
                  proceed:(void (^)(void))proceed;
+ (BOOL)handleOpenURL:(nullable NSURL *)url proceed:(void (^)(void))proceed;
+ (BOOL)hasActivePayment;

@end

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
