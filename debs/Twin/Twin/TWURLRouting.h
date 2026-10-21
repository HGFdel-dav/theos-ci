#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Call in SpringBoard after the PX engine is loaded. Idempotent; retryable if
// classes are not yet present. Does not launch applications at startup.
FOUNDATION_EXPORT void TWURLRoutingStart(void);
NS_ASSUME_NONNULL_END
