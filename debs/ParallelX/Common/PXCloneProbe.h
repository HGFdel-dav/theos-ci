#pragma once
#import <Foundation/Foundation.h>

// Temporary, content-free diagnostic trail for the URL-routing investigation.
// Appends one short line per event to a file in the hidden root's Caches dir.
// Cheap enough to keep for a few builds; remove once routing is settled.
@interface PXCloneProbe : NSObject
+ (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
+ (NSString *)path;
@end
