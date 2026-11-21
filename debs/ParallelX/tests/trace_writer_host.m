#import <Foundation/Foundation.h>
#import "../Common/PXCloneTrace.h"
#import "../Common/PXClonePaths.h"
#import "../Common/PXCloneRootPolicy.h"
#include <limits.h>
#include <stdlib.h>
#include <stdio.h>

/* Substitute path discovery only. Link the unmodified production writer,
 * Darwin status publication, plist serializer, serial queue and atomic I/O. */
NSString *const PXClonePathsErrorDomain = @"test.trace.paths";
NSString *PXCloneActiveRoot(NSError **error) {
    (void)error;
    const char *root = getenv("PXTRACE_TEST_ROOT");
    return root ? [NSString stringWithUTF8String:root] : nil;
}
NSString *PXCloneCurrentTracePath(NSError **error) {
    return [PXCloneActiveRoot(error) stringByAppendingPathComponent:@"var/mobile/Library/Preferences/fixture.launch-trace.plist"];
}
BOOL PXCloneValidateRoot(NSString *root, NSError **error) {
    (void)error;
    char canonical[PATH_MAX];
    return root && realpath(root.fileSystemRepresentation, canonical) &&
        [root isEqual:[NSString stringWithUTF8String:canonical]] && PXCloneRootIsAppGroup(canonical);
}
BOOL PXCloneEnsureStorage(NSError **error) {
    return [NSFileManager.defaultManager createDirectoryAtPath:
        [PXCloneCurrentTracePath(error) stringByDeletingLastPathComponent]
        withIntermediateDirectories:YES attributes:nil error:error];
}
static PXCloneTraceState writeEvents(NSArray *events) {
    __block BOOL completed = NO;
    __block PXCloneTraceState result = PXCloneTraceStateUnknown;
    [PXCloneTrace writeEvents:events completion:^(PXCloneTraceState state, NSError *error) {
        (void)error; result = state; completed = YES;
    }];
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:8];
    while (!completed && end.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    return result;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSString *action = [NSString stringWithUTF8String:argv[1]];
        double now = NSDate.date.timeIntervalSince1970;
        NSMutableArray *events = [NSMutableArray array];
        for (unsigned i = 0; i < 31; ++i)
            [events addObject:@{ @"time": @(now - 1 + i * 0.01), @"token": @1, @"stage": @"open_visibility", @"code": @0,
                @"detail": @{ @"poll": @(i + 1), @"candidates": @[@{ @"checkedMask": @2047, @"failedMask": @8,
                    @"windowIntersection": @{ @"valid": @NO } }] } }];
        BOOL failing = [action isEqual:@"fail"] || [action isEqual:@"duplicate"];
        [events addObject:failing ? @{ @"time": @(now), @"token": @1, @"stage": @"failed", @"code": @19,
            @"failureID": NSUUID.UUID.UUIDString, @"summary": @{ @"lastOpen": @{ @"poll": @100, @"failedMask": @8 } } } :
            @{ @"time": @(now), @"token": @1, @"stage": @"done ms=221 ok=1 reuse=1", @"code": @0 }];
        PXCloneTraceState result = writeEvents(events);
        if ([action isEqual:@"duplicate"] && result == PXCloneTraceStatePersisted)
            for (unsigned i = 0; i < 6; ++i) result = writeEvents(events);
        printf("{\"state\":%lu}\n", (unsigned long)result);
        return result == PXCloneTraceStateUnknown ? 3 : 0;
    }
}
