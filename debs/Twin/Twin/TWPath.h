// TWPath.h — shared jbroot path resolution (RootHide / rootless compatible)
// Used by both the SpringBoard tweak and the standalone Settings bundle.
//
// Verified on the target device (iOS 15.5 / RootHide):
//   /Library  -> /var/containers/Bundle/Application/.jbroot-703BE1466AE884EA/Library
//   the same jbroot is also reachable as
//   /var/mobile/Containers/Shared/AppGroup/.jbroot-703BE1466AE884EA/
// so BOTH bases must be scanned.
#import <Foundation/Foundation.h>
#import <dlfcn.h>

// Deliberately not dispatch_once: RootHide roots can rotate during this process.
static inline NSArray<NSString *> *TWJBRootCandidates(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *roots = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSArray *bases = @[
        @"/var/containers/Bundle/Application",
        @"/var/mobile/Containers/Shared/AppGroup",
        @"/var/mobile/Containers/Bundle/Application",
    ];
    for (NSString *base in bases) {
        for (NSString *name in [fm contentsOfDirectoryAtPath:base error:nil]) {
            if (![name hasPrefix:@".jbroot-"]) continue;
            NSString *path = [base stringByAppendingPathComponent:name];
            NSString *key = path.stringByResolvingSymlinksInPath ?: path;
            if ([seen containsObject:key]) continue;
            BOOL directory = NO;
            if ([fm fileExistsAtPath:path isDirectory:&directory] && directory) {
                [seen addObject:key];
                [roots addObject:path];
            }
        }
    }
    BOOL directory = NO;
    if ([fm fileExistsAtPath:@"/var/jb" isDirectory:&directory] && directory) [roots addObject:@"/var/jb"];
    return roots;
}

// Pick the root that actually contains this package's files. The dylib wins;
// in the Preferences process (no dylib injected) the bundle path wins instead,
// so both processes resolve to the same directory.
static inline NSString *TWJBRootPath(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    Dl_info image = {0};
    dladdr((const void *)&TWJBRootPath, &image);
    NSString *own = image.dli_fname ? [[NSString stringWithUTF8String:image.dli_fname] stringByResolvingSymlinksInPath] : @"";
    NSString *best = nil; NSInteger bestScore = -1; NSTimeInterval bestTime = -1;
    for (NSString *root in TWJBRootCandidates()) {
        NSString *resolved = root.stringByResolvingSymlinksInPath;
        if (!resolved.length || [resolved isEqualToString:@"/"]) continue;
        NSString *ms = [root stringByAppendingPathComponent:@"Library/MobileSubstrate/DynamicLibraries/Twin.dylib"];
        NSString *usr = [root stringByAppendingPathComponent:@"usr/lib/Twin.dylib"];
        NSString *bundle = [root stringByAppendingPathComponent:@"Library/PreferenceBundles/TwinPrefs.bundle"];
        BOOL hasMS = [fm fileExistsAtPath:ms], hasUsr = [fm fileExistsAtPath:usr];
        BOOL hasBundle = [fm fileExistsAtPath:bundle];
        NSInteger score = hasMS ? 2000 : (hasUsr ? 1000 : 0);
        if (hasBundle) score += 500;
        if (own.length) {
            NSString *prefix = [resolved stringByAppendingString:@"/"];
            if ([own hasPrefix:prefix]) score += 10000;
        }
        if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"Library/MobileSubstrate"]]) score += 20;
        else if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"usr/lib"]]) score += 10;
        if (!score) continue;
        NSString *stampPath = hasMS ? ms : (hasUsr ? usr : (hasBundle ? bundle : root));
        NSTimeInterval stamp = [[[fm attributesOfItemAtPath:stampPath error:nil] fileModificationDate] timeIntervalSince1970];
        if (score > bestScore || (score == bestScore && (stamp > bestTime || (stamp == bestTime && [root compare:best] == NSOrderedAscending)))) {
            best = root; bestScore = score; bestTime = stamp;
        }
    }
    return best ?: @"";
}

// The real /var/mobile/Library/Preferences must never hold Twin preferences.
static inline BOOL TWPrefsPathIsSafe(NSString *path) {
    if (![path.lastPathComponent isEqualToString:@"com.niubiprass.twin.plist"]) return NO;
    NSString *resolved = path.stringByResolvingSymlinksInPath;
    for (NSString *real in @[@"/var/mobile/Library/Preferences", @"/private/var/mobile/Library/Preferences"]) {
        if ([resolved hasPrefix:[real stringByAppendingString:@"/"]]) return NO;
    }
    for (NSString *root in TWJBRootCandidates()) {
        NSString *base = root.stringByResolvingSymlinksInPath;
        if (base.length > 1 && [resolved hasPrefix:[base stringByAppendingString:@"/"]]) return YES;
    }
    return NO;
}

static inline NSString *TWPrefsFilePath(void) {
    NSString *base = TWJBRootPath();
    if (!base.length) return nil;
    NSString *path = [base stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.niubiprass.twin.plist"];
    return TWPrefsPathIsSafe(path) ? path : nil;
}

#define TWPrefsChangedNotification "com.niubiprass.twin/preferences-changed"

#define TWKeyEnabled          @"TWEnabled"
#define TWKeyArcEnabled       @"TWArcEnabled"
#define TWKeyArcSide          @"TWArcSide"          // 0 left, 1 right
#define TWKeyArcTriggerWidth  @"TWArcTriggerWidth"  // points
#define TWKeyArcItemCount     @"TWArcItemCount"     // icons per menu
#define TWKeyArcRadius        @"TWArcRadius"        // points
#define TWKeyArcSound         @"TWArcSoundEnabled"
// 弧形覆盖窗口的层级优先级（Arc-X 同名概念）：0～2200，默认 46。
// 生效层级 = UIWindowLevelAlert - 2 + 该值（即 1998..4198）。
#define TWKeyArcWindowPriority @"TWArcWindowPriority"
#define TWArcPriorityDefault  46
#define TWArcPriorityMax      2200
#define TWKeyCraneEnabled     @"TWCraneEnabled"
#define TWKeyCraneApps        @"TWCraneApps"        // NSDictionary { bundleID : containerID }
#define TWKeyRememberSize     @"TWRememberSize"     // BOOL, default YES
#define TWKeyRememberFrames   @"TWRememberFrames"   // dict { bundleID : {x,y,w,h} }