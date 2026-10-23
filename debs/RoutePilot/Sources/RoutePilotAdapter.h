#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RoutePilotAdapterState) {
    RoutePilotAdapterStateUnavailable = 0,
    RoutePilotAdapterStateDetected,
    RoutePilotAdapterStateReady,
    RoutePilotAdapterStateApplying,
    RoutePilotAdapterStateFailed,
};

@protocol RoutePilotAdapter <NSObject>
@property (nonatomic, copy, readonly) NSString *routepilot_app_identifier;
@property (nonatomic, copy, readonly) NSString *routepilot_app_displayName;
- (RoutePilotAdapterState)routepilot_app_state;
- (BOOL)routepilot_app_validateSelectedBundleIDs:(NSArray<NSString *> *)bundleIDs error:(NSError **)error;
- (BOOL)routepilot_app_applyDirectBundleIDs:(NSArray<NSString *> *)bundleIDs error:(NSError **)error;
- (BOOL)routepilot_app_restorePreviousConfiguration:(NSError **)error;
@end

@interface RoutePilotAdapterRegistry : NSObject
+ (instancetype)routepilot_app_shared;
- (NSArray<id<RoutePilotAdapter>> *)routepilot_app_availableAdapters;
- (nullable id<RoutePilotAdapter>)routepilot_app_activeAdapter;
- (void)routepilot_app_registerAdapter:(id<RoutePilotAdapter>)adapter;
@end

NS_ASSUME_NONNULL_END
