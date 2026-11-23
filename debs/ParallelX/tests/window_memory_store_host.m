#import <Foundation/Foundation.h>
#import "../Common/PXWindowMemoryStore.h"
#import "../Common/PXClonePaths.h"
#import "../Common/PXCloneRootPolicy.h"
#include <limits.h>
#include <stdlib.h>
#include <stdio.h>

/* Only path discovery is substituted; the actual production storage, locking,
 * schema validation, snapshot publication and serialization are linked below. */
NSString *const PXClonePathsErrorDomain = @"test.paths";
NSString *PXCloneActiveRoot(NSError **error) {
    (void)error;
    const char *root=getenv("PXWM_TEST_ROOT");
    return root ? [NSString stringWithUTF8String:root] : nil;
}
NSString *PXCloneCurrentPrefsPath(NSError **error) {
    return [PXCloneActiveRoot(error) stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.niubiprass.clonex.plist"];
}
BOOL PXCloneValidateRoot(NSString *root,NSError **error) {
    (void)error;
    char path[PATH_MAX];
    return root && realpath(root.fileSystemRepresentation,path) &&
           [root isEqual:[NSString stringWithUTF8String:path]] && PXCloneRootIsAppGroup(path);
}
BOOL PXCloneEnsureStorage(NSError **error) {
    NSString *root=PXCloneActiveRoot(error);
    if (!root.length) return NO;
    return [NSFileManager.defaultManager createDirectoryAtPath:
               [PXCloneCurrentPrefsPath(error) stringByDeletingLastPathComponent]
               withIntermediateDirectories:YES attributes:nil error:error];
}
static void spin(BOOL (^condition)(void)) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:8];
    while (!condition() && [end timeIntervalSinceNow]>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
}
static BOOL drain(PXWindowMemoryStore *store) {
    __block BOOL completed=NO, success=NO;
    [store setDiagnosticsEnabled:YES completion:^(BOOL ok) { success=ok; completed=YES; }];
    spin(^BOOL { return completed; }); return completed && success;
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        if (argc!=2) return 2;
        NSString *action=[NSString stringWithUTF8String:argv[1]];
        PXWindowMemoryStore *store=PXWindowMemoryStore.shared;
        spin(^BOOL { return store.isLoaded || store.errorText.length>0; });
        BOOL ok=YES;
        if ([action hasPrefix:@"save"] || [action isEqual:@"late"]) {
            PXWMGeometry geometry={{50,140,260,520},{0,0,390,844}};
            NSString *bundle=[action isEqual:@"saveB"] ? @"com.example.b" : @"com.example.a";
            uint64_t epoch=[action isEqual:@"late"] ? 0 : [store.snapshot[@"epoch"] unsignedLongLongValue];
            [store saveGeometry:geometry bundle:bundle orientation:0 observedEpoch:epoch];
            ok=drain(store);
        } else if ([action isEqual:@"move"] || [action isEqual:@"moveLate"] ||
                   [action isEqual:@"moveNoSlot"] || [action isEqual:@"moveThenResize"] ||
                   [action isEqual:@"resizeThenMove"]) {
            PXWMGeometry moved={{48.66667175292969,54.73334350585935,312,675.2},{0,0,390,844}};
            PXWMGeometry resized={{100,90,220,476.10256410256414},{0,0,390,844}};
            uint64_t epoch=[action isEqual:@"moveLate"] ? 0 : [store.snapshot[@"epoch"] unsignedLongLongValue];
            unsigned orientation=[action isEqual:@"moveNoSlot"] ? 2 : 0;
            if ([action isEqual:@"resizeThenMove"])
                [store saveGeometry:resized bundle:@"com.example.a" orientation:0 observedEpoch:epoch];
            [store savePosition:moved bundle:@"com.example.a" orientation:orientation observedEpoch:epoch];
            if ([action isEqual:@"moveThenResize"])
                [store saveGeometry:resized bundle:@"com.example.a" orientation:0 observedEpoch:epoch];
            ok=drain(store);
        } else if ([action isEqual:@"clear"] || [action isEqual:@"disable"] || [action isEqual:@"enable"]) {
            __block BOOL completed=NO, result=NO;
            void (^done)(BOOL)=^(BOOL success) { result=success; completed=YES; };
            if ([action isEqual:@"clear"]) [store clearMemoryWithCompletion:done];
            else [store setMemoryEnabled:[action isEqual:@"enable"] completion:done];
            spin(^BOOL { return completed; }); ok=completed && result;
        } else if ([action isEqual:@"malformed"]) {
            PXWMGeometry out;
            ok=!PXWindowMemoryGeometry(@{@"enabled":@YES,@"apps":@"wrong"},@"com.example.a",0,&out) &&
               !PXWindowMemoryGeometry(@{@"enabled":@YES,@"apps":@{@"com.example.a":@42}},@"com.example.a",0,&out);
        } else if ([action isEqual:@"logs"]) {
            for (unsigned i=0;i<300;i++) [store diagnostic:@"fixture" details:@{@"index":@(i)}];
            ok=drain(store);
        }
        NSDictionary *output=@{@"loaded":@(store.isLoaded),@"ok":@(ok),@"error":store.errorText,
                               @"snapshot":store.snapshot};
        NSData *data=[NSJSONSerialization dataWithJSONObject:output options:0 error:NULL];
        puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
        return ok ? 0 : 1;
    }
}
