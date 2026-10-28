//
//  POApplicationHelper.h
//  SplitX
//
//  Created by Will Smillie on 4/8/19.
//

#import <Foundation/Foundation.h>
#import "POSplitTarget.h"
#import <UIKit/UIKit.h>

#import "headers.h"

@interface POApplicationHelper : NSObject

+ (NSArray<NSString *> *)recentAppsWithCount:(int)count;
+ (NSArray<NSString *> *)quickSwitchBundleIdentifiers;
/// 每个应用按真实容器展开；无分身能力时只有一个 DEFAULT 目标。
+ (NSArray<POSplitTarget *> *)quickSwitchTargets;
+ (UIImage *)imageForBundleId:(NSString *)bundleId;
+ (NSString *)frontMostBundleId;
+ (BOOL)isUserFacingApplicationBundleId:(NSString *)bundleId;
+ (UIInterfaceOrientationMask)supportedInterfaceOrientationsForBundleId:(NSString *)bundleId;
+ (UIInterfaceOrientation)preferredHostedInterfaceOrientationForBundleId:(NSString *)bundleId;

+ (NSUserDefaults *)settingsDefaults;
+ (NSDictionary<NSString *, id> *)settings;
+ (void)reloadSettings;
+ (BOOL)isEnabled;
+ (BOOL)isExternalURLRoutingEnabled;
+ (BOOL)isExternalURLRoutingTargetBundleId:(NSString *)bundleId;

+ (UIImage *)iconImageForIdentifier:(NSString *)identifier;

@end
