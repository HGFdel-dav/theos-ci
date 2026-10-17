// PXPPath.h — shared jbroot path resolution (RootHide / rootless compatible)
// Used by both the SpringBoard tweak and the Settings bundle.
#import <Foundation/Foundation.h>
#import <dlfcn.h>

// Deliberately not dispatch_once: RootHide roots can rotate during this process.
static inline NSArray<NSString *> *PXPJBRootCandidates(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *group = @"/var/mobile/Containers/Shared/AppGroup";
    NSMutableArray *roots = [NSMutableArray array];
    for (NSString *name in [fm contentsOfDirectoryAtPath:group error:nil]) {
        if (![name hasPrefix:@".jbroot-"]) continue;
        NSString *path = [group stringByAppendingPathComponent:name];
        BOOL directory = NO;
        if ([fm fileExistsAtPath:path isDirectory:&directory] && directory) [roots addObject:path];
    }
    BOOL directory = NO;
    if ([fm fileExistsAtPath:@"/var/jb" isDirectory:&directory] && directory) [roots addObject:@"/var/jb"];
    return roots;
}

static inline NSString *PXPJBRootPath(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    Dl_info image = {0};
    dladdr((const void *)&PXPJBRootPath, &image);
    NSString *own = image.dli_fname ? [[NSString stringWithUTF8String:image.dli_fname] stringByResolvingSymlinksInPath] : @"";
    NSString *best = nil; NSInteger bestScore = -1; NSTimeInterval bestTime = -1;
    for (NSString *root in PXPJBRootCandidates()) {
        NSString *resolved = root.stringByResolvingSymlinksInPath;
        if (!resolved.length || [resolved isEqualToString:@"/"]) continue;
        NSString *ms = [root stringByAppendingPathComponent:@"Library/MobileSubstrate/DynamicLibraries/ParaX.dylib"];
        NSString *usr = [root stringByAppendingPathComponent:@"usr/lib/ParaX.dylib"];
        BOOL hasMS = [fm fileExistsAtPath:ms], hasUsr = [fm fileExistsAtPath:usr];
        NSInteger score = hasMS ? 2000 : (hasUsr ? 1000 : 0);
        if ([own hasPrefix:[resolved stringByAppendingString:@"/"]]) score += 10000;
        if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"Library/MobileSubstrate"]]) score += 20;
        else if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"usr/lib"]]) score += 10;
        if (!score) continue;
        NSString *stampPath = hasMS ? ms : (hasUsr ? usr : root);
        NSTimeInterval stamp = [[[fm attributesOfItemAtPath:stampPath error:nil] fileModificationDate] timeIntervalSince1970];
        if (score > bestScore || (score == bestScore && (stamp > bestTime || (stamp == bestTime && [root compare:best] == NSOrderedAscending)))) {
            best = root; bestScore = score; bestTime = stamp;
        }
    }
    return best ?: @"";
}

static inline BOOL PXPPrefsPathIsSafe(NSString *path) {
    if (![path.lastPathComponent isEqualToString:@"com.niubiprass.parax.plist"]) return NO;
    NSString *resolved = path.stringByResolvingSymlinksInPath;
    for (NSString *real in @[@"/var/mobile/Library/Preferences", @"/private/var/mobile/Library/Preferences"]) {
        if ([resolved hasPrefix:[real stringByAppendingString:@"/"]]) return NO;
    }
    for (NSString *root in PXPJBRootCandidates()) {
        NSString *base = root.stringByResolvingSymlinksInPath;
        if (base.length > 1 && [resolved hasPrefix:[base stringByAppendingString:@"/"]]) return YES;
    }
    return NO;
}

static inline NSString *PXPPrefsFilePath(void) {
    NSString *base = PXPJBRootPath();
    if (!base.length) return nil;
    NSString *path = [base stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.niubiprass.parax.plist"];
    return PXPPrefsPathIsSafe(path) ? path : nil;
}

#define PXPPrefsChangedNotification "com.niubiprass.parax/preferences-changed"

#define PXPKeyEnabled          @"PXPEnabled"
#define PXPKeyArcEnabled       @"PXPArcEnabled"
#define PXPKeyArcSide          @"PXPArcSide"          // 0 left, 1 right
#define PXPKeyArcTriggerWidth  @"PXPArcTriggerWidth"  // points
#define PXPKeyArcItemCount     @"PXPArcItemCount"     // icons per menu
#define PXPKeyArcRadius        @"PXPArcRadius"        // points
#define PXPKeyArcSound         @"PXPArcSoundEnabled"
#define PXPKeyCraneEnabled     @"PXPCraneEnabled"
#define PXPKeyCraneApps        @"PXPCraneApps"        // NSDictionary { bundleID : containerID }
#define PXPKeyRememberSize     @"PXPRememberSize"     // BOOL, default YES
#define PXPKeyRememberFrames   @"PXPRememberFrames"   // dict { bundleID : {x,y,w,h} }