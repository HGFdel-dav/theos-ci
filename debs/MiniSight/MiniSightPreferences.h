#ifndef MINISIGHT_PREFERENCES_H
#define MINISIGHT_PREFERENCES_H
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT id _Nullable MSMiniSightPreference(NSString *key);
FOUNDATION_EXPORT void MSMiniSightSetPreference(NSString *key, id value);
FOUNDATION_EXPORT void MSMiniSightRemovePreference(NSString *key);
NS_ASSUME_NONNULL_END
#endif
