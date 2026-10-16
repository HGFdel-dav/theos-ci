// TWPrefs.m
#import "TWPrefs.h"
#import <UIKit/UIKit.h>   // UIApplicationDidBecomeActiveNotification

@implementation TWPrefs {
    NSMutableDictionary *_cache;
    BOOL _dirty;
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
        [self reload];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload)
                                                     name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}

- (void)reload {
    NSString *path = TWPrefsFilePath();
    _cache = [NSMutableDictionary dictionary];
    if (path.length) {
        NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:path];
        if (disk) [_cache setDictionary:disk];
    }
    _dirty = NO;
}

- (id)objectForKey:(NSString *)key {
    @synchronized (self) { return _cache[key]; }
}

- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)def {
    id v = [self objectForKey:key];
    return v ? [v boolValue] : def;
}

- (NSInteger)integerForKey:(NSString *)key defaultValue:(NSInteger)def {
    id v = [self objectForKey:key];
    return v ? [v integerValue] : def;
}

- (CGFloat)floatForKey:(NSString *)key defaultValue:(CGFloat)def {
    id v = [self objectForKey:key];
    return v ? [v floatValue] : def;
}

- (void)setObject:(id)obj forKey:(NSString *)key {
    @synchronized (self) {
        if (obj) _cache[key] = obj; else [_cache removeObjectForKey:key];
        _dirty = YES;
    }
}

- (void)setBool:(BOOL)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setInteger:(NSInteger)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setFloat:(CGFloat)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }

- (void)synchronize {
    NSString *path = TWPrefsFilePath();
    if (!path.length) return;
    NSDictionary *snapshot;
    @synchronized (self) { snapshot = [_cache copy]; _dirty = NO; }
    NSError *err = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    if (![snapshot writeToFile:path atomically:YES]) {
        NSLog(@"[Twin] failed to write prefs: %@", err.localizedDescription ?: @"unknown");
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

@end