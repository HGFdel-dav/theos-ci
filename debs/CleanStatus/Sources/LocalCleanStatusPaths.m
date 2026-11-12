#import "LocalCleanStatusPaths.h"
#import <dlfcn.h>
#import <unistd.h>

// Use the same logical path from Preferences and SpringBoard. RootHide may
// redirect /var/mobile at the filesystem layer; don't second-guess that mapping.
static NSString * const local_cleanstatus_logicalPreferencePath =
    @"/var/mobile/Library/Preferences/com.local.cleanstatus.plist";

NSString *local_cleanstatus_preferencesPath(void) {
    return local_cleanstatus_logicalPreferencePath;
}

// The destination is a fixed logical path, not caller-controlled input.
// '/' is the containment boundary; migrations use canonical paths separately.
NSString *local_cleanstatus_selectedRoot(void) {
    return @"/";
}

static NSString *LCSCHiddenRoot(void) {
    static NSString *root; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *candidate = nil;
        // .../<root>/Library/ControlCenter/Bundles/X.bundle or .../DynamicLibraries
        NSArray *parts = NSBundle.mainBundle.bundlePath.pathComponents;
        for (NSInteger i = parts.count - 1; i > 0; i--) {
            if ([parts[i] isEqualToString:@"Library"]) {
                candidate = [NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0, i)]];
                break;
            }
        }
        if (!candidate.length) {
            Dl_info info;
            if (dladdr((void *)LCSCHiddenRoot, &info) && info.dli_fname)
                candidate = [NSString stringWithUTF8String:info.dli_fname].stringByDeletingLastPathComponent;
        }
        if (candidate.length && access([candidate stringByAppendingPathComponent:@"usr/bin"].fileSystemRepresentation, F_OK) == 0)
            root = candidate;
    });
    return root;
}

NSString *local_cleanstatus_toolPath(NSString *name) {
    if (!name.length) return nil;
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    NSString *hidden = LCSCHiddenRoot();
    if (hidden.length) [roots addObject:hidden];
    [roots addObject:@"/var/jb"];
    [roots addObject:@""];
    for (NSString *root in roots) {
        NSString *path = [root stringByAppendingPathComponent:[@"usr/bin" stringByAppendingPathComponent:name]];
        if (access(path.fileSystemRepresentation, X_OK) == 0) return path;
    }
    return nil;
}
