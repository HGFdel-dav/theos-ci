#pragma once
#import <Foundation/Foundation.h>
// Callers supply category/reason codes only, never SSIDs, Bluetooth names or credentials.
void local_cleanstatus_ccLog(NSString *event, NSString *reason);
