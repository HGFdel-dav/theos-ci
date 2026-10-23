#pragma once

#import <Foundation/Foundation.h>

@interface RoutePilotConfig : NSObject
+ (instancetype)routepilot_app_shared;
- (BOOL)routepilot_app_isEnabled;
- (id)routepilot_app_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)routepilot_app_reload;
@end
