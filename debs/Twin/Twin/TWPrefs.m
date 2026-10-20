// TWPrefs.m
//
// 0.9.9：存储改走 CFPreferences（域 com.niubiprass.twin），与 ParallelX 面板
// 完全同一条链路。为什么必须这样：
//   * 直接写文件时，SpringBoard 进程写出来的 plist / 日志在设置进程里看不到，
//     两个进程各拿一份"自己的文件"，设置永远对不上（0.9.8 实机复现）。
//   * PSListController / ParallelX 都是用 cfprefsd 代理读写，跨进程天然一致。
//   * 本机 RootHide 的 .jbroot、/var/jb 都是指向 "/" 的符号链接，不存在
//     "藏在隐根里"这回事，CFPreferences 落点就是 /var/mobile/Library/Preferences，
//     和 ParallelX 自己的 com.moxuan.parallelx.plist 同级。
#import "TWPrefs.h"
#import "TWPath.h"
#import "TWRuntimeLog.h"
#import <UIKit/UIKit.h>
#import <notify.h>
#import <CoreFoundation/CoreFoundation.h>

static NSString *const TWDomain = @"com.niubiprass.twin";
static CFStringRef TWDomainRef(void) { return (__bridge CFStringRef)TWDomain; }

static BOOL TWValidMigration(NSDictionary *dict) {
    if (![dict isKindOfClass:NSDictionary.class] || !dict.count) return NO;
    NSSet *numbers = [NSSet setWithArray:@[TWKeyEnabled,TWKeyArcEnabled,TWKeyArcSide,TWKeyArcTriggerWidth,TWKeyArcItemCount,TWKeyArcRadius,TWKeyArcSound,TWKeyArcWindowPriority,TWKeyCraneEnabled,TWKeyRememberSize,TWKeyWakeMode,TWKeyArcUsePXPanel,TWKeyArcIconSize,TWKeyArcFirstRowCount,TWKeyArcRingGap,TWKeyArcCorners,TWKeyArcCornerSize,TWKeyArcOpenMode,TWKeySideOpenMode]];
    for (id key in dict) {
        id value = dict[key];
        if ([numbers containsObject:key]) { if (![value isKindOfClass:NSNumber.class]) return NO; }
        else if ([key isEqual:TWKeyCraneApps]) {
            if (![value isKindOfClass:NSDictionary.class]) return NO;
            for (id app in value) if (![app isKindOfClass:NSString.class] || ![app length] || ![value[app] isKindOfClass:NSString.class] || ![value[app] length]) return NO;
        } else if ([key isEqual:TWKeyRememberFrames]) {
            if (![value isKindOfClass:NSDictionary.class]) return NO;
            for (id app in value) {
                id frame = value[app];
                if (![app isKindOfClass:NSString.class] || ![app length] || ![frame isKindOfClass:NSDictionary.class]) return NO;
                for (NSString *k in @[@"x",@"y",@"w",@"h"]) if (![frame[k] isKindOfClass:NSNumber.class]) return NO;
            }
        } else if ([key isEqual:TWKeyCraneAppList]) {
            if (![value isKindOfClass:NSArray.class]) return NO;
            for (id app in value) if (![app isKindOfClass:NSString.class] || ![app length]) return NO;
        } else if ([key isEqual:TWKeyCraneContainers]) {
            if (![value isKindOfClass:NSArray.class]) return NO;
            for (id entry in value) {
                if (![entry isKindOfClass:NSDictionary.class]) return NO;
                if (![entry[@"bundleID"] isKindOfClass:NSString.class]) return NO;
            }
        } else if ([key isEqual:TWKeyRememberStates]) {
            if (![value isKindOfClass:NSDictionary.class]) return NO;
        } else return NO;
    }
    return YES;
}

static NSDictionary *TWReadDomain(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    CFPreferencesAppSynchronize(TWDomainRef());
    CFArrayRef keys = CFPreferencesCopyKeyList(TWDomainRef(), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys) {
        for (id key in (__bridge_transfer NSArray *)keys) {
            if (![key isKindOfClass:NSString.class]) continue;
            CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, TWDomainRef());
            if (value) out[key] = (__bridge_transfer id)value;
        }
    }
    return out;
}

static void TWWriteValues(NSDictionary *values) {
    for (NSString *key in values) {
        id value = values[key];
        if ([value isKindOfClass:NSNull.class]) continue;
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, TWDomainRef());
    }
    CFPreferencesAppSynchronize(TWDomainRef());
}

// 旧版本留下的是文件（Preferences 目录或 Library/Twin）。域里没数据时导一次。
static void TWMigrateIfNeeded(NSDictionary *current) {
    if (current.count) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *sources = [NSMutableArray array];
    [sources addObjectsFromArray:TWLegacyPrefsFiles()];
    for (NSString *dir in TWPrefsDirectoryCandidates()) {
        NSString *p = [dir stringByAppendingPathComponent:@"prefs.plist"];
        if (p.length && ![sources containsObject:p]) [sources addObject:p];
    }
    [sources sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDate *ad = [[fm attributesOfItemAtPath:a error:nil] fileModificationDate] ?: NSDate.distantPast;
        NSDate *bd = [[fm attributesOfItemAtPath:b error:nil] fileModificationDate] ?: NSDate.distantPast;
        return [bd compare:ad];
    }];
    for (NSString *source in sources) {
        if (![[[fm attributesOfItemAtPath:source error:nil] fileType] isEqual:NSFileTypeRegular]) continue;
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:source];
        if (!TWValidMigration(dict)) continue;
        TWWriteValues(dict);
        TWRuntimeLog(@"[prefs] migrated %lu keys from %@", (unsigned long)dict.count, source);
        break;
    }
}

@implementation TWPrefs {
    NSMutableDictionary *_cache;
    NSMutableSet *_pendingKeys;
    int _notifyToken;
    BOOL _loggedPath;
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
        NSMutableDictionary *disk = [TWReadDomain() mutableCopy] ?: [NSMutableDictionary dictionary];
        if (!disk.count && !_pendingKeys.count) TWMigrateIfNeeded(disk);
        if (!disk.count) disk = [NSMutableDictionary dictionary];
        for (NSString *key in _pendingKeys) {
            if (_cache[key]) disk[key] = _cache[key]; else [disk removeObjectForKey:key];
        }
        _cache = disk;
        if (!_loggedPath) {
            _loggedPath = YES;
            TWRuntimeLog(@"[prefs] domain=%@ keys=%lu twEnabled=%@ wakeMode=%@ arcEnabled=%@ crane=%@",
                         TWDomain, (unsigned long)_cache.count,
                         _cache[TWKeyEnabled] ?: @"-", _cache[TWKeyWakeMode] ?: @"-",
                         _cache[TWKeyArcEnabled] ?: @"-", _cache[TWKeyCraneEnabled] ?: @"-");
        }
    }
}

- (id)objectForKey:(NSString *)key {
    if (!key.length) return nil;
    [self reload];
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
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        for (NSString *key in _pendingKeys) {
            id value = _cache[key];
            values[key] = value ?: (id)[NSNull null];
        }
        for (NSString *key in values) {
            CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                     [values[key] isKindOfClass:NSNull.class] ? NULL : (__bridge CFPropertyListRef)values[key],
                                     TWDomainRef());
        }
        BOOL ok = CFPreferencesAppSynchronize(TWDomainRef());
        NSDictionary *readback = TWReadDomain();
        BOOL verified = YES;
        for (NSString *key in _pendingKeys) {
            id want = _cache[key];
            id got = readback[key];
            if (want && ![got isEqual:want]) { verified = NO; break; }
            if (!want && got) { verified = NO; break; }
        }
        TWRuntimeLog(@"[prefs] save %@ (sync=%d) keys=%@", verified ? @"ok" : @"FAILED", ok,
                     [[_pendingKeys allObjects] componentsJoinedByString:@","] ?: @"-");
        if (verified) {
            _cache = [readback mutableCopy];
            [_pendingKeys removeAllObjects];
            notify_post(TWPrefsChangedNotification);
        }
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


#pragma mark - 原版 ARC 设置（域：com.susudear.screencoreprefs）

static CFStringRef TWArcOrigDomain(void) { return CFSTR("com.susudear.screencoreprefs"); }

double TWArcOrigNumber(NSString *key, double fallback) {
    if (![key isKindOfClass:NSString.class] || !key.length) return fallback;
    CFPreferencesAppSynchronize(TWArcOrigDomain());
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, TWArcOrigDomain());
    if (!v) return fallback;
    double out = fallback;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberDoubleType, &out);
    else if (CFGetTypeID(v) == CFBooleanGetTypeID()) out = CFBooleanGetValue(v) ? 1 : 0;
    CFRelease(v);
    return out;
}

BOOL TWArcOrigBool(NSString *key, BOOL fallback) {
    return TWArcOrigNumber(key, fallback ? 1 : 0) != 0;
}
