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

+ (NSArray<NSString *> *)containerIdentifiersForBundle:(NSString *)bundleID;
// Same shape as the catalog entries, for ONE bundle (no full app scan).
+ (NSArray<NSDictionary *> *)containersForBundle:(NSString *)bundleID;
+ (NSArray<NSDictionary *> *)prefsContainersForBundle:(NSString *)bundleID;
+ (BOOL)isApplicationRunning:(NSString *)bundleID;
+ (BOOL)terminateApplication:(NSString *)bundleID;
+ (NSString *)activeContainerForBundle:(NSString *)bundleID;
+ (BOOL)containerExists:(NSString *)containerID forBundle:(NSString *)bundleID;
// Requests Crane's normal authentication path with reloadApplication:NO.
// Return value means the request was started, not that it switched accounts.
// The reply BOOL is the RAW Crane callback flag, NOT a success flag: Crane's
// no-biometric branch sets the container, then replies NO (arm64e 0x86a4..bc).
// Every real reply must reach the controller's bounded active-container check.
// Errors/throwing before a reply are returned via error; no synthetic reply.
// reload:YES restarts the app in the new container (good for a plain launch).
// reload:NO leaves it stopped so a URL handoff can launch it WITH its URL.
+ (BOOL)switchToContainer:(NSString *)containerID forBundle:(NSString *)bundleID
                   reload:(BOOL)reload error:(NSError **)error;
+ (BOOL)requestSwitchToContainer:(NSString *)containerID
                       forBundle:(NSString *)bundleID
                           reply:(void (^)(BOOL rawAuthenticationFlag))reply
                           error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
