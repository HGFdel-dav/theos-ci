#import "LocalCleanStatusAnimationPreferences.h"
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#include <sys/stat.h>
#include <unistd.h>

NSString * const LCSAnimationPreferencesChanged = @"com.local.cleanstatus.animations-changed";
static NSString * const LCSAGroupDirectory = @"/var/mobile/Containers/Shared/AppGroup";
static NSString * const LCSARelativeFile = @"var/mobile/Library/Preferences/com.local.cleanstatus.animations.plist";

static BOOL LCSAHiddenRoot(NSString *root) {
    NSString *standard = root.stringByStandardizingPath;
    NSString *parent = standard.stringByDeletingLastPathComponent;
    return [parent isEqualToString:LCSAGroupDirectory] &&
        [standard.lastPathComponent hasPrefix:@".jbroot-"] && standard.lastPathComponent.length > 8;
}
static int LCSARootRank(NSString *root) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *prefix in @[@"", @".jbroot"]) {
        NSString *base = prefix.length ? [root stringByAppendingPathComponent:prefix] : root;
        for (NSString *relative in @[@"Library/MobileSubstrate/DynamicLibraries/LocalCleanStatusAnimations.dylib",
                                      @"usr/lib/TweakInject/LocalCleanStatusAnimations.dylib"])
            if ([fm fileExistsAtPath:[base stringByAppendingPathComponent:relative]]) return 3;
    }
    for (NSString *prefix in @[@"", @".jbroot"]) {
        NSString *base = prefix.length ? [root stringByAppendingPathComponent:prefix] : root;
        BOOL directory = NO;
        if ([fm fileExistsAtPath:[base stringByAppendingPathComponent:@"Library/MobileSubstrate"] isDirectory:&directory] && directory) return 2;
    }
    for (NSString *prefix in @[@"", @".jbroot"]) {
        NSString *base = prefix.length ? [root stringByAppendingPathComponent:prefix] : root;
        BOOL directory = NO;
        if ([fm fileExistsAtPath:[base stringByAppendingPathComponent:@"usr/lib"] isDirectory:&directory] && directory) return 1;
    }
    return 0;
}
static NSString *LCSARootFromImage(void) {
    Dl_info info = {0};
    if (!dladdr((const void *)LCSARootFromImage, &info) || !info.dli_fname) return nil;
    NSString *image = [NSString stringWithUTF8String:info.dli_fname];
    for (NSString *path = image.stringByDeletingLastPathComponent; path.length > 1; path = path.stringByDeletingLastPathComponent)
        if (LCSAHiddenRoot(path)) return path;
    return nil;
}
static NSString *LCSASelectedRoot(void) {
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        NSString *imageRoot = LCSARootFromImage();
        if (imageRoot) [candidates addObject:imageRoot];
        for (NSString *name in [fm contentsOfDirectoryAtPath:LCSAGroupDirectory error:NULL]) {
            NSString *candidate = [LCSAGroupDirectory stringByAppendingPathComponent:name];
            if (!LCSAHiddenRoot(candidate)) continue;
            struct stat st;
            if (lstat(candidate.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode) && ![candidates containsObject:candidate])
                [candidates addObject:candidate];
        }
        int bestRank = 0;
        NSTimeInterval newest = -1;
        for (NSString *candidate in candidates) {
            int rank = LCSARootRank(candidate);
            NSDate *date = [fm attributesOfItemAtPath:candidate error:NULL][NSFileModificationDate];
            NSTimeInterval stamp = date.timeIntervalSince1970;
            if (rank > bestRank || (rank == bestRank && rank > 0 && stamp > newest)) {
                root = candidate; bestRank = rank; newest = stamp;
            }
        }
        // Rootless is a fallback only when no hidden roots exist at all.
        BOOL directory = NO;
        if (!root && candidates.count == 0 &&
            [fm fileExistsAtPath:@"/var/jb/usr/lib" isDirectory:&directory] && directory) root = @"/var/jb";
    });
    return root;
}
NSString *local_cleanstatus_animationPreferencesPath(void) {
    NSString *root = LCSASelectedRoot();
    return root.length ? [root stringByAppendingPathComponent:LCSARelativeFile] : nil;
}
NSDictionary *local_cleanstatus_sanitizedAnimationPreferences(NSDictionary *values) {
    if (![values isKindOfClass:NSDictionary.class]) values = @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < LCS_ANIMATION_BOOL_COUNT; ++i) {
        const LCSAnimationBoolSetting setting = lcsAnimationBoolSettings[i];
        NSString *key = [NSString stringWithUTF8String:setting.key];
        id value = values[key];
        result[key] = @([value isKindOfClass:NSNumber.class] ? [value boolValue] : setting.fallback);
    }
    for (NSUInteger i = 0; i < LCS_ANIMATION_NUMBER_COUNT; ++i) {
        const LCSAnimationNumberSetting setting = lcsAnimationNumberSettings[i];
        NSString *key = [NSString stringWithUTF8String:setting.key];
        id value = values[key];
        BOOL number = [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID();
        result[key] = @(number ? local_cleanstatus_animationNumber([value doubleValue], &setting) : setting.fallback);
    }
    return [result copy];
}
NSDictionary *local_cleanstatus_animationDefaults(void) {
    return local_cleanstatus_sanitizedAnimationPreferences(@{});
}
NSDictionary *local_cleanstatus_readAnimationPreferences(void) {
    NSString *path = local_cleanstatus_animationPreferencesPath();
    struct stat st;
    if (!path.length || lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode) ||
        st.st_nlink != 1 || st.st_size <= 0 || st.st_size > 65536) return local_cleanstatus_animationDefaults();
    NSData *data = [NSData dataWithContentsOfFile:path];
    id values = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL] : nil;
    return local_cleanstatus_sanitizedAnimationPreferences(values);
}
static NSError *LCSAStoreError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.local.cleanstatus.animations" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
BOOL local_cleanstatus_writeAnimationPreferences(NSDictionary *values, NSError **error) {
    NSString *root = LCSASelectedRoot();
    NSString *path = local_cleanstatus_animationPreferencesPath();
    if (!path.length || (!LCSAHiddenRoot(root) && ![root isEqualToString:@"/var/jb"])) {
        if (error) *error = LCSAStoreError(1, @"未找到动画模块的有效隐根，设置未保存。");
        return NO;
    }
    // Keep the physical AppGroup-root spelling. RootHide may redirect var via a
    // symlink; resolving it into real var would discard the required namespace.
    struct stat rootStat, targetStat;
    if (lstat(root.fileSystemRepresentation, &rootStat) != 0 || !S_ISDIR(rootStat.st_mode)) {
        if (error) *error = LCSAStoreError(2, @"隐根已变化，请重新进入设置。");
        return NO;
    }
    if (lstat(path.fileSystemRepresentation, &targetStat) == 0 &&
        (!S_ISREG(targetStat.st_mode) || targetStat.st_nlink != 1)) {
        if (error) *error = LCSAStoreError(3, @"动画设置目标不是普通文件，未覆盖。");
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    struct stat recheck;
    if (lstat(root.fileSystemRepresentation, &recheck) != 0 || recheck.st_dev != rootStat.st_dev || recheck.st_ino != rootStat.st_ino) {
        if (error) *error = LCSAStoreError(4, @"隐根已变化，设置未保存。");
        return NO;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:local_cleanstatus_sanitizedAnimationPreferences(values)
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    // Verify the bytes before publishing a change notification.
    if (![[NSData dataWithContentsOfFile:path] isEqualToData:data]) {
        if (error) *error = LCSAStoreError(5, @"动画设置写入后校验失败，请重试。");
        return NO;
    }
    return YES;
}
#include "LCSAAnimationMigration.h"

void local_cleanstatus_notifyAnimationsApplied(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)LCSAnimationPreferencesChanged, NULL, NULL, true);
}
