#import "MiniSightPreferences.h"

static NSString *const kMSRootBase = @"/var/mobile/Containers/Shared/AppGroup";
static NSString *const kMSPreferenceFile = @"com.niubiprass.minisight.plist";
static NSString *const kMSLegacyDomainFile = @"com.apple.springboard.plist";
static NSString *MSCachedRoot;
static NSMutableSet<NSString *> *MSMigratedRoots;
static NSArray<NSString *> *MSOwnedKeys(void) {
    return @[@"MiniSightCenterX", @"MiniSightCenterY", @"MiniSightUserHidden"];
}

static NSObject *MSPreferenceLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static NSDate *MSModificationDate(NSString *path) {
    return [[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] objectForKey:NSFileModificationDate] ?: NSDate.distantPast;
}

static NSString *MSActiveRoot(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (MSCachedRoot.length && [fm fileExistsAtPath:MSCachedRoot]) return MSCachedRoot;
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:kMSRootBase error:nil];
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    for (NSString *name in names) {
        if (![name hasPrefix:@".jbroot-"]) continue;
        NSString *root = [kMSRootBase stringByAppendingPathComponent:name];
        NSString *dylibAtRoot = [root stringByAppendingPathComponent:@"Library/MobileSubstrate/DynamicLibraries/MiniSight.dylib"];
        NSString *dylibUnderVar = [root stringByAppendingPathComponent:@"var/mobile/Library/MobileSubstrate/DynamicLibraries/MiniSight.dylib"];
        NSString *substrateAtRoot = [root stringByAppendingPathComponent:@"Library/MobileSubstrate"];
        NSString *substrateUnderVar = [root stringByAppendingPathComponent:@"var/mobile/Library/MobileSubstrate"];
        NSString *usr = [root stringByAppendingPathComponent:@"usr/lib"];
        NSInteger score = ([fm fileExistsAtPath:dylibAtRoot] || [fm fileExistsAtPath:dylibUnderVar]) ? 3 :
            (([fm fileExistsAtPath:substrateAtRoot] || [fm fileExistsAtPath:substrateUnderVar]) ? 2 :
             ([fm fileExistsAtPath:usr] ? 1 : 0));
        if (!score) continue;
        [candidates addObject:@{@"root":root, @"score":@(score), @"date":MSModificationDate(root)}];
    }
    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger sa = [a[@"score"] integerValue], sb = [b[@"score"] integerValue];
        if (sa != sb) return sa > sb ? NSOrderedAscending : NSOrderedDescending;
        return [b[@"date"] compare:a[@"date"]];
    }];
    MSCachedRoot = candidates.firstObject[@"root"];
    return MSCachedRoot;
}

static NSDictionary *MSReadPlist(NSString *path) {
    NSDictionary *value = [NSDictionary dictionaryWithContentsOfFile:path];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static BOOL MSWritePlist(NSDictionary *value, NSString *path) {
    NSString *parent = path.stringByDeletingLastPathComponent;
    NSDictionary *directoryAttributes = @{
        NSFileOwnerAccountName:@"mobile",
        NSFileGroupOwnerAccountName:@"mobile",
        NSFilePosixPermissions:@0755
    };
    if (![NSFileManager.defaultManager createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:directoryAttributes error:nil]) return NO;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:nil]) return NO;
    NSDictionary *fileAttributes = @{
        NSFileOwnerAccountName:@"mobile",
        NSFileGroupOwnerAccountName:@"mobile",
        NSFilePosixPermissions:@0600
    };
    [NSFileManager.defaultManager setAttributes:fileAttributes ofItemAtPath:path error:nil];
    return YES;
}

static NSString *MSLegacySpringBoardPath(NSString *root) {
    return [root stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.apple.springboard.plist"];
}

static NSString *MSRootPreferencesPath(NSString *root) {
    return [root stringByAppendingPathComponent:@"var/mobile/Library/Preferences"];
}

static BOOL MSMigrateAndCleanup(NSString *targetPath, NSString *activeRoot) {
    if (!activeRoot.length) return NO;
    if (!MSMigratedRoots) MSMigratedRoots = [NSMutableSet set];
    if ([MSMigratedRoots containsObject:activeRoot]) return YES;

    NSArray<NSString *> *roots = [NSFileManager.defaultManager contentsOfDirectoryAtPath:kMSRootBase error:nil] ?: @[];
    NSMutableArray<NSString *> *sources = [NSMutableArray arrayWithObjects:
        @"/var/mobile/Library/Preferences/com.apple.springboard.plist",
        @"/var/mobile/Library/Preferences/com.niubiprass.minisight.plist",
        @"/var/jb/var/mobile/Library/Preferences/com.apple.springboard.plist",
        @"/var/jb/var/mobile/Library/Preferences/com.niubiprass.minisight.plist", nil];
    [sources addObject:targetPath];
    for (NSString *name in roots) {
        if (![name hasPrefix:@".jbroot-"]) continue;
        NSString *root = [kMSRootBase stringByAppendingPathComponent:name];
        [sources addObject:MSLegacySpringBoardPath(root)];
        [sources addObject:[MSRootPreferencesPath(root) stringByAppendingPathComponent:kMSPreferenceFile]];
    }

    NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:MSReadPlist(targetPath) ?: @{}];
    for (NSString *key in MSOwnedKeys()) {
        NSString *bestPath = nil;
        NSDate *bestDate = NSDate.distantPast;
        id bestValue = nil;
        for (NSString *path in sources) {
            NSDictionary *plist = MSReadPlist(path);
            id value = plist[key];
            NSDate *date = MSModificationDate(path);
            if (value && [date compare:bestDate] == NSOrderedDescending) {
                bestPath = path; bestDate = date; bestValue = value;
            }
        }
        if (!bestValue) {
            bestValue = [NSUserDefaults.standardUserDefaults objectForKey:key];
        }
        if (bestValue) merged[key] = bestValue;
        (void)bestPath;
    }

    // Persist and verify before removing any legacy values. Preserve unrelated
    // SpringBoard keys; only MiniSight-owned keys are removed from its old domain.
    if (!MSWritePlist(merged, targetPath)) return NO;
    NSDictionary *verified = MSReadPlist(targetPath);
    if (![verified isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in MSOwnedKeys()) {
        id expected = merged[key];
        if (expected && ![verified[key] isEqual:expected]) return NO;
    }

    for (NSString *path in sources) {
        if ([path isEqualToString:targetPath]) continue;
        if ([path.lastPathComponent isEqualToString:kMSLegacyDomainFile]) {
            NSMutableDictionary *legacy = [NSMutableDictionary dictionaryWithDictionary:MSReadPlist(path) ?: @{}];
            BOOL changed = NO;
            for (NSString *key in MSOwnedKeys()) {
                if (legacy[key]) { [legacy removeObjectForKey:key]; changed = YES; }
            }
            if (changed) MSWritePlist(legacy, path);
        } else if ([path.lastPathComponent isEqualToString:kMSPreferenceFile]) {
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        }
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in MSOwnedKeys()) [defaults removeObjectForKey:key];
    [defaults synchronize];
    [MSMigratedRoots addObject:activeRoot];
    return YES;
}

id MSMiniSightPreference(NSString *key) {
    if (![MSOwnedKeys() containsObject:key]) return nil;
    @synchronized (MSPreferenceLock()) {
        NSString *root = MSActiveRoot();
        if (!root) return [NSUserDefaults.standardUserDefaults objectForKey:key]; // Rootless keeps legacy behavior.
        NSString *target = [MSRootPreferencesPath(root) stringByAppendingPathComponent:kMSPreferenceFile];
        MSMigrateAndCleanup(target, root);
        return MSReadPlist(target)[key];
    }
}

void MSMiniSightSetPreference(NSString *key, id value) {
    if (![MSOwnedKeys() containsObject:key] || !value) return;
    @synchronized (MSPreferenceLock()) {
        NSString *root = MSActiveRoot();
        if (!root) { [NSUserDefaults.standardUserDefaults setObject:value forKey:key]; return; }
        NSString *target = [MSRootPreferencesPath(root) stringByAppendingPathComponent:kMSPreferenceFile];
        MSMigrateAndCleanup(target, root);
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:MSReadPlist(target) ?: @{}];
        dict[key] = value;
        MSWritePlist(dict, target);
    }
}

void MSMiniSightRemovePreference(NSString *key) {
    if (![MSOwnedKeys() containsObject:key]) return;
    @synchronized (MSPreferenceLock()) {
        NSString *root = MSActiveRoot();
        if (!root) { [NSUserDefaults.standardUserDefaults removeObjectForKey:key]; return; }
        NSString *target = [MSRootPreferencesPath(root) stringByAppendingPathComponent:kMSPreferenceFile];
        MSMigrateAndCleanup(target, root);
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:MSReadPlist(target) ?: @{}];
        [dict removeObjectForKey:key];
        MSWritePlist(dict, target);
    }
}
