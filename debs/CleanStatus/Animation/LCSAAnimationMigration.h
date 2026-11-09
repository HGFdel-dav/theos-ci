#pragma once
// Included by the animation store only. The old CleanStatus configuration is
// neither read nor removed; only the new animation filename is considered.
static NSDictionary *LCSAReadAnimationFile(NSString *path) {
    struct stat st;
    if (!path.length || lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode) ||
        st.st_nlink != 1 || st.st_size <= 0 || st.st_size > 65536) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    id values = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL] : nil;
    return [values isKindOfClass:NSDictionary.class] ? values : nil;
}
BOOL local_cleanstatus_migrateAnimationPreferences(NSError **error) {
    NSString *target = local_cleanstatus_animationPreferencesPath();
    if (!target.length) {
        if (error) *error = LCSAStoreError(6, @"未找到动画配置的有效隐根，保留所有原文件。");
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithObject:target];
    BOOL hasHiddenRoots = NO;
    for (NSString *name in [fm contentsOfDirectoryAtPath:LCSAGroupDirectory error:NULL]) {
        NSString *root = [LCSAGroupDirectory stringByAppendingPathComponent:name];
        if (!LCSAHiddenRoot(root)) continue;
        struct stat st;
        if (lstat(root.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) continue;
        hasHiddenRoots = YES;
        NSString *path = [root stringByAppendingPathComponent:LCSARelativeFile];
        if (![paths containsObject:path]) [paths addObject:path];
    }
    if (!hasHiddenRoots) [paths addObject:[@"/var/jb" stringByAppendingPathComponent:LCSARelativeFile]];
    [paths addObject:[@"/" stringByAppendingPathComponent:LCSARelativeFile]];
    NSMutableDictionary<NSString *, NSDictionary *> *snapshots = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *identities = [NSMutableSet set];
    NSString *winner = nil;
    NSDate *newest = NSDate.distantPast;
    for (NSString *path in paths) {
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) != 0) continue;
        NSString *identity = [NSString stringWithFormat:@"%llu:%llu", (unsigned long long)st.st_dev, (unsigned long long)st.st_ino];
        if ([identities containsObject:identity]) continue;
        [identities addObject:identity];
        NSDictionary *values = LCSAReadAnimationFile(path);
        if (!values) continue;
        NSDate *date = [fm attributesOfItemAtPath:path error:NULL][NSFileModificationDate] ?: NSDate.distantPast;
        snapshots[path] = @{ @"values": values, @"date": date, @"identity": identity };
        if (!winner || [date compare:newest] == NSOrderedDescending ||
            ([date compare:newest] == NSOrderedSame && [path isEqualToString:target])) {
            winner = path; newest = date;
        }
    }
    if (!winner) return YES;
    NSDictionary *expected = local_cleanstatus_sanitizedAnimationPreferences(snapshots[winner][@"values"]);
    if (![winner isEqualToString:target] && !local_cleanstatus_writeAnimationPreferences(expected, error)) return NO;
    if (![expected isEqual:local_cleanstatus_sanitizedAnimationPreferences(LCSAReadAnimationFile(target))]) {
        if (error) *error = LCSAStoreError(7, @"动画配置迁移校验失败，旧文件已保留。");
        return NO;
    }
    if (![winner isEqualToString:target]) local_cleanstatus_notifyAnimationsApplied();
    struct stat targetStat;
    if (lstat(target.fileSystemRepresentation, &targetStat) != 0) return NO;
    BOOL success = YES;
    for (NSString *path in snapshots) {
        struct stat st;
        if ([path isEqualToString:target] || lstat(path.fileSystemRepresentation, &st) != 0 ||
            (st.st_dev == targetStat.st_dev && st.st_ino == targetStat.st_ino)) continue;
        NSString *identity = [NSString stringWithFormat:@"%llu:%llu", (unsigned long long)st.st_dev, (unsigned long long)st.st_ino];
        NSDate *date = [fm attributesOfItemAtPath:path error:NULL][NSFileModificationDate];
        if (![identity isEqual:snapshots[path][@"identity"]] || ![date isEqual:snapshots[path][@"date"]] ||
            ![LCSAReadAnimationFile(path) isEqual:snapshots[path][@"values"]]) { success = NO; continue; }
        if (![fm removeItemAtPath:path error:error]) success = NO;
    }
    if (!success && error && !*error) *error = LCSAStoreError(8, @"部分旧动画配置已变化，未删除这些副本。");
    return success;
}
