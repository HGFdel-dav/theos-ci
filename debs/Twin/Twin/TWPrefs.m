// TWPrefs.m
#import "TWPrefs.h"
#import <UIKit/UIKit.h>
#import <notify.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>

static BOOL TWValidMigration(NSDictionary *dict) {
    if (![dict isKindOfClass:NSDictionary.class] || !dict.count) return NO;
    NSSet *numbers = [NSSet setWithArray:@[TWKeyEnabled,TWKeyArcEnabled,TWKeyArcSide,TWKeyArcTriggerWidth,TWKeyArcItemCount,TWKeyArcRadius,TWKeyArcSound,TWKeyArcWindowPriority,TWKeyCraneEnabled,TWKeyRememberSize,TWKeyWakeMode,TWKeyArcCorners,TWKeyArcCornerSize,TWKeyArcOpenMode,TWKeySideOpenMode]];
    for (id key in dict) {
        id value = dict[key];
        if ([numbers containsObject:key]) { if (![value isKindOfClass:NSNumber.class]) return NO; }
        else if ([key isEqual:TWKeyCraneApps]) {
            if (![value isKindOfClass:NSDictionary.class]) return NO;
            for (id app in value) if (![app isKindOfClass:NSString.class] || ![app length] || ![value[app] isKindOfClass:NSString.class] || ![value[app] length]) return NO;
        } else if ([key isEqual:TWKeyRememberFrames]) {
            // { bundleID : {x,y,w,h} } — all values are NSNumbers, frame inside screen.
            if (![value isKindOfClass:NSDictionary.class]) return NO;
            for (id app in value) {
                id frame = value[app];
                if (![app isKindOfClass:NSString.class] || ![app length] || ![frame isKindOfClass:NSDictionary.class]) return NO;
                NSArray *keys = @[@"x",@"y",@"w",@"h"];
                for (NSString *k in keys) {
                    id num = frame[k];
                    if (![num isKindOfClass:NSNumber.class]) return NO;
                    if ([k isEqual:@"w"] || [k isEqual:@"h"]) { if ([num doubleValue] <= 0 || [num doubleValue] > 5000) return NO; }
                    else { double v = [num doubleValue]; if (v < -5000 || v > 5000) return NO; }
                }
            }
        } else if ([key isEqual:TWKeyCraneAppList]) {
            // NSArray<NSString *>：Arc 里显示哪些应用（有序 bundleID）。
            if (![value isKindOfClass:NSArray.class]) return NO;
            for (id app in value) if (![app isKindOfClass:NSString.class] || ![app length]) return NO;
        } else if ([key isEqual:TWKeyCraneContainers]) {
            // NSArray<NSDictionary *>：每项 {bundleID, containerID?, name?, badge?, enabled?}
            if (![value isKindOfClass:NSArray.class]) return NO;
            for (id entry in value) {
                if (![entry isKindOfClass:NSDictionary.class]) return NO;
                id bundleID = entry[@"bundleID"];
                if (![bundleID isKindOfClass:NSString.class] || ![bundleID length]) return NO;
                for (NSString *k in @[@"containerID", @"name", @"badge"]) {
                    id v = entry[k];
                    if (v && ![v isKindOfClass:NSString.class]) return NO;
                }
                id enabled = entry[@"enabled"];
                if (enabled && ![enabled isKindOfClass:NSNumber.class]) return NO;
            }
        } else if ([key isEqual:TWKeyRememberStates]) {
            // { "bundleID|containerID" : @{p,l,docked,side,updated} } —— 形态快照。
            if (![value isKindOfClass:NSDictionary.class]) return NO;
            for (id entryKey in value) {
                id state = value[entryKey];
                if (![entryKey isKindOfClass:NSString.class] || ![entryKey length]) return NO;
                if (![state isKindOfClass:NSDictionary.class]) return NO;
                for (NSString *orientation in @[@"p", @"l"]) {
                    id frame = state[orientation];
                    if (!frame) continue;
                    if (![frame isKindOfClass:NSDictionary.class]) return NO;
                    for (NSString *k in @[@"x", @"y", @"w", @"h"]) {
                        id num = frame[k];
                        if (![num isKindOfClass:NSNumber.class]) return NO;
                        double v = [num doubleValue];
                        if ([k isEqual:@"w"] || [k isEqual:@"h"]) { if (v <= 0 || v > 5000) return NO; }
                        else if (v < -5000 || v > 5000) return NO;
                    }
                }
                for (NSString *k in @[@"docked", @"side"]) {
                    id v = state[k];
                    if (v && ![v isKindOfClass:NSNumber.class]) return NO;
                }
            }
        } else return NO;
    }
    return YES;
}

// Target must be safe both before and after creating its parent (symlink guard).
static int TWLockPrefs(NSString *path) {
    if (!TWPrefsPathIsSafe(path)) return -1;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil] || !TWPrefsPathIsSafe(path)) return -1;
    int fd = open([[path stringByAppendingString:@".lock"] fileSystemRepresentation], O_CREAT|O_RDWR|O_NOFOLLOW, 0600);
    if (fd >= 0 && flock(fd, LOCK_EX|LOCK_NB) != 0) { close(fd); return -1; }
    return fd;
}

static void TWMigratePrefs(NSString *target) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!target.length || [fm fileExistsAtPath:target]) return;
    int fd = TWLockPrefs(target); if (fd < 0) return;
    if (![fm fileExistsAtPath:target]) {
        NSMutableArray *sources = [NSMutableArray array];
        for (NSString *root in TWJBRootCandidates()) [sources addObject:[root stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.niubiprass.twin.plist"]];
        [sources addObject:@"/var/mobile/Library/Preferences/com.niubiprass.twin.plist"];
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
            if (!TWValidMigration(dict)) continue;
            if (TWPrefsPathIsSafe(target) && [dict writeToFile:target atomically:YES] && [[NSDictionary dictionaryWithContentsOfFile:target] isEqual:dict]) {
                // Remove ONLY this exact same-domain, unchanged validated source.
                if ([[NSData dataWithContentsOfFile:source] isEqual:original]) [fm removeItemAtPath:source error:nil];
            }
            break;
        }
    }
    flock(fd, LOCK_UN); close(fd);
}

@implementation TWPrefs {
    NSMutableDictionary *_cache;
    NSMutableSet *_pendingKeys;
    int _notifyToken;
}

+ (instancetype)shared {
    static TWPrefs *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _cache = [NSMutableDictionary dictionary];
        _pendingKeys = [NSMutableSet set];
        _notifyToken = -1;
        __weak TWPrefs *weakSelf = self;
        notify_register_dispatch(TWPrefsChangedNotification, &_notifyToken, dispatch_get_main_queue(), ^(int token) { [weakSelf reload]; });
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
        NSString *path = TWPrefsFilePath();
        TWMigratePrefs(path);
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
        NSString *path = TWPrefsFilePath(); int fd = TWLockPrefs(path);
        if (fd < 0) { NSLog(@"[Twin] Preferences not saved: unavailable, unsafe or busy root; pending edits retained."); return; }
        NSMutableDictionary *merged = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy] ?: [NSMutableDictionary dictionary];
        for (NSString *key in _pendingKeys) {
            if (_cache[key]) merged[key] = _cache[key]; else [merged removeObjectForKey:key];
        }
        BOOL ok = TWPrefsPathIsSafe(path) && [merged writeToFile:path atomically:YES] && [[NSDictionary dictionaryWithContentsOfFile:path] isEqual:merged];
        if (ok) { _cache = merged; [_pendingKeys removeAllObjects]; }
        flock(fd, LOCK_UN); close(fd);
        if (ok) notify_post(TWPrefsChangedNotification);
        else NSLog(@"[Twin] Preferences write failed; pending edits retained.");
    }
}

- (NSDictionary<NSString *,NSString *> *)craneApps {
    id v = [self objectForKey:TWKeyCraneApps];
    if ([v isKindOfClass:[NSDictionary class]]) return v;
    return @{};
}

- (void)setCraneApp:(NSString *)containerID forBundleID:(NSString *)bundleID {
    NSMutableDictionary *apps = [self craneApps].mutableCopy;
    NSString *trimmed = [containerID stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length) apps[bundleID] = trimmed; else [apps removeObjectForKey:bundleID];
    [self setObject:apps forKey:TWKeyCraneApps];
    [self synchronize];
}

- (void)removeCraneAppForBundleID:(NSString *)bundleID {
    NSMutableDictionary *apps = [self craneApps].mutableCopy;
    [apps removeObjectForKey:bundleID];
    [self setObject:apps forKey:TWKeyCraneApps];
    [self synchronize];
}

#pragma mark - Remembered frames

- (CGRect)rememberedFrameForBundleID:(NSString *)bundleID {
    if (!bundleID.length) return CGRectNull;
    id v = [self objectForKey:TWKeyRememberFrames];
    if (![v isKindOfClass:[NSDictionary class]]) return CGRectNull;
    NSDictionary *frameDict = v[bundleID];
    if (![frameDict isKindOfClass:[NSDictionary class]]) return CGRectNull;
    NSNumber *x = frameDict[@"x"], *y = frameDict[@"y"], *w = frameDict[@"w"], *h = frameDict[@"h"];
    if (![x isKindOfClass:NSNumber.class] || ![y isKindOfClass:NSNumber.class] ||
        ![w isKindOfClass:NSNumber.class] || ![h isKindOfClass:NSNumber.class]) return CGRectNull;
    CGRect frame = CGRectMake(x.doubleValue, y.doubleValue, w.doubleValue, h.doubleValue);
    if (frame.size.width <= 0 || frame.size.height <= 0 ||
        frame.size.width > 5000 || frame.size.height > 5000) return CGRectNull;
    return frame;
}

- (void)setRememberedFrame:(CGRect)frame forBundleID:(NSString *)bundleID {
    if (!bundleID.length || CGRectIsNull(frame) || CGRectIsEmpty(frame)) return;
    NSMutableDictionary *frames = [(id)[self objectForKey:TWKeyRememberFrames] mutableCopy];
    if (!frames) frames = [NSMutableDictionary dictionary];
    frames[bundleID] = @{@"x": @(frame.origin.x), @"y": @(frame.origin.y),
                         @"w": @(frame.size.width), @"h": @(frame.size.height)};
    [self setObject:frames forKey:TWKeyRememberFrames];
    [self synchronize];
}

- (void)clearRememberedFrames {
    [self setObject:nil forKey:TWKeyRememberFrames];
    [self synchronize];
}

@end