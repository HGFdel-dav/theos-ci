#import "LocalCleanStatusCCEnvironment.h"
#import "LocalCleanStatusCCRuntime.h"
#import <dlfcn.h>
#include <signal.h>
#include <unistd.h>
#include <string.h>

// Resolve the hidden root once, in the documented priority order: official
// jbroot() when present, then the directory that actually contains this image
// (own dylib for the tweak, own bundle for the CC module). Never hardcode a
// .jbroot-<UUID> and never scan every candidate root on a normal write.
static NSString *lcscc_rootFromImage(void) {
    NSBundle *bundle=NSBundle.mainBundle;
    NSString *image=[bundle.bundleIdentifier hasPrefix:@"com.apple.springboard"]?nil:bundle.bundlePath;
    if (!image.length) {
        Dl_info info;
        if (dladdr((void *)lcscc_rootFromImage,&info) && info.dli_fname)
            image=[NSString stringWithUTF8String:info.dli_fname];
    }
    if (!image.length || !image.isAbsolutePath) return nil;
    NSArray *parts=image.stringByStandardizingPath.pathComponents;
    for (NSInteger i=(NSInteger)parts.count-1;i>0;i--) {
        if (![parts[i] isEqualToString:@"Library"]) continue;
        NSString *candidate=[NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0,(NSUInteger)i)]];
        if ([NSFileManager.defaultManager fileExistsAtPath:[candidate stringByAppendingPathComponent:@"usr/lib"]])
            return candidate;
    }
    return nil;
}
static NSString *lcscc_rootFromMapper(void) {
    // Weak on purpose: no link-time dependency on the jailbreak library and no
    // guess about which process has it injected.
    const char *(*mapper)(const char *)=(const char *(*)(const char *))dlsym(RTLD_DEFAULT,"jbroot");
    if (!mapper) return nil;
    const char *mapped=mapper("/");
    if (!mapped) return nil;
    NSString *root=[NSString stringWithUTF8String:mapped];
    if (![root isEqualToString:@"/"] && root.isAbsolutePath &&
        [NSFileManager.defaultManager fileExistsAtPath:[root stringByAppendingPathComponent:@"usr/lib"]])
        return root;
    return nil;
}
NSString *local_cleanstatus_ccRoot(void) {
    static NSString *root; static dispatch_once_t once;
    dispatch_once(&once,^{
        root=lcscc_rootFromMapper();
        if (!root.length) root=lcscc_rootFromImage();
    });
    return root;
}
BOOL local_cleanstatus_ccIsSpringBoard(void) {
    static BOOL valid; static dispatch_once_t once;
    dispatch_once(&once,^{
        NSBundle *bundle=NSBundle.mainBundle;
        valid=getpid()>1 && [bundle.bundleIdentifier isEqualToString:@"com.apple.springboard"] &&
            [bundle.executablePath.stringByResolvingSymlinksInPath
                isEqualToString:@"/System/Library/CoreServices/SpringBoard.app/SpringBoard"];
    });
    return valid;
}
BOOL local_cleanstatus_ccUnlocked(void) {
    if (!local_cleanstatus_ccIsSpringBoard()) return NO;
    id aggregator=lcscc_object(NSClassFromString(@"SBLockStateAggregator"),"sharedInstance");
    SEL sel=sel_registerName("lockState");
    Method m=aggregator?class_getInstanceMethod(object_getClass(aggregator),sel):NULL;
    if (!m || method_getNumberOfArguments(m)!=2) return NO;
    char *type=method_copyReturnType(m);
    const char *name=lcscc_type(type);
    BOOL numeric=name && (!strcmp(name,@encode(NSUInteger))||!strcmp(name,@encode(NSInteger)));
    free(type);
    if (!numeric) return NO; // fail closed instead of misreading an object as a mask
    return ((((NSUInteger(*)(id,SEL))objc_msgSend)(aggregator,sel))&2)==0;
}
NSString *local_cleanstatus_ccResourcePath(NSString *logicalPath) {
    NSString *root=local_cleanstatus_ccRoot();
    if (!root.length || !logicalPath.isAbsolutePath || [logicalPath.pathComponents containsObject:@".."])
        return nil;
    return [root stringByAppendingPathComponent:[logicalPath substringFromIndex:1]];
}
NSString *local_cleanstatus_ccModulePath(void) {
    return local_cleanstatus_ccResourcePath(@"/Library/ControlCenter/Bundles/LocalCleanStatusSystemActions.bundle");
}
NSString *local_cleanstatus_ccToolPath(NSString *name) {
    if (!name.length || [name containsString:@"/"]) return nil;
    NSMutableArray<NSString *> *candidates=[NSMutableArray new];
    NSString *root=local_cleanstatus_ccRoot();
    if (root.length) {
        [candidates addObject:[root stringByAppendingPathComponent:[@"usr/bin/" stringByAppendingString:name]]];
        [candidates addObject:[root stringByAppendingPathComponent:[@"basebin/" stringByAppendingString:name]]];
    }
    [candidates addObject:[@"/usr/bin/" stringByAppendingString:name]];
    [candidates addObject:[@"/var/jb/usr/bin/" stringByAppendingString:name]];
    for (NSString *path in candidates)
        if (access(path.fileSystemRepresentation,X_OK)==0) return path;
    return nil;
}

void local_cleanstatus_ccConsumeSafeModeFlag(void) {
    if (!local_cleanstatus_ccIsSpringBoard()) return;
    NSString *path=local_cleanstatus_ccResourcePath(@"/var/mobile/Library/Preferences/com.local.cleanstatus.safemode");
    if (!path.length) return;
    NSDictionary *flag=[NSDictionary dictionaryWithContentsOfFile:path];
    if (![flag isKindOfClass:NSDictionary.class]) return;
    NSTimeInterval armed=[flag[@"armed"] doubleValue];
    NSUInteger crashes=[flag[@"crashes"] unsignedIntegerValue];
    double now=[NSDate date].timeIntervalSince1970;
    // Stale arming (device rebooted by other means, or the promise never
    // completed) must not be able to crash-loop the device later.
    if (armed<=0 || now-armed>600 || crashes>1) { [NSFileManager.defaultManager removeItemAtPath:path error:NULL]; return; }
    if (crashes==0) {
        [@{@"crashes":@1,@"armed":@(now)} writeToFile:path atomically:YES];
    } else {
        [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    }
    // Second boot crash is what makes the jailbreak treat this as a boot loop
    // and enter safe mode; the flag is already cleared so the next boot is
    // normal either way.
    kill(getpid(),SIGSEGV);
}
