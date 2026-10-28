#import <Foundation/Foundation.h>

@interface POExternalActivationCoordinator : NSObject

+ (instancetype)sharedInstance;

- (id)prepareOpenApplicationRequestIfNeeded:(id)request completion:(id)completion;
- (id)prepareTrustedWorkspaceOpenApplication:(id)application
                                     options:(id)options
                                      origin:(id)origin
                                      result:(id)result
                                routedResult:(id __autoreleasing *)routedResult;
- (void)prepareNativeTakeoverForTransitionRequestIfNeeded:(id)transitionRequest;

/// 从 openApplication 请求里解析目标 bundle（复用内部同一套递归解析）。
+ (nullable NSString *)targetBundleIdentifierForRequest:(id)request;
/// 请求携带的 URL，纯诊断用。
+ (nullable NSString *)openURLStringForRequest:(id)request;

@end
