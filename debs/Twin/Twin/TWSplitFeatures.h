#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Call on SpringBoard startup, after loading the window engine. Idempotent;
// safe to call again after the engine is loaded. No constructor / dylib loading.
FOUNDATION_EXPORT void TWSplitFeaturesStart(void);
NS_ASSUME_NONNULL_END
