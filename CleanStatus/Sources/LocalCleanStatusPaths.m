#import "LocalCleanStatusPaths.h"
#import <roothide.h>

static NSString * const local_cleanstatus_mobileSuffix = @"/var/mobile";

static BOOL local_cleanstatus_isHiddenRoot(NSString *candidate) {
    if (!candidate.length) return NO;
    struct stat st;
    if (lstat(candidate.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) return NO;
    NSString *root = candidate.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    NSString *base = local_cleanstatus_appGroupDirectory.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    NSString *name = root.lastPathComponent;
    return [name hasPrefix:@".jbroot-"] && name.length > @".jbroot-".length &&
        [root.stringByDeletingLastPathComponent isEqualToString:base];
}

static NSString *local_cleanstatus_mappedRoot(void) {
    NSString *mobileHome = jbroot(@"/var/mobile").stringByStandardizingPath;
    if (![mobileHome hasSuffix:local_cleanstatus_mobileSuffix] ||
        mobileHome.length <= local_cleanstatus_mobileSuffix.length) return nil;
    NSString *candidate = [mobileHome substringToIndex:mobileHome.length-local_cleanstatus_mobileSuffix.length];
    return local_cleanstatus_isHiddenRoot(candidate) ? candidate.stringByResolvingSymlinksInPath.stringByStandardizingPath : nil;
}

static NSInteger local_cleanstatus_rootScore(NSString *root) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"Library/MobileSubstrate/DynamicLibraries/LocalCleanStatus.dylib"]] ||
        [fm fileExistsAtPath:[root stringByAppendingPathComponent:@"var/mobile/Library/MobileSubstrate/DynamicLibraries/LocalCleanStatus.dylib"]]) return 3;
    if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"Library/MobileSubstrate"]] ||
        [fm fileExistsAtPath:[root stringByAppendingPathComponent:@"var/mobile/Library/MobileSubstrate"]]) return 2;
    if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"usr/lib"]]) return 1;
    return 0;
}

static NSString *local_cleanstatus_scannedRoot(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:local_cleanstatus_appGroupDirectory error:nil];
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    for (NSString *name in names) {
        if (![name hasPrefix:@".jbroot-"]) continue;
        NSString *candidate = [local_cleanstatus_appGroupDirectory stringByAppendingPathComponent:name];
        if (!local_cleanstatus_isHiddenRoot(candidate)) continue;
        NSString *root = candidate.stringByResolvingSymlinksInPath.stringByStandardizingPath;
        NSInteger score = local_cleanstatus_rootScore(root);
        if (score <= 0) continue;
        NSDate *date = [fm attributesOfItemAtPath:root error:nil][NSFileModificationDate] ?: NSDate.distantPast;
        [candidates addObject:@{ @"root": root, @"score": @(score), @"date": date }];
    }
    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger sa = [a[@"score"] integerValue], sb = [b[@"score"] integerValue];
        if (sa != sb) return sa > sb ? NSOrderedAscending : NSOrderedDescending;
        return [b[@"date"] compare:a[@"date"]];
    }];
    return candidates.firstObject[@"root"];
}

NSString *local_cleanstatus_selectedRoot(void) {
    static NSString *selected;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        selected = [local_cleanstatus_mappedRoot() copy];
        if (selected) return;
        selected = [local_cleanstatus_scannedRoot() copy];
        if (selected) return;
        struct stat st; // Legacy rootless fallback only when no hidden root exists.
        if (lstat("/var/jb", &st) == 0 && S_ISDIR(st.st_mode)) selected = @"/var/jb";
    });
    return selected;
}
