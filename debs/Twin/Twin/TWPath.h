// TWPath.h — shared jbroot path resolution (RootHide / rootless compatible)
// Used by both the SpringBoard tweak and the Settings bundle.
#import <Foundation/Foundation.h>

static inline NSString *TWJBRootPath(void) {
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 1. RootHide: scan /var/mobile/Containers/Shared/AppGroup/.jbroot-*
        //    prefer a root that contains our own dylib.
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *appGroupDir = @"/var/mobile/Containers/Shared/AppGroup";
        NSArray *entries = [fm contentsOfDirectoryAtPath:appGroupDir error:nil];
        NSString *fallback = nil;
        for (NSString *name in entries) {
            if (![name hasPrefix:@".jbroot-"]) continue;
            NSString *cand = [appGroupDir stringByAppendingPathComponent:name];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:cand isDirectory:&isDir] || !isDir) continue;
            if (![fm fileExistsAtPath:[cand stringByAppendingPathComponent:@"Library"]]) continue;
            if ([fm fileExistsAtPath:[cand stringByAppendingPathComponent:@"Library/MobileSubstrate/DynamicLibraries/Twin.dylib"]]) {
                root = cand;
                break;
            }
            if (!fallback) fallback = cand;
        }
        if (!root) root = fallback;
        // 2. Dopamine / rootless fallback
        if (!root && [fm fileExistsAtPath:@"/var/jb"]) root = @"/var/jb";
        // 3. Last resort: real root
        if (!root) root = @"";
    });
    return root;
}

// Plist holding Twin preferences, always under the jbroot tree so that
// nothing is ever written to the real /var/mobile/Library/Preferences.
static inline NSString *TWPrefsFilePath(void) {
    NSString *base = TWJBRootPath();
    if (!base.length) return nil;
    return [base stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.niubiprass.twin.plist"];
}

#define TWKeyEnabled          @"TWEnabled"
#define TWKeyArcEnabled       @"TWArcEnabled"
#define TWKeyArcSide          @"TWArcSide"          // 0 left, 1 right
#define TWKeyArcTriggerWidth  @"TWArcTriggerWidth"  // points
#define TWKeyArcItemCount     @"TWArcItemCount"     // icons per menu
#define TWKeyArcRadius        @"TWArcRadius"        // points
#define TWKeyArcSound         @"TWArcSoundEnabled"
#define TWKeyCraneEnabled     @"TWCraneEnabled"
#define TWKeyCraneApps        @"TWCraneApps"        // NSDictionary { bundleID : containerID }