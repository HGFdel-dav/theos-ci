#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const PXCloneErrorDomain;

typedef NS_ENUM(NSInteger, PXCloneCraneError) {
    PXCloneCraneErrorUnavailable = 1,
    PXCloneCraneErrorUnsupported,
    PXCloneCraneErrorABI,
    PXCloneCraneErrorSwitchFailed,
    PXCloneCraneErrorReloadFailed,
    PXCloneCraneErrorInvalidArgument,
};

// Catalog shape: @[ @{@"bundle": NSString, @"name": NSString,
//                     @"containers": @[ @{@"container": NSString,
//                                          @"name": NSString,
//                                          @"isDefault": NSNumber} ]} ]
@interface PXCloneCrane : NSObject

+ (BOOL)prepareManager;
+ (NSArray<NSDictionary *> *)cachedCatalog;
+ (void)refreshCatalogWithCompletion:(void (^)(NSArray<NSDictionary *> *catalog,
                                               NSError * _Nullable error))completion;

+ (NSString *)activeContainerForBundle:(NSString *)bundleID;
+ (BOOL)containerExists:(NSString *)containerID forBundle:(NSString *)bundleID;
// Authenticated Crane switch with reloadApplication:NO. The controller owns
// the watchdog; a late biometric callback must remain observable.
+ (BOOL)switchContainer:(NSString *)containerID
              forBundle:(NSString *)bundleID
             completion:(void (^)(BOOL ok, NSError * _Nullable error))completion
                  error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
