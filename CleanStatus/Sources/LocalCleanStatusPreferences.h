#pragma once
#import <CoreFoundation/CoreFoundation.h>
#import "LocalCleanStatusPaths.h"
#import "LocalCleanStatusCore.h"

static NSString * const local_cleanstatus_preferencesChangedNotification = @"com.local.cleanstatus.preferences-changed";
static NSString * const local_cleanstatus_toggleLowPowerNotification = @"com.local.cleanstatus.toggle-low-power";

static inline BOOL local_cleanstatus_bool(id value) {
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}
static inline NSDictionary *local_cleanstatus_sanitizedPreferences(NSDictionary *input) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"enabled"] = @(local_cleanstatus_bool(input[@"enabled"]));
    for (NSUInteger i = 0; i < LocalCleanStatusFeatureCount; i++) {
        NSString *key = [NSString stringWithUTF8String:local_cleanstatus_featureNames[i]];
        BOOL fallback = [key isEqualToString:@"hideUnknownParts"];
        result[key] = input[key] ? @(local_cleanstatus_bool(input[key])) : @(fallback);
    }
    return [result copy];
}
static inline NSDictionary *local_cleanstatus_readPreferences(void) {
    return local_cleanstatus_sanitizedPreferences(local_cleanstatus_readDictionary(local_cleanstatus_preferencesPath()) ?: @{});
}

// Only the PreferenceBundle calls these write/migration routines. No NSUserDefaults
// suite mirroring: cfprefsd must not create a second file in real /var/mobile.
static inline BOOL local_cleanstatus_writePreferences(NSDictionary *values, NSError **error) {
    NSString *path = local_cleanstatus_preferencesPath();
    if (!path.length) {
        if (error) *error = local_cleanstatus_error(1, @"未找到有效隐根，已阻止写入真实 var。");
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) == 0 &&
        (!S_ISREG(st.st_mode) || st.st_nlink != 1)) {
        if (error) *error = local_cleanstatus_error(2, @"偏好目标不是普通文件，未写入。");
        return NO;
    }
    if (!local_cleanstatus_pathInsideRoot(path, local_cleanstatus_selectedRoot())) {
        if (error) *error = local_cleanstatus_error(6, @"偏好目录超出选定隐根，已阻止写入。");
        return NO;
    }
    if (![fm createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    if (!local_cleanstatus_pathInsideRoot(path, local_cleanstatus_selectedRoot())) {
        if (error) *error = local_cleanstatus_error(6, @"偏好目录超出选定隐根，已阻止写入。");
        return NO;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:local_cleanstatus_sanitizedPreferences(values)
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    return data && [data writeToFile:path options:NSDataWritingAtomic error:error];
}

static inline NSString *local_cleanstatus_canonicalPreferencePath(NSString *path) {
    if (!path.length) return nil;
    NSString *parent = path.stringByDeletingLastPathComponent.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    return [[parent stringByAppendingPathComponent:path.lastPathComponent] stringByStandardizingPath];
}
static inline BOOL local_cleanstatus_sameFile(NSString *a, NSString *b) {
    struct stat sa, sb;
    return lstat(a.fileSystemRepresentation, &sa) == 0 && lstat(b.fileSystemRepresentation, &sb) == 0 &&
        sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino;
}
static inline BOOL local_cleanstatus_migratePreferences(NSError **error) {
    NSString *target = local_cleanstatus_preferencesPath();
    if (!target) { if (error) *error = local_cleanstatus_error(1, @"未找到偏好路径。"); return NO; }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *roots = [local_cleanstatus_migrationRoots() mutableCopy];
    if (roots.count == 0) [roots addObject:@"/var/jb"]; // Legacy source only when no hidden roots exist.
    [roots addObject:@"/"]; // Real-var is a migration source, never a separate target.
    NSString *targetKey = local_cleanstatus_canonicalPreferencePath(target);
    NSMutableDictionary<NSString *, NSString *> *uniquePaths = [NSMutableDictionary dictionary];
    if (targetKey) uniquePaths[targetKey] = target;
    for (NSString *root in roots) {
        NSString *candidate = [root stringByAppendingPathComponent:local_cleanstatus_preferenceRelative];
        NSString *key = local_cleanstatus_canonicalPreferencePath(candidate);
        if (key.length && ![key isEqualToString:targetKey] &&
            !local_cleanstatus_sameFile(candidate, target) && !uniquePaths[key]) uniquePaths[key] = candidate;
    }
    NSSet *paths = [NSSet setWithArray:uniquePaths.allValues];
    NSMutableDictionary *snapshots = [NSMutableDictionary dictionary];
    NSString *winner = nil; NSDate *newest = NSDate.distantPast;
    for (NSString *path in paths) {
        NSDictionary *values = local_cleanstatus_readDictionary(path);
        if (!values) continue;
        NSDate *date = [fm attributesOfItemAtPath:path error:nil][NSFileModificationDate] ?: NSDate.distantPast;
        snapshots[path] = @{ @"values": values, @"date": date };
        if (!winner || [date compare:newest] == NSOrderedDescending ||
            ([date compare:newest] == NSOrderedSame && [path isEqualToString:target])) {
            newest = date; winner = path;
        }
    }
    if (!winner) return YES;
    if (![winner isEqualToString:target] && !local_cleanstatus_writePreferences(snapshots[winner][@"values"], error)) return NO;
    NSDictionary *verified = local_cleanstatus_readDictionary(target);
    if (!verified || ![local_cleanstatus_sanitizedPreferences(verified) isEqual:local_cleanstatus_sanitizedPreferences(snapshots[winner][@"values"])]) {
        if (error) *error = local_cleanstatus_error(3, @"迁移后校验失败，旧文件已保留。");
        return NO;
    }
    BOOL success = YES;
    for (NSString *path in snapshots) {
        if ([path isEqualToString:target] || local_cleanstatus_sameFile(path, target) ||
            [local_cleanstatus_canonicalPreferencePath(path) isEqualToString:local_cleanstatus_canonicalPreferencePath(target)]) continue;
        NSDictionary *current = local_cleanstatus_readDictionary(path);
        NSDate *date = [fm attributesOfItemAtPath:path error:nil][NSFileModificationDate];
        if (![current isEqual:snapshots[path][@"values"]] || ![date isEqual:snapshots[path][@"date"]]) {
            success = NO; continue; // Changed during migration: never delete it.
        }
        NSError *removeError = nil;
        if (![fm removeItemAtPath:path error:&removeError]) { if (error) *error = removeError; success = NO; }
    }
    if (!success && error && !*error) *error = local_cleanstatus_error(4, @"部分旧偏好变化或无法清理，未删除这些副本。");
    return success;
}

static inline void local_cleanstatus_notifyApplied(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)local_cleanstatus_preferencesChangedNotification, NULL, NULL, true);
}
