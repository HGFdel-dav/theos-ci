#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

// Routes SpringBoard's external "open application with URL" requests through a
// clone-account chooser. Only bundles that actually have more than one Crane
// container are intercepted; everything else proceeds untouched.
@interface PXCloneURLRouter : NSObject

// Returns YES when the router owns this request and will call `proceed` itself
// (immediately for coincident choices, or after the chosen account is active).
// Returns NO when the caller must run its normal path right now.
//
// While the account catalog is still loading the router already owns the
// request, so the URL cannot slip through to the current account. If the
// chosen account cannot be confirmed, `proceed` is NOT called: the router
// shows a short error and the user retries, instead of opening the wrong
// account silently.
//
// `proceed` is invoked at most once, on the main thread, and may be deferred;
// the caller must not run the original implementation before that.
+ (BOOL)handleOpenRequest:(nullable id)request
                  proceed:(void (^)(void))proceed;

// In-app path: every app process hooks -[UIApplication openURL:...] so a
// payment handoff is caught at its SOURCE, whichever app it comes from
// (China Unicom, China Mobile, Taobao, Safari ...), not just SpringBoard.
// Returns YES when the router owns the request.
+ (BOOL)handleOpenURL:(nullable NSURL *)url proceed:(void (^)(void))proceed;
+ (BOOL)recentAppHandoff;
+ (void)noteAppHandoff;

@end

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
