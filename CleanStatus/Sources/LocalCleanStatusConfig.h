#pragma once

#import <Foundation/Foundation.h>
#import "LocalCleanStatusCore.h"

FOUNDATION_EXPORT uint32_t local_cleanstatus_currentFlags(void);

@interface LocalCleanStatusConfig : NSObject
+ (instancetype)local_cleanstatus_shared;
- (BOOL)local_cleanstatus_isEnabled;
- (id)local_cleanstatus_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)local_cleanstatus_reload;
@end
