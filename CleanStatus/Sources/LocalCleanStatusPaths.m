#import "LocalCleanStatusPaths.h"
#import <roothide.h>

static NSString * const local_cleanstatus_logicalPreferencePath =
    @"/var/mobile/Library/Preferences/com.local.cleanstatus.plist";
static NSString * const local_cleanstatus_preferenceSuffix =
    @"/var/mobile/Library/Preferences/com.local.cleanstatus.plist";

// ParticleX-style direct mapping. If RootHide returns identity (or nil), the
// real logical path is used as-is; panel and tweak derive the same path.
NSString *local_cleanstatus_preferencesPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *mapped = jbroot(local_cleanstatus_logicalPreferencePath);
        if (!mapped.length) mapped = local_cleanstatus_logicalPreferencePath;
        path = [mapped stringByStandardizingPath];
    });
    return path;
}

// Write containment boundary: the selected path prefix, or "/" for real var.
NSString *local_cleanstatus_selectedRoot(void) {
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = local_cleanstatus_preferencesPath();
        if (![path hasSuffix:local_cleanstatus_preferenceSuffix]) return;
        NSString *candidate = [path substringToIndex:path.length-local_cleanstatus_preferenceSuffix.length];
        root = candidate.length ? [candidate copy] : @"/";
    });
    return root;
}
