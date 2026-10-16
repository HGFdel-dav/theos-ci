// PXPPrefs.m
#import "PXPPrefs.h"
#import <UIKit/UIKit.h>
#import <notify.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>

static BOOL PXPValidMigration(NSDictionary *dict) {
    if (![dict isKindOfClass:NSDictionary.class] || !dict.count) return NO;
    NSSet *numbers = [NSSet setWithArray:@[PXPKeyEnabled,PXPKeyArcEnabled,PXPKeyArcSide,PXPKeyArcTriggerWidth,PXPKeyArcItemCount,PXPKeyArcRadius,PXPKeyArcSound,PXPKeyCraneEnabled]];
    for (id key in dict) {
        id value = dict[key];
        if ([numbers containsObject:key]) { if (![value isKindOfClass:NSNumber.class]) return NO; }
        else if ([key isEqual:PXPKeyCraneApps]) {
            if (![value isKindOfClass:NSDictionary.class]) return NO;
            for (id app in value) if (![app isKindOfClass:NSString.class] || ![app length] || ![value[app] isKindOfClass:NSString.class] || ![value[app] length]) return NO;
        } else return NO;
    }
    return YES;
}

// Target must be safe both before and after creating its parent (symlink guard).
static int PXPLockPrefs(NSString *path) {
    if (!PXPPrefsPathIsSafe(path)) return -1;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil] || !PXPPrefsPathIsSafe(path)) return -1;
    int fd = open([[path stringByAppendingString:@".lock"] fileSystemRepresentation], O_CREAT|O_RDWR|O_NOFOLLOW, 0600);
    if (fd >= 0 && flock(fd, LOCK_EX|LOCK_NB) != 0) { close(fd); return -1; }
    return fd;
}

static void PXPMigratePrefs(NSString *target) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!target.length || [fm fileExistsAtPath:target]) return;
    int fd = PXPLockPrefs(target); if (fd < 0) return;
    if (![fm fileExistsAtPath:target]) {
        NSMutableArray *sources = [NSMutableArray array];
        for (NSString *root in PXPJBRootCandidates()) [sources addObject:[root stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.niubiprass.parax.plist"]];
        [sources addObject:@"/var/mobile/Library/Preferences/com.niubiprass.parax.plist"];
        [sources sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSDate *ad = [[fm attributesOfItemAtPath:a error:nil] fileModificationDate] ?: NSDate.distantPast;
            NSDate *bd = [[fm attributesOfItemAtPath:b error:nil] fileModificationDate] ?: NSDate.distantPast;
            return [bd compare:ad];
        }];
        for (NSString *source in sources) {
            if ([source.stringByResolvingSymlinksInPath isEqual:target.stringByResolvingSymlinksInPath]) continue;
            if (![[[fm attributesOfItemAtPath:source error:nil] fileType] isEqual:NSFileTypeRegular]) continue;
            NSData *original = [NSData dataWithContentsOfFile:source];
            NSDictionary *dict = original ? [NSPropertyListSerialization propertyListWithData:original options:NSPropertyListImmutable format:NULL error:nil] : nil;
            if (!PXPValidMigration(dict)) continue;
            if (PXPPrefsPathIsSafe(target) && [dict writeToFile:target atomically:YES] && [[NSDictionary dictionaryWithContentsOfFile:target] isEqual:dict]) {
                // Remove ONLY this exact same-domain, unchanged validated source.
                if ([[NSData dataWithContentsOfFile:source] isEqual:original]) [fm removeItemAtPath:source error:nil];
            }
            break;
        }
    }
    flock(fd, LOCK_UN); close(fd);
}

@implementation PXPPrefs {
    NSMutableDictionary *_cache;
    NSMutableSet *_pendingKeys;
    int _notifyToken;
}

+ (instancetype)shared {
    static PXPPrefs *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _cache = [NSMutableDictionary dictionary];
        _pendingKeys = [NSMutableSet set];
        _notifyToken = -1;
        __weak PXPPrefs *weakSelf = self;
        notify_register_dispatch(PXPPrefsChangedNotification, &_notifyToken, dispatch_get_main_queue(), ^(int token) { [weakSelf reload]; });
        [self reload];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload) name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    if (_notifyToken >= 0) notify_cancel(_notifyToken);
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reload {
    @synchronized (self) {
        NSString *path = PXPPrefsFilePath();
        PXPMigratePrefs(path);
        NSMutableDictionary *disk = path ? [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy] : nil;
        if (!disk) disk = [NSMutableDictionary dictionary];
        for (NSString *key in _pendingKeys) {
            if (_cache[key]) disk[key] = _cache[key]; else [disk removeObjectForKey:key];
        }
        _cache = disk;
    }
}

- (id)objectForKey:(NSString *)key {
    if (!key.length) return nil;
    [self reload]; // Also handles missed Darwin notifications and rotated jbroot.
    @synchronized (self) { return [_cache[key] copy]; }
}

- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)def {
    id v = [self objectForKey:key];
    return ([v isKindOfClass:NSNumber.class] || [v isKindOfClass:NSString.class]) ? [v boolValue] : def;
}

- (NSInteger)integerForKey:(NSString *)key defaultValue:(NSInteger)def {
    id v = [self objectForKey:key];
    return ([v isKindOfClass:NSNumber.class] || [v isKindOfClass:NSString.class]) ? [v integerValue] : def;
}

- (CGFloat)floatForKey:(NSString *)key defaultValue:(CGFloat)def {
    id v = [self objectForKey:key];
    return ([v isKindOfClass:NSNumber.class] || [v isKindOfClass:NSString.class]) ? [v floatValue] : def;
}

- (void)setObject:(id)obj forKey:(NSString *)key {
    if (![key isKindOfClass:NSString.class] || !key.length) return;
    if (obj && ![NSPropertyListSerialization propertyList:obj isValidForFormat:NSPropertyListBinaryFormat_v1_0]) return;
    @synchronized (self) {
        if (obj) _cache[key] = [obj copy]; else [_cache removeObjectForKey:key];
        [_pendingKeys addObject:key];
    }
}

- (void)setBool:(BOOL)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setInteger:(NSInteger)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setFloat:(CGFloat)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }

- (void)synchronize {
    @synchronized (self) {
        if (!_pendingKeys.count) return;
        NSString *path = PXPPrefsFilePath(); int fd = PXPLockPrefs(path);
        if (fd < 0) { NSLog(@"[ParaX] Preferences not saved: unavailable, unsafe or busy root; pending edits retained."); return; }
        NSMutableDictionary *merged = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy] ?: [NSMutableDictionary dictionary];
        for (NSString *key in _pendingKeys) {
            if (_cache[key]) merged[key] = _cache[key]; else [merged removeObjectForKey:key];
        }
        BOOL ok = PXPPrefsPathIsSafe(path) && [merged writeToFile:path atomically:YES] && [[NSDictionary dictionaryWithContentsOfFile:path] isEqual:merged];
        if (ok) { _cache = merged; [_pendingKeys removeAllObjects]; }
        flock(fd, LOCK_UN); close(fd);
        if (ok) notify_post(PXPPrefsChangedNotification);
        else NSLog(@"[ParaX] Preferences write failed; pending edits retained.");
    }
}

- (NSDictionary<NSString *,NSString *> *)craneApps {
    id v = [self objectForKey:PXPKeyCraneApps];
    if ([v isKindOfClass:[NSDictionary class]]) return v;
    return @{};
}

- (void)setCraneApp:(NSString *)containerID forBundleID:(NSString *)bundleID {
    NSMutableDictionary *apps = [self craneApps].mutableCopy;
    NSString *trimmed = [containerID stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length) apps[bundleID] = trimmed; else [apps removeObjectForKey:bundleID];
    [self setObject:apps forKey:PXPKeyCraneApps];
    [self synchronize];
}

- (void)removeCraneAppForBundleID:(NSString *)bundleID {
    NSMutableDictionary *apps = [self craneApps].mutableCopy;
    [apps removeObjectForKey:bundleID];
    [self setObject:apps forKey:PXPKeyCraneApps];
    [self synchronize];
}

@end