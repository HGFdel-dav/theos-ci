//
//  POSplitXSettings.m
//  SplitX
//

#import "POSplitXSettings.h"
#import "POSplitXLog.h"

static NSString *const PXDomain = @"com.niubiprass.splitx";
/// 设置页用 suite 写入；这里必须读同一个域，不能用 standardUserDefaults（那是 SpringBoard 自己的域）。
static NSUserDefaults *PXDefaults(void) {
    static NSUserDefaults *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ defaults = [[NSUserDefaults alloc] initWithSuiteName:PXDomain]; });
    return defaults;
}
static void PXSettingsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                              const void *object, CFDictionaryRef userInfo) {
    [[POSplitXSettings shared] reload];
}
static NSArray<NSString *> *PXAllowedKeys(void) {
    return @[@"iconSize", @"tileSize", @"itemSpacing", @"panelRadius", @"panelAlpha",
             @"panelColumns", @"fanRadius", @"fanSpan", @"animationSpeed", @"triggerWidth", @"triggerOffsetY", @"dockEnabled", @"dockScale"];
}

@implementation POSplitXSettings {
    NSMutableDictionary<NSString *, id> *_values;
}

+ (instancetype)shared {
    static POSplitXSettings *settings;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ settings = [POSplitXSettings new]; });
    return settings;
}

- (instancetype)init {
    if ((self = [super init])) {
        _values = [NSMutableDictionary dictionary];
        [self reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge const void *)self, PXSettingsChanged,
                                        CFSTR("com.niubiprass.splitx.settings-changed"),
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    return self;
}

- (void)reload {
    NSDictionary *before = [_values copy];
    [_values removeAllObjects];
    NSDictionary *stored = [PXDefaults() dictionaryRepresentation];
    for (NSString *key in PXAllowedKeys()) {
        id value = stored[key];
        if (value) _values[key] = value;
    }
    for (NSString *key in PXAllowedKeys()) {
        id old = before[key] ?: @"(空)";
        id now = _values[key] ?: @"(空)";
        if (![old isEqual:now]) {
            PXLog(@"prefs", @"changed %@: %@ -> %@", key, old, now);
        }
    }
    PXLog(@"prefs", @"reload keys=%lu", (unsigned long)_values.count);
}

- (CGFloat)doubleForKey:(NSString *)key fallback:(CGFloat)fallback min:(CGFloat)min max:(CGFloat)max {
    id raw = _values[key];
    if (![raw respondsToSelector:@selector(doubleValue)]) return fallback;
    CGFloat v = [raw doubleValue];
    return MIN(MAX(v, min), max);
}

- (CGFloat)iconSize { return [self doubleForKey:@"iconSize" fallback:46 min:40 max:72]; }
- (CGFloat)tileSize { return [self doubleForKey:@"tileSize" fallback:62 min:52 max:88]; }
- (CGFloat)itemSpacing { return [self doubleForKey:@"itemSpacing" fallback:6 min:0 max:20]; }
- (CGFloat)panelRadius { return [self doubleForKey:@"panelRadius" fallback:30 min:12 max:40]; }
- (CGFloat)panelAlpha { return [self doubleForKey:@"panelAlpha" fallback:100 min:40 max:100] / 100.0; }
- (NSInteger)panelColumns { return (NSInteger)[self doubleForKey:@"panelColumns" fallback:2 min:1 max:3]; }
- (CGFloat)fanRadius { return [self doubleForKey:@"fanRadius" fallback:170 min:90 max:210]; }
- (CGFloat)fanSpan { return [self doubleForKey:@"fanSpan" fallback:120 min:60 max:200]; }
- (CGFloat)animationSpeed { return [self doubleForKey:@"animationSpeed" fallback:100 min:50 max:200]; }
- (CGFloat)triggerWidth { return [self doubleForKey:@"triggerWidth" fallback:30 min:8 max:60]; }
- (CGFloat)triggerOffsetY { return [self doubleForKey:@"triggerOffsetY" fallback:0 min:-200 max:200]; }
- (CGFloat)dockScale { return [self doubleForKey:@"dockScale" fallback:0.28 min:0.2 max:0.5]; }

- (BOOL)dockEnabled {
    id raw = _values[@"dockEnabled"];
    return [raw respondsToSelector:@selector(boolValue)] ? [raw boolValue] : YES;
}

- (void)setValue:(id)value forKey:(NSString *)key {
    if (![PXAllowedKeys() containsObject:key]) {
        PXLog(@"prefs", @"reject unknown key=%@", key);
        return;
    }
    _values[key] = value;
    [PXDefaults() setObject:value forKey:key];
    [PXDefaults() synchronize];
    PXLog(@"prefs", @"set %@=%@", key, value);
}

- (NSDictionary<NSString *, id> *)allValues {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *key in PXAllowedKeys()) {
        id value = _values[key];
        if (value) out[key] = value;
    }
    return out;
}

#pragma mark - 期望容器

- (void)setExpectedContainer:(NSString *)container forBundleIdentifier:(NSString *)bundle {
    if (bundle.length == 0) return;
    NSString *key = [@"expectedContainer." stringByAppendingString:bundle];
    if (container.length) {
        [PXDefaults() setObject:container forKey:key];
    } else {
        [PXDefaults() removeObjectForKey:key];
    }
    [PXDefaults() synchronize];
    PXLog(@"route", @"expected %@ -> %@", bundle, container ?: @"(clear)");
}

- (NSString *)expectedContainerForBundleIdentifier:(NSString *)bundle {
    if (bundle.length == 0) return nil;
    id value = [PXDefaults() objectForKey:[@"expectedContainer." stringByAppendingString:bundle]];
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

- (BOOL)exportBackupToPath:(NSString *)path error:(NSError **)error {
    NSDictionary *payload = @{@"version": @1, @"exportedAt": NSDate.date, @"values": [self allValues]};
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:payload
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0 error:error];
    if (!data) { PXLog(@"backup", @"export failed %@", *error); return NO; }
    BOOL ok = [data writeToFile:path atomically:YES];
    PXLog(@"backup", @"export %@ ok=%d bytes=%lu", path, ok, (unsigned long)data.length);
    if (!ok && error) *error = [NSError errorWithDomain:PXDomain code:2 userInfo:nil];
    return ok;
}

- (BOOL)importBackupFromPath:(NSString *)path error:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        PXLog(@"backup", @"import missing file %@", path);
        if (error) *error = [NSError errorWithDomain:PXDomain code:3 userInfo:nil];
        return NO;
    }
    NSDictionary *payload = [NSPropertyListSerialization propertyListWithData:data
                                                                     options:NSPropertyListImmutable
                                                                      format:NULL error:error];
    NSDictionary *values = [payload isKindOfClass:NSDictionary.class] ? payload[@"values"] : nil;
    if (![values isKindOfClass:NSDictionary.class]) {
        PXLog(@"backup", @"import invalid payload");
        if (error) *error = [NSError errorWithDomain:PXDomain code:4 userInfo:nil];
        return NO;
    }
    NSUInteger applied = 0;
    for (NSString *key in PXAllowedKeys()) {
        id value = values[key];
        if (!value) continue;
        [self setValue:value forKey:key];
        applied++;
    }
    PXLog(@"backup", @"import applied=%lu", (unsigned long)applied);
    return applied > 0;
}

@end
